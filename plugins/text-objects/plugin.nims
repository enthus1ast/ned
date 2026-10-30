## text-objects — more of vim's text objects: an argument, an indentation level, any quotes, a line, a part of a name …
##
## For vim mode: after an operator (d c y > < gu gU, and the plugins' — gc, ga, cx …) or in visual mode. ned's vim
## has iw aw, i( a( ib ab, i[ a[, i{ a{ iB aB, i< a<, i" a", i' a', i` a`, ip ap; these are the ones it lacks:
##
##   ia aa     an argument, in any brackets ( [ { (and Nim's {. .}) — over several lines too; aa takes one comma with
##             it (the one after, or for the last argument the one before), so daa leaves a list that is still right
##   ii ai aI  an indentation level, as whole lines: the lines indented as much as the cursor's or more (blank
##             lines inside them too); ai with the line above (the if, the proc), aI with the line below too (a
##             closing }); iI is ii. At the top level: the paragraph. dii deletes the lines, cii keeps the
##             indentation, vii is visual-line
##   iq aq     the nearest quotes of any kind (" ' `) on the line: around the cursor, else the next ones, else the
##             ones before
##   il al     the line: il without the indentation and the spaces at the end, al the whole line
##   ie ae     the whole text, as lines: ie without the blank lines at the start and the end
##   i_ a_     a part of a name: between underscores (snake_case) or one hump of camelCase; a_ takes one _ with it
##
## Examples: cia (write an argument again), daa, yii, >ii, vaI, ciq, gUi_, yae (copy everything).
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

const CharLitLangs = ["nim", "c", "cpp", "rust", "go", "java", "csharp", "kotlin", "zig", "odin", "haskell", "elixir",
                      "gleam", "scala", "swift", "dart"]

# whether the byte can be part of a name: a letter, digit or `_`, or part of a non-ASCII character
func isIdent(c: char): bool = c in IdentChars or ord(c) >= 128
# whether the line is empty or only spaces
func isBlank(s: string): bool = s.strip.len == 0

func runeLenAt(t: string, i: int): int =
  ## how many bytes the UTF-8 character that starts at byte `i` takes (1 past the end of the text), read from its first
  ## byte
  if i >= t.len: 1
  elif ord(t[i]) < 0xC0: 1
  elif ord(t[i]) < 0xE0: 2
  elif ord(t[i]) < 0xF0: 3
  else: 4

# ── arguments: the text around the cursor, what is code in it, its brackets ──

type Scan = object
  first: int                     ## the line the text starts at
  t: string                      ## the lines, joined with \n
  kinds: string                  ## each byte: c code, s a string (its quotes too), m a comment
  starts: seq[int]               ## where each line starts in t
  lang: string

func scanKinds(t, lang, cm: string): string =
  ## which bytes of t are code: strings ("…", `…`, '…' — in Nim, C, Rust … only a character: 'a', '\n'),
  ## Nim's and Python's """…""", line comments, /* … */ and #[ … ]#
  result = newString(t.len)
  let charLit = lang in CharLitLangs
  let triple = lang in ["nim", "python"]
  let (bo, bc) = if cm == "//": ("/*", "*/") elif lang == "nim": ("#[", "]#") else: ("", "")
  var i = 0
  template fill(a, e: int, k: char) =
    ## marks the bytes from `a` up to `e` of the result with the kind `k`
    for x in a ..< e: result[x] = k
  while i < t.len:
    let c = t[i]
    if bo.len > 0 and t.continuesWith(bo, i):
      let j = t.find(bc, i + bo.len)
      let e = if j < 0: t.len else: j + bc.len
      fill(i, e, 'm')
      i = e
    elif cm.len > 0 and t.continuesWith(cm, i):
      let j = t.find('\n', i)
      let e = if j < 0: t.len else: j
      fill(i, e, 'm')
      i = e
    elif triple and (t.continuesWith("\"\"\"", i) or (lang == "python" and t.continuesWith("'''", i))):
      let j = t.find(t[i ..< i + 3], i + 3)
      let e = if j < 0: t.len else: j + 3
      fill(i, e, 's')
      i = e
    elif c == '"' or c == '`' or (c == '\'' and not charLit):
      var j = i + 1
      while j < t.len and t[j] != c and (t[j] != '\n' or c == '`'):
        if t[j] == '\\' and c != '`' and j + 1 < t.len and t[j + 1] != '\n': inc j
        inc j
      let e = if j < t.len and t[j] == c: j + 1 else: j
      fill(i, e, 's')
      i = e
    elif c == '\'':
      var j = i + 1
      if j < t.len and t[j] == '\\':
        j += 2
        while j < t.len and t[j] notin {'\'', '\n'} and j - i < 12: inc j
      else: j += runeLenAt(t, j)
      if j < t.len and t[j] == '\'':
        fill(i, j + 1, 's')
        i = j + 1
      else:
        result[i] = 'c'
        inc i
    else:
      result[i] = 'c'
      inc i

proc scanAround(b: Buf, line: int): Scan =
  ## the 200 lines before and after the line, scanned
  result.first = max(0, line - 200)
  let ls = b.lines(result.first, min(b.lineCount - 1, line + 200))
  result.t = ls.join("\n")
  var k = 0
  for l in ls:
    result.starts.add k
    k += l.len + 1
  result.lang = b.lang
  result.kinds = scanKinds(result.t, result.lang, b.lineComment)

# the position in the buffer as an offset in the scanned text
func offsetOf(sc: Scan, p: Pos): int = sc.starts[p.line - sc.first] + p.col

func posOf(sc: Scan, i: int): Pos =
  ## the buffer position (line and column) of the offset `i` in the scanned text — the last line that starts at or
  ## before it
  var l = sc.starts.high
  while l > 0 and sc.starts[l] > i: dec l
  pos(sc.first + l, i - sc.starts[l])

func enclosing(sc: Scan, at: int): (int, int) =
  ## the innermost ( [ { around the offset (on a bracket: that one) and where it closes; (-1, -1) none
  var st: seq[int]
  result = (-1, -1)
  for i in 0 ..< sc.t.len:
    if sc.kinds[i] != 'c': continue
    let c = sc.t[i]
    if c in {'(', '[', '{'}: st.add i
    elif c in {')', ']', '}'}:
      let want = (case c
        of ')': '('
        of ']': '['
        else: '{')
      var k = st.high
      while k >= 0 and sc.t[st[k]] != want: dec k
      if k >= 0:
        let o = st[k]
        st.setLen(k)
        if o <= at and at <= i and o > result[0]: result = (o, i)

proc argument(b: Buf, p: Pos, around: bool): Range =
  ## the range of the argument at the cursor in the innermost brackets around it (Nim's {. .} too), split at the commas
  ## that are not in strings, comments or inner brackets; with `around` the comma that goes with it is included (the one
  ## after, else the one before). An empty range when there are no brackets or no arguments
  let sc = scanAround(b, p.line)
  let at = min(sc.offsetOf(p), max(0, sc.t.len - 1))
  let (o, c) = sc.enclosing(at)
  if o < 0: return noRange()
  # the arguments: (start, end) without the spaces round them; seps: where each one's comma is (-1: none)
  var args: seq[(int, int)]
  var seps: seq[int]
  var depth = 0
  # (what is between the brackets — Nim's pragma braces are {. and .})
  let pragma = sc.lang == "nim" and sc.t[o] == '{' and c - o >= 3 and sc.t[o + 1] == '.' and sc.t[c - 1] == '.'
  let (a0, e0) = if pragma: (o + 2, c - 1) else: (o + 1, c)
  var a = a0
  proc addArg(x0, y0, sep: int) =
    ## adds the argument that spans `x0` up to `y0`, with the spaces round it left out, and where its comma is (-1:
    ## none)
    var (x, y) = (x0, y0)
    while x < y and sc.t[x] in Whitespace: inc x
    while y > x and sc.t[y - 1] in Whitespace: dec y
    args.add (x, y)
    seps.add sep
  for i in a0 ..< e0:
    if sc.kinds[i] != 'c': continue
    let ch = sc.t[i]
    if ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif depth == 0 and ch == ',':
      addArg(a, i, i)
      a = i + 1
  addArg(a, e0, -1)
  if args.len > 1 and args[^1][0] == args[^1][1]:       # (a comma after the last one)
    args.setLen(args.len - 1)
  if args.len == 0 or (args.len == 1 and args[0][0] == args[0][1]): return noRange()
  # the one at the cursor: up to its comma (on the comma: the one before it); on the closing bracket: the last
  var k = 0
  while k < args.high and seps[k] >= 0 and at > seps[k]: inc k
  if at >= e0: k = args.high
  var (x, y) = args[k]
  if around:
    if k < args.high: y = args[k + 1][0]                 # its comma, and the spaces up to the next one
    elif k > 0: x = args[k - 1][1]                       # the last one: the comma before it
    elif seps[k] >= 0: y = seps[k] + 1                   # the only one: its comma after it, if it has one
  rng(sc.posOf(x), sc.posOf(y))

textObject("ia", "an argument") do (b: Buf, p: Pos) -> Range: argument(b, p, false)
textObject("aa", "an argument and its comma") do (b: Buf, p: Pos) -> Range: argument(b, p, true)

# ── lines: an indentation level, the line, the whole text ──

func indentOf(s: string): int =
  ## the width of the line's indentation, a tab counting four columns
  for c in s:
    if c == ' ': inc result
    elif c == '\t': result += 4
    else: break

func firstCol(s: string): int =
  ## the column of the line's first character that is not a space or a tab
  while result < s.len and s[result] in {' ', '\t'}: inc result

proc window(b: Buf, p: Pos): (int, seq[string], int) =
  ## the 2000 lines before and after the cursor's (the first one's number, the lines, how many the file has)
  let n = b.lineCount
  let first = max(0, p.line - 2000)
  (first, b.lines(first, min(n - 1, p.line + 2000)), n)

func wholeLines(first, last, lastLen, lineCount: int): Range =
  ## lines first .. last as whole lines: up to the next line's start (ned's operators and visual mode take that as
  ## lines), or to the end of the file's last line
  if last + 1 < lineCount: rng(pos(first, 0), pos(last + 1, 0)) else: rng(pos(first, 0), pos(last, lastLen))

proc indentLevel(b: Buf, p: Pos, above, below: bool): Range =
  ## the whole lines round the cursor that are indented as much as its line or more, blank lines inside them too (on a
  ## blank line: the level of the next line with text). At the top level it is the paragraph. `above` adds the line
  ## above the block (the if, the proc), `below` the line below too when it is indented less (the closing bracket)
  let (first, ls, total) = window(b, p)
  let n = ls.len
  let l0 = p.line - first
  var r = l0                     # (on a blank line: the level of the next line with text, else the one before)
  while r < n and ls[r].isBlank: inc r
  if r >= n:
    r = l0
    while r >= 0 and ls[r].isBlank: dec r
  if r < 0: return noRange()
  let lvl = indentOf(ls[r])
  var (a, e) = (r, r)
  if lvl == 0:
    while a > 0 and not ls[a - 1].isBlank: dec a
    while e + 1 < n and not ls[e + 1].isBlank: inc e
  else:
    while a > 0 and (ls[a - 1].isBlank or indentOf(ls[a - 1]) >= lvl): dec a
    while e + 1 < n and (ls[e + 1].isBlank or indentOf(ls[e + 1]) >= lvl): inc e
    while ls[a].isBlank: inc a
    while ls[e].isBlank: dec e
    if above:
      var k = a - 1
      while k >= 0 and ls[k].isBlank: dec k
      if k >= 0: a = k
    if below:
      var k = e + 1
      while k < n and ls[k].isBlank: inc k
      if k < n and indentOf(ls[k]) < lvl: e = k
  wholeLines(first + a, first + e, ls[e].len, total)

textObject("ii", "an indentation level") do (b: Buf, p: Pos) -> Range: indentLevel(b, p, false, false)
textObject("iI", "an indentation level") do (b: Buf, p: Pos) -> Range: indentLevel(b, p, false, false)
textObject("ai", "an indentation level and the line above") do (b: Buf, p: Pos) -> Range: indentLevel(b, p, true, false)
textObject("aI", "an indentation level and the lines above and below") do (b: Buf, p: Pos) -> Range:
  indentLevel(b, p, true, true)

textObject("il", "the line without its indentation") do (b: Buf, p: Pos) -> Range:
  let s = b.line(p.line)
  if s.isBlank: return noRange()
  rng(pos(p.line, firstCol(s)), pos(p.line, s.strip(leading = false).len))

textObject("al", "the whole line") do (b: Buf, p: Pos) -> Range:
  let s = b.line(p.line)
  if s.len == 0: return noRange()
  rng(pos(p.line, 0), pos(p.line, s.len))

proc entire(b: Buf, inner: bool): Range =
  ## the whole text as lines; `inner` leaves out the blank lines at its start and its end
  let ls = b.lines
  var (a, e) = (0, ls.high)
  if inner:
    while a < e and ls[a].isBlank: inc a
    while e > a and ls[e].isBlank: dec e
  wholeLines(a, e, ls[e].len, ls.len)

textObject("ie", "the whole text without blank lines round it") do (b: Buf, p: Pos) -> Range: entire(b, true)
textObject("ae", "the whole text") do (b: Buf, p: Pos) -> Range: entire(b, false)

# ── on the line: quotes, a part of a name ──

proc quotes(b: Buf, p: Pos, around: bool): Range =
  ## the quoted texts of the line, paired from its start (an escaped quote does not end one; a ' with no pair,
  ## as in don't, is no quote; in Nim, C, Rust … a ' is a character: 'a'): the one around the cursor, else the next
  let s = b.line(p.line)
  let charLit = b.lang in CharLitLangs
  var spans: seq[(int, int)]
  var i = 0
  while i < s.len:
    let q = s[i]
    if q in {'"', '\'', '`'}:
      var j = i + 1
      while j < s.len and s[j] != q:
        if s[j] == '\\' and q != '`': inc j
        inc j
      if j < s.len and (q != '\'' or not charLit or j - i <= 3 or (s[i + 1] == '\\' and j - i <= 12)):
        spans.add (i, j)
        i = j + 1
        continue
    inc i
  var k = -1
  for x, sp in spans:
    if sp[0] <= p.col and p.col <= sp[1]: k = x
  if k < 0:
    for x, sp in spans:
      if sp[0] > p.col:
        k = x
        break
  if k < 0: k = spans.high
  if k < 0: return noRange()
  let (a, e) = spans[k]
  if around: rng(pos(p.line, a), pos(p.line, e + 1)) else: rng(pos(p.line, a + 1), pos(p.line, e))

textObject("iq", "inside the nearest quotes") do (b: Buf, p: Pos) -> Range: quotes(b, p, false)
textObject("aq", "the nearest quotes") do (b: Buf, p: Pos) -> Range: quotes(b, p, true)

proc namePart(b: Buf, p: Pos, around: bool): Range =
  ## the part of the name at the cursor: snake_case's words, camelCase's humps (HTTPServer: HTTP, Server)
  let s = b.line(p.line)
  var c = min(p.col, s.len - 1)
  if c < 0 or not isIdent(s[c]): return noRange()
  var a = c
  while a > 0 and isIdent(s[a - 1]): dec a
  var e = c
  while e < s.len and isIdent(s[e]): inc e
  var parts: seq[(int, int)]
  var i = a
  while i < e:
    if s[i] == '_':
      inc i
      continue
    var j = i + 1
    while j < e and s[j] != '_':
      let (pc, ch) = (s[j - 1], s[j])
      if ch in {'A' .. 'Z'} and (pc in {'a' .. 'z', '0' .. '9'} or
         (pc in {'A' .. 'Z'} and j + 1 < e and s[j + 1] in {'a' .. 'z'})): break
      inc j
    parts.add (i, j)
    i = j
  if parts.len == 0: return noRange()
  var k = parts.high
  for x, pt in parts:
    if c < pt[1]:
      k = x
      break
  var (x, y) = parts[k]
  if around:
    if y < e and s[y] == '_': inc y
    elif x > a and s[x - 1] == '_': dec x
  rng(pos(p.line, x), pos(p.line, y))

textObject("i_", "a part of a name (snake_case, camelCase)") do (b: Buf, p: Pos) -> Range: namePart(b, p, false)
textObject("a_", "a part of a name and its _") do (b: Buf, p: Pos) -> Range: namePart(b, p, true)
