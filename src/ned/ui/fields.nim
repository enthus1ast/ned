# ── one-line fields drawn: the text in view, its selection, and the mouse in it (a press places the cursor, a drag
#    selects, a double click a word, a triple click everything) — every field ned draws goes through drawField ──

var
  fieldDragText: ptr string       # the field being dragged in
  fieldDragCur: ptr int
  fieldDragX, fieldDragBi = 0     # where its text starts on screen, and the first byte shown there
  fieldDragSecret = false
  fieldClickAt: MonoTime
  fieldClicks, fieldClickX = 0

func fieldBulletByte(text: string, k: int): int =
  ## (a secret field shows a • per character) the byte where character k starts
  var i = 0
  var n = 0
  while i < text.len and n < k:
    i = nextRune(text, i)
    inc n
  i

func fieldRunes(text: string, a, b: int): int =
  var i = a
  while i < b and i < text.len:
    i = nextRune(text, i)
    inc result

proc fieldByteAt(text: string, bi, x0, x: int, secret: bool): int =
  ## the byte under screen column x of a field whose text (from byte bi) starts at x0
  if secret: return fieldBulletByte(text, fieldRunes(text, 0, bi) + max(0, x - x0))
  colAtVis(text, visColOf(text, bi) + max(0, x - x0))

proc fieldPress(tp: ptr string, cp: ptr int, x0, bi: int, secret: bool) =
  let idx = clamp(fieldByteAt(tp[], bi, x0, mouseX, secret), 0, tp[].len)
  if msSince(fieldClickAt) < 450 and abs(mouseX - fieldClickX) <= 1 and fieldDragText == tp: inc fieldClicks
  else: fieldClicks = 1
  fieldClickAt = getMonoTime()
  fieldClickX = mouseX
  case fieldClicks
  of 2:
    var a = fieldWordStart(tp[], idx)
    var b = fieldWordEnd(tp[], idx)
    if a == b: b = min(tp[].len, nextCluster(tp[], a))
    fieldSelect(tp[], a, b)
    cp[] = b
  of 3:
    fieldSelect(tp[], 0, tp[].len)
    cp[] = tp[].len
  else:
    fieldSelect(tp[], idx, idx)
    cp[] = idx
  fieldDragText = tp
  fieldDragCur = cp
  fieldDragX = x0
  fieldDragBi = bi
  fieldDragSecret = secret
  if fieldClicks == 1: dragTarget = dtField
  needRender = true

proc fieldDragTo(x: int) =
  if fieldDragText == nil or fieldDragCur == nil: return
  fieldDragCur[] = clamp(fieldByteAt(fieldDragText[], fieldDragBi, fieldDragX, x, fieldDragSecret), 0,
                         fieldDragText[].len)
  needRender = true

proc drawField(x, y, w: int, text: var string, cur: var int, focused: bool, fg: Rgb = NoColor, bg: Rgb = NoColor,
               placeholder = "", secret = false, onFocus: Action = nil, hintFocused = false): int =
  ## the field's text, scrolled so the cursor shows, its selection shaded; returns the cursor's screen x (-1 when
  ## the field does not have the focus). A press in it calls onFocus, then places the cursor (or selects).
  result = -1
  if w <= 0: return
  let fgc = if fg == NoColor: theme.fg else: fg
  let bgc = if bg == NoColor: theme.inputBg else: bg
  cur = clamp(cur, 0, text.len)
  fillRect(x, y, w, 1, fgc, bgc)
  var bi = 0
  var curVis = 0
  if secret:
    let n = fieldRunes(text, 0, cur)
    let off = max(0, n - w + 1)
    bi = fieldBulletByte(text, off)
    curVis = n - off
    discard putStr(x, y, "•".repeat(fieldRunes(text, bi, text.len)), fgc, bgc, {}, x + w)
  else:
    let cv = strWidth(text[0 ..< cur])
    let off = max(0, cv - w + 1)
    bi = colAtVis(text, off)
    curVis = cv - visColOf(text, bi)
    if text.len == 0 and placeholder.len > 0 and (hintFocused or not focused):
      discard putStr(x, y, placeholder, theme.dim, bgc, {aItalic}, x + w)
    else:
      discard putStr(x, y, text[bi .. ^1], fgc, bgc, {}, x + w)
  if focused:
    let (a, b) = fieldSelRange(text, cur)
    if b > a:
      let xa = x + (if secret: fieldRunes(text, bi, max(bi, a)) else: strWidth(text[bi ..< max(bi, a)]))
      let xb = x + (if secret: fieldRunes(text, bi, max(bi, b)) else: strWidth(text[bi ..< max(bi, b)]))
      for xx in max(x, xa) ..< min(x + w, xb):
        grid[y * scrW + xx].bg = theme.sel
    result = x + curVis
  let tp = addr text
  let cp = addr cur
  let x0 = x
  let b0 = bi
  let sec = secret
  let foc = onFocus
  region(x, y, w, 1, proc() =
    if foc != nil: foc()
    fieldPress(tp, cp, x0, b0, sec), "", proc() =
    if foc != nil: foc()
    ctxOpen(fieldMenu(tp, cp)))
