# ── Nim: test coverage, profiling, playground, compiler versions, docs browser, nimble view ──

# ── Nim test coverage: the tests (one test file, or a program) built with gcov's instrumentation and run, each Nim
#    line's count read back. The build is kept in a private nimcache per test file, so the next run compiles only the
#    C that changed (and, with nothing changed, -d:nimBetterRun skips the compiler's work): `nim c --compileOnly`
#    writes the C and its build recipe (<name>.json), the C compiler builds the recipe, the program runs. gcc: each
#    new C file is rewritten first so a statement counts on its own .nim line, and gcov reads the .gcda files ·
#    clang (Termux, macOS): source-based coverage, llvm-profdata and `llvm-cov export` count C lines, and the #line
#    anchors take them to the .nim lines (testing/gcovdata says why). Only the project's own files count — not the
#    standard library, nimble packages or (nim.coverageTestFiles) the tests themselves ──

type NimCovRun = ref object
  queue: seq[string]          # test files (or the program) still to run
  tests: seq[string]          # all of this run's
  hits: CovHits
  passed, failed, broken: int # programs that ran and passed / failed / did not build
  built, kept: int            # C files compiled / kept from the run before
  cc: string                  # "gcc" or "clang": the C compiler the recipes use ("" until a build says)
  ccVer: string               # its major version
  tool: string                # gcc: gcov (gcov-13 …) · clang: llvm-cov (llvm-cov-18, xcrun llvm-cov …)
  profdata: string            # clang: llvm-profdata, which merges the runs' .profraw files
  toolJson: bool              # gcov --json-format (gcc 9 and later)
  cmaps: Table[string, Table[int, (string, int)]]   # clang: a C file's #line anchors → (.nim file, line)
  started: MonoTime
  what: string                # for the messages: "3 test files", "tcalc.nim"
  realRoot: string            # the project folder with symlinks resolved (the compiler's paths)
  libDir: string              # the Nim toolchain's lib folder (never counted)
  compiled: HashSet[string]   # the project's files the test programs that ran are built from (recipes' depfiles)
  deps: seq[string]           # … those of the one being built (counted once it has run)

var
  nimCovRun: NimCovRun                              # the run going on (nil: none)
  covHits: CovHits                                  # the last Nim run's counts: file → 1-based line → times run
  covUnreached: Table[string, seq[(string, int)]]   # file → the procs no test reaches: (name, 0-based line)
  covNotBuilt: seq[string]                          # the project's files no test compiles
  covWhat = ""                                      # what the coverage on show came from
  ccFlavors: Table[string, (string, string)]        # C compiler → ("gcc" / "clang", its major version)

const CovSkipDirs = ["tests", "test", "examples", "example", "benchmarks", "bench", "docs", "doc", "tools", "scripts",
                     "nimbledeps", "nimcache", "vendor", ".nimble", "pkgs", "pkgs2", ".git"]

proc covFileLines(p: string): seq[string] =
  let i = bufIndexByPath(p)
  if i >= 0: return bufs[i].lines
  try:
    if getFileSize(p) < 8_000_000: result = readFile(p).splitLines
  except CatchableError: discard

proc nimCovTestFiles(): seq[string] =
  ## the project's Nim test programs: the test explorer's (std/unittest, testament specs that run) and nimble's own
  ## rule (tests/…/t*.nim)
  if not testScanned: rescanTests()
  var cands: seq[string]
  for e in testEntries:
    if e.path.endsWith(".nim") and e.path notin cands: cands.add e.path
  for rel in projectFiles():
    if rel.startsWith("tests/") and rel.endsWith(".nim") and extractFilename(rel).startsWith("t") and
       (rootDir / rel) notin cands:
      cands.add rootDir / rel
  for p in cands:
    # a testament spec that does not run (action: reject / compile, disabled) gives no coverage
    let lines = covFileLines(p)
    if testamentSpecLine(lines) >= 0:
      let spec = testamentSpec(lines)
      let action = spec.getOrDefault("action", (if "errormsg" in spec: "reject" else: "run")).strip(chars = {'"'})
      if action != "run" or spec.getOrDefault("disabled").strip(chars = {'"'}).toLowerAscii in ["true", "on", "yes"]:
        continue
    result.add p
  result.sort()

proc covIsTestFile(p: string, tests: seq[string]): bool =
  if p in tests: return true
  let rel = if p.startsWith(rootDir & "/"): p[rootDir.len + 1 .. ^1] else: p
  rel.startsWith("tests/") or rel.startsWith("test/") or isTestamentTest(p)

proc nimCovPath(r: NimCovRun, f: string): string =
  ## the file gcov names → the project file to count it under ("" = not the project's own)
  var p = normalizedPath(f)
  if r.realRoot.len > 0 and r.realRoot != rootDir and p.startsWith(r.realRoot & "/"):
    p = rootDir / p[r.realRoot.len + 1 .. ^1]
  if not p.endsWith(".nim") or not p.startsWith(rootDir & "/") or p.startsWith(CovBleedFile): return ""
  if r.libDir.len > 0 and p.startsWith(r.libDir & "/"): return ""
  if p.startsWith(privDir() & "/") or p.startsWith(getHomeDir() / ".nimble" & "/"): return ""
  let parts = p[rootDir.len + 1 .. ^1].split('/')
  for c in parts[0 ..< ^1]:
    if c in ["nimbledeps", "nimcache", "vendor", ".nimble", "pkgs", "pkgs2", ".git"]: return ""
  if not cfgCovTestFiles and covIsTestFile(p, r.tests): return ""
  p

proc ccFlavor(cc, cwd: string): (string, string) =
  ## ("gcc" or "clang", the major version) of a C compiler: Termux's and macOS's gcc are clang
  if cc in ccFlavors: return ccFlavors[cc]
  let (_, o, _) = runFilter(quoteShell(cc) & " --version 2>&1", "", cwd, 8000)
  let name = extractFilename(cc)
  let clang = "clang" in o.toLowerAscii or "clang" in name or "zig" in name
  var ver = ""
  let k = o.find("version ")
  let v = if clang: (if k >= 0: o[k + 8 .. ^1] else: "")
          else: runFilter(quoteShell(cc) & " -dumpversion 2>&1", "", cwd, 8000)[1].strip
  for ch in v:
    if ch in Digits: ver.add ch
    else: break
  result = ((if clang: "clang" else: "gcc"), ver)
  ccFlavors[cc] = result

proc covToolFor(r: NimCovRun, flavor, ver, cwd: string): bool =
  ## the tools that read what this compiler's programs wrote (r.tool, r.profdata) — false, the reason told, when
  ## they are not installed
  if flavor == "gcc":
    for t in ["gcov-" & ver, "gcov"]:
      if ver.len == 0 and t == "gcov-": continue
      if haveExe(t):
        let (_, h, _) = runFilter(t & " --help 2>&1", "", cwd, 8000)
        r.toolJson = "json-format" in h
        r.tool = t
        return true
    error("Nim test coverage needs gcov, which comes with gcc (Debian/Ubuntu: apt install gcc · Fedora: dnf " &
          "install gcc)")
    return false
  for v in [ver, ""]:
    if ver.len == 0 and v.len > 0: continue
    let sfx = if v.len > 0: "-" & v else: ""
    if haveExe("llvm-cov" & sfx) and haveExe("llvm-profdata" & sfx):
      r.tool = "llvm-cov" & sfx
      r.profdata = "llvm-profdata" & sfx
      return true
  if haveExe("xcrun"):
    r.tool = "xcrun llvm-cov"
    r.profdata = "xcrun llvm-profdata"
    return true
  error("Nim test coverage with clang needs llvm-cov and llvm-profdata (Termux: pkg install llvm · Debian/Ubuntu: " &
        "apt install llvm)")
  false

proc ncNext(r: NimCovRun)

proc ncStop(r: NimCovRun, why: string, tell = true) =
  if nimCovRun == r: nimCovRun = nil
  addPanelLine(PanelLine(text: "■ " & why, sev: 2, line: -1))
  if tell: info(why)

func ncKilled(j: Job): bool = j.code in [130, 137, 143]     # (Stop, another run: SIGTERM / SIGKILL / SIGINT)

proc ncGcov(r: NimCovRun, test, dir, exe, cwd: string) =
  ## what the program wrote (gcc: .gcda files · clang: .profraw files) → counts per Nim line; then those files go,
  ## and the tools' output with them
  let clang = r.cc == "clang"
  var data: seq[string]
  for f in walkFiles(dir / (if clang: "*.profraw" else: "*.gcda")): data.add f
  if data.len == 0:
    addPanelLine(PanelLine(text: "  no coverage data from " & extractFilename(test) & " (did it crash, or never end?)",
                           sev: 2, line: -1))
    ncNext(r)
    return
  let outFile = privTmp("ned-gcov")
  var cmd = ""
  if clang:
    let pd = privTmp("ned-profdata")
    cmd = r.profdata & " merge -sparse -o " & quoteShell(pd)
    for g in data: cmd.add " " & quoteShell(g)
    cmd.add " && " & r.tool & " export -format=lcov -instr-profile=" & quoteShell(pd) & " " & quoteShell(exe) &
            " > " & quoteShell(outFile) & " ; rm -f " & quoteShell(pd)
  elif r.toolJson:
    cmd = r.tool & " --json-format --stdout"
    for g in data: cmd.add " " & quoteShell(g)
    cmd.add " > " & quoteShell(outFile)
  else:
    cmd = r.tool & " -i"                           # (gcc before 9: intermediate .gcov files, here)
    for g in data: cmd.add " " & quoteShell(g)
    cmd.add " > /dev/null"
  let j = startJob(jkTool, cmd, dir, proc(j: Job) =
    if nimCovRun != r: return
    var files: seq[string]
    if fileExists(outFile): files.add outFile
    if not clang:
      for f in walkFiles(dir / "*.gcov"): files.add f
    let before = r.hits.len
    let mapPath = proc(p: string): string = nimCovPath(r, p)
    for f in files:
      try:
        if clang:
          parseLcovMappedFile(f, r.hits, mapPath, proc(cf: string): Table[int, (string, int)] =
            if cf notin r.cmaps:
              r.cmaps[cf] = (try: covLineMap(readFile(cf)) except CatchableError: initTable[int, (string, int)]())
            r.cmaps[cf])
        else: parseGcovFile(f, r.hits, mapPath, cwd)
      except CatchableError as e: addPanelLine(PanelLine(text: "  " & e.msg, sev: 1, line: -1))
      try: removeFile(f)
      except OSError: discard
    r.cmaps.clear()
    for g in data:
      try: removeFile(g)
      except OSError: discard
    if files.len > 0:
      for d in r.deps: r.compiled.incl d          # (its modules count: it ran, and its data was read)
    if files.len == 0 or (j.code != 0 and r.hits.len == before):
      addPanelLine(PanelLine(text: "  " & r.tool & " could not read the coverage data:", sev: 1, line: -1))
      for l in j.output.strip.splitLines: addPanelLine(PanelLine(text: "    " & l, line: -1))
    ncNext(r))
  if j == nil: ncStop(r, "Coverage stopped: " & r.tool & " did not start")

proc ncRunTest(r: NimCovRun, test, dir, exe, cwd: string) =
  ## run the test program (where the test explorer runs it); its [OK] / [FAILED] lines go to the explorer too
  for pat in ["*.gcda", "*.profraw"]:
    for f in walkFiles(dir / pat):
      try: removeFile(f)
      except OSError: discard
  for e in testEntries:
    if e.path == test: testStatus[testKey(test, e.name)] = 3
  addPanelLine(PanelLine(text: "  running " & relPath(test), sev: 3, line: -1))
  let env = if r.cc == "clang": "LLVM_PROFILE_FILE=" & quoteShell(dir / "ned-%p.profraw") & " " else: ""
  let j = startJob(jkRun, env & quoteShell(exe), parentDir(test), proc(j: Job) =
    if j.partial.len > 0:
      addRunLine(j, j.partial)
      j.partial = ""
    if nimCovRun != r: return
    if ncKilled(j):
      for e in testEntries:
        if e.path == test and testStatus.getOrDefault(testKey(test, e.name)) == 3: testStatus.del testKey(test, e.name)
      ncStop(r, "Coverage stopped")
      return
    parseTestOutput(test, j.output)
    for e in testEntries:
      if e.path == test and testStatus.getOrDefault(testKey(test, e.name)) == 3:
        testStatus[testKey(test, e.name)] = (if j.code == 0: 1 else: 2)
    if j.code == 0: inc r.passed
    else:
      inc r.failed
      addPanelLine(PanelLine(text: "  ✗ " & relPath(test) & ": exit code " & $j.code, sev: 1, line: -1))
    ncGcov(r, test, dir, exe, cwd))
  if j == nil: ncStop(r, "Coverage stopped: the test program did not start")

proc ncCompileC(r: NimCovRun, test, dir, name: string) =
  ## the recipe's new C files, rewritten (gcovdata.covRewriteC) and compiled side by side, then linked. With nothing
  ## changed the compiler leaves the recipe as it was (-d:nimBetterRun): its C files are built already
  var recipe: JsonNode
  var stamp = ""
  try:
    let text = readFile(dir / (name & ".json"))
    stamp = covHash(text)
    recipe = parseJson(text)
  except CatchableError as e:
    addPanelLine(PanelLine(text: "  ✗ no build recipe from the compiler: " & e.msg, sev: 1, line: -1))
    inc r.broken
    ncNext(r)
    return
  let cwd = recipe{"currentDir"}.getStr(parentDir(test))
  let linkCmd0 = recipe{"linkcmd"}.getStr
  let exe = dir / name
  for d in jitems(recipe{"depfiles"}):             # (every module it is built from)
    if d.kind == JArray and d.len > 0:
      let p = nimCovPath(r, d[0].getStr)
      if p.len > 0: r.deps.add p
  let builtFrom = try: readFile(dir / "ned-built.txt") except CatchableError: ""
  let fresh = stamp != builtFrom or not fileExists(exe)
  if r.cc.len == 0:
    let w = shellCommands(linkCmd0)
    let (flavor, ver) = ccFlavor((if w.len > 0 and w[0].len > 0: w[0][0] else: "cc"), cwd)
    r.cc = flavor
    r.ccVer = ver
    if not covToolFor(r, flavor, ver, cwd):
      ncStop(r, "Coverage stopped: nothing here reads " & flavor & "'s coverage data", tell = false)   # (said why)
      return
  let clang = r.cc == "clang"
  # clang: its source-based coverage (C lines; ned takes them to the .nim lines) instead of --coverage
  let linkCmd = if clang: linkCmd0.replace(" --coverage", " -fprofile-instr-generate") else: linkCmd0
  var script = "cd " & quoteShell(cwd) & " || exit 1\nf=0\n"
  var n = 0
  var batch: seq[string]
  let par = clamp(covJobs(), 1, 6)
  proc flush() =
    for p in batch: script.add "wait $" & p & " || f=1\n"
    batch.setLen(0)
  for it in jitems(recipe{"compile"}):
    if it.kind != JArray or it.len < 2 or not fresh: continue
    let cfile = it[0].getStr
    let cmd = it[1].getStr
    var line = cmd
    if clang: line = cmd.replace(" --coverage", " -fprofile-instr-generate -fcoverage-mapping")
    elif cfile.startsWith(dir & "/") and cfile.endsWith(".c"):
      let cov = cfile[0 ..< ^2] & ".cov.c"
      var ok = false
      try:
        writeFile(cov, covRewriteC(readFile(cfile)))
        ok = true
      except CatchableError: discard
      if ok:
        for suffix in [quoteShell(cfile), cfile]:
          if line == cmd and cmd.endsWith(" " & suffix): line = cmd[0 ..< cmd.len - suffix.len] & quoteShell(cov)
      if line != cmd:
        # (should the rewritten C not build, the compiler's own does — its lines then count less exactly)
        line = "{ " & line & " ; } 2>/dev/null || { echo " &
               quoteShell("ned: " & extractFilename(cfile) & " is built as the compiler wrote it") & " ; " & cmd &
               " ; }"
    inc n
    script.add "( " & line & " ) & p" & $n & "=$!\n"
    batch.add "p" & $n
    if batch.len >= par: flush()
  flush()
  script.add "[ $f = 0 ] || exit 1\n"
  let linkedWith = try: readFile(dir / "ned-link.txt") except CatchableError: ""
  let relink = n > 0 or not fileExists(exe) or linkedWith != linkCmd
  if relink:
    script.add linkCmd & " || exit 1\n"
    for x in jitems(recipe{"extraCmds"}): script.add x.getStr & " || exit 1\n"
  var objs = 0
  for _ in jitems(recipe{"link"}): inc objs
  r.built += n
  r.kept += max(0, objs - n)
  if not relink:
    try: writeFile(dir / "ned-built.txt", stamp)
    except CatchableError: discard
    addPanelLine(PanelLine(text: "  the C build is the one from last time (" & $objs & " files)", sev: 3, line: -1))
    ncRunTest(r, test, dir, exe, cwd)
    return
  addPanelLine(PanelLine(text: "  C: " & $n & " file(s) to compile, " & $max(0, objs - n) & " kept from last time" &
                               " (" & r.cc & ", " & $par & " at a time)", sev: 3, line: -1))
  let sf = dir / "ned-build.sh"
  try: writeFile(sf, script)
  except CatchableError as e:
    ncStop(r, "Coverage stopped: " & e.msg)
    return
  let j = startJob(jkRun, "sh " & quoteShell(sf), cwd, proc(j: Job) =
    if j.partial.len > 0:
      addRunLine(j, j.partial)
      j.partial = ""
    try: removeFile(sf)
    except OSError: discard
    if nimCovRun != r: return
    if ncKilled(j):
      ncStop(r, "Coverage stopped")
      return
    if j.code != 0:
      inc r.broken
      if "clang_rt.profile" in j.output or "libclang_rt" in j.output:
        addPanelLine(PanelLine(text: "  ✗ clang's profile runtime (libclang_rt.profile) is missing — Termux: pkg " &
                                     "install libcompiler-rt · Debian/Ubuntu: apt install libclang-rt-" &
                                     (if r.ccVer.len > 0: r.ccVer & "-" else: "") & "dev", sev: 1, line: -1))
      else: addPanelLine(PanelLine(text: "  ✗ the C build of " & relPath(test) & " failed", sev: 1, line: -1))
      ncNext(r)
      return
    try:
      # the recipe told the program's new time: with nothing changed, the compiler skips its work next time
      # (-d:nimBetterRun compares it)
      let jf = dir / (name & ".json")
      let jr = parseFile(jf)
      jr["outputLastModificationTime"] = %($getLastModificationTime(exe))
      let text = jr.pretty
      writeFile(jf, text)
      writeFile(dir / "ned-link.txt", linkCmd)
      writeFile(dir / "ned-built.txt", covHash(text))
    except CatchableError: discard
    ncRunTest(r, test, dir, exe, cwd))
  if j == nil: ncStop(r, "Coverage stopped: sh did not start")

proc ncBuild(r: NimCovRun, test: string) =
  ## the C of one test program and its build recipe, in its kept nimcache
  let dir = privDir() / "ned_cov" / covCacheName(rootDir) / covCacheName(test)
  try:
    if (try: readFile(dir / "ned-cov-version") except CatchableError: "") != CovCacheVersion:
      removeDir(dir)
      createDir(dir)
      writeFile(dir / "ned-cov-version", CovCacheVersion)
  except CatchableError as e:
    ncStop(r, "Coverage stopped: " & e.msg)
    return
  let name = splitFile(test).name
  let flags = (if cfgNimTestFlags.len > 0: " " & cfgNimTestFlags else: "") &
              (if cfgNimFlags.len > 0: " " & cfgNimFlags else: "") & (if isTestamentTest(test): " -d:testing" else: "")
  let cmd = "nim c --compileOnly -d:nimBetterRun --colors:off" & flags & " --debugger:off --lineDir:on --opt:none " &
            "--stackTrace:on --lineTrace:on --passC:-O0 --passC:--coverage --passL:--coverage " &
            "--nimcache:" & quoteShell(dir) & " -o:" & quoteShell(dir / name) & " " & quoteShell(test)
  let nth = if r.tests.len > 1: "  (" & $(r.tests.len - r.queue.len) & " of " & $r.tests.len & ")" else: ""
  addPanelLine(PanelLine(text: "▶ " & relPath(test) & nth, sev: 5, line: -1))
  info("Coverage: building " & extractFilename(test) & "…")
  let j = startJob(jkRun, cmd, parentDir(test), proc(j: Job) =
    if j.partial.len > 0:
      addRunLine(j, j.partial)
      j.partial = ""
    if nimCovRun != r: return
    if ncKilled(j):
      ncStop(r, "Coverage stopped")
      return
    if j.code != 0:
      inc r.broken
      addPanelLine(PanelLine(text: "  ✗ " & relPath(test) & " does not compile", sev: 1, line: -1))
      ncNext(r)
      return
    ncCompileC(r, test, dir, name))
  if j == nil: ncStop(r, "Coverage stopped: nim did not start")

proc covPanel()

proc ncFinish(r: NimCovRun) =
  ## the counts in the gutter (and the procs no test reaches, red), the project's total, the summary by file
  if nimCovRun == r: nimCovRun = nil
  covLines.clear()
  covUnreached.clear()
  covNotBuilt.setLen(0)
  covHits = r.hits
  covWhat = r.what
  var files: seq[string]
  for f in r.hits.keys: files.add f
  for f in r.compiled:
    if f notin r.hits: files.add f
  for file in files:
    let t = r.hits.getOrDefault(file)
    let lines = covFileLines(file)
    var m = initTable[int, bool]()
    for ln, cnt in t:
      if ln - 1 < lines.len:
        let s = lines[ln - 1].strip
        if covNoCodeLine(s): continue              # (blank, a comment, else:, of, when, type … : no code)
      m[ln - 1] = cnt > 0
    # Nim leaves out of the C what no one calls: a proc of a tested module with no line in the data never ran
    var inactive: seq[(int, int)]
    try:
      let f = nxLoad(file)
      if f != nil: inactive = nxInactiveWhen(f, lines)
    except CatchableError: discard
    for sp in nimRoutineSpans(lines, inactive):
      var seen = false
      for l in sp.first .. sp.last:
        if (l + 1) in t:
          seen = true
          break
      if seen: continue
      covUnreached.mgetOrPut(file, @[]).add (sp.name, sp.first)
      for l in sp.code:
        if l notin m: m[l] = false
    if m.len > 0: covLines[file] = m
  # the project's own files no test compiles (listed, not counted)
  let src = if nimble.srcDir.len > 0 and nimble.dir == rootDir: nimble.srcDir & "/" else: ""
  for rel in projectFiles():
    if not rel.endsWith(".nim") or (src.len > 0 and not rel.startsWith(src)): continue
    var skip = false
    for c in rel.split('/')[0 ..< ^1]:
      if c in CovSkipDirs: skip = true
    let p = rootDir / rel
    if skip or p in covLines or p in r.compiled or covIsTestFile(p, r.tests): continue
    if covNotBuilt.len < 500: covNotBuilt.add p
  var total, ran = 0
  for _, t in covLines:
    for _, v in t:
      inc total
      if v: inc ran
  let secs = formatFloat(float(msSince(r.started)) / 1000.0, ffDecimal, 1)
  var tally: seq[string]
  if r.passed > 0: tally.add $r.passed & " passed"
  if r.failed > 0: tally.add $r.failed & " failed"
  if r.broken > 0: tally.add $r.broken & " did not build"
  addPanelLine(PanelLine(text: (if r.failed + r.broken == 0: "✓ " else: "✗ ") & "coverage of " & r.what & ": " &
                               tally.join(", ") & " · C: " & $r.built & " compiled, " & $r.kept & " kept · " &
                               secs & "s",
                         sev: (if r.failed + r.broken == 0: 4 else: 1), line: -1))
  if total == 0:
    error("No coverage data — see the Output panel")
    needRender = true
    return
  info("Coverage: " & $(ran * 100 div total) & "% of " & $total & " lines ran (" & $covLines.len &
       (if covLines.len == 1: " file, " else: " files, ") & r.what &
       ", " & secs & "s) — green line numbers ran, red never did · palette › Test coverage: summary by file")
  covPanel()

proc ncNext(r: NimCovRun) =
  if nimCovRun != r: return
  if r.queue.len == 0:
    ncFinish(r)
    return
  let t = r.queue[0]
  r.queue.delete(0)
  r.deps.setLen(0)
  ncBuild(r, t)

proc nimCovStart(files: seq[string], what: string, program = false) =
  ## build each with coverage, run it, count: one after another, into one result (a program: its own lines count)
  if files.len == 0: return
  if nimCovRun != nil:
    info("Coverage is running already — Run › Stop running process ends it")
    return
  if not haveExe("nim"):
    error("nim not found")
    return
  if not haveExe("gcov") and not haveExe("llvm-cov") and not haveExe("xcrun"):
    error("Nim test coverage needs gcov (it comes with gcc) or llvm-cov (Termux: pkg install llvm · Debian/Ubuntu: " &
          "apt install llvm)")
    return
  for f in files:
    if not codeTrusted(parentDir(f)):
      askTrust(parentDir(f))
      return
  discard saveAll()
  let r = NimCovRun(queue: files, tests: (if program: @[] else: files), started: getMonoTime(), what: what)
  try: r.realRoot = expandFilename(rootDir)
  except CatchableError: r.realRoot = rootDir
  r.libDir = nimLibDir()
  loadNimbleInfo()
  # the kept builds of other projects not used for two weeks go
  try:
    for kind, d in walkDir(privDir() / "ned_cov"):
      if kind == pcDir and getTime() - getLastModificationTime(d) > initDuration(days = 14): removeDir(d)
    let mine = privDir() / "ned_cov" / covCacheName(rootDir)
    createDir(mine)
    setLastModificationTime(mine, getTime())
  except CatchableError: discard
  nimCovRun = r
  let old = runningJob()
  if old != nil: killProc(old.pr)
  diagsBuild.clear()
  panelKind = pkOutput
  panelLines = @[PanelLine(text: "▶ test coverage: " & what & " — built with gcov's counters, kept between runs",
                           sev: 5, line: -1)]
  panelTitle = "OUTPUT"
  panelOpen = true
  panelFollow = true
  panelSel = 0
  ncNext(r)

proc cmdCoverageTestFile(path: string) =
  ## one Nim test file with coverage (the test explorer: c)
  if not path.endsWith(".nim"):
    info("Test coverage from the explorer is for Nim test files — Test coverage: run covers the others")
    return
  nimCovStart(@[path], extractFilename(path))

proc cmdCoverageNimAll() =
  ## all the project's Nim tests with coverage, into one result
  let tests = nimCovTestFiles()
  if tests.len == 0:
    let b = buf()
    if b.lang.mode == lmNim and b.path.len > 0:
      let main = if isNimProgram(b): b.path else: nimProjectFile(b)
      nimCovStart(@[main], extractFilename(main), program = true)
    else: info("No Nim tests found (tests/t*.nim, std/unittest blocks, testament specs)")
    return
  nimCovStart(tests, (if tests.len == 1: extractFilename(tests[0]) else: $tests.len & " test files"))

proc cmdCoverage() =
  ## Nim: test coverage — of this test file; of the program this is; else of the project's tests
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open the Nim test (or program) to measure")
    return
  let tests = nimCovTestFiles()
  if b.path in tests: nimCovStart(@[b.path], extractFilename(b.path))
  elif isNimProgram(b) or tests.len == 0:
    let main = if isNimProgram(b): b.path else: nimProjectFile(b)
    nimCovStart(@[main], extractFilename(main), program = true)
  else: nimCovStart(tests, (if tests.len == 1: extractFilename(tests[0]) else: $tests.len & " test files"))

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

proc covPanel() =
  ## Test coverage: summary by file — each file's share of lines that ran (the least first), the procs no test
  ## reaches, the project's files no test compiles, the total; Enter opens a file at its first line that never ran
  if covLines.len == 0:
    info("No coverage yet — Test coverage: run")
    return
  var rows: seq[(int, int, int, string, int)]          # (per mille, ran, lines, file, first line that never ran)
  var total, ran = 0
  for f, t in covLines:
    var fr, ft = 0
    var first = -1
    for l, v in t:
      inc ft
      if v: inc fr
      elif first < 0 or l < first: first = l
    if ft == 0: continue
    total += ft
    ran += fr
    rows.add (fr * 1000 div ft, fr, ft, f, first)
  rows.sort(proc(a, b: (int, int, int, string, int)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmp(relPath(a[3]), relPath(b[3])))
  let pct = if total > 0: ran * 100 div total else: 0
  panelKind = pkSearch
  panelLines.setLen(0)
  panelLines.add PanelLine(text: "   ran    lines   file   (" & (if covWhat.len > 0: covWhat & " · " else: "") &
                                 "green line numbers ran, red never did · Enter: the first line that never ran)",
                           sev: 5, line: -1)
  for (pm, fr, ft, f, first) in rows:
    panelLines.add PanelLine(text: align($(pm div 10) & "%", 6) & align($fr & "/" & $ft, 10) & "   " & relPath(f) &
                                   (if fr == ft: "" elif first >= 0: "   (first: line " & $(first + 1) & ")" else: ""),
                             path: f, line: max(first, 0), sev: (if fr == ft: 4 elif fr == 0: 1 else: 0))
    let un = covUnreached.getOrDefault(f)
    for k, (name, l) in un:
      if k == 8:
        panelLines.add PanelLine(text: "                   … and " & $(un.len - 8) & " more no test reaches", path: f,
                                 line: un[8][1], sev: 2)
        break
      panelLines.add PanelLine(text: "                   ✗ " & name & " (line " & $(l + 1) & ") — no test reaches " &
                                     "it", path: f, line: l, sev: 2)
  for f in covNotBuilt:
    panelLines.add PanelLine(text: "     –            " & relPath(f) & " — no test compiles it (not counted)",
                             path: f, line: 0, sev: 2)
  panelLines.add PanelLine(text: "  total " & $pct & "%: " & $ran & " of " & $total & " lines ran in " & $rows.len &
                                 " file(s)", sev: 5, line: -1)
  panelTitle = "COVERAGE · " & $pct & "%"
  panelOpen = true
  panelFollow = false
  panelSel = 0
  needRender = true

proc covSummary(what: string, j: Job) =
  covWhat = what
  covUnreached.clear()
  covNotBuilt.setLen(0)
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
    cmdCoverageNimAll()              # (the project's tests; with none, this program)
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
    elif nimCovTestFiles().len > 0: cmdCoverageNimAll()     # (a Nim project, another file open)
    else: info("No coverage tool for " & b.lang.name & " — Test coverage: load an lcov file… reads one any tool wrote")
