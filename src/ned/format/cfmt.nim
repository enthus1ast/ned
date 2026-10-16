# ════════════════════════════════════════════════════════════════════════════
#  Built-in C formatter, for when clang-format is not installed (C files, and the C in a Nim {.emit.}):
#  indentation by braces (2 spaces, LLVM's layout: case labels at the switch, one level for a body without
#  braces, continuation lines keep their offset), spaces after commas and keywords, around assignments
#  and comparisons, none inside brackets — your line breaks stay. It checks its own result: the tokens
#  must come out the same, or the text is left alone.
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

proc cSameTokens(a, b: seq[CTok]): bool =
  ## the same code: the same tokens in the same order (comments and directives with their spaces evened out)
  if a.len != b.len: return false
  for k in 0 ..< a.len:
    if a[k].kind != b[k].kind: return false
    if a[k].kind in {ckBlockComment, ckPP}:
      if a[k].text.splitWhitespace != b[k].text.splitWhitespace: return false
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

proc cSep(a, b: CTok, ws: string, cpp: bool, aBin = false, bBin = false): string =
  ## the space between two tokens on a line
  if b.kind in {ckLineComment, ckBlockComment}: return (if ws.len > 0: ws else: " ")
  if a.kind in {ckBlockComment}: return (if ws.len > 0: " " else: "")
  let at = a.text
  let bt = b.text
  if at in ["(", "["]: return ""
  if bt in [")", "]"]: return ""
  if bt in [",", ";"]: return ""
  if at == "," : return " "
  if at == ";": return " "
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

proc fmtC*(text: string, indentW = 2, cpp = false): (string, string) =
  ## (formatted text, error) — ned's own C formatter: indentation and spaces, your line breaks kept
  var ok = true
  let toks = cLex(text, ok)
  if not ok: return (text, "cannot read this C (an unclosed comment or string?)")
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
  let w = max(1, indentW)
  var outp: seq[string]
  var stack: seq[char]          # open brackets: { ( [
  var pending = 0               # bodies without braces still to come (if (a) ⏎ x;)
  var prevLast = CTok(kind: ckPunct, text: ";")    # the last code token of the line before
  var stmtNew, stmtOld = 0      # where the statement a continuation line belongs to starts (new and old)
  var stmtFirst = ""            # and its first word
  var shift = newSeq[int](toks.len)   # how far a token's first line moved (its other lines move as far)
  var blanks = 0
  for l in 0 ..< src.len:
    let raw = src[l]
    if covered[l] >= 0:
      # inside a block comment or a continued macro: moved as far as its first line
      let s = shift[covered[l]]
      let lead = cIndentOf(raw)
      let tok = toks[covered[l]]
      if tok.kind == ckPP: outp.add raw.strip(leading = false)
      elif tok.kind in {ckStr, ckChar}: outp.add raw          # a string continued with \ : exactly as it is
      else: outp.add spaces(max(0, lead + s)) & raw.strip(trailing = false).strip(leading = false)
      # (tokens after the comment's end on this line: as written)
      for k in byLine[l]:
        let t = toks[k]
        if t.kind notin {ckLineComment, ckBlockComment, ckPP}:
          for ch in t.text:
            if ch in {'{', '(', '['}: stack.add ch
            elif ch in {'}', ')', ']'} and stack.len > 0: stack.setLen(stack.len - 1)
          prevLast = t
      continue
    if raw.strip.len == 0:
      inc blanks
      if blanks <= 1 and outp.len > 0: outp.add ""
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
      outp.add first.text.split('\n')[0].strip(leading = false)
      continue
    # this line's indentation
    var lead = 0
    for k in ts:
      if toks[k].text == "}": inc lead
      else: break
    let inBraces = stack.len == 0 or stack[^1] == '{'
    var depth = 0
    for ch in stack:
      if ch == '{': inc depth
    # a continuation line: inside ( or [, or after an operator that wants more
    let cont = not inBraces or
               (prevLast.kind == ckPunct and prevLast.text notin [";", "{", "}", ":", ")", "]"] and
                not (prevLast.text == "," and inBraces) and
                not (prevLast.text in ["*", "&"] and stack.len == 0))   # static char * ⏎ name(…): a return type
    var ind: int
    if cont and first.text != "{":
      let rel = oldInd - stmtOld
      ind = if first.text in [")", "]"]: stmtNew + max(0, rel)       # foo( ⏎ a ⏎ );
            else: stmtNew + (if rel > 0: rel else: 2 * w)
    else:
      var lvl = depth - min(lead, depth) + pending
      if first.kind == ckWord and (first.text == "case" or (first.text == "default" and ts.len > 1 and
         toks[ts[1]].text == ":") or (first.text in ["public", "private", "protected"] and ts.len > 1 and
         toks[ts[1]].text == ":")):
        lvl = max(0, lvl - 1)
      if first.text == "{" and pending > 0: lvl = max(0, lvl - 1)      # if (a) ⏎ { — the brace at the if's level
      ind = lvl * w
      stmtNew = ind
      stmtOld = oldInd
      stmtFirst = first.text
      if first.text == "}" and ts.len > 1: stmtFirst = "} " & toks[ts[1]].text
    # the line, its tokens spaced
    var s = spaces(ind)
    for n, k in ts:
      let t = toks[k]
      if n > 0:
        let p = toks[ts[n - 1]]
        let ws = raw[min(raw.len, p.col + p.text.len) ..< min(raw.len, t.col)]
        # (C++ `operator==(…)`: as written)
        let afterOperator = (n >= 2 and toks[ts[n - 2]].text == "operator") or p.text == "operator"
        s.add (if afterOperator: (if ws.len > 0: " " else: "") else: cSep(p, t, ws, cpp, bin[ts[n - 1]], bin[k]))
      if t.kind in {ckBlockComment, ckPP, ckStr, ckChar} and '\n' in t.text:
        shift[k] = cColOf(s, s.len) - cColOf(raw, t.col)
        s.add t.text.split('\n')[0]
      else: s.add t.text
    outp.add s.strip(leading = false)
    # what this line leaves open
    var lastCode = -1
    for k in ts:
      let t = toks[k]
      if t.kind in {ckLineComment, ckBlockComment}: continue
      lastCode = k
      if t.kind == ckPunct:
        case t.text
        of "{", "(", "[": stack.add t.text[0]
        of "}", ")", "]":
          if stack.len == 0: return (text, "the brackets do not match")
          stack.setLen(stack.len - 1)
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
  result = (outp.join("\n") & (if text.endsWith("\n"): "\n" else: ""), "")
  # the check: the same tokens
  var ok2 = true
  let toks2 = cLex(result[0], ok2)
  if not ok2 or not cSameTokens(toks, toks2):
    return (text, "the built-in C formatter would change the code here, so nothing was changed")
