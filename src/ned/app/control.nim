# ════════════════════════════════════════════════════════════════════════════
#  Remote control: a socket only you can reach (in ned's private folder, 0600), so that the ned that is running
#  can be told what to do —
#    · `ned FILE` typed in ned's own terminal opens the file here instead of starting a ned inside ned
#    · `ned --wait FILE`, git's editor in that terminal: `git commit` opens its message in a tab and waits until
#      you close it
#    · scripts: ned --remote FILE[:LINE[:COL]] · --remote-command NAME · --remote-message TEXT ·
#      --remote-problems [NAME] (a build's output on stdin → Problems) · --remote-get WHAT · --remote-list
#  One JSON request per line, one or two answers back ("waiting", then "done").
# ════════════════════════════════════════════════════════════════════════════

type CtlClient = ref object
  fd: cint
  input: string
  waitPaths: seq[string]           # --wait: these files' tabs …
  waitIds: seq[int]                # … and these buffers: "done" once none is open any more
  backToTerm: bool                 # (asked from the terminal: the focus goes back there when it is done)

var
  ctlFd: cint = -1
  ctlPath = ""
  ctlClients: seq[CtlClient]

proc ctlSockName(pid: int): string = privDir() / ("remote-" & $pid & ".sock")

proc ctlSweep() =
  ## sockets of neds that are gone
  try:
    for kind, p in walkDir(privDir()):
      let n = extractFilename(p)
      if not (n.startsWith("remote-") and n.endsWith(".sock")): continue
      let pidS = n[7 ..< n.len - 5]
      if pidS.len == 0 or not pidS.allCharsInSet(Digits): continue
      let pid = parseInt(pidS)
      if pid != getCurrentProcessId() and kill(Pid(pid), 0) != 0 and errno == ESRCH: removeFile(p)
  except CatchableError: discard

proc sockAddr(path: string, a: var Sockaddr_un): bool =
  if path.len >= a.sun_path.len: return false        # (too long a name for a socket)
  zeroMem(addr a, sizeof(a))
  a.sun_family = TSa_Family(AF_UNIX)
  for i, c in path: a.sun_path[i] = c
  true

proc ctlListen() =
  ## start answering: the socket, and $NED_SOCKET for what ned starts (its terminal above all)
  if ctlFd >= 0: return
  ctlSweep()
  let path = ctlSockName(getCurrentProcessId())
  var a: Sockaddr_un
  if not sockAddr(path, a): return
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.cint < 0: return
  discard posix.unlink(path.cstring)
  let old = umask(0o177)
  let ok = posix.bindSocket(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0
  discard umask(old)
  if not ok or posix.listen(fd, 8) != 0:
    discard posix.close(fd)
    return
  discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
  setNonBlock(fd.cint)
  ctlFd = fd.cint
  ctlPath = path
  putEnv("NED_SOCKET", path)

proc ctlSend(c: CtlClient, j: JsonNode) =
  let s = $j & "\n"
  var off = 0
  var tries = 0
  while off < s.len and c.fd >= 0:
    let n = posix.write(c.fd, unsafeAddr s[off], s.len - off)
    if n > 0:
      off += n
      continue
    if n < 0 and errno in [EAGAIN, EWOULDBLOCK, EINTR] and tries < 50:
      inc tries
      var pf = TPollfd(fd: c.fd, events: POLLOUT)
      discard poll(addr pf, 1, 100)
      continue
    break

proc ctlDrop(c: CtlClient) =
  if c.fd >= 0:
    discard posix.close(c.fd)
    c.fd = -1

proc openTextBuffer(text: string, title = "") =
  ## text that came from a pipe (`git log | ned`): a new tab, its language guessed (a diff, a log …)
  let b = newBuffer()
  let txt = stripAnsi(text).replace("\r\n", "\n")
  b.setContent(if txt.endsWith("\n"): txt[0 ..< ^1] else: txt)
  let l0 = b.lines[0]
  b.lang = if l0.startsWith("diff ") or l0.startsWith("--- ") or
              (l0.startsWith("commit ") and "\ndiff --git " in txt): langByName("Diff")
           else: detectLang("", l0)
  if title.len > 0: b.title = title
  if bufs.len == 1 and bufs[0].isWelcome(): bufs[0] = b
  else: bufs.add b
  curBuf = bufs.find(b)
  focus = fEditor

proc ctlGet(what: string): JsonNode =
  let b = buf()
  case what
  of "file": %b.path
  of "line": %(b.primary.head.line + 1)
  of "col": %(b.primary.head.col + 1)
  of "selection":
    let (a, e) = b.primary.range
    %(if a != e: b.getText(a, e) else: "")
  of "word": %b.wordAt(b.primary.head)
  of "root", "project": %rootDir
  of "files":
    var a = newJArray()
    for x in bufs:
      if x.path.len > 0: a.add %x.path
    a
  of "text": %(b.lines.join("\n"))
  else: newJNull()

proc ctlHandle(c: CtlClient, line: string) =
  var j: JsonNode
  try: j = parseJson(line)
  except CatchableError:
    c.ctlSend(%*{"error": "not a request"})
    return
  if j.kind != JObject:
    c.ctlSend(%*{"error": "not a request"})
    return
  needRender = true
  let fromTerm = focus == fPanel and panelOpen and panelKind == pkTerminal
  case j{"cmd"}.getStr
  of "info":
    var files = newJArray()
    for x in bufs:
      if x.path.len > 0: files.add %x.path
    c.ctlSend(%*{"ok": true, "pid": getCurrentProcessId(), "root": rootDir, "version": Version, "files": files})
  of "open":
    var opened = 0
    var problems: seq[string]
    for f in j{"files"}.jitems:
      let path = f{"path"}.getStr
      if path.len == 0: continue
      if dirExists(path):
        if rootDir.len > 0 and (path == rootDir or path.startsWith(rootDir & "/")):
          showSide(svProject)
          inc opened
        else:
          problems.add path & " is a folder of another project — `ned --new " & quoteShell(path) & "` opens it in a new ned"
        continue
      let b = openFile(path, f{"line"}.getInt(-1), f{"col"}.getInt(-1))
      if b == nil:
        problems.add "could not open " & path
        continue
      inc opened
      if j{"wait"}.getBool:
        c.waitPaths.add b.path
        c.waitIds.add b.id
    if j{"wait"}.getBool and c.waitIds.len > 0:
      c.backToTerm = fromTerm
      focus = fEditor
      let names = block:
        var ns: seq[string]
        for p in c.waitPaths: ns.add extractFilename(p)
        ns.join(", ")
      info(names & " — " & (if "COMMIT_EDITMSG" in names or "git-rebase-todo" in names or "TAG_EDITMSG" in names: "git" else: "the terminal") &
           " waits for it: save it and close the tab (Ctrl+S, Ctrl+W) to go on")
      c.ctlSend(%*{"ok": true, "waiting": true, "opened": opened})
    elif problems.len > 0 and opened == 0: c.ctlSend(%*{"error": problems.join("\n")})
    else:
      if problems.len > 0: warn(problems.join("\n"))
      c.ctlSend(%*{"ok": true, "opened": opened})
  of "text":
    openTextBuffer(j{"text"}.getStr, j{"title"}.getStr)
    if j{"wait"}.getBool:
      c.waitIds.add buf().id
      c.backToTerm = fromTerm
      c.ctlSend(%*{"ok": true, "waiting": true})
    else: c.ctlSend(%*{"ok": true})
  of "command":
    let name = j{"name"}.getStr
    var found = false
    for cm in commands:
      if cm.name == name: found = true
    if not found:
      var close: seq[string]
      for cm in commands:
        if name.len >= 3 and name.toLowerAscii in cm.name.toLowerAscii: close.add cm.name
      c.ctlSend(%*{"error": "no command \"" & name & "\"" &
                   (if close.len > 0: " — did you mean: " & close[0 ..< min(5, close.len)].join(" · ") else: "")})
    else:
      c.ctlSend(%*{"ok": true})
      runCmd(name)
  of "message":
    let t = j{"text"}.getStr
    case j{"level"}.getStr
    of "error": error(t)
    of "warn", "warning": warn(t)
    else: info(t)
    c.ctlSend(%*{"ok": true})
  of "problems":
    let n = problemsFromText(j{"source"}.getStr, j{"text"}.getStr, j{"cwd"}.getStr)
    if n > 0 and not panelOpen: setPanel(pkProblems)
    c.ctlSend(%*{"ok": true, "problems": n})
  of "get":
    let v = ctlGet(j{"what"}.getStr)
    if v.kind == JNull: c.ctlSend(%*{"error": "--remote-get: file, line, col, selection, word, root, files or text"})
    else: c.ctlSend(%*{"ok": true, "value": v})
  else:
    c.ctlSend(%*{"error": "unknown request \"" & j{"cmd"}.getStr & "\""})

proc ctlFds(fds: var seq[TPollfd]) =
  if ctlFd >= 0: fds.add TPollfd(fd: ctlFd, events: POLLIN)
  for c in ctlClients:
    if c.fd >= 0: fds.add TPollfd(fd: c.fd, events: POLLIN)

proc ctlPump(ready: HashSet[cint]) =
  ## new connections, requests, and the waits that are over
  if ctlFd >= 0 and ctlFd in ready:
    while true:
      let fd = posix.accept(SocketHandle(ctlFd), nil, nil)
      if fd.cint < 0: break
      discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
      setNonBlock(fd.cint)
      ctlClients.add CtlClient(fd: fd.cint)
  for c in ctlClients:
    if c.fd < 0 or c.fd notin ready: continue
    var tmp: array[65536, char]
    while c.fd >= 0:
      let n = posix.read(c.fd, addr tmp[0], tmp.len)
      if n > 0:
        let old = c.input.len
        c.input.setLen(old + n)
        copyMem(addr c.input[old], addr tmp[0], n)
        if c.input.len > 64 * 1024 * 1024:
          c.ctlSend(%*{"error": "too much"})
          c.ctlDrop()
      elif n == 0: c.ctlDrop()                       # (it went away: what it waited for does not matter now)
      else:
        if errno notin [EAGAIN, EWOULDBLOCK, EINTR]: c.ctlDrop()
        break
    while c.fd >= 0:
      let nl = c.input.find('\n')
      if nl < 0: break
      let line = c.input[0 ..< nl]
      c.input = c.input[nl + 1 .. ^1]
      try: c.ctlHandle(line)
      except CatchableError as e: c.ctlSend(%*{"error": e.msg})
  # the waits: done once none of the tabs is open any more
  for c in ctlClients:
    if c.fd < 0 or c.waitIds.len == 0: continue
    var open = false
    for id in c.waitIds:
      if bufById(id) != nil: open = true
    if not open:
      c.ctlSend(%*{"done": true})
      c.ctlDrop()
      if c.backToTerm and terms.len > 0:
        setPanel(pkTerminal)
        focus = fPanel
      needRender = true
  var keep: seq[CtlClient]
  for c in ctlClients:
    if c.fd >= 0: keep.add c
  ctlClients = keep

proc ctlClose() =
  ## ned is quitting: whoever waits is told, and the socket goes
  for c in ctlClients:
    if c.waitIds.len > 0: c.ctlSend(%*{"done": true, "quit": true})
    c.ctlDrop()
  ctlClients.setLen(0)
  if ctlFd >= 0:
    discard posix.close(ctlFd)
    ctlFd = -1
  if ctlPath.len > 0:
    discard posix.unlink(ctlPath.cstring)
    ctlPath = ""

# ── the other side: `ned` talking to the ned that is running ──

proc ctlConnect(path: string): cint =
  var a: Sockaddr_un
  if path.len == 0 or not sockAddr(path, a): return -1
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.cint < 0: return -1
  if posix.connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) != 0:
    discard posix.close(fd)
    return -1
  fd.cint

proc ctlReadLine(fd: cint, buffer: var string, timeoutMs: int): string =
  ## one answer ("" when the other side went away, or after timeoutMs; -1: no limit)
  while true:
    let nl = buffer.find('\n')
    if nl >= 0:
      result = buffer[0 ..< nl]
      buffer = buffer[nl + 1 .. ^1]
      return
    var pf = TPollfd(fd: fd, events: POLLIN)
    let r = poll(addr pf, 1, timeoutMs.cint)
    if r < 0 and errno == EINTR: continue
    if r <= 0: return ""
    var tmp: array[65536, char]
    let n = posix.read(fd, addr tmp[0], tmp.len)
    if n <= 0: return ""
    let old = buffer.len
    buffer.setLen(old + n)
    copyMem(addr buffer[old], addr tmp[0], n)

proc ctlAsk(path: string, req: JsonNode, waitMs = 5000): JsonNode =
  ## one request, its first answer (nil: no ned answered there)
  let fd = ctlConnect(path)
  if fd < 0: return nil
  defer: discard posix.close(fd)
  let s = $req & "\n"
  if posix.write(fd, unsafeAddr s[0], s.len) != s.len: return nil
  var rest = ""
  let line = ctlReadLine(fd, rest, waitMs)
  if line.len == 0: return nil
  try: parseJson(line) except CatchableError: nil

proc ctlRunning(): seq[(string, JsonNode)] =
  ## the neds running for you: (socket, what it says about itself)
  try:
    for kind, p in walkDir(privDir()):
      let n = extractFilename(p)
      if n.startsWith("remote-") and n.endsWith(".sock"):
        let j = ctlAsk(p, %*{"cmd": "info"}, 1500)
        if j != nil and j{"ok"}.getBool: result.add (p, j)
  except CatchableError: discard

proc ctlFind(near: string): string =
  ## the ned to talk to: the one whose terminal this is ($NED_SOCKET), else the one whose project holds `near`,
  ## else the one started last
  let env = getEnv("NED_SOCKET")
  if env.len > 0 and ctlAsk(env, %*{"cmd": "info"}, 1500) != nil: return env
  var best = ""
  var bestLen = -1
  var lastPid = -1
  var last = ""
  for (p, j) in ctlRunning():
    let root = j{"root"}.getStr
    if root.len > 0 and (near == root or near.startsWith(root & "/")) and root.len > bestLen:
      best = p
      bestLen = root.len
    if j{"pid"}.getInt > lastPid:
      lastPid = j{"pid"}.getInt
      last = p
  if best.len > 0: best else: last

proc ctlClient(sock: string, req: JsonNode, wait: bool): int =
  ## send `req`; print what comes back; with `wait` stay until the ned says "done". The exit code
  let fd = ctlConnect(sock)
  if fd < 0:
    stderr.writeLine("ned: no ned answers at " & sock)
    return 1
  defer: discard posix.close(fd)
  let s = $req & "\n"
  var off = 0
  while off < s.len:
    let n = posix.write(fd, unsafeAddr s[off], s.len - off)
    if n <= 0:
      if n < 0 and errno == EINTR: continue
      stderr.writeLine("ned: the running ned did not take the request")
      return 1
    off += n
  var rest = ""
  let first = ctlReadLine(fd, rest, 30_000)
  if first.len == 0:
    stderr.writeLine("ned: no answer from the running ned")
    return 1
  var j: JsonNode
  try: j = parseJson(first)
  except CatchableError:
    stderr.writeLine("ned: " & first)
    return 1
  if j{"error"}.getStr.len > 0:
    stderr.writeLine("ned: " & j{"error"}.getStr)
    return 1
  if j.hasKey("problems"): echo $j{"problems"}.getInt & (if j{"problems"}.getInt == 1: " problem" else: " problems")
  if j.hasKey("value"):
    let v = j["value"]
    case v.kind
    of JString: stdout.write v.getStr & (if v.getStr.endsWith("\n"): "" else: "\n")
    of JArray:
      for x in v: echo x.getStr
    else: echo $v
  if wait and j{"waiting"}.getBool:
    discard ctlReadLine(fd, rest, -1)        # ("done", or the ned went away: either way it is over)
  0
