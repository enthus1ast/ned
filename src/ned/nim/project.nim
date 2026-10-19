# ════════════════════════════════════════════════════════════════════════════
#  Tools, nimble projects, scratch buffers
# ════════════════════════════════════════════════════════════════════════════

proc haveExe(name: string): bool =
  ## cached PATH lookup (findExe stats every PATH entry; this runs on hot paths)
  if name notin exeCache: exeCache[name] = findExe(name)
  exeCache[name].len > 0

proc resetExeCache() =
  exeCache.clear()

proc findNimbleFile(start: string): string =
  ## nearest *.nimble file in `start` or its parents
  var d = start
  for _ in 0 .. 12:
    try:
      for kind, p in walkDir(d):
        if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): return p
    except OSError: discard
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc nimStrings(s: string): seq[string] =
  ## all "double quoted" literals on a line
  var i = 0
  while i < s.len:
    if s[i] == '"':
      let e = s.find('"', i + 1)
      if e < 0: break
      result.add s[i + 1 ..< e]
      i = e + 1
    else: inc i

proc val(t: string): string =
  let q = nimStrings(t)
  if q.len > 0: q[0] else: ""

proc parseNimble(path: string): NimbleInfo =
  result.file = path
  result.dir = parentDir(path)
  result.name = splitFile(path).name
  var lines: seq[string]
  try: lines = readFile(path).splitLines
  except CatchableError: return
  var inRequires = false
  for raw in lines:
    let t = raw.strip
    if t.startsWith("#") or t.len == 0:
      inRequires = false
      continue
    let low = t.toLowerAscii
    if low.startsWith("version") and '=' in t: result.version = val(t)
    elif low.startsWith("author") and '=' in t: result.author = val(t)
    elif low.startsWith("description") and '=' in t: result.desc = val(t)
    elif low.startsWith("license") and '=' in t: result.license = val(t)
    elif low.startsWith("srcdir") and '=' in t: result.srcDir = val(t)
    elif low.startsWith("bin") and '=' in t:
      for b in nimStrings(t): result.bins.add b
    elif low.startsWith("namedbin"):
      for b in nimStrings(t): result.bins.add b
    elif low.startsWith("requires") or (inRequires and t.startsWith("\"")):
      for r in nimStrings(t): result.requires.add r
      inRequires = t.endsWith(",")
      continue
    elif low.startsWith("task "):
      let rest = t[5 .. ^1]
      let comma = rest.find(',')
      let nm = (if comma > 0: rest[0 ..< comma] else: rest.strip(chars = {':', ' '})).strip
      let d = nimStrings(rest)
      result.tasks.add (nm, (if d.len > 0: d[0] else: ""))
    inRequires = false

proc loadNimbleInfo(force = false) =
  let f = findNimbleFile(if buf().path.len > 0: parentDir(buf().path) else: rootDir)
  if f.len == 0:
    nimble = NimbleInfo()
    nimbleAt = ""
    return
  if f == nimbleAt and not force: return
  nimble = parseNimble(f)
  nimbleAt = f

proc nimMainModule(dir: string): string =
  ## the module the Nim project in `dir` is built from ("" = none found). Same order as nimble's
  ## entry points (srcDir/<pkg>.nim first), so nimlangserver never starts a second nimsuggest for it.
  if dir.len == 0 or not dirExists(dir): return ""
  var nf = ""
  var tops: seq[string]
  var cfgMain = ""
  try:
    for kind, p in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}: continue
      if p.endsWith(".nimble") and nf.len == 0: nf = p
      elif p.endsWith(".nims") and extractFilename(p) notin ["config.nims", "nimble.nims"]:
        if cfgMain.len == 0 and fileExists(p[0 ..< ^5] & ".nim"): cfgMain = p[0 ..< ^5] & ".nim"
      elif p.endsWith(".nim.cfg"):
        if cfgMain.len == 0 and fileExists(p[0 ..< ^4]): cfgMain = p[0 ..< ^4]
      elif p.endsWith(".nim"): tops.add p
  except OSError: discard
  if nf.len > 0:
    let info = parseNimble(nf)
    let src = if info.srcDir.len > 0: dir / info.srcDir else: dir
    var cands = @[src / info.name & ".nim"]
    for bin in info.bins:
      let bn = if bin.endsWith(".nim"): bin else: bin & ".nim"
      cands.add dir / bn
      cands.add src / bn
    for c in cands:
      if fileExists(c): return c.normalizedPath
  let base = extractFilename(dir)
  for c in [dir / base & ".nim", dir / "src" / base & ".nim", cfgMain, dir / "main.nim", dir / "src" / "main.nim"]:
    if c.len > 0 and fileExists(c): return c.normalizedPath
  if tops.len == 1: return tops[0]
  ""

var projFileMemo: Table[string, (string, MonoTime)]   # file → (its project's main module, when worked out)

proc nimProjectFile0(b: Buffer): string

proc nimProjectFile(b: Buffer): string =
  ## the module nimsuggest/the compiler should treat as project root for `b` (worked out again after 2 s: the engine
  ## asks for it on every question, and the .nimble is read from disk for it)
  let m = projFileMemo.getOrDefault(b.path, ("", MonoTime()))
  if m[0].len > 0 and msSince(m[1]) < 2000: return m[0]
  result = nimProjectFile0(b)
  if projFileMemo.len > 500: projFileMemo.clear()
  projFileMemo[b.path] = (result, getMonoTime())

proc nimProjectFile0(b: Buffer): string =
  let nf = findNimbleFile(parentDir(b.path))
  if nf.len > 0:
    let info = parseNimble(nf)
    let src = if info.srcDir.len > 0: info.dir / info.srcDir else: info.dir
    if b.path.startsWith(src & "/"):
      let m = nimMainModule(info.dir)
      if m.len > 0: return m
  let top = nxTopIncluder(b.path)                     # (a file another one includes: that module)
  if top.len > 0: return top
  b.path

func reEsc(s: string): string =
  ## escape a literal for nimlangserver's regex (fileRegex)
  for c in s:
    if c in {'.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\'}: result.add '\\'
    result.add c

var
  nlsRootMapped = false                 # the opened folder has its own main module: one rule covers it
  nlsProjects: seq[(string, string)]    # nimble projects inside the folder: (folder, main module), relative
  nlsLoose = ""                         # the loose file that serves every other loose .nim file

proc nimMapRebuild() =
  ## nimlangserver takes the first rule that matches: nested packages before their parents, loose files last
  var ps = nlsProjects
  ps.sort(proc(x, y: (string, string)): int = cmp(y[0].len, x[0].len))
  nlsAutoMap = newJArray()
  for (d, m) in ps:
    nlsAutoMap.add %*{"projectFile": m, "fileRegex": (if d.len == 0 or d == ".": ".*\\.nim$" else: "^" & reEsc(d) & "/.*\\.nim$")}
  if nlsLoose.len > 0: nlsAutoMap.add %*{"projectFile": nlsLoose, "fileRegex": ".*\\.nim$"}

proc nimMapAdd(b: Buffer): bool =
  ## give `b`'s project a rule if it has none yet (true = the mapping changed). A folder that holds several
  ## nimble packages and loose scripts (your home folder, say) gets one nimsuggest per package — a package
  ## file must never be served by a script's nimsuggest, or nothing in the package resolves.
  if nlsRootMapped or b == nil or not b.path.endsWith(".nim") or not b.path.startsWith(rootDir & "/"): return false
  let nf = findNimbleFile(parentDir(b.path))
  if nf.len > 0 and nf.startsWith(rootDir & "/"):
    let pdir = parentDir(nf)
    let m = nimMainModule(pdir)
    if m.len > 0:
      var relD, relM: string
      try:
        relD = relativePath(pdir, rootDir)
        relM = relativePath(m, rootDir)
      except CatchableError: return false
      for (d, _) in nlsProjects:
        if d == relD: return false
      nlsProjects.add (relD, relM)
      if nlsMain.len == 0: nlsMain = m
      nimMapRebuild()
      return true
  if nlsLoose.len > 0: return false
  try: nlsLoose = relativePath(b.path, rootDir)
  except CatchableError: return false
  if nlsMain.len == 0: nlsMain = b.path
  nimMapRebuild()
  true

proc prepareNimMapping(b: Buffer) =
  ## Decides, before nimlangserver starts, which module each .nim file is checked with — ONE nimsuggest per
  ## project. Without a mapping nimlangserver guesses a project per file (older versions start a nimsuggest
  ## for each file you open; newer ones pin whichever opened first). Modern nimsuggest answers for files
  ## outside the project's import graph too (tests, examples), so one process serves a whole project.
  nlsAutoMap = newJArray()
  nlsMain = ""
  nlsProjects.setLen(0)
  nlsLoose = ""
  nlsRootMapped = false
  var main = ""
  let ps = sStr("nim.projectFile")
  if ps.len > 0:
    let p = if ps.isAbsolute: ps else: rootDir / ps
    if fileExists(p): main = p.normalizedPath
    else: warn("nim.projectFile: " & ps & " does not exist — detecting the main module instead")
  if main.len == 0:
    main = nimMainModule(rootDir)
    var rootIsPackage = false
    try:
      for kind, f in walkDir(rootDir):
        if kind in {pcFile, pcLinkToFile} and f.endsWith(".nimble"): rootIsPackage = true
    except OSError: discard
    if main.len > 0 and not rootIsPackage:
      # a folder that is not a package (scripts, your home folder) whose main module was only guessed: it
      # serves the loose files, and each nimble package inside still gets its own nimsuggest (nimMapAdd)
      nlsMain = main
      try: nlsLoose = relativePath(main, rootDir)
      except CatchableError: nlsLoose = main
      nimMapRebuild()
      discard nimMapAdd(b)
      return
  var insideProject = false
  if main.len == 0:
    # the folder is part of a package (you opened its src/, say): the package's main module serves it all
    let nf = findNimbleFile(rootDir)
    if nf.len > 0 and not nf.startsWith(rootDir & "/"):
      main = nimMainModule(parentDir(nf))
      insideProject = main.len > 0
  if main.len == 0:
    # several packages and/or loose scripts: rules are added per project as files open (nimMapAdd)
    discard nimMapAdd(b)
    return
  nlsRootMapped = true
  nlsMain = main
  var rel = main
  try: rel = relativePath(main, rootDir)
  except CatchableError: discard
  # the project's own sources go to the main module. Tests and examples are separate programs:
  # they stay unmapped, so with nim.maxNimsuggestProcesses = 1 (the default) they share the same
  # process, and with 2+ nimlangserver may give them their own for full answers there.
  let mainDir = parentDir(rel)
  var rx = ""
  if insideProject or rel.startsWith("../"):
    rx = ".*\\.nim$"
  elif mainDir.len > 0 and mainDir != ".":
    rx = "^" & reEsc(mainDir) & "/.*\\.nim$"
  else:
    var subs: seq[string]
    try:
      for kind, p in walkDir(rootDir):
        let n = extractFilename(p)
        if kind == pcDir and not n.startsWith(".") and
           n notin ["tests", "test", "examples", "example", "bench", "benchmarks", "docs", "htmldocs", "nimcache",
                    "nimbledeps", "deps", "vendor"]:
          subs.add reEsc(n)
    except OSError: discard
    rx = if subs.len > 0: "^([^/]*|(" & subs.join("|") & ")/.*)\\.nim$" else: "^[^/]*\\.nim$"
  nlsAutoMap.add %*{"projectFile": rel, "fileRegex": rx}

proc openScratch(title, content: string, lang: Lang): Buffer =
  ## read-only virtual buffer (macro expansions, ARC output, diffs, …); reused by title
  for i, x in bufs:
    if x.title == title:
      x.setContent(content)
      x.lang = lang
      x.undoStack.setLen(0)
      x.redoStack.setLen(0)
      x.savedSeq = 0
      x.setSingle(Pos())
      x.topLine = 0
      x.topSub = 0
      curBuf = i
      focus = fEditor
      return x
  let b = newBuffer()
  b.title = title
  b.lang = lang
  b.setContent(content)
  b.readOnly = true
  b.indent = "  "
  if bufs.len == 1 and bufs[0].path.len == 0 and bufs[0].title.len == 0 and not bufs[0].dirty and
     bufs[0].lines == @[""]:
    bufs[0] = b
    curBuf = 0
  else:
    bufs.add b
    curBuf = bufs.high
  focus = fEditor
  needRender = true
  b

proc unquoteNim(s: string): string =
  ## decodes a Nim string literal as printed by nimsuggest ("…\x0A…")
  var t = s
  if t.len >= 2 and t[0] == '"' and t[^1] == '"': t = t[1 .. ^2]
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len:
      let c = t[i + 1]
      case c
      of 'n': result.add '\n'; i += 2
      of 't': result.add '\t'; i += 2
      of 'r': i += 2
      of '\\', '"', '\'': result.add c; i += 2
      of 'x':
        if i + 3 < t.len:
          try: result.add chr(parseHexInt(t[i + 2 .. i + 3]))
          except ValueError: discard
          i += 4
        else: i += 2
      else:
        result.add c
        i += 2
    else:
      result.add t[i]
      inc i

func enclosingProc(b: Buffer): string =
  ## name of the proc/func/method/iterator surrounding the cursor
  let ln = b.primary.head.line
  for l in countdown(ln, max(0, ln - 3000)):
    let t = b.lines[l].strip(trailing = false)
    for kw in ["proc ", "func ", "method ", "iterator ", "converter ", "template ", "macro "]:
      if t.startsWith(kw):
        var k = kw.len
        while k < t.len and t[k] == ' ': inc k
        var e = k
        if k < t.len and t[k] == '`':
          e = t.find('`', k + 1)
          if e < 0: return ""
          return t[k + 1 ..< e]
        while e < t.len and isWordByte(t[e]): inc e
        return t[k ..< e]
  ""
