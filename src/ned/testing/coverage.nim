# ── Nim: test coverage, profiling, playground, compiler versions, docs browser, nimble view ──

proc cmdCoverage() =
  ## build with coverage, run (a test file, or the program), and colour the line numbers: green ran, red never ran
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open the Nim test (or program) to measure")
    return
  let gcov = if haveExe("gcov"): "gcov" elif haveExe("llvm-cov"): "llvm-cov gcov" else: ""
  if gcov.len == 0:
    error("Coverage needs gcov (Debian/Ubuntu: it comes with gcc · Termux: pkg install llvm)")
    return
  discard saveAll()
  let main = if isNimProgram(b): b.path else: nimProjectFile(b)
  let dir = privDir() / ("ned_cov_" & splitFile(main).name)
  try: removeDir(dir)
  except OSError: discard
  let cmd = "nim c -r --hints:off --debugger:native --lineDir:on --opt:none --gcc.options.debug:-g " &
            "--clang.options.debug:-g --passC:--coverage --passL:--coverage --nimcache:" & quoteShell(dir) &
            " -o:" & quoteShell(dir / "prog") & " " & quoteShell(main) & " ; cd " & quoteShell(dir) &
            " && for f in *.gcda; do " & gcov & " -p \"$f\" > /dev/null 2>&1; done"
  info("Running " & extractFilename(main) & " with coverage…")
  discard startJob(jkTool, cmd, parentDir(main), proc(j: Job) =
    covLines.clear()
    var total, ran = 0
    try:
      for f in walkFiles(dir / "*.gcov"):
        var src = ""
        for l in lines(f):
          let c1 = l.find(':')
          if c1 < 0: continue
          let c2 = l.find(':', c1 + 1)
          if c2 < 0: continue
          let cnt = l[0 ..< c1].strip
          let ln = (try: parseInt(l[c1 + 1 ..< c2].strip) except ValueError: -1)
          if ln == 0 and l[c2 + 1 .. ^1].startsWith("Source:"):
            src = l[c2 + 1 + "Source:".len .. ^1].strip
            if not src.isAbsolute: src = normalizedPath(dir / src)
            if not src.startsWith(rootDir & "/"): src = ""
            continue
          if src.len == 0 or ln <= 0 or cnt == "-": continue
          let code = l[c2 + 1 .. ^1].strip
          if code in ["else:", "of", "finally:", "except:"] or code.len == 0: continue
          let did = cnt != "#####" and cnt != "=====" and not cnt.startsWith("0")
          let t = covLines.mgetOrPut(src, initTable[int, bool]())
          covLines[src][ln - 1] = t.getOrDefault(ln - 1, false) or did
    except OSError: discard
    for path, t in covLines:
      for _, v in t:
        inc total
        if v: inc ran
    if total == 0:
      error("No coverage data — did it build? See the Output panel")
      for l in j.output.splitLines: addPanelLine(PanelLine(text: l, line: -1))
      return
    info("Coverage: " & $(ran * 100 div total) & "% of " & $total & " lines ran (" & $covLines.len &
         " files) — green line numbers ran, red never did · palette: Nim: hide coverage")
    needRender = true)

# ── test coverage in other languages: coverage.py, go test -coverprofile, cargo llvm-cov / tarpaulin,
#    Node's own (--experimental-test-coverage), and any lcov file — the same green / red line numbers ──

proc covAdd(path: string, ln: int, did: bool) =
  ## line `ln` (0-based) of `path` ran or not (ran wins when several records cover it)
  if ln < 0: return
  let p = (if path.isAbsolute: path else: rootDir / path).normalizedPath
  if p notin covLines: covLines[p] = initTable[int, bool]()
  covLines[p][ln] = covLines[p].getOrDefault(ln, false) or did

proc parseLcov(text, base: string) =
  ## SF:<file> … DA:<line>,<count> … end_of_record
  var src = ""
  for raw in text.splitLines:
    let l = raw.strip
    if l.startsWith("SF:"):
      src = l[3 .. ^1]
      if not src.isAbsolute: src = base / src
    elif l.startsWith("DA:") and src.len > 0:
      let parts = l[3 .. ^1].split(',')
      if parts.len >= 2:
        let ln = (try: parseInt(parts[0]) except ValueError: 0)
        let cnt = (try: parseInt(parts[1].strip) except ValueError: 0)
        covAdd(src, ln - 1, cnt > 0)
    elif l == "end_of_record": src = ""

proc parseCoveragePy(text, base: string) =
  ## coverage.py's json: files → executed_lines / missing_lines
  try:
    let j = parseJson(text)
    for f, v in j{"files"}.pairs:
      let p = if f.isAbsolute: f else: base / f
      for x in jitems(v{"executed_lines"}): covAdd(p, x.getInt - 1, true)
      for x in jitems(v{"missing_lines"}): covAdd(p, x.getInt - 1, false)
  except CatchableError: discard

proc parseGoCover(text, modDir, modPath: string) =
  ## mode: set · <import path>/f.go:12.34,15.2 3 1
  for raw in text.splitLines:
    let l = raw.strip
    if l.startsWith("mode:") or l.len == 0: continue
    let c = l.rfind(':', l.find(".go:") + 4)
    let k = l.find(".go:")
    if k < 0: continue
    var file = l[0 ..< k + 3]
    let rest = l[k + 4 .. ^1].splitWhitespace()
    if rest.len < 3: continue
    discard c
    let rng = rest[0].split(',')
    if rng.len < 2: continue
    let a = (try: parseInt(rng[0].split('.')[0]) except ValueError: 0)
    let e = (try: parseInt(rng[1].split('.')[0]) except ValueError: 0)
    let cnt = (try: parseInt(rest[2]) except ValueError: 0)
    if modPath.len > 0 and file.startsWith(modPath & "/"): file = modDir / file[modPath.len + 1 .. ^1]
    elif not file.isAbsolute: file = modDir / file
    for ln in a .. e: covAdd(file, ln - 1, cnt > 0)

proc covSummary(what: string, j: Job) =
  var total, ran = 0
  for path, t in covLines:
    for _, v in t:
      inc total
      if v: inc ran
  if total == 0:
    error("No coverage data from " & what & " — see the Output panel")
    if j != nil:
      for l in j.output.splitLines: addPanelLine(PanelLine(text: l, line: -1))
    return
  info("Coverage (" & what & "): " & $(ran * 100 div total) & "% of " & $total & " lines ran in " & $covLines.len &
       " file(s) — green line numbers ran, red never did · palette › Test coverage: hide")
  needRender = true

proc lcovFiles(dir: string): seq[string] =
  for f in ["coverage/lcov.info", "lcov.info", "coverage.lcov", "target/lcov.info", "target/llvm-cov/lcov.info",
            "coverage/lcov/lcov.info", "tests/lcov.info"]:
    if fileExists(dir / f): result.add dir / f

proc cmdCoverageLoad(path = "") =
  ## an lcov file another tool wrote (jest, vitest, c8, cargo llvm-cov, gcovr, kcov …)
  var f = path
  if f.len == 0:
    let fs = lcovFiles(rootDir)
    if fs.len == 0:
      info("No lcov file found (coverage/lcov.info, lcov.info …) — Test coverage: run makes one")
      return
    f = fs[0]
  covLines.clear()
  try: parseLcov(readFile(f), parentDir(f))
  except CatchableError as e:
    error(e.msg)
    return
  covSummary(relPath(f), nil)

proc goModInfo(start: string): (string, string) =
  ## (the folder with go.mod, the module path)
  var d = start
  while d.len > 1:
    if fileExists(d / "go.mod"):
      try:
        for l in readFile(d / "go.mod").splitLines:
          if l.startsWith("module "): return (d, l[7 .. ^1].strip.strip(chars = {'"'}))
      except CatchableError: discard
      return (d, "")
    if parentDir(d) == d: break
    d = parentDir(d)
  ("", "")

proc cmdCoverageRun() =
  ## Test coverage: run the tests (or this file) with the language's coverage tool
  let b = buf()
  if b.lang.mode == lmNim:
    cmdCoverage()
    return
  discard saveAll()
  let dir = privDir() / "ned_cov_other"
  try:
    removeDir(dir)
    createDir(dir)
  except OSError: discard
  case b.lang.id
  of "python":
    var py = "python3"
    for v in [rootDir / ".venv" / "bin" / "python", rootDir / "venv" / "bin" / "python"]:
      if fileExists(v): py = quoteShell(v)
    let (ok, _, _) = runFilter(py & " -c 'import coverage' 2>&1", "", rootDir, 8000)
    if not ok:
      toast("coverage.py is not installed", 2, "Install", proc() = runInTerm(py & " -m pip install coverage"), 15000)
      return
    if not testScanned: rescanTests()
    var hasTests = false
    for e in testEntries:
      if testLangOf(e.path) == "py": hasTests = true
    let data = quoteShell(dir / ".coverage")
    let (pyOk, _, _) = runFilter(py & " -c 'import pytest' 2>&1", "", rootDir, 8000)
    let what = if hasTests and pyOk: "-m pytest -q -p no:cacheprovider" else: quoteShell(b.path)
    let cmd = py & " -m coverage run --data-file=" & data & " " & what & " ; " & py & " -m coverage json --data-file=" &
              data & " -o " & quoteShell(dir / "cov.json") & " -q"
    info("Running " & (if hasTests and pyOk: "pytest" else: b.name) & " with coverage.py…")
    discard startJob(jkTool, cmd & " 2>&1", rootDir, proc(j: Job) =
      covLines.clear()
      try: parseCoveragePy(readFile(dir / "cov.json"), rootDir)
      except CatchableError: discard
      covSummary("coverage.py", j))
  of "go":
    let (md, mp) = goModInfo(parentDir(b.path))
    if md.len == 0:
      info("No go.mod above this file")
      return
    info("Running go test with -coverprofile…")
    discard startJob(jkTool, "go test -coverprofile=" & quoteShell(dir / "c.out") & " ./... 2>&1", md, proc(j: Job) =
      covLines.clear()
      try: parseGoCover(readFile(dir / "c.out"), md, mp)
      except CatchableError: discard
      covSummary("go test", j))
  of "rust":
    let root = cargoRoot(parentDir(b.path))
    if root.len == 0:
      info("No Cargo.toml above this file")
      return
    var cmd = ""
    let (hasLlvm, _, _) = runFilter("cargo llvm-cov --version 2>&1", "", root, 8000)
    if hasLlvm: cmd = "cargo llvm-cov --lcov --output-path " & quoteShell(dir / "lcov.info")
    else:
      let (hasTarp, _, _) = runFilter("cargo tarpaulin --version 2>&1", "", root, 8000)
      if hasTarp: cmd = "cargo tarpaulin --out Lcov --output-dir " & quoteShell(dir)
    if cmd.len == 0:
      toast("Rust coverage needs cargo-llvm-cov (or cargo-tarpaulin)", 2, "Install",
            proc() = runInTerm("cargo install cargo-llvm-cov && rustup component add llvm-tools-preview"), 15000)
      return
    info("Running cargo test with coverage…")
    discard startJob(jkTool, cmd & " 2>&1", root, proc(j: Job) =
      covLines.clear()
      try: parseLcov(readFile(dir / "lcov.info"), root)
      except CatchableError: discard
      covSummary("cargo", j))
  of "javascript", "typescript":
    if not haveExe("node"):
      error("node is not installed")
      return
    let strip = if b.lang.id == "typescript": "--experimental-strip-types --no-warnings " else: ""
    let cmd = "node " & strip & "--test --experimental-test-coverage --test-reporter=lcov --test-reporter-destination=" &
              quoteShell(dir / "lcov.info") & " " & quoteShell(b.path)
    info("Running " & b.name & " with Node's coverage…")
    discard startJob(jkTool, cmd & " 2>&1", parentDir(b.path), proc(j: Job) =
      covLines.clear()
      try: parseLcov(readFile(dir / "lcov.info"), parentDir(b.path))
      except CatchableError: discard
      covSummary("node", j))
  else:
    if lcovFiles(rootDir).len > 0: cmdCoverageLoad()
    else: info("No coverage tool for " & b.lang.name & " — Test coverage: load an lcov file… reads one any tool wrote")
