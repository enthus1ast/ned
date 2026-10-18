# ── quick fixes of our own: Nim imports, AI fix/explain ──

proc diagsAtCursor(b: Buffer): seq[Diag] =
  let l = b.primary.head.line
  for d in diagsFor(b.path):
    if d.line <= l and l <= max(d.line, d.eline): result.add d
  result.sort(proc(x, y: Diag): int = cmp(x.sev, y.sev))

var aiFixN = 0

proc aiFixVerify(bid: int, text: string, attempt: int, firstMsg: string)

proc aiFixAsk(b: Buffer, d: Diag, attempt: int, prev, prevErr: string) =
  ## ask the model to fix the problem; its answer is checked by nim check before it is applied
  let l0 = max(0, d.line - 30)
  let l1 = min(b.lines.high, d.line + 30)
  var instr = "Fix this " & (if d.sev == 1: "compiler error" else: "warning") & " reported at line " & $(d.line + 1) &
              ":\n" & d.msg.strip & "\nChange as little as possible."
  let defs = nimDefinitionsFor(b, l0, l1)
  if defs.len > 0: instr.add "\n\nDeclarations the code uses (for reference, do not repeat them):\n" & defs
  if attempt > 0:
    instr.add "\n\nYour previous answer was:\n" & prev & "\nWith it, `nim check` still reports:\n" & prevErr &
              "\nGive a corrected replacement."
  # the whole top-level declaration or statement with the problem (the cause is often a few lines above it,
  # like the `let` of a name assigned to), when it is not huge
  var top = d.line
  while top > 0 and (b.lines[top].len == 0 or b.lines[top][0] in {' ', '\t', '#'}): dec top
  var last = d.line
  var k = top + 1
  while k < b.lines.len and (b.lines[k].len == 0 or b.lines[k][0] in {' ', '\t'}):
    if b.lines[k].strip.len > 0: last = k
    inc k
  last = max(last, d.line)
  let saved = b.cursors
  if last - top <= 300 and b.primary.range[0] == b.primary.range[1]:
    b.cursors = @[Cursor(anchor: Pos(line: top, col: 0), head: Pos(line: last, col: b.lines[last].len), goalX: -1)]
  aiInlineEdit(instr)
  b.cursors = saved
  if not aiInlineMode: return
  let id = b.id
  let fm = d.msg.splitLines()[0]
  aiOneShotCb = proc(t: string) = aiFixVerify(id, t, attempt, fm)

proc aiFixVerify(bid: int, text: string, attempt: int, firstMsg: string) =
  ## the model's fix applied to a copy of the file beside it and checked with nim check: applied only when the
  ## problem is gone and nothing new is wrong; one more try with the new error otherwise
  let b = bufById(bid)
  if b == nil: return
  let t = inlineClean(text)
  let a = aiInlineA
  let e = b.clampPos(aiInlineE)
  var cand = b.lines[0 ..< a.line]
  let newLines = (b.lines[a.line][0 ..< a.col] & t & b.lines[e.line][e.col .. ^1]).split('\n')
  for x in newLines: cand.add x
  for i in e.line + 1 ..< b.lines.len: cand.add b.lines[i]
  inc aiFixN
  # (a private copy, checked from the file's folder on stdin — or, a file another one includes, inside that one)
  let tmp = privTmp("fixcheck") & ".nim"
  var main, mainText = ""
  if nxIncluderOf(b.path).len > 0:
    let saved = b.lines
    b.lines = cand
    (main, mainText) = includerCopy(b, tmp)
    b.lines = saved
  let mainCopy = if main.len > 0: privTmp("fixcheckmain") & ".nim" else: ""
  try:
    writeFile(tmp, cand.join("\n") & "\n")
    if main.len > 0: writeFile(mainCopy, mainText)
  except CatchableError:
    aiInlineText = text
    applyInlineEdit()
    return
  var before: HashSet[string]              # what was wrong before (the problem being fixed aside)
  for d in diagsFor(b.path):
    if d.sev == 1: before.incl d.msg.splitLines()[0]
  before.excl firstMsg
  let regionLo = a.line
  let regionHi = a.line + newLines.len - 1
  info("Checking the AI's fix with nim check…")
  let mainOf = if main.len > 0: main else: b.path
  discard startJob(jkCheck, "nim check --hint:all:off --colors:off --listFullPaths:on - < " &
                   quoteShell(if main.len > 0: mainCopy else: tmp), parentDir(mainOf), proc(j: Job) =
    var bad: seq[string]
    let tn = extractFilename(tmp)
    for raw in j.output.splitLines:              # (read while the file is there: its path is checked)
      var t = stripAnsi(raw)
      if t.startsWith("stdinfile.nim("): t = mainOf & t["stdinfile.nim".len .. ^1]
      var (ok, p, l, _, sev, m) = parseErrLine(t, j.cwd)
      if ok and extractFilename(p) == tn: p = b.path
      if main.len > 0 and p == main: continue     # (the module that includes it: not this file)
      if not ok or sev != 1 or p != b.path: continue
      let f = m.splitLines()[0]
      if (l >= regionLo and l <= regionHi) or f == firstMsg or f notin before:
        bad.add "line " & $(l + 1) & ": " & f
    if j.code != 0 and bad.len == 0 and "Error:" in j.output and tn notin j.output and "stdinfile" notin j.output:
      bad.add "nim check failed: " & j.output.strip.splitLines()[^1]
    try:
      removeFile(tmp)
      if mainCopy.len > 0: removeFile(mainCopy)
    except CatchableError: discard
    let b2 = bufById(bid)
    if b2 == nil: return
    if bad.len == 0:
      aiInlineText = text
      applyInlineEdit()
      info("✓ AI fix applied — nim check passes for it · Ctrl+Z undoes it")
      return
    if attempt == 0 and buf() == b2:
      info("The AI's fix did not compile (" & bad[0] & ") — asking again with the error…")
      var dd = Diag(line: aiInlineA.line, msg: firstMsg, sev: 1)
      for d in diagsFor(b2.path):
        if d.msg.splitLines()[0] == firstMsg: dd = d
      aiFixAsk(b2, dd, 1, t, bad[0 ..< min(3, bad.len)].join("\n"))
      return
    let ta = text
    let pa = a
    let pe = e
    toast("The AI's fix still does not compile: " & bad[0], 2, "Apply it anyway", proc() =
      aiInlineBuf = bid
      aiInlineA = pa
      aiInlineE = pe
      aiInlineText = ta
      applyInlineEdit(), 15000))

proc aiFixProblem() =
  let b = buf()
  let ds = diagsAtCursor(b)
  if ds.len == 0:
    info("No problem on this line")
    return
  let d = ds[0]
  if b.lang.mode == lmNim and b.path.endsWith(".nim") and haveExe("nim") and d.sev == 1:
    aiFixAsk(b, d, 0, "", "")          # checked by the compiler before it is applied
    return
  aiInlineEdit("Fix this " & (if d.sev == 1: "error" else: "warning") & " reported at line " & $(d.line + 1) &
               ": " & d.msg.splitLines()[0] & ". Change as little as possible.")

proc aiExplainProblem() =
  let b = buf()
  let ds = diagsAtCursor(b)
  if ds.len == 0:
    info("No problem on this line")
    return
  let d = ds[0]
  showSide(svAssistant)
  aiSend("Explain this " & (if d.sev == 1: "compiler error" else: "warning") & " at line " & $(d.line + 1) &
         " and how to fix it:\n\n" & d.msg)
