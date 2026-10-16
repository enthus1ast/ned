# ════════════════════════════════════════════════════════════════════════════
#  Terminal: raw mode, cell grid, diffed output
# ════════════════════════════════════════════════════════════════════════════

const
  MouseOffSeq = "\e[?1006l\e[?1003l\e[?1002l\e[?1000l"

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
  writeAll("\e[?1049h\e[?7l\e[?2004h\e[?1004h\e[?25l" & cursorStyleSeq() & mouseSeq())
  prevGrid.setLen(0)
  writeAll("\e]11;?\a")         # the background colour, for "theme": "auto" (terminals that do not answer ignore it)

proc leaveRaw() =
  if not gRaw: return
  writeAll(MouseOffSeq & "\e[?1004l\e[?2004l\e[0m\e[0 q\e[?7h\e[?25h\e[?1049l")
  discard tcSetAttr(0, TCSAFLUSH, addr gOrigTerm)
  gRaw = false

proc rgbTo256(c: Rgb): int =
  let r = int((c shr 16) and 0xFF)
  let g = int((c shr 8) and 0xFF)
  let b = int(c and 0xFF)
  if abs(r - g) < 12 and abs(g - b) < 12:
    if r < 8: return 16
    if r > 246: return 231
    return 232 + (r - 8) * 24 div 240
  proc q(v: int): int = (if v < 48: 0 elif v < 115: 1 else: (v - 35) div 40)
  16 + 36 * q(r) + 6 * q(g) + q(b)

proc gridResize() =
  (scrW, scrH) = getTermSize()
  grid.setLen(scrW * scrH)
  prevGrid.setLen(0)

proc setCell(x, y: int, c: Cell) {.inline.} =
  if x < 0 or y < 0 or x >= scrW or y >= scrH: return
  let i = y * scrW + x
  if grid[i].ch == 0 and x > 0: grid[i-1].ch = 32           # broke a wide char's right half
  if x + 1 < scrW and grid[i+1].ch == 0 and grid[i].ch != 0 and runeWidth(grid[i].ch.int) == 2:
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
    i += n
    if cp == 9: cp = 32
    elif cp < 32: cp = 0x2400 + cp
    elif cp == 127: cp = 0x2421
    let w = runeWidth(cp)
    if w == 0: continue
    if x + w > lim:
      while x < lim:
        setCell(x, y, Cell(ch: 32, fg: fg, bg: bg, at: at))
        inc x
      break
    setCell(x, y, Cell(ch: cp.uint32, fg: fg, bg: bg, at: at))
    if w == 2: setCell(x + 1, y, Cell(ch: 0, fg: fg, bg: bg, at: at))
    x += w
  x

var numStr: array[256, string]
for i in 0 .. 255: numStr[i] = $i

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

proc sameCell(a, b: Cell): bool {.inline.} =
  a.ch == b.ch and a.fg == b.fg and a.bg == b.bg and a.at == b.at

var cfgAccessible = false       # ui.accessible: ASCII for every box line and symbol, letters beside colours

proc asciiGlyph(cp: int): int =
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

proc flushScreen() =
  ## cell-level diff against what the terminal shows: unchanged rows cost one memcmp,
  ## changed rows only send the span that differs
  var o = newStringOfCap(8192)
  o.add "\e[?2026h\e[?25l"
  let full = prevGrid.len != grid.len
  if full:
    prevGrid.setLen(grid.len)
  for y in 0..<scrH:
    let base = y * scrW
    if not full and equalMem(addr grid[base], addr prevGrid[base], scrW * sizeof(Cell)): continue
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
    o.add $(y + 1)
    o.add ';'
    o.add $(x0 + 1)
    o.add 'H'
    var lf, lb: Rgb = 0xFFFFFFFF'u32
    var la: set[Attr] = {}
    var started = false
    var prevWide = false
    for x in x0 .. x1:
      let c = grid[base + x]
      var ch = c.ch.int
      if ch == 0:
        if prevWide:
          prevWide = false
          continue
        ch = 32
      let at = if cfgItalics: c.at else: c.at - {aItalic}   # many terminals/fonts have no italics
      if not started or c.fg != lf or c.bg != lb or at != la:
        o.add "\e[0"
        if aBold in at: o.add ";1"
        if aDim in at: o.add ";2"
        if aItalic in at: o.add ";3"
        if aUnder in at: o.add ";4"
        if aRev in at: o.add ";7"
        sgrColorFast(o, c.fg, true)
        sgrColorFast(o, c.bg, false)
        o.add 'm'
        lf = c.fg; lb = c.bg; la = at
        started = true
      if cfgAccessible and ch >= 128 and ch < 0x3000: ch = asciiGlyph(ch)
      if ch < 128: o.add char(ch) else: o.addUtf8(ch)
      prevWide = ch >= 0x1100 and runeWidth(ch) == 2
    copyMem(addr prevGrid[base], addr grid[base], scrW * sizeof(Cell))
  o.add "\e[0m"
  if cursorX >= 0 and cursorY >= 0 and cursorX < scrW and cursorY < scrH:
    o.add "\e[" & $(cursorY + 1) & ";" & $(cursorX + 1) & "H\e[?25h"
  o.add "\e[?2026l"
  writeAll(o)
