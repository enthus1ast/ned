# ════════════════════════════════════════════════════════════════════════════
#  Background jobs: run/build, checks, git
# ════════════════════════════════════════════════════════════════════════════

proc setNonBlock(fd: cint) =
  ## puts the file descriptor in non-blocking mode, so reading it never waits for output that has not come
  if fd >= 0: discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)

# ── Child processes ───────────────────────────────────────────────────────────
# A small fork/exec layer instead of std/osproc: Termux's bionic has no posix_spawn on
# older Android versions, and own process groups let us stop a whole build/run tree.

type
  StdinMode = enum siNull, siPipe
  ErrMode = enum erMerge, erPipe, erNull

proc csystem(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}

func closeFd(fd: var cint) =
  ## closes the file descriptor if it is open and sets it to -1
  if fd >= 0:
    discard posix.close(fd)
    fd = -1

const
  CodeTools = ["nim", "nimble", "nimsuggest", "nimlangserver", "testament", "nimony", "atlas"]
    ## programs that run a folder's code: config.nims, .nims and .nimble files are scripts, macros run at compile time
  TrustRefusal = "not run — this folder is not trusted:"

proc shellCommands(cmd: string): seq[seq[string]] =
  ## the commands a shell line starts, each as its words (quotes taken off): `cd x && nim check a.nim | head`
  var cur: seq[string]
  var w = ""
  var inWord = false
  var i = 0
  template endWord() =
    ## ends the word being collected: adds it to the command's words
    if inWord:
      cur.add w
      w = ""
      inWord = false
  template endCmd() =
    ## ends the word and the command being collected: a command with words goes to the result, and a new one starts
    endWord()
    if cur.len > 0: result.add cur
    cur = @[]
  while i < cmd.len:
    let c = cmd[i]
    case c
    of ' ', '\t': endWord()
    of '\n', ';', '&', '|', '(', ')', '`': endCmd()
    of '$':
      if i + 1 < cmd.len and cmd[i + 1] == '(':
        endCmd()
        inc i
      else:
        w.add c
        inWord = true
    of '\'', '"':
      let q = c
      inc i
      while i < cmd.len and cmd[i] != q:
        if q == '"' and cmd[i] == '\\' and i + 1 < cmd.len: inc i
        w.add cmd[i]
        inc i
      inWord = true
    of '\\':
      if i + 1 < cmd.len:
        inc i
        w.add cmd[i]
        inWord = true
    else:
      w.add c
      inWord = true
    inc i
  endCmd()

proc runsProjectCode(argv: seq[string], depth = 0): bool =
  ## does this command run a folder's code — the Nim compiler, nimble, nimsuggest … (not just `nim --version`)?
  if argv.len == 0 or depth > 3: return false
  var cmds: seq[seq[string]]
  if extractFilename(argv[0]) in ["sh", "bash", "dash", "zsh", "ash"] and argv.len >= 3 and argv[1] == "-c":
    cmds = shellCommands(argv[2])
  else: cmds = @[argv]
  for ws0 in cmds:
    var ws = ws0
    # past variable settings and wrappers: LC_ALL=C nim …, env X=1 nim …, timeout 5 nim …, nice -n 5 nim …
    while ws.len > 0:
      let a = ws[0]
      let eq = a.find('=')
      if eq > 0 and a[0 ..< eq].allCharsInSet(IdentChars): ws.delete(0)
      elif a in ["env", "exec", "nohup", "command", "time", "stdbuf", "nice", "ionice", "timeout", "cd"]:
        ws.delete(0)
        while ws.len > 0 and (ws[0].startsWith("-") or ws[0].allCharsInSet(Digits + {'.', 's'})): ws.delete(0)
        if a == "cd" and ws.len > 0: ws.delete(0)          # (cd's folder)
      else: break
    if ws.len == 0: continue
    let prog = extractFilename(ws[0])
    if prog in CodeTools:
      if ws.len >= 2 and ws[1] in ["--version", "-v", "--help", "-h", "--fullhelp"]: continue
      return true
    if prog in ["sh", "bash", "dash", "zsh", "ash"] and ws.len >= 3 and ws[1] == "-c" and
       runsProjectCode(@[prog, "-c", ws[2]], depth + 1):
      return true
  false

when not defined(windows):
  proc c_setpriority(which, who, prio: cint): cint {.importc: "setpriority", header: "<sys/resource.h>".}
when defined(linux) or defined(android):
  type CSchedParam {.importc: "struct sched_param", header: "<sched.h>".} = object
    sched_priority: cint
  proc c_sched_setscheduler(pid: cint, policy: cint, p: ptr CSchedParam): cint {.importc: "sched_setscheduler",
    header: "<sched.h>".}

proc spawnProc(argv: seq[string], cwd: string, sin = siNull, serr = erMerge, niceness = 0): Proc =
  ## starts `argv` (PATH lookup) in its own session and process group; raises OSError on failure — and when it would
  ## run the code of a folder you have not trusted (security.folderTrust). `niceness`: how much it yields the CPU
  ## (background checks, language servers: ned and your terminal first — on a phone that is what keeps it smooth)
  result = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)
  if argv.len == 0: raise newException(OSError, "empty command")
  if cfgFolderTrust == "ask" and runsProjectCode(argv):
    var where = if cwd.len > 0: cwd else: getCurrentDir()
    if (where.startsWith(privDir()) or where.startsWith(getTempDir())) and not codeTrusted(where):
      where = if rootDir.len > 0: rootDir else: where        # (a private copy of the text: the project's)
    if not codeTrusted(where):
      askTrust(where)
      raise newException(OSError, TrustRefusal & " " & where)
  when defined(windows):
    # CreateProcess: its output (and errors) on pipes, its input a pipe or nothing; `sh -c` through Git for
    # Windows' sh (or cmd.exe); a lower priority class for niceness
    let errMode = case serr
                  of erMerge: 0
                  of erPipe: 1
                  of erNull: 2
    let w = winSpawn(argv, cwd, sin == siPipe, errMode, niceness)
    result.pid = w.pid
    result.inFd = w.inFd
    result.outFd = w.outFd
    result.errFd = w.errFd
    return
  else:
    var pin, pout, perr: array[0..1, cint]
    pin = [-1.cint, -1]
    perr = [-1.cint, -1]
    if pipe(pout) != 0: raise newException(OSError, "pipe() failed")
    if sin == siPipe and pipe(pin) != 0: raise newException(OSError, "pipe() failed")
    if serr == erPipe and pipe(perr) != 0: raise newException(OSError, "pipe() failed")
    for fd in [pin[0], pin[1], pout[0], pout[1], perr[0], perr[1]]:
      if fd >= 0: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    let devnull = posix.open("/dev/null", O_RDWR)
    let args = allocCStringArray(argv)
    let ccwd: cstring = cwd
    let pid = fork()
    if pid < 0:
      deallocCStringArray(args)
      raise newException(OSError, "fork() failed")
    if pid == 0:
      # child: only async-signal-safe calls from here on. A session of its own (and a process group): no
      # controlling terminal, so nothing it starts (a debugger's launcher …) can take ned's terminal away
      if setsid() < 0: discard setpgid(0, 0)
      signal(SIGPIPE, SIG_DFL)
      signal(SIGQUIT, SIG_DFL)          # (ned ignores it; what it starts must not)
      discard dup2((if sin == siPipe: pin[0] else: devnull), 0)
      discard dup2(pout[1], 1)
      case serr
      of erMerge: discard dup2(pout[1], 2)
      of erPipe: discard dup2(perr[1], 2)
      of erNull: discard dup2(devnull, 2)
      if cwd.len > 0: discard chdir(ccwd)
      if niceness > 0: discard c_setpriority(0, 0, niceness.cint)     # (PRIO_PROCESS, this process)
      when defined(linux) or defined(android):
        # (the compiler's checks and other work no one waits for: only when the core is idle — on one core, nice 10
        # still took the editor's core in the middle of a frame)
        if niceness >= 10:
          var sp = CSchedParam(sched_priority: 0)
          discard c_sched_setscheduler(0, 5, addr sp)                 # SCHED_IDLE
      discard execvp(args[0], args)
      exitnow(127)
    deallocCStringArray(args)
    if devnull >= 0: discard posix.close(devnull)
    if pin[0] >= 0: discard posix.close(pin[0])
    discard posix.close(pout[1])
    if perr[1] >= 0: discard posix.close(perr[1])
    result.pid = pid
    result.inFd = pin[1]
    result.outFd = pout[0]
    result.errFd = perr[0]

proc reap(p: var Proc): bool =
  ## non-blocking: true once the process has exited (exit code in p.code)
  if p.exited or p.pid <= 0: return true
  var status: cint
  let r = waitpid(p.pid, status, WNOHANG)
  if r == p.pid:
    p.exited = true
    p.code = if WIFEXITED(status): WEXITSTATUS(status).int
             elif WIFSIGNALED(status): 128 + WTERMSIG(status).int
             else: 1
  elif r < 0:
    p.exited = true
    p.code = -1
  p.exited

proc killProc(p: var Proc, sig = SIGTERM) =
  ## sends the signal (SIGTERM unless told) to the process's group, so everything a build or run started stops, or to
  ## the process alone when that fails; does nothing once it has exited
  if p.pid > 0 and not p.exited:
    if posix.kill(Pid(-p.pid), sig) != 0: discard posix.kill(p.pid, sig)

var reapPids: seq[Pid]           # stopped helpers (a debugger, its adapter) still to be waited for

proc reapSoon(pid: Pid) =
  ## notes a stopped helper's pid to be waited for by `reapPending` (once)
  if pid > 0 and pid notin reapPids: reapPids.add pid

proc reapPending() =
  ## wait for ended helpers without blocking, so none is left behind as a zombie
  var i = 0
  while i < reapPids.len:
    var st: cint
    let r = waitpid(reapPids[i], st, WNOHANG)
    if r != 0: reapPids.delete(i) else: inc i

proc waitProc(p: var Proc, timeoutMs = 2000): int =
  ## waits for the process to end, looking every 3 ms, and returns its exit code; after `timeoutMs` it is killed with
  ## SIGKILL and the code is 137
  let t0 = getMonoTime()
  while not p.reap():
    if msSince(t0) > timeoutMs:
      killProc(p, SIGKILL)
      var status: cint
      discard waitpid(p.pid, status, 0)
      p.exited = true
      p.code = 137
      break
    os.sleep(3)
  p.code

func closeProc(p: var Proc) =
  ## closes the process's input, output and error pipes
  closeFd(p.inFd)
  closeFd(p.outFd)
  closeFd(p.errFd)

proc jobChunk(j: Job, chunk: string)

proc checkSlots(): int =
  ## how many checks — compilers, most of them: the on-save check, the one while typing, a test on save — run at once:
  ## two, one when the device is short of memory (each can take the size of the whole program; nine at once closed
  ## Termux on a phone)
  if lowMemory: 1 else: 2

proc checksRunning(): int =
  ## the checks running now (not those waiting for their turn)
  for j in jobs:
    if j.kind == jkCheck and not j.done and not j.queued and not j.eof: inc result

proc startQueuedChecks() =
  ## starts the checks waiting for their turn, oldest first, while there is room (a check that cannot start ends at once
  ## with code 127, so whoever waits for it hears)
  var room = checkSlots() - checksRunning()
  if room <= 0: return
  for j in jobs:
    if room <= 0: break
    if not j.queued or j.done: continue
    j.queued = false
    j.started = getMonoTime()
    try:
      var p = spawnProc(@["sh", "-c", j.qRun], j.cwd, siNull, erMerge, j.qNice)
      j.outFd = p.outFd
      p.outFd = -1
      j.pr = p
      setNonBlock(j.outFd)
      dec room
    except CatchableError as e:
      j.pr = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1, exited: true, code: 127)
      j.eof = true
      j.output.add "ned: cannot start: " & e.msg & "\n"

proc startJob(kind: JobKind, cmd, cwd: string, onDone: proc(j: Job) {.closure.} = nil): Job =
  ## starts a shell command as a background job of the given kind, in a folder, with its output (errors merged in) read
  ## without blocking and `onDone` called when it ends. Check and auxiliary jobs run at a lower priority than ned (kind
  ## decides), and git of a remote folder is wrapped to run on the server. A folder that is not trusted gives a job that
  ## has already ended with code 126 and says why in its output; any other failure is reported and gives nil. A check
  ## beyond checkSlots waits for its turn (started by startQueuedChecks when one ends)
  # git for a remote folder runs on the server (its repository is the real one)
  let run = if remotes.len > 0 and (kind == jkGit or cmd.startsWith("git ")): gitWrap(cmd, cwd) else: cmd
  try:
    # (background work yields the CPU to ned and the terminal; what you run yourself does not)
    let niceness = case kind
                   of jkRun: 0
                   of jkCheck, jkAux: 10
                   else: 5
    if kind == jkCheck and checksRunning() >= checkSlots() and codeTrusted(cwd):
      result = Job(kind: kind, pr: Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1), outFd: -1, errFd: -1,
                   started: getMonoTime(), cmd: cmd, cwd: cwd, onDone: onDone, queued: true, qRun: run,
                   qNice: niceness)
      jobs.add result
      return
    var p = spawnProc(@["sh", "-c", run], cwd, siNull, erMerge, niceness)
    let fd = p.outFd
    p.outFd = -1
    result = Job(kind: kind, pr: p, outFd: fd, errFd: -1, started: getMonoTime(),
                 cmd: cmd, cwd: cwd, onDone: onDone)
    setNonBlock(result.outFd)
    jobs.add result
  except CatchableError as e:
    if e.msg.startsWith(TrustRefusal):
      # an untrusted folder (askTrust said so): a job that ended at once, so whoever waits for it hears why
      result = Job(kind: kind, pr: Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1, exited: true, code: 126),
                   outFd: -1, errFd: -1, eof: true, started: getMonoTime(), cmd: cmd, cwd: cwd, onDone: onDone)
      jobs.add result
      jobChunk(result, "ned " & e.msg & " — palette › Workspace: trust this folder\n")
    else:
      error("Cannot start: " & e.msg)
      result = nil

func stripAnsi(s: string): string =
  ## the string without terminal escape sequences: those starting `ESC [` up to their final letter, `ESC ]` up to a bell
  ## or `ESC \`, and any other escape with the character after it
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len:
      if s[i+1] == '[':
        var j = i + 2
        while j < s.len and s[j] notin {'@'..'~'}: inc j
        i = j + 1
        continue
      if s[i+1] == ']':
        var j = i + 2
        while j < s.len and s[j] != '\a' and not (s[j] == '\e' and j + 1 < s.len and s[j+1] == '\\'): inc j
        i = j + (if j < s.len and s[j] == '\a': 1 else: 2)
        continue
      i += 2
      continue
    result.add s[i]
    inc i

proc resolvePath(p, cwd: string): string =
  ## the full path of an existing file named by `p` (relative to `cwd` when it is not absolute), or "" when there is no
  ## such file, or the name is empty or over 1000 bytes
  if p.len == 0 or p.len > 1000: return ""
  let q = if p.isAbsolute: p else: cwd / p
  if fileExists(q): normalizedPath(q) else: ""

# true for a string that has digits only (and is not empty)
func allDigits(s: string): bool = s.len > 0 and s.allCharsInSet(Digits)
