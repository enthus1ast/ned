# ── surround: brackets, quotes, a tag or a block (if, for, try…) around the selection; the pair around the cursor
#    changed for another or taken away. Edit › Surround with…, and vim's ys{motion}{char}, yss, cs{old}{new},
#    ds{char} and S{char} in visual mode (as vim-surround) ──

func surroundPair(ch: char, spaced = true): (string, string) =
  ## the pair a key stands for (vim-surround's): an opening bracket puts spaces inside, a closing one does not
  case ch
  of '(': (if spaced: ("( ", " )") else: ("(", ")"))
  of ')', 'b': ("(", ")")
  of '[': (if spaced: ("[ ", " ]") else: ("[", "]"))
  of ']', 'r': ("[", "]")
  of '{': (if spaced: ("{ ", " }") else: ("{", "}"))
  of '}', 'B': ("{", "}")
  of '>', 'a': ("<", ">")
  of '"', '\'', '`', '*', '_', '~', '|', '/', '=', '-', '+', '$', '%', '#', ':', ',', '.', '!', '?', '^', '&', '\\':
    ($ch, $ch)
  else: ("", "")

func tagPair(tag: string): (string, string) =
  ## <tag attrs…> and </tag>
  let t = tag.strip.strip(chars = {'<', '>'})
  var name = t
  let sp = t.find({' ', '\t'})
  if sp > 0: name = t[0 ..< sp]
  ("<" & t & ">", "</" & name & ">")

proc surroundRanges(b: Buffer, op, cl: string, ranges: seq[(Pos, Pos)]) =
  ## `op` before and `cl` after each range (one undo step); each cursor then holds its text with the pair
  if not b.canEdit() or ranges.len == 0: return
  var rs = ranges
  rs.sort(proc(x, y: (Pos, Pos)): int = cmp(x[0], y[0]))
  b.beginEdit()
  for i in countdown(rs.high, 0):
    let (a, e) = rs[i]
    discard b.replaceText(e, e, cl)
    discard b.replaceText(a, a, op)
  b.endEdit()
  # (where each one is now: what the ranges before it put on its line moved it right; op and cl hold no line break)
  var cs: seq[Cursor]
  for i, (a, e) in rs:
    var shift = 0
    for j in 0 ..< i:
      if rs[j][0].line == a.line: shift += op.len
      if rs[j][1].line == a.line: shift += cl.len
    let na = Pos(line: a.line, col: a.col + shift)
    var ne = Pos(line: e.line, col: e.col + cl.len)
    if e.line == a.line: ne.col += shift + op.len
    cs.add Cursor(anchor: na, head: ne, goalX: -1)
  b.cursors = cs
  b.prim = cs.high
  b.normalize()

proc selectionsOrWord(b: Buffer): seq[(Pos, Pos)] =
  ## what a surround goes around: each selection, or the word under each cursor
  for c in b.cursors:
    var (a, e) = c.range
    if a == e:
      let (wa, we) = b.wordRangeAt(c.head)
      a = wa
      e = we
    result.add (a, e)

proc surroundLines(b: Buffer, header, footer: string, l0, l1: int) =
  ## lines l0..l1 one level in, under `header` and above `footer` (snippet text: ${1:…} are places Tab visits; a
  ## \n in the footer starts a line at the block's indentation, a \t is one level of indentation)
  if not b.canEdit(): return
  var ind = ""
  var found = false
  for l in l0 .. l1:
    if not isBlank(b.lines[l]):
      let w = leadingWs(b.lines[l])
      if not found or w.len < ind.len: ind = w
      found = true
  # escapes `$` in the person's own text so the snippet that inserts it does not take it for a placeholder
  func esc(s: string): string = s.replace("$", "\\$")
  # (a Markdown fence or a C #if: the lines stay where they are; any other block: one level in)
  let step = if header.startsWith("```") or header.startsWith("#if"): "" else: b.indent
  var body = ind & header.replace("\n", "\n" & ind).replace("\t", b.indent)
  for l in l0 .. l1:
    let s = b.lines[l]
    body.add "\n" & (if isBlank(s): "" else: ind & step & esc(s[min(ind.len, s.len) .. ^1]))
  if footer.len > 0:
    body.add "\n" & ind & footer.replace("\n", "\n" & ind).replace("\t", b.indent)
  b.expandSnippet(Pos(line: l0, col: 0), Pos(line: l1, col: b.lines[l1].len), body, literal = true)

proc surroundBlocks(lang: string): seq[(string, string, string, string)] =
  ## (label, what it does, header, footer) for the language's blocks
  case lang
  of "nim", "nimf":
    @[("if", "the lines run only if…", "if ${1:true}:", ""),
      ("when", "the lines compiled only when…", "when ${1:defined(release)}:", ""),
      ("for", "the lines in a loop", "for ${1:x} in ${2:xs}:", ""),
      ("while", "the lines in a while loop", "while ${1:true}:", ""),
      ("block", "the lines in a block (break leaves it)", "block ${1:outer}:", ""),
      ("try", "the lines with an except", "try:", "except ${1:CatchableError} as e:\n\t${2:discard}"),
      ("try … finally", "something done after the lines, whatever happens", "try:", "finally:\n\t${1:discard}"),
      ("proc", "the lines become a routine", "proc ${1:name}() =", "")]
  of "python":
    @[("if", "the lines run only if…", "if ${1:True}:", ""),
      ("for", "the lines in a loop", "for ${1:x} in ${2:xs}:", ""),
      ("while", "the lines in a while loop", "while ${1:True}:", ""),
      ("with", "the lines in a with", "with ${1:open(path)} as ${2:f}:", ""),
      ("try", "the lines with an except", "try:", "except ${1:Exception} as e:\n\t${2:pass}"),
      ("def", "the lines become a function", "def ${1:name}():", "")]
  of "c", "cpp", "javascript", "typescript", "java", "csharp", "php", "kotlin":
    var r = @[("if", "the lines run only if…", "if (${1:cond}) {", "}"),
              ("for", "the lines in a loop", "for (${1:int i = 0; i < n; i++}) {", "}"),
              ("while", "the lines in a while loop", "while (${1:cond}) {", "}"),
              ("{ }", "the lines in a block", "{", "}")]
    if lang != "c":
      r.add ("try", "the lines with a catch", "try {", "} catch (${1:e}) {\n\t${2}\n}")
    if lang == "c" or lang == "cpp":
      r.add ("#if", "the lines only when a macro is set", "#if ${1:DEBUG}", "#endif")
    r
  of "go", "rust":
    @[("if", "the lines run only if…", "if ${1:cond} {", "}"),
      ("for", "the lines in a loop", (if lang == "go": "for ${1:i := 0; i < n; i++} {" else: "for ${1:x} in ${2:xs} {"), "}"),
      ("{ }", "the lines in a block", "{", "}")]
  of "shellscript":
    @[("if", "the lines run only if…", "if [ ${1:-n \"$x\"} ]; then", "fi"),
      ("for", "the lines in a loop", "for ${1:f} in ${2:*}; do", "done"),
      ("while", "the lines in a while loop", "while ${1:true}; do", "done")]
  of "lua":
    @[("if", "the lines run only if…", "if ${1:cond} then", "end"),
      ("for", "the lines in a loop", "for ${1:i} = ${2:1}, ${3:n} do", "end"),
      ("do", "the lines in a block", "do", "end")]
  of "ruby":
    @[("if", "the lines run only if…", "if ${1:cond}", "end"),
      ("each", "the lines in a loop", "${1:xs}.each do |${2:x}|", "end"),
      ("begin", "the lines with a rescue", "begin", "rescue ${1:StandardError} => e\n\t${2}\nend")]
  of "markdown":
    @[("``` block", "the lines as a code block", "```${1:nim}", "```"),
      ("> quote", "the lines as a quote", "", "")]
  else: @[]

proc cmdSurroundTag(b: Buffer, ranges: seq[(Pos, Pos)], lines = false) =
  ## asks for a tag name (attributes allowed, `div` offered) and puts <tag> … </tag> around the ranges, or, with
  ## `lines`, around the whole lines of the first range as a block
  askText("Tag (with attributes if you like)", "div", proc(t: string) =
    if t.strip.len == 0: return
    let (op, cl) = tagPair(t)
    if lines:
      let (a, e) = ranges[0]
      b.surroundLines(op.replace("$", "\\$"), cl, a.line, e.line)
    else: b.surroundRanges(op, cl, ranges))

# (an action for each item made by a proc of its own: closures made in a loop would share the loop's variables)
proc surPairAct(c: char, ranges: seq[(Pos, Pos)]): proc() {.closure.} =
  result = proc() =
    let (op, cl) = surroundPair(c)
    buf().surroundRanges(op, cl, ranges)

proc surSameAct(o: string, ranges: seq[(Pos, Pos)]): proc() {.closure.} =
  ## the action that puts the same text, such as `**`, before and after each range
  result = proc() = buf().surroundRanges(o, o, ranges)

proc surLinesAct(h, f: string, l0, l1: int): proc() {.closure.} =
  ## the action that puts lines l0..l1 inside a block with header h and footer f
  result = proc() = buf().surroundLines(h, f, l0, l1)

proc cmdSurround() =
  ## Edit › Surround with…: a pair around each selection (or word), or a block around the selected lines
  let b = buf()
  if not b.canEdit(): return
  let ranges = b.selectionsOrWord()
  let (sa, se) = b.primary.range
  let manyLines = sa.line != se.line
  let l0 = sa.line
  let l1 = if se.col == 0 and se.line > sa.line: se.line - 1 else: se.line
  var items: seq[(string, string, proc() {.closure.})]
  for (lab, det, ch) in [("( … )", "parentheses", ')'), ("[ … ]", "square brackets", ']'), ("{ … }", "braces", '}'),
                         ("\" … \"", "double quotes", '"'), ("' … '", "single quotes", '\''),
                         ("` … `", "backticks", '`')]:
    items.add (lab, det, surPairAct(ch, ranges))
  items.add ("<tag> … </tag>", "an HTML or XML element (you type its name)", proc() =
    buf().cmdSurroundTag(ranges, lines = manyLines))
  if b.lang != nil:
    if b.lang.id == "markdown":
      for (lab, det, op) in [("** … **", "bold", "**"), ("_ … _", "italic", "_"), ("~~ … ~~", "struck through", "~~")]:
        items.add (lab, det, surSameAct(op, ranges))
    for (lab, det, header, footer) in surroundBlocks(b.lang.id):
      if lab == "> quote":
        items.add (lab, det, proc() =
          let bb = buf()
          bb.beginEdit()
          for l in l0 .. l1: discard bb.replaceText(Pos(line: l, col: 0), Pos(line: l, col: 0), "> ")
          bb.endEdit())
      else:
        items.add (lab & " …", det & (if manyLines: "" else: " (this line)"), surLinesAct(header, footer, l0, l1))
  var search: seq[string]
  for it in items: search.add it[1]
  openActions("Surround with", items, search)

proc surroundingPairs(b: Buffer, p: Pos, which = '\0'): seq[(Pos, int, Pos, int)] =
  ## the pairs around p (opener at, its length, closer at, its length), the innermost first; `which`: only that
  ## kind (a bracket, a quote, t for a tag)
  var found: seq[(Pos, int, Pos, int)]
  let brackets = case which
    of '\0': @['(', '[', '{']
    of '(', ')', 'b': @['(']
    of '[', ']', 'r': @['[']
    of '{', '}', 'B': @['{']
    else: @[]
  for obj in brackets:
    let (ok, x, y) = b.textObject('a', obj, p)
    if ok: found.add (x, 1, Pos(line: y.line, col: y.col - 1), 1)
  if which == '\0' or which in {'"', '\'', '`'}:
    for q in (if which == '\0': @['"', '\'', '`'] else: @[which]):
      let (ok, x, y) = b.textObject('a', q, p)
      if ok and x.col < y.col:
        # (the `a"` range takes the blanks after the quotes — or, at a line's end, the ones before: the quotes are the
        # first and last characters of it that are not blanks)
        var a = x.col
        while a < y.col and b.lines[x.line][a] in {' ', '\t'}: inc a
        var e = y.col - 1
        while e > a and b.lines[y.line][e] in {' ', '\t'}: dec e
        found.add (Pos(line: x.line, col: a), 1, Pos(line: y.line, col: e), 1)
  if which in {'\0', 't', '<'}:
    # (the element around p: back to an opening tag whose closing tag is after p)
    let (ok, os, oe, cs, ce) = b.htmlElementAround(p)
    if ok: found.add (os, oe.col - os.col, cs, ce.col - cs.col)
  if which notin {'\0', '(', ')', 'b', '[', ']', 'r', '{', '}', 'B', '"', '\'', '`', 't', '<'}:
    # any other character: the nearest ones on the line around p
    let s = b.lines[p.line]
    let i = s.rfind(which, last = max(0, min(p.col, s.len - 1)))
    let j = if i >= 0: s.find(which, max(i + 1, p.col)) else: -1
    if i >= 0 and j > i: found.add (Pos(line: p.line, col: i), 1, Pos(line: p.line, col: j), 1)
  # innermost first: the one starting last
  found.sort(proc(x, y: (Pos, int, Pos, int)): int = cmp(y[0], x[0]))
  found

proc deleteSurrounding(b: Buffer, which = '\0'): bool =
  ## the pair around the cursor taken away (vim's ds: an opening bracket also takes the spaces inside)
  if not b.canEdit(): return false
  let ps = b.surroundingPairs(b.primary.head, which)
  if ps.len == 0:
    info("No pair around the cursor" & (if which != '\0': " (" & $which & ")" else: ""))
    return false
  let (oa, ol, ca, cl) = ps[0]
  var openEnd = Pos(line: oa.line, col: oa.col + ol)
  var closeStart = ca
  if which in {'(', '[', '{'}:
    while openEnd.col < b.lines[openEnd.line].len and b.lines[openEnd.line][openEnd.col] == ' ': inc openEnd.col
    while closeStart.col > 0 and b.lines[closeStart.line][closeStart.col - 1] == ' ': dec closeStart.col
  b.beginEdit()
  discard b.replaceText(closeStart, Pos(line: ca.line, col: ca.col + cl), "")
  discard b.replaceText(oa, openEnd, "")
  b.endEdit()
  b.setSingle(oa)
  true

proc changeSurrounding(b: Buffer, op, cl: string, which = '\0'): bool =
  ## the pair around the cursor replaced with op … cl
  if not b.canEdit(): return false
  let ps = b.surroundingPairs(b.primary.head, which)
  if ps.len == 0:
    info("No pair around the cursor" & (if which != '\0': " (" & $which & ")" else: ""))
    return false
  let (oa, ol, ca, ccl) = ps[0]
  var openEnd = Pos(line: oa.line, col: oa.col + ol)
  var closeStart = ca
  if which in {'(', '[', '{'}:
    while openEnd.col < b.lines[openEnd.line].len and b.lines[openEnd.line][openEnd.col] == ' ': inc openEnd.col
    while closeStart.col > 0 and b.lines[closeStart.line][closeStart.col - 1] == ' ': dec closeStart.col
  b.beginEdit()
  discard b.replaceText(closeStart, Pos(line: ca.line, col: ca.col + ccl), cl)
  discard b.replaceText(oa, openEnd, op)
  b.endEdit()
  b.setSingle(oa)
  true

proc surChangeAct(c: char): proc() {.closure.} =
  ## the action that changes the pair around the cursor to the pair that key c stands for
  result = proc() =
    let (op, cl) = surroundPair(c)
    discard buf().changeSurrounding(op, cl)

proc changeSurroundingToTag(which = '\0') =
  ## the pair around the cursor replaced with an element (its name asked)
  askText("Tag", "div", proc(t: string) =
    let (op, cl) = tagPair(t)
    discard buf().changeSurrounding(op, cl, which))

proc cmdChangeSurrounding() =
  ## Edit › Surround › Change the pair around…: a menu of the pairs (brackets, quotes, backticks, a tag) to turn the innermost pair
  ## around the cursor into; its title shows the opening text of the pair that is there now
  let b = buf()
  let ps = b.surroundingPairs(b.primary.head)
  if ps.len == 0:
    info("No pair around the cursor")
    return
  let (oa, ol, _, _) = ps[0]
  let was = b.lines[oa.line][oa.col ..< oa.col + ol]
  var items: seq[(string, string, proc() {.closure.})]
  for (lab, det, ch) in [("( … )", "parentheses", ')'), ("[ … ]", "square brackets", ']'), ("{ … }", "braces", '}'),
                         ("\" … \"", "double quotes", '"'), ("' … '", "single quotes", '\''),
                         ("` … `", "backticks", '`')]:
    items.add (lab, det, surChangeAct(ch))
  items.add ("<tag> … </tag>", "an element (you type its name)", proc() {.closure.} = changeSurroundingToTag())
  var search: seq[string]
  for it in items: search.add it[1]
  openActions("Change " & truncTo(was, 20) & " … to", items, search)

# Edit › Surround › Delete the pair around: takes away the innermost pair around the cursor
proc cmdDeleteSurrounding() = discard buf().deleteSurrounding()

proc vimSurroundChar(b: Buffer, ch: char, ranges: seq[(Pos, Pos)], lines = false) =
  ## vim: the character typed after ys{motion}, yss or S — t or < asks for a tag
  if ch in {'t', '<'}:
    b.cmdSurroundTag(ranges, lines)
    return
  let (op, cl) = surroundPair(ch)
  if op.len == 0: return
  if lines:
    let (a, e) = ranges[0]
    b.surroundLines(op.strip.replace("$", "\\$"), cl.strip.replace("$", "\\$"), a.line, e.line)
  else: b.surroundRanges(op, cl, ranges)
