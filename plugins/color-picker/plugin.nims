## color-picker — the colour at the cursor written another way, made lighter or darker; CSS's named colours to pick
##
##   Colour: convert         the colour at the cursor in its next form: #rrggbb → rgb() → hsl() → #rrggbb (with
##                           alpha: #rrggbbaa → rgba() → hsla()); a name (tomato) becomes #rrggbb. In Nim code (not
##                           in a string): 0xRRGGBB → rgb(r, g, b) → 0xRRGGBB, and std/colors' colTomato → 0xFF6347
##   Colour: pick…           CSS's 148 named colours: the one chosen replaces the colour at the cursor in its form, or
##                           goes in at the cursor in the form the file uses most (a CSS or HTML file with none: the
##                           name; Nim: colName when the file imports std/colors, else 0xRRGGBB)
##   Colour: lighter · Colour: darker   5 % more or less lightness (as hsl() counts it), the form kept — a name
##                           becomes #rrggbb, Nim's colName 0xRRGGBB
##   settings                plugins.color-picker.step — the percent of lightness lighter and darker change
##
## The colour at the cursor: #rgb #rgba #rrggbb #rrggbbaa, rgb() rgba() hsl() hsla() (commas or spaces, a / alpha,
## percentages), 0xRRGGBB, a CSS name (in CSS, HTML, Svelte, Vue and Markdown files, or in quotes in others) and
## Nim's colName. Hex digits keep their case; #f80 stays short when it can.
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")

settingDef("step", 5, "Colour: lighter / darker — how many percent of lightness each step adds or takes away")

# CSS's named colours (std/colors has each as col<Name>: its spelling, Darkorange too)
const Named = [
  ("AliceBlue", 0xF0F8FF), ("AntiqueWhite", 0xFAEBD7), ("Aqua", 0x00FFFF), ("Aquamarine", 0x7FFFD4),
  ("Azure", 0xF0FFFF), ("Beige", 0xF5F5DC), ("Bisque", 0xFFE4C4), ("Black", 0x000000), ("BlanchedAlmond", 0xFFEBCD),
  ("Blue", 0x0000FF), ("BlueViolet", 0x8A2BE2), ("Brown", 0xA52A2A), ("BurlyWood", 0xDEB887),
  ("CadetBlue", 0x5F9EA0), ("Chartreuse", 0x7FFF00), ("Chocolate", 0xD2691E), ("Coral", 0xFF7F50),
  ("CornflowerBlue", 0x6495ED), ("Cornsilk", 0xFFF8DC), ("Crimson", 0xDC143C), ("Cyan", 0x00FFFF),
  ("DarkBlue", 0x00008B), ("DarkCyan", 0x008B8B), ("DarkGoldenRod", 0xB8860B), ("DarkGray", 0xA9A9A9),
  ("DarkGreen", 0x006400), ("DarkGrey", 0xA9A9A9), ("DarkKhaki", 0xBDB76B), ("DarkMagenta", 0x8B008B),
  ("DarkOliveGreen", 0x556B2F), ("Darkorange", 0xFF8C00), ("DarkOrchid", 0x9932CC), ("DarkRed", 0x8B0000),
  ("DarkSalmon", 0xE9967A), ("DarkSeaGreen", 0x8FBC8F), ("DarkSlateBlue", 0x483D8B), ("DarkSlateGray", 0x2F4F4F),
  ("DarkSlateGrey", 0x2F4F4F), ("DarkTurquoise", 0x00CED1), ("DarkViolet", 0x9400D3), ("DeepPink", 0xFF1493),
  ("DeepSkyBlue", 0x00BFFF), ("DimGray", 0x696969), ("DimGrey", 0x696969), ("DodgerBlue", 0x1E90FF),
  ("FireBrick", 0xB22222), ("FloralWhite", 0xFFFAF0), ("ForestGreen", 0x228B22), ("Fuchsia", 0xFF00FF),
  ("Gainsboro", 0xDCDCDC), ("GhostWhite", 0xF8F8FF), ("Gold", 0xFFD700), ("GoldenRod", 0xDAA520), ("Gray", 0x808080),
  ("Green", 0x008000), ("GreenYellow", 0xADFF2F), ("Grey", 0x808080), ("HoneyDew", 0xF0FFF0), ("HotPink", 0xFF69B4),
  ("IndianRed", 0xCD5C5C), ("Indigo", 0x4B0082), ("Ivory", 0xFFFFF0), ("Khaki", 0xF0E68C), ("Lavender", 0xE6E6FA),
  ("LavenderBlush", 0xFFF0F5), ("LawnGreen", 0x7CFC00), ("LemonChiffon", 0xFFFACD), ("LightBlue", 0xADD8E6),
  ("LightCoral", 0xF08080), ("LightCyan", 0xE0FFFF), ("LightGoldenRodYellow", 0xFAFAD2), ("LightGray", 0xD3D3D3),
  ("LightGreen", 0x90EE90), ("LightGrey", 0xD3D3D3), ("LightPink", 0xFFB6C1), ("LightSalmon", 0xFFA07A),
  ("LightSeaGreen", 0x20B2AA), ("LightSkyBlue", 0x87CEFA), ("LightSlateGray", 0x778899),
  ("LightSlateGrey", 0x778899), ("LightSteelBlue", 0xB0C4DE), ("LightYellow", 0xFFFFE0), ("Lime", 0x00FF00),
  ("LimeGreen", 0x32CD32), ("Linen", 0xFAF0E6), ("Magenta", 0xFF00FF), ("Maroon", 0x800000),
  ("MediumAquaMarine", 0x66CDAA), ("MediumBlue", 0x0000CD), ("MediumOrchid", 0xBA55D3), ("MediumPurple", 0x9370DB),
  ("MediumSeaGreen", 0x3CB371), ("MediumSlateBlue", 0x7B68EE), ("MediumSpringGreen", 0x00FA9A),
  ("MediumTurquoise", 0x48D1CC), ("MediumVioletRed", 0xC71585), ("MidnightBlue", 0x191970), ("MintCream", 0xF5FFFA),
  ("MistyRose", 0xFFE4E1), ("Moccasin", 0xFFE4B5), ("NavajoWhite", 0xFFDEAD), ("Navy", 0x000080),
  ("OldLace", 0xFDF5E6), ("Olive", 0x808000), ("OliveDrab", 0x6B8E23), ("Orange", 0xFFA500), ("OrangeRed", 0xFF4500),
  ("Orchid", 0xDA70D6), ("PaleGoldenRod", 0xEEE8AA), ("PaleGreen", 0x98FB98), ("PaleTurquoise", 0xAFEEEE),
  ("PaleVioletRed", 0xDB7093), ("PapayaWhip", 0xFFEFD5), ("PeachPuff", 0xFFDAB9), ("Peru", 0xCD853F),
  ("Pink", 0xFFC0CB), ("Plum", 0xDDA0DD), ("PowderBlue", 0xB0E0E6), ("Purple", 0x800080),
  ("RebeccaPurple", 0x663399), ("Red", 0xFF0000), ("RosyBrown", 0xBC8F8F), ("RoyalBlue", 0x4169E1),
  ("SaddleBrown", 0x8B4513), ("Salmon", 0xFA8072), ("SandyBrown", 0xF4A460), ("SeaGreen", 0x2E8B57),
  ("SeaShell", 0xFFF5EE), ("Sienna", 0xA0522D), ("Silver", 0xC0C0C0), ("SkyBlue", 0x87CEEB), ("SlateBlue", 0x6A5ACD),
  ("SlateGray", 0x708090), ("SlateGrey", 0x708090), ("Snow", 0xFFFAFA), ("SpringGreen", 0x00FF7F),
  ("SteelBlue", 0x4682B4), ("Tan", 0xD2B48C), ("Teal", 0x008080), ("Thistle", 0xD8BFD8), ("Tomato", 0xFF6347),
  ("Turquoise", 0x40E0D0), ("Violet", 0xEE82EE), ("Wheat", 0xF5DEB3), ("White", 0xFFFFFF), ("WhiteSmoke", 0xF5F5F5),
  ("Yellow", 0xFFFF00), ("YellowGreen", 0x9ACD32)
]

type
  Form = enum fHex, fRgb, fHsl, fName, fNimHex, fNimName
  Col = object
    r, g, b: int                # 0 … 255
    a: float                    # 0 … 1 (1: opaque)
    alpha: bool                 # written with an alpha
  Found = object
    start, stop: int            # where it is in the line (bytes; stop not included); start -1: none
    form: Form
    col: Col
    upper, short, modern: bool  # hex in capitals, #rgb, rgb(1 2 3 / 50%) with spaces
    h, s, l: float              # hsl() as written (0 … 360, 0 … 100)

# ── numbers ──

func fmt1(x: float): string =
  ## a number with one decimal at most (12, 12.5)
  let t = int(abs(x) * 10.0 + 0.5)
  (if x < 0 and t > 0: "-" else: "") & $(t div 10) & (if t mod 10 != 0: "." & $(t mod 10) else: "")

func fmtAlpha(a: float): string =
  ## an alpha with two decimals at most (0.5, 0.25, 1)
  let t = int(a * 100.0 + 0.5)
  if t >= 100: "1"
  elif t <= 0: "0"
  else:
    var s = $t
    if s.len == 1: s = "0" & s
    s = "0." & s
    if s.endsWith("0"): s = s[0 ..< s.high]
    s

func clampByte(x: float): int = max(0, min(255, int(x + 0.5)))

func hex2(n: int, upper: bool): string =
  let s = toHex(n, 2)
  if upper: s else: s.toLowerAscii

func rgbToHsl(c: Col): (float, float, float) =
  ## the colour as hue (0 … 360), saturation and lightness (0 … 100)
  let r = c.r.float / 255.0
  let g = c.g.float / 255.0
  let b = c.b.float / 255.0
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let l = (mx + mn) / 2.0
  var h, s = 0.0
  if mx != mn:
    let d = mx - mn
    s = if l > 0.5: d / (2.0 - mx - mn) else: d / (mx + mn)
    h = if mx == r: (g - b) / d + (if g < b: 6.0 else: 0.0)
        elif mx == g: (b - r) / d + 2.0
        else: (r - g) / d + 4.0
    h *= 60.0
  (h, s * 100.0, l * 100.0)

func hslToCol(h, s, l: float, a = 1.0, alpha = false): Col =
  let sf = max(0.0, min(1.0, s / 100.0))
  let lf = max(0.0, min(1.0, l / 100.0))
  var hd = h
  while hd < 0.0: hd += 360.0
  while hd >= 360.0: hd -= 360.0
  let c = (1.0 - abs(2.0 * lf - 1.0)) * sf
  let hh = hd / 60.0
  let x = c * (1.0 - abs(hh - 2.0 * float(int(hh / 2.0)) - 1.0))
  var (r, g, b) = (0.0, 0.0, 0.0)
  if hh < 1: (r, g, b) = (c, x, 0.0)
  elif hh < 2: (r, g, b) = (x, c, 0.0)
  elif hh < 3: (r, g, b) = (0.0, c, x)
  elif hh < 4: (r, g, b) = (0.0, x, c)
  elif hh < 5: (r, g, b) = (x, 0.0, c)
  else: (r, g, b) = (c, 0.0, x)
  let m = lf - c / 2.0
  Col(r: clampByte((r + m) * 255.0), g: clampByte((g + m) * 255.0), b: clampByte((b + m) * 255.0), a: a, alpha: alpha)

# ── names ──

func cssName(n: string): string = n.toLowerAscii

func nameOf(c: Col): string =
  ## the CSS name of an opaque colour ("" when it has none; gray before grey)
  if c.alpha: return ""
  let v = (c.r shl 16) or (c.g shl 8) or c.b
  for (n, x) in Named:
    if x == v: return n

func namedCol(word: string): (bool, Col) =
  ## a CSS name (any case) → its colour
  let w = word.toLowerAscii
  for (n, x) in Named:
    if n.toLowerAscii == w:
      return (true, Col(r: x shr 16, g: (x shr 8) and 255, b: x and 255, a: 1.0))

# ── finding colours in a line ──

func cssy(lang: string): bool =
  ## a language whose files write colours as CSS does, outside strings too
  lang in ["css", "scss", "sass", "less", "stylus", "html", "xml", "svg", "svelte", "vue", "astro", "markdown"]

func inString(line: string, col: int): bool =
  ## is the column inside a "…" or '…' string of the line (counted from its start)?
  var q = '\0'
  var i = 0
  while i < min(col, line.len):
    let c = line[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c == '#' and i + 1 < line.len and line[i + 1] in {' ', '['}: break     # (a comment: # …, #[ … ]#)
    inc i
  q != '\0'

func numArg(t: string, scale: float): (bool, float) =
  ## "255", "50%", "120deg", "0.5" → the number (a percentage of `scale`)
  var x = t.strip
  var pct = false
  if x.endsWith("%"):
    pct = true
    x = x[0 ..< x.high]
  elif x.endsWith("deg"): x = x[0 ..< x.len - 3]
  if x.len == 0: return (false, 0.0)
  for c in x:
    if c notin {'0' .. '9', '.', '-', '+'}: return (false, 0.0)
  try: (true, (if pct: parseFloat(x) * scale / 100.0 else: parseFloat(x)))
  except ValueError: (false, 0.0)

func hexCol(h: string): (bool, Col) =
  for c in h:
    if c notin HexDigits: return (false, Col())
  case h.len
  of 3, 4:
    var c = Col(r: parseHexInt(h[0 .. 0]) * 17, g: parseHexInt(h[1 .. 1]) * 17, b: parseHexInt(h[2 .. 2]) * 17, a: 1.0)
    if h.len == 4: (c.a, c.alpha) = (float(parseHexInt(h[3 .. 3]) * 17) / 255.0, true)
    (true, c)
  of 6, 8:
    var c = Col(r: parseHexInt(h[0 .. 1]), g: parseHexInt(h[2 .. 3]), b: parseHexInt(h[4 .. 5]), a: 1.0)
    if h.len == 8: (c.a, c.alpha) = (float(parseHexInt(h[6 .. 7])) / 255.0, true)
    (true, c)
  else: (false, Col())

func colours(line, lang: string): seq[Found] =
  ## the colours written in the line
  let css = cssy(lang)
  let nim = lang == "nim"
  var i = 0
  while i < line.len:
    let c = line[i]
    let before = if i > 0: line[i - 1] else: ' '
    if c == '#' and before notin IdentChars + {'&'}:
      var e = i + 1
      while e < line.len and line[e] in HexDigits: inc e
      let n = e - i - 1
      if n in [3, 4, 6, 8] and (e >= line.len or line[e] notin IdentChars):
        let (ok, col) = hexCol(line[i + 1 ..< e])
        if ok:
          let digits = line[i + 1 ..< e]
          result.add Found(start: i, stop: e, form: fHex, col: col, short: n <= 4,
                           upper: digits != digits.toLowerAscii)
          i = e
          continue
    elif c == '0' and i + 1 < line.len and line[i + 1] in {'x', 'X'} and before notin IdentChars:
      var e = i + 2
      while e < line.len and line[e] in HexDigits: inc e
      if e - i - 2 == 6 and (e >= line.len or line[e] notin IdentChars or line[e] == '\''):
        let (ok, col) = hexCol(line[i + 2 ..< e])
        if ok:
          let digits = line[i + 2 ..< e]
          # (no letters in it: capitals, as std/colors writes them)
          result.add Found(start: i, stop: e, form: fNimHex, col: col, upper: digits == digits.toUpperAscii)
          i = e
          continue
    elif c in {'r', 'h', 'R', 'H'} and before notin IdentChars and
         (line.continuesWith("rgb", i) or line.continuesWith("hsl", i) or line.continuesWith("RGB", i) or
          line.continuesWith("HSL", i)):
      var o = i + 3
      if o < line.len and line[o] in {'a', 'A'}: inc o
      let cl = if o < line.len and line[o] == '(': line.find(')', o) else: -1
      if cl > o:
        let inner = line[o + 1 ..< cl]
        let modern = ',' notin inner
        var parts: seq[string]
        for x in inner.replace("/", " / ").split({',', ' '}):
          if x.len > 0 and x != "/": parts.add x
        if parts.len in [3, 4]:
          let isRgb = line[i] in {'r', 'R'}
          let n0 = numArg(parts[0], (if isRgb: 255.0 else: 360.0))
          let n1 = numArg(parts[1], (if isRgb: 255.0 else: 100.0))
          let n2 = numArg(parts[2], (if isRgb: 255.0 else: 100.0))
          let n3 = if parts.len == 4: numArg(parts[3], 1.0) else: (true, 1.0)
          if n0[0] and n1[0] and n2[0] and n3[0]:
            # (a percentage of lightness is written "50%": numArg made it 50 of 100 already; a bare one too)
            var f = Found(start: i, stop: cl + 1, modern: modern)
            let a = max(0.0, min(1.0, n3[1]))
            if isRgb:
              f.form = fRgb
              f.col = Col(r: clampByte(n0[1]), g: clampByte(n1[1]), b: clampByte(n2[1]), a: a, alpha: parts.len == 4)
            else:
              f.form = fHsl
              (f.h, f.s, f.l) = (n0[1], n1[1], n2[1])
              f.col = hslToCol(f.h, f.s, f.l, a, parts.len == 4)
            result.add f
            i = cl + 1
            continue
    elif nim and c == 'c' and before notin IdentChars and line.continuesWith("col", i) and i + 3 < line.len and
         line[i + 3] in {'A' .. 'Z'}:
      var e = i + 3
      while e < line.len and line[e] in IdentChars: inc e
      let (ok, col) = namedCol(line[i + 3 ..< e].replace("_", ""))
      if ok:
        result.add Found(start: i, stop: e, form: fNimName, col: col)
        i = e
        continue
    elif c in Letters and before notin IdentChars + {'-', '#', '.', '$', '@'}:
      var e = i
      while e < line.len and line[e] in Letters: inc e
      if e >= line.len or line[e] notin IdentChars + {'-'}:
        let (ok, col) = namedCol(line[i ..< e])
        if ok and (css or inString(line, i)):
          result.add Found(start: i, stop: e, form: fName, col: col)
        i = e
        continue
    inc i

func colourAt(line, lang: string, col: int): Found =
  ## the colour the column is in (or right after); start -1 when there is none
  result.start = -1
  for f in colours(line, lang):
    if col >= f.start and col <= f.stop: return f

# ── writing a colour ──

func render(f: Found, form: Form): string =
  ## the colour of `f` written in `form` (its case, shortness and comma style kept where they apply)
  let c = f.col
  case form
  of fHex:
    var bytes = @[c.r, c.g, c.b]
    if c.alpha: bytes.add clampByte(c.a * 255.0)
    var canShort = f.short
    for x in bytes:
      if x mod 17 != 0: canShort = false
    result = "#"
    for x in bytes:
      result.add (if canShort: hex2(x, f.upper)[1 .. 1] else: hex2(x, f.upper))
  of fNimHex:
    let up = if f.form == fNimHex: f.upper else: true        # (std/colors writes capitals)
    result = "0x" & hex2(c.r, up) & hex2(c.g, up) & hex2(c.b, up)
  of fRgb:
    if f.modern:
      result = "rgb(" & $c.r & " " & $c.g & " " & $c.b & (if c.alpha: " / " & fmtAlpha(c.a) else: "") & ")"
    else:
      result = (if c.alpha: "rgba(" else: "rgb(") & $c.r & ", " & $c.g & ", " & $c.b &
               (if c.alpha: ", " & fmtAlpha(c.a) else: "") & ")"
  of fHsl:
    var (h, s, l) = if f.form == fHsl: (f.h, f.s, f.l) else: rgbToHsl(c)
    if f.modern:
      result = "hsl(" & fmt1(h) & " " & fmt1(s) & "% " & fmt1(l) & "%" &
               (if c.alpha: " / " & fmtAlpha(c.a) else: "") & ")"
    else:
      result = (if c.alpha: "hsla(" else: "hsl(") & fmt1(h) & ", " & fmt1(s) & "%, " & fmt1(l) & "%" &
               (if c.alpha: ", " & fmtAlpha(c.a) else: "") & ")"
  of fName: result = cssName(nameOf(c))
  of fNimName: result = "col" & nameOf(c)

func nextForm(f: Found, nimCode: bool): Form =
  ## what Colour: convert turns it into — nimCode: Nim's own forms (0xRRGGBB ⇄ rgb(r, g, b))
  if nimCode:
    if f.form == fNimHex: fRgb else: fNimHex
  else:
    case f.form
    of fHex, fName, fNimName, fNimHex: fRgb
    of fRgb: fHsl
    of fHsl: fHex

func shaded(f: Found, dl: float): Found =
  ## the colour with dl more lightness (percent), in the same form — a name becomes #rrggbb (0xRRGGBB in Nim)
  result = f
  var (h, s, l) = if f.form == fHsl: (f.h, f.s, f.l) else: rgbToHsl(f.col)
  l = max(0.0, min(100.0, l + dl))
  result.col = hslToCol(h, s, l, f.col.a, f.col.alpha)
  (result.h, result.s, result.l) = (h, s, l)
  if f.form == fName: result.form = fHex
  elif f.form == fNimName: result.form = fNimHex

# ── the commands ──

func nimCode(lang, line: string, f: Found): bool =
  ## a colour in Nim's own forms: 0xRRGGBB and colName, rgb(r, g, b) not in a string
  lang == "nim" and (f.form in {fNimHex, fNimName} or (f.form == fRgb and not inString(line, f.start)))

proc atCursor(b: Buf): (string, Found) =
  let p = b.cursor
  let l = b.line(p.line)
  (l, colourAt(l, b.lang, p.col))

proc convert() =
  let b = current()
  if not b.valid: return
  let (l, f) = atCursor(b)
  if f.start < 0:
    message("Colour: no colour at the cursor (#rrggbb, rgb(), hsl(), 0xRRGGBB, a name)")
    return
  if f.form == fNimHex and b.lang != "nim":
    message("Colour: " & l[f.start ..< f.stop] & " has no other form in a " & b.lang & " file")
    return
  let to = render(f, nextForm(f, nimCode(b.lang, l, f)))
  let line = b.cursor.line
  b.replace(rng(pos(line, f.start), pos(line, f.stop)), to)
  b.setCursor(pos(line, f.start))
  message("Colour: " & l[f.start ..< f.stop] & " → " & to)

proc shade(sign: float) =
  let b = current()
  if not b.valid: return
  let (l, f) = atCursor(b)
  if f.start < 0:
    message("Colour: no colour at the cursor (#rrggbb, rgb(), hsl(), 0xRRGGBB, a name)")
    return
  let to = render(shaded(f, sign * setting("step", 5).float), shaded(f, 0).form)
  let line = b.cursor.line
  b.replace(rng(pos(line, f.start), pos(line, f.stop)), to)
  b.setCursor(pos(line, f.start))
  message("Colour: " & l[f.start ..< f.stop] & " → " & to)

func usualForm(lines: seq[string], lang: string): Form =
  ## the form the file writes its colours in most (the first of them when two are as common); none: by its language
  var counts: array[Form, int]
  var first: array[Form, int]
  var n = 0
  for i, l in lines:
    if i > 3000: break
    for f in colours(l, lang):
      if counts[f.form] == 0: first[f.form] = n
      inc counts[f.form]
      inc n
  var best = fHex
  var found = false
  for fm in Form:
    if counts[fm] > 0 and (not found or counts[fm] > counts[best] or
                           (counts[fm] == counts[best] and first[fm] < first[best])):
      best = fm
      found = true
  if found: return best
  if lang == "nim":
    for i, l in lines:
      if i > 200: break
      let t = l.strip
      if (t.startsWith("import") or t.startsWith("from")) and ("colors" in t): return fNimName
    return fNimHex
  if cssy(lang): fName else: fHex

proc pickNamed() =
  let b = current()
  if not b.valid: return
  var items, details: seq[string]
  for (n, x) in Named:
    let c = Col(r: x shr 16, g: (x shr 8) and 255, b: x and 255, a: 1.0)
    items.add cssName(n)
    details.add render(Found(col: c), fHex) & " · " & render(Found(col: c), fRgb)
  let (l, f) = atCursor(b)
  let title = if f.start >= 0: "Colour: replace " & l[f.start ..< f.stop] & " with" else: "Colour: insert"
  let k = pick(title, items, details)
  if k < 0: return
  let x = Named[k][1]
  var c = Col(r: x shr 16, g: (x shr 8) and 255, b: x and 255, a: 1.0)
  let p = b.cursor
  if f.start >= 0:
    # (in the form of the colour it replaces — its alpha kept where that form has one)
    var form = f.form
    if form in {fHex, fRgb, fHsl}: (c.a, c.alpha) = (f.col.a, f.col.alpha)
    let g = Found(col: c, form: fRgb, upper: f.upper, short: f.short, modern: f.modern)
    let to = render(g, form)
    b.replace(rng(pos(p.line, f.start), pos(p.line, f.stop)), to)
    b.setCursor(pos(p.line, f.start + to.len))
    message("Colour: " & l[f.start ..< f.stop] & " → " & to)
  else:
    let to = render(Found(col: c), usualForm(b.lines, b.lang))
    let r = b.selection
    let at = if r.isEmpty: p else: r.start
    b.replace(if r.isEmpty: rng(p, p) else: r, to)
    b.setCursor(pos(at.line, at.col + to.len))
    message("Colour: " & to)

command "Colour: convert": convert()
command "Colour: pick…": pickNamed()
command "Colour: lighter": shade(1.0)
command "Colour: darker": shade(-1.0)
