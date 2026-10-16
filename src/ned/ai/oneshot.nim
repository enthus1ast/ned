# ── one-shot requests (commit messages, …): the reply goes to a callback, not the chat ──

proc aiOneShot(prompt: string, onDone: proc(t: string) {.closure.}) =
  if aiBusy or aiInlineMode:
    info("The assistant is busy — try again in a moment")
    return
  aiInlineBuf = -1
  aiInlineText = ""
  aiInlineMode = true
  aiOneShotCb = onDone
  let saved = aiMsgs
  aiMsgs = @[AiMsg(role: 0, text: prompt)]
  aiRequest()
  aiMsgs = saved

proc aiCommitMessage() =
  if gitHome().len == 0:
    info("Not a git repository")
    return
  var d = gitText("diff --no-color --cached")
  var what = "staged"
  if d.strip.len == 0:
    d = gitText("diff --no-color")
    what = "unstaged"
  if d.strip.len == 0:
    info("No changes to describe")
    return
  info("Writing a commit message for the " & what & " changes…")
  aiOneShot("Write a git commit message for this diff. Reply with ONE line only: an imperative summary of at most " &
            "72 characters, no quotes, no trailing period, no Markdown.\n\n<diff>\n" & d & "\n</diff>",
    proc(t: string) =
      var m = t.strip.splitLines()
      let line = if m.len > 0: m[0].strip(chars = {'"', '`', ' '}) else: ""
      if line.len == 0:
        warn("The AI returned no message")
        return
      openPrompt(pGitCommit, "Commit message (" & what & ")", line)
      promptCur = promptText.len)

proc aiReviewStaged() =
  ## the staged changes (or the unstaged ones), reviewed by the AI; its findings go to the Problems panel
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  var d = gitText("diff --no-color -U5 --cached")
  var what = "staged"
  if d.strip.len == 0:
    d = gitText("diff --no-color -U5")
    what = "unstaged"
  if d.strip.len == 0:
    info("No changes to review")
    return
  if d.len > 200_000: d = d[0 ..< 200_000]
  info("Reviewing the " & what & " changes…")
  aiOneShot("Review this diff like a careful senior engineer. Report only real problems: bugs, crashes, " &
            "wrong logic, security issues, missing error handling, clear performance traps. No style nits, no praise. " &
            "Reply with one JSON object per line and nothing else, like:\n" &
            "{\"file\": \"src/app.nim\", \"line\": 42, \"severity\": \"error\", \"message\": \"…\"}\n" &
            "severity is error, warning or info; line is the line number in the NEW file. " &
            "If there is nothing to report, reply with the single word NONE.\n\n<diff>\n" & d & "\n</diff>",
    proc(t: string) =
      diagsAi.clear()
      var n = 0
      for raw in t.splitLines:
        let l = raw.strip(chars = Whitespace + {',', '`'})
        if not l.startsWith("{"): continue
        try:
          let j = parseJson(l)
          let rel = j{"file"}.getStr
          if rel.len == 0: continue
          let path = (if rel.isAbsolute: rel else: root / rel).normalizedPath
          let sev = case j{"severity"}.getStr("warning").toLowerAscii
                    of "error": 1
                    of "info", "note": 3
                    else: 2
          let ln = max(0, j{"line"}.getInt(1) - 1)
          diagsAi.mgetOrPut(path, @[]).add Diag(line: ln, col: 0, eline: ln, ecol: -1, sev: sev,
                                                msg: j{"message"}.getStr, src: "AI review")
          inc n
        except CatchableError: discard
      rebuildProblems()
      if n == 0: info("AI review: nothing to report in the " & what & " changes")
      else:
        setPanel(pkProblems)
        info("AI review: " & $n & " finding(s) in Problems — palette › AI: clear review findings removes them")
      needRender = true)

proc aiRegenerate() =
  if aiBusy: return
  var i = aiMsgs.high
  while i >= 0 and aiMsgs[i].role != 0: dec i
  if i < 0:
    info("Nothing to regenerate")
    return
  aiMsgs.setLen(i + 1)
  aiSteps = 0
  aiScrollOff = 0
  inc aiVersion
  aiRequest()

proc fmtTokens(n: int): string =
  if n >= 1_000_000: formatFloat(n.float / 1_000_000, ffDecimal, 1) & "M"
  elif n >= 10_000: $(n div 1000) & "k"
  elif n >= 1000: formatFloat(n.float / 1000, ffDecimal, 1) & "k"
  else: $n

const SlashCmds = [
  ("/explain", "explain the current file or selection"),
  ("/fix", "fix the errors and warnings in this file"),
  ("/tests", "write unit tests and add them to the project"),
  ("/doc", "add doc comments to the public API"),
  ("/review", "review the uncommitted changes (git diff)"),
  ("/optimize", "make this code faster"),
  ("/commit", "write a commit message for the staged changes"),
  ("/regen", "regenerate the last reply"),
  ("/new", "start a new chat"),
  ("/history", "open a saved chat"),
  ("/model", "choose the model"),
  ("/provider", "choose the provider"),
  ("/help", "list commands and @mentions")]

proc mcpPromptFind(cmd: string): (McpServer, int) =
  ## "server:prompt" (any case) → the server and the prompt's index
  let c = cmd.find(':')
  if c < 1: return (nil, -1)
  let sn = cmd[0 ..< c].toLowerAscii
  let pn = cmd[c + 1 .. ^1].toLowerAscii
  for s in mcpServers:
    if s.dead or s.name.toLowerAscii != sn: continue
    for i, p in s.prompts:
      if p.name.toLowerAscii == pn: return (s, i)
  (nil, -1)

proc slashNames(): seq[string] =
  ## every /command, the MCP servers' prompts included
  for (c, _) in SlashCmds: result.add c
  for s in mcpServers:
    if not s.dead:
      for p in s.prompts: result.add "/" & s.name & ":" & p.name

proc mcpRunPrompt(s: McpServer, pi: int, rest, typed: string) =
  ## /server:prompt arg… — the server fills in the prompt, which is then sent as your message
  let pr = s.prompts[pi]
  var vals: Table[string, string]
  var pos: seq[string]
  for tok in parseCmdLine(rest):
    let eq = tok.find('=')
    var named = false
    if eq > 0:
      for (n, _, _) in pr.args:
        if n == tok[0 ..< eq]:
          vals[n] = tok[eq + 1 .. ^1]
          named = true
    if not named: pos.add tok
  var k = 0
  for ai, (n, _, _) in pr.args:
    if n in vals: continue
    if k < pos.len:
      vals[n] = (if ai == pr.args.high: pos[k .. ^1].join(" ") else: pos[k])
      inc k
  var missing: seq[string]
  for (n, d, req) in pr.args:
    if req and n notin vals: missing.add n & (if d.len > 0: " (" & d & ")" else: "")
  if missing.len > 0:
    aiMsgs.add AiMsg(role: 3, text: "/" & s.name & ":" & pr.name & " needs: " & missing.join(", ") &
                                    " — e.g. /" & s.name & ":" & pr.name & " " & pr.args[0][0] & "=…")
    inc aiVersion
    return
  var args = newJObject()
  for n, v in vals: args[n] = %v
  aiPhase = s.name & ": prompt " & pr.name
  needRender = true
  s.mcpRequest("prompts/get", %*{"name": pr.name, "arguments": args}, proc(res: JsonNode, err: string) =
    aiPhase = ""
    if err.len > 0:
      aiMsgs.add AiMsg(role: 3, text: "/" & s.name & ":" & pr.name & ": " & err)
      inc aiVersion
      needRender = true
      return
    var text = ""
    for m in jitems(res{"messages"}):
      let c = m{"content"}
      var part = ""
      if c != nil and c.kind == JObject:
        case c{"type"}.getStr
        of "text": part = c{"text"}.getStr
        of "resource": part = c{"resource", "text"}.getStr
        else: part = "[" & c{"type"}.getStr & "]"
      elif c != nil and c.kind == JArray:
        for x in c:
          if x{"type"}.getStr == "text": part.add x{"text"}.getStr & "\n"
      if part.len == 0: continue
      if text.len > 0: text.add "\n\n"
      text.add (if m{"role"}.getStr == "assistant": "(assistant) " else: "") & part
    if text.strip.len == 0:
      aiMsgs.add AiMsg(role: 3, text: "/" & s.name & ":" & pr.name & " returned no text")
      inc aiVersion
      return
    aiSend(text, true, typed))

proc isSlashCommand(t: string): bool =
  ## "/fix …" is a command; "/usr/bin/x crashes" is a message
  let sp = t.find(' ')
  let cmd = (if sp > 0: t[1 ..< sp] else: t[1 .. ^1]).toLowerAscii
  if cmd in ["?", "clear", "retry", "regenerate", "chats", "docs", "perf"]: return true
  if ':' in cmd and mcpPromptFind(cmd)[0] != nil: return true
  for (c, _) in SlashCmds:
    if c == "/" & cmd: return true
  false

proc slashCommand(t: string): (bool, string) =
  ## (handled, prompt to send instead — empty when nothing is sent)
  let sp = t.find(' ')
  let cmd = (if sp > 0: t[1 ..< sp] else: t[1 .. ^1]).toLowerAscii
  let rest = if sp > 0: t[sp + 1 .. ^1].strip else: ""
  let more = if rest.len > 0: "\n\n" & rest else: ""
  case cmd
  of "new", "clear":
    aiNewChat()
    (true, "")
  of "help", "?":
    var h = "Commands:\n"
    for (c, d) in SlashCmds: h.add "  " & c & " — " & d & "\n"
    for s in mcpServers:
      for p in s.prompts: h.add "  /" & s.name & ":" & p.name & " — " & truncTo(p.desc.splitLines()[0], 60) & " (MCP)\n"
    h.add "\nMentions attach context: @file @selection @diff @staged @problems @terminal @tree, or @path/to/file"
    aiMsgs.add AiMsg(role: 3, text: h)
    inc aiVersion
    (true, "")
  of "model":
    aiChooseModel()
    (true, "")
  of "provider":
    aiChooseProvider()
    (true, "")
  of "history", "chats":
    cmdChatHistory()
    (true, "")
  of "regen", "retry", "regenerate":
    aiRegenerate()
    (true, "")
  of "commit":
    aiCommitMessage()
    (true, "")
  of "explain": (true, "Explain what this code does — the big picture first, then anything subtle." & more)
  of "fix": (true, "Fix the compiler errors and warnings in this file. @problems" & more)
  of "tests": (true, "Write unit tests for this code (for Nim use std/unittest), add them to the project and run them." & more)
  of "doc", "docs": (true, "Add concise doc comments (## for Nim) to the public procs and types here, editing the file." & more)
  of "review": (true, "Review these uncommitted changes: bugs, risky spots and missing tests, most important first. @diff" & more)
  of "optimize", "perf": (true, "Make this code faster. Measure or reason about the hot path first; keep behaviour identical." & more)
  else:
    let (ms, mpi) = mcpPromptFind(cmd)
    if ms != nil:
      mcpRunPrompt(ms, mpi, rest, t)
      return (true, "")
    aiMsgs.add AiMsg(role: 3, text: "Unknown command /" & cmd & " — /help lists them")
    inc aiVersion
    (true, "")
