proc mbHeader(lang: Lang, path: string, start: int): string =
  (if lang != nil and lang.lineComment.len > 0: lang.lineComment else: "#") & " § " & relPath(path) & ":" & $(start + 1)

proc mbHeaderOf(lang: Lang, sc: MbSection): string =
  mbHeader(lang, sc.path, sc.start) & (if sc.note.len > 0: "  — " & sc.note else: "")

proc mbReadFile(path: string): tuple[lines: seq[string], nl, crlf: bool] =
  ## a file that is not open, as a buffer would have it: its lines (not the empty one after its last line end), CR LF
  ## line ends taken off — and how it ended and its line ends, to write it back the same way
  try:
    var t = readFile(path)
    result.crlf = "\r\n" in t
    if result.crlf: t = t.replace("\r\n", "\n")
    result.nl = t.endsWith("\n")
    result.lines = t.split('\n')
    if result.nl and result.lines.len > 1: result.lines.setLen(result.lines.len - 1)
  except IOError, OSError: discard

proc fileLinesNow(path: string): seq[string] =
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i].lines
  mbReadFile(path).lines

func mbTextOf(lines: seq[string]): string =
  ## a multibuffer's text for setContent or setTextMinimal: a line end after the last line, so a last piece that
  ## ends with an empty line keeps it (both take one empty line at the end for the file's last line end)
  lines.join("\n") & "\n"


var
  mbLast = -1                  # the multibuffer pieces are added to (Multibuffer: add the selection)
  mbSig: Table[int, string]    # each multibuffer's files as they were when it was made: their versions (refresh)
  mbPumpAt: MonoTime

proc mbMatchAt(cur, orig: seq[string], s: int): bool =
  if s < 0 or s + orig.len > cur.len: return false
  for i in 0 ..< orig.len:
    if cur[s + i] != orig[i]: return false
  true

proc mbFind(cur, orig: seq[string], near: int): int =
  ## where the lines `orig` are in the file now: at `near`, else the nearest place (-1: not there as they were)
  if orig.len == 0: return clamp(near, 0, max(0, cur.len - 1))
  if mbMatchAt(cur, orig, near): return near
  for d in 1 .. cur.len:
    if near - d < 0 and near + d + orig.len > cur.len: break
    if mbMatchAt(cur, orig, near - d): return near - d
    if mbMatchAt(cur, orig, near + d): return near + d
  -1

proc mbAnchor(sc: MbSection, cur: seq[string]): MbSection =
  ## the piece where it is in the file now: moved with the lines added or removed above it; when its own lines were
  ## changed (elsewhere), the lines between its first and last ones — or as many lines from where it was
  result = sc
  if cur.len == 0: return
  let s = mbFind(cur, sc.orig, sc.start)
  if s >= 0:
    result.start = s
    return
  var a = -1
  var e = -1
  if sc.orig.len > 0:
    for d in 0 .. 400:
      for c in [sc.start - d, sc.start + d]:
        if a < 0 and c >= 0 and c < cur.len and cur[c] == sc.orig[0]: a = c
      if a >= 0: break
    if a >= 0:
      for c in a ..< min(cur.len, a + sc.orig.len * 3 + 40):
        if cur[c] == sc.orig[^1]:
          e = c
          if c >= a + sc.orig.len - 1: break
  if a < 0 or e < a:
    a = clamp(sc.start, 0, cur.high)
    e = min(cur.high, a + max(1, sc.orig.len) - 1)
  result.start = a
  result.orig = cur[a .. e]

proc mbMerge(secs: seq[MbSection]): seq[MbSection] =
  ## pieces of a file that touch or overlap become one, as many times as it takes; a file's pieces go where its
  ## first one was, in the order of their lines
  var order: seq[string]
  var byPath: Table[string, seq[MbSection]]
  for sc in secs:
    if sc.path notin byPath:
      order.add sc.path
      byPath[sc.path] = @[]
    byPath[sc.path].add sc
  for path in order:
    var ps = byPath[path]
    ps.sort(proc(x, y: MbSection): int = cmp(x.start, y.start))
    let cur = fileLinesNow(path)
    var acc: seq[MbSection]
    for sc in ps:
      if acc.len > 0 and cur.len > 0 and sc.start <= acc[^1].start + acc[^1].orig.len:
        let x = acc[^1]
        let a = x.start
        let e = min(cur.high, max(x.start + x.orig.len, sc.start + sc.orig.len) - 1)
        if e >= a and a <= cur.high:
          acc[^1].orig = cur[a .. e]
          if acc[^1].note.len == 0: acc[^1].note = sc.note
          continue
      acc.add sc
    result.add acc

proc mbSignature(secs: seq[MbSection]): string =
  ## the versions of a multibuffer's files: an open one's edit count, another's time on disk
  var seen: seq[string]
  for sc in secs:
    if sc.path in seen: continue
    seen.add sc.path
    let i = bufIndexByPath(sc.path)
    result.add sc.path & "=" & (if i >= 0: "b" & $bufs[i].changeId
                                else: (try: $getLastModificationTime(sc.path).toUnixFloat except CatchableError: "?")) & ";"

proc mbFiles(secs: seq[MbSection]): Table[string, seq[string]] =
  ## the lines of a multibuffer's files as they are now, each file read once
  for sc in secs:
    if sc.path notin result: result[sc.path] = fileLinesNow(sc.path)

proc mbRebuild(b: Buffer, secs: seq[MbSection]) =
  ## the multibuffer's text made again from its pieces as they are in the files — the cursor kept on its line. Its
  ## undo steps go: they would put back text the pieces no longer have
  multiBufs[b.id] = secs
  var text: seq[string]
  for sc in secs:
    text.add mbHeaderOf(b.lang, sc)
    text.add sc.orig
  b.setTextMinimal(mbTextOf(text))
  b.undoStack.setLen(0)
  b.redoStack.setLen(0)
  b.undoBranches.setLen(0)
  b.savedSeq = b.topSeq()
  b.normalize()
  mbSig[b.id] = mbSignature(secs)
  needRender = true

proc mbHeaderLines(b: Buffer): seq[int] =
  ## the § header lines of a multibuffer, in order
  let secs = multiBufs.getOrDefault(b.id)
  if secs.len == 0: return
  var k = 0
  var want = mbHeaderOf(b.lang, secs[0])
  for l in 0 ..< b.lines.len:
    if b.lines[l] == want:
      result.add l
      inc k
      if k >= secs.len: break
      want = mbHeaderOf(b.lang, secs[k])

proc mbPieceAt(b: Buffer, line: int): (int, int) =
  ## the piece of a multibuffer a line is in (its index) and the line of its § header — (-1, -1) before the first
  result = (-1, -1)
  for k, hl in b.mbHeaderLines():
    if hl > line: break
    result = (k, hl)

proc mbSourceLines(b: Buffer): seq[int] =
  ## each line of a multibuffer: the line of its file it shows (-1: a § header, or before the first)
  result = newSeq[int](b.lines.len)
  for l in 0 ..< result.len: result[l] = -1
  let secs = multiBufs.getOrDefault(b.id)
  let hs = b.mbHeaderLines()
  for k, hl in hs:
    let e = if k + 1 < hs.len: hs[k + 1] else: b.lines.len
    for l in hl + 1 ..< e: result[l] = secs[k].start + (l - hl - 1)

proc mbPlace(b: Buffer, p: Pos): (bool, string, Pos) =
  ## the file and the place in it behind a place in a multibuffer (on a § header: the piece's first line)
  let (k, hl) = b.mbPieceAt(p.line)
  if k < 0: return
  let sc = multiBufs[b.id][k]
  if p.line == hl: return (true, sc.path, Pos(line: sc.start, col: 0))
  (true, sc.path, Pos(line: sc.start + (p.line - hl - 1), col: p.col))

proc mbLineOf(b: Buffer, path: string, line: int): int =
  ## the line of a multibuffer that shows that line of that file (-1: none)
  let secs = multiBufs.getOrDefault(b.id)
  let hs = b.mbHeaderLines()
  for k in 0 ..< min(secs.len, hs.len):
    let sc = secs[k]
    let n = (if k + 1 < hs.len: hs[k + 1] else: b.lines.len) - hs[k] - 1
    if sc.path == path and line >= sc.start and line < sc.start + n: return hs[k] + 1 + (line - sc.start)
  -1

proc mbFreeTitle(t: string): string =
  ## a multibuffer's title: `t`, or `t (2)` … when a tab of that title has edits not saved (a new multibuffer of
  ## the same title would take its place and lose them)
  result = t
  var n = 1
  while true:
    var taken = false
    for x in bufs:
      if x.title == result and x.path.len == 0 and x.dirty: taken = true
    if not taken: return
    inc n
    result = t & " (" & $n & ")"

proc openMultibuffer(title: string, hits: seq[(string, int)], context = 1) =
  ## every hit with a line of context around it, file by file, in one buffer you can edit; Ctrl+S saves
  var order: seq[string]
  var byFile: Table[string, seq[int]]
  for (path, l) in hits:
    if path notin byFile:
      order.add path
      byFile[path] = @[]
    byFile[path].add l
  var secs: seq[MbSection]
  for path in order:
    let ls = fileLinesNow(path)
    if ls.len == 0: continue
    var hs = byFile[path]
    hs.sort()
    var a = -1
    var e = -1
    for l in hs:
      if l < 0 or l > ls.high: continue           # a stale hit: the file got shorter since the search
      let la = max(0, l - context)
      let le = min(ls.high, l + context)
      if a >= 0 and la <= e + 1: e = max(e, le)
      else:
        if a >= 0: secs.add MbSection(path: path, start: a, orig: ls[a .. e])
        a = la
        e = le
    if a >= 0: secs.add MbSection(path: path, start: a, orig: ls[a .. e])
  if secs.len == 0:
    info("Nothing to show")
    return
  let lang = detectLang(secs[0].path, "")
  var text: seq[string]
  for sc in secs:
    text.add mbHeaderOf(lang, sc)
    text.add sc.orig
  let b = openScratch(mbFreeTitle("Multibuffer: " & title), mbTextOf(text), lang)
  b.readOnly = false
  b.savedSeq = b.topSeq()
  multiBufs[b.id] = secs
  mbLast = b.id
  info($secs.len & (if secs.len == 1: " piece of " else: " pieces of ") & $order.len &
       (if order.len == 1: " file" else: " files") & " — edit them here, Ctrl+S writes every change back")

proc openMultibufferOf(title: string, ranges: seq[tuple[path: string, first, last: int, note: string]],
                       focusIt = true): Buffer =
  ## a multibuffer of these pieces — lines first .. last of a file, with a note — for plugins (what they give is
  ## clamped to the files' lines)
  var secs: seq[MbSection]
  var files: Table[string, seq[string]]
  for r in ranges:
    if r.path notin files: files[r.path] = fileLinesNow(r.path)
    let cur = files[r.path]
    if cur.len == 0: continue
    let a = clamp(r.first, 0, cur.high)
    let e = clamp(r.last, a, cur.high)
    secs.add MbSection(path: r.path, start: a, orig: cur[a .. e], note: r.note.replace("\n", " "))
  secs = mbMerge(secs)
  if secs.len == 0: return nil
  let keep = curBuf
  let b = openScratch(mbFreeTitle("Multibuffer: " & title), "", detectLang(secs[0].path, ""))
  b.readOnly = false
  mbRebuild(b, secs)
  mbLast = b.id
  if not focusIt: curBuf = keep
  b

proc saveMultibuffer(b: Buffer): bool =
  var secs = multiBufs[b.id]
  # the pieces, as edited: between the § headers
  var pieces: seq[seq[string]]
  var k = -1
  for l in b.lines:
    if k + 1 < secs.len and l == mbHeaderOf(b.lang, secs[k + 1]):
      inc k
      pieces.add @[]
    elif k >= 0: pieces[k].add l
    elif l.strip.len > 0:
      error("Text before the first § header — the multibuffer cannot be saved")
      return false
  if pieces.len != secs.len:
    error("A § header line was changed or removed — undo that (Ctrl+Z), then save")
    return false
  # a piece is written where its lines are now (lines added or removed above it in the file meanwhile move it);
  # nothing is written when a piece edited here had its own lines changed elsewhere too
  let now0 = mbFiles(secs)
  for i, sc in secs:
    let at = mbFind(now0[sc.path], sc.orig, sc.start)
    if at >= 0: secs[i].start = at
    elif pieces[i] != sc.orig:
      error(relPath(sc.path) & ":" & $(sc.start + 1) & " changed in its file too since the multibuffer was made — " &
            "copy your edit, then Multibuffer: refresh")
      return false
  var stale = false              # (a piece not edited here whose lines changed in the file: shown again as they are)
  for i, sc in secs:
    if pieces[i] == sc.orig and not mbMatchAt(now0[sc.path], sc.orig, sc.start): stale = true
  # a file that may not be changed — locked as a library (files.protectLibraries), read-only — is not written
  for i, sc in secs:
    if pieces[i] == sc.orig: continue
    let bi = bufIndexByPath(sc.path)
    if (bi >= 0 and bufs[bi].readOnly) or isLibraryFile(sc.path):
      error(relPath(sc.path) & " is read-only (" & (if isLibraryFile(sc.path): "a library's file — files.protectLibraries"
            else: "its tab is read-only") & ") — undo the edit of its piece (Ctrl+Z), then save")
      return false
  var files: seq[string]
  for sc in secs:
    if sc.path notin files: files.add sc.path
  var written = 0
  for path in files:
    # only the pieces edited here are written, the lowest first: the lines above them stay where they are
    var idx: seq[int]
    for i, sc in secs:
      if sc.path == path and pieces[i] != sc.orig: idx.add i
    if idx.len == 0: continue
    idx.sort(proc(x, y: int): int = cmp(secs[y].start, secs[x].start))
    inc written
    let bi = bufIndexByPath(path)
    var rf: tuple[lines: seq[string], nl, crlf: bool]
    var ls = if bi >= 0: bufs[bi].lines else: (rf = mbReadFile(path); rf.lines)
    # (the file's lines with each edited piece in place of what it was — a piece emptied takes its lines out, one
    # that was empty puts its lines in)
    for i in idx:
      let sc = secs[i]
      let a0 = clamp(sc.start, 0, ls.len)
      let e0 = clamp(sc.start + sc.orig.len, a0, ls.len)
      ls = ls[0 ..< a0] & pieces[i] & ls[e0 .. ^1]
    if bi >= 0:
      let fb = bufs[bi]
      let wasDirty = fb.dirty
      fb.setTextMinimal(mbTextOf(ls))          # (one undo step in the file's tab; the cursors stay on their code)
      if not wasDirty: discard fb.saveBuffer()
    else:
      let eol = if rf.crlf: "\r\n" else: "\n"
      try:
        writeFile(path, ls.join(eol) & (if rf.nl: eol else: ""))
        fileWritten(path)
      except IOError, OSError:
        multiBufs[b.id] = secs                 # (the files written before it: where their pieces are now)
        error("Could not write " & relPath(path))
        return false
    # the pieces of the file below an edited one move with the lines it gained or lost
    var moved = newSeq[int](secs.len)
    for i in idx:
      let d = pieces[i].len - secs[i].orig.len
      for j in 0 ..< secs.len:
        if j != i and secs[j].path == path and secs[j].start > secs[i].start: moved[j] += d
    for j in 0 ..< secs.len: secs[j].start += moved[j]
    for i in idx: secs[i].orig = pieces[i]
  if stale:
    let now = mbFiles(secs)
    for i in 0 ..< secs.len: secs[i] = mbAnchor(secs[i], now[secs[i].path])
    mbRebuild(b, secs)
  else:
    multiBufs[b.id] = secs
    # the headers show the new line numbers
    var text: seq[string]
    for i, sc in secs:
      text.add mbHeaderOf(b.lang, sc)
      text.add pieces[i]
    if text != b.lines: b.setTextMinimal(mbTextOf(text))
    b.savedSeq = b.topSeq()
    mbSig[b.id] = mbSignature(secs)
  info(if written > 0: "Saved changes to " & $written & " file(s)" else: "No changes to save")
  if written > 0: gcAfterSave(b)
  true

proc cmdMultibufferFromSearch() =
  var hits: seq[(string, int)]
  if panelKind == pkSearch:
    for pl in panelLines:
      if pl.path.len > 0 and pl.line >= 0: hits.add (pl.path, pl.line)
  if hits.len == 0:
    for h in searchHits: hits.add (h.path, h.line)
  if hits.len == 0:
    info("Search the project first (Alt+S), or find references (Alt+Q)")
    return
  openMultibuffer((if panelTitle.len > 0 and panelKind == pkSearch: panelTitle else: "search results"), hits)

proc mbHere(what: string): Buffer =
  ## the multibuffer in front — nil (and why) when it is not one, or it has edits not saved
  let b = buf()
  if b.id notin multiBufs:
    info("Not a multibuffer — Multibuffer: from search results, problems, TODOs, files…")
    return nil
  if b.dirty:
    info("Save the multibuffer first (Ctrl+S writes your edits to the files), then " & what)
    return nil
  b

proc mbRefresh(b: Buffer, quiet = false, read: Table[string, seq[string]] = initTable[string, seq[string]]()) =
  ## each piece as its file has it now: moved with the lines added or removed above it, its own lines as they are
  ## (`read`: the files' lines when the caller has them already)
  if b.dirty:
    if not quiet: info("Save the multibuffer first (Ctrl+S), then refresh it")
    return
  var secs: seq[MbSection]
  let all = multiBufs.getOrDefault(b.id)
  let files = if read.len > 0: read else: mbFiles(all)
  for sc in all:
    if files[sc.path].len > 0: secs.add mbAnchor(sc, files[sc.path])     # (a file that is gone: its pieces go)
  mbRebuild(b, mbMerge(secs))
  if not quiet: info("Multibuffer: every piece as its file has it now")

proc mbPump() =
  ## (the main loop, twice a second) a multibuffer without edits of its own follows its files: changed in their
  ## tabs, by a formatter, by git or another program
  if multiBufs.len == 0 or msSince(mbPumpAt) < 500: return
  mbPumpAt = getMonoTime()
  if buf().id in multiBufs: mbLast = buf().id
  var ids: seq[int]
  for id in multiBufs.keys: ids.add id
  for id in ids:
    let b = bufById(id)
    if b == nil:
      multiBufs.del id
      mbSig.del id
      continue
    if b.dirty or b.title == "Git: changes": continue      # (the changes view follows git itself)
    let sg = mbSignature(multiBufs[id])
    if id notin mbSig: mbSig[id] = sg
    elif sg != mbSig[id]:
      let before = multiBufs[id]
      let files = mbFiles(before)
      var same = true
      for sc in before:
        if not mbMatchAt(files[sc.path], sc.orig, sc.start): same = false
      if same: mbSig[id] = sg
      else: mbRefresh(b, true, files)

proc mbJump(d: int) =
  ## the next (1) or previous (-1) piece: the cursor on its first line
  let b = buf()
  if b.id notin multiBufs:
    info("Not a multibuffer")
    return
  let hs = b.mbHeaderLines()
  if hs.len == 0: return
  let (k, _) = b.mbPieceAt(b.primary.head.line)
  let t = clamp(k + d, 0, hs.high)
  if t == k and k >= 0:
    info(if d > 0: "The last piece" else: "The first piece")
    return
  let p = b.clampPos(Pos(line: min(hs[t] + 1, b.lines.high), col: 0))
  b.setSingle(p)
  b.centerOn(p)
  needRender = true

proc mbMore(up, down: int) =
  ## more lines of the file around the piece at the cursor (a piece it reaches becomes one with it)
  let b = mbHere("show more around it")
  if b == nil: return
  let (k, _) = b.mbPieceAt(b.primary.head.line)
  if k < 0: return
  var secs = multiBufs[b.id]
  let cur = fileLinesNow(secs[k].path)
  if cur.len == 0: return
  var sc = mbAnchor(secs[k], cur)
  let a = max(0, sc.start - up)
  let e = min(cur.high, sc.start + sc.orig.len - 1 + down)
  if a == sc.start and e == sc.start + sc.orig.len - 1:
    info("The whole of " & relPath(sc.path) & " that way is shown")
    return
  sc.start = a
  sc.orig = cur[a .. e]
  secs[k] = sc
  mbRebuild(b, mbMerge(secs))

proc mbRemovePiece() =
  ## the piece at the cursor out of the multibuffer (its file as it is)
  let b = mbHere("remove a piece")
  if b == nil: return
  let (k, _) = b.mbPieceAt(b.primary.head.line)
  if k < 0: return
  var secs = multiBufs[b.id]
  let gone = secs[k]
  secs.delete(k)
  mbRebuild(b, secs)
  info("Removed " & relPath(gone.path) & ":" & $(gone.start + 1) & " from the multibuffer" &
       (if secs.len == 0: " — nothing is left in it" else: ""))

proc mbHeaderAct(bid, hl, what: int): Action =
  ## a § header's buttons: more lines above (0), below (1), the piece out (2)
  result = proc() =
    let b = bufById(bid)
    let i = bufs.find(b)
    if b == nil or i < 0: return
    curBuf = i
    focus = fEditor
    b.setSingle(b.clampPos(Pos(line: min(hl + 1, b.lines.high), col: 0)))
    case what
    of 0: mbMore(5, 0)
    of 1: mbMore(0, 5)
    else: mbRemovePiece()

proc mbOpenSource() =
  ## the file behind the cursor, at that place (on a § header: the piece's first line)
  let b = buf()
  let (ok, path, p) = b.mbPlace(b.primary.head)
  if not ok:
    info("The cursor is not in a piece of a file")
    return
  let ob = openFile(path, p.line, p.col)
  if ob != nil: ob.centerOn(ob.clampPos(p))

proc mbDefinition(): bool =
  ## F12 in a multibuffer: the definition of the name at the cursor, looked up in its file
  let b = buf()
  if b.id notin multiBufs: return false
  let (ok, path, p) = b.mbPlace(b.primary.head)
  if not ok: return false
  let (k, hl) = b.mbPieceAt(b.primary.head.line)
  if k >= 0 and hl == b.primary.head.line:
    mbOpenSource()
    return true
  let ob = openFile(path, p.line, p.col)
  if ob == nil: return true
  if ob.lines.len > p.line and b.lines[b.primary.head.line] == ob.lines[p.line]:
    ob.setSingle(ob.clampPos(p))
    cmdDefinition()                         # (the file has the same line there: its definition)
  else: info("This line was edited here: save the multibuffer first, then go to its definition")
  true

proc mbAddRange(path: string, a0, e0: int): bool =
  ## lines a .. e of a file added to the multibuffer in use (a new one, "collected", when there is none); false when
  ## the file has no lines to add
  var target = bufById(mbLast)
  if target != nil and (target.id notin multiBufs or target.dirty or target.title == "Git: changes"): target = nil
  let cur = fileLinesNow(path)
  if cur.len == 0: return false
  let a = clamp(a0, 0, cur.high)
  let e = clamp(e0, a, cur.high)
  let sc = MbSection(path: path, start: a, orig: cur[a .. e])
  if target == nil:
    let keep = curBuf
    target = openScratch(mbFreeTitle("Multibuffer: collected"), "", detectLang(path, ""))
    target.readOnly = false
    multiBufs[target.id] = @[]
    mbLast = target.id
    curBuf = keep
  mbRebuild(target, mbMerge(multiBufs[target.id] & @[sc]))
  let n = multiBufs[target.id].len
  info("Added to “" & target.title & "” (" & $n & (if n == 1: " piece" else: " pieces") &
       ") — Multibuffer: show the one in use")
  true

proc cmdMbAddSelection() =
  ## the selected lines (or the line) of this file added to the multibuffer in use
  let b = buf()
  if b.id in multiBufs:
    info("This is a multibuffer — add pieces from a file")
    return
  if b.path.len == 0:
    info("Save the file first: a multibuffer shows pieces of files")
    return
  for c in b.cursors:
    let (s, e) = c.range
    let last = if e.line > s.line and e.col == 0: e.line - 1 else: e.line
    discard mbAddRange(b.path, s.line, last)

proc cmdMbShow() =
  let b = bufById(mbLast)
  if b == nil or b.id notin multiBufs:
    info("No multibuffer open — Multibuffer: add the selection makes one")
    return
  let i = bufs.find(b)
  if i >= 0:
    curBuf = i
    focus = fEditor
    needRender = true

proc cmdMbFromFiles() =
  ## the open files, whole, in one multibuffer
  var hits: seq[(string, int)]
  for x in bufs:
    if x.path.len > 0 and x.id notin multiBufs and not x.largeOn and x.lines.len <= 5000 and not x.readOnly:
      for l in 0 ..< x.lines.len: hits.add (x.path, l)
  if hits.len == 0:
    info("No files open")
    return
  openMultibuffer("open files", hits, 0)

proc cmdMbFromTodos() =
  ## every TODO, FIXME and HACK of the project with a line around it
  var hits: seq[(string, int)]
  var seen: HashSet[string]
  for b in bufs:
    if b.path.len > 0 and b.id in todoBufCache:
      seen.incl b.path
      for t in todoBufCache[b.id][1]: hits.add (t.path, t.line)
  for p, items in todoFiles:
    if p notin seen:
      for t in items: hits.add (t.path, t.line)
  if hits.len == 0:
    info("No TODOs found (the TODOs dock scans the project)")
    return
  openMultibuffer("TODOs", hits, 1)

proc showReferences(title: string, hits: seq[(string, int, int)]) =
  panelKind = pkSearch
  panelLines.setLen(0)
  var last = ""
  var files = 0
  # each file is read once, not once per hit (60,000 uses of `int` across the standard library)
  var read = initTable[string, seq[string]]()
  var readBytes = 0
  var rowOf = initTable[(string, int), int]()     # one row per line: a second use on it is marked there too
  for (path, l, c) in hits:
    var rawText = ""
    let bi = bufIndexByPath(path)
    if bi >= 0 and l < bufs[bi].lines.len: rawText = bufs[bi].lines[l]
    else:
      if path notin read:
        if readBytes > 64_000_000: read.clear()
        var ls: seq[string]
        try:
          if getFileSize(path) <= 32_000_000:
            let all = readFile(path)
            readBytes += all.len
            ls = all.splitLines()
        except CatchableError: discard
        read[path] = ls
      read.withValue(path, ls):        # no copy of the file's lines per hit
        if l >= 0 and l < ls[].len: rawText = ls[][l]
    # the use: the word (or operator) written at the column
    let lead = rawText.len - rawText.strip(trailing = false).len
    var e = c
    if c >= 0 and c < rawText.len and isWordByte(rawText[c]):
      while e < rawText.len and isWordByte(rawText[e]): inc e
    elif c >= 0 and c < rawText.len and rawText[c] == '`':
      let q = rawText.find('`', c + 1)
      e = (if q > c: q + 1 else: c + 1)
    else:
      while e < rawText.len and rawText[e] in {'+', '-', '*', '/', '<', '>', '=', '!', '&', '$', '%', '@', '~',
                                                  '^', '|', '.', ':', '?'}: inc e
    let text = rawText.strip
    let pre = align($(l + 1), 5) & "  "
    let mark = (pre.len + c - lead, e - c)
    let okMark = c >= lead and e > c and c - lead + (e - c) <= text.len
    let key = (path, l)
    if key in rowOf:
      let r = rowOf[key]
      if okMark and mark notin panelLines[r].marks: panelLines[r].marks.add mark
      continue
    if path != last:
      panelLines.add PanelLine(text: relPath(path), sev: 5, line: -1)
      last = path
      inc files
    rowOf[key] = panelLines.len
    panelLines.add PanelLine(text: pre & text, path: path, line: l, col: c,
                             marks: (if okMark: @[mark] else: @[]))
  panelTitle = title & " · " & $hits.len
  panelOpen = true
  panelFollow = false
  panelScroll = 0
  panelSel = if panelLines.len > 1: 1 else: 0
  focus = if hits.len > 0: fPanel else: fEditor
  if hits.len == 0: info("No references found")

proc applyRenameHits(hits: seq[(string, int, int)], oldName, newName: string) =
  ## rename at exact positions (from nimsuggest `use`), grouped per file, bottom-up
  var byFile = initTable[string, seq[(int, int)]]()
  for (p, l, c) in hits: byFile.mgetOrPut(p, @[]).add (l, c)
  var n = 0
  for path, locs0 in byFile:
    let b = loadBuffer(path)
    if b == nil or b.readOnly: continue
    var locs = locs0
    locs.sort(proc(x, y: (int, int)): int = cmp(y[0] * 1_000_000 + y[1], x[0] * 1_000_000 + x[1]))
    b.beginEdit()
    var last = (-1, -1)
    for (l, c) in locs:
      if (l, c) == last or l >= b.lines.len: continue
      last = (l, c)
      let s = b.lines[l]
      var col = c
      var e = col + oldName.len
      if not s.startsAt(oldName, col):
        # Nim names are style-insensitive: foo_bar and fooBar are the same identifier
        var k = col
        while k < s.len and isWordByte(s[k]): inc k
        if k > col and s[col ..< k].replace("_", "").toLowerAscii == oldName.replace("_", "").toLowerAscii and
           s[col] == oldName[0]:
          e = k
        else:
          let j = s.find(oldName)
          if j < 0: continue
          col = j
          e = j + oldName.len
      discard b.replaceText(Pos(line: l, col: col), Pos(line: l, col: e), newName)
      inc n
    b.endEdit()
    b.normalize()
  info("Renamed " & $n & " occurrence(s) in " & $byFile.len & " file(s) — Ctrl+S saves")
