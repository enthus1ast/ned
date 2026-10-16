# ── C in {.emit.} through clangd: a hidden C document per Nim file, with the emitted C on the very lines and
#    columns it has in the .nim file (everything else blank), so positions need no mapping either way ──

var
  emitShadow: Table[int, Buffer]          # Nim buffer id → its hidden C document
  shadowChange: Table[int, int]           # Nim buffer id → the change the document mirrors
  shadowFlags: Table[string, string]      # hidden document → the compile flags clangd was given
  shadowSrv: Table[int, LspServer]        # Nim buffer id → the server it is open in
  clangdSeen = -1                         # clangd installed? (-1: not looked yet)

proc emitOneLiners(ls: seq[string], skip: seq[string]): seq[(int, int, string)] =
  ## {.emit: "…".} and {.emit: ["…", x, "…"].} on one line: (line, column, C text); the Nim names between
  ## the pieces become a 0 of the same width. Strings with escapes are left out (their columns would move).
  for l, t in ls:
    if l < skip.len and skip[l].len > 0: continue
    var k = t.find("emit")
    if k < 0: continue
    k += 4
    while k < t.len and t[k] in {' ', ':', '('}: inc k
    if k >= t.len: continue
    proc strAt(i: int): (int, int) =
      ## a one-line string literal at i: (text start, text end) — (-1, -1) if not one, or with escapes
      var a = i
      if a < t.len and t[a] == 'r': inc a
      if a >= t.len or t[a] != '"' or t.continuesWith("\"\"\"", a): return (-1, -1)
      let e = t.find('"', a + 1)
      if e < 0 or '\\' in t[a + 1 ..< e]: return (-1, -1)
      (a + 1, e)
    if t[k] == '[':
      var pieces: seq[(int, string)]
      var i = k + 1
      var ok = true
      while i < t.len and t[i] != ']':
        if t[i] in {' ', ','}:
          inc i
          continue
        let (a, e) = strAt(i)
        if a >= 0:
          pieces.add (a, t[a ..< e])
          i = e + 1
          continue
        if t.continuesWith("\"\"\"", i):         # a triple-quoted piece: one line only
          let e = t.find("\"\"\"", i + 3)
          if e < 0:
            ok = false
            break
          pieces.add (i + 3, t[i + 3 ..< e])
          i = e + 3
          continue
        if t[i] == '"':                        # a string with escapes
          ok = false
          break
        # a Nim expression: up to the next , or ] at this depth
        var j = i
        var d = 0
        while j < t.len:
          if t[j] in {'(', '['}: inc d
          elif t[j] in {')', ']'}:
            if d == 0: break
            dec d
          elif t[j] == ',' and d == 0: break
          inc j
        pieces.add (i, "0" & spaces(max(0, j - i - 1)))
        i = j
      if ok:
        for (c, x) in pieces: result.add (l, c, x)
    else:
      let (a, e) = strAt(k)
      if a >= 0: result.add (l, a, t[a ..< e])

proc shadowLines(ls: seq[string]): seq[string] =
  result = newSeq[string](ls.len)
  for (l, c, body) in emitBlocks(ls):
    for k, t in body:
      if l + k >= result.len: break
      var x = if k == 0: spaces(c) & t else: t
      # `nimName` (the old way to name a Nim symbol in an emit): a placeholder of the same width
      var i = x.find('`')
      while i >= 0:
        let j = x.find('`', i + 1)
        if j < 0: break
        x[i] = '0'
        for q in i + 1 .. j: x[q] = ' '
        i = x.find('`', j + 1)
      result[l + k] = x
  for (l, c, x) in emitOneLiners(ls, result):
    var line = result[l]
    if line.len < c + x.len: line.add spaces(c + x.len - line.len)
    for q in 0 ..< x.len: line[c + q] = x[q]
    result[l] = line

proc emitLangId(b: Buffer): string =
  ## c or cpp (the backend's), "" when the file emits no C
  for (l, c, body) in emitBlocks(b.lines):
    for k, t in body:
      if t.strip.len > 0:
        let lg = b.langAt(Pos(line: l + k, col: (if k == 0: c else: 0) + t.len - t.strip(leading = true).len))
        return (if lg != nil and lg.id in ["c", "cpp"]: lg.id else: "")
  var any = false
  for l in b.lines:
    if "emit" in l:
      any = true
      break
  if not any: return ""
  for (l, c, x) in emitOneLiners(b.lines, @[]):         # only one-line emits
    if x.strip.len > 0 and x[0] != '0':
      let lg = b.langAt(Pos(line: l, col: c))
      return (if lg != nil and lg.id in ["c", "cpp"]: lg.id else: "")
  ""

proc emitFlags(b: Buffer, langId, shadowPath: string): seq[string] =
  ## how clangd compiles the emitted C: like Nim's generated C (nimbase.h first, NIM_INTBITS), with the
  ## file's include folders and the headers its header: pragmas bring in
  result = @[(if langId == "cpp": "clang++" else: "clang"), (if langId == "cpp": "-xc++" else: "-xc"),
             (if langId == "cpp": "-std=gnu++17" else: "-std=gnu11"), "-w", "-DNIM_INTBITS=" & $(sizeof(int) * 8)]
  let sys = cSystemIncludeDirs()
  for d in cIncludeDirs(b.path, b.lines):
    if d notin sys: result.add "-I" & d
  for d in cDefines(b.path, b.lines): result.add d
  result.add ["-include", "nimbase.h"]
  var hs: seq[string]
  for l in b.lines:
    let k = l.find("header:")
    if k < 0: continue
    let q1 = l.find('"', k)
    let q2 = if q1 >= 0: l.find('"', q1 + 1) else: -1
    if q2 > q1 + 1:
      let h = l[q1 + 1 ..< q2].strip(chars = {'<', '>', ' '})
      if h.len > 0 and h notin hs: hs.add h
  for h in hs: result.add ["-include", h]
  result.add shadowPath

proc emitLsp(b: Buffer): (LspServer, Buffer) =
  ## clangd for the C this Nim file emits — its hidden document up to date and its flags sent; (nil, nil)
  ## when there is none (clangd not installed or not ready yet, nim.emitClangd off, no C emitted)
  if not cfgEmitClangd or b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or b.largeOn or
     b.lines.len > 40000:
    return
  if clangdSeen < 0: clangdSeen = (if findExe("clangd").len > 0: 1 else: 0)
  if clangdSeen == 0: return
  var sh = emitShadow.getOrDefault(b.id)
  if sh == nil or shadowChange.getOrDefault(b.id, -1) != b.changeId:
    let lid = emitLangId(b)
    if lid.len == 0:
      if sh != nil: emitClose(b)
      shadowChange[b.id] = b.changeId                   # nothing emitted at this version: no need to look again
      return
    if sh == nil or sh.lang == nil or sh.lang.id != lid:
      if sh != nil: shadowNim.del sh.path
      sh = newBuffer()
      sh.lang = embedLang(lid)
      if sh.lang == nil: return
      sh.path = privDir() / "emit" / fnv(b.path) /
                (splitFile(b.path).name & (if lid == "cpp": ".cpp" else: ".c"))
      try: createDir(parentDir(sh.path))
      except CatchableError: return
      emitShadow[b.id] = sh
      shadowNim[sh.path] = b.path
      shadowSrv.del b.id
    sh.lines = shadowLines(b.lines)
    if sh.lines.len == 0: sh.lines = @[""]
    sh.lspDirty = true
    shadowChange[b.id] = b.changeId
  let s = lspFor(sh)
  if s == nil or not s.ready or s.dead: return
  if shadowSrv.getOrDefault(b.id) != s:          # a new (or restarted) clangd: open it there
    sh.lspOpen = false
    shadowSrv[b.id] = s
    shadowFlags.del sh.path
  let flags = emitFlags(b, sh.lang.id, sh.path)
  let key = flags.join("\x1f")
  if shadowFlags.getOrDefault(sh.path) != key:
    s.lspNotify("workspace/didChangeConfiguration", %*{"settings": {"compilationDatabaseChanges": {
      sh.path: {"workingDirectory": parentDir(b.path), "compilationCommand": flags}}}})
    shadowFlags[sh.path] = key
  lspSync(sh)
  (s, sh)

proc emitClose(b: Buffer) =
  ## the Nim file closed: its hidden document too
  if b == nil or b.id notin emitShadow: return
  let sh = emitShadow[b.id]
  let s = shadowSrv.getOrDefault(b.id)
  if s != nil and not s.dead and sh.lspOpen: s.lspNotify("textDocument/didClose", %*{"textDocument": {"uri": uriFromPath(sh.path)}})
  shadowNim.del sh.path
  shadowFlags.del sh.path
  emitShadow.del b.id
  shadowChange.del b.id
  shadowSrv.del b.id
  if sh.path in diagsByShadow:
    diagsByShadow.del sh.path
    mergeShadowDiags(b.path)

var emitPumpAt: Table[int, MonoTime]

proc emitPump(b: Buffer) =
  ## after a pause in typing: clangd's copy of the current Nim file's emitted C brought up to date (its
  ## problems then come back while you type)
  if not cfgEmitClangd and emitShadow.len > 0:      # turned off: the hidden documents and their problems go
    var open: seq[Buffer]
    for id in emitShadow.keys:
      let x = bufById(id)
      if x != nil: open.add x
    for x in open: emitClose(x)
    emitShadow.clear()
    diagsEmit.clear()
    needRender = true
  if not cfgEmitClangd or clangdSeen == 0 or b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0:
    return
  if msSince(b.lspChangeAt) < 400 or msSince(emitPumpAt.getOrDefault(b.id)) < 300: return
  let sh = emitShadow.getOrDefault(b.id)
  if shadowChange.getOrDefault(b.id, -1) == b.changeId and (sh == nil or (sh.lspOpen and not sh.lspDirty)): return
  emitPumpAt[b.id] = getMonoTime()
  discard emitLsp(b)

proc realPathOf(path: string): string =
  ## a hidden emit document's path → its Nim file (definitions found by clangd open the .nim)
  shadowNim.getOrDefault(path, path)

proc emitLspComplete(b: Buffer, p: Pos): bool =
  ## clangd's completion in emitted C (after a letter, or . -> ::)
  let (s, sh) = emitLsp(b)
  if s == nil or s.caps == nil or s.caps{"completionProvider"} == nil: return false
  let line = b.lines[p.line]
  let prev = if p.col > 0: line[p.col - 1] else: ' '
  var trig = ""
  if prev == '.' or (prev == '>' and p.col >= 2 and line[p.col - 2] == '-') or
     (prev == ':' and p.col >= 2 and line[p.col - 2] == ':'):
    trig = $prev
  elif not isWordByte(prev): return false
  let ctx = if trig.len > 0: %*{"triggerKind": 2, "triggerCharacter": trig} else: %*{"triggerKind": 1}
  discard s.lspRequest("textDocument/completion", %*{"textDocument": {"uri": uriFromPath(sh.path)},
    "position": s.lspPos(sh, p), "context": ctx},
    LspReq(kind: lrCompletion, bufId: b.id, pos: p, version: sh.lspVersion, extra: "c"))
  true

proc emitLspHover(b: Buffer, p: Pos, auto: bool): bool =
  if not emitIsC(b, p): return false
  let (s, sh) = emitLsp(b)
  if s == nil or s.caps == nil or s.caps{"hoverProvider"} == nil: return false
  discard s.lspRequest("textDocument/hover", %*{"textDocument": {"uri": uriFromPath(sh.path)},
    "position": s.lspPos(sh, p)}, LspReq(kind: lrHover, bufId: b.id, pos: p,
    extra: (if auto: "auto" else: ""), extra2: "emit"))
  true

proc emitLspDefinition(b: Buffer, p: Pos): bool =
  let (s, sh) = emitLsp(b)
  if s == nil or s.caps == nil or s.caps{"definitionProvider"} == nil: return false
  discard s.lspRequest("textDocument/definition", %*{"textDocument": {"uri": uriFromPath(sh.path)},
    "position": s.lspPos(sh, p)}, LspReq(kind: lrDefinition, bufId: b.id, pos: p))
  true

proc emitSignature(b: Buffer, p: Pos): bool =
  ## ( or , typed in emitted C: clangd's parameter hints (or nothing: not Nim's)
  if not emitIsC(b, p): return false
  let (s, sh) = emitLsp(b)
  if s != nil and s.caps != nil and s.caps{"signatureHelpProvider"} != nil:
    discard s.lspRequest("textDocument/signatureHelp", %*{"textDocument": {"uri": uriFromPath(sh.path)},
      "position": s.lspPos(sh, p)}, LspReq(kind: lrSignature, bufId: b.id, pos: p))
  true

proc emitNimNote(b: Buffer, w: string): string =
  for nd in nimFfiDecls(b.lines):
    if nd.cname == w and nd.kind in ["proc", "func"]:
      return "\n\nImported into Nim as `" & nd.name & "` (line " & $(nd.line + 1) & ")"

proc mergeShadowDiags(path: string) =
  ## a Nim file's problems from all its hidden documents (C in emits, HTML, CSS, SQL, JSON in strings)
  var all: seq[Diag]
  for sp, ds in diagsByShadow:
    if shadowNim.getOrDefault(sp) == path:
      for d in ds: all.add d
  if all.len > 0: diagsEmit[path] = all
  elif path in diagsEmit: diagsEmit.del path
  needRender = true

proc emitShadowDiags(s: LspServer, shadowPath: string, params: JsonNode) =
  ## a hidden document's problems → the Nim file's, on the same lines. For C: not shown, a name clangd does
  ## not know that the Nim code declares (an exportc proc), and a `name` placeholder's line
  let path = shadowNim.getOrDefault(shadowPath)
  if path.len == 0: return
  let bi = bufIndexByPath(path)
  if bi < 0:
    diagsByShadow.del shadowPath
    mergeShadowDiags(path)
    return
  let b = bufs[bi]
  let isC = shadowPath.endsWith(".c") or shadowPath.endsWith(".cpp")
  let prefix = if isC: "C: " else: shadowLangName.getOrDefault(shadowPath, "") & ": "
  var nimWords: HashSet[string]
  if isC:
    let sl = shadowLines(b.lines)
    for i, l in b.lines:
      if i < sl.len and sl[i].len > 0: continue
      var k = 0
      while k < l.len:
        if l[k] in IdentStartChars:
          var e = k
          while e < l.len and l[e] in IdentChars: inc e
          nimWords.incl l[k ..< e]
          k = e
        else: inc k
  var ds: seq[Diag]
  for d in jitems(params{"diagnostics"}):
    let a = fromLspPos(s, b, d{"range", "start"})
    let e = fromLspPos(s, b, d{"range", "end"})
    if a.line >= b.lines.len or (isC and '`' in b.lines[a.line]): continue
    let msg = d{"message"}.getStr
    if isC:
      let q1 = msg.find('\'')
      let q2 = if q1 >= 0: msg.find('\'', q1 + 1) else: -1
      if q2 > q1 + 1 and ("undeclared" in msg or "Unknown type name" in msg or "unknown type name" in msg) and
         msg[q1 + 1 ..< q2] in nimWords:
        continue
    let sev = d{"severity"}.getInt(1)
    if not isC and sev > 2: continue                 # hints and information from the string servers: no
    let (m, fx) = lspDiagMsg(d)
    ds.add Diag(line: a.line, col: a.col, eline: e.line, ecol: e.col, sev: (if sev == 0: 1 else: sev),
                msg: prefix & m, raw: msg, fixes: fx, src: s.name, code: d{"code"})
  if ds.len > 0: diagsByShadow[shadowPath] = ds
  elif shadowPath in diagsByShadow: diagsByShadow.del shadowPath
  mergeShadowDiags(path)
