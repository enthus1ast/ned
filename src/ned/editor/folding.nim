# ════════════════════════════════════════════════════════════════════════════
#  IDE features: folding, inlay hints, tests, project symbols, code actions,
#  expand selection, gutter actions, gdb
# ════════════════════════════════════════════════════════════════════════════

# ── folding (indentation based; works for every language) ──

proc foldRange(b: Buffer, l: int): (bool, int) =
  ## the block that starts at line l: the language server's range when it gave one, else the lines indented
  ## deeper than l
  if l < 0 or l >= b.lines.high or isBlank(b.lines[l]): return (false, l)
  if b.lspFolds.len > 0 and b.lspFoldsAt == b.changeId and l in b.lspFolds:
    return (true, min(b.lspFolds[l], b.lines.high))
  let ind = visColOf(b.lines[l], leadingWs(b.lines[l]).len)
  var k = l + 1
  var last = l
  while k < b.lines.len:
    let s = b.lines[k]
    if not isBlank(s):
      if visColOf(s, leadingWs(s).len) <= ind: break
      last = k
    inc k
  (last > l, last)

proc foldHeaderFor(b: Buffer, l: int): int =
  ## innermost foldable header containing line l (or l itself)
  let (ok, _) = b.foldRange(l)
  if ok: return l
  let ind = if isBlank(b.lines[l]): high(int) else: visColOf(b.lines[l], leadingWs(b.lines[l]).len)
  for k in countdown(l - 1, max(0, l - 5000)):
    let s = b.lines[k]
    if isBlank(s): continue
    if visColOf(s, leadingWs(s).len) < ind:
      let (ok2, e) = b.foldRange(k)
      if ok2 and e >= l: return k
  -1

proc addFold(b: Buffer, s, e: int) =
  ## folds lines s..e (the first line stays shown): folds it swallows are dropped, a block inside an already folded one
  ## is ignored, and the list stays sorted by first line
  var keep: seq[(int, int)]
  for f in b.folds:
    if f[0] >= s and f[1] <= e: continue        # swallowed
    if s > f[0] and s <= f[1]: return           # inside a folded block already
    keep.add f
  keep.add (s, e)
  keep.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
  b.folds = keep

proc foldLine(b: Buffer, l: int) =
  ## folds the innermost block around line `l`; a cursor that was inside it moves to the block's first line
  let h = b.foldHeaderFor(l)
  if h < 0:
    info("Nothing to fold here")
    return
  let (_, e) = b.foldRange(h)
  b.addFold(h, e)
  let p = b.primary.head
  if p.line > h and p.line <= e: b.setSingle(Pos(line: h, col: min(p.col, b.lines[h].len)))

proc toggleFold(b: Buffer, l: int) =
  ## opens the fold at (or hiding) line `l`, or folds the block around it when there is none
  if b.foldAt(l) >= 0 or b.isHidden(l): b.unfoldLine(l) else: b.foldLine(l)

proc foldAllAt(b: Buffer, level: int) =
  ## fold every block whose header sits at indentation `level` (0 = top level)
  let unit = max(1, b.indentW())
  b.folds.setLen(0)
  var l = 0
  while l < b.lines.high:
    let s = b.lines[l]
    if not isBlank(s) and visColOf(s, leadingWs(s).len) div unit == level:
      let (ok, e) = b.foldRange(l)
      if ok:
        b.folds.add (l, e)
        l = e + 1
        continue
    inc l
  let p = b.primary.head
  if b.isHidden(p.line):
    for (s, e) in b.folds:
      if p.line > s and p.line <= e: b.setSingle(Pos(line: s, col: 0))
