# ── a side-by-side diff: lines aligned, removed red on the left, added green on the right, changed words marked ──

type
  DiffRow = object
    a, b: int              # line on the left / on the right (-1: a filler row)
    kind: char             # ' ' same · '-' removed · '+' added · '~' changed
  DiffView = ref object
    left, right: seq[string]
    src: int               # the right side is this live buffer (0: the fixed `right` text)
    leftTitle, rightTitle: string
    rows: seq[DiffRow]
    at: int
    built: bool

var diffViews: Table[int, DiffView]

proc diffRight(v: DiffView): seq[string] =
  if v.src != 0:
    let s = bufById(v.src)
    if s != nil: return s.lines
  v.right

proc diffRows(v: DiffView) =
  let s = if v.src != 0: bufById(v.src) else: nil
  let ch = if s != nil: s.changeId else: 0
  if v.built and v.at == ch: return
  v.built = true
  v.at = ch
  let ops = lineDiff(v.left, v.diffRight())
  v.rows.setLen(0)
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      v.rows.add DiffRow(a: ops[i].aLine, b: ops[i].bLine, kind: ' ')
      inc i
      continue
    var dels, adds: seq[int]
    while i < ops.len and ops[i].kind != ' ':
      if ops[i].kind == '-': dels.add ops[i].aLine
      else: adds.add ops[i].bLine
      inc i
    for k in 0 ..< max(dels.len, adds.len):
      let a = if k < dels.len: dels[k] else: -1
      let b = if k < adds.len: adds[k] else: -1
      v.rows.add DiffRow(a: a, b: b, kind: (if a >= 0 and b >= 0: '~' elif a >= 0: '-' else: '+'))

func diffSpan(x, y: string): (int, int, int) =
  ## the changed part of two similar lines: common prefix length, and where the change ends in each
  var p = 0
  while p < x.len and p < y.len and x[p] == y[p]: inc p
  var ex = x.len
  var ey = y.len
  while ex > p and ey > p and x[ex - 1] == y[ey - 1]:
    dec ex
    dec ey
  (p, ex, ey)

proc drawDiffSide(text: string, num, numW, x, y, w: int, lang: Lang, bg, hiBg: Rgb, ha, he: int) =
  fillRect(x, y, w, 1, theme.fg, bg)
  discard putStr(x, y, (if num >= 0: align($(num + 1), numW) else: spaces(numW)), theme.gutter, bg)
  var toks: seq[TokKind]
  var st: LexSt = 0
  st = lexLine(lang, text, st, toks)
  var cx = x + numW + 1
  let lim = x + w
  var i = 0
  var vc = 0
  while i < text.len and cx < lim:
    let (cw, n) = charWidthAt(text, i, vc)
    if cx + cw > lim: break
    let cbg = if i >= ha and i < he: hiBg else: bg
    let fg = theme.syn[if i < toks.len: toks[i] else: tkText]
    if text[i] == '\t': discard putStr(cx, y, spaces(cw), fg, cbg)
    else: discard putStr(cx, y, text[i ..< i + n], fg, cbg)
    cx += cw
    vc += cw
    i += n

proc diffRevertAt(v: DiffView, ri: int)

proc drawDiffView(b: Buffer, x0, y0, w, h: int) =
  let v = diffViews[b.id]
  v.diffRows()
  let n = max(1, v.rows.len)
  if b.lines.len != n:
    b.lines = newSeq[string](n)
    b.primary.head.line = min(b.primary.head.line, n - 1)
  cursorX = -1
  cursorY = -1
  let rowsH = max(1, h - 1)
  let hd = b.primary.head.line
  if hd != viewHead.getOrDefault(b.id, -1):
    viewHead[b.id] = hd
    if hd < b.topLine: b.topLine = hd
    if hd >= b.topLine + rowsH: b.topLine = hd - rowsH + 1
  b.topLine = clamp(b.topLine, 0, max(0, n - 1))
  let right = v.diffRight()
  let half = (w - 1) div 2
  let numW = max(3, len($max(v.left.len, right.len)))
  var changes = 0
  for k, r in v.rows:
    if r.kind != ' ' and (k == 0 or v.rows[k - 1].kind == ' '): inc changes
  let hbg = theme.crumbBg
  fillRect(x0, y0, w, 1, theme.fg, hbg)
  discard putStr(x0 + 1, y0, truncTo(v.leftTitle, half - 2), theme.dim, hbg)
  let help = $changes & " change" & (if changes == 1: "" else: "s") & " · F7 next · Enter opens" &
             (if v.src != 0: " · r reverts" else: "")
  let rt = truncTo(v.rightTitle, max(4, w - half - 3))
  discard putStr(x0 + half + 2, y0, rt, theme.fg, hbg, {aBold})
  # the keys: in full when there is room, shorter when not, at least the number of changes
  let room = w - (half + 2 + strWidth(rt) + 3)
  let short = $changes & " · F7 · ↵" & (if v.src != 0: " · r" else: "")
  let shown = if strWidth(help) <= room: help elif strWidth(short) <= room: short
              elif strWidth($changes) <= room: $changes else: ""
  if shown.len > 0: discard putStr(x0 + w - strWidth(shown) - 1, y0, shown, theme.dim, hbg)
  let delBg = blend(theme.bg, theme.gitDel, 0.16)
  let delHi = blend(theme.bg, theme.gitDel, 0.40)
  let addBg = blend(theme.bg, theme.gitAdd, 0.14)
  let addHi = blend(theme.bg, theme.gitAdd, 0.36)
  let fill = blend(theme.bg, theme.fg, 0.04)
  for row in 0 ..< rowsH:
    let ri = b.topLine + row
    let y = y0 + 1 + row
    if ri >= v.rows.len: break
    let r = v.rows[ri]
    let lt = if r.a >= 0 and r.a < v.left.len: v.left[r.a] else: ""
    let rtx = if r.b >= 0 and r.b < right.len: right[r.b] else: ""
    var (p, ea, eb) = (0, 0, 0)
    if r.kind == '~': (p, ea, eb) = diffSpan(lt, rtx)
    let cur = ri == hd
    # left
    if r.a < 0:
      fillRect(x0, y, half, 1, blend(theme.bg, theme.fg, 0.12), fill)
      for xx in countup(x0 + numW + 1, x0 + half - 1, 2): discard putStr(xx, y, "╱", blend(fill, theme.fg, 0.12), fill)
    else:
      drawDiffSide(lt, r.a, numW, x0, y, half, b.lang, (if r.kind in {'-', '~'}: delBg else: theme.bg), delHi, p, ea)
    # the divider: the current row, and a revert button on each change
    let dx = x0 + half
    if r.kind != ' ' and (ri == 0 or v.rows[ri - 1].kind == ' ') and v.src != 0:
      let rr = ri
      capture rr:
        discard button(dx, y, "⟲", proc() = diffRevertAt(diffViews[b.id], rr), "Revert this change", theme.accent, theme.bg)
    else: discard putStr(dx, y, (if cur: "▶" else: "│"), (if cur: theme.accent else: theme.splitBar), theme.bg)
    # right
    if r.b < 0:
      fillRect(dx + 1, y, w - half - 1, 1, blend(theme.bg, theme.fg, 0.12), fill)
      for xx in countup(dx + 2 + numW, x0 + w - 1, 2): discard putStr(xx, y, "╱", blend(fill, theme.fg, 0.12), fill)
    else:
      drawDiffSide(rtx, r.b, numW, dx + 1, y, w - half - 1, b.lang, (if r.kind in {'+', '~'}: addBg else: theme.bg), addHi, p, eb)
    if cur and r.kind == ' ':
      for xx in x0 ..< x0 + w:
        let gi = y * scrW + xx
        if gi < grid.len: grid[gi].bg = blend(grid[gi].bg, theme.fg, 0.06)

proc drawMdPreview(b: Buffer, x0, y0, w, h: int) =
  ## a Markdown preview: the source rendered (headings, lists, code), scrolling like a file
  let src = bufById(b.mdSrc)
  cursorX = -1
  cursorY = -1
  if src == nil:
    discard putStr(x0 + 2, y0 + 1, "The Markdown file was closed", theme.dim, theme.bg)
    return
  let tw = max(20, min(w - 4, 100))
  var c = mdPreviewCache.getOrDefault(b.id, (-1, -1, @[]))
  # (a Nim file's docs: made again after a pause in the typing, not at every key)
  let wait = b.mdNimDocs and c[2].len > 0 and c[1] == tw and msSince(lastInputAt) < 400
  if (c[0] != src.changeId or c[1] != tw) and not wait:
    c = (src.changeId, tw, markdownLines((if b.mdNimDocs: docPvText(src) else: src.lines.join("\n")), tw, theme.bg))
    mdPreviewCache[b.id] = c
    b.lines = newSeq[string](max(1, c[2].len))
  let hd = b.primary.head.line
  if hd != viewHead.getOrDefault(b.id, -1):
    viewHead[b.id] = hd
    if hd < b.topLine: b.topLine = hd
    if hd >= b.topLine + h: b.topLine = hd - h + 1
  b.topLine = clamp(b.topLine, 0, max(0, c[2].len - 1))
  drawDocLines(c[2], x0 + 2, y0, tw, h, b.topLine, theme.bg)
