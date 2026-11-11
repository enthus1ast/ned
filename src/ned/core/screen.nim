# ════════════════════════════════════════════════════════════════════════════
#  Terminal: raw mode, cell grid, diffed output
# ════════════════════════════════════════════════════════════════════════════

const
  MouseOffSeq = "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"

var titleReset = false          # (raw mode left: the terminal's title is set again when it comes back)

type GfxReq = object             # a picture the terminal draws itself (kitty, sixel, iTerm2) over the cells
  key: string                    # what it is (a new key: sent again)
  x, y, w, h: int                # where, in cells
  payload: string                # the escape sequence that draws it
  del: string                    # … and the one that takes it away (kitty: delete; sixel: nothing — text covers it)
  again: bool                    # sent again when the cells under it were drawn (sixel: text erases it)
var
  gfxNow: GfxReq                 # this frame's (set while drawing; none when a menu or dialog is over it)
  gfxShown: GfxReq               # what the terminal has
  gfxDirty = false               # (a row under it drawn again this frame)

proc writeAll(s: string) =
  ## writes the whole string to the terminal (standard output), going on after an interruption or a busy output; any
  ## other error gives up
  var off = 0
  while off < s.len:
    let n = posix.write(1.cint, unsafeAddr s[off], s.len - off)
    if n < 0:
      if errno == EINTR or errno == EAGAIN: continue
      return
    off += n

proc getTermSize(): (int, int) =
  ## the terminal's columns and rows, 80 × 24 when it does not say
  var ws: IOctl_WinSize
  if ioctl(1, TIOCGWINSZ, addr ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0:
    (ws.ws_col.int, ws.ws_row.int)
  else:
    (80, 24)

proc mouseSeq(): string =
  ## the escape sequence for the mouse: clicks and drags with SGR coordinates (and all movement while hover effects are
  ## on), or the sequence that turns the mouse reporting off when ui.mouse is off
  if not cfgMouse: return MouseOffSeq
  "\e[?1000h\e[?1002h" & (if cfgHoverFx: "\e[?1003h" else: "\e[?1003l") & "\e[?1006h"

proc cursorStyleSeq(): string =
  ## the escape sequence for the cursor's shape (ui.cursorStyle): block, underline, else a bar
  case cfgCursorStyle
  of "block": "\e[2 q"
  of "underline": "\e[4 q"
  else: "\e[6 q"

proc termCapsStart()
proc termCapsStop()

# sends the mouse reporting wanted now, after turning every kind off
proc setMouseMode() = writeAll(MouseOffSeq & mouseSeq())
# sends the cursor shape wanted now
proc applyCursorStyle() = writeAll(cursorStyleSeq())

proc enterRaw() =
  ## puts the terminal into raw mode — no echo, line editing, signals or output changes, reads that return at once —
  ## keeping the old settings to come back to, and notes whether its erase key sends ^H. It saves the title, switches to
  ## the alternate screen, turns on bracketed paste, focus reports and the mouse, hides the cursor, asks for the
  ## terminal's background colour and starts the terminal-capability queries
  if tcGetAttr(0, addr gOrigTerm) != 0: return
  eraseIsCtrlH = gOrigTerm.c_cc[VERASE] == '\x08'
  var t = gOrigTerm
  t.c_iflag = t.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  t.c_oflag = t.c_oflag and not OPOST
  t.c_cflag = t.c_cflag or CS8
  t.c_lflag = t.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  t.c_cc[VMIN] = 0.char
  t.c_cc[VTIME] = 0.char
  discard tcSetAttr(0, TCSAFLUSH, addr t)
  gRaw = true
  writeAll("\e[22;0t\e[?1049h\e[?7l\e[?2004h\e[?1004h\e[?25l" & cursorStyleSeq() & mouseSeq())
  prevGrid.setLen(0)
  writeAll("\e]11;?\a")         # the background colour, for "theme": "auto" (terminals that do not answer ignore it)
  termCapsStart()               # (and what else it can do: see termcaps)

proc leaveRaw() =
  ## gives the terminal back: the pointer shape, mouse, focus reports, paste mode, colours, cursor, main screen and old
  ## title, then its original settings (after enterRaw)
  if not gRaw: return
  if pointerShape.len > 0 and pointerShape != "default": writeAll("\e]22;default\a")   # (the arrow back)
  pointerShape = ""
  termCapsStop()
  titleReset = true
  writeAll(MouseOffSeq & "\e[?1004l\e[?2004l\e[0m\e[0 q\e[?7h\e[?25h\e[?1049l\e[23;0t")   # (and its old title back)
  discard tcSetAttr(0, TCSAFLUSH, addr gOrigTerm)
  gRaw = false

const CubeLevels = [0, 95, 135, 175, 215, 255]          # (the 6×6×6 cube's steps of the 256-colour palette)

proc rgbTo256(c: Rgb): int =
  ## the nearest colour of the 256-colour palette: of the cube's and the grey ramp's, the one closer to the eye —
  ## a dark blue-grey background stays dark grey (the cube's nearest is a strong blue, #00005F)
  let r = int((c shr 16) and 0xFF)
  let g = int((c shr 8) and 0xFF)
  let b = int(c and 0xFF)
  # the step 0 … 5 of the colour cube that a channel value 0 … 255 falls in
  template q(v: int): int = (if v < 48: 0 elif v < 115: 1 else: (v - 35) div 40)
  let (qr, qg, qb) = (q(r), q(g), q(b))
  # how far (r, g, b) is from the colour (x, y, z), squares weighted for the eye (green most)
  template dist(x, y, z: int): int = 2 * (r - x) * (r - x) + 4 * (g - y) * (g - y) + 3 * (b - z) * (b - z)
  let cube = 16 + 36 * qr + 6 * qg + qb
  let dc = dist(CubeLevels[qr], CubeLevels[qg], CubeLevels[qb])
  let k = clamp(((r + g + b) div 3 - 3) div 10, 0, 23)   # (232 + k is 8 + 10k on every channel)
  let gv = 8 + 10 * k
  if dist(gv, gv, gv) < dc: 232 + k else: cube

proc gridResize() =
  ## reads the terminal's size and sizes the cell grid to it; the picture of what the terminal shows is forgotten, so
  ## the next frame is drawn whole
  (scrW, scrH) = getTermSize()
  grid.setLen(scrW * scrH)
  prevGrid.setLen(0)

proc setCell(x, y: int, c: Cell) {.inline.} =
  ## puts a cell in the grid (nothing outside it); when that breaks the half of a wide character, the other half becomes
  ## a space
  if x < 0 or y < 0 or x >= scrW or y >= scrH: return
  let i = y * scrW + x
  if grid[i].ch == 0 and x > 0: grid[i-1].ch = 32           # broke a wide char's right half
  if x + 1 < scrW and grid[i+1].ch == 0 and grid[i].ch != 0 and cellWidth(grid[i].ch) == 2:
    grid[i+1].ch = 32                                       # broke a wide char's left half
  grid[i] = c

proc fillRect(x, y, w, h: int, fg, bg: Rgb) =
  ## fills a rectangle of the grid, cut to the screen, with spaces in the given colours
  for yy in max(0, y) ..< min(scrH, y + h):
    for xx in max(0, x) ..< min(scrW, x + w):
      grid[yy * scrW + xx] = Cell(ch: 32, fg: fg, bg: bg)

proc putStr(x, y: int, s: string, fg, bg: Rgb, at: set[Attr] = {}, maxX = -1): int =
  ## draw `s` at (x,y) clipped to `maxX` (exclusive); returns the next x
  var x = x
  let lim = if maxX < 0: scrW else: min(maxX, scrW)
  if y < 0 or y >= scrH: return x
  var i = 0
  while i < s.len and x < lim:
    var (cp, n) = runeAt(s, i)
    var ch = cp.uint32
    var w = 1
    if cp == 9: ch = 32
    elif cp < 32: ch = uint32(0x2400 + cp)
    elif cp == 127: ch = 0x2421
    elif cp >= 0x80 or (i + 1 < s.len and s[i + 1].uint8 >= 0x80):
      # (a character of several code points — an accent, a ZWJ emoji — is one cell; see cellOf)
      let (e, uw) = unitAt(s, i, graphemes)
      n = e - i
      w = uw
      ch = cellOf(s, i, n)
    i += n
    if w == 0: continue
    if x + w > lim:
      while x < lim:
        setCell(x, y, Cell(ch: 32, fg: fg, bg: bg, at: at))
        inc x
      break
    setCell(x, y, Cell(ch: ch, fg: fg, bg: bg, at: at))
    if w == 2: setCell(x + 1, y, Cell(ch: 0, fg: fg, bg: bg, at: at))
    x += w
  x

var numStr: array[256, string]
for i in 0 .. 255: numStr[i] = $i

var ulStyled = false            # curly underlines in the problem's colour (ui.undercurl and the terminal: termcaps)

proc sgrColorFast(s: var string, c: Rgb, fg: bool) {.inline.} =
  ## adds a colour to an SGR parameter list as ";38;2;r;g;b" (true colour) or ";38;5;n" (the 256-colour palette), for
  ## the foreground or the background (48); nothing for NoColor
  if c == NoColor: return
  if trueColor:
    s.add (if fg: ";38;2;" else: ";48;2;")
    s.add numStr[int((c shr 16) and 0xFF)]; s.add ';'
    s.add numStr[int((c shr 8) and 0xFF)]; s.add ';'
    s.add numStr[int(c and 0xFF)]
  else:
    s.add (if fg: ";38;5;" else: ";48;5;")
    s.add numStr[rgbTo256(c)]

proc sgrUnderline(s: var string, at: set[Attr], added: set[Attr]) =
  ## a curly underline and its colour (ui.undercurl and a terminal that draws them): `added` is what is new
  if not ulStyled or aUnder notin at: return
  if aCurl in added: s.add ";4:3"
  let c = if aUcErr in added: theme.err elif aUcWarn in added: theme.warn elif aUcInfo in added: theme.info
          else: NoColor
  if c == NoColor: return
  if trueColor:
    s.add ";58:2::"
    s.add numStr[int((c shr 16) and 0xFF)]; s.add ':'
    s.add numStr[int((c shr 8) and 0xFF)]; s.add ':'
    s.add numStr[int(c and 0xFF)]
  else:
    s.add ";58:5:"
    s.add numStr[rgbTo256(c)]

func sameCell(a, b: Cell): bool {.inline.} =
  ## whether two cells look the same: character, colours and attributes
  a.ch == b.ch and a.fg == b.fg and a.bg == b.bg and a.at == b.at

var cfgAccessible = false       # ui.accessible: ASCII for every box line and symbol, letters beside colours

func asciiGlyph(cp: int): int =
  ## accessibility mode: the frames, bars and symbols as plain ASCII a screen reader reads sensibly
  case cp
  of 0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D, 0x2550, 0x2574, 0x2576, 0x2578, 0x257A,
     0x257C, 0x257E, 0x2014, 0x2013, 0x2015: ord('-')
  of 0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F, 0x2551, 0x2575, 0x2577, 0x2579, 0x257B,
     0x257D, 0x257F, 0x258F, 0x258E, 0x258D, 0x258C, 0x2590, 0x2595, 0x2016: ord('|')
  of 0x250C .. 0x254B, 0x2552 .. 0x2573: ord('+')
  of 0x2581: ord('_')
  of 0x2580, 0x2582 .. 0x258B, 0x2591 .. 0x2594, 0x2596 .. 0x259F, 0x25A0, 0x29C9: ord('#')
  of 0x2800: ord(' ')
  of 0x2801 .. 0x28FF: ord(':')
  of 0x2022, 0x25CF, 0x25C6, 0x2726, 0x2605, 0x2699, 0x2731: ord('*')
  of 0x00B7, 0x2026, 0x22EF: ord('.')
  of 0x2713, 0x2714: ord('v')
  of 0x2717, 0x2718, 0x00D7, 0x2922: ord('x')
  of 0x25CB, 0x25C7, 0x25F7, 0x25A1, 0x25CC: ord('o')
  of 0x25B6, 0x25B8, 0x2192, 0x21AA, 0x203A, 0x00BB, 0x276F: ord('>')
  of 0x25C0, 0x25C2, 0x2190, 0x23CE, 0x2039, 0x00AB: ord('<')
  of 0x25BE, 0x25BC, 0x2193: ord('v')
  of 0x25B4, 0x25B2, 0x2191: ord('^')
  of 0x2261: ord('=')
  of 0x2315: ord('?')
  of 0x2387: ord('Y')
  of 0x21BB: ord('@')
  of 0x2691: ord('F')
  of 0x25E7, 0x229F, 0x25E8: ord('#')
  of 0x201C, 0x201D: ord('"')
  of 0x2018, 0x2019: ord('\'')
  else: cp

var
  scrollHint: tuple[on: bool, y0, y1, x0, x1: int]   # render: the editor's rows (and text columns) that may have
                                                     # moved up or down since the last frame — flushScreen checks
  cfgTermScroll = true                               # ui.terminalScroll: let the terminal move those rows
  frameBytes*: int                                   # (the last frame's size, for Help › Performance)
  frameBytesTotal*, framesTotal*: int
  frameScrolls*: int                                 # (frames that scrolled the terminal instead of repainting)
  frameStats*: seq[tuple[buildUs, writeUs, bytes: int, scrolled: bool]]   # the last frames (Help › Performance)
  frameBuildUs*: int                                 # (set by render: how long the frame took to make)
  busyMaxUs*, busyOver50*, busyRounds*: int          # main loop rounds: the longest, how many over 50 ms
  busyRecent*: seq[(MonoTime, int)]                  # (rounds over 50 ms in the last minute: when, how long)

var slowWork*: seq[(MonoTime, string, int)]          # (work over 30 ms: when, what, how long — Help › Performance)

var
  perfTraceOn* = false              # NED_PERF_TRACE=file: every round over 4 ms, with what it did (tests/perf)
  perfTrace*: seq[string]
  perfTraceItems: seq[(string, int)]
  perfTraceT0 = getMonoTime()
  perfTraceDepth = 0                # (work inside other work: noted with "› " — the round's own items add up)
  perfRoundCpu0 = 0                 # (the processor time the main thread had used when the round began)

proc threadCpuUs(): int =
  ## processor time this thread has used: a round much longer than it waited (the system ran something else,
  ## a page was read from disk) — not work of ned's
  var ts: Timespec
  if clock_gettime(CLOCK_THREAD_CPUTIME_ID, ts) != 0: return 0
  ts.tv_sec.int * 1_000_000 + ts.tv_nsec.int div 1000

proc perfRoundStart() =
  ## when tracing performance (NED_PERF_TRACE), notes the processor time this thread has used as a round of the main
  ## loop starts
  if perfTraceOn: perfRoundCpu0 = threadCpuUs()

var
  crashWork: array[4, array[64, char]]     # what runs now, by depth (timedWork's names: what a crash note says ned
  crashWorkLen: array[4, int]              #   was doing), in memory a signal handler can read without allocating
  crashDepth = -1                          # (-1: nothing named runs)

proc noteWorking(depth: int, name: string) {.inline.} =
  ## (timedWork) the name of what runs at that depth, for a crash note (app/crash.nim)
  if depth < crashWork.len:
    let n = min(name.len, crashWork[depth].len)
    if n > 0: copyMem(addr crashWork[depth][0], unsafeAddr name[0], n)
    crashWorkLen[depth] = n
  crashDepth = depth

template timedWork(name: string, body: untyped) =
  ## `body`, noted when it takes over 30 ms (what kept ned busy: the performance report names it), and named while it
  ## runs for a crash note
  let twT0 = getMonoTime()
  noteWorking(perfTraceDepth, name)
  inc perfTraceDepth
  try: body
  finally:
    dec perfTraceDepth
    crashDepth = perfTraceDepth - 1
  let twUs = int((getMonoTime() - twT0).inMicroseconds)
  if twUs > 30_000:
    slowWork.add (getMonoTime(), name, twUs)
    if slowWork.len > 200: slowWork = slowWork[100 .. ^1]
  if perfTraceOn and twUs >= 500: perfTraceItems.add ((if perfTraceDepth > 0: "› " else: "") & name, twUs)

proc noteWork(name: string, t0: MonoTime) =
  ## what timedWork notes, for work that returns from the middle (defer: noteWork("…", t0))
  let us = int((getMonoTime() - t0).inMicroseconds)
  if us > 30_000:
    slowWork.add (getMonoTime(), name, us)
    if slowWork.len > 200: slowWork = slowWork[100 .. ^1]
  if perfTraceOn and us >= 500: perfTraceItems.add ((if perfTraceDepth > 0: "› " else: "") & name, us)

proc noteBusy(us: int) =
  ## one round of the main loop done: how long it kept ned from reading input
  inc busyRounds
  busyMaxUs = max(busyMaxUs, us)
  if us > 50_000:
    inc busyOver50
    busyRecent.add (getMonoTime(), us)
    if busyRecent.len > 200: busyRecent = busyRecent[100 .. ^1]
  if perfTraceOn:
    if us >= 4000 and perfTrace.len < 200_000:
      var l = $((getMonoTime() - perfTraceT0).inMilliseconds) & " " & $us & " " & $(threadCpuUs() - perfRoundCpu0) &
              " " & $(heapInUse() div 1024) & " " & $(heapHeld() div 1024)     # (the heap: in use, held, KB; -1 not known)
      var own = 0
      for (n, t) in perfTraceItems:
        l.add "\t" & n & "=" & $t
        if not n.startsWith("› "): own += t
      if us - own >= 2000: l.add "\t(not named)=" & $(us - own)
      perfTrace.add l
    perfTraceItems.setLen(0)

const UnknownCell = Cell(ch: 0xFFFFFFFF'u32)        # (a cell whose content on the terminal is not known: repainted)

func rowHash(g: seq[Cell], base, x0, x1: int): uint64 =
  ## a hash of cells x0 … x1 of the row that starts at base (characters and colours), to tell rows of two frames apart
  result = 1469598103934665603'u64
  for x in x0 .. x1:
    let c = g[base + x]
    result = (result xor c.ch.uint64) * 1099511628211'u64
    result = (result xor (c.fg.uint64 shl 32 or c.bg.uint64)) * 1099511628211'u64

proc termScroll(o: var string) =
  ## the editor's text moved up or down by whole rows: the terminal moves the rows it already shows (a scroll
  ## region, as vim and less do), and only what is new or different is sent after — a fraction of a repaint.
  ## prevGrid is moved the same way, so the diff that follows knows what the terminal shows
  let h = scrollHint
  if not h.on or not cfgTermScroll or prevGrid.len != grid.len or h.y1 - h.y0 < 3: return
  let rows = h.y1 - h.y0 + 1
  var oldH, newH = newSeq[uint64](rows)
  for i in 0 ..< rows:
    oldH[i] = rowHash(prevGrid, (h.y0 + i) * scrW, h.x0, h.x1)
    newH[i] = rowHash(grid, (h.y0 + i) * scrW, h.x0, h.x1)
  # (the shift that lines up the most rows: new row i shows what old row i + d showed)
  var bestD, best = 0
  for i in 0 ..< rows:
    if newH[i] == oldH[i]: inc best
  let still = best
  for d in -(rows div 2 + rows div 4) .. (rows div 2 + rows div 4):
    if d == 0: continue
    var n = 0
    for i in max(0, -d) ..< min(rows, rows - d):
      if newH[i] == oldH[i + d]: inc n
    if n > best:
      best = n
      bestD = d
  if bestD == 0 or best < max(3, still + rows div 4): return
  # (worth it: the cells that would differ after the move, against those that differ now)
  var now, after = 0
  for i in 0 ..< rows:
    let base = (h.y0 + i) * scrW
    let j = i + bestD
    if not equalMem(addr grid[base], addr prevGrid[base], scrW * sizeof(Cell)):
      for x in 0 ..< scrW:
        if not sameCell(grid[base + x], prevGrid[base + x]): inc now
    if j < 0 or j >= rows: after += scrW
    elif not equalMem(addr grid[base], addr prevGrid[(h.y0 + j) * scrW], scrW * sizeof(Cell)):
      let ob = (h.y0 + j) * scrW
      for x in 0 ..< scrW:
        if not sameCell(grid[base + x], prevGrid[ob + x]): inc after
  if after * 3 > now * 2: return
  o.add "\e[0m\e["
  o.add $(h.y0 + 1)
  o.add ';'
  o.add $(h.y1 + 1)
  o.add 'r'
  if bestD > 0:
    o.add "\e["
    o.add $(h.y1 + 1)
    o.add ";1H"
    for _ in 0 ..< bestD: o.add '\n'
    for i in 0 ..< rows:
      let dst = (h.y0 + i) * scrW
      if i + bestD < rows: copyMem(addr prevGrid[dst], addr prevGrid[(h.y0 + i + bestD) * scrW], scrW * sizeof(Cell))
      else:
        for x in 0 ..< scrW: prevGrid[dst + x] = UnknownCell
  else:
    o.add "\e["
    o.add $(h.y0 + 1)
    o.add ";1H"
    for _ in 0 ..< -bestD: o.add "\eM"
    for i in countdown(rows - 1, 0):
      let dst = (h.y0 + i) * scrW
      if i + bestD >= 0: copyMem(addr prevGrid[dst], addr prevGrid[(h.y0 + i + bestD) * scrW], scrW * sizeof(Cell))
      else:
        for x in 0 ..< scrW: prevGrid[dst + x] = UnknownCell
  o.add "\e[r"
  inc frameScrolls

proc caCursorMoved(): bool

# (an erase fills with the background in use — in every terminal ned meets but GNU screen without its bce option:
# there it would show the terminal's own background)
let eraseKeepsBg = not (getEnv("TERM").startsWith("screen") and getEnv("TMUX").len == 0 and getEnv("STY").len > 0)

proc flushScreen() =
  ## cell-level diff against what the terminal shows: unchanged rows cost one memcmp, changed rows send only the
  ## cells that differ (a run of unchanged ones is stepped over), each colour change only what changed — and a
  ## space only its background (its foreground cannot be seen); text that moved up or down is moved by the terminal
  var o = newStringOfCap(8192)
  o.add "\e[?2026h\e[?25l"
  let full = prevGrid.len != grid.len
  let scrollCount0 = frameScrolls
  if full:
    prevGrid.setLen(grid.len)
  else:
    termScroll(o)
  scrollHint.on = false
  # (what the terminal draws with now: unknown until the first colour of the frame)
  var lf, lb: Rgb = NoColor
  var la: set[Attr] = {}
  var known = false
  const SpaceShows = {aUnder, aRev, aStrike}      # (what a space shows besides its background)
  for y in 0..<scrH:
    let base = y * scrW
    if not full and equalMem(addr grid[base], addr prevGrid[base], scrW * sizeof(Cell)): continue
    if gfxNow.key.len > 0 and y >= gfxNow.y and y < gfxNow.y + gfxNow.h: gfxDirty = true
    var x0 = 0
    var x1 = scrW - 1
    var hasWide = false
    if not full:
      while x0 < scrW and sameCell(grid[base + x0], prevGrid[base + x0]): inc x0
      if x0 >= scrW:
        copyMem(addr prevGrid[base], addr grid[base], scrW * sizeof(Cell))
        continue
      while x1 > x0 and sameCell(grid[base + x1], prevGrid[base + x1]): dec x1
      for x in 0 ..< scrW:
        if grid[base + x].ch == 0 or prevGrid[base + x].ch == 0:
          hasWide = true
          break
      if hasWide:
        # terminals and wcwidth sometimes disagree on wide glyphs: repaint to the row end
        x1 = scrW - 1
        while x0 > 0 and grid[base + x0].ch == 0: dec x0
    o.add "\e["
    o.add (if y + 1 <= 255: numStr[y + 1] else: $(y + 1))
    o.add ';'
    o.add $(x0 + 1)
    o.add 'H'
    var prevWide = false
    var blankRun = 0                 # (cells after this one to erase rather than send)
    var x = x0
    while x <= x1:
      var c = grid[base + x]
      if inkScreen: inkCell(c)                                         # (e-ink: black and white, nothing between)
      if cfgTransparentBg and c.bg == theme.bg: c.bg = NoColor       # (the terminal's own background shows)
      # (a run of cells the terminal already shows: stepped over)
      if not full and not hasWide and sameCell(grid[base + x], prevGrid[base + x]):
        var e = x + 1
        while e <= x1 and sameCell(grid[base + e], prevGrid[base + e]): inc e
        if e - x >= 5:
          o.add "\e["
          o.add $(e - x)
          o.add 'C'
          x = e
          continue
      # (a run of blank cells of one background — the rest of a short line, the space before the minimap: its first
      # cell sent, the others erased in that background and stepped over, not sent as spaces each)
      if eraseKeepsBg and not inkScreen and not hasWide and c.ch == 32 and c.at * SpaceShows == {} and
         x + 12 <= x1 + 1:
        var e = x + 1
        while e <= x1 and grid[base + e].ch == 32 and grid[base + e].bg == grid[base + x].bg and
              grid[base + e].at * SpaceShows == {}:
          inc e
        if e - x >= 12:
          blankRun = e - x - 1
      var ch = c.ch.int
      if ch == 0:
        if prevWide:
          prevWide = false
          inc x
          continue
        ch = 32
      let at = if cfgItalics: c.at else: c.at - {aItalic}   # many terminals/fonts have no italics
      let invisibleFg = ch == 32 and at * SpaceShows == {} and la * SpaceShows == {}
      if not known or c.bg != lb or (not invisibleFg and (c.fg != lf or at != la)):
        if not known or (la - at) != {} and not invisibleFg:
          # (from nothing: every attribute and both colours)
          o.add "\e[0"
          if aBold in at: o.add ";1"
          if aDim in at: o.add ";2"
          if aItalic in at: o.add ";3"
          if aUnder in at: o.add ";4"
          if aRev in at: o.add ";7"
          if aStrike in at: o.add ";9"
          sgrUnderline(o, at, at)
          sgrColorFast(o, c.fg, true)
          sgrColorFast(o, c.bg, false)
          o.add 'm'
          lf = c.fg; lb = c.bg; la = at
          known = true
        else:
          # (only what changed)
          let mark = o.len
          o.add "\e["
          if not invisibleFg:
            let add = at - la
            if aBold in add: o.add ";1"
            if aDim in add: o.add ";2"
            if aItalic in add: o.add ";3"
            if aUnder in add: o.add ";4"
            if aRev in add: o.add ";7"
            if aStrike in add: o.add ";9"
            sgrUnderline(o, at, (if aUnder in add: at else: add))
            la = at
            if c.fg != lf:
              if c.fg == NoColor: o.add ";39" else: sgrColorFast(o, c.fg, true)
              lf = c.fg
          if c.bg != lb:
            if c.bg == NoColor: o.add ";49" else: sgrColorFast(o, c.bg, false)
            lb = c.bg
          if o.len == mark + 2: o.setLen(mark)      # (nothing changed after all)
          else:
            o.delete(mark + 2 .. mark + 2)          # ("\e[;…" → "\e[…")
            o.add 'm'
      if ch < 0xA0: ch = visibleCh(ch)            # (a control character: its picture, never the control itself)
      if cfgAccessible and ch >= 128 and ch < 0x3000: ch = asciiGlyph(ch)
      if ch < 128: o.add char(ch)
      elif ch >= PoolBase.int: o.add cellPool[ch - PoolBase.int]          # (several code points: one character)
      else: o.addUtf8(ch)
      prevWide = ch >= 0x1100 and cellWidth(ch.uint32) == 2
      inc x
      if blankRun > 0:
        o.add "\e["
        o.add $blankRun
        o.add "X\e["                  # (erase that many, in the background just set …)
        o.add $blankRun
        o.add 'C'                      # (… and past them)
        x += blankRun
        blankRun = 0
    copyMem(addr prevGrid[base], addr grid[base], scrW * sizeof(Cell))
  o.add "\e[0m"
  # a picture the terminal draws: sent when it is new (or the cells under it were drawn again: sixel), taken away
  # when it is gone
  if gfxNow.key.len > 0:
    if gfxShown.key.len > 0 and gfxShown.key != gfxNow.key: o.add gfxShown.del
    if gfxShown.key != gfxNow.key or full or (gfxNow.again and gfxDirty):
      o.add "\e[" & $(gfxNow.y + 1) & ";" & $(gfxNow.x + 1) & "H" & gfxNow.payload
    gfxShown = gfxNow
  elif gfxShown.key.len > 0:
    o.add gfxShown.del
    gfxShown = GfxReq()
  gfxDirty = false
  # (a jump of the cursor glides there: the glide shows it when it arrives — caPump)
  if not caCursorMoved() and cursorX >= 0 and cursorY >= 0 and cursorX < scrW and cursorY < scrH:
    o.add "\e[" & $(cursorY + 1) & ";" & $(cursorX + 1) & "H\e[?25h"
  o.add "\e[?2026l"
  frameBytes = o.len
  frameBytesTotal += o.len
  inc framesTotal
  let scrolled = scrollCount0 != frameScrolls
  let tw = getMonoTime()
  writeAll(o)
  # (how long the terminal took to take it: a slow terminal blocks the write)
  if frameStats.len >= 240: frameStats = frameStats[120 .. ^1]
  frameStats.add (frameBuildUs, int((getMonoTime() - tw).inMicroseconds), o.len, scrolled)

proc termSpeed(): (int, int) =
  ## (KB per second the terminal takes, the frames it was measured on): from frames big enough to tell (a small
  ## one fits in the terminal's buffer at once)
  var bytes, us, n = 0
  for f in frameStats:
    if f.bytes >= 2048:
      bytes += f.bytes
      us += max(1, f.writeUs)
      inc n
  if n < 5 or us <= 0: return (-1, n)
  (int(float(bytes) / 1024.0 / (float(us) / 1_000_000.0)), n)

proc slowTerminal(): bool =
  ## does the terminal fall behind ned's frames? (Termux on an older phone, a slow SSH link): then the minimap set
  ## to "auto" is left out — the light frames keep scrolling smooth
  let (kbs, n) = termSpeed()
  n >= 8 and kbs >= 0 and kbs < 1500

# ── the cursor's glide (ui.cursorAnimation): when the cursor jumps — a line down, a word on, a search, a definition —
#    a short trail goes from where it was to where it is, fading behind it. Each glide frame sends only the trail's
#    cells (and puts back those it left), up to 120 a second, for ui.cursorAnimationMs; the screen is not drawn
#    again for it. Off on a slow terminal and in accessibility mode ──

const CaFrameMs = 8                # (120 frames a second at most)

var
  cfgCursorAnim = "glide"          # ui.cursorAnimation: glide · off
  cfgCursorAnimMs = 100            # ui.cursorAnimationMs: how long a glide lasts
  batterySave = false              # (6.32) saving the battery (ui.batterySaver): no glide, fewer wake-ups
  lowMemory = false                # (6.37) the device is short of memory (ui.lowMemory): ned keeps light
  caShownX, caShownY = -1          # where the last frame put the cursor
  caOn = false                     # a glide going on
  caFrom, caTo: (float, float)     # (column, row)
  caT0, caNextAt: MonoTime
  caCells: seq[int]                # the cells the last glide frame drew (indices of grid)
  caGlides*, caFrames*, caBytes*: int   # (Help › Performance)

func caEase(t: float): float =
  ## the cubic ease-out of a glide: fast at first, slow to arrive; t from 0 to 1
  let u = 1.0 - clamp(t, 0.0, 1.0)
  1.0 - u * u * u                  # (fast away, slow to arrive)

proc caAt(t: float): (float, float) =
  ## where the cursor is at time t of a glide: (column, row) between its start and end, eased
  let e = caEase(t)
  (caFrom[0] + (caTo[0] - caFrom[0]) * e, caFrom[1] + (caTo[1] - caFrom[1]) * e)

# how far a glide has got: the time since it began over its length (ui.cursorAnimationMs, at least 20 ms), 1 or more
# once it is over
proc caT(): float = float((getMonoTime() - caT0).inMicroseconds) / (max(20, cfgCursorAnimMs).float * 1000.0)

proc caCursorMoved(): bool =
  ## (flushScreen, the frame written but for the cursor) a jump starts a glide — true: the cursor stays hidden until
  ## the glide brings it. The frame has just repainted the cells the glide had drawn (they were marked unknown)
  let (nx, ny) = (cursorX, cursorY)
  caCells.setLen(0)
  if cfgCursorAnim == "off" or nx < 0 or ny < 0 or cfgAccessible or slowTerminal() or batterySave:
    caOn = false
  elif nx != caShownX or ny != caShownY:
    let (dx, dy) = (abs(nx - caShownX), abs(ny - caShownY))
    if caShownX >= 0 and caShownY >= 0 and (dy >= 1 or dx >= 3):
      caFrom = if caOn: caAt(caT()) else: (caShownX.float, caShownY.float)
      caTo = (nx.float, ny.float)
      caT0 = getMonoTime()
      caNextAt = caT0
      caOn = true
      inc caGlides
    else:
      caOn = false                 # (a step of a column or two — typing: no glide)
  caShownX = nx
  caShownY = ny
  caOn

proc caEmit(o: var string, i: int, c0: Cell) =
  ## one cell sent on its own (the attributes and colours from nothing)
  var c = c0
  if cfgTransparentBg and c.bg == theme.bg: c.bg = NoColor
  o.add "\e["
  o.add $(i div scrW + 1)
  o.add ';'
  o.add $(i mod scrW + 1)
  o.add "H\e[0"
  let at = if cfgItalics: c.at else: c.at - {aItalic}
  if aBold in at: o.add ";1"
  if aDim in at: o.add ";2"
  if aItalic in at: o.add ";3"
  if aUnder in at: o.add ";4"
  if aRev in at: o.add ";7"
  if aStrike in at: o.add ";9"
  sgrUnderline(o, at, at)
  sgrColorFast(o, c.fg, true)
  sgrColorFast(o, c.bg, false)
  o.add 'm'
  var ch = c.ch.int
  if ch == 0: ch = 32
  if ch < 0xA0: ch = visibleCh(ch)
  if cfgAccessible and ch >= 128 and ch < 0x3000: ch = asciiGlyph(ch)
  if ch < 128: o.add char(ch)
  elif ch >= PoolBase.int: o.add cellPool[ch - PoolBase.int]
  else: o.addUtf8(ch)

proc caDueMs(): int =
  ## (the main loop's wait) until the next glide frame; -1: no glide
  if not caOn: return -1
  max(0, int((caNextAt - getMonoTime()).inMilliseconds))

proc caPump() =
  ## the next glide frame, when it is due: the trail from its tail to its head, brightest at the head
  if not caOn or getMonoTime() < caNextAt: return
  caNextAt = getMonoTime() + initDuration(milliseconds = CaFrameMs)
  if grid.len != scrW * scrH or prevGrid.len != grid.len:
    caOn = false
    caCells.setLen(0)
    return
  let t = caT()
  var cells: seq[(int, float)]
  if t < 1.0:
    let head = caAt(t)
    let tail = caAt(t - 0.3)       # (the tail follows a little behind: a smear, not a jump)
    let (x0, y0) = (int(round(tail[0])), int(round(tail[1])))
    let (x1, y1) = (int(round(head[0])), int(round(head[1])))
    let steps = max(abs(x1 - x0), abs(y1 - y0))
    for k in countdown(steps, 0):  # (from the head: when the trail is long, its far end is left out)
      let f = if steps == 0: 1.0 else: k / steps
      let x = int(round(x0.float + (x1 - x0).float * f))
      let y = int(round(y0.float + (y1 - y0).float * f))
      if x < 0 or y < 0 or x >= scrW or y >= scrH: continue
      let i = y * scrW + x
      let ch = grid[i].ch
      if ch == 0 or ch >= PoolBase or (ch >= 0x1100 and cellWidth(ch) == 2): continue   # (a wide character)
      if gfxShown.key.len > 0 and y >= gfxShown.y and y < gfxShown.y + gfxShown.h: continue  # (a picture's cells)
      var seen = false
      for (j, _) in cells:
        if j == i: seen = true
      if seen: continue
      cells.add (i, 0.3 + 0.6 * f)
      if cells.len >= 80: break
  var o = newStringOfCap(1024)
  o.add "\e[?2026h\e[?25l"
  for i in caCells:                # (the cells the trail left: what the frame has there)
    var still = false
    for (j, _) in cells:
      if j == i: still = true
    if not still and i < grid.len:
      caEmit(o, i, grid[i])
      prevGrid[i] = grid[i]
  caCells.setLen(0)
  let glyph = case cfgCursorStyle
              of "block": 0x2588'u32
              of "underline": 0x2581'u32
              else: 0x258E'u32
  for (i, k) in cells:
    let bg = if grid[i].bg == NoColor: theme.bg else: grid[i].bg
    caEmit(o, i, Cell(ch: glyph, fg: blend(bg, theme.fg, k), bg: grid[i].bg))
    prevGrid[i] = UnknownCell      # (a frame drawn meanwhile repaints it)
    caCells.add i
  if t >= 1.0:
    caOn = false
    if cursorX >= 0 and cursorY >= 0 and cursorX < scrW and cursorY < scrH:
      o.add "\e[" & $(cursorY + 1) & ";" & $(cursorX + 1) & "H\e[?25h"
  o.add "\e[0m\e[?2026l"
  writeAll(o)
  inc caFrames
  caBytes += o.len
