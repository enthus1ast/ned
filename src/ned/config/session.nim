# ned's remembered state between runs (state.json): recent files, cursor positions, theme, each folder's open files,
# breakpoints and layout, bookmarks, AI prompt history — loaded at start, saved at exit — and the folder trust that lets
# ned run a folder's code.
proc loadState() =
  ## reads state.json into the tables the editor keeps (recent files, saved positions, command and completion use
  ## counts, saved layout and sessions, AI history, trusted folders, bookmarks, the Nim build mode); a missing or
  ## damaged file is ignored, so ned starts fresh
  try:
    let j = parseFile(stateFile())
    if j.kind != JObject: return                 # damaged state file: start fresh, never crash
    if j.hasKey("recent") and j["recent"].kind == JArray:
      for x in j["recent"]: recentFiles.add x.getStr
    if j.hasKey("pos") and j["pos"].kind == JObject:
      for k, v in j["pos"]:
        if v.kind == JArray and v.len >= 2: savedPos[k] = Pos(line: v[0].getInt, col: v[1].getInt)
    if j.hasKey("theme"): stateOverrides["theme"] = j["theme"]
    if j.hasKey("lastRun"): lastRunCmd = j["lastRun"].getStr
    if j.hasKey("uses") and j["uses"].kind == JObject:
      for k, v in j["uses"]: cmdUses[k] = v.getInt
    if j.hasKey("completions") and j["completions"].kind == JObject:
      for k, v in j["completions"]:
        compRecent[k] = v.getInt
        compRecentN = max(compRecentN, v.getInt)
    if j.hasKey("nim") and j["nim"].kind == JObject:
      let n = j["nim"]
      if n.hasKey("mode"): stateOverrides["nim.buildMode"] = n["mode"]
      if n.hasKey("backend"): stateOverrides["nim.backend"] = n["backend"]
      if n.hasKey("compiler"): stateOverrides["nim.compiler"] = n["compiler"]
      if n.hasKey("folded") and n["folded"].kind == JArray:
        for x in n["folded"]: nimFolded.incl x.getStr
    if j.hasKey("layout") and j["layout"].kind == JObject: savedLayout = j["layout"]
    if j.hasKey("sessions") and j["sessions"].kind == JObject: savedSessions = j["sessions"]
    if j.hasKey("aiHistory") and j["aiHistory"].kind == JArray:
      for x in j["aiHistory"]: aiPromptHist.add x.getStr
    if j.hasKey("trusted") and j["trusted"].kind == JArray:
      for x in j["trusted"]: trustedDirs.add x.getStr
    if j.hasKey("bookmarks") and j["bookmarks"].kind == JObject:
      for k, v in j["bookmarks"]:
        if v.kind != JArray: continue
        var ls: seq[int]
        for x in v: ls.add x.getInt
        if ls.len > 0: savedMarks[k] = ls
    if j.hasKey("aiQuirks") and j["aiQuirks"].kind == JArray:
      for x in j["aiQuirks"]:
        if x.kind == JString: aiQuirks.incl x.getStr
  except CatchableError: discard

proc rememberPos(b: Buffer) =
  ## remembers where the main cursor of a file is, to put it back when the file is opened again
  if b.path.len > 0:
    if savedPos.len > 2000:
      # (every file ever opened in a long session: only the recent ones' places are kept, as the session file does)
      var keep = initTable[string, Pos]()
      for r in recentFiles:
        if r in savedPos: keep[r] = savedPos[r]
      savedPos = keep
    savedPos[b.path] = b.cursors[b.prim].head

proc layoutState(): JsonNode

proc aiQuirksList(): JsonNode =
  ## what each model's endpoint refused, so a new session does not have to learn it again
  result = newJArray()
  for q in aiQuirks:
    if result.len < 300: result.add %q

proc saveState() =
  ## writes state.json: the undo history of clean files, the cursor positions (of recent files, at most 300), the recent
  ## files, the 300 most recent completions chosen, the last 50 AI prompts, bookmarks and trusted folders — and, when
  ## sessions are restored, this folder's open files, breakpoints, watches and tasks. A failure to write is ignored
  for b in bufs: writeUndo(b)            # (clean files only; unchanged ones are skipped)
  for b in bufs: rememberPos(b)
  var pos = newJObject()
  var n = 0
  for r in recentFiles:
    if r in savedPos and n < 300:
      pos[r] = %*[savedPos[r].line, savedPos[r].col]
      inc n
  for b in bufs:
    if b.path.len > 0 and not pos.hasKey(b.path) and b.path in savedPos:
      pos[b.path] = %*[savedPos[b.path].line, savedPos[b.path].col]
  var uses = newJObject()
  for k, v in cmdUses: uses[k] = %v
  # (the completions you chose: the 300 most recent)
  var comps = newJObject()
  var recent: seq[(int, string)]
  for k, v in compRecent: recent.add (v, k)
  recent.sort(proc(x, y: (int, string)): int = cmp(y[0], x[0]))
  for i, (v, k) in recent:
    if i >= 300: break
    comps[k] = %v
  var sessions = if savedSessions.isNil: newJObject() else: savedSessions
  let open = newJArray()
  for b in bufs:
    if b.path.len > 0 and b.title.len == 0: open.add %b.path
  if rootDir.len > 0 and cfgRestoreSession:
    var bps = newJObject()
    for f, ls in breakpoints:
      if ls.len > 0:
        let a = newJArray()
        for l in ls: a.add %l
        bps[f] = a
    var conds = newJObject()
    for k, c in bpCond: conds[k] = %c
    var logs = newJObject()
    for k, c in bpLog: logs[k] = %c
    sessions[rootDir] = %*{"files": open, "cur": (if curBuf in 0 .. bufs.high: bufs[curBuf].path else: ""),
                           "breakpoints": bps, "bpConditions": conds, "bpLogs": logs, "watches": dbgWatches, "watchpoints": dbgWpWanted,
                           "runConfig": activeRunConfig, "tasks": taskRecent, "lastTask": lastTask}
  var hist = newJArray()
  for h in aiPromptHist[max(0, aiPromptHist.len - 50) .. ^1]: hist.add %h
  for b in bufs:
    if b.path.len > 0:
      if b.marks.len > 0: savedMarks[b.path] = b.marks
      else: savedMarks.del b.path
  var foldedJ = newJArray()
  for f in nimFolded: foldedJ.add %f
  var marksJ = newJObject()
  for k, v in savedMarks:
    if v.len > 0 and marksJ.len < 300: marksJ[k] = %v
  let j = %*{"recent": recentFiles, "pos": pos, "theme": cfgThemeName, "lastRun": lastRunCmd,
             "uses": uses, "completions": comps, "layout": layoutState(), "sessions": sessions, "aiHistory": hist,
             "trusted": trustedDirs, "bookmarks": marksJ, "aiQuirks": aiQuirksList(),
             "nim": {"mode": cfgNimMode, "backend": cfgNimTarget, "compiler": cfgNimCompiler, "folded": foldedJ}}
  try:
    createDir(parentDir(stateFile()))
    writeFileSafe(stateFile(), $j)
  except CatchableError: discard

proc addRecent(path: string) =
  ## puts a file at the top of the recent files, once, keeping at most 60
  let i = recentFiles.find(path)
  if i >= 0: recentFiles.delete(i)
  recentFiles.insert(path, 0)
  if recentFiles.len > 60: recentFiles.setLen(60)

# ── folder trust (security.folderTrust): a folder's code runs once you trust it ──

proc dropToasts(prefix: string)

proc trustFolder(root: string) =
  ## trust a folder: its project settings may start programs, and ned may run its code — and the checks it held
  ## back run now
  let k = trustKey(root)
  if k notin trustedDirs: trustedDirs.add k
  trustAsked.excl k
  saveState()
  reloadSettings(true)
  for b in bufs:
    if b.path.len > 0 and codeTrusted(parentDir(b.path)): b.chkAt = 0       # (checked by the compiler, now)
  dropToasts("Not trusted yet: " & k)
  needRender = true
  info("Trusted " & k & " — ned may run its code now (the Nim compiler, nimble, nimsuggest, its tests)")

var trustToldAt: MonoTime

proc askTrust(dir: string, quiet = false) =
  ## ned held back running a folder's code: once a session per folder, say so with a Trust button (and then — for
  ## what you asked for, not quiet — a short message at most every few seconds)
  var root = trustKey(dir)
  if rootDir.len > 0:
    let r = trustKey(rootDir)
    if root == r or root.startsWith(r & "/"): root = r
  if root in trustAsked:
    if not quiet and msSince(trustToldAt) > 8000:
      trustToldAt = getMonoTime()
      info("Not run: " & root & " is not trusted — palette › Workspace: trust this folder")
    return
  trustAsked.incl root
  trustToldAt = getMonoTime()
  let r2 = root
  toast("Not trusted yet: " & root & " — ned reads and checks its code with its own engine, but runs none of " &
        "it: not the Nim compiler (config.nims and macros can run commands), nimble, nimsuggest or its tests",
        2, "Trust", proc() = trustFolder(r2), 30000)
  needRender = true
