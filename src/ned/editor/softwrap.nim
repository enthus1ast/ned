# ════════════════════════════════════════════════════════════════════════════
#  Visual layout helpers (soft wrap)
# ════════════════════════════════════════════════════════════════════════════

# ── very long lines (minified JSON, JS, CSS; a log on one line): where each 16 KB of the line starts on the screen,
#    made only as far as something needs and kept for each such line; an edit within the line drops only the marks
#    after it. The cursor's column (the status bar, drawing it, keeping it in view) and the first character shown
#    when scrolled to the right are found from the nearest mark instead of from the start of the line — a frame of a
#    5 MB line took 22 ms, most of it counting columns from the start, and typing in one 2.4 ms before 6.41 (0.5) ──

const
  VcLongLine = 32_768                  # lines this long get marks
  VcStep = 16_384                      # (about) bytes between two marks

type
  VcLine = object                      # one long line's marks
    m: seq[(int, int)]                 # (byte, visual column) at character boundaries, the first (0, 0)
    at, atVc: int                      # how far they are made: the byte the counting got to, and its visual column
  VcMarks = object
    change, tab: int                   # the buffer's changeId and the tab width they were made for
    joined: bool                       # (and whether the terminal joins grapheme clusters: their widths differ)
    lines: Table[int, VcLine]

var vcMarks: Table[int, VcMarks]       # buffer id → its long lines' marks

proc vcExtend(s: string, v: var VcLine, limit: int) =
  ## the marks of a long line made on to byte `limit` (or the end of the line): a mark about every 16 KB. Plain ASCII
  ## is counted eight bytes at a time
  var i = v.at
  var vc = v.atVc
  var next = (if v.m.len > 0: v.m[^1][0] else: 0) + VcStep
  let stop = min(limit, s.len)
  while i < stop:
    if i >= next:
      v.m.add (i, vc)
      next = i + VcStep
    if i + 8 <= s.len and printable8(s, i) and (i + 8 >= s.len or s[i + 8].uint8 < 0x80):
      vc += 8
      i += 8
      continue
    let (w, n) = charWidthAt(s, i, vc)
    vc += w
    i += n
  v.at = i
  v.atVc = vc

proc vcLineOf(b: Buffer, line: int): ptr VcLine =
  ## a long line's marks as far as they are made, kept per buffer; all of a buffer's marks are dropped when its text
  ## changed (other than by an edit within one long line, which vcLineEdited follows), or the tab width or the
  ## grapheme-joining setting did
  if b.id notin vcMarks or vcMarks[b.id].change != b.changeId or vcMarks[b.id].tab != tabW or
     vcMarks[b.id].joined != graphemes:
    vcMarks[b.id] = VcMarks(change: b.changeId, tab: tabW, joined: graphemes)
  if line notin vcMarks[b.id].lines: vcMarks[b.id].lines[line] = VcLine(m: @[(0, 0)])
  addr vcMarks[b.id].lines[line]

proc vcMarksOf(b: Buffer, line: int, upTo = int.high): seq[(int, int)] =
  ## the marks of a long line, made at least as far as byte `upTo` (the whole line by default)
  let v = b.vcLineOf(line)
  if v.at < min(upTo, b.lines[line].len): vcExtend(b.lines[line], v[], max(upTo, v.at + VcStep))
  v.m

proc vcLineEdited(b: Buffer, line, col: int) =
  ## (rawReplace, after an edit within one long line) the line's marks from `col` on are no longer right: they go and
  ## are made again when needed; those before it — and every other line's — stay, so typing in a 5 MB line counts
  ## columns only from the edit on, and only as far as the screen needs
  vcMarks.withValue(b.id, vm):
    if vm.change != b.changeId - 1: return            # (already stale: they all go at the next look)
    vm.change = b.changeId
    vm.lines.withValue(line, v):
      let keep = col - 64                             # (a little before: a joining character may change the one before)
      var k = v.m.len
      while k > 1 and v.m[k - 1][0] > keep: dec k
      v.m.setLen(k)
      if v.at > v.m[^1][0]:
        v.at = v.m[^1][0]
        v.atVc = v.m[^1][1]

proc visColAt(b: Buffer, line, col: int): int =
  ## the visual column of byte `col` of a line (on a very long line: counted from the nearest mark)
  if line < 0 or line >= b.lines.len: return 0
  if b.lines[line].len < VcLongLine: return visColOf(b.lines[line], col)
  let m = b.vcMarksOf(line, col + 1)
  var lo = 0
  var hi = m.high
  while lo < hi:                          # (the last mark at or before col)
    let mid = (lo + hi + 1) div 2
    if m[mid][0] <= col: lo = mid else: hi = mid - 1
  visColFrom(b.lines[line], col, m[lo][0], m[lo][1])

proc vcMarkBefore(b: Buffer, line, vcol: int): (int, int) =
  ## the last mark of a long line at or before visual column `vcol`: (byte, visual column)
  let v = b.vcLineOf(line)
  while v.at < b.lines[line].len and v.atVc <= vcol: vcExtend(b.lines[line], v[], v.at + 4 * VcStep)
  let m = v.m
  var lo = 0
  var hi = m.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if m[mid][1] <= vcol: lo = mid else: hi = mid - 1
  m[lo]

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

func subRowOf(segs: seq[int], col: int): int =
  ## the screen row within a wrapped line (0 for the first) that the byte column falls on, given the byte offsets where
  ## its rows start
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

proc vrowCount(b: Buffer, line: int): int {.inline.} =
  ## the rows drawn under a line that are not its text (a notebook cell's output)
  if b.vrows.len == 0: return 0
  b.vrows.withValue(line, v): return v[].len

proc segCount(b: Buffer, line: int): int =
  ## the rows a line takes on the screen: its own (more than one when soft wrap breaks it), and those under it
  if line < 0 or line >= b.lines.len: return 1
  (if not cfgWrap: 1 else: b.lineSegs(line).len) + b.vrowCount(line)

proc stepBack(b: Buffer, line, sub, n: int): (int, int) =
  ## the (line, wrapped row) that is n screen rows above the given one, counting the rows of wrapped lines and skipping
  ## folded lines; stops at the top of the buffer
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
  ## how many screen rows lie between (line l1, row s1) and (l2, s2); -1 when the second is above the first, and it
  ## stops adding once the count passes `limit` so it stays quick on a long file
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
  ## scrolls the view just enough to show the main cursor with the scroll-off margin of rows around it, moving the first
  ## visible line and row; without wrapping it also scrolls sideways to keep the cursor's column in view, with wrapping
  ## the sideways scroll is reset
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
    let vx = b.visColAt(c.line, c.col)
    let margin = min(4, textW div 4)
    if vx < b.leftCol + margin: b.leftCol = max(0, vx - margin)
    elif vx >= b.leftCol + textW - margin: b.leftCol = vx - textW + margin + 1
  else:
    b.leftCol = 0

proc scrollBy(b: Buffer, rows: int) =
  ## scrolls the view by screen rows (positive is down), through wrapped rows and over folds, without moving the cursor;
  ## remembers the cursor and text as they are so the next draw does not scroll back to the cursor
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
