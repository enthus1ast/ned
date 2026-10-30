# ── Zed and Helix themes imported: a Zed theme family (.json) or a Helix theme (.toml, with its `inherits` and its
#    [palette]) becomes ned's own theme file in ~/.config/ned/themes — after that it is one of your own themes,
#    read by themeFromJson like any other. What the theme does not say comes from the built-in theme nearest to it of
#    the same kind (light or dark); a colour too faint to read is moved until it reads, its hue kept.
#    The converting needs only the standard library: tests/unit/tthemeimport.nim includes this file without the
#    editor (the palette's command and `ned --import-theme`, at the end, are left out there) ──

const
  TiKeys = ["bg", "fg", "accent", "selection", "comment", "keyword", "type", "string", "number", "function",
            "operator", "macro", "property", "error", "warning", "ok"]     # (ThemeKeys: mkTheme's colours, in order)
  TiChrome = ["titleBar", "dock", "statusBar"]
  TiAnsi = [("black", 0x000000'u32), ("red", 0xCD0000'u32), ("green", 0x00CD00'u32), ("yellow", 0xCDCD00'u32),
            ("blue", 0x0000EE'u32), ("magenta", 0xCD00CD'u32), ("cyan", 0x00CDCD'u32), ("gray", 0x7F7F7F'u32),
            ("light-red", 0xFF0000'u32), ("light-green", 0x00FF00'u32), ("light-yellow", 0xFFFF00'u32),
            ("light-blue", 0x5C5CFF'u32), ("light-magenta", 0xFF00FF'u32), ("light-cyan", 0x00FFFF'u32),
            ("light-gray", 0xE5E5E5'u32), ("white", 0xFFFFFF'u32)]
    ## Helix's names for the terminal's sixteen colours, as xterm shows them (a theme that uses them leaves the
    ## colours to the terminal; ned needs one)

type
  TiBuiltin = object
    ## a built-in theme, for what an imported one leaves out
    name: string
    dark: bool
    base: array[16, uint32]   # its colours, in TiKeys' order
  TiColours = object
    ## what one theme of the file says, in ned's colour names
    name, source: string
    have: Table[string, uint32]
    dark, darkKnown, bold: bool
    ruler: int                # -1: none
  TiImport = object
    ## what importing a file gave
    format: string            # "Zed" or "Helix"; "" when the file is neither (and no error)
    themes: seq[JsonNode]     # ned's theme files, one for each theme in the file
    themeNotes: seq[string]   # for each: the colours taken from a built-in theme, the colours made readable
    notes: seq[string]        # for the file: a parent theme not found
    files: seq[string]        # where tiWrite put them
    err: string

# ── colours ──

proc tiBlend(a, b: uint32, t: float): uint32 =
  ## a mixed with b; t = 0 → a, t = 1 → b (as `blend`)
  for sh in [16, 8, 0]:
    let x = float((a shr sh) and 0xFF)
    let y = float((b shr sh) and 0xFF)
    result = result or (uint32(clamp(int(x + (y - x) * t + 0.5), 0, 255)) shl sh)

proc tiParse(s: string, over: uint32): int =
  ## "#RGB", "#RRGGBB" or "#RRGGBBAA" (the alpha blended over `over`); -1 when it is not a colour
  var h = s.strip
  if not h.startsWith("#"): return -1
  h = h[1 .. ^1]
  if h.len == 3: h = $h[0] & h[0] & h[1] & h[1] & h[2] & h[2]
  if h.len notin [6, 8]: return -1
  for c in h:
    if c notin HexDigits: return -1
  let rgb = uint32(parseHexInt(h[0 .. 5]))
  if h.len == 8: int(tiBlend(over, rgb, float(parseHexInt(h[6 .. 7])) / 255.0)) else: int(rgb)

# a colour as "#rrggbb"
func tiHex(c: uint32): string = "#" & toHex(int(c), 6)

proc tiLum(c: uint32): float =
  ## a colour's relative luminance (WCAG), 0 for black to 1 for white
  proc ch(v: uint32): float =
    ## one channel 0 … 255 made linear, as the luminance needs it
    let x = float(v) / 255.0
    if x <= 0.03928: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  0.2126 * ch((c shr 16) and 0xFF) + 0.7152 * ch((c shr 8) and 0xFF) + 0.0722 * ch(c and 0xFF)

proc tiContrast(a, b: uint32): float =
  ## the WCAG contrast ratio, 1 to 21
  let x = tiLum(a)
  let y = tiLum(b)
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

proc tiReadable(c, bg: uint32, minR: float): uint32 =
  ## `c` moved away from `bg` until it reads (as readableOn: the hue kept, only the lightness moves)
  if tiContrast(c, bg) >= minR: return c
  let target = if tiLum(bg) < 0.2: 0xFFFFFF'u32 else: 0x000000'u32
  result = c
  for i in 1 .. 20:
    result = tiBlend(c, target, float(i) * 0.05)
    if tiContrast(result, bg) >= minR: return

proc tiBgUnder(bg, text: uint32, minR: float): uint32 =
  ## a background moved away from the text on it until that text reads (as bgUnder)
  if tiContrast(text, bg) >= minR: return bg
  let target = if tiLum(text) > 0.2: 0x000000'u32 else: 0xFFFFFF'u32
  result = bg
  for i in 1 .. 20:
    result = tiBlend(bg, target, float(i) * 0.05)
    if tiContrast(text, result) >= minR: return

proc tiLab(c: uint32): (float, float, float) =
  ## CIE L*a*b*, to tell how near two colours look
  proc lin(v: uint32): float =
    let x = float(v) / 255.0
    if x <= 0.04045: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  let r = lin((c shr 16) and 0xFF)
  let g = lin((c shr 8) and 0xFF)
  let b = lin(c and 0xFF)
  # the cube-root step of the CIE L*a*b* conversion (with its straight part near black)
  proc f(t: float): float = (if t > 0.008856: pow(t, 1.0 / 3.0) else: 7.787 * t + 16.0 / 116.0)
  let x = f((r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047)
  let y = f(r * 0.2126 + g * 0.7152 + b * 0.0722)
  let z = f((r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883)
  (116.0 * y - 16.0, 500.0 * (x - y), 200.0 * (y - z))

proc tiDelta(a, b: uint32): float =
  ## how far apart two colours look (CIE76 ΔE)
  let (l1, a1, b1) = tiLab(a)
  let (l2, a2, b2) = tiLab(b)
  pow((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2), 0.5)

proc tiChroma(c: uint32): float =
  ## how colourful a colour is: its distance from grey in the a*, b* plane (0 for a grey)
  let (_, a, b) = tiLab(c)
  pow(a * a + b * b, 0.5)

proc tiOr(xs: varargs[int]): int =
  ## the first colour found (-1: none)
  for x in xs:
    if x >= 0: return x
  -1

func tiSlug(s: string): string =
  ## a theme name that is also a safe file name (as themeSlug)
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '_'}: result.add c
    elif result.len > 0 and result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "my-theme"

# ── TOML, as far as themes use it: tables, inline tables (also over several lines), dotted and quoted keys, strings,
#    arrays, numbers, true and false — read into a JsonNode ──

type TiToml = object
  s: string
  i, line: int

proc tiTomlErr(p: TiToml, what: string) {.noreturn.} =
  ## stops the TOML reading with a ValueError that names the line and what was expected
  raise newException(ValueError, "line " & $p.line & ": " & what)

proc tiSpaces(p: var TiToml, lines = false) =
  ## spaces and tabs; with `lines`, line ends and comments too (inside an array or an inline table)
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c in {' ', '\t', '\r'}: inc p.i
    elif lines and c == '\n':
      inc p.i
      inc p.line
    elif lines and c == '#':
      while p.i < p.s.len and p.s[p.i] != '\n': inc p.i
    else: break

func tiUtf8(cp: int): string =
  ## a code point as UTF-8
  if cp < 0x80: result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or ((cp shr 18) and 0x07))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))

proc tiTomlString(p: var TiToml): string =
  ## "basic" (with escapes), 'literal', and their three-quote forms that go over lines
  let q = p.s[p.i]
  let close = $q & q & q
  let multi = p.s.continuesWith(close, p.i)
  p.i += (if multi: 3 else: 1)
  if multi and p.i < p.s.len and p.s[p.i] == '\n':      # (a line end straight after the quotes is not part of it)
    inc p.i
    inc p.line
  while true:
    if p.i >= p.s.len: p.tiTomlErr("a string without its end")
    let c = p.s[p.i]
    if (multi and p.s.continuesWith(close, p.i)) or (not multi and c == q):
      p.i += (if multi: 3 else: 1)
      return
    if c == '\n':
      if not multi: p.tiTomlErr("a string without its end")
      inc p.line
    if c == '\\' and q == '"':
      inc p.i
      if p.i >= p.s.len: p.tiTomlErr("a string without its end")
      let e = p.s[p.i]
      case e
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'e': result.add '\e'
      of '"', '\\': result.add e
      of 'u', 'U':
        let n = if e == 'u': 4 else: 8
        if p.i + n >= p.s.len: p.tiTomlErr("a \\" & e & " escape cut short")
        try: result.add tiUtf8(parseHexInt(p.s[p.i + 1 .. p.i + n]))
        except ValueError: p.tiTomlErr("not a \\" & e & " escape")
        p.i += n
      of '\n', ' ', '\t', '\r':
        if not multi: p.tiTomlErr("a \\ at the end of a one-line string")
        while p.i < p.s.len and p.s[p.i] in {' ', '\t', '\r', '\n'}:    # (a \ at a line's end joins the lines)
          if p.s[p.i] == '\n': inc p.line
          inc p.i
        continue
      else: p.tiTomlErr("unknown escape \\" & e)
      inc p.i
      continue
    result.add c
    inc p.i

proc tiTomlKey(p: var TiToml): seq[string] =
  ## a key: bare words, "quoted" or 'literal' parts, joined by dots
  while true:
    p.tiSpaces()
    if p.i >= p.s.len: p.tiTomlErr("a key expected")
    if p.s[p.i] in {'"', '\''}: result.add p.tiTomlString()
    else:
      let st = p.i
      while p.i < p.s.len and p.s[p.i] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}: inc p.i
      if p.i == st: p.tiTomlErr("a key expected, not " & p.s[p.i])
      result.add p.s[st ..< p.i]
    p.tiSpaces()
    if p.i < p.s.len and p.s[p.i] == '.': inc p.i
    else: return

proc tiTomlTable(root: JsonNode, path: openArray[string]): JsonNode =
  ## the table at `path`, made where it is missing (in an array of tables: its last one)
  result = root
  for k in path:
    var n = result{k}
    if n != nil and n.kind == JArray and n.len > 0 and n[^1].kind == JObject: n = n[^1]
    elif n == nil or n.kind != JObject:
      n = newJObject()
      result[k] = n
    result = n

proc tiTomlValue(p: var TiToml): JsonNode

proc tiTomlPair(p: var TiToml, into: JsonNode) =
  ## key = value
  let k = p.tiTomlKey()
  if p.i >= p.s.len or p.s[p.i] != '=': p.tiTomlErr("= expected after " & k.join("."))
  inc p.i
  tiTomlTable(into, k[0 ..< ^1])[k[^1]] = p.tiTomlValue()

proc tiTomlValue(p: var TiToml): JsonNode =
  ## the TOML value at the reading position: a string, an inline table (also over several lines) or an array, else a
  ## bare word — true, false, a number, or any other text kept as it is
  p.tiSpaces()
  if p.i >= p.s.len: p.tiTomlErr("a value expected")
  case p.s[p.i]
  of '"', '\'': result = %p.tiTomlString()
  of '{':
    inc p.i
    result = newJObject()
    p.tiSpaces(lines = true)        # (TOML 1.1 lets an inline table go over lines, and themes do)
    if p.i < p.s.len and p.s[p.i] == '}':
      inc p.i
      return
    while true:
      p.tiTomlPair(result)
      p.tiSpaces(lines = true)
      if p.i >= p.s.len: p.tiTomlErr("a { without its }")
      if p.s[p.i] == ',':
        inc p.i
        p.tiSpaces(lines = true)
        if p.i < p.s.len and p.s[p.i] == '}':
          inc p.i
          return
      elif p.s[p.i] == '}':
        inc p.i
        return
      else: p.tiTomlErr(", or } expected, not " & p.s[p.i])
  of '[':
    inc p.i
    result = newJArray()
    while true:
      p.tiSpaces(lines = true)
      if p.i >= p.s.len: p.tiTomlErr("a [ without its ]")
      if p.s[p.i] == ']':
        inc p.i
        return
      result.add p.tiTomlValue()
      p.tiSpaces(lines = true)
      if p.i < p.s.len and p.s[p.i] == ',': inc p.i
      elif p.i < p.s.len and p.s[p.i] == ']':
        inc p.i
        return
      else: p.tiTomlErr(", or ] expected")
  else:
    # true, false, a number (or a date: kept as the text it is)
    let st = p.i
    while p.i < p.s.len and p.s[p.i] in {'A'..'Z', 'a'..'z', '0'..'9', '_', '+', '-', '.', ':'}: inc p.i
    let w = p.s[st ..< p.i]
    if w.len == 0: p.tiTomlErr("a value expected, not " & p.s[p.i])
    if w == "true": result = %true
    elif w == "false": result = %false
    else:
      try: result = %parseInt(w.replace("_", ""))
      except ValueError:
        try: result = %parseFloat(w.replace("_", ""))
        except ValueError: result = %w

proc tiParseToml(text: string): JsonNode =
  ## a TOML text as JSON; ValueError (with the line) for what it cannot read
  var p = TiToml(s: text, line: 1)
  result = newJObject()
  var cur = result
  while true:
    p.tiSpaces(lines = true)
    if p.i >= p.s.len: return
    if p.s[p.i] == '[':
      let arr = p.s.continuesWith("[[", p.i)
      p.i += (if arr: 2 else: 1)
      let k = p.tiTomlKey()
      if not p.s.continuesWith((if arr: "]]" else: "]"), p.i): p.tiTomlErr("] expected after [" & k.join("."))
      p.i += (if arr: 2 else: 1)
      if arr:
        let o = tiTomlTable(result, k[0 ..< ^1])
        if o{k[^1]} == nil or o[k[^1]].kind != JArray: o[k[^1]] = newJArray()
        cur = newJObject()
        o[k[^1]].add cur
      else: cur = tiTomlTable(result, k)
    else: p.tiTomlPair(cur)
    # the rest of the line: a comment at most
    p.tiSpaces()
    if p.i < p.s.len and p.s[p.i] == '#':
      while p.i < p.s.len and p.s[p.i] != '\n': inc p.i
    if p.i < p.s.len and p.s[p.i] != '\n': p.tiTomlErr("the line goes on after its value: " & p.s[p.i])

# ── one theme's colours → ned's theme file ──

proc tiFinish(c: TiColours, builtins: openArray[TiBuiltin], taken: var seq[string], notes: var string): JsonNode =
  ## the theme file: what the theme leaves out from the nearest built-in theme of its kind, the bars it does not
  ## give made as ned makes them, every colour moved until it reads (the thresholds of tests/themes/contrast.py for the
  ## themes ned took in, and of the theme editor for backgrounds)
  var have = c.have
  var dark = c.dark
  if not c.darkKnown:                   # (from the background, as themeFromJson tells; with none, ned's default: dark)
    dark = if "bg" in have: tiLum(have["bg"]) < 0.2 elif "fg" in have: tiLum(have["fg"]) > 0.4 else: true
  # the nearest built-in theme: the background counts most, then the text, then each colour of code
  var best = -1
  var bestD = Inf
  for i, b in builtins:
    if b.dark != dark: continue
    var kinds: seq[uint32]
    for x in b.base:
      if x notin kinds: kinds.add x
    if kinds.len < 4: continue          # (e-ink: black and white only — nothing to take a colour from)
    var d = 0.0
    for j, k in TiKeys:
      if k in have: d += (if k == "bg": 4.0 elif k == "fg": 2.0 else: 1.0) * tiDelta(have[k], b.base[j])
    if d < bestD:
      bestD = d
      best = i
  if best < 0: return nil
  let near = builtins[best]
  var filled: seq[string]
  for j, k in TiKeys:
    if k notin have and k != "selection":
      have[k] = near.base[j]
      filled.add k
  let bg = have["bg"]
  if "selection" notin have: have["selection"] = tiBlend(bg, have["accent"], (if dark: 0.35 else: 0.25))
  # the bars: as mkTheme makes them from the background, where the theme does not give them
  let title = if dark: tiBlend(bg, 0, 0.32) else: tiBlend(bg, 0, 0.07)
  if "titleBar" notin have: have["titleBar"] = have.getOrDefault("statusBar", title)
  if "statusBar" notin have: have["statusBar"] = have["titleBar"]
  if "dock" notin have: have["dock"] = (if dark: tiBlend(bg, 0, 0.20) else: tiBlend(bg, 0, 0.035))
  var moved: seq[string]
  for (k, need) in [("fg", 7.0), ("keyword", 4.5), ("type", 4.5), ("string", 4.5), ("number", 4.5),
                    ("function", 4.5), ("macro", 4.5), ("property", 4.5), ("error", 4.5), ("comment", 3.0),
                    ("operator", 3.0), ("accent", 3.0), ("warning", 3.0), ("ok", 3.0)]:
    let v = tiReadable(have[k], bg, need)
    if v != have[k]:
      have[k] = v
      moved.add k
  for k in ["selection", "titleBar", "dock", "statusBar"]:
    let v = tiBgUnder(have[k], have["fg"], 4.5)
    if v != have[k]:
      have[k] = v
      moved.add k
  # the name: a built-in theme's is not taken (as the VS Code import does), nor one taken by this file already
  var name = tiSlug(c.name)
  for b in builtins:
    if b.name == name: name.add "-imported"
  var n = name
  var i = 2
  while n in taken:
    n = name & "-" & $i
    inc i
  taken.add n
  result = %*{"name": n, "importedFrom": c.source, "dark": dark, "base": near.name, "boldKeywords": c.bold}
  var cs = newJObject()
  for k in TiKeys: cs[k] = %tiHex(have[k])
  for k in TiChrome: cs[k] = %tiHex(have[k])
  if c.ruler >= 0 and tiContrast(uint32(c.ruler), bg) >= 1.3: cs["ruler"] = %tiHex(uint32(c.ruler))
  result["colors"] = cs
  var parts: seq[string]
  if filled.len > 0: parts.add filled.join(", ") & " as in " & near.name
  if moved.len > 0: parts.add moved.join(", ") & " made readable"
  notes = parts.join("; ")

# ── Zed: {"themes": [{"name", "appearance", "style": {"editor.background", …, "players": […],
#    "syntax": {"keyword": {"color", "font_weight"}, …}}}]} ──

proc tiZedColours(t: JsonNode): TiColours =
  ## the colours of one Zed theme in ned's colour names: from its style (editor, panel, title and status bar, players,
  ## terminal colours) and syntax entries, the first found of several fallbacks for each, light or dark from its
  ## appearance, the wrap guide as the ruler, and bold keywords when the keyword weight is 600 or more
  let st = t{"style"}
  let syn = st{"syntax"}
  result.ruler = -1
  result.darkKnown = t{"appearance"} != nil and t{"appearance"}.kind == JString
  result.dark = t{"appearance"}.getStr("dark") != "light"
  var over = if result.dark: 0x000000'u32 else: 0xFFFFFF'u32     # (what a colour with an alpha is laid over)
  # a colour string of the theme as a number (an alpha laid over the editor's background), -1 when it is not one
  proc col(n: JsonNode): int = (if n != nil and n.kind == JString: tiParse(n.getStr, over) else: -1)
  proc style(keys: varargs[string]): int =
    ## the first colour found among the style entries of these names, -1 when none
    result = -1
    for k in keys:
      result = col(st{k})
      if result >= 0: return
  proc syntax(keys: varargs[string]): int =
    ## the first colour found among the syntax entries of these names, -1 when none
    result = -1
    for k in keys:
      result = col(syn{k}{"color"})
      if result >= 0: return
  proc player(field: string): int =
    ## a field of the first player (the cursor's colours), -1 when there is none
    let ps = st{"players"}
    if ps != nil and ps.kind == JArray and ps.len > 0: col(ps[0]{field}) else: -1
  template put(k: string, v: int) =
    ## records a colour under ned's name for it when one was found
    let x = v
    if x >= 0: result.have[k] = uint32(x)
  let bg = style("editor.background", "background")
  put("bg", bg)
  if bg >= 0: over = uint32(bg)
  put("fg", style("editor.foreground", "text"))
  put("accent", tiOr(style("text.accent", "icon.accent"), player("cursor"), style("border.focused")))
  put("selection", tiOr(player("selection"), style("element.selected", "ghost_element.selected")))
  put("comment", syntax("comment"))
  put("keyword", syntax("keyword"))
  put("type", syntax("type", "type.builtin", "enum", "constructor"))
  put("string", syntax("string"))
  put("number", syntax("number", "constant", "boolean"))
  put("function", syntax("function", "function.method", "constructor"))
  put("operator", syntax("operator", "punctuation.special", "punctuation"))
  put("macro", syntax("preproc", "function.special", "attribute", "keyword.directive"))
  put("property", syntax("property", "variable.member", "field", "variable.special"))
  put("error", style("error", "deleted", "version_control.deleted", "terminal.ansi.red"))
  put("warning", style("warning", "modified", "version_control.modified", "terminal.ansi.yellow"))
  put("ok", style("success", "created", "version_control.added", "terminal.ansi.green"))
  put("titleBar", style("title_bar.background"))
  put("dock", style("panel.background", "surface.background", "tab_bar.background"))
  put("statusBar", style("status_bar.background"))
  result.ruler = style("editor.wrap_guide")
  let w = syn{"keyword"}{"font_weight"}
  result.bold = w != nil and ((w.kind == JInt and w.getInt >= 600) or (w.kind == JFloat and w.getFloat >= 600))

proc tiFromZed(j: JsonNode, file: string, builtins: openArray[TiBuiltin]): TiImport =
  ## a Zed theme family (or one theme of it) → ned's theme files
  result.format = "Zed"
  var list: seq[JsonNode]
  if j{"themes"} != nil and j["themes"].kind == JArray:
    for t in j["themes"]:
      if t.kind == JObject and t{"style"} != nil and t["style"].kind == JObject: list.add t
  elif j{"style"} != nil and j["style"].kind == JObject: list.add j
  var taken: seq[string]
  for t in list:
    var c = tiZedColours(t)
    if c.have.len == 0: continue
    c.name = t{"name"}.getStr(j{"name"}.getStr(splitFile(file).name))
    c.source = extractFilename(file) & " (Zed: " & c.name & ")"
    var notes = ""
    let tj = tiFinish(c, builtins, taken, notes)
    if tj == nil: continue
    result.themes.add tj
    result.themeNotes.add notes
  if result.themes.len == 0: result.err = "No colours found in " & extractFilename(file) & " — not a Zed theme"

# ── Helix: "scope" = "colour" or { fg, bg, modifiers, underline = { color } }, colours by [palette] name, #rrggbb or
#    the terminal's names; `inherits` = another theme, its file beside this one or in Helix's folders ──

proc tiHelixFind(name, near: string): string =
  ## the file of the theme `inherits` names: beside the theme, then your Helix themes, then Helix's own
  var dirs = @[parentDir(near)]
  let xdg = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  dirs.add xdg / "helix" / "themes"
  if getEnv("APPDATA").len > 0: dirs.add getEnv("APPDATA") / "helix" / "themes"          # (Windows)
  if getEnv("HELIX_RUNTIME").len > 0: dirs.add getEnv("HELIX_RUNTIME") / "themes"
  dirs.add xdg / "helix" / "runtime" / "themes"
  for root in [getEnv("PREFIX"), "/usr", "/usr/local"]:                 # (PREFIX: Termux's /data/…/usr)
    if root.len > 0:
      dirs.add root / "lib" / "helix" / "runtime" / "themes"
      dirs.add root / "share" / "helix" / "runtime" / "themes"
  for brew in ["/opt/homebrew", "/usr/local"]: dirs.add brew / "opt" / "helix" / "libexec" / "runtime" / "themes"
  for d in dirs:
    let f = d / (name & ".toml")
    if fileExists(f): return f
  ""

proc tiHelixInherit(t: JsonNode, file: string, seen: var seq[string], notes: var seq[string]): JsonNode =
  ## the theme with what it inherits: the parent's scopes with this one's over them, the palettes merged (the
  ## parent's scopes take this theme's palette, as in Helix)
  result = t
  let parent = t{"inherits"}.getStr("")
  if parent.len == 0: return
  let f = tiHelixFind(parent, file)
  if f.len == 0 or seen.len > 8 or absolutePath(f) in seen:
    notes.add "it inherits " & parent & ", which was not found"
    return
  seen.add absolutePath(f)
  var base: JsonNode
  try: base = tiHelixInherit(tiParseToml(readFile(f)), f, seen, notes)
  except CatchableError as e:
    notes.add "its parent " & extractFilename(f) & " could not be read (" & e.msg & ")"
    return
  for k, v in t:
    if k == "palette" and v.kind == JObject and base{"palette"} != nil and base["palette"].kind == JObject:
      for pk, pv in v: base["palette"][pk] = pv
    elif k != "inherits": base[k] = v
  result = base

proc tiHelixWalk(acc: var Table[string, JsonNode], scope: string, v: JsonNode) =
  ## scope → style; a table that is not a style (an unquoted ui.background) is read as dotted scopes
  if v.kind == JString:
    acc[scope] = v
  elif v.kind == JObject:
    var own = false
    for k, x in v:
      if k in ["fg", "bg", "modifiers", "underline"]: own = true
      elif x.kind in {JString, JObject}: tiHelixWalk(acc, scope & "." & k, x)
    if own: acc[scope] = v

proc tiHelixColours(t: JsonNode): TiColours =
  ## the colours of one Helix theme in ned's colour names: its scopes (ui.background, keyword, string …) looked up with
  ## fallbacks, colours by palette name, #rrggbb or a terminal colour name; the accent is the first cursor, selection or
  ## highlight colour with some hue; bold keywords when the keyword scope says bold
  var styles = initTable[string, JsonNode]()
  for k, v in t:
    if k notin ["palette", "inherits", "rainbow"]: tiHelixWalk(styles, k, v)
  let pal = t{"palette"}
  result.ruler = -1
  proc colour(name: string): int =
    ## a colour of a Helix theme as a number: a palette name looked up first, then #rrggbb or one of the terminal's
    ## colour names; -1 when it is none of them
    var n = name.strip
    if pal != nil and pal.kind == JObject and pal{n} != nil and pal[n].kind == JString: n = pal[n].getStr.strip
    if n.startsWith("#"): return tiParse(n, 0)
    for (a, c) in TiAnsi:
      if a == n: return int(c)
    -1
  proc get(scope, field: string): int =
    ## one field of a scope's style (fg, bg, or underline for its colour) as a colour, -1 when absent; a scope given as
    ## a plain string is its foreground
    let s = styles.getOrDefault(scope)
    if s == nil: return -1
    if s.kind == JString: return (if field == "fg": colour(s.getStr) else: -1)
    if field == "underline": return colour(s{"underline"}{"color"}.getStr(""))
    colour(s{field}.getStr(""))
  proc fg(scopes: varargs[string]): int =
    ## the first foreground colour found among these scopes, -1 when none
    result = -1
    for s in scopes:
      result = get(s, "fg")
      if result >= 0: return
  template put(k: string, v: int) =
    ## records a colour under ned's name for it when one was found
    let x = v
    if x >= 0: result.have[k] = uint32(x)
  put("bg", get("ui.background", "bg"))
  put("fg", fg("ui.text", "variable"))
  # the accent: the cursor's colour, or what else stands out — a colour with a hue, not a grey
  var accent = -1
  for (s, f) in [("ui.cursor.primary", "bg"), ("ui.cursor", "bg"), ("ui.menu.selected", "bg"), ("ui.text.focus", "fg"),
                 ("info", "fg"), ("function", "fg")]:
    let v = get(s, f)
    if v >= 0 and accent < 0: accent = v
    if v >= 0 and tiChroma(uint32(v)) >= 20:
      accent = v
      break
  put("accent", accent)
  put("selection", tiOr(get("ui.selection.primary", "bg"), get("ui.selection", "bg")))
  put("comment", fg("comment", "comment.line"))
  put("keyword", fg("keyword", "keyword.control"))
  put("type", fg("type", "type.builtin", "constructor"))
  put("string", fg("string"))
  put("number", fg("constant.numeric", "constant.numeric.integer", "constant"))
  put("function", fg("function", "function.method"))
  put("operator", fg("operator", "keyword.operator", "punctuation"))
  put("macro", fg("function.macro", "keyword.directive", "attribute"))
  put("property", fg("variable.other.member", "variable.member", "property"))
  put("error", tiOr(fg("error"), get("diagnostic.error", "underline"), fg("diagnostic.error", "diff.minus")))
  put("warning", tiOr(fg("warning"), get("diagnostic.warning", "underline"), fg("diagnostic.warning", "diff.delta")))
  put("ok", fg("diff.plus"))
  put("titleBar", tiOr(get("ui.bufferline.background", "bg"), get("ui.bufferline", "bg")))
  put("statusBar", get("ui.statusline", "bg"))
  result.ruler = get("ui.virtual.ruler", "bg")
  let kw = styles.getOrDefault("keyword")
  if kw != nil and kw.kind == JObject and kw{"modifiers"} != nil and kw["modifiers"].kind == JArray:
    for m in kw["modifiers"]:
      if m.getStr == "bold": result.bold = true

proc tiFromHelix(t0: JsonNode, file: string, builtins: openArray[TiBuiltin]): TiImport =
  ## a Helix theme (read with tiParseToml) → ned's theme file
  result.format = "Helix"
  var seen = @[absolutePath(file)]
  let t = tiHelixInherit(t0, file, seen, result.notes)
  var c = tiHelixColours(t)
  if c.have.len == 0:
    result.err = "No colours found in " & extractFilename(file) & " — not a Helix theme"
    return
  c.name = splitFile(file).name                    # (Helix calls a theme by its file's name)
  c.source = extractFilename(file) & " (Helix)"
  var taken: seq[string]
  var notes = ""
  let tj = tiFinish(c, builtins, taken, notes)
  if tj == nil:
    result.err = "No built-in theme to take the rest from"
    return
  result.themes.add tj
  result.themeNotes.add notes

proc tiConvert(text, file: string, builtins: openArray[TiBuiltin]): TiImport =
  ## a Zed (.json) or Helix (.toml) theme file's text → ned's theme files; format "" (and no error) when it is
  ## neither. (std/json reads Zed's comments and trailing commas as they are)
  let text = if text.startsWith("\xEF\xBB\xBF"): text[3 .. ^1] else: text      # (a byte-order mark: Windows' editors)
  let s = text.strip
  if s.startsWith("{"):
    var j: JsonNode
    try: j = parseJson(text)
    except CatchableError as e:
      result.err = "Not JSON ned can read: " & e.msg
      return
    if j.kind == JObject and ((j{"themes"} != nil and j["themes"].kind == JArray) or j{"style"} != nil):
      return tiFromZed(j, file, builtins)
    return                                    # (VS Code, base16 or ned's own: not for this importer)
  var t: JsonNode
  try: t = tiParseToml(text)
  except ValueError as e:
    if file.toLowerAscii.endsWith(".toml"): result.err = "Cannot read " & extractFilename(file) & ": " & e.msg
    return
  var helix = file.toLowerAscii.endsWith(".toml") or t{"palette"} != nil or t{"inherits"} != nil or t{"ui"} != nil
  for k, _ in t:
    if k.startsWith("ui."): helix = true
  if helix: result = tiFromHelix(t, file, builtins)

proc tiWrite(r: var TiImport, dir: string) =
  ## the themes into `dir` (your themes folder) as <name>.json — one with that name already there is replaced
  try:
    createDir(dir)
    for t in r.themes:
      let f = dir / (t["name"].getStr & ".json")
      writeFile(f, t.pretty & "\n")
      r.files.add f
  except CatchableError as e:
    r.err = "Cannot write the theme: " & e.msg

# ── in the editor: the palette's "Theme: import a Zed or Helix theme…", and `ned --import-theme FILE…` ──

when not declared(themeImportAlone):          # (the unit test includes the converting alone, without the editor)
  proc tiBuiltins(): seq[TiBuiltin] =
    ## the built-in themes, as the converting wants them: name, dark or light, and their sixteen colours
    for t in allThemesRaw(): result.add TiBuiltin(name: t.name, dark: t.dark, base: t.base)

  proc tiImportPath(path: string): TiImport =
    ## a theme file → ned's theme files in your themes folder (format "": the file is not a Zed or Helix theme)
    let p = absolutePath(expandTilde(path.strip))
    var text = ""
    try: text = readFile(p)
    except CatchableError as e: return TiImport(err: "Cannot read " & path & ": " & e.msg)
    result = tiConvert(text, p, tiBuiltins())
    if result.err.len == 0 and result.themes.len > 0: tiWrite(result, themesDir())

  proc importZedHelixTheme(path: string) =
    ## the themes written; the one of the kind in use (light or dark) put in use. A VS Code or base16 theme goes to
    ## the importer for those
    let r = tiImportPath(path)
    if r.err.len > 0:
      error(r.err)
      return
    if r.format.len == 0:
      importTheme(path)
      return
    var pick = 0
    for i, t in r.themes:
      if t{"dark"}.getBool == theme.dark:
        pick = i
        break
    let name = r.themes[pick]{"name"}.getStr
    reloadThemes()
    applyTheme(name)
    setSetting("theme", %name)
    var m = "Imported the " & r.format & " theme " & name & " → " & tildePath(r.files[pick])
    if r.themes.len > 1:
      var others: seq[string]
      for i, t in r.themes:
        if i != pick: others.add t{"name"}.getStr
      m = "Imported " & $r.themes.len & " " & r.format & " themes → " & tildePath(themesDir()) & ": " & name &
          " in use, " & others.join(", ") & " (Alt+T)"
    for n in r.notes & @[r.themeNotes[pick]]:
      if n.len > 0: m.add " · " & n
    info(m)

  proc cmdImportZedHelixTheme() =
    ## the palette command that asks for a Zed (.json) or Helix (.toml) theme file and imports it
    askPath("Zed (.json) or Helix (.toml) theme file", getHomeDir() & "/", proc(t: string) = importZedHelixTheme(t))

  proc importThemeCli(args: seq[string]): int =
    ## ned --import-theme FILE…: Zed and Helix themes made ned's own, without starting the editor
    if args.len == 0:
      stderr.writeLine("ned: --import-theme needs a Zed (.json) or Helix (.toml) theme file")
      return 2
    var names: seq[string]
    for a in args:
      let r = tiImportPath(a)
      if r.err.len > 0:
        stderr.writeLine("ned: " & r.err)
        result = 1
        continue
      if r.format.len == 0:
        stderr.writeLine("ned: " & a & " is not a Zed or Helix theme (a VS Code or base16 one: the palette's " &
                         "Theme: import a VS Code or base16 theme…)")
        result = 1
        continue
      for n in r.notes: echo a & ": " & n
      for i, t in r.themes:
        let n = t{"name"}.getStr
        names.add n
        echo n & " → " & tildePath(r.files[i]) & (if r.themeNotes[i].len > 0: " (" & r.themeNotes[i] & ")" else: "")
    if names.len > 0:
      echo "In ned: Alt+T, or \"theme\": \"" & names[0] & "\" in the settings"
