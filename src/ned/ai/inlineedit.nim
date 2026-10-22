# ── inline edit (selection → AI → replacement) ──

func inlineClean(text: string): string =
  ## the model's replacement code: without a surrounding code fence if it added one
  var t = text.strip(chars = {'\n'})
  if t.startsWith("```"):
    let nl = t.find('\n')
    t = if nl >= 0: t[nl + 1 .. ^1] else: ""
    let e = t.rfind("```")
    if e >= 0: t = t[0 ..< e]
    t = t.strip(leading = false, chars = {'\n'})
  t

proc applyInlineEdit() =
  let bi = bufIndexByPath("")
  discard bi
  var b: Buffer = nil
  for x in bufs:
    if x.id == aiInlineBuf: b = x
  if b == nil: return
  let t = inlineClean(aiInlineText)
  b.beginEdit()
  let p = b.replaceText(aiInlineA, b.clampPos(aiInlineE), t)
  b.endEdit()
  b.setSingle(p, aiInlineA)
  info("AI edit applied — Ctrl+Z undoes it")
  needRender = true

proc foldHeaderFor(b: Buffer, l: int): int

proc aiInlinePrompt(b: Buffer, a, e: Pos, instruction: string): string =
  ## what the model is asked for an edit of the text between a and e: that code, what is around it, the
  ## declarations it uses, the instruction — and to answer with the replacement only (the AI fix in nedls asks
  ## the same)
  let code = b.getText(a, e)
  let ctxLo = max(0, a.line - 40)
  var before = ""
  for i in ctxLo ..< a.line: before.add b.lines[i] & "\n"
  var after = ""
  for i in e.line + 1 .. min(b.lines.high, e.line + 20): after.add b.lines[i] & "\n"
  let defs = codeDefinitionsFor(b, ctxLo, min(b.lines.high, e.line + 20))   # (so it uses the real APIs)
  "Rewrite the code in <code> according to the instruction. Reply with ONLY the " &
    "replacement code (no explanation, no Markdown fences), keeping the surrounding indentation. Use only the " &
    "names that exist: the code and <definitions> show them.\n" &
    "Language: " & b.lang.name & "\nFile: " & (if b.path.len > 0: relPath(b.path) else: b.name) & "\n" &
    "<before>\n" & before & "</before>\n<code>\n" & code & "\n</code>\n<after>\n" & after & "</after>\n" &
    (if defs.len > 0: defs & "\n" else: "") & "Instruction: " & instruction

proc aiInlineEdit(instruction: string) =
  let b = buf()
  if instruction.strip.len == 0: return
  if aiBusy or aiInlineMode:
    info("The assistant is busy — try again when it has finished (Esc in the assistant stops it)")
    return
  aiOneShotCb = nil
  var (a, e) = b.primary.range
  if a == e:
    # no selection: the enclosing block (proc, type, …) or else the current line
    let h = b.foldHeaderFor(a.line)
    if h >= 0 and a.line - h < 400:
      let (_, fe) = b.foldRange(h)
      a = Pos(line: h, col: 0)
      e = Pos(line: fe, col: b.lines[fe].len)
    else:
      a = Pos(line: a.line, col: 0)
      e = Pos(line: a.line, col: b.lines[a.line].len)
  aiInlineA = a
  aiInlineE = e
  aiInlineBuf = b.id
  aiInlineText = ""
  aiInlineMode = true
  let saved = aiMsgs
  aiMsgs = @[AiMsg(role: 0, text: aiInlinePrompt(b, a, e, instruction))]
  aiRequest()
  aiMsgs = saved
  info("Asking the AI to edit the selection…")

proc aiQuick(prompt: string) =
  showSide(svAssistant)
  aiSend(prompt)

proc aiAskAboutFile(path: string) =
  let b = openFile(path)
  if b == nil: return
  showSide(svAssistant)
  aiInput = "Explain what " & relPath(path) & " does and point out anything that looks wrong."
  aiInputCur = aiInput.len

proc typeModelAction(): (string, string, Action) =
  act("Type a model id…", "any model your provider offers", proc() =
    settingKey = "ai.model"
    settingNoUi = true
    openPrompt(pSetting, "AI model id for " & cfgAiProvider & " (e.g. gpt-5.1, o4-mini)", aiModel()))

proc aiChooseModel() =
  if cfgAiProvider == "anthropic":
    var items: seq[(string, string, Action)]
    items.add typeModelAction()
    for (m, d) in [("claude-opus-5-5", "most capable for long agentic coding"), ("claude-sonnet-5-5", "balanced (default)"),
                   ("claude-haiku-4-5", "fastest, cheapest"), ("claude-fable-5-1", "Mythos-class, demanding reasoning")]:
      let mm = m
      let dd = d
      capture mm:
        items.add act(mm & (if mm == aiModel(): "  ✓" else: ""), dd, proc() =
          setSetting("ai.model", %mm)
          info("AI model: " & mm))
    openActions("AI model — Anthropic", items)
    return
  if not haveExe("curl"):
    error("curl is needed: pkg install curl")
    return
  let base = aiProviderBase()
  if base.len == 0:
    error("Set ai.baseUrl first")
    return
  let key = aiKey()
  # the key goes to curl in a private file, never on the command line (other processes can read that)
  var hdrArg = ""
  if key.len > 0:
    let hf = privTmp("ai-h")
    try:
      writeFile(hf, "")
      setFilePermissions(hf, {fpUserRead, fpUserWrite})
      writeFile(hf, "Authorization: Bearer " & key & "\n")
      hdrArg = " -H @" & quoteShell(hf)
      aiTmp.add hf
    except CatchableError:
      error("Cannot write a temporary file in " & privDir())
      return
  info("Fetching models from " & base & "…")
  discard startJob(jkTool, "curl -sS --max-time 20" & hdrArg & " " & quoteShell(base & "/models"), rootDir, proc(j: Job) =
    aiCleanup()
    var ids: seq[string]
    var why = ""
    try:
      let r = parseJson(j.output)
      if jHasErr(r):
        why = if r["error"].kind == JString: r["error"].getStr else: r{"error", "message"}.getStr
      if r{"data"} != nil and r["data"].kind == JArray:
        for m in r["data"]:
          let id = m{"id"}.getStr
          if id.len == 0: continue
          if cfgAiProvider == "openai":
            # only models that chat: not embeddings, speech, images, moderation …
            let x = id.toLowerAscii
            let chatty = x.startsWith("gpt-") or x.startsWith("chatgpt-") or "codex" in x or
                         (x.len > 1 and x[0] == 'o' and x[1] in Digits)
            var skip = not chatty
            for bad in ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe",
                        "moderation", "search", "instruct"]:
              if bad in x: skip = true
            if skip: continue
          ids.add id
    except CatchableError:
      let o = stripAnsi(j.output).strip
      if o.len > 0: why = truncTo(o.splitLines()[0], 120)
    var items: seq[(string, string, Action)]
    items.add typeModelAction()
    if ids.len == 0:
      error("Could not list the models" & (if why.len > 0: ": " & why else: "") & " — type a model id instead")
      openActions("AI model — " & cfgAiProvider, items)
      return
    ids.sort()
    for id in ids:
      let mm = id
      capture mm:
        items.add act(mm, (if mm == aiModel(): "current" else: ""), proc() =
          setSetting("ai.model", %mm)
          info("AI model: " & mm))
    openActions("AI model — " & cfgAiProvider, items))

proc cmdAiOffline()

proc aiChooseProvider() =
  var items: seq[(string, string, Action)]
  items.add act("On this device, offline…", "Ollama or llama.cpp: set up, download a model that fits", proc() = cmdAiOffline())
  for p in ["anthropic", "openai", "openrouter", "ollama", "groq", "deepseek", "gemini", "mistral", "custom"]:
    let pp = p
    let env = block:
      let old = cfgAiProvider
      cfgAiProvider = pp
      let e = aiKeyEnvName()
      cfgAiProvider = old
      e
    capture pp, env:
      items.add act(pp & (if pp == cfgAiProvider: "  ✓" else: ""),
                    (if pp == "ollama": "local models, no key" elif pp == "custom": "any OpenAI-compatible URL"
                     else: "key: $" & env & (if getEnv(env).len > 0: " ✓" else: "")), proc() =
        setSetting("ai.provider", %pp)
        if cfgAiModel.len > 0: setSetting("ai.model", %"")
        info("AI provider: " & pp & " · model " & (if aiModel().len > 0: aiModel() else: "(choose one)")))
  openActions("AI provider", items)
