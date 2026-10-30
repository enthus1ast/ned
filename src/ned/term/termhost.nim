# ════════════════════════════════════════════════════════════════════════════
#  Terminals that outlive ned (terminal.keepRunning). A terminal's shell belongs to a small process of its own, a
#  term host (`ned --term-host`, started by ned and left to run on its own), which holds the pseudo-terminal and
#  keeps the last MB the shell printed. ned talks to it through a socket in its private folder (0600). When ned
#  quits, or its window is closed, the host goes on; the next ned in the same folder connects again, the host plays
#  back what the shell printed, and the terminal is as it was — with whatever was running still running.
#  Messages, both ways: a kind (one byte), a length (4 bytes, big-endian), the bytes (see pty: hostFrame).
#    ned → host: a attach (the host's key, from term-ID.key — a sandboxed plugin cannot read it —, then a line
#    "force": take it from another ned) · d typed · r "COLS ROWS" · k end the shell · q detach
#    host → ned: i what it is (JSON) · p what the shell printed so far · d printed · x its exit code · b in use
#  Not on Windows; not REPLs (they start again by themselves), nor a remote folder's terminal (its ssh connection
#  ends with ned).
# ════════════════════════════════════════════════════════════════════════════

const
  HostRing = 1 shl 20           # what a host keeps of the output, to play back
  HostBehind = 1 shl 20         # … output not yet taken by ned: the shell waits (as in any terminal)
  HostDrop = 8 shl 20           # … a ned that takes nothing at all any more is let go

# a term host's file in ned's private folder (`term-ID` plus .sock, .json or .key)
proc hostPath(id, ext: string): string = privDir() / ("term-" & id & ext)

when not defined(windows):
  proc hostWriteAll(fd: cint, s: string, ms: int): bool =
    ## all of `s`, waiting up to ms for room
    var off = 0
    let until = getMonoTime() + initDuration(milliseconds = ms)
    while off < s.len:
      let n = posix.write(fd, unsafeAddr s[off], s.len - off)
      if n > 0: off += n
      elif n < 0 and errno in [EAGAIN, EINTR]:
        if getMonoTime() > until: return false
        var pf = TPollfd(fd: fd, events: POLLOUT)
        discard poll(addr pf, 1, 20)
      else: return false
    true

  proc hostReadFrame(fd: cint, buf: var string, kind: var char, pay: var string, ms: int): bool =
    ## the next whole message from fd, waiting up to ms
    let until = getMonoTime() + initDuration(milliseconds = ms)
    var tmp: array[65536, char]
    while not hostTake(buf, kind, pay):
      let left = int((until - getMonoTime()).inMilliseconds)
      if left <= 0: return false
      var pf = TPollfd(fd: fd, events: POLLIN)
      let r = poll(addr pf, 1, left.cint)
      if r < 0 and errno == EINTR: continue
      if r <= 0: return false
      let n = posix.read(fd, addr tmp[0], tmp.len)
      if n < 0 and errno in [EAGAIN, EINTR]: continue
      if n <= 0: return false
      let old = buf.len
      buf.setLen(old + n)
      copyMem(addr buf[old], addr tmp[0], n)
    true

  proc hostAttach(t: Term, id: string, force = false): bool =
    ## connect `t` to the host `id`: what it showed is played back into it (false: gone, or another ned has it)
    let fd = ctlConnect(hostPath(id, ".sock"))
    if fd < 0: return false
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    var buf = ""
    var kind: char
    var pay: string
    let key = ctlKeyOf(hostPath(id, ".sock"))
    if not hostWriteAll(fd, hostFrame('a', key & (if force: "\nforce" else: "")), 500) or
       not hostReadFrame(fd, buf, kind, pay, 2000) or kind != 'i':
      discard posix.close(fd)
      return false
    let j = try: parseJson(pay) except CatchableError: newJObject()
    t.pid = Pid(j{"shell"}.getInt)
    t.name = j{"name"}.getStr(t.name)
    let w = j{"cols"}.getInt(t.w)
    let h = j{"rows"}.getInt(t.h)
    t.hostId = id
    t.hosted = true
    t.fd = fd
    t.code = -1
    if w != t.w or h != t.h: t.resize(w, h)       # (played back at the size it was printed at)
    if hostReadFrame(fd, buf, kind, pay, 3000) and kind == 'p':
      t.feed(pay)
      t.reply.setLen(0)                           # (answers to what was asked before: not again)
      t.gotOutput = pay.len > 0
    t.inBuf = buf
    setNonBlock(fd)
    true

proc hostStart(t: Term, cwd: string, env: seq[(string, string)], argv: seq[string]): bool =
  ## the shell `argv` in a term host of its own, `t` connected to it (false: it could not start — ned then runs the
  ## shell itself, as before)
  when defined(windows): false
  else:
    let app = getAppFilename()
    if app.len == 0 or not fileExists(app): return false
    var id = toLowerAscii(toHex(int64(epochTime() * 1000) and 0xFF_FFFF_FFFF'i64, 10) &
                          toHex(getCurrentProcessId() and 0xFFF, 3))
    while fileExists(hostPath(id, ".json")) or fileExists(hostPath(id, ".sock")): id.add 'x'
    var a: Sockaddr_un
    if not sockAddr(hostPath(id, ".sock"), a): return false     # (too long a name for a socket)
    # (its key: what a ned attaching sends first — in a file only you can read, not on its command line, which
    # every program can see)
    let key = ctlNewKey()
    if key.len == 0 or not ctlWriteKey(hostPath(id, ".key"), key): return false
    let args = @[app, "--term-host", id, $t.w, $t.h, cwd, rootDir, "--"] & argv
    let pid = fork()
    if pid < 0: return false
    if pid == 0:
      # on its own: a session of its own, not ned's child (twice forked), nothing of ned's open
      discard setsid()
      if fork() != 0: exitnow(0)
      let nul = posix.open("/dev/null", O_RDWR)
      if nul >= 0:
        discard dup2(nul, 0)
        discard dup2(nul, 1)
        discard dup2(nul, 2)
        if nul > 2: discard posix.close(nul)
      for fd in 3 .. 1023: discard posix.close(cint(fd))
      for (k, v) in env: putEnv(k, v)
      discard execv(cstring(app), allocCStringArray(args))
      exitnow(127)
    var st: cint
    discard waitpid(pid, st, 0)
    let until = getMonoTime() + initDuration(milliseconds = 3000)
    while getMonoTime() < until:
      if fileExists(hostPath(id, ".json")) and t.hostAttach(id): return true
      os.sleep(5)
    false

proc hostList(): seq[JsonNode] =
  ## the terminals kept running (every folder's), oldest first; what is left of hosts that are gone is removed
  when not defined(windows):
    try:
      for kind, p in walkDir(privDir()):
        let n = extractFilename(p)
        if not (n.startsWith("term-") and n.endsWith(".json")): continue
        let j = try: parseJson(readFile(p)) except CatchableError: nil
        let pid = if j != nil: j{"pid"}.getInt else: 0
        if pid <= 0 or (kill(Pid(pid), 0) != 0 and errno == ESRCH):
          try:
            removeFile(p)
            removeFile(p.changeFileExt(".sock"))
            removeFile(p.changeFileExt(".key"))
          except CatchableError: discard
          continue
        result.add j
    except CatchableError: discard
    result.sort(proc(a, b: JsonNode): int = cmp(a{"created"}.getFloat, b{"created"}.getFloat))

proc hostEnd(j: JsonNode) =
  ## end a kept terminal's shell (its host then ends too)
  when not defined(windows):
    let sh = j{"shell"}.getInt
    if sh > 0:
      discard kill(Pid(-sh), SIGHUP)
      discard kill(Pid(sh), SIGHUP)

proc termReattach() =
  ## (at start) the terminals this folder's ned kept running last time, back in the Terminal panel
  when not defined(windows):
    if not cfgTermKeep: return
    var n = 0
    for j in hostList():
      if j{"project"}.getStr != rootDir: continue
      let t = blankTerm(j{"cols"}.getInt(80), j{"rows"}.getInt(24))
      t.name = j{"name"}.getStr("sh")
      t.replAt = getMonoTime()
      if t.hostAttach(j{"id"}.getStr):
        terms.add t
        inc n
    if n > 0:
      curTerm = 0
      info((if n == 1: "A terminal" else: $n & " terminals") & " kept running since last time: back in the " &
           "Terminal panel (Ctrl+\\)")

proc termKeptMenu() =
  ## Terminal: kept terminals… — every folder's, each to end
  let ks = hostList()
  if ks.len == 0:
    info("No terminal is kept running (terminal.keepRunning: " & (if cfgTermKeep: "on" else: "off") & ")")
    return
  # the menu action that ends one kept terminal's shell and says so (a factory proc: each menu item needs its own `j`)
  proc endAct(j: JsonNode): Action = (proc() =
    hostEnd(j)
    info("Ended " & j{"name"}.getStr & " in " & j{"project"}.getStr.tildePath))
  var items: seq[MenuItem]
  for j in ks:
    let here = j{"project"}.getStr == rootDir
    let since = try: fromUnixFloat(j{"created"}.getFloat).local.format("d MMM HH:mm") except CatchableError: ""
    items.add mi("End " & j{"name"}.getStr & " in " & (if here: "this folder" else: j{"project"}.getStr.tildePath) &
                 (if since.len > 0: " (since " & since & ")" else: ""), "", endAct(j))
  items.add msep()
  items.add mi("End all " & $ks.len, "", proc() =
    for j in ks: hostEnd(j)
    info("Ended " & $ks.len & " kept terminal" & (if ks.len == 1: "" else: "s")))
  openMenu(items, max(0, scrW div 2 - 30), max(1, scrH div 4))

when not defined(windows):
  proc termHostMain(args: seq[string]) =
    ## `ned --term-host ID COLS ROWS CWD FOLDER -- SHELL ARGS…`: hold one shell for ned (see above); never returns
    if args.len < 7 or args[5] != "--": quit 2
    let id = args[0]
    let cols = try: parseInt(args[1]) except ValueError: 80
    let rows = try: parseInt(args[2]) except ValueError: 24
    let cwd = args[3]
    let project = args[4]
    let argv = args[6 .. ^1]
    signal(SIGHUP, SIG_IGN)           # (ned's window closed: not a reason to end)
    signal(SIGPIPE, SIG_IGN)
    let sockP = hostPath(id, ".sock")
    let infoP = hostPath(id, ".json")
    let keyP = hostPath(id, ".key")
    let key = try: readFile(keyP).strip except CatchableError: ""
    if key.len == 0: quit 1               # (no key: a ned could not prove it is yours)
    var a: Sockaddr_un
    if not sockAddr(sockP, a): quit 1
    let ls = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    if ls.cint < 0: quit 1
    discard posix.unlink(sockP.cstring)
    let old = umask(0o177)
    let bound = posix.bindSocket(ls, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0
    discard umask(old)
    if not bound or posix.listen(ls, 4) != 0: quit 1
    let lfd = ls.cint
    discard fcntl(lfd, F_SETFD, FD_CLOEXEC)
    proc gone(code: int) =
      ## the host's exit: removes its socket, info and key files, then quits with `code`
      discard posix.unlink(sockP.cstring)
      try:
        removeFile(infoP)
        removeFile(keyP)
      except CatchableError: discard
      quit code
    let (mfd, slave) = ptyOpen()
    if mfd < 0: gone(1)
    var ws: IOctl_WinSize
    ws.ws_row = uint16(rows)
    ws.ws_col = uint16(cols)
    discard ioctl(mfd, TIOCSWINSZ, addr ws)
    discard fcntl(mfd, F_SETFD, FD_CLOEXEC)
    let shellPid = fork()
    if shellPid == 0: ptyExec(mfd, slave, cwd, @[], argv)    # (its environment came with the host)
    if shellPid < 0: gone(1)
    setNonBlock(mfd)
    var info = %*{"id": id, "pid": getCurrentProcessId(), "shell": shellPid.int, "project": project, "cwd": cwd,
                  "name": extractFilename(argv[0]), "cols": cols, "rows": rows, "created": epochTime()}
    try:
      writeFile(infoP & ".tmp", $info)
      moveFile(infoP & ".tmp", infoP)
    except CatchableError: gone(1)
    var
      ring = ""                       # what the shell printed (the last HostRing bytes, from a line's start)
      client: cint = -1               # the ned that has it
      cin, cout = ""                  # … what came from it, not yet whole messages; what goes to it, not yet sent
      coutAt = 0                      # … (sent up to here: cout is cut down now and then, not at every write)
      code = -1
      ended = false
      endAt: MonoTime                 # (asked to end: SIGKILL if it is still there 2 s later)
      tmp: array[65536, char]
    proc drop(c: var cint) =
      ## lets go of the connected ned: closes its socket and clears what was waiting to be read from it or sent to it
      if c >= 0: discard posix.close(c)
      c = -1
      cin = ""
      cout = ""
      coutAt = 0
    proc output(s: string) =
      ## takes what the shell printed: adds it to the kept output (cut back to the last megabyte, from a line's start,
      ## only now and then) and queues it for the connected ned, if there is one
      ring.add s
      if ring.len > 2 * HostRing:       # (cut down to the last HostRing now and then: not copied at every read)
        var cut = ring.len - HostRing
        let nl = ring.find('\n', cut)
        if nl >= 0 and nl - cut < 4096: cut = nl + 1
        ring = ring[cut .. ^1]
      if client >= 0: cout.add hostFrame('d', s)
    while not ended:
      var pf: array[3, TPollfd]
      pf[0] = TPollfd(fd: lfd, events: POLLIN)
      pf[1] = TPollfd(fd: (if cout.len - coutAt < HostBehind: mfd else: -1), events: POLLIN)
      pf[2] = TPollfd(fd: client, events: POLLIN or (if cout.len > coutAt: POLLOUT else: 0))
      let r = poll(addr pf[0], 3, 500)
      if r < 0 and errno != EINTR: break
      # the shell's output
      if pf[1].fd >= 0 and (pf[1].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        for _ in 0 ..< 16:
          let n = posix.read(mfd, addr tmp[0], tmp.len)
          if n > 0:
            var s = newString(n)
            copyMem(addr s[0], addr tmp[0], n)
            output(s)
          else:
            if n == 0 or errno notin [EAGAIN, EINTR]: ended = true
            break
      # the shell itself ended (what it started may still hold the terminal: the shell is what counts)
      var st: cint
      if waitpid(shellPid, st, WNOHANG) == shellPid:
        code = if WIFEXITED(st): int(WEXITSTATUS(st)) else: -1
        ended = true
      elif endAt != MonoTime() and getMonoTime() - endAt > initDuration(seconds = 2):
        discard kill(Pid(-shellPid), SIGKILL)
        discard kill(shellPid, SIGKILL)
      # a ned connecting: its first message says whether it takes the terminal from another ned that has it
      if (pf[0].revents and POLLIN) != 0:
        var sa: Sockaddr_un
        var sl = SockLen(sizeof(sa))
        let c = posix.accept(ls, cast[ptr SockAddr](addr sa), addr sl).cint
        if c >= 0:
          discard fcntl(c, F_SETFD, FD_CLOEXEC)
          var b = ""
          var kind: char
          var pay: string
          if not hostReadFrame(c, b, kind, pay, 500) or kind != 'a': discard posix.close(c)
          elif not ctlSameKey(pay.split('\n')[0], key):
            discard posix.close(c)        # (without the key: a program that may not type into your shell)
          elif client >= 0 and not pay.endsWith("\nforce"):
            discard hostWriteAll(c, hostFrame('b', ""), 200)
            discard posix.close(c)
          else:
            drop(client)
            client = c
            setNonBlock(c)
            cin = b
            info["cols"] = %int(ws.ws_col)
            info["rows"] = %int(ws.ws_row)
            cout = hostFrame('i', $info) & hostFrame('p', ring)
            coutAt = 0
      # what ned sends
      if client >= 0 and (pf[2].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        let n = posix.read(client, addr tmp[0], tmp.len)
        if n > 0:
          let old = cin.len
          cin.setLen(old + n)
          copyMem(addr cin[old], addr tmp[0], n)
          var kind: char
          var pay: string
          var at = 0
          while client >= 0 and hostTake(cin, at, kind, pay):
            case kind
            of 'd': discard hostWriteAll(mfd, pay, 1000)
            of 'r':
              let p = pay.splitWhitespace
              if p.len == 2:
                try:
                  ws.ws_col = uint16(clamp(parseInt(p[0]), 2, 1000))
                  ws.ws_row = uint16(clamp(parseInt(p[1]), 2, 1000))
                  discard ioctl(mfd, TIOCSWINSZ, addr ws)   # (the shell gets SIGWINCH and draws again)
                except ValueError: discard
            of 'k':
              discard kill(Pid(-shellPid), SIGHUP)
              discard kill(shellPid, SIGHUP)
              endAt = getMonoTime()
            of 'q': drop(client)
            else: discard
          if client >= 0 and at > 0: cin = cin[at .. ^1]
        elif n == 0 or errno notin [EAGAIN, EINTR]: drop(client)
      if client >= 0 and cout.len > coutAt and (pf[2].revents and POLLOUT) != 0:
        let n = posix.write(client, addr cout[coutAt], cout.len - coutAt)
        if n > 0:
          coutAt += n
          if coutAt == cout.len:
            cout.setLen(0)
            coutAt = 0
          elif coutAt > HostBehind:
            cout = cout[coutAt .. ^1]
            coutAt = 0
        elif n < 0 and errno notin [EAGAIN, EINTR]: drop(client)
      if cout.len - coutAt > HostDrop: drop(client)
    # the end: what is left of the output, then how the shell ended
    for _ in 0 ..< 64:
      let n = posix.read(mfd, addr tmp[0], tmp.len)
      if n <= 0: break
      var s = newString(n)
      copyMem(addr s[0], addr tmp[0], n)
      output(s)
    if code < 0:
      var st: cint
      for _ in 0 ..< 100:
        if waitpid(shellPid, st, WNOHANG) == shellPid:
          code = if WIFEXITED(st): int(WEXITSTATUS(st)) else: -1
          break
        os.sleep(10)
    if client >= 0: discard hostWriteAll(client, cout[coutAt .. ^1] & hostFrame('x', $code), 2000)
    gone(0)
