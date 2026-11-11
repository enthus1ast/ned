# ── (6.45) when ned itself fails — a fault the program cannot go on from (SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT:
#    a bug, a stack too deep, memory gone bad) — the terminal is given back as ned found it (its own screen, the
#    mouse and paste modes off, scrolling back), a note says what ned was doing, and the next start says so: the
#    unsaved edits are in the recovery files, which it offers as after any other end. Before, the terminal stayed in
#    ned's modes — no scrolling, mouse codes typed into the shell — and nothing said why. Not on Windows ──

when not defined(windows):
  const CrashReset = "\e[?2026l\e]22;default\a\e[<u\e[?2027l\e[?2031l" & MouseOffSeq &
                     "\e[?1004l\e[?2004l\e[0m\e[0 q\e[?7h\e[?25h\e[?1049l\e[23;0t"   # (leaveRaw's, all at once)

  var
    crashNotePath: string            # (made once: the handler may not allocate)
    crashAltStack: seq[byte]         # (the handler's own stack: a stack too deep has no room left for it)

  proc crashPut(fd: cint, s: cstring) =
    ## (in the handler) writes a C string: nothing that allocates
    discard posix.write(fd, cast[pointer](s), s.len)

  proc crashPutWork(fd: cint) =
    ## (in the handler) what ned was doing, from the outermost to the innermost: "a › b"
    for d in 0 .. min(crashDepth, crashWork.high):
      if crashWorkLen[d] > 0:
        if d > 0: crashPut(fd, " › ")
        discard posix.write(fd, addr crashWork[d][0], crashWorkLen[d])

  proc onCrash(sig: cint) {.noconv.} =
    ## the handler of a fatal signal (on its own stack): the terminal given back, the note written, then the signal
    ## again with the system's own handling (the program ends as it would have). Only calls safe in a signal handler
    let name: cstring = (if sig == SIGSEGV: "SIGSEGV (memory out of bounds)" elif sig == SIGBUS: "SIGBUS (memory)"
                         elif sig == SIGFPE: "SIGFPE (arithmetic)" elif sig == SIGILL: "SIGILL (bad instruction)"
                         elif sig == SIGABRT: "SIGABRT (aborted)" else: "a fatal signal")
    if gRaw:
      crashPut(1, CrashReset)
      discard tcSetAttr(0, TCSANOW, addr gOrigTerm)
      gRaw = false
    if crashNotePath.len > 0:
      let fd = posix.open(crashNotePath.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
      if fd >= 0:
        crashPut(fd, name)
        crashPut(fd, "\n")
        crashPutWork(fd)
        crashPut(fd, "\n")
        discard posix.close(fd)
    crashPut(2, "\r\nned stopped: ")
    crashPut(2, name)
    if crashDepth >= 0:
      crashPut(2, ", while: ")
      crashPutWork(2)
    crashPut(2, ".\r\nYour unsaved changes are kept: ned offers them when it starts again.\r\n")
    discard posix.signal(sig, SIG_DFL)
    discard posix.kill(getpid(), sig)

  proc crashGuard() =
    ## (at start) the fatal signals handled by onCrash, on a stack of its own, its note's path made ahead
    try:
      privateDir(stateDir())
      crashNotePath = stateDir() / "crash.txt"
    except CatchableError: crashNotePath = ""
    crashAltStack = newSeq[byte](64 * 1024)
    var ss = Stack(ss_sp: addr crashAltStack[0], ss_size: crashAltStack.len, ss_flags: 0)
    var old: Stack
    discard sigaltstack(ss, old)
    var sa: Sigaction
    sa.sa_handler = onCrash
    sa.sa_flags = SA_ONSTACK or SA_RESETHAND
    discard sigemptyset(sa.sa_mask)
    for s in [SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT]: discard sigaction(s, sa, nil)

  proc crashNoted(): string =
    ## (at start) what the note of a crash last time says — signal, then what ned was doing — and the note goes
    ## (written to errors.log first, with the version); "" when there is none
    let p = stateDir() / "crash.txt"
    if not fileExists(p): return ""
    try:
      let ls = readFile(p).splitLines
      removeFile(p)
      result = ls[0].strip
      if ls.len > 1 and ls[1].strip.len > 0: result.add ", while: " & ls[1].strip
      let log = stateDir() / "errors.log"
      let f = open(log, fmAppend)
      f.writeLine(times.now().format("yyyy-MM-dd HH:mm:ss") & " ned " & Version & " stopped: " & result)
      f.close()
    except CatchableError: discard

else:
  proc crashGuard() =
    ## (Windows: its own error reporting does this)
    discard

  proc crashNoted(): string =
    ## (Windows: no note is written)
    ""
