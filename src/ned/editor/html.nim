# HTML editing helpers: a closing tag added when the `>` of an opening one is typed, linked editing (renaming a tag
# renames its partner) and the expansion of Emmet abbreviations
const VoidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                  "source", "track", "wbr"]

proc htmlAutoClose(b: Buffer) =
  ## typing the `>` of <tag …> inserts </tag> after the cursor
  if b.readOnly: return
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    let h = b.cursors[i].head
    let s = b.lines[h.line]
    if h.col == 0 or s[h.col - 1] != '>': continue
    if h.col >= 2 and s[h.col - 2] == '/': continue
    let lt = s.rfind('<', last = h.col - 1)
    if lt < 0 or lt + 1 >= s.len or s[lt + 1] in {'/', '!', '?'}: continue
    var e = lt + 1
    while e < s.len and (isWordByte(s[e]) or s[e] in {'-', ':', '.'}): inc e
    let tag = s[lt + 1 ..< e]
    if tag.len == 0 or tag.toLowerAscii in VoidTags or e >= h.col: continue
    if s[h.col .. ^1].startsWith("</" & tag): continue
    discard b.replaceText(h, h, "</" & tag & ">")
    b.cursors[i] = cur(h)
  b.endEdit()
  b.normalize()

# ── HTML: renaming a tag renames its partner (linked editing) · Emmet abbreviations expand with Tab ──

func htmlTagNameAt(s: string, col: int): (int, int, bool) =
  ## the tag name the cursor is in or just after: (start, end, a closing tag?) — start -1 when none
  if col > s.len: return (-1, -1, false)
  var a = col
  while a > 0 and (isWordByte(s[a - 1]) or s[a - 1] in {'-', ':', '.'}): dec a
  var e = col
  while e < s.len and (isWordByte(s[e]) or s[e] in {'-', ':', '.'}): inc e
  if a >= 2 and s[a - 1] == '/' and s[a - 2] == '<': return (a, e, true)
  if a >= 1 and s[a - 1] == '<': return (a, e, false)
  (-1, -1, false)

proc htmlTagsOn(s: string): seq[(int, int, bool, bool)] =
  ## the tags on a line: (name start, name end, closing?, self-closing?)
  var i = 0
  while i < s.len:
    if s[i] == '<' and i + 1 < s.len:
      if s.continuesWith("<!--", i):
        let e = s.find("-->", i + 4)
        if e < 0: break
        i = e + 3
        continue
      let cl = s[i + 1] == '/'
      let na = i + (if cl: 2 else: 1)
      var ne = na
      while ne < s.len and (isWordByte(s[ne]) or s[ne] in {'-', ':', '.'}): inc ne
      if ne > na:
        let gt = s.find('>', ne)
        result.add (na, ne, cl, gt > 0 and s[gt - 1] == '/')
      i = ne
    else: inc i

proc htmlPartner(b: Buffer, line, a, e: int, closing: bool): (int, int, int) =
  ## the matching tag's name: (line, start, end) — line -1 when there is none
  let name = b.lines[line][a ..< e].toLowerAscii
  if name.len == 0 or name in VoidTags: return (-1, 0, 0)
  var depth = 0
  if not closing:
    var l = line
    while l < b.lines.len and l - line < 5000:
      for (na, ne, cl, selfc) in htmlTagsOn(b.lines[l]):
        if l == line and na <= a: continue
        if b.lines[l][na ..< ne].toLowerAscii != name or selfc: continue
        if cl:
          if depth == 0: return (l, na, ne)
          dec depth
        else: inc depth
      inc l
  else:
    var l = line
    while l >= 0 and line - l < 5000:
      let ts = htmlTagsOn(b.lines[l])
      for k in countdown(ts.high, 0):
        let (na, ne, cl, selfc) = ts[k]
        if l == line and na >= a: continue
        if b.lines[l][na ..< ne].toLowerAscii != name or selfc: continue
        if cl: inc depth
        elif depth == 0: return (l, na, ne)
        else: dec depth
      dec l
  (-1, 0, 0)

var htmlLink, htmlLinkLast: tuple[bufId, line, a: int, closing: bool, name: string, pl, pa, pe: int] =
  (0, 0, 0, false, "", -1, 0, 0)

proc htmlElementAround(b: Buffer, p: Pos): (bool, Pos, Pos, Pos, Pos) =
  ## the nearest element around p: (found, the opening tag's start, the end after its `>`, the closing tag's start,
  ## the end after its `>`) — found by walking back to an opening tag whose closing tag is after p. Each tag's start
  ## and end are on one line.
  var l = p.line
  var depth: Table[string, int]
  while l >= 0 and p.line - l < 2000:
    let ts = htmlTagsOn(b.lines[l])
    for k in countdown(ts.high, 0):
      let (na, ne, cl, selfc) = ts[k]
      if l == p.line and na > p.col: continue
      let name = b.lines[l][na ..< ne].toLowerAscii
      if selfc or name in VoidTags: continue
      if cl: depth[name] = depth.getOrDefault(name) + 1
      elif depth.getOrDefault(name) > 0: depth[name] = depth[name] - 1
      else:
        let (pl, pa, pe) = b.htmlPartner(l, na, ne, false)
        if pl < 0: continue
        let gt = b.lines[l].find('>', ne)
        let cgt = b.lines[pl].find('>', pe)
        if gt < 0 or cgt < 0: continue
        let closeStart = Pos(line: pl, col: pa - 2)
        if closeStart < p: continue
        return (true, Pos(line: l, col: na - 1), Pos(line: l, col: gt + 1),
                closeStart, Pos(line: pl, col: cgt + 1))
    dec l
  (false, p, p, p, p)
proc htmlLinkBefore(b: Buffer) =
  ## run before an edit: when the cursor is in a tag's name, remembers that name and where the matching opening or
  ## closing tag's name is (in htmlLink), so htmlLinkAfter can rename it; with the whole name deleted, the partner from
  ## the last change is used
  htmlLink.pl = -1
  if b.cursors.len != 1 or b.primary.hasSel or b.readOnly: return
  let h = b.primary.head
  let s = b.lines[h.line]
  let (a, e, cl) = htmlTagNameAt(s, h.col)
  if a < 0: return
  if e == a:
    # the whole name was deleted: its partner (now empty too) is remembered from the last change
    let lk = htmlLinkLast
    if lk.pl >= 0 and lk.bufId == b.id and lk.line == h.line and lk.a == a and lk.closing == cl and lk.name == "" and
       lk.pl < b.lines.len and lk.pe <= b.lines[lk.pl].len:
      htmlLink = lk
    return
  let (pl, pa, pe) = b.htmlPartner(h.line, a, e, cl)
  if pl < 0: return
  htmlLink = (b.id, h.line, a, cl, s[a ..< e], pl, pa, pe)

proc htmlLinkAfter(b: Buffer) =
  ## the tag name just changed: give its partner the same name (one undo step with the typing)
  if htmlLink.pl < 0 or htmlLink.bufId != b.id: return
  let lk = htmlLink
  htmlLink.pl = -1
  let h = b.primary.head
  if h.line != lk.line or b.cursors.len != 1: return
  let s = b.lines[h.line]
  let (a, e, cl) = htmlTagNameAt(s, h.col)
  if a != lk.a or cl != lk.closing: return
  let nn = s[a ..< e]
  if nn == lk.name: return
  var pa = lk.pa
  var pe = lk.pe
  if lk.pl == lk.line and pa > a:
    pa += nn.len - lk.name.len
    pe += nn.len - lk.name.len
  if lk.pl >= b.lines.len or pe > b.lines[lk.pl].len or pa < 0 or
     b.lines[lk.pl][pa ..< pe].toLowerAscii != lk.name.toLowerAscii: return
  # joined to the typing (or deleting) it follows, so one undo takes both back
  b.beginEdit(if b.undoStack.len > 0 and b.undoStack[^1].kind in {ekType, ekDelete}: b.undoStack[^1].kind else: ekType)
  discard b.replaceText(Pos(line: lk.pl, col: pa), Pos(line: lk.pl, col: pe), nn)
  b.endEdit()
  # remembered for the next key (a partner before the tag on the same line moved the tag)
  htmlLinkLast = (b.id, lk.line, (if lk.pl == lk.line and pa < a: a + nn.len - lk.name.len else: a), cl, nn, lk.pl, pa,
                  pa + nn.len)

# Emmet: ul>li.item$*3, div#main.box>p{Hello}+a[href=/], (header>nav)+main, !, lorem

type EmNode = ref object
  tag, id, text: string
  classes: seq[string]
  attrs: seq[(string, string)]
  count: int
  children: seq[EmNode]
  group: bool

const EmTags = ["a", "abbr", "address", "article", "aside", "audio", "b", "blockquote", "body", "br", "button",
  "canvas", "caption", "code", "dd", "details", "div", "dl", "dt", "em", "fieldset", "figcaption", "figure",
  "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "i", "iframe", "img",
  "input", "label", "legend", "li", "link", "main", "meta", "nav", "ol", "option", "p", "pre", "script",
  "section", "select", "small", "source", "span", "strong", "style", "sub", "summary", "sup", "svg", "table",
  "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "ul", "video", "lorem"]

func emCount(s: string, i: var int): int =
  ## reads the `*3` repeat count at `i` in an Emmet abbreviation (moving `i` on); 1 when there is none, a ValueError for
  ## a count outside 1 to 200
  result = 1
  if i < s.len and s[i] == '*':
    inc i
    var n = 0
    var any = false
    while i < s.len and s[i].isDigit:
      n = n * 10 + ord(s[i]) - ord('0')
      any = true
      inc i
    if not any or n < 1 or n > 200: raise newException(ValueError, "count")
    result = n

proc emElement(s: string, i: var int): EmNode =
  ## reads one element of an Emmet abbreviation at `i`: a tag name followed by any of `#id`, `.class`, `[attr=value …]`,
  ## `{text}` and `*count`; a ValueError when it is malformed or empty
  result = EmNode(count: 1)
  let st = i
  while i < s.len and (s[i].isAlphaNumeric or s[i] in {':', '-'}): inc i
  result.tag = s[st ..< i]
  var any = result.tag.len > 0
  while i < s.len:
    case s[i]
    of '#', '.':
      let kind = s[i]
      inc i
      let a = i
      while i < s.len and (s[i].isAlphaNumeric or s[i] in {'_', '-', '$', '@'}): inc i
      if i == a: raise newException(ValueError, "name")
      if kind == '#': result.id = s[a ..< i] else: result.classes.add s[a ..< i]
      any = true
    of '[':
      let e = s.find(']', i)
      if e < 0: raise newException(ValueError, "]")
      var body = s[i + 1 ..< e]
      i = e + 1
      while body.strip.len > 0:
        body = body.strip(trailing = false)
        var k = 0
        while k < body.len and body[k] notin {'=', ' '}: inc k
        let name = body[0 ..< k]
        var val = ""
        if k < body.len and body[k] == '=':
          inc k
          if k < body.len and body[k] in {'"', '\''}:
            let q = body[k]
            let qe = body.find(q, k + 1)
            if qe < 0: raise newException(ValueError, "quote")
            val = body[k + 1 ..< qe]
            k = qe + 1
          else:
            let a = k
            while k < body.len and body[k] != ' ': inc k
            val = body[a ..< k]
        if name.len > 0: result.attrs.add (name, val)
        body = body[min(k, body.len) .. ^1]
      any = true
    of '{':
      let e = s.find('}', i)
      if e < 0: raise newException(ValueError, "}")
      result.text = s[i + 1 ..< e]
      i = e + 1
      any = true
    of '*':
      result.count = emCount(s, i)
    else: break
  if not any: raise newException(ValueError, "element")

proc emParse(s: string, i: var int): EmNode =
  ## siblings and children up to a ) or the end, under a group node
  result = EmNode(group: true, count: 1)
  var parents = @[result]
  var last: EmNode = nil
  while i < s.len:
    case s[i]
    of ')': return
    of '>':
      if last == nil: raise newException(ValueError, ">")
      parents.add last
      inc i
    of '+': inc i
    of '^':
      if parents.len > 1: parents.setLen(parents.len - 1)
      inc i
    of '(':
      inc i
      let g = emParse(s, i)
      if i >= s.len or s[i] != ')': raise newException(ValueError, ")")
      inc i
      g.count = emCount(s, i)
      parents[^1].children.add g
      last = g
    else:
      let n = emElement(s, i)
      parents[^1].children.add n
      last = n

proc emNumber(s: string, idx: int): string =
  ## $ → the copy's number ($$ → 01 …)
  result = ""
  var i = 0
  while i < s.len:
    if s[i] == '$':
      var n = 0
      while i < s.len and s[i] == '$':
        inc n
        inc i
      result.add align($idx, n, '0')
    else:
      result.add s[i]
      inc i

proc emRender(n: EmNode, parentTag: string, idx: int, ind, unit: string, outp: var seq[string]) =
  ## adds the HTML lines for an Emmet node, repeated by its count, to `outp`, indented by `ind` and `unit` for the
  ## children. A missing tag name comes from the parent (li in a list, td in a row …), `$` in names and text becomes the
  ## copy's number, a, img, link, input and label get their usual attributes, void tags have no closing tag, and \x01
  ## marks where the cursor goes.
  for k in 1 .. n.count:
    let ix = if n.count > 1: k else: idx
    if n.group:
      for c in n.children: emRender(c, parentTag, ix, ind, unit, outp)
      continue
    if n.tag == "lorem":
      outp.add ind & "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt."
      continue
    let tag = if n.tag.len > 0: n.tag
              else:
                case parentTag
                of "ul", "ol": "li"
                of "table", "tbody", "thead", "tfoot": "tr"
                of "tr": "td"
                of "select", "optgroup": "option"
                of "span", "a", "em", "strong", "b", "i", "p", "label", "button": "span"
                else: "div"
    var open = "<" & tag
    if n.id.len > 0: open.add " id=\"" & emNumber(n.id, ix) & "\""
    if n.classes.len > 0:
      var cs: seq[string]
      for c in n.classes: cs.add emNumber(c, ix)
      open.add " class=\"" & cs.join(" ") & "\""
    var attrs = n.attrs
    var have: seq[string]
    for (an, _) in attrs: have.add an
    case tag
    of "a": (if "href" notin have: attrs.insert(("href", ""), 0))
    of "img":
      if "src" notin have: attrs.add ("src", "")
      if "alt" notin have: attrs.add ("alt", "")
    of "link":
      if "rel" notin have: attrs.add ("rel", "stylesheet")
      if "href" notin have: attrs.add ("href", "")
    of "input": (if "type" notin have: attrs.insert(("type", "text"), 0))
    of "label": (if "for" notin have: attrs.add ("for", ""))
    else: discard
    for (an, av) in attrs:
      open.add " " & an & "=\"" & (if av.len == 0: "\x01" else: emNumber(av, ix)) & "\""
    open.add ">"
    let text = emNumber(n.text, ix)
    if tag.toLowerAscii in VoidTags: outp.add ind & open
    elif n.children.len == 0: outp.add ind & open & (if text.len > 0: text else: "\x01") & "</" & tag & ">"
    else:
      outp.add ind & open & text
      for c in n.children: emRender(c, tag, ix, ind & unit, unit, outp)
      outp.add ind & "</" & tag & ">"

proc emmetExpand(abbr, unit: string): string =
  ## the HTML for an abbreviation ("" when it is not one); \x01 marks where the cursor goes
  if abbr == "!":
    return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n" & unit & "<meta charset=\"UTF-8\">\n" & unit &
           "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n" & unit &
           "<title>Document</title>\n</head>\n<body>\n" & unit & "\x01\n</body>\n</html>"
  var plain = true
  for c in abbr:
    if c in {'.', '#', '>', '+', '^', '*', '(', '[', '{'}: plain = false
  if plain and abbr.toLowerAscii notin EmTags: return ""
  try:
    var i = 0
    let root = emParse(abbr, i)
    if i != abbr.len: return ""
    var outp: seq[string]
    emRender(root, "", 1, "", unit, outp)
    outp.join("\n")
  except ValueError: ""
