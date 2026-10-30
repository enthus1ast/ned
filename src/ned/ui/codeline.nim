# drawing one line of code in its syntax colours, without the cursor or selection, for places that show a line out of
# the editor (sticky headers, previews)
proc drawCodeLine(b: Buffer, l, x0, y, maxX: int, bg: Rgb, skipVc = 0) =
  ## one syntax-coloured line, no selection/cursor decorations (sticky headers, previews)
  let s = b.lines[l]
  var toks: seq[TokKind]
  if s.len <= 20000: discard lexLine(b.lang, s, b.stateAt(l)[0], toks)
  var i = 0
  var vc = 0
  let pads = if b.lang.mode == lmCsv: b.inlays.getOrDefault(l) else: @[]   # (a CSV header, lined up like the rows)
  var pk = 0
  var shift = 0
  while i < s.len:
    while pk < pads.len and pads[pk][0] <= i:
      shift += pads[pk][1].len
      inc pk
    let (cw, n) = charWidthAt(s, i, vc)
    let x = x0 + vc + shift - skipVc
    if x + cw > maxX:
      if x < maxX: discard putStr(maxX - 1, y, "…", theme.dim, bg)
      break
    if x >= x0 and cw > 0 and s[i] notin {' ', '\t'}:
      let tk = if i < toks.len: toks[i] else: tkText
      var (cp, _) = runeAt(s, i)
      if cp < 32: cp = 0x2400 + cp
      setCell(x, y, Cell(ch: (if n > 1 and cp >= 32: cellOf(s, i, n) else: cp.uint32), fg: theme.syn[tk], bg: bg,
                         at: (if tk in {tkComment, tkDoc}: {aItalic}
                              elif tk == tkKeyword and theme.boldKw: {aBold} else: {})))
      if cw == 2: setCell(x + 1, y, Cell(ch: 0, fg: theme.syn[tk], bg: bg))
    vc += cw
    i += n
