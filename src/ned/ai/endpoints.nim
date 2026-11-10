# ── what an endpoint accepts differs per model; refusals are learned and the request retried ──

var
  aiRetries = 0
  aiReqMsgs: seq[AiMsg]       # the messages of the last one-shot/inline request (for a retry)
  aiNoStream = false          # the running request asked for one JSON reply instead of a stream
  aiFinish = ""               # why the model stopped (length / max_tokens … explains an empty reply)

# whether this model's endpoint has refused the thing `q` names before (learned by aiLearnQuirk), so that the request
# leaves it out
proc hasQuirk(q: string): bool = (aiModel() & "|" & q) in aiQuirks

proc isReasoningModel(m: string): bool =
  ## OpenAI reasoning models: no temperature, max_completion_tokens, and they think before answering
  let x = m.toLowerAscii.split('/')[^1]
  if x.contains("-chat"): return false          # gpt-5-chat-latest & co. are plain chat models
  x.len >= 2 and ((x[0] == 'o' and x[1] in Digits) or x.startsWith("gpt-5") or x.startsWith("gpt-6") or
                  x.startsWith("gpt-7") or x.startsWith("gpt-8") or x.startsWith("codex"))

proc aiOutputBudget(model: string): int =
  ## reasoning tokens count against the output limit: give thinking models room, or they answer with nothing
  result = if cfgAiProvider in ["openai", "openrouter"] and isReasoningModel(model): max(cfgAiMaxTokens, 25000)
           else: cfgAiMaxTokens
  for q in aiQuirks:                   # a limit the endpoint told us about ("cap:<n>")
    if q.startsWith(model & "|cap:"):
      try: result = min(result, parseInt(q[model.len + 5 .. ^1]))
      except ValueError: discard

proc useResponsesApi(): bool =
  ## whether to use OpenAI's Responses API, not chat completions: ai.openaiApi is "responses", or "auto" and the model
  ## has been found to need it
  cfgAiProvider == "openai" and (sStr("ai.openaiApi") == "responses" or
    (sStr("ai.openaiApi") == "auto" and hasQuirk("responses")))

proc aiLearnQuirk(msg: string): bool =
  ## an API refused something about the request: remember it for this model; true = retrying may help
  let m = msg.toLowerAscii
  var learned = false
  proc learn(q: string) =
    ## remembers the quirk `q` for the current model, and notes that something new was learned
    let key = aiModel() & "|" & q
    if key notin aiQuirks:
      aiQuirks.incl key
      learned = true
  var param = ""
  for marker in ["unsupported parameter: '", "unknown parameter: '", "unrecognized request argument supplied: ",
                 "unsupported value: '"]:
    let k = m.find(marker)
    if k >= 0:
      let st = k + marker.len
      var e = st
      while e < m.len and m[e] notin {'\'', ' ', '\n', ',', '.'}: inc e
      param = m[st ..< e]
      break
  if "v1/responses" in m or "responses api" in m: learn("responses")
  if param == "max_tokens" or (param.len == 0 and "max_completion_tokens" in m and "max_tokens" in m):
    learn("mct")
  elif param == "max_completion_tokens": learn("maxtokens")
  if param == "temperature" or ("temperature" in m and ("unsupported" in m or "not supported" in m or
                                                         "only the default" in m or "does not support" in m)):
    learn("notemp")
  if param.startsWith("stream_options"): learn("nostreamopts")
  elif param == "stream" or "verified to stream" in m or
       (" streaming" in m and ("not supported" in m or "unsupported" in m or "not available" in m)):
    learn("nostream")       # e.g. "Your organization must be verified to stream this model"
  if param.startsWith("tools") or param.startsWith("tool_choice") or
     (("tool" in m or "function" in m) and ("not supported" in m or "does not support" in m)):
    learn("notools")
  if "role" in m and "'system'" in m: learn("developer")
  if "role" in m and "'developer'" in m: learn("nosysrole")
  if "token" in m:
    # "max_tokens is too large: 25000. This model supports at most 16384 completion tokens" and the like
    for marker in ["at most ", "less than or equal to ", "maximum of ", "maximum value for max_tokens is "]:
      let k = m.find(marker)
      if k < 0: continue
      var i = k + marker.len
      while i < m.len and m[i] in {'`', '\'', ' '}: inc i
      var num = ""
      while i < m.len and m[i] in Digits: (num.add m[i]; inc i)
      if num.len in 3 .. 7:
        learn("cap:" & num)
        break
    let w = m.find(", which is the maximum")      # Anthropic: "max_tokens: 64000 > 32000, which is the maximum …"
    if w > 0:
      var i = w - 1
      while i >= 0 and m[i] in Digits: dec i
      let num = m[i + 1 ..< w]
      if num.len in 3 .. 7: learn("cap:" & num)
  learned

proc openaiTools(flat: bool): JsonNode =
  ## the tools the model may call — the built-in ones and the MCP servers' — in OpenAI's format; `flat` is the Responses
  ## API's, with the function's fields at the top instead of under "function"
  result = newJArray()
  for (n, d, sc) in AiTools:
    if flat: result.add %*{"type": "function", "name": n, "description": d, "parameters": parseJson(sc)}
    else: result.add %*{"type": "function", "function": {"name": n, "description": d, "parameters": parseJson(sc)}}
  for (n, d, sc) in mcpTools():
    if flat: result.add %*{"type": "function", "name": n, "description": d, "parameters": sc}
    else: result.add %*{"type": "function", "function": {"name": n, "description": d, "parameters": sc}}

proc aiArgsSent(args: string): string =
  ## a tool call's arguments as sent back with the conversation: the model's JSON written out again strictly — a local
  ## model's literal tab or newline inside a string, a comma before `}` — for a server that reads them (llama.cpp
  ## answers the whole request with HTTP 500 otherwise); "{}" for arguments that are not JSON at all (the tool's
  ## result says so)
  if args.strip.len == 0: return "{}"
  try: $parseJson(args)
  except CatchableError: "{}"

proc openaiBody(): JsonNode =
  ## the request for a chat-completions endpoint: the system prompt (as a developer message for reasoning models, or in
  ## the first user message when the endpoint takes no system role), the conversation with its pictures, tool calls and
  ## results, then the options this model takes — streaming (with usage), the right name for the output limit,
  ## temperature, tools in agent mode
  let msgs = newJArray()
  let model = aiModel()
  let sysRole = if hasQuirk("developer") or (cfgAiProvider == "openai" and isReasoningModel(model)): "developer"
                else: "system"
  let noSys = hasQuirk("nosysrole")
  if not noSys: msgs.add %*{"role": sysRole, "content": aiSystemPrompt()}
  var first = true
  let lastUser = aiLastUser()
  for mi, m in aiMsgs:
    case m.role
    of 0:
      msgs.add %*{"role": "user", "content": aiUserContent(m, (if noSys and first: aiSystemPrompt() & "\n\n" & m.text
                                                                else: m.text), "openai")}
      first = false
    of 1:
      var o = %*{"role": "assistant", "content": m.text}
      if m.calls.len > 0:
        let tc = newJArray()
        for c in m.calls:
          tc.add %*{"id": c.id, "type": "function", "function": {"name": c.name, "arguments": aiArgsSent(c.args)}}
        o["tool_calls"] = tc
        if m.text.len == 0: o["content"] = newJNull()
      msgs.add o
    of 2:
      for c in m.calls: msgs.add %*{"role": "tool", "tool_call_id": c.id, "content": aiSentResult(mi, c, lastUser)}
    else: discard
  let stream = not hasQuirk("nostream")
  result = %*{"model": model, "stream": stream, "messages": msgs}
  if stream and cfgAiProvider in ["openai", "openrouter", "deepseek"] and not hasQuirk("nostreamopts"):
    result["stream_options"] = %*{"include_usage": true}
  if cfgAiProvider != "ollama":
    # OpenAI wants max_completion_tokens (the only one its reasoning models accept); others max_tokens
    let mct = (cfgAiProvider == "openai" and not hasQuirk("maxtokens")) or hasQuirk("mct")
    result[(if mct: "max_completion_tokens" else: "max_tokens")] = %aiOutputBudget(model)
  if cfgAiTemp >= 0 and not hasQuirk("notemp") and not (cfgAiProvider == "openai" and isReasoningModel(model)):
    result["temperature"] = %(cfgAiTemp.float / 100.0)
  if cfgAiAgent and not aiInlineMode and not hasQuirk("notools"):
    result["tools"] = openaiTools(false)

proc responsesBody(): JsonNode =
  ## OpenAI Responses API (models that are not served by /chat/completions)
  var items = newJArray()
  let lastUser = aiLastUser()
  for mi, m in aiMsgs:
    case m.role
    of 0: items.add %*{"role": "user", "content": aiUserContent(m, m.text, "responses")}
    of 1:
      if m.text.len > 0: items.add %*{"role": "assistant", "content": m.text}
      for c in m.calls:
        items.add %*{"type": "function_call", "call_id": c.id, "name": c.name, "arguments": aiArgsSent(c.args)}
    of 2:
      for c in m.calls: items.add %*{"type": "function_call_output", "call_id": c.id, "output": aiSentResult(mi, c, lastUser)}
    else: discard
  result = %*{"model": aiModel(), "stream": not hasQuirk("nostream"), "store": false,
              "instructions": aiSystemPrompt(), "input": items, "max_output_tokens": aiOutputBudget(aiModel())}
  if cfgAiTemp >= 0 and not hasQuirk("notemp") and not isReasoningModel(aiModel()):
    result["temperature"] = %(cfgAiTemp.float / 100.0)
  if cfgAiAgent and not aiInlineMode and not hasQuirk("notools"):
    result["tools"] = openaiTools(true)

proc aiCleanup() =
  ## deletes the temporary files of the request (its headers, which hold the key, and its body)
  for f in aiTmp:
    try: removeFile(f)
    except CatchableError: discard
  aiTmp.setLen(0)

proc aiPlanRunDone(): bool
proc aiPlanInterrupted() =
  ## a plan's run failed or was stopped: the plan waits (palette › AI: the plan…)
  if aiPlanState in {apPlanning, apDoing}: aiPlanState = (if aiPlanSteps.len > 0: apReady else: apNone)

proc aiFail(msg: string) =
  ## ends the request with an error: a plan being run waits, the message is added to the chat as a notice (with a hint
  ## about pictures when the model may not read them) and the assistant is idle again
  aiPlanInterrupted()
  var msg = msg
  var pics = false
  for m in aiMsgs:
    if m.pics.len > 0: pics = true
  if pics and ("image" in msg.toLowerAscii or "vision" in msg.toLowerAscii or "multimodal" in msg.toLowerAscii):
    msg.add " — the message has pictures: this model may not read them (choose one that does, or send it without)"
  aiMsgs.add AiMsg(role: 3, text: msg)
  aiBusy = false
  aiPhase = ""
  aiInlineMode = false
  aiOneShotCb = nil
  inc aiVersion
  needRender = true

proc jHasErr(j: JsonNode): bool =
  ## an "error" member that is set (the Responses API sends "error": null on success)
  j{"error"} != nil and j["error"].kind notin {JNull}

proc aiContentParts(c: JsonNode, think, text: var string)

proc aiApplyWhole(raw: string): bool =
  ## a non-streamed reply (stream=false): one JSON document in chat-completions or Responses format
  var r: JsonNode
  try: r = parseJson(raw.strip)
  except CatchableError: return false
  if r.kind != JObject or jHasErr(r): return false
  var text, think = ""
  var calls: seq[AiCall]
  if r{"choices"} != nil and r["choices"].kind == JArray and r["choices"].len > 0:
    let ch = r["choices"][0]
    aiFinish = ch{"finish_reason"}.getStr
    let msg = ch{"message"}
    if msg != nil and msg.kind == JObject:
      text = msg{"content"}.getStr
      think = msg{"reasoning_content"}.getStr
      if think.len == 0: think = msg{"reasoning"}.getStr
      aiContentParts(msg{"content"}, think, text)
      if msg{"tool_calls"} != nil and msg["tool_calls"].kind == JArray:
        for c in msg["tool_calls"]:
          calls.add AiCall(id: c{"id"}.getStr("call_" & $calls.len), name: c{"function", "name"}.getStr,
                           args: c{"function", "arguments"}.getStr)
    let u = r{"usage"}
    if u != nil and u.kind == JObject:
      aiReqIn = u{"prompt_tokens"}.getInt
      aiReqOut = u{"completion_tokens"}.getInt
      aiReqCacheRead = u{"prompt_tokens_details", "cached_tokens"}.getInt
  elif r{"output"} != nil and r["output"].kind == JArray:
    if r{"status"}.getStr == "incomplete": aiFinish = r{"incomplete_details", "reason"}.getStr("length")
    for item in r["output"]:
      case item{"type"}.getStr
      of "message":
        if item{"content"} != nil and item["content"].kind == JArray:
          for c in item["content"]:
            if c{"type"}.getStr == "output_text": text.add c{"text"}.getStr
      of "reasoning":
        if item{"summary"} != nil and item["summary"].kind == JArray:
          for c in item["summary"]: think.add c{"text"}.getStr
      of "function_call":
        calls.add AiCall(id: item{"call_id"}.getStr, name: item{"name"}.getStr, args: item{"arguments"}.getStr)
      else: discard
    let u = r{"usage"}
    if u != nil and u.kind == JObject:
      aiReqIn = u{"input_tokens"}.getInt
      aiReqOut = u{"output_tokens"}.getInt
      aiReqCacheRead = u{"input_tokens_details", "cached_tokens"}.getInt
  elif r{"content"} != nil and r["content"].kind == JArray:      # Anthropic Messages
    aiFinish = r{"stop_reason"}.getStr
    for blk in r["content"]:
      if blk{"type"}.getStr == "text": text.add blk{"text"}.getStr
      elif blk{"type"}.getStr == "thinking": think.add blk{"thinking"}.getStr
      elif blk{"type"}.getStr == "tool_use":
        calls.add AiCall(id: blk{"id"}.getStr, name: blk{"name"}.getStr,
                         args: (if blk{"input"} != nil: $blk["input"] else: "{}"))
  else: return false
  let (inText, answer) = splitThink(text)        # (<think> … </think> written into the answer)
  if inText.len > 0: think.add (if think.len > 0: "\n\n" else: "") & inText
  if aiInlineMode:
    aiInlineText.add answer
    aiInlineThink.add think
  elif aiMsgs.len > 0 and aiMsgs[^1].role == 1:
    aiMsgs[^1].text.add answer
    aiMsgs[^1].think.add think
    aiMsgs[^1].calls.add calls
  true

proc fmtTokens(n: int): string

proc aiCostText(inTok, outTok, cacheTok: int): string =
  ## "$0.042" with ai.price set, "" otherwise
  let pr = settingNode("ai.price")
  if pr == nil or pr.kind != JObject or pr.len == 0: return ""
  proc rate(k: string): float =
    ## the price per million tokens set in ai.price for that kind (0 when it has none)
    let v = pr{k}
    if v == nil: 0.0 elif v.kind == JFloat: v.getFloat elif v.kind == JInt: v.getInt.float else: 0.0
  let usd = (inTok.float * rate("input") + outTok.float * rate("output") + cacheTok.float * rate("cacheRead")) / 1e6
  "$" & formatFloat(usd, ffDecimal, (if usd < 0.1: 3 else: 2))

proc aiLogWrite(s: string) =
  ## adds `s` to the request log (ai.log), a file only you can read in ned's state folder; past 4 MB it becomes ai.log.1
  ## (the one before goes) and a new one begins
  if not cfgAiLog: return
  let p = stateDir() / "ai.log"
  try:
    createDir(parentDir(p))
    if fileExists(p) and getFileSize(p) > 4_000_000: moveFile(p, p & ".1")
    let fresh = not fileExists(p)
    var f = open(p, fmAppend)
    if fresh: setFilePermissions(p, {fpUserRead, fpUserWrite})
    f.write(s)
    f.close()
  except CatchableError: discard

func aiLoggedUrl(u: string): string =
  ## the address for the log, without a user and password in it or a query (where a key could be)
  result = u
  let q = result.find('?')
  if q >= 0: result.setLen(q)
  let s = result.find("://")
  if s >= 0:
    let at = result.find('@', s + 3)
    let slash = result.find('/', s + 3)
    if at >= 0 and (slash < 0 or at < slash): result = result[0 ..< s + 3] & result[at + 1 .. ^1]

func aiSizeText(n: int): string =
  ## a size in bytes for people: 812 B, 3.2 KB, 1.4 MB
  if n < 1024: $n & " B"
  elif n < 1024 * 1024: formatFloat(n / 1024, ffDecimal, 1) & " KB"
  else: formatFloat(n / (1024 * 1024), ffDecimal, 1) & " MB"

proc aiEndSplit()
proc aiReplyForLog(): string

proc aiRequest() =
  ## sends the conversation to the model with curl as a streaming job: checks curl, key, model and address first, waits
  ## for the MCP servers' tools in agent mode, builds the body for the provider (Anthropic, Responses, chat completions)
  ## with secrets replaced, asks before a request over ai.warnTokens, and keeps the headers and body in private
  ## temporary files. When curl ends it adds up the tokens, turns a refusal of a parameter into a retry (up to three
  ## times), reports a failure with a hint, and otherwise runs the tool calls it was sent, or finishes the answer (an
  ## empty one is explained) with a toast about changed files or the reply. Inline edits and one-shot requests are
  ## handed to their own callback
  if not haveExe("curl"):
    aiFail("The assistant needs curl:  pkg install curl")
    return
  let key = aiKey()
  if key.len == 0 and cfgAiProvider notin ["ollama", "custom"]:
    aiFail("No API key for " & cfgAiProvider & ". Set it in your shell (e.g. ~/.bashrc):\n\n    export " &
           aiKeyEnvName() & "=…\n\nthen restart ned — or put it in settings as \"ai.apiKey\" (palette › AI: settings…).")
    return
  if aiModel().len == 0:
    aiFail("Choose a model for " & cfgAiProvider & ": palette › AI: choose model…  (or set \"ai.model\" in settings)")
    return
  let base = aiProviderBase()
  if base.len == 0:
    aiFail("Set \"ai.baseUrl\" for the custom provider (an OpenAI-compatible endpoint).")
    return
  if cfgAiAgent and not aiInlineMode:
    mcpStartAll()
    if mcpStarting():                         # their tools belong in this request: wait (at most 20 s)
      mcpWaitReq = true
      aiBusy = true
      aiPhase = "starting MCP servers…"
      needRender = true
      return
  let anth = cfgAiProvider == "anthropic"
  let resp = not anth and useResponsesApi()
  aiRespApi = resp
  let url = if anth: base & "/v1/messages" elif resp: base & "/responses" else: base & "/chat/completions"
  let body = if anth: anthropicBody() elif resp: responsesBody() else: openaiBody()
  aiRedactBody(body)
  if not aiInlineMode and not aiWarnOk and aiSteps == 0 and cfgAiWarnTokens > 0:
    let est = ($body).len div 4
    if est > cfgAiWarnTokens:
      let cost = aiCostText(est, 0, 0)
      askConfirm("This request is about " & fmtTokens(est) & " tokens" & (if cost.len > 0: " (" & cost & ")" else: "") &
                 " — send it? (y/n)  ai.warnTokens sets the limit", proc(c: char) =
        if c in {'y', 'Y'}:
          aiWarnOk = true
          aiRequest()
        else:
          if aiMsgs.len > 0 and aiMsgs[^1].role == 0: aiMsgs.setLen(aiMsgs.len - 1)
          info("Not sent — select less, or turn off \"ai.includeFile\"")
          needRender = true)
      return
  if aiInlineMode: aiReqMsgs = aiMsgs
  aiNoStream = body{"stream"} != nil and body["stream"].kind == JBool and not body["stream"].getBool
  aiFinish = ""
  var hdr = "Content-Type: application/json\nAccept: " & (if aiNoStream: "application/json" else: "text/event-stream") & "\n"
  if anth:
    hdr.add "x-api-key: " & key & "\nanthropic-version: 2023-06-01\n"
  elif key.len > 0:
    hdr.add "Authorization: Bearer " & key & "\n"
  if cfgAiProvider == "openrouter": hdr.add "X-Title: ned editor\n"
  let hf = privTmp("ai-h")
  let bf = privTmp("ai-b")
  try:
    writeFile(hf, hdr)
    setFilePermissions(hf, {fpUserRead, fpUserWrite})
    let sent = utf8Repaired($body)        # (a byte that is not UTF-8 from a file or a command: the request refused)
    writeFile(bf, sent)
    setFilePermissions(bf, {fpUserRead, fpUserWrite})
    aiLogWrite("\n━━ " & now().format("yyyy-MM-dd HH:mm:ss") & "  sent to " & aiLoggedUrl(url) & "  (" & aiModel() &
               ", " & aiSizeText(sent.len) & ")\n" & sent & "\n")
  except CatchableError as e:
    aiFail("Cannot write request: " & e.msg)
    return
  aiTmp.add hf
  aiTmp.add bf
  aiRaw.setLen(0)
  aiHttp.setLen(0)
  aiBlocks.clear()
  aiTokensOut = 0
  aiReqIn = 0
  aiReqOut = 0
  aiReqCacheRead = 0
  aiReqCacheWrite = 0
  aiSplit = ThinkSplit()
  aiInlineThink = ""
  aiReqStart = getMonoTime()
  aiBusy = true
  aiPhase = "thinking…"
  if not aiInlineMode: aiMsgs.add AiMsg(role: 1)
  inc aiVersion
  let cmd = "curl -sS -N --no-buffer --max-time 900 -X POST " & quoteShell(url) & " -H @" & quoteShell(hf) &
            " --data-binary @" & quoteShell(bf) & " -w '\\n__HTTP__%{http_code}\\n'"
  aiJob = startJob(jkAi, cmd, rootDir, proc(j: Job) =
    if j.partial.len > 0:
      aiLine(j.partial)
      j.partial = ""
    aiCleanup()
    if j != aiJob: return
    aiJob = nil
    aiEndSplit()
    let logged = if cfgAiLog: aiReplyForLog() else: ""   # (before the secrets go back into what it wrote)
    if aiSecretTab.items.len > 0:
      # (a placeholder the model wrote where a secret belongs: the secret goes back into what becomes a file's text
      #  — an inline edit or a one-shot answer, edit_file, write_file — never into a command, an MCP call or the chat)
      if aiInlineMode: aiInlineText = restoreSecrets(aiInlineText, aiSecretTab)
      elif aiMsgs.len > 0 and aiMsgs[^1].role == 1:
        for c in aiMsgs[^1].calls.mitems:
          if c.name in ["edit_file", "write_file"]: c.args = restoreSecretsJson(c.args, aiSecretTab)
    let code = try: parseInt(aiHttp) except ValueError: 0
    aiUsageIn += aiReqIn
    aiUsageOut += aiReqOut
    aiUsageCacheRead += aiReqCacheRead
    aiUsageCacheWrite += aiReqCacheWrite
    var failed = code >= 400 or (code == 0 and j.code != 0)
    if not failed and aiNoStream and not aiApplyWhole(aiRaw):
      failed = true                       # 200 but not the JSON reply we asked for
    var m = aiRaw.strip
    if failed:
      try:
        let e = parseJson(m)
        let em = if e{"error"} != nil and e["error"].kind == JString: e["error"].getStr
                 else: e{"error", "message"}.getStr
        if em.len > 0: m = em
      except CatchableError: discard
    if cfgAiLog:
      let secs = (getMonoTime() - aiReqStart).inMilliseconds.float / 1000
      aiLogWrite("━━ " & now().format("yyyy-MM-dd HH:mm:ss") & "  came back after " & formatFloat(secs, ffDecimal, 1) &
                 " s: " & (if code > 0: "HTTP " & $code else: "no answer (curl " & $j.code & ")") &
                 (if aiFinish.len > 0: ", finish reason " & aiFinish else: "") &
                 (if aiReqIn + aiReqOut > 0: ", " & $aiReqIn & " tokens in, " & $aiReqOut & " out" else: "") & "\n" &
                 (if failed: "[error]\n" & m & "\n" else: "") & logged)
    # the endpoint refused a parameter this model does not take: learn it and ask again
    let retry = failed and code in [400, 404, 422] and aiRetries < 3 and aiLearnQuirk(m)
    if retry: inc aiRetries
    else: aiRetries = 0
    if aiInlineMode:
      if retry:
        let saved = aiMsgs
        aiMsgs = aiReqMsgs
        aiInlineText = ""
        aiRequest()
        aiMsgs = saved
        return
      aiInlineMode = false
      aiBusy = false
      aiPhase = ""
      let cb = aiOneShotCb
      aiOneShotCb = nil
      if failed:
        error("AI request failed: " & (if m.len > 0: m.splitLines[0] else: "HTTP " & aiHttp))
      elif aiInlineText.strip.len == 0:
        error("The model sent an empty reply" & (if aiFinish.len > 0: " (finish reason: " & aiFinish & ")" else: "") &
              " — try again or choose another model")
      elif cb != nil: cb(aiInlineText)
      else: applyInlineEdit()
      return
    let mi = aiMsgs.high
    if failed:
      if mi >= 0 and aiMsgs[mi].role == 1 and aiMsgs[mi].text.len == 0 and aiMsgs[mi].calls.len == 0: aiMsgs.delete(mi)
      if retry:
        aiPhase = "adjusting the request for " & aiModel() & "…"
        aiRequest()
        return
      let lm = m.toLowerAscii
      let hint =
        if code == 401 or "api key" in lm or "api_key" in lm:
          "\n\nCheck the key: " & aiKeyEnvName() & " in the shell that started ned, or \"ai.apiKey\" in settings."
        elif "quota" in lm or "billing" in lm or "credit" in lm:
          "\n\nThe account has no usable credit for this key or project (new credit can take a few minutes, " &
          "and keys made before buying credit sometimes need to be created again)."
        elif code == 404 or "does not exist" in lm or "model_not_found" in lm or "no access" in lm:
          "\n\nThis key cannot use " & aiModel() & ". Pick another one: palette › AI: choose model…"
        elif code == 429: "\n\nRate limited — wait a moment and use ↻ Retry."
        else: ""
      aiFail("Request failed" & (if code > 0: " (HTTP " & $code & ")" else: "") & ": " &
             (if m.len > 0: m else: "no response — check the network, ai.baseUrl and ai.model") & hint)
      saveChat()
      return
    if mi >= 0 and aiMsgs[mi].role == 1 and aiMsgs[mi].calls.len > 0:
      aiPhase = "running tools"
      aiContinue()
    else:
      if mi >= 0 and aiMsgs[mi].role == 1 and aiMsgs[mi].text.strip.len == 0:
        # an empty answer is never what the user wanted: say why instead of showing nothing
        aiMsgs.delete(mi)
        let f = aiFinish.toLowerAscii
        aiMsgs.add AiMsg(role: 3, text: "The model sent an empty reply" &
          (if f in ["length", "max_tokens", "max_output_tokens"]:
             " — it used up its token limit (" & $aiOutputBudget(aiModel()) & ") before answering. Thinking models " &
             "spend tokens on reasoning first: raise \"ai.maxTokens\" in settings, or ask something smaller."
           elif f.len > 0: " (finish reason: " & aiFinish & "). Try again, or choose another model."
           else: ". Try again, or choose another model (palette › AI: choose model…)."))
      aiBusy = false
      aiPhase = ""
      saveChat()
      if aiPlanRunDone(): discard                   # (a plan: its next step, or its menu)
      elif aiRunCp >= 0 and aiRunCp <= aiCheckpoints.high and aiCheckpoints[aiRunCp].files.len > 0:
        let id = aiCheckpoints[aiRunCp].id
        let n = aiCheckpoints[aiRunCp].files.len
        aiRunCp = -1
        toast("The assistant changed " & $n & " file(s)", 3, "Review", proc() =
          aiReviewCheckpoint(id), 15000)
      elif focus != fRight or rightView != svAssistant or not rightOpen:
        toast("The assistant replied", 4, "Show", proc() = showSide(svAssistant))
    inc aiVersion
    needRender = true)
  if aiJob == nil: aiFail("Could not start curl")

proc curAssistant(): int =
  ## the index of the assistant message being written (the last one), -1 when the last message is not one
  if aiMsgs.len > 0 and aiMsgs[^1].role == 1: aiMsgs.high else: -1

proc aiEndSplit() =
  ## the reply is complete: what the <think> splitter held back goes to the thinking or the answer. A chat keeps the last
  ## 64 KB of each thinking (its conclusion), so that a long chat with a thinking model does not grow without end
  if aiInlineMode: aiSplit.finish(aiInlineThink, aiInlineText)
  else:
    let mi = curAssistant()
    if mi >= 0:
      aiSplit.finish(aiMsgs[mi].think, aiMsgs[mi].text)
      if aiMsgs[mi].think.len > 65536:
        let t = aiMsgs[mi].think
        aiMsgs[mi].think = "… " & t[utf8Cut(t, t.len - 65536) .. ^1]

proc aiReplyForLog(): string =
  ## what came back, for the request log: the thinking, the answer and each tool call with its arguments
  if aiInlineMode:
    if aiInlineThink.len > 0: result.add "[thinking]\n" & aiInlineThink & "\n"
    result.add "[answer]\n" & aiInlineText & "\n"
    return
  let mi = curAssistant()
  if mi < 0: return
  if aiMsgs[mi].think.len > 0: result.add "[thinking]\n" & aiMsgs[mi].think & "\n"
  if aiMsgs[mi].text.len > 0: result.add "[answer]\n" & aiMsgs[mi].text & "\n"
  for c in aiMsgs[mi].calls: result.add "[tool call] " & c.name & " " & c.args & "\n"

proc aiCallTarget(c: AiCall): string =
  ## what a tool call is about in a few words, read from its arguments even while they are still being written:
  ## "edit src/a.nim", "$ nimble test", or its name
  case c.name
  of "edit_file": "edit " & partialJsonString(c.args, "path")
  of "write_file": "write " & partialJsonString(c.args, "path")
  of "read_file": "read " & partialJsonString(c.args, "path")
  of "run_command":
    let cmd = partialJsonString(c.args, "command")
    let nl = cmd.find('\n')
    "$ " & (if nl < 0: cmd else: cmd[0 ..< nl] & " …")
  of "search": "search \"" & partialJsonString(c.args, "query") & "\""
  else: c.name

proc aiDeltaThought(d: JsonNode): string =
  ## a chat-completions delta's thinking: reasoning_content (llama.cpp, LM Studio, DeepSeek) or reasoning (Ollama,
  ## OpenRouter, vLLM, Groq) — only one of them when a server sends both
  if d == nil or d.kind != JObject: return ""
  result = d{"reasoning_content"}.getStr
  if result.len == 0: result = d{"reasoning"}.getStr

proc aiWaitedText(): string =
  ## how long the request has run, for the chat while the model works: " · 14 s" (nothing in its first 3 seconds) — a
  ## local model can take minutes to read a long request before anything comes
  if not aiBusy or aiJob == nil: return ""
  let secs = (getMonoTime() - aiReqStart).inSeconds
  if secs < 3: "" else: " · " & $secs & " s"

proc aiContentParts(c: JsonNode, think, text: var string) =
  ## a content given as a list of parts (Mistral's thinking models): its text parts to `text`, its thinking parts to
  ## `think`
  if c == nil or c.kind != JArray: return
  for part in c:
    case part{"type"}.getStr
    of "text": text.add part{"text"}.getStr
    of "thinking":
      let t = part{"thinking"}
      if t != nil and t.kind == JArray:
        for x in t: think.add x{"text"}.getStr
      else: think.add t.getStr
    else: discard

proc aiThinkPhase(think: string): string =
  ## the phase while a model thinks: "thinking · 312 words"
  "thinking · " & $wordCount(think) & " words"

proc aiCallPhase(c: AiCall): string =
  ## the phase while a tool call is being written: "calling edit src/a.nim · 3.2 KB"
  "calling " & aiCallTarget(c) & (if c.args.len >= 1024: " · " & aiSizeText(c.args.len) else: "")

proc aiLine(line: string) =
  ## one line of curl's output: the HTTP status marker is kept; a reply that is not streamed is collected whole; a line
  ## of the stream is read for its text, tool calls, token counts, finish reason and errors, in the form of the
  ## provider's API (Anthropic, Responses or chat completions), and added to the assistant's message — or to the text of
  ## an inline edit
  var l = line
  if l.endsWith('\r'): l.setLen(l.len - 1)
  if l.startsWith("__HTTP__"):
    aiHttp = l[8 .. ^1].strip
    return
  if aiNoStream:                      # one JSON document: keep all of it
    if aiRaw.len < 8_000_000: aiRaw.add l & "\n"
    return
  if l.len == 0 or l.startsWith("event:") or l.startsWith(":"): return
  if not l.startsWith("data:"):
    if aiRaw.len < 20000: aiRaw.add l & "\n"
    return
  let data = l[5 .. ^1].strip
  if data == "[DONE]": return
  var j: JsonNode
  try: j = parseJson(data)
  except CatchableError: return
  if aiInlineMode:
    var r = ""                           # (the thinking in this piece, if the model thinks)
    if cfgAiProvider == "anthropic": r = j{"delta", "thinking"}.getStr
    elif aiRespApi:
      if j{"type"}.getStr in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"]:
        r = j{"delta"}.getStr
    elif j{"choices"} != nil and j["choices"].kind == JArray and j["choices"].len > 0:
      r = aiDeltaThought(j["choices"][0]{"delta"})
    aiInlineThink.add r
    let t = if cfgAiProvider == "anthropic": j{"delta", "text"}.getStr
            elif aiRespApi: (if j{"type"}.getStr == "response.output_text.delta": j{"delta"}.getStr else: "")
            else: (if j{"choices"} != nil and j["choices"].kind == JArray and j["choices"].len > 0:
                     j["choices"][0]{"delta", "content"}.getStr else: "")
    if aiRespApi and j{"type"}.getStr in ["response.failed", "error"]:
      aiRaw.add (if j{"response", "error", "message"}.getStr.len > 0: j{"response", "error", "message"}.getStr
                 else: j{"error", "message"}.getStr & j{"message"}.getStr) & "\n"
      aiHttp = "500"
    elif not aiRespApi and j{"error"} != nil and j["error"].kind == JObject:
      aiRaw.add j{"error", "message"}.getStr & "\n"       # an error in the middle of the stream
      aiHttp = "500"
    if j{"choices"} != nil and j["choices"].kind == JArray and j["choices"].len > 0 and
       j["choices"][0]{"finish_reason"} != nil and j["choices"][0]["finish_reason"].kind == JString:
      aiFinish = j["choices"][0]["finish_reason"].getStr
    aiSplit.feed(t, aiInlineThink, aiInlineText)
    aiTokensOut += (t.len + r.len) div 4
    aiPhase = if aiInlineText.len == 0 and aiInlineThink.len > 0: aiThinkPhase(aiInlineThink)
              else: "editing… " & $aiTokensOut & " tokens"
    needRender = true
    return
  let mi = curAssistant()
  if mi < 0: return
  if aiRespApi:
    case j{"type"}.getStr
    of "response.output_text.delta":
      aiSplit.feed(j{"delta"}.getStr, aiMsgs[mi].think, aiMsgs[mi].text)
      aiPhase = "writing…"
    of "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
      aiMsgs[mi].think.add j{"delta"}.getStr
      aiPhase = aiThinkPhase(aiMsgs[mi].think)
    of "response.output_item.added":
      let it = j{"item"}
      if it != nil and it{"type"}.getStr == "function_call":
        aiMsgs[mi].calls.add AiCall(id: it{"call_id"}.getStr, name: it{"name"}.getStr, args: it{"arguments"}.getStr)
        aiBlocks[j{"output_index"}.getInt] = aiMsgs[mi].calls.high
        aiPhase = "calling " & it{"name"}.getStr
    of "response.function_call_arguments.delta":
      let ci = aiBlocks.getOrDefault(j{"output_index"}.getInt, -1)
      if ci >= 0 and ci < aiMsgs[mi].calls.len:
        aiMsgs[mi].calls[ci].args.add j{"delta"}.getStr
        aiPhase = aiCallPhase(aiMsgs[mi].calls[ci])
    of "response.function_call_arguments.done":
      let ci = aiBlocks.getOrDefault(j{"output_index"}.getInt, -1)
      if ci >= 0 and ci < aiMsgs[mi].calls.len and j{"arguments"}.getStr.len > 0:
        aiMsgs[mi].calls[ci].args = j{"arguments"}.getStr
    of "response.completed", "response.incomplete":
      if j{"type"}.getStr == "response.incomplete":
        aiFinish = j{"response", "incomplete_details", "reason"}.getStr("length")
      let u = j{"response", "usage"}
      if u != nil and u.kind == JObject:
        aiReqIn = u{"input_tokens"}.getInt
        aiReqOut = u{"output_tokens"}.getInt
        aiReqCacheRead = u{"input_tokens_details", "cached_tokens"}.getInt
    of "response.failed", "error":
      let em = j{"response", "error", "message"}.getStr
      aiRaw.add (if em.len > 0: em else: j{"error", "message"}.getStr & j{"message"}.getStr) & "\n"
      aiHttp = "500"
    else: discard
    inc aiVersion
    needRender = true
    return
  if cfgAiProvider == "anthropic":
    case j{"type"}.getStr
    of "message_start":
      let u = j{"message", "usage"}
      if u != nil:
        aiReqIn = u{"input_tokens"}.getInt
        aiReqCacheRead = u{"cache_read_input_tokens"}.getInt
        aiReqCacheWrite = u{"cache_creation_input_tokens"}.getInt
        aiReqOut = u{"output_tokens"}.getInt
    of "message_delta":
      if j{"delta", "stop_reason"}.getStr.len > 0: aiFinish = j{"delta", "stop_reason"}.getStr
      let u = j{"usage"}
      if u != nil and u{"output_tokens"} != nil: aiReqOut = u{"output_tokens"}.getInt
    of "content_block_start":
      let cb = j{"content_block"}
      let idx = j{"index"}.getInt
      if cb{"type"}.getStr == "tool_use":
        aiMsgs[mi].calls.add AiCall(id: cb{"id"}.getStr, name: cb{"name"}.getStr)
        aiBlocks[idx] = aiMsgs[mi].calls.high
        aiPhase = "calling " & cb{"name"}.getStr
      else: aiBlocks[idx] = -1
    of "content_block_delta":
      let d = j{"delta"}
      let idx = j{"index"}.getInt
      case d{"type"}.getStr
      of "text_delta":
        aiSplit.feed(d{"text"}.getStr, aiMsgs[mi].think, aiMsgs[mi].text)
        aiPhase = "writing…"
      of "thinking_delta":
        aiMsgs[mi].think.add d{"thinking"}.getStr
        aiPhase = aiThinkPhase(aiMsgs[mi].think)
      of "input_json_delta":
        let ci = aiBlocks.getOrDefault(idx, -1)
        if ci >= 0:
          aiMsgs[mi].calls[ci].args.add d{"partial_json"}.getStr
          aiPhase = aiCallPhase(aiMsgs[mi].calls[ci])
      else: discard
    of "error":
      aiRaw.add j{"error", "message"}.getStr & "\n"
      aiHttp = "500"
    else: discard
  else:
    let u = j{"usage"}
    if u != nil and u.kind == JObject:
      aiReqIn = u{"prompt_tokens"}.getInt
      aiReqOut = u{"completion_tokens"}.getInt
      aiReqCacheRead = u{"prompt_tokens_details", "cached_tokens"}.getInt
    let ch = j{"choices"}
    if ch == nil or ch.kind != JArray or ch.len == 0:
      if jHasErr(j):
        aiRaw.add j{"error", "message"}.getStr & "\n"
        aiHttp = "500"
      return
    if ch[0]{"finish_reason"} != nil and ch[0]["finish_reason"].kind == JString:
      aiFinish = ch[0]["finish_reason"].getStr
    let d = ch[0]{"delta"}
    if d == nil: return
    # a thinking model's thoughts: llama.cpp, LM Studio, DeepSeek send reasoning_content; Ollama, OpenRouter, vLLM,
    # Groq reasoning (some send both, the same text: one is taken)
    let r = aiDeltaThought(d)
    if r.len > 0:
      aiMsgs[mi].think.add r
      aiPhase = aiThinkPhase(aiMsgs[mi].think)
    var t = d{"content"}.getStr
    if d{"content"} != nil and d["content"].kind == JArray:
      aiContentParts(d["content"], aiMsgs[mi].think, t)
      if t.len == 0: aiPhase = aiThinkPhase(aiMsgs[mi].think)
    if t.len > 0:
      aiSplit.feed(t, aiMsgs[mi].think, aiMsgs[mi].text)
      aiPhase = if aiMsgs[mi].text.len > 0: "writing…" else: aiThinkPhase(aiMsgs[mi].think)
    let tc = d{"tool_calls"}
    if tc != nil and tc.kind == JArray:
      for c in tc:
        let idx = c{"index"}.getInt(aiMsgs[mi].calls.len)
        while aiMsgs[mi].calls.len <= idx:
          aiMsgs[mi].calls.add AiCall(id: "call_" & $aiMsgs[mi].calls.len)
        if c{"id"}.getStr.len > 0: aiMsgs[mi].calls[idx].id = c{"id"}.getStr
        let f = c{"function"}
        if f != nil:
          if f{"name"}.getStr.len > 0: aiMsgs[mi].calls[idx].name = f{"name"}.getStr
          aiMsgs[mi].calls[idx].args.add f{"arguments"}.getStr
          aiPhase = aiCallPhase(aiMsgs[mi].calls[idx])
  inc aiVersion
  needRender = true

proc slashCommand(t: string): (bool, string)
proc isSlashCommand(t: string): bool

var
  mcpResCache: Table[string, string]   # "server\0uri" → the resource's text, read for the message being sent
  mcpResWaiting = 0

proc mcpMentionOf(w: string): (McpServer, string) =
  ## "@server:uri" → (that server, the uri)
  if w.len < 4 or w[0] != '@': return (nil, "")
  let c = w.find(':')
  if c < 2: return (nil, "")
  let name = w[1 ..< c]
  for s in mcpServers:
    if not s.dead and s.name.toLowerAscii == name.toLowerAscii and (s.hasResources or s.resources.len > 0):
      return (s, w[c + 1 .. ^1])
  (nil, "")

proc aiSend(text: string, withContext = true, shownAs = "")
proc aiMentionedPics(t: string, quiet = false): seq[string]

proc mcpFetchMentions(t: string, withContext: bool, shownAs: string): bool =
  ## @server:uri mentions: read them first (the message goes once they are in); true while waiting
  var want: seq[(McpServer, string)]
  for w0 in t.splitWhitespace:
    let w = w0.strip(leading = false, chars = {',', ';', '?', '!', ')'})
    let (srv, uri) = mcpMentionOf(w)
    if srv != nil and (srv.name & "\0" & uri) notin mcpResCache: want.add (srv, uri)
  if want.len == 0: return false
  mcpResWaiting = want.len
  aiPhase = "reading " & $want.len & " MCP resource(s)"
  needRender = true
  for (srv, uri) in want:
    let key = srv.name & "\0" & uri
    let server = srv
    let u = uri
    capture key:
      server.mcpRequest("resources/read", %*{"uri": u}, proc(res: JsonNode, err: string) =
        mcpResCache[key] = (if err.len > 0: "(could not read it: " & err & ")" else: mcpResourceText(res))
        dec mcpResWaiting
        if mcpResWaiting == 0:
          aiPhase = ""
          aiSend(t, withContext, shownAs))
  true

proc aiSend(text: string, withContext = true, shownAs = "") =
  ## sends the user's message: refuses while the assistant is busy, runs a /command (which may give a prompt of its
  ## own), waits for the MCP resources it mentions, then adds the message — with the @mentions' contents and, with
  ## `withContext`, the current file in front — to the chat, remembers it in the prompt history (100 kept) and starts
  ## the request; `shownAs` is what the chat shows in its place
  var t = text.strip
  if t.len == 0: return
  if aiBusy:
    info("The assistant is still busy — Esc stops it")
    return
  if mcpResWaiting > 0:
    info("Still reading the MCP resources of the last message…")
    return
  if t.len > 1 and t[0] == '/' and isSlashCommand(t):
    let (handled, prompt) = slashCommand(t)
    if handled and prompt.len == 0:
      showSide(svAssistant)
      return
    if handled: t = prompt
  if mcpFetchMentions(t, withContext, shownAs): return
  var full = expandMentions(t)
  mcpResCache.clear()
  if withContext and cfgAiIncludeFile:
    let ctx = fileContext()
    if ctx.len > 0: full = ctx & "\n\n" & full        # (the @mentions' attachments too, not only the text)
  aiMsgs.add AiMsg(role: 0, text: full, shown: (if shownAs.len > 0: shownAs else: t), pics: aiMentionedPics(t))
  aiRunCp = -1
  aiWarnOk = false
  aiSteps = 0
  aiRetries = 0
  aiScrollOff = 0
  let i = aiPromptHist.find(t)
  if i >= 0: aiPromptHist.delete(i)
  aiPromptHist.add t
  if aiPromptHist.len > 100: aiPromptHist.delete(0)
  aiRequest()

proc aiStop() =
  ## stops the assistant: kills the request and any command it is running, drops the checks of its edits still running,
  ## adds "Stopped." and answers its open tool calls with "Cancelled by the user." so that the next request is valid
  aiPlanInterrupted()
  mcpWaitReq = false
  inc aiCheckGen
  if aiJob != nil:
    killProc(aiJob.pr)
    aiJob = nil
  if aiCmdJob != nil:
    killProc(aiCmdJob.pr)
    aiCmdJob = nil
  aiCleanup()
  if aiBusy:
    aiMsgs.add AiMsg(role: 3, text: "Stopped.")
  # unanswered tool calls would break the next request: answer them
  if aiMsgs.len > 0 and aiMsgs[^1].role == 1 and aiMsgs[^1].calls.len > 0:
    var r = AiMsg(role: 2, calls: aiMsgs[^1].calls)
    for c in r.calls.mitems:
      if c.state != 2:
        c.result = "Cancelled by the user."
        c.isError = true
        c.state = 2
    aiMsgs.add r
  elif aiMsgs.len > 0 and aiMsgs[^1].role == 3 and aiMsgs.len >= 2 and aiMsgs[^2].role == 1 and aiMsgs[^2].calls.len > 0:
    var r = AiMsg(role: 2, calls: aiMsgs[^2].calls)
    for c in r.calls.mitems:
      if c.state != 2:
        c.result = "Cancelled by the user."
        c.isError = true
        c.state = 2
    aiMsgs.insert(r, aiMsgs.high)
  aiBusy = false
  aiInlineMode = false
  aiOneShotCb = nil
  aiPhase = ""
  inc aiVersion

proc aiNewChat() =
  ## starts a new chat: stops the assistant, saves the old chat, and clears the messages, the always-allowed tools and
  ## the token counts
  aiStop()
  saveChat()
  aiMsgs.setLen(0)
  aiAlwaysAllow.clear()
  aiScrollOff = 0
  aiChatId = ""
  aiUsageIn = 0
  aiUsageOut = 0
  aiUsageCacheRead = 0
  aiUsageCacheWrite = 0
  inc aiVersion
  showSide(svAssistant)
