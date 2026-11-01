## doc-gen — a doc comment for a routine: a line for what it does, one for each parameter and one for its result
##
##   Doc: write a doc comment    for the routine the cursor is in the signature of, else the next one below it:
##                               Nim — ## lines under the signature; Python — a docstring (Args and Returns, or
##                               the numpy or Sphinx style); JavaScript and TypeScript — JSDoc (/** @param …
##                               @returns */); C and C++ — Doxygen (/** @param … @return */); Go — // lines that
##                               start with its name; Rust — /// lines (# Arguments, # Returns). Where you write
##                               is marked … and the first one is selected: type over it. Nothing is written
##                               when the routine has a doc comment already
##   Alt+Enter                   on a routine's signature that has no doc comment: "Write a doc comment for name"
##   settings                    plugins.doc-gen.placeholder — what marks where you write (…)
##                               plugins.doc-gen.pythonStyle — google (Args:, Returns:), numpy or sphinx (:param:)
##
## The signature is read, not compiled: self and cls (Python) and self (Rust) are left out, Go's parameters are
## named only when they have names, a C parameter without a name is left out. A result is described when the
## signature has one (not void, None, () or untyped) — in Python and JavaScript without one, when the body returns
## a value. An iterator (Nim) or a generator (Python) yields.
import nedplugin
import std/strutils

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("placeholder", "…", "Doc: write a doc comment — what marks where you write (… , TODO …)")
settingDef("pythonStyle", "google", "Doc: write a doc comment — a Python docstring's style: google (Args:, " &
           "Returns:), numpy (Parameters and Returns under dashes) or sphinx (:param x:, :returns:)")

const Langs = ["nim", "python", "javascript", "typescript", "c", "cpp", "go", "rust"]

type Routine* = object
  name*: string
  kind*: string                  # "routine", "iterator" (it yields), "constructor"
  params*: seq[string]
  returns*: bool
  first*, last*: int             # its signature's first and last line
  endCol*: int                   # Nim, Python: the column after its = or : on the last line (-1: none — a declaration)
  docAt*: int                    # JS, C, Go, Rust: the line the comment goes above (its decorators' first)

func indentOf(l: string): int =
  ## how many spaces or tabs the line starts with
  while result < l.len and l[result] in {' ', '\t'}: inc result

func joinFrom(ls: seq[string], s, n: int): (string, seq[int]) =
  ## lines s ..< s+n joined with \n, and where each starts in the text
  var text = ""
  var starts: seq[int]
  for k in s ..< min(ls.len, s + n):
    starts.add text.len
    text.add ls[k] & "\n"
  (text, starts)

func lineOf(starts: seq[int], o: int): (int, int) =
  ## an offset in the joined text: (its line from the first, its column)
  var k = starts.high
  while k > 0 and starts[k] > o: dec k
  (k, o - starts[k])

func skipString(t: string, i: int): int =
  ## the offset after the string (or character) literal that starts at i
  let q = t[i]
  if q == '"' and t.continuesWith("\"\"\"", i):
    let e = t.find("\"\"\"", i + 3)
    return if e < 0: t.len else: e + 3
  var j = i + 1
  while j < t.len and t[j] != q and t[j] != '\n':
    if t[j] == '\\': inc j
    inc j
  min(t.len, j + 1)

func matchClose(t: string, i: int, angle = false): int =
  ## the offset of the bracket that closes the one at i (-1: none); angle: < > count too (not -> => >= <=)
  var depth = 0
  var j = i
  while j < t.len:
    let c = t[j]
    case c
    of '"', '\'', '`':
      if c == '\'' and j + 1 < t.len and t[j + 1] in {'a'..'z'} and angle:   # (Rust's 'a: a lifetime)
        inc j
        continue
      j = skipString(t, j)
      continue
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      dec depth
      if depth == 0: return j
    of '<':
      if angle and not (j + 1 < t.len and t[j + 1] in {'=', '<'}): inc depth
    of '>':
      if angle and j > 0 and t[j - 1] notin {'-', '=', '>'} and not (j + 1 < t.len and t[j + 1] == '='):
        dec depth
        if depth == 0: return j
    else: discard
    inc j
  -1

func splitTop(s: string, seps: set[char], angle = false): seq[string] =
  ## s split at the separators that are not in brackets or strings
  var depth = 0
  var cur = ""
  var j = 0
  while j < s.len:
    let c = s[j]
    if c in {'"', '\'', '`'} and not (c == '\'' and angle and j + 1 < s.len and s[j + 1] in {'a'..'z'}):
      let e = skipString(s, j)
      cur.add s[j ..< e]
      j = e
      continue
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif angle and c == '<' and not (j + 1 < s.len and s[j + 1] in {'=', '<'}): inc depth
    elif angle and c == '>' and j > 0 and s[j - 1] notin {'-', '=', '>'}: dec depth
    if c in seps and depth == 0:
      result.add cur
      cur = ""
    else: cur.add c
    inc j
  if cur.strip.len > 0: result.add cur

func identAt(t: string, i: int): string =
  ## the name (letters, digits, _, non-ASCII bytes) that starts at offset i of the text; empty when there is none
  var j = i
  while j < t.len and (t[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or t[j].uint8 >= 0x80): inc j
  t[i ..< j]

func skipSpaces(t: string, i: int): int =
  ## the offset of the first character at or after i that is not a space, tab or line end
  result = i
  while result < t.len and t[result] in {' ', '\t', '\n', '\r'}: inc result

func cutAtTop(s: string, stops: set[char]): string =
  ## s up to the first of stops outside brackets and strings
  let parts = splitTop(s & "\x01", stops)
  if parts.len > 0: parts[0].strip(chars = {' ', '\t', '\n', '\x01'}) else: ""

# ── Nim ──

const NimWords = ["proc", "func", "method", "iterator", "template", "macro", "converter"]

proc nimRoutine*(ls: seq[string], s: int): (bool, Routine) =
  ## reads the Nim routine whose signature starts at line s (proc, func, method, iterator, template, macro or converter;
  ## the lines after it are read too, for a signature of several): its name, the names of its parameters, whether it
  ## gives a result, and the line and column where its signature ends (after the =); false when the line is not one
  let t = ls[s].strip
  var kw = ""
  for w in NimWords:
    if t.startsWith(w & " ") or t.startsWith(w & "`"): kw = w
  if kw.len == 0: return
  let (text, starts) = joinFrom(ls, s, 40)
  var i = skipSpaces(text, indentOf(ls[s]) + kw.len)
  var name = ""
  if i < text.len and text[i] == '`':
    let e = text.find('`', i + 1)
    if e < 0: return
    name = text[i + 1 ..< e]
    i = e + 1
  else:
    name = identAt(text, i)
    i += name.len
  if name.len == 0: return
  if i < text.len and text[i] == '*': inc i
  i = skipSpaces(text, i)
  if i < text.len and text[i] == '[':
    let e = matchClose(text, i)
    if e < 0: return
    i = skipSpaces(text, e + 1)
  var r = Routine(name: name, kind: (if kw == "iterator": "iterator" else: "routine"), first: s, endCol: -1)
  if i < text.len and text[i] == '(':
    let e = matchClose(text, i)
    if e < 0: return
    for piece in splitTop(text[i + 1 ..< e], {',', ';'}):
      var p = piece
      let pr = p.find("{.")
      if pr >= 0: p = p[0 ..< pr]
      let n = cutAtTop(p, {':', '='}).strip(chars = {' ', '`', '\n', '\t'})
      if n.len > 0: r.params.add n
    i = e + 1
  # then `: T`, pragmas, and = (the body) — or the line's end, for a declaration
  var j = i
  var depth = 0
  var stop = text.len
  while j < text.len:
    let c = text[j]
    if c in {'"', '\''}:
      j = skipString(text, j)
      continue
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif c == '#' and depth == 0:
      while j < text.len and text[j] != '\n': inc j
      continue
    elif c == '=' and depth == 0 and not (j + 1 < text.len and text[j + 1] == '=') and
         not (j > 0 and text[j - 1] in {'<', '>', '!', '=', '.'}):
      let (k, col) = lineOf(starts, j)
      r.last = s + k
      r.endCol = col + 1
      stop = j
      break
    elif c == '\n' and depth == 0:
      let (k, _) = lineOf(starts, j)
      r.last = s + k
      stop = j
      break
    inc j
  var rtype = text[i ..< min(stop, text.len)].strip
  if rtype.startsWith(":"):
    rtype = rtype[1 .. ^1]
    let pr = rtype.find("{.")
    if pr >= 0: rtype = rtype[0 ..< pr]
    rtype = rtype.strip
  else: rtype = ""
  r.returns = rtype.len > 0 and rtype notin ["void", "untyped", "typed"]
  (true, r)

func nimHasDoc(ls: seq[string], r: Routine): bool =
  ## whether a Nim routine has a ## comment already: after the = of its signature, or on the first line under it when
  ## that is indented deeper than the routine
  if r.endCol >= 0 and r.endCol < ls[r.last].len and ls[r.last][r.endCol .. ^1].strip.startsWith("##"): return true
  for k in r.last + 1 ..< ls.len:
    let t = ls[k].strip
    if t.len == 0: continue
    return t.startsWith("##") and indentOf(ls[k]) > indentOf(ls[r.first])
  false

# ── Python ──

proc pyRoutine*(ls: seq[string], s: int): (bool, Routine) =
  ## reads the Python function whose def starts at line s (async too): its name, its parameters (self, cls, / and * left
  ## out), whether it returns a value (its -> type, else a return with a value in its body) or is a generator (yield),
  ## and where its colon is; false when the line is not a def
  var t = ls[s].strip
  if t.startsWith("async "): t = t[6 .. ^1].strip
  if not t.startsWith("def "): return
  let (text, starts) = joinFrom(ls, s, 40)
  let d = text.find("def ")
  var i = skipSpaces(text, d + 4)
  let name = identAt(text, i)
  i = skipSpaces(text, i + name.len)
  if name.len == 0 or i >= text.len or text[i] != '(': return
  let e = matchClose(text, i)
  if e < 0: return
  var r = Routine(name: name, kind: "routine", first: s, endCol: -1)
  for k, piece in splitTop(text[i + 1 ..< e], {','}):
    let n = cutAtTop(piece, {':', '='})
    if n.len == 0 or n in ["/", "*"]: continue
    if k == 0 and n in ["self", "cls"]: continue
    r.params.add n
  # -> T, then the colon
  var j = e + 1
  var depth = 0
  var colon = -1
  while j < text.len:
    let c = text[j]
    if c in {'"', '\''}:
      j = skipString(text, j)
      continue
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif c == ':' and depth == 0:
      colon = j
      break
    inc j
  if colon < 0: return
  let (k, col) = lineOf(starts, colon)
  r.last = s + k
  r.endCol = col + 1
  var rtype = text[e + 1 ..< colon].strip
  if rtype.startsWith("->"): rtype = rtype[2 .. ^1].strip else: rtype = ""
  # the body: does it return a value, does it yield?
  let ind = indentOf(ls[s])
  var returnsValue, yields = false
  let rest = ls[r.last][r.endCol .. ^1].strip
  if rest.startsWith("return ") and rest.len > 7: returnsValue = true
  for m in r.last + 1 ..< ls.len:
    let l = ls[m]
    let lt = l.strip
    if lt.len == 0 or lt.startsWith("#"): continue
    if indentOf(l) <= ind: break
    if lt.startsWith("return ") and lt[7 .. ^1].strip notin ["", "None"]: returnsValue = true
    if lt.startsWith("yield ") or lt == "yield" or " yield " in lt or "= yield" in lt: yields = true
  if yields: r.kind = "iterator"
  r.returns = if rtype.len > 0: rtype != "None" and not yields else: returnsValue
  (true, r)

func pyHasDoc(ls: seq[string], r: Routine): bool =
  ## whether a Python function has a docstring: a string right after its colon, or as the first thing of its body
  let rest = ls[r.last][r.endCol .. ^1].strip
  if rest.len > 0 and not rest.startsWith("#"):
    return rest[0] in {'"', '\''} or (rest.len > 1 and rest[0] in {'r', 'R', 'u', 'U'} and rest[1] in {'"', '\''})
  for k in r.last + 1 ..< ls.len:
    let t = ls[k].strip
    if t.len == 0 or t.startsWith("#"): continue
    return t[0] in {'"', '\''} or (t.len > 1 and t[0] in {'r', 'R', 'u', 'U'} and t[1] in {'"', '\''})
  false

# ── JavaScript and TypeScript ──

const JsNotNames = ["if", "for", "while", "switch", "catch", "return", "function", "new", "typeof", "await",
  "yield", "else", "do", "try", "with", "super", "this", "import", "export", "throw", "delete", "void", "case"]
const JsPrefixes = ["export ", "default ", "async ", "static ", "public ", "private ", "protected ", "readonly ",
  "override ", "abstract ", "declare ", "get ", "set "]

func jsReturnsIn(text: string, open: int): bool =
  ## does the block that starts at open return a value?
  let e = matchClose(text, open)
  let body = if e < 0: text[open .. ^1] else: text[open .. e]
  var k = body.find("return")
  while k >= 0:
    let before = if k > 0: body[k - 1] else: ' '
    let after = if k + 6 < body.len: body[k + 6] else: ';'
    if before notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '$', '.'} and
       after in {' ', '\t', '(', '[', '{', '"', '\'', '`'}:
      var m = k + 6
      while m < body.len and body[m] in {' ', '\t'}: inc m
      if m < body.len and body[m] notin {';', '\n', '}'}: return true
    k = body.find("return", k + 6)
  false

proc jsRoutine*(ls: seq[string], s: int, ts: bool): (bool, Routine) =
  ## reads the JavaScript (TypeScript when ts) routine that starts at line s: a function, a const/let/var holding a
  ## function or an arrow function, or a method or constructor of a class — with its parameters (decorators and access
  ## words left out, a destructured one called param0, param1 …), whether it returns a value (its type, else a return
  ## with a value in its body), and the line above its decorators where a comment goes; false when the line is not one
  let raw = ls[s]
  var t = raw.strip
  var pre = indentOf(raw)
  var again = true
  while again:
    again = false
    for p in JsPrefixes:
      if t.startsWith(p) and t.len > p.len:
        t = t[p.len .. ^1].strip
        again = true
  let (text0, starts) = joinFrom(ls, s, 400)
  let off = text0.find(t, pre)                          # (where t starts in the text)
  if off < 0: return
  let text = text0
  var r = Routine(kind: "routine", first: s, docAt: s, endCol: -1)
  var i = off
  var arrow = false
  if t.startsWith("function"):
    i = skipSpaces(text, i + 8)
    if i < text.len and text[i] == '*': i = skipSpaces(text, i + 1)
    r.name = identAt(text, i)
    i = skipSpaces(text, i + r.name.len)
    if r.name.len == 0: r.name = "function"
  elif t.startsWith("const ") or t.startsWith("let ") or t.startsWith("var "):
    i = skipSpaces(text, i + t.find(' '))
    r.name = identAt(text, i)
    if r.name.len == 0: return
    i = skipSpaces(text, i + r.name.len)
    if i < text.len and text[i] == ':':                 # (const f: Handler = …)
      while i < text.len and text[i] notin {'=', '\n'}: inc i
    if i >= text.len or text[i] != '=' or (i + 1 < text.len and text[i + 1] in {'=', '>'}): return
    i = skipSpaces(text, i + 1)
    if text.continuesWith("async", i): i = skipSpaces(text, i + 5)
    if text.continuesWith("function", i):
      i = skipSpaces(text, i + 8)
      if i < text.len and text[i] == '*': i = skipSpaces(text, i + 1)
      i = skipSpaces(text, i + identAt(text, i).len)
    else: arrow = true
    if i < text.len and text[i] == '<':                 # (TypeScript's <T>)
      let e = matchClose(text, i, true)
      if e < 0: return
      i = skipSpaces(text, e + 1)
    if arrow and i < text.len and text[i] != '(':
      # x => …: one parameter without brackets
      let p = identAt(text, i)
      if p.len == 0: return
      let a = skipSpaces(text, i + p.len)
      if not text.continuesWith("=>", a): return
      r.params.add p
      let b = skipSpaces(text, a + 2)
      let (k, _) = lineOf(starts, a)
      r.last = s + k
      r.returns = b < text.len and (text[b] != '{' or jsReturnsIn(text, b))
      return (true, r)
  else:
    # a method: name(…) { — not a call, not a statement
    if t.startsWith("*") or t.startsWith("#"): i = off + 1
    r.name = identAt(text, i)
    if r.name.len == 0 or r.name in JsNotNames: return
    i = skipSpaces(text, i + r.name.len)
    if i < text.len and text[i] == '?': inc i
    if i < text.len and text[i] == '<':
      let e = matchClose(text, i, true)
      if e < 0: return
      i = skipSpaces(text, e + 1)
    if r.name == "constructor": r.kind = "constructor"
  if i >= text.len or text[i] != '(': return
  let e = matchClose(text, i, ts)
  if e < 0: return
  for k, piece in splitTop(text[i + 1 ..< e], {','}, ts):
    var p = piece.strip
    while p.startsWith("@"):                             # (a decorator: @Inject() x)
      let sp = p.find(' ')
      if sp < 0: break
      p = p[sp + 1 .. ^1].strip
    for m in ["public ", "private ", "protected ", "readonly ", "override "]:
      if p.startsWith(m): p = p[m.len .. ^1].strip
    if p.startsWith("..."): p = p[3 .. ^1]
    if p.len == 0: continue
    if p[0] in {'{', '['}: r.params.add "param" & $k
    else:
      let n = cutAtTop(p, {':', '=', '?'})
      if n.len > 0 and n != "this": r.params.add n
  # : T, then { or =>
  var j = e + 1
  var rtype = ""
  let a = skipSpaces(text, j)
  if a < text.len and text[a] == ':':
    j = a + 1
    var depth = 0
    while j < text.len:
      let c = text[j]
      if c in {'(', '[', '<'} and not (c == '<' and j + 1 < text.len and text[j + 1] == '='): inc depth
      elif c in {')', ']'} or (c == '>' and text[j - 1] notin {'=', '-'}): dec depth
      elif c == '{' and depth == 0 and text[a + 1 ..< j].strip.len > 0 and
           not text[a + 1 ..< j].strip.endsWith("|") and not text[a + 1 ..< j].strip.endsWith(":"): break
      elif c == '{': inc depth
      elif c == '}': dec depth
      elif depth == 0 and (c in {';', '\n'} or text.continuesWith("=>", j)): break
      inc j
    rtype = text[a + 1 ..< j].strip
  j = skipSpaces(text, j)
  var bodyAt = -1
  if text.continuesWith("=>", j):
    let b = skipSpaces(text, j + 2)
    if b < text.len and text[b] == '{': bodyAt = b
    else:
      let (k, _) = lineOf(starts, j)
      r.last = s + k
      r.returns = rtype.len == 0 or rtype notin ["void", "never", "undefined", "Promise<void>"]
      return (true, r)
  elif j < text.len and text[j] == '{': bodyAt = j
  elif ts and j < text.len and text[j] == ';' and (t.startsWith("function") or rtype.len > 0):
    bodyAt = -1                                          # (an overload's or an interface's signature)
  else: return
  let (k, _) = lineOf(starts, (if bodyAt >= 0: bodyAt else: j))
  r.last = s + k
  var d = s
  while d > 0 and ls[d - 1].strip.startsWith("@"): dec d   # (its decorators: the comment goes above them)
  r.docAt = d
  if r.kind == "constructor" or (" set " & r.name) in (" " & raw.strip): r.returns = false
  elif rtype.len > 0: r.returns = rtype notin ["void", "never", "undefined", "Promise<void>"]
  elif bodyAt >= 0: r.returns = jsReturnsIn(text, bodyAt)
  (true, r)

# ── C and C++ ──

const CNotFirst = ["if", "for", "while", "switch", "return", "else", "do", "case", "default", "goto", "sizeof",
  "typedef", "using", "namespace", "public:", "private:", "protected:", "delete", "new", "throw", "co_return",
  "co_await", "static_assert"]
const CSpecifiers = ["static", "inline", "extern", "virtual", "constexpr", "consteval", "explicit", "friend",
  "__inline", "__forceinline", "_Noreturn", "noreturn"]

proc cRoutine*(ls: seq[string], s: int): (bool, Routine) =
  ## reads the C or C++ function, method, constructor or operator whose definition or declaration starts at line s:
  ## finds the ( after its type and name and the { or ; after it, and refuses statements, calls and anything with a = in
  ## its tail; gives its parameters' names, whether it returns something (not void) and the line above its template line
  ## where a comment goes; false when the line is not one
  let t = ls[s].strip
  if t.len == 0 or t[0] in {'#', '/', '*', '}', '{', '(', ')', ':', ';', '"'}: return
  let first = t.splitWhitespace()[0]
  for w in CNotFirst:
    if first == w or first.startsWith(w & "("): return
  let (text, starts) = joinFrom(ls, s, 30)
  let lead = indentOf(ls[s])
  var p = -1
  for j in lead ..< text.len:
    if text[j] in {';', '{', '}', '='}: return
    if text[j] == '(':
      p = j
      break
  if p < 0: return
  let head = text[lead ..< p].strip
  if head.len == 0 or "->" in head or '.' in head or '"' in head: return
  # its name: the last word of the head (Class::name, ~Class, operator==)
  var name = ""
  let op = head.rfind("operator")
  var typ = ""
  if op >= 0 and (op == 0 or head[op - 1] in {' ', ':', '*', '&'}):
    var a = op
    while a > 0 and head[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_', ':', '~'}: dec a
    name = head[a .. ^1].strip
    typ = head[0 ..< a].strip
  else:
    var a = head.len
    while a > 0 and head[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_', ':', '~'}: dec a
    name = head[a .. ^1]
    typ = head[0 ..< a].strip
  if name.len == 0 or name.endsWith(":"): return
  # (the specifiers and attributes are not the type)
  var words: seq[string]
  for w in typ.replace("[[", " [[").splitWhitespace:
    if w notin CSpecifiers and not w.startsWith("[[") and not w.endsWith("]]") and not w.startsWith("__attribute__"):
      words.add w
  typ = words.join(" ")
  let short = name.split("::")
  let ctor = name.startsWith("~") or (short.len >= 2 and (short[^1] == short[^2] or short[^1].startsWith("~")))
  if typ.len == 0 and not ctor and "::" in name: return
  let e = matchClose(text, p, true)
  if e < 0: return
  # the rest, up to { (a definition) or ; (a declaration)
  var j = e + 1
  var depth = 0
  var endAt = -1
  while j < text.len:
    let c = text[j]
    if c in {'"', '\''}:
      j = skipString(text, j)
      continue
    if c == '(': inc depth
    elif c == ')': dec depth
    elif depth == 0 and c in {'{', ';'}:
      endAt = j
      break
    elif depth == 0 and c == '}': return
    inc j
  if endAt < 0: return
  let tail = text[e + 1 ..< endAt].strip
  if typ.len == 0 and not ctor and (text[endAt] == ';' or tail.len > 0): return   # (a call: foo(x);)
  if '=' in tail and not (tail.endsWith("= 0") or tail.endsWith("= default") or tail.endsWith("= delete")): return
  var r = Routine(name: name, kind: (if ctor: "constructor" else: "routine"), first: s, docAt: s, endCol: -1)
  let (k, _) = lineOf(starts, endAt)
  r.last = s + k
  for piece in splitTop(text[p + 1 ..< e], {','}, true):
    var q = cutAtTop(piece, {'='})
    if q in ["", "void", "..."]: continue
    let fp = q.find("(*")
    let rp = q.find("(&")
    if fp >= 0 or rp >= 0:
      let a = (if fp >= 0: fp else: rp) + 2
      let n = identAt(q, a)
      if n.len > 0: r.params.add n
      continue
    while q.endsWith("]"):
      let b = q.rfind('[')
      if b < 0: break
      q = q[0 ..< b].strip
    var a = q.len
    while a > 0 and q[a - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec a
    let n = q[a .. ^1]
    let before = q[0 ..< a].strip
    if n.len == 0 or before.len == 0 or before.endsWith("::") or before in ["struct", "enum", "union", "const",
       "unsigned", "signed"]: continue
    r.params.add n
  r.returns = not ctor and typ.len > 0 and typ.replace(" ", "") notin ["void", "staticvoid"]
  if "->" in tail:                                       # (auto f() -> T)
    r.returns = tail[tail.find("->") + 2 .. ^1].strip.splitWhitespace()[0] != "void"
  # (a template's line above it: the comment goes above that)
  var d = s
  while d > 0 and (ls[d - 1].strip.startsWith("template") or ls[d - 1].strip.startsWith("[[")): dec d
  r.docAt = d
  (true, r)

# ── Go ──

proc goRoutine*(ls: seq[string], s: int): (bool, Routine) =
  ## reads the Go function or method (a receiver is skipped) whose func starts at line s: its name, its parameters'
  ## names (only when they have names) and whether it declares a result; false when the line is not one
  let t = ls[s].strip
  if not t.startsWith("func "): return
  let (text, starts) = joinFrom(ls, s, 30)
  var i = skipSpaces(text, text.find("func") + 4)
  if i < text.len and text[i] == '(':                    # (a method's receiver)
    let e = matchClose(text, i)
    if e < 0: return
    i = skipSpaces(text, e + 1)
  var r = Routine(first: s, docAt: s, kind: "routine", endCol: -1)
  r.name = identAt(text, i)
  if r.name.len == 0: return
  i += r.name.len
  if i < text.len and text[i] == '[':
    let e = matchClose(text, i)
    if e < 0: return
    i = e + 1
  if i >= text.len or text[i] != '(': return
  let e = matchClose(text, i)
  if e < 0: return
  let pieces = splitTop(text[i + 1 ..< e], {','})
  var named = false
  for piece in pieces:
    if piece.strip.splitWhitespace.len >= 2: named = true
  if named:
    for piece in pieces:
      let w = piece.strip.splitWhitespace
      if w.len > 0: r.params.add w[0]
  var j = e + 1
  var depth = 0
  while j < text.len:
    let c = text[j]
    if c in {'(', '['}: inc depth
    elif c in {')', ']'}: dec depth
    elif c == '{' and depth == 0: break
    elif c == '\n' and depth == 0: break
    inc j
  r.returns = text[e + 1 ..< j].strip.len > 0
  let (k, _) = lineOf(starts, min(j, text.high))
  r.last = s + k
  (true, r)

# ── Rust ──

proc rustRoutine*(ls: seq[string], s: int): (bool, Routine) =
  ## reads the Rust fn that starts at line s (pub, async, unsafe, extern … in front of it are skipped): its name, its
  ## parameters (self left out) and whether it has a result other than (); the comment goes above its #[…] lines; false
  ## when the line is not one
  var t = ls[s].strip
  var again = true
  while again:
    again = false
    if t.startsWith("pub("):
      let e = t.find(')')
      if e > 0:
        t = t[e + 1 .. ^1].strip
        again = true
    for p in ["pub ", "default ", "const ", "async ", "unsafe "]:
      if t.startsWith(p):
        t = t[p.len .. ^1].strip
        again = true
    if t.startsWith("extern "):
      t = t[7 .. ^1].strip
      if t.startsWith("\""):
        let e = t.find('"', 1)
        t = (if e > 0: t[e + 1 .. ^1] else: "").strip
      again = true
  if not t.startsWith("fn "): return
  let (text, starts) = joinFrom(ls, s, 30)
  var i = skipSpaces(text, text.find("fn ") + 3)
  var r = Routine(first: s, kind: "routine", endCol: -1)
  r.name = identAt(text, i)
  if r.name.len == 0: return
  i = skipSpaces(text, i + r.name.len)
  if i < text.len and text[i] == '<':
    let e = matchClose(text, i, true)
    if e < 0: return
    i = skipSpaces(text, e + 1)
  if i >= text.len or text[i] != '(': return
  let e = matchClose(text, i, true)
  if e < 0: return
  for piece in splitTop(text[i + 1 ..< e], {','}, true):
    var pat = cutAtTop(piece, {':'})
    let flat = pat.replace(" ", "")
    if flat in ["self", "&self", "&mutself", "mutself"] or (flat.startsWith("&'") and flat.endsWith("self")): continue
    if pat.startsWith("mut "): pat = pat[4 .. ^1].strip
    if pat.len > 0: r.params.add pat
  var j = e + 1
  var depth = 0
  while j < text.len:
    let c = text[j]
    if c in {'(', '['} or (c == '<'): inc depth
    elif c in {')', ']'} or (c == '>' and text[j - 1] != '-'): dec depth
    elif depth <= 0 and c in {'{', ';'}: break
    elif depth <= 0 and text.continuesWith("where", j) and text[j - 1] in {' ', '\n'}: break
    inc j
  let tail = text[e + 1 ..< min(j, text.len)].strip
  r.returns = tail.startsWith("->") and tail[2 .. ^1].strip notin ["()", ""]
  let (k, _) = lineOf(starts, min(j, text.high))
  r.last = s + k
  var d = s
  while d > 0 and ls[d - 1].strip.startsWith("#["): dec d
  r.docAt = d
  (true, r)

# ── which routine, has it a comment ──

proc routineAt*(ls: seq[string], s: int, lang: string): (bool, Routine) =
  ## the routine whose signature starts at line s
  if s < 0 or s >= ls.len or ls[s].strip.len == 0: return
  case lang
  of "nim": nimRoutine(ls, s)
  of "python": pyRoutine(ls, s)
  of "javascript": jsRoutine(ls, s, false)
  of "typescript": jsRoutine(ls, s, true)
  of "c", "cpp": cRoutine(ls, s)
  of "go": goRoutine(ls, s)
  of "rust": rustRoutine(ls, s)
  else: (false, Routine())

proc findRoutine*(ls: seq[string], line: int, lang: string, below = 300): (bool, Routine) =
  ## the routine the line is in the signature of, else the first one below it
  for s in countdown(line, max(0, line - 12)):
    let (ok, r) = routineAt(ls, s, lang)
    if ok and r.last >= line: return (true, r)
  for s in line + 1 .. min(ls.high, line + below):
    let (ok, r) = routineAt(ls, s, lang)
    if ok: return (true, r)

func hasDoc*(ls: seq[string], r: Routine, lang: string): bool =
  ## whether the routine already has a doc comment: for Nim and Python by the rules of their own (## lines, a
  ## docstring), for the others when the line above it (above its blank lines too, except in Go) ends a /** */ block or
  ## is a /// (or in Go a //) comment
  case lang
  of "nim": return nimHasDoc(ls, r)
  of "python": return pyHasDoc(ls, r)
  else: discard
  var k = r.docAt - 1
  while k >= 0 and ls[k].strip.len == 0 and lang != "go": dec k
  if k < 0: return false
  let t = ls[k].strip
  case lang
  of "go": t.startsWith("//") or t.endsWith("*/")
  of "rust": t.startsWith("///") or t.startsWith("#[doc") or t.endsWith("*/")
  of "c", "cpp": t.endsWith("*/") or t.startsWith("///") or t.startsWith("//!")
  else: t.endsWith("*/")

# ── the comment ──

func docLines*(r: Routine, lang, ph, style, unit: string): seq[string] =
  ## the comment's lines, from column 0 (the routine's indentation is added after)
  let ret = r.returns
  let yields = r.kind == "iterator"
  case lang
  of "nim":
    result.add "## " & ph
    if r.params.len > 0 or ret or yields: result.add "##"
    for p in r.params: result.add "## - `" & p & "`: " & ph
    if (ret or yields) and r.params.len > 0: result.add "##"
    if yields: result.add "## Yields " & ph
    elif ret: result.add "## Returns " & ph
  of "python":
    let more = r.params.len > 0 or ret or yields
    if not more: return @["\"\"\"" & ph & "\"\"\""]
    result.add "\"\"\"" & ph
    case style
    of "sphinx":
      result.add ""
      for p in r.params: result.add ":param " & p.strip(chars = {'*'}) & ": " & ph
      if yields: result.add ":yields: " & ph
      elif ret: result.add ":returns: " & ph
    of "numpy":
      if r.params.len > 0:
        result.add ""
        result.add "Parameters"
        result.add "----------"
        for p in r.params:
          result.add p
          result.add unit & ph
      if yields or ret:
        result.add ""
        result.add (if yields: "Yields" else: "Returns")
        result.add (if yields: "------" else: "-------")
        result.add ph
    else:
      if r.params.len > 0:
        result.add ""
        result.add "Args:"
        for p in r.params: result.add unit & p & ": " & ph
      if yields or ret:
        result.add ""
        result.add (if yields: "Yields:" else: "Returns:")
        result.add unit & ph
    result.add "\"\"\""
  of "javascript", "typescript", "c", "cpp":
    result.add "/**"
    result.add " * " & ph
    if r.params.len > 0 or ret: result.add " *"
    for p in r.params:
      result.add " * @param " & (if lang == "javascript": "{*} " else: "") & p & " " & ph
    if ret:
      result.add (if lang in ["c", "cpp"]: " * @return " else: " * @returns ") & ph
    result.add " */"
  of "go":
    result.add "// " & r.name & " " & ph
    if r.params.len > 0:
      result.add "//"
      for p in r.params: result.add "//   - " & p & ": " & ph
    if ret:
      result.add "//"
      result.add "// It returns " & ph
  of "rust":
    result.add "/// " & ph
    if r.params.len > 0:
      result.add "///"
      result.add "/// # Arguments"
      result.add "///"
      for p in r.params: result.add "/// * `" & p & "` - " & ph
    if ret:
      result.add "///"
      result.add "/// # Returns"
      result.add "///"
      result.add "/// " & ph
  else: discard

proc docEdit*(ls: seq[string], r: Routine, lang, ph, style, unit: string): (Edit, Pos) =
  ## the edit that puts the comment in, and where its first placeholder is once it is in
  let rel = docLines(r, lang, ph, style, unit)
  var at: Pos
  var stop: Pos
  var text = ""
  if lang in ["nim", "python"]:
    let sigInd = ls[r.first][0 ..< indentOf(ls[r.first])]
    var ind = sigInd & unit
    for k in r.last + 1 ..< ls.len:
      if ls[k].strip.len == 0: continue
      if indentOf(ls[k]) > sigInd.len: ind = ls[k][0 ..< indentOf(ls[k])]
      break
    var lines: seq[string]
    for x in rel: lines.add (if x.len > 0: ind & x else: x)
    let l = ls[r.last]
    let rest = if r.endCol >= 0 and r.endCol <= l.len: l[r.endCol .. ^1].strip else: ""
    if rest.len > 0 and not rest.startsWith("#"):
      # (the body on the signature's line: it goes under the comment)
      at = pos(r.last, r.endCol)
      stop = pos(r.last, l.len)
      text = "\n" & lines.join("\n") & "\n" & ind & rest
    else:
      at = pos(r.last, l.len)
      stop = at
      text = "\n" & lines.join("\n")
  else:
    let l = ls[r.docAt]
    let ind = l[0 ..< indentOf(l)]
    var lines: seq[string]
    for x in rel: lines.add ind & x
    at = pos(r.docAt, 0)
    stop = at
    text = lines.join("\n") & "\n"
  let k = text.find(ph)
  var sel = at
  if k >= 0:
    let nl = text[0 ..< k].count('\n')
    sel = if nl == 0: pos(at.line, at.col + k) else: pos(at.line + nl, k - text.rfind('\n', 0, k - 1) - 1)
  (Edit(range: rng(at, stop), text: text), sel)

# ── the command, the quick fix ──

proc placeholder(): string =
  ## the text that marks where the comment is to be written: the placeholder setting, … when it is empty
  let p = setting("placeholder", "…")
  if p.strip.len > 0: p else: "…"

proc writeDoc() =
  ## Doc: write a doc comment — finds the routine the cursor is in the signature of (else the next one below), and
  ## unless it has a comment already inserts the generated one and selects the first placeholder to be typed over; says
  ## so when the language is not supported or there is no routine
  let b = current()
  if not b.valid: return
  let lang = b.lang
  if lang notin Langs:
    message("Doc: not for " & (if lang.len > 0: lang else: "these") & " files — Nim, Python, JavaScript, " &
            "TypeScript, C, C++, Go and Rust")
    return
  let ls = b.lines
  let (ok, r) = findRoutine(ls, b.cursor.line, lang)
  if not ok:
    message("Doc: no routine at the cursor or below it")
    return
  if hasDoc(ls, r, lang):
    message("Doc: " & r.name & " has a doc comment already (line " & $(r.first + 1) & ")")
    b.setCursor(pos(r.first, indentOf(ls[r.first])))
    return
  let ph = placeholder()
  let (e, sel) = docEdit(ls, r, lang, ph, setting("pythonStyle", "google"), b.indentUnit)
  b.replace(e.range, e.text)
  b.select(rng(sel, pos(sel.line, sel.col + ph.len)))
  message("Doc: a comment for " & r.name & " — type over each " & ph)

command "Doc: write a doc comment":
  writeDoc()

proc docFix(lang: string): proc(b: Buf, r: Range): seq[Fix] =
  ## the quick fix for one language (a proc of its own for each: closures made in a loop share its variables)
  result = proc(b: Buf, r: Range): seq[Fix] =
    let line = r.start.line
    let first = max(0, line - 12)
    let ls = b.lines(first, min(b.lineCount - 1, line + 60))
    var found = false
    var rt: Routine
    for s in countdown(line - first, 0):
      let (ok, x) = routineAt(ls, s, lang)
      if ok and x.last >= line - first:
        found = true
        rt = x
        break
    if not found or hasDoc(ls, rt, lang): return
    let (e, _) = docEdit(ls, rt, lang, placeholder(), setting("pythonStyle", "google"), b.indentUnit)
    var ed = e
    ed.range = rng(pos(e.range.start.line + first, e.range.start.col), pos(e.range.stop.line + first, e.range.stop.col))
    result.add Fix(title: "Write a doc comment for " & rt.name, edits: @[ed])

for lang in Langs:
  codeActions(lang, docFix(lang))
