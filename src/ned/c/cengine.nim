# ── C files with ned's own engine (c.engine): completion — struct members after `.` and `->` too —, hover with the
#    comment that documents a declaration, F12 through #includes, references and rename, the outline, signature
#    help, the C compiler's errors while you type, and a missing #include added. No clangd needed ──

proc cEngineOn(b: Buffer): bool =
  ## does ned's own C engine answer for this file? (c.engine: auto — when clangd is not installed —, builtin, both)
  b != nil and b.lang != nil and b.lang.id == "c" and b.path.len > 0 and not b.largeOn and b.lines.len < 200_000 and
    (cfgCEngine in ["builtin", "both"] or (cfgCEngine == "auto" and not haveExe("clangd")))

var cxDirsKey = ""

proc cxSetDirs(b: Buffer) =
  ## where #include looks: the file's folder, the project's include folders (and compile_commands.json's -I),
  ## then the C compiler's own
  let key = rootDir & "|" & parentDir(b.path)
  if key == cxDirsKey and cxDirs.len > 0: return
  cxDirsKey = key
  var ds: seq[string]
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
            inc k
          if ds.len > 40: break
      except CatchableError: discard
  for v in [getEnv("C_INCLUDE_PATH"), getEnv("CPATH")]:
    for d in v.split(':'): add d
  for d in cSystemIncludeDirs(): add d
  cxDirs = ds

proc cxFileOf(b: Buffer): CxFile =
  ## this buffer's index (its unsaved text)
  cxSetDirs(b)
  cxLoad(b.path, b.allText & "\n", "buf:" & $b.id & ":" & $b.changeId)

proc cxKindIcon(k: CxKind): int =
  ## the completion list's icon (LSP's numbers)
  case k
  of cxFunc: 3
  of cxField: 5
  of cxVar, cxParam, cxLocal: 6
  of cxStruct, cxUnion: 22
  of cxEnum: 13
  of cxEnumConst: 20
  of cxTypedef: 7
  of cxMacro: 15

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
  var out0: seq[CompItem]
  for it in items:
    out0.add CompItem(label: it.label, insert: it.label, detail: it.detail, kind: cxKindIcon(it.kind),
                      filter: it.label, sortText: $it.rank & it.label, rank: it.rank,
                      doc: (if it.detail.len > 0: "```c\n" & it.detail & "\n```\n" else: "") & it.doc, docMade: true)
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
  try: ts = cxTargets(cxFileOf(b), p.line, p.col)
  except CatchableError as e:
    internalError("C engine", e)
    return false
  if ts.len == 0:
    # a function declared in a header and defined in another .c file of the project
    return false
  var (g, s) = ts[0]
  if s.kind == cxFunc and not s.isDef and rootDir.len > 0:
    for f in projectFiles():
      if not f.endsWith(".c"): continue
      let full = if f.isAbsolute: f else: rootDir / f
      let h = cxLoad(full)
      if h == nil: continue
      var found = false
      for x in h.syms:
        if x.name == s.name and x.kind == cxFunc and x.isDef:
          (g, s) = (h, x)
          found = true
          break
      if found: break
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
  if w in CxKeywords: return (@[], w & " is a C keyword")
  if ts.len > 0 and ts[0][1].kind in {cxLocal, cxParam}:
    let s = ts[0][1]
    var lo = s.scopeA
    if s.kind == cxParam:
      for x in f.syms:
        if x.kind == cxFunc and x.name == s.owner and x.isDef: lo = x.line
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
      if not (f2.endsWith(".c") or f2.endsWith(".h")): continue
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
  if nn in CxKeywords:
    warn("'" & nn & "' is a C keyword")
    return true
  try:
    let f = cxFileOf(b)
    let ts = cxTargets(f, p.line, p.col)
    if ts.len > 0 and ts[0][1].kind notin {cxLocal, cxParam} and
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
  var lbl = (if s.kind == cxMacro: "#define " else: s.typ & " ") & s.name & "("
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

proc cEngOutline(b: Buffer): seq[SideItem] =
  if not cEngineOn(b): return
  try:
    let f = cxFileOf(b)
    for s in cxOutline(f):
      let icon = case s.kind
        of cxFunc: "ƒ"
        of cxStruct, cxUnion, cxEnum, cxTypedef: "T"
        of cxMacro: "#"
        else: "v"
      result.add SideItem(text: s.name, detail: (if s.kind == cxFunc: s.text else: s.typ), path: b.path,
                          line: s.line, col: s.col, depth: 0, icon: icon,
                          role: (if s.kind == cxFunc: 7 elif s.kind in {cxStruct, cxUnion, cxEnum, cxTypedef}: 8 else: 0))
      if s.kind in {cxStruct, cxUnion}:
        for x in f.syms:
          if x.kind == cxField and x.owner == s.name:
            result.add SideItem(text: x.name, detail: x.typ, path: b.path, line: x.line, col: x.col, depth: 1,
                                icon: "v", role: 0)
  except CatchableError as e: internalError("C engine", e)

# ── errors while you type: the C compiler on the unsaved text (a private copy, removed after) ──

var cTypingChecks: Table[string, (int, string)]      # path → (changeId checked, the copy)

proc cTypingCheck(b: Buffer) =
  if b.path in cTypingChecks or not haveExe("cc"): return
  let id = b.changeId
  let copy = privTmp("ctyping") & ".c"
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
  discard startJob(jkCheck, "cc -fsyntax-only -Wall -fdiagnostics-color=never" & inc & " -x c - < " & quoteShell(copy),
                   parentDir(path), proc(j: Job) =
    cTypingChecks.del path
    try: removeFile(copy)
    except CatchableError: discard
    let x = bufById(bid)
    if x == nil or x.changeId != id: return
    var ds: seq[Diag]
    for raw in j.output.splitLines:
      var t = stripAnsi(raw)
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
      if sev == 0 or sev == 3: continue
      ds.add Diag(line: max(0, l), col: max(0, c), eline: max(0, l), ecol: -1, sev: sev, msg: rest, src: "cc")
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
  let a = m.find({'\'', '`'})
  if a < 0: return
  var e = a + 1
  while e < m.len and m[e] notin {'\'', '`'}: inc e
  let name = m[a + 1 ..< e]
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
