# ── Emmet for CSS: Tab after m10 → margin: 10px; · p10-20 · w100p · df · posr · jcsb · c#333 · bd1-s-#ccc · fz14! ──

const EmmetCssAbbrevs = [("m", "margin"), ("mt", "margin-top"), ("mr", "margin-right"), ("mb", "margin-bottom"),
  ("ml", "margin-left"), ("p", "padding"), ("pt", "padding-top"), ("pr", "padding-right"), ("pb", "padding-bottom"),
  ("pl", "padding-left"), ("w", "width"), ("h", "height"), ("maw", "max-width"), ("mah", "max-height"),
  ("miw", "min-width"), ("mih", "min-height"), ("t", "top"), ("r", "right"), ("b", "bottom"), ("l", "left"),
  ("z", "z-index"), ("zi", "z-index"), ("fz", "font-size"), ("fw", "font-weight"), ("ff", "font-family"),
  ("fs", "font-style"), ("lh", "line-height"), ("lts", "letter-spacing"), ("c", "color"), ("bg", "background"),
  ("bgc", "background-color"), ("bgi", "background-image"), ("bd", "border"), ("bdt", "border-top"),
  ("bdr", "border-right"), ("bdb", "border-bottom"), ("bdl", "border-left"), ("bdc", "border-color"),
  ("bdrs", "border-radius"), ("br", "border-radius"), ("op", "opacity"), ("d", "display"), ("pos", "position"),
  ("ta", "text-align"), ("td", "text-decoration"), ("tt", "text-transform"), ("ov", "overflow"),
  ("ovx", "overflow-x"), ("ovy", "overflow-y"), ("cur", "cursor"), ("fl", "float"), ("g", "gap"), ("gap", "gap"),
  ("jc", "justify-content"), ("ji", "justify-items"), ("ai", "align-items"), ("ac", "align-content"),
  ("as", "align-self"), ("fd", "flex-direction"), ("fxd", "flex-direction"), ("fxw", "flex-wrap"),
  ("fx", "flex"), ("fxg", "flex-grow"), ("fxs", "flex-shrink"), ("fxb", "flex-basis"), ("ord", "order"),
  ("gtc", "grid-template-columns"), ("gtr", "grid-template-rows"), ("ga", "grid-area"), ("gc", "grid-column"),
  ("gr", "grid-row"), ("trs", "transition"), ("trf", "transform"), ("bxsh", "box-shadow"), ("bxz", "box-sizing"),
  ("ws", "white-space"), ("va", "vertical-align"), ("v", "visibility"), ("ol", "outline"), ("ct", "content"),
  ("ani", "animation"), ("tov", "text-overflow"), ("us", "user-select"), ("pe", "pointer-events"),
  ("obf", "object-fit"), ("ar", "aspect-ratio"), ("ins", "inset")]

const CssKeywords = [("display", "f flex|if inline-flex|g grid|ig inline-grid|b block|i inline|ib inline-block|n none|t table|c contents"),
  ("position", "r relative|a absolute|f fixed|s static|st sticky"),
  ("text-align", "c center|l left|r right|j justify"),
  ("text-decoration", "n none|u underline|l line-through"),
  ("text-transform", "u uppercase|l lowercase|c capitalize|n none"),
  ("overflow", "h hidden|a auto|s scroll|v visible"), ("overflow-x", "h hidden|a auto|s scroll|v visible"),
  ("overflow-y", "h hidden|a auto|s scroll|v visible"),
  ("cursor", "p pointer|d default|t text|m move|na not-allowed|g grab"),
  ("float", "l left|r right|n none"), ("font-weight", "b bold|n normal|l lighter|br bolder"),
  ("font-style", "i italic|n normal"),
  ("justify-content", "c center|sb space-between|sa space-around|se space-evenly|fs flex-start|fe flex-end|s start|e end"),
  ("align-items", "c center|fs flex-start|fe flex-end|s stretch|b baseline"),
  ("align-self", "c center|fs flex-start|fe flex-end|s stretch|a auto"),
  ("flex-direction", "c column|r row|cr column-reverse|rr row-reverse"),
  ("flex-wrap", "w wrap|nw nowrap"), ("white-space", "nw nowrap|p pre|pw pre-wrap|n normal"),
  ("visibility", "h hidden|v visible"), ("box-sizing", "bb border-box|cb content-box"),
  ("vertical-align", "m middle|t top|b bottom|bl baseline"), ("border", "n none"), ("background", "n none"),
  ("user-select", "n none|a all"), ("pointer-events", "n none|a auto"), ("text-overflow", "e ellipsis|c clip"),
  ("object-fit", "c cover|cn contain|f fill")]

const CssDefaults = [("box-sizing", "border-box"), ("transition", "all 0.2s ease"), ("text-overflow", "ellipsis"),
  ("display", "flex"), ("position", "relative")]

const CssUnitless = ["z-index", "opacity", "line-height", "font-weight", "flex", "flex-grow", "flex-shrink", "order"]

func emmetCssProp(abbr: string): string =
  ## the CSS property an Emmet abbreviation stands for (`mt` → margin-top), or "" when it is not one of the known
  ## abbreviations
  for (a, p) in EmmetCssAbbrevs:
    if a == abbr: return p
  ""

proc cssKeyword(prop, k: string): string =
  ## the keyword value that the short form `k` stands for in the property `prop` (`c` in flex-direction → column), or ""
  ## when there is none
  for (p, kws) in CssKeywords:
    if p == prop:
      for kv in kws.split('|'):
        let sp = kv.find(' ')
        if kv[0 ..< sp] == k: return kv[sp + 1 .. ^1]
  ""

proc cssValue(prop, v: string): string =
  ## one value: 10 → 10px · 100p → 100% · 1.5e → 1.5em · 2r → 2rem · a → auto · #f00 · s (border) → solid
  if v.len == 0: return ""
  if v[0] == '#': return v
  if v == "a": return "auto"
  if v == "i": return "inherit"
  if prop.startsWith("border") and v in ["s", "d", "dt"]: return (if v == "s": "solid" elif v == "d": "dashed" else: "dotted")
  var k = 0
  if k < v.len and v[k] == '-': inc k
  var num = false
  while k < v.len and (v[k] in Digits or v[k] == '.'):
    num = true
    inc k
  if not num:
    let kw = cssKeyword(prop, v)
    return (if kw.len > 0: kw else: v)
  let n = v[0 ..< k]
  let u = v[k .. ^1]
  case u
  of "": (if prop in CssUnitless or n == "0" or n == "-0": n else: n & "px")
  of "p": n & "%"
  of "e": n & "em"
  of "r": n & "rem"
  of "x": n & "ex"
  else: n & u                                   # vh, vw, s, ms, deg, fr …

proc emmetCss(abbr0: string): (string, int) =
  ## the declaration for an abbreviation, and where the cursor goes (-1: at the end)
  var abbr = abbr0
  var imp = false
  if abbr.endsWith("!"):
    imp = true
    abbr = abbr[0 ..< ^1]
  if abbr.len == 0: return ("", -1)
  let tail = (if imp: " !important;" else: ";")
  # prop:value
  let colon = abbr.find(':')
  if colon > 0:
    let prop = emmetCssProp(abbr[0 ..< colon])
    if prop.len == 0: return ("", -1)
    var vals: seq[string]
    for v in abbr[colon + 1 .. ^1].split('-'): vals.add cssValue(prop, v)
    return (prop & ": " & vals.join(" ") & tail, -1)
  # a known property alone: its default, else an empty value with the cursor in it
  let alone = emmetCssProp(abbr)
  if alone.len > 0:
    for (p, d) in CssDefaults:
      if p == alone: return (p & ": " & d & tail, -1)
    let t = alone & ": " & tail
    return (t, alone.len + 2)
  # property + keyword (df, posr, jcsb …) or property + values (m10-20, w100p, c#333, bd1-s-#ccc)
  for cut in countdown(min(4, abbr.len - 1), 1):
    let prop = emmetCssProp(abbr[0 ..< cut])
    if prop.len == 0: continue
    let rest = abbr[cut .. ^1]
    let kw = cssKeyword(prop, rest)
    if kw.len > 0: return (prop & ": " & kw & tail, -1)
    if rest[0] in Digits or rest[0] in {'#', '-', '.'}:
      # values split on "-", where "--5" means a negative one
      var vals: seq[string]
      var cur = ""
      var i = 0
      while i < rest.len:
        let c = rest[i]
        if c == '-' and cur.len > 0 and cur[0] != '#':
          vals.add cur
          cur = ""
          if i + 1 < rest.len and rest[i + 1] == '-':
            cur = "-"
            inc i
        elif c == '-' and cur.len > 0:
          vals.add cur
          cur = ""
        else: cur.add c
        inc i
      if cur.len > 0: vals.add cur
      var outv: seq[string]
      for v in vals: outv.add cssValue(prop, v)
      return (prop & ": " & outv.join(" ") & tail, -1)
  ("", -1)

proc tryEmmetCss(b: Buffer): bool =
  ## Tab after an abbreviation inside a CSS rule (the only thing on its line)
  if b.cursors.len != 1 or b.primary.hasSel or b.readOnly: return false
  let h = b.primary.head
  let s = b.lines[h.line]
  if h.col == 0 or h.col > s.len or s[h.col .. ^1].strip.len > 0: return false
  let ind = leadingWs(s).len
  let abbr = s[ind ..< h.col]
  if abbr.len == 0 or not abbr[0].isLowerAscii: return false
  for c in abbr:
    if not (c.isAlphaNumeric or c in {'-', '.', '#', ':', '!', '%'}): return false
  # inside a rule: more { than } before the cursor
  var depth = 0
  for l in countdown(h.line - 1, max(0, h.line - 3000)):
    for c in b.lines[l]:
      if c == '{': inc depth
      elif c == '}': dec depth
  if depth <= 0: return false
  let (text, curAt) = emmetCss(abbr)
  if text.len == 0: return false
  b.beginEdit()
  discard b.replaceText(Pos(line: h.line, col: ind), h, text)
  b.endEdit()
  b.setSingle(Pos(line: h.line, col: ind + (if curAt >= 0: curAt else: text.len)))
  true

proc tryEmmet(b: Buffer): bool =
  ## Tab after an abbreviation in HTML: expand it
  if b.cursors.len != 1 or b.primary.hasSel or b.readOnly: return false
  let h = b.primary.head
  let s = b.lines[h.line]
  if h.col == 0 or h.col > s.len or (h.col < s.len and s[h.col] notin {' ', '\t', '<'}): return false
  var a = h.col
  while a > 0:
    let c = s[a - 1]
    if c == '}':
      let o = s.rfind('{', last = a - 2)
      if o < 0: return false
      a = o
    elif c == ']':
      let o = s.rfind('[', last = a - 2)
      if o < 0: return false
      a = o
    elif c in {' ', '\t'}: break
    else: dec a
  # after a tag on the line ("<p class=x>ul>li"): the abbreviation starts behind the tag; inside a tag: nothing
  let lastLt = s.rfind('<', last = h.col - 1)
  if lastLt >= 0:
    let close = s.find('>', lastLt)
    if close < 0 or close >= h.col: return false
    a = max(a, close + 1)
  let abbr = s[a ..< h.col]
  if abbr.len == 0 or not (abbr[0].isAlphaAscii or abbr[0] in {'.', '#', '(', '!'}): return false
  let unit = b.indent
  let ex = emmetExpand(abbr, unit)
  if ex.len == 0: return false
  let ind = leadingWs(s)
  var text = ex.replace("\n", "\n" & ind)
  let mark = text.find('\x01')
  text = text.replace("\x01", "")
  b.beginEdit()
  discard b.replaceText(Pos(line: h.line, col: a), h, text)
  b.endEdit()
  if mark >= 0:
    let before = text[0 ..< mark]
    let nl = before.count('\n')
    let col = if nl == 0: a + before.len else: before.len - before.rfind('\n') - 1
    b.setSingle(b.clampPos(Pos(line: h.line + nl, col: col)))
  true
