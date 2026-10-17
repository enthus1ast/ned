# ════════════════════════════════════════════════════════════════════════════
#  nedls — open documents as ned Buffers (so the engine reads the unsaved text, as in the editor), positions
#  in the client's encoding (UTF-16 code units, or UTF-8 bytes when both sides speak it; ned's columns are
#  bytes), and edits as LSP TextEdits.
# ════════════════════════════════════════════════════════════════════════════

type LsDoc = ref object
  uri: string                  # as the client wrote it (replies use the same text)
  b: Buffer
  version: int
  changedAt: MonoTime          # its last change (checks wait for a pause)
  editPos: Pos                 # where it changed last (misspelled names are looked for around it)

var
  lsDocs: Table[string, LsDoc]        # uri → open document
  lsUtf8 = false                      # positions count UTF-8 bytes (else UTF-16 code units)
  lsActive: LsDoc                     # the document worked on last: the one checked while typing (ned's current tab)
  lsDiskLines: Table[string, (string, seq[string])]   # path → (stamp, lines) of files read for positions
  lsDiskOrder: seq[string]

proc lsPathOf(uri: string): string =
  ## the file a file:// URI names ("" for other schemes: untitled:, …)
  if not uri.startsWith("file:"): return ""
  var p = pathFromUri(uri)
  if p.startsWith("localhost/"): p = p["localhost".len .. ^1]
  if p.len > 2 and p[0] == '/' and p[2] == ':': p = p[1 .. ^1]     # (file:///C:/…)
  try: normalizedPath(p)
  except CatchableError: p

proc lsUriOf(path: string): string =
  ## the URI for a file: an open document's own, else file://…
  for u, d in lsDocs:
    if d.b.path == path: return u
  uriFromPath(path)

proc lsDocByPath(path: string): LsDoc =
  for u, d in lsDocs:
    if d.b.path == path: return d
  nil

proc lsLinesOf(path: string): seq[string] =
  ## a file's lines for positions: an open document's, else from disk (a few kept, by mtime and size)
  let d = lsDocByPath(path)
  if d != nil: return d.b.lines
  let st = nxStamp(path)
  if path in lsDiskLines and lsDiskLines[path][0] == st: return lsDiskLines[path][1]
  try:
    if st.len == 0 or getFileSize(path) > 8_000_000: return @[]
    result = readFile(path).replace("\r\n", "\n").split('\n')
  except CatchableError: return @[]
  lsDiskLines[path] = (st, result)
  lsDiskOrder.add path
  if lsDiskOrder.len > 40:
    lsDiskLines.del lsDiskOrder[0]
    lsDiskOrder.delete(0)

# ── positions ──

proc lsChar(s: string, col: int): int =
  ## ned's byte column → the client's character offset
  let c = clamp(col, 0, s.len)
  if lsUtf8: return c
  var i = 0
  while i < c:
    if s[i].uint8 < 0x80:
      inc result
      inc i
    else:
      let (cp, n) = runeAt(s, i)
      result += (if cp >= 0x10000: 2 else: 1)
      i += n

proc lsCol(s: string, ch: int): int =
  ## the client's character offset → ned's byte column (past the end: the end; inside a character: its start)
  if ch <= 0: return 0
  if lsUtf8:
    result = min(ch, s.len)
    while result > 0 and result < s.len and (s[result].uint8 and 0xC0) == 0x80: dec result
    return
  var i = 0
  var k = 0
  while i < s.len:
    if s[i].uint8 < 0x80:
      if k >= ch: return i
      inc k
      inc i
    else:
      let (cp, n) = runeAt(s, i)
      let w = if cp >= 0x10000: 2 else: 1
      if k + w > ch: return i
      k += w
      i += n
  s.len

proc lsPosIn(lines: seq[string], l, c: int): JsonNode =
  ## {line, character} for byte position (l, c) of these lines
  if lines.len == 0: return %*{"line": max(0, l), "character": max(0, c)}
  if l > lines.high: return %*{"line": lines.high, "character": lsChar(lines[^1], lines[^1].len)}
  let ll = max(0, l)
  %*{"line": ll, "character": lsChar(lines[ll], c)}

proc lsRangeIn(lines: seq[string], l0, c0, l1, c1: int): JsonNode =
  %*{"start": lsPosIn(lines, l0, c0), "end": lsPosIn(lines, l1, c1)}

proc lsPos(b: Buffer, p: Pos): JsonNode = lsPosIn(b.lines, p.line, p.col)

proc lsToPos(b: Buffer, j: JsonNode): Pos =
  ## an LSP position in this buffer (clamped to its text; past the last line: the end of the text)
  if j == nil or j.kind != JObject: lsRaise(ErrInvalidParams, "position expected")
  let l = j{"line"}.getInt(-1)
  let ch = j{"character"}.getInt(0)
  if l < 0: lsRaise(ErrInvalidParams, "invalid position")
  if l > b.lines.high: return Pos(line: b.lines.high, col: b.lines[^1].len)
  Pos(line: l, col: lsCol(b.lines[l], ch))

proc lsWordEnd(s: string, c: int): int =
  ## where the name starting at byte c ends (an identifier, or a `backticked` one)
  if c >= s.len: return c
  if s[c] == '`':
    let e = s.find('`', c + 1)
    return if e < 0: c + 1 else: e + 1
  result = c
  while result < s.len and (isWordByte(s[result]) or s[result].uint8 >= 0x80): inc result
  if result == c: result = min(s.len, c + 1)

# ── documents ──

proc lsDocOf(params: JsonNode, required = true): LsDoc =
  ## the open document a request is about (an error for one that is not open)
  let u = params{"textDocument"}{"uri"}.getStr
  if u.len == 0: lsRaise(ErrInvalidParams, "textDocument.uri expected")
  result = lsDocs.getOrDefault(u)
  if result == nil and required: lsRaise(ErrInvalidParams, "document not open: " & u)

proc lsFocus(d: LsDoc, p: Pos) =
  ## make the document ned's current buffer with its cursor at p (ned's commands work on the current one)
  let i = bufs.find(d.b)
  if i >= 0: curBuf = i
  d.b.setSingle(p)
  lsActive = d

proc lsNormText(t: string): string =
  ## line ends as ned keeps them: \n only
  if '\r' notin t: return t
  t.replace("\r\n", "\n").replace('\r', '\n')

proc lsMarkChanged(d: LsDoc, at: Pos) =
  let b = d.b
  b.savedSeq = -1                      # (unsaved changes: ned's buffers know it from their undo history)
  b.lspChangeAt = MonoTime()           # (no pause to wait for: the client asks when it wants an answer)
  d.changedAt = getMonoTime()
  d.editPos = at
  lsActive = d

proc lsOpenDoc(uri, text0: string, version: int, langId: string): LsDoc =
  let path = lsPathOf(uri)
  if uri in lsDocs:
    let old = lsDocs[uri]
    let i = bufs.find(old.b)
    if i >= 0: bufs.delete(i)
  if path.len > 0:
    let i = bufIndexByPath(path)          # (a buffer a quick fix loaded for another file)
    if i > 0: bufs.delete(i)
  let b = newBuffer()
  b.path = path
  b.setContent(lsNormText(text0))
  b.lang = if path.len > 0: detectLang(path, b.lines[0]) else: nil
  if b.lang == nil or b.lang.id == "plaintext" or (langId == "nim" and b.lang.mode != lmNim):
    b.lang = (if langId in ["nim", "nimscript", "nimble"] or path.len == 0: langByName("Nim") else: langByName("Text"))
  b.detectIndent()
  if path.len > 0: b.applyEditorConfig()
  b.savedSeq = 0
  b.setSingle(Pos())
  bufs.add b
  curBuf = bufs.high
  result = LsDoc(uri: uri, b: b, version: version, changedAt: getMonoTime())
  lsDocs[uri] = result
  lsActive = result

proc lsCloseDoc(uri: string) =
  let d = lsDocs.getOrDefault(uri)
  if d == nil: return
  lsDocs.del uri
  let i = bufs.find(d.b)
  if i >= 0: bufs.delete(i)
  curBuf = 0
  if lsActive == d: lsActive = nil
  nxWarm.excl d.b.id
  semMaps.del d.b.id
  if d.b.path.len > 0:
    diagsBuild.del d.b.path            # (what the unsaved text had: the file on disk is checked again on save)
    unusedHints.del d.b.path

proc lsApplyChange(d: LsDoc, ch: JsonNode) =
  ## one entry of didChange's contentChanges: a range and its new text, or the whole text
  let b = d.b
  let text = lsNormText(ch{"text"}.getStr)
  let r = ch{"range"}
  if r == nil or r.kind != JObject:
    let keepLang = b.lang
    b.setContent(text)
    b.lang = keepLang
    lsMarkChanged(d, Pos())
    return
  var a = lsToPos(b, r{"start"})
  var c = lsToPos(b, r{"end"})
  if c < a: swap(a, c)
  let e = b.rawReplace(a, c, text)
  b.normalize()
  lsMarkChanged(d, e)

# ── edits ──

proc lsEol(b: Buffer): string = (if b != nil and b.crlf: "\r\n" else: "\n")

proc lsLineEdits(old, nw: seq[string], eol = "\n"): JsonNode =
  ## TextEdits that turn lines `old` into `nw`, only where they differ (positions in `old`)
  result = newJArray()
  if old == nw: return
  let ops = lineDiff(old, nw)
  var ai = 0
  var bi = 0
  var k = 0
  while k < ops.len:
    if ops[k].kind == ' ':
      inc ai
      inc bi
      inc k
      continue
    let a0 = ai
    let b0 = bi
    while k < ops.len and ops[k].kind != ' ':
      if ops[k].kind == '-': inc ai else: inc bi
      inc k
    let (a1, b1) = (ai, bi)
    let mid = nw[b0 ..< b1].join(eol)
    if a1 > a0 and b1 > b0:
      result.add %*{"range": lsRangeIn(old, a0, 0, a1 - 1, old[a1 - 1].len), "newText": mid}
    elif a1 > a0:                                   # lines removed
      if a1 < old.len: result.add %*{"range": lsRangeIn(old, a0, 0, a1, 0), "newText": ""}
      elif a0 > 0:
        result.add %*{"range": lsRangeIn(old, a0 - 1, old[a0 - 1].len, a1 - 1, old[a1 - 1].len), "newText": ""}
      else: result.add %*{"range": lsRangeIn(old, 0, 0, a1 - 1, old[a1 - 1].len), "newText": ""}
    else:                                           # lines added
      if a0 < old.len: result.add %*{"range": lsRangeIn(old, a0, 0, a0, 0), "newText": mid & eol}
      else: result.add %*{"range": lsRangeIn(old, old.high, old[^1].len, old.high, old[^1].len), "newText": eol & mid}

proc lsTextLines(text: string): seq[string] =
  ## a whole text as lines (a last line end does not make an empty line)
  result = text.split('\n')
  if result.len > 1 and result[^1].len == 0: result.setLen(result.len - 1)

proc lsDryRun(act: Action): seq[(string, seq[string], seq[string])] =
  ## what an editor action would change, without changing it: (file, its lines before, after) for every file it
  ## edits. The action runs on ned's buffers as in the editor; then each edit is undone and every table it moved
  ## (problems, inlays) is put back. A file it opened for itself is closed again.
  var saved: seq[(Buffer, int, int, int, seq[Cursor])]
  for b in bufs: saved.add (b, b.undoStack.len, b.redoStack.len, b.changeId, b.cursors)
  let nb = bufs.len
  let snapLines = if lsActive != nil: lsActive.b.lines else: @[]
  let snapFor = if lsActive != nil: lsActive.b else: nil
  let dB = diagsBuild
  let dL = diagsLsp
  let dF = diagsFfi
  let dE = diagsEmit
  let uH = unusedHints
  let logLen = msgLog.len
  let cb = curBuf
  try: act()
  except Exception as e: lsLog("quick fix failed: " & e.msg)
  for (b, ul, rl, cid, cs) in saved:
    if b.changeId == cid: continue
    let after = b.lines
    while b.undoStack.len > ul:
      let before = b.undoStack.len
      b.undo()
      if b.undoStack.len >= before: break
    if b == snapFor and b.lines != snapLines:
      b.lines = snapLines                           # (an edit that kept no undo step: the copy taken before)
      inc b.changeId
    if b.undoStack.len > ul: b.undoStack.setLen(ul)
    b.redoStack.setLen(min(rl, b.redoStack.len))
    b.cursors = cs
    b.normalize()
    b.hlValid = 0
    b.lspChangeAt = MonoTime()
    if b.chkAt == cid: b.chkAt = b.changeId        # (put back as it was: no new check for an unchanged text)
    if typoAt.getOrDefault(b.id, -2) == cid: typoAt[b.id] = b.changeId
    if after != b.lines and b.path.len > 0: result.add (b.path, b.lines, after)
  if bufs.len > nb:
    for i in countdown(bufs.high, nb):
      let x = bufs[i]
      if x.path.len > 0 and x.changeId > 1:
        var before: seq[string]
        try: before = lsTextLines(readFile(x.path).replace("\r\n", "\n"))
        except CatchableError: before = @[]
        if before.len == 0: before = @[""]
        if before != x.lines: result.add (x.path, before, x.lines)
      bufs.delete(i)
  diagsBuild = dB
  diagsLsp = dL
  diagsFfi = dF
  diagsEmit = dE
  unusedHints = uH
  if msgLog.len > logLen: msgLog.setLen(logLen)
  curBuf = clamp(cb, 0, bufs.high)

proc lsWorkspaceEdit(changes: seq[(string, seq[string], seq[string])]): JsonNode =
  ## {changes: {uri: [TextEdit]}} for (file, before, after) triples
  var ch = newJObject()
  for (path, before, after) in changes:
    let d = lsDocByPath(path)
    let eol = if d != nil: lsEol(d.b) else: "\n"
    let es = lsLineEdits(before, after, eol)
    if es.len > 0: ch[lsUriOf(path)] = es
  if ch.len == 0: return nil
  %*{"changes": ch}
