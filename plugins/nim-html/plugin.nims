## nim-html — web pages written in Nim: Karax's DSL completed and explained, Emmet and HTML turned into it, snippets
##
##   In a buildHtml block        completion of the tags — Karax's names: tdiv for div, italic for i, bold for b,
##                               underlined for u, strikethrough for s; and text, verbatim — and, in a tag's
##                               brackets, of its attributes as named arguments (class = "…", `type` = "…",
##                               onclick = …); hover says what a tag or an attribute is
##   Nim HTML: Emmet to Karax    the Emmet abbreviation on the cursor's line — div.card>h2+p*2, ul>li.item$*3,
##                               a[href=#]{Home}, #main, (header>h1)+footer, p>{Hi}^p — as Karax's DSL, at the
##                               line's indentation. In a buildHtml block, Alt+Enter on such a line offers it too
##   Nim HTML: HTML to Karax     the selected HTML as Karax's DSL: in a .nim file in its place (in a buildHtml block
##                               as it is, elsewhere as a buildHtml(…) with the import it needs), in another file in a
##                               tab; nothing selected: the whole file, in a tab (page.html → page.nim) with the
##                               imports and a proc that builds it
##   Nim HTML: htmlgen to Karax  the std/htmlgen call selected, or the one at the cursor — html(head(title("…")),
##                               body(…)) — as a buildHtml(…) block in its place
##   Snippets (Nim files)        buildhtml · karax (an app: createDom and setRenderer) · htmlgen (a page)
##
## What does not carry over: an HTML event attribute (onclick="…") is JavaScript, while Karax's is a Nim proc — it
## becomes a comment above its tag; a tag Karax does not have (a custom element) becomes a tdiv, with a comment.
import nedplugin
import std/[strutils, tables]

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

const NimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
  "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
  "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr",
  "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when",
  "while", "xor", "yield"]

# Karax's tags: (its name, the HTML element, what it is) — completion and hover
const Tags = [
  ("html", "html", "the whole page: its head and body"),
  ("head", "head", "the page's head: its title, meta, links, styles and scripts"),
  ("title", "title", "the page's title, on the browser's tab"),
  ("base", "base", "the address the page's relative links start from"),
  ("link", "link", "a file the page uses: rel = \"stylesheet\", href = \"style.css\""),
  ("meta", "meta", "data about the page: charset = \"utf-8\", name = \"viewport\" …"),
  ("style", "style", "CSS for the page"),
  ("script", "script", "a script: src = \"app.js\", or its code in it"),
  ("noscript", "noscript", "shown when scripts do not run"),
  ("body", "body", "the page's content"),
  ("section", "section", "a part of the page, usually with a heading"),
  ("nav", "nav", "links to move around the site"),
  ("article", "article", "a piece that stands on its own: a post, a card"),
  ("aside", "aside", "content beside the main one: a sidebar"),
  ("h1", "h1", "a heading, the biggest (one a page)"),
  ("h2", "h2", "a heading of the second level"),
  ("h3", "h3", "a heading of the third level"),
  ("h4", "h4", "a heading of the fourth level"),
  ("h5", "h5", "a heading of the fifth level"),
  ("h6", "h6", "a heading of the sixth level"),
  ("hgroup", "hgroup", "a heading and its subtitle"),
  ("header", "header", "the top of the page or of a section"),
  ("footer", "footer", "the bottom of the page or of a section"),
  ("address", "address", "contact details"),
  ("main", "main", "the page's main content (one a page)"),
  ("p", "p", "a paragraph"),
  ("hr", "hr", "a line between two parts (no children)"),
  ("pre", "pre", "text shown as it is written: its spaces and line ends kept"),
  ("blockquote", "blockquote", "a quotation set apart: cite = its source"),
  ("ol", "ol", "a numbered list of li"),
  ("ul", "ul", "a list of li, with bullets"),
  ("li", "li", "an item of a list (ul, ol, menu)"),
  ("dl", "dl", "a list of terms (dt) and what they mean (dd)"),
  ("dt", "dt", "a term of a dl"),
  ("dd", "dd", "what the term before it means, in a dl"),
  ("figure", "figure", "a picture, a diagram or code, with its caption"),
  ("figcaption", "figcaption", "the caption of a figure"),
  ("tdiv", "div", "a block that groups others — Karax writes div as tdiv, as div is a Nim keyword"),
  ("a", "a", "a link: href = \"…\" (target = \"_blank\": a new tab)"),
  ("em", "em", "text said with stress (in italics)"),
  ("strong", "strong", "important text (in bold)"),
  ("small", "small", "small print: notes, legal text"),
  ("strikethrough", "s", "text that is no longer right, struck through — Karax writes s as strikethrough"),
  ("cite", "cite", "the title of a work"),
  ("dfn", "dfn", "the term a sentence defines"),
  ("abbr", "abbr", "an abbreviation: title = what it stands for"),
  ("data", "data", "a value with a machine-readable form: value = …"),
  ("time", "time", "a date or a time: datetime = \"2026-10-26\""),
  ("code", "code", "a piece of code, in the text"),
  ("`var`", "var", "a variable, in maths or code — Karax writes it `var`, as var is a Nim keyword"),
  ("samp", "samp", "what a program printed"),
  ("kbd", "kbd", "keys to press: Ctrl+S"),
  ("sub", "sub", "text below the line: H₂O"),
  ("sup", "sup", "text above the line: x²"),
  ("italic", "i", "text in italics — Karax writes i as italic"),
  ("bold", "b", "bold text — Karax writes b as bold"),
  ("underlined", "u", "underlined text — Karax writes u as underlined"),
  ("mark", "mark", "highlighted text"),
  ("ruby", "ruby", "text with its pronunciation above (rt)"),
  ("rt", "rt", "the pronunciation in a ruby"),
  ("rp", "rp", "brackets for a browser that shows no ruby"),
  ("bdi", "bdi", "text whose direction (left to right, right to left) is its own"),
  ("bdo", "bdo", "text in the direction dir = \"rtl\" or \"ltr\" says"),
  ("span", "span", "a piece of text to style (inline: no new line)"),
  ("br", "br", "a line break (no children)"),
  ("wbr", "wbr", "where a long word may break"),
  ("ins", "ins", "text added to the document"),
  ("del", "del", "text taken out of the document"),
  ("img", "img", "a picture: src = \"…\", alt = \"what it shows\" (no children)"),
  ("iframe", "iframe", "another page inside this one: src = \"…\""),
  ("embed", "embed", "content of another program: src, `type`"),
  ("`object`", "object", "an outside resource: data, `type` — Karax writes it `object`, a Nim keyword"),
  ("param", "param", "a parameter of an object"),
  ("video", "video", "a video: src, controls, autoplay, poster"),
  ("audio", "audio", "sound: src, controls"),
  ("source", "source", "one of the files of a video, audio or picture: src, `type`"),
  ("track", "track", "subtitles for a video: src, kind, srclang"),
  ("canvas", "canvas", "a surface to draw on with scripts: width, height"),
  ("map", "map", "an image map: its areas"),
  ("area", "area", "a clickable part of an image map"),
  ("svg", "svg", "an SVG drawing: viewBox, width, height"),
  ("g", "g", "a group of SVG shapes"),
  ("path", "path", "an SVG shape drawn by d = \"M 0 0 L 10 10\""),
  ("circle", "circle", "an SVG circle: cx, cy, r"),
  ("rect", "rect", "an SVG rectangle: x, y, width, height"),
  ("line", "line", "an SVG line: x1, y1, x2, y2"),
  ("polyline", "polyline", "SVG lines through points = \"…\""),
  ("polygon", "polygon", "an SVG shape through points = \"…\""),
  ("ellipse", "ellipse", "an SVG ellipse: cx, cy, rx, ry"),
  ("stext", "text", "text in an SVG drawing — Karax writes SVG's text as stext"),
  ("use", "use", "a copy of another SVG element: href = \"#id\""),
  ("defs", "defs", "SVG elements to use later"),
  ("table", "table", "a table: thead, tbody, tr"),
  ("caption", "caption", "the title of a table"),
  ("colgroup", "colgroup", "a group of a table's columns"),
  ("col", "col", "a column of a table, to style it"),
  ("tbody", "tbody", "the rows of a table's body"),
  ("thead", "thead", "a table's heading rows"),
  ("tfoot", "tfoot", "a table's rows at the bottom"),
  ("tr", "tr", "a row of a table"),
  ("td", "td", "a cell of a table"),
  ("th", "th", "a heading cell of a table"),
  ("form", "form", "a form: action, `method`, its inputs and a button"),
  ("fieldset", "fieldset", "a group of a form's fields, with a legend"),
  ("legend", "legend", "the title of a fieldset"),
  ("label", "label", "the name of a field: `for` = the field's id"),
  ("input", "input", "a field: `type` = \"text\", \"checkbox\", \"email\" …, value, placeholder (no children)"),
  ("button", "button", "a button: onclick = a proc, `type` = \"submit\""),
  ("select", "select", "a list to choose from: its options"),
  ("datalist", "datalist", "suggestions for an input (list = its id)"),
  ("optgroup", "optgroup", "a group of a select's options: label"),
  ("option", "option", "one choice of a select: value, selected"),
  ("textarea", "textarea", "a field of several lines: rows, cols"),
  ("output", "output", "the result of a calculation"),
  ("progress", "progress", "how far something has come: value, max"),
  ("meter", "meter", "a measure in a range: value, min, max"),
  ("details", "details", "a part you open and close: a summary, then what it hides"),
  ("summary", "summary", "what a details shows when it is closed"),
  ("menu", "menu", "a list of commands (li)"),
  ("dialog", "dialog", "a dialog box: open"),
  ("slot", "slot", "where a web component puts its children"),
  ("`template`", "template", "HTML kept for scripts, not shown — Karax writes it `template`, a Nim keyword")]

# (Karax's other tags — SVG's and MathML's: known, not offered)
const OtherTags = ["quote", "dbo", "keygen", "command", "animate", "animateMotion", "animateTransform", "clipPath",
  "desc", "discard", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix",
  "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB",
  "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset",
  "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "filter", "foreignObject", "image",
  "linearGradient", "marker", "mask", "metadata", "mpath", "pattern", "radialGradient", "set", "stop", "switch",
  "symbol", "textPath", "tspan", "unknown", "view", "maction", "math", "menclose", "merror", "mfenced", "mfrac",
  "mglyph", "mi", "mlabeledtr", "mmultiscripts", "mn", "mo", "mover", "mpadded", "mphantom", "mroot", "mrow", "ms",
  "mspace", "msqrt", "mstyle", "msub", "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder", "munderover",
  "semantics"]

# the words of the DSL that are not tags
const Words = [
  ("text", "text \"$1\"$0", "a text node: `text \"Hello\"`, `text $count` — the text is escaped"),
  ("verbatim", "verbatim \"$1\"$0", "HTML put in as it is, not escaped: `verbatim \"<b>hi</b>\"`")]

# attributes, as named arguments of a tag: (the name as Karax takes it, what goes in, what it is)
const Attrs = [
  ("class", "class = \"$1\"$0", "the element's classes, for CSS: class = \"card big\""),
  ("id", "id = \"$1\"$0", "the element's id: one a page (href = \"#id\" links to it)"),
  ("style", "style = \"$1\".toCss$0", "its CSS: style = \"color: red\".toCss (import karax/vstyles), or " &
           "style = style(StyleAttr.color, \"red\")"),
  ("href", "href = \"$1\"$0", "a (and link, area, base): the address it goes to"),
  ("src", "src = \"$1\"$0", "img, script, iframe, video, audio, source: the file's address"),
  ("alt", "alt = \"$1\"$0", "img: what the picture shows, for who cannot see it"),
  ("title", "title = \"$1\"$0", "a tip shown when the mouse rests on the element"),
  ("`type`", "`type` = \"$1\"$0", "input (text, checkbox, email, number, password …), button (submit, button), " &
            "script, source — `type` in backticks: type is a Nim keyword"),
  ("value", "value = $1$0", "input, option, button: its value (Karax keeps the field's value in step with it)"),
  ("name", "name = \"$1\"$0", "a form field's name, sent with the form"),
  ("placeholder", "placeholder = \"$1\"$0", "input, textarea: a hint shown while it is empty"),
  ("`for`", "`for` = \"$1\"$0", "label: the id of its field — `for` in backticks: for is a Nim keyword"),
  ("action", "action = \"$1\"$0", "form: where it is sent"),
  ("`method`", "`method` = \"${1:post}\"$0", "form: get or post — `method` in backticks: a Nim keyword"),
  ("target", "target = \"${1:_blank}\"$0", "a, form: where the page opens (_blank: a new tab)"),
  ("rel", "rel = \"$1\"$0", "a, link: what the linked file is to the page (stylesheet, icon, noopener …)"),
  ("disabled", "disabled = \"\"$0", "button, input, select: it cannot be used"),
  ("checked", "checked = \"\"$0", "input (checkbox, radio): ticked — or checked = toChecked(aBool)"),
  ("selected", "selected = \"\"$0", "option: the one chosen"),
  ("readonly", "readonly = \"\"$0", "input, textarea: it can be read, not changed"),
  ("required", "required = \"\"$0", "input, select, textarea: the form is not sent while it is empty"),
  ("autofocus", "autofocus = \"\"$0", "input, button: has the focus when the page opens"),
  ("multiple", "multiple = \"\"$0", "select, input (file, email): more than one value"),
  ("hidden", "hidden = \"\"$0", "not shown"),
  ("width", "width = \"$1\"$0", "img, canvas, video, iframe: its width"),
  ("height", "height = \"$1\"$0", "img, canvas, video, iframe: its height"),
  ("min", "min = \"$1\"$0", "input (number, range, date), meter: the smallest value"),
  ("max", "max = \"$1\"$0", "input (number, range, date), meter, progress: the largest value"),
  ("step", "step = \"$1\"$0", "input (number, range): how much a value changes at a time"),
  ("maxlength", "maxlength = \"$1\"$0", "input, textarea: how many characters it takes at most"),
  ("pattern", "pattern = \"$1\"$0", "input: a regular expression the value must match"),
  ("autocomplete", "autocomplete = \"${1:off}\"$0", "input, form: may the browser fill it in"),
  ("tabindex", "tabindex = \"${1:0}\"$0", "where it comes when Tab moves the focus"),
  ("role", "role = \"$1\"$0", "what the element is to a screen reader: button, dialog, navigation …"),
  ("aria-label", "aria-label = \"$1\"$0", "its name for a screen reader, when it shows none"),
  ("lang", "lang = \"${1:en}\"$0", "the language of its text"),
  ("colspan", "colspan = \"${1:2}\"$0", "td, th: how many columns the cell spans"),
  ("rowspan", "rowspan = \"${1:2}\"$0", "td, th: how many rows the cell spans"),
  ("rows", "rows = \"$1\"$0", "textarea: how many lines it shows"),
  ("cols", "cols = \"$1\"$0", "textarea: how many characters a line"),
  ("download", "download = \"$1\"$0", "a: the file is saved, not opened (under this name)"),
  ("content", "content = \"$1\"$0", "meta: the value of name = …"),
  ("charset", "charset = \"${1:utf-8}\"$0", "meta: the page's encoding"),
  ("contenteditable", "contenteditable = \"${1:true}\"$0", "the text can be edited in the page"),
  ("draggable", "draggable = \"${1:true}\"$0", "the element can be dragged"),
  ("index", "index = $1$0", "Karax: the node's index, for event handlers that need it"),
  ("setFocus", "setFocus = $1$0", "Karax: the element gets the focus when this is true"),
  ("events", "events = $1$0", "Karax: event handlers to add, from a seq of (EventKind, handler)"),
  ("onclick", "onclick = ${1:handler}$0", "Karax: a proc called on a click — proc () = …, or " &
             "proc (ev: Event; n: VNode) = …"),
  ("ondblclick", "ondblclick = ${1:handler}$0", "Karax: a proc called on a double click"),
  ("oninput", "oninput = ${1:handler}$0", "Karax: a proc called as the field's text changes (n.value: its text)"),
  ("onchange", "onchange = ${1:handler}$0", "Karax: a proc called when a field's value is changed"),
  ("onkeydown", "onkeydown = ${1:handler}$0", "Karax: a proc called when a key goes down"),
  ("onkeyup", "onkeyup = ${1:handler}$0", "Karax: a proc called when a key comes up"),
  ("onsubmit", "onsubmit = ${1:handler}$0", "Karax: a proc called when the form is sent"),
  ("onfocus", "onfocus = ${1:handler}$0", "Karax: a proc called when it gets the focus"),
  ("onblur", "onblur = ${1:handler}$0", "Karax: a proc called when it loses the focus"),
  ("onmouseover", "onmouseover = ${1:handler}$0", "Karax: a proc called when the mouse comes over it"),
  ("onmouseout", "onmouseout = ${1:handler}$0", "Karax: a proc called when the mouse leaves it")]

const VoidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source",
                  "track", "wbr"]

# ── names ──

func isIdent(s: string): bool =
  ## a plain Nim name: a letter first, then letters, digits and single underscores
  if s.len == 0 or s[0] notin {'a'..'z', 'A'..'Z'}: return false
  for i, c in s:
    if c == '_':
      if i == s.high or s[i + 1] == '_': return false
    elif c notin {'a'..'z', 'A'..'Z', '0'..'9'}: return false
  true

func nimStr*(s: string): string =
  ## s as a Nim string literal
  result = "\""
  var i = 0
  while i < s.len:
    let c = s[i]
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    of '\0'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F', '\x7F': result.add "\\x" & toHex(ord(c), 2)
    of '\xC2':
      if i + 1 < s.len and s[i + 1] == '\xA0':           # (a no-break space: written so it can be seen)
        result.add "\\u00A0"
        inc i
      else: result.add c
    else: result.add c
    inc i
  result.add "\""

func karaxTag*(html: string): string =
  ## the name Karax gives an HTML element ("" when it has none)
  case html
  of "div": "tdiv"
  of "i": "italic"
  of "b": "bold"
  of "u": "underlined"
  of "s": "strikethrough"
  of "text": "stext"
  of "var", "object", "template", "set", "discard": "`" & html & "`"
  else:
    for (k, h, _) in Tags:
      if h == html: return k
    for t in OtherTags:
      if t == html or t.toLowerAscii == html: return t
    ""

func attrName*(k: string): string =
  ## an attribute as the name of a named argument: class, `type`, aria-label (Karax reads a-b), else "x:y"
  if k in NimKeywords: return "`" & k & "`"
  if isIdent(k): return k
  let parts = k.split('-')
  var ok = parts.len > 1
  for p in parts:
    if not isIdent(p) or p in NimKeywords: ok = false
  if ok: k else: nimStr(k)

func indentOf(l: string): int =
  ## how many spaces or tabs the line starts with
  while result < l.len and l[result] in {' ', '\t'}: inc result

# ── the tree all three conversions make ──

type
  HKind = enum hkElement, hkText, hkExpr, hkComment
  HNode = ref object
    kind: HKind
    tag: string                  # hkElement: the HTML element (lower case)
    attrs: seq[(string, string)] # its attributes: name, the value as Nim code
    notes: seq[string]           # comments that go above it
    text: string                 # hkText: the text · hkExpr: Nim code · hkComment: what it says
    raw: bool                    # hkText: as it is (pre, script, style): no spaces collapsed
    kids: seq[HNode]

# a new element node with that tag and nothing in it yet
func elem(tag: string): HNode = HNode(kind: hkElement, tag: tag)

proc tidy(kids: seq[HNode]): seq[HNode] =
  ## the children as Karax shows them: runs of spaces as one, a text of spaces between lines left out
  for k in kids:
    if k.kind != hkText or k.raw:
      result.add k
      continue
    var t = ""
    var sp = false
    for c in k.text:
      if c in {' ', '\t', '\n', '\r', '\f'}:
        if not sp: t.add ' '
        sp = true
      else:
        t.add c
        sp = false
    if t.strip.len == 0 and ('\n' in k.text or result.len == 0): continue
    result.add HNode(kind: hkText, text: t)
  if result.len > 0 and result[0].kind == hkText and not result[0].raw:
    result[0].text = result[0].text.strip(trailing = false)
  if result.len > 0 and result[^1].kind == hkText and not result[^1].raw:
    result[^1].text = result[^1].text.strip(leading = false)
  var keep: seq[HNode]
  for k in result:
    if k.kind == hkText and k.text.len == 0: continue
    keep.add k
  result = keep

func textCode(n: HNode): string =
  ## a text node's argument: a string (a multi-line one of pre, script, style as it is), or Nim code
  if n.kind == hkExpr: return n.text
  if n.raw and '\n' in n.text and "\"\"\"" notin n.text and not n.text.endsWith("\""):
    return "\"\"\"" & n.text & "\"\"\""
  nimStr(n.text)

proc headOf(n: HNode, notes: var seq[string]): string =
  ## an element's tag and its attributes as named arguments: a(href = "#")
  var tag = karaxTag(n.tag)
  if tag.len == 0:
    notes.add "<" & n.tag & ">: Karax has no tag of this name"
    tag = "tdiv"
  var args: seq[string]
  for (k, v) in n.attrs:
    if k.len > 2 and k.startsWith("on") and v.len > 0 and v[0] == '"':
      notes.add k & "=" & v & " — in Karax an event is a proc: " & k & " = proc () = …"
    elif k == "style" and v.len > 0 and v[0] == '"': args.add "style = " & v & ".toCss"
    else: args.add attrName(k) & " = " & v
  tag & (if args.len > 0: "(" & args.join(", ") & ")" else: "")

proc emit(n: HNode, ind, unit: string, res: var seq[string]) =
  ## adds the Karax lines of a node to res at the indentation ind: a text as `text …`, a comment as # lines, an element
  ## as its tag line with its children under it (indented by unit) — a lone short text child goes on the tag's own line
  ## after a colon
  case n.kind
  of hkText, hkExpr: res.add ind & "text " & textCode(n)
  of hkComment:
    for l in n.text.strip.splitLines:
      res.add ind & (if l.strip.len > 0: "# " & l.strip else: "#")
  of hkElement:
    var notes = n.notes
    let head = headOf(n, notes)
    for x in notes: res.add ind & "# " & x
    let kids = tidy(n.kids)
    if kids.len == 0:
      res.add ind & head & (if '(' in head: "" else: "()")
    elif kids.len == 1 and kids[0].kind in {hkText, hkExpr} and '\n' notin textCode(kids[0]):
      res.add ind & head & ": text " & textCode(kids[0])
    else:
      res.add ind & head & ":"
      for k in kids: emit(k, ind & unit, unit, res)

proc karaxLines*(nodes: seq[HNode], unit: string): seq[string] =
  ## the nodes as Karax's DSL, from column 0
  for n in tidy(nodes): emit(n, "", unit, result)

proc wrapped*(nodes: seq[HNode], unit: string): seq[string] =
  ## the nodes as a buildHtml(…) expression: buildHtml(the root): its children — buildHtml(tdiv) for several
  let ns = tidy(nodes)
  if ns.len == 1 and ns[0].kind == hkElement and tidy(ns[0].kids).len > 0:
    var notes: seq[string]
    let head = headOf(ns[0], notes)
    result.add "buildHtml(" & head & "):"
    for x in notes: result.add unit & "# " & x          # (inside: the first line may follow `let x = `)
    for k in tidy(ns[0].kids): emit(k, unit, unit, result)
  else:
    result.add "buildHtml(tdiv):"
    for n in ns: emit(n, unit, unit, result)

func usesStyle(nodes: seq[HNode]): bool =
  ## whether any element in the tree (children too) has a style attribute written as a string — which becomes style =
  ## "…".toCss and needs karax/vstyles
  for n in nodes:
    if n.kind == hkElement:
      for (k, v) in n.attrs:
        if k == "style" and v.len > 0 and v[0] == '"': return true
      if usesStyle(n.kids): return true

# ── HTML ──

const RawTags = ["script", "style", "textarea", "title"]
const ClosesP = ["address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption",
  "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav",
  "ol", "p", "pre", "section", "table", "ul"]
const Entities = {"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\xC2\xA0",
  "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "laquo": "«", "raquo": "»",
  "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "times": "×",
  "divide": "÷", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "plusmn": "±", "para": "¶",
  "sect": "§", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓", "hearts": "♥",
  "shy": "\xC2\xAD", "ensp": "\xE2\x80\x82", "emsp": "\xE2\x80\x83", "thinsp": "\xE2\x80\x89"}.toTable

func utf8(cp: int): string =
  ## the UTF-8 bytes of a code point
  if cp < 0x80: $chr(cp)
  elif cp < 0x800: $chr(0xC0 or (cp shr 6)) & $chr(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    $chr(0xE0 or (cp shr 12)) & $chr(0x80 or ((cp shr 6) and 0x3F)) & $chr(0x80 or (cp and 0x3F))
  else:
    $chr(0xF0 or (cp shr 18)) & $chr(0x80 or ((cp shr 12) and 0x3F)) & $chr(0x80 or ((cp shr 6) and 0x3F)) &
      $chr(0x80 or (cp and 0x3F))

func decode*(s: string): string =
  ## the text with its character references (&amp; &#169; &#x2014;) as the characters
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let e = s.find(';', i + 1)
      if e > i + 1 and e - i <= 12:
        let name = s[i + 1 ..< e]
        var got = ""
        if name[0] == '#':
          try:
            let cp = if name.len > 1 and name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1]) else: parseInt(name[1 .. ^1])
            if cp > 0 and cp <= 0x10FFFF: got = utf8(cp)
          except ValueError: discard
        elif name in Entities: got = Entities[name]
        if got.len > 0:
          result.add got
          i = e + 1
          continue
    result.add s[i]
    inc i

proc closeFor(stack: var seq[HNode], tag: string) =
  ## the elements a start tag ends: an li ends the li before it, a block ends an open p …
  proc upTo(stack: var seq[HNode], these, stops: openArray[string]) =
    for k in countdown(stack.high, 1):
      if stack[k].tag in these:
        stack.setLen(k)
        return
      if stack[k].tag in stops: return
  case tag
  of "li": upTo(stack, ["li"], ["ul", "ol", "menu"])
  of "dt", "dd": upTo(stack, ["dt", "dd"], ["dl"])
  of "tr": upTo(stack, ["tr"], ["table", "thead", "tbody", "tfoot"])
  of "td", "th": upTo(stack, ["td", "th"], ["tr", "table"])
  of "thead", "tbody", "tfoot": upTo(stack, ["thead", "tbody", "tfoot"], ["table"])
  of "option": upTo(stack, ["option"], ["select", "datalist", "optgroup"])
  of "optgroup": upTo(stack, ["optgroup", "option"], ["select"])
  else: discard
  if tag in ClosesP and stack.len > 1 and stack[^1].tag == "p": stack.setLen(stack.len - 1)

proc parseHtml*(s: string): seq[HNode] =
  ## the HTML as a tree (as a browser would mend it: end tags left out, void elements)
  let low = s.toLowerAscii
  let root = elem("#root")
  var stack = @[root]
  var i = 0
  var text = ""
  proc flush(text: var string, stack: seq[HNode]) =
    ## adds the text read so far to the open element (the top of the stack) as a text node, its character references
    ## decoded and kept as it is inside pre, and clears it
    if text.len > 0:
      stack[^1].kids.add HNode(kind: hkText, text: decode(text), raw: stack[^1].tag == "pre")
      text = ""
  while i < s.len:
    if s[i] == '<' and i + 1 < s.len:
      if s.continuesWith("<!--", i):
        flush(text, stack)
        let e = s.find("-->", i + 4)
        stack[^1].kids.add HNode(kind: hkComment, text: s[i + 4 ..< (if e < 0: s.len else: e)])
        i = if e < 0: s.len else: e + 3
        continue
      if s[i + 1] in {'!', '?'}:                       # <!DOCTYPE html>, <?xml …?>
        let e = s.find('>', i)
        i = if e < 0: s.len else: e + 1
        continue
      if s[i + 1] == '/':
        var j = i + 2
        while j < s.len and s[j] notin {'>', ' ', '\t', '\n', '\r'}: inc j
        let name = low[i + 2 ..< j]
        flush(text, stack)
        for k in countdown(stack.high, 1):
          if stack[k].tag == name:
            stack.setLen(k)
            break
        let e = s.find('>', j)
        i = if e < 0: s.len else: e + 1
        continue
      if s[i + 1] in {'a'..'z', 'A'..'Z'}:
        flush(text, stack)
        var j = i + 1
        while j < s.len and s[j] notin {'>', '/', ' ', '\t', '\n', '\r'}: inc j
        let el = elem(low[i + 1 ..< j])
        var selfClosed = false
        # its attributes
        while j < s.len:
          while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
          if j >= s.len: break
          if s[j] == '>':
            inc j
            break
          if s[j] == '/':
            selfClosed = true
            inc j
            continue
          var e = j
          while e < s.len and s[e] notin {' ', '\t', '\n', '\r', '=', '>', '/'}: inc e
          if e == j: e = j + 1
          let name = s[j ..< e]                         # (as written: SVG's viewBox)
          j = e
          while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
          var value = ""
          if j < s.len and s[j] == '=':
            inc j
            while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
            if j < s.len and s[j] in {'"', '\''}:
              let q = s.find(s[j], j + 1)
              let stop = if q < 0: s.len else: q
              value = s[j + 1 ..< stop]
              j = stop + 1
            else:
              var v = j
              while v < s.len and s[v] notin {' ', '\t', '\n', '\r', '>'}: inc v
              value = s[j ..< v]
              j = v
          el.attrs.add (name, nimStr(decode(value)))
        i = j
        closeFor(stack, el.tag)
        stack[^1].kids.add el
        if el.tag in VoidTags or selfClosed: continue
        if el.tag in RawTags:
          let e = low.find("</" & el.tag, i)
          let stop = if e < 0: s.len else: e
          let body = s[i ..< stop]
          if body.len > 0:
            if el.tag in ["script", "style"]: el.kids.add HNode(kind: hkText, text: body, raw: true)
            else: el.kids.add HNode(kind: hkText, text: decode(body), raw: el.tag == "textarea")
          let close = if e < 0: s.len else: s.find('>', e)
          i = if close < 0: s.len else: close + 1
          continue
        stack.add el
        continue
    text.add s[i]
    inc i
  flush(text, stack)
  root.kids

# ── Emmet ──

type ENode = ref object
  tag, id, text: string
  classes: seq[string]
  attrs: seq[(string, string)]
  hasText, group: bool
  count: int
  kids: seq[ENode]

func implied(parent: string): string =
  ## the tag of `.x` or `#x` alone, by where it is: li in a list, tr in a table, td in a row …
  case parent
  of "ul", "ol", "menu": "li"
  of "table", "tbody", "thead", "tfoot": "tr"
  of "tr": "td"
  of "select", "optgroup", "datalist": "option"
  of "span", "a", "em", "strong", "b", "i", "u", "s", "small", "code", "label", "button", "p", "h1", "h2", "h3", "h4",
     "h5", "h6": "span"
  else: "div"

const EmmetStop = {'.', '#', '[', '{', '*', '>', '+', '^', '(', ')'}

proc emmetElement(s: string, i: var int, parent: string): ENode =
  ## reads one Emmet element at i: a tag name (taken from the parent when there is only a class, id or attribute — li in
  ## a list, td in a row …), then any number of .class, #id, [attributes] and {text}; i is moved past it; raises
  ## ValueError for a name missing or a bracket not closed
  result = ENode(count: 1)
  var j = i
  while j < s.len and s[j] in {'a'..'z', 'A'..'Z', '0'..'9', '-', ':', '_'}: inc j
  result.tag = s[i ..< j]
  i = j
  while i < s.len:
    case s[i]
    of '.', '#':
      let c = s[i]
      inc i
      var e = i
      while e < s.len and s[e] notin EmmetStop and s[e] != ' ': inc e
      if e == i: raise newException(ValueError, "a name after " & c & " (column " & $(i + 1) & ")")
      if c == '.': result.classes.add s[i ..< e] else: result.id = s[i ..< e]
      i = e
    of '[':
      inc i
      while true:
        while i < s.len and s[i] == ' ': inc i
        if i >= s.len: raise newException(ValueError, "a [ not closed")
        if s[i] == ']':
          inc i
          break
        var e = i
        while e < s.len and s[e] notin {'=', ' ', ']'}: inc e
        let name = s[i ..< e]
        if name.len == 0: raise newException(ValueError, "an attribute's name (column " & $(i + 1) & ")")
        i = e
        var value = ""
        if i < s.len and s[i] == '=':
          inc i
          if i < s.len and s[i] in {'"', '\''}:
            let q = s.find(s[i], i + 1)
            if q < 0: raise newException(ValueError, "a quote not closed")
            value = s[i + 1 ..< q]
            i = q + 1
          else:
            var v = i
            while v < s.len and s[v] notin {' ', ']'}: inc v
            value = s[i ..< v]
            i = v
        result.attrs.add (name, value)
    of '{':
      let e = s.find('}', i + 1)
      if e < 0: raise newException(ValueError, "a { not closed")
      result.text = s[i + 1 ..< e]
      result.hasText = true
      i = e + 1
    else: break
  if result.tag.len == 0:
    if result.id.len > 0 or result.classes.len > 0 or result.attrs.len > 0: result.tag = implied(parent)
    elif not result.hasText:
      raise newException(ValueError, "a tag's name (column " & $(i + 1) & ")")

proc emmetList(s: string, i: var int, parent: string, inGroup: bool): seq[ENode] =
  ## reads the Emmet elements joined by > (child), + (sibling) and ^ (up a level), with (groups) and *n repeats, until
  ## the end of the text or the ) that closes the group; raises ValueError with what is wrong and where
  let root = ENode(group: true, tag: parent)
  var stack = @[root]
  var last: ENode = nil
  var want = true                        # an element (or a group) comes next
  while i < s.len:
    if want:
      var item: ENode
      if s[i] == '(':
        inc i
        item = ENode(group: true, count: 1, kids: emmetList(s, i, stack[^1].tag, true))
      else:
        item = emmetElement(s, i, stack[^1].tag)
      if i < s.len and s[i] == '*':
        inc i
        var e = i
        while e < s.len and s[e] in Digits: inc e
        if e == i: raise newException(ValueError, "a number after * (column " & $(i + 1) & ")")
        item.count = max(1, parseInt(s[i ..< e]))
        i = e
      stack[^1].kids.add item
      last = item
      want = false
      continue
    case s[i]
    of '>':
      var t = last
      while t.group and t.kids.len > 0: t = t.kids[^1]
      stack.add t
    of '+': discard
    of '^':
      if stack.len > 1: stack.setLen(stack.len - 1)
      if i + 1 < s.len and s[i + 1] == '^':
        inc i
        continue
    of ')':
      if not inGroup: raise newException(ValueError, "a ) without its (")
      inc i
      return root.kids
    else: raise newException(ValueError, "'" & s[i] & "' where + > ^ or the end should be (column " & $(i + 1) & ")")
    inc i
    want = true
  if inGroup: raise newException(ValueError, "a ( not closed")
  if want and root.kids.len > 0: raise newException(ValueError, "something after the last + > or ^")
  root.kids

func numbered(s: string, n: int): string =
  ## $ as the number of the copy (1, 2, 3 …), $$ as 01, 02 …
  var i = 0
  while i < s.len:
    if s[i] == '$':
      var e = i
      while e < s.len and s[e] == '$': inc e
      result.add align($n, e - i, '0')
      i = e
    else:
      result.add s[i]
      inc i

proc expand(n: ENode, idx: int): seq[HNode] =
  ## the HTML nodes an Emmet node stands for: its repeats written out (a $ in names and text is the copy's number), its
  ## id, classes and attributes, the attributes Emmet gives a, img, input, link, form and label when they have none, its
  ## text and its children
  for k in 1 .. n.count:
    let ix = if n.count > 1: k else: idx
    if n.group:
      for c in n.kids: result.add expand(c, ix)
      continue
    if n.tag.len == 0:
      result.add HNode(kind: hkText, text: numbered(n.text, ix))
      continue
    let h = elem(n.tag)
    if n.id.len > 0: h.attrs.add ("id", nimStr(numbered(n.id, ix)))
    if n.classes.len > 0: h.attrs.add ("class", nimStr(numbered(n.classes.join(" "), ix)))
    var given: seq[string]
    for (a, v) in n.attrs:
      h.attrs.add (a, nimStr(numbered(v, ix)))
      given.add a
    # (what Emmet gives these tags when they have none)
    let defaults = case n.tag
                   of "a": @[("href", "")]
                   of "img": @[("src", ""), ("alt", "")]
                   of "input": @[("type", "text")]
                   of "link": @[("rel", "stylesheet"), ("href", "")]
                   of "form": @[("action", "")]
                   of "label": @[("for", "")]
                   else: @[]
    for (a, v) in defaults:
      if a notin given: h.attrs.add (a, nimStr(v))
    if n.hasText: h.kids.add HNode(kind: hkText, text: numbered(n.text, ix))
    for c in n.kids: h.kids.add expand(c, ix)
    result.add h

proc parseEmmet*(abbr: string): seq[HNode] =
  ## an Emmet abbreviation as the elements it stands for (ValueError: why it is not one)
  var i = 0
  let s = abbr.strip
  if s.len == 0: raise newException(ValueError, "the line is empty")
  for n in emmetList(s, i, "", false): result.add expand(n, 1)

func looksLikeEmmet*(s: string): bool =
  ## a line that could be an abbreviation, not a line of Karax (no spaces outside {…} and […], an operator)
  let t = s.strip
  if t.len == 0 or t.endsWith(":"): return false
  var depth = 0
  var op = false
  for c in t:
    case c
    of '{', '[': inc depth
    of '}', ']': dec depth
    of ' ', '=', '"', ',':
      if depth == 0: return false
    of '>', '+', '*', '.', '#', '^': op = op or depth == 0
    else: discard
  op

# ── std/htmlgen ──

const HtmlgenTags = ["a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo", "big",
  "blockquote", "body", "br", "button", "canvas", "caption", "center", "cite", "code", "col", "colgroup", "data",
  "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em", "embed", "fieldset", "figure",
  "figcaption", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "html", "hr", "i", "iframe",
  "img", "input", "ins", "kbd", "keygen", "label", "legend", "li", "link", "main", "map", "mark", "marquee", "meta",
  "meter", "nav", "noscript", "object", "ol", "optgroup", "option", "output", "p", "param", "picture", "pre",
  "progress", "q", "rb", "rp", "rt", "rtc", "ruby", "s", "samp", "script", "section", "select", "slot", "small",
  "source", "span", "strong", "style", "sub", "summary", "sup", "table", "tbody", "td", "template", "textarea",
  "tfoot", "th", "thead", "time", "title", "tr", "track", "tt", "u", "ul", "var", "video", "wbr", "math"]

const OpChars = {'=', '<', '>', '!', '+', '-', '*', '/', '.', '$', '@', '%', '|', '~', '^', '&'}

type
  TokKind = enum tkIdent, tkStr, tkLPar, tkRPar, tkComma, tkEq, tkAmp, tkOther, tkEnd
  Tok = object
    kind: TokKind
    text: string                 # tkIdent: the name (without backticks) · tkStr: the string's value
    a, b: int                    # where it is in the source

func unescape(s: string): string =
  ## the text of a Nim string literal with its backslash escapes (\n \t \r \\ \" \' \xHH \uHHHH) turned into the
  ## characters
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      inc i
      case s[i]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of '\\': result.add '\\'
      of '"': result.add '"'
      of '\'': result.add '\''
      of 'x':
        if i + 2 < s.len:
          try: result.add chr(parseHexInt(s[i + 1 .. i + 2]))
          except ValueError: discard
          i += 2
      of 'u':
        if i + 4 < s.len:
          try: result.add utf8(parseHexInt(s[i + 1 .. i + 4]))
          except ValueError: discard
          i += 4
      else: result.add s[i]
    else: result.add s[i]
    inc i

func tokens(s: string): seq[Tok] =
  ## splits Nim source into the tokens htmlgen calls are made of: names (a backticked one without its backticks;
  ## htmlgen.h1 starts at htmlgen), strings (plain, raw and triple-quoted), brackets, commas, = and &, other operators,
  ## with where each is; comments are skipped and a tkEnd closes the list
  var i = 0
  var qual = -1
  while i < s.len:
    let c = s[i]
    if c in {' ', '\t', '\n', '\r'}:
      inc i
      continue
    if c == '#':                                         # a comment, to the line's end
      while i < s.len and s[i] != '\n': inc i
      continue
    let a = i
    if c != '`' and c notin {'a'..'z', 'A'..'Z', '_'}: qual = -1
    if c == '"' or (c in {'r', 'R'} and i + 1 < s.len and s[i + 1] == '"'):
      let rawStr = c != '"'
      if rawStr: inc i
      if s.continuesWith("\"\"\"", i):
        let e = s.find("\"\"\"", i + 3)
        let stop = if e < 0: s.len else: e
        var body = s[i + 3 ..< stop]
        if body.startsWith("\n"): body = body[1 .. ^1]
        result.add Tok(kind: tkStr, text: body, a: a, b: min(s.len, stop + 3))
        i = min(s.len, stop + 3)
        continue
      var j = i + 1
      var body = ""
      while j < s.len and s[j] != '"':
        if s[j] == '\\' and not rawStr and j + 1 < s.len:
          body.add s[j .. j + 1]
          j += 2
        elif rawStr and s[j] == '"' and j + 1 < s.len and s[j + 1] == '"':
          body.add '"'
          j += 2
        else:
          body.add s[j]
          inc j
      result.add Tok(kind: tkStr, text: (if rawStr: body else: unescape(body)), a: a, b: min(s.len, j + 1))
      i = j + 1
      continue
    if c == '`':
      let e = s.find('`', i + 1)
      let stop = if e < 0: s.len else: e
      result.add Tok(kind: tkIdent, text: s[i + 1 ..< stop], a: (if qual >= 0: qual else: a), b: min(s.len, stop + 1))
      qual = -1
      i = stop + 1
      continue
    if c in {'a'..'z', 'A'..'Z', '_'} or c.uint8 >= 0x80:
      var j = i
      while j < s.len and (s[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or s[j].uint8 >= 0x80): inc j
      if s[i ..< j] == "htmlgen" and j < s.len and s[j] == '.':
        qual = a                                         # (htmlgen.h1(…): the call starts at htmlgen)
        i = j + 1
        continue
      result.add Tok(kind: tkIdent, text: s[i ..< j], a: (if qual >= 0: qual else: a), b: j)
      qual = -1
      i = j
      continue
    let k = case c
            of '(': tkLPar
            of ')': tkRPar
            of ',': tkComma
            of '=': (if i + 1 < s.len and s[i + 1] == '=': tkOther else: tkEq)
            of '&': tkAmp
            else: tkOther
    if k == tkOther and c in OpChars - {'&'}:
      var j = i
      while j < s.len and s[j] in OpChars: inc j
      if j - i == 1 and c == '&':
        result.add Tok(kind: tkAmp, a: a, b: j)
      else:
        result.add Tok(kind: tkOther, text: s[i ..< j], a: a, b: j)
      i = j
      continue
    result.add Tok(kind: k, text: $c, a: a, b: i + 1)
    inc i
  result.add Tok(kind: tkEnd, a: s.len, b: s.len)

type GenParser = object
  src: string
  t: seq[Tok]
  i: int

# the token k places after the current one (the last one, the end, when there are not so many)
func peek(p: GenParser, k = 0): Tok = p.t[min(p.i + k, p.t.high)]

func isTagCall(p: GenParser): bool =
  ## whether the next tokens are the call of a std/htmlgen tag: its name and an opening bracket
  p.peek.kind == tkIdent and p.peek.text in HtmlgenTags and p.peek(1).kind == tkLPar

proc skipExpr(p: var GenParser): (int, int) =
  ## an expression that is not a tag: its place in the source (up to a , ) or & at its depth; &"…" is one)
  let a = p.peek.a
  var b = a
  var depth = 0
  var first = true
  while p.peek.kind != tkEnd:
    let k = p.peek.kind
    if depth == 0 and k in {tkComma, tkRPar, tkAmp} and not (first and k == tkAmp): break
    first = false
    if k == tkLPar: inc depth
    elif k == tkRPar: dec depth
    elif k == tkOther and p.peek.text in ["[", "{"]: inc depth
    elif k == tkOther and p.peek.text in ["]", "}"]: dec depth
    b = p.peek.b
    inc p.i
  (a, b)

proc genChild(p: var GenParser): seq[HNode]

proc genCall(p: var GenParser): HNode =
  ## reads a htmlgen tag call tag(a = "…", child, …) as an element: name = value pairs are its attributes (a string
  ## value becomes a string, any other expression stays Nim code), the rest its children; raises ValueError when the
  ## bracket is not closed
  result = elem(p.peek.text)
  p.i += 2                                               # the tag and its (
  while p.peek.kind notin {tkRPar, tkEnd}:
    if p.peek.kind == tkIdent and p.peek(1).kind == tkEq:
      let name = p.peek.text
      p.i += 2
      if p.peek.kind == tkStr and p.peek(1).kind in {tkComma, tkRPar}:
        result.attrs.add (name, nimStr(p.peek.text))
        inc p.i
      else:
        let (a, b) = skipExpr(p)
        result.attrs.add (name, p.src[a ..< b].strip)
    else:
      for k in genChild(p): result.kids.add k
    if p.peek.kind == tkComma: inc p.i
    elif p.peek.kind notin {tkRPar, tkEnd}:
      let (a, b) = skipExpr(p)                           # (something the parser does not know: kept as code)
      if b > a: result.kids.add HNode(kind: hkExpr, text: p.src[a ..< b].strip)
  if p.peek.kind == tkEnd: raise newException(ValueError, "a ( not closed")
  inc p.i

proc genChild(p: var GenParser): seq[HNode] =
  ## a child: a tag's call, a string, any other expression (text made from it) — several joined with &
  while true:
    if isTagCall(p): result.add genCall(p)
    elif p.peek.kind == tkStr and p.peek(1).kind in {tkComma, tkRPar, tkAmp, tkEnd}:
      for n in parseHtml(p.peek.text): result.add n     # (htmlgen puts a string in as HTML: <b>, &amp; …)
      inc p.i
    else:
      let (a, b) = skipExpr(p)
      if b <= a: raise newException(ValueError, "something the parser does not know at column " & $(a + 1))
      result.add HNode(kind: hkExpr, text: p.src[a ..< b].strip)
    if p.peek.kind == tkAmp: inc p.i
    else: break

proc parseHtmlgen*(src: string): seq[HNode] =
  ## an htmlgen expression — h1(a(href = "…", "Nim")) — as a tree
  var p = GenParser(src: src, t: tokens(src))
  if not isTagCall(p): raise newException(ValueError, "it does not start with a tag of std/htmlgen: h1(…)")
  result = genChild(p)
  if p.peek.kind != tkEnd: raise newException(ValueError, "more after the call (column " & $(p.peek.a + 1) & ")")

proc htmlgenCallAt*(lines: seq[string], line, col: int): (Pos, Pos) =
  ## the outermost htmlgen call around (line, col), or starting on its line: its start and its end (line -1: none)
  result = (pos(-1, 0), pos(-1, 0))
  let first = max(0, line - 60)
  let last = min(lines.high, line + 200)
  var text = ""
  var starts: seq[int]
  for k in first .. last:
    starts.add text.len
    text.add lines[k] & "\n"
  let here = starts[line - first] + min(col, lines[line].len)
  let lineEnd = starts[line - first] + lines[line].len
  let ts = tokens(text)
  var around = (-1, -1)                  # the first call (the outermost) the cursor is in
  var onLine = (-1, -1)                  # the first one that starts on the cursor's line
  for k in 0 ..< ts.high:
    let t = ts[k]
    if t.kind == tkIdent and t.text in HtmlgenTags and ts[k + 1].kind == tkLPar and
       (k == 0 or not (ts[k - 1].kind == tkOther and ts[k - 1].text == ".")):
      var depth = 0
      var e = -1
      for m in k + 1 ..< ts.len:
        if ts[m].kind == tkLPar: inc depth
        elif ts[m].kind == tkRPar:
          dec depth
          if depth == 0:
            e = ts[m].b
            break
      if e < 0: continue
      if around[0] < 0 and t.a <= here and here <= e: around = (t.a, e)
      if onLine[0] < 0 and t.a >= starts[line - first] and t.a <= lineEnd: onLine = (t.a, e)
  let (best, bestEnd) = if around[0] >= 0: around else: onLine
  if best < 0: return
  proc toPos(o: int): Pos =
    ## the buffer position of offset o in the text that was joined from the lines
    var k = starts.high
    while k > 0 and starts[k] > o: dec k
    pos(first + k, o - starts[k])
  result = (toPos(best), toPos(bestEnd))

# ── where the cursor is in Karax's DSL ──

func inBuildHtml*(lines: seq[string], k, col: int): bool =
  ## is column col of lines[k] in a buildHtml block (or its brackets)? — the lines above it, by indentation
  if k < 0 or k >= lines.len: return false
  let cur = lines[k]
  if "buildHtml" in cur[0 ..< min(col, cur.len)]: return true
  var ind = if cur.strip.len == 0: col else: indentOf(cur)
  for i in countdown(k - 1, 0):
    let l = lines[i]
    let t = l.strip
    if t.len == 0 or t.startsWith("#"): continue
    let li = indentOf(l)
    if li < ind:
      if "buildHtml" in l: return true
      ind = li
      if li == 0: return false
  false

func openCall*(lines: seq[string], k, col: int): (string, int) =
  ## the name of the call whose brackets are open at column col of lines[k] (looking up to 5 lines up), and the
  ## column after the last ( or , before col ("" when no bracket is open)
  var depth = 0
  var sep = -1
  for i in countdown(k, max(0, k - 5)):
    let l = lines[i]
    var j = if i == k: min(col, l.len) - 1 else: l.high
    var inStr = false
    # (strings: the quotes counted from the line's start)
    var quoted = newSeq[bool](l.len)
    var q = false
    for m in 0 ..< l.len:
      if l[m] == '"' and (m == 0 or l[m - 1] != '\\'): q = not q
      quoted[m] = q
    while j >= 0:
      inStr = quoted[j] or l[j] == '"'
      if not inStr:
        case l[j]
        of ')', ']', '}': inc depth
        of '(', '[', '{':
          if depth == 0:
            if l[j] != '(': return ("", -1)
            # (a bracket on a line above is open for this one only when this one goes on from it: indented more)
            if i < k and indentOf(lines[k]) <= indentOf(l): return ("", -1)
            var e = j
            while e > 0 and l[e - 1] == ' ': dec e
            var a = e
            while a > 0 and l[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '`'}: dec a
            if i == k and sep < 0: sep = j + 1
            return (l[a ..< e].strip(chars = {'`'}), sep)
          dec depth
        of ',':
          if depth == 0 and i == k and sep < 0: sep = j + 1
        else: discard
      dec j
  ("", -1)

func tagNames(): seq[string] =
  ## the names of Karax's tags (without backticks)
  for (k, _, _) in Tags: result.add k.strip(chars = {'`'})

func isKaraxTag(name: string): bool =
  ## whether Karax has a tag of this name
  name in tagNames() or name in OtherTags

proc tagDoc(name: string): string =
  ## the hover text for a Karax tag or word (text, verbatim …): its name, the HTML element and what it is; "" for
  ## anything else
  for (k, h, what) in Tags:
    if k.strip(chars = {'`'}) == name:
      return "**" & k & "** — `<" & h & ">`: " & what
  for (w, _, what) in Words:
    if w == name: return "**" & w & "** — " & what
  if name in OtherTags: return "**" & name & "** — the `<" & name & ">` element (SVG or MathML)"
  ""

proc attrDoc(name: string): string =
  ## the hover text for an attribute: what it is; an on… name is described as an event proc; "" for any other
  for (k, _, what) in Attrs:
    if k.strip(chars = {'`'}) == name: return "**" & k & "** — " & what
  if name.startsWith("on"): return "**" & name & "** — Karax: a proc called on the " & name[2 .. ^1] & " event"
  ""

# ── completion and hover ──

completions("nim") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let first = max(0, p.line - 300)
  let ls = b.lines(first, p.line)
  let k = p.line - first
  if k < 0 or k >= ls.len or not inBuildHtml(ls, k, p.col): return
  let l = ls[k]
  let start = max(0, min(p.col, l.len) - prefix.len)
  let before = l[0 ..< start]
  let lp = prefix.toLowerAscii
  let (call, sep) = openCall(ls, k, start)
  if call.len > 0 and call != "buildHtml":
    # in a tag's brackets: its attributes, where a name goes (not after =)
    if not isKaraxTag(call) or (sep >= 0 and l[sep ..< start].strip.len > 0) or (sep < 0 and before.strip.len > 0):
      return
    for (name, ins, what) in Attrs:
      if name.strip(chars = {'`'}).toLowerAscii.startsWith(lp):
        result.add CompletionItem(label: name.strip(chars = {'`'}), insert: ins, snippet: true, kind: "field",
                                  detail: "attribute", doc: what)
    return
  let t = before.strip
  if not (t.len == 0 or t.endsWith(":") or (call == "buildHtml" and t.endsWith("("))): return
  for (name, h, what) in Tags:
    let n = name.strip(chars = {'`'})
    if n.toLowerAscii.startsWith(lp) or h.startsWith(lp):
      result.add CompletionItem(label: n, insert: name, kind: "class", detail: "<" & h & ">", doc: what)
  if not (call == "buildHtml" and t.endsWith("(")):
    for (w, ins, what) in Words:
      if w.startsWith(lp):
        result.add CompletionItem(label: w, insert: ins, snippet: true, kind: "keyword", detail: "Karax", doc: what)

hover("nim") do (b: Buf, p: Pos) -> string:
  let first = max(0, p.line - 300)
  let ls = b.lines(first, p.line)
  let k = p.line - first
  if k < 0 or k >= ls.len or not inBuildHtml(ls, k, p.col): return ""
  let l = ls[k]
  if p.col >= l.len or l[p.col] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return ""
  var a = p.col
  var e = p.col
  while a > 0 and l[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: dec a
  while e < l.len and l[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: inc e
  let w = l[a ..< e]
  var after = e
  if after < l.len and l[after] == '`': inc after
  while after < l.len and l[after] == ' ': inc after
  let isArg = after < l.len and l[after] == '=' and (after + 1 >= l.len or l[after + 1] != '=')
  let (call, _) = openCall(ls, k, a)
  if isArg and call.len > 0 and isKaraxTag(call): return attrDoc(w)
  if '-' in w: return ""
  # (a tag where a statement starts — after the indentation, a colon, buildHtml( — not a variable of that name)
  var s = a
  if s > 0 and l[s - 1] == '`': dec s
  let before = l[0 ..< s].strip
  if before.len == 0 or before.endsWith(":") or (call == "buildHtml" and before.endsWith("(")): tagDoc(w)
  else: ""

# ── the commands ──

proc karaxImport(b: Buf, style: bool): int =
  ## import karax/[karaxdsl, vdom] in a Nim file that imports neither karaxdsl nor karax/prelude: after its
  ## imports, else after the comments it starts with — how many lines were added
  let ls = b.lines
  var at = -1
  var i = 0
  while i < ls.len:
    let l = ls[i]
    if l.startsWith("import") or l.startsWith("include") or l.startsWith("from"):
      if "karaxdsl" in l or "prelude" in l: return 0
      # (the statement's lines: on while a bracket is open or the line ends with a comma)
      var depth = 0
      var j = i
      while j < ls.len:
        for c in ls[j]:
          if c in {'[', '('}: inc depth
          elif c in {']', ')'}: dec depth
        if "karaxdsl" in ls[j] or "prelude" in ls[j]: return 0
        if depth <= 0 and not ls[j].strip.endsWith(","): break
        inc j
      at = j + 1
      i = j
    inc i
  var text = "import karax/[karaxdsl, vdom" & (if style: ", vstyles" else: "") & "]\n"
  if at < 0:
    at = 0
    while at < ls.len and ls[at].startsWith("#"): inc at
    if at < ls.len and ls[at].strip.len > 0: text.add "\n"
    if at > 0:
      text = "\n" & text
  b.insert(pos(at, 0), text)
  text.count('\n')

proc placeLines(b: Buf, r: Range, rel: seq[string]): Pos =
  ## the lines (indented from column 0) in place of the range: at its line's indentation when the range starts
  ## there, else on from where it starts; the cursor's place after them
  let l0 = b.line(r.start.line)
  let ind = l0[0 ..< indentOf(l0)]
  let atIndent = l0[0 ..< min(r.start.col, l0.len)].strip.len == 0
  let a = if atIndent: pos(r.start.line, 0) else: r.start
  var out0: seq[string]
  for i, x in rel:
    out0.add (if i == 0 and not atIndent: x elif x.len > 0: ind & x else: x)
  var text = out0.join("\n")
  if r.stop.col == 0 and r.stop.line > r.start.line: text.add "\n"
  b.replace(rng(a, r.stop), text)
  let lastLine = a.line + out0.high
  pos(lastLine, out0[^1].len)

proc emmetToKarax() =
  ## Nim HTML: Emmet to Karax — replaces the Emmet abbreviation on the cursor's line with Karax's DSL at the line's
  ## indentation, the cursor in the first empty "" or () to fill; warns when the line is not an abbreviation
  let b = current()
  if not b.valid: return
  let ln = b.cursor.line
  let l = b.line(ln)
  var nodes: seq[HNode]
  try: nodes = parseEmmet(l)
  except ValueError as e:
    warn("Emmet: not an abbreviation — " & e.msg)
    return
  let ind = l[0 ..< indentOf(l)]
  var lines: seq[string]
  for x in karaxLines(nodes, b.indentUnit): lines.add ind & x
  b.replace(b.lineRange(ln), lines.join("\n"))
  # (the cursor where something is to be written: the first "" or (), else the end)
  for i, x in lines:
    for mark in ["\"\"", "()"]:
      let c = x.find(mark)
      if c >= 0:
        b.setCursor(pos(ln + i, c + 1))
        return
  b.setCursor(pos(ln + lines.high, lines[^1].len))

func tabName(path: string): string =
  ## the name for the tab of the Karax code made from a file: the file's name with .nim in place of its extension
  ## (page.nim when the tab has no file)
  if path.len == 0: return "page.nim"
  let n = extractFilename(path)
  let d = n.rfind('.')
  (if d > 0: n[0 ..< d] else: n) & ".nim"

proc toTab(b: Buf, nodes: seq[HNode], what: string) =
  ## a whole program in a new tab: the imports, a proc that builds the page
  let unit = "  "
  var code = "import karax/[karaxdsl, vdom" & (if usesStyle(nodes): ", vstyles" else: "") & "]\n\n" &
             "proc render*(): VNode =\n"
  var body = wrapped(nodes, unit)
  body[0] = "result = " & body[0]
  for x in body: code.add unit & x & "\n"
  code.add "\nwhen isMainModule:\n" & unit & "echo render()   # the HTML (Karax's $ for a VNode)\n"
  let name = tabName(b.path)
  discard newTab(name, code, "nim")
  message("Karax's DSL for " & what & " is in " & name)

proc htmlToKarax() =
  ## Nim HTML: HTML to Karax — converts the selected HTML (the whole file when none is selected) to Karax's DSL: in
  ## place in a .nim file (a buildHtml(…) with its import added unless the selection is inside a buildHtml block),
  ## otherwise in a new tab
  let b = current()
  if not b.valid: return
  let sel = b.selection
  let isNim = b.lang == "nim"
  if sel.isEmpty:
    let nodes = parseHtml(b.text)
    if tidy(nodes).len == 0:
      message("HTML to Karax: no HTML in this file")
      return
    toTab(b, nodes, (if b.path.len > 0: extractFilename(b.path) else: "the file"))
    return
  let nodes = parseHtml(b.textIn(sel))
  if tidy(nodes).len == 0:
    message("HTML to Karax: no HTML in the selection")
    return
  if not isNim:
    toTab(b, nodes, "the selection")
    return
  let first = max(0, sel.start.line - 300)
  let ls = b.lines(first, sel.start.line)
  let inside = inBuildHtml(ls, sel.start.line - first, sel.start.col)
  let unit = b.indentUnit
  let rel = if inside: karaxLines(nodes, unit) else: wrapped(nodes, unit)
  let at = placeLines(b, sel, rel)
  let added = if inside: 0 else: karaxImport(b, usesStyle(nodes))
  b.setCursor(pos(at.line + added, at.col))
  message("HTML to Karax: " & $rel.len & " lines" & (if usesStyle(nodes) and inside: " — style uses toCss " &
          "(import karax/vstyles)" else: ""))

proc htmlgenToKarax() =
  ## Nim HTML: htmlgen to Karax — converts the selected std/htmlgen call, or the outermost one around the cursor or
  ## starting on its line, into Karax's DSL in its place (a buildHtml(…) with its import added unless it is inside a
  ## buildHtml block)
  let b = current()
  if not b.valid: return
  var r = b.selection
  if r.isEmpty:
    let ls = b.lines
    let c = b.cursor
    let (a, e) = htmlgenCallAt(ls, c.line, c.col)
    if a.line < 0:
      message("htmlgen to Karax: no htmlgen call here — h1(…), html(head(…), body(…))")
      return
    r = rng(a, e)
  var nodes: seq[HNode]
  try: nodes = parseHtmlgen(b.textIn(r))
  except ValueError as e:
    warn("htmlgen to Karax: " & e.msg)
    return
  let first = max(0, r.start.line - 300)
  let ls = b.lines(first, r.start.line)
  let inside = inBuildHtml(ls, r.start.line - first, r.start.col)
  let unit = b.indentUnit
  let rel = if inside: karaxLines(nodes, unit) else: wrapped(nodes, unit)
  let at = placeLines(b, r, rel)
  let added = if inside: 0 else: karaxImport(b, usesStyle(nodes))
  b.setCursor(pos(at.line + added, at.col))
  message("htmlgen to Karax: " & $rel.len & " lines")

command "Nim HTML: Emmet to Karax":
  emmetToKarax()

command "Nim HTML: HTML to Karax":
  htmlToKarax()

command "Nim HTML: htmlgen to Karax":
  htmlgenToKarax()

codeActions("nim") do (b: Buf, r: Range) -> seq[Fix]:
  # an Emmet abbreviation alone on its line, in a buildHtml block: its expansion
  let first = max(0, r.start.line - 300)
  let ls = b.lines(first, r.start.line)
  let k = r.start.line - first
  if k < 0 or k >= ls.len or not looksLikeEmmet(ls[k]) or not inBuildHtml(ls, k, indentOf(ls[k])): return
  try:
    let nodes = parseEmmet(ls[k])
    let ind = ls[k][0 ..< indentOf(ls[k])]
    var lines: seq[string]
    for x in karaxLines(nodes, b.indentUnit): lines.add ind & x
    result.add Fix(title: "Emmet: expand " & ls[k].strip,
                   edits: @[Edit(range: rng(pos(r.start.line, 0), pos(r.start.line, ls[k].len)),
                                 text: lines.join("\n"))])
  except ValueError: discard

# ── snippets ──

snippet("nim", "buildhtml", "buildHtml(${1:tdiv}(class = \"${2:box}\")):\n\t${0:text \"Hello\"}",
        "a Karax buildHtml block")
snippet("nim", "karax", "include karax/prelude\n\nproc createDom(): VNode =\n\tresult = buildHtml(tdiv):\n\t\t" &
        "h1: text \"${1:Hello}\"\n\t\tbutton:\n\t\t\ttext \"${2:Click me}\"\n\t\t\tproc onclick() =\n\t\t\t\t$0" &
        "discard\n\nsetRenderer createDom", "a Karax app: createDom and setRenderer (nim js)")
snippet("nim", "htmlgen", "import std/htmlgen\n\nlet page = html(\n\thead(title(\"${1:Title}\")),\n\tbody(\n\t\t" &
        "h1(\"${2:Hello}\"),\n\t\tp(\"$0\")\n\t)\n)\nwriteFile(\"${3:index.html}\", \"<!DOCTYPE html>\\n\" & page)",
        "a page made with std/htmlgen, written to a file")
