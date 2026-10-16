# ── expand / shrink selection ──

var selStack: seq[seq[Cursor]]

proc expandSelection() =
  let b = buf()
  let (a, e) = b.primary.range
  var cands: seq[(Pos, Pos)]
  let (wa, we) = b.wordRangeAt(b.primary.head)
  if wa != we: cands.add (wa, we)
  for obj in ['"', '\'', '(', '[', '{']:
    for kind in ['i', 'a']:
      let (ok, x, y) = b.textObject(kind, obj, b.primary.head)
      if ok and x != y: cands.add (x, y)
  let ls = b.lines[a.line]
  cands.add (Pos(line: a.line, col: leadingWs(ls).len), Pos(line: e.line, col: b.lines[e.line].len))
  cands.add (Pos(line: a.line, col: 0), Pos(line: min(b.lines.high, e.line + 1), col: 0))
  let h = b.foldHeaderFor(a.line)
  if h >= 0:
    let (_, fe) = b.foldRange(h)
    cands.add (Pos(line: h, col: 0), Pos(line: fe, col: b.lines[fe].len))
  cands.add (Pos(), Pos(line: b.lines.high, col: b.lines[^1].len))
  var best = (Pos(line: -1), Pos())
  var bestSize = high(int)
  for (x, y) in cands:
    if x <= a and e <= y and (x < a or e < y):
      let size = (y.line - x.line) * 100000 + (y.col - x.col)
      if size < bestSize:
        bestSize = size
        best = (x, y)
  if best[0].line < 0: return
  selStack.add b.cursors
  b.setSingle(best[1], best[0])

proc shrinkSelection() =
  if selStack.len == 0: return
  let b = buf()
  b.cursors = selStack.pop()
  b.prim = 0
  b.normalize()
