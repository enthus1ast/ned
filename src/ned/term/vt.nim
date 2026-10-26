proc blankTerm(w, h: int): Term =
  ## a terminal with nothing in it yet (and no shell)
  result = Term(w: max(10, w), h: max(2, h), fd: -1, autoWrap: true, cursorVisible: true, fg: NoColor, bg: NoColor,
                navCmd: -1)
  result.top = 0
  result.bot = result.h - 1
  for _ in 0 ..< result.h: result.scr.add result.blankRow

proc hostStart(t: Term, cwd: string, env: seq[(string, string)], argv: seq[string]): bool

proc newTerm(w, h: int, cwd: string, cmd = "", keep = false): Term =
  ## a terminal running the user's shell, or `cmd` (a REPL) through sh; `keep`: a shell that may outlive this ned
  ## (terminal.keepRunning — see termhost)
  let t = blankTerm(w, h)
  let shell = if cmd.len > 0: (let sh = findExe("sh"); if sh.len > 0: sh else: "/bin/sh") else: termShell()
  t.name = extractFilename(shell)
  t.replCmd = cmd
  t.replAt = getMonoTime()
  when defined(windows):
    # a pseudo-console (ConPTY): the shell, or `cmd` through sh (Git for Windows') or cmd.exe
    let (siArgs, siEnv) = if cmd.len == 0: shellIntegration(shell) else: (@[], @[])
    let env = @[("TERM", "xterm-256color"), ("COLORTERM", "truecolor"), ("TERM_PROGRAM", "ned")] & siEnv
    let argv = if cmd.len > 0: @["sh", "-c", cmd] else: @[shell] & siArgs
    let r = winPtySpawn(argv, cwd, t.w, t.h, env)
    if r.fd < 0:
      t.dead = true
      t.title = r.err
      return t
    t.fd = r.fd
    t.pid = r.pid
    t
  else:
    let (siArgs, siEnv) = if cmd.len == 0: shellIntegration(shell) else: (@[], @[])
    # terminal.editorEnv: this ned is git's editor here (and EDITOR, VISUAL where they are not set) — `git commit`
    # opens its message in a tab and waits for it (see control)
    var edEnv: seq[(string, string)]
    if cfgEditorEnv and getEnv("NED_SOCKET").len > 0:
      let me = quoteShell(getAppFilename()) & " --wait"
      if getEnv("GIT_EDITOR").len == 0: edEnv.add ("GIT_EDITOR", me)
      for v in ["EDITOR", "VISUAL"]:
        if getEnv(v).len == 0: edEnv.add (v, me)
    let argv = if cmd.len > 0: @[shell, "-c", "exec " & cmd] else: @[shell] & siArgs
    if keep and cmd.len == 0 and cfgTermKeep and t.hostStart(cwd, siEnv & edEnv, argv):
      return t                            # (else a shell of this ned's own, as before)
    let (fd, slave) = ptyOpen()
    if fd < 0:
      t.dead = true
      t.title = "cannot open a pseudo-terminal"
      return t
    t.fd = fd
    t.setWinSize()
    let pid = fork()
    if pid == 0: ptyExec(fd, slave, cwd, siEnv & edEnv, argv)
    t.pid = pid
    let fl = fcntl(fd, F_GETFL)
    discard fcntl(fd, F_SETFL, fl or O_NONBLOCK)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    t

proc ansiColor(n: int): Rgb =
  if n < 16: return theme.ansi[n]
  if n < 232:
    let v = n - 16
    let lv = [0, 95, 135, 175, 215, 255]
    return Rgb((lv[v div 36] shl 16) or (lv[(v div 6) mod 6] shl 8) or lv[v mod 6])
  let g = 8 + (n - 232) * 10
  Rgb((g shl 16) or (g shl 8) or g)

proc trimScrollback(t: Term) =
  ## the oldest lines past terminal.scrollback, dropped a chunk at a time: one shift of the scrollback per chunk
  ## (it used to shift all of it for every new line — a flood of output, 200 000 lines, took 1 s with 3000
  ## lines kept and 6 s with 20 000; now about 0.1 s whatever is kept)
  if t.sb.len > cfgTermScrollback + max(64, cfgTermScrollback div 8):
    let n = t.sb.len - cfgTermScrollback
    for i in 0 ..< t.sb.len - n: t.sb[i] = move(t.sb[i + n])
    t.sb.setLen(t.sb.len - n)
    t.sbDropped += n
    t.view = min(t.view, t.sb.len)

proc resize(t: Term, w, h: int) =
  let w = max(10, w)
  let h = max(2, h)
  if w == t.w and h == t.h: return
  proc fit(rows: var seq[TRow], t: Term, w: int) =
    for r in rows.mitems:
      if r.len < w:
        let c = TCell(ch: 32, fg: NoColor, bg: NoColor)
        while r.len < w: r.add c
      elif r.len > w: r.setLen(w)
  t.w = w
  fit(t.scr, t, w)
  if t.mainSaved.len > 0: fit(t.mainSaved, t, w)
  # height: drop lines from the top into scrollback (keeps the cursor line) or add blank rows
  while t.scr.len > h:
    if t.cy > 0 or t.scr.len - 1 > t.cy:
      if t.cy >= h:
        if not t.altActive:
          t.sb.add move(t.scr[0])
          t.trimScrollback()
        t.scr.delete(0)
        dec t.cy
      else: t.scr.setLen(t.scr.len - 1)
    else: t.scr.setLen(t.scr.len - 1)
  while t.scr.len < h: t.scr.add t.blankRow
  t.h = h
  t.top = 0
  t.bot = h - 1
  t.cx = clamp(t.cx, 0, w - 1)
  t.cy = clamp(t.cy, 0, h - 1)
  t.wrapPending = false
  t.setWinSize()

proc scrollUp(t: Term, n = 1) =
  for _ in 0 ..< n:
    if t.top == 0 and not t.altActive:
      t.sb.add move(t.scr[0])                  # (moved, not copied: the row leaves the screen just below)
      t.trimScrollback()
      if t.view > 0: t.view = min(t.view + 1, t.sb.len)
    t.scr.delete(t.top)
    t.scr.insert(t.blankRow, t.bot)

proc scrollDown(t: Term, n = 1) =
  for _ in 0 ..< n:
    t.scr.delete(t.bot)
    t.scr.insert(t.blankRow, t.top)

proc lineFeed(t: Term) =
  if t.cy == t.bot: t.scrollUp()
  elif t.cy < t.h - 1: inc t.cy

const DecLine = [("j", "┘"), ("k", "┐"), ("l", "┌"), ("m", "└"), ("n", "┼"), ("q", "─"), ("t", "├"), ("u", "┤"),
                 ("v", "┴"), ("w", "┬"), ("x", "│"), ("a", "▒"), ("`", "◆"), ("f", "°"), ("g", "±"), ("~", "·"),
                 ("o", "⎺"), ("s", "⎽"), ("y", "≤"), ("z", "≥"), ("{", "π"), ("|", "≠"), ("}", "£")]

proc putChar(t: Term, cp0: int) =
  var cp = cp0
  if (t.lineDraw and not t.shiftOut) or (t.g1Line and t.shiftOut):
    if cp < 128:
      for (a, b) in DecLine:
        if a[0] == char(cp):
          cp = runeAt(b, 0)[0]
          break
  let cw = runeWidth(cp)
  if cw == 0:
    return
  if t.wrapPending:
    if t.autoWrap:
      t.cx = 0
      t.lineFeed()
    t.wrapPending = false
  if t.cx + cw > t.w:
    if t.autoWrap:
      t.cx = 0
      t.lineFeed()
    else: t.cx = t.w - cw
  if t.insertMode:
    for _ in 0 ..< cw:
      t.scr[t.cy].insert(t.blankCell, t.cx)
      t.scr[t.cy].setLen(t.w)
  t.scr[t.cy][t.cx] = TCell(ch: uint32(cp), fg: t.fg, bg: t.bg, at: t.at)
  if cw == 2 and t.cx + 1 < t.w: t.scr[t.cy][t.cx + 1] = TCell(ch: 0, fg: t.fg, bg: t.bg, at: t.at)
  t.lastCh = uint32(cp)
  if t.cx + cw >= t.w: t.wrapPending = true
  else: t.cx += cw

proc eraseCells(t: Term, row, a, b: int) =
  if row < 0 or row >= t.h: return
  let c = t.blankCell
  for x in max(0, a) .. min(t.w - 1, b): t.scr[row][x] = c

proc csiParams(t: Term): seq[int] =
  if t.params.len == 0: return @[]
  for p in t.params.split(';'):
    let q = p.split(':')[0]
    result.add (if q.len == 0: 0 else: (try: parseInt(q) except ValueError: 0))

proc sgr(t: Term, ps: seq[int]) =
  var ps = ps
  if ps.len == 0: ps = @[0]
  var i = 0
  while i < ps.len:
    let p = ps[i]
    case p
    of 0:
      t.fg = NoColor
      t.bg = NoColor
      t.at = {}
    of 1: t.at.incl aBold
    of 2: t.at.incl aDim
    of 3: t.at.incl aItalic
    of 4: t.at.incl aUnder
    of 7: t.at.incl aRev
    of 9: t.at.incl aStrike
    of 29: t.at.excl aStrike
    of 22: t.at = t.at - {aBold, aDim}
    of 23: t.at.excl aItalic
    of 24: t.at.excl aUnder
    of 27: t.at.excl aRev
    of 30..37: t.fg = ansiColor(p - 30)
    of 39: t.fg = NoColor
    of 40..47: t.bg = ansiColor(p - 40)
    of 49: t.bg = NoColor
    of 90..97: t.fg = ansiColor(p - 90 + 8)
    of 100..107: t.bg = ansiColor(p - 100 + 8)
    of 38, 48:
      var c = NoColor
      if i + 2 < ps.len and ps[i + 1] == 5:
        c = ansiColor(clamp(ps[i + 2], 0, 255))
        i += 2
      elif i + 4 < ps.len and ps[i + 1] == 2:
        c = Rgb((clamp(ps[i + 2], 0, 255) shl 16) or (clamp(ps[i + 3], 0, 255) shl 8) or clamp(ps[i + 4], 0, 255))
        i += 4
      if p == 38: t.fg = c else: t.bg = c
    else: discard
    inc i

proc setMode(t: Term, ps: seq[int], on: bool) =
  let priv = t.inter.contains('?')
  for p in ps:
    if priv:
      case p
      of 1: t.appCursor = on
      of 6:
        t.originMode = on
        t.cx = 0
        t.cy = if on: t.top else: 0
      of 7: t.autoWrap = on
      of 25: t.cursorVisible = on
      of 47, 1047, 1049:
        if on and not t.altActive:
          if p == 1049:
            t.sx = t.cx
            t.sy = t.cy
          t.mainSaved = t.scr
          t.scr.setLen(0)
          for _ in 0 ..< t.h: t.scr.add t.blankRow
          t.altActive = true
        elif not on and t.altActive:
          t.scr = t.mainSaved
          t.mainSaved.setLen(0)
          t.altActive = false
          if p == 1049:
            t.cx = clamp(t.sx, 0, t.w - 1)
            t.cy = clamp(t.sy, 0, t.h - 1)
        t.top = 0
        t.bot = t.h - 1
      of 1000, 1002, 1003: t.mouseMode = if on: p else: 0
      of 1006: t.sgrMouse = on
      of 2004: t.bracketed = on
      else: discard
    else:
      if p == 4: t.insertMode = on

proc doCsi(t: Term, fin: char) =
  let ps = t.csiParams()
  proc arg(i: int, def = 1): int = (if i < ps.len and ps[i] > 0: ps[i] else: def)
  t.wrapPending = false
  if t.inter.len > 0 and t.inter[0] notin {'?', '>', '='}:
    # intermediates like ' ' (DECSCUSR) or '!' (DECSTR)
    if t.inter == "!" and fin == 'p':
      t.at = {}
      t.fg = NoColor
      t.bg = NoColor
      t.top = 0
      t.bot = t.h - 1
      t.autoWrap = true
      t.cursorVisible = true
      t.appCursor = false
      t.insertMode = false
    return
  case fin
  of '@':
    for _ in 0 ..< arg(0):
      t.scr[t.cy].insert(t.blankCell, t.cx)
    t.scr[t.cy].setLen(t.w)
  of 'A': t.cy = max(if t.cy >= t.top: t.top else: 0, t.cy - arg(0))
  of 'B', 'e': t.cy = min(if t.cy <= t.bot: t.bot else: t.h - 1, t.cy + arg(0))
  of 'C', 'a': t.cx = min(t.w - 1, t.cx + arg(0))
  of 'D': t.cx = max(0, t.cx - arg(0))
  of 'E':
    t.cy = min(t.h - 1, t.cy + arg(0))
    t.cx = 0
  of 'F':
    t.cy = max(0, t.cy - arg(0))
    t.cx = 0
  of 'G', '`': t.cx = clamp(arg(0) - 1, 0, t.w - 1)
  of 'H', 'f':
    let base = if t.originMode: t.top else: 0
    t.cy = clamp(base + arg(0) - 1, 0, t.h - 1)
    t.cx = clamp(arg(1) - 1, 0, t.w - 1)
  of 'I':
    for _ in 0 ..< arg(0): t.cx = min(t.w - 1, (t.cx div 8 + 1) * 8)
  of 'J':
    case arg(0, 0)
    of 0:
      t.eraseCells(t.cy, t.cx, t.w - 1)
      for r in t.cy + 1 ..< t.h: t.eraseCells(r, 0, t.w - 1)
    of 1:
      for r in 0 ..< t.cy: t.eraseCells(r, 0, t.w - 1)
      t.eraseCells(t.cy, 0, t.cx)
    of 2:
      for r in 0 ..< t.h: t.eraseCells(r, 0, t.w - 1)
      if not t.altActive:
        # the commands shown on the screen are gone with it (`clear`)
        let screenTop = t.sbDropped + t.sb.len
        var keep: seq[TermCmd]
        for c in t.cmds:
          if c.promptRow < screenTop or (c.ran and c.endRow < 0): keep.add c
        t.cmds = keep
        t.navCmd = -1
    of 3:
      t.sbDropped += t.sb.len
      t.sb.setLen(0)
      t.view = 0
      t.navCmd = -1
    else: discard
  of 'K':
    case arg(0, 0)
    of 0: t.eraseCells(t.cy, t.cx, t.w - 1)
    of 1: t.eraseCells(t.cy, 0, t.cx)
    of 2: t.eraseCells(t.cy, 0, t.w - 1)
    else: discard
  of 'L':
    if t.cy >= t.top and t.cy <= t.bot:
      for _ in 0 ..< min(arg(0), t.bot - t.cy + 1):
        t.scr.delete(t.bot)
        t.scr.insert(t.blankRow, t.cy)
  of 'M':
    if t.cy >= t.top and t.cy <= t.bot:
      for _ in 0 ..< min(arg(0), t.bot - t.cy + 1):
        t.scr.delete(t.cy)
        t.scr.insert(t.blankRow, t.bot)
  of 'P':
    for _ in 0 ..< min(arg(0), t.w - t.cx):
      t.scr[t.cy].delete(t.cx)
      t.scr[t.cy].add t.blankCell
  of 'S': t.scrollUp(arg(0))
  of 'T': t.scrollDown(arg(0))
  of 'X': t.eraseCells(t.cy, t.cx, t.cx + arg(0) - 1)
  of 'Z':
    for _ in 0 ..< arg(0): t.cx = max(0, (t.cx - 1) div 8 * 8)
  of 'b':
    if t.lastCh != 0:
      for _ in 0 ..< min(arg(0), 2000): t.putChar(int(t.lastCh))
  of 'c':
    if t.inter == ">": t.reply.add "\e[>0;10;1c"
    elif t.inter.len == 0: t.reply.add "\e[?62;22c"
  of 'd': t.cy = clamp(arg(0) - 1, 0, t.h - 1)
  of 'h': t.setMode(ps, true)
  of 'l': t.setMode(ps, false)
  of 'm':
    if t.inter.len == 0: t.sgr(ps)
  of 'n':
    if arg(0, 0) == 5: t.reply.add "\e[0n"
    elif arg(0, 0) == 6: t.reply.add "\e[" & $(t.cy + 1) & ";" & $(t.cx + 1) & "R"
  of 'r':
    if t.inter.len == 0:
      let a = arg(0) - 1
      let b = (if ps.len > 1 and ps[1] > 0: ps[1] else: t.h) - 1
      if a < b and b < t.h:
        t.top = a
        t.bot = b
        t.cx = 0
        t.cy = if t.originMode: t.top else: 0
  of 's':
    if t.inter.len == 0:
      t.sx = t.cx
      t.sy = t.cy
  of 'u':
    t.cx = clamp(t.sx, 0, t.w - 1)
    t.cy = clamp(t.sy, 0, t.h - 1)
  else: discard

func gRow(t: Term): int = t.sbDropped + t.sb.len + t.cy      # the cursor's row, as a global row

func rowByGlobal(t: Term, g: int): TRow =
  let a = g - t.sbDropped
  if a < 0: return @[]
  if a < t.sb.len: return t.sb[a]
  if a - t.sb.len < t.scr.len: return t.scr[a - t.sb.len]
  @[]

proc rowText(row: TRow, fromCol = 0): string =
  for x in max(0, fromCol) ..< row.len:
    if row[x].ch != 0: result.addUtf8(int(if row[x].ch < 32: 32'u32 else: row[x].ch))
  result = result.strip(leading = false)

proc osc133(t: Term, arg: string) =
  ## shell integration marks: A prompt starts · B the command line starts · C it runs · D;code it ended
  if t.altActive or arg.len == 0: return
  t.integrated = true
  let g = t.gRow
  case arg[0]
  of 'A':
    if t.cmds.len > 0 and not t.cmds[^1].ran:
      t.cmds[^1].promptRow = g                  # an empty Enter: the same command, a new prompt
      t.cmds[^1].inputRow = -1
    else:
      t.cmds.add TermCmd(promptRow: g, inputRow: -1, outRow: -1, endRow: -1, code: -1)
      if t.cmds.len > 500:
        t.cmds.delete(0)
        if t.navCmd >= 0: dec t.navCmd
  of 'B':
    if t.cmds.len > 0 and not t.cmds[^1].ran:
      t.cmds[^1].inputRow = g
      t.cmds[^1].inputCol = t.cx
  of 'C':
    if t.cmds.len > 0 and not t.cmds[^1].ran:
      var c = addr t.cmds[^1]
      c.ran = true
      c.outRow = g
      c.started = getMonoTime()
      # the command line as typed: from where the prompt ended to the line Enter left
      let first = if c.inputRow >= 0: c.inputRow else: c.promptRow
      var txt = ""
      for r in first ..< max(first + 1, g):
        let row = t.rowByGlobal(r)
        let part = rowText(row, (if r == first and c.inputRow >= 0: c.inputCol else: 0))
        if txt.len > 0: txt.add (if row.len > 0 and row[^1].ch notin [0'u32, 32'u32]: "" else: "\n")
        txt.add part
      c.text = txt.strip
  of 'D':
    if t.cmds.len > 0 and t.cmds[^1].ran and t.cmds[^1].endRow < 0:
      let semi = arg.find(';')
      t.cmds[^1].code = if semi > 0: (try: parseInt(arg[semi + 1 .. ^1].strip) except ValueError: -1) else: -1
      t.cmds[^1].endRow = g
      t.cmds[^1].ended = getMonoTime()
  else: discard

proc feed(t: Term, data: string) =
  var i = 0
  while i < data.len:
    let c = data[i]
    case t.st
    of psGround:
      if t.utf.len > 0 and (ord(c) and 0xC0) != 0x80:
        # broken UTF-8 sequence: show a replacement and handle this byte normally
        t.putChar(0xFFFD)
        t.utf.setLen(0)
        continue
      if t.utf.len > 0:
        t.utf.add c
        if t.utf.len >= runeLen(t.utf[0]):
          t.putChar(runeAt(t.utf, 0)[0])
          t.utf.setLen(0)
      elif c >= ' ' and c < '\x7f': t.putChar(ord(c))
      elif ord(c) >= 0xC0:
        t.utf = $c
      elif ord(c) >= 0x80: discard
      else:
        case c
        of '\e':
          t.st = psEsc
          t.inter.setLen(0)
        of '\r':
          t.cx = 0
          t.wrapPending = false
        of '\n', '\v', '\f':
          t.lineFeed()
          t.wrapPending = false
        of '\b':
          if t.cx > 0: dec t.cx
          t.wrapPending = false
        of '\t': t.cx = min(t.w - 1, (t.cx div 8 + 1) * 8)
        of '\x0e': t.shiftOut = true
        of '\x0f': t.shiftOut = false
        else: discard
    of psEsc:
      t.st = psGround
      case c
      of '[':
        t.st = psCsi
        t.params.setLen(0)
        t.inter.setLen(0)
      of ']':
        t.st = psOsc
        t.osc.setLen(0)
      of 'P', '_', '^', 'X': t.st = psStr
      of '(', ')', '*', '+':
        t.inter = $c
        t.st = psCharset
      of '#': t.st = psHash
      of '7':
        t.sx = t.cx
        t.sy = t.cy
        t.sFg = t.fg
        t.sBg = t.bg
        t.sAt = t.at
      of '8':
        t.cx = clamp(t.sx, 0, t.w - 1)
        t.cy = clamp(t.sy, 0, t.h - 1)
        t.fg = t.sFg
        t.bg = t.sBg
        t.at = t.sAt
      of 'D': t.lineFeed()
      of 'E':
        t.cx = 0
        t.lineFeed()
      of 'M':
        if t.cy == t.top: t.scrollDown()
        elif t.cy > 0: dec t.cy
      of 'c':
        t.fg = NoColor
        t.bg = NoColor
        t.at = {}
        t.top = 0
        t.bot = t.h - 1
        t.cx = 0
        t.cy = 0
        for r in 0 ..< t.h: t.scr[r] = t.blankRow
        t.cmds.setLen(0)
        t.navCmd = -1
      else: discard
    of psCsi:
      if c in {'0'..'9', ';', ':'}: t.params.add c
      elif c in {'?', '>', '=', '!', ' ', '$', '"', '\''}: t.inter.add c
      elif c >= '@' and c <= '~':
        t.doCsi(c)
        t.st = psGround
      elif c == '\e': t.st = psEsc
      elif c < ' ': discard
      else: t.st = psGround
    of psOsc:
      if c == '\a' or (c == '\\' and t.osc.endsWith("\e")):
        var o = t.osc
        if o.endsWith("\e"): o.setLen(o.len - 1)
        let semi = o.find(';')
        if semi > 0 and o[0 ..< semi] in ["0", "2"]: t.title = o[semi + 1 .. ^1]
        elif o.startsWith("133;"): t.osc133(o[4 .. ^1])
        t.st = psGround
      elif t.osc.len < 4096: t.osc.add c
    of psStr:
      if c == '\a': t.st = psGround
      elif c == '\\' and i > 0 and data[i - 1] == '\e': t.st = psGround
    of psCharset:
      let line = c == '0'
      if t.inter == "(": t.lineDraw = line
      elif t.inter == ")": t.g1Line = line
      t.st = psGround
    of psHash:
      t.st = psGround
    inc i

proc termWrite(t: Term, s: string) =
  if t.fd < 0 or t.dead or s.len == 0: return
  if t.hosted:
    t.hostSend('d', s)
    return
  var off = 0
  var tries = 0
  while off < s.len and tries < 200:
    let n = posix.write(t.fd, unsafeAddr s[off], s.len - off)
    if n > 0: off += n
    elif errno in [EAGAIN, EINTR]:
      inc tries
      os.sleep(1)
    else: break

proc termReap(t: Term) =
  if t.pid <= 0 or t.hosted: return      # (a kept shell is its host's child: the host says how it ended)
  var status: cint
  let r = waitpid(t.pid, status, WNOHANG)
  if r == t.pid:
    t.code = if WIFEXITED(status): int(WEXITSTATUS(status)) else: -1
    t.pid = 0
