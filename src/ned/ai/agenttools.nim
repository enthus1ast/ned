proc toolKind(name: string): int =
  ## 0 read-only, 1 edits files, 2 runs commands (an MCP server's tool counts as a command; a plugin's too, unless
  ## it said it only reads)
  if name.startsWith("mcp__"): return 2
  if name.startsWith("plugin__"):
    for t in plugAiTools:
      if t.name == name: return (if t.readOnly: 0 else: 2)
    return 2
  case name
  of "edit_file", "write_file": 1
  of "run_command": 2
  else: 0

proc outsideProject(c: AiCall): bool =
  ## a path argument that leaves the project folder (~/.ssh, /etc …)
  try:
    let j = parseJson(if c.args.strip.len == 0: "{}" else: c.args)
    for k in ["path", "cwd"]:
      let v = j{k}.getStr
      if v.len > 0:
        let q = expandTilde(v.strip)
        let p = if q.isAbsolute: q.normalizedPath else: (rootDir / q).normalizedPath
        if p != rootDir and not p.startsWith(rootDir & "/"): return true
  except CatchableError: discard
  false

proc needsApproval(c: AiCall): bool =
  if aiPlanState == apPlanning and toolKind(c.name) != 0: return false   # (refused at once: see runCall)
  if outsideProject(c): return true            # never silently, whatever ai.autoApprove says
  if c.name in aiAlwaysAllow: return false
  case toolKind(c.name)
  of 0: cfgAiApprove == "none"
  of 1: cfgAiApprove notin ["edits", "all"]
  else: cfgAiApprove != "all"

proc absProjectPath(p: string): string =
  let q = expandTilde(p.strip)
  if q.isAbsolute: q.normalizedPath else: (rootDir / q).normalizedPath

proc bufferFor(path: string): Buffer =
  ## open buffer for a path without stealing focus (agent edits)
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i]
  let b = newBuffer()
  if not b.loadFile(path): return nil
  bufs.add b
  lspAttach(b)
  b

func posAt(text: string, off: int): Pos =
  var line = 0
  var ls = 0
  for i in 0 ..< min(off, text.len):
    if text[i] == '\n':
      inc line
      ls = i + 1
  Pos(line: line, col: off - ls)

# ── secrets kept from the AI (core/secrets.nim, ai.redactSecrets): keys, tokens and passwords in what is sent are
#    replaced with placeholders, put back where the model writes them into a file; files of secrets are not sent ──

var
  aiSecretTab: SecretTable                 # this session's placeholders: the same secret, the same placeholder
  aiSecretPats: (string, times.Time, seq[string])   # (the project, its .gitignore's time, the lines of it about secrets)

const AiSecretNote = "(not sent: this file holds secrets — ned keeps such files from the assistant, ai.redactSecrets)"

proc aiSecretFile(path: string): bool =
  ## a file that holds secrets — .env, *.pem, id_ed25519 …, or one the project's .gitignore keeps out for its
  ## secrets — is never sent to the AI while ai.redactSecrets is on
  if path.len == 0 or not sBool("ai.redactSecrets"): return false
  let gi = rootDir / ".gitignore"
  var t: times.Time
  try: t = getLastModificationTime(gi)
  except CatchableError: discard
  if aiSecretPats[0] != rootDir or aiSecretPats[1] != t:
    var pats: seq[string]
    try:
      if rootDir.len > 0 and fileExists(gi): pats = secretIgnorePatterns(readFile(gi))
    except CatchableError: discard
    aiSecretPats = (rootDir, t, pats)
  isSecretFile(path, aiSecretPats[2], rootDir)

proc aiRedactBody(body: JsonNode) =
  ## a request about to be sent: the secrets in every string of it replaced (ai.redactSecrets)
  if sBool("ai.redactSecrets"): discard redactSecretsJson(body, aiSecretTab)

proc toolReadFile(j: JsonNode): (string, bool) =
  let path = absProjectPath(j{"path"}.getStr)
  if aiSecretFile(path): return (AiSecretNote, true)
  var lines: seq[string]
  let bi = bufIndexByPath(path)
  if bi >= 0: lines = bufs[bi].lines
  elif fileExists(path):
    try:
      if getFileSize(path) > 4_000_000: return ("file is too large (" & $getFileSize(path) & " bytes)", true)
      lines = readFile(path).splitLines
    except CatchableError as e: return (e.msg, true)
  else: return ("no such file: " & relPath(path), true)
  let a = max(1, j{"start_line"}.getInt(1))
  let e = min(lines.len, j{"end_line"}.getInt(min(lines.len, a + 799)))
  var o = ""
  for i in a .. e:
    o.add align($i, 5) & "  " & lines[i - 1] & "\n"
  if e < lines.len: o.add "… (" & $(lines.len - e) & " more lines; use start_line/end_line)\n"
  if o.len == 0: o = "(empty file)"
  (o, false)

proc toolListFiles(j: JsonNode): (string, bool) =
  let f = j{"filter"}.getStr.toLowerAscii
  var o: seq[string]
  for p in projectFiles():
    if f.len == 0 or f in p.toLowerAscii:
      o.add p
      if o.len >= 400: break
  ((if o.len == 0: "no files match" else: o.join("\n") & (if o.len >= 400: "\n… (more; refine the filter)" else: "")), false)

proc toolSearch(j: JsonNode): (string, bool) =
  let q = j{"query"}.getStr
  if q.len == 0: return ("empty query", true)
  let sub = j{"path"}.getStr
  let caseS = q != q.toLowerAscii
  var o: seq[string]
  let t0 = getMonoTime()
  for rel in projectFiles():
    if sub.len > 0 and not rel.startsWith(sub.strip(chars = {'/', '.'})): continue
    let path = rootDir / rel
    if aiSecretFile(path): continue
    try:
      if getFileSize(path) > 2_000_000: continue
      var l = 0
      let bi = bufIndexByPath(path)
      let lines = if bi >= 0: bufs[bi].lines else: readFile(path).splitLines
      for s in lines:
        inc l
        if findInLine(s, q, 0, caseS, false) >= 0:
          o.add rel & ":" & $l & ": " & s.strip[0 ..< min(200, s.strip.len)]
          if o.len >= 150: break
    except CatchableError: discard
    if o.len >= 150 or msSince(t0) > 3000: break
  ((if o.len == 0: "no matches" else: o.join("\n")), false)

type AiCheckpoint = object
  id: int                                        # stays the same while older checkpoints come and go
  at, prompt: string
  files: OrderedTable[string, (bool, string)]    # path → (it existed, its text before the assistant's run)

var
  aiCheckpoints: seq[AiCheckpoint]
  aiRunCp = -1               # this run's checkpoint (-1: the run has changed nothing yet)
  aiCpNextId = 1

proc aiReviewCheckpoint(id: int)

proc aiCpIndex(id: int): int =
  for i, cp in aiCheckpoints:
    if cp.id == id: return i
  -1

proc aiRemember(path: string) =
  ## before the assistant's first change to a file in this run: keep what it was, for AI: undo
  if aiRunCp < 0 or aiRunCp > aiCheckpoints.high:
    var prompt = ""
    for m in aiMsgs:
      if m.role == 0 and m.shown.len > 0: prompt = m.shown
    aiCheckpoints.add AiCheckpoint(id: aiCpNextId, at: times.now().format("HH:mm"), prompt: prompt)
    inc aiCpNextId
    if aiCheckpoints.len > 20: aiCheckpoints.delete(0)
    aiRunCp = aiCheckpoints.high
  if path in aiCheckpoints[aiRunCp].files: return
  let bi = bufIndexByPath(path)
  if bi >= 0: aiCheckpoints[aiRunCp].files[path] = (true, bufs[bi].allText)
  elif fileExists(path):
    try: aiCheckpoints[aiRunCp].files[path] = (true, readFile(path))
    except CatchableError: discard
  else: aiCheckpoints[aiRunCp].files[path] = (false, "")

proc aiUndoCheckpoint(id: int) =
  let ci = aiCpIndex(id)
  if ci < 0:
    info("Those changes were already undone")
    return
  let cp = aiCheckpoints[ci]
  var n = 0
  for path, (existed, text) in cp.files:
    let bi = bufIndexByPath(path)
    try:
      if not existed:
        if bi >= 0:
          bufs[bi].savedSeq = bufs[bi].topSeq()      # nothing to ask about: it was the assistant's file
          closeBufferAt(bi)
        if fileExists(path):
          removeFile(path)
          remoteFileOp("rm", path)                    # a remote folder: gone on the server too
      elif bi >= 0:
        let b = bufs[bi]
        b.setTextMinimal(text)
        discard b.saveBuffer(force = true)
      else: writeFileSafe(path, text)
      inc n
    except CatchableError as e: error("Could not restore " & relPath(path) & ": " & e.msg)
  aiCheckpoints.delete(ci)
  if aiRunCp == ci: aiRunCp = -1
  elif aiRunCp > ci: dec aiRunCp
  refreshTree()
  info("Undid the assistant's changes to " & $n & " file(s)")
  needRender = true

proc cmdAiUndo() =
  ## the assistant's runs that changed files, newest first: undo one
  if aiCheckpoints.len == 0:
    info("The assistant has not changed any files in this session")
    return
  var items: seq[(string, string, Action)]
  for i in countdown(aiCheckpoints.high, 0):
    let cp = aiCheckpoints[i]
    let id = cp.id
    let n = cp.files.len
    var names: seq[string]
    for p in cp.files.keys: names.add extractFilename(p)
    capture id, n:
      items.add act(cp.at & "  " & truncTo(cp.prompt.replace('\n', ' '), 50),
                    $n & " file(s): " & names.join(", "), proc() =
        askConfirm("Put back " & $n & " file(s) as they were before this run? (y/n)",
          proc(c: char) =
            if c in {'y', 'Y'}: aiUndoCheckpoint(id)))
  openActions("Undo the assistant's changes", items)

proc toolEditFile(j: JsonNode): (string, bool) =
  let path = absProjectPath(j{"path"}.getStr)
  aiRemember(path)
  let oldT = j{"old_text"}.getStr
  let newT = j{"new_text"}.getStr
  if not fileExists(path) and bufIndexByPath(path) < 0:
    if oldT.len == 0:
      try:
        createDir(parentDir(path))
        writeFile(path, newT)
        fileWritten(path)
        refreshTree()
        return ("created " & relPath(path), false)
      except CatchableError as e: return (e.msg, true)
    return ("no such file: " & relPath(path), true)
  let b = bufferFor(path)
  if b == nil: return ("cannot open " & relPath(path), true)
  let text = b.allText
  b.beginEdit()
  if oldT.len == 0:
    let endP = Pos(line: b.lines.high, col: b.lines[^1].len)
    discard b.replaceText(endP, endP, (if text.len > 0 and not text.endsWith("\n"): "\n" else: "") & newT)
  else:
    let i = text.find(oldT)
    if i < 0:
      b.endEdit()
      return ("old_text was not found in " & relPath(path) & " — read the file again and copy the exact text", true)
    if text.find(oldT, i + 1) >= 0:
      b.endEdit()
      return ("old_text appears more than once in " & relPath(path) & " — include more surrounding lines", true)
    discard b.replaceText(posAt(text, i), posAt(text, i + oldT.len), newT)
  b.endEdit()
  b.normalize()
  let saved = b.saveBuffer()
  let added = newT.count('\n') + 1
  let removed = (if oldT.len == 0: 0 else: oldT.count('\n') + 1)
  ("edited " & relPath(path) & " (+" & $added & " −" & $removed & " lines)" &
   (if saved: "" else: " in the editor, NOT saved: the file changed on disk or is open in another ned — the user decides"),
   false)

proc toolWriteFile(j: JsonNode): (string, bool) =
  let path = absProjectPath(j{"path"}.getStr)
  aiRemember(path)
  let content = j{"content"}.getStr
  let bi = bufIndexByPath(path)
  try:
    if bi >= 0:
      let b = bufs[bi]
      b.beginEdit()
      discard b.replaceText(Pos(), Pos(line: b.lines.high, col: b.lines[^1].len), content.strip(leading = false, chars = {'\n'}))
      b.endEdit()
      b.normalize()
      if not b.saveBuffer():
        return ("wrote " & relPath(path) & " in the editor, NOT saved: the file changed on disk or is open in " &
                "another ned — the user decides", false)
    else:
      createDir(parentDir(path))
      writeFile(path, content)
      fileWritten(path)
      refreshTree()
      if fileCacheValid and relPath(path) notin fileCache: fileCache.add relPath(path)
    ("wrote " & relPath(path) & " (" & $(content.count('\n') + 1) & " lines)", false)
  except CatchableError as e: (e.msg, true)

proc toolDiagnostics(j: JsonNode): (string, bool) =
  let p = j{"path"}.getStr
  var o: seq[string]
  var paths: seq[string]
  if p.len > 0: paths.add absProjectPath(p)
  else:
    for k in diagsLsp.keys: paths.add k
    for k in diagsBuild.keys:
      if k notin paths: paths.add k
  for path in paths:
    for d in diagsFor(path):
      o.add relPath(path) & ":" & $(d.line + 1) & ":" & $(d.col + 1) & ": " &
            ["", "error", "warning", "info", "hint"][clamp(d.sev, 0, 4)] & ": " & d.msg.splitLines()[0]
  ((if o.len == 0: "no problems reported (save the file to re-check)" else: o.join("\n")), false)

proc aiRequest()
proc aiContinue()
proc aiWriteTests()
proc aiOutputBudget(model: string): int
proc applyInlineEdit()
proc expandMentions(t: string): string
proc diffForCall(c: AiCall): string
proc projectInstructions(): string
proc saveChat()

func utf8Cut(s: string, at: int): int =
  ## a byte index near `at` that does not split a UTF-8 character
  result = clamp(at, 0, s.len)
  while result > 0 and result < s.len and (ord(s[result]) and 0xC0) == 0x80: dec result

proc aiLastUser(): int =
  for i in countdown(aiMsgs.high, 0):
    if aiMsgs[i].role == 0: return i
  -1

proc aiSentResult(mi: int, c: AiCall, lastUser: int): string =
  ## a tool's output as sent with a request: in full for the question being answered; a long one of an earlier
  ## question cut to its start and end (ai.trimOldResults — the conversation sent at every step grew by every
  ## file the assistant ever read)
  if not cfgAiTrimOld or mi > lastUser or c.result.len <= 2400: return c.result
  let a = utf8Cut(c.result, 1200)
  let b = utf8Cut(c.result, c.result.len - 600)
  c.result[0 ..< a] & "\n… (" & $(c.result.count('\n') + 1) & " lines of an earlier step left out — run the tool again " &
    "if you need them) …\n" & c.result[b .. ^1]

proc finishCall(mi, ci: int, res: string, isErr: bool) =
  if mi >= aiMsgs.len or ci >= aiMsgs[mi].calls.len: return
  var r = res
  if r.len > 30000: r = r[0 ..< utf8Cut(r, 15000)] & "\n… (output truncated) …\n" & r[utf8Cut(r, r.len - 14000) .. ^1]
  aiMsgs[mi].calls[ci].result = r
  aiMsgs[mi].calls[ci].isError = isErr
  aiMsgs[mi].calls[ci].state = 2
  inc aiVersion
  needRender = true

proc runCall(mi, ci: int) =
  let c = aiMsgs[mi].calls[ci]
  var j: JsonNode
  try: j = parseJson(if c.args.strip.len == 0: "{}" else: c.args)
  except CatchableError:
    finishCall(mi, ci, "invalid JSON arguments: " & c.args, true)
    return
  if aiPlanState == apPlanning and toolKind(c.name) != 0:
    finishCall(mi, ci, "Not now: this is the planning step — reply with the numbered plan. Files are changed and " &
               "commands run only after the user approves the plan.", true)
    return
  aiMsgs[mi].calls[ci].state = 1
  if c.name in ["edit_file", "write_file"]:
    aiMsgs[mi].calls[ci].diff = diffForCall(c)     # kept with the chat: what the edit changed
    if outsideProject(c):
      finishCall(mi, ci, "editing files outside the project folder is not allowed", true)
      return
  case c.name
  of "read_file": (let (r, e) = toolReadFile(j); finishCall(mi, ci, r, e))
  of "list_files": (let (r, e) = toolListFiles(j); finishCall(mi, ci, r, e))
  of "search": (let (r, e) = toolSearch(j); finishCall(mi, ci, r, e))
  of "edit_file": (let (r, e) = toolEditFile(j); finishCall(mi, ci, r, e))
  of "write_file": (let (r, e) = toolWriteFile(j); finishCall(mi, ci, r, e))
  of "get_diagnostics": (let (r, e) = toolDiagnostics(j); finishCall(mi, ci, r, e))
  of "run_command":
    let cmd = j{"command"}.getStr
    let cwd = if j{"cwd"}.getStr.len > 0: absProjectPath(j{"cwd"}.getStr) else: rootDir
    if cmd.strip.len == 0:
      finishCall(mi, ci, "empty command", true)
      return
    aiPhase = "running " & truncTo(cmd, 30)
    let m = mi
    let k = ci
    # a remote folder: on the server (once the saves are there); what it changes there comes back before the
    # assistant reads on
    let ri = if remotes.len > 0: remoteOf(cwd) else: -1
    let run = if ri >= 0: remoteWaitPushes() & remoteCommand(remotes[ri], cmd, cwd) & " 2>&1" else: cmd
    let where = if ri >= 0: " (on " & remotes[ri].host & ")" else: ""
    var inline = true
    proc start() =
      aiCmdJob = startJob(jkTool, run, cwd, proc(jb: Job) =
        aiCmdJob = nil
        let o = stripAnsi(jb.output)
        finishCall(m, k, "exit code " & $jb.code & where & "\n" & o, jb.code != 0)
        if ri >= 0 and ri < remotes.len: remoteSync(ri, proc() = aiContinue())
        else: aiContinue())
      if aiCmdJob == nil:
        finishCall(m, k, "could not start the command", true)
        if not inline: aiContinue()
    if ri >= 0: remoteConnect(remotes[ri], start)
    else: start()
    inline = false
  else:
    if c.name.startsWith("plugin__"):
      aiPhase = c.name[8 .. ^1].replace("__", ": ")
      let m = mi
      let k = ci
      var inline = true
      plugAiRun(c.name, j, proc(text: string, isError: bool) =
        finishCall(m, k, text, isError)
        if not inline: aiContinue())
      inline = false
      return
    let (srv, tool) = mcpFind(c.name)
    if srv == nil or srv.dead:
      finishCall(mi, ci, "unknown tool " & c.name & (if c.name.startsWith("mcp__"): " (its MCP server is not running)" else: ""), true)
      return
    aiPhase = srv.name & ": " & (if tool == McpReadRes: "read_resource" else: tool)
    let m = mi
    let k = ci
    if tool == McpReadRes:
      srv.mcpRequest("resources/read", %*{"uri": j{"uri"}.getStr}, proc(res: JsonNode, err: string) =
        if err.len > 0: finishCall(m, k, err, true)
        else: finishCall(m, k, mcpResourceText(res), false)
        aiContinue())
      return
    srv.mcpRequest("tools/call", %*{"name": tool, "arguments": j}, proc(res: JsonNode, err: string) =
      if err.len > 0: finishCall(m, k, err, true)
      else: finishCall(m, k, mcpResultText(res), res{"isError"}.getBool(false))
      aiContinue())

proc checkerName(cmd: string): string =
  ## "nim check", "py_compile" … for a checker command
  let w = cmd.splitWhitespace()
  if w.len == 0: return "check"
  if w[0].strip(chars = {'\'', '"'}).endsWith("nimony"): return "nimony check"
  case w[0]
  of "nim", "cargo", "node", "bash": (if w.len > 1: w[0] & " " & w[1] else: w[0])
  of "python3": "py_compile"
  of "cc", "c++": w[0] & " -fsyntax-only"
  else: w[0]

proc aiEditCheck(mi: int): bool =
  ## the files this step edited, checked (nim check, py_compile, node --check, cargo check …) before the results
  ## go back: what is wrong goes with them, so the model fixes its own mistakes. false: nothing to check
  aiMsgs[mi].checked = true
  var last: OrderedTable[string, int]           # edited file → its last edit in this step
  for ci, c in aiMsgs[mi].calls:
    if c.name notin ["edit_file", "write_file"] or c.state != 2 or c.isError or "NOT saved" in c.result: continue
    try:
      let p = absProjectPath(parseJson(c.args){"path"}.getStr)
      if fileExists(p): last[p] = ci
    except CatchableError: discard
  # one check per file (and, for Nim, the project's main module too: a changed proc can break its callers)
  var runs: seq[(string, string, string)]       # (command, cwd, what it checks)
  var labels: Table[string, string]             # edited file → the checker
  var seen: HashSet[string]
  for p in last.keys:
    var ln = ""
    try:
      let f = open(p)
      discard f.readLine(ln)
      f.close()
    except CatchableError: discard
    let lang = detectLang(p, ln)
    let (cmd, cwd) = checkCmdForPath(p, lang.id)
    if cmd.len == 0: continue
    labels[p] = checkerName(cmd)
    if cmd in seen: continue
    seen.incl cmd
    runs.add (cmd, cwd, p)
    if lang.id == "nim":
      let nf = findNimbleFile(parentDir(p))
      if nf.len > 0:
        let m = nimMainModule(parentDir(nf))
        if m.len > 0 and m != p:
          let (mc, mcwd) = checkCmdForPath(m, "nim")
          if mc.len > 0 and mc notin seen:
            seen.incl mc
            runs.add (mc, mcwd, m)
  if runs.len == 0: return false
  let gen = aiCheckGen
  let msgIdx = mi
  var left = runs.len
  var errs: OrderedTable[string, seq[string]]   # file → its errors ("line:col: message")
  var failed = ""                               # a checker that could not run
  aiPhase = "checking the edits"
  needRender = true
  proc finish() =
    if gen != aiCheckGen or msgIdx != aiMsgs.high or aiMsgs[msgIdx].role != 1: return
    var total = 0
    for p, es in errs: total += es.len
    # each edited file's last edit carries the verdict; errors elsewhere go with the last edit of all
    var lastCall = -1
    for p, ci in last: lastCall = max(lastCall, ci)
    for p, ci in last:
      if p notin labels: continue
      let mine = errs.getOrDefault(p)
      var other: seq[string]
      if ci == lastCall:
        for q, es in errs:
          if q notin last:
            for e in es: other.add relPath(q) & ":" & e
      template c: untyped = aiMsgs[msgIdx].calls[ci]
      if mine.len == 0 and other.len == 0:
        c.check = (if failed.len > 0: "" else: "ok")
        if failed.len == 0: c.result.add "\n\n[ned checked " & relPath(p) & " after this: no errors]"
        continue
      var lines: seq[string]
      for e in mine: lines.add relPath(p) & ":" & e
      for e in other: lines.add e
      let n = lines.len
      if lines.len > 25: lines = lines[0 ..< 25] & @["… and " & $(n - 25) & " more"]
      c.check = $n & " error" & (if n == 1: "" else: "s")
      c.checkOut = lines.join("\n")
      c.result.add "\n\n[ned checked " & relPath(p) & " after this edit (" & labels.getOrDefault(p, "check") & "): " & c.check &
                   (if other.len > 0: " — some in other files, which your change may have caused" else: "") &
                   "]\n" & c.checkOut & "\nFix these errors, then check again with get_diagnostics or a build."
    aiPhase = ""
    if total > 0: info("The assistant's edit has " & $total & " error" & (if total == 1: "" else: "s") & " — it was told")
    aiContinue()
  for (cmd, cwd, what) in runs:
    let w = what
    discard w
    let jb = startJob(jkCheck, cmd, cwd, proc(j: Job) =
      var lastP = ""
      var extra = 0
      for raw in j.output.splitLines:
        let t = stripAnsi(raw)
        let (ok, p, l, c, sev, m) = parseErrLine(t, j.cwd)
        if ok:
          lastP = ""
          if sev == 1 and m.len > 0 and m != "Traceback":
            let e = $(l + 1) & ":" & $(c + 1) & ": " & m
            if e notin errs.mgetOrPut(p, @[]):
              errs[p].add e
              lastP = p
              extra = 0
          continue
        # (type mismatch: the details follow on the next lines)
        if lastP.len > 0 and extra < 8 and t.strip.len > 0 and not t.startsWith("Hint:") and not t.startsWith("CC:"):
          errs[lastP][^1].add "\n    " & t.strip
          inc extra
      dec left
      if left == 0: finish())
    if jb == nil:
      failed = cmd
      dec left
  if left == 0:
    finish()
    return true
  true

proc aiContinue() =
  ## run approved calls, wait for approvals, then send the results back
  if aiMsgs.len == 0: return
  let mi = aiMsgs.high
  if aiMsgs[mi].role != 1 or aiMsgs[mi].calls.len == 0:
    aiBusy = false
    aiPhase = ""
    return
  for ci in 0 ..< aiMsgs[mi].calls.len:
    let st = aiMsgs[mi].calls[ci].state
    if st == 0:
      if needsApproval(aiMsgs[mi].calls[ci]):
        aiPhase = "waiting for approval"
        aiBusy = true
        needRender = true
        if focus != fRight or rightView != svAssistant:
          toast("The assistant wants to " & (if aiMsgs[mi].calls[ci].name.startsWith("mcp__"): "use an MCP tool"
                                              elif aiMsgs[mi].calls[ci].name.startsWith("plugin__"): "use a plugin's tool"
                                              elif toolKind(aiMsgs[mi].calls[ci].name) == 2: "run a command" else: "edit files"),
                3, "Review", proc() = showSide(svAssistant))
        return
      runCall(mi, ci)
      if aiMsgs[mi].calls[ci].state == 1: return       # async command still running
    elif st == 1: return
  # every call answered → the edited files checked, then the results sent
  if cfgAiCheckEdits and not aiMsgs[mi].checked and aiEditCheck(mi): return
  var res = AiMsg(role: 2)
  res.calls = aiMsgs[mi].calls
  aiMsgs.add res
  inc aiSteps
  if aiSteps >= cfgAiMaxSteps:
    aiMsgs.add AiMsg(role: 3, text: "Stopped after " & $aiSteps & " tool steps (ai.maxSteps). Say \"continue\" to go on.")
    aiBusy = false
    aiPhase = ""
    return
  aiRequest()

proc approveCall(mi, ci: int, allow: bool, always = false) =
  if mi >= aiMsgs.len or ci >= aiMsgs[mi].calls.len: return
  if aiMsgs[mi].calls[ci].state != 0: return
  if allow:
    if always: aiAlwaysAllow.incl aiMsgs[mi].calls[ci].name
    runCall(mi, ci)
    if aiMsgs[mi].calls[ci].state == 1: return
  else:
    finishCall(mi, ci, "The user denied this action.", true)
  aiContinue()
