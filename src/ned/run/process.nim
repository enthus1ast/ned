# ════════════════════════════════════════════════════════════════════════════
#  Background jobs: run/build, checks, git
# ════════════════════════════════════════════════════════════════════════════

proc setNonBlock(fd: cint) =
  if fd >= 0: discard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK)

# ── Child processes ───────────────────────────────────────────────────────────
# A small fork/exec layer instead of std/osproc: Termux's bionic has no posix_spawn on
# older Android versions, and own process groups let us stop a whole build/run tree.

type
  StdinMode = enum siNull, siPipe
  ErrMode = enum erMerge, erPipe, erNull

proc csystem(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}

proc closeFd(fd: var cint) =
  if fd >= 0:
    discard posix.close(fd)
    fd = -1

proc spawnProc(argv: seq[string], cwd: string, sin = siNull, serr = erMerge): Proc =
  ## starts `argv` (PATH lookup) in its own session and process group; raises OSError on failure
  result = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)
  if argv.len == 0: raise newException(OSError, "empty command")
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
  if p.pid > 0 and not p.exited:
    if posix.kill(Pid(-p.pid), sig) != 0: discard posix.kill(p.pid, sig)

var reapPids: seq[Pid]           # stopped helpers (a debugger, its adapter) still to be waited for

proc reapSoon(pid: Pid) =
  if pid > 0 and pid notin reapPids: reapPids.add pid

proc reapPending() =
  ## wait for ended helpers without blocking, so none is left behind as a zombie
  var i = 0
  while i < reapPids.len:
    var st: cint
    let r = waitpid(reapPids[i], st, WNOHANG)
    if r != 0: reapPids.delete(i) else: inc i

proc waitProc(p: var Proc, timeoutMs = 2000): int =
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

proc closeProc(p: var Proc) =
  closeFd(p.inFd)
  closeFd(p.outFd)
  closeFd(p.errFd)

proc startJob(kind: JobKind, cmd, cwd: string, onDone: proc(j: Job) {.closure.} = nil): Job =
  # git for a remote folder runs on the server (its repository is the real one)
  let run = if remotes.len > 0 and (kind == jkGit or cmd.startsWith("git ")): gitWrap(cmd, cwd) else: cmd
  try:
    var p = spawnProc(@["sh", "-c", run], cwd, siNull, erMerge)
    let fd = p.outFd
    p.outFd = -1
    result = Job(kind: kind, pr: p, outFd: fd, errFd: -1, started: getMonoTime(),
                 cmd: cmd, cwd: cwd, onDone: onDone)
    setNonBlock(result.outFd)
    jobs.add result
  except CatchableError as e:
    error("Cannot start: " & e.msg)
    result = nil

proc stripAnsi(s: string): string =
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
  if p.len == 0 or p.len > 1000: return ""
  let q = if p.isAbsolute: p else: cwd / p
  if fileExists(q): normalizedPath(q) else: ""

proc allDigits(s: string): bool = s.len > 0 and s.allCharsInSet(Digits)
