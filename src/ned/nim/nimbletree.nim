# ── Nimble: the dependency tree — what the project requires, what that requires in turn, and what is installed ──

type DepPkg = object
  name, version, dir, nimble: string
  ver: seq[int]

proc depVer(s: string): seq[int] =
  for part in s.strip(chars = {'v', ' '}).split('.'):
    var d = ""
    for c in part:
      if c in Digits: d.add c
      else: break
    if d.len == 0: break
    try: result.add parseInt(d)
    except ValueError: break

proc depCmp(a, b: seq[int]): int =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return cmp(x, y)
  0

proc depSatisfies(v: seq[int], cons: string): bool =
  ## nimble's version rules: >= 1.2 · > · <= · < · == · 1.2 (exact) · ^= 1.2 (same major) · ~= 1.2.3 (same
  ## minor) · several joined by & · #head, #tag (any version counts)
  let c = cons.strip
  if c.len == 0 or c.startsWith("#") or c == "any version" or c == "*": return true
  if v.len == 0: return true                       # a version we cannot read: not held against it
  for part0 in c.split('&'):
    let part = part0.strip
    if part.len == 0: continue
    var op = ""
    var k = 0
    while k < part.len and part[k] in {'>', '<', '=', '^', '~', '@'}: inc k
    op = part[0 ..< k]
    let want = depVer(part[k .. ^1])
    if want.len == 0: continue
    let d = depCmp(v, want)
    let ok = case op
      of ">=": d >= 0
      of ">": d > 0
      of "<=": d <= 0
      of "<": d < 0
      of "", "==", "@": d == 0
      of "^=": d >= 0 and v.len > 0 and want.len > 0 and
               (if want[0] > 0: v[0] == want[0] else: v.len > 1 and want.len > 1 and v[1] == want[1])
      of "~=":
        var same = true
        for i in 0 ..< max(1, want.len - 1):
          if i >= v.len or i >= want.len or v[i] != want[i]: same = false
        d >= 0 and same
      else: true
    if not ok: return false
  true

proc depSplit(spec: string): (string, string) =
  ## "chronos >= 4.0" → ("chronos", ">= 4.0"); a URL requirement → its repository's name
  let t = spec.strip
  var k = 0
  while k < t.len and t[k] notin {' ', '>', '<', '=', '#', '@', '~', '^'}: inc k
  var nm = t[0 ..< k]
  if "://" in nm or nm.startsWith("git@"):
    nm = nm.strip(chars = {'/'}).split('/')[^1]
    if nm.endsWith(".git"): nm.setLen(nm.len - 4)
  (nm, t[k .. ^1].strip)

proc depRoots(): seq[string] =
  ## the folders nimble (and atlas) install packages in: the project's own first
  for d in [rootDir / "nimbledeps" / "pkgs2", rootDir / "nimbledeps" / "pkgs", rootDir / "deps", rootDir / "vendor"]:
    if dirExists(d): result.add d
  let nd = getEnv("NIMBLE_DIR")
  if nd.len > 0:
    for d in [nd / "pkgs2", nd / "pkgs"]:
      if dirExists(d) and d notin result: result.add d
  for d in nxDumpLazy:
    if dirExists(d) and d notin result: result.add d
  for d in [getHomeDir() / ".nimble" / "pkgs2", getHomeDir() / ".nimble" / "pkgs"]:
    if dirExists(d) and d notin result: result.add d

proc depInstalled(): Table[string, seq[DepPkg]] =
  ## every installed package version: pkgs2/name-1.2.3-<checksum>, pkgs/name-1.2.3, atlas's deps/name
  for root in depRoots():
    try:
      for kind, d in walkDir(root):
        if kind notin {pcDir, pcLinkToDir}: continue
        let base = extractFilename(d)
        var nm = base
        var ver = ""
        let parts = base.split('-')
        if parts.len >= 2:
          var vi = -1
          for i in 1 ..< parts.len:
            if parts[i].len > 0 and (parts[i][0] in Digits or parts[i][0] == '#'):
              vi = i
              break
          if vi > 0:
            nm = parts[0 ..< vi].join("-")
            ver = parts[vi]
        var nf = ""
        try:
          for k2, f in walkDir(d):
            if k2 in {pcFile, pcLinkToFile} and f.endsWith(".nimble"):
              nf = f
              break
        except OSError: discard
        if ver.len == 0 and nf.len > 0: ver = parseNimble(nf).version
        result.mgetOrPut(nm.toLowerAscii, @[]).add DepPkg(name: nm, version: ver, dir: d, nimble: nf, ver: depVer(ver))
    except OSError: discard

proc depNimVersion(): string =
  ## the Nim compiler's version, from its standard library
  let lib = if nxLibDir.len > 0: nxLibDir else: nxGuessLib()
  if lib.len == 0: return ""
  var maj, mnr, pat = ""
  for f in [lib / "system" / "compilation.nim", lib / "system.nim"]:
    if not fileExists(f): continue
    try:
      for l in lines(f):
        let t = l.strip
        for (key, dest) in [("NimMajor*", 0), ("NimMinor*", 1), ("NimPatch*", 2)]:
          if t.startsWith(key) and '=' in t:
            let v = t[t.rfind('=') + 1 .. ^1].strip
            if v.len > 0 and v[0] in Digits:
              case dest
              of 0: maj = v
              of 1: mnr = v
              else: pat = v
    except CatchableError: discard
    if maj.len > 0: break
  if maj.len == 0: "" else: maj & "." & mnr & "." & pat

proc depAct(kind, a, b: string): Action =
  ## (made here, not in a loop's body, so each line keeps its own package)
  result = proc() =
    case kind
    of "open":
      let ob = openFile(a)
      if ob != nil: focus = fEditor
    of "install":
      askConfirm("Install " & a & (if b.len > 0: " " & b else: "") & " with nimble? (y/n)", proc(c: char) =
        if c == 'y': runCommand("nimble install -y " & quoteShell(a & (if b.len > 0: "@" & b.replace(" ", "") else: "")), rootDir))
    else: discard

proc cmdNimbleTree() =
  ## the project's dependencies as a tree, each with the version the build uses and why (nimble.lock, nimble.paths,
  ## atlas …), else the newest installed that meets it (or why it is a problem)
  let nf = findNimbleFile(if buf().path.len > 0: parentDir(buf().path) else: rootDir)
  if nf.len == 0:
    info("No .nimble file in this folder")
    return
  let info0 = parseNimble(nf)
  let inst = depInstalled()
  let nimV = depNimVersion()
  var ls: seq[PanelLine]
  depActs.setLen(0)
  var nPkgs, nMissing, nOld = 0
  var seen: HashSet[string]
  proc line(text: string, sev: int, a: Action) =
    if a != nil:
      depActs.add a
      ls.add PanelLine(text: text, path: "dep:" & $(depActs.high), line: 0, sev: sev)
    else: ls.add PanelLine(text: text, line: -1, sev: sev)
  proc walk(reqs0: seq[string], prefix: string, depth: int) =
    # (a dependency's own Nim requirement only when this compiler does not meet it)
    var reqs: seq[string]
    for spec in reqs0:
      let (nm, cons) = depSplit(spec)
      if nm.len == 0: continue
      if depth > 0 and nm.toLowerAscii == "nim" and (nimV.len == 0 or depSatisfies(depVer(nimV), cons)): continue
      reqs.add spec
    for i, spec in reqs:
      let last = i == reqs.high
      let (nm, cons) = depSplit(spec)
      let branch = prefix & (if last: "└── " else: "├── ")
      let label = nm & (if cons.len > 0: " " & cons else: "")
      let pad = spaces(max(1, 44 - strWidth(branch & label)))
      if nm.toLowerAscii == "nim":
        let ok = nimV.len == 0 or depSatisfies(depVer(nimV), cons)
        line("  " & branch & label & pad & (if nimV.len == 0: "the compiler" elif ok: nimV & " ✓  (the compiler)"
                                            else: nimV & " ✗ the compiler is older"), (if ok: 0 else: 1), nil)
        continue
      # (the version the build uses — nimble.lock, nimble.paths, atlas, nimbledeps: the engine's choice — when it
      # has one; else the newest installed that meets the requirement)
      let ed = engineDepOf(parentDir(nf), nm)
      if ed.dir.len > 0 and ed.why.len > 0 and ed.why != "newest installed" and not ed.why.startsWith("requires") and
         " requires" notin ed.why:
        let okv = ed.version.len == 0 or ed.version.startsWith("#") or cons.len == 0 or depSatisfies(depVer(ed.version), cons)
        var enf = ""
        try:
          for k2, f in walkDir(ed.dir):
            if k2 in {pcFile, pcLinkToFile} and f.endsWith(".nimble"):
              enf = f
              break
        except OSError: discard
        let again = nm.toLowerAscii in seen
        if not again: inc nPkgs
        if not okv: inc nOld
        line("  " & branch & label & pad & (if ed.version.len > 0: ed.version else: "?") &
             (if okv: " ✓" else: " ✗ does not meet " & cons) & "  (" & ed.why & ")" &
             (if again: "  (its dependencies are above)" else: ""), (if okv: 0 else: 2),
             (if enf.len > 0: depAct("open", enf, "") else: nil))
        if again or depth >= 12 or enf.len == 0: continue
        seen.incl nm.toLowerAscii
        walk(parseNimble(enf).requires, prefix & (if last: "    " else: "│   "), depth + 1)
        continue
      let have = inst.getOrDefault(nm.toLowerAscii)
      var best = -1
      for k, p in have:
        if depSatisfies(p.ver, cons) and (best < 0 or depCmp(p.ver, have[best].ver) > 0): best = k
      if have.len == 0:
        inc nMissing
        line("  " & branch & label & pad & "✗ not installed — Enter installs it", 1, depAct("install", nm, cons))
        continue
      if best < 0:
        inc nOld
        var newest = 0
        for k, p in have:
          if depCmp(p.ver, have[newest].ver) > 0: newest = k
        line("  " & branch & label & pad & have[newest].version & " ✗ does not meet " & cons & " — Enter installs one that does",
             2, depAct("install", nm, cons))
        continue
      let p = have[best]
      let again = nm.toLowerAscii in seen
      if not again: inc nPkgs
      line("  " & branch & label & pad & p.version & " ✓" & (if again: "  (its dependencies are above)" else: ""), 0,
           (if p.nimble.len > 0: depAct("open", p.nimble, "") else: nil))
      if again or depth >= 12 or p.nimble.len == 0: continue
      seen.incl nm.toLowerAscii
      walk(parseNimble(p.nimble).requires, prefix & (if last: "    " else: "│   "), depth + 1)
  walk(info0.requires, "", 0)
  let head = "NIMBLE DEPENDENCIES — " & info0.name & (if info0.version.len > 0: " " & info0.version else: "") & " · " &
             $nPkgs & " package(s)" & (if nMissing > 0: " · " & $nMissing & " not installed" else: "") &
             (if nOld > 0: " · " & $nOld & " too old" else: "") & "   (Enter opens a package's .nimble, or installs)"
  var all = @[PanelLine(text: head, line: -1, sev: 5)]
  depActs.insert(Action(nil), 0)          # (line numbers shift by the header: dep:k still names its action)
  for l in ls:
    var x = l
    if x.path.startsWith("dep:"): x.path = "dep:" & $(parseInt(x.path[4 .. ^1]) + 1)
    all.add x
  if info0.requires.len == 0: all.add PanelLine(text: "  (" & extractFilename(nf) & " requires nothing)", line: -1)
  setPanel(pkOutput)
  panelTitle = "DEPENDENCIES"
  panelLines = all
  panelSel = (if all.len > 1: 1 else: 0)
  panelFollow = false
  panelScroll = 0
  focus = fPanel
  needRender = true
