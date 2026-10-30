## ── ned's own HTML: where the cursor is (a tag's name, an attribute, its value, text), what fits there, what an
##    element or attribute is, and the mistakes a browser repairs silently (a closing tag that closes the wrong
##    element, one never closed, an id twice, an element that does not exist) ──

import std/[strutils, sets, tables]
import webdata, webcommon

type
  HtmlCtxKind* = enum hcNone, hcText, hcTagName, hcCloseTag, hcAttrName, hcAttrValue
  HtmlCtx* = object
    kind*: HtmlCtxKind
    tag*: string               # hcAttrName / hcAttrValue: the element's name (lower case)
    attr*: string              # hcAttrValue: the attribute's name (lower case)
    start*: int                # where the word being completed starts
    word*: string
    open*: seq[string]         # the elements open there, outermost first
    quoted*: bool              # hcAttrValue: in quotes
  HtmlTagAt* = object          # a tag of the document
    name*: string              # lower case
    closing*, selfClosing*: bool
    line*, col*, eline*, ecol*: int     # from `<` to after `>`
    attrs*: seq[(string, string, int, int)]   # (name lower case, value, line, column of the name)

const
  OptionalEnd = ["p", "li", "dt", "dd", "rt", "rp", "optgroup", "option", "colgroup", "caption", "thead", "tbody",
                 "tfoot", "tr", "td", "th", "head", "body", "html"]
  RawText = ["script", "style", "textarea", "title", "pre"]   # (pre: markup inside is markup, but kept as written)
  BoolAttrs = ["hidden", "disabled", "checked", "required", "readonly", "multiple", "selected", "autofocus",
               "novalidate", "async", "defer", "open", "loop", "muted", "controls", "autoplay", "playsinline", "inert",
               "ismap", "nomodule", "reversed", "default", "formnovalidate", "allowfullscreen", "itemscope"]

func isVoid*(t: string): bool =
  ## true for an element that has no end tag (br, img, input …)
  let i = htmlTag(t)
  i >= 0 and HtmlTags[i][2]

# can the character be in a tag or attribute name?
func isNameChar(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', ':', '.'} or ord(c) >= 0x80

proc htmlTags*(lines: openArray[string], upto = (high(int), 0)): seq[HtmlTagAt] =
  ## the document's tags up to a place (comments, <!DOCTYPE>, and what <script> and <style> hold skipped)
  var l = 0
  var c = 0
  var raw = ""                                     # inside <script> or <style>: until its </…>
  # true when the reading position (l, c) is past the last line or at or past the place to stop at
  template atEnd(): bool = l > lines.high or (l == upto[0] and c >= upto[1]) or l > upto[0]
  # the character at the reading position; a line end reads as a newline
  template ch(): char = (if c < lines[l].len: lines[l][c] else: '\n')
  template adv() =
    ## moves the reading position one character on, to the start of the next line after the end of a line
    if c < lines[l].len: inc c
    else:
      inc l
      c = 0
  while not atEnd():
    let s = lines[l]
    if raw.len > 0:
      let k = s.toLowerAscii.find("</" & raw, c)
      if k < 0:
        inc l
        c = 0
        continue
      c = k
      raw = ""
      continue
    let k = s.find('<', c)
    if k < 0:
      inc l
      c = 0
      continue
    c = k
    if l == upto[0] and c >= upto[1]: break
    if s.continuesWith("<!--", c):
      # a comment: to its -->
      var found = false
      while l <= lines.high:
        let e = lines[l].find("-->", c)
        if e >= 0:
          c = e + 3
          found = true
          break
        inc l
        c = 0
      if not found: break
      continue
    if c + 1 >= s.len or not (s[c + 1] in {'a'..'z', 'A'..'Z', '/', '!', '?'}):
      inc c
      continue
    var t = HtmlTagAt(line: l, col: c)
    adv()
    if ch() == '/':
      t.closing = true
      adv()
    if ch() in {'!', '?'}:
      # <!DOCTYPE html>, <?xml …?>: skipped
      while not atEnd() and ch() != '>': adv()
      if not atEnd(): adv()
      continue
    var name = ""
    while not atEnd() and c < lines[l].len and isNameChar(ch()):
      name.add ch()
      adv()
    t.name = name.toLowerAscii
    # attributes, to the `>`
    var done = false
    while not atEnd():
      let x = ch()
      if x == '>':
        adv()
        done = true
        break
      if x == '/' and c + 1 < lines[l].len and lines[l][c + 1] == '>':
        t.selfClosing = true
        adv()
        adv()
        done = true
        break
      if x == '<': break                            # (a tag never closed: the next one starts)
      if isNameChar(x) or x in {'@', '#', '['}:
        let al = l
        let ac = c
        var an = ""
        while not atEnd() and c < lines[l].len and (isNameChar(ch()) or ch() in {'@', '#', '[', ']', '(', ')'}):
          an.add ch()
          adv()
        while not atEnd() and ch() in {' ', '\t', '\n'}: adv()
        var av = ""
        if not atEnd() and ch() == '=':
          adv()
          while not atEnd() and ch() in {' ', '\t', '\n'}: adv()
          if not atEnd() and ch() in {'"', '\''}:
            let q = ch()
            adv()
            while not atEnd() and ch() != q:
              av.add (if c < lines[l].len: lines[l][c] else: '\n')
              adv()
            if not atEnd(): adv()
          else:
            while not atEnd() and c < lines[l].len and ch() notin {' ', '\t', '>'}:
              av.add ch()
              adv()
        t.attrs.add (an.toLowerAscii, av, al, ac)
        continue
      adv()
    t.eline = l
    t.ecol = c
    if t.name.len > 0: result.add t
    if done and not t.closing and t.name in ["script", "style"]: raw = t.name
    if not done: break

proc openElements*(tags: seq[HtmlTagAt]): seq[(string, int)] =
  ## the elements open after these tags (name, index of its tag), outermost first — as a browser closes them
  for i, t in tags:
    if t.closing:
      var k = result.high
      while k >= 0 and result[k][0] != t.name: dec k
      if k >= 0: result.setLen(k)
    elif not t.selfClosing and not isVoid(t.name):
      # (a <p> or <li> is closed by the next one; a <td> by the next cell)
      if result.len > 0 and result[^1][0] == t.name and t.name in ["p", "li", "dt", "dd", "option", "tr", "td", "th"]:
        result.setLen(result.len - 1)
      result.add (t.name, i)

proc htmlContext*(lines: openArray[string], line, col: int): HtmlCtx =
  ## what is being written at (line, col)
  if line < 0 or line > lines.high: return
  let s = lines[line]
  let c = min(col, s.len)
  # inside a tag? the last `<` before the cursor on this line or the few above, with no `>` after it
  var l = line
  var k = c - 1
  var lt = (-1, -1)
  var steps = 0
  block search:
    while l >= 0 and steps < 40:
      let t = lines[l]
      var i = min(k, t.high)
      while i >= 0:
        if t[i] == '>': break search
        if t[i] == '<':
          lt = (l, i)
          break search
        dec i
      dec l
      inc steps
      if l >= 0: k = lines[l].high
  var a = c
  while a > 0 and isNameChar(s[a - 1]) and s[a - 1] notin {':', '.'}: dec a
  result.start = a
  result.word = s[a ..< c]
  let tags = htmlTags(lines, (line, c))
  for (n, _) in openElements(tags): result.open.add n
  if result.open.len > 0 and result.open[^1] in ["script", "style"]:
    return HtmlCtx(kind: hcNone)
  if lt[0] < 0:
    result.kind = hcText
    return
  # the text of the tag so far
  var t = ""
  for x in lt[0] .. line:
    let ln = lines[x]
    let a0 = if x == lt[0]: lt[1] else: 0
    let e0 = if x == line: c else: ln.len
    if e0 > a0: t.add ln[a0 ..< e0]
    if x < line: t.add ' '
  if t.startsWith("<!--") or t.startsWith("<!") or t.startsWith("<?"): return HtmlCtx(kind: hcNone)
  if t.startsWith("</"):
    result.kind = hcCloseTag
    result.start = c - (t.len - 2)
    result.word = t[2 .. ^1]
    if not result.word.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-'}): result.kind = hcNone
    return
  var i = 1
  while i < t.len and isNameChar(t[i]): inc i
  result.tag = t[1 ..< i].toLowerAscii
  if i == t.len:
    result.kind = hcTagName
    return
  # an attribute's value: an open quote after name=
  var q = '\0'
  var lastName = ""
  var j = i
  var nameStart = -1
  while j < t.len:
    let x = t[j]
    if q != '\0':
      if x == q: q = '\0'
    elif x in {'"', '\''}: q = x
    elif isNameChar(x) or x in {'@', '#', '[', ']'}:
      if nameStart < 0 or (j > 0 and t[j - 1] in {' ', '\t'}):
        nameStart = j
      var e = j
      while e < t.len and (isNameChar(t[e]) or t[e] in {'@', '#', '[', ']'}): inc e
      lastName = t[nameStart ..< e].toLowerAscii
      j = e
      continue
    elif x in {' ', '\t'}: nameStart = -1
    inc j
  if q != '\0':
    result.kind = hcAttrValue
    result.quoted = true
    let eq = t.rfind('=')
    var n = eq - 1
    while n >= 0 and t[n] == ' ': dec n
    var b0 = n
    while b0 >= 0 and (isNameChar(t[b0]) or t[b0] in {'@', '#', '[', ']'}): dec b0
    result.attr = t[b0 + 1 .. n].toLowerAscii
    # the value's word: back to a space or the quote
    var w0 = c
    while w0 > 0 and s[w0 - 1] notin {' ', '"', '\''}: dec w0
    result.start = w0
    result.word = s[w0 ..< c]
    return
  if t.endsWith("=") or (t.len > 0 and t[^1] in {' ', '\t'} and t.strip.endsWith("=")):
    result.kind = hcAttrValue
    result.attr = lastName
    return
  result.kind = hcAttrName

proc tagAttrs(tag: string): seq[string] =
  ## the attributes particular to the element, from HtmlTagAttrs
  for (t, attrs) in HtmlTagAttrs:
    if t == tag: return attrs.splitWhitespace

proc attrValues(tag, attr: string): seq[string] =
  ## the values known for an attribute of an element — those listed for that element first, else for the attribute on
  ## any element (but not `type` outside input)
  for (k, vals) in HtmlAttrValues:
    if k == tag & "." & attr: return vals.splitWhitespace
  if attr == "type" and tag != "input": return
  for (k, vals) in HtmlAttrValues:
    if k == attr: return vals.splitWhitespace

proc attrDesc(tag, attr: string): string =
  ## what the attribute is, for hover and checks: a global attribute's description, the sort of aria-, data- and on…
  ## attributes, or that it belongs to the element; empty when it is none of them
  for (n, d) in HtmlGlobalAttrs:
    if n == attr: return d
  if attr.startsWith("aria-"): return "accessibility: what assistive technology is told about the element"
  if attr.startsWith("data-"): return "your own data, read with element.dataset"
  if attr.startsWith("on"): return "an event handler (JavaScript run on " & attr[2 .. ^1] & ")"
  if attr in tagAttrs(tag): return "an attribute of <" & tag & ">"

proc htmlComplete*(lines: openArray[string], line, col: int, classes: seq[string] = @[],
                   ids: seq[string] = @[]): (HtmlCtx, seq[WebItem]) =
  ## what fits at (line, col): with the class names the page's CSS defines and the ids it has
  let cx = htmlContext(lines, line, col)
  result[0] = cx
  var items: seq[WebItem]
  case cx.kind
  of hcNone, hcText: discard
  of hcTagName:
    for t in HtmlTags:
      items.add WebItem(label: t[0], insert: t[0], doc: t[1], detail: (if t[2]: "element (no end tag)" else: "element"),
                        kind: KStruct, rank: 1)
  of hcCloseTag:
    for k in countdown(cx.open.high, 0):
      items.add WebItem(label: cx.open[k], insert: cx.open[k] & ">", detail: "open element", kind: KStruct,
                        rank: (if k == cx.open.high: 0 else: 2))
      if cx.open[k] notin OptionalEnd: break
  of hcAttrName:
    var seen: HashSet[string]
    proc add(items: var seq[WebItem], n, d: string, rank: int) =
      ## adds the attribute n as a completion unless already listed; a yes/no attribute is inserted bare, others with
      ## ="" and the cursor between the quotes. Rank 0 (the element's own) shows the tag's name as its detail.
      if n in seen: return
      seen.incl n
      let b = n in BoolAttrs
      items.add WebItem(label: n, insert: (if b: n else: n & "=\"\""), snippet: (if b: "" else: n & "=\"$1\"$0"),
                        doc: d, detail: (if rank == 0: "<" & cx.tag & ">" else: "attribute"), kind: KField, rank: rank)
    for a in tagAttrs(cx.tag): items.add(a, attrDesc(cx.tag, a), 0)
    for (n, d) in HtmlGlobalAttrs:
      if '*' notin n: items.add(n, d, 1)
    for n in HtmlEventAttrs: items.add(n, "event handler", 2)
  of hcAttrValue:
    if cx.attr == "class":
      for c in classes: items.add WebItem(label: c, insert: c, detail: "class in the page's CSS", kind: KClass)
    elif cx.attr in ["for", "aria-labelledby", "aria-describedby", "aria-controls", "list", "form", "popovertarget",
                     "anchor", "headers"]:
      for c in ids: items.add WebItem(label: c, insert: c, detail: "id in the page", kind: KField)
    elif cx.attr == "href" and cx.word.startsWith("#"):
      for c in ids: items.add WebItem(label: "#" & c, insert: "#" & c, detail: "id in the page", kind: KField)
    else:
      for v in attrValues(cx.tag, cx.attr):
        items.add WebItem(label: v, insert: (if cx.quoted: v else: "\"" & v & "\""), detail: cx.attr, kind: KValue)
  result[1] = items

proc htmlHover*(lines: openArray[string], line, col: int): string =
  ## what the element or attribute at (line, col) is
  if line < 0 or line > lines.high: return
  let s = lines[line]
  var a = min(col, s.len)
  var e = a
  while a > 0 and isNameChar(s[a - 1]): dec a
  while e < s.len and isNameChar(s[e]): inc e
  if a >= e: return
  let w = s[a ..< e].toLowerAscii
  let cx = htmlContext(lines, line, a)
  case cx.kind
  of hcTagName, hcCloseTag:
    let i = htmlTag(w)
    if i >= 0:
      return "**<" & w & ">** — HTML element" & (if HtmlTags[i][2]: " (no end tag)" else: "") & "\n\n" & HtmlTags[i][1] &
             "\n\nhttps://developer.mozilla.org/docs/Web/HTML/Element/" & w
  of hcAttrName:
    let d = attrDesc(cx.tag, w)
    if d.len > 0:
      var vals = attrValues(cx.tag, w)
      return "**" & w & "** — attribute" & (if cx.tag.len > 0: " of <" & cx.tag & ">" else: "") & "\n\n" & d &
             (if vals.len > 0: "\n\nValues: " & vals.join(", ") else: "")
  else: discard

proc htmlWholePage*(lines: openArray[string]): bool =
  ## a whole page (a doctype, <html> or <body>), not a piece of one that a tool or a template puts in a page
  for l in lines:
    let t = l.toLowerAscii
    if "<!doctype" in t or "<html" in t or "<body" in t: return true
  false

proc htmlScriptMakesIds*(lines: openArray[string]): bool =
  ## does a script of the page make elements, or give them ids (.id =, setAttribute("id", …), innerHTML …)?
  var inScript = false
  for l in lines:
    let t = l.toLowerAscii
    var k = 0
    while k < t.len:
      if not inScript:
        let a = t.find("<script", k)
        if a < 0: break
        let e = t.find('>', a)
        if e < 0: break
        let head = t[a .. e]
        # (data in a script tag is no code: JSON, a template)
        inScript = not ("application/ld+json" in head or "application/json" in head or "text/template" in head or
                        "importmap" in head)
        k = e + 1
      else:
        let c = t.find("</script", k)
        let part = if c < 0: t[k .. ^1] else: t[k ..< c]
        for pat in [".id =", ".id=", "setattribute(\"id\"", "setattribute('id'", "innerhtml", "outerhtml",
                    "insertadjacenthtml", "document.write", "createelement", ".dataset"]:
          if pat in part: return true
        if c < 0: break
        inScript = false
        k = c + 8
  false

proc htmlChecks*(lines: openArray[string], fragment = false): seq[WebDiag] =
  ## a closing tag that closes the wrong element or nothing, an element never closed, an id used twice, an
  ## element HTML does not have (fragment: HTML cut into the pieces of a template or of Nim strings — only the
  ## ids and the elements)
  let tags = htmlTags(lines)
  var open: seq[(string, int)]
  var ids: Table[string, (int, int)]
  var inForeign = 0                                   # inside <svg> or <math>: their own elements
  for i, t in tags:
    if not t.closing:
      for (n, v, al, ac) in t.attrs:
        if n == "id" and v.len > 0 and '{' notin v and '<' notin v and '$' notin v:
          if v in ids:
            let (l0, _) = ids[v]
            result.add WebDiag(line: al, col: ac, eline: al, ecol: ac + 2, sev: 2, rule: "html-id",
                               msg: "the id '" & v & "' is used before (line " & $(l0 + 1) & ") — ids are unique")
          else: ids[v] = (al, ac)
      if t.name in ["svg", "math"] and not t.selfClosing: inc inForeign
      if inForeign == 0 and htmlTag(t.name) < 0 and '-' notin t.name and ':' notin t.name and '.' notin t.name and
         t.name.allCharsInSet({'a'..'z', '0'..'9'}):
        let near = block:
          var ns: seq[string]
          for x in HtmlTags: ns.add x[0]
          closest(t.name, ns)
        result.add WebDiag(line: t.line, col: t.col + 1, eline: t.line, ecol: t.col + 1 + t.name.len, sev: 2,
                           rule: "html-element", msg: "HTML has no <" & t.name & "> element" &
                           (if near.len > 0: " — did you mean <" & near & ">?" else: ""))
      if t.name == "img" and not fragment:
        var alt = false
        for (n, _, _, _) in t.attrs:
          if n == "alt": alt = true
        if not alt:
          result.add WebDiag(line: t.line, col: t.col + 1, eline: t.line, ecol: t.col + 4, sev: 4, rule: "html-alt",
                             msg: "<img> without alt text (screen readers say nothing, or the file name)")
    else:
      if t.name in ["svg", "math"] and inForeign > 0: dec inForeign
    if fragment: continue
    if t.closing:
      if isVoid(t.name):
        result.add WebDiag(line: t.line, col: t.col, eline: t.eline, ecol: t.ecol, sev: 2, rule: "html-close",
                           msg: "<" & t.name & "> has no end tag — this </" & t.name & "> is ignored")
        continue
      var k = open.high
      while k >= 0 and open[k][0] != t.name: dec k
      if k < 0:
        result.add WebDiag(line: t.line, col: t.col, eline: t.eline, ecol: t.ecol, sev: 1, rule: "html-close",
                           msg: "</" & t.name & "> closes nothing — no <" & t.name & "> is open here")
        continue
      # what it closes on the way (an element whose end tag may be left out is fine)
      for m in countdown(open.high, k + 1):
        let (n, ti) = open[m]
        if n in OptionalEnd: continue
        let ot = tags[ti]
        result.add WebDiag(line: ot.line, col: ot.col, eline: ot.line, ecol: ot.col + n.len + 1, sev: 1,
                           rule: "html-close", msg: "<" & n & "> is not closed before </" & t.name & "> (line " &
                           $(t.line + 1) & ")")
      open.setLen(k)
    elif not t.selfClosing and not isVoid(t.name):
      if open.len > 0 and open[^1][0] == t.name and t.name in ["p", "li", "dt", "dd", "option", "tr", "td", "th"]:
        open.setLen(open.len - 1)
      open.add (t.name, i)
  if not fragment:
    for (n, ti) in open:
      if n in OptionalEnd: continue
      let ot = tags[ti]
      result.add WebDiag(line: ot.line, col: ot.col, eline: ot.line, ecol: ot.col + n.len + 1, sev: 2,
                         rule: "html-close", msg: "<" & n & "> is never closed")
    # href="#x" with no element of that id (or name) in the page; an attribute a letter or two from one the
    # element takes
    var names: HashSet[string]
    for t in tags:
      for (n, v, _, _) in t.attrs:
        if n == "name" and v.len > 0: names.incl v
    var idList: seq[string]
    for k in ids.keys: idList.add k
    # (not where the page's ids are not all in its text: a piece of a page a tool puts together — no <html>,
    # <body> or doctype —, or a page whose own script makes elements and ids)
    let anchorsKnown = htmlWholePage(lines) and not htmlScriptMakesIds(lines)
    inForeign = 0
    for t in tags:
      if t.closing:
        if t.name in ["svg", "math"] and inForeign > 0: dec inForeign
        continue
      if t.name in ["svg", "math"] and not t.selfClosing: inc inForeign
      for (n, v, al, ac) in t.attrs:
        if anchorsKnown and n == "href" and v.len > 1 and v[0] == '#' and v != "#top" and
           v[1 .. ^1].allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', ':', '.'}) and
           v[1 .. ^1] notin ids and v[1 .. ^1] notin names:
          let vc = max(ac, lines[al].find(v, ac))
          let near = closest(v[1 .. ^1], idList)
          result.add WebDiag(line: al, col: vc, eline: al, ecol: vc + v.len, sev: 2, rule: "html-anchor",
                             msg: "no element has the id '" & v[1 .. ^1] & "'" &
                                  (if near.len > 0: " — '#" & near & "'?" else: ""))
        if inForeign == 0 and htmlTag(t.name) >= 0 and n.len > 2 and n.allCharsInSet({'a'..'z', '-'}) and
           attrDesc(t.name, n).len == 0 and not n.startsWith("on") and not n.startsWith("aria-") and
           not n.startsWith("data-") and not n.startsWith("x-") and not n.startsWith("v-") and
           not n.startsWith("hx-") and not n.startsWith("ng-"):
          var known = tagAttrs(t.name)
          for (g, _) in HtmlGlobalAttrs:
            if '*' notin g: known.add g
          let near = closest(n, known, limit = 1)
          if near.len > 0 and near != n:
            result.add WebDiag(line: al, col: ac, eline: al, ecol: ac + n.len, sev: 2, rule: "html-attribute",
                               msg: "<" & t.name & "> has no attribute '" & n & "' — '" & near & "'?")
  sortDiags(result)

proc htmlLocalRefs*(lines: openArray[string]): seq[(int, int, int, string)] =
  ## the page's links to files beside it: href and src values that are relative paths — (line, col, end col, the
  ## path without its ?query and #part)
  for t in htmlTags(lines):
    if t.closing: continue
    for (n, v, al, ac) in t.attrs:
      if n notin ["href", "src"] or v.len == 0: continue
      if v[0] in {'#', '/', '{', '$', '<', '?'} or "://" in v or ':' in v.split('/')[0] or "{{" in v or
         "${" in v or v.startsWith("//"):
        continue
      var path = v
      for c in ['?', '#']:
        let k = path.find(c)
        if k >= 0: path = path[0 ..< k]
      if path.len == 0 or path.strip != path: continue
      let vc = max(ac, lines[al].find(v, ac))
      result.add (al, vc, vc + v.len, path)

proc htmlClassesAndIds*(lines: openArray[string]): (seq[string], seq[string]) =
  ## the class names and ids a document's elements have
  var cs, ids: HashSet[string]
  for t in htmlTags(lines):
    for (n, v, _, _) in t.attrs:
      if n == "class":
        for c in v.splitWhitespace:
          if c.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}) and c notin cs:
            cs.incl c
            result[0].add c
      elif n == "id" and v.len > 0 and v.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', ':', '.'}) and
           v notin ids:
        ids.incl v
        result[1].add v

proc cssClassesAndIds*(lines: openArray[string]): (seq[string], seq[string]) =
  ## the class names and ids a stylesheet's selectors name (not a value's #fff or .5em)
  var cs, ids: HashSet[string]
  var inComment = false
  var depth = 0
  var inValue = false                 # after `prop:` in a block, to its `;`
  for s in lines:
    var i = 0
    while i < s.len:
      let c = s[i]
      if inComment:
        if c == '*' and i + 1 < s.len and s[i + 1] == '/':
          inComment = false
          inc i
      elif c == '/' and i + 1 < s.len and s[i + 1] == '*': inComment = true
      elif c == '{':
        inc depth
        inValue = false
      elif c == '}':
        depth = max(0, depth - 1)
        inValue = false
      elif c == ';': inValue = false
      elif c == ':' and depth > 0 and i + 1 < s.len and s[i + 1] in {' ', '\t'}: inValue = true
      elif c in {'.', '#'} and not inValue and i + 1 < s.len and s[i + 1] in {'a'..'z', 'A'..'Z', '_', '-'} and
           (i == 0 or not isCssIdent(s[i - 1])):
        var e = i + 1
        while e < s.len and isCssIdent(s[e]): inc e
        let n = s[i + 1 ..< e]
        if c == '.' and n notin cs:
          cs.incl n
          result[0].add n
        elif c == '#' and n notin ids:
          ids.incl n
          result[1].add n
        i = e
        continue
      inc i
