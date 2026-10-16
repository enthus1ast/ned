# ── swap files: unsaved edits survive a crash, a killed Termux session or a dead battery ──
# One file per (path, ned process): <hash(path)>-<pid>.json. A session only ever writes or deletes its
# own files, so a crashed session's edits stay until you restore or discard them.

proc swapDir(): string = stateDir() / "swap"

var
  privTmpN = 0
  privDirCache = ""

var projectTemps: seq[string]       # helper files ned writes inside a project for a moment (effects, benchmarks)

proc cleanProjectTemps() =
  ## on the way out: nothing of ned's is left in your project, even if a job was still running
  for p in projectTemps:
    try:
      if fileExists(p): removeFile(p)
    except CatchableError: discard
  projectTemps.setLen(0)

proc privDir(): string =
  ## a folder only you can read, for temporary files (API keys for curl, unsaved code for nimsuggest,
  ## clipboard text, build output): <tmp>/ned-<uid>, mode 0700 and checked to be yours — else
  ## ~/.local/state/ned/tmp. Never a fixed name in the shared /tmp.
  if privDirCache.len > 0 and dirExists(privDirCache): return privDirCache
  proc mine(d: string): bool =
    try:
      createDir(d)
      setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec})
      var st: Stat
      if lstat(d.cstring, st) != 0: return false
      S_ISDIR(st.st_mode) and st.st_uid == getuid() and (st.st_mode.int and 0o077) == 0
    except CatchableError: false
  let a = tmpDir() / ("ned-" & $getuid())
  if mine(a): privDirCache = a
  else:
    privDirCache = stateDir() / "tmp"
    discard mine(privDirCache)
  privDirCache

proc privTmp(name: string): string =
  ## a fresh temp file name in privDir()
  inc privTmpN
  privDir() / (name & "-" & $getCurrentProcessId() & "-" & $privTmpN)

# ── persistent undo: a file's undo history is kept (state/undo) and comes back while the file is unchanged ──

var undoWritten: Table[int, int]        # buffer id → the undo step last written

proc undoFile(path: string): string = stateDir() / "undo" / fnv(path) & ".json"

proc writeUndo(b: Buffer) =
  if not cfgPersistentUndo or b.path.len == 0 or b.title.len > 0 or b.binary or b.dirty: return
  if b.lines.len > 200_000: return             # (huge files: hashing them on every save costs too much)
  if undoWritten.getOrDefault(b.id, -1) == b.topSeq() and b.undoStack.len > 0: return
  undoWritten[b.id] = b.topSeq()
  let f = undoFile(b.path)
  if b.undoStack.len == 0 and b.redoStack.len == 0:
    removeFile(f)
    return
  proc pos(p: Pos): JsonNode = %[p.line, p.col]
  proc curs(cs: seq[Cursor]): JsonNode =
    result = newJArray()
    for c in cs: result.add %[c.anchor.line, c.anchor.col, c.head.line, c.head.col]
  proc groups(gs: seq[UndoGroup]): JsonNode =
    result = newJArray()
    var size = 0
    for g in gs[max(0, gs.len - 300) .. ^1]:
      var ops = newJArray()
      for o in g.ops:
        ops.add %*[pos(o.a), o.oldText, o.newText]
        size += o.oldText.len + o.newText.len
      result.add %*{"o": ops, "b": curs(g.before), "a": curs(g.after), "k": g.kind, "s": g.seqId}
      if size > 4_000_000: break
  let j = %*{"path": b.path, "hash": fnv(b.lines.join("\n")), "undo": groups(b.undoStack), "redo": groups(b.redoStack)}
  try:
    createDir(parentDir(f))
    writeFile(f, $j)
  except IOError, OSError: discard

proc readUndo(b: Buffer) =
  if not cfgPersistentUndo or b.path.len == 0 or b.lines.len > 200_000: return
  let f = undoFile(b.path)
  if not fileExists(f): return
  var j: JsonNode
  try: j = parseFile(f)
  except CatchableError: return
  if j{"path"}.getStr != b.path or j{"hash"}.getStr != fnv(b.lines.join("\n")): return     # changed elsewhere
  proc posOf(n: JsonNode): Pos = Pos(line: n[0].getInt, col: n[1].getInt)
  proc cursOf(n: JsonNode): seq[Cursor] =
    for c in jitems(n):
      result.add Cursor(anchor: Pos(line: c[0].getInt, col: c[1].getInt), head: Pos(line: c[2].getInt, col: c[3].getInt), goalX: -1)
  proc groupsOf(n: JsonNode): seq[UndoGroup] =
    for g in jitems(n):
      var ug = UndoGroup(kind: g{"k"}.getInt, seqId: g{"s"}.getInt, before: cursOf(g{"b"}), after: cursOf(g{"a"}))
      for o in jitems(g{"o"}): ug.ops.add EditOp(a: posOf(o[0]), oldText: o[1].getStr, newText: o[2].getStr)
      result.add ug
  try:
    b.undoStack = groupsOf(j{"undo"})
    b.redoStack = groupsOf(j{"redo"})
  except CatchableError:
    b.undoStack.setLen(0)
    b.redoStack.setLen(0)
    return
  for g in b.undoStack: undoSeq = max(undoSeq, g.seqId)
  for g in b.redoStack: undoSeq = max(undoSeq, g.seqId)
  b.savedSeq = b.topSeq()
  undoWritten[b.id] = b.topSeq()

proc procStart(pid: int): string =
  ## start time of a process (/proc/<pid>/stat field 22): tells a live ned from a reused pid
  try:
    let st = readFile("/proc/" & $pid & "/stat")
    let r = st.rfind(')')
    if r < 0: return ""
    let f = st[r + 2 .. ^1].splitWhitespace()
    if f.len > 19: return f[19]
  except CatchableError: discard
  ""

var myStart = ""

proc swapKey(b: Buffer): string =
  if b.path.len > 0: fnv(b.path) else: "untitled" & $b.id

proc swapPath(b: Buffer): string =
  swapDir() / swapKey(b) & "-" & $getCurrentProcessId() & ".json"

proc removeSwap(b: Buffer) =
  ## deletes only this session's recovery file for `b`
  b.swapAt = b.changeId
  if not b.swapMine: return
  b.swapMine = false
  try:
    let p = swapPath(b)
    if fileExists(p): removeFile(p)
  except CatchableError: discard

proc writeSwap(b: Buffer, force = false) =
  if b.binary or b.title.len > 0 or b.readOnly: return
  if not b.dirty:
    removeSwap(b)
    return
  if b.lines.len > 300_000: return
  # big files: at most every 20 s (phones have slow flash); crashes and signals always write
  if not force and (b.lines.len > 20_000 or b.large) and b.swapMine and msSince(b.swapWrittenAt) < 20_000: return
  b.swapAt = b.changeId
  b.swapWrittenAt = getMonoTime()
  try:
    privateDir(swapDir())
    if myStart.len == 0: myStart = procStart(getCurrentProcessId())
    let j = %*{"path": b.path, "pid": getCurrentProcessId(), "start": myStart, "time": getTime().toUnix,
               "text": b.lines.join("\n"), "crlf": b.crlf}
    writeFileSafe(swapPath(b), $j, 0o600)
    b.swapMine = true
  except CatchableError: discard

proc swapOwnerAlive(j: JsonNode): bool =
  ## is the ned that wrote this recovery file still running? (never true for this session)
  let pid = j{"pid"}.getInt
  if pid <= 0 or pid == getCurrentProcessId(): return false
  if posix.kill(Pid(pid), 0) != 0: return false          # gone (EPERM: another user's process)
  let st = j{"start"}.getStr
  if st.len > 0:
    let now = procStart(pid)
    if now.len > 0 and now != st: return false           # the pid was reused after a reboot
  true

proc swapsLeftBehind(): seq[JsonNode] =
  ## recovery files of ned sessions that are no longer running (newest first)
  if not dirExists(swapDir()): return
  let mine = "-" & $getCurrentProcessId() & ".json"
  for kind, p in walkDir(swapDir()):
    if kind != pcFile or not p.endsWith(".json") or p.endsWith(mine): continue
    try:
      let j = parseFile(p)
      if j.kind != JObject or swapOwnerAlive(j): continue
      j["file"] = %p
      result.add j
    except CatchableError: discard
  result.sort(proc(x, y: JsonNode): int = cmp(y{"time"}.getInt, x{"time"}.getInt))

proc otherSessionEditing(path: string): int =
  ## pid of another running ned with unsaved edits to `path` (0 = none)
  if not dirExists(swapDir()): return 0
  let pre = fnv(path) & "-"
  for kind, p in walkDir(swapDir()):
    let n = extractFilename(p)
    if kind != pcFile or not n.startsWith(pre): continue
    try:
      let j = parseFile(p)
      if swapOwnerAlive(j): return j{"pid"}.getInt
    except CatchableError: discard
  0
