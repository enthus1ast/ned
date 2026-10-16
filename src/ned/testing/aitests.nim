# ── tests the AI writes, kept only when they compile and pass ──

var
  aiTestsBusy = false
  aiTestsMadeDir = ""           # the tests folder ned made for them (removed again when nothing is kept)

proc testBlocksOf(lines: seq[string]): seq[(string, int, int)] =
  ## the `test "name":` blocks of a std/unittest file: (name, first line, last line)
  for i, l in lines:
    let name = quotedName(l, "test ")
    if name.len == 0: continue
    let ind = l.len - l.strip(trailing = false).len
    var last = i
    for k in i + 1 ..< lines.len:
      let t = lines[k]
      if t.strip.len == 0: continue
      if t.len - t.strip(trailing = false).len <= ind: break
      last = k
    result.add (name, i, last)

proc nimCodeBlock(t: string): string =
  ## the code of the reply's first ```nim block (the reply itself when it has none)
  var a = t.find("```nim")
  if a < 0: a = t.find("```")
  if a < 0: return t.strip & "\n"
  let nl = t.find('\n', a)
  if nl < 0: return ""
  let e = t.find("\n```", nl)
  (if e < 0: t[nl + 1 .. ^1] else: t[nl + 1 ..< e]).strip(leading = false) & "\n"

proc aiTestsAsk(srcPath, testPath, spec, focus: string, attempt: int, prevCode, prevErr: string)

proc commentLines(d: string): string =
  ## a failure's output as comments under the test
  var o: seq[string]
  for l in d.splitLines: o.add "  # " & l
  o.join("\n")

proc aiTestsVerify(srcPath, testPath, spec, focus, code: string, attempt: int, confirm = false,
                   dropped: seq[(string, string)] = @[]) =
  ## the test file compiled and run beside the project's other tests: tests that fail are dropped, the file is
  ## kept when what is left passes; a file that does not compile goes back to the model (twice at most)
  aiTestsBusy = true
  try:
    createDir(parentDir(testPath))
    writeFile(testPath, code)
  except CatchableError as e:
    aiTestsBusy = false
    error("Cannot write " & relPath(testPath) & ": " & e.msg)
    return
  let cache = privTmp("aitests")
  let exe = cache / "aitest"
  let tmo = if haveExe("timeout"): "timeout 60 " else: ""
  let cmd = "nim c --hints:off --colors:off --nimcache:" & quoteShell(cache) & " -o:" & quoteShell(exe) & " " &
            quoteShell(testPath) & " && echo NED_TESTS_RUN && " & tmo & quoteShell(exe)
  info((if confirm: "Running the tests that passed once more…" elif attempt == 0: "Compiling and running the AI's tests…"
        else: "Compiling the AI's corrected tests…"))
  let j0 = startJob(jkTool, cmd, parentDir(testPath), proc(j: Job) =
    try: removeDir(cache)
    except CatchableError: discard
    let outp = stripAnsi(j.output)
    let k = outp.find("NED_TESTS_RUN")
    proc drop(why: string) =
      try:
        removeFile(testPath)
        let d = parentDir(testPath)
        if d == aiTestsMadeDir:
          var empty = true
          for _ in walkDir(d): empty = false
          if empty: removeDir(d)
      except CatchableError: discard
      aiTestsBusy = false
      error(why)
    if k < 0:
      # it did not compile
      var errs: seq[string]
      for raw in outp.splitLines:
        let (ok, p, l, c, sev, m) = parseErrLine(raw, j.cwd)
        if ok and sev == 1: errs.add extractFilename(p) & "(" & $(l + 1) & ", " & $(c + 1) & ") Error: " & m
      if errs.len == 0: errs.add outp.strip.splitLines()[^1 .. ^1].join("")
      if confirm or attempt >= 2:
        drop("The AI's tests do not compile (" & errs[0] & ") — none kept")
        return
      try: removeFile(testPath)
      except CatchableError: discard
      aiTestsBusy = false
      info("The AI's tests do not compile (" & errs[0] & ") — asking it to fix them…")
      aiTestsAsk(srcPath, testPath, spec, focus, attempt + 1, code, errs[0 ..< min(6, errs.len)].join("\n"))
      return
    let run = outp[k + "NED_TESTS_RUN".len .. ^1]
    # [OK] / [FAILED] name, a failure's details on the lines before its [FAILED]
    var oks: seq[string]
    var fails: seq[(string, string)]
    var detail: seq[string]
    for raw in run.splitLines:
      let l = raw.strip
      if l.startsWith("[OK]"):
        oks.add l[4 .. ^1].strip
        detail.setLen(0)
      elif l.startsWith("[FAILED]"):
        fails.add (l[8 .. ^1].strip, detail.join("\n"))
        detail.setLen(0)
      elif l.startsWith("[Suite]"): detail.setLen(0)
      elif l.len > 0: detail.add l.replace(testPath, relPath(testPath))
    if j.code == 124:
      drop("The AI's tests did not finish in 60 s — none kept")
      return
    if fails.len == 0 and (j.code != 0 or oks.len == 0):
      drop("The AI's tests " & (if oks.len == 0: "ran no test" else: "ended with exit code " & $j.code) & " — none kept" &
           (if detail.len > 0: ": " & detail[^1] else: ""))
      return
    var allDropped = dropped
    if fails.len > 0:
      if confirm:
        drop("Some of the AI's tests pass only sometimes — none kept")
        return
      # without the failed ones; what is left runs again
      var lines = code.splitLines
      var bad: HashSet[string]
      for (n, d) in fails:
        bad.incl n
        var body = ""
        for (bn, a, e) in testBlocksOf(lines):
          if bn == n: body = lines[a .. e].join("\n")
        allDropped.add (body, d)
      for (bn, a, e) in testBlocksOf(lines).reversed:
        if bn in bad:
          for _ in a .. e: lines.delete(a)
      if testBlocksOf(lines).len == 0:
        drop("None of the AI's " & $fails.len & " tests passed — none kept")
        var t = "# The AI's tests for " & relPath(srcPath) & " — none passed. Either the test is wrong or the code is.\n\n"
        for (body, d) in allDropped:
          t.add body & "\n" & commentLines(d) & "\n\n"
        discard openScratch("Failed AI tests", t, langByName("Nim"))
        return
      aiTestsVerify(srcPath, testPath, spec, focus, lines.join("\n"), attempt, true, allDropped)
      return
    # kept: every test in it passes
    aiTestsBusy = false
    fileWritten(testPath)
    refreshTree()
    if fileCacheValid and relPath(testPath) notin fileCache: fileCache.add relPath(testPath)
    rescanTests()
    parseTestOutput(testPath, run)
    let tb = openFile(testPath)
    info("Kept " & $oks.len & " AI-written test" & (if oks.len == 1: "" else: "s") & " in " & relPath(testPath) &
         " — they compile and pass" & (if allDropped.len > 0: " · " & $allDropped.len & " dropped: they failed (see the tab)" else: ""))
    if allDropped.len > 0:
      var t = "# Tests the AI wrote for " & relPath(srcPath) & " that FAILED, so they were left out of " &
              relPath(testPath) & ".\n# Either the test expects the wrong thing, or the code has a bug: worth a look.\n\n"
      for (body, d) in allDropped:
        t.add body & "\n" & commentLines(d) & "\n\n"
      discard openScratch("Dropped AI tests", t, langByName("Nim"))
      if tb != nil: discard openFile(testPath))
  if j0 == nil:
    aiTestsBusy = false

proc aiTestsAsk(srcPath, testPath, spec, focus: string, attempt: int, prevCode, prevErr: string) =
  var src = ""
  try: src = readFile(srcPath)
  except CatchableError: return
  if src.len > 60_000: src = src[0 ..< 60_000] & "\n# …"
  var prompt = "Write a test file for the Nim module below, with std/unittest. It is saved as " & relPath(testPath) &
    " and compiled on its own, so it can only use what the module exports (names marked with *). Start it with " &
    "exactly:\nimport std/unittest\nimport " & spec & "\nThen one suite with 3 to 8 small, independent `test \"…\":` " &
    "blocks, each checking concrete results you are sure of from the code (exact values; edge cases such as empty " &
    "input, zero, one element). Reply with only the file, in one ```nim block."
  if focus.len > 0: prompt.add "\nTest `" & focus & "` only."
  prompt.add "\n\n<module path=\"" & relPath(srcPath) & "\">\n" & src & "\n</module>"
  if prevErr.len > 0:
    prompt.add "\n\nYour previous file does not compile:\n" & prevErr & "\n\n```nim\n" & prevCode &
               "```\n\nReply with the corrected complete file."
  aiOneShot(prompt, proc(t: string) =
    var code = nimCodeBlock(t)
    if code.strip.len == 0:
      error("The AI sent no test file")
      return
    if "unittest" notin code: code = "import std/unittest\n" & code
    if extractFilename(spec) notin code: code = "import " & spec & "\n" & code
    aiTestsVerify(srcPath, testPath, spec, focus, code, attempt))

proc aiWriteTests() =
  ## tests for this module (or the exported proc the cursor is in), written by the AI, kept only when they compile
  ## and pass
  let b = buf()
  if b.lang.mode != lmNim or not b.path.endsWith(".nim") or not haveExe("nim"):
    aiQuick("Write unit tests for this code. For Nim use std/unittest in tests/; create the file and run it.")
    return
  if aiTestsBusy:
    info("The AI's tests are still being checked")
    return
  if not saveForTool(b): return
  let f = nxFileFor(b)
  var focus = ""
  var anyExported = false
  if f != nil:
    for sym in f.syms:
      if sym.exported and sym.kind in NxRoutineKinds: anyExported = true
    let ri = nxEnclosing(f, b.primary.head.line)
    if ri >= 0:
      if f.syms[ri].exported: focus = f.syms[ri].name
      else: info(f.syms[ri].name & " is not exported (*): the tests import the module, so they test what it exports")
  if f != nil and not anyExported:
    info("Nothing in " & extractFilename(b.path) & " is exported (*) — the tests import the module and need its exported procs")
    return
  let nf = findNimbleFile(parentDir(b.path))
  let dir = (if nf.len > 0: parentDir(nf) else: rootDir) / "tests"
  let name = splitFile(b.path).name
  var testPath = dir / "test_" & name & ".nim"
  var n = 2
  while fileExists(testPath) or bufIndexByPath(testPath) >= 0:
    testPath = dir / "test_" & name & $n & ".nim"
    inc n
  let spec = relativePath(b.path.changeFileExt(""), dir).replace('\\', '/')
  aiTestsMadeDir = if dirExists(dir): "" else: dir
  showSide(svAssistant)
  info("The AI is writing tests for " & (if focus.len > 0: focus else: extractFilename(b.path)) & "…")
  aiTestsAsk(b.path, testPath, spec, focus, 0, "", "")
