## split-join — put the list in the brackets at the cursor one item a line, or back on one line
##
##   Split/join: toggle the list at the cursor   the innermost ( ) [ ] { } around the cursor, or the one right after
##                     the name it is on (foo in foo(a, b)) — call arguments, a parameter list, @[…] and seq literals,
##                     tables, dicts, objects — split when it is on one line, joined when it is on several
##   Split/join: split the list at the cursor · Split/join: join the list at the cursor
##   split             one item a line, one indentation unit deeper than the line, the closing bracket on a line of
##                     its own: f(a, b) → f( ⏎ a, ⏎ b, ⏎ ) — a comma after the last item in Nim, Python, Rust,
##                     JavaScript, TypeScript, Go, Kotlin, Zig, Odin and Gleam; none in JSON and C; elsewhere as
##                     the list had it. Commas in strings, comments and inner brackets are not the list's
##   join              the items back on one line, f(a, b) — inner lists that were split are joined too; (a,) keeps
##                     its comma (a tuple); a list with comments in it stays split (they would end up inside the line)
##   not lists         Nim's pragmas {.inline, raises: [].} are one ({. and .} kept); brackets that hold statements —
##                     a ; (for (i = 0; …), { a(); }) or a { } block over several lines — are left as they are
##   vim               gS split · gJ join (on no list split over lines, gJ joins lines as before)
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

const
  CommaLangs = ["nim", "python", "rust", "javascript", "typescript", "javascriptreact", "typescriptreact", "go",
                "kotlin", "zig", "odin", "gleam", "dart"]
  NoCommaLangs = ["json", "jsonc", "c", "cpp", "objc", "csharp", "java", "css", "sql"]
  CharLitLangs = ["nim", "c", "cpp", "rust", "go", "java", "csharp", "kotlin", "zig", "odin", "haskell", "elixir",
                  "gleam", "scala", "swift", "dart"]
  SpacedBraceLangs = ["javascript", "typescript", "javascriptreact", "typescriptreact", "rust"]

# ── the text around the cursor: what is code, what is a string or a comment ──

type Scan = object
  first: int                     ## the line the text starts at
  t: string                      ## the lines, joined with \n
  kinds: string                  ## each byte: c code, s a string (its quotes too), m a comment
  starts: seq[int]               ## where each line starts in t
  pairs: seq[(int, int)]         ## the brackets ( [ { and where they close (offsets in t)
  lang: string

func runeLenAt(t: string, i: int): int =
  ## how many bytes the UTF-8 character that starts at byte `i` takes (1 past the end of the text), read from its first
  ## byte
  if i >= t.len: 1
  elif ord(t[i]) < 0xC0: 1
  elif ord(t[i]) < 0xE0: 2
  elif ord(t[i]) < 0xF0: 3
  else: 4

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

func bracketPairs(t, kinds: string): seq[(int, int)] =
  ## every ( [ { of the code (not of strings and comments) with the offset of the bracket that closes it, found with a
  ## stack; a closing bracket with no matching opener is skipped, and an opener left over has no pair
  var st: seq[int]
  for i in 0 ..< t.len:
    if kinds[i] != 'c': continue
    case t[i]
    of '(', '[', '{': st.add i
    of ')', ']', '}':
      let want = (case t[i]
        of ')': '('
        of ']': '['
        else: '{')
      var k = st.high
      while k >= 0 and t[st[k]] != want: dec k
      if k >= 0:
        result.add (st[k], i)
        st.setLen(k)
    else: discard

proc scanAround(b: Buf, line: int): Scan =
  ## the 300 lines before and after the line, scanned
  let n = b.lineCount
  result.first = max(0, line - 300)
  let ls = b.lines(result.first, min(n - 1, line + 300))
  result.t = ls.join("\n")
  var k = 0
  for l in ls:
    result.starts.add k
    k += l.len + 1
  result.lang = b.lang
  result.kinds = scanKinds(result.t, result.lang, b.lineComment)
  result.pairs = bracketPairs(result.t, result.kinds)

# the position in the buffer as an offset in the scanned text
func offsetOf(sc: Scan, p: Pos): int = sc.starts[p.line - sc.first] + p.col

func posOf(sc: Scan, i: int): Pos =
  ## the buffer position (line and column) of the offset `i` in the scanned text — the last line that starts at or
  ## before it
  var l = sc.starts.high
  while l > 0 and sc.starts[l] > i: dec l
  pos(sc.first + l, i - sc.starts[l])

# whether the bracket pair has a line end between its brackets
func multiLine(sc: Scan, pr: (int, int)): bool = '\n' in sc.t[pr[0] ..< pr[1]]

func around(sc: Scan, at: int, want: int): int =
  ## the innermost pair around the offset (the brackets themselves count) — or the one right after the name the
  ## offset is on (foo in foo(a, b)); want 0 any, 1 one on a line, 2 one over several lines; -1 none
  result = -1
  var j = at
  while j < sc.t.len and sc.kinds[j] == 'c' and sc.t[j] in IdentChars: inc j
  if j > at and j < sc.t.len and sc.t[j] in {'(', '[', '{'} and sc.kinds[j] == 'c':
    for k, pr in sc.pairs:
      if pr[0] == j and (want == 0 or (want == 2) == sc.multiLine(pr)): return k
  for k, pr in sc.pairs:
    if pr[0] <= at and at <= pr[1] and (want == 0 or (want == 2) == sc.multiLine(pr)) and
       (result < 0 or pr[0] > sc.pairs[result][0]):
      result = k

func ends(sc: Scan, pr: (int, int)): (string, string) =
  ## the brackets as they are written: ( ) [ ] { } — or Nim's pragma braces {. .}
  if sc.lang == "nim" and sc.t[pr[0]] == '{' and pr[1] - pr[0] >= 3 and sc.t[pr[0] + 1] == '.' and
     sc.t[pr[1] - 1] == '.': ("{.", ".}")
  else: ($sc.t[pr[0]], $sc.t[pr[1]])

func inside(sc: Scan, pr: (int, int)): (int, int) =
  ## where what is between the brackets starts and ends
  let (o, c) = sc.ends(pr)
  (pr[0] + o.len, pr[1] - c.len + 1)

type Item = object
  a, e: int                      ## its text (offsets in the scan), spaces and line ends round it left out
  sep: char                      ## what comes after it: , ; or nothing

proc listItems(sc: Scan, pr: (int, int)): seq[Item] =
  ## the list's items: split at its own commas (and at ; in Nim: a parameter list), not at those in strings,
  ## comments or inner brackets; an empty last item (a comma after the last one) is left out
  var depth = 0
  let (a0, e0) = sc.inside(pr)
  var a = a0
  proc addItem(r: var seq[Item], a, e: int, sep: char) =
    ## adds the item that spans `a` up to `e`, with the spaces and line ends round it left out and `sep` as what follows
    ## it
    var (x, y) = (a, e)
    while x < y and sc.t[x] in Whitespace: inc x
    while y > x and sc.t[y - 1] in Whitespace: dec y
    r.add Item(a: x, e: y, sep: sep)
  for i in a0 ..< e0:
    if sc.kinds[i] != 'c': continue
    let c = sc.t[i]
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif depth == 0 and (c == ',' or (c == ';' and sc.lang == "nim")):
      addItem(result, a, i, c)
      a = i + 1
  addItem(result, a, e0, '\0')
  if result.len > 0 and result[^1].a == result[^1].e: result.setLen(result.len - 1)

func statements(sc: Scan, pr: (int, int), its: seq[Item]): string =
  ## why the brackets hold statements and not a list ("" when they are a list): a ; of their own (not in Nim,
  ## where it is a parameter list's), or a { } of a language with blocks whose items go on over lines
  let (a0, e0) = sc.inside(pr)
  var depth = 0
  for i in a0 ..< e0:
    if sc.kinds[i] != 'c': continue
    let c = sc.t[i]
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif depth == 0 and c == ';' and sc.lang != "nim":
      return "the brackets hold statements (a ;), not a list"
  if sc.t[pr[0]] == '{' and sc.lang notin ["nim", "python", "json", "jsonc"]:
    for it in its:
      depth = 0
      for i in it.a ..< it.e:
        if sc.kinds[i] != 'c': continue
        let c = sc.t[i]
        if c in {'(', '[', '{'}: inc depth
        elif c in {')', ']', '}'}: dec depth
        elif c == '\n' and depth == 0: return "the { } holds lines of statements, not a list"
  ""

func lineIndent(s: string): string =
  ## the spaces and tabs at the start of the line, as written
  var k = 0
  while k < s.len and s[k] in {' ', '\t'}: inc k
  s[0 ..< k]

# ── split, join ──

func isCall(sc: Scan, open: int): bool =
  ## a ( right after a name or a closing bracket: a call (or a definition), not brackets round an expression
  open > 0 and sc.t[open] == '(' and (sc.t[open - 1] in IdentChars or sc.t[open - 1] in {')', ']', '>'})

proc splitPair(b: Buf, sc: Scan, pr: (int, int)) =
  ## rewrites the list in the brackets as one item a line, one indentation unit deeper than the line the opening bracket
  ## is on and with the closing bracket on a line of its own; it says why (a message) when the list is empty or holds
  ## statements. The comma after the last item follows the language's habit, or the list's own when the language has
  ## none, and the cursor goes to the opening bracket
  let its = sc.listItems(pr)
  if its.len == 0:
    message("Split/join: the list is empty — nothing to split")
    return
  let why = sc.statements(pr, its)
  if why.len > 0:
    message("Split/join: " & why)
    return
  let (o, c) = sc.ends(pr)
  let (a0, e0) = sc.inside(pr)
  let op = sc.posOf(pr[0])
  let ind = lineIndent(b.line(op.line))
  let unit = b.indentUnit
  let had = sc.t[a0 ..< e0].strip.endsWith(",")
  var comma = if sc.lang in CommaLangs: true elif sc.lang in NoCommaLangs: false else: had
  if its.len == 1 and sc.t[pr[0]] == '(' and not sc.isCall(pr[0]): comma = had   # ((a) is not the tuple (a,))
  if its.len == 1 and o == "{" and sc.lang notin ["nim", "python"]: comma = had  # (perhaps a block: { x + 1 })
  var s = o & "\n"
  for k, it in its:
    s.add ind & unit & sc.t[it.a ..< it.e]
    if k < its.high: s.add it.sep
    elif comma: s.add ','
    s.add "\n"
  s.add ind & c
  b.replace(rng(op, sc.posOf(pr[1] + 1)), s)
  b.setCursor(op)

proc joinedText(sc: Scan, a, e: int): string

proc joinedPair(sc: Scan, pr: (int, int)): string =
  ## the pair on one line: its items joined with ", "
  let its = sc.listItems(pr)
  let (o, c) = sc.ends(pr)
  var inner = ""
  for k, it in its:
    inner.add joinedText(sc, it.a, it.e)
    if k < its.high: inner.add $it.sep & " "
  # (a, ) in Nim and Python is a tuple of one: its comma stays
  if its.len == 1 and o == "(" and sc.lang in ["nim", "python"] and sc.t[its[0].e ..< pr[1]].strip == ",":
    inner.add ","
  let spaced = o == "{" and inner.len > 0 and sc.lang in SpacedBraceLangs and
               not (pr[0] >= 2 and sc.t[pr[0] - 2 ..< pr[0]] == "::")
  if spaced: "{ " & inner & " }" else: o & inner & c

proc joinedText(sc: Scan, a, e: int): string =
  ## the text from a to e on one line: inner lists that are split joined, each line's spaces round a line end one
  var i = a
  while i < e:
    let c = sc.t[i]
    if c in {'(', '[', '{'} and sc.kinds[i] == 'c':
      var done = false
      for pr in sc.pairs:
        if pr[0] == i and pr[1] < e:
          result.add (if sc.multiLine(pr): joinedPair(sc, pr) else: sc.t[pr[0] .. pr[1]])
          i = pr[1] + 1
          done = true
          break
      if done: continue
    if c == '\n':
      result = result.strip(leading = false)
      inc i
      while i < e and sc.t[i] in {' ', '\t'}: inc i
      if result.len > 0 and i < e: result.add ' '
      continue
    result.add c
    inc i

proc joinPair(b: Buf, sc: Scan, pr: (int, int)): bool =
  ## the list on one line; false (and a message) when it cannot be
  for i in pr[0] ..< pr[1]:
    if sc.kinds[i] == 'm':
      message("Split/join: the list has comments in it — joined they would end up inside the line")
      return false
    if sc.t[i] == '\n' and sc.kinds[i] == 's':
      message("Split/join: a string in the list goes over several lines — it stays split")
      return false
  let why = sc.statements(pr, sc.listItems(pr))
  if why.len > 0:
    message("Split/join: " & why & " — it stays as it is")
    return false
  b.replace(rng(sc.posOf(pr[0]), sc.posOf(pr[1] + 1)), joinedPair(sc, pr))
  b.setCursor(sc.posOf(pr[0]))
  true

proc splitJoin(want: int, joinLinesElse = false) =
  ## want 0: toggle the innermost list at the cursor, 1: split the innermost one on one line, 2: join the innermost
  ## one over several lines
  let b = current()
  if not b.valid: return
  let p = b.cursor
  let sc = scanAround(b, p.line)
  let at = sc.offsetOf(p)
  let k = sc.around(min(at, max(0, sc.t.len - 1)), want)
  if k < 0:
    if joinLinesElse: runCommand("Join lines")
    else:
      message(case want
        of 1: "Split/join: no list on one line around the cursor"
        of 2: "Split/join: no list over several lines around the cursor"
        else: "Split/join: no list in brackets around the cursor")
    return
  let pr = sc.pairs[k]
  if sc.multiLine(pr): discard joinPair(b, sc, pr)
  else: splitPair(b, sc, pr)

command "Split/join: toggle the list at the cursor": splitJoin(0)
command "Split/join: split the list at the cursor": splitJoin(1)
command "Split/join: join the list at the cursor": splitJoin(2)

nmap("gS", "split the list at the cursor: one item a line") do (count: int): splitJoin(1)
nmap("gJ", "join the list at the cursor on one line (or the lines)") do (count: int): splitJoin(2, joinLinesElse = true)
