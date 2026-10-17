# ── AI: fix a failing test — the test, its failure and the code it tests go to the model; its change is applied,
#    the test run again, and the change kept only when the test then passes (one more try with the new failure;
#    else everything is put back as it was) ──

type AiTestFix = object
  test, name: string                 # the test file, the test
  originals: seq[(string, string)]   # files changed: (path, the text before)
  attempt: int

proc fileTextNow(p: string): string =
  let bi = bufIndexByPath(p)
  if bi >= 0: return bufs[bi].lines.join("\n") & (if bufs[bi].noEol: "" else: "\n")
  try: readFile(p) except CatchableError: ""

proc putFileText(p, text: string) =
  ## a file's new text: in its buffer (saved) when it is open, else on disk
  let bi = bufIndexByPath(p)
  if bi >= 0:
    bufs[bi].setTextMinimal(text)
    discard bufs[bi].saveBuffer()
  else: writeFileSafe(p, text)

proc testBlock(lines: seq[string], name: string): (int, int) =
  ## the lines of `test "name":` (-1 when there is none)
  for i, l in lines:
    if quotedName(l.strip, "test ") == name:
      let ind = leadWs(l)
      var e = i
      for k in i + 1 .. lines.high:
        if lines[k].strip.len == 0: continue
        if leadWs(lines[k]) <= ind: break
        e = k
      return (i, e)
  (-1, -1)

proc applySearchReplace(reply: string, allowed: seq[string]): (seq[(string, string, string)], string) =
  ## the model's SEARCH/REPLACE blocks → (path, text before, text after) for each file, or why they do not apply
  var cur = ""
  var texts: Table[string, string]
  var order: seq[string]
  let ls = reply.splitLines
  var i = 0
  while i < ls.len:
    let l = ls[i].strip
    if l.startsWith("FILE:"):
      let rel = l[5 .. ^1].strip.strip(chars = {'`', '"'})
      cur = ""
      for a in allowed:
        if a.endsWith("/" & rel) or relPath(a) == rel or a == rel: cur = a
      if cur.len == 0: return (@[], "it names a file it was not given: " & rel)
      if cur notin texts:
        texts[cur] = fileTextNow(cur)
        order.add cur
      inc i
      continue
    if l.startsWith("<<<<<<< SEARCH"):
      if cur.len == 0: return (@[], "a change without its FILE: line")
      var search, repl: seq[string]
      var k = i + 1
      while k < ls.len and not ls[k].startsWith("======="):
        search.add ls[k]
        inc k
      inc k
      while k < ls.len and not ls[k].startsWith(">>>>>>> REPLACE"):
        repl.add ls[k]
        inc k
      if k >= ls.len: return (@[], "a change that does not end")
      let s = search.join("\n")
      let t = texts[cur]
      let at = t.find(s)
      if s.len == 0 or at < 0: return (@[], "its SEARCH text is not in " & relPath(cur))
      if t.find(s, at + 1) >= 0: return (@[], "its SEARCH text is in " & relPath(cur) & " more than once")
      texts[cur] = t[0 ..< at] & repl.join("\n") & t[at + s.len .. ^1]
      i = k + 1
      continue
    inc i
  var res: seq[(string, string, string)]
  for p in order:
    let before = fileTextNow(p)
    if texts[p] != before: res.add (p, before, texts[p])
  if res.len == 0: return (@[], "it changes nothing")
  (res, "")

proc aiFixTestAsk(fx: AiTestFix, prevReply, prevFailure: string)

proc aiFixTestCheck(fx: AiTestFix, reply: string) =
  ## the model's change applied, the test run again: kept when it passes, else undone (and asked once more)
  var allowed = @[fx.test]
  for (p, _) in fx.originals: allowed.add p
  let g = nxLoad(fx.test)
  if g != nil:
    for im in g.imports:
      let r = nxResolve(fx.test, im.spec)
      if r.len > 0 and rootDir.len > 0 and r.startsWith(rootDir & "/") and r notin allowed: allowed.add r
  let (changes, why) = applySearchReplace(reply, allowed)
  if why.len > 0:
    error("The AI's fix could not be applied: " & why)
    return
  var f2 = fx
  f2.originals.setLen(0)
  try:
    for (p, before, after) in changes:
      f2.originals.add (p, before)
      putFileText(p, after)
  except CatchableError as e:
    for (p, before) in f2.originals: (try: putFileText(p, before) except CatchableError: discard)
    error("The AI's fix could not be written: " & e.msg)
    return
  var names: seq[string]
  for (p, _, _) in changes: names.add relPath(p)
  info("Applied the AI's change to " & names.join(", ") & " — running " & extractFilename(fx.test) & " again…")
  runTestOnSave(fx.test, proc(state: int, failed: seq[string], passed: int) =
    if state == 0 or (state == 1 and fx.name notin failed):
      toast("✓ " & fx.name & " passes now — the AI changed " & names.join(", ") & " (local history has the version before)",
            4, "Undo", proc() =
        for (p, before) in f2.originals: (try: putFileText(p, before) except CatchableError: discard)
        info("Put back as it was"), 20000)
      return
    # not passing: everything back as it was; once more with what went wrong
    for (p, before) in f2.originals: (try: putFileText(p, before) except CatchableError: discard)
    let failure = block:
      var m = ""
      for d in diagsTest.getOrDefault(fx.test): m.add d.msg & "\n"
      if m.len == 0: m = (if state == 2: "it did not compile" else: "the test still fails")
      m
    if fx.attempt == 0:
      info("The AI's fix did not make the test pass — asking again with the new failure…")
      var f3 = fx
      f3.attempt = 1
      aiFixTestAsk(f3, reply, failure)
    else:
      error("The AI could not make " & fx.name & " pass — nothing was changed (" & failure.splitLines()[0] & ")"))

proc aiFixTestAsk(fx: AiTestFix, prevReply, prevFailure: string) =
  let tl = fileTextNow(fx.test).splitLines
  let (a, e) = testBlock(tl, fx.name)
  if a < 0:
    error("No test named " & fx.name & " in " & extractFilename(fx.test))
    return
  var failure = ""
  for d in diagsTest.getOrDefault(fx.test): failure.add "line " & $(d.line + 1) & ": " & d.msg & "\n"
  if failure.len == 0: failure = "the test fails (no message)\n"
  var prompt = "This unit test fails:\n<test file=\"" & relPath(fx.test) & "\" lines=\"" & $(a + 1) & "-" & $(e + 1) &
               "\">\n" & tl[a .. e].join("\n") & "\n</test>\nWhat it says:\n" & failure &
               "\nFix the code under test so that the test passes. Change the test only when it is plainly wrong " &
               "itself. Change as little as possible.\n"
  # the code it tests: the project's modules the test file imports (whole when not big)
  let g = nxLoad(fx.test)
  var shown = 0
  if g != nil:
    for im in g.imports:
      let r = nxResolve(fx.test, im.spec)
      if r.len == 0 or rootDir.len == 0 or not r.startsWith(rootDir & "/") or r == fx.test or shown >= 3: continue
      let t = fileTextNow(r)
      if t.len == 0: continue
      inc shown
      if t.countLines <= 600:
        prompt.add "<file path=\"" & relPath(r) & "\">\n" & t & "</file>\n"
      else:
        let bi = bufIndexByPath(fx.test)
        if bi >= 0: prompt.add nimDefinitionsFor(bufs[bi], a, e) & "\n"
  prompt.add "\nReply with the changes only, as blocks like this (the SEARCH text copied exactly from the file, " &
             "a few lines, enough to be found once):\nFILE: path/of/the/file.nim\n<<<<<<< SEARCH\nthe lines as " &
             "they are\n=======\nthe lines as they should be\n>>>>>>> REPLACE\n"
  if prevReply.len > 0:
    prompt.add "\nYour previous answer was:\n" & prevReply & "\nWith it the test still fails:\n" & prevFailure &
               "\nGive a corrected answer."
  info("Asking the AI to make " & fx.name & " pass…")
  let f = fx
  aiOneShot(prompt, proc(t: string) = aiFixTestCheck(f, t))

proc aiFixTest(testPath, name: string) =
  ## the AI makes a failing test pass — its change kept only when the test passes afterwards
  if cfgAiProvider notin ["ollama", "custom"] and aiKey().len == 0:
    info("Set up an AI provider first (AI › choose provider)")
    return
  if not codeTrusted(parentDir(testPath)):
    askTrust(parentDir(testPath))                  # (the test has to run to tell)
    return
  aiFixTestAsk(AiTestFix(test: testPath, name: name), "", "")

proc failingTestAt(b: Buffer, line: int): string =
  ## the failed test the line belongs to (its `test` line, or a line inside it), "" when none
  if b.path.len == 0: return ""
  for e in testEntries:
    if e.path != b.path or e.isSuite: continue
    if testStatus.getOrDefault(testKey(b.path, e.name)) != 2: continue
    let (a, z) = testBlock(b.lines, e.name)
    if a >= 0 and line >= a and line <= z: return e.name
  ""

proc cmdAiFixTest() =
  let b = buf()
  var name = failingTestAt(b, b.primary.head.line)
  if name.len == 0:
    for e in testEntries:
      if e.path == b.path and not e.isSuite and testStatus.getOrDefault(testKey(b.path, e.name)) == 2:
        name = e.name
        break
  if name.len == 0:
    info("No failed test here — run the tests first (save the file, or ▶ in the gutter)")
    return
  aiFixTest(b.path, name)
