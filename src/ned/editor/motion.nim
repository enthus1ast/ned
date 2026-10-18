# ════════════════════════════════════════════════════════════════════════════
#  Cursor movement
# ════════════════════════════════════════════════════════════════════════════

func charClass(c: char): int {.inline.} =
  if c in {' ', '\t'}: 0 elif isWordByte(c): 1 else: 2

func posLeft(b: Buffer, p: Pos): Pos =
  if p.col > 0: Pos(line: p.line, col: prevRune(b.lines[p.line], p.col))
  elif p.line > 0: Pos(line: p.line - 1, col: b.lines[p.line - 1].len)
  else: p

func posRight(b: Buffer, p: Pos): Pos =
  let s = b.lines[p.line]
  if p.col < s.len: Pos(line: p.line, col: nextRune(s, p.col))
  elif p.line + 1 < b.lines.len: Pos(line: p.line + 1, col: 0)
  else: p

func posWordRight(b: Buffer, p: Pos): Pos =
  let s = b.lines[p.line]
  var i = p.col
  if i >= s.len:
    return (if p.line + 1 < b.lines.len: Pos(line: p.line + 1, col: 0) else: p)
  while i < s.len and charClass(s[i]) == 0: inc i
  if i < s.len:
    let k = charClass(s[i])
    while i < s.len and charClass(s[i]) == k: inc i
  Pos(line: p.line, col: i)

func posWordLeft(b: Buffer, p: Pos): Pos =
  if p.col == 0:
    return (if p.line > 0: Pos(line: p.line - 1, col: b.lines[p.line - 1].len) else: p)
  let s = b.lines[p.line]
  var i = p.col
  while i > 0 and charClass(s[i-1]) == 0: dec i
  if i > 0:
    let k = charClass(s[i-1])
    while i > 0 and charClass(s[i-1]) == k: dec i
  Pos(line: p.line, col: i)

func posHome(b: Buffer, p: Pos): Pos =
  let s = b.lines[p.line]
  let fnw = leadingWs(s).len
  Pos(line: p.line, col: (if p.col == fnw: 0 else: fnw))

proc moveVert(b: Buffer, c: var Cursor, dy: int) =
  var line = c.head.line
  var segs = b.lineSegs(line)
  var sub = subRowOf(segs, c.head.col)
  let s0 = b.lines[line]
  let x = if c.goalX >= 0: c.goalX
          else: visColOf(s0, c.head.col) - visColOf(s0, segs[sub]) + (if sub > 0: contIndent(s0, textW) else: 0)
  var k = abs(dy)
  while k > 0:
    if dy > 0:
      if sub + 1 < segs.len: inc sub
      elif (if b.folds.len > 0: b.nextVisible(line) else: line + 1) < b.lines.len:
        line = if b.folds.len > 0: b.nextVisible(line) else: line + 1
        segs = b.lineSegs(line)
        sub = 0
      else:
        c.head = Pos(line: line, col: b.lines[line].len)
        c.goalX = x
        return
    else:
      if sub > 0: dec sub
      elif line > 0:
        line = if b.folds.len > 0: max(0, b.prevVisible(line)) else: line - 1
        segs = b.lineSegs(line)
        sub = segs.high
      else:
        c.head = Pos(line: 0, col: 0)
        c.goalX = x
        return
    dec k
  let s = b.lines[line]
  let segStart = segs[sub]
  let base = visColOf(s, segStart)
  let rx = max(0, x - (if sub > 0: contIndent(s, textW) else: 0))
  var col = colAtVis(s, base + rx, segStart, base)
  if sub + 1 < segs.len and col >= segs[sub + 1]: col = prevRune(s, segs[sub + 1])
  c.head = Pos(line: line, col: col)
  c.goalX = x

proc moveAll(b: Buffer, select: bool, f: proc(b: Buffer, c: var Cursor)) =
  for c in b.cursors.mitems:
    f(b, c)
    if not select: c.anchor = c.head
  b.normalize()

proc cmdMove(kind: KeyKind, select, word: bool) =
  let b = buf()
  case kind
  of kLeft:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      c.goalX = -1
      if c.hasSel and not select: c.head = c.range[0]
      else: c.head = (if word: b.posWordLeft(c.head) else: b.posLeft(c.head)))
  of kRight:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      c.goalX = -1
      if c.hasSel and not select: c.head = c.range[1]
      else: c.head = (if word: b.posWordRight(c.head) else: b.posRight(c.head)))
  of kUp:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      if c.hasSel and not select:
        c.head = c.range[0]
        c.goalX = -1
      b.moveVert(c, -1))
  of kDown:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      if c.hasSel and not select:
        c.head = c.range[1]
        c.goalX = -1
      b.moveVert(c, 1))
  of kHome:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      c.goalX = -1
      c.head = (if word: Pos() else: b.posHome(c.head)))
  of kEnd:
    b.moveAll(select, proc(b: Buffer, c: var Cursor) =
      c.goalX = -1
      c.head = (if word: Pos(line: b.lines.high, col: b.lines[^1].len)
                else: Pos(line: c.head.line, col: b.lines[c.head.line].len)))
  of kPgUp, kPgDn:
    let n = max(1, textH - 2) * (if kind == kPgUp: -1 else: 1)
    b.moveAll(select, proc(b: Buffer, c: var Cursor) = b.moveVert(c, n))
    b.scrollBy(n)
  else: discard
