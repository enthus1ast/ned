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

var
  terms: seq[Term]
  curTerm = 0
  termSelecting = false
  termRect: tuple[x, y, w, h: int]
  termPanes: seq[tuple[idx: int, r: tuple[x, y, w, h: int], gut: int]]   # the terminals on screen (two when split)
  termSplit = false            # two terminals side by side
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

proc setWinSize(t: Term) =
  if t.fd < 0: return
  var ws: IOctl_WinSize
  ws.ws_row = uint16(t.h)
  ws.ws_col = uint16(t.w)
  discard ioctl(t.fd, TIOCSWINSZ, addr ws)
