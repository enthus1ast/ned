# ── C files with ned's own engine (c.engine): completion — struct members after `.` and `->` too, a call's
#    parameters to fill in, a header's names with their #include —, hover with the comment that documents a
#    declaration, F12 through #includes, type definition, references, highlights and rename by symbol, the outline
#    and symbols, signature help, colours by what names are, the C compiler's errors while you type, a missing
#    #include added, refactors. No clangd needed. C++ files (.cpp .cc .hpp …, and a .h that is C++) too: classes,
#    methods, namespaces, templates read past; the type hierarchy and a method's overrides ──

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

proc cxSetDirsFor(path: string) =
  ## where #include looks: the file's folder, the project's include folders (and compile_commands.json's -I),
  ## then the C compiler's own
  let key = rootDir & "|" & parentDir(path) & "|" & $cSysDirsDone     # (the compiler's own folders, once it said)
  if key == cxDirsKey and cxDirs.len > 0: return
  cxDirsKey = key
  var ds: seq[string]
  var defs: seq[string]
  var each: seq[(string, seq[string])]            # (a file of compile_commands.json, its own -D and -U)
  proc add(d: string) =
    if d.len > 0 and dirExists(d) and d notin ds: ds.add d
  add parentDir(path)
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
          var mine: seq[string]
          var k = 0
          while k < args.len:
            let a = args[k]
            if a in ["-I", "-isystem", "-iquote"] and k + 1 < args.len:
              add(if args[k + 1].isAbsolute: args[k + 1] else: dir / args[k + 1])
              inc k
            elif a.startsWith("-I") and a.len > 2: add(if a[2 .. ^1].isAbsolute: a[2 .. ^1] else: dir / a[2 .. ^1])
            elif (a.startsWith("-D") or a.startsWith("-U")) and a.len > 2 and defs.len < 200:
              mine.add a
              let nm = a[2 .. ^1].split('=')[0]
              var dup = false
              for x in defs:
                if x[2 .. ^1].split('=')[0] == nm: dup = true
              if not dup: defs.add a               # (the first file's, when files differ)
            inc k
          let file = e{"file"}.getStr
          if file.len > 0: each.add ((if file.isAbsolute: file else: dir / file), mine)
          if ds.len > 40: break
      except CatchableError: discard
  for v in [getEnv("C_INCLUDE_PATH"), getEnv("CPATH")]:
    for d in v.split(':'): add d
  for d in cSystemIncludeDirs(): add d
  cxDirs = ds
  cxSysDirs = cSystemIncludeDirs()
  cxCompileDefs = defs
  cxDefines = defs                     # (the engine's #ifs see them too)
  # the files these are all the -D and -U of: their #ifs know a macro defined nowhere is not defined
  cxStrictFiles.clear()
  let all = defs.toHashSet
  for (file, mine) in each:
    if mine.toHashSet == all: cxStrictFiles.incl normalizedPath(file)
  if not cxPredefSet:
    # the compilers' predefined macros, once a session: the #if branches their target decides (__x86_64__,
    # __linux__, _WIN32, __STDC_VERSION__ …) — C's and C++'s; without a compiler, what ned knows of its platform
    proc predefOf(cmds: openArray[string], lang: string): Table[string, string] =
      for cc in cmds:
        if not haveExe(cc): continue
        let (ok, o, _) = runFilter(cc & " -dM -E -x " & lang & " -", "", getCurrentDir(), 5000)
        if not ok: continue
        for l in o.splitLines:
          let p = l.splitWhitespace(2)
          if p.len >= 2 and p[0] == "#define": result[p[1]] = (if p.len > 2: p[2] else: "")
        if result.len > 0: return
    cxPredef = predefOf(["cc", "clang", "gcc"], "c")
    if cxPredef.len == 0: cxPredef = cxBuiltinPredef(cpp = false)
    cxPredefCpp = predefOf(["c++", "clang++", "g++"], "c++")
    if cxPredefCpp.len == 0: cxPredefCpp = cxBuiltinPredef(cpp = true)
    cxPredefSet = true

proc cxSetDirs(b: Buffer) = cxSetDirsFor(b.path)

cxPrepare = cxSetDirsFor       # (the dimming of what #ifs leave out can come first, before the engine reads the file)

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

func cEngCallSnippet(it: CxItem, line: string, col, wordStart: int): string =
  ## a function's call with its parameters to fill in — `area(${1:width}, ${2:height})$0` —, the parentheses only
  ## for overloads (signature help tells the rest); "" for anything else, where a call is there already (`(` after
  ## the word), on a preprocessor line, or after a unary `&` (the function's address)
  if not it.call: return ""
  var e = min(col, line.len)
  while e < line.len and line[e] in IdentChars: inc e
  while e < line.len and line[e] in {' ', '\t'}: inc e
  if e < line.len and line[e] == '(': return ""
  if line.strip(trailing = false).startsWith("#"): return ""
  var k = wordStart
  while k > 0 and line[k - 1] in {' ', '\t'}: dec k
  if k > 0 and line[k - 1] == '&':
    var j = k - 1
    while j > 0 and line[j - 1] in {' ', '\t'}: dec j
    if j == 0 or line[j - 1] notin IdentChars + {')', ']'}: return ""
  if it.overloads: return it.label & "($0)"
  var ps: seq[string]
  for i, prm in it.params:
    ps.add "${" & $(i + 1) & ":" & prm.multiReplace(("$", ""), ("}", ""), ("\\", "")) & "}"
  it.label & "(" & ps.join(", ") & ")$0"

proc cEngIncludeItems(b: Buffer, p: Pos, have: HashSet[string]): seq[CompItem]

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
  let ws = b.wordStart(p)
  var out0: seq[CompItem]
  for it in items:
    out0.add CompItem(label: it.label, insert: it.label, detail: it.detail, kind: cxKindIcon(it.kind),
                      filter: it.label, sortText: $it.rank & it.label, rank: it.rank,
                      snippet: cEngCallSnippet(it, b.lines[p.line], p.col, ws),
                      doc: (if it.detail.len > 0: fence & it.detail & "\n```\n" else: "") & it.doc, docMade: true)
  if not member:
    # (names of headers it does not include: choosing one adds the #include)
    var have: HashSet[string]
    for it in items: have.incl it.label
    try: out0.add cEngIncludeItems(b, p, have)
    except CatchableError as e: internalError("C engine", e)
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

proc cEngJump(b: Buffer, path: string, line, col: int, what: string) =
  ## to a declaration (the jump remembered: Alt+← comes back)
  pushJump()
  let nb = if path == b.path: b else: openFile(path)
  if nb != nil:
    let at = nb.clampPos(Pos(line: line, col: col))
    nb.cursors = @[cur(at)]
    nb.centerOn(at)
  if what.len > 0: info(what)

proc cEngDefTarget(b: Buffer, p: Pos): (string, int, int, string) =
  ## where F12 goes from p: (the file, line, column, the declaration's text) — ("", -1, -1, "") nowhere
  result = ("", -1, -1, "")
  var ts = cxTargets(cxFileOf(b), p.line, p.col, jump = true)
  let cpp = cxIsCppBuf(b)
  proc projectC(): seq[string] =
    if rootDir.len > 0:
      for f in projectFiles():
        if (f.endsWith(".c") or (cpp and cxIsCppPath(f) and not f.splitFile.ext.startsWith(".h"))) and f != b.path:
          result.add(if f.isAbsolute: f else: rootDir / f)
  if ts.len == 0:
    # declared in no header this file includes: a function or global defined in the project's other .c files
    let (a, e) = cxWordAt(b.lines[p.line], p.col)
    if a >= e: return
    let w = b.lines[p.line][a ..< e]
    if w in CxKeywords or (cpp and w in CxxKeywords): return
    let cs = projectC()
    for kind in (if cpp: @[cxFunc, cxVar, cxClass, cxStruct] else: @[cxFunc, cxVar, cxStruct]):
      let (h, k) = cxBodyIn(cs, w, kind)
      if h != nil:
        ts.add (h, h.syms[k])
        break
    if ts.len == 0: return
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
  result = ((if g.path == b.path: b.path else: g.path), s.line, s.col, s.text)

proc cEngDefinition(b: Buffer, p: Pos): bool =
  ## F12: the declaration (a function's body first), through the #includes
  if not cEngineOn(b): return false
  var t: (string, int, int, string)
  try: t = cEngDefTarget(b, p)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if t[0].len == 0: return false
  cEngJump(b, t[0], t[1], t[2], t[3])
  true

proc cEngTypeTarget(b: Buffer, p: Pos): (string, int, int, string) =
  ## where go to type definition goes from p: (the file, line, column, the declaration) — ("", …) nowhere
  result = ("", -1, -1, "")
  let (g, s) = cxTypeTarget(cxFileOf(b), p.line, p.col)
  if g != nil: result = ((if g.path == b.path: b.path else: g.path), s.line, s.col, s.text)

proc cEngTypeDefinition(b: Buffer): bool =
  ## the declaration of the type of what the name at the cursor names — a struct's body through its typedef
  if not cEngineOn(b) or b.wordAt(b.primary.head).len == 0: return false
  var t: (string, int, int, string)
  try: t = cEngTypeTarget(b, b.primary.head)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if t[0].len == 0: return false
  cEngJump(b, t[0], t[1], t[2], t[3])
  true

proc cEngReferenceHits(b: Buffer, p: Pos, onlyHere = false): (seq[(string, int, int)], string) =
  ## where what the name at p names is used: a local in its function, anything else in the project's C files (and
  ## the open ones) — each place checked with the engine: a field of another struct, a static function of another
  ## file or another function's local of that name is not among them. A name the engine does not know: where it
  ## does not know it either. onlyHere: in this file only. Second result: why there are none
  let f = cxFileOf(b)
  let (a, e) = cxWordAt(b.lines[p.line], p.col)
  if a >= e: return (@[], "No symbol under cursor")
  let w = b.lines[p.line][a ..< e]
  let cpp = f.cpp
  if w in CxKeywords: return (@[], w & " is a C keyword")
  if cpp and w in CxxKeywords: return (@[], w & " is a C++ keyword")
  let ts = cxTargets(f, p.line, p.col)
  let keys = cxKeysOf(ts)
  let unknown = keys.len == 0
  let member = cxIsMember(b.lines[p.line], a)
  if ts.len > 0 and ts[0][1].kind in {cxLocal, cxParam, cxLabel}:
    let s = ts[0][1]
    var lo = s.scopeA
    if s.kind == cxParam:
      for x in f.syms:
        if x.kind == cxFunc and x.name == s.owner and x.isDef and
           (not cpp or (x.line <= s.line and x.endLine >= s.line)): lo = x.line
        elif cpp and x.kind == cxMethod and x.name == s.owner and x.isDef and x.line <= s.line and x.endLine >= s.line:
          lo = x.line
    for (l, c) in cxUsesOf(f, w, keys, lo, s.scopeB): result[0].add (b.path, l, c)
    return
  # (a function or a global with linkage: a call in a file that sees no prototype of it is still one)
  let loose = keys.len > 0 and keys[0].startsWith("G:") and ts[0][1].kind in {cxFunc, cxVar}
  for (l, c) in cxUsesOf(f, w, keys, loose = loose, unknown = unknown, member = member):
    result[0].add (b.path, l, c)
  if onlyHere: return
  # (a static one, a type, a field, a macro or a constant a source file declares: that file only)
  var own = keys.len > 0
  for k in keys:
    if not (k.len > 2 and k[0] in {'S', 'T', 'F', '#', 'E'} and k[2 .. ^1].startsWith(b.path & ":")): own = false
  if own: return
  var seen: HashSet[string]
  seen.incl b.path
  for x in bufs:
    if x.path.len == 0 or x.lang == nil or x.lang.id notin ["c", "cpp"] or x.path in seen: continue
    seen.incl x.path
    var g: CxFile
    try: g = cxFileOf(x)
    except CatchableError: continue
    for (l, c) in cxUsesOf(g, w, keys, loose = loose, unknown = unknown, member = member):
      result[0].add (x.path, l, c)
  if rootDir.len > 0:
    var n = 0
    for f2 in projectFiles():
      if not (f2.endsWith(".c") or f2.endsWith(".h") or (cpp and cxIsCppPath(f2))): continue
      let full = if f2.isAbsolute: f2 else: rootDir / f2
      if full in seen: continue
      inc n
      if n > 3000: break
      var t: string
      try:
        t = readFile(full)
        if w notin t: continue
      except CatchableError: continue
      # (a header: as the files that include it have it, its lines lent for the look; a source file: read whole,
      # its functions' locals too)
      var g: CxFile
      var lent = false
      try:
        if cxIsHeaderPath(full):
          g = cxLoad(full, cpp = cpp or cxIsCppPath(full))
          if g != nil and g.lines.len == 0:
            g.lines = t.splitLines
            lent = true
        else: g = cxLoad(full, t, "refs:" & $hash(t), cpp = cxIsCppPath(full))
      except CatchableError: g = nil
      if g == nil: continue
      try:
        for (l, c) in cxUsesOf(g, w, keys, loose = loose, unknown = unknown, member = member):
          result[0].add (full, l, c)
      finally:
        if lent: g.lines = @[]

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

proc cEngHighlights(b: Buffer, p: Pos): seq[(Pos, Pos)] =
  ## the uses in this file of what the name at p names (the editor marks them, as it marks a language server's)
  if not cEngineOn(b) or p.line >= b.lines.len: return
  let (a, e) = cxWordAt(b.lines[p.line], p.col)
  if a >= e: return
  # (a name written hundreds of times: not each use looked at — the editor marks the word, as without the engine)
  if cxOccurrences(b.lines, b.lines[p.line][a ..< e]).len > 400: return
  try:
    for (path, l, c) in cEngReferenceHits(b, p, onlyHere = true)[0]:
      if path == b.path: result.add (Pos(line: l, col: c), Pos(line: l, col: c + e - a))
  except CatchableError as ex: internalError("C engine", ex)

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

proc cEngChecks(b: Buffer)
proc cEngMerge(ds: var seq[Diag], mine: seq[Diag]): int
var cEngLast: Table[string, (int, seq[Diag])]   # file → (the change, the engine's problems then, before the compiler's)

proc cEngInlays(b: Buffer, lo, hi: int) =
  ## the names of the parameters before a call's arguments, as clangd shows them: `pt_move(p, dx: 1, dy: 2)` —
  ## before literals unless nim.parameterHints is "all"; not for one-parameter functions, single-letter names, an
  ## argument that is the name already, or a macro's (…) beyond its parameters. A call over several lines too
  cEngChecks(b)                        # (the engine's checks too: when the file is opened, and after a change)
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
  # (the code of the lines around: comments and strings blanked — a call begun above the first line shown counts)
  let first = max(0, lo - 30)
  let last = min(b.lines.high, hi + 30)
  var code: seq[string]
  var inBlock = false
  for l in first .. last: code.add(if b.lines[l].len > 500: "" else: cxCodeOf(b.lines[l], inBlock))
  template cd(l: int): string = code[l - first]
  var hs: Table[int, seq[(int, string)]]
  for l in first .. min(hi, last):
    if msSince(t0) > 40: break
    let s = cd(l)
    if '(' notin s or s.strip(trailing = false).startsWith("#"): continue
    for open in 1 ..< s.len:
      if s[open] != '(': continue
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
      # its arguments — (first line, column, last line, column) of each —, when they close within 30 lines
      var d = 0
      var closed = false
      var args: seq[(int, int, int, int)]
      var (al, ac) = (l, open + 1)
      var ln = l
      var k = open
      block scan:
        while ln <= last and ln - l <= 30:
          let u = cd(ln)
          if ln > l and u.strip(trailing = false).startsWith("#"): break scan
          while k < u.len:
            let c = u[k]
            if c in {'(', '[', '{'}: inc d
            elif c in {')', ']', '}'}:
              dec d
              if d == 0:
                args.add (al, ac, ln, k)
                closed = true
                break scan
            elif c == ',' and d == 1:
              args.add (al, ac, ln, k)
              (al, ac) = (ln, k + 1)
            elif c == ';': break scan
            inc k
          inc ln
          k = 0
      if not closed or (args.len == 1 and args[0][0] == args[0][2] and cd(args[0][0])[args[0][1] ..< args[0][3]].strip.len == 0):
        continue
      # (each argument's text, and where it starts: the first of it that is not a space)
      var texts: seq[(string, int, int)]
      for (sl, sc, el, ec) in args:
        var txt = ""
        var at = (-1, -1)
        for q in sl .. el:
          let u = b.lines[q]
          let a0 = if q == sl: sc else: 0
          let e0 = if q == el: ec else: u.len
          let cq = cd(q)
          for c in a0 ..< min(e0, cq.len):
            if at[0] < 0 and cq[c] notin Whitespace: at = (q, c)
          if a0 < min(e0, u.len): txt.add (if txt.len > 0: " " else: "") & u[a0 ..< min(e0, u.len)]
        texts.add (txt, at[0], at[1])
      var want = false
      for (txt, _, _) in texts:
        if all or cArgIsLiteral(txt): want = true
      if not want: continue
      var sym: CxSym
      try: sym = cxSignature(f, l, open + 1, whole = true)[0]     # (C++: the overload every argument fits)
      except CatchableError: continue
      if sym.name != name or sym.params.len < 2: continue
      for ai, (txt, ql, qc) in texts:
        if ai >= sym.params.len: break
        if ql < lo or ql > hi or not (all or cArgIsLiteral(txt)): continue
        let pn = sym.params[ai].name
        if pn.len <= 1 or txt.strip == pn or pn == "...": continue
        hs.mgetOrPut(ql, @[]).add (qc, pn & ": ")
  for l, x in hs:
    var xs = x
    xs.sort(proc(p, q: (int, string)): int = cmp(p[0], q[0]))
    b.inlays[l] = xs

proc cEngOutlineOf(f: CxFile, path: string): seq[SideItem] =
  ## a C file's declarations as the outline lists them: its functions, types, macros and globals, a struct's or
  ## class's members under it
  try:
    for s in cxOutline(f):
      let icon = case s.kind
        of cxFunc, cxMethod: "ƒ"
        of cxStruct, cxUnion, cxEnum, cxTypedef, cxClass: "T"
        of cxMacro: "#"
        else: "v"
      let fn = s.kind in {cxFunc, cxMethod}
      # (C++: a method defined outside its class, as Class::name)
      let name = if s.kind == cxMethod and s.owner.len > 0: cxxNoArgs(cxxSplit(s.owner)[^1]) & "::" & s.name else: s.name
      result.add SideItem(text: name, detail: (if fn or s.kind == cxClass: s.text else: s.typ), path: path,
                          line: s.line, col: s.col, depth: 0, icon: icon,
                          role: (if fn: 7 elif s.kind in {cxStruct, cxUnion, cxEnum, cxTypedef, cxClass}: 8 else: 0))
      if s.kind in {cxStruct, cxUnion, cxClass}:
        let key = if f.cpp: cxxKey(s) else: s.name
        for x in f.syms:
          if x.kind in {cxField, cxMethod} and x.owner == key and (x.kind == cxField or x.scope == x.owner):
            result.add SideItem(text: x.name, detail: (if x.kind == cxMethod: x.text else: x.typ), path: path,
                                line: x.line, col: x.col, depth: 1, icon: (if x.kind == cxMethod: "ƒ" else: "v"),
                                role: (if x.kind == cxMethod: 7 else: 0))
  except CatchableError as e: internalError("C engine", e)

proc cEngSymbolsOf(f: CxFile, path: string, rel = ""): seq[PickItem] =
  ## Ctrl+T (and the project's symbols): a C file's declarations as the engine reads them — its functions, types,
  ## macros and globals, a struct's fields and a class's methods as owner.name, an enum's constants
  var owner = ""
  for it in cEngOutlineOf(f, path):
    if it.depth == 0: owner = it.text
    let where = if rel.len > 0: rel & ":" & $(it.line + 1) & "  " else: ""
    result.add PickItem(label: (if it.depth > 0 and owner.len > 0: owner & "." & it.text else: it.text),
                        detail: truncTo(where & it.detail, 60), icon: (if it.depth > 0 and it.icon == "v": "m" else: it.icon),
                        path: path, line: it.line, col: it.col)
  for s in f.syms:
    if s.kind == cxEnumConst and not cxLineInactive(f, s.line):
      result.add PickItem(label: s.name, detail: truncTo((if rel.len > 0: rel & ":" & $(s.line + 1) & "  " else: "") &
                          "enum " & s.owner, 60), icon: "c", path: path, line: s.line, col: s.col)
  result.sort(proc(x, y: PickItem): int = cmp(x.line, y.line))

proc cEngSymbols(b: Buffer): seq[PickItem] =
  if not cEngineOn(b): return
  try: cEngSymbolsOf(cxFileOf(b), b.path)
  except CatchableError as e:
    internalError("C engine", e)
    @[]

proc cEngOutline(b: Buffer): seq[SideItem] =
  if not cEngineOn(b): return
  var f: CxFile
  try: f = cxFileOf(b)
  except CatchableError as e:
    internalError("C engine", e)
    return
  cEngOutlineOf(f, b.path)

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

proc cEngCursorFixes(b: Buffer, ds: seq[Diag]): seq[(string, string, Action)]

proc cFixItActions*(b: Buffer, ds: seq[Diag]): seq[(string, string, Action)] =
  ## the compiler's fixes for the problems here (C/C++ without clangd: cc -fsyntax-only's fix-its), then the
  ## engine's own at the cursor: the #include an unknown name needs, a switch's missing cases, a selection in a
  ## variable, an if/else inverted
  let bid = b.id
  var fixes: seq[(string, string, Action)]             # (filled inside `capture`, where `result` is its own)
  for d in ds:
    if d.src notin ["cc", "ned"] or d.fixes == nil: continue
    for f in jitems(d.fixes):
      let who = if d.src == "cc" and not f{"ned"}.getBool: "the compiler's fix" else: "ned's engine"
      capture f:                  # (closures made in a loop share its variables: each its own)
        let edits = f{"nedEdits"}
        let at = f{"at"}.getInt(-1)
        fixes.add act(f{"title"}.getStr, who, proc() =
          let x = bufById(bid)
          if x == nil or not x.canEdit(): return
          if x.changeId != at:
            info("The file changed since it was checked — pause typing, then try again")
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
  if cEngineOn(b):
    try: fixes.add cEngCursorFixes(b, ds)
    except CatchableError as e: internalError("C engine", e)
  fixes

proc cTypingCheck(b: Buffer) =
  cEngChecks(b)                        # (the engine's own checks first: at once, with no compiler too)
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
    # (the engine's own checks stay, where the compiler says nothing on their line)
    if path in cEngLast and cEngLast[path][0] == id: discard cEngMerge(ds, cEngLast[path][1])
    else:
      for d in diagsBuild.getOrDefault(path):
        if d.src == "ned":
          var taken = false
          for e in ds:
            if e.line == d.line: taken = true
          if not taken: ds.add d
    diagsBuild[path] = ds
    needRender = true)

# ── ned's own checks (c.engineChecks): an #include nothing of which is used, a struct that takes less room with
#    its fields ordered by size, printf and scanf formats against their arguments — at once, with no compiler ──

import cchecks

var cEngChecked: Table[int, (int, string)]      # buffer id → (the change its checks were made for, which checks)

proc cEngMerge(ds: var seq[Diag], mine: seq[Diag]): int =
  ## the engine's problems among the compiler's: where the compiler says something on the same line, its words
  ## stay — and a format's fix goes with them (gcc's -Wformat has none); the number added
  for d in mine:
    var taken = false
    for e in ds.mitems:
      if e.src == "cc" and e.line == d.line:
        taken = true
        if d.rule == "c-format" and d.fixes != nil and "format" in e.msg and
           (e.fixes == nil or e.fixes.len == 0 or e.fixes[0]{"ned"}.getBool):
          e.fixes = d.fixes
          break
    if not taken:
      ds.add d
      inc result

proc cEngChecks(b: Buffer) =
  ## the engine's checks of a C file among its problems, with their fixes (Alt+Enter) — the compiler's word first on
  ## a line where both say something. Not with c.engine "both": clangd's checks are there
  if not cEngineOn(b) or cfgCEngine == "both" or b.path.len == 0: return
  let key = $cxChecks & "/" & $cSysDirsDone          # (the compiler's folders arrived: a header now read whole)
  if cEngChecked.getOrDefault(b.id) == (b.changeId, key): return
  cEngChecked[b.id] = (b.changeId, key)
  var found: seq[CkProblem]
  try:
    let f = cxFileOf(b)
    var others: seq[seq[string]]                 # (the other open C files: a brace list there fills a struct too)
    for x in bufs:
      if x != b and x.lang != nil and x.lang.id in ["c", "cpp"] and others.len < 20: others.add x.lines
    found = ckChecks(f, cxChecks.includes, cxChecks.padding, cxChecks.formats, others)
  except CatchableError as e:
    internalError("C engine checks", e)
    return
  var mine: seq[Diag]
  for p in found:
    var d = Diag(line: p.line, col: p.col, eline: p.eline, ecol: p.ecol, sev: p.sev, msg: p.msg, src: "ned",
                 rule: p.rule)
    for fx in p.fixes:
      var es: seq[(Pos, Pos, string)]
      for e in fx.edits: es.add (Pos(line: e.line, col: e.col), Pos(line: e.eline, col: e.ecol), e.text)
      if d.fixes == nil: d.fixes = newJArray()
      let j = cFixItJson(b, es, fx.title, b.changeId)
      j["ned"] = %true
      d.fixes.add j
    mine.add d
  lintApply(b.path, b.lines, mine)                # (.ned/lint.json: a rule's severity, or off)
  cEngLast[b.path] = (b.changeId, mine)
  var ds: seq[Diag]
  for d in diagsBuild.getOrDefault(b.path):
    if d.src != "ned": ds.add d
  let before = diagsBuild.getOrDefault(b.path).len
  let added = cEngMerge(ds, mine)
  if added > 0 or ds.len != before or mine.len > 0:     # (or a fix given to the compiler's words)
    diagsBuild[b.path] = ds
    needRender = true

proc cEngAgain(path: string) =
  ## the compiler's check on save replaced a C file's problems: the engine's own go back among them (worked out
  ## again when the text has changed since)
  let i = bufIndexByPath(path)
  if i < 0 or path notin cEngLast: return
  if cEngLast[path][0] != bufs[i].changeId:
    cEngChecked.del bufs[i].id
    return
  var ds = diagsBuild.getOrDefault(path)
  if cEngMerge(ds, cEngLast[path][1]) > 0:
    diagsBuild[path] = ds
    needRender = true

# ── a missing #include ──

const CxStdHeaders = ["stdio.h", "stdlib.h", "string.h", "math.h", "ctype.h", "stdint.h", "stdbool.h", "stddef.h",
  "stdarg.h", "time.h", "errno.h", "assert.h", "limits.h", "float.h", "signal.h", "setjmp.h", "locale.h", "wchar.h",
  "inttypes.h", "unistd.h", "fcntl.h", "sys/types.h", "sys/stat.h", "sys/time.h", "sys/wait.h", "sys/mman.h",
  "sys/socket.h", "netinet/in.h", "arpa/inet.h", "netdb.h", "pthread.h", "dirent.h", "poll.h", "termios.h",
  "dlfcn.h", "strings.h", "sys/ioctl.h", "sys/select.h", "getopt.h", "libgen.h", "glob.h", "regex.h", "search.h",
  "stdatomic.h", "threads.h", "complex.h", "tgmath.h", "uchar.h", "wctype.h", "iso646.h", "stdalign.h",
  "stdnoreturn.h"]

var cxStdIdx: (bool, seq[string], Table[string, (int, CxSym)])   # (made, the headers as #include names them, names)

proc cxStdIndex() =
  ## what the standard headers declare (and the headers they include): read once, the first time it is asked
  if cxStdIdx[0]: return
  cxStdIdx[0] = true
  let dirs = cSystemIncludeDirs()
  var paths: seq[string]
  for h in CxStdHeaders:
    let hp = cFindHeader("<" & h & ">", dirs)
    if hp.len > 0:
      paths.add hp
      cxStdIdx[1].add "<" & h & ">"
  try: cxStdIdx[2] = cxHeaderNames(paths, closure = true)
  except CatchableError as e: internalError("C engine", e)

proc cxHeaderOf(name: string): string =
  ## the standard header that declares `name` (a function, type, macro or variable), as `<h>`, or ""
  const quick = {"NULL": "stddef.h", "size_t": "stddef.h", "ptrdiff_t": "stddef.h", "offsetof": "stddef.h",
                 "bool": "stdbool.h", "true": "stdbool.h", "false": "stdbool.h", "va_list": "stdarg.h",
                 "va_start": "stdarg.h", "va_end": "stdarg.h", "va_arg": "stdarg.h", "errno": "errno.h",
                 "ssize_t": "sys/types.h", "off_t": "sys/types.h", "pid_t": "sys/types.h"}.toTable
  if name in quick: return "<" & quick[name] & ">"
  cxStdIndex()
  let (i, _) = cxStdIdx[2].getOrDefault(name, (-1, CxSym()))
  if i >= 0: cxStdIdx[1][i] else: ""

type CxProjIdx = object
  root: string
  cpp: bool
  at: float                         # (when the headers were listed: listed and read again after ten seconds)
  paths: seq[string]                # the project's headers
  next: int                         # (how many of them are read: a few at a time, a tenth of a second each)
  names: Table[string, (string, CxSym)]       # what they declare, and where (the last reading, while the next is
  making: Table[string, (string, CxSym)]      # made)

var cxProjIdx: CxProjIdx

proc cxProjIndex(cpp: bool) =
  ## what the project's own headers declare — read a slice at a time (a big project's first answer has some of
  ## them), and again now and then: the last reading answers meanwhile
  let now = epochTime()
  if cxProjIdx.root != rootDir or cxProjIdx.cpp != cpp:
    cxProjIdx = CxProjIdx(root: rootDir, cpp: cpp)
  if now - cxProjIdx.at > 10.0 and cxProjIdx.next >= cxProjIdx.paths.len:
    cxProjIdx.at = now
    cxProjIdx.paths.setLen(0)
    cxProjIdx.next = 0
    cxProjIdx.making.clear()
    if rootDir.len > 0:
      for rel in projectFiles():
        if cxIsHeaderPath(rel) and (cpp or not cxIsCppPath(rel)) and cxProjIdx.paths.len < 3000:
          cxProjIdx.paths.add(if rel.isAbsolute: rel else: rootDir / rel)
  let t0 = getMonoTime()
  while cxProjIdx.next < cxProjIdx.paths.len and msSince(t0) < 100:
    let i = cxProjIdx.next
    inc cxProjIdx.next
    var one: Table[string, (int, CxSym)]
    try: one = cxHeaderNames([cxProjIdx.paths[i]], cpp = cpp)
    except CatchableError: discard
    for n, (_, s) in one:
      if n notin cxProjIdx.making: cxProjIdx.making[n] = (cxProjIdx.paths[i], s)
    if cxProjIdx.next == cxProjIdx.paths.len: cxProjIdx.names = move cxProjIdx.making

proc cxProjNames(): ptr Table[string, (string, CxSym)] =
  ## what the project's headers declare: the last reading (the first time, what is read so far)
  if cxProjIdx.names.len == 0: addr cxProjIdx.making else: addr cxProjIdx.names

proc cEngHeaderFor(b: Buffer, name: string): string =
  ## the #include (as the file would write it: <stdio.h>, "util.h") of the header that declares `name` — one of the
  ## project's, else a standard one —; "" when ned knows of none, or the file is that header
  cxProjIndex(cxIsCppBuf(b))
  let (hp, _) = cxProjNames()[].getOrDefault(name, ("", CxSym()))
  if hp.len > 0 and hp != b.path:
    cxSetDirs(b)
    return cxIncludeText(hp, b.path, cxDirs)
  cxHeaderOf(name)

proc cAddInclude(b: Buffer, incl: string) =
  ## `#include <h>` added where the file's #includes are (unless it is there already)
  if not b.canEdit(): return
  let h = incl.strip.replace("#include", "").strip
  for l in b.lines:
    let t = l.strip
    if t.startsWith("#") and "include" in t and h in t: return
  let at = cxIncludeLine(b.lines)
  b.beginEdit()
  if at >= b.lines.len:
    let l = b.lines.high
    discard b.replaceText(Pos(line: l, col: b.lines[l].len), Pos(line: l, col: b.lines[l].len), "\n#include " & h)
  else: discard b.replaceText(Pos(line: at, col: 0), Pos(line: at, col: 0), "#include " & h & "\n")
  b.endEdit()
  needRender = true
  info("Added #include " & h)

proc cIncludeFix(b: Buffer, d: Diag): (string, string, Action) =
  ## the quick fix for "implicit declaration of function 'x'", "unknown type name 'y'", "'NULL' undeclared":
  ## #include the header (the project's, or a standard one) that declares it
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
  let h = cEngHeaderFor(b, name)
  if h.len == 0: return
  for l in b.lines:
    if l.strip.startsWith("#include") and h in l: return
  let bid = b.id
  ("#include " & h, "declares " & name, proc() =
    let x = bufById(bid)
    if x != nil: cAddInclude(x, "#include " & h))

proc cEngIncludeItems(b: Buffer, p: Pos, have: HashSet[string]): seq[CompItem] =
  ## completion of a name a header the file does not include declares (the project's, then the standard ones —
  ## a word of two letters or more): choosing it adds the #include
  let line = b.lines[p.line]
  let ws = b.wordStart(p)
  let prefix = line[ws ..< min(p.col, line.len)]
  if prefix.len < 2 or line.strip(trailing = false).startsWith("#") or cxIsMember(line, ws): return
  let lp = prefix.toLowerAscii
  let fence = if cxIsCppBuf(b): "```cpp\n" else: "```c\n"
  var added: HashSet[string]
  proc add(name, incl: string, s: CxSym, rank: int, res: var seq[CompItem]) =
    var it = CxItem(label: name, kind: s.kind)
    cxCallOf(it, s)
    let detail = if s.kind == cxFunc: s.text else: s.typ
    res.add CompItem(label: name, insert: name, detail: "#include " & incl, kind: cxKindIcon(s.kind), filter: name,
                     sortText: "5" & name.toLowerAscii, rank: rank, addImport: "#include " & incl,
                     snippet: cEngCallSnippet(it, line, p.col, ws),
                     doc: (if detail.len > 0: fence & detail & "\n```\n" else: "") & "Adds `#include " & incl & "`" &
                          (if s.doc.len > 0: "\n\n" & s.doc else: ""), docMade: true)
    added.incl name
  cxProjIndex(cxIsCppBuf(b))
  cxSetDirs(b)
  var closure: HashSet[string]
  try:
    for g in cxClosure(cxFileOf(b)): closure.incl g.path
  except CatchableError: discard
  for n, (hp, s) in cxProjNames()[]:
    if result.len >= 40: break
    if n in have or n in added or not n.toLowerAscii.startsWith(lp) or hp == b.path or hp in closure: continue
    add(n, cxIncludeText(hp, b.path, cxDirs), s, 4, result)
  cxStdIndex()
  for n, (i, s) in cxStdIdx[2]:
    if result.len >= 40: break
    if n in have or n in added or not n.toLowerAscii.startsWith(lp): continue
    let incl = cxHeaderOf(n)
    if incl.len > 0: add(n, incl, s, 5, result)

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

# ── the engine's own fixes and refactors at the cursor (Alt+Enter): the #include an unknown name needs, a switch's
#    missing cases, a selection in a variable, an if/else inverted ──

proc cEngApply(b: Buffer, fx: CkFix) =
  ## a fix's edits made, as one step (from the last back: the earlier places stay where they are)
  var es = fx.edits
  es.sort(proc(p, q: CkEdit): int = cmp((q.line, q.col), (p.line, p.col)))
  b.beginEdit()
  for e in es:
    discard b.replaceText(b.clampPos(Pos(line: e.line, col: e.col)), b.clampPos(Pos(line: e.eline, col: e.ecol)), e.text)
  b.endEdit()
  needRender = true

proc cEngFixAct(bid, at: int, fx: CkFix): Action =
  ## (made by a proc of its own: each action with its own fix)
  result = proc() =
    let x = bufById(bid)
    if x == nil or not x.canEdit(): return
    if x.changeId != at:
      info("The file changed since — try again")
      return
    cEngApply(x, fx)

proc cEngExtractAct(bid, at, line, a, e: int, guess: string): Action =
  ## the selection into a variable: its name asked (the one ned would give it offered), then the cursor on it
  result = proc() =
    askText("Name of the variable", guess, proc(name: string) =
      let x = bufById(bid)
      if x == nil or not x.canEdit(): return
      let n = name.strip
      if n.len == 0 or n[0] notin IdentStartChars or not n.allCharsInSet(IdentChars) or n in CxKeywords:
        error(n & " is not a C name")
        return
      if x.changeId != at:
        info("The file changed since — try again")
        return
      var fx: seq[CkFix]
      try: fx = ckExtractVar(cxFileOf(x), line, a, e, n)
      except CatchableError as ex: internalError("C engine", ex)
      if fx.len == 0: return
      cEngApply(x, fx[0])
      let ins = fx[0].edits[1]
      let c = x.lines[min(ins.line, x.lines.high)].find(n & " = ")
      if c >= 0: x.setSingle(Pos(line: ins.line, col: c))
      info("Extracted into " & n & " — F2 renames it everywhere"))

proc cEngCursorFixes(b: Buffer, ds: seq[Diag]): seq[(string, string, Action)] =
  let f = cxFileOf(b)
  let p = b.primary.head
  let bid = b.id
  let at = b.changeId
  # an unknown name: the header that declares it (unless the compiler's problem there offers it already)
  let t = b.lines[p.line]
  let (wa, we) = cxWordAt(t, p.col)
  if wa < we and t[wa] notin Digits and not cxIsMember(t, wa) and
     b.tokenAt(Pos(line: p.line, col: wa)) notin {tkComment, tkDoc, tkString, tkChar}:
    let w = t[wa ..< we]
    if w notin CxKeywords and not (f.cpp and w in CxxKeywords) and cxTargets(f, p.line, p.col).len == 0:
      let h = cEngHeaderFor(b, w)
      var offered = false
      for d in ds:
        if cIncludeFix(b, d)[0] == "#include " & h: offered = true
      if h.len > 0 and not offered:
        result.add act("#include " & h, "declares " & w, proc() =
          let x = bufById(bid)
          if x != nil: cAddInclude(x, "#include " & h))
  for fx in ckFillSwitch(f, p.line, p.col):
    result.add act(fx.title, "ned's engine", cEngFixAct(bid, at, fx))
  let (sa, se) = b.primary.range
  if sa != se and sa.line == se.line:
    let fx = ckExtractVar(f, sa.line, sa.col, se.col)
    if fx.len > 0:
      let decl = fx[0].edits[1].text.strip
      let guess = fx[0].edits[0].text
      result.add act("Extract into a variable", truncTo(decl, 50), cEngExtractAct(bid, at, sa.line, sa.col, se.col, guess))
  for fx in ckInvertIf(b.lines, p.line):
    result.add act("Invert the if", "!(condition), the branches swapped", cEngFixAct(bid, at, fx))

# ── semantic colours (nim.semanticColors): a C file's names coloured by what the engine knows they are — a
#    parameter, a global, a macro, a field, an enum constant, a type, a function ──

var cEngSem: Table[int, (int, CxSemMap)]     # buffer id → (the change its map was made for, the map)

proc cEngSemMap(b: Buffer, make: bool): CxSemMap =
  ## the buffer's map of names (nil: none yet) — made again once typing pauses, in a quiet moment (make): kept by
  ## name meanwhile, so the lines an edit moves keep their colours
  if not cfgSemColors or not cEngineOn(b): return nil
  let have = cEngSem.getOrDefault(b.id, (-1, CxSemMap(nil)))
  result = have[1]
  if not make or have[0] == b.changeId or msSince(b.lspChangeAt) < 300: return
  try:
    result = cxSemMapOf(cxFileOf(b))
    if cEngSem.len > 64:
      # (the maps of buffers closed since go)
      var open: HashSet[int]
      for x in bufs: open.incl x.id
      var gone: seq[int]
      for id in cEngSem.keys:
        if id notin open: gone.add id
      for id in gone: cEngSem.del id
    cEngSem[b.id] = (b.changeId, result)
    needRender = true
  except CatchableError as e: internalError("C engine", e)

proc cEngSemApply(s: string, toks: var seq[TokKind], m: CxSemMap, line: int) =
  ## recolour a line's names by what the engine knows they are (where the lexer coloured them by their shape)
  var code = s
  for q in 0 ..< min(s.len, toks.len):
    if toks[q] in {tkComment, tkDoc, tkString, tkChar, tkEscape}: code[q] = ' '
  for (c, n, k) in cxSemLine(m, line, code):
    let tk = case k
             of cxParam: tkParam
             of cxVar: (if cfgRichColors: tkGlobalVar else: tkText)
             of cxField: tkProperty
             of cxEnumConst: tkConst
             of cxMacro: tkPreproc
             of cxTypedef, cxNamespace: tkType
             of cxFunc: tkFunc
             else: tkText
    for q in c ..< min(c + n, toks.len):
      if tk == tkText:
        if toks[q] in {tkType, tkConst}: toks[q] = tkText     # (a variable whose capital letter looked like a type)
      elif toks[q] in {tkText, tkType, tkVariable, tkFunc, tkConst}: toks[q] = tk

proc cEngProjectSymbols(path, rel: string): seq[PickItem] =
  ## Go to symbol in project: a C or C++ file's declarations from the engine (an open file as it is now; the others
  ## read on their own, without their headers — quick), when the engine answers for C (c.engine); none otherwise —
  ## the pattern search then
  if not (cfgCEngine in ["builtin", "both"] or (cfgCEngine == "auto" and not haveExe("clangd"))): return
  try:
    let bi = bufIndexByPath(path)
    var f: CxFile
    if bi >= 0 and cEngineOn(bufs[bi]): f = cxFileOf(bufs[bi])
    else:
      let cpp = cxIsCppPath(path) or (path.endsWith(".h") and cxLooksCpp(readFile(path)))
      f = cxLoad(path, cpp = cpp, shallow = true)
    if f != nil: result = cEngSymbolsOf(f, path, rel)
  except CatchableError as e: internalError("C engine", e)

# ── C++: the type hierarchy (a class's bases, the classes derived from it) and go to implementation (a method's
#    overrides, a class's derived classes) ──

proc cEngCppFiles(): seq[CxFile] =
  ## the project's C++ files and headers as the engine reads them (an open one as it is now) — four seconds at most
  ## the first time (each kept after, while it is unchanged)
  let t0 = getMonoTime()
  var seen: HashSet[string]
  for x in bufs:
    if x.path.len == 0 or x.path in seen or x.lang == nil or x.lang.id notin ["c", "cpp"] or not cxIsCppBuf(x): continue
    seen.incl x.path
    try: result.add cxFileOf(x)
    except CatchableError: discard
  if rootDir.len == 0: return
  for rel in projectFiles():
    if msSince(t0) > 4000 or result.len > 3000: break
    if not (cxIsCppPath(rel) or rel.endsWith(".h")): continue
    let full = if rel.isAbsolute: rel else: rootDir / rel
    if full in seen: continue
    seen.incl full
    try:
      let g = cxLoad(full, cpp = true)
      if g != nil: result.add g
    except CatchableError: discard

proc cEngClassItem(g: CxFile, s: CxSym, label: string): PickItem =
  PickItem(label: label, detail: relPath(g.path) & ":" & $(s.line + 1) & " · " & s.text, icon: "T", path: g.path,
           line: s.line, col: s.col)

proc cEngTypeHierarchy(b: Buffer): bool =
  ## C++: the class at the cursor (or a value's class): the classes it derives from, and those derived from it
  if not cEngineOn(b) or not cxIsCppBuf(b): return false
  var items: seq[PickItem]
  var here = -1
  var name = ""
  try:
    let p = b.primary.head
    let (g, cls) = cxxClassAt(cxFileOf(b), p.line, p.col)
    if g == nil: return false
    name = cls.name
    # (its bases, theirs above them: the farthest first)
    var ups: seq[(CxFile, CxSym, int)]
    var level = @[(g, cls)]
    var seen: HashSet[string]
    seen.incl cxxKey(cls)
    for depth in 1 .. 8:
      var next: seq[(CxFile, CxSym)]
      for (h, c) in level:
        for (h2, c2) in cxxBasesOf(h, c):
          if cxxKey(c2) in seen: continue
          seen.incl cxxKey(c2)
          next.add (h2, c2)
          ups.add (h2, c2, depth)
      if next.len == 0: break
      level = next
    var top = 0
    for (_, _, dp) in ups: top = max(top, dp)
    for k in countdown(ups.high, 0):
      items.add cEngClassItem(ups[k][0], ups[k][1], "↑ " & repeat("  ", top - ups[k][2]) & ups[k][1].name)
    here = items.len
    items.add cEngClassItem(g, cls, "• " & repeat("  ", top) & cls.name)
    for (h, d, depth) in cxxDerived(cEngCppFiles(), cls):
      items.add cEngClassItem(h, d, "↓ " & repeat("  ", top + depth) & d.name)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if items.len <= 1:
    info(name & " derives from nothing, and nothing in this project derives from it")
    return true
  openPicker(pickSymbol, "Type hierarchy — " & name & "  (↑ derives from · ↓ derived from it)", items)
  if here >= 0: pickSel = max(0, pickShown.find(here))
  true

proc cEngImplementations(b: Buffer): bool =
  ## C++: a method — the overrides of it in the classes derived from its class; a class — the classes derived from it
  if not cEngineOn(b) or not cxIsCppBuf(b): return false
  var items: seq[PickItem]
  var name = ""
  try:
    let f = cxFileOf(b)
    let p = b.primary.head
    let ts = cxTargets(f, p.line, p.col)
    if ts.len == 0: return false
    if ts[0][1].kind == cxMethod:
      let (m, ov) = cxxOverrides(cEngCppFiles(), f, p.line, p.col)
      if m.name.len == 0: return false
      name = m.name
      for (g, x) in ov:
        items.add PickItem(label: cxxNoArgs(cxxSplit(x.owner)[^1]) & "::" & x.name, detail: relPath(g.path) & ":" &
                           $(x.line + 1) & " · " & x.text, icon: "ƒ", path: g.path, line: x.line, col: x.col)
    else:
      let (g, cls) = cxxClassAt(f, p.line, p.col)
      if g == nil or ts[0][1].kind notin {cxClass, cxStruct, cxUnion, cxTypedef}: return false
      name = cls.name
      for (h, d, depth) in cxxDerived(cEngCppFiles(), cls):
        items.add cEngClassItem(h, d, repeat("  ", depth - 1) & d.name)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if items.len == 0:
    info("Nothing in this project overrides or derives from " & name)
    return true
  if items.len == 1:
    cEngJump(b, items[0].path, items[0].line, items[0].col, items[0].detail)
    return true
  openPicker(pickSymbol, "Implementations — " & name, items)
  true
