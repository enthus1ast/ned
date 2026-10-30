# ── Nim rewrites in the quick-fix list (Alt+Enter), learned from other languages' servers: the type a let or var
#    gets written out (rust-analyzer, Pylance), a call written the other way — f(x, y) ⇄ x.f(y) —, a call's
#    arguments named, an if/elif chain on one value ⇄ a case, an if/else inverted, an integer literal in another
#    base (rust-analyzer). Each is one edit of the text: nedls offers them as code actions too ──

func rwCodeEnd(s: string): int =
  ## where the line's code ends: its `#` comment's start (outside strings and characters), or s.len
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      let raw = i > 0 and s[i - 1] in {'r', 'R'} and (i == 1 or s[i - 2] notin IdentChars)
      if i + 2 < s.len and s[i + 1] == '"' and s[i + 2] == '"':
        let e = s.find("\"\"\"", i + 3)
        if e < 0: return s.len
        i = e + 3
        continue
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and not raw: inc i
        inc i
      inc i
      continue
    if c == '#': return i
    inc i
  s.len

func rwSimpleExpr(e: string): bool =
  ## an expression that needs no parentheses before `.f`: a name, a.b, a[i], f(x), a literal — nothing spaced out
  let t = e.strip
  if t.len == 0: return false
  var d = 0
  var i = 0
  while i < t.len:
    let c = t[i]
    if c == '"':
      inc i
      while i < t.len and t[i] != '"':
        if t[i] == '\\': inc i
        inc i
    elif c in {'(', '[', '{'}: inc d
    elif c in {')', ']', '}'}: dec d
    elif d == 0 and (c in {' ', '\t'} or (c in {'+', '-', '*', '/', '<', '>', '=', '&', '|', '%', '^', '~', '@', '$', '!'} and
                                          i > 0)):
      return false
    inc i
  true

# ── the type written out ──

proc rwTypesToWrite(b: Buffer): seq[(Pos, string)] =
  ## the names the let/var/const on the cursor's line declares without a type: where `: T` goes, and T (the
  ## engine's answer — none for a tuple unpacked, a pragma after the name, or a type it cannot write)
  let l = b.primary.head.line
  let f = nxFileFor(b)
  if f == nil or l >= b.lines.len: return
  let s = b.lines[l]
  let code = s[0 ..< rwCodeEnd(s)]
  let t = code.strip
  var head = ""
  for kw in ["let ", "var ", "const "]:
    if t.startsWith(kw): head = kw
  if head.len == 0:
    # (a line in a let/var/const section: `name = value` under it)
    var k = l - 1
    let ind = leadingWs(s).len
    while k >= 0 and (b.lines[k].strip.len == 0 or leadingWs(b.lines[k]).len >= ind): dec k
    if k < 0 or ind == 0 or b.lines[k].strip notin ["let", "var", "const"]: return
  let eq = nxFindTop(code, '=')
  if eq <= 0 or (eq + 1 < code.len and code[eq + 1] == '=') or code[eq - 1] in {'<', '>', '!', '='}: return
  let lhs = code[0 ..< eq]
  if nxFindTop(lhs, ':') >= 0 or '(' in lhs or "{." in lhs: return
  var hints: Table[int, seq[(int, string)]]
  let keep = engineInlayBudget
  engineInlayBudget = 1500
  engineTypesFull = true
  try: discard engineTypeHints(b, f, nxScope(f), l, l, hints, getMonoTime())
  except Exception as e: internalError("types to write", e)
  finally:
    engineInlayBudget = keep
    engineTypesFull = false
  for (c, h) in hints.getOrDefault(l):
    if not h.startsWith(": ") or c > eq: continue
    let ty = h[2 .. ^1].strip
    if ty.len == 0 or "…" in ty or "?" in ty or ty in ["untyped", "typed", "auto", "void", "nil"] or
       ty.startsWith("range ") or ty.startsWith("type "): continue
    result.add (Pos(line: l, col: c), ty)

proc rwWriteTypes(bid: int, at: int, ws: seq[(Pos, string)]): Action =
  ## an action that writes each type (`: type`) after its name, from the last to the first so the positions stay right,
  ## as one edit; it does nothing if the buffer changed since the fix was offered
  result = proc() =
    let b = bufById(bid)
    if b == nil or not b.canEdit() or b.changeId != at: return
    b.beginEdit()
    for k in countdown(ws.high, 0):
      let (p, ty) = ws[k]
      discard b.replaceText(p, p, ": " & ty)
    b.endEdit()

# ── f(x, y) ⇄ x.f(y) ──

proc rwCallSyntax(b: Buffer): (string, string, Pos, Pos, string) =
  ## the call the cursor's name makes, written the other way: (title, what, from, to, new text) — "" when none
  let p = b.primary.head
  let s0 = b.lines[p.line]
  let s = s0[0 ..< rwCodeEnd(s0)]
  let (wa, we) = b.wordRangeAt(p)
  if wa.col >= we.col or we.col > s.len: return
  let a = wa.col
  let e = we.col
  let name = s[a ..< e]
  if name[0] in Digits or name in FKeywords: return
  let (rd, ok) = rfDeclOf(b)
  if not ok or rd.sym.kind notin NxRoutineKinds: return
  if rd.file.path == b.path and rd.sym.line == p.line: return             # (its declaration)
  if a >= 1 and s[a - 1] == '.' and not (a >= 2 and s[a - 2] == '.'):
    # x.f(y) → f(x, y)
    var k = a - 2
    var d = 0
    while k >= 0:
      let c = s[k]
      if c in {')', ']', '}'}: inc d
      elif c in {'(', '[', '{'}:
        if d == 0: break
        dec d
      elif c == '"' and d == 0:
        dec k
        while k >= 0 and s[k] != '"': dec k
      elif d == 0 and not (c in IdentChars or c == '.' or c == '`'): break
      dec k
    let ra = k + 1
    let recv = s[ra ..< a - 1]
    if recv.strip.len == 0 or recv.startsWith(".") or recv[0] in {'.'}: return
    var rest = ""
    var stop = e
    if e < s.len and s[e] == '(':
      let close = nxMatchClose(s, e)
      if close < 0: return
      rest = s[e + 1 ..< close].strip
      stop = close + 1
    else:
      var j = e
      while j < s.len and s[j] == ' ': inc j
      if j < s.len and j > e and (s[j] in IdentChars or s[j] in {'"', '\'', '@', '['}): return   # (x.f y: a command)
    let nt = name & "(" & recv & (if rest.len > 0: ", " & rest else: "") & ")"
    return ("Write as " & truncTo(nt, 40), "the call without method syntax", Pos(line: p.line, col: ra),
            Pos(line: p.line, col: stop), nt)
  if e < s.len and s[e] == '(' and not (a > 0 and s[a - 1] in IdentChars):
    # f(x, y) → x.f(y)
    let close = nxMatchClose(s, e)
    if close < 0 or close == e + 1: return
    let args = nxSplitTop(s[e + 1 ..< close], {','})
    if args.len == 0: return
    let first = args[0].strip
    if first.len == 0 or nxFindTop(first, '=') >= 0: return
    let recv = if rwSimpleExpr(first): first else: "(" & first & ")"
    var rest: seq[string]
    for x in args[1 .. ^1]: rest.add x.strip
    let nt = recv & "." & name & (if rest.len > 0: "(" & rest.join(", ") & ")" else: "")
    return ("Write as " & truncTo(nt, 40), "method call syntax", Pos(line: p.line, col: a),
            Pos(line: p.line, col: close + 1), nt)

# ── the arguments named ──

proc rwNameArgs(b: Buffer): (string, Pos, Pos, string) =
  ## the call around the cursor with each argument named after its parameter: (what, from, to, new text)
  let f = nxFileFor(b)
  if f == nil: return
  let p = b.primary.head
  let s0 = b.lines[p.line]
  let s = s0[0 ..< rwCodeEnd(s0)]
  # (the call: the `(` the cursor is in, or the one after the name the cursor is on)
  var open = -1
  let (wa, we) = b.wordRangeAt(p)
  if wa.col < we.col and we.col < s.len and s[we.col] == '(': open = we.col
  else:
    var d = 0
    var k = min(p.col, s.len) - 1
    while k >= 0:
      if s[k] in {')', ']'}: inc d
      elif s[k] in {'(', '['}:
        if d == 0:
          if s[k] == '(' and k > 0 and s[k - 1] in IdentChars: open = k
          break
        dec d
      dec k
  if open <= 0: return
  let close = nxMatchClose(s, open)
  if close < 0 or close == open + 1: return
  var ne = open
  var na = ne
  while na > 0 and s[na - 1] in IdentChars: dec na
  if na == ne or s[na ..< ne] in FKeywords: return
  let args = nxSplitTop(s[open + 1 ..< close], {','})
  for x in args:
    if x.strip.len == 0 or nxFindTop(x, '=') >= 0: return             # (named already: as written)
  var h: NxSigHelp
  try: h = nxSignatureHelp(f, b.lines, p.line, open + 1)
  except Exception: return
  if h.overloads.len == 0: return
  let off = if h.ufcs: 1 else: 0
  var names = newSeq[string](args.len)
  for i in 0 ..< args.len:
    var name = ""
    for r in h.overloads:
      let ps = r.sym.params
      if ps.len - off < args.len: continue
      let idx = i + off
      if ps[idx].typ.startsWith("varargs"): return
      if name.len == 0: name = ps[idx].name
      elif nxNorm(ps[idx].name) != nxNorm(name): return              # (overloads disagree)
    if name.len == 0: return
    names[i] = name
  var parts: seq[string]
  for i, x in args: parts.add names[i] & " = " & x.strip
  let nt = "(" & parts.join(", ") & ")"
  (s[na ..< ne] & truncTo(nt, 40), Pos(line: p.line, col: open), Pos(line: p.line, col: close + 1), nt)

# ── if/elif ⇄ case ──

type RwBranch = tuple[line, colon: int, kw, cond, rest: string]    # a branch's header: its line, where its `:` is

proc rwBranches(b: Buffer, l0: int, kws: openArray[string]): (seq[RwBranch], int) =
  ## the branches of the statement starting on l0 (if/elif/else, case/of/elif/else): their headers, and the last
  ## line of the statement's last branch
  let ind = leadingWs(b.lines[l0]).len
  var last = l0
  var l = l0
  var res: seq[RwBranch]
  while l < b.lines.len:
    let s0 = b.lines[l]
    let s = s0[0 ..< rwCodeEnd(s0)]
    let t = s.strip
    if l > l0 and t.len == 0:
      inc l
      continue
    let li = leadingWs(s0).len
    if l > l0 and li <= ind:
      var kw = ""
      for k in kws:
        if t.startsWith(k & " ") or t.startsWith(k & ":") or t == k: kw = k
      if kw.len == 0 or li < ind: break
      let colon = nxFindTop(s, ':', li + kw.len)
      if colon < 0: return
      res.add (l, colon, kw, s[li + kw.len ..< colon].strip, s0[colon + 1 .. ^1])
    elif l == l0:
      let kw = t.split(' ')[0].strip(chars = {':'})
      let colon = nxFindTop(s, ':', li + kw.len)
      res.add (l, colon, kw, (if colon > 0: s[li + kw.len ..< colon].strip else: s[li + kw.len .. ^1].strip),
               (if colon > 0: s0[colon + 1 .. ^1] else: ""))
    if t.len > 0: last = l
    inc l
  (res, last)

proc rwEnumAll(b: Buffer, subject: string, line: int): seq[string] =
  ## the values of the enum (or bool) `subject` is, from the index — none when it is not one
  let f = nxFileFor(b)
  if f == nil: return
  let sc = nxScope(f)
  let t = nxTypeOfExpr(f, sc, nxLocals(f, b.lines, line, leadingWs(b.lines[line]).len), subject, line, 0).typ
  if t.len == 0: return
  let base = nxResolveAlias(sc, nxBaseName(t))
  if base == "bool": return @["false", "true"]
  for r in nxLookup(sc, base):
    if r.sym.kind != nxType: continue
    for sy in r.file.syms:
      if sy.kind == nxEnumVal and nxNorm(sy.owner) == nxNorm(r.sym.name): result.add sy.name
    if result.len > 0: return

proc rwIfToCase(b: Buffer): (string, int, int, seq[string]) =
  ## an if/elif chain that compares one value with constants (x == A, x == B or x == C, x in {D, E}, x in a..b) as
  ## a case: (the subject, the first and last line replaced, their new lines)
  let l0 = b.primary.head.line
  let s0 = b.lines[l0]
  if not s0.strip.startsWith("if "): return
  let (brs, last) = rwBranches(b, l0, ["elif", "else"])
  if brs.len < 2 or brs[0].colon < 0: return
  var subject = ""
  var vals: seq[seq[string]]
  for k, br in brs:
    if br.kw == "else":
      vals.add @[]
      continue
    var vs: seq[string]
    for part in br.cond.split(" or "):
      let q = part.strip
      var lhs, rhs: string
      let inAt = q.find(" in ")
      let eqAt = q.find(" == ")
      if eqAt > 0:
        lhs = q[0 ..< eqAt].strip
        rhs = q[eqAt + 4 .. ^1].strip
        vs.add rhs
      elif inAt > 0:
        lhs = q[0 ..< inAt].strip
        rhs = q[inAt + 4 .. ^1].strip
        if rhs.startsWith("{") and rhs.endsWith("}"):
          for v in nxSplitTop(rhs[1 .. ^2], {','}):
            if v.strip.len > 0: vs.add v.strip
        elif ".." in rhs and nxFindTop(rhs, ' ') < 0: vs.add rhs
        else: return
      else: return
      if lhs.len == 0 or rhs.len == 0 or " and " in lhs or " and " in rhs: return
      if subject.len == 0: subject = lhs
      elif lhs.replace(" ", "") != subject.replace(" ", ""): return
    vals.add vs
  if subject.len == 0: return
  let ind = spaces(leadingWs(s0).len)
  var outl: seq[string]
  var covered: seq[string]
  var hasElse = false
  for k, br in brs:
    if k == 0:
      outl.add ind & "case " & subject
    if br.kw == "else":
      hasElse = true
      outl.add ind & "else:" & br.rest
    else:
      outl.add ind & "of " & vals[k].join(", ") & ":" & br.rest
      covered.add vals[k]
    # (the branch's body: as it is)
    let stop = if k + 1 < brs.len: brs[k + 1].line - 1 else: last
    for l in br.line + 1 .. stop: outl.add b.lines[l]
  if not hasElse:
    # (a case must cover every value: else: discard, unless every value of an enum or bool has its branch)
    var all: seq[string]
    try: all = rwEnumAll(b, subject, l0)
    except Exception: discard
    var full = all.len > 0
    for v in all:
      var seen = false
      for c in covered:
        if nxNorm(c.split('.')[^1]) == nxNorm(v): seen = true
      if not seen: full = false
    if not full: outl.add ind & "else: discard"
  (subject, l0, last, outl)

proc rwCaseToIf(b: Buffer): (string, int, int, seq[string]) =
  ## a case statement as an if/elif chain: (the subject, the first and last line replaced, their new lines)
  let l0 = b.primary.head.line
  let s0 = b.lines[l0]
  let t = s0[0 ..< rwCodeEnd(s0)].strip
  if not t.startsWith("case "): return
  var subject = t[5 .. ^1].strip
  if subject.endsWith(":"): subject = subject[0 ..< subject.high].strip
  if subject.len == 0 or nxFindTop(subject, ':') >= 0: return            # (an object variant's `case kind: Kind`)
  let ind = leadingWs(s0).len
  # (its branches: at the case's indentation or one level in)
  var ofInd = -1
  for l in l0 + 1 ..< b.lines.len:
    let u = b.lines[l].strip
    if u.len == 0 or u.startsWith("#"): continue
    if u.startsWith("of ") or u.startsWith("else") or u.startsWith("elif "): ofInd = leadingWs(b.lines[l]).len
    break
  if ofInd < ind: return
  var brs: seq[RwBranch]
  var last = l0
  for l in l0 + 1 ..< b.lines.len:
    let r0 = b.lines[l]
    let r = r0[0 ..< rwCodeEnd(r0)]
    let u = r.strip
    if u.len == 0: continue
    let li = leadingWs(r0).len
    if li < ofInd or (li == ofInd and not (u.startsWith("of ") or u.startsWith("else") or u.startsWith("elif "))):
      if li <= ind: break
    if li == ofInd:
      let kw = if u.startsWith("of "): "of" elif u.startsWith("elif "): "elif" else: "else"
      let colon = nxFindTop(r, ':', li + kw.len)
      if colon < 0: return
      brs.add (l, colon, kw, r[li + kw.len ..< colon].strip, r0[colon + 1 .. ^1])
    last = l
  if brs.len == 0: return
  let pad = spaces(ind)
  let simple = rwSimpleExpr(subject)
  let subj = if simple: subject else: "(" & subject & ")"
  var outl: seq[string]
  for k, br in brs:
    let kw = if k == 0: "if" elif br.kw == "else": "else" else: "elif"
    case br.kw
    of "of":
      var conds: seq[string]
      for v in nxSplitTop(br.cond, {','}):
        let x = v.strip
        if x.len == 0: continue
        conds.add (if x.startsWith("{") or (".." in x and nxFindTop(x, ' ') < 0 and not x.startsWith("\"")):
                     subj & " in " & x
                   else: subj & " == " & x)
      outl.add pad & kw & " " & conds.join(" or ") & ":" & br.rest
    of "elif": outl.add pad & kw & " " & br.cond & ":" & br.rest
    else:
      if k == 0: return
      outl.add pad & "else:" & br.rest
    let stop = if k + 1 < brs.len: brs[k + 1].line - 1 else: last
    for l in br.line + 1 .. stop: outl.add b.lines[l]
  (subject, l0, last, outl)

# ── an if/else inverted ──

func rwNegate(c: string): string =
  ## not c, written simply: a comparison turned round, `not x` → x, `x in s` → `x notin s`
  let t = c.strip
  if t.startsWith("not ") and rwSimpleExpr(t[4 .. ^1]): return t[4 .. ^1].strip
  if t.startsWith("not (") and nxMatchClose(t, 4) == t.high: return t[5 ..< t.high].strip
  if t.startsWith("not(") and nxMatchClose(t, 3) == t.high: return t[4 ..< t.high].strip
  var hasWordOp = false
  for w in [" and ", " or ", " xor ", " not "]:
    if w in t: hasWordOp = true
  if not hasWordOp:
    for (op, neg) in [(" == ", " != "), (" != ", " == "), (" <= ", " > "), (" >= ", " < "), (" < ", " >= "),
                      (" > ", " <= "), (" notin ", " in "), (" in ", " notin "), (" isnot ", " is "),
                      (" is ", " isnot ")]:
      let k = t.find(op)
      if k > 0 and t.find(op, k + 1) < 0 and nxFindTop(t, op[1]) >= 0:
        return t[0 ..< k] & neg & t[k + op.len .. ^1]
  if rwSimpleExpr(t): return "not " & t
  "not (" & t & ")"

proc rwInvertIf(b: Buffer): (int, int, seq[string]) =
  ## `if c:` A `else:` B as `if not c:` B `else:` A — (the first and last line replaced, their new lines)
  let l0 = b.primary.head.line
  let s0 = b.lines[l0]
  if not s0.strip.startsWith("if "): return (-1, -1, @[])
  let (brs, last) = rwBranches(b, l0, ["elif", "else"])
  if brs.len != 2 or brs[1].kw != "else" or brs[0].colon < 0: return (-1, -1, @[])
  if brs[0].rest.strip.len > 0 and not brs[0].rest.strip.startsWith("#"): return (-1, -1, @[])
  if brs[1].rest.strip.len > 0 and not brs[1].rest.strip.startsWith("#"): return (-1, -1, @[])
  if brs[1].line == brs[0].line + 1 or last == brs[1].line: return (-1, -1, @[])     # (an empty branch)
  let pad = spaces(leadingWs(s0).len)
  var outl = @[pad & "if " & rwNegate(brs[0].cond) & ":" & brs[0].rest]
  for l in brs[1].line + 1 .. last: outl.add b.lines[l]
  outl.add pad & "else:" & brs[1].rest
  for l in brs[0].line + 1 ..< brs[1].line: outl.add b.lines[l]
  # (the blank lines before `else`: they stay before it)
  (l0, last, outl)

proc rwReplaceAct(bid, at: int, pa, pe: Pos, nt: string): Action =
  ## an action that replaces the text between two positions with nt as one edit; it does nothing if the buffer changed
  ## since the fix was offered
  result = proc() =
    let x = bufById(bid)
    if x == nil or not x.canEdit() or x.changeId != at: return
    x.beginEdit()
    discard x.replaceText(pa, pe, nt)
    x.endEdit()

proc rwReplaceLines(bid, at, l0, l1: int, outl: seq[string]): Action =
  ## an action that replaces whole lines l0 to l1 with the given lines as one edit; it does nothing if the buffer
  ## changed since the fix was offered
  result = proc() =
    let b = bufById(bid)
    if b == nil or not b.canEdit() or b.changeId != at or l1 >= b.lines.len: return
    b.beginEdit()
    discard b.replaceText(Pos(line: l0, col: 0), Pos(line: l1, col: b.lines[l1].len), outl.join("\n"))
    b.endEdit()

# ── an integer literal in another base ──

proc rwIntLiteral(b: Buffer): (Pos, Pos, uint64, string, int) =
  ## the integer literal at the cursor: (from, to, its value, its suffix ('u8 …), its base) — base 0 when none
  let p = b.primary.head
  let s = b.lines[p.line]
  var a = min(p.col, s.len)
  while a > 0 and s[a - 1] in IdentChars + {'\''}: dec a
  var e = min(p.col, s.len)
  while e < s.len and s[e] in IdentChars + {'\''}: inc e
  if a >= e or s[a] notin Digits or (a > 0 and s[a - 1] in {'.'}): return
  if e < s.len and s[e] == '.' and e + 1 < s.len and s[e + 1] in Digits: return            # (a float)
  var lit = s[a ..< e]
  var suffix = ""
  let q = lit.find('\'')
  if q >= 0:
    suffix = lit[q .. ^1]
    lit = lit[0 ..< q]
    if suffix.toLowerAscii notin ["'i8", "'i16", "'i32", "'i64", "'u", "'u8", "'u16", "'u32", "'u64", "'i"]: return
  var base = 10
  var digits = lit
  if lit.len > 2 and lit[0] == '0' and lit[1] in {'x', 'X'}: (base, digits) = (16, lit[2 .. ^1])
  elif lit.len > 2 and lit[0] == '0' and lit[1] in {'b', 'B'}: (base, digits) = (2, lit[2 .. ^1])
  elif lit.len > 2 and lit[0] == '0' and lit[1] in {'o', 'O'}: (base, digits) = (8, lit[2 .. ^1])
  var v: uint64 = 0
  var any = false
  for c in digits:
    if c == '_': continue
    let d = case c
            of '0'..'9': ord(c) - ord('0')
            of 'a'..'f': ord(c) - ord('a') + 10
            of 'A'..'F': ord(c) - ord('A') + 10
            else: 99
    if d >= base: return
    if v > (high(uint64) - uint64(d)) div uint64(base): return            # (too big)
    v = v * uint64(base) + uint64(d)
    any = true
  if not any: return
  (Pos(line: p.line, col: a), Pos(line: p.line, col: e), v, suffix, base)

func rwInBase(v: uint64, base: int): string =
  ## a number written in base 10, 16 (0x…), 8 (0o…) or 2 (0b…, with underscores between groups of four digits when
  ## longer than a byte)
  if base == 10: return $v
  const ds = "0123456789ABCDEF"
  var x = v
  var d = ""
  if x == 0: d = "0"
  while x > 0:
    d.insert $ds[int(x mod uint64(base))]
    x = x div uint64(base)
  if base == 2 and d.len > 8:
    # (in groups of four, from the right: 0b1010_0110)
    var g = ""
    for i, c in d:
      if i > 0 and (d.len - i) mod 4 == 0: g.add '_'
      g.add c
    d = g
  (case base
   of 16: "0x"
   of 2: "0b"
   else: "0o") & d

# ── in the quick-fix list ──

proc nimRewrites(b: Buffer): seq[(string, string, Action)] =
  ## the rewrites that apply at the cursor (ned's engine on)
  let bid = b.id
  let at = b.changeId
  let l = b.primary.head.line
  if l >= b.lines.len: return
  block types:
    var ws: seq[(Pos, string)]
    try: ws = rwTypesToWrite(b)
    except Exception as e: internalError("types to write", e)
    if ws.len == 1: result.add act("Write the type: " & truncTo(ws[0][1], 50), "the type ned works out for it",
                                   rwWriteTypes(bid, at, ws))
    elif ws.len > 1: result.add act("Write the types (" & $ws.len & ")", "the types ned works out for them",
                                    rwWriteTypes(bid, at, ws))
  block callSyntax:
    var r: (string, string, Pos, Pos, string)
    try: r = rwCallSyntax(b)
    except Exception as e: internalError("call syntax", e)
    if r[0].len > 0: result.add act(r[0], r[1], rwReplaceAct(bid, at, r[2], r[3], r[4]))
  block named:
    var r: (string, Pos, Pos, string)
    try: r = rwNameArgs(b)
    except Exception as e: internalError("named arguments", e)
    if r[0].len > 0: result.add act("Name the arguments", r[0], rwReplaceAct(bid, at, r[1], r[2], r[3]))
  let t = b.lines[l].strip
  if t.startsWith("if "):
    var r: (string, int, int, seq[string])
    try: r = rwIfToCase(b)
    except Exception as e: internalError("if to case", e)
    if r[0].len > 0: result.add act("Write as a case on " & truncTo(r[0], 30), "one branch per value",
                                    rwReplaceLines(bid, at, r[1], r[2], r[3]))
    var v: (int, int, seq[string])
    try: v = rwInvertIf(b)
    except Exception as e: internalError("invert if", e)
    if v[0] >= 0: result.add act("Invert the if", "the condition negated, the branches swapped",
                                 rwReplaceLines(bid, at, v[0], v[1], v[2]))
  if t.startsWith("case "):
    var r: (string, int, int, seq[string])
    try: r = rwCaseToIf(b)
    except Exception as e: internalError("case to if", e)
    if r[0].len > 0: result.add act("Write as if/elif", "a condition per branch",
                                    rwReplaceLines(bid, at, r[1], r[2], r[3]))
  block literal:
    let (pa, pe, v, suffix, base) = rwIntLiteral(b)
    if base == 0: break literal
    let old = b.lines[l][pa.col ..< pe.col]
    for nb in [16, 10, 2, 8]:
      if nb == base: continue
      let nt = rwInBase(v, nb) & suffix
      if nb == 2 and v > 0xFFFF'u64: continue                  # (a binary number that long helps nobody)
      let what = case nb
                 of 16: "hexadecimal"
                 of 10: "decimal"
                 of 2: "binary"
                 else: "octal"
      result.add act("Write " & old & " as " & nt, what, rwReplaceAct(bid, at, pa, pe, nt))
