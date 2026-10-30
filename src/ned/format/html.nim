# ── HTML (and the templates in it): block elements on their own lines with their content indented, inline content
# flowing in lines; <pre>, <textarea>, <script>, <style>, comments, declarations and templates kept as written ──

const
  hVoidElems = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
  hRawElems = ["pre", "textarea", "script", "style"]
  hBlockElems = ["address", "area", "article", "aside", "base", "blockquote", "body", "caption", "center", "col",
    "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
    "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
    "legend", "li", "link", "main", "menu", "meta", "nav", "noscript", "ol", "optgroup", "option", "p", "pre",
    "script", "search", "section", "source", "style", "summary", "table", "tbody", "td", "template", "tfoot", "th",
    "thead", "title", "tr", "track", "ul",
    # SVG's groups and shapes (the whitespace between them does not show)
    "circle", "clippath", "defs", "ellipse", "filter", "g", "line", "lineargradient", "marker", "mask", "path",
    "pattern", "polygon", "polyline", "radialgradient", "rect", "stop", "symbol", "use"]
  hClosesP = ["address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "fieldset",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
    "menu", "nav", "ol", "p", "pre", "section", "table", "ul"]
  hWs = {' ', '\t', '\n', '\r', '\f'}
  hChanged = "the built-in HTML formatter would change the content here, so nothing was changed"

type
  HTokKind = enum htText, htOpen, htClose, htComment, htDecl, htRaw
  HTok = object
    kind: HTokKind
    text: string          # htText: as in the source; htComment, htDecl, htRaw: as it is; htClose: `</name>`
    name: string          # a tag's name as written
    lname: string         # … in lower case
    attrs: seq[string]    # a start tag's attributes, each as written
    slash: string         # how a self-closed start tag ends: "/>" or " />" ("" for `>`)
  HNode = ref object
    tok: HTok             # the start tag of an element, else the token itself
    kids: seq[HNode]
    close: string         # the end tag (`</name>`), "" when it is left out
    blk: bool             # laid out as a block: a block element, an element with a block in it, a declaration
  HGap = enum gNone, gSpace, gKeep   # before an atom: nothing, a space (or a line break), a space kept in the line
  HAtomKind = enum haWord, haTag, haComment, haRaw, haBlock
  HAtom = object
    kind: HAtomKind
    text: string          # a word (templates whole), an end tag, a comment, raw content
    node: HNode           # a start tag's element, a block
    gap: HGap
    nl: int               # line breaks in the whitespace before it in the source
    stmt: bool            # a comment or template statement in a block's own content: alone on its line(s) or kept in it
    alone: bool           # … on a line of its own
  HFlat = object
    atoms: seq[HAtom]
    ws: bool              # whitespace before the next atom
    nl: int               # … with this many line breaks

func hFindClose(s: string, i: int, close: string, limit: int): int =
  ## the index just after the next `close` text found from i within `limit` characters, or -1
  let e = s.find(close, i, last = min(s.high, i + limit))
  if e < 0: -1 else: e + close.len

func hTemplEnd(s: string, i: int): int =
  ## the end (exclusive) of the template at s[i] — {{ }}, {% %}, {# #}, <% %>, a Nim strformat {expr} (also the
  ## {…} of JavaScript's ${…}) — or -1 when there is none
  if s[i] == '<':
    return (if i + 1 < s.len and s[i + 1] == '%': hFindClose(s, i + 2, "%>", 4000) else: -1)
  if s[i] != '{': return -1
  if i + 1 < s.len and s[i + 1] in {'{', '%', '#'}:
    let r = hFindClose(s, i + 2, (if s[i + 1] == '{': "}}" else: s[i + 1] & "}"), 4000)
    if r > 0: return r
  # {expr}: balanced braces on one line, no tags in it
  var depth = 0
  var j = i
  while j < s.len and j - i < 400:
    case s[j]
    of '{': inc depth
    of '}':
      dec depth
      if depth == 0: return j + 1
    of '\n', '<': return -1
    else: discard
    inc j
  -1

func hIsStmt(w: string): bool =
  ## a template statement ({% %}, {# #}, <% %> but not the output of <%= %>), the whole word
  (w.startsWith("{%") or w.startsWith("{#") or w.startsWith("<%") and not w.startsWith("<%=") and
    not w.startsWith("<%-")) and hTemplEnd(w, 0) == w.len

proc hAttrTok(s: string, i: int): int =
  ## the end of the attribute text at s[i] (quoted values and templates whole), -1 when a quote is not closed
  var j = i
  while j < s.len:
    let c = s[j]
    if c in hWs or c == '>' or c == '/' and j + 1 < s.len and s[j + 1] == '>': break
    if c in {'"', '\''}:
      let e = s.find(c, j + 1)
      if e < 0: return -1
      j = e + 1
    elif c in {'{', '<'}:
      let e = hTemplEnd(s, j)
      j = if e > 0: e else: j + 1
    else: inc j
  j

proc hAttrEnd(s: string, i: int): int =
  ## the end of the attribute at s[i]: its name, and `= value` with the spaces around = as written
  var j = hAttrTok(s, i)
  while j > 0:
    var k = j
    while k < s.len and s[k] in hWs: inc k
    if k >= s.len or k == j or s[k] == '>' or s[k] == '/' and k + 1 < s.len and s[k + 1] == '>': break
    if s[k] == '=' or s[j - 1] == '=': j = hAttrTok(s, k)   # `name =value`, `name= value`
    else: break
  j

proc hOpenTag(s: string, i: int, t: var HTok): int =
  ## reads the start tag at s[i] (`<` and a letter) into t: the index after it, -1 when it does not end
  var j = i + 1
  while j < s.len and s[j] notin hWs + {'>', '/'}: inc j
  t = HTok(kind: htOpen, name: s[i + 1 ..< j])
  t.lname = t.name.toLowerAscii
  while true:
    var ws = false
    while j < s.len and s[j] in hWs:
      ws = true
      inc j
    if j >= s.len: return -1
    if s[j] == '>': return j + 1
    if s[j] == '/' and j + 1 < s.len and s[j + 1] == '>':
      t.slash = if ws: " />" else: "/>"
      return j + 2
    let a = hAttrEnd(s, j)
    if a < 0: return -1
    t.attrs.add s[j ..< a]
    j = a

proc htmlToks(s: string, err: var string): seq[HTok] =
  ## text (whitespace and templates in it), tags, comments, declarations, and the content of raw elements as it is
  let low = s.toLowerAscii
  var i = 0
  var textStart = 0
  template add(t: HTok, next: int) =
    ## adds token t to the result, first adding the text that came before it as a text token, and moves on to `next`
    if i > textStart: result.add HTok(kind: htText, text: s[textStart ..< i])
    result.add t
    i = next
    textStart = next
  template fail(msg: string) =
    ## gives up with the error message and the line the reader had reached
    err = msg & " (line " & $(s[0 ..< i].count('\n') + 1) & ")"
    return
  while i < s.len:
    let c = s[i]
    let d = if i + 1 < s.len: s[i + 1] else: '\0'
    if c == '{' or c == '<' and d == '%':
      let e = hTemplEnd(s, i)
      i = if e > 0: e else: i + 1
    elif c != '<': inc i
    elif s.continuesWith("<!--", i):
      let e = s.find("-->", i + 4)
      if e < 0: fail "a comment is not closed"
      add(HTok(kind: htComment, text: s[i ..< e + 3]), e + 3)
    elif d in {'!', '?'}:
      let close = if s.continuesWith("<![CDATA[", i): "]]>" elif d == '?': "?>" else: ">"
      let e = s.find(close, i + 2)
      if e < 0: fail "a declaration is not closed"
      add(HTok(kind: htDecl, text: s[i ..< e + close.len]), e + close.len)
    elif d == '/' and i + 2 < s.len and s[i + 2] in Letters:
      var j = i + 2
      while j < s.len and s[j] notin hWs + {'>', '/', '<'}: inc j
      let name = s[i + 2 ..< j]
      while j < s.len and s[j] in hWs: inc j
      if j >= s.len or s[j] != '>': fail "the end tag </" & name & " is not closed or has something in it"
      add(HTok(kind: htClose, name: name, lname: name.toLowerAscii, text: "</" & name & ">"), j + 1)
    elif d in Letters:
      var t: HTok
      let j = hOpenTag(s, i, t)
      if j < 0: fail "the tag <" & t.name & " is not closed"
      add(t, j)
      if t.lname in hRawElems and t.slash.len == 0:
        # its content, as it is, up to its end tag
        var e = j
        while true:
          e = low.find("</" & t.lname, e)
          if e < 0: fail "<" & t.name & "> is not closed"
          let after = e + 2 + t.lname.len
          if after >= s.len or s[after] in hWs + {'>', '/'}: break
          e = after
        if e > j: add(HTok(kind: htRaw, text: s[j ..< e]), e)
    else: inc i
  if i > textStart: result.add HTok(kind: htText, text: s[textStart ..< i])

proc hAutoClose(stack: var seq[HNode], name: string) =
  ## the elements a start tag ends when their end tags are left out: <li> after <li>, <td> after <td>, <p> before a block…
  while stack.len > 1:
    let top = stack[^1].tok.lname
    let ends = case name
      of "li": top in ["li", "p"]
      of "dt", "dd": top in ["dt", "dd", "p"]
      of "tr": top in ["tr", "td", "th"]
      of "td", "th": top in ["td", "th"]
      of "thead", "tbody", "tfoot": top in ["thead", "tbody", "tfoot", "tr", "td", "th"]
      of "option": top == "option"
      of "optgroup": top in ["optgroup", "option"]
      else: top == "p" and name in hClosesP
    if not ends: break
    stack.setLen(stack.len - 1)

proc hTree(toks: seq[HTok]): HNode =
  ## the elements and what is in them; an end tag closes the elements still open in it, one that closes nothing
  ## (a stray end tag) stays where it is
  result = HNode(tok: HTok(kind: htOpen))
  var stack = @[result]
  for t in toks:
    case t.kind
    of htOpen:
      hAutoClose(stack, t.lname)
      let n = HNode(tok: t)
      stack[^1].kids.add n
      if t.slash.len == 0 and t.lname notin hVoidElems: stack.add n
    of htClose:
      var k = stack.high
      while k > 0 and stack[k].tok.lname != t.lname: dec k
      if k > 0:
        stack[k].close = t.text
        stack.setLen(k)
      else: stack[^1].kids.add HNode(tok: t)
    else: stack[^1].kids.add HNode(tok: t)

proc hMark(n: HNode): bool =
  ## marks (and says) what is laid out as a block
  var inner = false
  for k in n.kids:
    if hMark(k): inner = true
  n.blk = case n.tok.kind
    of htOpen: inner or n.tok.lname in hBlockElems
    of htDecl: true
    of htClose: n.tok.lname in hBlockElems
    else: false
  n.blk

proc hTagText(t: HTok, d, ind, maxW: int): string =
  ## a start tag on one line, or with one attribute a line when that line would be longer than maxW
  let tail = if t.slash.len > 0: t.slash else: ">"
  result = "<" & t.name
  for a in t.attrs: result.add " " & a
  result.add tail
  if t.attrs.len >= 2 and d * ind + strWidth(result) > maxW:
    result = "<" & t.name
    for a in t.attrs: result.add "\n" & spaces((d + 1) * ind) & a
    result.add tail

iterator hWords(s: string): tuple[ws: bool, nl: int, word: string] =
  ## the words of a text (templates whole), each with the whitespace before it; a last "" for the whitespace at the end
  var i = 0
  var ws = false
  var nl = 0
  var w = ""
  while i < s.len:
    let c = s[i]
    if c in hWs:
      if w.len > 0:
        yield (ws, nl, w)
        (ws, nl, w) = (false, 0, "")
      ws = true
      if c == '\n': inc nl
      inc i
    else:
      var e = if c in {'{', '<'}: hTemplEnd(s, i) else: -1
      if e < 0: e = i + 1
      w.add s[i ..< e]
      i = e
  if w.len > 0:
    yield (ws, nl, w)
    (ws, nl) = (false, 0)
  yield (ws, nl, "")

proc hAdd(f: var HFlat, a: HAtom) =
  ## adds an atom to the flattened content, noting whether whitespace (and how many line breaks) stood before it in the
  ## source
  var a = a
  a.gap = if f.ws: gSpace else: gNone
  a.nl = f.nl
  f.ws = false
  f.nl = 0
  f.atoms.add a

proc hFlatten(f: var HFlat, kids: seq[HNode], top: bool) =
  ## the atoms of a block's content: inline elements opened up into their tags and content, blocks whole
  for n in kids:
    case n.tok.kind
    of htText:
      for (ws, nl, w) in hWords(n.tok.text):
        if ws: f.ws = true
        f.nl += nl
        if w.len > 0: f.hAdd HAtom(kind: haWord, text: w, stmt: top and hIsStmt(w))
    of htComment: f.hAdd HAtom(kind: haComment, text: n.tok.text, stmt: top)
    of htRaw: f.hAdd HAtom(kind: haRaw, text: n.tok.text)
    else:
      if n.blk: f.hAdd HAtom(kind: haBlock, node: n)
      elif n.tok.kind == htOpen:
        f.hAdd HAtom(kind: haTag, node: n)
        f.hFlatten(n.kids, false)
        if n.close.len > 0: f.hAdd HAtom(kind: haTag, text: n.close)
      else: f.hAdd HAtom(kind: haTag, text: n.tok.text)

proc hAtomsOf(kids: seq[HNode], closed: bool): seq[HAtom] =
  ## a block's content as atoms; a comment or template statement with line breaks (or blocks) on both sides keeps
  ## its own line, one inside a line keeps the spaces around it as spaces (so it stays inside its line); the end
  ## of a block without an end tag (or of the text) is the end of a line
  var f = HFlat()
  f.hFlatten(kids, true)
  result = f.atoms
  for i in 0 ..< result.len:
    if not result[i].stmt: continue
    let before = i == 0 or result[i].nl > 0 or result[i - 1].kind == haBlock
    let after = if i == result.high: f.nl > 0 or not closed else: result[i + 1].nl > 0 or result[i + 1].kind == haBlock
    if before and after: result[i].alone = true
    else:
      if result[i].gap == gSpace: result[i].gap = gKeep
      if i < result.high and result[i + 1].gap == gSpace: result[i + 1].gap = gKeep

# is this atom put on lines of its own: a block element, or a comment or template statement that stood alone in the
# source
func hOwnLine(a: HAtom): bool = a.kind == haBlock or a.alone

# is this atom a <br> tag, after which a line is broken
func hIsBr(a: HAtom): bool = a.kind == haTag and a.node != nil and a.node.tok.lname == "br"

proc hWidth(s: string, last = false): int =
  ## the width of the first (or the last) line of s
  if last: strWidth(s[s.rfind('\n') + 1 .. ^1])
  else:
    let e = s.find('\n')
    strWidth(if e < 0: s else: s[0 ..< e])

proc hPiece(a: HAtom, d, ind, maxW: int): string =
  ## the text an atom is written as: a start tag laid out by hTagText, anything else as it is
  if a.kind == haTag and a.node != nil: hTagText(a.node.tok, d, ind, maxW) else: a.text

proc hFill(o: var string, atoms: openArray[HAtom], d, ind, maxW: int) =
  ## inline content at depth d: lines filled up to maxW, broken only where the source had whitespace (and after a
  ## <br> with whitespace after it, and before what takes several lines)
  let pad = spaces(d * ind)
  o.add pad
  var col = d * ind
  var i = 0
  while i < atoms.len:
    var j = i + 1
    while j < atoms.len and atoms[j].gap != gSpace: inc j
    var unit = ""
    for k in i ..< j:
      if k > i and atoms[k].gap == gKeep: unit.add ' '
      unit.add hPiece(atoms[k], d, ind, maxW)
    if i > 0:
      if hIsBr(atoms[i - 1]) or '\n' in unit or col + 1 + hWidth(unit) > maxW:
        o.add "\n" & pad
        col = d * ind
      else:
        o.add ' '
        inc col
    o.add unit
    col = if '\n' in unit: hWidth(unit, last = true) else: col + hWidth(unit)
    i = j
  o.add '\n'

proc hFlatLine(atoms: seq[HAtom], d, ind, maxW: int): (string, bool) =
  ## inline content on one line (false when it cannot be: a block in it, a line kept for itself, a <br> to break after)
  var line = ""
  for k, a in atoms:
    if a.hOwnLine or k > 0 and a.gap == gSpace and hIsBr(atoms[k - 1]): return ("", false)
    if k > 0 and a.gap != gNone: line.add ' '
    line.add hPiece(a, d, ind, maxW)
  (line, true)

proc hAtoms(o: var string, atoms: seq[HAtom], d, ind, maxW: int)

proc hBlock(o: var string, n: HNode, d, ind, maxW: int) =
  ## a block on its own lines: on one line when its content is short inline content
  let pad = spaces(d * ind)
  if n.tok.kind != htOpen:
    o.add pad & n.tok.text & "\n"
    return
  let open = hTagText(n.tok, d, ind, maxW)
  if n.tok.lname in hRawElems and n.tok.slash.len == 0:
    o.add pad & open & (if n.kids.len > 0: n.kids[0].tok.text else: "") & n.close & "\n"
    return
  let atoms = hAtomsOf(n.kids, n.close.len > 0)
  let (flat, ok) = hFlatLine(atoms, d, ind, maxW)
  let one = open & flat & n.close
  if ok and '\n' notin one and d * ind + strWidth(one) <= maxW:
    o.add pad & one & "\n"
    return
  o.add pad & open & "\n"
  o.hAtoms(atoms, d + 1, ind, maxW)
  if n.close.len > 0: o.add pad & n.close & "\n"

proc hAtoms(o: var string, atoms: seq[HAtom], d, ind, maxW: int) =
  ## a block's content at depth d: each block on its own lines, the inline content between them filled in lines,
  ## one blank line where the source had blank lines
  var i = 0
  while i < atoms.len:
    if i > 0 and atoms[i].nl >= 2 and not o.endsWith("\n\n"): o.add '\n'
    if atoms[i].kind == haBlock:
      o.hBlock(atoms[i].node, d, ind, maxW)
      inc i
    elif atoms[i].alone:
      o.add spaces(d * ind) & atoms[i].text & "\n"
      inc i
    else:
      var j = i + 1
      while j < atoms.len and not atoms[j].hOwnLine: inc j
      o.hFill(atoms.toOpenArray(i, j - 1), d, ind, maxW)
      i = j

type HCanon = object
  s: string
  sp: bool    # whitespace pending
  edge: bool  # next to a block's tag: whitespace there does not count

proc hAdd(c: var HCanon, x: string, blk = false) =
  ## adds a piece to the comparison form of a document: a block's tag is marked off with NUL characters and whitespace
  ## next to it is dropped, other pieces are joined by a single space where whitespace stood
  if blk:
    c.s.add "\0" & x & "\0"
    c.edge = true
  else:
    if c.sp and not c.edge: c.s.add ' '
    c.s.add x
    c.edge = false
  c.sp = false

proc hCanon(c: var HCanon, kids: seq[HNode]) =
  ## what the formatter must keep: the tags (attributes as written), the text with its whitespace collapsed
  ## (whitespace next to a block's tags does not count), comments, raw content, declarations
  for n in kids:
    case n.tok.kind
    of htText:
      for (ws, _, w) in hWords(n.tok.text):
        if ws: c.sp = true
        if w.len > 0: c.hAdd w
    of htComment, htRaw: c.hAdd n.tok.text
    of htDecl, htClose: c.hAdd("\0" & n.tok.text, n.blk)
    of htOpen:
      c.hAdd("\0" & hTagText(n.tok, 0, 1, high(int)), n.blk)
      c.hCanon(n.kids)
      if n.close.len > 0: c.hAdd("\0" & n.close, n.blk)
      elif n.blk: (c.sp, c.edge) = (false, true)

proc hCanonOf(s: string, err: var string): string =
  ## the comparison form of an HTML text (its tags, collapsed text, comments and raw content) that the formatter's
  ## result is checked against; empty with err set when the HTML cannot be read
  let toks = htmlToks(s, err)
  if err.len > 0: return
  let root = hTree(toks)
  discard hMark(root)
  var c = HCanon(edge: true)
  c.hCanon(root.kids)
  c.s

proc fmtHtml*(s: string, indent = 2, maxW = 100): (string, string) =
  ## (formatted text, error): block elements on their own lines, their content indented, inline elements and text
  ## flowing in lines up to maxW, whitespace collapsed; <pre>, <textarea>, <script>, <style>, comments,
  ## declarations, attributes and templates ({{ }}, {% %}, <% %>, ${}, {expr}) as written
  let src = s.replace("\r\n", "\n")
  let ind = max(1, indent)
  var err = ""
  let toks = htmlToks(src, err)
  if err.len > 0: return (s, err)
  let root = hTree(toks)
  discard hMark(root)
  var o = ""
  o.hAtoms(hAtomsOf(root.kids, false), 0, ind, maxW)
  let res = if o.len == 0: "\n" else: o
  # safety: the same tags, text, comments and raw content
  var e1, e2 = ""
  if hCanonOf(src, e1) != hCanonOf(res, e2) or e2.len > 0: return (s, hChanged)
  (res, "")
