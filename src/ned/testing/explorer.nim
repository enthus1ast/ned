# the test explorer: running every test of the project, the list of tests with their status in the side panel, and the
# run buttons (code lenses) shown on test lines in the editor
proc runAllTests() =
  ## runs every test of the project the way its kind of project does it: the hastur files of a Nim 3 project; the Cargo,
  ## Go, PHP, JVM, .NET or Python runner when there is no nimble file (the results are read back from its output for
  ## every test file); else `nimble test`, testament specs, or each std/unittest file with `nim c -r`
  loadNimbleInfo()
  if nim3On():
    # a Nim 3 project: its hastur tests (not `nimble test`, which is Nim 2's)
    if not testScanned: rescanTests()
    var hast: seq[string]
    for e in testEntries:
      if e.name == HasturName and e.path notin hast: hast.add e.path
    if hast.len > 0:
      runHasturFiles(hast)
      return
  if nimble.file.len == 0:
    # a Rust, Go or Python project: its own runner, and every file's results from its output
    if not testScanned: rescanTests()
    var kind = ""
    var hasCs = false
    try:
      for k, f in walkDir(rootDir):
        if k == pcFile and (f.endsWith(".sln") or f.endsWith(".csproj")): hasCs = true
    except OSError: discard
    if fileExists(rootDir / "Cargo.toml"): kind = "rs"
    elif fileExists(rootDir / "go.mod"): kind = "go"
    elif fileExists(rootDir / "composer.json") or fileExists(rootDir / "phpunit.xml") or
         fileExists(rootDir / "phpunit.xml.dist"): kind = "php"
    elif fileExists(rootDir / "settings.gradle.kts") or fileExists(rootDir / "settings.gradle") or
         fileExists(rootDir / "build.gradle.kts") or fileExists(rootDir / "build.gradle") or
         fileExists(rootDir / "pom.xml"): kind = "jvm"
    elif hasCs: kind = "cs"
    else:
      for e in testEntries:
        if testLangOf(e.path) == "py": kind = "py"
    if kind.len > 0:
      let cmd = case kind
        of "rs": "cargo test 2>&1"
        of "go": "go test -v ./..."
        of "php":
          let runner = if fileExists(rootDir / "vendor" / "bin" / "phpunit"): "vendor/bin/phpunit" else: "phpunit"
          "rm -f " & quoteShell(tmpDir() / "ned-junit.xml") & "; " & runner & " --log-junit " &
            quoteShell(tmpDir() / "ned-junit.xml") & " 2>&1"
        of "cs": "dotnet test --logger \"console;verbosity=normal\" 2>&1"
        of "jvm":
          if fileExists(rootDir / "pom.xml") and not fileExists(rootDir / "build.gradle") and
             not fileExists(rootDir / "build.gradle.kts"): "mvn -q test 2>&1"
          else: (if fileExists(rootDir / "gradlew"): "./gradlew" else: "gradle") & " test --console=plain 2>&1"
        else: otherTestCmd(rootDir / "x.py", "")[0].replace(" " & quoteShell(rootDir / "x.py"), "")
      for e in testEntries:
        if testLangOf(e.path) == kind: testStatus[testKey(e.path, e.name)] = 3
      runCommand(cmd, rootDir)
      let j = runningJob()
      if j != nil:
        let prev = j.onDone
        j.onDone = proc(jj: Job) =
          if prev != nil: prev(jj)
          var done: seq[string]
          for e in testEntries:
            if testLangOf(e.path) == kind and e.path notin done:
              done.add e.path
              parseOtherTestOutput(e.path, jj.output)
          for e in testEntries:
            if testStatus.getOrDefault(testKey(e.path, e.name)) == 3: testStatus.del testKey(e.path, e.name)
          needRender = true
      return
  if nimble.file.len > 0 and haveExe("nimble"):
    runNimble("test")
    let j = runningJob()
    if j != nil:                                  # a test task that runs testament: its PASS/FAIL lines too
      let prev = j.onDone
      j.onDone = proc(jj: Job) =
        if prev != nil: prev(jj)
        parseTestamentOutput(rootDir, jj.output)
        needRender = true
    return
  if not testScanned: rescanTests()
  var files, specs, hast: seq[string]
  for e in testEntries:
    if e.name == TestamentName:
      if e.path notin specs: specs.add e.path
    elif e.name == HasturName:
      if e.path notin hast: hast.add e.path
    elif e.path notin files: files.add e.path
  if specs.len > 0 and files.len == 0 and hast.len == 0:
    runTestamentFiles(specs)
    return
  if hast.len > 0 and files.len == 0 and specs.len == 0:
    runHasturFiles(hast)          # (a Nim 3 project's tests: each with what it should print beside it)
    return
  if files.len == 0:
    info("No tests found (std/unittest `test \"name\":` blocks in tests/)")
    return
  var cmd = ""
  for f in files:
    if cmd.len > 0: cmd.add " && "
    cmd.add "nim c -r --hints:off " & quoteShell(f)
  runCommand(cmd, rootDir)

func testAct(p, n: string, line: int, isS: bool): Action =
  ## the action for a test's row: opens its file and centres on the test's line, then runs the test (name `n`) or, for a
  ## suite or file row, the whole file
  proc() =
    if line >= 0:
      let b = openFile(p)
      if b != nil: b.centerOn(Pos(line: line, col: 0))
    if not isS: runTests(p, n) else: runTests(p)

proc buildTestItems(): seq[SideItem] =
  ## the rows of the test list in the side panel: one per test file, then its suites and tests, each with an icon for
  ## its last result (passed, failed, running, skipped, not run) and its line; with no tests found, a hint and a button
  ## that creates tests/test1.nim
  if not testScanned: rescanTests()
  if testEntries.len == 0:
    return @[sideItem("No tests found", 2), sideItem("std/unittest `test \"name\":` blocks in tests/ are listed here", 2),
             sideItem("Create tests/test1.nim", 0, "+", "", proc() =
               let p = rootDir / "tests" / "test1.nim"
               try:
                 createDir(parentDir(p))
                 if not fileExists(p):
                   writeFile(p, "import std/unittest\n\nsuite \"basics\":\n  test \"one plus one\":\n    check 1 + 1 == 2\n")
                   fileWritten(p)
                 discard openFile(p)
                 rescanTests()
               except CatchableError as e: error(e.msg))]
  var last = ""
  for e in testEntries:
    if e.path != last:
      last = e.path
      result.add sideItem(relPath(e.path), 0, ic("run"), "run file", testAct(e.path, "", -1, true), e.path, 0, 0, "file")
    let st = testStatus.getOrDefault(testKey(e.path, e.name))
    let (icn, role) = case st
      of 1: (ic("ok"), 5)
      of 2: ("✗", 3)
      of 3: ("…", 1)
      of 4: ("–", 2)
      else: ((if e.isSuite: "◇" else: "○"), 2)
    result.add sideItem(e.name, (if st == 0: (if e.isSuite: 8 else: 0) else: role), icn, "line " & $(e.line + 1),
                        testAct(e.path, e.name, e.line, e.isSuite), e.path, e.line, (if e.isSuite: 1 else: 2))

proc lensAt(b: Buffer, l: int): (string, Action) =
  ## runnable things on a line: test / suite / isMainModule / proc main (Nim), tests in Python, Go and Rust
  if not cfgCodeLens or b.path.len == 0: return ("", nil)
  let p = b.path
  if replMarker(b.lines[l]) and b.lang.lineComment.len > 0 and b.lines[l].strip.startsWith(b.lang.lineComment):
    let (bb, ll) = (b, l)
    # a # %% cell: run in the notebook (Nim, Python: its output under it), else sent to the REPL
    if nbCanRun(b): return (ic("run"), proc() = nbRunAt(bb, ll + 1))
    return (ic("run"), proc() = replSendCell(bb, ll))
  if b.lang.mode != lmNim:
    if testLangOf(p) notin ["py", "go", "rs", "php", "cs", "jvm"]: return ("", nil)
    let (tn, _) = b.otherTestAt(l)
    if tn.len == 0: return ("", nil)
    let st = testStatus.getOrDefault(testKey(p, tn))
    return ((if st == 1: ic("ok") elif st == 2: "✗" elif st == 3: "…" else: ic("run")), proc() = runTests(p, tn))
  let t = b.lines[l].strip
  if t.startsWith("discard \"\"\"") and ("tests" & DirSep) in p and testamentSpecLine(b.lines) == l:
    let st = testStatus.getOrDefault(testKey(p, TestamentName))    # a testament spec: run this test file
    return ((if st == 1: ic("ok") elif st == 2: "✗" elif st == 3: "…" else: ic("run")), proc() = runTestamentFiles(@[p]))
  let tn = quotedName(t, "test ")
  if tn.len > 0:
    let st = testStatus.getOrDefault(testKey(p, tn))
    return ((if st == 1: ic("ok") elif st == 2: "✗" elif st == 3: "…" else: ic("run")), proc() = runTests(p, tn))
  if quotedName(t, "suite ").len > 0: return (ic("run"), proc() = runTests(p))
  if t.startsWith("when isMainModule"): return (ic("run"), proc() = runCurrent())
  if examplesHead(t):
    let st = exampleStatus.getOrDefault(p & ":" & $l)
    let (bb, ll) = (b, l)
    return ((if st == 1: ic("ok") elif st == 2: "✗" elif st == 3: "…" else: ic("run")), proc() = runExamples(bb, ll))
  ("", nil)
