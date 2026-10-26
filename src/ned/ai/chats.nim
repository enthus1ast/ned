# ── ned 4: saved chats, change diffs, slash commands, @mentions, usage, one-shot requests ──

proc chatsDir(): string = stateDir() / "chats"

proc callJson(c: AiCall): JsonNode =
  %*{"id": c.id, "name": c.name, "args": c.args, "state": c.state,
     "result": (if c.result.len > 20000: c.result[0 ..< 20000] & "\n…" else: c.result),
     "isError": c.isError, "diff": c.diff, "check": c.check, "checkOut": c.checkOut}

proc callFrom(j: JsonNode): AiCall =
  AiCall(id: j{"id"}.getStr, name: j{"name"}.getStr, args: j{"args"}.getStr, state: j{"state"}.getInt(2),
         result: j{"result"}.getStr, isError: j{"isError"}.getBool, diff: j{"diff"}.getStr,
         check: j{"check"}.getStr, checkOut: j{"checkOut"}.getStr)

proc chatTitle(): string =
  for m in aiMsgs:
    if m.role == 0:
      let t = (if m.shown.len > 0: m.shown else: m.text).strip.splitLines()
      if t.len > 0: return truncTo(t[0], 70)
  "chat"

proc saveChat() =
  ## every conversation is kept (AI › Chat history); tool output is trimmed
  if aiMsgs.len == 0: return
  var hasUser = false
  for m in aiMsgs:
    if m.role == 0: hasUser = true
  if not hasUser: return
  if aiChatId.len == 0: aiChatId = $(epochTime() * 1000).int64
  var msgs = newJArray()
  for m in aiMsgs:
    let calls = newJArray()
    for c in m.calls: calls.add callJson(c)
    msgs.add %*{"role": m.role, "text": m.text, "shown": m.shown, "calls": calls, "pics": m.pics}
  let j = %*{"id": aiChatId, "title": chatTitle(), "root": rootDir, "provider": cfgAiProvider, "model": aiModel(),
             "updated": (epochTime() * 1000).int64, "usage": {"in": aiUsageIn, "out": aiUsageOut,
             "cacheRead": aiUsageCacheRead}, "msgs": msgs}
  try:
    privateDir(chatsDir())
    writeFileSafe(chatsDir() / aiChatId & ".json", $j, 0o600)
    # keep the newest 200
    var all: seq[(times.Time, string)]
    for kind, p in walkDir(chatsDir()):
      if kind == pcFile and p.endsWith(".json"): all.add (getLastModificationTime(p), p)
    if all.len > 200:
      all.sort(proc(x, y: (times.Time, string)): int = cmp(x[0], y[0]))
      for i in 0 ..< all.len - 200: removeFile(all[i][1])
  except CatchableError: discard

proc loadChat(path: string) =
  try:
    let j = parseFile(path)
    aiStop()
    aiMsgs.setLen(0)
    for m in jitems(j{"msgs"}):
      var am = AiMsg(role: m{"role"}.getInt, text: m{"text"}.getStr, shown: m{"shown"}.getStr)
      for p in jitems(m{"pics"}):
        if fileExists(p.getStr): am.pics.add p.getStr       # (a picture removed since: the chat goes on without it)
      for c in jitems(m{"calls"}): am.calls.add callFrom(c)
      aiMsgs.add am
    # a chat that was cut off mid-tool-call would make the next request invalid: close it
    if aiMsgs.len > 0 and aiMsgs[^1].role == 1 and aiMsgs[^1].calls.len > 0:
      var r = AiMsg(role: 2, calls: aiMsgs[^1].calls)
      for c in r.calls.mitems:
        if c.state != 2:
          c.result = "Cancelled."
          c.isError = true
          c.state = 2
      aiMsgs.add r
    aiChatId = j{"id"}.getStr
    aiUsageIn = j{"usage", "in"}.getInt
    aiUsageOut = j{"usage", "out"}.getInt
    aiUsageCacheRead = j{"usage", "cacheRead"}.getInt
    aiAlwaysAllow.clear()
    aiScrollOff = 0
    inc aiVersion
    showSide(svAssistant)
    info("Chat restored: " & j{"title"}.getStr)
  except CatchableError as e:
    error("Cannot open that chat: " & e.msg)

proc chatAct(p: string): Action = (proc() = loadChat(p))

proc cmdChatHistory() =
  if not dirExists(chatsDir()):
    info("No saved chats yet")
    return
  var rows: seq[(int64, string, string, string)]
  for kind, p in walkDir(chatsDir()):
    if kind != pcFile or not p.endsWith(".json"): continue
    try:
      let j = parseFile(p)
      rows.add (j{"updated"}.getBiggestInt.int64, p, j{"title"}.getStr, j{"root"}.getStr)
    except CatchableError: discard
  if rows.len == 0:
    info("No saved chats yet")
    return
  rows.sort(proc(x, y: (int64, string, string, string)): int = cmp(y[0], x[0]))
  var items: seq[(string, string, Action)]
  # this project's chats first
  for pass in 0 .. 1:
    for (t, p, title, root) in rows:
      if (root == rootDir) != (pass == 0): continue
      items.add act((if p.extractFilename == aiChatId & ".json": "● " else: "") & title,
                    agoText(t) & (if root != rootDir: " · " & extractFilename(root) else: ""), chatAct(p))
  items.add act("Delete all saved chats…", "", proc() =
    askConfirm("Delete every saved chat? (y)es (c)ancel", proc(c: char) =
      if c == 'y':
        try: removeDir(chatsDir())
        except CatchableError: discard
        info("Chat history deleted")))
  openActions("Chat history", items)
