# ════════════════════════════════════════════════════════════════════════════
#  Built-in C formatter (C files, and the C in a Nim {.emit.}). Its "keep" style is ned's own way:
#  indentation by braces (LLVM's layout: case labels at the switch, one level for a body without braces,
#  continuation lines keep their offset), spaces after commas and keywords, around assignments and
#  comparisons, none inside brackets — your line breaks stay. The other styles (clang-format's presets, a
#  .clang-format, its keys as settings — cstyle.nim) do what clang-format does with them: braces placed,
#  one statement a line, short blocks and ifs split, pointers at the type or the name, spaces before
#  parentheses, case labels indented, lines joined and wrapped at the column limit, comments, macros,
#  assignments and declarations lined up. Three passes: the line breaks (cStructure), indentation and
#  spaces (cReindent), then what looks across lines (cPost). It checks its own result: the tokens must
#  come out the same, or the text is left alone.
# ════════════════════════════════════════════════════════════════════════════

type
  CKind = enum ckWord, ckNum, ckStr, ckChar, ckPunct, ckLineComment, ckBlockComment, ckPP
  CTok = object
    kind: CKind
    text: string
    line: int         # the line it starts on
    col: int          # column there
    endLine: int      # the line it ends on (block comments, macros continued with \)

const
  CPunct3 = [">>=", "<<=", "...", "->*"]
  CPunct2 = ["->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "&=",
             "|=", "^=", "##", "::"]
  CSpacedOps = ["=", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "||",
                "&&"]

proc cLex(text: string, ok: var bool): seq[CTok] =
  ## C (and C++ enough to format it) as tokens; whitespace dropped. ok = false for an unclosed comment or string
  ok = true
  var i = 0
  var line = 0
  var col = 0
  var lineStart = true            # nothing but whitespace so far on this line
  template adv(n: int) =
    for _ in 0 ..< n:
      if text[i] == '\n':
        inc line
        col = 0
        lineStart = true
      else: inc col
      inc i
  while i < text.len:
    let c = text[i]
    if c in {' ', '\t', '\r', '\f', '\v', '\n'}:
      adv(1)
      continue
    let (l0, c0) = (line, col)
    let start = i
    var kind = ckPunct
    if c == '#' and lineStart:
      # a preprocessor line, with its \ continuations
      while i < text.len:
        if text[i] == '\n':
          var k = i - 1
          while k > start and text[k] in {' ', '\t', '\r'}: dec k
          if text[k] != '\\': break
        if text[i] == '/' and i + 1 < text.len and text[i + 1] == '*':
          let e = text.find("*/", i + 2)
          if e < 0:
            ok = false
            return
          adv(e + 2 - i)
          continue
        adv(1)
      kind = ckPP
    elif c == '/' and i + 1 < text.len and text[i + 1] == '/':
      while i < text.len and text[i] != '\n': adv(1)
      kind = ckLineComment
    elif c == '/' and i + 1 < text.len and text[i + 1] == '*':
      let e = text.find("*/", i + 2)
      if e < 0:
        ok = false
        return
      adv(e + 2 - i)
      kind = ckBlockComment
    elif c == 'R' and i + 1 < text.len and text[i + 1] == '"':
      # a C++ raw string R"x(…)x"
      let p = text.find('(', i + 2)
      if p < 0:
        ok = false
        return
      let delim = ")" & text[i + 2 ..< p] & "\""
      let e = text.find(delim, p + 1)
      if e < 0:
        ok = false
        return
      adv(e + delim.len - i)
      kind = ckStr
    elif c in {'"', '\''}:
      adv(1)
      while i < text.len and text[i] != c:
        if text[i] == '\\' and i + 1 < text.len: adv(1)
        elif text[i] == '\n':
          ok = false
          return
        adv(1)
      if i >= text.len:
        ok = false
        return
      adv(1)
      kind = if c == '"': ckStr else: ckChar
    elif c in Digits or (c == '.' and i + 1 < text.len and text[i + 1] in Digits):
      while i < text.len and (text[i] in {'0' .. '9', 'a' .. 'z', 'A' .. 'Z', '_', '.', '\''} or
            (text[i] in {'+', '-'} and text[i - 1] in {'e', 'E', 'p', 'P'})):
        adv(1)
      kind = ckNum
    elif c in {'a' .. 'z', 'A' .. 'Z', '_', '$'} or ord(c) >= 128:
      while i < text.len and (text[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'} or ord(text[i]) >= 128):
        adv(1)
      # a string's prefix: L"…", u8"…"
      if i < text.len and text[i] in {'"', '\''} and text[start ..< i] in ["L", "u", "U", "u8"]:
        let q = text[i]
        adv(1)
        while i < text.len and text[i] != q:
          if text[i] == '\\' and i + 1 < text.len: adv(1)
          elif text[i] == '\n':
            ok = false
            return
          adv(1)
        if i >= text.len:
          ok = false
          return
        adv(1)
        kind = ckStr
      else: kind = ckWord
    else:
      var n = 1
      for p in CPunct3:
        if text.continuesWith(p, i):
          n = 3
          break
      if n == 1:
        for p in CPunct2:
          if text.continuesWith(p, i):
            n = 2
            break
      adv(n)
    lineStart = false
    result.add CTok(kind: kind, text: text[start ..< i], line: l0, col: c0, endLine: line)
    if kind in {ckPP, ckLineComment}: lineStart = true

proc cIndentOf(s: string): int =
  ## the leading whitespace of a line in columns (a tab to the next multiple of 8, as C sources mean it)
  for ch in s:
    if ch == ' ': inc result
    elif ch == '\t': result = (result div 8 + 1) * 8
    else: break

proc cColOf(s: string, n: int): int =
  ## the screen column of byte n of a line (tabs to multiples of 8)
  for k in 0 ..< min(n, s.len):
    if s[k] == '\t': result = (result div 8 + 1) * 8
    else: inc result

proc cPPJoined(t: string): string =
  ## a directive continued with `\` as one line (each `\` and its line break a space)
  if '\n' notin t: return t
  for l in t.split('\n'):
    var x = l.strip(leading = false)
    if x.endsWith("\\"): x.setLen(x.len - 1)
    if result.len > 0: result.add " "
    result.add x

proc cPPSig(t0: string): seq[string] =
  ## what a directive says, its spaces aside: its words and C tokens — and whether a #define is function-like
  ## (`#define F(x)` is, `#define F (x)` is not)
  let t = cPPJoined(t0)
  var j = 1
  while j < t.len and t[j] in {' ', '\t'}: inc j
  var e = j
  while e < t.len and t[e] in {'a'..'z', 'A'..'Z', '_'}: inc e
  let dir = t[j ..< e]
  result.add "#" & dir
  var rest = t[e .. ^1]
  if dir == "define":
    var a = 0
    while a < rest.len and rest[a] in {' ', '\t'}: inc a
    var b = a
    while b < rest.len and (rest[b].isAlphaNumeric or rest[b] in {'_', '$'}): inc b
    result.add rest[a ..< b]
    if b < rest.len and rest[b] == '(': result.add "<function-like>"
    rest = rest[b .. ^1]
  elif dir in ["include", "include_next", "import", "pragma", "error", "warning", "line", "ident"]:
    return result & rest.splitWhitespace
  var ok = true
  let ts = cLex(rest, ok)
  if not ok: return result & rest.splitWhitespace
  for x in ts:
    result.add (if x.kind in {ckBlockComment}: x.text.splitWhitespace.join(" ") else: x.text.strip(leading = false))

proc cSameTokens(a, b: seq[CTok]): bool =
  ## the same code: the same tokens in the same order (comments and directives with their spaces evened out)
  if a.len != b.len: return false
  for k in 0 ..< a.len:
    if a[k].kind != b[k].kind: return false
    if a[k].kind == ckBlockComment:
      if a[k].text.splitWhitespace != b[k].text.splitWhitespace: return false
    elif a[k].kind == ckPP:
      if a[k].text.splitWhitespace != b[k].text.splitWhitespace and cPPSig(a[k].text) != cPPSig(b[k].text):
        return false
    elif a[k].text.strip(leading = false) != b[k].text.strip(leading = false): return false
  true

proc cBinary(toks: seq[CTok], cpp: bool): seq[bool] =
  ## which of + - / % < > << >> | ^ ? are binary operators here (an operand in front: a name, a number, a string,
  ## a closing bracket) — never `*` and `&` (a pointer in a declaration looks the same)
  result = newSeq[bool](toks.len)
  var prev = -1
  for k, t in toks:
    if t.kind in {ckLineComment, ckBlockComment}: continue
    if t.kind == ckPP:
      prev = -1
      continue
    if t.kind == ckPunct and prev >= 0 and t.text in ["+", "-", "/", "%", "<", ">", "<<", ">>", "|", "^", "?"] and
       not (cpp and t.text in ["<", ">", ">>"]):
      let p = toks[prev]
      result[k] = p.kind in {ckNum, ckStr, ckChar} or p.text in [")", "]"] or
                  (p.kind == ckWord and p.text notin ["return", "case", "sizeof", "else", "do", "throw", "goto",
                                                      "alignof", "_Alignof", "defined", "co_return", "co_yield"])
    prev = k

func cSep(a, b: CTok, ws: string, cpp: bool, aBin = false, bBin = false): string =
  ## the space between two tokens on a line
  if b.kind in {ckLineComment, ckBlockComment}: return (if ws.len > 0: ws else: " ")
  if a.kind in {ckBlockComment}: return (if ws.len > 0: " " else: "")
  let at = a.text
  let bt = b.text
  if at in ["(", "["]: return ""
  if bt in [")", "]"]: return ""
  if bt in [",", ";"]: return ""
  if at == "," : return " "
  if at == ";": return (if bt == "}" and ws.len == 0: "" else: " ")    # ({return 1;} as written: not {return 1; })
  if at == "->" or bt == "->": return ""
  if aBin or bBin: return " "
  if a.kind == ckWord and at in ["if", "for", "while", "switch", "catch"] and bt == "(": return " "
  if bt == "{" and (at == ")" or at in ["else", "do", "try"]): return " "
  if at == "}" and bt in ["else", "while", "catch"]: return " "
  let spaced = CSpacedOps
  if a.kind == ckPunct and at in spaced and not (cpp and at == "&&"):
    return " "
  if b.kind == ckPunct and bt in spaced and not (cpp and bt == "&&") and at != "operator": return " "
  if ws.len > 0: " " else: ""


# ── what the tokens are: brackets matched, the kind of each brace, the role of `*` `&` `:` `(` ──

type
  CBrace = enum cbOther, cbFunc, cbCtl, cbDo, cbType, cbEnum, cbInit, cbNs, cbBlock
  CInfo = object
    prevC, nextC: seq[int]        # each token's code neighbours (comments skipped; -1: none)
    match: seq[int]               # a bracket's partner (-1)
    brace: seq[CBrace]            # the kind of a `{` (and of its `}`)
    role: seq[int]                # `*` `&`: 1 binary · 2 unary · 3 a pointer's (declarator) — `:`: 1 spaced ·
                                  # 2 ends a label (none before) — `(`: 1 a call's or declaration's · 2 a control
                                  # keyword's · 3 a cast's
    castEnd: seq[bool]            # a `)` that ends a cast
    caseColon: seq[bool]          # the `:` that ends a `case …:` / `default:` / label
    ctlParen: seq[bool]           # the `)` that ends an if/for/while/switch's condition
    ternary: seq[bool]            # a ternary's `?` or `:`

const
  CTypeWords = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool",
                "_Complex", "size_t", "ssize_t", "ptrdiff_t", "FILE", "wchar_t", "va_list", "auto", "intptr_t",
                "uintptr_t", "off_t", "pid_t", "time_t", "u_char", "u_int", "u_long", "u_short", "uint", "ulong",
                "ushort", "uchar", "BOOL", "DWORD", "HANDLE", "string", "wint_t", "char16_t", "char32_t",
                "char8_t", "nullptr_t", "jmp_buf", "sigset_t", "mode_t", "socklen_t", "in_addr_t", "regex_t"]
  CQualifiers = ["const", "volatile", "restrict", "__restrict", "__restrict__", "static", "extern", "inline",
                 "register", "_Thread_local", "thread_local", "__inline", "__inline__", "_Atomic", "__extension__",
                 "constexpr", "mutable", "typename", "virtual", "explicit", "friend"]
  CCtlWords = ["if", "for", "while", "switch", "catch"]
  CNotCalls = ["return", "case", "else", "do", "goto", "throw", "new", "delete", "co_return", "co_yield",
               "co_await", "typedef", "and", "or", "not"]
  CFuncLike = ["sizeof", "alignof", "_Alignof", "__alignof__", "typeof", "__typeof__", "decltype", "defined",
               "_Static_assert", "static_assert", "__attribute__", "__declspec", "_Generic", "offsetof", "noexcept",
               "alignas", "_Alignas", "__asm__", "asm"]

proc cTypeNames(toks: seq[CTok]): HashSet[string] =
  ## the names a file uses as types: its typedefs, struct / union / enum / class tags, names ending in _t
  for k, t in toks:
    if t.kind != ckWord: continue
    if t.text.endsWith("_t") and t.text.len > 2: result.incl t.text
    if t.text in ["struct", "union", "enum", "class"] and k + 1 < toks.len and toks[k + 1].kind == ckWord:
      result.incl toks[k + 1].text
    if t.text == "typedef":
      # (its name: the last word before the `;` — or `(*Name)` of a function pointer's)
      var d = 0
      var last = ""
      var fp = ""
      var j = k + 1
      while j < toks.len:
        let x = toks[j]
        if x.kind == ckPunct:
          if x.text in ["(", "[", "{"]: inc d
          elif x.text in [")", "]", "}"]: dec d
          elif x.text == ";" and d <= 0: break
          elif x.text == "*" and j > 0 and toks[j - 1].text == "(" and j + 1 < toks.len and toks[j + 1].kind == ckWord:
            if fp.len == 0: fp = toks[j + 1].text
        elif x.kind == ckWord and d == 0: last = x.text
        inc j
      if fp.len > 0: result.incl fp
      elif last.len > 0: result.incl last

proc cInfoOf(toks: seq[CTok], cpp: bool): CInfo =
  let n = toks.len
  result.prevC = newSeq[int](n)
  result.nextC = newSeq[int](n)
  result.match = newSeq[int](n)
  result.brace = newSeq[CBrace](n)
  result.role = newSeq[int](n)
  result.castEnd = newSeq[bool](n)
  result.caseColon = newSeq[bool](n)
  result.ctlParen = newSeq[bool](n)
  result.ternary = newSeq[bool](n)
  var last = -1
  for k in 0 ..< n:
    result.prevC[k] = last
    result.match[k] = -1
    if toks[k].kind notin {ckLineComment, ckBlockComment}: last = k
  last = -1
  for k in countdown(n - 1, 0):
    result.nextC[k] = last
    if toks[k].kind notin {ckLineComment, ckBlockComment}: last = k
  # brackets, and each `{`'s kind (a forward pass: what is around it)
  let types = cTypeNames(toks)
  var stack: seq[int]
  template P(k: int): int = result.prevC[k]
  template txt(k: int): string = (if k >= 0: toks[k].text else: "")
  proc isTypeWord(s: string): bool = s in CTypeWords or s in types
  for k in 0 ..< n:
    let t = toks[k]
    if t.kind != ckPunct: continue
    case t.text
    of "(", "[", "{":
      stack.add k
      if t.text == "{":
        let p = P(k)
        var kind = cbOther
        let pt = txt(p)
        var q = p
        # (`f(void) const {`, `f() noexcept {`: the qualifiers after the parameters)
        while q >= 0 and toks[q].kind == ckWord and toks[q].text in ["const", "noexcept", "override", "final",
                                                                       "volatile"]:
          q = P(q)
        var outer = cbNs                 # (the brace around it: functions are at the top, in a namespace or class)
        for j in countdown(stack.high - 1, 0):
          if toks[stack[j]].text == "{":
            outer = result.brace[stack[j]]
            break
        if q >= 0 and toks[q].text == ")" and result.match[q] >= 0:
          let b = P(result.match[q])
          if b >= 0 and toks[b].kind == ckWord and toks[b].text in CCtlWords: kind = cbCtl
          elif b >= 0 and (toks[b].kind == ckWord or toks[b].text in [">", ")"]) and outer in {cbNs, cbType}:
            kind = cbFunc
          else: kind = cbOther
        elif q >= 0 and toks[q].text == ":" and outer in {cbNs, cbType}:
          # (C++: `A() : x(1) {` — a constructor's; `class A : public B {` — a class's)
          kind = cbFunc
          var j = q
          while j >= 0 and toks[j].text notin [";", "{", "}"]:
            if toks[j].text in ["class", "struct"]: kind = cbType
            j = P(j)
        elif p >= 0 and toks[p].kind == ckPunct and outer notin {cbInit, cbEnum} and
             (pt in [";", "{", "}"] or (pt == ":" and outer notin {cbNs, cbType})):
          kind = cbBlock                 # (a block of its own, a case's: `case 1: {`)
        elif p >= 0 and toks[p].kind == ckWord and pt in ["else", "try"]: kind = cbCtl
        elif p >= 0 and toks[p].kind == ckWord and pt == "do": kind = cbDo
        elif p < 0: kind = cbBlock                  # (a text that starts with `{`: a macro's body, a block)
        elif pt in ["=", ",", "(", "{", "[", "return", "?"] or toks[p].kind == ckPP:
          kind = (if toks[p].kind == ckPP: cbOther else: cbInit)
        else:
          # (the statement it ends: struct / union / class / enum / namespace / extern "C")
          var j = p
          while j >= 0 and toks[j].text notin [";", "{", "}"] and toks[j].kind != ckPP:
            if toks[j].kind == ckWord:
              case toks[j].text
              of "struct", "union", "class": kind = cbType
              of "enum": kind = cbEnum
              of "namespace": kind = cbNs
              of "extern":
                if j + 1 < n and toks[j + 1].kind == ckStr: kind = cbNs
              else: discard
            if toks[j].text == "=" and kind == cbOther: kind = cbInit
            j = P(j)
          if kind == cbOther and outer == cbInit: kind = cbInit
        result.brace[k] = kind
    of ")", "]", "}":
      if stack.len > 0:
        let o = stack.pop()
        result.match[o] = k
        result.match[k] = o
        if t.text == "}": result.brace[k] = result.brace[o]
        if t.text == ")":
          let b = P(o)
          if b >= 0 and toks[b].kind == ckWord and toks[b].text in CCtlWords: result.ctlParen[k] = true
    else: discard
  # the roles of `(`, `*`, `&`, `:`
  var tern = 0                         # `?` still waiting for their `:`
  for k in 0 ..< n:
    let t = toks[k]
    if t.kind != ckPunct: continue
    let p = P(k)
    let nx = result.nextC[k]
    case t.text
    of "(":
      if p >= 0 and toks[p].kind == ckWord:
        result.role[k] = (if toks[p].text in CCtlWords: 2 elif toks[p].text in CNotCalls: 0 else: 1)
      elif p >= 0 and toks[p].text in [")", "]"]: result.role[k] = 1
      # a cast: `(type *)` before an operand, not a call's parentheses
      let c = result.match[k]
      if c > k + 1 and not (p >= 0 and (toks[p].kind == ckWord and toks[p].text notin CNotCalls or
                                         toks[p].text in [")", "]"])):
        var allType = true
        var words = 0
        for j in k + 1 ..< c:
          let x = toks[j]
          if x.kind == ckWord:
            if not (isTypeWord(x.text) or x.text in CQualifiers or x.text in ["struct", "union", "enum"] or
                    (j > k + 1 and toks[j - 1].text in ["struct", "union", "enum"])):
              allType = false
            inc words
          elif not (x.kind == ckPunct and x.text in ["*", "&"]): allType = false
        # (`(Name)x`: one name in parentheses before a name, a number or a string — a cast, as clang-format reads it)
        if not allType and c == k + 2 and toks[k + 1].kind == ckWord and toks[k + 1].text notin CNotCalls:
          let after0 = result.nextC[c]
          if after0 >= 0 and toks[after0].kind in {ckWord, ckNum, ckStr, ckChar} and
             toks[after0].text notin ["and", "or"]:
            allType = true
        # (`(Name *)`, `(struct x **)`: a name, then only `*`: a type, known or not)
        if not allType and words >= 1 and toks[c - 1].text == "*":
          var onlyStars = true
          var seenStar = false
          var w = 0
          for j in k + 1 ..< c:
            if toks[j].kind == ckWord:
              if seenStar: onlyStars = false
              inc w
            elif toks[j].text == "*": seenStar = true
            else: onlyStars = false
          if onlyStars and w <= 3: allType = true
        let after = result.nextC[c]
        if allType and words > 0 and after >= 0 and
           (toks[after].kind in {ckWord, ckNum, ckStr, ckChar} or
            toks[after].text in ["(", "*", "&", "-", "+", "!", "~", "++", "--"]):
          result.role[k] = 3
          result.castEnd[c] = true
    of "*", "&":
      let pt = if p >= 0: toks[p] else: CTok(kind: ckPunct, text: ";")
      var r = 0
      if pt.kind == ckPunct and pt.text in ["(", "[", ",", "=", "{", ";", "}", "?", ":", "!", "~", "return", "+", "-",
                                            "/", "%", "<", ">", "<<", ">>", "|", "^", "&&", "||", "==", "!=", "<=",
                                            ">=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]:
        # (`(int *)`: a cast's — `f(char *s)`: a parameter's — else what follows is dereferenced)
        r = 2
        if pt.text in ["(", ","] and p >= 0:
          discard
      elif pt.kind in {ckNum, ckStr, ckChar}: r = 1
      elif pt.kind == ckPunct and pt.text in [")", "]"]:
        r = (if result.castEnd[p] or result.ctlParen[p]: 2 else: 1)
        # (`void (*)(int)`, `int (*fp)[3]`: inside a declarator)
      elif pt.kind == ckPunct and pt.text in ["*", "&"] and result.role[p] == 3: r = 3
      elif pt.kind == ckPunct and pt.text in ["*", "&"]: r = 2
      elif pt.kind == ckWord:
        if pt.text in ["return", "case", "sizeof", "throw", "co_return", "else", "do"]: r = 2
        elif isTypeWord(pt.text) or pt.text in CQualifiers or (p > 0 and toks[P(p)].text in ["struct", "union",
                                                                                           "enum", "class"]):
          r = 3
        else:
          # (an unknown name before `* x` at a statement's start, then `;` `=` `,` `)` `[` `(`: a declaration)
          let pp = P(p)
          var startOfStmt = pp < 0 or toks[pp].text in [";", "{", "}", "(", ","] or toks[pp].kind == ckPP or
                            toks[pp].text in CQualifiers or
                            (toks[pp].kind == ckWord and toks[pp].text notin CNotCalls and
                             toks[pp].text notin CCtlWords)
          if pp >= 0 and toks[pp].text in ["(", ","]:
            # (inside parentheses: a parameter only when they are a function's declarator — `int f(foo *x)`:
            # a name before the `(` with a type or `*` before it — not a call's or an expression's `(x * m)`)
            var o = pp
            if toks[pp].text == ",":
              var d = 0
              o = P(pp)
              while o >= 0:
                if toks[o].text in [")", "]"]: inc d
                elif toks[o].text in ["(", "["]:
                  if d == 0: break
                  dec d
                elif toks[o].text in [";", "{", "}"]:
                  o = -1
                  break
                o = P(o)
            startOfStmt = false
            if o >= 0 and toks[o].text == "(":
              let fname = P(o)
              if fname >= 0 and toks[fname].kind == ckWord and toks[fname].text notin CNotCalls and
                 toks[fname].text notin CCtlWords:
                let before = P(fname)
                # (`type name(`: two names before the parenthesis — a declaration; `= f(`, `return f(`: a call)
                startOfStmt = before >= 0 and ((toks[before].kind == ckWord and toks[before].text notin CNotCalls) or
                                               toks[before].text == "*")
          var j = nx
          while j >= 0 and toks[j].text in ["*", "&", "const"]: j = result.nextC[j]
          let after = if j >= 0: result.nextC[j] else: -1
          if startOfStmt and j >= 0 and toks[j].kind == ckWord and after >= 0 and
             toks[after].text in [";", "=", ",", ")", "[", "("]:
            r = 3
          elif j >= 0 and toks[j].text == ")" and startOfStmt: r = 3      # (`(Foo *)` — a type)
          else: r = 1
      result.role[k] = r
    of "?":
      inc tern
      result.ternary[k] = true
    of ":":
      if tern > 0:
        dec tern
        result.ternary[k] = true
      result.role[k] = 1
    else: discard
  # inside a cast: its `*` and `&` are the type's; a declaration of several names (`T *a, *b;`): their `*` at the
  # names, whatever the alignment (clang-format does not move them)
  for k in 0 ..< n:
    if toks[k].text == "(" and result.role[k] == 3 and result.match[k] > k:
      for j in k + 1 ..< result.match[k]:
        if toks[j].kind == ckPunct and toks[j].text in ["*", "&"]: result.role[j] = 3
  for k in 0 ..< n:
    if not (toks[k].kind == ckPunct and toks[k].text in ["*", "&"] and result.role[k] == 3): continue
    var j = k + 1
    var d = 0
    var several = false
    let p = result.prevC[k]
    if p >= 0 and toks[p].text == ",":
      several = true
    while j < n and not several:
      let x = toks[j]
      if x.kind == ckPunct:
        if x.text in ["(", "[", "{"]: inc d
        elif x.text in [")", "]", "}"]:
          if d == 0: break
          dec d
        elif x.text in [";", "="] and d == 0: break
        elif x.text == "," and d == 0:
          let nx = result.nextC[j]
          if nx >= 0 and toks[nx].text in ["*", "&"]: several = true
          break
      inc j
    if several: result.role[k] = 4
  # labels: `case …:`, `default:`, `name:` at a statement's start, `public:`
  for k in 0 ..< n:
    let t = toks[k]
    if t.kind != ckWord: continue
    if t.text == "case":
      var d = 0
      var j = k + 1
      while j < n:
        let x = toks[j]
        if x.kind == ckPunct:
          if x.text in ["(", "[", "{"]: inc d
          elif x.text in [")", "]", "}"]: dec d
          elif x.text == ":" and d == 0:
            result.caseColon[j] = true
            result.role[j] = 2
            break
          elif x.text == ";" and d <= 0: break
        inc j
    elif t.text in ["default", "public", "private", "protected"] or
         (result.prevC[k] < 0 or toks[result.prevC[k]].text in [";", "{", "}"] or
          toks[result.prevC[k]].kind == ckPP):
      let nx = result.nextC[k]
      if nx >= 0 and toks[nx].text == ":" and result.role[nx] != 2:
        # (a label — not `a ? b : c`, which has a `?` before; not a bitfield, which has a type before)
        if t.text in ["default", "public", "private", "protected"] or result.prevC[k] < 0 or
           toks[result.prevC[k]].text != "?":
          var tern = false
          var j = result.prevC[k]
          while j >= 0 and toks[j].text notin [";", "{", "}"]:
            if toks[j].text == "?": tern = true
            j = result.prevC[j]
          if not tern:
            result.caseColon[nx] = true
            result.role[nx] = 2

func cSepStyled(toks: seq[CTok], info: CInfo, ia, ib: int, ws: string, st: CStyle, cpp: bool,
                aBin, bBin: bool): string =
  ## the space between two tokens on a line, in a style (not "keep")
  let a = toks[ia]
  let b = toks[ib]
  let at = a.text
  let bt = b.text
  if b.kind == ckLineComment:
    return spaces(if st.commentSpaces > 0: st.commentSpaces elif ws.len > 0: ws.len else: 1)
  if b.kind == ckBlockComment: return (if st.commentSpaces > 0: " " elif ws.len > 0: ws else: " ")
  if a.kind == ckBlockComment: return (if ws.len > 0: " " else: "")
  if a.kind == ckPunct:
    if at in ["(", "["]: return ""
    if at == "{" and info.brace[ia] == cbInit and bt == "}": return ""
    if at == "{" and info.brace[ia] == cbInit and st.spaceInBraces > 0: return (if st.spaceInBraces == 2: " " else: "")
  if b.kind == ckPunct:
    if bt in [")", "]", ",", ";"]: return ""
    if bt == "}" and info.brace[ib] == cbInit and st.spaceInBraces > 0: return (if st.spaceInBraces == 2: " " else: "")
  if at in [",", ";"]: return " "
  # (a block on one line: `{ return a; }`)
  if a.kind == ckPunct and at == "{" and info.brace[ia] notin {cbInit}: return " "
  if b.kind == ckPunct and bt == "}" and info.brace[ib] notin {cbInit}: return (if at == "{": "" else: " ")
  if at in ["->", ".", "::"] or bt in ["->", ".", "::"]:
    return (if at == "," or (bt == "::" and a.kind == ckWord and at in CNotCalls): " " else: "")
  # (the brackets)
  if bt == "{": return (if a.kind == ckPunct and at in ["(", "[", "{"]: "" else: " ")
  if at == "}": return (if bt in [";", ",", ")"]: "" else: " ")
  if bt == "(":
    case info.role[ib]
    of 2: return (if st.parens == 2: "" else: " ")
    of 1: return (if st.parens == 3: " " elif a.kind == ckWord and at in CFuncLike: (if st.parens == 3: " " else: "")
                  else: "")
    else:
      if a.kind == ckWord and at in CNotCalls: return " "
      if a.kind == ckWord and at in CFuncLike: return (if st.parens == 3: " " else: "")
  if at == ")" and info.castEnd[ia]: return (if st.castSpace == 2: " " else: "")
  # `*` `&` as pointers, unary or binary operators
  if b.kind == ckPunct and bt in ["*", "&"] and info.role[ib] == 4:
    return (if a.kind == ckPunct and at in ["*", "&", "(", ","]: (if at == ",": " " else: "") else: " ")
  if a.kind == ckPunct and at in ["*", "&"] and info.role[ia] == 4:
    return (if b.kind == ckPunct and bt in ["*", "&", ")"]: "" else: "")
  if b.kind == ckPunct and bt in ["*", "&"] and info.role[ib] in {1, 2, 3}:
    case info.role[ib]
    of 1: return " "
    of 2: return (if aBin or (a.kind == ckPunct and at in CSpacedOps): " "
                  elif a.kind == ckPunct and at in ["(", "[", "!", "~", "-", "+", "*", "&", "++", "--"] and
                     info.role[ia] != 1: "" else: " ")
    else:
      if a.kind == ckPunct and at in ["*", "&", "("]: return ""
      return (case st.pointer
              of 1, 3: " "
              of 2: ""
              else: (if ws.len > 0: " " else: ""))
  if a.kind == ckPunct and at in ["*", "&"] and info.role[ia] in {1, 2, 3}:
    case info.role[ia]
    of 1: return " "
    of 2: return ""
    else:
      if b.kind == ckPunct and bt in ["*", "&", ")", ",", ">", "(", "[", ";"]: return ""
      return (case st.pointer
              of 1: ""
              of 2, 3: " "
              else: (if ws.len > 0: " " else: ""))
  # `:` of a label or `case`: none before; else spaced
  if bt == ":" and b.kind == ckPunct:
    return (if info.role[ib] == 2 or info.caseColon[ib]: "" else: " ")
  if at == ":" and a.kind == ckPunct: return " "
  if aBin or bBin: return " "
  if a.kind == ckWord and at in CCtlWords and bt == "(": return (if st.parens == 2: "" else: " ")
  if at == "}" and bt in ["else", "while", "catch"]: return " "
  if a.kind == ckPunct and at in CSpacedOps and not (cpp and at == "&&"): return " "
  if b.kind == ckPunct and bt in CSpacedOps and not (cpp and bt == "&&") and at != "operator": return " "
  # unary operators hold to their operand
  if a.kind == ckPunct and at in ["!", "~"]: return ""
  if a.kind == ckPunct and at in ["-", "+"] and not aBin: return ""
  if a.kind == ckPunct and at in ["++", "--"]:
    return (if b.kind in {ckWord, ckNum} or bt in ["(", "*"]: "" else: (if ws.len > 0: " " else: ""))
  if b.kind == ckPunct and bt in ["++", "--"] and (a.kind in {ckWord, ckNum} or at in [")", "]"]): return ""
  if a.kind in {ckWord, ckNum, ckStr, ckChar} and b.kind in {ckWord, ckNum, ckStr, ckChar}: return " "
  if ws.len > 0: " " else: ""

# ── lines left as they are: `// clang-format off` … `on`, and (in a style) what `#if 0` leaves out ──

proc cFrozen(lines: openArray[string], ifZero: bool): seq[bool] =
  result = newSeq[bool](lines.len)
  var off = false
  var zeroDepth = 0             # (inside `#if 0`: the #if nesting from it)
  for i, raw in lines:
    let l = raw.strip
    if off:
      result[i] = true
      if l in ["// clang-format on", "/* clang-format on */"]: off = false
      continue
    if l in ["// clang-format off", "/* clang-format off */"]:
      off = true
      result[i] = true
      continue
    if not ifZero: continue
    let pp = if l.startsWith("#"): l[1 .. ^1].strip else: ""
    if zeroDepth > 0:
      if pp.startsWith("if"):
        inc zeroDepth
        result[i] = true
      elif pp.startsWith("endif"):
        dec zeroDepth
        result[i] = zeroDepth > 0
      elif (pp.startsWith("else") or pp.startsWith("elif")) and zeroDepth == 1: zeroDepth = 0
      else: result[i] = true
      continue
    if pp.startsWith("if") and pp.splitWhitespace.len >= 2 and pp.splitWhitespace[0] == "if" and
       pp.splitWhitespace[1] == "0":
      zeroDepth = 1

# ── pass 1: the line breaks a style wants ──

proc cStructure(text: string, toks: seq[CTok], info: CInfo, st: CStyle): string =
  ## the text with the line breaks the style asks for (tokens and what is inside them unchanged; the
  ## indentation of a line it makes is left to cReindent)
  let n = toks.len
  if n == 0: return text
  # (each token's start and end offsets in the text)
  var lineStart = @[0]
  for i, c in text:
    if c == '\n': lineStart.add i + 1
  proc offOf(t: CTok): int = lineStart[min(t.line, lineStart.high)] + t.col
  var brk = newSeq[bool](n)          # a line break before the token
  var blanks = newSeq[int](n)        # empty lines before it
  var forced = newSeq[bool](n)       # a break the style wants (joining does not take it away)
  for k in 1 ..< n:
    let p = toks[k - 1]
    let pEnd = offOf(p) + p.text.len
    var nl = 0
    for i in pEnd ..< offOf(toks[k]):
      if text[i] == '\n': inc nl
    brk[k] = nl > 0
    blanks[k] = max(0, nl - 1)
  template force(k: int, v = true) =
    if k > 0 and k < n:
      brk[k] = v
      forced[k] = true
  # where a statement may be joined into one line (the column limit wraps it again)
  var inInit = newSeq[int](n)          # inside a braced list / an enum's body: its line breaks stay
  block:
    var d = 0
    for k in 0 ..< n:
      let t = toks[k]
      if t.text == "}" and t.kind == ckPunct and info.brace[k] in {cbInit, cbEnum} and d > 0: dec d
      inInit[k] = d
      if t.text == "{" and t.kind == ckPunct and info.brace[k] in {cbInit, cbEnum}: inc d
  # (a braced list at the column limit: joined, to be wrapped — or, with a comma after its last element, one
  # element a line, as clang-format has it; one with comments inside stays as written)
  var reflow = newSeq[bool](n)        # a token inside a list that is joined
  if st.colLimit > 0:
    for k in 0 ..< n:
      if not (toks[k].text == "{" and info.brace[k] == cbInit) or inInit[k] > 0: continue
      let c = info.match[k]
      if c < 0: continue
      var comments = false
      for j in k + 1 ..< c:
        if toks[j].kind in {ckLineComment, ckBlockComment, ckPP}: comments = true
      if comments: continue
      let trailing = info.prevC[c] > k and toks[info.prevC[c]].text == ","
      for j in k + 1 .. c:
        reflow[j] = true
      if trailing:
        # (each top-level element on its own line)
        var d = 0
        for j in k + 1 ..< c:
          let x = toks[j]
          if x.text in ["(", "[", "{"]: inc d
          elif x.text in [")", "]", "}"]: dec d
          elif x.text == "," and d == 0 and j + 1 <= c: force(j + 1)
        force(k + 1)
        force(c)
  if st.colLimit > 0:
    for k in 1 ..< n:
      if not brk[k] or (inInit[k] > 0 and not reflow[k]) or forced[k]: continue
      let t = toks[k]
      let p = toks[k - 1]
      # (not after a line comment or a directive; a block comment of one line is joined like code — not one that
      # starts its line, a comment above what follows)
      if t.kind in {ckPP, ckLineComment} or p.kind in {ckPP, ckLineComment}: continue
      if t.kind == ckBlockComment and ('\n' in t.text or (k + 1 < n and brk[k + 1])): continue
      if p.kind == ckBlockComment and ('\n' in p.text or k < 2 or brk[k - 1] or
                                       toks[k - 2].kind in {ckLineComment, ckPP}):
        continue                        # (a comment on a line of its own: what follows starts its own)
      if blanks[k] > 0: continue
      let pc = info.prevC[k]
      if pc < 0: continue
      let q = toks[pc]
      if q.kind == ckPunct and q.text in [";", "{", "}"]: continue
      if q.kind == ckPunct and q.text == ":" and (info.caseColon[pc] or info.role[pc] == 2): continue
      if q.kind == ckPunct and q.text == ")" and info.ctlParen[pc]: continue      # (a body after `if (…)`)
      if q.kind == ckWord and q.text in ["else", "do"]: continue
      if t.kind == ckPunct and t.text in ["{", "}"]: continue
      if t.kind == ckWord and t.text in ["case", "default", "public", "private", "protected"]: continue
      brk[k] = false
  # binary operators at the ends of lines (BreakBeforeBinaryOperators: None) — or at the starts (All)
  if st.breakBinary >= 0 and st.name != "keep":
    let bin = cBinary(toks, false)
    proc isBinOp(k: int): bool =
      let t = toks[k]
      t.kind == ckPunct and (bin[k] and t.text notin ["?"] or t.text in ["&&", "||", "==", "!=", "<=", ">="] or
                             (t.text in ["*", "&"] and info.role[k] == 1))
    for k in 1 ..< n:
      if inInit[k] > 0 or not isBinOp(k): continue
      let p = toks[k - 1]
      if p.kind in {ckPP, ckLineComment, ckBlockComment}: continue
      if st.breakBinary == 0 and brk[k] and blanks[k] == 0:
        brk[k] = false                   # (`a⏎ + b` → `a + b`: the operator ends the line when one is broken)
      elif st.breakBinary == 2 and not brk[k] and k + 1 < n and brk[k + 1] and blanks[k + 1] == 0 and
           toks[k + 1].kind notin {ckLineComment, ckBlockComment, ckPP}:
        brk[k] = true                    # (`a +⏎ b` → `a⏎ + b`)
        brk[k + 1] = false
  # a ternary's `?` and `:` start a line when it is broken there, never end one (BreakBeforeTernaryOperators)
  if st.breakBinary >= 0 and st.name != "keep":
    for k in 0 ..< n - 1:
      if inInit[k] > 0 or not info.ternary[k]: continue
      if brk[k + 1] and blanks[k + 1] == 0 and toks[k + 1].kind notin {ckLineComment, ckBlockComment, ckPP}:
        brk[k + 1] = false
  # the preprocessor and line comments: lines of their own
  for k in 0 ..< n:
    if toks[k].kind == ckPP:
      force(k)
      force(k + 1)
    elif toks[k].kind == ckLineComment: force(k + 1)
  # a short function: `int f() { return 1; }` (when it fits) — and `{}`
  var keepOne = newSeq[bool](n)         # a `{` whose block stays on one line
  if st.colLimit > 0 and st.shortFuncs > 0:
    for k in 0 ..< n:
      if not (toks[k].text == "{" and info.brace[k] == cbFunc): continue
      let c = info.match[k]
      if c < 0: continue
      var simple = true
      var semis = 0
      var width = 0
      for j in k + 1 ..< c:
        let x = toks[j]
        if x.kind in {ckPP, ckLineComment, ckBlockComment} or x.text in ["{", "}"]: simple = false
        if x.text == ";": inc semis
        width += x.text.len + 1
      if not simple or semis > 1 or (st.shortFuncs == 1 and c > k + 1): continue
      # (the header's length: back to the statement's start)
      var h = info.prevC[k]
      var hw = 0
      while h >= 0 and toks[h].text notin [";", "{", "}"] and toks[h].kind != ckPP:
        hw += toks[h].text.len + 1
        h = info.prevC[h]
      var depth = 0
      for j in 0 ..< k:
        if toks[j].text == "{": inc depth
        elif toks[j].text == "}": dec depth
      if depth * st.indent + hw + width + 4 <= st.colLimit:
        keepOne[k] = true
        force(k, false)
        for j in k + 1 .. c: force(j, false)
  # a definition's return type on a line of its own (AlwaysBreakAfterDefinitionReturnType: GNU, Mozilla)
  if st.breakReturnType > 0:
    var depth = 0
    for k in 0 ..< n:
      let t = toks[k]
      if t.kind == ckPunct and t.text == "{":
        if info.brace[k] == cbFunc and info.prevC[k] >= 0 and (st.breakReturnType == 1 or depth == 0):
          # (the name before the parameters' `(`, and a type before it)
          var q = info.prevC[k]
          while q >= 0 and toks[q].kind == ckWord and toks[q].text in ["const", "noexcept", "override", "final"]:
            q = info.prevC[q]
          if q >= 0 and toks[q].text == ")" and info.match[q] >= 0:
            let name = info.prevC[info.match[q]]
            let before = if name >= 0: info.prevC[name] else: -1
            if name >= 0 and toks[name].kind == ckWord and before >= 0 and
               (toks[before].kind == ckWord or toks[before].text in ["*", "&"]) and
               toks[before].text notin CNotCalls:
              force(name)
        inc depth
      elif t.kind == ckPunct and t.text == "}": dec depth
  # `= {`: a braced list starts on the `=`'s line
  if st.name != "keep":
    for k in 1 ..< n:
      if toks[k].text == "{" and info.brace[k] == cbInit and info.prevC[k] == k - 1 and toks[k - 1].text == "=" and
         brk[k]:
        force(k, false)
        blanks[k] = 0
  # braces
  for k in 0 ..< n:
    let t = toks[k]
    if t.kind != ckPunct or t.text != "{" or keepOne[k]: continue
    let kind = info.brace[k]
    if kind notin {cbFunc, cbCtl, cbDo, cbType, cbEnum, cbBlock}: continue
    let c = info.match[k]
    let want = case kind
               of cbFunc: st.braceFunc
               of cbType, cbEnum: st.braceType
               of cbBlock: 0                          # (a block of its own: where it is)
               else: st.braceCtl
    let prevTok = toks[max(0, k - 1)]
    if want == 1 and k > 0 and prevTok.kind notin {ckLineComment, ckPP} and info.prevC[k] == k - 1:
      force(k, false)
      blanks[k] = 0
    elif want == 2: force(k)
    if st.name == "keep": continue
    # the block's inside: a line of its own (unless a short one may stay: AllowShortBlocks…)
    let oneLine = c > 0 and not brk[c] and (block:
      var flat = true
      for j in k + 1 .. c:
        if brk[j]: flat = false
      flat)
    let mayStay = oneLine and kind in {cbCtl, cbDo, cbBlock} and st.shortBlocks
    if kind == cbEnum and oneLine: continue
    if not mayStay:
      if k + 1 < n and toks[k + 1].kind == ckBlockComment and not brk[k + 1] and '\n' notin toks[k + 1].text:
        if k + 2 < n and k + 2 != c or (k + 2 == c and st.shortBlocks == false): force(k + 2)   # (`{ /* … */`: the comment stays)
      elif k + 1 < n and toks[k + 1].kind != ckLineComment and not (toks[k + 1].kind == ckBlockComment and
                                                                  not brk[k + 1] and k + 2 < n and brk[k + 2]):
        if not (c == k + 1 and kind == cbFunc and st.shortFuncs > 0): force(k + 1)
      if c > 0 and not (c == k + 1 and kind == cbFunc and st.shortFuncs > 0): force(c)
    # after the `}`: `} else`, `} while (…);` of a do, `};` `} Name;` — else a new line
    if c > 0 and c + 1 < n:
      let nx = toks[c + 1]
      if nx.kind == ckWord and nx.text == "else":
        if st.elseLine == 1: force(c + 1, false)
        elif st.elseLine == 2: force(c + 1)
      elif nx.kind == ckWord and nx.text == "while" and kind == cbDo: force(c + 1, false)
      elif nx.kind == ckPunct and nx.text in [";", ",", ")"]: force(c + 1, false)
      elif kind in {cbType, cbEnum} and nx.kind == ckWord: force(c + 1, false)
      elif nx.kind notin {ckLineComment, ckBlockComment}: force(c + 1)
  if st.name != "keep":
    for k in 0 ..< n:
      let t = toks[k]
      # one statement a line
      if st.oneStatement and t.kind == ckPunct and t.text == ";" and k + 1 < n:
        # (a `;` of a statement: not one inside `for (…)`)
        var d = 0
        var j = k - 1
        var inParen = false
        while j >= 0:
          let x = toks[j]
          if x.kind == ckPunct:
            if x.text in [")", "]"]: inc d
            elif x.text in ["(", "["]:
              if d == 0:
                inParen = true
                break
              dec d
            elif x.text in ["{", "}"] and d == 0: break
          dec j
        let nx = toks[k + 1]
        if not inParen and inInit[k] == 0 and nx.kind notin {ckLineComment, ckBlockComment} and
           not (nx.kind == ckPunct and nx.text in ["}", ")"]):
          # (inside a one-line block that may stay: its statements stay too)
          var openK = -1
          var dd = 0
          for jj in countdown(k - 1, 0):
            if toks[jj].text == "}": inc dd
            elif toks[jj].text == "{":
              if dd == 0:
                openK = jj
                break
              dec dd
          if not (openK >= 0 and (keepOne[openK] or (not brk[k + 1] and st.shortBlocks and
                                                       info.brace[openK] in {cbCtl, cbDo}))):
            force(k + 1)
      # an if / for / while whose body has no braces: the body on a line of its own (AllowShortIfs, …Loops)
      if t.kind == ckPunct and t.text == ")" and info.ctlParen[k] and k + 1 < n:
        let o = info.match[k]
        let kw = toks[info.prevC[o]].text
        let nx = toks[k + 1]
        if nx.kind == ckPunct and nx.text == ";" and kw in ["while", "for"] and not st.shortLoops:
          let pw0 = info.prevC[info.prevC[o]]
          if not (kw == "while" and pw0 >= 0 and toks[pw0].text == "}" and info.brace[pw0] == cbDo):
            force(k + 1)                 # (`while (x)⏎  ;` — an empty body on its own line)
        if nx.kind notin {ckLineComment, ckBlockComment} and not (nx.kind == ckPunct and nx.text in ["{", ";"]) and
           kw != "switch":
          let allowed = if kw == "if": st.shortIfs else: st.shortLoops
          # (`} while (x);` ends a do: no body)
          let pw = info.prevC[info.prevC[o]]
          let isDoWhile = kw == "while" and pw >= 0 and toks[pw].text == "}" and info.brace[pw] == cbDo
          if not allowed and not isDoWhile: force(k + 1)
      if t.kind == ckWord and t.text == "else" and k + 1 < n:
        let nx = toks[k + 1]
        if nx.kind notin {ckLineComment, ckBlockComment} and not (nx.kind == ckWord and nx.text == "if") and
           not (nx.kind == ckPunct and nx.text == "{") and not st.shortIfs:
          force(k + 1)
      # `case 1: x;` — the statement under its label (AllowShortCaseLabelsOnASingleLine)
      if t.kind == ckPunct and t.text == ":" and info.caseColon[k] and k + 1 < n and not st.shortCase:
        let nx = toks[k + 1]
        if nx.kind notin {ckLineComment, ckBlockComment} and not (nx.kind == ckPunct and nx.text == "{"):
          force(k + 1)
  # (lines left as they are: their tokens' breaks as written)
  let frozen = cFrozen(text.split('\n'), true)
  for k in 1 ..< n:
    let t = toks[k]
    let p = toks[k - 1]
    if (t.line < frozen.len and frozen[t.line]) or (p.endLine < frozen.len and frozen[p.endLine]):
      var nl = 0
      for i in offOf(p) + p.text.len ..< offOf(t):
        if text[i] == '\n': inc nl
      brk[k] = nl > 0
      blanks[k] = max(0, nl - 1)
      forced[k] = true
  # the text: each token as it was, separated by its original space on a line, else a break
  for k in 0 ..< n:
    if brk[k]:
      if not forced[k] or blanks[k] > 0: blanks[k] = min(blanks[k], st.maxBlank)
      if not st.blankAtBlockStart and k > 0 and toks[k - 1].text == "{" and info.brace[k - 1] in
         {cbFunc, cbCtl, cbDo, cbBlock, cbType}:
        blanks[k] = 0
    else: blanks[k] = 0
  var outp = newStringOfCap(text.len + 256)
  for k in 0 ..< n:
    let t = toks[k]
    if k > 0:
      let p = toks[k - 1]
      let pEnd = offOf(p) + p.text.len
      if brk[k]:
        outp.add "\n".repeat(1 + blanks[k])
        # (a line as it was: its indentation kept — the offset of a continuation line means something)
        if t.line > p.endLine:
          let ls = lineStart[min(t.line, lineStart.high)]
          outp.add text[ls ..< offOf(t)]
      elif t.line == p.endLine: outp.add text[pEnd ..< offOf(t)]
      else: outp.add " "
    else:
      let ls = lineStart[min(t.line, lineStart.high)]
      outp.add text[ls ..< offOf(t)]
    outp.add t.text
  if text.endsWith("\n"): outp.add "\n"
  outp

# ── pass 2: indentation and the spaces on each line ──

proc cPPNormal(t: string, st: CStyle, cpp: bool): string =
  ## a one-line directive, spaced as code is (`#if !defined(X)`, `#define MAX 30`): its `#` at the start, one
  ## space after its name, a #define's parameters and value spaced; #include and #pragma as written
  result = t.strip
  if result.len < 2 or result[0] != '#' or '\n' in t: return
  var j = 1
  while j < result.len and result[j] in {' ', '\t'}: inc j
  var e = j
  while e < result.len and result[e] in {'a'..'z', 'A'..'Z', '_'}: inc e
  let dir = result[j ..< e]
  if dir.len == 0: return
  var rest = result[e .. ^1]
  var head = "#" & dir
  if dir in ["include", "include_next", "import", "pragma", "error", "warning", "line", "ident"]:
    let r = rest.strip
    return head & (if r.len > 0: " " & r else: "")
  if dir == "define":
    var a = 0
    while a < rest.len and rest[a] in {' ', '\t'}: inc a
    var b = a
    while b < rest.len and (rest[b].isAlphaNumeric or rest[b] in {'_', '$'}): inc b
    if b == a: return
    head.add " " & rest[a ..< b]
    rest = rest[b .. ^1]
    if rest.startsWith("("):
      let c = rest.find(')')
      if c < 0: return
      var ps: seq[string]
      for p in rest[1 ..< c].split(','): ps.add p.strip
      head.add "(" & ps.join(", ") & ")"
      rest = rest[c + 1 .. ^1]
  var ok = true
  let ts = cLex(rest, ok)
  if not ok or ts.len == 0: return head & (if rest.strip.len > 0: " " & rest.strip else: "")
  let info = cInfoOf(ts, cpp)
  let bin = cBinary(ts, cpp)
  var body = ts[0].text
  for k in 1 ..< ts.len:
    let ws = rest[min(rest.len, ts[k - 1].col + ts[k - 1].text.len) ..< min(rest.len, ts[k].col)]
    if ts[k - 1].kind == ckWord and ts[k - 1].text == "defined" and ts[k].text == "(":
      body.add ts[k].text                   # (`defined(X)`, in every style)
      continue
    body.add cSepStyled(ts, info, k - 1, k, ws, st, cpp, bin[k - 1], bin[k])
    body.add ts[k].text
  result = head & " " & body

proc fmtCWith*(text: string, st: CStyle, cpp = false): (string, string)

proc cMacroFormat(t: string, st: CStyle, cpp: bool, ind: int): seq[string] =
  ## a directive continued with `\` over several lines, formatted as clang-format does: a #define's head
  ## spaced, its body formatted as code (one level in; a `{` block on the line below the head), its `\` lined
  ## up (AlignEscapedNewlines); another directive (`#if a && \⏎ b`) on one line when there is no column
  ## limit — [] when it is left as it is (a body with `#` or `##`, or one that does not format)
  if st.escNewlines < 0: return
  let joined = cPPJoined(t)
  var j = 1
  while j < joined.len and joined[j] in {' ', '\t'}: inc j
  var e = j
  while e < joined.len and joined[e] in {'a'..'z', 'A'..'Z', '_'}: inc e
  let dir = joined[j ..< e]
  if dir != "define":
    if st.colLimit == 0 and dir in ["if", "elif"]: return @[cPPNormal(joined, st, cpp)]
    return
  # the head: #define NAME(params)
  var rest = joined[e .. ^1]
  var a = 0
  while a < rest.len and rest[a] in {' ', '\t'}: inc a
  var b = a
  while b < rest.len and (rest[b].isAlphaNumeric or rest[b] in {'_', '$'}): inc b
  if b == a: return
  var head = "#define " & rest[a ..< b]
  rest = rest[b .. ^1]
  if rest.startsWith("("):
    let c = rest.find(')')
    if c < 0: return
    var ps: seq[string]
    for p in rest[1 ..< c].split(','): ps.add p.strip
    head.add "(" & ps.join(", ") & ")"
    rest = rest[c + 1 .. ^1]
  if '#' in rest: return
  # the body as it was written: its own lines (the first maybe on the head's line)
  var bodyLines: seq[string]
  var first = true
  var onHead = false
  for l in t.split('\n'):
    var x = l.strip(leading = false)
    if x.endsWith("\\"): x.setLen(x.len - 1)
    if first:
      first = false
      # (what follows the head on its own line)
      let hl = x
      let k = hl.find(rest.strip.split(' ')[0]) 
      discard k
      continue
    bodyLines.add x
  # (the first body line on the head's line: the rest of the joined text before the second line's content)
  let firstLine = cPPJoined(t.split('\n')[0] & "\n")
  var headRest = ""
  block:
    var fl = t.split('\n')[0].strip(leading = false)
    if fl.endsWith("\\"): fl.setLen(fl.len - 1)
    discard firstLine
    # (the head's own text ends where the parameters close, or the name ends)
    var q = fl.find("define")
    if q < 0: return
    q += 6
    while q < fl.len and fl[q] in {' ', '\t'}: inc q
    while q < fl.len and (fl[q].isAlphaNumeric or fl[q] in {'_', '$'}): inc q
    if q < fl.len and fl[q] == '(':
      let c = fl.find(')', q)
      if c < 0: return
      q = c + 1
    headRest = fl[q .. ^1].strip
  onHead = headRest.len > 0
  var body = (if onHead: headRest & "\n" else: "") & bodyLines.join("\n")
  if body.strip.len == 0: return
  var bst = st
  bst.colLimit = (if st.colLimit > 0: max(20, st.colLimit - 2 - st.indent) else: 0)
  bst.escNewlines = -1
  let (fb, err) = fmtCWith(body.strip(leading = false) & "\n", bst, cpp)
  if err.len > 0: return
  var outl: seq[string]
  let fbl = fb.strip(chars = {'\n'}).split('\n')
  if onHead and not body.strip.startsWith("{") and fbl.len == 1:
    outl.add head & " " & fbl[0]
  else:
    outl.add head
    for x in fbl: outl.add (if x.len > 0: spaces(st.indent) & x else: "")
  if outl.len == 1: return outl
  # the `\`s
  var longest = 0
  for k in 0 ..< outl.high: longest = max(longest, outl[k].len)
  let col = case st.escNewlines
            of 2: (if st.colLimit > 0: max(longest + 1, st.colLimit - 1) else: longest + 1)
            of 1: longest + 1
            else: 0
  for k in 0 ..< outl.high:
    outl[k] = (if col > 0: outl[k] & spaces(col - outl[k].len) else: outl[k] & " ") & "\\"
  outl

proc cReindent(text: string, st: CStyle, cpp: bool): (string, string) =
  ## (text, error) — each line indented by its braces and spaced (your line breaks kept)
  var ok = true
  let toks = cLex(text, ok)
  if not ok: return (text, "cannot read this C (an unclosed comment or string?)")
  let styled = st.name != "keep"
  let info = if styled: cInfoOf(toks, cpp) else: CInfo()
  let src = text.split('\n')
  let bin = cBinary(toks, cpp)
  var byLine = newSeq[seq[int]](src.len)        # the tokens that start on each line
  for k, t in toks:
    if t.line < byLine.len: byLine[t.line].add k
  var covered = newSeq[int](src.len)            # a line inside a token that started earlier: that token
  for k in 0 ..< src.len: covered[k] = -1
  for k, t in toks:
    for l in t.line + 1 .. t.endLine:
      if l < covered.len: covered[l] = k
  let w = max(1, st.indent)
  var outp: seq[string]
  var stack: seq[char]          # open brackets: { ( [
  var openCol: seq[int]         # (styled) the column after each open bracket in the result
  var openLast: seq[bool]       # … and whether it ended its line
  var isSwitch: seq[bool]       # … and whether a `{` is a switch's
  var isCaseBlock: seq[bool]    # … or a case's (`case 1: {` — its inside at the case's statements' level)
  var openInd: seq[int]         # … and the indentation of the line it opened on (a closing line goes there)
  var gnuBrace: seq[bool]       # … (IndentBraces) a block's `{` on a line of its own: its inside a level more
  var lineInd = 0               # (this line's indentation, for what it opens)
  var pending = 0               # bodies without braces still to come (if (a) ⏎ x;)
  var prevLast = CTok(kind: ckPunct, text: ";")    # the last code token of the line before
  var stmtNew, stmtOld = 0      # where the statement a continuation line belongs to starts (new and old)
  var stmtFirst = ""            # and its first word
  var stmtLine = -1             # (styled) the result line it starts on
  var shift = newSeq[int](toks.len)   # how far a token's first line moved (its other lines move as far)
  var colOf = newSeq[int](toks.len)   # (styled) where each token ends in its result line
  var ppDone = newSeq[bool](toks.len)  # (styled) a continued directive formatted whole
  var blanks = 0
  template push(ch: char, col: int, last, sw: bool, cb = false, gb = false) =
    stack.add ch
    openCol.add col
    openLast.add last
    isSwitch.add sw
    isCaseBlock.add cb
    openInd.add lineInd
    gnuBrace.add gb
  template pop() =
    stack.setLen(stack.len - 1)
    openCol.setLen(openCol.len - 1)
    openLast.setLen(openLast.len - 1)
    isSwitch.setLen(isSwitch.len - 1)
    isCaseBlock.setLen(isCaseBlock.len - 1)
    openInd.setLen(openInd.len - 1)
    gnuBrace.setLen(gnuBrace.len - 1)
  type PPState = (seq[char], seq[int], seq[bool], seq[bool], seq[bool], seq[int], seq[bool], int)
  var ppSaved: seq[PPState]                 # (at each open #if: the brackets as it found them)
  var ppAfter: seq[(bool, PPState)]         # (… and as its first branch left them, once an #else came)
  let frozen = cFrozen(src, styled)
  for l in 0 ..< src.len:
    let raw = src[l]
    if frozen[l]:
      # (`// clang-format off` …, `#if 0` …: as written — its brackets still counted)
      outp.add raw
      for k in byLine[l]:
        let t = toks[k]
        if t.kind == ckPunct:
          if t.text in ["{", "(", "["]: push(t.text[0], 0, true, false)
          elif t.text in ["}", ")", "]"] and stack.len > 0: pop()
        if t.kind notin {ckLineComment, ckBlockComment}: prevLast = t
      blanks = 0
      continue
    if covered[l] >= 0:
      # inside a block comment or a continued macro: moved as far as its first line
      let s = shift[covered[l]]
      let lead = cIndentOf(raw)
      let tok = toks[covered[l]]
      if tok.kind == ckPP and ppDone[covered[l]]: continue        # (formatted with its first line)
      if tok.kind == ckPP: outp.add raw.strip(leading = false)
      elif tok.kind in {ckStr, ckChar}: outp.add raw          # a string continued with \ : exactly as it is
      else: outp.add spaces(max(0, lead + s)) & raw.strip(trailing = false).strip(leading = false)
      # (tokens after the comment's end on this line: as written)
      for k in byLine[l]:
        let t = toks[k]
        if t.kind notin {ckLineComment, ckBlockComment, ckPP}:
          for ch in t.text:
            if ch in {'{', '(', '['}: push(ch, 0, true, false)
            elif ch in {'}', ')', ']'} and stack.len > 0: pop()
          prevLast = t
      continue
    if raw.strip.len == 0:
      inc blanks
      if blanks <= st.maxBlank and outp.len > 0: outp.add ""
      continue
    blanks = 0
    let ts = byLine[l]
    if ts.len == 0:
      outp.add raw.strip(leading = false)
      continue
    let first = toks[ts[0]]
    let oldInd = cIndentOf(raw)
    if first.kind == ckPP:
      shift[ts[0]] = -oldInd
      # (#if … #else … #endif whose branches open or close braces differently — `#ifdef X⏎ if (a) {⏎#else⏎
      # if (b) {⏎#endif`: each branch from where the #if left things, the code after from the first branch)
      block:
        var dw = first.text[1 .. ^1].strip
        var de = 0
        while de < dw.len and dw[de] in {'a'..'z'}: inc de
        dw = dw[0 ..< de]
        case dw
        of "if", "ifdef", "ifndef":
          ppSaved.add (stack, openCol, openLast, isSwitch, isCaseBlock, openInd, gnuBrace, pending)
          ppAfter.add (false, (stack, openCol, openLast, isSwitch, isCaseBlock, openInd, gnuBrace, pending))
        of "elif", "else":
          if ppSaved.len > 0:
            if not ppAfter[^1][0]:
              ppAfter[^1] = (true, (stack, openCol, openLast, isSwitch, isCaseBlock, openInd, gnuBrace, pending))
            (stack, openCol, openLast, isSwitch, isCaseBlock, openInd, gnuBrace, pending) = ppSaved[^1]
        of "endif":
          if ppSaved.len > 0:
            if ppAfter[^1][0]:
              (stack, openCol, openLast, isSwitch, isCaseBlock, openInd, gnuBrace, pending) = ppAfter[^1][1]
            ppSaved.setLen(ppSaved.len - 1)
            ppAfter.setLen(ppAfter.len - 1)
        else: discard
      if styled and ('\n' in first.text or first.text.splitWhitespace.len > 2 and
                     first.text.strip(trailing = false)[1 .. ^1].strip.startsWith("define")):
        let m = cMacroFormat(first.text, st, cpp, 0)
        if m.len > 0:
          for x in m: outp.add x
          ppDone[ts[0]] = true
          continue
      outp.add (if styled and '\n' notin first.text: cPPNormal(first.text, st, cpp)
                else: first.text.split('\n')[0].strip(leading = false))
      continue
    # this line's indentation
    var lead = 0
    block:
      var j = stack.high
      for k in ts:
        if toks[k].text != "}": break
        while j >= 0 and stack[j] notin {'{', 'L'}: dec j
        if j >= 0 and stack[j] == '{': inc lead
        dec j
    let closesList = styled and first.text == "}" and stack.len > 0 and stack[^1] == 'L'
    let inBraces = stack.len == 0 or stack[^1] == '{'
    var depth = 0
    for ch in stack:
      if ch == '{': inc depth
    # a continuation line: inside ( or [, or after an operator that wants more
    let startsWithOp = first.kind == ckPunct and (first.text in ["?", "&&", "||", "==", "!=", "<=", ">=", "+", "-",
                                                                 "/", "%", "|", "^", "<<", ">>", "<", ">"] or
                       (first.text == ":" and not (styled and (info.caseColon[ts[0]] or info.role[ts[0]] == 2)))) and
                       prevLast.kind != ckPP and prevLast.text notin [";", "{", "}"]
    let cont = not inBraces or startsWithOp or
               (prevLast.kind == ckPunct and prevLast.text notin [";", "{", "}", ":", ")", "]"] and
                not (prevLast.text == "," and inBraces) and
                not (prevLast.text in ["*", "&"] and stack.len == 0))   # static char * ⏎ name(…): a return type
    let isLabel = first.kind == ckWord and (first.text == "case" or (first.text == "default" and ts.len > 1 and
         toks[ts[1]].text == ":") or (first.text in ["public", "private", "protected"] and ts.len > 1 and
         toks[ts[1]].text == ":"))
    # (a goto label, `again:` — styled: one level out, as clang-format's IndentGotoLabels has it)
    let gotoLabel = styled and not isLabel and first.kind == ckWord and ts.len > 1 and toks[ts[1]].text == ":" and
                    info.caseColon[ts[1]]
    var ind: int
    if (cont and (first.text != "{" or (styled and not inBraces))) or closesList:
      var qcol = -1                     # (a ternary's `:` under its `?` — inside parentheses too)
      if styled and st.alignOperands and first.kind == ckPunct and first.text == ":" and info.ternary[ts[0]] and
         stmtLine >= 0:
        for li in countdown(outp.high, stmtLine):
          var okq = true
          let lt = cLex(outp[li], okq)
          if not okq: break
          for x in countdown(lt.high, 0):
            if lt[x].text == "?":
              qcol = lt[x].col
              break
          if qcol >= 0: break
      if styled and qcol >= 0: ind = qcol
      elif styled:
        if not inBraces and st.alignAfterParen and not openLast[^1] and first.text notin [")", "]", "}"]:
          ind = openCol[^1]
        elif first.text in [")", "]"] or closesList: ind = (if stack.len > 0: openInd[^1] else: stmtNew)
        else:
          ind = (if not inBraces and stack.len > 0: openInd[^1] else: stmtNew) + st.contIndent
          if st.alignOperands and inBraces and stmtLine >= 0 and stmtLine < outp.len:
            # (AlignOperands: under the first operand — after the statement's `= ` or `return ` — and a
            # ternary's `:` under its `?`)
            var anchor = -1
            if first.kind == ckPunct and first.text == ":":
              for li in countdown(outp.high, stmtLine):
                var okq = true
                let lt = cLex(outp[li], okq)
                if not okq: break
                for x in countdown(lt.high, 0):
                  if lt[x].text == "?":
                    anchor = lt[x].col
                    break
                if anchor >= 0: break
            if anchor < 0:
              var okq = true
              let lt = cLex(outp[stmtLine], okq)
              var d = 0
              if okq:
                for x in 0 ..< lt.len:
                  let tt = lt[x]
                  if tt.kind == ckPunct and tt.text in ["(", "[", "{"]: inc d
                  elif tt.kind == ckPunct and tt.text in [")", "]", "}"]: dec d
                  elif d == 0 and x + 1 < lt.len and ((tt.kind == ckPunct and tt.text in ["=", "+=", "-=", "*=",
                       "/=", "|=", "&=", "^=", "%=", "<<=", ">>="]) or (tt.kind == ckWord and tt.text == "return")):
                    anchor = lt[x + 1].col + (if tt.text == "return" and first.text in ["?", ":"]: st.contIndent
                                              else: 0)
                    break
            if anchor > stmtNew: ind = anchor
      else:
        let rel = oldInd - stmtOld
        ind = if first.text in [")", "]"]: stmtNew + max(0, rel)       # foo( ⏎ a ⏎ );
              else: stmtNew + (if rel > 0: rel else: 2 * w)
    else:
      var lvl = depth - min(lead, depth) + pending
      if styled:
        # (a case's block: its inside at the level of the case's statements, its `}` at the case's)
        var bk: seq[bool]
        for k2, ch in stack:
          if ch == '{': bk.add isCaseBlock[k2]
        let keep = max(0, bk.len - lead)
        for k2 in 0 ..< keep:
          if bk[k2]: dec lvl
        if lead > 0 and keep < bk.len and bk[keep]: dec lvl
        lvl = max(0, lvl)
      if st.caseIndent:
        # (IndentCaseLabels: each switch's body one level in — its labels at that level, the rest one more)
        var braces: seq[bool]
        for k2, ch in stack:
          if ch == '{': braces.add isSwitch[k2]
        let open = braces[0 ..< max(0, braces.len - lead)]
        var extra = 0
        for sw in open:
          if sw: inc extra
        if isLabel and open.len > 0 and open[^1]: dec extra
        lvl += extra
      elif isLabel:
        lvl = max(0, lvl - 1)
      if gotoLabel: lvl = max(0, lvl - 1)
      if st.indentBraces:
        # (GNU: a block's braces one level in from its statement, the inside one more)
        var gb: seq[bool]
        for k2, ch in stack:
          if ch == '{': gb.add gnuBrace[k2]
        let keep = max(0, gb.len - lead)
        for k2 in 0 ..< keep:
          if gb[k2]: inc lvl
        if lead > 0 and keep < gb.len and gb[keep]: inc lvl
      if first.text == "{" and pending > 0 and not st.indentBraces:
        lvl = max(0, lvl - 1)      # if (a) ⏎ { — the brace at the if's level
      ind = lvl * w
      stmtNew = ind
      stmtLine = outp.len
      stmtOld = oldInd
      stmtFirst = first.text
      if first.text == "}" and ts.len > 1: stmtFirst = "} " & toks[ts[1]].text
    # the line, its tokens spaced
    lineInd = ind
    var s = spaces(ind)
    for n, k in ts:
      let t = toks[k]
      if n > 0:
        let p = toks[ts[n - 1]]
        let ws = raw[min(raw.len, p.col + p.text.len) ..< min(raw.len, t.col)]
        # (C++ `operator==(…)`: as written)
        let afterOperator = (n >= 2 and toks[ts[n - 2]].text == "operator") or p.text == "operator"
        s.add (if afterOperator: (if ws.len > 0: " " else: "")
               elif styled: cSepStyled(toks, info, ts[n - 1], k, ws, st, cpp, bin[ts[n - 1]], bin[k])
               else: cSep(p, t, ws, cpp, bin[ts[n - 1]], bin[k]))
      if t.kind in {ckBlockComment, ckPP, ckStr, ckChar} and '\n' in t.text:
        shift[k] = cColOf(s, s.len) - cColOf(raw, t.col)
        s.add t.text.split('\n')[0]
      else: s.add t.text
      colOf[k] = s.len
    outp.add s.strip(leading = false)
    # what this line leaves open
    var lastCode = -1
    for k in ts:
      if toks[k].kind notin {ckLineComment, ckBlockComment}: lastCode = k
    for k in ts:
      let t = toks[k]
      if t.kind in {ckLineComment, ckBlockComment}: continue
      if t.kind == ckPunct:
        case t.text
        of "{", "(", "[":
          var sw = false
          var cb = false
          if styled and t.text == "{":
            let p = info.prevC[k]
            if p >= 0 and toks[p].text == ")" and info.ctlParen[p]:
              let kw = info.prevC[info.match[p]]
              sw = kw >= 0 and toks[kw].text == "switch"
            cb = p >= 0 and toks[p].text == ":" and info.caseColon[p]
          let ch = if styled and t.text == "{" and info.brace[k] == cbInit: 'L' else: t.text[0]
          let gb = st.indentBraces and t.text == "{" and k == ts[0] and info.brace[k] in {cbCtl, cbDo, cbBlock}
          push(ch, colOf[k], k == lastCode, sw, cb, gb)
        of "}", ")", "]":
          if stack.len == 0: return (text, "the brackets do not match")
          pop()
        else: discard
    if lastCode >= 0:
      let lt = toks[lastCode]
      let ft = stmtFirst
      let atStmt = stack.len == 0 or stack[^1] == '{'
      let opensBody = atStmt and ((ft in ["if", "for", "while", "switch"] and lt.text == ")") or
                      (ft in ["else", "} else"] and (lt.text == "else" or lt.text == ")")) or
                      (ft == "do" and lt.text == "do"))
      if opensBody: inc pending
      elif lt.text in [";", "}"] and atStmt: pending = 0
      elif lt.text == "{": pending = 0
      prevLast = lt
  if stack.len != 0: return (text, "the brackets do not match")
  while outp.len > 0 and outp[^1].len == 0: outp.setLen(outp.len - 1)
  (outp.join("\n") & (if text.endsWith("\n"): "\n" else: ""), "")

# ── pass 3: what looks across lines — long lines wrapped, comments, macros, `=` and names lined up ──

proc cLineToks(line: string): seq[CTok] =
  ## the tokens of one line of code ([] when it does not lex on its own: inside a comment or a string)
  var ok = true
  result = cLex(line, ok)
  if not ok: result = @[]

proc cWrapLine(line: string, st: CStyle, cpp: bool): seq[string] =
  ## a line longer than the column limit, broken where clang-format would: between adjacent strings, after a
  ## comma (the arguments under the first one: AlignAfterOpenBracket), before a ternary's `?` and `:` (the `:`
  ## under its `?`), after && || and other operators, after `=` when the rest then fits, else after an open
  ## parenthesis — each piece as long as fits (BinPackArguments)
  let toks = cLineToks(line)
  if toks.len < 3: return @[line]
  for t in toks:
    if t.kind in {ckPP} or (t.kind == ckBlockComment and '\n' in t.text): return @[line]
  let ind = cIndentOf(line)
  var seps = newSeq[string](toks.len)
  for k in 1 ..< toks.len:
    seps[k] = line[toks[k - 1].col + toks[k - 1].text.len ..< toks[k].col]
  let bin = cBinary(toks, cpp)
  # (a ternary's `?` and `:`)
  var tern = newSeq[bool](toks.len)
  var colonOf = newSeq[int](toks.len)       # a `?`'s `:`
  block:
    var qs: seq[int]
    for k, t in toks:
      colonOf[k] = -1
      if t.kind == ckPunct and t.text == "?":
        qs.add k
        tern[k] = true
      elif t.kind == ckPunct and t.text == ":" and qs.len > 0:
        colonOf[qs.pop()] = k
        tern[k] = true
  proc widthOf(a, b: int): int =
    ## the columns tokens a..b take on one line
    for j in a .. b:
      if j > a: result += seps[j].len
      result += toks[j].text.len
  var lines: seq[string]
  var start = 0
  var curInd = ind
  var parenStack: seq[(int, int)]   # (token, column after it in the result) of the brackets still open
  var qCols: seq[int]               # the columns of the `?`s in the result (a `:` piece goes under its `?`)
  var strCol = -1                   # where the run of adjacent strings started in the result
  var mustBreak = -1                # a `:` whose `?` started a line: it starts one too
  var opCol = -1                    # (AlignOperands) the first operand's column: after `= ` or `return `
  var opReturn = false
  var guard = 0
  while start < toks.len and guard < 200:
    inc guard
    var col = curInd
    var best = -1
    var bestScore = high(int)
    var bestInd = 0
    var k = start
    var localStack = parenStack
    var localQ = qCols
    var stackAt = newSeq[seq[(int, int)]](toks.len + 1)
    var qAt = newSeq[seq[int]](toks.len + 1)
    var over = false
    var lStr = strCol
    while k < toks.len:
      let t = toks[k]
      if k == mustBreak and k > start and best >= 0:
        best = k - 1
        bestInd = (if localQ.len > 0: localQ[^1] else: bestInd)
        over = true
        break
      let sep = if k == start: 0 else: seps[k].len
      let w = sep + t.text.len
      if col + w > st.colLimit and k > start and t.kind notin {ckLineComment, ckBlockComment} and best >= 0:
        over = true                     # (past the limit — `;` and `)` too: the break comes before them)
        break
      let tokCol = col + sep
      col += w
      if t.kind == ckPunct:
        if t.text in ["(", "[", "{"]: localStack.add (k, col)
        elif t.text in [")", "]", "}"] and localStack.len > 0: localStack.setLen(localStack.len - 1)
        if tern[k] and t.text == "?": localQ.add tokCol
        elif tern[k] and t.text == ":" and localQ.len > 0: localQ.setLen(localQ.len - 1)
      if t.kind == ckStr and (k == 0 or toks[k - 1].kind notin {ckStr, ckWord}): lStr = tokCol
      if start == 0 and opCol < 0 and localStack.len == 0 and k + 1 < toks.len and
         ((t.kind == ckPunct and t.text in ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]) or
          (t.kind == ckWord and t.text == "return")):
        opCol = col + seps[k + 1].len
        opReturn = t.kind == ckWord
      stackAt[k + 1] = localStack
      qAt[k + 1] = localQ
      # a place to break after this token
      if k + 1 < toks.len and k >= start:
        let nx = toks[k + 1]
        if not (nx.kind == ckPunct and nx.text in [";", ")", ",", "]"]) and nx.kind notin {ckLineComment}:
          let d = localStack.len
          var score = -1
          var ni = curInd + st.contIndent
          if localStack.len > 0 and st.alignAfterParen and localStack[^1][0] != k: ni = localStack[^1][1]
          elif localStack.len > 0 and localStack[^1][0] == k: ni = (if start == 0: ind else: curInd) + st.contIndent
          if (t.kind == ckStr and nx.kind in {ckStr, ckWord} or t.kind == ckWord and nx.kind == ckStr) and
             lStr >= 0 and (t.kind == ckStr or nx.kind == ckStr):
            score = 10 * d + (if t.kind == ckStr and nx.kind == ckStr: 0 else: 1)   # (between two strings first)
            if lStr > 0: ni = lStr
          elif t.kind == ckPunct and t.text == ",": score = 10 * d + 2
          elif nx.kind == ckPunct and tern[k + 1]:
            # (an assignment's ternary: before its `?` — under the first operand — then its `:`; a `return`'s,
            # or one inside parentheses: its `:` under its `?`)
            let assign = d == 0 and opCol >= 0 and not opReturn
            score = 10 * d + (if nx.text == "?": (if assign: 3 else: 5) else: 4)
            if nx.text == ":" and localQ.len > 0: ni = localQ[^1]
            elif nx.text == "?" and st.alignOperands and assign: ni = opCol
          elif t.kind == ckPunct and t.text in ["&&", "||"]: score = 10 * d + 4
          elif t.kind == ckPunct and d == 0 and nx.text != "{" and t.text in ["=", "+=", "-=", "*=", "/=", "%=",
                                                                               "&=", "|=", "^=", "<<=", ">>="]:
            # (after `=`: best when the rest then fits on one line)
            score = (if curInd + st.contIndent + widthOf(k + 1, toks.high) <= st.colLimit: 1 else: 9)
            ni = (if start == 0: ind else: curInd) + st.contIndent
          elif t.kind == ckPunct and bin[k]: score = 10 * d + 6
          elif t.kind == ckPunct and t.text in ["(", "[", "{"]: score = 50 + 10 * d
          if score >= 0 and score <= bestScore:
            best = k
            bestScore = score
            bestInd = ni
      inc k
    var s = (if start == 0: line[0 ..< ind] else: spaces(curInd))
    if not over or best < 0:
      for j in start ..< toks.len:
        if j > start: s.add seps[j]
        s.add toks[j].text
      lines.add s
      break
    for j in start .. best:
      if j > start: s.add seps[j]
      s.add toks[j].text
    lines.add s.strip(leading = false)
    parenStack = stackAt[best + 1]
    qCols = qAt[best + 1]
    strCol = lStr
    curInd = bestInd
    start = best + 1
    if toks[start].kind == ckPunct and toks[start].text == "?" and tern[start] and opCol >= 0 and not opReturn:
      mustBreak = colonOf[start]
  if lines.len == 0: @[line] else: lines

proc cAlignRun(lines: var seq[string], run: seq[(int, int)]) =
  ## the lines of a run, each with the column where its part to line up starts: that part moved to the run's
  ## furthest column
  if run.len < 2: return
  var target = 0
  for (li, c) in run:
    var e = c
    while e > 0 and lines[li][e - 1] == ' ': dec e
    target = max(target, e + 1)
  for (li, c) in run:
    var e = c
    while e > 0 and lines[li][e - 1] == ' ': dec e
    lines[li] = lines[li][0 ..< e] & spaces(target - e) & lines[li][c .. ^1]

proc cPostWrap(text: string, st: CStyle, cpp: bool): (string, bool) =
  ## the lines longer than the column limit wrapped — (text, whether any was)
  var lines = text.split('\n')
  var ok = true
  let toks = cLex(text, ok)
  if not ok: return (text, false)
  var plain = newSeq[bool](lines.len)
  let frozen0 = cFrozen(lines, st.name != "keep")
  for i in 0 ..< lines.len: plain[i] = not frozen0[i]
  for t in toks:
    for l in t.line + 1 .. t.endLine:
      if l < plain.len: plain[l] = false
    if t.kind == ckPP and t.line < plain.len: plain[t.line] = false
  var res: seq[string]
  var changed = false
  for i, l in lines:
    if plain[i] and l.len > st.colLimit:
      let ts = cLineToks(l)
      var spans = ts.len == 0
      for t in ts:
        if t.endLine > 0: spans = true
      if spans or (i + 1 < lines.len and not plain[i + 1] and ts.len > 0 and ts[^1].kind == ckBlockComment):
        res.add l
        continue
      let w = cWrapLine(l, st, cpp)
      if w.len > 1: changed = true
      for piece in w: res.add piece
    else: res.add l
  (res.join("\n"), changed)

proc cPost(text: string, st: CStyle, cpp: bool): string =
  var text = text
  if st.colLimit > 0:
    # (wrapped, then indented again — the way a second run would — until it holds)
    for round in 0 ..< 3:
      let (w, changed) = cPostWrap(text, st, cpp)
      if not changed: break
      let (r, err) = cReindent(w, st, cpp)
      text = if err.len == 0: r else: w
  var lines = text.split('\n')
  # which lines are code of their own (not inside a block comment, a string or a macro continued with \)
  var ok = true
  let toks = cLex(text, ok)
  if not ok: return text
  var plain = newSeq[bool](lines.len)
  let frozen0 = cFrozen(lines, st.name != "keep")
  for i in 0 ..< lines.len: plain[i] = not frozen0[i]
  for t in toks:
    for l in t.line + 1 .. t.endLine:
      if l < plain.len: plain[l] = false
    if t.kind == ckPP and t.line < plain.len: plain[t.line] = false
  # long lines wrapped (cPostWrap: the lines are indented again after, until nothing changes)
  if false:
    var res: seq[string]
    for i, l in lines:
      if plain[i] and l.len > st.colLimit and (i + 1 >= lines.len or plain[i + 1] or true):
        let ts = cLineToks(l)
        if ts.len > 0 and ts[^1].kind == ckBlockComment and '\n' in ts[^1].text:
          res.add l
          continue
        # (a line whose last token goes on below — a block comment opened here: as it is)
        var spans = false
        for t in ts:
          if t.endLine > 0: spans = true
        if spans or (i + 1 < lines.len and not plain[i + 1] and ts.len > 0 and ts[^1].kind == ckBlockComment):
          res.add l
          continue
        for piece in cWrapLine(l, st, cpp): res.add piece
      else: res.add l
    if res.len != lines.len:
      lines = res
      let t2 = cLex(lines.join("\n"), ok)
      plain = newSeq[bool](lines.len)
      let frozen1 = cFrozen(lines, st.name != "keep")
      for i in 0 ..< lines.len: plain[i] = not frozen1[i]
      for t in t2:
        for l in t.line + 1 .. t.endLine:
          if l < plain.len: plain[l] = false
        if t.kind == ckPP and t.line < plain.len: plain[t.line] = false
  # #defines that follow each other: their values at one column (AlignConsecutiveMacros)
  if st.alignMacros:
    var run: seq[(int, int)]
    for i in 0 .. lines.len:
      var c = -1
      if i < lines.len and lines[i].startsWith("#define ") and not lines[i].endsWith("\\"):
        let l = lines[i]
        var j = "#define ".len
        while j < l.len and l[j] == ' ': inc j
        while j < l.len and (l[j].isAlphaNumeric or l[j] == '_'): inc j
        if j < l.len and l[j] == '(':
          let e = l.find(')', j)
          j = (if e > 0: e + 1 else: l.len)
        while j < l.len and l[j] == ' ': inc j
        if j < l.len: c = j
      if c < 0:
        cAlignRun(lines, run)
        run.setLen(0)
      else: run.add (i, c)
  # `=` of assignments that follow each other at one indentation (AlignConsecutiveAssignments)
  if st.alignAssign:
    var run: seq[(int, int)]
    var runInd = -1
    for i in 0 .. lines.len:
      var c = -1
      if i < lines.len and plain[i] and lines[i].strip.len > 0:
        let ts = cLineToks(lines[i])
        var d = 0
        for t in ts:
          if t.kind == ckPunct:
            if t.text in ["(", "[", "{"]: inc d
            elif t.text in [")", "]", "}"]: dec d
            elif d == 0 and t.text in ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]:
              c = t.col
              break
        if ts.len > 0 and ts[0].kind == ckWord and ts[0].text in ["if", "for", "while", "return", "switch"]: c = -1
      let ind = if i < lines.len: cIndentOf(lines[i]) else: -1
      if c < 0 or (run.len > 0 and ind != runInd):
        cAlignRun(lines, run)
        run.setLen(0)
      if c >= 0:
        run.add (i, c)
        runInd = ind
  # the names of declarations that follow each other (AlignConsecutiveDeclarations)
  if st.alignDecls:
    var run: seq[(int, int)]
    var runInd = -1
    for i in 0 .. lines.len:
      var c = -1
      if i < lines.len and plain[i] and lines[i].strip.len > 0:
        let ts = cLineToks(lines[i])
        # (type words, then the name — with its `*`: `char *name` — before ; = [ , ( )
        var j = 0
        var words = 0
        while j < ts.len and ts[j].kind == ckWord and ts[j].text notin ["return", "if", "for", "while", "else",
                                                                        "case", "goto", "do", "switch"]:
          inc words
          inc j
        if words >= 2 and j < ts.len and ts[j].kind == ckPunct and ts[j].text in [";", "=", "[", ",", "(", ")"]:
          c = ts[j - 1].col
          var s = j - 1
          while s > 0 and ts[s - 1].kind == ckPunct and ts[s - 1].text in ["*", "&"] and
                ts[s - 1].col + 1 == ts[s].col:
            dec s
          c = ts[s].col
        elif words >= 1 and j < ts.len and ts[j].kind == ckPunct and ts[j].text in ["*", "&"]:
          var s = j
          while s < ts.len and ts[s].kind == ckPunct and ts[s].text in ["*", "&"]: inc s
          if s < ts.len and ts[s].kind == ckWord and s + 1 < ts.len and ts[s + 1].text in [";", "=", "[", ",", "("]:
            c = (if st.pointer == 2: ts[s].col else: ts[j].col)
      let ind = if i < lines.len: cIndentOf(lines[i]) else: -1
      if c < 0 or (run.len > 0 and ind != runInd):
        cAlignRun(lines, run)
        run.setLen(0)
      if c >= 0:
        run.add (i, c)
        runInd = ind
  # trailing comments of lines that follow each other: at one column (AlignTrailingComments), the way clang-format
  # does it — each comment has the columns it may take (one after its code, with SpacesBeforeTrailingComments, up
  # to the column limit less its length); one whose columns do not meet its run's starts a new run, and so does a
  # line that closes a block (`}`, `} while (x);`) and the line after it
  if st.alignComments:
    var run: seq[(int, int, int)]          # (line, its comment's column, where its code ends)
    var minC = 0
    var maxC = high(int)
    var prevLine = -2
    var prevClosed = false
    template flush() =
      if run.len >= 2:
        for (li, cc, ce) in run:
          lines[li] = lines[li][0 ..< ce] & spaces(max(1, minC - ce)) & lines[li][cc .. ^1]
      run.setLen(0)
    for i in 0 ..< lines.len:
      if not plain[i]:
        flush()
        continue
      let ts = cLineToks(lines[i])
      if not (ts.len >= 2 and ts[^1].kind in {ckLineComment, ckBlockComment} and
              ts[^2].kind notin {ckLineComment, ckBlockComment}):
        flush()
        continue
      var lastCode = ""
      for t in ts:
        if t.kind notin {ckLineComment, ckBlockComment}: lastCode = t.text
      let closes = ts[0].text == "}" and lastCode != "{" and not (ts.len > 1 and ts[1].kind == ckWord and
                                                                    ts[1].text == "else")
      let cc = ts[^1].col
      let ce = ts[^2].col + ts[^2].text.len
      let cmin = ce + (if ts[^1].kind == ckLineComment: max(1, st.commentSpaces) else: 1)
      let clen = lines[i].len - cc
      let cmax = if st.colLimit == 0: high(int) elif st.colLimit >= clen: st.colLimit - clen else: cmin
      if run.len == 0 or i != prevLine + 1 or closes or prevClosed or cmin > maxC or cmax < minC:
        flush()
        minC = cmin
        maxC = cmax
      else:
        minC = max(minC, cmin)
        maxC = min(maxC, cmax)
      run.add (i, cc, ce)
      prevLine = i
      prevClosed = closes
    flush()
  # indentation in tabs (UseTab)
  if st.useTab:
    let tw = max(1, st.tabWidth)
    for i in 0 ..< lines.len:
      if not plain[i] and not lines[i].startsWith("#"): continue
      let l = lines[i]
      var j = 0
      while j < l.len and l[j] == ' ': inc j
      if j >= tw: lines[i] = "\t".repeat(j div tw) & spaces(j mod tw) & l[j .. ^1]
  lines.join("\n")

proc fmtCWith*(text: string, st: CStyle, cpp = false): (string, string) =
  ## (formatted text, error) — ned's own C formatter in a style (cstyle.nim); its result checked: the same tokens

  var ok = true
  let toks = cLex(text, ok)
  if not ok: return (text, "cannot read this C (an unclosed comment or string?)")
  var t = text
  var st = st
  if st.name != "keep":
    let info = cInfoOf(toks, cpp)
    if st.derivePointer:
      # (where this file puts the `*` of its declarations most: at the name, or at the type)
      var right, left = 0
      for k, x in toks:
        if x.kind == ckPunct and x.text == "*" and info.role[k] == 3 and k > 0 and k + 1 < toks.len:
          let a = toks[k - 1]
          let b = toks[k + 1]
          let spaceBefore = a.line == x.line and a.col + a.text.len < x.col
          let spaceAfter = b.line == x.line and x.col + 1 < b.col
          if spaceBefore and not spaceAfter: inc right
          elif spaceAfter and not spaceBefore: inc left
      if right > left: st.pointer = 1
      elif left > right: st.pointer = 2
    t = cStructure(text, toks, info, st)
  let (r, err) = cReindent(t, st, cpp)
  if err.len > 0: return (text, err)
  let posted = if st.name != "keep" or st.alignComments or st.useTab or st.colLimit > 0: cPost(r, st, cpp) else: r
  result = (posted, "")
  # the check: the same tokens
  var ok2 = true
  let toks2 = cLex(result[0], ok2)
  if not ok2 or not cSameTokens(toks, toks2):
    return (text, "the built-in C formatter would change the code here, so nothing was changed")

proc fmtC*(text: string, indentW = 2, cpp = false): (string, string) =
  ## (formatted text, error) — ned's own C formatter, its own way: indentation and spaces, your line breaks kept
  fmtCWith(text, cStyleKeep(indentW), cpp)
