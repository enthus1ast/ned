# ── C files with ned's own engine (c.engine): completion — struct members after `.` and `->` too —, hover with the
#    comment that documents a declaration, F12 through #includes, references and rename, the outline, signature
#    help, the C compiler's errors while you type, and a missing #include added. No clangd needed. C++ files
#    (.cpp .cc .hpp …, and a .h that is C++) too: classes, methods, namespaces, templates read past ──

proc cEngineOn(b: Buffer): bool =
  ## does ned's own C engine answer for this file? (c.engine: auto — when clangd is not installed —, builtin, both)
  b != nil and b.lang != nil and b.lang.id in ["c", "cpp"] and b.path.len > 0 and not b.largeOn and
    b.lines.len < 200_000 and (cfgCEngine in ["builtin", "both"] or (cfgCEngine == "auto" and not haveExe("clangd")))

var cxCppSeen: Table[int, (int, bool)]       # buffer id → (the change it was looked at, is it C++)

proc cxIsCppBuf(b: Buffer): bool =
  ## is this buffer C++: a C++ file, or a .h with classes, namespaces or templates in it
  if b.lang != nil and b.lang.id == "cpp": return true
  if not b.path.endsWith(".h"): return false
  if b.id in cxCppSeen and cxCppSeen[b.id][0] == b.changeId: return cxCppSeen[b.id][1]
  result = cxLooksCpp(b.allText)
  cxCppSeen[b.id] = (b.changeId, result)

var
  cxDirsKey = ""
  cxCompileDefs: seq[string]          # compile_commands.json's -D and -U: the compiler's check of the unsaved text

proc cxSetDirs(b: Buffer) =
  ## where #include looks: the file's folder, the project's include folders (and compile_commands.json's -I),
  ## then the C compiler's own
  let key = rootDir & "|" & parentDir(b.path)
  if key == cxDirsKey and cxDirs.len > 0: return
  cxDirsKey = key
  var ds: seq[string]
  var defs: seq[string]
  proc add(d: string) =
    if d.len > 0 and dirExists(d) and d notin ds: ds.add d
  add parentDir(b.path)
  if rootDir.len > 0:
    for sub in ["include", "inc", "src", "lib", "."]: add rootDir / sub
    let cc = rootDir / "compile_commands.json"
    if fileExists(cc):
      try:
        let j = parseJson(readFile(cc))
        for e in j:
          let dir = e{"directory"}.getStr
          var args: seq[string]
          if e{"arguments"} != nil:
            for a in e["arguments"]: args.add a.getStr
          else: args = e{"command"}.getStr.splitWhitespace
          var k = 0
          while k < args.len:
            let a = args[k]
            if a in ["-I", "-isystem", "-iquote"] and k + 1 < args.len:
              add(if args[k + 1].isAbsolute: args[k + 1] else: dir / args[k + 1])
              inc k
            elif a.startsWith("-I") and a.len > 2: add(if a[2 .. ^1].isAbsolute: a[2 .. ^1] else: dir / a[2 .. ^1])
            elif (a.startsWith("-D") or a.startsWith("-U")) and a.len > 2 and defs.len < 200:
              let nm = a[2 .. ^1].split('=')[0]
              var dup = false
              for x in defs:
                if x[2 .. ^1].split('=')[0] == nm: dup = true
              if not dup: defs.add a               # (the first file's, when files differ)
            inc k
          if ds.len > 40: break
      except CatchableError: discard
  for v in [getEnv("C_INCLUDE_PATH"), getEnv("CPATH")]:
    for d in v.split(':'): add d
  for d in cSystemIncludeDirs(): add d
  cxDirs = ds
  cxSysDirs = cSystemIncludeDirs()
  cxCompileDefs = defs
  if not cxPredefSet:
    # the compiler's predefined macros: the #if branches its target decides (__x86_64__, __linux__, _WIN32 …)
    cxPredefSet = true
    for cc in ["cc", "clang", "gcc"]:
      if not haveExe(cc): continue
      let (ok, o, _) = runFilter(cc & " -dM -E -x c -", "", getCurrentDir(), 5000)
      if not ok: continue
      for l in o.splitLines:
        let p = l.splitWhitespace(2)
        if p.len >= 2 and p[0] == "#define": cxPredef[p[1]] = (if p.len > 2: p[2] else: "")
      break

var cxBufParse: Table[int, (int, float, CxFile)]      # buffer id → (the change it was read at, when, its index)

proc cxFileOf(b: Buffer): CxFile =
  ## this buffer's index (its unsaved text). A very long file (reading it takes a tenth of a second or more) is read
  ## again at most every two seconds while it is typed in: in between, its declarations as they were a moment
  ## ago, with the text as it is now
  cxSetDirs(b)
  let now = epochTime()
  if b.lines.len > 20_000 and b.id in cxBufParse:
    let (cid, at, f) = cxBufParse[b.id]
    if f != nil and (cid == b.changeId or now - at < 2.0):
      if cid != b.changeId: f.lines = b.lines
      return f
  result = cxLoad(b.path, b.allText & "\n", "buf:" & $b.id & ":" & $b.changeId, cpp = cxIsCppBuf(b))
  if b.lines.len > 20_000: cxBufParse[b.id] = (b.changeId, now, result)
  else: cxBufParse.del b.id

proc cEngComplete(b: Buffer, p: Pos, manual: bool): bool =
  if not cEngineOn(b): return false
  var res: (seq[CxItem], bool, string)
  try: res = cxComplete(cxFileOf(b), p.line, p.col, cSystemIncludeDirs())
  except CatchableError as e:
    internalError("C engine", e)
    return false
  let (items, member, typ) = res
  if member and items.len == 0:
    if manual: info(if typ.len > 0: "No members known for " & typ else: "The type there is not known")
    return true
  let fence = if cxIsCppBuf(b): "```cpp\n" else: "```c\n"
  var out0: seq[CompItem]
  for it in items:
    out0.add CompItem(label: it.label, insert: it.label, detail: it.detail, kind: cxKindIcon(it.kind),
                      filter: it.label, sortText: $it.rank & it.label, rank: it.rank,
                      doc: (if it.detail.len > 0: fence & it.detail & "\n```\n" else: "") & it.doc, docMade: true)
  if out0.len == 0: return false
  compLine = p.line
  compStartCol = b.wordStart(p)
  compManual = manual
  compNx.setLen(0)
  compItems = out0
  compFromLsp = true
  refilterComp()
  true

proc cEngHover(b: Buffer, p: Pos): string =
  if not cEngineOn(b): return ""
  try: cxHover(cxFileOf(b), p.line, p.col)
  except CatchableError as e:
    internalError("C engine", e)
    ""

proc cEngDefinition(b: Buffer, p: Pos): bool =
  ## F12: the declaration (a function's body first), through the #includes
  if not cEngineOn(b): return false
  var ts: seq[(CxFile, CxSym)]
  try: ts = cxTargets(cxFileOf(b), p.line, p.col, jump = true)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  let cpp = cxIsCppBuf(b)
  proc projectC(): seq[string] =
    if rootDir.len > 0:
      for f in projectFiles():
        if (f.endsWith(".c") or (cpp and cxIsCppPath(f) and not f.splitFile.ext.startsWith(".h"))) and f != b.path:
          result.add(if f.isAbsolute: f else: rootDir / f)
  if ts.len == 0:
    # declared in no header this file includes: a function or global defined in the project's other .c files
    let (a, e) = cxWordAt(b.lines[p.line], p.col)
    if a >= e: return false
    let w = b.lines[p.line][a ..< e]
    if w in CxKeywords or (cpp and w in CxxKeywords): return false
    let cs = projectC()
    for kind in (if cpp: @[cxFunc, cxVar, cxClass, cxStruct] else: @[cxFunc, cxVar, cxStruct]):
      let (h, k) = cxBodyIn(cs, w, kind)
      if h != nil:
        ts.add (h, h.syms[k])
        break
    if ts.len == 0: return false
  var (g, s) = ts[0]
  # on a definition's own name: its prototype (and from there back); a prototype: the body, in another .c file of
  # the project when it is not in this one's
  let onDef = ts[^1][1].isDef and ts[^1][0].path == b.path and ts[^1][1].line == p.line
  # (a system header's declaration stays: a body the project has for it is a fallback, compiled out where the
  # system has its own)
  if s.kind in {cxFunc, cxStruct, cxUnion, cxVar, cxClass, cxMethod} and not s.isDef and not onDef and
     rootDir.len > 0 and (g.path == b.path or g.path.startsWith(rootDir & "/")):
    # (C++: a method's body in a .cpp of the project — of its class; a namespace's function as `int ns::f() { … }`)
    var (h, k) = cxBodyIn(projectC(), s.name, s.kind, owner = (if s.kind == cxMethod: s.owner else: ""))
    if h == nil and cpp and s.kind == cxFunc and s.scope.len > 0:
      (h, k) = cxBodyIn(projectC(), s.name, cxMethod, owner = s.scope)
    if h != nil: (g, s) = (h, h.syms[k])
  pushJump()
  let path = if g.path == b.path: b.path else: g.path
  let nb = if path == b.path: b else: openFile(path)
  if nb != nil:
    let at = nb.clampPos(Pos(line: s.line, col: s.col))
    nb.cursors = @[cur(at)]
    nb.centerOn(at)
  info(s.text)
  true

proc cEngReferenceHits(b: Buffer, p: Pos): (seq[(string, int, int)], string) =
  ## where the name at p is used: a local in its function, anything else in the project's C files (and the
  ## open ones); second result: why there are none
  let f = cxFileOf(b)
  let ts = cxTargets(f, p.line, p.col)
  let (a, e) = cxWordAt(b.lines[p.line], p.col)
  if a >= e: return (@[], "No symbol under cursor")
  let w = b.lines[p.line][a ..< e]
  let cpp = f.cpp
  if w in CxKeywords: return (@[], w & " is a C keyword")
  if cpp and w in CxxKeywords: return (@[], w & " is a C++ keyword")
  if ts.len > 0 and ts[0][1].kind in {cxLocal, cxParam, cxLabel}:
    let s = ts[0][1]
    var lo = s.scopeA
    if s.kind == cxParam:
      for x in f.syms:
        if x.kind == cxFunc and x.name == s.owner and x.isDef and
           (not cpp or (x.line <= s.line and x.endLine >= s.line)): lo = x.line
        elif cpp and x.kind == cxMethod and x.name == s.owner and x.isDef and x.line <= s.line and x.endLine >= s.line:
          lo = x.line
    for (l, c) in cxOccurrences(b.lines, w, lo, s.scopeB): result[0].add (b.path, l, c)
    return
  if ts.len > 0 and not ts[0][0].path.startsWith(rootDir & "/") and ts[0][0].path != b.path and rootDir.len > 0:
    discard               # (declared outside the project: its uses inside it are still listed)
  var seen: HashSet[string]
  for x in bufs:
    if x.path.len == 0 or x.lang == nil or x.lang.id notin ["c", "cpp"]: continue
    seen.incl x.path
    for (l, c) in cxOccurrences(x.lines, w): result[0].add (x.path, l, c)
  if rootDir.len > 0:
    var n = 0
    for f2 in projectFiles():
      if not (f2.endsWith(".c") or f2.endsWith(".h") or (cpp and cxIsCppPath(f2))): continue
      let full = if f2.isAbsolute: f2 else: rootDir / f2
      if full in seen: continue
      inc n
      if n > 3000: break
      var ls: seq[string]
      try:
        let t = readFile(full)
        if w notin t: continue
        ls = t.splitLines
      except CatchableError: continue
      for (l, c) in cxOccurrences(ls, w): result[0].add (full, l, c)

proc cEngReferences(b: Buffer, p: Pos): bool =
  if not cEngineOn(b): return false
  try:
    let (hits, why) = cEngReferenceHits(b, p)
    if hits.len == 0:
      info(if why.len > 0: why else: "No references")
      return true
    showReferences("REFERENCES " & b.wordAt(p), hits)
  except CatchableError as e: internalError("C engine", e)
  true

proc cEngRename(b: Buffer, p: Pos, newName: string): bool =
  ## every use renamed (with a preview): a local in its function, anything else across the project's C files
  if not cEngineOn(b): return false
  let nn = newName.strip
  if nn.len == 0 or nn[0] notin IdentStartChars or not nn.allCharsInSet(IdentChars):
    warn("'" & nn & "' is not a C identifier")
    return true
  if nn in CxKeywords or (cxIsCppBuf(b) and nn in CxxKeywords):
    warn("'" & nn & "' is a " & (if nn in CxKeywords: "C" else: "C++") & " keyword")
    return true
  try:
    let f = cxFileOf(b)
    let ts = cxTargets(f, p.line, p.col)
    if ts.len > 0 and ts[0][1].kind notin {cxLocal, cxParam, cxLabel} and
       not (ts[0][0].path == b.path or (rootDir.len > 0 and ts[0][0].path.startsWith(rootDir & "/"))):
      warn("'" & b.wordAt(p) & "' is declared in " & ts[0][0].path & " — outside this project, so it is not renamed")
      return true
    let (hits, why) = cEngReferenceHits(b, p)
    if hits.len == 0: info(if why.len > 0: why else: "Nothing to rename")
    else: previewRenameHits(hits, b.wordAt(p), nn)
  except CatchableError as e: internalError("C engine", e)
  true

proc cEngSignature(b: Buffer, p: Pos): bool =
  ## signature help in a call: the function's parameters, the one being typed marked
  if not cEngineOn(b): return false
  var s: CxSym
  var active = 0
  try: (s, active) = cxSignature(cxFileOf(b), p.line, p.col)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if s.name.len == 0: return false
  var lbl = (if s.kind == cxMacro: "#define " elif s.typ.len > 0: s.typ & " " else: "") & s.name & "("
  var spans: seq[(int, int)]
  for i, prm in s.params:
    if i > 0: lbl.add ", "
    let a = lbl.len
    lbl.add (prm.typ & (if prm.typ.len > 0 and prm.name.len > 0: " " else: "") & prm.name).replace("* ", "*")
    spans.add (a, lbl.len)
  if s.varargs: lbl.add (if s.params.len > 0: ", ..." else: "...")
  lbl.add ")"
  sigLabel = lbl
  sigHl = if active < spans.len: spans[active] else: (0, 0)
  sigDoc = s.doc
  sigMore = ""
  sigLine = p.line
  sigOpen = true
  needRender = true
  true

func cArgIsLiteral(a: string): bool =
  ## a number, string, character, NULL / true / false / nullptr — an argument whose meaning the parameter's name tells
  var t = a.strip
  while t.startsWith("(") and t.endsWith(")") and t.len > 2: t = t[1 .. ^2].strip
  if t.len == 0: return false
  if t[0] in Digits or (t[0] in {'-', '+', '.'} and t.len > 1 and t[1] in Digits): return true
  if t[0] in {'"', '\''} or t.startsWith("L\"") or t.startsWith("u8\"") or t.startsWith("L'"): return true
  t in ["NULL", "true", "false", "nullptr", "0"]

proc cEngInlays(b: Buffer, lo, hi: int) =
  ## the names of the parameters before a call's arguments, as clangd shows them: `pt_move(p, dx: 1, dy: 2)` —
  ## before literals unless nim.parameterHints is "all"; not for one-parameter functions, single-letter names, an
  ## argument that is the name already, a call over several lines, or a macro's (…) beyond its parameters
  b.inlays.clear()
  b.inlayAt = b.changeId
  b.inlayLo = lo
  b.inlayHi = hi
  needRender = true
  if cfgParamHints == "off": return
  let all = cfgParamHints == "all"
  let f = cxFileOf(b)
  if f == nil: return
  let t0 = getMonoTime()
  var inBlock = false
  for l in lo .. min(hi, b.lines.high):
    if msSince(t0) > 40: break
    let s = b.lines[l]
    if s.len > 500: continue
    # where the code is on this line (not in comments, strings, characters)
    var code = newSeq[bool](s.len)
    var i = 0
    while i < s.len:
      if inBlock:
        let e = s.find("*/", i)
        if e < 0:
          i = s.len
          break
        inBlock = false
        i = e + 2
        continue
      if s[i] == '/' and i + 1 < s.len and s[i + 1] == '/': break
      if s[i] == '/' and i + 1 < s.len and s[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if s[i] in {'"', '\''}:
        let q = s[i]
        code[i] = true
        inc i
        while i < s.len and s[i] != q:
          if s[i] == '\\': inc i
          inc i
        if i < s.len: code[i] = true
        inc i
        continue
      code[i] = true
      inc i
    if '(' notin s or s.strip(trailing = false).startsWith("#"): continue
    var hs: seq[(int, string)]
    for open in 1 ..< s.len:
      if s[open] != '(' or not code[open]: continue
      var e = open
      while e > 0 and s[e - 1] == ' ': dec e
      var a = e
      while a > 0 and s[a - 1] in IdentChars: dec a
      if a == e or s[a] in Digits: continue
      let name = s[a ..< e]
      if name in ["if", "for", "while", "switch", "return", "sizeof", "case", "do", "else", "catch", "alignof",
                  "_Alignof", "typeof", "__typeof__", "decltype", "defined", "_Generic", "static_assert",
                  "_Static_assert"]:
        continue
      # its arguments, when they close on this line
      var d = 0
      var close = -1
      var args: seq[(int, int)]
      var argStart = open + 1
      var k = open
      while k < s.len:
        if code[k]:
          let c = s[k]
          if c in {'"', '\''}:
            let q = c
            inc k
            while k < s.len and s[k] != q:
              if s[k] == '\\': inc k
              inc k
          elif c in {'(', '[', '{'}: inc d
          elif c in {')', ']', '}'}:
            dec d
            if d == 0:
              close = k
              break
          elif c == ',' and d == 1:
            args.add (argStart, k)
            argStart = k + 1
        inc k
      if close < 0 or close == open + 1: continue
      args.add (argStart, close)
      var want = false
      for (x, y) in args:
        if all or cArgIsLiteral(s[x ..< y]): want = true
      if not want: continue
      var sym: CxSym
      try: sym = cxSignature(f, l, open + 1)[0]
      except CatchableError: continue
      if sym.name != name or sym.params.len < 2: continue
      for ai, (x, y) in args:
        if ai >= sym.params.len: break
        let txt = s[x ..< y]
        if not (all or cArgIsLiteral(txt)): continue
        let pn = sym.params[ai].name
        if pn.len <= 1 or txt.strip == pn or pn == "...": continue
        var c = x
        while c < y and s[c] == ' ': inc c
        hs.add (c, pn & ": ")
    if hs.len > 0: b.inlays[l] = hs

proc cEngOutline(b: Buffer): seq[SideItem] =
  if not cEngineOn(b): return
  try:
    let f = cxFileOf(b)
    for s in cxOutline(f):
      let icon = case s.kind
        of cxFunc, cxMethod: "ƒ"
        of cxStruct, cxUnion, cxEnum, cxTypedef, cxClass: "T"
        of cxMacro: "#"
        else: "v"
      let fn = s.kind in {cxFunc, cxMethod}
      # (C++: a method defined outside its class, as Class::name)
      let name = if s.kind == cxMethod and s.owner.len > 0: cxxSplit(s.owner)[^1] & "::" & s.name else: s.name
      result.add SideItem(text: name, detail: (if fn or s.kind == cxClass: s.text else: s.typ), path: b.path,
                          line: s.line, col: s.col, depth: 0, icon: icon,
                          role: (if fn: 7 elif s.kind in {cxStruct, cxUnion, cxEnum, cxTypedef, cxClass}: 8 else: 0))
      if s.kind in {cxStruct, cxUnion, cxClass}:
        let key = if f.cpp: cxxQual(s) else: s.name
        for x in f.syms:
          if x.kind in {cxField, cxMethod} and x.owner == key and (x.kind == cxField or x.scope == x.owner):
            result.add SideItem(text: x.name, detail: (if x.kind == cxMethod: x.text else: x.typ), path: b.path,
                                line: x.line, col: x.col, depth: 1, icon: (if x.kind == cxMethod: "ƒ" else: "v"),
                                role: (if x.kind == cxMethod: 7 else: 0))
  except CatchableError as e: internalError("C engine", e)

# ── errors while you type: the C compiler on the unsaved text (a private copy, removed after) ──

var cTypingChecks: Table[string, (int, string)]      # path → (changeId checked, the copy)

proc cFixItEdit(t: string): (Pos, Pos, string) =
  ## fix-it:"<stdin>":{L1:C1-L2:C2}:"text" (clang's and gcc's -fdiagnostics-parseable-fixits: 1-based, bytes,
  ## the end not included, the text with C's escapes) — "\0" as the text when the line is not one
  result[2] = "\0"
  let a = t.find('{')
  let z = t.find('}', a + 1)
  if a < 0 or z < 0 or z + 2 >= t.len or t[z + 1] != ':' or t[z + 2] != '"' or not t.endsWith("\""): return
  let r = t[a + 1 ..< z].split('-')
  if r.len != 2: return
  let p0 = r[0].split(':')
  let p1 = r[1].split(':')
  if p0.len != 2 or p1.len != 2: return
  try:
    result[0] = Pos(line: parseInt(p0[0]) - 1, col: parseInt(p0[1]) - 1)
    result[1] = Pos(line: parseInt(p1[0]) - 1, col: parseInt(p1[1]) - 1)
  except ValueError: return
  if result[0].line < 0 or result[0].col < 0 or result[1] < result[0]: return
  let q = t[z + 3 ..< t.len - 1]
  var txt = ""
  var i = 0
  while i < q.len:
    if q[i] == '\\' and i + 1 < q.len:
      inc i
      case q[i]
      of 'n': txt.add '\n'
      of 't': txt.add '\t'
      of '0'..'7':
        var v = 0
        var k = 0
        while k < 3 and i < q.len and q[i] in {'0'..'7'}:
          v = v * 8 + ord(q[i]) - ord('0')
          inc i
          inc k
        txt.add chr(v and 255)
        continue
      else: txt.add q[i]
    else: txt.add q[i]
    inc i
  result[2] = txt

proc cFixItJson(b: Buffer, edits: seq[(Pos, Pos, string)], note: string, at: int): JsonNode =
  ## one fix as the quick-fix list takes it: its title (the note's words, or what it changes), its edits
  var title = ""
  if note.len > 0:
    title = note
    for tail in [" to silence this warning", " to silence this diagnostic"]:
      if title.endsWith(tail): title = title[0 ..< title.len - tail.len]
    if title.len > 0: title[0] = title[0].toUpperAscii
  elif edits.len == 1:
    let (p0, p1, nt) = edits[0]
    var old = ""
    if b != nil and p0.line == p1.line and p0.line < b.lines.len and p1.col <= b.lines[p0.line].len:
      old = b.lines[p0.line][p0.col ..< p1.col]
    title = if old.len == 0: "Insert '" & nt & "'"
            elif nt.len == 0: "Remove '" & old & "'"
            else: "Change '" & old & "' to '" & nt & "'"
  else: title = "Apply the compiler's fix (" & $edits.len & " changes)"
  var es = newJArray()
  for (p0, p1, nt) in edits:
    es.add %*{"range": {"start": {"line": p0.line, "col": p0.col}, "stop": {"line": p1.line, "col": p1.col}},
              "text": nt}
  %*{"title": truncTo(title.replace("\n", " "), 70), "nedEdits": es, "at": at}

proc cFixItActions*(b: Buffer, ds: seq[Diag]): seq[(string, string, Action)] =
  ## the compiler's fixes for the problems here (C/C++ without clangd: cc -fsyntax-only's fix-its)
  let bid = b.id
  for d in ds:
    if d.src != "cc" or d.fixes == nil: continue
    for f in jitems(d.fixes):
      let edits = f{"nedEdits"}
      let at = f{"at"}.getInt(-1)
      result.add act(f{"title"}.getStr, "the compiler's fix", proc() =
        let x = bufById(bid)
        if x == nil or not x.canEdit(): return
        if x.changeId != at:
          info("The file changed since the compiler looked — save or pause typing, then try again")
          return
        var es: seq[(Pos, Pos, string)]
        for e in jitems(edits):
          es.add (Pos(line: e{"range", "start", "line"}.getInt, col: e{"range", "start", "col"}.getInt),
                  Pos(line: e{"range", "stop", "line"}.getInt, col: e{"range", "stop", "col"}.getInt), e{"text"}.getStr)
        # (from the last edit back: the earlier ranges stay where they are)
        es.sort(proc(p, q: (Pos, Pos, string)): int = (if q[0] < p[0]: -1 elif p[0] < q[0]: 1 else: 0))
        x.beginEdit()
        for (a, e, t) in es: discard x.replaceText(x.clampPos(a), x.clampPos(e), t)
        x.endEdit()
        needRender = true)

proc cTypingCheck(b: Buffer) =
  let cpp = cxIsCppBuf(b)
  if b.path in cTypingChecks or not haveExe(if cpp: "c++" else: "cc"): return
  let id = b.changeId
  let copy = privTmp("ctyping") & (if cpp: ".cpp" else: ".c")
  try: writeFile(copy, b.lines.join("\n") & "\n")
  except CatchableError: return
  b.chkAt = id
  let path = b.path
  let bid = b.id
  cTypingChecks[path] = (id, copy)
  cxSetDirs(b)
  var inc = " -iquote " & quoteShell(parentDir(path))
  for d in cxDirs:
    if d != parentDir(path) and not cSystemIncludeDirs().contains(d): inc.add " -I" & quoteShell(d)
  for d in cxCompileDefs: inc.add " " & quoteShell(d)
  let cc = if cpp: "c++ -std=c++17" else: "cc"
  discard startJob(jkCheck, "LC_ALL=C " & cc & " -fsyntax-only -Wall -fdiagnostics-color=never" &
                   " -fdiagnostics-parseable-fixits" & inc &
                   (if cpp: " -x c++ - < " else: " -x c - < ") & quoteShell(copy),
                   parentDir(path), proc(j: Job) =
    cTypingChecks.del path
    try: removeFile(copy)
    except CatchableError: discard
    let x = bufById(bid)
    if x == nil or x.changeId != id: return
    var ds: seq[Diag]
    # the compiler's own fixes (fix-it: lines after a problem or after one of its notes): Alt+Enter, as clangd's
    var owner = -1                 # (the problem the fix-its below belong to)
    var noteWords = ""             # (the note they follow: what the fix does, in its words)
    var edits: seq[(Pos, Pos, string)]
    proc flush() =
      if edits.len > 0 and owner >= 0:
        if ds[owner].fixes == nil: ds[owner].fixes = newJArray()
        ds[owner].fixes.add cFixItJson(x, edits, noteWords, id)
      edits.setLen(0)
    for raw in j.output.splitLines:
      var t = stripAnsi(raw)
      if t.startsWith("fix-it:\"<stdin>\":{"):
        let e = cFixItEdit(t)
        if e[2] != "\0": edits.add e
        continue
      if not t.startsWith("<stdin>:"): continue
      t = t["<stdin>:".len .. ^1]
      let parts = t.split(':', 3)
      if parts.len < 4: continue
      var l, c: int
      try:
        l = parseInt(parts[0]) - 1
        c = parseInt(parts[1]) - 1
      except ValueError: continue
      let rest = parts[3].strip
      let sev = if parts[2].strip == "error" or parts[2].strip == "fatal error": 1
                elif parts[2].strip == "warning": 2
                elif parts[2].strip == "note": 3
                else: 0
      if sev == 0: continue
      flush()
      if sev == 3:
        noteWords = rest
        continue
      noteWords = ""
      ds.add Diag(line: max(0, l), col: max(0, c), eline: max(0, l), ecol: -1, sev: sev, msg: rest, src: "cc")
      owner = ds.high
    flush()
    diagsBuild[path] = ds
    needRender = true)

# ── a missing #include ──

const CxStdHeaders = ["stdio.h", "stdlib.h", "string.h", "math.h", "ctype.h", "stdint.h", "stdbool.h", "stddef.h",
  "stdarg.h", "time.h", "errno.h", "assert.h", "limits.h", "float.h", "signal.h", "setjmp.h", "locale.h", "wchar.h",
  "inttypes.h", "unistd.h", "fcntl.h", "sys/types.h", "sys/stat.h", "sys/time.h", "sys/wait.h", "sys/mman.h",
  "sys/socket.h", "netinet/in.h", "arpa/inet.h", "netdb.h", "pthread.h", "dirent.h", "poll.h", "termios.h",
  "dlfcn.h", "strings.h", "sys/ioctl.h", "sys/select.h", "getopt.h", "libgen.h", "glob.h", "regex.h", "search.h",
  "stdatomic.h", "threads.h", "complex.h", "tgmath.h", "uchar.h", "wctype.h", "iso646.h", "stdalign.h",
  "stdnoreturn.h"]

var cxHeaderOfCache: Table[string, string]

proc cxHeaderOf(name: string): string =
  ## the standard header that declares `name` (a function, type, macro or variable), as `<h>`, or ""
  if name in cxHeaderOfCache: return cxHeaderOfCache[name]
  result = ""
  const quick = {"NULL": "stddef.h", "size_t": "stddef.h", "bool": "stdbool.h", "true": "stdbool.h",
                 "false": "stdbool.h", "uint8_t": "stdint.h", "int32_t": "stdint.h", "uint32_t": "stdint.h",
                 "int64_t": "stdint.h", "uint64_t": "stdint.h", "va_list": "stdarg.h", "errno": "errno.h",
                 "EOF": "stdio.h", "FILE": "stdio.h", "printf": "stdio.h", "malloc": "stdlib.h", "free": "stdlib.h",
                 "strlen": "string.h", "memcpy": "string.h", "INT_MAX": "limits.h"}.toTable
  if name in quick: result = "<" & quick[name] & ">"
  else:
    let dirs = cSystemIncludeDirs()
    for h in CxStdHeaders:
      let hp = cFindHeader("<" & h & ">", dirs)
      if hp.len == 0: continue
      var seen: HashSet[string]
      if cFindIn(hp, name, dirs, 0, seen).kind.len > 0:
        result = "<" & h & ">"
        break
  cxHeaderOfCache[name] = result

proc cIncludeFix(b: Buffer, d: Diag): (string, string, Action) =
  ## the quick fix for "implicit declaration of function 'x'", "unknown type name 'y'", "'NULL' undeclared":
  ## #include the standard header that declares it
  let m = d.msg
  if not ("implicit declaration of function" in m or "call to undeclared function" in m or
          "unknown type name" in m or "undeclared" in m or "use of undeclared identifier" in m):
    return
  var a = -1
  var ql = 1
  for q in ["'", "`", "\"", "‘"]:                        # (‘’: the compiler's quotes in a UTF-8 locale)
    let k = m.find(q)
    if k >= 0 and (a < 0 or k < a): (a, ql) = (k, q.len)
  if a < 0: return
  var e = a + ql
  while e < m.len and m[e] notin {'\'', '`', '"'} and not m.continuesWith("’", e): inc e
  let name = m[a + ql ..< e]
  if name.len == 0: return
  let h = cxHeaderOf(name)
  if h.len == 0: return
  for l in b.lines:
    if l.strip.startsWith("#include") and h in l: return
  let bid = b.id
  ("#include " & h, "declares " & name, proc() =
    let x = bufById(bid)
    if x == nil: return
    var at = 0
    for i, l in x.lines:
      if l.strip.startsWith("#include"): at = i + 1
    x.beginEdit()
    discard x.replaceText(Pos(line: at, col: 0), Pos(line: at, col: 0), "#include " & h & "\n")
    x.endEdit()
    x.normalize()
    info("Added #include " & h))

proc cEngCallHierarchy(b: Buffer): bool =
  ## who calls the function at the cursor (←) and what it calls (→): its references in the project's C files, each
  ## under the function it is in — and the calls in its body, each to its declaration
  if not cEngineOn(b): return false
  let f = cxFileOf(b)
  let p = b.primary.head
  var fn: CxSym
  var fnFile: CxFile
  var have = false
  if b.wordAt(p).len > 0:
    try:
      let ts = cxTargets(f, p.line, p.col)
      if ts.len > 0 and ts[0][1].kind in {cxFunc, cxMethod}:
        (fnFile, fn, have) = (ts[0][0], ts[0][1], true)
    except CatchableError: discard
  if not have:
    for s in f.syms:
      if s.kind in {cxFunc, cxMethod} and s.isDef and s.line <= p.line and p.line <= s.endLine:
        (fnFile, fn, have) = (f, s, true)
  if not have:
    info("Put the cursor on a function's name, or in its body")
    return true
  # (its body: where it is defined — this file, or the one cxTargets found)
  if not fn.isDef:
    try:
      let defs = cxTargets(f, p.line, p.col, jump = true)
      for (g, s) in defs:
        if s.kind == fn.kind and s.isDef: (fnFile, fn) = (g, s)
    except CatchableError: discard
  var items: seq[PickItem]
  # ← its callers
  let at = if fnFile != nil and fnFile.path == b.path: Pos(line: fn.line, col: fn.col)
           elif b.wordAt(p) == fn.name: p
           else: Pos(line: -1)
  if at.line >= 0:
    var hits: seq[(string, int, int)]
    try: hits = cEngReferenceHits(b, at)[0]
    except CatchableError: discard
    var loaded: Table[string, CxFile]
    var seen: Table[string, int]
    for (path, l, c) in hits:
      var g: CxFile
      if path == b.path: g = f
      elif path in loaded: g = loaded[path]
      else:
        try: g = cxLoad(path, readFile(path), "ch:" & path)
        except CatchableError: g = nil
        loaded[path] = g
      if g == nil or l >= g.lines.len: continue
      # (a call: the name followed by `(`)
      var k = c + fn.name.len
      let t = g.lines[l]
      while k < t.len and t[k] == ' ': inc k
      if k >= t.len or t[k] != '(': continue
      var caller = ""
      var callerLine = -1
      for s in g.syms:
        if s.kind in {cxFunc, cxMethod} and s.isDef and s.line <= l and l <= s.endLine: (caller, callerLine) = (s.name, s.line)
      if callerLine == l and caller == fn.name: continue        # (its own declaration)
      if caller.len == 0: caller = "(file level)"
      let key = path & ":" & caller
      if key in seen:
        inc items[seen[key]].score
        items[seen[key]].detail = relPath(path) & ":" & $(items[seen[key]].line + 1) & " · " &
                                  $items[seen[key]].score & " calls"
        continue
      seen[key] = items.len
      items.add PickItem(label: "← " & caller, detail: relPath(path) & ":" & $(l + 1), icon: "ƒ", path: path, line: l,
                         col: c, score: 1)
  # → what it calls
  if fn.isDef and fnFile != nil:
    var outSeen: HashSet[string]
    for l in fn.line .. min(fn.endLine, fnFile.lines.high):
      let t = fnFile.lines[l]
      var i = 0
      while i < t.len:
        if t[i] in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
          var e = i
          while e < t.len and t[e] in IdentChars: inc e
          var k = e
          while k < t.len and t[k] == ' ': inc k
          let w = t[i ..< e]
          if k < t.len and t[k] == '(' and w != fn.name and w notin CxKeywords and w notin outSeen and
             not (l == fn.line):
            var ts: seq[(CxFile, CxSym)]
            try: ts = cxTargets(fnFile, l, i, jump = true)
            except CatchableError: discard
            if ts.len > 0 and ts[0][1].kind in {cxFunc, cxMethod, cxMacro}:
              outSeen.incl w
              items.add PickItem(label: "→ " & w, detail: relPath(ts[0][0].path) & ":" & $(ts[0][1].line + 1),
                                 icon: (if ts[0][1].kind == cxMacro: "#" else: "ƒ"), path: ts[0][0].path,
                                 line: ts[0][1].line, col: ts[0][1].col)
          i = e
        else: inc i
  if items.len == 0:
    info("No calls to or from " & fn.name)
    return true
  openPicker(pickSymbol, "Call hierarchy — " & fn.name & "  (← called by · → calls)", items)
  true

proc cOtherFile(path: string): string =
  ## a C file's header, a header's C file: the same name next to it, else in the project
  let (dir, name, ext) = splitFile(path)
  let lext = ext.toLowerAscii
  let wanted = if lext in [".h", ".hh", ".hpp", ".hxx", ".inl"]: @[".c", ".cc", ".cpp", ".cxx", ".m", ".mm"]
               elif lext in [".c", ".cc", ".cpp", ".cxx", ".m", ".mm"]: @[".h", ".hpp", ".hh", ".hxx"]
               else: @[]
  for e in wanted:
    if fileExists(dir / name & e): return dir / name & e
  for e in wanted:
    for sub in ["include", "src", "../include", "../src"]:
      if fileExists(dir / sub / name & e): return normalizedPath(dir / sub / name & e)
  if rootDir.len > 0:
    for rel in projectFiles():
      let (_, n2, e2) = splitFile(rel)
      if n2 == name and e2.toLowerAscii in wanted: return (if rel.isAbsolute: rel else: rootDir / rel)
  ""

proc cmdSwitchHeaderSource() =
  ## C, C++: from a .c to its .h and back (clangd's switch between source and header)
  let b = buf()
  if b.path.len == 0:
    info("Save the file first")
    return
  let o = cOtherFile(b.path)
  if o.len == 0:
    let (_, name, ext) = splitFile(b.path)
    info("No " & (if ext.toLowerAscii in [".h", ".hh", ".hpp", ".hxx"]: "source" else: "header") & " named " & name &
         " here or in the project")
    return
  discard openFile(o)
