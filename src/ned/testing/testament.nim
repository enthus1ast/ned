# ── testament (the Nim compiler's test runner): a file whose first statement is a `discard """…"""` spec ──

const TestamentName = "testament"

func testamentSpecLine(lines: seq[string]): int =
  ## the line of a testament spec at the top of a file, -1 when there is none
  for i, l in lines:
    let t = l.strip
    if t.len == 0 or t.startsWith("#"): continue
    return (if t.startsWith("discard \"\"\"") or t.startsWith("discard \"\"\"\""): i else: -1)
  -1

proc isTestamentTest(path: string): bool =
  ## whether the file was scanned as a testament test (it has an entry named testament)
  for e in testEntries:
    if e.path == path and e.name == TestamentName: return true
  false

proc testamentRoot(path: string): string =
  ## testament runs from the folder that holds tests/
  var d = parentDir(path)
  while d.len > 1 and d != parentDir(d):
    if extractFilename(d) == "tests": return parentDir(d)
    d = parentDir(d)
  rootDir

proc testamentSpec(lines: seq[string]): Table[string, string] =
  ## the spec's keys (output, exitcode, action, errormsg, line, outputsub, disabled …); multi-line values too
  let at = testamentSpecLine(lines)
  if at < 0: return
  var body = lines[at].strip
  body = body["discard".len .. ^1].strip
  var i = at
  var text = ""
  if body.startsWith("\"\"\""):
    text = body[3 .. ^1]
    var closed = text.find("\"\"\"")
    while closed < 0 and i < lines.high:
      inc i
      text.add "\n" & lines[i]
      closed = text.find("\"\"\"")
    if closed >= 0: text = text[0 ..< closed]
  let ls = text.splitLines
  var k = 0
  while k < ls.len:
    let l = ls[k]
    let c = l.find(':')
    if c <= 0 or l.strip.startsWith("#"):
      inc k
      continue
    let key = l[0 ..< c].strip.toLowerAscii
    var v = l[c + 1 .. ^1].strip
    if v.startsWith("\'\'\'"):
      var acc = v[3 .. ^1]
      var e = acc.find("\'\'\'")
      while e < 0 and k < ls.high:
        inc k
        acc.add "\n" & ls[k]
        e = acc.find("\'\'\'")
      if e >= 0: acc = acc[0 ..< e]
      if acc.startsWith("\n"): acc = acc[1 .. ^1]
      v = acc
    elif v.len >= 2 and v[0] == '"' and v[^1] == '"':
      v = v[1 ..< ^1].replace("\\n", "\n").replace("\\\"", "\"")
    result[key] = v
    inc k

proc parseTestamentOutput(root, output: string) =
  ## PASS: tests/x/t1.nim c … / FAIL: … / SKIP: …
  for raw in output.splitLines:
    let l = stripAnsi(raw).strip
    for (w, v) in [("PASS: ", 1), ("FAIL: ", 2), ("SKIP: ", 4)]:
      if l.startsWith(w):
        let rel = l[w.len .. ^1].firstWord.strip(chars = {'[', ']'})
        let full = (if rel.isAbsolute: rel else: root / rel).normalizedPath
        let k = testKey(full, TestamentName)
        if v == 2 or testStatus.getOrDefault(k) != 2 or testStatus.getOrDefault(k) == 3: testStatus[k] = v

proc testamentJudge(spec: Table[string, string], compiled: bool, compileOut, runOut: string,
                    code: int): (bool, string) =
  ## ned's own check of a testament spec (when testament itself is not installed)
  let action = spec.getOrDefault("action", (if "errormsg" in spec: "reject" else: "run")).strip(chars = {'"'})
  if spec.getOrDefault("disabled").strip(chars = {'"'}).toLowerAscii in ["true", "on", "yes"]: return (true, "disabled")
  case action
  of "reject":
    if compiled: return (false, "expected a compile error, but it compiled")
    let want = spec.getOrDefault("errormsg")
    if want.len > 0 and want notin compileOut: return (false, "expected the error: " & want)
    let wl = spec.getOrDefault("line")
    if wl.len > 0 and want.len > 0:
      var seen = false
      for l in compileOut.splitLines:
        if want in l and ("(" & wl & ",") in l: seen = true
      if not seen: return (false, "the error is not on line " & wl)
    (true, "")
  of "compile":
    if not compiled: return (false, "it does not compile")
    (true, "")
  else:
    if not compiled: return (false, "it does not compile")
    let wantCode = (try: parseInt(spec.getOrDefault("exitcode", "0").strip(chars = {'"'})) except ValueError: 0)
    if code != wantCode: return (false, "exit code " & $code & ", expected " & $wantCode)
    let got = runOut.replace("\r\n", "\n").strip
    if "output" in spec and got != spec["output"].replace("\r\n", "\n").strip:
      return (false, "the output differs:\n  expected: " & spec["output"].strip.replace("\n", "⏎") &
                     "\n  got:      " & got.replace("\n", "⏎"))
    if "outputsub" in spec and spec["outputsub"] notin got: return (false, "the output lacks: " & spec["outputsub"])
    (true, "")

type TtRun = ref object         # ned's own testament runner: the files still to run, the tally
  queue: seq[string]
  ok, bad: int
  root: string

proc ttNext(r: TtRun) =
  ## ned's own testament runner, one file at a time: compiles the next file of the queue and, unless its spec only
  ## expects a compile or a rejection, runs it, then judges the result against the spec and writes PASS, FAIL or SKIP to
  ## the Output panel; when the queue is empty it writes the tally and shows a message
  if r.queue.len == 0:
    addPanelLine(PanelLine(text: (if r.bad == 0: "✓ " else: "✗ ") & $r.ok & " passed, " & $r.bad & " failed",
                           sev: (if r.bad == 0: 4 else: 1), line: -1))
    if r.bad > 0: toast($r.bad & " testament test(s) failed", 1, "Show", proc() = setPanel(pkOutput))
    else: toast($r.ok & " testament test(s) passed", 4)
    needRender = true
    return
  let f = r.queue[0]
  r.queue.delete(0)
  let lines = try: readFile(f).splitLines except CatchableError: @[]
  let spec = testamentSpec(lines)
  let exe = privDir() / ("ned_tt_" & splitFile(f).name) & ExeDot
  let compile = "nim c --hints:off --warnings:off --colors:off -d:testing --nimcache:" &
                quoteShell(privDir() / "tt_cache" / splitFile(f).name) & " -o:" & quoteShell(exe) & " " & quoteShell(f)
  proc finish(compiled: bool, compileOut, runOut: string, code: int) =
    ## records one file's result: judges it against its spec, marks the test passed, failed or skipped, writes the
    ## result line (and the reason, with the compiler's output when it did not compile) to the panel, and goes on to the
    ## next file
    let (pass, why) = testamentJudge(spec, compiled, compileOut, runOut, code)
    testStatus[testKey(f, TestamentName)] = (if why == "disabled": 4 elif pass: 1 else: 2)
    if pass: inc r.ok else: inc r.bad
    addPanelLine(PanelLine(text: (if why == "disabled": "SKIP: " elif pass: "PASS: " else: "FAIL: ") &
                                 relativePath(f, r.root), path: f, line: 0, sev: (if pass: 4 else: 1)))
    if not pass:
      for l in why.splitLines: addPanelLine(PanelLine(text: "    " & l, line: -1))
      if not compiled:
        for l in compileOut.strip.splitLines:
          if l.len > 0: addPanelLine(PanelLine(text: "    " & l, line: -1))
    needRender = true
    ttNext(r)
  let action = spec.getOrDefault("action", (if "errormsg" in spec: "reject" else: "run")).strip(chars = {'"'})
  let j = startJob(jkTool, compile & " 2>&1", parentDir(f), proc(cj: Job) =
    let compiled = cj.code == 0
    if not compiled or action in ["reject", "compile"]: finish(compiled, cj.output, "", cj.code)
    else:
      let rj = startJob(jkTool, quoteShell(exe) & " 2>&1", parentDir(f), proc(rj: Job) =
        finish(true, cj.output, rj.output, rj.code))
      if rj == nil: finish(true, cj.output, "could not start the test program", 1))
  if j == nil: finish(false, "could not start nim", "", 1)

proc runTestamentFiles(files: seq[string]) =
  ## testament's own runner when it is installed; else ned checks each spec (output, exitcode, reject …)
  if files.len == 0: return
  discard saveAll()
  for f in files: testStatus[testKey(f, TestamentName)] = 3
  let root = testamentRoot(files[0])
  if haveExe("testament"):
    var parts: seq[string]
    for f in files: parts.add "testament --colors:off r " & quoteShell(relativePath(f, root))
    let cmd = parts.join("; ")
    runCommand(cmd, root)
    let j = runningJob()
    if j != nil:
      let prev = j.onDone
      j.onDone = proc(jj: Job) =
        if prev != nil: prev(jj)
        parseTestamentOutput(root, jj.output)
        var ok, bad = 0
        for f in files:
          let k = testKey(f, TestamentName)
          if testStatus.getOrDefault(k) == 3: testStatus[k] = (if jj.code == 0: 1 else: 2)
          if testStatus[k] == 1: inc ok elif testStatus[k] == 2: inc bad
        if bad > 0: toast($bad & " testament test(s) failed", 1, "Show", proc() = setPanel(pkOutput))
        elif ok > 0: toast($ok & " testament test(s) passed", 4)
        needRender = true
    return
  if not haveExe("nim"):
    error("nim not found")
    return
  panelKind = pkOutput
  panelLines = @[PanelLine(text: "▶ testament specs (ned's runner — testament is not installed)", sev: 5, line: -1)]
  panelTitle = "OUTPUT"
  panelOpen = true
  panelFollow = true
  panelSel = 0
  ttNext(TtRun(queue: files, root: root))

# ── hastur (Nimony's test runner), in a Nim 3 project: a test file in tests/ with what it should print beside it
#    (`t1.output`) or the compiler's messages it should give (`t1.msgs`) ──

const HasturName = "hastur"

proc hasturExe(): string =
  ## Nimony's hastur: beside the nimony in use, else on PATH ("" when there is none)
  let n = nimonyExe()
  if n.len > 0:
    let h = parentDir(n) / addFileExt("hastur", ExeExt)
    if fileExists(h): return h
  findExe("hastur")

proc hasturTestFile(path: string): bool =
  ## whether the file is a hastur test of a Nim 3 project: a .nim file under tests/ with a .output or .msgs file beside
  ## it
  nim3On() and path.endsWith(".nim") and ("tests" & DirSep) in path and
    (fileExists(path.changeFileExt("output")) or fileExists(path.changeFileExt("msgs")))

proc isHasturTest(path: string): bool =
  ## whether the file was scanned as a hastur test (it has an entry named hastur)
  for e in testEntries:
    if e.path == path and e.name == HasturName: return true
  false

proc runHasturFiles(files: seq[string]) =
  ## each file with `hastur test` (from the folder that holds tests/): ✓ or ✗ by what hastur says of it
  if files.len == 0: return
  let h = hasturExe()
  if h.len == 0:
    error("hastur not found (it is built with Nimony: hastur build all)")
    return
  discard saveAll()
  let root = testamentRoot(files[0])
  var parts: seq[string]
  for f in files:
    testStatus[testKey(f, HasturName)] = 3
    let rel = relativePath(f, root)
    # (each one's exit status marked in the output: one run holds them all)
    # (its build files in ned's own folder, not a nimcache/ in the project)
    parts.add quoteShell(h) & " --cachedir:" & quoteShell(privDir() / "nimony" / ("hastur-" & nimonyKey(root))) &
              " test " & quoteShell(rel) & " 2>&1; echo \"[hastur] $? " & rel & "\""
  runCommand(parts.join("; "), root)
  let j = runningJob()
  if j == nil: return
  let prev = j.onDone
  j.onDone = proc(jj: Job) =
    if prev != nil: prev(jj)
    var ok, bad = 0
    for raw in jj.output.splitLines:
      let l = stripAnsi(raw).strip
      if not l.startsWith("[hastur] "): continue
      let rest = l["[hastur] ".len .. ^1]
      let sp = rest.find(' ')
      if sp <= 0: continue
      let f = normalizedPath(root / rest[sp + 1 .. ^1])
      let pass = rest[0 ..< sp] == "0"
      testStatus[testKey(f, HasturName)] = (if pass: 1 else: 2)
      if pass: inc ok else: inc bad
    for f in files:
      if testStatus.getOrDefault(testKey(f, HasturName)) == 3: testStatus.del testKey(f, HasturName)
    if bad > 0: toast($bad & " hastur test(s) failed", 1, "Show", proc() = setPanel(pkOutput))
    elif ok > 0: toast($ok & " hastur test(s) passed", 4)
    needRender = true

proc scanTestFile(path: string, lines: seq[string]): seq[TestEntry] =
  ## the tests of a file, from its text: for a Nim file a testament or hastur entry when it is one, then its `suite` and
  ## `test` blocks (each test with the suite it is under); other languages go to scanOtherTests
  if not path.endsWith(".nim"): return scanOtherTests(path, lines)
  let sl = testamentSpecLine(lines)
  if sl >= 0 and ("tests" & DirSep) in path:
    result.add TestEntry(path: path, name: TestamentName, line: sl)
  elif hasturTestFile(path):
    result.add TestEntry(path: path, name: HasturName, line: 0)
  var suite = ""
  var suiteInd = -1
  for i, l in lines:
    let t = l.strip(trailing = false)
    let ind = l.len - t.len
    if suiteInd >= 0 and ind <= suiteInd and t.len > 0 and not t.startsWith("test"):
      suite = ""
      suiteInd = -1
    let sn = quotedName(t, "suite ")
    if sn.len > 0:
      suite = sn
      suiteInd = ind
      result.add TestEntry(path: path, name: sn, line: i, isSuite: true)
      continue
    let tn = quotedName(t, "test ")
    if tn.len > 0: result.add TestEntry(path: path, name: tn, suite: suite, line: i)

proc rescanTests() =
  ## builds the list of tests again: picks the project's test files by language and naming rules (and the file now open
  ## if it is a test file), reads them from their buffers or from disk (files over 2 MB skipped), and scans each
  testEntries.setLen(0)
  var files: seq[string]
  for rel in projectFiles():
    let base = extractFilename(rel)
    let inTests = rel.startsWith("tests/") or rel.startsWith("test/")
    if rel.endsWith(".nim"):
      if inTests or base.startsWith("test") or base.startsWith("t_"): files.add rootDir / rel
    elif rel.endsWith(".py"):
      if base.startsWith("test_") or base.endsWith("_test.py") or (inTests and base.startsWith("test")): files.add rootDir / rel
    elif rel.endsWith("_test.go"): files.add rootDir / rel
    elif rel.endsWith("Test.php") or rel.endsWith("Tests.php"): files.add rootDir / rel
    elif (rel.endsWith(".kt") or rel.endsWith(".java")) and ("/test/" in "/" & rel or base.endsWith("Test.kt") or
          base.endsWith("Test.java") or base.endsWith("Tests.kt") or base.endsWith("Tests.java")): files.add rootDir / rel
    elif rel.endsWith(".cs") and files.len < 2000 and (inTests or "Test" in rel):
      try:
        if getFileSize(rootDir / rel) < 1_000_000:
          let t = readFile(rootDir / rel)
          if "[Fact" in t or "[Test" in t or "[Theory" in t: files.add rootDir / rel
      except CatchableError: discard
    elif rel.endsWith(".rs") and files.len < 2000:
      try:
        if getFileSize(rootDir / rel) < 1_000_000 and "#[" in readFile(rootDir / rel) and
           "test]" in readFile(rootDir / rel): files.add rootDir / rel
      except CatchableError: discard
  let cb = buf()
  if testLangOf(cb.path).len > 0 and cb.path notin files: files.add cb.path
  for f in files:
    try:
      let bi = bufIndexByPath(f)
      let lines = if bi >= 0: bufs[bi].lines elif getFileSize(f) < 2_000_000: readFile(f).splitLines else: @[]
      testEntries.add scanTestFile(f, lines)
    except CatchableError: discard
  testScanned = true
  needRender = true

proc parseTestOutput(path, output: string) =
  ## sets the status of a file's tests from a run's output: the `[OK]`, `[FAILED]` and `[SKIPPED]` lines of std/unittest
  ## (other languages go to parseOtherTestOutput)
  if not path.endsWith(".nim"):
    parseOtherTestOutput(path, output)
    return
  for raw in output.splitLines:
    let l = stripAnsi(raw).strip
    for (tag, st) in [("[OK]", 1), ("[FAILED]", 2), ("[SKIPPED]", 4)]:
      if l.startsWith(tag):
        let name = l[tag.len .. ^1].strip
        testStatus[testKey(path, name)] = st

proc runTests(path: string, filter = "") =
  ## runs a test file, or one test or suite of it named by `filter`, by the right runner (other languages, testament,
  ## hastur, else `nim c -r` with the name as argument) after saving all files; the tests show as running, and when the
  ## job ends their results are read from its output and a message tells how many failed or passed
  if testLangOf(path) in ["py", "go", "rs", "php", "cs", "jvm"]:
    runOtherTests(path, filter)
    return
  if isTestamentTest(path) and (filter.len == 0 or filter == TestamentName):
    runTestamentFiles(@[path])
    return
  if isHasturTest(path) and (filter.len == 0 or filter == HasturName):
    runHasturFiles(@[path])
    return
  if not haveExe("nim"):
    error("nim not found")
    return
  discard saveAll()
  for e in testEntries:
    if e.path == path and (filter.len == 0 or e.name == filter): testStatus[testKey(path, e.name)] = 3
  testRunPath = path
  let flags = (if cfgNimTestFlags.len > 0: " " & cfgNimTestFlags else: "") & (if cfgNimFlags.len > 0: " " & cfgNimFlags else: "")
  var cmd = "nim c -r" & flags & " " & quoteShell(path)
  if filter.len > 0: cmd.add " " & quoteShell(filter)
  runCommand(cmd, parentDir(path))
  let p = path
  let started = getMonoTime()
  # watch the run job and pick up [OK]/[FAILED] lines when it finishes
  let j = runningJob()
  if j != nil:
    let prev = j.onDone
    j.onDone = proc(jj: Job) =
      if prev != nil: prev(jj)
      parseTestOutput(p, jj.output)
      for e in testEntries:
        if e.path == p and testStatus.getOrDefault(testKey(p, e.name)) == 3:
          testStatus[testKey(p, e.name)] = (if jj.code == 0: 1 else: 2)
      discard started
      var ok, bad = 0
      for e in testEntries:
        if e.path == p and not e.isSuite:
          case testStatus.getOrDefault(testKey(p, e.name))
          of 1: inc ok
          of 2: inc bad
          else: discard
      if bad > 0: toast($bad & " test(s) failed in " & extractFilename(p), 1, "Show", proc() = setPanel(pkOutput))
      elif ok > 0: toast($ok & " test(s) passed in " & extractFilename(p), 4)
      needRender = true
