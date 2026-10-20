## ── ned's own JavaScript: its tokens (template and regex literals and all), the names a script declares and where
##    they are seen (block scopes by braces), what fits at the cursor (the members of console., Math., document.,
##    of an instance of a class of the file, of this. …), what a name is, where it is declared, and the mistakes
##    worth a word: a bracket never closed, let/const declared twice, a const assigned, a name nothing uses, ==
##    against a literal, a misspelled name. It works on a document's lines — JS in a .js file, in an HTML
##    <script>, in a Nim string (its text at its own columns, the rest blank) ──

import std/[strutils, sets, tables, algorithm]
import jsdata, webcommon

type
  JsTokKind* = enum jtIdent, jtNumber, jtString, jtTemplate, jtRegex, jtPunct, jtPrivate, jtComment
  JsTok* = object
    kind*: JsTokKind
    text*: string              # a template literal in pieces: "`a${", "}b${", "}c`" (or "`abc`" whole)
    line*, col*: int           # where it starts
    eline*, ecol*: int         # where it ends (just after it)
    open*: bool                # a string, template or comment the text never ends (a // comment: always)
    nl*: bool                  # a line break before it, since the code token before (comments do not count)
  JsDeclKind* = enum
    jdVar = "var", jdLet = "let", jdConst = "const", jdFunction = "function", jdClass = "class",
    jdParam = "parameter", jdImport = "import", jdMethod = "method", jdField = "field"
  JsDecl* = object             # a name the document declares
    name*: string
    kind*: JsDeclKind
    line*, col*: int
    params*: string            # a function or method's: "(a, b = 1)"
    owner*: string             # a method or field: its class's name
    typ*: string               # what its value is, when that shows: "String", "Array", "Element", a class's name,
                               # "function", "class" or "object"
    tok, scope, cls: int       # its token, the scope it is seen in, its class (a member, a class, a class's const)
    keys: seq[string]          # an object literal's keys ("name()" for a method)
    exported, isStatic, inner, getter, restSibling: bool   # inner: a function or class expression's own name
  ScopeKind = enum skProgram, skFunction, skArrowFn, skBlock, skClass, skArrow
  Scope = object
    kind: ScopeKind            # skArrow: an arrow function without braces (its parameters and expression)
    parent: int
    a, b: int                  # its first and last token
    closed: bool               # t[b] is the bracket that closes it
  ClassInfo = object
    name, base: string
    body: int                  # its body's `{`, then its scope (-1 none)
  JsDoc = object               # a document, read
    all, t: seq[JsTok]         # every token; the code's (no comments)
    fwd, back: seq[int]        # an opening bracket → the one that closes it, and back
    braces: seq[WebDiag]       # the brackets that close nothing or never close
    scopes: seq[Scope]
    scopeOf: seq[int]          # each code token → the innermost scope it is in
    braceScope, arrowScope: Table[int, int]    # a `{`, a `=>` without braces → the scope it starts
    bodyClass, classAt: Table[int, int]        # a class body's scope, a `class` token → the class
    staticBody: HashSet[int]   # the scopes of static methods
    classes: seq[ClassInfo]
    decls, members: seq[JsDecl]
    byScope: seq[seq[int]]     # each scope → its declarations, in order
    names: seq[Table[string, int]]             # each scope → name → its first declaration
    isDef: seq[bool]           # tokens that name what is declared, keys, labels: not uses
    refs: seq[(int, int)]      # (a use's token, the declaration it means or -1)
    used: seq[bool]            # each declaration: something uses it
    module: bool               # has import, export or require: its top level is its own
  Recv = object                # what is before a `.`, as far as its members go
    owners: seq[string]        # built-in members that fit: "Array.prototype", "document" …
    cls: int                   # a class of the document (-1)
    statics: bool              # the class itself, not an instance
    keys: seq[string]          # an object literal's keys

const
  Reserved = ["break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
              "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new",
              "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while",
              "with", "enum"]
  Contextual = ["let", "static", "async", "await", "yield", "of", "get", "set", "from", "as", "accessor"]
  Puncts = [">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=", "=>", "==", "!=", "<=",
            ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>"]
  AssignOps = ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??="]
  RegexAfter = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
                "yield", "await"]           # (after these words a `/` starts a regex; after other names it divides)
  NotEnds = ["return", "typeof", "new", "delete", "void", "throw", "in", "of", "instanceof", "case", "await", "yield",
             "else", "do", "extends"]
  ElementOwners = ["HTMLElement.prototype", "Element.prototype", "Node.prototype", "EventTarget.prototype"]
  ElementMakers = ["querySelector", "getElementById", "createElement", "createElementNS", "closest",
                   "elementFromPoint", "insertAdjacentElement"]
  ElementProps = ["body", "head", "documentElement", "activeElement", "parentElement", "firstElementChild",
                  "lastElementChild", "nextElementSibling", "previousElementSibling", "target", "currentTarget"]
  ArrayMakers = ["split", "map", "filter", "flat", "flatMap", "toSorted", "toReversed", "toSpliced"]
  StringMakers = ["join", "toUpperCase", "toLowerCase", "trim", "trimStart", "trimEnd", "padStart", "padEnd", "repeat",
                  "replace", "replaceAll", "toFixed", "toPrecision", "toISOString", "stringify", "substring", "charAt",
                  "toLocaleDateString", "toLocaleTimeString"]
  PromiseStatics = ["all", "allSettled", "any", "race", "resolve", "reject"]
  Mdn = "https://developer.mozilla.org/docs/Web/"

func isIdStart(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '_', '$'} or ord(c) >= 0x80
func isIdChar(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '$'} or ord(c) >= 0x80

# ── the tokens ──

proc regexMayStart(toks: seq[JsTok], prev: int): bool =
  ## whether a `/` after the token `prev` starts a regex literal (else it divides)
  if prev < 0: return true
  let p = toks[prev]
  case p.kind
  of jtIdent: p.text in RegexAfter
  of jtPunct: p.text notin [")", "]", "++", "--"]
  of jtTemplate: p.text.endsWith("${")
  else: false

func tplEnd(s: string, i: int): (int, int) =
  ## from i in a template's text: (where it stops, how) — 1 at its closing `, 2 at a ${, 0 at the line's end
  var k = i
  while k < s.len:
    case s[k]
    of '\\': k += 2
    of '`': return (k + 1, 1)
    of '$':
      if k + 1 < s.len and s[k + 1] == '{': return (k + 2, 2)
      inc k
    else: inc k
  (s.len, 0)

func numberEnd(s: string, i: int): int =
  ## after the number at i: 0x1F, 0b1010, 1_000, 1.5e-3, .5, 10n
  var e = i
  if s[i] == '0' and i + 1 < s.len and s[i + 1] in {'x', 'X', 'b', 'B', 'o', 'O'}:
    e = i + 2
    while e < s.len and s[e] in HexDigits + {'_'}: inc e
  else:
    while e < s.len and s[e] in Digits + {'_'}: inc e
    if e < s.len and s[e] == '.':
      inc e
      while e < s.len and s[e] in Digits + {'_'}: inc e
    if e < s.len and s[e] in {'e', 'E'}:
      var k = e + 1
      if k < s.len and s[k] in {'+', '-'}: inc k
      if k < s.len and s[k] in Digits:
        e = k
        while e < s.len and s[e] in Digits + {'_'}: inc e
  if e < s.len and s[e] == 'n': inc e
  e

func regexEnd(s: string, i: int): int =
  ## after the regex literal whose `/` is at i, flags and all (-1: no closing `/` on the line)
  var e = i + 1
  var cls = false
  while e < s.len:
    let c = s[e]
    if c == '\\':
      e += 2
      continue
    if cls:
      if c == ']': cls = false
    elif c == '[': cls = true
    elif c == '/': break
    inc e
  if e >= s.len: return -1
  inc e
  while e < s.len and s[e] in {'a'..'z'}: inc e
  e

proc jsTokens*(lines: openArray[string]): seq[JsTok] =
  ## the JS's tokens, comments too: a template literal is cut into its pieces of text ("`a${", "}b`") with the
  ## tokens of each ${…} between them; a `/` is a regex or a division by the token before it
  var stack: seq[char]                 # each open `{`: 'b' a block or an object, 't' a template's ${
  var cur: JsTok                       # a token going on over lines: a /* comment */, a template's text
  var inBlock, inTpl = false
  var prev = -1                        # the last token that is not a comment
  for l in 0 .. lines.high:
    let s = lines[l]
    var i = 0
    template nl(): bool = prev < 0 or result[prev].eline < l
    template add(k: JsTokKind, a, e: int, isOpen = false) =
      let x = JsTok(kind: k, text: s[a ..< e], line: l, col: a, eline: l, ecol: e, open: isOpen, nl: nl())
      if k != jtComment: prev = result.len
      result.add x
    template finish(e: int) =
      cur.eline = l
      cur.ecol = e
      if cur.kind != jtComment: prev = result.len
      result.add cur
    # what goes on from the line before
    if inBlock:
      let e = s.find("*/")
      if e < 0:
        cur.text.add "\n" & s
        continue
      cur.text.add "\n" & s[0 ..< e + 2]
      inBlock = false
      finish(e + 2)
      i = e + 2
    elif inTpl:
      let (e, how) = tplEnd(s, 0)
      cur.text.add "\n" & s[0 ..< e]
      if how == 0: continue
      inTpl = false
      if how == 2: stack.add 't'
      finish(e)
      i = e
    while i < s.len:
      let c = s[i]
      if c in {' ', '\t', '\r', '\f', '\v'}:
        inc i
        continue
      if c == '/' and i + 1 < s.len and s[i + 1] == '/':
        add(jtComment, i, s.len, true)
        break
      if c == '/' and i + 1 < s.len and s[i + 1] == '*':
        let e = s.find("*/", i + 2)
        if e < 0:
          cur = JsTok(kind: jtComment, text: s[i .. ^1], line: l, col: i, nl: nl())
          inBlock = true
          break
        add(jtComment, i, e + 2)
        i = e + 2
        continue
      if c == '#' and l == 0 and i == 0 and s.startsWith("#!"):
        add(jtComment, 0, s.len, true)
        break
      if c in {'"', '\''}:
        var e = i + 1
        while e < s.len and s[e] != c: e += (if s[e] == '\\': 2 else: 1)
        if e < s.len: add(jtString, i, e + 1)
        else: add(jtString, i, s.len, true)
        i = e + 1
        continue
      if c == '`' or (c == '}' and stack.len > 0 and stack[^1] == 't'):
        if c == '}': stack.setLen(stack.len - 1)
        cur = JsTok(kind: jtTemplate, line: l, col: i, nl: nl())
        let (e, how) = tplEnd(s, i + 1)
        cur.text = s[i ..< e]
        if how == 0:
          inTpl = true
          break
        if how == 2: stack.add 't'
        finish(e)
        i = e
        continue
      if isIdStart(c):
        var e = i + 1
        while e < s.len and isIdChar(s[e]): inc e
        add(jtIdent, i, e)
        i = e
        continue
      if c in Digits or (c == '.' and i + 1 < s.len and s[i + 1] in Digits):
        let e = numberEnd(s, i)
        add(jtNumber, i, e)
        i = e
        continue
      if c == '#' and i + 1 < s.len and isIdStart(s[i + 1]):
        var e = i + 2
        while e < s.len and isIdChar(s[e]): inc e
        add(jtPrivate, i, e)
        i = e
        continue
      if c == '/' and regexMayStart(result, prev):
        let e = regexEnd(s, i)
        if e > 0:
          add(jtRegex, i, e)
          i = e
          continue
      var p = 1
      for x in Puncts:
        if s.continuesWith(x, i) and not (x == "?." and i + 2 < s.len and s[i + 2] in Digits):
          p = x.len
          break
      if c == '{': stack.add 'b'
      elif c == '}' and stack.len > 0: stack.setLen(stack.len - 1)
      add(jtPunct, i, i + p)
      i += p
  if (inBlock or inTpl) and lines.len > 0:
    # a comment or template the text never ends
    cur.open = true
    cur.eline = lines.high
    cur.ecol = lines[^1].len
    result.add cur

func inside(x: JsTok, line, col: int): bool =
  ## whether a place is in a string, comment, regex or a template's text (not at its edges)
  x.kind in {jtString, jtTemplate, jtRegex, jtComment} and posLess(x.line, x.col, line, col) and
    (posLess(line, col, x.eline, x.ecol) or (x.open and not posLess(x.eline, x.ecol, line, col)))

proc jsInCode*(lines: openArray[string], line, col: int): bool =
  ## whether (line, col) is in code: not in a string, a comment, a regex or a template's text (its ${…} is code)
  for x in jsTokens(lines):
    if x.line > line: break
    if x.inside(line, col): return false
  true

# ── reading the tokens ──

func word(d: JsDoc, k: int): string =
  ## the identifier at token k ("" for anything else)
  if k >= 0 and k < d.t.len and d.t[k].kind == jtIdent: d.t[k].text else: ""

func punct(d: JsDoc, k: int, p: string): bool =
  k >= 0 and k < d.t.len and d.t[k].kind == jtPunct and d.t[k].text == p

func afterDot(d: JsDoc, k: int): bool =
  ## a property's name: `x.name`, `x?.name`
  d.punct(k - 1, ".") or d.punct(k - 1, "?.")

func kw(d: JsDoc, k: int, w: string): bool =
  ## the word w at token k, not a property named so
  d.word(k) == w and not d.afterDot(k)

func endsExpr(x: JsTok): bool =
  ## whether an expression can end with the token (then a line break after it may end the statement)
  case x.kind
  of jtIdent: x.text notin NotEnds
  of jtNumber, jtString, jtRegex, jtPrivate: true
  of jtTemplate: x.text.len >= 2 and x.text.endsWith("`")
  of jtPunct: x.text in [")", "]", "}", "++", "--"]
  of jtComment: false

func startsStmt(x: JsTok): bool =
  ## whether a token on a new line, after an expression that may end, starts the next statement
  x.kind in {jtIdent, jtNumber, jtString, jtPrivate} and x.text notin ["in", "of", "instanceof"]

func span(d: JsDoc, a, b: int): string =
  ## the text of tokens a..b, spaced as written
  for k in max(a, 0) .. min(b, d.t.high):
    if k > a and (d.t[k - 1].eline != d.t[k].line or d.t[k - 1].ecol < d.t[k].col): result.add ' '
    result.add d.t[k].text

func skipTemplate(d: JsDoc, k: int): int =
  ## from a template's piece that opens a ${ at k: its last piece (-1 when it never closes)
  var m = k
  while d.t[m].kind == jtTemplate and d.t[m].text.endsWith("${"):
    if d.fwd[m] < 0: return -1
    m = d.fwd[m]
  m

func exprEnd(d: JsDoc, k: int, comma = true): int =
  ## the last token of the expression from k: up to a `;`, a `,` (comma), a bracket closing what it is in, or a
  ## line break where a new statement starts (k - 1 when there is none)
  var j = k
  var last = k - 1
  while j < d.t.len:
    let x = d.t[j]
    if j > k and x.nl and endsExpr(d.t[j - 1]) and startsStmt(x): return last
    if x.kind == jtPunct:
      case x.text
      of ")", "]", "}", ";": return last
      of ",":
        if comma: return last
      of "(", "[", "{":
        if d.fwd[j] < 0: return d.t.high
        last = d.fwd[j]
        j = last + 1
        continue
      else: discard
    elif x.kind == jtTemplate:
      if x.text.startsWith("}"): return last           # (the end of the ${…} it is in)
      if x.text.endsWith("${"):
        let m = d.skipTemplate(j)
        if m < 0: return d.t.high
        last = m
        j = m + 1
        continue
    last = j
    inc j
  last

func stmtEnd(d: JsDoc, k: int, depth = 0): int =
  ## the last token of the statement from k — a for's body without braces: a block, an if with its else, a loop,
  ## a try with its catch and finally, or an expression up to its `;`
  if k >= d.t.len or depth > 64: return d.t.high
  if d.punct(k, "{"): return (if d.fwd[k] >= 0: d.fwd[k] else: d.t.high)
  if d.punct(k, ";"): return k
  template paren(j: int): int = (if d.punct(j, "(") and d.fwd[j] >= 0: d.fwd[j] else: -1)
  case d.word(k)
  of "if":
    let q = paren(k + 1)
    if q >= 0:
      result = d.stmtEnd(q + 1, depth + 1)
      if d.word(result + 1) == "else": result = d.stmtEnd(result + 2, depth + 1)
      return
  of "for", "while", "with":
    let q = paren(if d.word(k + 1) == "await": k + 2 else: k + 1)
    if q >= 0: return d.stmtEnd(q + 1, depth + 1)
  of "do":
    result = d.stmtEnd(k + 1, depth + 1)
    if d.word(result + 1) == "while":
      let q = paren(result + 2)
      if q >= 0: result = (if d.punct(q + 1, ";"): q + 1 else: q)
    return
  of "try":
    result = d.stmtEnd(k + 1, depth + 1)
    if d.word(result + 1) == "catch":
      let q = paren(result + 2)
      result = d.stmtEnd((if q >= 0: q + 1 else: result + 2), depth + 1)
    if d.word(result + 1) == "finally": result = d.stmtEnd(result + 2, depth + 1)
    return
  of "switch":
    let q = paren(k + 1)
    if q >= 0: return d.stmtEnd(q + 1, depth + 1)
  else: discard
  result = d.exprEnd(k, comma = false)
  if d.punct(result + 1, ";"): inc result

func entryEnd(d: JsDoc, j, e: int): int =
  ## the `,` that ends a list's entry from token j (or e, the list's closing bracket)
  var k = j
  while k < e:
    let x = d.t[k]
    if x.kind == jtPunct:
      if x.text == ",": return k
      if x.text in ["(", "[", "{"] and d.fwd[k] > k and d.fwd[k] < e: k = d.fwd[k]
    elif x.kind == jtTemplate and x.text.endsWith("${"):
      let m = d.skipTemplate(k)
      if m > k and m < e: k = m
    inc k
  e

func findAt(d: JsDoc, j, e: int, p: string): int =
  ## the punctuation p between tokens j and e, not inside brackets (-1 none)
  var k = j
  while k < e:
    if d.punct(k, p): return k
    if d.t[k].kind == jtPunct and d.t[k].text in ["(", "[", "{"] and d.fwd[k] > k and d.fwd[k] < e: k = d.fwd[k]
    inc k
  -1

# ── the brackets and the scopes ──

func openerOf(x: JsTok): string = (if x.kind == jtTemplate: "${" else: x.text)

proc matchBrackets(d: var JsDoc) =
  ## pairs the brackets — ( [ { and a template's ${ } — and notes those that close nothing or never close
  let n = d.t.len
  d.fwd = newSeq[int](n)
  d.back = newSeq[int](n)
  for i in 0 ..< n:
    d.fwd[i] = -1
    d.back[i] = -1
  proc diag(x: JsTok, msg: string): WebDiag =
    let (l, c) = if x.kind == jtTemplate: (x.eline, x.ecol - 2) else: (x.line, x.col)
    WebDiag(line: l, col: c, eline: l, ecol: c + (if x.kind == jtTemplate: 2 else: 1), sev: 1, rule: "js-brace",
            msg: msg)
  var st: seq[int]
  for i in 0 ..< n:
    let x = d.t[i]
    var want = ""
    if x.kind == jtPunct and x.text in [")", "]", "}"]:
      want = (if x.text == ")": "(" elif x.text == "]": "[" else: "{")
    elif x.kind == jtTemplate and x.text.startsWith("}"):
      want = "${"
    if want.len > 0:
      var k = st.high
      while k >= 0 and openerOf(d.t[st[k]]) != want: dec k
      if k < 0:
        d.braces.add diag(x, "'" & x.text[0] & "' closes nothing")
      else:
        for m in k + 1 .. st.high:
          d.braces.add diag(d.t[st[m]], "'" & openerOf(d.t[st[m]]) & "' is never closed")
        d.fwd[st[k]] = i
        d.back[i] = st[k]
        st.setLen(k)
    if (x.kind == jtPunct and x.text in ["(", "[", "{"]) or (x.kind == jtTemplate and x.text.endsWith("${")):
      st.add i
  for k in st: d.braces.add diag(d.t[k], "'" & openerOf(d.t[k]) & "' is never closed")

proc findClasses(d: var JsDoc) =
  ## each `class`: its name, what it extends, its body's `{`
  for i in 0 ..< d.t.len:
    if not d.kw(i, "class") or d.punct(i + 1, ":"): continue      # (`{ class: … }`: a key)
    var c = ClassInfo(body: -1)
    var k = i + 1
    if d.word(k).len > 0 and d.word(k) != "extends":
      c.name = d.word(k)
      inc k
    if d.word(k) == "extends":
      inc k
      while k < d.t.len and not d.punct(k, "{"):
        if d.t[k].kind == jtPunct and d.t[k].text in ["(", "["] and d.fwd[k] > k: k = d.fwd[k]
        elif d.t[k].kind == jtIdent: c.base = d.t[k].text
        inc k
    if d.punct(k, "{"): c.body = k
    d.classAt[i] = d.classes.len
    d.classes.add c

func braceKind(d: JsDoc, i: int): ScopeKind =
  ## what a `{` opens, by what stands before it: a function's body, an arrow function's, or a block (an object
  ## literal counts as one: nothing is declared in it)
  if d.punct(i - 1, "=>"): return skArrowFn
  if d.punct(i - 1, ")") and d.back[i - 1] >= 0:
    let o = d.back[i - 1]
    let w = if d.afterDot(o - 1): "" else: d.word(o - 1)
    if w in ["if", "while", "switch", "with", "catch", "for"] or (w == "await" and d.word(o - 2) == "for"):
      return skBlock
    return skFunction
  skBlock

proc addScope(d: var JsDoc, kind: ScopeKind, a, b: int, closed: bool): int =
  d.scopes.add Scope(kind: kind, parent: -1, a: a, b: max(a, b), closed: closed)
  d.scopes.high

proc buildScopes(d: var JsDoc) =
  ## the scopes — the program, each { } (a function from its parameters on, a class's body, a block), a for from
  ## its head to its body's end, an arrow function without braces — each one's parent, each token's innermost
  let n = d.t.len
  discard d.addScope(skProgram, 0, n - 1, false)
  var bodyOf: Table[int, int]                     # a class's `{` → the class
  for ci, c in d.classes:
    if c.body >= 0: bodyOf[c.body] = ci
  for i in 0 ..< n:
    let x = d.t[i]
    if x.kind == jtPunct and x.text == "{":
      let closed = d.fwd[i] >= 0
      let kind = if i in bodyOf: skClass else: d.braceKind(i)
      var a = i
      if kind == skFunction: a = d.back[i - 1]
      elif kind == skArrowFn:
        if d.punct(i - 2, ")") and d.back[i - 2] >= 0: a = d.back[i - 2]
        elif d.word(i - 2).len > 0: a = i - 2
      let s = d.addScope(kind, a, (if closed: d.fwd[i] else: n - 1), closed)
      d.braceScope[i] = s
      if kind == skClass:
        d.classes[bodyOf[i]].body = s
        d.bodyClass[s] = bodyOf[i]
    elif d.kw(i, "for"):
      let p = if d.word(i + 1) == "await": i + 2 else: i + 1
      if d.punct(p, "(") and d.fwd[p] >= 0:
        let q = d.fwd[p]
        if d.punct(q + 1, "{") and d.fwd[q + 1] >= 0: discard d.addScope(skBlock, i, d.fwd[q + 1], true)
        else: discard d.addScope(skBlock, i, d.stmtEnd(q + 1), false)
    elif x.kind == jtPunct and x.text == "=>" and not d.punct(i + 1, "{"):
      let a = if d.punct(i - 1, ")") and d.back[i - 1] >= 0: d.back[i - 1] else: max(0, i - 1)
      d.arrowScope[i] = d.addScope(skArrow, a, d.exprEnd(i + 1), false)
  for ci, c in d.classes:
    if c.body >= 0 and c.body notin d.bodyClass: d.classes[ci].body = -1
  # parents: by where each starts (the outer first when two start together)
  var order: seq[(int, int, int)]
  for s in 1 .. d.scopes.high: order.add (d.scopes[s].a, -d.scopes[s].b, s)
  order.sort()
  d.scopeOf = newSeq[int](n)
  var st = @[0]
  var o = 0
  for k in 0 ..< n:
    while st.len > 1 and d.scopes[st[^1]].b < k: st.setLen(st.len - 1)
    while o < order.len and order[o][0] <= k:
      let s = order[o][2]
      d.scopes[s].parent = st[^1]
      d.scopes[s].b = min(d.scopes[s].b, d.scopes[st[^1]].b)      # (kept inside its parent)
      st.add s
      inc o
    d.scopeOf[k] = st[^1]

func enclosingClass(d: JsDoc, k: int): (int, bool) =
  ## the class whose method (or field) token k is in — through arrow functions, not through a `function` — and
  ## whether that method is static
  var s = if k >= 0 and k < d.scopeOf.len: d.scopeOf[k] else: 0
  var fn = -1
  while s > 0:
    case d.scopes[s].kind
    of skClass: return (d.bodyClass.getOrDefault(s, -1), fn >= 0 and fn in d.staticBody)
    of skFunction:
      if fn >= 0: return (-1, false)
      fn = s
    else: discard
    s = d.scopes[s].parent
  (-1, false)

# ── the declarations ──

proc declare(d: var JsDoc, k: int, kind: JsDeclKind, scope: int): int =
  ## the name at token k declared, seen in a scope
  d.isDef[k] = true
  d.decls.add JsDecl(name: d.t[k].text, kind: kind, line: d.t[k].line, col: d.t[k].col, tok: k, scope: scope, cls: -1)
  d.decls.high

proc addMember(d: var JsDoc, ci, k: int, name: string, kind: JsDeclKind): int =
  ## a method or field of a class, named at token k
  if d.t[k].kind == jtIdent: d.isDef[k] = true
  d.members.add JsDecl(name: name, kind: kind, line: d.t[k].line, col: d.t[k].col, tok: k, scope: -1, cls: ci,
                       owner: d.classes[ci].name)
  d.members.high

func declScope(d: JsDoc, k: int, kind: JsDeclKind): int =
  ## the scope of a declaration whose statement starts at token k: its block (a var's: its function's)
  var s = d.scopeOf[k]
  while s > 0 and d.scopes[s].kind in {skArrow, skClass}: s = d.scopes[s].parent
  if kind == jdVar:
    while s > 0 and d.scopes[s].kind notin {skFunction, skArrowFn}: s = d.scopes[s].parent
  s

func inExpr(d: JsDoc, i: int): bool =
  ## whether the `function` or `class` at token i is an expression — its name seen only inside it
  var p = i - 1
  if d.word(p) == "async": dec p
  if p < 0: return false
  let x = d.t[p]
  if d.t[p + 1].nl and endsExpr(x): return false               # (a new statement on a new line)
  case x.kind
  of jtPunct: x.text notin [";", "{", "}", ")"]
  of jtIdent: x.text in ["return", "yield", "await", "typeof", "new", "void", "delete", "in", "of", "instanceof",
                         "case", "throw", "extends"]
  of jtTemplate: x.text.endsWith("${")
  else: false

func exportedAt(d: JsDoc, i: int): bool =
  ## `export` (`export default`, `export async`) before the declaration at token i
  var p = i - 1
  if d.word(p) == "async": dec p
  if d.word(p) == "default": dec p
  d.word(p) == "export"

proc bindPattern(d: var JsDoc, k: int, kind: JsDeclKind, scope: int, got: var seq[int]): int =
  ## declares the names a binding at token k makes — a name, {a, b: c, ...d} or [x, , ...y], defaults and all —
  ## and gives the token after it
  if k >= d.t.len: return k
  let x = d.t[k]
  if x.kind == jtIdent:
    if x.text notin Reserved: got.add d.declare(k, kind, scope)
    return k + 1
  if x.kind != jtPunct or x.text notin ["{", "["] or d.fwd[k] < 0: return k + 1
  let e = d.fwd[k]
  let first = got.len
  var rest = false
  var j = k + 1
  while j < e:
    let ee = d.entryEnd(j, e)
    if j < ee:
      if d.punct(j, "..."):
        rest = true
        discard d.bindPattern(j + 1, kind, scope, got)
      elif x.text == "[":
        discard d.bindPattern(j, kind, scope, got)
      else:
        let c = d.findAt(j, ee, ":")
        if c >= 0:
          if d.t[j].kind == jtIdent: d.isDef[j] = true          # (the key: not a use)
          discard d.bindPattern(c + 1, kind, scope, got)
        elif d.t[j].kind == jtIdent and d.t[j].text notin Reserved:
          got.add d.declare(j, kind, scope)
    j = ee + 1
  if rest and x.text == "{":
    for g in first ..< got.len: d.decls[got[g]].restSibling = true
  e + 1

proc params(d: var JsDoc, p, q, scope: int) =
  ## a parameter list's names, from its `(` p to its `)` q, seen in the function's scope
  if scope < 0: return
  var j = p + 1
  while j < q:
    let ee = d.entryEnd(j, q)
    var got: seq[int]
    discard d.bindPattern((if d.punct(j, "..."): j + 1 else: j), jdParam, scope, got)
    j = ee + 1

func objKeys(d: JsDoc, a: int): seq[string] =
  ## the keys of the object literal whose `{` is token a ("name()" for a method)
  let e = d.fwd[a]
  var j = a + 1
  while j < e:
    let ee = d.entryEnd(j, e)
    var k = j
    while d.word(k) in ["get", "set", "async"] and k + 1 < ee and d.t[k + 1].kind in {jtIdent, jtString}: inc k
    if d.punct(k, "*"): inc k
    if k < ee and d.t[k].kind in {jtIdent, jtString, jtNumber}:
      let name = d.t[k].text.strip(chars = {'"', '\''})
      let fn = d.punct(k + 1, "(") or (d.punct(k + 1, ":") and (d.word(k + 2) in ["function", "async"] or
               d.punct(k + 3, "=>") or (d.punct(k + 2, "(") and d.punct(d.fwd[k + 2] + 1, "=>"))))
      result.add name & (if fn: "()" else: "")
    j = ee + 1

func callResult(d: JsDoc, a, e: int): string =
  ## what the call that ends the expression a..e gives, when that shows: "Element", "Array", "String", "Promise" …
  if not d.punct(e, ")") or d.back[e] <= a + 1 and a >= 0: return ""
  let f = d.back[e] - 1
  let m = d.word(f)
  if m.len == 0: return ""
  if d.afterDot(f):
    let on = d.word(f - 2)
    if m in ElementMakers: return "Element"
    if m in ArrayMakers or (on == "Object" and m in ["keys", "values", "entries"]) or
       (on == "Array" and m in ["from", "of"]):
      return "Array"
    if m in StringMakers: return "String"
    if m in ["then", "catch", "finally"] or (on == "Promise" and m in PromiseStatics): return "Promise"
    return ""
  if d.word(f - 1) == "new": return m
  case m
  of "fetch": "Promise"
  of "String": "String"
  of "Number", "parseInt", "parseFloat": "Number"
  else: ""

func valueOf(d: JsDoc, a, e: int): (string, string, seq[string]) =
  ## what an initializer from token a to e gives: (its type when that shows, a function's parameters, an object
  ## literal's keys)
  if a > e or a >= d.t.len: return
  let x = d.t[a]
  var p = a
  if d.word(p) == "async" and p < e: inc p
  if d.word(p) == "function":
    var q = p + 1
    if d.punct(q, "*"): inc q
    if d.word(q).len > 0: inc q
    return ("function", (if d.punct(q, "(") and d.fwd[q] > q: d.span(q, d.fwd[q]) else: ""), @[])
  if d.punct(p, "(") and d.fwd[p] > p and d.punct(d.fwd[p] + 1, "=>"): return ("function", d.span(p, d.fwd[p]), @[])
  if d.word(p).len > 0 and d.punct(p + 1, "=>"): return ("function", "(" & d.word(p) & ")", @[])
  if d.word(a) == "class": return ("class", "", @[])
  if d.word(a) == "new":
    var k = a + 1
    while d.punct(k + 1, ".") and d.word(k + 2).len > 0: k += 2
    if k == e or (d.punct(k + 1, "(") and d.fwd[k + 1] == e): return (d.word(k), "", @[])
    return (d.callResult(a, e), "", @[])
  if d.word(a) == "await":
    if d.word(a + 1) == "fetch" and d.punct(a + 2, "(") and d.fwd[a + 2] == e: return ("Response", "", @[])
    return
  if a == e:
    case x.kind
    of jtString: return ("String", "", @[])
    of jtNumber: return ("Number", "", @[])
    of jtRegex: return ("RegExp", "", @[])
    else: discard
  if x.kind == jtTemplate and x.text.startsWith("`") and (x.text.endsWith("`") and x.text.len >= 2 and a == e or
     x.text.endsWith("${") and d.skipTemplate(a) == e):
    return ("String", "", @[])
  if d.punct(a, "[") and d.fwd[a] == e: return ("Array", "", @[])
  if d.punct(a, "{") and d.fwd[a] == e: return ("object", "", d.objKeys(a))
  (d.callResult(a, e), "", @[])

proc varDecl(d: var JsDoc, i: int) =
  ## var / let / const: each name (destructured too) and what it is given
  let kind = case d.t[i].text
    of "var": jdVar
    of "let": jdLet
    else: jdConst
  let scope = d.declScope(i, kind)
  let exported = d.kw(i - 1, "export")
  var j = i + 1
  while j < d.t.len:
    var got: seq[int]
    let simple = d.t[j].kind == jtIdent
    j = d.bindPattern(j, kind, scope, got)
    for g in got: d.decls[g].exported = exported
    if d.punct(j, "="):
      let e = d.exprEnd(j + 1)
      if simple and got.len == 1:
        let (typ, ps, keys) = d.valueOf(j + 1, e)
        let g = got[0]
        d.decls[g].typ = typ
        d.decls[g].params = ps
        d.decls[g].keys = keys
        if typ == "class" and (j + 1) in d.classAt:
          let ci = d.classAt[j + 1]
          d.decls[g].cls = ci
          if d.classes[ci].name.len == 0: d.classes[ci].name = d.decls[g].name
      j = e + 1
    if not d.punct(j, ","): break
    inc j

proc funcDecl(d: var JsDoc, i: int) =
  ## function name(params) { … }: the name (seen only inside when it is an expression) and the parameters
  var j = i + 1
  if d.punct(j, "*"): inc j
  var nameTok = -1
  if d.word(j).len > 0 and d.punct(j + 1, "("):
    nameTok = j
    inc j
  if not d.punct(j, "(") or d.fwd[j] < 0: return
  let q = d.fwd[j]
  let body = if d.punct(q + 1, "{"): d.braceScope.getOrDefault(q + 1, -1) else: -1
  if nameTok >= 0:
    let inner = d.inExpr(i)
    let scope = if inner: body else: d.declScope(i, jdFunction)
    if scope >= 0:
      let di = d.declare(nameTok, jdFunction, scope)
      d.decls[di].params = d.span(j, q)
      d.decls[di].typ = "function"
      d.decls[di].inner = inner
      d.decls[di].exported = d.exportedAt(i)
  d.params(j, q, body)

proc arrowParams(d: var JsDoc, i: int) =
  ## an arrow function's parameters: `(a, {b}) =>` or `a =>`
  let scope = if d.punct(i + 1, "{"): d.braceScope.getOrDefault(i + 1, -1) else: d.arrowScope.getOrDefault(i, -1)
  if d.punct(i - 1, ")") and d.back[i - 1] >= 0:
    d.params(d.back[i - 1], i - 1, scope)
  elif d.word(i - 1).len > 0 and scope >= 0:
    var got: seq[int]
    discard d.bindPattern(i - 1, jdParam, scope, got)

proc classDecl(d: var JsDoc, i: int) =
  ## a class: its name, and its methods and fields (static or not, #private too) with their parameters
  let ci = d.classAt.getOrDefault(i, -1)
  if ci < 0: return
  let body = d.classes[ci].body
  if d.word(i + 1).len > 0 and d.word(i + 1) != "extends":
    let inner = d.inExpr(i)
    let scope = if inner: body else: d.declScope(i, jdClass)
    if scope >= 0:
      let di = d.declare(i + 1, jdClass, scope)
      d.decls[di].inner = inner
      d.decls[di].exported = d.exportedAt(i)
      d.decls[di].cls = ci
  if body < 0: return
  let sc = d.scopes[body]
  let e = if sc.closed: sc.b else: d.t.len
  var j = sc.a + 1
  while j < e:
    var isStatic = false
    var acc = ""
    while d.word(j) in ["static", "async", "get", "set", "accessor"] and j + 1 < e and
          not (d.t[j + 1].kind == jtPunct and d.t[j + 1].text in ["(", "=", ";", "}"]):
      if d.word(j) == "static": isStatic = true
      elif d.word(j) in ["get", "set"]: acc = d.word(j)
      d.isDef[j] = true
      inc j
    if d.punct(j, "*"): inc j
    if j >= e: break
    if d.punct(j, ";"):
      inc j
      continue
    if d.punct(j, "{"):                                      # static { … }
      j = (if d.fwd[j] > j: d.fwd[j] + 1 else: e)
      continue
    let k = j
    let name = case d.t[j].kind
      of jtIdent, jtPrivate, jtNumber: d.t[j].text
      of jtString: d.t[j].text.strip(chars = {'"', '\''})
      else: ""
    if d.punct(j, "[") and d.fwd[j] > j: j = d.fwd[j]
    inc j
    if d.punct(j, "(") and d.fwd[j] > j:
      let q = d.fwd[j]
      let mb = if d.punct(q + 1, "{"): d.braceScope.getOrDefault(q + 1, -1) else: -1
      if name.len > 0:
        let m = d.addMember(ci, k, name, jdMethod)
        d.members[m].params = d.span(j, q)
        d.members[m].isStatic = isStatic
        d.members[m].getter = acc == "get"
      d.params(j, q, mb)
      if isStatic and mb >= 0: d.staticBody.incl mb
      j = if mb >= 0 and d.scopes[mb].closed: d.fwd[q + 1] + 1 else: q + 1
    else:
      var m = -1
      if name.len > 0:
        m = d.addMember(ci, k, name, jdField)
        d.members[m].isStatic = isStatic
      if d.punct(j, "="):
        let ee = d.exprEnd(j + 1, comma = false)
        if m >= 0:
          let (typ, ps, keys) = d.valueOf(j + 1, ee)
          d.members[m].typ = typ
          d.members[m].params = ps
          d.members[m].keys = keys
        j = ee + 1
      if d.punct(j, ";"): inc j

proc thisField(d: var JsDoc, i: int) =
  ## `this.name = …` in a class's method: a field of the class
  if not (d.punct(i + 1, ".") and i + 3 < d.t.len and d.t[i + 2].kind in {jtIdent, jtPrivate} and
          d.punct(i + 3, "=")):
    return
  let (ci, _) = d.enclosingClass(i)
  if ci < 0: return
  let name = d.t[i + 2].text
  for m in d.members:
    if m.cls == ci and m.name == name: return
  let m = d.addMember(ci, i + 2, name, jdField)
  let (typ, ps, keys) = d.valueOf(i + 4, d.exprEnd(i + 4))
  d.members[m].typ = typ
  d.members[m].params = ps
  d.members[m].keys = keys

proc importDecl(d: var JsDoc, i: int) =
  ## import x, {a, b as c} from "m" — import * as ns from "m"
  d.module = true
  var j = i + 1
  if j >= d.t.len or d.t[j].kind == jtString: return
  if d.word(j).len > 0 and (d.punct(j + 1, ",") or d.word(j + 1) == "from"):
    discard d.declare(j, jdImport, 0)
    inc j
    if d.punct(j, ","): inc j
  if d.punct(j, "*") and d.word(j + 1) == "as" and d.word(j + 2).len > 0:
    d.isDef[j + 1] = true
    discard d.declare(j + 2, jdImport, 0)
    j += 3
  if d.punct(j, "{") and d.fwd[j] > j:
    let e = d.fwd[j]
    var k = j + 1
    while k < e:
      let ee = d.entryEnd(k, e)
      var n = k
      if d.word(k + 1) == "as" and k + 2 < ee:
        if d.t[k].kind == jtIdent: d.isDef[k] = true
        d.isDef[k + 1] = true
        n = k + 2
      if n < ee and d.t[n].kind == jtIdent: discard d.declare(n, jdImport, 0)
      k = ee + 1
    j = e + 1
  if d.word(j) == "from": d.isDef[j] = true

proc exportDecl(d: var JsDoc, i: int) =
  ## export {a, b as c}: a and b are used; export {x} from "m", export * as ns from "m": names of another module
  d.module = true
  if d.punct(i + 1, "{") and d.fwd[i + 1] > i + 1:
    let e = d.fwd[i + 1]
    let reexport = d.word(e + 1) == "from"
    for k in i + 2 ..< e:
      if d.t[k].kind == jtIdent and (reexport or d.word(k) == "as" or d.word(k - 1) == "as"): d.isDef[k] = true
    if reexport: d.isDef[e + 1] = true
  elif d.punct(i + 1, "*") and d.word(i + 2) == "as":
    d.isDef[i + 2] = true
    if i + 3 < d.t.len: d.isDef[i + 3] = true

proc collect(d: var JsDoc) =
  ## the declarations, in one walk over the code
  for i in 0 ..< d.t.len:
    let x = d.t[i]
    if x.kind == jtPunct and x.text == "=>":
      d.arrowParams(i)
      continue
    if x.kind != jtIdent or d.afterDot(i) or d.punct(i + 1, ":"): continue
    case x.text
    of "var", "let", "const":
      let nx = if i + 1 < d.t.len: d.t[i + 1] else: JsTok()
      if (nx.kind == jtIdent and nx.text notin ["in", "instanceof", "of"]) or
         (nx.kind == jtPunct and nx.text in ["{", "["]):
        d.varDecl(i)
    of "function": d.funcDecl(i)
    of "class": d.classDecl(i)
    of "catch":
      if d.punct(i + 1, "(") and d.fwd[i + 1] > i + 1:
        let q = d.fwd[i + 1]
        if d.punct(q + 1, "{"): d.params(i + 1, q, d.braceScope.getOrDefault(q + 1, -1))
    of "import":
      if not d.punct(i + 1, "(") and not d.punct(i + 1, "."): d.importDecl(i)
    of "export": d.exportDecl(i)
    of "this": d.thisField(i)
    of "require":
      if d.punct(i + 1, "("): d.module = true
    of "module":
      if d.punct(i + 1, ".") and d.word(i + 2) == "exports": d.module = true
    of "exports":
      if d.punct(i + 1, "."): d.module = true
    else: discard

# ── the uses ──

func resolve(d: JsDoc, name: string, k: int): int =
  ## the declaration a name at token k means (-1 none)
  var s = if k >= 0 and k < d.scopeOf.len: d.scopeOf[k] else: 0
  while s >= 0:
    let r = d.names[s].getOrDefault(name, -1)
    if r >= 0: return r
    s = d.scopes[s].parent
  -1

func keyOrLabel(d: JsDoc, k: int): bool =
  ## a name before `:` that is an object's key or a label — not a use (`a ? b : c` and `case b:` use it)
  if not d.punct(k + 1, ":"): return false
  if k == 0: return true
  let p = d.t[k - 1]
  if p.kind == jtPunct and p.text in ["{", ",", ";", "}"]: return true
  d.t[k].nl and (p.kind != jtPunct or endsExpr(p)) and d.word(k - 1) != "case"      # (a label on a new line)

func methodName(d: JsDoc, k: int): bool =
  ## the name in a method's definition — `name(…) { … }` in an object literal — not a use
  if not d.punct(k + 1, "(") or d.fwd[k + 1] < 0: return false
  let s = d.braceScope.getOrDefault(d.fwd[k + 1] + 1, -1)
  s >= 0 and d.scopes[s].kind == skFunction

proc findRefs(d: var JsDoc) =
  ## each use of a name, and the declaration it means
  d.used = newSeq[bool](d.decls.len)
  for k in 0 ..< d.t.len:
    let x = d.t[k]
    if x.kind != jtIdent or d.isDef[k] or d.afterDot(k) or x.text in Reserved: continue
    if d.keyOrLabel(k) or d.methodName(k): continue
    if d.word(k - 1) in ["break", "continue"] and not x.nl: continue
    let r = d.resolve(x.text, k)
    if r < 0 and x.text in Contextual: continue
    d.refs.add (k, r)
    if r >= 0: d.used[r] = true

proc analyze(lines: openArray[string]): JsDoc =
  ## the document read: tokens, brackets, scopes, declarations, uses
  result.all = jsTokens(lines)
  for x in result.all:
    if x.kind != jtComment: result.t.add x
  result.isDef = newSeq[bool](result.t.len)
  result.matchBrackets()
  result.findClasses()
  result.buildScopes()
  result.collect()
  result.byScope = newSeq[seq[int]](result.scopes.len)
  result.names = newSeq[Table[string, int]](result.scopes.len)
  for i, x in result.decls:
    result.byScope[x.scope].add i
    if x.name notin result.names[x.scope]: result.names[x.scope][x.name] = i
  result.findRefs()

# ── what a name is ──

func classByName(d: JsDoc, name: string): int =
  if name.len == 0: return -1
  for i, c in d.classes:
    if c.name == name: return i
  -1

func memberOf(d: JsDoc, ci: int, name: string): int =
  ## the member of a class (or of the classes it extends) named so (-1)
  var c = ci
  var depth = 0
  while c >= 0 and depth < 8:
    for i, m in d.members:
      if m.cls == c and m.name == name: return i
    c = d.classByName(d.classes[c].base)
    inc depth
  -1

func instanceOwners(typ: string): seq[string] =
  ## the built-in members an instance of a type has
  if typ == "Element" or (typ.startsWith("HTML") and typ.endsWith("Element")): return @ElementOwners
  if jsMembersOf(typ & ".prototype").len > 0: return @[typ & ".prototype"]
  if typ.endsWith("Event"): return @["Event.prototype"]
  @[]

func staticOwners(name: string): seq[string] =
  ## the built-in members of a global object
  case name
  of "localStorage", "sessionStorage": @["Storage.prototype"]
  of "document": @["document", "EventTarget.prototype"]
  of "window": @["window", "EventTarget.prototype"]
  else: (if jsMembersOf(name).len > 0: @[name] else: @[])

func known(r: Recv): bool = r.owners.len > 0 or r.cls >= 0 or r.keys.len > 0

func typeRecv(d: JsDoc, typ: string): Recv =
  result.cls = d.classByName(typ)
  if result.cls < 0: result.owners = instanceOwners(typ)

func declRecv(d: JsDoc, x: JsDecl): Recv =
  ## what a declared name holds, as far as its members go
  if x.kind == jdClass or x.typ == "class": return Recv(cls: x.cls, statics: true)
  if x.typ == "object": return Recv(cls: -1, keys: x.keys)
  d.typeRecv(x.typ)

func recvOf(d: JsDoc, k: int, depth = 0): Recv =
  ## what the expression that ends at token k is, as far as its members go
  result.cls = -1
  if k < 0 or k >= d.t.len or depth > 6: return
  let x = d.t[k]
  case x.kind
  of jtString: return d.typeRecv("String")
  of jtNumber: return d.typeRecv("Number")
  of jtRegex: return d.typeRecv("RegExp")
  of jtTemplate:
    if x.text.endsWith("`"): return d.typeRecv("String")
  of jtPunct:
    if x.text == "]" and d.back[k] >= 0:
      let o = d.back[k]
      if o == 0 or not endsExpr(d.t[o - 1]): return d.typeRecv("Array")      # ([1, 2].… — not a[0].…)
    elif x.text == ")" and d.back[k] >= 0:
      return d.typeRecv(d.callResult(-1, k))
  of jtIdent:
    let w = x.text
    if w in ["this", "super"]:
      let (ci, st) = d.enclosingClass(k)
      if ci < 0: return
      if w == "this": return Recv(cls: ci, statics: st)
      let bi = d.classByName(d.classes[ci].base)
      if bi >= 0: return Recv(cls: bi, statics: st)
      return Recv(cls: -1, owners: (if st: @[] else: instanceOwners(d.classes[ci].base)))
    if d.afterDot(k):
      let on = d.word(k - 2)
      if w == "classList": return Recv(cls: -1, owners: @["DOMTokenList.prototype"])
      if w in ElementProps: return d.typeRecv("Element")
      if w == "searchParams": return Recv(cls: -1, owners: @["URLSearchParams.prototype"])
      if w == "prototype":
        let ci = d.classByName(on)
        if ci >= 0: return Recv(cls: ci)
        return Recv(cls: -1, owners: instanceOwners(on))
      if on in ["window", "globalThis", "self"] and jsGlobal(w) >= 0: return Recv(cls: -1, owners: staticOwners(w))
      let inner = d.recvOf(k - 2, depth + 1)
      if inner.cls >= 0:
        let m = d.memberOf(inner.cls, w)
        if m >= 0: return d.declRecv(d.members[m])
      return
    let r = d.resolve(w, k)
    if r >= 0: return d.declRecv(d.decls[r])
    if jsGlobal(w) >= 0: return Recv(cls: -1, owners: staticOwners(w))
  else: discard

func tokBefore(d: JsDoc, line, col: int): int =
  ## the last code token that starts before a place (-1 none)
  result = -1
  for k, x in d.t:
    if posLess(x.line, x.col, line, col): result = k else: break

func tokAt(d: JsDoc, line, col: int): int =
  ## the name (identifier or #private) at a place, or just before it (-1 none)
  result = -1
  for k, x in d.t:
    if x.line > line: break
    if x.line == line and x.kind in {jtIdent, jtPrivate} and x.col <= col and col <= x.ecol:
      result = k
      if col < x.ecol: return

func scopeAt(d: JsDoc, line, col: int): int =
  ## the innermost scope a place is in
  var best = -1
  for s in 1 .. d.scopes.high:
    let sc = d.scopes[s]
    let a = d.t[sc.a]
    let b = d.t[sc.b]
    let ended = if sc.closed: posLess(b.line, b.col, line, col)
                else: sc.b < d.t.high and posLess(b.eline, b.ecol, line, col)
    if posLess(a.line, a.col, line, col) and not ended and sc.a > best:
      best = sc.a
      result = s

func ownerName(owner: string): string = owner.replace(".prototype", "")

func webPage(name: string): string =
  ## the MDN page of a browser global, under Web/API/
  case name
  of "window": "Window"
  of "document": "Document"
  of "navigator": "Navigator"
  of "location": "Location"
  of "history": "History"
  of "performance": "Performance"
  of "crypto": "Crypto"
  of "self", "localStorage", "sessionStorage", "customElements", "indexedDB": "Window/" & name
  of "Image": "HTMLImageElement/Image"
  of "Audio": "HTMLAudioElement/Audio"
  else: name

func globalUrl(i: int): string =
  ## where a global is documented: MDN for the language and the browser, nodejs.org for Node.js
  let g = JsGlobals[i]
  case g.env
  of "js": Mdn & "JavaScript/Reference/Global_Objects/" & g.name
  of "node":
    case g.name
    of "process": "https://nodejs.org/api/process.html"
    of "Buffer": "https://nodejs.org/api/buffer.html"
    of "global": "https://nodejs.org/api/globals.html"
    else: "https://nodejs.org/api/modules.html"
  else:
    if g.kind == "function": Mdn & "API/Window/" & g.name else: Mdn & "API/" & webPage(g.name)

func memberUrl(owner, name: string): string =
  ## where a member is documented
  let base = ownerName(owner)
  let g = jsGlobal(base)
  if g < 0: return ""
  case JsGlobals[g].env
  of "js": Mdn & "JavaScript/Reference/Global_Objects/" & base & "/" & name
  of "node": globalUrl(g)
  else:
    if base == "console": Mdn & "API/console/" & name & "_static"
    else: Mdn & "API/" & webPage(base) & "/" & name

func memberItem(owner: string, i, rank: int, maybe = false): WebItem =
  let m = JsMembers[i]
  let fn = m.kind == "method"
  WebItem(label: m.name, insert: m.name,
          snippet: (if not fn: "" elif m.sig == "()": m.name & "()$0" else: m.name & "($1)$0"),
          detail: (if maybe: "maybe · " else: "") & (if fn: m.sig & " · " else: "") & ownerName(owner),
          doc: m.desc & "\n\n" & memberUrl(owner, m.name), kind: (if fn: KFunction else: KField), rank: rank)

proc ownerItems(owners: openArray[string], rank: int, items: var seq[WebItem], seen: var HashSet[string],
                maybe = false) =
  for o in owners:
    for i in jsMembersOf(o):
      if JsMembers[i].name notin seen:
        seen.incl JsMembers[i].name
        items.add memberItem(o, i, rank, maybe)

func globalItem(i, rank: int): WebItem =
  let g = JsGlobals[i]
  let fn = g.kind == "function"
  WebItem(label: g.name, insert: g.name, snippet: (if fn: g.name & "($1)$0" else: ""),
          detail: g.kind & (if g.sig.len > 0: " " & g.sig else: "") & (if g.env == "node": " · Node.js" else: ""),
          doc: g.desc & "\n\n" & globalUrl(i), rank: rank,
          kind: (case g.kind
                 of "function": KFunction
                 of "class": KClass
                 of "object": KModule
                 else: KConst))

func declItem(lines: openArray[string], x: JsDecl, rank: int): WebItem =
  let fn = x.kind in {jdFunction, jdMethod} or x.typ == "function"
  let kind = if fn: KFunction
             elif x.kind == jdClass or x.typ == "class": KClass
             elif x.kind == jdImport: KModule
             elif x.kind == jdField: KField
             elif x.kind == jdConst: KConst
             else: KVariable
  WebItem(label: x.name, insert: x.name, snippet: (if fn: x.name & "($1)$0" else: ""), kind: kind, rank: rank,
          detail: (if x.getter: "getter" else: $x.kind) & (if x.params.len > 0: " " & x.params else: "") &
                  (if x.owner.len > 0: " · " & x.owner else: "") & " · line " & $(x.line + 1),
          doc: "```js\n" & lines[x.line].strip & "\n```")

proc classItems(d: JsDoc, lines: openArray[string], ci: int, statics: bool, rank: int, items: var seq[WebItem],
                seen: var HashSet[string], depth = 0) =
  ## a class's members — an instance's, or the class's static ones — then what it inherits
  if ci < 0 or depth > 8: return
  for m in d.members:
    if m.cls == ci and m.isStatic == statics and m.name notin seen:
      seen.incl m.name
      items.add declItem(lines, m, rank)
  let base = d.classes[ci].base
  let bi = d.classByName(base)
  if bi >= 0 and bi != ci: d.classItems(lines, bi, statics, min(rank + 1, 3), items, seen, depth + 1)
  elif base.len > 0 and not statics: ownerItems(instanceOwners(base), min(rank + 1, 3), items, seen)

proc jsComplete*(lines: openArray[string], line, col: int): (int, seq[WebItem]) =
  ## what fits at (line, col): (where the word starts, the items) — after `.` the members of what is before it
  ## when that shows (else, lower, the members of the file's classes, of a string, an array, an element),
  ## elsewhere the names declared where the cursor is (nearest first), the keywords, the globals; nothing in a
  ## string or a comment (a template's ${…} is code)
  result[0] = col
  if line < 0 or line > lines.high: return
  let s = lines[line]
  let c = min(col, s.len)
  var a = c
  while a > 0 and isIdChar(s[a - 1]): dec a
  if a > 0 and s[a - 1] == '#': dec a
  result[0] = a
  let d = analyze(lines)
  for x in d.all:
    if x.line > line: break
    if x.inside(line, c): return
  var items: seq[WebItem]
  var seen: HashSet[string]
  let k = d.tokBefore(line, a)
  if k >= 0 and (d.punct(k, ".") or d.punct(k, "?.")):
    let r = d.recvOf(k - 1)
    d.classItems(lines, r.cls, r.statics, 0, items, seen)
    for key in r.keys:
      let fn = key.endsWith("()")
      let name = if fn: key[0 ..< ^2] else: key
      if name notin seen:
        seen.incl name
        items.add WebItem(label: name, insert: name, snippet: (if fn: name & "($1)$0" else: ""), detail: "key",
                          kind: (if fn: KFunction else: KField), rank: 0)
    ownerItems(r.owners, 0, items, seen)
    if not r.known:
      for m in d.members:
        if not m.isStatic and m.name notin seen:
          seen.incl m.name
          items.add declItem(lines, m, 2)
      ownerItems(@["String.prototype", "Array.prototype"] & @ElementOwners, 3, items, seen, maybe = true)
    result[1] = items
    return
  let afterNew = d.word(k) == "new"
  var sc = d.scopeAt(line, a)
  var rank = 0
  while sc >= 0:
    for di in d.byScope[sc]:
      let x = d.decls[di]
      if x.name in seen or (x.line == line and x.col == a): continue
      seen.incl x.name
      items.add declItem(lines, x, (if afterNew and (x.kind == jdClass or x.typ == "class"): 0 else: rank))
    if d.scopes[sc].kind in {skFunction, skArrowFn, skArrow}: rank = 1
    sc = d.scopes[sc].parent
  for w in JsKeywords:
    if w notin seen: items.add WebItem(label: w, insert: w, detail: "keyword", kind: KKeyword, rank: 2)
  for i, g in JsGlobals:
    if g.name notin seen: items.add globalItem(i, (if afterNew and g.kind == "class": 0 else: 3))
  result[1] = items

func declHover(lines: openArray[string], x: JsDecl): string =
  result = "**" & (if x.kind in {jdMethod, jdField} and x.owner.len > 0: x.owner & "." else: "") & x.name & "**" &
           x.params & " — " & (if x.kind == jdParam: "parameter" elif x.getter: "getter" else: $x.kind)
  if x.isStatic: result.add " (static)"
  if x.typ.len > 0 and x.typ notin ["function", "object", "class"]: result.add " · " & x.typ
  result.add " · line " & $(x.line + 1) & "\n```js\n" & lines[x.line].strip & "\n```"

func memberHover(owner: string, i: int): string =
  let m = JsMembers[i]
  "**" & owner & "." & m.name & "**" & m.sig & " — " & m.kind & "\n\n" & m.desc & "\n\n" & memberUrl(owner, m.name)

func globalHover(i: int): string =
  let g = JsGlobals[i]
  "**" & g.name & "**" & g.sig & " — " & g.kind & (if g.env == "node": " · Node.js" else: "") & "\n\n" & g.desc &
    "\n\n" & globalUrl(i)

proc jsHover*(lines: openArray[string], line, col: int): string =
  ## what the name at (line, col) is (Markdown; "" for nothing known): a global's or a member's signature and what
  ## it does, with where it is documented; a declaration of the file's kind, line and the line that declares it
  ## (a function's parameters with it)
  if line < 0 or line > lines.high: return
  let d = analyze(lines)
  let k = d.tokAt(line, col)
  if k < 0: return
  let w = d.t[k].text
  if d.afterDot(k):
    let r = d.recvOf(k - 2)
    if r.cls >= 0:
      let m = d.memberOf(r.cls, w)
      if m >= 0: return declHover(lines, d.members[m])
    for o in r.owners:
      for i in jsMembersOf(o):
        if JsMembers[i].name == w: return memberHover(o, i)
    if r.known: return
    # what is before the `.` does not show: what a member of that name may be
    var parts: seq[string]
    for m in d.members:
      if m.name == w and parts.len < 3: parts.add declHover(lines, m)
    for o in @["Array.prototype", "String.prototype"] & @ElementOwners:
      for i in jsMembersOf(o):
        if JsMembers[i].name == w and parts.len < 3: parts.add memberHover(o, i)
    return parts.join("\n\n---\n\n")
  if d.isDef[k]:
    for x in d.decls:
      if x.tok == k: return declHover(lines, x)
    for x in d.members:
      if x.tok == k: return declHover(lines, x)
    return
  if d.t[k].kind != jtIdent: return
  let r = d.resolve(w, k)
  if r >= 0: return declHover(lines, d.decls[r])
  let g = jsGlobal(w)
  if g >= 0: return globalHover(g)

proc jsDefinition*(lines: openArray[string], line, col: int): (int, int) =
  ## where the name at (line, col) is declared in this document — a variable, function, class, parameter, import,
  ## or a member of a class of the file after `.` — ((-1, -1) when it is not)
  result = (-1, -1)
  if line < 0 or line > lines.high: return
  let d = analyze(lines)
  let k = d.tokAt(line, col)
  if k < 0: return
  if d.afterDot(k):
    let r = d.recvOf(k - 2)
    if r.cls >= 0:
      let m = d.memberOf(r.cls, d.t[k].text)
      if m >= 0: return (d.members[m].line, d.members[m].col)
    return
  if d.isDef[k]:
    for x in d.decls:
      if x.tok == k: return (x.line, x.col)
    for x in d.members:
      if x.tok == k: return (x.line, x.col)
    return
  let r = d.resolve(d.t[k].text, k)
  if r >= 0: return (d.decls[r].line, d.decls[r].col)

# ── the problems ──

func diagAt(x: JsTok, sev: int, rule, msg: string): WebDiag =
  WebDiag(line: x.line, col: x.col, eline: x.eline, ecol: x.ecol, sev: sev, rule: rule, msg: msg)

proc redeclared(d: JsDoc, ds: var seq[WebDiag], fragment: bool) =
  ## let, const, class or import twice in one scope, or beside a var, function or parameter of the same name: a
  ## SyntaxError (a fragment's top level is left alone: its pieces may be scripts of their own)
  for s in 0 .. d.scopes.high:
    if fragment and s == 0: continue
    var first: Table[string, int]
    for di in d.byScope[s]:
      let x = d.decls[di]
      if x.inner: continue
      let f = first.getOrDefault(x.name, -1)
      if f < 0: first[x.name] = di
      elif x.kind in {jdLet, jdConst, jdClass, jdImport} or d.decls[f].kind in {jdLet, jdConst, jdClass, jdImport}:
        ds.add diagAt(d.t[x.tok], 1, "js-redeclare", "'" & x.name & "' is already declared in this scope (line " &
                      $(d.decls[f].line + 1) & ") — a SyntaxError")

proc constAssigned(d: JsDoc, ds: var seq[WebDiag]) =
  ## a const (or an import) assigned, ++'d or --'d: a TypeError when it runs
  for (k, r) in d.refs:
    if r < 0 or d.decls[r].kind notin {jdConst, jdImport}: continue
    let nx = if k + 1 < d.t.len: d.t[k + 1] else: JsTok()
    let prefix = (d.punct(k - 1, "++") or d.punct(k - 1, "--")) and
                 not (k >= 2 and endsExpr(d.t[k - 2]) and d.t[k - 2].line == d.t[k - 1].line) and
                 not (nx.kind == jtPunct and nx.text in [".", "?.", "["])             # (++k.n: k.n, not k)
    if not ((nx.kind == jtPunct and (nx.text in AssignOps or (nx.text in ["++", "--"] and not nx.nl))) or prefix):
      continue
    let x = d.decls[r]
    ds.add diagAt(d.t[k], 1, "js-const-assign",
                  (if x.kind == jdConst: "'" & x.name & "' is a constant (line " & $(x.line + 1) & ")"
                   else: "'" & x.name & "' is an import, read-only") & " — assigning to it throws a TypeError")

proc unused(d: JsDoc, ds: var seq[WebDiag], fragment: bool) =
  ## a function, let, const or import nothing uses (a hint) — not what is exported, not a `_name`, not a script's
  ## top level (other scripts and the page's onclick="…" may use it)
  for di, x in d.decls:
    if d.used[di] or x.kind notin {jdFunction, jdLet, jdConst, jdImport}: continue
    if x.exported or x.inner or x.restSibling or x.name.startsWith("_"): continue
    if x.scope == 0 and (fragment or not d.module): continue
    if d.names[x.scope][x.name] != di: continue                 # (declared twice: that is the mistake)
    ds.add diagAt(d.t[x.tok], 4, "js-unused", case x.kind
      of jdFunction: "function '" & x.name & "' is never used"
      of jdImport: "'" & x.name & "' is imported but never used"
      else: "'" & x.name & "' is declared but never used")

func literal(d: JsDoc, k: int): bool =
  ## a literal other than null and undefined: a number, a string, a template without ${}, true, false
  if k < 0 or k >= d.t.len: return false
  let x = d.t[k]
  x.kind in {jtNumber, jtString} or (x.kind == jtIdent and x.text in ["true", "false"]) or
    (x.kind == jtTemplate and x.text.len >= 2 and x.text[0] == '`' and x.text[^1] == '`')

func typeofBefore(d: JsDoc, k: int): bool =
  ## `typeof x ==`: the operand before the operator at k is a typeof
  var p = k - 1
  if d.punct(p, ")") and d.back[p] >= 0: return d.word(d.back[p] - 1) == "typeof"
  while p >= 0 and not d.t[p].nl and (d.t[p].kind in {jtIdent, jtPrivate} or d.punct(p, ".") or d.punct(p, "?.")) and
        d.word(p) != "typeof":
    dec p
  d.word(p) == "typeof"

proc eqeq(d: JsDoc, ds: var seq[WebDiag]) =
  ## `==` / `!=` with a literal (not null) on one side: it converts the other side first (a hint)
  for k, x in d.t:
    if x.kind != jtPunct or x.text notin ["==", "!="]: continue
    var r = k + 1
    if d.punct(r, "-") or d.punct(r, "+"): inc r
    if not (d.literal(k - 1) or d.literal(r)): continue
    if d.word(k + 1) == "typeof" or d.typeofBefore(k): continue      # (typeof gives a string: nothing converts)
    ds.add diagAt(x, 4, "js-eqeq", "'" & x.text & "' converts types before comparing — '" & x.text &
                  "=' compares without converting")

func caseKey(s: string): string =
  ## the word with its capitals turned into other letters: wordDistance then counts a change of case as an edit
  result = s
  for c in result.mitems:
    if c in {'A'..'Z'}: c = chr(ord(c) + 0x80)

proc nearest(w: string, names: openArray[string], limit: int): string =
  ## the name nearest a misspelled one, capitals counted ("" when none is near enough)
  var keys = newSeqOfCap[string](names.len)
  for n in names: keys.add caseKey(n)
  let k = closest(caseKey(w), keys, limit)
  if k.len > 0:
    for i, x in keys:
      if x == k: return names[i]

proc typos(d: JsDoc, ds: var seq[WebDiag]) =
  ## a name nothing declares that is a letter or two off one the file declares, or a letter off a global (capitals
  ## counted both times): a warning — a name near nothing may well be another script's or the environment's, left alone
  var known: HashSet[string]
  var globalKeys: seq[string]
  var byKey: Table[string, string]
  for g in JsGlobals:
    known.incl g.name
    globalKeys.add caseKey(g.name)
    byKey[caseKey(g.name)] = g.name
  for g in JsOtherGlobals: known.incl g
  var unresolved: CountTable[string]
  for (k, r) in d.refs:
    if r < 0: unresolved.inc d.t[k].text
  for (k, r) in d.refs:
    let w = d.t[k].text
    if r >= 0 or w.len < 3 or w in known or unresolved[w] >= 3 or d.word(k - 1) == "typeof": continue
    var names: seq[string]
    var s = d.scopeOf[k]
    while s >= 0:
      for di in d.byScope[s]: names.add d.decls[di].name
      s = d.scopes[s].parent
    var near = nearest(w, names, (if w.len >= 6: 2 else: 1))
    if near.len == 0: near = byKey.getOrDefault(closest(caseKey(w), globalKeys, (if w.len >= 10: 2 else: 1)), "")
    if near.len > 0 and near != w:
      ds.add diagAt(d.t[k], 2, "js-typo", "'" & w & "' is not declared — did you mean '" & near & "'?")

proc jsChecks*(lines: openArray[string], fragment = false): seq[WebDiag] =
  ## the mistakes worth a word: a bracket that closes nothing or never closes (not in a fragment: JS cut into the
  ## pieces of a template), let/const declared twice in a scope, a const assigned, a declaration nothing uses,
  ## == against a literal, a name not declared that is a letter or two off one that is
  let d = analyze(lines)
  if not fragment: result.add d.braces
  d.redeclared(result, fragment)
  d.constAssigned(result)
  d.unused(result, fragment)
  d.eqeq(result)
  d.typos(result)
  sortDiags(result)
