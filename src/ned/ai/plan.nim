# ── AI: plan first, then do it — the assistant looks at the code (reading only) and answers with a numbered plan;
#    you go on with all of it or one step at a time, change it, or drop it. Each step is a run of its own with a
#    restore point (the files as they were before it): any step can be undone, back to before the plan ──

proc aiPlanSteps0(text: string): seq[string] =
  ## the numbered steps of a reply ("1. …", "2) …", "**3.** …", "Step 4: …"); a step's indented lines stay with it
  var cur = ""
  var inList = false
  for raw in text.splitLines:
    let t = raw.strip
    var k = 0
    var u = t
    if u.startsWith("**"): u = u[2 .. ^1]
    if u.toLowerAscii.startsWith("step "): u = u[5 .. ^1]
    while k < u.len and u[k] in Digits: inc k
    let numbered = k > 0 and k <= 3 and k < u.len and u[k] in {'.', ')', ':'} and raw.len - raw.strip(trailing = false).len <= 1
    if numbered:
      if cur.len > 0: result.add cur.strip
      var rest = u[k + 1 .. ^1].strip
      if rest.startsWith("**"): rest = rest[2 .. ^1].strip
      cur = rest
      inList = true
    elif inList and t.len > 0 and (raw.startsWith(" ") or raw.startsWith("\t") or t[0] in {'-', '*', '+'}):
      cur.add "\n" & t
    elif inList and t.len == 0: discard
    elif inList:
      if cur.len > 0: result.add cur.strip
      cur = ""
      inList = false
  if cur.len > 0: result.add cur.strip
  var keep: seq[string]
  for s in result:
    let s2 = s.replace("**", "")
    if s2.strip.len > 0: keep.add s2
  keep

proc stepLine(i: int): string =
  ## a step's first line as a menu shows it (without Markdown's backticks)
  aiPlanSteps[i].splitLines()[0].replace("`", "")

proc aiPlanTitle(i: int): string =
  "Step " & $(i + 1) & "/" & $aiPlanSteps.len & ": " & truncTo(stepLine(i), 70)

proc aiPlanNext()
proc aiPlanMenu()

proc aiPlanUndoFrom(k: int) =
  ## the files back to before step k (its restore point and the later ones, newest first)
  var n = 0
  for i in countdown(aiPlanCps.high, k):
    if aiPlanCps[i] >= 0 and aiCpIndex(aiPlanCps[i]) >= 0:
      aiUndoCheckpoint(aiPlanCps[i])
      inc n
  if aiPlanCps.len > k: aiPlanCps.setLen(k)
  aiPlanAt = k
  aiPlanState = apReady
  aiMsgs.add AiMsg(role: 3, text: "Back to before step " & $(k + 1) & (if n == 0: " (those steps changed no files)" else: "") &
                   ". palette › AI: the plan… goes on from there.")
  inc aiVersion
  needRender = true

proc aiPlanStepAct(i: int): Action =
  result = proc() =
    askConfirm("Put the files back as they were before step " & $(i + 1) & "? (y/n)", proc(c: char) =
      if c in {'y', 'Y'}: aiPlanUndoFrom(i))

proc aiPlanMenu() =
  ## what to do with the plan: go on (all, or one step), change it, go back to a restore point, drop it
  if aiPlanSteps.len == 0:
    info("No plan — palette › AI: plan a change, then do it…")
    return
  var items: seq[(string, string, Action)]
  if aiPlanAt < aiPlanSteps.len:
    let left = aiPlanSteps.len - aiPlanAt
    items.add act((if aiPlanAt == 0: "Do it: all " & $left & " steps"
                   elif left == 1: "Go on: the last step" else: "Go on: the " & $left & " steps left"),
                  "stops when a check fails", proc() =
      aiPlanAuto = true
      aiPlanNext())
    items.add act("One step: " & truncTo(stepLine(aiPlanAt), 50), "then asks again", proc() =
      aiPlanAuto = false
      aiPlanNext())
    items.add act("Change the plan…", "say what should be different", proc() =
      askText("What should change in the plan?", "", proc(t: string) =
        aiPlanState = apPlanning
        aiSend("Change the plan: " & t & "\n\nReply with the whole plan again as a numbered list (only the steps " &
               "not done yet" & (if aiPlanAt > 0: " — steps 1–" & $aiPlanAt & " are done" else: "") &
               "). Do not change any files yet.", withContext = false, shownAs = "Change the plan: " & t)))
  for i in countdown(min(aiPlanCps.high, aiPlanAt - 1), 0):
    items.add act("Back to before step " & $(i + 1), truncTo(stepLine(i), 40), aiPlanStepAct(i))
  items.add act("Drop the plan", "the changes made so far stay", proc() =
    aiPlanState = apNone
    aiPlanSteps.setLen(0)
    aiPlanCps.setLen(0)
    info("Plan dropped"))
  openActions("Plan — " & truncTo(aiPlanTask, 50) & " · " & $aiPlanAt & "/" & $aiPlanSteps.len & " done", items)

proc aiPlanNext() =
  if aiPlanAt >= aiPlanSteps.len:
    aiPlanState = apNone
    aiMsgs.add AiMsg(role: 3, text: "The plan is done: " & $aiPlanSteps.len & " steps. Each one can still be undone: " &
                     "palette › AI: undo the assistant's changes…")
    inc aiVersion
    toast("The plan is done (" & $aiPlanSteps.len & " steps)", 4, "Show", proc() = showSide(svAssistant))
    return
  aiPlanState = apDoing
  let i = aiPlanAt
  showSide(svAssistant)
  aiSend("Do step " & $(i + 1) & " of the plan now — only this step:\n" & aiPlanSteps[i] &
         "\n\nCheck it when it can be checked (build or test). End with one line saying what you changed.",
         withContext = false, shownAs = "▶ " & aiPlanTitle(i))

proc aiPlanRunDone(): bool =
  ## a run of the assistant ended: a plan's step, or the plan itself. false when no plan is going on
  case aiPlanState
  of apNone, apReady: return false
  of apPlanning:
    var reply = ""
    for i in countdown(aiMsgs.high, 0):
      if aiMsgs[i].role == 1 and aiMsgs[i].text.strip.len > 0:
        reply = aiMsgs[i].text
        break
      if aiMsgs[i].role == 0: break
    let steps = aiPlanSteps0(reply)
    if steps.len == 0:
      aiPlanState = apNone
      aiMsgs.add AiMsg(role: 3, text: "No numbered plan in the reply — ask again, or go on as a normal chat.")
      inc aiVersion
      return true
    aiPlanSteps = steps
    aiPlanAt = 0
    aiPlanCps.setLen(0)
    aiPlanState = apReady
    aiMsgs.add AiMsg(role: 3, text: "A plan of " & $steps.len & " steps. Nothing is changed yet — palette › AI: the plan… " &
                     "(or the menu now): do it all, one step at a time, or change it.")
    inc aiVersion
    aiPlanMenu()
    return true
  of apDoing:
    # this step's restore point: the files as they were before it (none when it changed nothing)
    var cp = -1
    if aiRunCp >= 0 and aiRunCp <= aiCheckpoints.high and aiCheckpoints[aiRunCp].files.len > 0:
      cp = aiCheckpoints[aiRunCp].id
    aiRunCp = -1
    while aiPlanCps.len < aiPlanAt: aiPlanCps.add -1
    if aiPlanCps.len == aiPlanAt: aiPlanCps.add cp
    else: aiPlanCps[aiPlanAt] = cp
    let i = aiPlanAt
    inc aiPlanAt
    aiPlanState = apReady
    # a step whose edits left errors: stop there, whatever the mode
    var broken = false
    for m in countdown(aiMsgs.high, max(0, aiMsgs.high - 40)):
      if aiMsgs[m].role == 0: break
      for c in aiMsgs[m].calls:
        if c.check.len > 0 and c.check != "ok" and "error" in c.check: broken = true
    if aiPlanAuto and not broken and aiPlanAt < aiPlanSteps.len:
      aiPlanNext()
    elif aiPlanAt >= aiPlanSteps.len and not broken:
      aiPlanNext()                             # (says it is done)
    else:
      if broken: warn("Step " & $(i + 1) & " left errors — the plan stopped there")
      aiPlanMenu()
    return true

proc aiPlanStart(task: string) =
  ## the assistant plans first (reading only), then you decide
  let t = task.strip
  if t.len == 0: return
  if cfgAiProvider notin ["ollama", "custom"] and aiKey().len == 0:
    info("Set up an AI provider first (AI › choose provider)")
    return
  if not cfgAiAgent:
    setSetting("ai.agent", %true)
    info("The assistant's tools are on (ai.agent): it reads the code to plan, and makes the changes after")
  if aiBusy:
    info("The assistant is still busy — Esc stops it")
    return
  aiPlanTask = t
  aiPlanSteps.setLen(0)
  aiPlanCps.setLen(0)
  aiPlanAt = 0
  aiPlanState = apPlanning
  showSide(svAssistant)
  aiSend("Plan this change before making it: " & t & "\n\nFirst look at the code you need (read_file, search, " &
         "list_files, get_diagnostics — reading only: editing files and running commands are not allowed yet). Then " &
         "reply with the plan: a numbered list (1., 2., …) of small steps, each one change that can be checked on its " &
         "own — which file, what changes, how to check it. After the list, at most one line on the risks. Do not " &
         "change any files yet.", shownAs = "Plan: " & t)

proc cmdAiPlan() =
  if aiPlanSteps.len > 0 and aiPlanState == apReady:
    aiPlanMenu()
    return
  askText("What should the assistant do? (it plans first; nothing changes until you say so)", "", proc(t: string) =
    aiPlanStart(t))
