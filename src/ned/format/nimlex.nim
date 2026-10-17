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
  FmtReflow* = false   # long ## doc comments re-wrapped at the line length

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

proc fKwIndex*(): array['a' .. 'y', seq[int]] =
  for i, k in FKeywords: result[k[0]].add i

const
  FKwByFirst* = fKwIndex()
  FCommonOps* = ["=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "&", "$", "@", "..", "..<", "+=",
                "-=", "*=", "&=", "->", "=>", "%", "|", "^", "!", "~", "::", "*:", "=~", "<<", ">>"]

proc fKeywordAt*(text: string, i, j: int): int =
  ## the keyword text[i ..< j] is (its index in FKeywords), or -1 — without making a string
  let c = text[i]
  if c notin {'a' .. 'y'} or j - i > 9: return -1
  for k in FKwByFirst[c]:
    let kw = FKeywords[k]
    if kw.len == j - i and text.continuesWith(kw, i): return k
  -1

proc fIsIdent*(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

proc fPunct*(c: char): string {.inline.} =
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
    if b - a == 1 and k in {fkOpen, fkClose, fkComma, fkSemi, fkColon, fkDot}:
      addT(k, a, fPunct(text[a]))           # a shared literal: no allocation
    else: addT(k, a, text[a ..< b])
  template addT(k: FKind, a: int, tt: string) =
    let t = tt
    # only long strings and block comments can span lines
    let nlAt = if k in {fkStr, fkComment}: t.rfind('\n') else: -1
    result.add FTok(kind: k, text: t, nl: not lineHasTok, col: col, sp: sp and lineHasTok, multi: nlAt >= 0,
                    blanks: (if not lineHasTok: blanks else: 0), pos: a)
    if not lineHasTok: blanks = 0
    lineHasTok = true
    sp = false
    # the column after a multi-line token is where its last line ends
    col = if nlAt >= 0: t.len - nlAt - 1 else: col + t.len
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
        while e > i and text[e - 1] in {' ', '\t', '\r'}: dec e
        add(fkComment, st, e)
        i = j
      continue
    if c == '"' or (fIsIdent(c) and not (c in {'0'..'9'})):
      var j = i
      var raw = false
      if c != '"':
        while j < n and fIsIdent(text[j]): inc j
        if j >= n or text[j] != '"':
          let kw = fKeywordAt(text, i, j)
          if kw >= 0: addT(fkKw, st, FKeywords[kw])          # a shared literal: no allocation
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
      while j < n and (fIsIdent(text[j]) or (text[j] == '.' and j + 1 < n and text[j + 1] in {'0'..'9'}) or
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
      add(fkIdent, st, e + 1)
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
    if c in FOpChars:
      if c == '.' and i + 1 < n and text[i + 1] == '}':
        add(fkPragClose, st, i + 2)
        i += 2
        continue
      var j = i
      while j < n and text[j] in FOpChars: inc j
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

proc fWordOp*(t: FTok): bool {.inline.} = t.kind == fkKw and t.text in FWordOps

proc fOperand*(t: FTok): bool {.inline.} =
  ## can this token end an operand (so an operator after it is binary)?
  t.kind in {fkIdent, fkNum, fkStr, fkChar, fkClose, fkPragClose} or
    (t.kind == fkKw and t.text in ["nil", "result"])

proc fCallParen*(toks: openArray[FTok], k: int): bool =
  ## is the `(` at k a call's argument list (`f(x)`), not a parenthesized expression or tuple (`(x)`)?
  k > 0 and toks[k].text == "(" and not toks[k].sp and not toks[k].nl and
    toks[k - 1].kind in {fkIdent, fkClose}

proc fNamesHead*(toks: openArray[FTok], colon: int): bool =
  ## `a, b*, c {.x.}:` — the names of a declaration before its type (more than one, or exported)
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
  several and d == 0

proc fGroupLines*(toks: seq[FTok]): seq[FLine] =
  ## tokens → logical lines (a statement continued inside brackets or after an operator is one line)
  var cur: FLine
  var depth = 0
  var started = false
  var secInd = -1          # inside a var/let/const/type section: its indentation
  template noteSection() =
    let ll = result[^1]
    if not ll.comment:
      if ll.toks[0].kind == fkKw and ll.toks[0].text in ["var", "let", "const", "type"] and
         (ll.toks.len == 1 or ll.toks[1].kind == fkComment):
        secInd = ll.indent     # (`const ## doc` too)
      elif ll.toks.len > 1 and ll.toks[0].kind == fkKw and ll.toks[0].text == "type" and
           ll.toks[^1].kind == fkKw and ll.toks[^1].text in ["object", "tuple"]:
        secInd = ll.indent     # type X = object  ⏎  its fields are a section's members too
      elif ll.indent <= secInd: secInd = -1
  for k, t in toks:
    if t.nl and started:
      let last = cur.toks[^1]
      var cont = depth > 0
      if not cont and not cur.comment:
        if last.kind == fkComma and t.col < cur.indent:
          cont = false         # `a,` ⏎ (less indented): a trailing comma ends an enum's values, not the next type
        elif last.kind == fkComma or last.kind == fkDot or (last.kind == fkOp and last.text != "=" and last.text != "*") or
           (fWordOp(last) and last.text notin ["of", "as"]):
          cont = true
        elif t.col > cur.indent and (t.kind == fkDot or (t.kind == fkKw and t.text in ["else", "elif"] and
             not (last.kind in {fkColon} or (last.kind == fkOp and last.text == "=")))):
          cont = true          # let z = if a: 1   ⏎   else: 2
        elif t.col > cur.indent and last.kind == fkColon and cur.toks[0].kind == fkKw and
             cur.toks[0].text in FRoutineKw:
          cont = true          # proc f(a: int):   ⏎   tuple[x, y: int] =
        elif t.col > cur.indent and last.kind == fkKw and last.text == "import" and cur.toks[0].kind == fkKw and
             cur.toks[0].text == "from":
          cont = true          # from a import   ⏎   b, c
        elif t.col > cur.indent and last.kind == fkColon and secInd >= 0 and cur.indent > secInd and
             fNamesHead(cur.toks, cur.toks.high):
          cont = true          # in a var/let/const/type section:  a, b*, c:   ⏎   seq[string] = @[]
        elif t.col > cur.indent and t.kind == fkPragOpen and cur.toks[0].kind == fkKw and
             cur.toks[0].text in FRoutineKw and not (last.kind == fkOp and last.text == "="):
          cont = true          # proc f(): T   ⏎   {.raises: [].} =
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
      cur = FLine(toks: @[t], indent: t.col, blank: t.blanks > 0, comment: t.kind == fkComment, phys: 1)
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
    var prev: FTok = nil
    for t in l.toks:
      if t.multi: l.verbatim = true
      # (an if-expression's `elif`/`else` on the next line after an inline branch: not a block — a line break
      # anywhere else after a statement started inside brackets is part of the code)
      if t.nl and stmtAt >= 0 and not (stmtIf and d == stmtAt and t.kind == fkKw and t.text in ["elif", "else"] and
                                       prev != nil and prev.kind != fkColon):
        l.verbatim = true
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}:
        dec d
        if stmtAt > d: stmtAt = -1
        if lambdaAt > d: lambdaAt = -1
      elif t.kind == fkKw:
        if t.text == "do" and stmtAt < 0:
          stmtAt = d
          stmtIf = false
        elif d > 0 and t.text in FRoutineKw and lambdaAt < 0: lambdaAt = d
        elif d > 0 and t.text in ["block", "case", "try", "for", "while", "if", "when"] and stmtAt < 0:
          stmtAt = d
          stmtIf = t.text in ["if", "when"]
      elif t.kind == fkOp and t.text == "=" and lambdaAt == d and stmtAt < 0:
        stmtAt = d
        stmtIf = false
      elif t.kind == fkComma and d > 0 and d == stmtAt and stmtIf:
        stmtAt = -1          # (the if-expression ended: it was one argument)
      if t.kind != fkComment: prev = t

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
