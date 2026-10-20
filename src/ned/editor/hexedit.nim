# ── the hex editor. A binary file opens as its bytes — offset · hex · text — to type over (or insert, Insert key),
#    delete, undo, search (bytes or text), go to an offset, and copy as hex, a Nim array or string, or a C array; a
#    data inspector reads the bytes at the cursor (integers both ways round, floats, a varint, UTF-8). An
#    executable (ELF, Mach-O, PE) shows what it is, and its sections and symbols — Nim's procs by their Nim
#    names, with their size — are a list to jump through; a Nim proc's source opens from there. Only what is on
#    the screen is drawn: a file of hundreds of megabytes scrolls as fast as a small one ──

func fmtSize(n: int): string =
  ## "812 bytes", "3.4 KB", "12.1 MB"
  if n < 1024: $n & " bytes"
  elif n < 1024 * 1024: formatFloat(n / 1024, ffDecimal, 1) & " KB"
  elif n < 1024 * 1024 * 1024: formatFloat(n / (1024 * 1024), ffDecimal, 1) & " MB"
  else: formatFloat(n / (1024 * 1024 * 1024), ffDecimal, 2) & " GB"

func hexUtf8(cp: int): string =
  ## a character's UTF-8 bytes (U+FFFD for what is no character)
  if cp < 0 or cp > 0x10FFFF: return "\xEF\xBF\xBD"
  if cp < 0x80: result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or (cp shr 18))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))

func hexSel(hx: HexState): (int, int) =
  ## the selected bytes, [a, e) — or the byte at the cursor when nothing is selected
  let n = hx.data.len
  if hx.anchor < 0 or hx.anchor == hx.cur: return (min(hx.cur, n), min(hx.cur + 1, n))
  (min(min(hx.anchor, hx.cur), n), min(max(hx.anchor, hx.cur) + 1, n))

func hexHasSel(hx: HexState): bool = hx.anchor >= 0 and hx.anchor != hx.cur

proc hexMarkChanged(hx: HexState, at, removed, added: int) =
  ## the changed ranges after `removed` bytes at `at` became `added` new ones (those after it move along)
  let delta = added - removed
  var keep: seq[(int, int)]
  for (a, e) in hx.changed:
    if e <= at: keep.add (a, e)
    elif a >= at + removed: keep.add (a + delta, e + delta)
    else: keep.add (min(a, at), max(at + added, e + delta))
  if added > 0: keep.add (at, at + added)
  hx.changed = keep
  if hx.changed.len > 2000:          # (many small edits: one range from the first to the last)
    var lo = high(int)
    var hi = 0
    for (a, e) in hx.changed:
      lo = min(lo, a)
      hi = max(hi, e)
    hx.changed = @[(lo, hi)]

proc hexApply(hx: HexState, e: HexEdit) =
  ## `old` at `at` replaced by `new`, in place (a big file is moved along, not copied)
  let oldN = clamp(e.old.len, 0, hx.data.len - e.at)
  if oldN == e.new.len:
    for i in 0 ..< oldN: hx.data[e.at + i] = e.new[i]
    return
  if oldN > 0: hx.data.delete(e.at .. e.at + oldN - 1)
  if e.new.len > 0: hx.data.insert(e.new, e.at)

proc hexReplace(b: Buffer, at, removeN: int, bytes: string) =
  ## replace removeN bytes at `at` with `bytes` (one undo step)
  let hx = b.hex
  let a = clamp(at, 0, hx.data.len)
  let n = clamp(removeN, 0, hx.data.len - a)
  let e = HexEdit(at: a, old: hx.data[a ..< a + n], new: bytes)
  if e.old == e.new: return
  if n == bytes.len:
    for i in 0 ..< n: hx.data[a + i] = bytes[i]        # (typing over: no copy of the whole file)
  else: hx.hexApply(e)
  hx.undo.add e
  hx.redo.setLen(0)
  if hx.savedAt > hx.undo.high: hx.savedAt = -1        # (the saved state cannot come back by redo any more)
  hx.hexMarkChanged(a, n, bytes.len)
  inc b.changeId
  needRender = true

proc hexUndo(b: Buffer, redo = false) =
  let hx = b.hex
  if (if redo: hx.redo.len == 0 else: hx.undo.len == 0):
    info(if redo: "Nothing to redo" else: "Nothing to undo")
    return
  let e = if redo: hx.redo.pop() else: hx.undo.pop()
  if redo:
    hx.hexApply(e)
    hx.undo.add e
    hx.hexMarkChanged(e.at, e.old.len, e.new.len)
    hx.cur = min(e.at + e.new.len, hx.data.len)
  else:
    hx.hexApply(HexEdit(at: e.at, old: e.new, new: e.old))
    hx.redo.add e
    hx.hexMarkChanged(e.at, e.new.len, e.old.len)
    hx.cur = min(e.at, hx.data.len)
  hx.anchor = -1
  hx.nibble = 0
  inc b.changeId
  needRender = true

proc hexDirty(b: Buffer): bool = b.hex != nil and b.hex.undo.len != b.hex.savedAt

# ── what the bytes at the cursor read as ──

proc hexLe(d: string, at, n: int, be = false): uint64 =
  for i in 0 ..< n:
    let k = if be: i else: n - 1 - i
    result = (result shl 8) or uint64(ord(d[at + k]))

proc hexInspect(hx: HexState): seq[string] =
  ## the bytes at the cursor as numbers: each a short "name value" (as many as there are bytes for)
  let d = hx.data
  let at = hx.cur
  let left = d.len - at
  if left <= 0: return @["(end of file)"]
  let u8 = ord(d[at])
  result.add "u8 " & $u8
  result.add "i8 " & $cast[int8](uint8(u8))
  var bits = ""
  for i in countdown(7, 0): bits.add (if ((u8 shr i) and 1) == 1: '1' else: '0')
  result.add "bits " & bits
  if left >= 2:
    result.add "u16 " & $hexLe(d, at, 2) & " · BE " & $hexLe(d, at, 2, true)
    result.add "i16 " & $cast[int16](uint16(hexLe(d, at, 2)))
  if left >= 4:
    result.add "u32 " & $hexLe(d, at, 4) & " · BE " & $hexLe(d, at, 4, true)
    result.add "i32 " & $cast[int32](uint32(hexLe(d, at, 4)))
    result.add "f32 " & $cast[float32](uint32(hexLe(d, at, 4)))
  if left >= 8:
    result.add "u64 " & $hexLe(d, at, 8)
    result.add "i64 " & $cast[int64](hexLe(d, at, 8))
    result.add "f64 " & $cast[float64](hexLe(d, at, 8))
  # an unsigned LEB128 varint (protobuf, wasm, DWARF)
  var v = 0'u64
  var shift = 0
  for i in 0 ..< min(10, left):
    let c = ord(d[at + i])
    v = v or (uint64(c and 0x7F) shl shift)
    shift += 7
    if (c and 0x80) == 0:
      result.add "varint " & $v & " (" & $(i + 1) & (if i == 0: " byte)" else: " bytes)")
      break
  # a UTF-8 character starting here
  if u8 >= 0xC0 and u8 < 0xF8:
    let n = if u8 >= 0xF0: 4 elif u8 >= 0xE0: 3 else: 2
    if left >= n:
      var ok = true
      for i in 1 ..< n:
        if (ord(d[at + i]) and 0xC0) != 0x80: ok = false
      if ok:
        let (cp, _) = runeAt(d, at)
        result.add "UTF-8 " & d[at ..< at + n] & " U+" & toHex(cp, 4)

# ── drawing ──

proc hexCellColour(c: char): Rgb =
  if c == '\0': theme.dim
  elif c in {' ' .. '~'}: theme.fg
  elif c in {'\t', '\n', '\r'}: theme.syn[tkString]
  elif ord(c) >= 0x80: theme.syn[tkNumber]
  else: theme.syn[tkKeyword]

proc hexInChanged(hx: HexState, i: int): bool =
  for (a, e) in hx.changed:
    if i >= a and i < e: return true
  false

proc hexSymbolAt(b: Buffer, off: int): int =
  ## the symbol whose bytes hold `off` (-1: none) — a Nim proc's when there is one
  result = -1
  let info = b.hexInfo()
  for i, s in info.symbols:
    if s.offset >= 0 and s.size > 0 and off >= s.offset and off < s.offset + s.size:
      if result < 0 or (s.nimName.len > 0 and info.symbols[result].nimName.len == 0): result = i

proc hexClickAt(b: Buffer, x, y: int)

proc drawHexView(b: Buffer, x0, y0, w, h: int, active: bool) =
  let hx = b.hex
  editorRect = (x0, y0, w, h)
  fillRect(x0, y0, w, h, theme.fg, theme.bg)
  let n = hx.data.len
  let offW = if n > 0xFFFF_FFFF: 12 else: 8
  hx.perRow = if w >= offW + 2 + 16 * 3 + 1 + 2 + 16: 16 elif w >= offW + 2 + 8 * 3 + 2 + 8: 8 else: 4
  let pr = hx.perRow
  let inspRows = if h >= 12: 2 else: 1
  let rows = max(1, h - 1 - inspRows)
  hx.rows = rows
  hx.cur = clamp(hx.cur, 0, n)
  let curRow = hx.cur div pr
  if curRow < hx.top: hx.top = curRow
  if curRow >= hx.top + rows: hx.top = curRow - rows + 1
  hx.top = clamp(hx.top, 0, max(0, n div pr))
  # ── the first line: what the file is, the mode, the cursor's offset
  let info = b.hexInfo()
  var head = ""
  if info.format.len > 0:
    head = info.format & " " & info.arch & " " & info.kind & (if info.nim: " · Nim" else: "")
  else: head = "binary"
  head.add " · " & fmtSize(n)
  var x = putStr(x0 + 1, y0, head, theme.accent, theme.bg, {aBold}, x0 + w)
  x = putStr(x + 2, y0, (if hx.insert: "INSERT" else: "OVERWRITE"), (if hx.insert: theme.warn else: theme.dim),
             theme.bg, {}, x0 + w)
  let (sa, se) = hx.hexSel()
  let posTxt = "0x" & toHex(hx.cur, offW).toLowerAscii & " (" & $hx.cur & ")" &
               (if hx.hexHasSel: " · " & $(se - sa) & " selected" else: "")
  x = putStr(x + 2, y0, posTxt, theme.fg, theme.bg, {}, x0 + w)
  let si = if info.symbols.len > 0: b.hexSymbolAt(hx.cur) else: -1
  if si >= 0:
    let s = info.symbols[si]
    x = putStr(x + 2, y0, "in " & (if s.nimName.len > 0: s.nimName & " (" & s.nimModule & ")" else: s.name),
               theme.syn[tkFunc], theme.bg, {}, x0 + w)
  if info.format.len > 0 and info.symbols.len > 0 and x + 12 < x0 + w:
    x = button(x + 2, y0, " Symbols ", proc() = runCmd("Hex: symbols…"), "The symbols, Nim's procs by their names",
               theme.fg, theme.btnBg)
    if info.nim and x + 14 < x0 + w:
      x = button(x + 1, y0, " Nim sizes ", proc() = runCmd("Hex: Nim modules by size"),
                 "How many bytes of code each Nim module takes", theme.fg, theme.btnBg)
  # ── the rows
  let hexX = x0 + offW + 2
  let gap = if pr >= 16: 1 else: 0
  let txtX = hexX + pr * 3 + gap + 1
  let bid = b.id
  for r in 0 ..< rows:
    let y = y0 + 1 + r
    let off = (hx.top + r) * pr
    if off > n: break
    discard putStr(x0, y, toHex(off, offW).toLowerAscii, theme.gutter, theme.bg)
    setCell(txtX - 1, y, Cell(ch: 0x2502, fg: theme.guide, bg: theme.bg))
    for j in 0 ..< pr:
      let i = off + j
      if i > n or (i == n and i != hx.cur): break
      let cx = hexX + j * 3 + (if j >= pr div 2 and gap > 0: gap else: 0)
      let tx = txtX + j
      let selected = hx.hexHasSel and i >= sa and i < se
      let changed = i < n and hx.hexInChanged(i)
      var bg = if selected: theme.sel else: theme.bg
      if i == hx.cur and not selected: bg = blend(theme.bg, theme.fg, 0.10)
      let c = if i < n: hx.data[i] else: ' '
      let fg = if changed: theme.warn elif i < n: hexCellColour(c) else: theme.dim
      let at: set[Attr] = if changed: {aBold} else: {}
      if i < n:
        let hs = toHex(ord(c), 2).toLowerAscii
        setCell(cx, y, Cell(ch: uint32(ord(hs[0])), fg: fg, bg: bg, at: at))
        setCell(cx + 1, y, Cell(ch: uint32(ord(hs[1])), fg: fg, bg: bg, at: at))
        let shown = if c in {' ' .. '~'}: uint32(ord(c)) else: uint32(ord('.'))
        setCell(tx, y, Cell(ch: shown, fg: (if c in {' ' .. '~'}: fg else: theme.dim), bg: bg, at: at))
      else:
        setCell(cx, y, Cell(ch: uint32(ord(' ')), fg: fg, bg: bg))
        setCell(cx + 1, y, Cell(ch: uint32(ord(' ')), fg: fg, bg: bg))
      if i == hx.cur and active and focus == fEditor and pickKind == pickNone:
        cursorX = if hx.ascii: tx else: cx + hx.nibble
        cursorY = y
        edCaretX = cursorX
        edCaretY = y
        # the twin of the cursor in the other column
        let ox = if hx.ascii: cx else: tx
        grid[y * scrW + ox].bg = blend(theme.bg, theme.accent, 0.30)
        if not hx.ascii: grid[y * scrW + cx + 1].bg = blend(theme.bg, theme.accent, 0.30)
    region(x0, y, w, 1, proc() =
      # (where the click was: the mouse's own place — a closure made in a loop would see the last row's)
      let bb = bufById(bid)
      if bb != nil and bb.hex != nil: bb.hexClickAt(mouseX, mouseY))
  # ── the data inspector
  let iy = y0 + h - inspRows
  fillRect(x0, iy, w, inspRows, theme.fg, theme.panelBg)
  let parts = hx.hexInspect()
  var line = 0
  var ix = x0 + 1
  for p in parts:
    let pw = strWidth(p) + 3
    if ix + pw > x0 + w:
      inc line
      ix = x0 + 1
      if line >= inspRows: break
    let sp = p.find(' ')
    let nx = putStr(ix, iy + line, p[0 ..< max(0, sp)], theme.dim, theme.panelBg, {}, x0 + w)
    ix = putStr(nx + 1, iy + line, p[sp + 1 .. ^1], theme.fg, theme.panelBg, {}, x0 + w) + 3

proc hexClickAt(b: Buffer, x, y: int) =
  ## a click on a row: the byte under it, in the column clicked
  let hx = b.hex
  let (x0, y0, _, _) = editorRect
  let offW = if hx.data.len > 0xFFFF_FFFF: 12 else: 8
  let pr = hx.perRow
  let gap = if pr >= 16: 1 else: 0
  let hexX = x0 + offW + 2
  let txtX = hexX + pr * 3 + gap + 1
  let rowOff = (hx.top + (y - y0 - 1)) * pr
  var j = -1
  if x >= txtX and x < txtX + pr:
    j = x - txtX
    hx.ascii = true
  elif x >= hexX and x < txtX - 1:
    var rel = x - hexX
    if gap > 0 and rel >= (pr div 2) * 3: rel -= gap
    j = clamp(rel div 3, 0, pr - 1)
    hx.ascii = false
  if j < 0: return
  hx.cur = clamp(rowOff + j, 0, hx.data.len)
  hx.anchor = -1
  hx.nibble = 0
  focus = fEditor
  needRender = true

# ── keys ──

proc hexParseBytes(s: string): (bool, string) =
  ## "de ad be ef", "deadbeef", "0xde, 0xad", "\xde\xad" → the bytes (false: not hex)
  var t = s.strip
  var res = ""
  var digits = ""
  var i = 0
  while i < t.len:
    let c = t[i]
    if c == '0' and i + 1 < t.len and t[i + 1] in {'x', 'X'} and digits.len == 0:
      i += 2
      continue
    if c == '\\' and i + 1 < t.len and t[i + 1] in {'x', 'X'}:
      i += 2
      continue
    if c in HexDigits:
      digits.add c
      if digits.len == 2:
        res.add char(parseHexInt(digits))
        digits = ""
    elif c in {' ', ',', ':', '-', '\'', 'u', '8'} or c in Whitespace:
      if c in {'u', '8'}:
        discard                                                   # ('u8 suffixes of a Nim array)
      elif digits.len == 1:
        res.add char(parseHexInt(digits))
        digits = ""
    else: return (false, "")
    inc i
  if digits.len == 1: res.add char(parseHexInt(digits))
  (res.len > 0, res)

proc hexGoto(b: Buffer, s: string) =
  let hx = b.hex
  var t = s.strip.replace("_", "")
  var rel = 0
  if t.startsWith("+"):
    rel = 1
    t = t[1 .. ^1]
  elif t.startsWith("-"):
    rel = -1
    t = t[1 .. ^1]
  var v = 0
  try:
    v = if t.startsWith("0x") or t.startsWith("0X"): parseHexInt(t[2 .. ^1])
        elif t.len > 0 and t[^1] in {'h', 'H'}: parseHexInt(t[0 ..< t.high])
        else: parseInt(t)
  except ValueError:
    error("Not an offset: " & s & " (8000, 0x1F40, +16, -0x10)")
    return
  hx.cur = clamp(if rel == 0: v else: hx.cur + rel * v, 0, hx.data.len)
  hx.anchor = -1
  hx.nibble = 0
  hx.top = max(0, hx.cur div hx.perRow - hx.rows div 3)
  needRender = true

proc hexFindNext(b: Buffer, back = false) =
  let hx = b.hex
  if hx.find.len == 0:
    info("Ctrl+F: bytes (de ad be ef) or text (\"abc\")")
    return
  var at = -1
  if back:
    if hx.cur > 0: at = hx.data.rfind(hx.find, last = hx.cur - 1 + hx.find.len - 1)
    if at < 0 or at >= hx.cur: at = hx.data.rfind(hx.find)
  else:
    at = hx.data.find(hx.find, hx.cur + 1)
    if at < 0: at = hx.data.find(hx.find)              # (from the start again)
  if at < 0:
    info("Not found")
    return
  hx.cur = at + hx.find.len - 1
  hx.anchor = at
  hx.nibble = 0
  hx.top = max(0, at div hx.perRow - hx.rows div 3)
  info("Found at 0x" & toHex(at, 8).toLowerAscii & " (" & $at & ")")
  needRender = true

proc hexFind(b: Buffer, q: string) =
  let t = q.strip
  var bytes = ""
  if t.len >= 2 and t[0] == '"' and t[^1] == '"': bytes = t[1 ..< t.high]
  else:
    let (ok, bs) = hexParseBytes(t)
    bytes = if ok: bs else: t                          # (not hex: the text itself)
  b.hex.find = bytes
  b.hexFindNext()

proc hexCopy(b: Buffer, how: string) =
  ## the selection (or the byte at the cursor) to the clipboard: "hex", "nim", "nimstr", "c", "text"
  let hx = b.hex
  let (a, e) = hx.hexSel()
  if e <= a:
    info("Nothing to copy")
    return
  let s = hx.data[a ..< e]
  var t = ""
  case how
  of "nim":
    t = "["
    for i, c in s:
      if i > 0: t.add (if i mod 12 == 0: ",\n  " else: ", ")
      t.add "0x" & toHex(ord(c), 2).toLowerAscii & (if i == 0: "'u8" else: "")
    t.add "]"
  of "nimstr":
    t = "\""
    for c in s: t.add "\\x" & toHex(ord(c), 2).toLowerAscii
    t.add "\""
  of "c":
    t = "{"
    for i, c in s:
      if i > 0: t.add (if i mod 12 == 0: ",\n  " else: ", ")
      t.add "0x" & toHex(ord(c), 2).toLowerAscii
    t.add "}"
  of "text": t = s
  else:
    for i, c in s:
      if i > 0: t.add ' '
      t.add toHex(ord(c), 2).toLowerAscii
  clipSet(t)
  info("Copied " & $s.len & (if s.len == 1: " byte" else: " bytes") & (case how
    of "nim": " as a Nim array"
    of "nimstr": " as a Nim string"
    of "c": " as a C array"
    of "text": " as text"
    else: " as hex"))

proc hexType(b: Buffer, bytes: string) =
  ## typed or pasted bytes: over the selection, or inserted, or over what is at the cursor
  let hx = b.hex
  if hx.hexHasSel:
    let (a, e) = hx.hexSel()
    b.hexReplace(a, e - a, bytes)
    hx.cur = a + bytes.len
  elif hx.insert or hx.cur >= hx.data.len:
    b.hexReplace(hx.cur, 0, bytes)
    hx.cur += bytes.len
  else:
    b.hexReplace(hx.cur, min(bytes.len, hx.data.len - hx.cur), bytes)
    hx.cur += bytes.len
  hx.anchor = -1
  hx.nibble = 0
  hx.cur = min(hx.cur, hx.data.len)

proc hexKey(b: Buffer, k: Key): bool =
  ## a key in the hex editor (false: not one of its own — the global shortcuts go on as usual)
  let hx = b.hex
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  let n = hx.data.len
  let pr = max(1, hx.perRow)
  proc move(to: int) =
    if shift:
      if hx.anchor < 0: hx.anchor = hx.cur
    else: hx.anchor = -1
    hx.cur = clamp(to, 0, n)
    hx.nibble = 0
    needRender = true
  case k.kind
  of kLeft:
    if alt: return false
    move(hx.cur - 1)
  of kRight:
    if alt: return false
    move(hx.cur + 1)
  of kUp:
    if alt: return false
    move(hx.cur - pr)
  of kDown:
    if alt: return false
    move(hx.cur + pr)
  of kPgUp: move(hx.cur - pr * max(1, hx.rows - 1))
  of kPgDn: move(hx.cur + pr * max(1, hx.rows - 1))
  of kHome: move(if ctrl: 0 else: hx.cur - hx.cur mod pr)
  of kEnd: move(if ctrl: n else: min(n, hx.cur - hx.cur mod pr + pr - 1))
  of kTab:
    if ctrl or alt: return false
    hx.ascii = not hx.ascii
    hx.nibble = 0
    needRender = true
  of kInsert:
    hx.insert = not hx.insert
    info(if hx.insert: "Insert: typing adds bytes" else: "Overwrite: typing replaces bytes")
    needRender = true
  of kEsc:
    if hx.anchor < 0 and hx.nibble == 0: return false
    hx.anchor = -1
    hx.nibble = 0
    needRender = true
  of kDelete:
    if hx.hexHasSel:
      let (a, e) = hx.hexSel()
      b.hexReplace(a, e - a, "")
      hx.cur = a
    elif hx.cur < n: b.hexReplace(hx.cur, 1, "")
    hx.anchor = -1
    hx.nibble = 0
  of kBackspace:
    if hx.hexHasSel:
      let (a, e) = hx.hexSel()
      b.hexReplace(a, e - a, "")
      hx.cur = a
    elif hx.insert and hx.cur > 0:
      b.hexReplace(hx.cur - 1, 1, "")
      dec hx.cur
    else: move(hx.cur - 1)
    hx.anchor = -1
    hx.nibble = 0
  of kFn:
    if k.fn == 3:
      b.hexFindNext(back = shift)
    else: return false
  of kPaste:
    let (ok, bs) = if hx.ascii: (false, "") else: hexParseBytes(k.text)
    b.hexType(if ok: bs else: k.text)
  of kChar:
    if ctrl and not alt:
      case k.ch
      of ord('z'): b.hexUndo(redo = shift)
      of ord('y'): b.hexUndo(redo = true)
      of ord('c'): b.hexCopy(if hx.ascii: "text" else: "hex")
      of ord('x'):
        b.hexCopy(if hx.ascii: "text" else: "hex")
        let (a, e) = hx.hexSel()
        b.hexReplace(a, e - a, "")
        hx.cur = a
        hx.anchor = -1
      of ord('v'):
        let t = clipGet()
        let (ok, bs) = if hx.ascii: (false, "") else: hexParseBytes(t)
        if t.len > 0: b.hexType(if ok: bs else: t)
      of ord('a'):
        hx.anchor = 0
        hx.cur = max(0, n - 1)
        needRender = true
      of ord('g'):
        let bid = b.id
        askText("Go to offset (8000, 0x1F40, +16, -0x10)", "", proc(t: string) =
          let bb = bufById(bid)
          if bb != nil and bb.hex != nil: bb.hexGoto(t))
      of ord('f'):
        let bid = b.id
        askText("Find bytes (de ad be ef) or text (\"abc\")", "", proc(t: string) =
          let bb = bufById(bid)
          if bb != nil and bb.hex != nil: bb.hexFind(t))
      else: return false
      return true
    if alt or k.ch < 32: return false
    if hx.ascii:
      b.hexType(hexUtf8(k.ch))
    else:
      let c = if k.ch < 128: char(k.ch) else: '\0'   # (a character beyond ASCII is no hex digit)
      if c notin HexDigits:
        info("Hex digits here (0-9, a-f) — Tab: the text column")
        return true
      let v = parseHexInt($c)
      if hx.nibble != 0 and hx.cur >= hx.data.len: hx.nibble = 0   # (the byte half typed is gone: start a new one)
      if hx.nibble == 0:
        let old = if hx.cur < n and not hx.insert: ord(hx.data[hx.cur]) else: 0
        let nb = char((v shl 4) or (old and 0x0F))
        if hx.hexHasSel:
          let (a, e) = hx.hexSel()
          b.hexReplace(a, e - a, $nb)
          hx.cur = a
          hx.anchor = -1
        elif hx.insert or hx.cur >= n: b.hexReplace(hx.cur, 0, $nb)
        else: b.hexReplace(hx.cur, 1, $nb)
        hx.nibble = 1
      else:
        let nb = char((ord(hx.data[hx.cur]) and 0xF0) or v)
        b.hexReplace(hx.cur, 1, $nb)
        hx.nibble = 0
        hx.cur = min(hx.cur + 1, hx.data.len)
  of kEnter:
    discard                         # (no lines in bytes: Enter does nothing here)
  else: return false
  true

# ── an executable's symbols and sections, Nim's modules by size ──

proc hexJump(b: Buffer, off: int64) =
  let hx = b.hex
  if off < 0 or off > hx.data.len:
    info("Not in the file (it is made when the program runs)")
    return
  hx.cur = int(off)
  hx.anchor = -1
  hx.nibble = 0
  hx.top = max(0, hx.cur div max(1, hx.perRow) - hx.rows div 3)
  needRender = true

proc nimSourceOf(module, name: string): (string, int) =
  ## the Nim file and line of proc `name` of `module` (a path like "app" or "std/strutils"), when ned finds them
  let base = module.split('/')[^1]
  var cands: seq[string]
  if rootDir.len > 0:
    for f in projectFiles():
      if f.endsWith("/" & base & ".nim") or f == base & ".nim": cands.add (if f.isAbsolute: f else: rootDir / f)
  if nxLibDir.len > 0:
    for d in [nxLibDir, nxLibDir / "std", nxLibDir / "pure", nxLibDir / "core", nxLibDir / "pure" / "collections",
              nxLibDir / "system"]:
      if fileExists(d / base & ".nim"): cands.add d / base & ".nim"
  for p in cands:
    let f = nxLoad(p)
    if f == nil: continue
    for s in f.syms:
      if s.kind in NxRoutineKinds and s.name == name: return (p, s.line)
  if cands.len > 0: return (cands[0], -1)
  ("", -1)

proc cmdHexSymbols() =
  let b = buf()
  if b.hex == nil:
    info("Open a binary file (a program, a library)")
    return
  let info0 = b.hexInfo()
  if info0.symbols.len == 0:
    info(if info0.format.len == 0: "Not a program ned can read (ELF, Mach-O, PE)" else: "No symbols (stripped)")
    return
  var items: seq[(string, string, proc() {.closure.})]
  var order: seq[int]
  for i, s in info0.symbols:
    if s.offset >= 0: order.add i
  # (Nim's procs first, the biggest first)
  order.sort(proc(x, y: int): int =
    let a = info0.symbols[x]
    let c = info0.symbols[y]
    cmp((c.nimName.len > 0, c.size), (a.nimName.len > 0, a.size)))
  let bid = b.id
  for i in order:
    let s = info0.symbols[i]
    let label = if s.nimName.len > 0: s.nimName & "  (" & s.nimModule & ")" else: s.name
    let detail = (if s.code: "code" else: "data") & " · " & $s.size & " bytes · 0x" & toHex(s.offset, 8).toLowerAscii &
                 (if s.nimName.len > 0: " · " & s.name else: "")
    let off = s.offset
    capture off:                                  # (each item its own offset: closures in a loop share one)
      items.add (label, detail, proc() =
        let bb = bufById(bid)
        if bb != nil and bb.hex != nil: bb.hexJump(off))
    if items.len >= 5000: break
  openActions("Symbols — " & $info0.symbols.len & (if info0.nim: " (Nim's procs by their Nim names)" else: ""), items)

proc cmdHexSections() =
  let b = buf()
  if b.hex == nil: return
  let info0 = b.hexInfo()
  if info0.sections.len == 0:
    info("No sections: not a program ned can read (ELF, Mach-O, PE)")
    return
  var items: seq[(string, string, proc() {.closure.})]
  let bid = b.id
  for s in info0.sections:
    let off = s.offset
    let detail = fmtSize(int(s.size)) & (if off >= 0: " · at 0x" & toHex(off, 8).toLowerAscii else: " · not in the file") &
                 " · loaded at 0x" & toHex(s.address, 8).toLowerAscii
    let label = s.name
    capture off:
      items.add (label, detail, proc() =
        let bb = bufById(bid)
        if bb != nil and bb.hex != nil: bb.hexJump(off))
  openActions("Sections — " & info0.format & " " & info0.arch, items)

proc cmdHexNimSizes() =
  let b = buf()
  if b.hex == nil: return
  let info0 = b.hexInfo()
  let sizes = nimSizes(info0)
  if sizes.len == 0:
    info(if info0.nim: "No Nim symbols left (stripped: build without -d:strip to see them)" else: "Not built by Nim")
    return
  var total = 0'i64
  for (_, by, _) in sizes: total += by
  var items: seq[(string, string, proc() {.closure.})]
  for (m, by, cnt) in sizes:
    let mm = m
    let detail = fmtSize(int(by)) & " · " & $cnt & " procs · " &
                 formatFloat(100.0 * float(by) / float(max(1, total)), ffDecimal, 1) & "%"
    capture mm:
      items.add (mm, detail, proc() =
        # the module's procs, the biggest first
        let bb = buf()
        if bb.hex == nil: return
        var its: seq[(string, string, proc() {.closure.})]
        var syms: seq[BinSymbol]
        for s in bb.hexInfo().symbols:
          if s.nimModule == mm and s.code: syms.add s
        syms.sort(proc(x, y: BinSymbol): int = cmp(y.size, x.size))
        let bid = bb.id
        for s in syms:
          let off = s.offset
          let (lab, det) = (s.nimName, $s.size & " bytes · " & s.name)
          capture off:
            its.add (lab, det, proc() =
              let x = bufById(bid)
              if x != nil and x.hex != nil: x.hexJump(off))
        openActions(mm & " — its procs by size", its))
  openActions("Nim modules by the bytes of code they take — " & fmtSize(int(total)) & " in all", items)

proc cmdHexOpenSource() =
  ## the Nim source of the proc whose bytes the cursor is on
  let b = buf()
  if b.hex == nil: return
  let si = b.hexSymbolAt(b.hex.cur)
  if si < 0:
    info("The cursor is on no symbol's bytes — Hex: symbols… lists them")
    return
  let s = b.hexInfo().symbols[si]
  if s.nimName.len == 0:
    info(s.name & " is no Nim proc")
    return
  let (p, l) = nimSourceOf(s.nimModule, s.nimName)
  if p.len == 0:
    info("ned does not find " & s.nimModule & ".nim (the program's sources are not in this project)")
    return
  pushJump()
  let nb = openFile(p)
  if nb != nil and l >= 0: nb.centerOn(Pos(line: l, col: 0))

proc cmdHexAsText() =
  ## the file opened as text after all (not saved as text: a binary file's bytes stay as they are on disk)
  let b = buf()
  if b.hex == nil:
    info("This file is open as text")
    return
  if b.hexDirty:
    error("Save or undo the changes first")
    return
  var t = b.hex.data
  for c in t.mitems:
    if c == '\0': c = ' '
  b.hex = nil
  b.binary = false
  b.readOnly = true
  b.setContent(t)
  info("Shown as text, read-only (its NULs as spaces) — reopen the file for the hex editor")
  needRender = true
