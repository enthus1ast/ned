# ── inline AI suggestions (opt-in: ai.inlineCompletion) — grey text after the cursor, Tab accepts ──

var
  ghostDropped = ""        # the last suggestion's name that does not exist (it was not shown)
  ghostText = ""
  ghostBuf = -1
  ghostPos: Pos
  ghostChange = -1
  ghostJob: Job
  ghostAskedChange = -1
  ghostAskedBuf = -1

proc ghostVisible(b: Buffer): bool =
  ## whether the suggestion is still to be shown in this buffer: nothing has changed since it was made and the cursor is
  ## still where it was asked for (a single cursor, nothing selected)
  ghostText.len > 0 and b.id == ghostBuf and b.changeId == ghostChange and b.cursors.len == 1 and
    b.primary.head == ghostPos and not b.primary.hasSel

proc ghostClear() =
  ## forgets the suggestion shown
  ghostText = ""
  ghostBuf = -1

var ghostFallback = ""     # the default suggestion model is not offered: use the chat model instead

proc ghostModel(): string =
  ## the model that writes the suggestions: ai.inlineCompletionModel, else the chat model when the default was found not
  ## to be offered, else a fast one for Anthropic or OpenAI (suggestions must come in a moment), else the chat model
  let m = sStr("ai.inlineCompletionModel")
  if m.len > 0: return m
  if ghostFallback.len > 0: return ghostFallback
  case cfgAiProvider
  of "anthropic": "claude-haiku-4-5"
  of "openai": "gpt-4.1-mini"          # fast and not a reasoning model: suggestions must arrive in a moment
  else: aiModel()

proc ghostAccept(): bool =
  ## puts the suggestion in the file at the cursor, as one undo step, with the cursor after it; false when none is shown
  ## or the file cannot be edited
  let b = buf()
  if not ghostVisible(b) or not b.canEdit(): return false
  let t = ghostText
  ghostClear()
  b.beginEdit()
  let p = b.replaceText(b.primary.head, b.primary.head, t)
  b.endEdit()
  b.setSingle(p)
  true

var ghostWords: (int, int, HashSet[string])   # (buffer id, changeId, the names written in it)

proc ghostUnknownName(b: Buffer, at: Pos, t: string): string =
  ## a name the suggestion uses that does not exist here — Nim, checked by the built-in engine: not declared in
  ## scope, not one of the receiver's fields or procs (`s.toUpperFirst`), not declared by the suggestion itself and
  ## not already written in the file. "" when it uses only names that exist (or the engine cannot tell)
  if not sBool("ai.checkSuggestions") or b.lang == nil or b.lang.mode != lmNim or not nimEngineOn(b): return ""
  var f: NxFile
  try: f = nxFileFor(b)
  except CatchableError: return ""
  if f == nil: return ""
  # the names the file already has (a name the engine does not know but the file uses is fine)
  if ghostWords[0] != b.id or ghostWords[1] != b.changeId:
    var ws: HashSet[string]
    for i, l in b.lines:
      if i > 30_000: break
      var k = 0
      while k < l.len:
        if l[k] in IdentStartChars and (k == 0 or l[k - 1] notin IdentChars):
          var e = k
          while e < l.len and l[e] in IdentChars: inc e
          ws.incl nxNorm(l[k ..< e])
          k = e
        else: inc k
    ghostWords = (b.id, b.changeId, ws)
  # the suggestion's words: (name, start, after a dot)
  var words: seq[(string, int, bool)]
  var declared: HashSet[string]
  var i = 0
  var prevWord = ""
  var inFor = false
  while i < t.len:
    let c = t[i]
    if c == '#':
      while i < t.len and t[i] != '\n': inc i
      continue
    if c == '"':
      inc i
      while i < t.len and t[i] != '"' and t[i] != '\n':
        if t[i] == '\\': inc i
        inc i
      inc i
      continue
    if c == '\'' and i + 2 < t.len and (t[i + 2] == '\'' or t[i + 1] == '\\'):
      i += (if t[i + 1] == '\\': 4 else: 3)
      continue
    if c == '`':
      let e = t.find('`', i + 1)
      i = if e < 0: t.len else: e + 1
      continue
    if c in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
      var e = i
      while e < t.len and t[e] in IdentChars: inc e
      let w = t[i ..< e]
      var k = e
      while k < t.len and t[k] == ' ': inc k
      let nextC = if k < t.len: t[k] else: '\0'
      let next2 = if k + 1 < t.len: t[k + 1] else: '\0'
      let dotBefore = i > 0 and t[i - 1] == '.'
      if prevWord in ["let", "var", "const", "proc", "func", "iterator", "template", "macro", "method", "converter",
                      "type"] or inFor or (nextC == ':' and next2 != ':') or (nextC == '=' and next2 != '='):
        declared.incl nxNorm(w)
      if w == "for": inFor = true
      elif w == "in": inFor = false
      if w notin NxKeywords: words.add (w, i, dotBefore)
      prevWord = w
      i = e
      continue
    if c == '\n': inFor = false
    if c notin {' ', '*', ','}: prevWord = ""
    inc i
  let sc = nxScope(f)
  var localNames: HashSet[string]
  for s in nxLocals(f, b.lines, at.line, at.col): localNames.incl nxNorm(s.name)
  # the text with the suggestion in it (a member is looked up the way completion after its dot would)
  var newLines: seq[string]
  let tLines = t.split('\n')
  for (w, start, dot) in words:
    let n = nxNorm(w)
    if w.len <= 1 or n in declared or n in ghostWords[2] or w in ["it", "result", "_", "true", "false", "nil"]: continue
    if not dot:
      if nxLookup(sc, w).len == 0 and n notin localNames: return w
      continue
    # a member: the receiver's fields and procs, when its type is known
    if newLines.len == 0:
      newLines = b.lines[0 ..< at.line]
      let pre = b.lines[at.line][0 ..< at.col]
      let post = b.lines[at.line][at.col .. ^1]
      for k, tl in tLines:
        newLines.add (if k == 0: pre else: "") & tl & (if k == tLines.high: post else: "")
      if at.line + 1 <= b.lines.high: newLines.add b.lines[at.line + 1 .. ^1]
    # where this word stands in newLines
    var ln = at.line
    var col = at.col
    for q in 0 ..< start:
      if t[q] == '\n':
        inc ln
        col = 0
      else: inc col
    try:
      let comp = nxComplete(f, newLines, ln, col)
      if comp.member and comp.known:
        var ok = false
        for it in comp.items:
          if nxNorm(it.label) == n:
            ok = true
            break
        if not ok: return t[max(0, start - 1) ..< start + w.len]
    except CatchableError: discard
  ""

proc aiFastAsk(instr, user: string, maxTokens: int, onText: proc(t: string) {.closure.},
               onRetry: proc() {.closure.} = nil, model = "", timeoutS = 30,
               onFail: proc(why: string) {.closure.} = nil): Job =
  ## a short request to the quick model (the suggestions') — or to `model`: its reply's text goes to onText. A
  ## refusal it can learn from (a parameter, the endpoint) or a quick model that is gone (the chat model then)
  ## calls onRetry instead; any other failure onFail (when given), with what went wrong
  if not haveExe("curl"): return nil
  let key = aiKey()
  if key.len == 0 and cfgAiProvider notin ["ollama", "custom"]: return nil
  let base = aiProviderBase()
  if base.len == 0: return nil
  let anth = cfgAiProvider == "anthropic"
  let gm = if model.len > 0: model else: ghostModel()
  let reasoning = cfgAiProvider == "openai" and isReasoningModel(gm)
  let resp = cfgAiProvider == "openai" and ((gm & "|responses") in aiQuirks or sStr("ai.openaiApi") == "responses")
  var body: JsonNode
  if anth:
    body = %*{"model": gm, "max_tokens": maxTokens, "temperature": 0, "system": instr,
              "messages": [{"role": "user", "content": user}]}
  elif resp:
    body = %*{"model": gm, "max_output_tokens": (if reasoning: max(2000, maxTokens) else: maxTokens + 32),
              "store": false, "instructions": instr, "input": [{"role": "user", "content": user}]}
  else:
    body = %*{"model": gm, "stream": false,
              "messages": [{"role": (if reasoning: "developer" else: "system"), "content": instr},
                           {"role": "user", "content": user}]}
    let mct = (cfgAiProvider == "openai" and (gm & "|maxtokens") notin aiQuirks) or (gm & "|mct") in aiQuirks
    body[(if mct: "max_completion_tokens" else: "max_tokens")] = %(if reasoning: max(2000, maxTokens) else: maxTokens)
    if not reasoning and (gm & "|notemp") notin aiQuirks: body["temperature"] = %0
  aiRedactBody(body)
  var hdr = "Content-Type: application/json\n"
  if anth: hdr.add "x-api-key: " & key & "\nanthropic-version: 2023-06-01\n"
  elif key.len > 0: hdr.add "Authorization: Bearer " & key & "\n"
  let hf = privTmp("ai-h")
  let bf = privTmp("ai-b")
  try:
    writeFile(hf, hdr)
    setFilePermissions(hf, {fpUserRead, fpUserWrite})
    writeFile(bf, utf8Repaired($body))    # (UTF-8 only: strict servers refuse the request over one bad byte)
    setFilePermissions(bf, {fpUserRead, fpUserWrite})
  except CatchableError: return nil
  let url = if anth: base & "/v1/messages" elif resp: base & "/responses" else: base & "/chat/completions"
  let cmd = "curl -sS --max-time " & $timeoutS & " -X POST " & quoteShell(url) & " -H @" & quoteShell(hf) &
            " --data-binary @" & quoteShell(bf)
  startJob(jkTool, cmd, rootDir, proc(j: Job) =
    try:
      removeFile(hf)
      removeFile(bf)
    except CatchableError: discard
    if j.code != 0:
      if onFail != nil: onFail("the request failed: " & truncTo(j.output.strip.splitLines()[^1], 160))
      return
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
          if onRetry != nil: onRetry()
        elif learned and onRetry != nil: onRetry()   # ask again, adjusted; other errors wait for the next edit
        elif onFail != nil: onFail(truncTo(em, 200))
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
    except CatchableError:
      if onFail != nil: onFail("the answer was not JSON: " & truncTo(j.output.strip, 160))
      return
    if t.strip.startsWith("```"):
      var ls = t.strip.splitLines()
      if ls.len >= 2:
        ls = ls[1 .. ^1]
        if ls.len > 0 and ls[^1].strip.startsWith("```"): ls.setLen(ls.len - 1)
        t = ls.join("\n")
    onText(restoreSecrets(t, aiSecretTab)))       # (code to put in a file: a placeholder back to its secret)

proc ghostRequest(b: Buffer) =
  ## ask for a short continuation at the cursor (one request in flight; stale answers are dropped)
  if aiSecretFile(b.path): return                 # (a file of secrets is not sent: ai.redactSecrets)
  let p = b.primary.head
  if ghostJob != nil and not ghostJob.done: killProc(ghostJob.pr)
  ghostAskedChange = b.changeId
  ghostAskedBuf = b.id
  var pre = ""
  for l in max(0, p.line - 80) ..< p.line: pre.add b.lines[l] & "\n"
  pre.add b.lines[p.line][0 ..< p.col]
  var suf = b.lines[p.line][p.col .. ^1]
  for l in p.line + 1 .. min(b.lines.high, p.line + 25): suf.add "\n" & b.lines[l]
  # (on the empty line under a comment: the code the comment describes, a block of it — as Alt+Shift+C writes)
  let afterComment = p.line > 0 and b.aiIsComment(p.line - 1) and b.lines[p.line].strip.len == 0
  let instr = "You are a code completion engine. Continue the " & b.lang.name & " code at <CURSOR>. Reply with ONLY " &
              "the text to insert there — no explanation, no Markdown fences, nothing that is already after the " &
              "cursor. " & (if afterComment: "The comment just above says what code goes here: write it, the " &
                            "whole of it, at the cursor's indentation. " else: "At most a few lines; stop at the end " &
                            "of the statement or block. ") & "If nothing fits, reply with an empty message."
  let defs = codeDefinitionsFor(b, max(0, p.line - 12), p.line + 3, 1500)   # (the names that exist, as they are)
  let user = "File: " & (if b.path.len > 0: relPath(b.path) else: b.name) & "\n<code>\n" & pre & "<CURSOR>" & suf &
             "\n</code>" & (if defs.len > 0: "\n" & defs else: "")
  let id = b.id
  let ch = b.changeId
  let at = p
  let job = aiFastAsk(instr, user, (if afterComment: 400 else: 128), proc(t0: string) =
    let bb = bufById(id)
    if bb == nil or bb.changeId != ch or bb.primary.head != at: return
    var t = t0.strip(leading = false)
    if t.strip.len == 0: return
    # the model sometimes repeats what is already typed on the line
    let linePre = bb.lines[at.line][0 ..< at.col]
    let lp = linePre.strip(trailing = false)
    if lp.len > 0 and t.startsWith(lp) and t.len > lp.len: t = t[lp.len .. ^1]
    # a name that does not exist here: the suggestion is not shown (it would not compile)
    var bad = ""
    try: bad = ghostUnknownName(bb, at, t)
    except CatchableError: discard
    if bad.len > 0:
      ghostDropped = bad
      return
    ghostText = t
    ghostBuf = id
    ghostPos = at
    ghostChange = ch
    needRender = true, proc() = ghostAskedChange = -1)
  if job != nil: ghostJob = job

proc ghostTick() =
  ## main loop: after a typing pause, request a suggestion at the cursor
  if not sBool("ai.inlineCompletion") or focus != fEditor or compOpen or promptKind != pNone or
     pickKind != pickNone or aiInlineMode or batterySave: return    # (battery saver: none as you type)
  let b = buf()
  if b.readOnly or b.path.len == 0 or b.cursors.len != 1 or b.primary.hasSel or not b.dirty: return
  if b.changeId == ghostAskedChange and b.id == ghostAskedBuf: return
  if msSince(b.lspChangeAt) < max(250, sInt("ai.inlineCompletionDelay")): return
  let p = b.primary.head
  let rest = b.lines[p.line][p.col .. ^1].strip
  if rest.len > 0 and not rest.allCharsInSet({')', ']', '}', '"', '\'', ';', ',', ':'}): return
  if p.col == 0 and b.lines[p.line].len == 0 and p.line > 0 and b.lines[p.line - 1].strip.len == 0: return
  ghostRequest(b)
