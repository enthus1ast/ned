# ── tests on save: the std/unittest file you save — or, saving a module, the test files that import it — compiled
#    and run in the background (nim.testOnSave): ✓ / ✗ beside each `test`, a failed check's message on its line ──

var
  saveTestRuns: Table[string, Job]          # test file → its run
  saveTestAgain: HashSet[string]            # saved again while it ran: once more when it ends
  saveTestFailed: Table[string, HashSet[string]]   # test file → the tests that failed last time
  testFailLine: Table[string, int]          # "file::name" → the line of its first failure

const SaveTestTimeoutMs = 120_000

proc isNimTestFile(lines: openArray[string]): bool =
  ## a std/unittest file: it imports unittest and has a `test "…":`
  var imp, tst = false
  for i, l in lines:
    if i > 20_000: break
    let t = l.strip
    if not imp and (t.startsWith("import ") or t.startsWith("from ")) and "unittest" in t: imp = true
    if not tst and quotedName(t, "test ").len > 0: tst = true
    if imp and tst: return true
  false

proc importsModule(lines: openArray[string], m: string): bool =
  ## an import line names module m: `import m`, `import ../src/m`, `import pkg/[a, m]`, `from m import x`
  for i, l in lines:
    if i > 400: break
    let t = l.strip
    if not (t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include ")): continue
    var spec = t
    let h = spec.find('#')
    if h >= 0: spec.setLen(h)
    if spec.startsWith("from "):
      let k = spec.find(" import ")
      if k > 0: spec = spec[0 ..< k]
    for part in spec.multiReplace(("[", " "), ("]", " "), (",", " "), ("\"", " ")).splitWhitespace:
      if part in ["import", "from", "include", "except", "as"]: continue
      var n = part
      let s = n.rfind('/')
      if s >= 0: n = n[s + 1 .. ^1]
      if n.endsWith(".nim"): n.setLen(n.len - 4)
      if n == m: return true
  false

proc testsOfFile(path: string, lines: seq[string], related = true, most = 3): seq[string] =
  ## the test files for a Nim file: itself when it is one, else (related) the test files that import it
  if not path.endsWith(".nim"): return
  if isNimTestFile(lines): return @[path]
  if not related or path.len == 0: return
  let m = splitFile(path).name
  var cands: seq[string]
  if path.startsWith(rootDir & "/"):
    for rel in projectFiles():
      if not rel.endsWith(".nim"): continue
      let base = extractFilename(rel)
      if rel.startsWith("tests/") or rel.startsWith("test/") or "/tests/" in rel or base.startsWith("test") or
         base.startsWith("t_"):
        cands.add rootDir / rel
      if cands.len >= 300: break
  else:
    for d in [parentDir(path), parentDir(path) / "tests", parentDir(parentDir(path)) / "tests"]:
      try:
        for kind, f in walkDir(d):
          if kind == pcFile and f.endsWith(".nim") and f != path: cands.add f
      except OSError: discard
  for f in cands:
    if result.len >= most: break
    if f == path: continue
    try:
      let bi = bufIndexByPath(f)
      let lines = if bi >= 0: bufs[bi].lines
                  elif getFileSize(f) < 1_000_000: readFile(f).splitLines
                  else: @[]
      if importsModule(lines, m) and isNimTestFile(lines): result.add f
    except CatchableError: discard

proc testsForSave(b: Buffer): seq[string] =
  ## the test files a save of b runs
  if cfgTestOnSave == "off" or b.lang == nil or b.lang.mode != lmNim or not b.path.endsWith(".nim"): return
  testsOfFile(b.path, b.lines, cfgTestOnSave == "related")

proc parseSaveTestRun(path, output: string): seq[Diag] =
  ## [OK] / [FAILED] / [SKIPPED] each test; a failed check, or an exception, as an error on its line
  var pending: seq[Diag]                      # failures since the last test ended: they belong to the next [FAILED]
  var lastTrace = -1                          # an exception's last stack line in this file
  let lines = output.splitLines
  var i = 0
  while i < lines.len:
    let raw = stripAnsi(lines[i])
    let l = raw.strip
    var tag = ""
    var st = 0
    for (tg, v) in [("[OK]", 1), ("[FAILED]", 2), ("[SKIPPED]", 4)]:
      if l.startsWith(tg):
        tag = tg
        st = v
    if tag.len > 0:
      let name = l[tag.len .. ^1].strip
      let k = testKey(path, name)
      testStatus[k] = st
      if st == 2:
        if pending.len > 0: testFailLine[k] = pending[0].line
        elif lastTrace >= 0: testFailLine[k] = lastTrace
        for d in pending: result.add d
      else: testFailLine.del k
      pending.setLen(0)
      lastTrace = -1
      inc i
      continue
    # /path/t.nim(9, 20): Check failed: add(x, 1) == 3  — then what each side was, indented
    let par = l.find('(')
    if par > 0 and (l[0 ..< par] == path or l[0 ..< par].endsWith(DirSep & extractFilename(path))):
      let close = l.find(')', par)
      if close > par:
        let nums = l[par + 1 ..< close].split(',')
        var ln = -1
        try: ln = parseInt(nums[0].strip) - 1
        except ValueError: discard
        if ln >= 0 and close + 1 < l.len and l[close + 1] == ':':
          var msg = l[close + 2 .. ^1].strip
          var k = i + 1
          while k < lines.len and k - i <= 6:
            let nx = stripAnsi(lines[k]).strip
            if nx.len == 0 or nx.startsWith("[") or nx.find("): ") > 0: break
            msg.add (if k == i + 1: " — " else: ", ") & nx
            inc k
          pending.add Diag(line: ln, col: 0, eline: ln, ecol: -1, sev: 1, msg: msg, src: "test")
          i = k
          continue
        elif ln >= 0:
          lastTrace = ln                          # a stack trace line: /path/t.nim(12) t
    if l.startsWith("Unhandled exception:") or l.startsWith("Error: unhandled exception:"):
      let at = if lastTrace >= 0: lastTrace else: -1
      if at >= 0: pending.add Diag(line: at, col: 0, eline: at, ecol: -1, sev: 1, msg: l, src: "test")
    inc i
  # a check line's error starts at the check, not the indentation
  let bi = bufIndexByPath(path)
  if bi >= 0:
    for d in result.mitems:
      if d.line < bufs[bi].lines.len: d.col = leadWs(bufs[bi].lines[d.line])

type TestRunDone = proc(state: int, failed: seq[string], passed: int) {.closure.}
  ## a test file's run, done: state 0 all passed · 1 some failed · 2 did not compile or was stopped · 3 not run
  ## (the folder is not trusted, no nim)

var saveTestWaiters: Table[string, seq[TestRunDone]]   # test file → who waits for its run (checks before a commit)

proc runTestOnSave(path: string, after: TestRunDone = nil) =
  if after != nil: saveTestWaiters.mgetOrPut(path, @[]).add after
  proc notRun() =
    for w in saveTestWaiters.getOrDefault(path): w(3, @[], 0)
    saveTestWaiters.del path
  if path in saveTestRuns:
    saveTestAgain.incl path
    return
  if not codeTrusted(parentDir(path)):
    askTrust(parentDir(path), quiet = true)              # (tests run the project's code)
    notRun()
    return
  if not haveExe("nim"):
    notRun()
    return
  # the test file's tests: listed, so their marks show while it runs
  var known = false
  for e in testEntries:
    if e.path == path: known = true
  if not known:
    try:
      let bi = bufIndexByPath(path)
      testEntries.add scanTestFile(path, (if bi >= 0: bufs[bi].lines else: readFile(path).splitLines))
    except CatchableError: discard
  for e in testEntries:
    if e.path == path and not e.isSuite: testStatus[testKey(path, e.name)] = 3
  let bin = privTmp("test")
  let cache = privTmp("testc")
  let flags = (if cfgNimTestFlags.len > 0: " " & cfgNimTestFlags else: "") & (if cfgNimFlags.len > 0: " " & cfgNimFlags else: "")
  let cmd = "nim c -r --hints:off --colors:off" & flags & " --nimcache:" & quoteShell(cache) & " -o:" & quoteShell(bin) &
            " " & quoteShell(path)
  let p = path
  let j = startJob(jkCheck, cmd, parentDir(path), proc(jj: Job) =
    saveTestRuns.del p
    try:
      removeFile(bin)
      removeDir(cache)
    except CatchableError: discard
    if p in saveTestAgain:
      saveTestAgain.excl p
      runTestOnSave(p)
      return
    let out0 = jj.output
    let compiled = "[OK]" in out0 or "[FAILED]" in out0 or "[SKIPPED]" in out0 or "[Suite]" in out0
    let ds = parseSaveTestRun(p, out0)
    var ok, bad = 0
    var failed: HashSet[string]
    for e in testEntries:
      if e.path != p or e.isSuite: continue
      let k = testKey(p, e.name)
      if testStatus.getOrDefault(k) == 3:
        if jj.code == 137 or not compiled: testStatus.del k            # (killed, or it did not compile: not known)
        else: testStatus[k] = (if jj.code == 0: 1 else: 2)
      case testStatus.getOrDefault(k)
      of 1: inc ok
      of 2:
        inc bad
        failed.incl e.name
      else: discard
    if ds.len > 0: diagsTest[p] = ds
    elif p in diagsTest: diagsTest.del p
    let name = extractFilename(p)
    if jj.code == 137 and not jj.output.contains("[Suite]"):
      info("Tests in " & name & " took over " & $(SaveTestTimeoutMs div 1000) & " s — stopped")
    elif not compiled:
      info("Tests in " & name & " did not compile")
    elif bad > 0:
      var fresh = false
      for n in failed:
        if n notin saveTestFailed.getOrDefault(p): fresh = true
      if fresh:
        var firstLine = 0
        for e in testEntries:
          if e.path == p and e.name in failed:
            firstLine = testFailLine.getOrDefault(testKey(p, e.name), e.line)
            break
        let fl = firstLine
        toast($bad & " test" & (if bad == 1: "" else: "s") & " failed in " & name & " (" & $ok & " passed)", 1, "Open",
              proc() =
                let b = openFile(p)
                if b != nil: b.centerOn(Pos(line: fl, col: 0)))
      else: info("Tests: " & $ok & " ✓ · " & $bad & " ✗ — " & name)
    elif ok > 0:
      if saveTestFailed.getOrDefault(p).len > 0: toast("All " & $ok & " tests pass in " & name, 4)
      else: info("Tests: " & $ok & " ✓ — " & name)
    saveTestFailed[p] = failed
    let state = if jj.code == 137 or not compiled: 2 elif bad > 0: 1 else: 0
    var fl: seq[string]
    for n in failed: fl.add n
    for w in saveTestWaiters.getOrDefault(p): w(state, fl, ok)
    saveTestWaiters.del p
    needRender = true)
  if j != nil:
    j.deadlineMs = SaveTestTimeoutMs
    saveTestRuns[path] = j
  else: notRun()
  needRender = true

proc testsOnSave(b: Buffer) =
  if b == nil or cfgTestOnSave == "off": return
  for f in testsForSave(b): runTestOnSave(f)

proc testNoteAt(b: Buffer, line: int): (string, int) =
  ## the end-of-line note on a `test "…":` line: its last result (1 ✓, 2 ✗, 3 running, 4 skipped)
  if b.path.len == 0 or line >= b.lines.len: return
  let s = b.lines[line]
  if s.len > 400 or "test" notin s: return
  let tn = quotedName(s.strip, "test ")
  if tn.len == 0: return
  let k = testKey(b.path, tn)
  let st = testStatus.getOrDefault(k)
  case st
  of 1: ((if cfgAccessible: "ok" else: "✓") & " passed", 1)
  of 2:
    let fl = testFailLine.getOrDefault(k, -1)
    ((if cfgAccessible: "FAILED" else: "✗ failed") & (if fl > line: " — line " & $(fl + 1) else: ""), 2)
  of 3: ((if cfgAccessible: "running" else: "… running"), 3)
  of 4: ((if cfgAccessible: "skipped" else: "– skipped"), 4)
  else: ("", 0)
