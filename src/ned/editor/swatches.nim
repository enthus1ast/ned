# ── colour swatches: a small block before #RRGGBB, rgb(…), hsl(…) and Nim's 0xRRGGBB (editor.colorSwatches) ──

const SwatchMark = "■"

func hexNib(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

func hexColour(h: string): (bool, int, int, int, float) =
  ## "f80", "f80c", "ff8800", "ff8800cc" → (ok, r, g, b, alpha)
  for c in h:
    if hexNib(c) < 0: return
  case h.len
  of 3, 4:
    let a = if h.len == 4: float(hexNib(h[3]) * 17) / 255.0 else: 1.0
    (true, hexNib(h[0]) * 17, hexNib(h[1]) * 17, hexNib(h[2]) * 17, a)
  of 6, 8:
    let a = if h.len == 8: float(hexNib(h[6]) * 16 + hexNib(h[7])) / 255.0 else: 1.0
    (true, hexNib(h[0]) * 16 + hexNib(h[1]), hexNib(h[2]) * 16 + hexNib(h[3]), hexNib(h[4]) * 16 + hexNib(h[5]), a)
  else: (false, 0, 0, 0, 1.0)

proc hslToRgb(h, s, l: float): (int, int, int) =
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  var hd = h
  while hd < 0.0: hd += 360.0
  while hd >= 360.0: hd -= 360.0
  let hh = hd / 60.0
  let x = c * (1.0 - abs(hh - 2.0 * float(int(hh / 2.0)) - 1.0))
  var (r, g, b) = (0.0, 0.0, 0.0)
  if hh < 1: (r, g, b) = (c, x, 0.0)
  elif hh < 2: (r, g, b) = (x, c, 0.0)
  elif hh < 3: (r, g, b) = (0.0, c, x)
  elif hh < 4: (r, g, b) = (0.0, x, c)
  elif hh < 5: (r, g, b) = (x, 0.0, c)
  else: (r, g, b) = (c, 0.0, x)
  let m = l - c / 2.0
  (clamp(int((r + m) * 255.0 + 0.5), 0, 255), clamp(int((g + m) * 255.0 + 0.5), 0, 255),
   clamp(int((b + m) * 255.0 + 0.5), 0, 255))

func rgbToHsl(r, g, b: int): (int, int, int) =
  let rf = r.float / 255.0
  let gf = g.float / 255.0
  let bf = b.float / 255.0
  let mx = max(rf, max(gf, bf))
  let mn = min(rf, min(gf, bf))
  let l = (mx + mn) / 2.0
  var h, s = 0.0
  if mx != mn:
    let d = mx - mn
    s = if l > 0.5: d / (2.0 - mx - mn) else: d / (mx + mn)
    h = if mx == rf: (gf - bf) / d + (if gf < bf: 6.0 else: 0.0)
        elif mx == gf: (bf - rf) / d + 2.0
        else: (rf - gf) / d + 4.0
    h *= 60.0
  (int(h + 0.5) mod 360, int(s * 100.0 + 0.5), int(l * 100.0 + 0.5))

func cssNum(t: string, scale: float): float =
  ## "255", "50%", "120deg", "0.5" → a number (percentages of `scale`)
  var x = t.strip
  var pct = false
  if x.endsWith("%"):
    pct = true
    x = x[0 ..< x.high]
  elif x.endsWith("deg"): x = x[0 ..< x.len - 3]
  try: (if pct: parseFloat(x) * scale / 100.0 else: parseFloat(x))
  except ValueError: NaN

proc colourSwatches(lang: Lang, s: string, toks: seq[TokKind]): seq[(int, int, Rgb)] =
  ## colours on a line: (column, length of the text, the colour as it shows on this theme)
  let css = lang.mode in {lmCss, lmHtml}
  let nim = lang.mode == lmNim
  var i = 0
  while i < s.len and result.len < 24:
    let c = s[i]
    let tk = if i < toks.len: toks[i] else: tkText
    if tk in {tkComment, tkDoc} and lang.mode != lmHtml:
      inc i
      continue
    if c == '#' and (css or tk in {tkString, tkChar}) and (i == 0 or s[i - 1] notin IdentChars + {'&'}):
      var e = i + 1
      while e < s.len and s[e] in HexDigits: inc e
      let n = e - i - 1
      let whole = i > 0 and s[i - 1] in {'"', '\''} and e < s.len and s[e] in {'"', '\''}
      if n in [3, 4, 6, 8] and (e >= s.len or s[e] notin IdentChars) and (css or n in [6, 8] or whole):
        let (ok, r, g, b, a) = hexColour(s[i + 1 ..< e])
        if ok:
          result.add (i, e - i, blend(theme.bg, Rgb((r shl 16) or (g shl 8) or b), a))
          i = e
          continue
    elif css and (i == 0 or s[i - 1] notin IdentChars) and i + 4 < s.len and
         (s.continuesWith("rgb", i) or s.continuesWith("hsl", i)):
      let o = s.find('(', i)
      let cl = s.find(')', i)
      if o in i + 3 .. i + 4 and cl > o:
        var parts: seq[string]
        for x in s[o + 1 ..< cl].split({',', ' ', '/'}):
          if x.len > 0: parts.add x
        if parts.len >= 3:
          let a = if parts.len >= 4: cssNum(parts[3], 1.0) else: 1.0
          var col = -1
          if s.continuesWith("rgb", i):
            let (r, g, b) = (cssNum(parts[0], 255), cssNum(parts[1], 255), cssNum(parts[2], 255))
            if r == r and g == g and b == b:
              col = (clamp(int(r + 0.5), 0, 255) shl 16) or (clamp(int(g + 0.5), 0, 255) shl 8) or clamp(int(b + 0.5), 0, 255)
          else:
            let (h, sat, l) = (cssNum(parts[0], 360), cssNum(parts[1], 1), cssNum(parts[2], 1))
            if h == h and sat == sat and l == l:
              let (r, g, b) = hslToRgb(h, clamp(sat, 0.0, 1.0), clamp(l, 0.0, 1.0))
              col = (r shl 16) or (g shl 8) or b
          if col >= 0:
            result.add (i, cl - i + 1, blend(theme.bg, Rgb(col), (if a == a: clamp(a, 0.0, 1.0) else: 1.0)))
            i = cl + 1
            continue
    elif nim and c == '0' and i + 7 < s.len and s[i + 1] in {'x', 'X'} and tk == tkNumber and
         (i == 0 or s[i - 1] notin IdentChars):
      var e = i + 2
      while e < s.len and s[e] in HexDigits: inc e
      if e - i - 2 == 6 and (e >= s.len or s[e] notin IdentChars or s[e] == '\''):
        let (ok, r, g, b, _) = hexColour(s[i + 2 ..< e])
        if ok:
          result.add (i, e - i, Rgb((r shl 16) or (g shl 8) or b))
          i = e
          continue
    inc i

var decorOverlay: seq[(int, string)]
  ## set by lineDecor: hints drawn over the spaces that follow their column (an aligned `=`), (column, text)

func declShape(s: string): (bool, int, int, int) =
  ## a declaration lined up on its `=` — `name = …`, `name*: T   = …`: (it is one, indentation, where the spaces
  ## before the `=` start, the `=`'s column)
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  let ind = i
  if i >= s.len: return
  if s[i] == '`':
    let e = s.find('`', i + 1)
    if e < 0: return
    i = e + 1
  else:
    if s[i] notin IdentStartChars: return
    while i < s.len and s[i] in IdentChars: inc i
  if i < s.len and s[i] == '*': inc i
  var padStart = i
  var k = i
  while k < s.len and s[k] == ' ': inc k
  if k < s.len and s[k] == ':':
    # an explicit type: up to the `=` outside brackets
    var d = 0
    var q = k + 1
    while q < s.len:
      let c = s[q]
      if c in {'[', '(', '{'}: inc d
      elif c in {']', ')', '}'}: dec d
      elif c in {'"', '\''}: return
      elif c == '=' and d == 0: break
      inc q
    if q >= s.len: return
    var e = q
    while e > k and s[e - 1] == ' ': dec e
    padStart = e
    k = q
  if k >= s.len or s[k] != '=' or k == padStart or (k + 1 < s.len and s[k + 1] in {'=', '>', '<'}): return
  for q in padStart ..< k:
    if s[q] != ' ': return
  (true, ind, padStart, k)

proc typeHintAt(b: Buffer, line, col: int): string =
  ## the type hint (`: int`) drawn at a column of a line, or ""
  if cfgInlayHints and line in b.inlays:
    for (c, lb) in b.inlays[line]:
      if c == col and lb.strip.startsWith(":"): return lb

proc lineDecor(b: Buffer, line: int, toks: seq[TokKind], sw: seq[(int, int, Rgb)]): seq[(int, string)] =
  ## what is drawn between the characters of a line: inlay hints and colour swatches, in column order
  decorOverlay.setLen(0)
  if (cfgInlayHints or b.lang.mode == lmCsv) and line in b.inlays: result = b.lineInlays(line, toks)
  if cfgInlayHints and b.lang.mode == lmNim and line < b.lines.len and b.lines[line].len < 400 and
     (not cfgWrap or b.lineSegs(line).len == 1):
    # declarations lined up on their `=` (nim.format.align): a type hint goes over the spaces before the `=`, and
    # every line of the run moves its `=` by the same amount — they stay lined up, with hints or without
    let (ok, ind, padStart, eq) = declShape(b.lines[line])
    if ok:
      var a = line
      var e = line
      while a > 0 and line - a < 200:
        let (ok2, ind2, _, eq2) = declShape(b.lines[a - 1])
        if not ok2 or ind2 != ind or eq2 != eq: break
        dec a
      while e < b.lines.high and e - line < 200:
        let (ok2, ind2, _, eq2) = declShape(b.lines[e + 1])
        if not ok2 or ind2 != ind or eq2 != eq: break
        inc e
      var target = eq
      var anyHint = false
      for l in a .. e:
        let (_, _, ps, _) = declShape(b.lines[l])
        let h = b.typeHintAt(l, ps)
        if h.len > 0:
          anyHint = true
          target = max(target, ps + strWidth(h) + 1)
      if anyHint:
        let own = b.typeHintAt(line, padStart)
        var keep: seq[(int, string)]
        for (c, lb) in result:
          if not (c == padStart and lb == own): keep.add (c, lb)
        result = keep
        if target > eq: result.add (padStart, spaces(target - eq))
        if own.len > 0: decorOverlay.add (padStart, own)
        result.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  if cfgShowCopies and b.id in copyMarks and line in copyMarks[b.id] and line < b.lines.len:
    # where ARC/ORC copies (from the last save; while the line is as it was)
    var any = false
    for m in copyMarks[b.id][line]:
      if m.text == b.lines[line] and m.col <= b.lines[line].len:
        result.add (m.col, (if cfgAccessible: " (copy)" else: " ⧉copy"))
        any = true
    if any: result.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  if cfgCSigHints and b.id in cSigHints and line in cSigHints[b.id]:
    let (c, lb) = cSigHints[b.id][line]
    if line < b.lines.len and c == b.lines[line].len: result.add (c, lb)     # (at the end of the line it was made for)
  for (c, _, _) in sw: result.add (c, SwatchMark)
  if sw.len > 0: result.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))

proc swatchMenu(b: Buffer, line, col, n: int, rgb: Rgb) =
  ## a swatch clicked: copy the colour in another notation; a hex colour can be made lighter or darker
  let lit = if line < b.lines.len and col + n <= b.lines[line].len: b.lines[line][col ..< col + n] else: ""
  var r = int(rgb shr 16) and 255
  var g = int(rgb shr 8) and 255
  var bl = int(rgb) and 255
  if lit.len > 1:                              # the colour as written (the swatch shows it over the background)
    let (ok, r0, g0, b0, _) = hexColour(if lit[0] == '#': lit[1 .. ^1] elif lit.len > 2: lit[2 .. ^1] else: "")
    if ok: (r, g, bl) = (r0, g0, b0)
  let (h, s, l) = rgbToHsl(r, g, bl)
  let hex = "#" & toHex(r, 2).toLowerAscii & toHex(g, 2).toLowerAscii & toHex(bl, 2).toLowerAscii
  let rgbS = "rgb(" & $r & ", " & $g & ", " & $bl & ")"
  let hslS = "hsl(" & $h & ", " & $s & "%, " & $l & "%)"
  let bid = b.id
  var items: seq[(string, string, Action)]
  for v in [hex, rgbS, hslS]:
    let vv = v
    capture vv:
      items.add act("Copy " & vv, "", proc() =
        clipSet(vv)
        info("Copied " & vv))
  let isHex = lit.startsWith("#") or lit.startsWith("0x") or lit.startsWith("0X")
  if isHex and not b.readOnly:
    proc shade(dl: int): Action =
      result = proc() =
        let bb = bufById(bid)
        if bb == nil or line >= bb.lines.len or col + n > bb.lines[line].len or bb.lines[line][col ..< col + n] != lit: return
        let (r2, g2, b2) = hslToRgb(h.float, s.float / 100.0, clamp(l + dl, 0, 100).float / 100.0)
        let pre = if lit.startsWith("#"): "#" else: lit[0 .. 1]
        let digits = lit.len - pre.len
        var nh = toHex(r2, 2) & toHex(g2, 2) & toHex(b2, 2)
        if lit[pre.len .. ^1] == lit[pre.len .. ^1].toLowerAscii: nh = nh.toLowerAscii
        if digits == 8: nh.add lit[^2 .. ^1]                       # keep the alpha
        bb.beginEdit()
        discard bb.replaceText(Pos(line: line, col: col), Pos(line: line, col: col + n), pre & nh)
        bb.endEdit()
        needRender = true
    items.add act("Lighter", "+8% lightness", shade(8))
    items.add act("Darker", "−8% lightness", shade(-8))
  openActions(lit & "  " & rgbS, items)

proc drawSwatch(b: Buffer, line, col, hx, y, limX: int, sw: seq[(int, int, Rgb)], bg: Rgb) =
  var c = theme.fg
  var n = 0
  for (sc, sn, cc) in sw:
    if sc == col:
      c = cc
      n = sn
  discard putStr(hx, y, SwatchMark, c, bg, {}, limX)
  let r = int(c shr 16) and 255
  let g = int(c shr 8) and 255
  let bl = int(c) and 255
  let (bb, ln, cl, nn, cc) = (b, line, col, n, c)
  region(hx, y, 1, 1, proc() = swatchMenu(bb, ln, cl, nn, cc),
         "rgb(" & $r & ", " & $g & ", " & $bl & ") — click: copy it as hex, rgb or hsl, lighter, darker")
