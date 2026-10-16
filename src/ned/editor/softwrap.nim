# ════════════════════════════════════════════════════════════════════════════
#  Visual layout helpers (soft wrap)
# ════════════════════════════════════════════════════════════════════════════

proc contIndent(s: string, width: int): int =
  ## hanging indent for wrapped continuation rows
  if not cfgWrap: return 0
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  min(visColOf(s, i), width div 2)

proc wrapSegs(s: string, width: int, extra: seq[(int, int)] = @[]): seq[int] =
  ## byte offsets where each visual row of a line starts (`extra`: (column, width) of what is drawn between the
  ## characters — type hints — which wraps with them)
  result = @[0]
  if not cfgWrap or width < 8 or s.len == 0: return
  let ci = contIndent(s, width)
  var i = 0
  var vc = 0
  var segVc = 0
  var lastBreak = -1
  var lastBreakVc = 0
  while i < s.len:
    let (w, n) = charWidthAt(s, i, vc)
    let rowW = if result.len == 1: width else: width - ci
    var hv = 0                                  # the hints on this row so far (one just before this character too)
    for (c, ew) in extra:
      if c >= result[^1] and c <= i: hv += ew
    if vc + w - segVc + hv > rowW and i > result[^1]:
      if lastBreak > result[^1] and lastBreak <= i:
        result.add lastBreak
        segVc = lastBreakVc
      else:
        result.add i
        segVc = vc
      lastBreak = -1
      continue
    if s[i] == ' ' or s[i] == '\t':
      lastBreak = i + n
      lastBreakVc = vc + w
    vc += w
    i += n

proc subRowOf(segs: seq[int], col: int): int =
  result = 0
  for k in 1 ..< segs.len:
    if segs[k] <= col: result = k else: break

proc hintWidths(b: Buffer, line: int): seq[(int, int)] =
  ## the type hints drawn on a line, as (column, width): soft wrap makes room for them
  if not cfgWrap or b.inlays.len == 0 or line notin b.inlays or not (cfgInlayHints or b.lang.mode == lmCsv): return
  let s = b.lines[line]
  for (col, label) in b.inlays[line]:
    if col > s.len: continue
    if label.strip.startsWith(":") and (col == 0 or s[col - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '`', '\x80'..'\xFF'}):
      continue
    result.add (col, strWidth(label))

proc lineSegs(b: Buffer, line: int): seq[int] =
  ## where each visual row of a line starts, its type hints counted
  wrapSegs(b.lines[line], textW, b.hintWidths(line))

proc segCount(b: Buffer, line: int): int =
  if not cfgWrap or line < 0 or line >= b.lines.len: 1 else: b.lineSegs(line).len

proc stepBack(b: Buffer, line, sub, n: int): (int, int) =
  var l = clamp(line, 0, b.lines.high)
  var s = if l == line: sub else: 0
  var k = n
  while k > 0:
    if s > 0: dec s
    elif l > 0:
      l = if b.folds.len > 0: max(0, b.prevVisible(l)) else: l - 1
      s = b.segCount(l) - 1
    else: break
    dec k
  (l, s)

proc rowDist(b: Buffer, l1, s1, l2, s2, limit: int): int =
  if l1 == l2: return s2 - s1
  if l2 < l1: return -1
  var r = b.segCount(l1) - s1
  var l = if b.folds.len > 0: b.nextVisible(l1) else: l1 + 1
  while l < l2:
    r += b.segCount(l)
    if r > limit: return r
    l = if b.folds.len > 0: b.nextVisible(l) else: l + 1
  r + s2

proc ensureVisible(b: Buffer) =
  let h = max(1, textH)
  let c = b.cursors[b.prim].head
  let sub = if cfgWrap: subRowOf(b.lineSegs(c.line), c.col) else: 0
  let so = min(cfgScrollOff, (h - 1) div 2)
  let (tl, ts) = b.stepBack(c.line, sub, so)
  if b.topLine > tl or (b.topLine == tl and b.topSub > ts):
    b.topLine = tl
    b.topSub = ts
  else:
    let d = b.rowDist(b.topLine, b.topSub, c.line, sub, h + 10)
    if d > h - 1 - so or d < 0:
      (b.topLine, b.topSub) = b.stepBack(c.line, sub, h - 1 - so)
  if not cfgWrap:
    let vx = visColOf(b.lines[c.line], c.col)
    let margin = min(4, textW div 4)
    if vx < b.leftCol + margin: b.leftCol = max(0, vx - margin)
    elif vx >= b.leftCol + textW - margin: b.leftCol = vx - textW + margin + 1
  else:
    b.leftCol = 0

proc scrollBy(b: Buffer, rows: int) =
  if b.topLine > b.lines.high or b.topLine < 0:     # the text shrank under a stale scroll position
    b.topLine = clamp(b.topLine, 0, b.lines.high)
    b.topSub = 0
  if rows > 0:
    var k = rows
    while k > 0:
      if b.topSub + 1 < b.segCount(b.topLine): inc b.topSub
      elif (if b.folds.len > 0: b.nextVisible(b.topLine) else: b.topLine + 1) < b.lines.len:
        b.topLine = if b.folds.len > 0: b.nextVisible(b.topLine) else: b.topLine + 1
        b.topSub = 0
      else: break
      dec k
  else:
    (b.topLine, b.topSub) = b.stepBack(b.topLine, b.topSub, -rows)
  b.lastHead = b.cursors[b.prim].head
  b.lastChange = b.changeId
  needRender = true
