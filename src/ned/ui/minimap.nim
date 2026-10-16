# ── minimap ──

var
  mmStart = 0
  minimapShown = false

proc minimapWidth(w: int): int =
  case cfgMinimap
  of "off": 0
  of "on": (if w >= 40: 10 else: 0)
  else: (if w >= 100 and not lay.overlay: 10 else: 0)

proc drawMinimap(b: Buffer, x0, y0, w, h: int) =
  let bg = theme.bg
  fillRect(x0, y0, w, h, theme.minimap, bg)
  let total = b.lines.len
  let cap = h * 4
  var start = 0
  if total > cap:
    let vis = max(1, textH)
    start = clamp(b.topLine * (total - cap) div max(1, total - vis), 0, total - cap)
  mmStart = start
  let vpA = b.topLine
  let vpB = b.topLine + textH
  let ds = diagsFor(b.path)
  var diagLines: HashSet[int]
  for d in ds:
    if d.sev <= 2: diagLines.incl d.line
  for row in 0 ..< h:
    let l0 = start + row * 4
    if l0 >= total: break
    let inView = l0 + 3 >= vpA and l0 < vpB
    let rbg = if inView: blend(bg, theme.fg, 0.10) else: bg
    var hasErr = false
    for cx in 0 ..< w:
      var bits = 0
      for dy in 0 .. 3:
        let l = l0 + dy
        if l >= total: break
        if l in diagLines: hasErr = true
        let s = b.lines[l]
        for dx in 0 .. 1:
          let c0 = (cx * 2 + dx) * 4
          var on = false
          for k in c0 ..< min(s.len, c0 + 4):
            if s[k] notin {' ', '\t'}:
              on = true
              break
          if on:
            bits = bits or (if dx == 0: [0x01, 0x02, 0x04, 0x40][dy] else: [0x08, 0x10, 0x20, 0x80][dy])
      setCell(x0 + cx, y0 + row, Cell(ch: uint32(0x2800 + bits), fg: (if hasErr: theme.err else: theme.minimap), bg: rbg))
  mmRect = (x0, y0, w, h)
  mmFirst = mmStart
  region(x0, y0, w, h, proc() =
    let line = mmStart + (mouseY - y0) * 4
    let bb = buf()
    bb.topLine = clamp(line - textH div 2, 0, bb.lines.high)
    bb.topSub = 0
    bb.setSingle(bb.clampPos(Pos(line: clamp(line, 0, bb.lines.high), col: 0)))
    bb.lastHead = bb.primary.head
    bb.lastChange = bb.changeId, "Minimap")
