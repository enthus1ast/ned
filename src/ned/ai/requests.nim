# ── request building ──

proc aiSystemPrompt(): string =
  result = "You are the AI assistant inside ned, a fast terminal code editor (Nim first; also C, C++, Python, JS, Rust, " &
           "HTML) running in Termux on Android or on Linux. Project root: " & rootDir & ". "
  let b = buf()
  if b.path.len > 0: result.add "The user is editing " & relPath(b.path) & " (" & b.lang.name & "). "
  if nimble.name.len > 0: result.add "Nimble package: " & nimble.name & ". "
  result.add "Be concise and practical. Use Markdown; put code in fenced blocks with a language tag. "
  if cfgAiAgent:
    result.add "You can use tools to read, search and edit project files and to run shell commands " &
               "(nim c -r, nimble test, git …). Read files before editing them; make small exact edits with edit_file; " &
               "verify with a build or test command when useful. Paths are relative to the project root. "
  if nim3On() or (b.path.len > 0 and b.path in nim3Asked):
    # (Nim 3 is not the Nim the models learned: Nimony's own guides go with every request)
    result.add "This project is Nim 3 (Nimony), NOT Nim 2: write Nim 3 code — the rules below are Nimony's own guides. " &
               "Code is checked with `nimony check`." & nimonyGuide()
  else:
    result.add "For Nim, prefer idiomatic Nim 2 (ARC/ORC, std/ modules, nimble)."
  if cfgAiSystem.len > 0: result.add "\n" & cfgAiSystem
  result.add projectInstructions()

proc nimDefinitionsFor(b: Buffer, l0, l1: int, budget = 6000): string =
  ## Nim: the declarations the code in lines l0..l1 uses but does not contain — signatures, doc comments
  ## and small type bodies, found by the built-in engine — so the model knows what the names are
  if not cfgAiNimContext or b.lang.mode != lmNim or b.path.len == 0: return ""
  var f: NxFile
  try: f = nxFileFor(b)
  except CatchableError: return ""
  if f == nil: return ""
  var seen: HashSet[string]
  var defs: seq[(string, int)]
  var total = 0
  let t0 = getMonoTime()                    # a whole big file is sent: look up at most ~250 ms worth of names
  var lookups = 0
  for l in max(0, l0) .. min(b.lines.high, l1):
    if defs.len >= 20 or lookups >= 600 or (getMonoTime() - t0).inMilliseconds > 250: break
    let s = b.lines[l]
    var i = 0
    while i < s.len and defs.len < 20:
      if s[i] == '#': break
      if s[i] == '"':                       # skip strings
        inc i
        while i < s.len and s[i] != '"': inc i
        inc i
        continue
      if s[i] in IdentStartChars:
        var e = i
        while e < s.len and s[e] in IdentChars: inc e
        let w = s[i ..< e]
        if w.len > 1 and w notin seen and w notin b.lang.keywords:
          seen.incl w
          inc lookups
          var found: seq[(string, int, int, string)]
          try: found = nxDefinition(f, b.lines, l, i)
          except Exception: discard
          for (path, dl, _, _) in found:
            let p = if path.len == 0 or path == f.path: b.path else: path
            if p == b.path and dl >= l0 and dl <= l1: continue      # declared in the code itself
            if (p, dl) notin defs: defs.add (p, dl)
            break
        i = e
      else: inc i
  if defs.len == 0: return ""
  result = "<definitions note=\"declarations the code above uses, from the project and the standard library\">\n"
  for (p, dl) in defs:
    let ls = if p == b.path: b.lines else: fileLinesNow(p)
    if dl < 0 or dl > ls.high: continue
    let ind = leadingWs(ls[dl]).len
    var snip = ls[dl] & "\n"
    for k in dl + 1 .. min(ls.high, dl + 12):
      let s = ls[k]
      if s.strip.len == 0: break
      if leadingWs(s).len <= ind and not s.strip.startsWith("##"): break
      snip.add s & "\n"
    if total + snip.len > budget: break
    total += snip.len
    result.add "# " & relPath(p) & ":" & $(dl + 1) & "\n" & snip
  result.add "</definitions>"

proc cDefinitionsFor(b: Buffer, l0, l1: int, budget = 6000): string =
  ## C: the declarations the code in lines l0..l1 uses from headers and other files (prototypes, structs, macros —
  ## with the comment that documents them), from ned's C engine
  if not cfgAiNimContext or b.lang == nil or b.lang.id notin ["c", "cpp"] or b.path.len == 0: return ""
  var f: CxFile
  try: f = cxFileOf(b)
  except CatchableError: return ""
  if f == nil: return ""
  var seen: HashSet[string]
  var parts: seq[string]
  var total = 0
  let t0 = getMonoTime()
  for l in max(0, l0) .. min(b.lines.high, l1):
    if parts.len >= 20 or (getMonoTime() - t0).inMilliseconds > 250: break
    let s = b.lines[l]
    var i = 0
    while i < s.len and parts.len < 20:
      if s[i] == '"':
        inc i
        while i < s.len and s[i] != '"': inc i
        inc i
        continue
      if s[i] == '/' and i + 1 < s.len and s[i + 1] == '/': break
      if s[i] in IdentStartChars:
        var e = i
        while e < s.len and s[e] in IdentChars: inc e
        let w = s[i ..< e]
        if w.len > 1 and w notin seen and w notin CxKeywords:
          seen.incl w
          var ts: seq[(CxFile, CxSym)]
          try: ts = cxTargets(f, l, i)
          except CatchableError: discard
          if ts.len > 0:
            let (g, sy) = ts[0]
            if not (g.path == f.path and sy.line >= l0 and sy.line <= l1) and sy.text.len > 0:
              var snip = (if sy.doc.len > 0: "/* " & sy.doc.strip & " */\n" else: "") & sy.text & "\n"
              if sy.isDef and sy.kind in {cxStruct} and sy.endLine > sy.line and g.lines.len > sy.endLine:
                snip = (if sy.doc.len > 0: "/* " & sy.doc.strip & " */\n" else: "")
                for k in sy.line .. min(sy.endLine, sy.line + 15): snip.add g.lines[k] & "\n"
              if total + snip.len <= budget:
                total += snip.len
                parts.add "// " & relPath(g.path) & ":" & $(sy.line + 1) & "\n" & snip
        i = e
      else: inc i
  if parts.len == 0: return ""
  "<definitions note=\"declarations the code above uses, from its headers\">\n" & parts.join("") & "</definitions>"

proc codeDefinitionsFor(b: Buffer, l0, l1: int, budget = 6000): string =
  ## what the code in lines l0..l1 uses but does not declare: Nim from the built-in engine, C from ned's C engine
  if b.lang != nil and b.lang.mode == lmNim: nimDefinitionsFor(b, l0, l1, budget)
  elif b.lang != nil and b.lang.id in ["c", "cpp"]: cDefinitionsFor(b, l0, l1, budget)
  else: ""

proc fileContext(): string =
  ## the current file or selection, sent along with the user's message
  let b = buf()
  if b.isWelcome() or b.lines.len == 0: return ""
  let name = if b.path.len > 0: relPath(b.path) else: b.name
  let (a, e) = b.primary.range
  if a != e:
    let t = b.getText(a, e)
    let defs = codeDefinitionsFor(b, a.line, e.line)
    return "<selection file=\"" & name & "\" lines=\"" & $(a.line + 1) & "-" & $(e.line + 1) & "\">\n" & t &
           "\n</selection>" & (if defs.len > 0: "\n" & defs else: "")
  let cl = b.primary.head.line
  let lo = max(0, if b.lines.len <= 600: 0 else: cl - 300)
  let hi = min(b.lines.high, lo + 599)
  var t = ""
  for i in lo .. hi: t.add b.lines[i] & "\n"
  let defs = codeDefinitionsFor(b, max(0, cl - 25), cl + 25)       # what the code around the cursor uses
  "<file path=\"" & name & "\" cursor_line=\"" & $(cl + 1) & "\"" &
    (if lo > 0 or hi < b.lines.high: " showing=\"" & $(lo + 1) & "-" & $(hi + 1) & " of " & $b.lines.len & "\"" else: "") &
    ">\n" & t & "</file>" & (if defs.len > 0: "\n" & defs else: "")

proc anthropicBody(): JsonNode =
  let msgs = newJArray()
  let lastUser = aiLastUser()
  for mi, m in aiMsgs:
    case m.role
    of 0: msgs.add %*{"role": "user", "content": aiUserContent(m, m.text, "anthropic")}
    of 1:
      var content = newJArray()
      if m.text.len > 0: content.add %*{"type": "text", "text": m.text}
      for c in m.calls:
        var input: JsonNode
        try: input = parseJson(if c.args.strip.len == 0: "{}" else: c.args)
        except CatchableError: input = newJObject()
        content.add %*{"type": "tool_use", "id": c.id, "name": c.name, "input": input}
      if content.len == 0: content.add %*{"type": "text", "text": "…"}
      msgs.add %*{"role": "assistant", "content": content}
    of 2:
      let content = newJArray()
      for c in m.calls:
        content.add %*{"type": "tool_result", "tool_use_id": c.id, "content": aiSentResult(mi, c, lastUser),
                       "is_error": c.isError}
      msgs.add %*{"role": "user", "content": content}
    else: discard
  let cache = sBool("ai.promptCaching")
  if cache and msgs.len > 0:
    # cache breakpoint on the newest message: the whole conversation so far is reused next turn
    let last = msgs[^1]
    if last["content"].kind == JString:
      last["content"] = %*[{"type": "text", "text": last["content"].getStr, "cache_control": {"type": "ephemeral"}}]
    elif last["content"].kind == JArray and last["content"].len > 0:
      last["content"][^1]["cache_control"] = %*{"type": "ephemeral"}
  result = %*{"model": aiModel(), "max_tokens": aiOutputBudget(aiModel()), "stream": true, "messages": msgs}
  if cache: result["system"] = %*[{"type": "text", "text": aiSystemPrompt(), "cache_control": {"type": "ephemeral"}}]
  else: result["system"] = %aiSystemPrompt()
  if cfgAiTemp >= 0: result["temperature"] = %(cfgAiTemp.float / 100.0)
  if cfgAiAgent and not aiInlineMode:
    var tools = newJArray()
    for (n, d, s) in AiTools:
      tools.add %*{"name": n, "description": d, "input_schema": parseJson(s)}
    for (n, d, sc) in mcpTools(): tools.add %*{"name": n, "description": d, "input_schema": sc}
    if cache: tools[^1]["cache_control"] = %*{"type": "ephemeral"}
    result["tools"] = tools
