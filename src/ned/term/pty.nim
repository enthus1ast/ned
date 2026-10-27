# ════════════════════════════════════════════════════════════════════════════
#  Integrated terminal: pseudo-terminal + xterm-subset emulator
# ════════════════════════════════════════════════════════════════════════════

when not defined(windows):   # (Windows: a pseudo-console — see sys/winposix's winPtySpawn)
  var
    TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong
    TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

  # the portable POSIX pseudo-terminal calls (Linux, Android/Termux, macOS, the BSDs); Nim declares them itself
  proc posix_openpt(flags: cint): cint {.importc, cdecl.}
  proc grantpt(fd: cint): cint {.importc, cdecl.}
  proc unlockpt(fd: cint): cint {.importc, cdecl.}
  proc ptsname(fd: cint): cstring {.importc, cdecl.}

  proc ptyOpen(): (cint, string) =
    ## a pseudo-terminal: the fd of ned's side and the name of the shell's ((-1, "") when there is none)
    let fd = posix_openpt(O_RDWR or O_NOCTTY)
    if fd < 0: return (-1.cint, "")
    let pn = if grantpt(fd) == 0 and unlockpt(fd) == 0: ptsname(fd) else: nil
    if pn == nil:
      discard posix.close(fd)
      return (-1.cint, "")
    (fd, $pn)

  proc ptyExec(fd: cint, slave, cwd: string, env: seq[(string, string)], argv: seq[string]) =
    ## (in the child, after fork) become the shell on the pseudo-terminal's other side; never returns
    discard setsid()
    let s = posix.open(cstring(slave), O_RDWR)
    if s < 0: exitnow(127)
    discard ioctl(s, TIOCSCTTY, 0)
    discard dup2(s, 0)
    discard dup2(s, 1)
    discard dup2(s, 2)
    if s > 2: discard posix.close(s)
    discard posix.close(fd)
    putEnv("TERM", "xterm-256color")
    putEnv("COLORTERM", "truecolor")
    putEnv("TERM_PROGRAM", "ned")
    if getEnv("LANG").len == 0 and getEnv("LC_ALL").len == 0:
      putEnv("LANG", (when defined(macosx): "en_US.UTF-8" else: "C.UTF-8"))
    signal(SIGPIPE, SIG_DFL)          # ned ignores it; the shell and its pipes (`yes | head`) must not
    signal(SIGQUIT, SIG_DFL)          # … and Ctrl+\ quits programs in the terminal again
    signal(SIGHUP, SIG_DFL)           # (a term host ignores it: the shell must not)
    if cwd.len > 0: discard chdir(cstring(cwd))
    for (k, v) in env: putEnv(k, v)
    discard execvp(cstring(argv[0]), allocCStringArray(argv))
    exitnow(127)

type
  TCell = object
    ch: uint32
    fg, bg: Rgb
    at: set[Attr]
  TRow = seq[TCell]
  PState = enum psGround, psEsc, psCsi, psOsc, psStr, psCharset, psHash
  TermCmd = object
    ## one command the shell ran, from its OSC 133 marks; rows are "global": scrollback rows ever dropped + row
    promptRow, inputRow, inputCol, outRow, endRow: int
    text: string
    code: int                # exit code (-1: unknown or still running)
    ran: bool                # Enter was pressed (OSC 133;C)
    started, ended: MonoTime
  Term = ref object
    pid: Pid
    fd: cint
    w, h: int
    scr: seq[TRow]
    mainSaved: seq[TRow]
    altActive: bool
    sb: seq[TRow]
    cx, cy: int
    sx, sy: int
    sFg, sBg: Rgb
    sAt: set[Attr]
    fg, bg: Rgb
    at: set[Attr]
    top, bot: int
    wrapPending, autoWrap, cursorVisible, appCursor, bracketed, insertMode, originMode: bool
    lineDraw, g1Line, shiftOut: bool
    mouseMode: int        # 0 off, 1000, 1002, 1003
    sgrMouse: bool
    st: PState
    params: string
    inter: string
    osc: string
    utf: string
    lastCh: uint32
    title: string
    dead: bool
    code: int
    view: int             # lines scrolled back (0 = live)
    reply: string
    name: string
    selA, selB: (int, int)   # (absolute row, col)
    hasSel: bool
    gotOutput: bool
    pending: string          # typed into the shell once its prompt appears
    replLang, replCmd: string  # a REPL tab (Send to REPL): its language and the command it runs instead of a shell
    replQ: seq[string]       # code sent before the REPL showed its prompt
    replAt: MonoTime
    sbDropped: int           # scrollback rows dropped from the top so far
    cmds: seq[TermCmd]       # commands seen through shell integration
    navCmd: int              # the command Ctrl+↑/↓ went to (-1: none)
    integrated: bool         # the shell sends OSC 133 marks
    hosted: bool             # terminal.keepRunning: the shell is a term host's (see termhost), fd its socket
    hostId: string
    inBuf: string            # … what came from it, not yet a whole message
    paneId: int              # (6.32) a terminal in a pane of the editor (its tab's), not the panel's: > 0

var
  terms: seq[Term]
  curTerm = 0
  termSelecting = false
  termRect: tuple[x, y, w, h: int]
  termPanes: seq[tuple[idx: int, r: tuple[x, y, w, h: int], gut: int]]   # the terminals on screen (two when split)
  termSplit = false            # two terminals side by side
  termForPane = -1             # (6.32) a pane's terminal, while keys go to it: curTermObj answers it
  termPaneCursor = false       # (… while it is drawn, the active pane: its cursor shown)
  termOther = -1               # … the one that is not curTerm

func blankCell(t: Term): TCell = TCell(ch: 32, fg: NoColor, bg: t.bg)
proc blankRow(t: Term): TRow =
  result = newSeq[TCell](t.w)
  let c = t.blankCell
  for i in 0 ..< t.w: result[i] = c

proc termShell(): string =
  if cfgTermShell.len > 0: return cfgTermShell
  when defined(windows):
    for c in ["pwsh", "powershell"]:
      let p = findExe(c)
      if p.len > 0: return p
    return getEnv("ComSpec", "cmd.exe")
  let s = getEnv("SHELL")
  if s.len > 0 and fileExists(s): return s
  for c in ["bash", "zsh", "fish", "sh"]:
    let p = findExe(c)
    if p.len > 0: return p
  "/bin/sh"

proc hostFrame(kind: char, payload: string): string =
  ## one message between ned and a term host (see termhost): its kind, its length (4 bytes, big-endian), its bytes
  let n = payload.len
  kind & char((n shr 24) and 255) & char((n shr 16) and 255) & char((n shr 8) and 255) & char(n and 255) & payload

proc hostTake(buf: string, at: var int, kind: var char, payload: var string): bool =
  ## the whole message in `buf` at `at`, `at` moved past it (false: none yet). (The caller drops what was taken
  ## once, at the end: a megabyte of output in 64 KB messages is not copied sixteen times over.)
  if buf.len - at < 5: return false
  let n = (ord(buf[at + 1]) shl 24) or (ord(buf[at + 2]) shl 16) or (ord(buf[at + 3]) shl 8) or ord(buf[at + 4])
  if buf.len - at < 5 + n: return false
  kind = buf[at]
  payload = buf[at + 5 ..< at + 5 + n]
  at += 5 + n
  true

proc hostTake(buf: var string, kind: var char, payload: var string): bool =
  ## the first whole message in `buf`, taken off it (false: none yet)
  var at = 0
  result = hostTake(buf, at, kind, payload)
  if result: buf = buf[at .. ^1]

proc hostSend(t: Term, kind: char, payload: string) =
  ## one message to the term host of a kept terminal
  if t.fd < 0: return
  let s = hostFrame(kind, payload)
  var off = 0
  var tries = 0
  while off < s.len and tries < 2000:
    let w = posix.write(t.fd, unsafeAddr s[off], s.len - off)
    if w > 0: off += w
    elif errno in [EAGAIN, EINTR]:
      inc tries
      os.sleep(1)
    else: break

proc setWinSize(t: Term) =
  if t.fd < 0: return
  if t.hosted:
    t.hostSend('r', $t.w & " " & $t.h)
    return
  var ws: IOctl_WinSize
  ws.ws_row = uint16(t.h)
  ws.ws_col = uint16(t.w)
  discard ioctl(t.fd, TIOCSWINSZ, addr ws)
