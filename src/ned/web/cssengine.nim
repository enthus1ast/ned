## ── ned's own CSS: where the cursor is (a selector, a property, its value …), what fits there, what a name is,
##    and the mistakes a browser silently drops (an unknown property or value, a missing `;`, a brace too many).
##    It works on a document's lines — CSS in a .css file, in an HTML <style>, in a Nim string (its text at its
##    own columns, the rest blank) ──

import std/[strutils, sets]
import webdata, webcommon

type
  CssCtxKind* = enum ccNone, ccSelector, ccProperty, ccValue, ccAtRule, ccPseudo, ccClass, ccId, ccUnit, ccVar
  CssCtx* = object
    kind*: CssCtxKind
    prop*: string              # ccValue: the property (lower case)
    start*: int                # the column where the word being completed starts
    word*: string              # what is typed of it
    pseudoElem*: bool          # ccPseudo after `::`
  BlockKind = enum bkRules, bkDecls, bkKeyframes

const
  CssGlobals* = ["inherit", "initial", "unset", "revert", "revert-layer"]
  RuleAtRules = ["media", "supports", "container", "layer", "scope", "document", "starting-style", "-moz-document"]
  KeyframeAt = ["keyframes", "-webkit-keyframes", "-moz-keyframes"]

proc cssPropNames*(): seq[string] =
  ## the names of all the CSS properties ned knows
  for p in CssProps: result.add p[0]

var propNamesMemo: seq[string]
proc propNames(): seq[string] =
  ## cssPropNames, made once and kept (for the spelling suggestions)
  if propNamesMemo.len == 0: propNamesMemo = cssPropNames()
  propNamesMemo

func atName(seg: string): string =
  ## "@media screen" → "media"
  var s = seg.strip
  if s.len < 2 or s[0] != '@': return ""
  var e = 1
  while e < s.len and isCssIdent(s[e]): inc e
  s[1 ..< e].toLowerAscii

proc blockKindFor(seg: string, parent: BlockKind): BlockKind =
  ## what a block holds, from what stands before its `{`
  let a = atName(seg)
  if a.len > 0:
    if a in RuleAtRules: return (if parent == bkDecls: bkDecls else: bkRules)   # (nested @media in a rule)
    if a in KeyframeAt: return bkKeyframes
    return bkDecls
  if parent == bkKeyframes: return bkDecls                                    # from { … } / 50% { … }
  bkDecls

func looksSelector(seg: string): bool =
  ## a nested rule's selector in a declaration block (CSS nesting, SCSS): `&:hover`, `.x`, `#id`, `> a` …
  let s = seg.strip
  s.len > 0 and s[0] in {'&', '.', '#', '[', ':', '>', '+', '~', '*'}

type CssScan = object
  ## the state just before the cursor
  inComment, inString: bool
  stack: seq[BlockKind]
  seg: string                  # the text since the last { } or ;
  parenDepth: int
  funcs: seq[string]           # the functions whose ( are open, innermost last

proc scanTo(lines: openArray[string], line, col: int): CssScan =
  ## reads the document from its start to the cursor and gives back the state there: in a comment or a string, the open
  ## blocks (rules, declarations, keyframes), the text since the last { } or ; and the functions whose parenthesis is
  ## open. Braces and semicolons inside parentheses do not count.
  var q = '\0'
  for l in 0 .. min(line, lines.high):
    let s = lines[l]
    let stop = if l == line: min(col, s.len) else: s.len
    var i = 0
    while i < stop:
      let c = s[i]
      if result.inComment:
        if c == '*' and i + 1 < s.len and s[i + 1] == '/':
          result.inComment = false
          inc i
      elif result.inString:
        if c == '\\': inc i
        elif c == q: result.inString = false
        result.seg.add c
      elif c == '/' and i + 1 < s.len and s[i + 1] == '*':
        result.inComment = true
        inc i
      elif c in {'"', '\''}:
        result.inString = true
        q = c
        result.seg.add c
      elif c == '{' and result.parenDepth == 0:
        let parent = if result.stack.len > 0: result.stack[^1] else: bkRules
        result.stack.add blockKindFor(result.seg, parent)
        result.seg = ""
      elif c == '}' and result.parenDepth == 0:
        if result.stack.len > 0: result.stack.setLen(result.stack.len - 1)
        result.seg = ""
      elif c == ';' and result.parenDepth == 0:
        result.seg = ""
      else:
        if c == '(':
          var e = result.seg.len
          var a = e
          while a > 0 and isCssIdent(result.seg[a - 1]): dec a
          result.funcs.add result.seg[a ..< e].toLowerAscii
          inc result.parenDepth
        elif c == ')' and result.parenDepth > 0:
          dec result.parenDepth
          if result.funcs.len > 0: result.funcs.setLen(result.funcs.len - 1)
        result.seg.add c
      inc i
    if l < line and not result.inComment: result.seg.add ' '

proc cssContext*(lines: openArray[string], line, col: int): CssCtx =
  ## what is being written at (line, col)
  if line < 0 or line > lines.high: return
  let st = scanTo(lines, line, col)
  if st.inComment or st.inString: return CssCtx(kind: ccNone)
  let s = lines[line]
  let c = min(col, s.len)
  var a = c
  while a > 0 and isCssIdent(s[a - 1]): dec a
  result.start = a
  result.word = s[a ..< c]
  let before = if a > 0: s[a - 1] else: ' '
  let bk = if st.stack.len > 0: st.stack[^1] else: bkRules
  let seg = st.seg[0 ..< max(0, st.seg.len - result.word.len)]
  if before == '@':
    result.kind = ccAtRule
    result.start = a - 1
    result.word = "@" & result.word
    return
  if result.word.len > 0 and result.word[0] in Digits:
    # 10p → the unit
    var u = a
    while u < c and s[u] in {'0'..'9', '.'}: inc u
    result.kind = ccUnit
    result.start = u
    result.word = s[u ..< c]
    return
  if st.funcs.len > 0 and st.funcs[^1] == "var":
    result.kind = ccVar
    return
  let colon = block:
    var k = -1
    var d = 0
    for i, ch in seg:
      if ch == '(': inc d
      elif ch == ')': dec d
      elif ch == ':' and d == 0:
        k = i
        break
    k
  let inDecls = bk == bkDecls
  if inDecls and colon > 0 and not looksSelector(seg):
    let name = seg[0 ..< colon].strip.toLowerAscii
    let known = cssProp(name) >= 0 or name.startsWith("-")
    # (`a:ho` in a block: a nested rule's pseudo-class — `colr: re` a value all the same)
    if name.len > 0 and name.allCharsInSet({'a'..'z', '0'..'9', '-', '_'}) and (known or before != ':'):
      result.kind = ccValue
      result.prop = name
      return
  if inDecls and colon < 0 and not looksSelector(seg & result.word) and before notin {':', '.', '#'}:
    result.kind = ccProperty
    return
  # a selector
  if before == ':':
    result.kind = ccPseudo
    result.pseudoElem = a >= 2 and s[a - 2] == ':'
    result.start = a - (if result.pseudoElem: 2 else: 1)
    result.word = s[result.start ..< c]
    return
  if before == '.':
    result.kind = ccClass
    return
  if before == '#':
    result.kind = ccId
    return
  result.kind = if bk == bkKeyframes: ccNone else: ccSelector

proc propDesc(i: int): string =
  ## the help text of property number i of CssProps: what it does, then its keywords and the kinds of value it also
  ## takes
  let p = CssProps[i]
  result = p[3]
  if p[1].len > 0: result.add "\n\nValues: " & p[1].replace(" ", ", ")
  if p[2].len > 0: result.add "\n\nAlso: " & p[2].replace(" ", ", ")

proc customProps*(lines: openArray[string]): seq[string] =
  ## the custom properties (--name) a document declares
  var seen: HashSet[string]
  for s in lines:
    var i = s.find("--")
    while i >= 0:
      var e = i + 2
      while e < s.len and isCssIdent(s[e]): inc e
      var k = e
      while k < s.len and s[k] == ' ': inc k
      if e > i + 2 and k < s.len and s[k] == ':' and (i == 0 or not isCssIdent(s[i - 1])):
        let n = s[i ..< e]
        if n notin seen:
          seen.incl n
          result.add n
      i = s.find("--", max(e, i + 2))

proc valueItems(prop: string): seq[WebItem] =
  ## the completions for a property's value: its own keywords first, the CSS-wide keywords, colour names when it takes
  ## colours (or the property is unknown), and the functions that fit it (var and calc for all; rgb, url, gradients,
  ## transforms, filters … by what the property takes)
  let i = cssProp(prop)
  var kinds = ""
  if i >= 0:
    for v in CssProps[i][1].splitWhitespace:
      result.add WebItem(label: v, insert: v, detail: prop, kind: KValue, rank: 0)
    kinds = CssProps[i][2]
  for v in CssGlobals: result.add WebItem(label: v, insert: v, detail: "every property", kind: KKeyword, rank: 3)
  let ks = kinds.splitWhitespace
  if "color" in ks or i < 0:
    for c in CssColorNames: result.add WebItem(label: c, insert: c, detail: "colour", kind: KColor, rank: 2)
  for f in CssFunctions:
    let n = f[0]
    let fits = n in ["var", "calc", "min", "max", "clamp", "env", "attr"] or
      ("color" in ks and (n in ["rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color-mix", "color",
                                "light-dark"])) or
      (("image" in ks or "url" in ks) and (n == "url" or "gradient" in n or n == "image-set")) or
      (prop in ["transform", "translate", "rotate", "scale"] and (n.startsWith("translate") or n.startsWith("rotate") or
       n.startsWith("scale") or n.startsWith("skew") or n.startsWith("matrix") or n == "perspective")) or
      (prop in ["filter", "backdrop-filter"] and n in ["blur", "brightness", "contrast", "drop-shadow", "grayscale",
       "hue-rotate", "invert", "opacity", "saturate", "sepia"]) or
      (("timing-function" in prop or prop in ["transition", "animation"]) and n in ["cubic-bezier", "steps", "linear"]) or
      (prop.startsWith("grid-template") and n in ["repeat", "minmax", "fit-content"]) or
      (i < 0)
    if fits:
      result.add WebItem(label: n & "()", insert: n & "()", snippet: n & "($1)$0", detail: f[1], doc: f[2],
                         kind: KFunction, rank: 1)

proc cssComplete*(lines: openArray[string], line, col: int, classes: seq[string] = @[], ids: seq[string] = @[],
                  tags: seq[string] = @[]): (CssCtx, seq[WebItem]) =
  ## what fits at (line, col): with the class names and ids the page's HTML uses, when it has some
  let cx = cssContext(lines, line, col)
  result[0] = cx
  var items: seq[WebItem]
  case cx.kind
  of ccNone: discard
  of ccProperty:
    for i, p in CssProps:
      items.add WebItem(label: p[0], insert: p[0] & ": ", snippet: p[0] & ": $0", detail: "property",
                        doc: propDesc(i), kind: KProp, rank: 0)
  of ccValue:
    items = valueItems(cx.prop)
    if cx.start > 0 and lines[line][cx.start - 1] == '!':
      items = @[WebItem(label: "important", insert: "important", kind: KKeyword)]
  of ccVar:
    for n in customProps(lines): items.add WebItem(label: n, insert: n, detail: "custom property", kind: KVariable)
  of ccAtRule:
    for a in CssAtRules: items.add WebItem(label: a[0], insert: a[0], doc: a[1], detail: "at-rule", kind: KKeyword)
  of ccPseudo:
    if not cx.pseudoElem:
      for p in CssPseudoClasses:
        let fn = p[0].endsWith("()")
        items.add WebItem(label: p[0], insert: (if fn: p[0][0 ..< ^2] & "(" else: p[0]),
                          snippet: (if fn: p[0][0 ..< ^2] & "($1)$0" else: ""), doc: p[1], detail: "pseudo-class",
                          kind: KKeyword, rank: 0)
    for p in CssPseudoElements:
      items.add WebItem(label: p[0], insert: p[0], doc: p[1], detail: "pseudo-element", kind: KKeyword,
                        rank: (if cx.pseudoElem: 0 else: 1))
  of ccClass:
    for c in classes: items.add WebItem(label: c, insert: c, detail: "class in the page", kind: KClass)
  of ccId:
    for c in ids: items.add WebItem(label: c, insert: c, detail: "id in the page", kind: KField)
  of ccUnit:
    for u in CssUnits: items.add WebItem(label: u, insert: u, detail: "unit", kind: KUnit)
  of ccSelector:
    for t in HtmlTags: items.add WebItem(label: t[0], insert: t[0], doc: t[1], detail: "element", kind: KStruct, rank: 1)
    for c in tags: items.add WebItem(label: c, insert: c, detail: "element in the page", kind: KStruct, rank: 0)
  result[1] = items

proc wordAround(s: string, col: int): (int, int) =
  ## the name at col, with its @ or its : / :: in front
  var a = min(col, s.len)
  var e = a
  while a > 0 and isCssIdent(s[a - 1]): dec a
  while e < s.len and isCssIdent(s[e]): inc e
  if a > 0 and s[a - 1] == '@': dec a
  elif a > 0 and s[a - 1] == ':':
    # (a pseudo-class only where the colon is glued to what is before it — `a:hover`, `::before` — not `color: red`)
    if a >= 2 and s[a - 2] == ':': a -= 2
    elif a >= 2 and s[a - 2] notin {' ', '\t'} and not (e < s.len and s[e] == ';'): dec a
    elif a == 1: dec a
  (a, e)

proc cssHover*(lines: openArray[string], line, col: int): string =
  ## what the name at (line, col) is (Markdown; "" for nothing known)
  if line < 0 or line > lines.high: return
  let s = lines[line]
  var (a, e) = wordAround(s, col)
  if a >= e: return
  var w = s[a ..< e]
  let cx = cssContext(lines, line, a + (if w[0] in {'@', ':'}: 1 else: 0))
  if cx.kind == ccNone: return
  if w.startsWith(":") and cx.kind == ccValue:       # (color:red — the value, not a pseudo-class)
    w = w.strip(trailing = false, chars = {':'})
  if w.startsWith("@"):
    let n = w.toLowerAscii
    for x in CssAtRules:
      if x[0] == n: return "**" & n & "** — at-rule\n\n" & x[1]
    return
  if w.startsWith(":"):
    let n = w.toLowerAscii.strip(chars = {':'})
    for x in CssPseudoElements:
      if x[0].strip(chars = {':'}) == n: return "**::" & n & "** — pseudo-element\n\n" & x[1]
    for x in CssPseudoClasses:
      if x[0].strip(chars = {':'}).replace("()", "") == n: return "**" & x[0] & "** — pseudo-class\n\n" & x[1]
    return
  let lw = w.toLowerAscii
  # a property: followed by `:` in a declaration
  var k = e
  while k < s.len and s[k] == ' ': inc k
  if cx.kind == ccProperty and k < s.len and s[k] == ':':
    let i = cssProp(lw)
    if i >= 0: return "**" & lw & "** — CSS property\n\n" & propDesc(i) &
                      "\n\nhttps://developer.mozilla.org/docs/Web/CSS/" & lw
    if lw.startsWith("--"): return "**" & w & "** — custom property"
    return
  if k < s.len and s[k] == '(':
    for f in CssFunctions:
      if f[0].toLowerAscii == lw: return "**" & lw & f[1] & "** — CSS function\n\n" & f[2]
  if cx.kind == ccValue:
    if lw.startsWith("--"):
      for l2 in lines:
        let d = l2.find(lw & ":")
        if d >= 0: return "**" & w & "** — custom property\n```css\n" & l2.strip & "\n```"
    let i = cssProp(cx.prop)
    if i >= 0:
      for x in CssProps[i][1].splitWhitespace:
        if x.toLowerAscii == lw: return "**" & x & "** — a value of " & cx.prop & "\n\n" & CssProps[i][3]
    if lw in CssColorNames: return "**" & lw & "** — named colour"
    if lw in CssGlobals: return "**" & lw & "** — CSS-wide keyword (any property)"
    return
  if cx.kind == ccSelector:
    let t = htmlTag(lw)
    if t >= 0: return "**" & lw & "** — HTML element\n\n" & HtmlTags[t][1]

proc cssVarTypos*(lines: openArray[string]): seq[WebDiag] =
  ## var(--name) where the sheet sets custom properties but not this one, and one a letter or two away (a typo:
  ## the browser uses nothing) — a name set nowhere near is left alone (another sheet may set it), and so is one
  ## with a fallback (var(--name, 4px): unset on purpose, often)
  var defs: seq[string]
  var uses: seq[(string, int, int)]
  var inComment = false
  for l, s in lines:
    var i = 0
    while i < s.len:
      if inComment:
        if s.continuesWith("*/", i):
          inComment = false
          inc i
        inc i
        continue
      if s.continuesWith("/*", i):
        inComment = true
        i += 2
        continue
      if s.continuesWith("--", i) and (i == 0 or s[i - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
        var e = i + 2
        while e < s.len and s[e] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: inc e
        let name = s[i ..< e]
        var k = e
        while k < s.len and s[k] == ' ': inc k
        let isUse = i >= 4 and s[0 ..< i].strip(leading = false).endsWith("var(")
        # (var(--x, fallback): one that may be unset on purpose — a library's hook for its users)
        if isUse and not (k < s.len and s[k] == ','): uses.add (name, l, i)
        elif k < s.len and s[k] == ':' and name.len > 2 and name notin defs: defs.add name
        i = e
        continue
      inc i
  if defs.len == 0: return
  for (name, l, c) in uses:
    if name in defs: continue
    let near = closest(name, defs)
    if near.len > 0:
      result.add WebDiag(line: l, col: c, eline: l, ecol: c + name.len, sev: 2, rule: "css-var",
                         msg: "'" & name & "' is not set in this sheet — '" & near & "'?")

proc cssChecks*(lines: openArray[string], strict = true): seq[WebDiag] =
  ## the mistakes a browser drops silently: an unknown property, a value its property does not take, a missing
  ## `;` between declarations on two lines, a brace too many or never closed (strict: the braces too — not for CSS
  ## cut into the pieces of a template)
  var stack: seq[(BlockKind, int, int)]       # what is open, and where its { is
  var seg = ""
  var segAt = (-1, -1)                         # where the text since the last { } ; starts
  var inComment = false
  var q = '\0'
  var inString = false
  var paren = 0
  var lastDecl = (-1, -1, -1)                  # the last declaration ended by a line end: (line, its end, block depth)
  proc finishDecl(ds: var seq[WebDiag], seg: string, at: (int, int), bk: BlockKind) =
    ## checks one declaration (seg, starting at the place `at`) when it ends: a property name that does not exist (with
    ## the nearest known one as a hint), or — for a property that takes keywords only — a single word that is not one of
    ## them. Vendor-prefixed, custom, SCSS and nested-selector text is left alone.
    if bk != bkDecls or looksSelector(seg): return
    let c = seg.find(':')
    if c <= 0: return
    let name = seg[0 ..< c].strip
    if name.len == 0 or name.startsWith("--") or name.startsWith("-") or name.startsWith("$") or
       name.startsWith("@") or not name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
      return
    let l0 = at[0]
    let c0 = at[1]
    let lname = name.toLowerAscii
    let i = cssProp(lname)
    if i < 0:
      let near = closest(lname, propNames())
      ds.add WebDiag(line: l0, col: c0, eline: l0, ecol: c0 + name.len, sev: 2, rule: "css-property",
                     msg: "unknown property '" & name & "'" & (if near.len > 0: " — did you mean '" & near & "'?" else: ""))
      return
    # a property that takes only its keywords: one word it does not know
    if CssProps[i][2].len > 0 or CssProps[i][1].len == 0: return
    var v = seg[c + 1 .. ^1].strip
    if v.endsWith("!important"): v = v[0 ..< ^10].strip
    if v.len == 0 or not v.allCharsInSet({'a'..'z', 'A'..'Z', '-'}) or v.startsWith("-"): return
    let lv = v.toLowerAscii
    let vals = CssProps[i][1].splitWhitespace
    if lv in CssGlobals: return
    for x in vals:
      if x.toLowerAscii == lv: return               # (optimizeLegibility, sRGB: any case)
    let vi = seg.find(v, c + 1)
    # (where the value is: the text's lines are joined by spaces, so count them)
    var vl = l0
    var vc = at[1] + vi
    var k = 0
    var pos = 0
    while k < vi:
      if seg[k] == '\n':
        inc vl
        pos = k + 1
      inc k
    if vl != l0: vc = vi - pos
    let near = closest(lv, vals)
    ds.add WebDiag(line: vl, col: vc, eline: vl, ecol: vc + v.len, sev: 2, rule: "css-value",
                   msg: "'" & v & "' is not a value of " & lname & (if near.len > 0: " — did you mean '" & near & "'?"
                        else: " (it takes: " & vals.join(", ") & ")"))
  for l in 0 .. lines.high:
    let s = lines[l]
    var i = 0
    while i < s.len:
      let c = s[i]
      if inComment:
        if c == '*' and i + 1 < s.len and s[i + 1] == '/':
          inComment = false
          inc i
        inc i
        continue
      if inString:
        if c == '\\': inc i
        elif c == q: inString = false
        seg.add c
        inc i
        continue
      if c == '/' and i + 1 < s.len and s[i + 1] == '*':
        inComment = true
        i += 2
        continue
      if segAt[0] < 0:
        if c in {' ', '\t'}:
          inc i
          continue
        segAt = (l, i)
      let bk = if stack.len > 0: stack[^1][0] else: bkRules
      case c
      of '"', '\'':
        inString = true
        q = c
        seg.add c
      of '(':
        inc paren
        seg.add c
      of ')':
        if paren > 0: dec paren
        seg.add c
      of '{':
        if paren > 0:
          seg.add c
        else:
          stack.add (blockKindFor(seg, bk), l, i)
          seg = ""
          segAt = (-1, -1)
          lastDecl = (-1, -1, -1)
      of '}':
        if paren > 0:
          seg.add c
        else:
          if seg.strip.len > 0 and segAt[0] >= 0: finishDecl(result, seg, segAt, bk)
          if stack.len == 0:
            if strict: result.add WebDiag(line: l, col: i, eline: l, ecol: i + 1, sev: 1, rule: "css-brace",
                                          msg: "'}' closes nothing")
          else: stack.setLen(stack.len - 1)
          seg = ""
          segAt = (-1, -1)
          lastDecl = (-1, -1, -1)
      of ';':
        if paren > 0:
          seg.add c
        else:
          if seg.strip.len > 0 and segAt[0] >= 0: finishDecl(result, seg, segAt, bk)
          seg = ""
          segAt = (-1, -1)
          lastDecl = (-1, -1, -1)
      of ':':
        # `a: 1` on this line, after `b: 2` on a line before that has no `;`: the browser reads one declaration
        if paren == 0 and bk == bkDecls and lastDecl[0] >= 0 and lastDecl[0] < l and lastDecl[2] == stack.len:
          let name = s[0 ..< i].strip
          if name.len > 0 and name.allCharsInSet({'a'..'z', '-'}) and cssProp(name) >= 0:
            result.add WebDiag(line: lastDecl[0], col: lastDecl[1], eline: lastDecl[0], ecol: lastDecl[1] + 1, sev: 1,
                               rule: "css-semicolon", msg: "missing ';' — the next line is read as part of this value")
            lastDecl = (-1, -1, -1)
        seg.add c
      else: seg.add c
      inc i
    # the line ends inside a declaration that has its `:` and a value: remember it
    if not inComment and not inString and paren == 0 and stack.len > 0 and stack[^1][0] == bkDecls:
      let t = seg.strip
      let cpos = t.find(':')
      if cpos > 0 and cpos < t.high and not looksSelector(t) and not t.endsWith(",") and
         cssProp(t[0 ..< cpos].strip.toLowerAscii) >= 0:
        lastDecl = (l, s.strip(leading = false).len - 1, stack.len)
    if not inComment and segAt[0] >= 0: seg.add '\n'
  if strict:
    for (bk, l, c) in stack:
      result.add WebDiag(line: l, col: c, eline: l, ecol: c + 1, sev: 1, rule: "css-brace", msg: "'{' is never closed")
  result.add cssVarTypos(lines)
  sortDiags(result)
