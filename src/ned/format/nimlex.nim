# ════════════════════════════════════════════════════════════════════════════
#  Built-in Nim formatter, in nph's style: 2-space indentation, spaced operators and commas, one
#  statement per line, blank lines after multi-line routines and types, long calls and parameter lists
#  wrapped at 88 columns, short ones joined. It works on tokens, never changes them (only trailing
#  commas, `;` between typed parameters, and commas between enum values), and checks its own result:
#  if the tokens or the block structure would differ, the file is left alone.
# ════════════════════════════════════════════════════════════════════════════

type
  FKind* = enum fkIdent, fkKw, fkNum, fkStr, fkChar, fkComment, fkOp, fkOpen, fkClose, fkComma, fkSemi,
               fkColon, fkDot, fkPragOpen, fkPragClose
  FTok* = ref object   # shared, never changed once made (copies are cheap)
    kind*: FKind
    text*: string
    nl*: bool          # first token on its physical line
    col*: int          # column where it starts
    sp*: bool          # whitespace in front of it on its line
    multi*: bool       # spans lines (long string, block comment)
    blanks*: int       # empty lines in front of its line (first token of a line only)
    pos*: int          # byte offset in the text
  FLine* = object      # one statement, or a comment on a line of its own
    toks*: seq[FTok]
    indent*: int       # its original indentation
    depth*: int
    blank*: bool       # an empty line before it
    comment*: bool
    phys*: int         # physical lines it spans
    verbatim*: bool    # holds a multi-line token: keep its layout
    keep*: bool        # (NimScript) kept exactly as written — not laid out again as nph would (fScriptKeep)
    origText*: string
    complexKind*: int  # 1 routine with a body · 2 type section · 3 object/enum type member

type
  FWrap* = enum        # how a list (parameters, call arguments, literals) is laid out — nim.format.*
    fwFit = "fit"                 # one line when it fits, else wrapped (nph: parameters all on one line or one each)
    fwOnePerLine = "onePerLine"   # one line when it fits, else one element per line
    fwAlways = "always"           # one element per line whenever there are two or more
    fwKeep = "keep"               # the line breaks as you wrote them

var
  FmtWidth* = 88       # the line length chosen (nim.format.lineLength)
  FmtMax* = 88         # line width now (smaller while formatting an indented selection)
  FmtParams*, FmtArgs*, FmtColl*: FWrap   # parameter lists · call arguments · array/seq/table/set/tuple literals
  FmtBlank* = 1        # empty lines kept in a row (nim.format.maxBlankLines)
  FmtImports* = 0      # 0 as written · 1 sorted · 2 sorted, std modules merged into std/[a, b]
  FmtAlign* = false    # object field types and the `=` of const/let/var sections lined up
  FmtAlignComments* = false   # the trailing comments of lines that follow each other at one column
  FmtMagicComma* = false   # a list ending in a comma before its bracket stays one element per line (black, ruff)
  FmtNumbers* = false      # number literals written one way: 0x 0b 0o, hex digits in upper case, e (ruff)
  FmtDocCode* = false      # the Nim code in ## comments (```nim, .. code-block:: nim) formatted too
  FmtReflow* = false   # long ## doc comments re-wrapped at the line length
  FmtReflowPlain* = false   # … and long # comments of prose (not commented-out code, banners or directives)
  FmtScriptAlign* = true  # (with FmtScript) a run of package fields lined up even when each is written `name =
                          # value` (nph's way) — as nimble's template writes them (nim.format.alignNimbleFields)
  FmtScript* = false   # a NimScript file (.nims, .nimble): its package fields lined up, switches, task headers,
                       # short `if x: y` and lines with a comment at the end kept as written

func fIsScriptPath*(path: string): bool =
  ## NimScript: config.nims, build.nims, a package's .nimble
  path.endsWith(".nims") or path.endsWith(".nimble")

const
  FKeywords* = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
    "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
    "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot",
    "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc",
    "ptr", "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
    "when", "while", "xor", "yield"]
  FWordOps* = ["and", "or", "not", "xor", "shl", "shr", "div", "mod", "in", "notin", "is", "isnot", "of", "as"]
  FOpChars* = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.', '|', '=', '%', '&', '$', '@', '~', ':'}
  FRoutineKw* = ["proc", "func", "method", "iterator", "converter", "template", "macro"]
  FBlockKw* = ["if", "elif", "else", "when", "while", "for", "of", "try", "except", "finally", "block", "defer", "static"]
  FSectionKw* = ["type", "const", "let", "var", "using"]

func contains(a: openArray[string], s: string): bool {.inline.} =
  ## `word in ["a", "b"]` as system's, the length and first character compared first (asked very often here)
  let n = s.len
  if n == 0:
    for x in a:
      if x.len == 0: return true
    return false
  let c = s[0]
  for x in a:
    if x.len == n and x[0] == c and x == s: return true
  false

proc fKwIndex*(): array['a' .. 'y', seq[int]] =
  ## for each first letter, the indexes of the keywords that start with it — built when ned is compiled, for the keyword
  ## look-up
  for i, k in FKeywords: result[k[0]].add i

proc fKwIndexLen*(): array['a' .. 'y', array[2 .. 9, seq[int]]] =
  ## for each first letter and each length of 2 to 9, the indexes of the keywords like that — built when ned is
  ## compiled, so a word needs only one or two comparisons
  for i, k in FKeywords: result[k[0]][k.len].add i

const
  FKwByFirst* = fKwIndex()
  FKwByFirstLen* = fKwIndexLen()      # (by first letter and length: one or two to compare)
  FCommonOps* = ["=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "&", "$", "@", "..", "..<", "+=",
                "-=", "*=", "&=", "->", "=>", "%", "|", "^", "!", "~", "::", "*:", "=~", "<<", ">>"]

func fKeywordAt*(text: string, i, j: int): int =
  ## the keyword text[i ..< j] is (its index in FKeywords), or -1 — without making a string
  let c = text[i]
  let n = j - i
  if c notin {'a' .. 'y'} or n < 2 or n > 9: return -1
  for k in FKwByFirstLen[c][n]:
    let kw = FKeywords[k]
    var same = true
    for q in 1 ..< n:
      if text[i + q] != kw[q]:
        same = false
        break
    if same: return k
  -1

# can this character be in a name: a letter, digit or underscore, or a byte of a non-ASCII character?
func fIsIdent*(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

func fUniOpLen*(text: string, i: int): int =
  ## the bytes of the Unicode operator character at i (∙ ∘ × ★ ⊗ ⊘ ⊙ ⊛ ⊠ ⊡ ∩ ∧ ⊓ ± ⊕ ⊖ ⊞ ⊟ ∪ ∨ ⊔, and Nim 2.4's
  ## ⟑ ⟇ ⩓ ⩔ ■ □ ☆ — Nim's lexer reads them as operator characters, not as part of a name), else 0
  if i + 1 >= text.len: return 0
  case text[i]
  of '\226':
    if i + 2 >= text.len: return 0
    let b = text[i + 1]
    let c = text[i + 2]
    if b == '\136' and c in {'\152', '\153', '\167', '\168', '\169', '\170'}: 3
    elif b == '\138' and c in {'\147' .. '\153', '\155', '\158' .. '\161'}: 3
    elif b == '\152' and c in {'\133', '\134'}: 3                 # ★ ☆
    elif b == '\159' and c in {'\135', '\145'}: 3                 # ⟇ ⟑
    elif b == '\169' and c in {'\147', '\148'}: 3                 # ⩓ ⩔
    elif b == '\150' and c in {'\160', '\161'}: 3                 # ■ □
    else: 0
  of '\194': (if text[i + 1] == '\177': 2 else: 0)
  of '\195': (if text[i + 1] == '\151': 2 else: 0)
  else: 0

func fIdentAt(text: string, j: int): bool {.inline.} =
  ## text[j] continues a name (a number): not a Unicode operator
  let c = text[j]
  if c < '\x80': c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  else: not (c in {'\194', '\195', '\226'} and fUniOpLen(text, j) > 0)

func fPunct*(c: char): string {.inline.} =
  ## the text of a one-character token: a shared string for the brackets, comma, semicolon, colon and dot (no new string
  ## is made), else the character as a string
  case c
  of '(': "("
  of ')': ")"
  of '[': "["
  of ']': "]"
  of '{': "{"
  of '}': "}"
  of ',': ","
  of ';': ";"
  of ':': ":"
  of '.': "."
  else: $c

proc fAccQuoted*(s: string): string =
  ## an identifier in backticks as nph writes it: its parts (names, runs of operator characters) a space apart —
  ## `|div|` → `| div |` — except `=destroy`, `'big`, `name=` (the parts make one identifier, spaced or not)
  if s.len < 3: return s
  var parts: seq[string]
  var i = 1
  while i < s.high:
    let c = s[i]
    if c in {' ', '\t'}:
      inc i
      continue
    var j = i
    if fIdentAt(s, i):
      while j < s.high and fIdentAt(s, j): inc j
      # (a number with a fraction, `0.99`, is one token for Nim: one part — `v0.99.99` → `v0 . 99.99`, like nph)
      if c in {'0' .. '9'} and j + 1 < s.high and s[j] == '.' and s[j + 1] in {'0' .. '9'}:
        inc j
        while j < s.high and fIdentAt(s, j): inc j
    elif c in FOpChars or c in {'(', ')', '[', ']', '{', '}', '='} or fUniOpLen(s, i) > 0:
      while j < s.high:
        if s[j] in FOpChars or s[j] in {'(', ')', '[', ']', '{', '}', '='}: inc j
        elif fUniOpLen(s, j) > 0: j += fUniOpLen(s, j)      # (`⊙=`: one operator)
        else: break
    else: return s                      # (anything else: as written)
    parts.add s[i ..< j]
    i = j
  if parts.len < 2: return s
  # does the part start with a letter?
  proc alpha(p: string): bool = p.len > 0 and p[0] in {'a' .. 'z', 'A' .. 'Z'}
  result = "`"
  for k, p in parts:
    var space = k > 0
    if k == 1 and parts[0] in ["=", "'"]: space = not alpha(parts[1])
    elif k == 1 and parts[1] == "=": space = not alpha(parts[0])
    if space: result.add ' '
    result.add p
  result.add '`'

proc fLex*(text: string, ok: var bool): seq[FTok] =
  ## Nim tokens with the layout around them
  ok = true
  var i = 0
  let n = text.len
  var col = 0
  var sp = false
  var blanks = 0
  var lineHasTok = false
  result = newSeqOfCap[FTok](n div 6 + 16)
  template add(k: FKind, a, b: int) =
    ## adds a token of kind k from text[a ..< b]; a one-character bracket or separator uses a shared string
    if b - a == 1 and k in {fkOpen, fkClose, fkComma, fkSemi, fkColon, fkDot}:
      addT(k, a, fPunct(text[a]))           # a shared literal: no allocation
    else: addT(k, a, text[a ..< b])
  template addT(k: FKind, a: int, tt: string) =
    ## adds a token of kind k starting at a with the given text, noting its layout: whether it is first on its line, its
    ## column, the whitespace in front, whether it spans lines (long strings and block comments), the empty lines before
    ## its line and its byte offset
    var t = tt
    # only long strings and block comments can span lines
    let nlAt = if k in {fkStr, fkComment}: t.rfind('\n') else: -1
    let tlen = t.len
    result.add FTok(kind: k, text: move(t), nl: not lineHasTok, col: col, sp: sp and lineHasTok, multi: nlAt >= 0,
                    blanks: (if not lineHasTok: blanks else: 0), pos: a)
    if not lineHasTok: blanks = 0
    lineHasTok = true
    sp = false
    # the column after a multi-line token is where its last line ends
    col = if nlAt >= 0: tlen - nlAt - 1 else: col + tlen
  while i < n:
    let c = text[i]
    if c == '\n':
      if not lineHasTok: inc blanks
      lineHasTok = false
      col = 0
      sp = false
      inc i
      continue
    if c in {' ', '\t', '\r'}:
      sp = true
      inc col
      inc i
      continue
    let st = i
    if c == '#':
      if i + 1 < n and text[i + 1] == '[' or (i + 2 < n and text[i + 1] == '#' and text[i + 2] == '['):
        # block comment, nested
        var depth = 0
        var j = i
        while j < n:
          if j + 1 < n and text[j] == '#' and text[j + 1] == '[':
            inc depth
            j += 2
          elif j + 1 < n and text[j] == ']' and text[j + 1] == '#':
            dec depth
            j += 2
            if depth == 0:
              if j < n and text[j] == '#': inc j       # ]##
              break
          else: inc j
        if depth > 0:
          ok = false
          return
        add(fkComment, st, j)
        i = j
      else:
        var j = i
        while j < n and text[j] != '\n': inc j
        var e = j
        # (its trailing spaces stay: nph keeps them)
        while e > i and text[e - 1] == '\r': dec e
        add(fkComment, st, e)
        i = j
      continue
    if c == '"' or c in {'a'..'z', 'A'..'Z', '_'} or (c >= '\x80' and fIdentAt(text, i)):
      var j = i
      var raw = false
      if c != '"':
        while j < n and text[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc j
        if j < n and text[j] >= '\x80':                     # (rare: a name with other letters)
          while j < n and fIdentAt(text, j): inc j
        if j >= n or text[j] != '"':
          let kw = fKeywordAt(text, i, j)
          if kw >= 0 and result.len > 0 and result[^1].kind == fkKw and result[^1].text in FRoutineKw and
             lineHasTok and (j >= n or text[j] in {'*', '[', '('}):
            addT(fkIdent, st, text[i ..< j])                # (Nim 3: `func addr*[T](x: T)` — a routine's name)
          elif kw >= 0: addT(fkKw, st, FKeywords[kw])        # a shared literal: no allocation
          else: addT(fkIdent, st, text[i ..< j])
          i = j
          continue
        raw = true                                  # r"…", fmt"…": generalized raw string
      if j + 2 < n and text[j + 1] == '"' and text[j + 2] == '"':
        let e = text.find("\"\"\"", j + 3)
        if e < 0:
          ok = false
          return
        var k = e + 3
        while k < n and text[k] == '"': inc k
        add(fkStr, st, k)
        i = k
        continue
      var k = j + 1
      while k < n and text[k] != '\n':
        if text[k] == '\\' and not raw: k += 2
        elif text[k] == '"':
          if raw and k + 1 < n and text[k + 1] == '"': k += 2
          else: break
        else: inc k
      if k >= n or text[k] != '"':
        ok = false
        return
      add(fkStr, st, k + 1)
      i = k + 1
      continue
    if c in {'0'..'9'}:
      var j = i
      while j < n and (text[j] in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or (text[j] >= '\x80' and fIdentAt(text, j)) or
                       (text[j] == '.' and j + 1 < n and text[j + 1] in {'0'..'9'}) or
                       (text[j] in {'+', '-'} and j > i and text[j - 1] in {'e', 'E'} and
                        not (text[i] == '0' and i + 1 < n and text[i + 1] in {'x', 'X'}))):
        inc j
      if j < n and text[j] == '\'':
        inc j
        while j < n and fIsIdent(text[j]): inc j
      add(fkNum, st, j)
      i = j
      continue
    if c == '\'':
      var j = i + 1
      if j < n and text[j] == '\\':
        j += 2
        while j < n and text[j] != '\'' and j - i < 12: inc j
      else: inc j
      if j >= n or text[j] != '\'':
        ok = false
        return
      add(fkChar, st, j + 1)
      i = j + 1
      continue
    if c == '`':
      let e = text.find('`', i + 1)
      if e < 0:
        ok = false
        return
      addT(fkIdent, st, fAccQuoted(text[st .. e]))
      col += (e + 1 - st) - result[^1].text.len      # (columns go on from where it ends in the text)
      i = e + 1
      continue
    case c
    of '(', '[':
      add(fkOpen, st, i + 1)
      inc i
      continue
    of '{':
      if i + 1 < n and text[i + 1] == '.' and not (i + 2 < n and text[i + 2] == '.'):
        add(fkPragOpen, st, i + 2)
        i += 2
      else:
        add(fkOpen, st, i + 1)
        inc i
      continue
    of ')', ']', '}':
      add(fkClose, st, i + 1)
      inc i
      continue
    of ',':
      add(fkComma, st, i + 1)
      inc i
      continue
    of ';':
      add(fkSemi, st, i + 1)
      inc i
      continue
    else: discard
    if c in FOpChars or (c in {'\194', '\195', '\226'} and fUniOpLen(text, i) > 0):
      if c == '.' and i + 1 < n and text[i + 1] == '}':
        add(fkPragClose, st, i + 2)
        i += 2
        continue
      var j = i
      while j < n:
        if text[j] in FOpChars: inc j
        elif text[j] in {'\194', '\195', '\226'} and fUniOpLen(text, j) > 0: j += fUniOpLen(text, j)
        else: break
      # `name*: T` — a colon ending an operator is the colon of a declaration
      if j - i > 1 and text[j - 1] == ':' and not (j - i == 2 and c == ':'): dec j
      if j - i == 1 and c == ':': add(fkColon, st, j)
      elif j - i == 1 and c == '.': add(fkDot, st, j)
      else:
        var lit = -1
        if j - i <= 3:
          for k, op in FCommonOps:
            if op.len == j - i and text.continuesWith(op, i):
              lit = k
              break
        if lit >= 0: addT(fkOp, st, FCommonOps[lit])       # a shared literal
        else: add(fkOp, st, j)
      i = j
      continue
    ok = false       # a character Nim does not have
    return

# is this token a word operator such as `and`, `or`, `div`, `in` or `of`?
func fWordOp*(t: FTok): bool {.inline.} = t.kind == fkKw and t.text in FWordOps

func fOperand*(t: FTok): bool {.inline.} =
  ## can this token end an operand (so an operator after it is binary)?
  t.kind in {fkIdent, fkNum, fkStr, fkChar, fkClose, fkPragClose} or
    (t.kind == fkKw and t.text in ["nil", "result"])

func fCallParen*(toks: openArray[FTok], k: int): bool =
  ## is the `(` at k a call's argument list (`f(x)`), not a parenthesized expression or tuple (`(x)`)?
  k > 0 and toks[k].text == "(" and not toks[k].sp and not toks[k].nl and
    toks[k - 1].kind in {fkIdent, fkClose}

func fNamesHead*(toks: openArray[FTok], colon: int, one = false): bool =
  ## `a, b*, c {.x.}:` — the names of a declaration before its type (more than one; with `one` one is enough)
  if colon < 1 or toks[0].kind != fkIdent: return false
  var d = 0
  var several = false
  var prevIdent = false
  for k in 0 ..< colon:
    let t = toks[k]
    if t.kind == fkPragOpen: inc d
    elif t.kind == fkPragClose: dec d
    elif d > 0: continue
    elif t.kind == fkComma:
      several = true
      prevIdent = false
    elif t.kind == fkOp and t.text == "*": discard
    elif t.kind == fkIdent:
      if prevIdent: return false            # `cmd a, b:` — a call with a block, not names
      prevIdent = true
    else: return false
  (several or one) and d == 0

func fTopColonAt*(toks: openArray[FTok]): int =
  ## the first `:` outside brackets, or -1
  var d = 0
  for k, t in toks:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkColon: return k
  -1

proc fValueIfOpen(l: FLine): bool =
  ## is `l` a statement given an if-expression (`let r = if a: …`, `x = when …`, `result.add if …`, `return if …`)
  ## whose last branch has its body on the lines under it (the line ends with that branch's `:`)?
  if l.comment or l.toks.len < 4: return false
  let t0 {.cursor.} = l.toks[0]
  if t0.kind == fkKw and (t0.text in FBlockKw or t0.text in FRoutineKw or t0.text == "case"): return false
  var e = l.toks.high
  while e > 0 and l.toks[e].kind == fkComment: dec e
  if l.toks[e].kind != fkColon: return false
  var d = 0
  for k, t in l.toks:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and k > 0 and t.kind == fkKw and t.text in ["if", "when"]:
      let p {.cursor.} = l.toks[k - 1]
      return (p.kind == fkOp and p.text == "=") or p.kind == fkIdent or
             (p.kind == fkKw and p.text in ["return", "yield", "discard"])
  false

proc fGroupLines*(toks: seq[FTok]): seq[FLine] =
  ## tokens → logical lines (a statement continued inside brackets or after an operator is one line)
  var cur: FLine
  var depth = 0
  var started = false
  var secInd = -1          # inside a var/let/const/type section: its indentation
  var blockInd = -1        # (a member opening a block — `x = f:` — its indentation: what is under it is code)
  result = newSeqOfCap[FLine](toks.len div 6 + 16)
  template noteSection() =
    ## after a line is complete: keeps track of the section (`var`, `let`, `const`, `type`) and of a member's block that
    ## the next lines belong to, by indentation
    # the line just completed (the last one in the result)
    template ll: untyped = result[^1]
    if not ll.comment:
      if blockInd >= 0 and ll.indent <= blockInd: blockInd = -1
      if ll.toks[0].kind == fkKw and ll.toks[0].text in ["var", "let", "const", "type"] and
         (ll.toks.len == 1 or ll.toks[1].kind == fkComment):
        secInd = ll.indent     # (`const ## doc` too)
        blockInd = -1
      elif ll.toks.len > 1 and ll.toks[0].kind == fkKw and ll.toks[0].text == "type" and
           ll.toks[^1].kind == fkKw and ll.toks[^1].text in ["object", "tuple"]:
        secInd = ll.indent     # type X = object  ⏎  its fields are a section's members too
        blockInd = -1
      elif ll.indent <= secInd: secInd = -1
      elif blockInd < 0:
        var e = ll.toks.high
        while e > 0 and ll.toks[e].kind == fkComment: dec e
        if ll.toks[e].kind == fkColon or (ll.toks[e].kind == fkOp and ll.toks[e].text == "="): blockInd = ll.indent
  for k in 0 ..< toks.len:
    let t {.cursor.} = toks[k]
    if t.nl and started:
      let last {.cursor.} = cur.toks[^1]
      var cont = depth > 0
      if not cont and not cur.comment:
        if t.kind == fkColon and cur.toks[0].kind == fkKw and
           cur.toks[0].text in ["while", "if", "elif", "when", "for"] and fTopColonAt(cur.toks) < 0:
          cont = true          # (a long condition's `:` on a line of its own, as nph writes a while's)
        elif last.kind == fkComma and t.col < cur.indent:
          cont = false         # `a,` ⏎ (less indented): a trailing comma ends an enum's values, not the next type
        elif last.kind == fkComma or last.kind == fkDot or
           (last.kind == fkOp and last.text != "=" and (last.text != "*" or last.sp)) or
           (fWordOp(last) and last.text notin ["of", "as"] and
            not (cur.toks.len >= 2 and cur.toks[^2].kind == fkDot)):     # (`x.not`: a call, not an operator)
          cont = true
        elif last.kind == fkComment and t.col >= cur.indent and (block:
               # `x = a and # note` ⏎ `b`, `x = a and` ⏎ `# note` ⏎ `b`: a value goes on after an operator
               # before the comments (an assignment's: laid out as nph does — fCommentValue)
               var li = cur.toks.high
               while li > 0 and cur.toks[li].kind == fkComment: dec li
               let lc {.cursor.} = cur.toks[li]
               var eq = false
               var dd = 0
               for q in 0 ..< li:
                 let u {.cursor.} = cur.toks[q]
                 if u.kind in {fkOpen, fkPragOpen}: inc dd
                 elif u.kind in {fkClose, fkPragClose}: dec dd
                 elif dd == 0 and u.kind == fkOp and u.text == "=": eq = true
                 elif u.kind == fkKw and u.text in FRoutineKw: eq = false
               # (deeper than the statement — or a value on the line after `x =`, deeper than that line; a
               # condition's operands, written at the `if`'s column too: like nph — fCommentCond)
               let cond = cur.toks[0].kind == fkKw and cur.toks[0].text in ["if", "elif", "while", "when"] and
                          fTopColonAt(cur.toks) < 0
               if cond: eq = true
               elif eq: eq = t.col > cur.indent
               elif not (cur.toks[0].kind == fkKw and (cur.toks[0].text in FBlockKw or
                                                       cur.toks[0].text in ["case", "return", "discard"])):
                 var p = result.high
                 while p >= 0 and result[p].comment: dec p
                 if p >= 0 and cur.indent > result[p].indent and t.col > result[p].indent:
                   var e = result[p].toks.high
                   while e > 0 and result[p].toks[e].kind == fkComment: dec e
                   eq = result[p].toks[e].kind == fkOp and result[p].toks[e].text == "="
                   # (not a routine's `=`: its body follows, statements)
                   for u in result[p].toks:
                     if u.kind == fkKw and u.text in FRoutineKw: eq = false
               eq and ((lc.kind == fkOp and lc.text != "=" and (lc.text != "*" or lc.sp)) or
                       (fWordOp(lc) and lc.text notin ["of", "as"]))):
          cont = true
        elif t.col > cur.indent and (t.kind == fkDot or (t.kind == fkKw and t.text in ["else", "elif"] and
             not (last.kind in {fkColon} or (last.kind == fkOp and last.text == "=")))):
          cont = true          # let z = if a: 1   ⏎   else: 2
        elif t.col > cur.indent and t.kind == fkColon and last.kind notin {fkColon, fkComment} and
             cur.toks[0].kind == fkKw and cur.toks[0].text in ["if", "elif", "while", "when", "of", "for", "except"]:
          cont = true          # if a and   ⏎   b   ⏎   :   (a condition's `:` on a line of its own ends it)
        elif t.col > cur.indent and last.kind == fkColon and cur.toks[0].kind == fkKw and
             cur.toks[0].text in FRoutineKw:
          cont = true          # proc f(a: int):   ⏎   tuple[x, y: int] =
        elif t.col > cur.indent and last.kind == fkKw and last.text == "import" and cur.toks[0].kind == fkKw and
             cur.toks[0].text == "from":
          cont = true          # from a import   ⏎   b, c
        elif t.col > cur.indent and last.kind == fkColon and secInd >= 0 and cur.indent > secInd and
             (blockInd < 0 or cur.indent <= blockInd) and
             fNamesHead(cur.toks, cur.toks.high, one = true):
          cont = true          # in a var/let/const/type section:  a, b*, c:   ⏎   seq[string] = @[]
        elif t.col > cur.indent and last.kind == fkColon and cur.toks.len > 2 and cur.toks[0].kind == fkKw and
             cur.toks[0].text in ["var", "let", "const"] and cur.toks[1].kind == fkIdent and
             fNamesHead(cur.toks.toOpenArray(1, cur.toks.high), cur.toks.high - 1, one = true):
          cont = true          # var a, b:   ⏎   T   (its type under it, like nph)
        elif t.col > cur.indent and t.kind == fkPragOpen and not (last.kind == fkOp and last.text == "=") and
             last.kind != fkColon and (block:
               var r = false
               for u in cur.toks:
                 if u.kind == fkKw and u.text in FRoutineKw: r = true
               r):
          cont = true          # proc f(): T   ⏎   {.raises: [].} =   ·   cb: proc(x: int)   ⏎   {.nimcall.}
      if t.kind == fkComment and not cont and depth == 0:
        discard
      if cont:
        if t.nl: inc cur.phys
        cur.toks.add t
        if t.kind == fkOpen or t.kind == fkPragOpen: inc depth
        elif t.kind == fkClose or t.kind == fkPragClose: depth = max(0, depth - 1)
        continue
      result.add move(cur)
      noteSection()
      started = false
    if not started:
      cur = FLine(toks: newSeqOfCap[FTok](16), indent: t.col, blank: t.blanks > 0, comment: t.kind == fkComment,
                  phys: 1)
      cur.toks.add t
      started = true
    else:
      cur.toks.add t
      if cur.comment and t.kind != fkComment: cur.comment = false
    if t.kind == fkOpen or t.kind == fkPragOpen: inc depth
    elif t.kind == fkClose or t.kind == fkPragClose: depth = max(0, depth - 1)
  if started: result.add move(cur)
  for l in result.mitems:
    # kept as written: a multi-line token — or statements inside brackets (a lambda's body, `do`, a
    # block, case or try written over several lines), where the line breaks are part of the code
    var d = 0
    var stmtAt = -1          # bracket depth where a statement-like construct started
    var stmtIf = false       # (it is an if/when: maybe an if-expression, `if a: x` ⏎ `else: y`)
    var lambdaAt = -1        # bracket depth of a `proc` that may be a lambda (until its `=`)
    var parenStmt = -1       # bracket depth of statements in parentheses (`(let a = f(); a > 0)`)
    var brackets: seq[char]  # (the open brackets)
    var prev {.cursor.}: FTok = nil
    for ti, t in l.toks:
      if t.multi: l.verbatim = true
      # (statements in parentheses a line apart, `(let a = f()` ⏎ `a > 0)`, no `;` between them: those line
      # breaks are the code's — and any line in `(…)` or `{…}` starting an operand right after one, `{` ⏎
      # `write(f, x)` ⏎ `write(f, y)` ⏎ `}` in a template's pattern)
      if t.nl and parenStmt >= 0 and d == parenStmt and t.kind != fkClose and prev != nil and fOperand(prev):
        l.verbatim = true
      if t.nl and brackets.len > 0 and brackets[^1] in {'(', '{'} and prev != nil and fOperand(prev) and
         (t.kind in {fkIdent, fkNum, fkStr, fkChar, fkOpen} or
          (t.kind == fkKw and not fWordOp(t) and t.text notin ["elif", "else", "of", "except", "finally", "do"])):
        l.verbatim = true
      if t.kind in {fkOpen, fkPragOpen}: brackets.add t.text[0]
      elif t.kind in {fkClose, fkPragClose} and brackets.len > 0: brackets.setLen(brackets.len - 1)
      # (an if-expression's `elif`/`else` on the next line after an inline branch: not a block, nor the bracket
      # that closes after it on a line of its own — a line break anywhere else after a statement started inside
      # brackets is part of the code)
      if t.nl and stmtAt >= 0 and
         not (stmtIf and d == stmtAt and t.kind == fkKw and t.text in ["elif", "else"] and prev != nil and
              prev.kind != fkColon) and
         # (an if-expression's condition going on after an operator, `if a and` ⏎ `b: x else: y`: a long line's)
         not (stmtIf and prev != nil and ((prev.kind == fkOp and prev.text != "=") or fWordOp(prev))) and
         not (stmtIf and d == stmtAt and t.kind == fkClose and t.text in [")", "]"] and prev != nil and
              prev.kind != fkColon):
        l.verbatim = true
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}:
        dec d
        if stmtAt > d: stmtAt = -1
        if lambdaAt > d: lambdaAt = -1
        if parenStmt > d: parenStmt = -1
      elif t.kind == fkKw:
        # (`quote do: f(` ⏎ `a, b)` on the statement's own level: the line breaks only wrap the body's call)
        if t.text == "do" and stmtAt < 0 and
           not (d == 0 and ti + 1 < l.toks.len and l.toks[ti + 1].kind == fkColon):
          stmtAt = d
          stmtIf = false
        elif d > 0 and t.text in FRoutineKw and lambdaAt < 0 and
             not (d == 1 and prev != nil and prev.kind == fkColon and l.toks[0].kind == fkKw and
                  l.toks[0].text in FRoutineKw):
          lambdaAt = d       # (not `cb: proc(x: int) = nil` in a routine's parameters: a type, and its default)
        elif d > 0 and t.text in ["block", "case", "try", "for", "while", "if", "when"] and stmtAt < 0:
          stmtAt = d
          stmtIf = t.text in ["if", "when"]
        elif d > 0 and parenStmt < 0 and (t.text in ["let", "const"] or
                                          (t.text == "var" and prev != nil and prev.kind in {fkOpen, fkSemi})):
          parenStmt = d
      elif t.kind == fkOp and t.text == "=" and lambdaAt == d and stmtAt < 0:
        stmtAt = d
        stmtIf = false
      elif t.kind == fkComma and d > 0 and d == stmtAt and stmtIf:
        stmtAt = -1          # (the if-expression ended: it was one argument)
      if t.kind != fkComment: prev = t
  # an if-expression kept as written whose last branch has its body on the lines under it (`let r = if a: 1` ⏎
  # `elif b: (if x:` ⏎ `y else: "")` ⏎ `elif c:` ⏎ `z` ⏎ `else: ""`): the rest of it, every line under the statement,
  # is kept with it — laid out apart, its later branches would go under the wrong line
  var i = 0
  while i < result.len:
    if result[i].verbatim and fValueIfOpen(result[i]):
      var last = i
      var j = i + 1
      while j < result.len and (result[j].comment or result[j].indent > result[i].indent):
        if not result[j].comment: last = j          # (a comment after it stays a line of its own)
        inc j
      if last > i:
        for k in i + 1 .. last:
          result[i].toks.add result[k].toks
          result[i].phys += result[k].phys
        let n = last - i
        for k in last + 1 ..< result.len: result[k - n] = move result[k]
        result.setLen(result.len - n)
    inc i

proc fOpensBlock*(l: FLine): bool =
  ## does the next deeper line belong to this one as a block?
  if l.comment or l.toks.len == 0: return false
  var k = l.toks.high
  while k > 0 and l.toks[k].kind == fkComment: dec k
  let t = l.toks[k]
  if t.kind == fkColon or (t.kind == fkOp and t.text == "="): return true
  if l.toks.len == 1 and t.kind == fkKw and (t.text in FSectionKw or t.text in ["import", "export", "include", "from"]): return true
  if t.kind == fkKw and t.text in ["object", "enum", "tuple", "concept"]: return true
  t.kind == fkKw and t.text in ["else", "try", "finally", "do"]

proc fDepths*(lines: var seq[FLine]) =
  ## block depth of every line from its indentation; comments do not open or close blocks
  var stack = @[0]
  var prevOpens = false
  var lastIndent = 0
  var lastDepth = 0
  for l in lines.mitems:
    if l.comment:
      var d = 0
      for k, s in stack:
        if s <= l.indent: d = k
      if l.indent > lastIndent: d = lastDepth + 1         # under the line before: one deeper
      elif l.indent == lastIndent: d = lastDepth
      l.depth = d
      continue
    while stack.len > 1 and l.indent < stack[^1]: stack.setLen(stack.len - 1)
    if l.indent > stack[^1]: stack.add l.indent
    l.depth = stack.high
    prevOpens = fOpensBlock(l)
    lastIndent = l.indent
    lastDepth = l.depth
  # `result.add if a:` ⏎ its body ⏎ `else:` written under the `if` (further right than the line): the branches at the
  # line's own depth, as nph writes them — an if-expression given to a command or `return` is laid out as a statement
  for i in 0 ..< lines.len:
    # the line looked at, by its index
    template l: untyped = lines[i]
    if l.comment or l.toks.len < 4 or l.toks[^1].kind != fkColon: continue
    var at = -1
    var d = 0
    for k, t in l.toks:
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      elif d == 0 and k > 0 and t.kind == fkKw and t.text in ["if", "when"]:
        at = k
        break
    if at < 0: continue
    let p = l.toks[at - 1]
    if not (p.kind == fkIdent or (at == 1 and p.kind == fkKw and p.text in ["return", "yield", "discard"])): continue
    var j = i + 1
    while j < lines.len and (lines[j].comment or lines[j].depth > l.depth + 1): inc j
    if j >= lines.len or lines[j].depth != l.depth + 1: continue      # (its body)
    inc j
    while j < lines.len:
      while j < lines.len and (lines[j].comment or lines[j].depth > l.depth + 1): inc j
      if j >= lines.len or lines[j].depth != l.depth + 1 or lines[j].toks[0].kind != fkKw or
         lines[j].toks[0].text notin ["elif", "else"]:
        break
      lines[j].depth -= 1
      inc j
      while j < lines.len and (lines[j].comment or lines[j].depth > l.depth + 1):
        if lines[j].depth > l.depth + 1: lines[j].depth -= 1
        inc j
  # comments written left of the statement after them, in its block (`#  x.flags = n.flags` at the margin inside
  # a routine): at that statement's depth — nph writes a comment with what follows it
  var next = -1                    # (the next code line's index)
  for i in countdown(lines.high, 0):
    # the line looked at, by its index
    template l: untyped = lines[i]
    if not l.comment:
      next = i
      continue
    if next < 0 or lines[next].depth == 0 or l.indent >= lines[next].indent or l.depth >= lines[next].depth: continue
    # (only between two statements: a code line before it, as deep as the next one or deeper)
    var p = i - 1
    while p >= 0 and lines[p].comment: dec p
    if p >= 0 and lines[p].depth >= lines[next].depth and not fOpensBlock(lines[p]):
      l.depth = lines[next].depth
  # a comment written deeper after one at the next statement's own level (`# if a:` ⏎ `  # b()` ⏎ `c()`): at that
  # level too — nph writes the comments before a statement as one block
  var i = 0
  while i < lines.len:
    if not lines[i].comment:
      inc i
      continue
    var j = i
    while j < lines.len and lines[j].comment: inc j
    if j < lines.len:
      let d = lines[j].depth
      var level = false               # (a comment of the run at the statement's level met)
      for k in i ..< j:
        if lines[k].depth == d: level = true
        elif level and lines[k].depth > d and lines[k].indent > lines[j].indent: lines[k].depth = d
    i = j
