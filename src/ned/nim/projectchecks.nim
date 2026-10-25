# ── the project's own checks: a package imported that the .nimble does not require (a quick fix adds the line), a
#    requirement nothing imports, exported routines nothing in the project uses (programs only), and the .nimble
#    itself — its requires, the fields `nimble publish` needs, srcDir and bin, versions installed, the Nim it asks
#    for. Rules (.ned/lint.json): import-not-required, require-unused, unused-export, nimble ──

type PcRequire = object
  line, col, ecol: int                 # where its string is in the .nimble
  text: string                         # as written: "jsony >= 1.1"
  name: string                         # lower case
  cons: string                         # ">= 1.1" ("" any)
  feature: string                      # inside `feature "x":` (or `dev:`): that feature's — not the package's own

func pcNorm(name: string): string =
  ## a package's name as nimble compares them (case and - _ aside)
  for c in name:
    if c notin {'-', '_'}: result.add toLowerAscii(c)

proc pcRequires(lines: openArray[string]): seq[PcRequire] =
  ## the .nimble's `requires` strings, where they are (`requires "a", "b"`, `requires(` over several lines);
  ## taskRequires and feature requires are not the package's own
  var inReq = false
  var depth = 0
  var feature = ""                     # (the `feature "x":` / `dev:` block the lines are in)
  for l, raw in lines:
    let t = raw.strip
    if t.len == 0 or t.startsWith("#"):
      if depth == 0: inReq = false
      continue
    if raw[0] notin {' ', '\t'} and depth == 0 and not inReq:
      feature = ""
      if t.startsWith("feature") and t.endsWith(":"):
        let q1 = t.find('"')
        let q2 = if q1 >= 0: t.find('"', q1 + 1) else: -1
        feature = if q2 > q1: t[q1 + 1 ..< q2] else: "?"
      elif t == "dev:": feature = "dev"
    let k = raw.find("requires")
    let starts = k >= 0 and (k == 0 or raw[k - 1] in {' ', '\t'}) and k + 8 < raw.len and raw[k + 8] in {' ', '('} and
                 raw[0 ..< k].strip.len == 0
    if not (starts or (inReq and (t.startsWith("\"") or t.startsWith(")")))):
      inReq = false
      depth = 0
      continue
    var i = if starts: k + 8 else: 0
    while i < raw.len:
      if raw[i] == '#': break
      if raw[i] == '"':
        let e = raw.find('"', i + 1)
        if e < 0: break
        let txt = raw[i + 1 ..< e]
        let (nm, cons) = nxSplitRequire(txt)
        result.add PcRequire(line: l, col: i + 1, ecol: e, text: txt, name: nm.toLowerAscii, cons: cons,
                             feature: (if raw.len > 0 and raw[0] in {' ', '\t'}: feature else: ""))
        i = e + 1
      else:
        if raw[i] == '(': inc depth
        elif raw[i] == ')': depth = max(0, depth - 1)
        inc i
    inReq = t.endsWith(",") or depth > 0

proc pcNimbleLines(nb: string): seq[string] =
  let i = bufIndexByPath(nb)
  if i >= 0: return bufs[i].lines
  try: readFile(nb).splitLines except CatchableError: @[]

proc pcResolveDiags(nb: string, expl: seq[string]): seq[Diag] =
  ## nimble's explanation of why the dependencies cannot be resolved, on the requires lines it is about: the
  ## package's own "<name> depends on <pkg> …" (0.26, PubGrub's prose), the "+ pkg >= x" of 0.24's minimal set
  let lines = pcNimbleLines(nb)
  let reqs = pcRequires(lines)
  let root = pcNorm(splitFile(nb).name)
  let msg = "nimble cannot resolve the dependencies: " & expl.join(" ")
  var named: seq[string]
  for x in expl:
    if x.startsWith("+ "):
      let w = x[2 .. ^1].strip.splitWhitespace
      if w.len > 0: named.add pcNorm(w[0])
      continue
    var k = x.find(" depends on ")
    while k >= 0:
      var a = k
      while a > 0 and x[a - 1] notin {' ', ','}: dec a
      let subject = pcNorm(x[a ..< k])
      let rest = x[k + 12 .. ^1].splitWhitespace
      if rest.len > 0 and subject == root: named.add pcNorm(rest[0].strip(chars = {',', '.'}))
      k = x.find(" depends on ", k + 12)
  if named.len == 0:
    # (worded otherwise: the requires it names at all)
    let words = expl.join(" ").multiReplace([(",", " "), (".", " "), ("(", " "), (")", " ")]).splitWhitespace
    var ws: HashSet[string]
    for w in words: ws.incl pcNorm(w)
    for r in reqs:
      if r.feature.len == 0 and pcNorm(r.name) in ws: named.add pcNorm(r.name)
  for r in reqs:
    if r.feature.len == 0 and pcNorm(r.name) in named:
      result.add Diag(line: r.line, col: r.col, eline: r.line, ecol: r.ecol, sev: 1, msg: msg, src: "nimble",
                      rule: "nimble")
  if result.len == 0 and lines.len > 0:
    result.add Diag(line: 0, col: 0, eline: 0, ecol: lines[0].len, sev: 1, msg: msg, src: "nimble", rule: "nimble")

proc pcPackageOf(path: string): seq[string] =
  ## the nimble package a file belongs to — its folder's name and its .nimble's ("" none: not an installed
  ## package of nimble's pkgs2/pkgs, here or in a project's nimbledeps — a folder of yours merely called so is not)
  if not nxIsPkgPath(path): return
  for marker in ["/pkgs2/", "/pkgs/"]:
    let k = path.rfind(marker)
    if k < 0: continue
    let rest = path[k + marker.len .. ^1]
    let s = rest.find('/')
    if s <= 0: continue
    let dir = path[0 ..< k + marker.len] & rest[0 ..< s]
    let (nm, _) = nxPkgSplit(rest[0 ..< s])
    result.add pcNorm(nm)
    try:
      for kind, p in walkDir(dir):
        if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): result.add pcNorm(splitFile(p).name)
    except OSError: discard
    return

proc pcImportsNotRequired*(f: NxFile, b: Buffer, code: seq[string]): seq[Diag] =
  ## `import jsony` resolved to an installed package that the project's .nimble does not require: it builds here,
  ## but not for whoever installs the package
  if f == nil or b.path.len == 0 or nxIsPkgPath(b.path) or isLibraryFile(b.path): return
  let nb = findNimbleFile(parentDir(b.path))
  if nb.len == 0: return
  var reqs: HashSet[string]
  for r in pcRequires(pcNimbleLines(nb)): reqs.incl pcNorm(r.name)
  let own = pcNorm(splitFile(nb).name)
  var said: HashSet[string]
  for im in f.imports:
    if im.isInclude or im.line < 0 or im.line >= code.len: continue
    let p = nxResolve(f.path, im.spec)
    if p.len == 0: continue
    let pk = pcPackageOf(p)
    if pk.len == 0: continue
    var known = false
    for x in pk:
      if x in reqs or x == own: known = true
    if known or pk[0] in said: continue
    said.incl pk[0]
    let s = code[im.line]
    let last = im.spec.split('/')[^1]
    var c = s.find(last)
    if c < 0: c = 0
    var nm = pk[0]
    let (dn, _) = nxPkgSplit(extractFilename(parentDir(p)))
    if dn.len > 0 and pcNorm(dn) == pk[0]: nm = dn
    result.add Diag(line: im.line, col: c, eline: im.line, ecol: c + last.len, sev: 2, src: "ned",
                    rule: "import-not-required",
                    msg: "'" & nm & "' is imported but " & extractFilename(nb) & " does not require it")

proc pcAddRequireTo(b: Buffer, nb, pkg: string) =
  ## `requires "pkg >= <the version this project builds with>"` added to a .nimble's text, after its last requires
  let d = engineDepOf(parentDir(nb), pkg)
  let req = "requires \"" & pkg & (if d.version.len > 0 and d.version[0] in Digits: " >= " & d.version else: "") & "\""
  var at = -1
  for r in pcRequires(b.lines): at = max(at, r.line)
  if at >= 0:
    # (the end of that statement: a requires( … ) over several lines ends at its `)`)
    var e = at
    while e + 1 < b.lines.len and b.lines[e].strip.endsWith(","): inc e
    discard b.replaceText(Pos(line: e, col: b.lines[e].len), Pos(line: e, col: b.lines[e].len), "\n" & req)
  else:
    let n = b.lines.len
    let tail = if n > 0 and b.lines[n - 1].len == 0: n - 1 else: n
    if tail > 0 and tail - 1 < b.lines.len:
      discard b.replaceText(Pos(line: tail - 1, col: b.lines[tail - 1].len), Pos(line: tail - 1, col: b.lines[tail - 1].len),
                            "\n\n" & req)
    else: discard b.replaceText(Pos(line: 0, col: 0), Pos(line: 0, col: 0), req & "\n")

proc pcAddRequire*(nb, pkg: string): bool =
  ## the same in the .nimble's buffer (opened) — you save it
  let b = loadBuffer(nb)
  if b == nil or not b.canEdit(): return false
  b.beginEdit()
  pcAddRequireTo(b, nb, pkg)
  b.endEdit()
  true

proc pcConsOk(cons: string): bool =
  ## a version requirement nimble reads: >= 1.2 · ^= 1.2 · ~= 1.2.3 · == 1.2.3 · 1.2 & < 2.0 · #head · @#tag
  let c = cons.strip
  if c.len == 0 or c.startsWith("#") or c.startsWith("@"): return true
  for part in c.split('&'):
    let p = part.strip
    var q = 0
    while q < p.len and p[q] in {'>', '<', '=', '^', '~'}: inc q
    let op = p[0 ..< q]
    let v = p[q .. ^1].strip
    if op notin ["", ">=", "<=", ">", "<", "==", "^=", "~="] or v.len == 0 or nxVerKey(v).len == 0: return false
  true

proc pcNimbleChecks*(b: Buffer): seq[Diag] =
  ## a .nimble file's own problems
  if b == nil or not b.path.endsWith(".nimble") or nxIsPkgPath(b.path) or isLibraryFile(b.path): return
  result.add pnakUnpinned(b.path, b.lines)          # (a Nim 3 project's pnak.nif: what it does not pin)
  let dir = parentDir(b.path)
  var fields: Table[string, (int, string)]
  for l, raw in b.lines:
    let t = raw.strip
    let eq = t.find('=')
    if eq <= 0 or t.startsWith("#"): continue
    let k = t[0 ..< eq].strip
    if k notin ["version", "author", "description", "license", "srcDir", "bin", "binDir", "installDirs"]: continue
    if raw.len > 0 and raw[0] in {' ', '\t'}: continue                    # (inside a task or a when)
    fields[k] = (l, t[eq + 1 .. ^1].strip)
  template add(l, c, e: int, sv: int, m: string) =
    result.add Diag(line: l, col: c, eline: l, ecol: e, sev: sv, src: "ned", rule: "nimble", msg: m)
  # (the fields `nimble publish` and nimble's own check want)
  var missing: seq[string]
  for k in ["version", "author", "description", "license"]:
    if k notin fields: missing.add k
  if missing.len > 0:
    add(0, 0, (if b.lines.len > 0: b.lines[0].len else: 0), 3,
        "no " & missing.join(", ") & " — nimble check and nimble publish want " & (if missing.len == 1: "it" else: "them"))
  if "srcDir" in fields:
    let (l, v) = fields["srcDir"]
    let sd = v.strip(chars = {'"', ' '})
    if sd.len > 0 and not dirExists(dir / sd):
      add(l, 0, b.lines[l].len, 2, "srcDir \"" & sd & "\" is not a folder here")
  if "bin" in fields:
    let (l, v) = fields["bin"]
    let sd = if "srcDir" in fields: fields["srcDir"][1].strip(chars = {'"', ' '}) else: ""
    var k = v.find('"')
    while k >= 0:
      let e = v.find('"', k + 1)
      if e < 0: break
      let name = v[k + 1 ..< e]
      let src = (if sd.len > 0: dir / sd else: dir) / name & ".nim"
      if name.len > 0 and not fileExists(src) and not fileExists(dir / name & ".nim"):
        let c = b.lines[l].find("\"" & name & "\"")
        add(l, max(0, c), max(0, c) + name.len + 2, 2, "bin \"" & name & "\": no " &
            relativePath(src, dir) & " to build it from")
      k = v.find('"', e + 1)
  # (the requirements: written right, met by something installed, not twice, the Nim one met by the Nim in use)
  var seen: Table[string, int]
  for r in pcRequires(b.lines):
    if r.name.len == 0:
      add(r.line, r.col, r.ecol, 2, "requires \"" & r.text & "\": no package name")
      continue
    let cons = r.cons.strip
    if not pcConsOk(cons):
      if (r.feature & "\0" & pcNorm(r.name)) notin seen: seen[r.feature & "\0" & pcNorm(r.name)] = r.line
      add(r.line, r.col, r.ecol, 2, "requires \"" & r.text & "\": not a version nimble reads (>= 1.2 · ^= 1.2 · " &
          "~= 1.2.3 · == 1.2.3 · 1.2 & < 2.0 · #head)")
      continue
    # (twice among the package's own, or twice in one feature — a feature may ask for more of a package)
    let key = r.feature & "\0" & pcNorm(r.name)
    if key in seen:
      add(r.line, r.col, r.ecol, 2, "'" & r.name & "' is required twice (also line " & $(seen[key] + 1) & ")")
    else: seen[key] = r.line
    if r.name == "nim":
      if tcVer.len > 0 and cons.len > 0 and not nxSatisfies(tcVerText(tcVer), cons):
        add(r.line, r.col, r.ecol, 2, "requires nim " & cons & " — the Nim in use is " & tcVerText(tcVer) &
            " (Nim › choose the Nim for this project)")
      continue
    if "://" in r.name or r.name.startsWith("git@"): continue
    if nxInstalled.getOrDefault(r.name.toLowerAscii).len == 0 and nbPackageKnown(r.name) == 0:
      # (a name nimble's package lists do not have — a typo, mostly: nimble install would not find it)
      var names: seq[string]
      for (n, _) in nbPackageList(): names.add n
      let near = closest(r.name, names)
      add(r.line, r.col, r.ecol, 2, "'" & r.name & "' is not in nimble's package list" &
          (if near.len > 0: " — '" & near & "'?" else: " (a URL, or `nimble refresh`)"))
      continue
    let inst = nxInstalled.getOrDefault(r.name)
    if inst.len == 0 and cons.len > 0 and not cons.startsWith("#"):
      continue                                  # (not installed at all: nimble install says so; no noise here)
    if inst.len > 0 and cons.len > 0 and not cons.startsWith("#"):
      var ok = false
      var vs: seq[string]
      for it in inst:
        if it.ver.len > 0: vs.add it.ver
        if nxSatisfies(it.ver, cons): ok = true
      if not ok and vs.len > 0:
        add(r.line, r.col, r.ecol, 2, "no installed version of " & r.name & " meets " & cons & " (installed: " &
            vs.join(", ") & ") — nimble install")

proc pcRequireUnused*(nb: string, imported: HashSet[string]): seq[Diag] =
  ## a requirement nothing of the project imports (`imported`: the packages its files import, pcNorm'd)
  let lines = pcNimbleLines(nb)
  var seen: HashSet[string]
  for r in pcRequires(lines):
    if r.name.len == 0 or r.name == "nim" or "://" in r.name or r.name.startsWith("git@") or not pcConsOk(r.cons) or
       r.feature.len > 0:
      continue
    if pcNorm(r.name) in imported or pcNorm(r.name) in seen: continue
    seen.incl pcNorm(r.name)
    result.add Diag(line: r.line, col: r.col, eline: r.line, ecol: r.ecol, sev: 4, src: "ned", rule: "require-unused",
                    msg: "nothing in the project imports '" & r.name & "' (a tool or a task's may still need it)")

proc lintProjectChecks(files: Table[string, Buffer], nimbles: seq[string]): seq[(string, Diag)] =
  ## ned --lint over a project: the .nimble's checks, requirements nothing imports and — for a program (bin) —
  ## exported routines nothing uses. What the project imports and uses is read from all its files, the ones not
  ## checked (some given, --staged, left out by .ned/lint.json) from disk; only the checked ones get problems.
  for nb in nimbles:
    let dir = parentDir(nb)
    let nbb = newBuffer()
    nbb.path = nb
    nbb.lines = pcNimbleLines(nb)
    if nbb.lines.len == 0: continue
    var ds = pcNimbleChecks(nbb)
    # (the project's files: what they import, what they declare and use)
    var imported: HashSet[string]
    var used: CountTable[string]
    var exportsOf: seq[(string, NxSym)]
    var inProject = 0
    var all: seq[(string, Buffer)]
    for path, b in files:
      if path.startsWith(dir & "/"):
        all.add (path, b)
        inc inProject
    if inProject > 0:
      for p in fmtAllFiles(dir):
        if not p.endsWith(".nim") or p in files or nxIsPkgPath(p): continue
        let eb = newBuffer()
        eb.path = p
        try: eb.lines = readFile(p).splitLines
        except CatchableError: continue
        all.add (p, eb)
    for (path, b) in all:
      let f = try: nxFileFor(b) except CatchableError: nil
      if f == nil: continue
      var inTriple = false
      var inComment = 0
      var inBraces: Table[string, int]             # (names a format string interpolates: fmt"{helper()}")
      for l in b.lines: ecBraceNames(l, inBraces)
      for nm, n in inBraces: used.inc(nm, n)
      for l in b.lines:
        let c = ecCodeOnly(l, inTriple, inComment)
        var k = 0
        while k < c.len:
          if nxIsIdent(c[k]) and (k == 0 or not nxIsIdent(c[k - 1])) and c[k] notin {'0'..'9'}:
            var e = k
            while e < c.len and nxIsIdent(c[e]): inc e
            used.inc nxNorm(c[k ..< e])
            k = e
          else: inc k
      for im in f.imports:
        if im.isInclude: continue
        let p = nxResolve(f.path, im.spec)
        let pk = if p.len > 0: pcPackageOf(p) else: @[]
        if pk.len > 0:
          for x in pk: imported.incl x
        else:
          # (not installed here: its first path part — `pkg/jsony`, `jsony/x`)
          var first = im.spec.strip(chars = {'"'})
          if first.startsWith("pkg/"): first = first[4 .. ^1]
          if not first.startsWith(".") and "/" in first: first = first.split('/')[0]
          if not first.startsWith("."): imported.incl pcNorm(first)
      if path notin files: continue                # (read for what it uses; its own problems are not asked for)
      for sy in f.syms:
        if sy.exported and not sy.made and sy.kind in {nxProc, nxFunc, nxIterator, nxTemplate, nxMacro}:
          exportsOf.add (path, sy)
    if inProject > 0:                              # (the project's files checked too: what they import)
      for d in pcRequireUnused(nb, imported): ds.add d
    lintApply(nb, nbb.lines, ds)
    for d in ds: result.add (nb, d)
    if inProject == 0: continue
    # (a program's exported routines nothing uses: not for a library, whose users are elsewhere)
    var isProgram = false
    for l in nbb.lines:
      let t = l.strip
      if (t.startsWith("bin") and t[3 .. ^1].strip.startsWith("=")) or t.startsWith("bin.add") or
         t.startsWith("bin &=") or t.startsWith("namedBin"): isProgram = true
    if not isProgram: continue
    for (path, sy) in exportsOf:
      let key = nxNorm(sy.name)
      if used.getOrDefault(key) > 1: continue                    # (its declaration, and one use at least)
      if sy.name.len == 0 or not nxIsIdent(sy.name[0]) or sy.name.startsWith("=") or sy.name == "main": continue
      let pr = sy.pragmas.toLowerAscii
      if "exportc" in pr or "dynlib" in pr or "used" in pr or "importc" in pr: continue
      let b = files[path]
      let col = max(0, b.lines[sy.line].find(sy.name))
      var ds2 = @[Diag(line: sy.line, col: col, eline: sy.line, ecol: col + sy.name.len, sev: 4, src: "ned",
                       rule: "unused-export",
                       msg: "'" & sy.name & "' is exported but nothing in the project uses it")]
      lintApply(path, b.lines, ds2)
      for d in ds2: result.add (path, d)
