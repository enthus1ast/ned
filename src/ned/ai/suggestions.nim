# ── inline AI suggestions (opt-in: ai.inlineCompletion) — grey text after the cursor, Tab accepts ──

var
  ghostText = ""
  ghostBuf = -1
  ghostPos: Pos
  ghostChange = -1
  ghostJob: Job
  ghostAskedChange = -1
  ghostAskedBuf = -1

proc ghostVisible(b: Buffer): bool =
  ghostText.len > 0 and b.id == ghostBuf and b.changeId == ghostChange and b.cursors.len == 1 and
    b.primary.head == ghostPos and not b.primary.hasSel

proc ghostClear() =
  ghostText = ""
  ghostBuf = -1

var ghostFallback = ""     # the default suggestion model is not offered: use the chat model instead

proc ghostModel(): string =
  let m = sStr("ai.inlineCompletionModel")
  if m.len > 0: return m
  if ghostFallback.len > 0: return ghostFallback
  case cfgAiProvider
  of "anthropic": "claude-haiku-4-5"
  of "openai": "gpt-4.1-mini"          # fast and not a reasoning model: suggestions must arrive in a moment
  else: aiModel()

proc ghostAccept(): bool =
  let b = buf()
  if not ghostVisible(b) or not b.canEdit(): return false
  let t = ghostText
  ghostClear()
  b.beginEdit()
  let p = b.replaceText(b.primary.head, b.primary.head, t)
  b.endEdit()
  b.setSingle(p)
  true

proc ghostRequest(b: Buffer) =
  ## ask for a short continuation at the cursor (one request in flight; stale answers are dropped)
  if not haveExe("curl"): return
  let key = aiKey()
  if key.len == 0 and cfgAiProvider notin ["ollama", "custom"]: return
  let base = aiProviderBase()
  if base.len == 0: return
  let p = b.primary.head
  if ghostJob != nil and not ghostJob.done: killProc(ghostJob.pr)
  ghostAskedChange = b.changeId
  ghostAskedBuf = b.id
  var pre = ""
  for l in max(0, p.line - 80) ..< p.line: pre.add b.lines[l] & "\n"
  pre.add b.lines[p.line][0 ..< p.col]
  var suf = b.lines[p.line][p.col .. ^1]
  for l in p.line + 1 .. min(b.lines.high, p.line + 25): suf.add "\n" & b.lines[l]
  let instr = "You are a code completion engine. Continue the " & b.lang.name & " code at <CURSOR>. Reply with ONLY " &
              "the text to insert there — no explanation, no Markdown fences, nothing that is already after the " &
              "cursor. At most a few lines; stop at the end of the statement or block. If nothing fits, reply with " &
              "an empty message."
  let user = "File: " & (if b.path.len > 0: relPath(b.path) else: b.name) & "\n<code>\n" & pre & "<CURSOR>" & suf & "\n</code>"
  let anth = cfgAiProvider == "anthropic"
  let gm = ghostModel()
  let reasoning = cfgAiProvider == "openai" and isReasoningModel(gm)
  let resp = cfgAiProvider == "openai" and ((gm & "|responses") in aiQuirks or sStr("ai.openaiApi") == "responses")
  var body: JsonNode
  if anth:
    body = %*{"model": gm, "max_tokens": 128, "temperature": 0, "system": instr,
              "messages": [{"role": "user", "content": user}]}
  elif resp:
    body = %*{"model": gm, "max_output_tokens": (if reasoning: 2000 else: 160), "store": false,
              "instructions": instr, "input": [{"role": "user", "content": user}]}
  else:
    body = %*{"model": gm, "stream": false,
              "messages": [{"role": (if reasoning: "developer" else: "system"), "content": instr},
                           {"role": "user", "content": user}]}
    let mct = (cfgAiProvider == "openai" and (gm & "|maxtokens") notin aiQuirks) or (gm & "|mct") in aiQuirks
    body[(if mct: "max_completion_tokens" else: "max_tokens")] = %(if reasoning: 2000 else: 128)
    if not reasoning and (gm & "|notemp") notin aiQuirks: body["temperature"] = %0
  var hdr = "Content-Type: application/json\n"
  if anth: hdr.add "x-api-key: " & key & "\nanthropic-version: 2023-06-01\n"
  elif key.len > 0: hdr.add "Authorization: Bearer " & key & "\n"
  let hf = privTmp("ai-h")
  let bf = privTmp("ai-b")
  try:
    writeFile(hf, hdr)
    setFilePermissions(hf, {fpUserRead, fpUserWrite})
    writeFile(bf, $body)
    setFilePermissions(bf, {fpUserRead, fpUserWrite})
  except CatchableError: return
  let url = if anth: base & "/v1/messages" elif resp: base & "/responses" else: base & "/chat/completions"
  let cmd = "curl -sS --max-time 30 -X POST " & quoteShell(url) & " -H @" & quoteShell(hf) & " --data-binary @" & quoteShell(bf)
  let id = b.id
  let ch = b.changeId
  let at = p
  ghostJob = startJob(jkTool, cmd, rootDir, proc(j: Job) =
    try:
      removeFile(hf)
      removeFile(bf)
    except CatchableError: discard
    let bb = bufById(id)
    if bb == nil or bb.changeId != ch or bb.primary.head != at or j.code != 0: return
    var t = ""
    try:
      let r = parseJson(j.output)
      if jHasErr(r):
        # learn what the model refuses (max_tokens, temperature, chat endpoint …) for the next pause
        let saved = cfgAiModel
        cfgAiModel = gm
        let em = r{"error", "message"}.getStr
        let learned = aiLearnQuirk(em)
        cfgAiModel = saved
        let lem = em.toLowerAscii
        if sStr("ai.inlineCompletionModel").len == 0 and gm != aiModel() and aiModel().len > 0 and
           not learned and ("does not exist" in lem or "model_not_found" in lem or "no access" in lem or
                            ("not found" in lem and "model" in lem)):
          ghostFallback = aiModel()           # the default suggestion model is gone: use the chat model
          ghostAskedChange = -1
        elif learned: ghostAskedChange = -1   # ask again, adjusted; other errors wait for the next edit
        return
      if anth:
        if r{"content"} != nil and r["content"].kind == JArray:
          for blk in r["content"]:
            if blk{"type"}.getStr == "text": t.add blk{"text"}.getStr
      elif r{"output"} != nil and r["output"].kind == JArray:
        for item in r["output"]:
          if item{"type"}.getStr == "message" and item{"content"} != nil:
            for c in item["content"]:
              if c{"type"}.getStr == "output_text": t.add c{"text"}.getStr
      elif r{"choices"} != nil and r["choices"].kind == JArray and r["choices"].len > 0:
        t = r["choices"][0]{"message", "content"}.getStr
    except CatchableError: return
    if t.strip.startsWith("```"):
      var ls = t.strip.splitLines()
      if ls.len >= 2:
        ls = ls[1 .. ^1]
        if ls.len > 0 and ls[^1].strip.startsWith("```"): ls.setLen(ls.len - 1)
        t = ls.join("\n")
    t = t.strip(leading = false)
    if t.strip.len == 0: return
    # the model sometimes repeats what is already typed on the line
    let linePre = bb.lines[at.line][0 ..< at.col]
    let lp = linePre.strip(trailing = false)
    if lp.len > 0 and t.startsWith(lp) and t.len > lp.len: t = t[lp.len .. ^1]
    ghostText = t
    ghostBuf = id
    ghostPos = at
    ghostChange = ch
    needRender = true)

proc ghostTick() =
  ## main loop: after a typing pause, request a suggestion at the cursor
  if not sBool("ai.inlineCompletion") or focus != fEditor or compOpen or promptKind != pNone or
     pickKind != pickNone or aiInlineMode: return
  let b = buf()
  if b.readOnly or b.path.len == 0 or b.cursors.len != 1 or b.primary.hasSel or not b.dirty: return
  if b.changeId == ghostAskedChange and b.id == ghostAskedBuf: return
  if msSince(b.lspChangeAt) < max(250, sInt("ai.inlineCompletionDelay")): return
  let p = b.primary.head
  let rest = b.lines[p.line][p.col .. ^1].strip
  if rest.len > 0 and not rest.allCharsInSet({')', ']', '}', '"', '\'', ';', ',', ':'}): return
  if p.col == 0 and b.lines[p.line].len == 0 and p.line > 0 and b.lines[p.line - 1].strip.len == 0: return
  ghostRequest(b)
