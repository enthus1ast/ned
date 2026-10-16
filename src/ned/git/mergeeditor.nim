# ── the merge editor: ours and theirs side by side above the result (the file itself, with its markers) ──

type MergeSide = object
  buf: Buffer                          # this side's whole text (for colours)
  rows: seq[int]                       # display rows: a line of `buf`, or -1 where this side has nothing
  spans: seq[(int, int)]               # each conflict: its display rows [a, b)

var mergeCache: Table[int, (int, MergeSide, MergeSide, string, string)]

proc mergeSidesFor(b: Buffer): (MergeSide, MergeSide, string, string) =
  ## both sides of every conflict, with the text around them (cached per change)
  if b.id in mergeCache and mergeCache[b.id][0] == b.changeId:
    let c = mergeCache[b.id]
    return (c[1], c[2], c[3], c[4])
  var ol, tl: seq[string]
  var os, ts: MergeSide
  var oLab, tLab = ""
  let cs = b.conflictsOf()
  var l = 0
  var ci = 0
  while l < b.lines.len:
    if ci < cs.len and l == cs[ci].start:
      let c = cs[ci]
      let oursEnd = if c.base >= 0: c.base else: c.mid
      if oLab.len == 0: oLab = b.lines[c.start][min(7, b.lines[c.start].len) .. ^1].strip
      if tLab.len == 0: tLab = b.lines[c.stop][min(7, b.lines[c.stop].len) .. ^1].strip
      let oa = os.rows.len
      for k in c.start + 1 ..< oursEnd:
        os.rows.add ol.len
        ol.add b.lines[k]
      let ta = ts.rows.len
      for k in c.mid + 1 ..< c.stop:
        ts.rows.add tl.len
        tl.add b.lines[k]
      # the two sides get the same height, so the text after a conflict lines up
      while os.rows.len - oa < ts.rows.len - ta: os.rows.add -1
      while ts.rows.len - ta < os.rows.len - oa: ts.rows.add -1
      if os.rows.len == oa:                # both empty (rare): one row to show where it was
        os.rows.add -1
        ts.rows.add -1
      os.spans.add (oa, os.rows.len)
      ts.spans.add (ta, ts.rows.len)
      l = c.stop + 1
      inc ci
    else:
      os.rows.add ol.len
      ol.add b.lines[l]
      ts.rows.add tl.len
      tl.add b.lines[l]
      inc l
  for (side, text) in [(addr os, ol), (addr ts, tl)]:
    let tb = newBuffer()
    tb.lang = b.lang
    tb.setContent(text.join("\n"))
    side[].buf = tb
  if oLab.len == 0: oLab = "HEAD"
  if tLab.len == 0: tLab = "incoming"
  mergeCache[b.id] = (b.changeId, os, ts, oLab, tLab)
  (os, ts, oLab, tLab)

proc mergeCurrent(b: Buffer): int =
  ## the conflict the panes follow: the one at the cursor, else the next one below it, else the last one
  let cs = b.conflictsOf()
  if cs.len == 0: return -1
  let l = b.primary.head.line
  for i, c in cs:
    if l <= c.stop: return i
  cs.high

proc drawMergeSide(side: MergeSide, cur, x0, y0, w, h: int, title, label: string, accent: Rgb, accept: Action) =
  let hb = theme.crumbBg
  fillRect(x0, y0, w, 1, theme.fg, hb)
  var x = putStr(x0 + 1, y0, title, accent, hb, {aBold})
  x = putStr(x + 1, y0, truncTo(label, max(4, w div 3)), theme.dim, hb)
  if accept != nil and x + 12 < x0 + w:
    discard button(x + 2, y0, " ✓ Accept " & title.toLowerAscii & " ", accept, "Use this side for the conflict",
                   theme.fg, theme.btnBg)
  let bodyH = h - 1
  if bodyH <= 0: return
  let tb = side.buf
  var top = 0
  if cur >= 0 and cur < side.spans.len: top = max(0, side.spans[cur][0] - bodyH div 3)
  top = min(top, max(0, side.rows.len - bodyH))
  let numW = max(3, len($max(1, tb.lines.len)))
  for r in 0 ..< bodyH:
    let ri = top + r
    let y = y0 + 1 + r
    if ri >= side.rows.len: break
    var bg = theme.bg
    var inSpan = -1
    for k, (a, e) in side.spans:
      if ri >= a and ri < e: inSpan = k
    if inSpan >= 0: bg = blend(theme.bg, accent, (if inSpan == cur: 0.24 else: 0.11))
    fillRect(x0, y, w, 1, theme.fg, bg)
    let l = side.rows[ri]
    if l < 0:
      discard putStr(x0 + numW + 1, y, "⋯", theme.dim, bg)
      continue
    discard putStr(x0, y, align($(l + 1), numW), (if inSpan >= 0: accent else: theme.dim), bg)
    drawCodeLine(tb, l, x0 + numW + 1, y, x0 + w, bg)

proc mergeGo(d: int) =
  let b = buf()
  let cs = b.conflictsOf()
  if cs.len == 0: return
  var i = b.mergeCurrent()
  if b.conflictAt(b.primary.head.line) >= 0 or d < 0: i = (i + d + cs.len) mod cs.len
  b.setSingle(Pos(line: cs[i].start, col: 0))
  b.centerOn(Pos(line: cs[i].start, col: 0))

proc mergeAccept(choice: string) =
  let b = buf()
  let i = b.mergeCurrent()
  if i < 0: return
  b.resolveConflict(i, choice)
  let cs = b.conflictsOf()
  if cs.len > 0:                         # on to the next one
    let n = min(i, cs.high)
    b.setSingle(Pos(line: cs[n].start, col: 0))
    b.centerOn(Pos(line: cs[n].start, col: 0))

proc mergeClose(b: Buffer) =
  mergeViews.excl b.id
  mergeCache.del b.id
  needRender = true

proc drawMergeView(b: Buffer, x0, y0, w, h: int, active: bool) =
  let (os, ts, oLab, tLab) = mergeSidesFor(b)
  let cur = b.mergeCurrent()
  let topH = max(6, (h - 1) * 2 div 5)
  let lw = (w - 1) div 2
  let rw = w - lw - 1
  drawMergeSide(os, cur, x0, y0, lw, topH, "Ours", oLab, theme.gitAdd,
                (if cur >= 0: (proc() = mergeAccept("ours")) else: nil))
  for yy in y0 ..< y0 + topH: discard putStr(x0 + lw, yy, "│", theme.border, theme.bg)
  drawMergeSide(ts, cur, x0 + lw + 1, y0, rw, topH, "Theirs", tLab, theme.info,
                (if cur >= 0: (proc() = mergeAccept("theirs")) else: nil))
  # the result: the file, editable as usual
  let hy = y0 + topH
  let hb = theme.crumbBg
  fillRect(x0, hy, w, 1, theme.fg, hb)
  let n = b.conflictsOf().len
  var x = putStr(x0 + 1, hy, "Result", theme.accent, hb, {aBold})
  x = putStr(x + 1, hy, (if n == 0: "✓ no conflicts left" elif n == 1: "1 conflict left" else: $n & " conflicts left"),
             (if n == 0: theme.gitAdd else: theme.warn), hb)
  x += 2
  if n > 0:
    x = button(x, hy, " ◀ Previous ", proc() = mergeGo(-1), "The conflict before", theme.fg, theme.btnBg) + 1
    x = button(x, hy, " Next ▶ ", proc() = mergeGo(1), "The next conflict", theme.fg, theme.btnBg) + 1
    x = button(x, hy, " Accept both ", proc() = mergeAccept("both"), "Ours, then theirs", theme.fg, theme.btnBg) + 1
  else:
    let rel = relPath(b.path)
    x = button(x, hy, " Save and stage ", proc() =
      let bb = buf()
      if bb.dirty: discard bb.saveBuffer()
      gitRun(@["add", "--", rel], "Staged " & rel)
      bb.mergeClose(), "git add the resolved file", theme.fg, theme.btnBg) + 1
  if x + 9 < x0 + w:
    discard button(x0 + w - 9, hy, " Close ", proc() = buf().mergeClose(), "Back to the plain editor", theme.fg, theme.btnBg)
  mergeInner = true
  try: drawEditor(b, x0, hy + 1, w, h - topH - 1, active)
  finally: mergeInner = false

proc cmdMergeEditor() =
  let b = buf()
  if b.id in mergeViews:
    b.mergeClose()
    return
  if b.conflictsOf().len == 0:
    info("No merge conflicts in this file")
    return
  mergeViews.incl b.id
  let cs = b.conflictsOf()
  if b.conflictAt(b.primary.head.line) < 0: b.centerOn(Pos(line: cs[0].start, col: 0))
  info("Merge editor: ours | theirs above, the result below — Accept on either side, or edit the result")

proc render()
