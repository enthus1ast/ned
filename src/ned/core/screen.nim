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
  var off = 0
  while off < s.len:
    let n = posix.write(1.cint, unsafeAddr s[off], s.len - off)
    if n < 0:
      if errno == EINTR or errno == EAGAIN: continue
      return
    off += n

proc getTermSize(): (int, int) =
  var ws: IOctl_WinSize
  if ioctl(1, TIOCGWINSZ, addr ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0:
    (ws.ws_col.int, ws.ws_row.int)
  else:
    (80, 24)

proc mouseSeq(): string =
  if not cfgMouse: return MouseOffSeq
  "\e[?1000h\e[?1002h" & (if cfgHoverFx: "\e[?1003h" else: "\e[?1003l") & "\e[?1006h"

proc cursorStyleSeq(): string =
  case cfgCursorStyle
  of "block": "\e[2 q"
  of "underline": "\e[4 q"
  else: "\e[6 q"

proc termCapsStart()
proc termCapsStop()

proc setMouseMode() = writeAll(MouseOffSeq & mouseSeq())
proc applyCursorStyle() = writeAll(cursorStyleSeq())

proc enterRaw() =
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
  template q(v: int): int = (if v < 48: 0 elif v < 115: 1 else: (v - 35) div 40)
  let (qr, qg, qb) = (q(r), q(g), q(b))
  template dist(x, y, z: int): int = 2 * (r - x) * (r - x) + 4 * (g - y) * (g - y) + 3 * (b - z) * (b - z)
  let cube = 16 + 36 * qr + 6 * qg + qb
  let dc = dist(CubeLevels[qr], CubeLevels[qg], CubeLevels[qb])
  let k = clamp(((r + g + b) div 3 - 3) div 10, 0, 23)   # (232 + k is 8 + 10k on every channel)
  let gv = 8 + 10 * k
  if dist(gv, gv, gv) < dc: 232 + k else: cube

proc gridResize() =
  (scrW, scrH) = getTermSize()
  grid.setLen(scrW * scrH)
  prevGrid.setLen(0)

proc setCell(x, y: int, c: Cell) {.inline.} =
  if x < 0 or y < 0 or x >= scrW or y >= scrH: return
  let i = y * scrW + x
  if grid[i].ch == 0 and x > 0: grid[i-1].ch = 32           # broke a wide char's right half
  if x + 1 < scrW and grid[i+1].ch == 0 and grid[i].ch != 0 and cellWidth(grid[i].ch) == 2:
    grid[i+1].ch = 32                                       # broke a wide char's left half
  grid[i] = c

proc fillRect(x, y, w, h: int, fg, bg: Rgb) =
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
  if perfTraceOn: perfRoundCpu0 = threadCpuUs()

template timedWork(name: string, body: untyped) =
  ## `body`, noted when it takes over 30 ms (what kept ned busy: the performance report names it)
  let twT0 = getMonoTime()
  inc perfTraceDepth
  try: body
  finally: dec perfTraceDepth
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
              " " & $(getOccupiedMem() div 1024) & " " & $(getTotalMem() div 1024)     # (the heap: in use, held, KB)
      var own = 0
      for (n, t) in perfTraceItems:
        l.add "\t" & n & "=" & $t
        if not n.startsWith("› "): own += t
      if us - own >= 2000: l.add "\t(not named)=" & $(us - own)
      perfTrace.add l
    perfTraceItems.setLen(0)

const UnknownCell = Cell(ch: 0xFFFFFFFF'u32)        # (a cell whose content on the terminal is not known: repainted)

func rowHash(g: seq[Cell], base, x0, x1: int): uint64 =
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
    var x = x0
    while x <= x1:
      var c = grid[base + x]
      if cfgTransparentBg and c.bg == theme.bg: c.bg = NoColor       # (the terminal's own background shows)
      # (a run of cells the terminal already shows: stepped over)
      if not full and not hasWide and sameCell(c, prevGrid[base + x]):
        var e = x + 1
        while e <= x1 and sameCell(grid[base + e], prevGrid[base + e]): inc e
        if e - x >= 5:
          o.add "\e["
          o.add $(e - x)
          o.add 'C'
          x = e
          continue
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
      if cfgAccessible and ch >= 128 and ch < 0x3000: ch = asciiGlyph(ch)
      if ch < 128: o.add char(ch)
      elif ch >= PoolBase.int: o.add cellPool[ch - PoolBase.int]          # (several code points: one character)
      else: o.addUtf8(ch)
      prevWide = ch >= 0x1100 and cellWidth(ch.uint32) == 2
      inc x
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
  if cursorX >= 0 and cursorY >= 0 and cursorX < scrW and cursorY < scrH:
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
