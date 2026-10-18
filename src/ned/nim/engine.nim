# ════════════════════════════════════════════════════════════════════════════
#  Completion
# ════════════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════════════
#  The built-in Nim engine. ned's own index (above) answers completion, hover, definition,
#  signatures, outline, project symbols, references and rename at once and without a compiler;
#  `nim check` reports errors on save; nimsuggest, when installed, adds what only the compiler
#  knows: types the index cannot work out, errors while typing, inlay hints, macro expansion.
# ════════════════════════════════════════════════════════════════════════════


proc nimEngineOn(b: Buffer): bool =
  ## ned's Nim index serves this buffer (Nim source, and Nim is not handed to a language server)
  b != nil and b.lang != nil and b.lang.mode == lmNim and cfgNimIde != "off" and not nimUsesLsp() and
    b.lines.len < 60000 and b.title.len == 0 and not b.largeOn

var
  nxLibGuessed = false
  nxDumped, nxDumping: HashSet[string]   # project files whose `nim dump` was merged / is running
  nxDumpSearch, nxDumpLazy: seq[string]  # search paths and nimble package folders from `nim dump`
  nxLibFound = ""
  compNx: seq[NxItem]                    # index items behind the completion list (docs are made when shown)

proc nxGuessLib(): string =
  ## the standard library's folder, worked out from where `nim` lives (until `nim dump` says)
  var cands: seq[string]
  let exe = findExe("nim")
  if exe.len > 0:
    var real = exe
    for _ in 0 .. 5:
      try:
        let t = expandSymlink(real)
        real = if t.isAbsolute: t else: parentDir(real) / t
      except OSError: break
    let top = parentDir(parentDir(real))
    cands.add [top / "lib", top / "lib" / "nim", top / "lib" / "nim" / "lib"]
  let ch = getHomeDir() / ".choosenim" / "toolchains"
  if dirExists(ch):
    var tc: seq[string]
    try:
      for k, d in walkDir(ch):
        if k in {pcDir, pcLinkToDir}: tc.add d
    except OSError: discard
    tc.sort(proc(a, b: string): int = cmp(b, a))
    for d in tc: cands.add d / "lib"
  let prefix = getEnv("PREFIX")
  if prefix.len > 0: cands.add [prefix / "lib" / "nim", prefix / "lib" / "nim" / "lib"]
  cands.add ["/usr/lib/nim", "/usr/lib/nim/lib", "/usr/local/lib/nim", "/usr/local/lib/nim/lib", "/opt/nim/lib"]
  for c in cands:
    if fileExists(c / "system.nim"): return normalizedPath(c)
  ""

proc nxApplyToolchain() =
  var sp = nxDumpSearch
  # the package's own sources: tests/ and examples/ import them by name (nimble adds srcDir to the path)
  let nf = findNimbleFile(if rootDir.len > 0: rootDir else: getCurrentDir())
  if nf.len > 0:
    let info = parseNimble(nf)
    let src = normalizedPath(if info.srcDir.len > 0: info.dir / info.srcDir else: info.dir)
    if src notin sp: sp.add src
  var lazy = nxDumpLazy
  if lazy.len == 0:
    let nd = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
    lazy = @[nd / "pkgs2", nd / "pkgs"]
  var extra: seq[string]
  if rootDir.len > 0:
    # dependencies kept with the project (nimble's localdeps, atlas)
    for d in [rootDir / "nimbledeps" / "pkgs2", rootDir / "nimbledeps" / "pkgs", rootDir / "deps", rootDir / "vendor"]:
      if dirExists(d): extra.add d
  nxSetToolchain(nxLibFound, sp, lazy, extra)

proc isLibraryFile(path: string): bool =
  ## a file of the Nim toolchain (its standard library, or the compiler next to it) or of an installed nimble
  ## package — and not of the project you have open (working on Nim itself, or on a package in place, is fine)
  if path.len == 0 or not sBool("files.protectLibraries"): return false
  if rootDir.len > 1 and path.startsWith(rootDir & "/"): return false
  if nxLibFound.len == 0 and haveExe("nim"): nxLibFound = nxGuessLib()
  var roots: seq[string]
  if nxLibFound.len > 0:
    roots.add nxLibFound
    let top = parentDir(nxLibFound)               # a Nim tree (choosenim, a checkout): its compiler/ too
    if lastPathPart(nxLibFound) == "lib" and dirExists(top / "compiler") and fileExists(top / "bin" / "nim"):
      roots.add top
  let nimble = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  roots.add nimble / "pkgs2"
  roots.add nimble / "pkgs"
  for r in roots:
    if r.len > 1 and path.startsWith(r & "/"): return true
  false

proc nxDumpApply(proj, o: string) =
  ## what `nim dump --dump.format:json` said of a project: its library, search paths, package folders, defines
  let a = o.find('{')
  let e = o.rfind('}')
  if a < 0 or e <= a: return
  try:
    let js = parseJson(o[a .. e])
    let lib = js{"libpath"}.getStr
    if lib.len > 0 and fileExists(lib / "system.nim"): nxLibFound = normalizedPath(lib)
    # (a package folder on the path — nimble.paths, atlas' nim.cfg — is this project's version of it: two
    # projects may use two versions)
    let root = nxRootFor(parentDir(proj))
    var pkgPaths: seq[string]
    for x in jitems(js{"lib_paths"}):
      let p = normalizedPath(x.getStr)
      if p.len == 0: continue
      let own = p == root or (p.startsWith(root & "/") and not p.startsWith(root & "/nimbledeps/") and
                              not p.startsWith(root & "/deps/"))
      if root.len > 0 and nxIsPkgPath(p) and not own:
        if p notin pkgPaths: pkgPaths.add p
      elif p notin nxDumpSearch: nxDumpSearch.add p
    if root.len > 0: nxProjectPaths[root] = pkgPaths
    for x in jitems(js{"lazyPaths"}):
      let p = normalizedPath(x.getStr)
      if p.len > 0 and p notin nxDumpLazy: nxDumpLazy.add p
    # what the project's config defines (-d:ssl, -d:nimPreviewSlimSystem …): `when defined(…)` follows it
    var got = 0
    for x in jitems(js{"defined_symbols"}):
      if x.getStr.len > 0:
        nxDefines.incl x.getStr
        inc got
    if got > 20 and not nxDefinesComplete:
      # every symbol the project defines is known now: `when defined(vmathArrayBased)` is false, not maybe —
      # the files read before this are read again
      nxDefinesComplete = true
      nxForgetFiles()
    nxApplyToolchain()
    needRender = true
  except CatchableError: discard

proc nxEnsureToolchain(b: Buffer) =
  ## guess the toolchain at once; ask `nim dump` (in the background, once per project) for the real
  ## search paths: config.nims / nim.cfg --path, nimble packages
  if not nxLibGuessed:
    nxLibGuessed = true
    nxInitDefines()
    if nxLibFound.len == 0: nxLibFound = nxGuessLib()
    nxApplyToolchain()
  if b == nil or b.path.len == 0 or nxDumping.len > 0 or not haveExe("nim"): return
  let proj = nimProjectFile(b)
  if proj in nxDumped: return
  if not codeTrusted(parentDir(proj)):
    askTrust(parentDir(proj), quiet = true)        # (nim dump runs config.nims: the guess stands meanwhile)
    return
  nxDumping.incl proj
  discard startJob(jkTool, "nim dump --hints:off --warnings:off --dump.format:json " & quoteShell(proj) & " 2>/dev/null",
                   parentDir(proj), proc(j: Job) =
    nxDumping.excl proj
    nxDumped.incl proj
    nxDumpApply(proj, j.output))

proc engineDepOf(dir, name: string): NxDep =
  ## the version of package `name` the project in `dir` builds with (dir: "" for an empty name: not one it uses)
  let p = nxProjectAt(nxRootFor(dir))
  for d in p.deps:
    if cmpIgnoreCase(d.name, name) == 0: return d
  for d in p.rest:
    let (nm, ver) = nxPkgSplit(extractFilename(d))
    if cmpIgnoreCase(nm, name) == 0: return NxDep(name: nm, version: ver, dir: d, why: "newest installed")

proc engineDepNote(req: string): string =
  ## what a requirement of the project's .nimble resolves to, for the Nim dock: "1.1.5 (nimble.lock)"
  let (nm, _) = nxSplitRequire(req)
  if nm.len == 0 or cmpIgnoreCase(nm, "nim") == 0: return ""
  let d = engineDepOf(if nimble.dir.len > 0: nimble.dir else: rootDir, nm)
  if d.name.len == 0: return "not installed"
  let why = if d.why.startsWith("requires") or " requires" in d.why: "newest installed that meets it" else: d.why
  (if d.version.len > 0: d.version & " " else: "") & "(" & why & ")"

proc engineDepLines(dir: string): seq[string] =
  ## the package versions the project in `dir` builds with, one line each: "jsony 1.1.5 (nimble.lock)"
  for d in nxProjectAt(nxRootFor(dir)).deps:
    result.add d.name & (if d.version.len > 0: " " & d.version else: "") & " (" & d.why & ")"

proc nxBufStamp(path: string): string =
  let i = bufIndexByPath(path)
  if i < 0: "" else: "b" & $bufs[i].id & ":" & $bufs[i].changeId

proc nxBufLines(path: string): seq[string] =
  let i = bufIndexByPath(path)
  if i >= 0: bufs[i].lines else: @[]

nxBufferStamp = nxBufStamp
nxBufferLines = nxBufLines

proc nxFileFor(b: Buffer): NxFile =
  ## the index's view of a buffer (parsed again only after it changed)
  nxEnsureToolchain(b)
  nxSetActiveFile(b.path)              # (the package files it reaches: the versions its project builds with)
  if b.path.len > 0:
    result = nxLoad(b.path)
    if result != nil: return
  # an unsaved buffer: read as if it lived in the project folder
  let p = (if rootDir.len > 0: rootDir else: getCurrentDir()) / ("untitled-" & $b.id & ".nim")
  let stamp = "b" & $b.id & ":" & $b.changeId
  let old = nxFiles.getOrDefault(p)
  if old != nil and old.stamp == stamp: return old
  result = nxParse(b.lines, p)
  result.stamp = stamp
  nxFiles[p] = result

var typoAt: Table[int, int]          # buffer id → the change its misspelled names were looked for at

proc engineChecksFor(b: Buffer): seq[Diag]
proc lintApply*(path: string, lines: openArray[string], ds: var seq[Diag])

proc engineAgain(path: string) =
  ## the compiler's check replaced a file's problems: the engine's own (hints the compiler does not give) are
  ## worked out again, merged with it
  let i = bufIndexByPath(path)
  if i >= 0: typoAt.del bufs[i].id

proc engineChecksOnOpen(b: Buffer): bool =
  ## a project file just opened, not looked at yet: its problems without waiting for an edit (not a library's,
  ## not a file outside the project)
  typoAt.getOrDefault(b.id, -1) == -1 and b.path.len > 0 and rootDir.len > 0 and b.path.startsWith(rootDir & "/") and
    not isLibraryFile(b.path)

proc engineTypos(b: Buffer) =
  ## a misspelled name marked at once, and what the engine's own checks find (nim.engineChecks: a field that is
  ## not there, a wrong number of arguments, code that never runs, an unused local) — the compiler's check, a
  ## moment later, has the last word
  typoAt[b.id] = b.changeId
  if b.path.len == 0 or b.lines.len > 15_000 or not nimEngineOn(b): return
  let f = nxFileFor(b)
  if f == nil: return
  let lo = max(0, b.topLine - 100)
  let hi = min(b.lines.high, b.topLine + max(textH, 20) + 100)
  var found: seq[(int, int, string, string)]
  try: found = nxTypos(f, b.lines, lo, hi, (b.primary.head.line, b.primary.head.col))
  except CatchableError: return
  var ds: seq[Diag]
  for d in diagsBuild.getOrDefault(b.path):
    if d.src != "ned": ds.add d
  let before = diagsBuild.getOrDefault(b.path).len
  for (l, c, w, meant) in found:
    var dup = false
    for d in ds:
      if d.line == l and ("'" & w & "'") in d.msg: dup = true
    if dup: continue
    ds.add Diag(line: l, col: c, eline: l, ecol: -1, sev: 1, src: "ned", rule: "typo",
                msg: "undeclared identifier: '" & w & "'\ncandidates (edit distance, scope distance); see " &
                     "'--spellSuggest': \n (1, 0): '" & meant & "'")
  var checked = 0
  if cfgEngineChecks:
    var mine: seq[Diag]
    try: mine = engineChecksFor(b)
    except CatchableError, Defect: discard
    for d in mine:
      var taken = false
      for e in ds:
        if e.line == d.line and e.src != "ned": taken = true     # (the compiler said something there: its word)
      if not taken:
        ds.add d
        inc checked
  lintApply(b.path, b.lines, ds)                       # (.ned/lint.json, `# ned: ignore`: the typos too)
  if ds.len != before or found.len > 0 or checked > 0:
    diagsBuild[b.path] = ds
    needRender = true
