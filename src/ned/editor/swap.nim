# ── swap files: unsaved edits survive a crash, a killed Termux session or a dead battery ──
# One file per (path, ned process): <hash(path)>-<pid>.json. A session only ever writes or deletes its
# own files, so a crashed session's edits stay until you restore or discard them.

# the folder of the recovery (swap) files, inside ned's state folder
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
    ## makes the folder d (mode 0700) and says whether it is really yours: a folder, not a link, owned by this user,
    ## with no rights for group or others
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

proc privSweep() =
  ## what a ned that was killed left in privDir() (its process gone, the file 10 minutes old): its temp files
  ## are named name-PID-N, and only those whose PID runs no more are removed
  try:
    let now = getTime()
    for kind, p in walkDir(privDir()):
      let parts = extractFilename(p).split('-')
      if parts.len < 3 or parts[^2].len == 0 or not parts[^2].allCharsInSet(Digits) or parts[^2].len > 9: continue
      let pid = parseInt(parts[^2])
      if pid <= 1 or pid == getCurrentProcessId() or kill(Pid(pid), 0) == 0 or errno == EPERM: continue
      if now - getLastModificationTime(p) < initDuration(minutes = 10): continue
      if kind == pcDir: removeDir(p) else: removeFile(p)
  except CatchableError: discard

# ── persistent undo: a file's undo history is kept (state/undo) and comes back while the file is unchanged ──

var undoWritten: Table[int, int]        # buffer id → the undo step last written

# the file where the undo history of the file at this path is kept
proc undoFile(path: string): string = stateDir() / "undo" / fnv(path) & ".json"

proc writeUndo(b: Buffer) =
  ## keeps a saved file's undo history for the next time it is opened: the last 300 undo and redo steps (about 4 MB of
  ## text at most) and 20 undo-tree branches, as JSON together with a hash of the text, so readUndo only brings it back
  ## while the file is unchanged. Skipped for buffers with no file, titled or binary ones, ones with unsaved edits and
  ## huge ones; an empty history removes the file
  if not cfgPersistentUndo or b.path.len == 0 or b.title.len > 0 or b.binary or b.dirty: return
  if b.lines.len > 200_000: return             # (huge files: hashing them on every save costs too much)
  if undoWritten.getOrDefault(b.id, -1) == b.topSeq() and b.undoStack.len > 0: return
  undoWritten[b.id] = b.topSeq()
  let f = undoFile(b.path)
  if b.undoStack.len == 0 and b.redoStack.len == 0 and b.undoBranches.len == 0:
    removeFile(f)
    return
  # a position as JSON: [line, column]
  proc pos(p: Pos): JsonNode = %[p.line, p.col]
  proc curs(cs: seq[Cursor]): JsonNode =
    ## cursors as JSON: a list of [anchor line, anchor column, head line, head column]
    result = newJArray()
    for c in cs: result.add %[c.anchor.line, c.anchor.col, c.head.line, c.head.col]
  proc groups(gs: seq[UndoGroup]): JsonNode =
    ## the last 300 undo groups as JSON — each with its edits (position, old text, new text), the cursors before and
    ## after, its kind and sequence number — stopping when the texts add up to 4 MB
    result = newJArray()
    var size = 0
    for g in gs[max(0, gs.len - 300) .. ^1]:
      let ops = newJArray()
      for o in g.ops:
        ops.add %*[pos(o.a), o.oldText, o.newText]
        size += o.oldText.len + o.newText.len
      result.add %*{"o": ops, "b": curs(g.before), "a": curs(g.after), "k": g.kind, "s": g.seqId}
      if size > 4_000_000: break
  # the undo tree's branches (their first steps; where they leave the line of edits, counted in the steps kept)
  let offset = b.undoStack.len - min(300, b.undoStack.len)
  let brs = newJArray()
  for br in b.undoBranches[max(0, b.undoBranches.len - 20) .. ^1]:
    if br.at - offset < 0: continue
    brs.add %*{"at": br.at - offset, "g": groups(br.groups[0 ..< min(300, br.groups.len)])}
  let j = %*{"path": b.path, "hash": fnv(b.lines.join("\n")), "undo": groups(b.undoStack), "redo": groups(b.redoStack),
             "branches": brs}
  try:
    createDir(parentDir(f))
    writeFile(f, $j)
  except IOError, OSError: discard

proc readUndo(b: Buffer) =
  ## restores the undo history stored by writeUndo when it belongs to this file and the file's text is still the one it
  ## was stored for (else it is ignored); the numbering of undo steps carries on after it, and the buffer counts as
  ## saved
  if not cfgPersistentUndo or b.path.len == 0 or b.lines.len > 200_000: return
  let f = undoFile(b.path)
  if not fileExists(f): return
  var j: JsonNode
  try: j = parseFile(f)
  except CatchableError: return
  if j{"path"}.getStr != b.path or j{"hash"}.getStr != fnv(b.lines.join("\n")): return     # changed elsewhere
  # a position back from its JSON [line, column]
  proc posOf(n: JsonNode): Pos = Pos(line: n[0].getInt, col: n[1].getInt)
  proc cursOf(n: JsonNode): seq[Cursor] =
    ## cursors back from their JSON form
    for c in jitems(n):
      result.add Cursor(anchor: Pos(line: c[0].getInt, col: c[1].getInt), head: Pos(line: c[2].getInt, col: c[3].getInt), goalX: -1)
  proc groupsOf(n: JsonNode): seq[UndoGroup] =
    ## undo groups back from their JSON form
    for g in jitems(n):
      var ug = UndoGroup(kind: g{"k"}.getInt, seqId: g{"s"}.getInt, before: cursOf(g{"b"}), after: cursOf(g{"a"}))
      for o in jitems(g{"o"}): ug.ops.add EditOp(a: posOf(o[0]), oldText: o[1].getStr, newText: o[2].getStr)
      result.add ug
  try:
    b.undoStack = groupsOf(j{"undo"})
    b.redoStack = groupsOf(j{"redo"})
    b.undoBranches.setLen(0)
    for br in jitems(j{"branches"}):
      let at = br{"at"}.getInt
      if at >= 0 and at <= b.undoStack.len + b.redoStack.len:
        b.undoBranches.add UndoBranch(at: at, groups: groupsOf(br{"g"}))
  except CatchableError:
    b.undoStack.setLen(0)
    b.redoStack.setLen(0)
    b.undoBranches.setLen(0)
    return
  for g in b.undoStack: undoSeq = max(undoSeq, g.seqId)
  for g in b.redoStack: undoSeq = max(undoSeq, g.seqId)
  for br in b.undoBranches:
    for g in br.groups: undoSeq = max(undoSeq, g.seqId)
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
  ## the name a buffer's recovery file starts with: a hash of its path, or `untitled` and its number for a buffer with
  ## no file
  if b.path.len > 0: fnv(b.path) else: "untitled" & $b.id

proc swapPath(b: Buffer): string =
  ## this session's recovery file for the buffer: the key, a dash and the process id, so sessions never touch each
  ## other's files
  swapDir() / swapKey(b) & "-" & $getCurrentProcessId() & ".json"

# ── a recovery file is flushed to storage (fsync) and put in place by a thread of its own: on a phone's flash an
#    fsync took tens of ms — now and then hundreds — at every pause in typing, and no key was read meanwhile. Its
#    jobs are done in order (a file removed after it was written stays removed); a crash or a signal stops it first
#    and writes what is left itself ──
type SwapJob = object
  kind: int8                 # 0 stop · 1 flush the written temp file and rename it over the recovery file · 2 remove
  fd: cint
  tmp, dest: string

var
  swapChan: Channel[SwapJob]
  swapThr: Thread[void]
  swapThrOn = false
  swapTmpN = 0

proc swapThreadMain() {.thread.} =
  ## the recovery-file thread: does its jobs in the order given — stop; flush the written temp file to storage, close it
  ## and rename it over the recovery file; remove a recovery file
  while true:
    let j = swapChan.recv()
    case j.kind
    of 0: break
    of 1:
      discard fsync(j.fd)
      discard posix.close(j.fd)
      if cRename(j.tmp.cstring, j.dest.cstring) != 0: discard posix.unlink(j.tmp.cstring)
    else: discard posix.unlink(j.dest.cstring)

proc swapThreadStart(): bool =
  ## starts the recovery-file thread if it is not running; false when it cannot be started, and the caller then writes
  ## the file itself
  if swapThrOn: return true
  try:
    swapChan.open()
    createThread(swapThr, swapThreadMain)
    swapThrOn = true
  except CatchableError, ResourceExhaustedError: discard
  swapThrOn

proc swapThreadStop() =
  ## what it was given is done (then it stops): before ned leaves, and before a recovery file is written here
  if not swapThrOn: return
  swapChan.send(SwapJob(kind: 0))
  joinThread(swapThr)
  swapChan.close()
  swapThrOn = false

proc removeSwap(b: Buffer) =
  ## deletes only this session's recovery file for `b`
  b.swapAt = b.changeId
  if not b.swapMine: return
  b.swapMine = false
  try:
    let p = swapPath(b)
    if swapThrOn: swapChan.send(SwapJob(kind: 2, dest: p))     # (after a write it may still be finishing)
    elif fileExists(p): removeFile(p)
  except CatchableError: discard

proc swapWriteAsync(dest, content: string): bool =
  ## the recovery file written to a temp file here, flushed and put in place by the thread (false: do it here)
  if not swapThreadStart(): return false
  inc swapTmpN
  let tmp = dest & ".w" & $swapTmpN
  let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_TRUNC or O_NOFOLLOW or O_CLOEXEC, 0o600)
  if fd < 0: return false
  var off = 0
  while off < content.len:
    let n = posix.write(fd, unsafeAddr content[off], content.len - off)
    if n < 0:
      if errno == EINTR: continue
      discard posix.close(fd)
      discard posix.unlink(tmp.cstring)
      return false
    off += n
  swapChan.send(SwapJob(kind: 1, fd: fd, tmp: tmp, dest: dest))
  true

proc writeSwap(b: Buffer, force = false) =
  ## writes the buffer's unsaved text to its recovery file (JSON with the path, process id and start time, time, text
  ## and line ending; mode 0600), or removes the file when the buffer is unchanged. Not for binary, titled or read-only
  ## buffers, or over 300,000 lines; a big file at most every 20 seconds. Normally the thread flushes it; `force` (a
  ## crash or a signal) lets the thread finish and writes it here at once
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
    if force:
      swapThreadStop()                     # (a crash or a signal: what the thread had first, then this, here)
      writeFileSafe(swapPath(b), $j, 0o600)
    elif not swapWriteAsync(swapPath(b), $j):
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
