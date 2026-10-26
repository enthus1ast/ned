## markdown-tools — Markdown: a table of contents, numbered lists, checkboxes, bold and links, anchors
##
##   Markdown: table of contents     at the cursor, between <!-- toc --> and <!-- tocstop -->; run where those are,
##                                   it updates the list (GitHub's anchors) — and so does saving (tocOnSave)
##   Markdown: renumber this list    the numbered list at the cursor: 1. 2. 3. …, each list inside it from its own
##                                   first number
##   Markdown: toggle the checkbox   - [ ] ⇄ - [x] on the cursor's line (on each selected line); a list item, or a
##                                   line, without a box gets one
##   Markdown: bold, … italic, … code, … strikethrough, … link
##                                   around the selection, else the word at the cursor — taken away when it is there
##                                   already. A link takes the address on the clipboard when there is one
##   completion                      the headings' anchors after ](# — and after ](other.md#, that file's
##   hover                           on a link to a heading (#anchor): the heading's line — or that none has it
##   keys, in Markdown files         Ctrl+Alt+B bold, Ctrl+Alt+E italic, Ctrl+Alt+K link, Ctrl+Alt+C the checkbox
##   vim, in Markdown files          <leader>mt the contents, <leader>mn renumber, <leader>mx the checkbox;
##                                   <leader>mb mi mc ms ml — bold, italic, code, strikethrough, link (the word, or in
##                                   visual mode the selection)
##   settings                        plugins.markdown-tools.tocOnSave, plugins.markdown-tools.tocLevels
import nedplugin
import std/tables
from std/unicode import nil

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("clipboard", "a link takes the address on the clipboard")

settingDef("tocOnSave", true, "Markdown: update the table of contents (between <!-- toc --> and <!-- tocstop -->) " &
           "when you save the file")
settingDef("tocLevels", "1..6", "Markdown: the heading levels the table of contents lists (\"2..3\": ## and ###). " &
           "A lone # heading at the top is the document's title and is left out")

# ── headings and their anchors ──

type Heading = object
  line, level: int
  text: string                   # as written (Markdown in it)
  anchor: string                 # GitHub's: #on-termux

func indentOf(l: string): int =
  while result < l.len and l[result] == ' ': inc result

func fenceOf(l: string): string =
  ## the fence a line opens or closes (``` or ~~~, as long as it is), "" for none
  let i = indentOf(l)
  if i > 3 or i >= l.len or l[i] notin {'`', '~'}: return ""
  var j = i
  while j < l.len and l[j] == l[i]: inc j
  if j - i >= 3: l[i ..< j] else: ""

func atx(l: string): (int, string) =
  ## a # heading: its level and its text (0 when the line is not one)
  let i = indentOf(l)
  if i > 3: return (0, "")
  var j = i
  while j < l.len and l[j] == '#': inc j
  let n = j - i
  if n < 1 or n > 6 or (j < l.len and l[j] notin {' ', '\t'}): return (0, "")
  var t = l[j .. ^1].strip
  # a closing run of #s goes (## Title ##)
  var e = t.len
  while e > 0 and t[e - 1] == '#': dec e
  if e < t.len and (e == 0 or t[e - 1] == ' '): t = t[0 ..< e].strip
  (n, t)

func isListItem(l: string): bool =
  let t = l.strip(trailing = false)
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ': return true
  var k = 0
  while k < t.len and t[k] in Digits: inc k
  k > 0 and k < t.len and t[k] in {'.', ')'}

func setextLevel(prev, l: string): int =
  ## 1 or 2 when l underlines prev (=== or ---) and makes it a heading
  let t = l.strip
  if t.len == 0 or indentOf(l) > 3 or prev.strip.len == 0 or indentOf(prev) > 3: return 0
  if not (t.allCharsInSet({'='}) or t.allCharsInSet({'-'})): return 0
  let p = prev.strip
  if p[0] in {'#', '>', '|', '<'} or isListItem(prev) or fenceOf(prev).len > 0: return 0
  if t[0] == '=': 1 else: 2

func dropHtml(s: string): string =
  ## the text without HTML comments and tags
  var i = 0
  while i < s.len:
    if s.continuesWith("<!--", i):
      let e = s.find("-->", i + 4)
      i = if e < 0: s.len else: e + 3
    elif s[i] == '<' and i + 1 < s.len and (s[i + 1] in Letters or s[i + 1] == '/'):
      let e = s.find('>', i)
      if e < 0:
        result.add s[i]
        inc i
      else: i = e + 1
    else:
      result.add s[i]
      inc i

func dropLinks(s: string): string =
  ## [text](address) and ![alt](address) as their text, [text][ref] too
  var i = 0
  while i < s.len:
    let img = s[i] == '!' and i + 1 < s.len and s[i + 1] == '['
    let a = if img: i + 1 else: i
    if a < s.len and s[a] == '[':
      let c = s.find(']', a + 1)
      if c > 0 and c + 1 < s.len and s[c + 1] in {'(', '['}:
        let close = if s[c + 1] == '(': ')' else: ']'
        let e = s.find(close, c + 2)
        if e > 0:
          result.add s[a + 1 ..< c]
          i = e + 1
          continue
    result.add s[i]
    inc i

func plainText(s: string): string =
  ## what GitHub shows of a heading: no links, tags, emphasis marks; code as it is
  let t = dropLinks(dropHtml(s))
  var i = 0
  while i < t.len:
    let c = t[i]
    if c == '`':
      var n = 0
      while i + n < t.len and t[i + n] == '`': inc n
      let e = t.find(repeat('`', n), i + n)
      if e > 0:
        result.add t[i + n ..< e].strip
        i = e + n
        continue
      result.add t[i ..< i + n]
      i += n
    elif c == '*' or (c == '~' and i + 1 < t.len and t[i + 1] == '~'):
      i += (if c == '~': 2 else: 1)
    elif c == '_':
      # emphasis (_x_, __x__) at a word's edge; one inside a word (snake_case) stays
      const Alnum = {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF'}
      let inWord = i > 0 and i + 1 < t.len and t[i - 1] in Alnum and t[i + 1] in Alnum
      if inWord: result.add c
      inc i
    elif c == '\\' and i + 1 < t.len and t[i + 1] in PunctuationChars:
      result.add t[i + 1]
      i += 2
    else:
      result.add c
      inc i

func keepRune(r: int): bool =
  ## a character GitHub keeps in an anchor (letters, digits, - and _, a space as -)
  if r < 0x80: return char(r) in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', ' '}
  if r <= 0xBF: return r in [0xAA, 0xB2, 0xB3, 0xB5, 0xB9, 0xBA]
  if r == 0xD7 or r == 0xF7: return false
  if r in 0x2000 .. 0x2BFF or r in 0x2E00 .. 0x2E7F or r in 0x3000 .. 0x303F or r in 0xFE00 .. 0xFE0F or
     r in 0x1F000 .. 0x1FAFF: return false
  true

func slug(text: string): string =
  ## GitHub's anchor for a heading's text (without the -1 of a second one)
  for r in unicode.runes(unicode.toLower(plainText(text).strip)):
    let n = int(r)
    if keepRune(n): result.add (if n == ord(' '): "-" else: unicode.toUTF8(r))

proc headings(lines: seq[string]): seq[Heading] =
  ## the document's headings (# and underlined ones; not in code or front matter), each with its anchor
  var fence = ""
  var i = 0
  if lines.len > 0 and lines[0].strip == "---":
    i = 1
    while i < lines.len and lines[i].strip notin ["---", "..."]: inc i
    inc i
  var seen = initTable[string, int]()      # (as GitHub counts them: a second "intro" is intro-1)
  proc anchorFor(t: string): string =
    let base = slug(t)
    result = base
    while result in seen:
      seen[base] = seen[base] + 1
      result = base & "-" & $seen[base]
    seen[result] = 0
  while i < lines.len:
    let l = lines[i]
    let f = fenceOf(l)
    if fence.len > 0:
      if f.len >= fence.len and f[0] == fence[0] and l.strip == f: fence = ""
    elif f.len > 0: fence = f
    else:
      let (n, t) = atx(l)
      let s = if n == 0 and i + 1 < lines.len: setextLevel(l, lines[i + 1]) else: 0
      if n > 0: result.add Heading(line: i, level: n, text: t, anchor: anchorFor(t))
      elif s > 0:
        result.add Heading(line: i, level: s, text: l.strip, anchor: anchorFor(l.strip))
        inc i
    inc i

# ── the table of contents ──

func markerOf(l: string): string =
  ## "toc", "tocstop" or "/toc" for a line that is such a comment (any case, any spaces)
  let t = l.strip
  if not (t.startsWith("<!--") and t.endsWith("-->")): return ""
  let w = t[4 ..< t.len - 3].strip.toLowerAscii
  if w in ["toc", "tocstop", "/toc"]: w else: ""

func levelRange(spec: string): (int, int) =
  let p = spec.split("..")
  try:
    if p.len == 2: (max(1, parseInt(p[0].strip)), min(6, parseInt(p[1].strip)))
    else: (max(1, parseInt(spec.strip)), min(6, parseInt(spec.strip)))
  except ValueError: (1, 6)

func tocItems(lines: seq[string], hs: seq[Heading], first, last, tocLine: int): seq[string] =
  ## the list: each heading as a link to its anchor, two spaces deeper a level
  var ones = 0
  for h in hs:
    if h.level == 1: inc ones
  var keep: seq[Heading]
  for k, h in hs:
    if h.level < first or h.level > last: continue
    if h.level == 1 and ones == 1 and k == 0: continue                 # (the title)
    if "omit from toc" in h.text.toLowerAscii or "omit in toc" in h.text.toLowerAscii: continue
    if tocLine >= 0 and h.line < tocLine:
      var only = true                                                  # (the heading of the contents themselves)
      for j in h.line + 1 ..< tocLine:
        if lines[j].strip.len > 0: only = false
      if only: continue
    keep.add h
  var top = 7
  for h in keep: top = min(top, h.level)
  for h in keep:
    let t = dropLinks(dropHtml(h.text)).strip
    result.add spaces(2 * (h.level - top)) & "- [" & t & "](#" & h.anchor & ")"

proc tocMarkers(lines: seq[string]): (int, int) =
  ## the lines of <!-- toc --> and <!-- tocstop --> (-1 when there are none)
  result = (-1, -1)
  for i, l in lines:
    let m = markerOf(l)
    if m == "toc" and result[0] < 0: result[0] = i
    elif m in ["tocstop", "/toc"] and result[0] >= 0:
      result[1] = i
      return
  result = (-1, -1)

proc updateToc(b: Buf, insert: bool): string =
  ## the contents put in (or updated): what happened, in a few words
  let lines = b.lines
  let hs = headings(lines)
  let (lo, hi) = levelRange(setting("tocLevels", "1..6"))
  let (a, e) = tocMarkers(lines)
  if a >= 0:
    let items = tocItems(lines, hs, lo, hi, a)
    let body = @[""] & items & @[""]
    if lines[a + 1 ..< e] == body: return "The table of contents is up to date"
    b.replace(rng(pos(a + 1, 0), pos(e, 0)), body.join("\n") & "\n")
    return "Table of contents: " & $items.len & " headings"
  if not insert: return ""
  let l = b.cursor.line
  let items = tocItems(lines, hs, lo, hi, l + (if lines[l].strip.len == 0: 0 else: 1))
  if items.len == 0: return "No headings for a table of contents"
  let blk = (@["<!-- toc -->", ""] & items & @["", "<!-- tocstop -->"]).join("\n")
  if lines[l].strip.len == 0: b.replace(b.lineRange(l), blk & "\n")       # (the blank line stays after it)
  else: b.insert(pos(l, lines[l].len), "\n\n" & blk)
  "Table of contents: " & $items.len & " headings"

func isMarkdown(path, lang: string): bool =
  lang == "markdown" or path.endsWith(".md") or path.endsWith(".markdown") or path.endsWith(".mdx")

proc toc(b: Buf) =
  if not isMarkdown(b.path, b.lang):
    message("Markdown: table of contents — this is not a Markdown file")
    return
  message(updateToc(b, true))

command "Markdown: table of contents":
  toc(current())

onBeforeSave("lang:markdown") do (ev: Event):
  if setting("tocOnSave", true): discard updateToc(ev.buf, false)

# ── lists ──

type Item = object
  indent: int                    # where its marker starts (-1: not a list item)
  ordered: bool
  num, numStop: int              # (a numbered one) its number, and where the number ends
  content: int                   # where its text starts

func itemOf(l: string): Item =
  result.indent = -1
  let i = indentOf(l)
  if i >= l.len: return
  if l[i] in {'-', '*', '+'} and (i + 1 == l.len or l[i + 1] == ' '):
    var c = i + 1
    while c < l.len and l[c] == ' ': inc c
    return Item(indent: i, content: c)
  var k = i
  while k < l.len and k - i < 9 and l[k] in Digits: inc k
  if k > i and k < l.len and l[k] in {'.', ')'} and (k + 1 == l.len or l[k + 1] == ' '):
    var c = k + 1
    while c < l.len and l[c] == ' ': inc c
    return Item(indent: i, ordered: true, num: parseInt(l[i ..< k]), numStop: k, content: c)

proc listBlock(lines: seq[string], at: int): (int, int) =
  ## the lines of the list the line `at` is in (-1 when it is in none)
  proc inList(i: int): bool =
    let l = lines[i]
    l.strip.len > 0 and (itemOf(l).indent >= 0 or indentOf(l) > 0)
  var a = at
  while a >= 0 and lines[a].strip.len == 0: dec a       # (a blank line: the list above it)
  if a < 0: return (-1, -1)
  # up to the first item: past items, lines under them, and blank lines with more of the list above
  var first = -1
  var i = a
  while i >= 0:
    let l = lines[i]
    if l.strip.len == 0:
      if i == 0 or not inList(i - 1): break
      dec i
      continue
    if itemOf(l).indent >= 0: first = i
    elif indentOf(l) == 0 and (i == 0 or lines[i - 1].strip.len == 0): break   # (a paragraph of its own)
    if atx(l)[0] > 0 or fenceOf(l).len > 0: break
    dec i
  if first < 0: return (-1, -1)
  var last = first
  i = first + 1
  while i < lines.len:
    let l = lines[i]
    if l.strip.len == 0:
      var j = i
      while j < lines.len and lines[j].strip.len == 0: inc j
      if j >= lines.len or j - i != 1 or not inList(j): break
      i = j
      continue
    if atx(l)[0] > 0 or fenceOf(l).len > 0 and indentOf(l) == 0: break
    last = i
    inc i
  if at > last + 1: return (-1, -1)
  (first, last)

proc renumber(b: Buf) =
  let lines = b.lines
  let (a, e) = listBlock(lines, b.cursor.line)
  var ordered = false
  if a >= 0:
    for i in a .. e:
      if itemOf(lines[i]).ordered: ordered = true
  if not ordered:
    message("Markdown: the cursor is not in a numbered list")
    return
  var levels: seq[(int, bool, int)]        # each list open here: its indent, numbered, its next number
  var changed = 0
  for i in a .. e:
    let l = lines[i]
    let it = itemOf(l)
    if it.indent < 0:
      # a line under an item: the lists deeper than it end
      if l.strip.len > 0:
        let ind = indentOf(l)
        while levels.len > 0 and levels[^1][0] > ind and levels.len > 1: discard levels.pop
      continue
    while levels.len > 0 and levels[^1][0] > it.indent: discard levels.pop
    if levels.len > 0 and levels[^1][0] == it.indent and levels[^1][1] == it.ordered:
      if it.ordered:
        let n = levels[^1][2]
        levels[^1][2] = n + 1
        if n != it.num:
          b.replace(rng(pos(i, it.indent), pos(i, it.numStop)), $n)
          inc changed
    else:
      if levels.len > 0 and levels[^1][0] == it.indent: discard levels.pop
      levels.add (it.indent, it.ordered, it.num + 1)
  message(if changed == 0: "The list is numbered already" else: "Renumbered " & $changed & " items")

command "Markdown: renumber this list":
  renumber(current())

func toggledBox(l: string): string =
  ## the line with its box ticked, or not; a box added when it has none
  let it = itemOf(l)
  if it.indent < 0:
    let i = indentOf(l)
    return l[0 ..< i] & "- [ ] " & l[i .. ^1]
  let c = it.content
  let rest = l[c .. ^1]
  if rest.startsWith("[ ]"): l[0 ..< c] & "[x]" & rest[3 .. ^1]
  elif rest.startsWith("[x]") or rest.startsWith("[X]"): l[0 ..< c] & "[ ]" & rest[3 .. ^1]
  elif c == l.len and (c == 0 or l[c - 1] != ' '): l & " [ ] "
  else: l[0 ..< c] & "[ ] " & rest

proc toggleBox(b: Buf) =
  let s = b.selection
  var first = s.start.line
  var last = s.stop.line
  if last > first and s.stop.col == 0: dec last
  let lines = b.lines(first, last)
  for i, l in lines:
    let t = toggledBox(l)
    if t != l: b.replace(rng(pos(first + i, 0), pos(first + i, l.len)), t)
  if first == last:
    let p = b.cursor
    let grow = toggledBox(lines[0]).len - lines[0].len
    if p.col >= itemOf(lines[0]).content or lines[0].strip.len == 0: b.setCursor(pos(p.line, max(0, p.col + grow)))

command "Markdown: toggle the checkbox":
  toggleBox(current())

# ── bold, italic, code, strikethrough, links ──

func wordBounds(l: string, c: int): (int, int) =
  ## the word around column c (letters, digits, _ - '), empty when there is none
  proc w(ch: char): bool = ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '\''} or ch.uint8 >= 0x80
  var a = min(c, l.len)
  var e = a
  while a > 0 and w(l[a - 1]): dec a
  while e < l.len and w(l[e]): inc e
  (a, e)

func marks(m: string): seq[string] =
  ## the marks that mean the same (bold: ** or __)
  case m
  of "**": @["**", "__"]
  of "*": @["*", "_"]
  else: @[m]

func wrappedIn(t, m: string): bool =
  ## t starts and ends with the mark m (and, for one * or _, not with two of them unless three)
  if t.len < 2 * m.len or not (t.startsWith(m) and t.endsWith(m)): return false
  if m.len == 1 and m[0] in {'*', '_'}:
    let two = m & m
    if (t.startsWith(two) and not t.startsWith(two & m)) or (t.endsWith(two) and not t.endsWith(two & m)): return false
  true

func around(before, after, m: string): bool =
  ## the text between before and after has the mark m on both sides
  if not (before.endsWith(m) and after.startsWith(m)): return false
  if m.len == 1 and m[0] in {'*', '_'}:
    let two = m & m
    if (before.endsWith(two) and not before.endsWith(two & m)) or
       (after.startsWith(two) and not after.startsWith(two & m)): return false
  true

func linkAt(l: string, col: int): (int, int, int) =
  ## the link [text](target) around col: where its [, its ]( and its ) are (-1 when there is none)
  var k = l.find("](")
  while k >= 0:
    let e = l.find(')', k + 2)
    let a = l.rfind('[', last = k)
    if a >= 0 and e > 0 and col >= a and col <= e: return (a, k, e)
    k = if e > 0: l.find("](", e) else: -1
  (-1, -1, -1)

func looksLikeUrl(s: string): bool =
  let t = s.strip
  t.len > 0 and ' ' notin t and '\n' notin t and
    (t.startsWith("http://") or t.startsWith("https://") or t.startsWith("mailto:") or t.startsWith("./") or
     t.startsWith("../") or t.startsWith("#"))

proc styled(b: Buf, m: string, visual: bool) =
  ## the selection (else the word at the cursor) between the marks m — or without them when it has them
  var s = b.selection
  let p = b.cursor
  if s.isEmpty:
    let l = b.line(p.line)
    let (a, e) = wordBounds(l, p.col)
    if a == e:
      b.insert(p, m & m)
      b.setCursor(pos(p.line, p.col + m.len))
      return
    s = rng(pos(p.line, a), pos(p.line, e))
  let t = b.textIn(s)
  let before = b.line(s.start.line)[0 ..< s.start.col]
  let after = b.line(s.stop.line)[s.stop.col .. ^1]
  let sameLine = s.start.line == s.stop.line
  proc done(r: Range) =
    if visual: b.select(r)
    else: b.setCursor(r.start)
  for k in marks(m):
    if wrappedIn(t, k):
      b.replace(s, t[k.len ..< t.len - k.len])
      done(rng(s.start, pos(s.stop.line, s.stop.col - (if sameLine: 2 * k.len else: k.len))))
      return
    if around(before, after, k):
      let r = rng(pos(s.start.line, s.start.col - k.len), pos(s.stop.line, s.stop.col + k.len))
      b.replace(r, t)
      done(rng(r.start, pos(s.stop.line, s.stop.col - (if sameLine: k.len else: 0))))
      return
  b.replace(s, m & t & m)
  done(rng(pos(s.start.line, s.start.col + m.len), pos(s.stop.line, s.stop.col + (if sameLine: m.len else: 0))))

proc linked(b: Buf, visual: bool) =
  ## the selection (else the word) as a link — to the address on the clipboard, else with the cursor where the
  ## address goes; a link's text again when it is one
  var s = b.selection
  let p = b.cursor
  let l0 = b.line(p.line)
  if s.isEmpty:
    # on a link already: its text
    let (k, c, e) = linkAt(l0, p.col)
    if k >= 0:
      b.replace(rng(pos(p.line, k), pos(p.line, e + 1)), l0[k + 1 ..< c])
      b.setCursor(pos(p.line, k))
      return
    let (wa, we) = wordBounds(l0, p.col)
    s = rng(pos(p.line, wa), pos(p.line, we))
  let t = b.textIn(s)
  let clip = clipboard()
  let url = if looksLikeUrl(clip): clip.strip else: ""
  b.replace(s, "[" & t & "](" & url & ")")
  let close = s.stop.col + (if s.start.line == s.stop.line: 3 else: 2)
  if url.len == 0: b.setCursor(pos(s.stop.line, close))
  elif visual: b.select(rng(pos(s.start.line, s.start.col + 1), pos(s.stop.line, close - 2)))
  else: b.setCursor(pos(s.stop.line, close + url.len + 1))

command "Markdown: bold": styled(current(), "**", true)
command "Markdown: italic": styled(current(), "*", true)
command "Markdown: code": styled(current(), "`", true)
command "Markdown: strikethrough": styled(current(), "~~", true)
command "Markdown: link": linked(current(), true)

keyIn("markdown", "ctrl+alt+b", "bold") do (b: Buf): styled(b, "**", true)
keyIn("markdown", "ctrl+alt+e", "italic") do (b: Buf): styled(b, "*", true)
keyIn("markdown", "ctrl+alt+k", "link") do (b: Buf): linked(b, true)
keyIn("markdown", "ctrl+alt+c", "toggle the checkbox") do (b: Buf): toggleBox(b)

# vim: in Markdown files
nmapIn("markdown", "<leader>mt", "table of contents") do (count: int): toc(current())
nmapIn("markdown", "<leader>mn", "renumber the list") do (count: int): renumber(current())
nmapIn("markdown", "<leader>mx", "toggle the checkbox") do (count: int): toggleBox(current())
nmapIn("markdown", "<leader>mb", "bold") do (count: int): styled(current(), "**", false)
nmapIn("markdown", "<leader>mi", "italic") do (count: int): styled(current(), "*", false)
nmapIn("markdown", "<leader>mc", "code") do (count: int): styled(current(), "`", false)
nmapIn("markdown", "<leader>ms", "strikethrough") do (count: int): styled(current(), "~~", false)
nmapIn("markdown", "<leader>ml", "link") do (count: int): linked(current(), false)

vmapIn("markdown", "<leader>mb", "bold") do (count: int): styled(current(), "**", true)
vmapIn("markdown", "<leader>mi", "italic") do (count: int): styled(current(), "*", true)
vmapIn("markdown", "<leader>mc", "code") do (count: int): styled(current(), "`", true)
vmapIn("markdown", "<leader>ms", "strikethrough") do (count: int): styled(current(), "~~", true)
vmapIn("markdown", "<leader>ml", "link") do (count: int): linked(current(), true)

# ── anchors: completion after ](#, hover on a link ──

proc fileHeadings(b: Buf, target: string): (string, seq[Heading]) =
  ## the headings a link's file part names: this file's ("" before #), else that file's (from this one's folder)
  if target.len == 0: return ("", headings(b.lines))
  let base = b.path.parentDir
  let p = if target.isAbsolute: target else: (if base.len > 0: base / target else: projectRoot() / target)
  if not fileExists(p): return (target, @[])
  (target, headings(readFile(p).splitLines))

func fuzzy(typed, s: string): bool =
  ## the letters typed are in s, in that order
  var k = 0
  for c in s:
    if k < typed.len and c.toLowerAscii == typed[k]: inc k
  k == typed.len

completions("markdown") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  let upto = l[0 ..< min(p.col, l.len)]
  let k = upto.rfind("](")
  if k < 0: return
  let target = upto[k + 2 .. ^1]
  let h = target.find('#')
  if h < 0 or ' ' in target or ')' in target: return
  # (ned puts the item in place of the word typed: the part of the anchor before it stays)
  let frag = target[h + 1 .. ^1]
  var w = frag.len
  while w > 0 and (frag[w - 1] in IdentChars or frag[w - 1].uint8 >= 0x80): dec w
  let before = frag[0 ..< w]
  let typed = frag[w .. ^1].toLowerAscii
  let (file, hs) = fileHeadings(b, target[0 ..< h])
  for x in hs:
    if x.anchor.startsWith(before) and fuzzy(typed, x.anchor[before.len .. ^1]):
      result.add CompletionItem(label: x.anchor, insert: x.anchor[before.len .. ^1], kind: "value",
                                detail: repeat('#', x.level) & " " & plainText(x.text),
                                doc: (if file.len > 0: file & ", " else: "") & "line " & $(x.line + 1))

hover("markdown") do (b: Buf, p: Pos) -> string:
  # on a link to a heading: that heading's line (or that no heading has the anchor)
  let l = b.line(p.line)
  let (a, k, e) = linkAt(l, p.col)
  if a < 0: return ""
  let target = l[k + 2 ..< e].strip
  let h = target.find('#')
  if h < 0 or "://" in target: return ""
  let anchor = target[h + 1 .. ^1]
  let (file, hs) = fileHeadings(b, target[0 ..< h])
  let where = if file.len > 0: file & ", " else: ""
  for x in hs:
    if x.anchor == anchor:
      return "**" & where & "line " & $(x.line + 1) & "** · `" & repeat('#', x.level) & " " & x.text & "`"
  "No heading " & (if file.len > 0: "of " & file & " " else: "") & "has the anchor `#" & anchor & "`"
