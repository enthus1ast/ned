func nxWordAt*(text: string, col: int): (int, int) =
  var a = min(col, text.len)
  var e = a
  while a > 0 and nxIsIdent(text[a - 1]): dec a
  while e < text.len and nxIsIdent(text[e]): inc e
  (a, e)

proc nxSymAt*(f: NxFile, line, col: int): int
proc nxFileLines*(path: string): seq[string]
proc nxLexRuns*(line: string, st: var NxLexState, ops: bool): seq[(int, int)]

func nxIsOpName*(n: string): bool =
  ## an operator's name (`+`, `==`, `$`, `..<`), not `.` `:` `=` (which are not called)
  n.len > 0 and n.allCharsInSet(NxOpChars) and n notin [".", ":", "=", "::", "*:"]

proc nxOpRunAt*(line: string, col: int): (int, int) =
  ## the operator written at `col` (the cursor on it, or just after it), outside strings and comments
  var st: NxLexState
  for (a, e) in nxLexRuns(line, st, true):
    if a <= col and col <= e and nxIsOpName(line[a ..< e]): return (a, e)
  (0, 0)

func nxOperandBack*(line: string, i: int): int =
  ## where the operand that ends at line[i - 1] starts (words, dots, calls, brackets, strings)
  var k = i
  while k > 0:
    let c = line[k - 1]
    if c in {')', ']', '}'}:
      var depth = 0
      var j = k - 1
      while j >= 0:
        if line[j] in {')', ']', '}'}: inc depth
        elif line[j] in {'(', '[', '{'}:
          dec depth
          if depth == 0: break
        dec j
      if j < 0: return k
      k = j
    elif c == '"':
      let q = if k >= 2: line.rfind('"', last = k - 2) else: -1
      if q < 0: return k
      k = q
    elif nxIsIdent(c) or (c == '.' and k >= 2 and line[k - 2] != '.'): dec k
    else: break
  k

func nxOperandFwd*(line: string, i: int): int =
  ## where the operand that starts at line[i] ends
  var k = i
  while k < line.len and line[k] in {'-', '+', '$', '@', '!', '~'}: inc k     # (a prefix operator of its own)
  while k < line.len:
    let c = line[k]
    if c in {'(', '[', '{'}:
      let e = nxMatchClose(line, k)
      if e < 0: return line.len
      k = e + 1
    elif c == '"':
      let q = line.find('"', k + 1)
      if q < 0: return line.len
      k = q + 1
    elif nxIsIdent(c) or (c == '.' and k + 1 < line.len and nxIsIdent(line[k + 1])): inc k
    else: break
  k

proc nxOpFit*(sc: NxScope, s: NxSym, k: int, typ: string): int =
  ## how well a value of type `typ` fits parameter `k` of operator `s`: 3 its type · 2 a subtype ·
  ## 1 a generic or unknown one · 0 not at all
  if k >= s.params.len: return 0
  let want = nxBaseName(nxStripMods(s.params[k].typ))
  if want.len == 0: return 1
  if typ.len == 0: return 1
  let have = nxBaseName(nxStripMods(typ))
  if have.len == 0: return 1
  if nxNorm(want) == nxNorm(have): return 3
  let rw = nxResolveAlias(sc, want)
  let rh = nxResolveAlias(sc, have)
  if rw.len > 0 and nxNorm(rw) == nxNorm(rh): return 3
  var generic = (want.len == 1 and want[0] in {'A'..'Z'}) or want in ["auto", "untyped", "typed", "any"] or
                want.startsWith("Some")
  if not generic and s.generics.len > 0:
    var st: NxLexState
    for (ga, ge) in nxLexRuns(s.generics, st, false):
      if s.generics[ga ..< ge] == want: generic = true
  if generic: return 1
  if nxIsSubtype(sc, have, want): return 2
  if want in NxInts and have in NxInts: return 0
  0

proc nxOpTargets*(f: NxFile, lines: seq[string], line, col: int): seq[NxRef] =
  ## the declaration of the operator written at line:col (`a + b`, `$x`): the overload its operands' types pick
  let text = lines[line]
  let (a, e) = nxOpRunAt(text, col)
  if a >= e: return
  let op = text[a ..< e]
  let own = nxSymAt(f, line, a)
  if own >= 0 and f.syms[own].name == op: return @[NxRef(file: f, idx: int32(own))]
  let sc = nxScope(f)
  var cands: seq[NxRef]
  for r in nxLookup(sc, op):
    if r.sym.kind in NxRoutineKinds and r.sym.name == op: cands.add r
  if cands.len == 0: return
  # binary (a + b, a+b) or prefix ($x, -y: a space before it, none after)
  var i = a
  while i > 0 and text[i - 1] == ' ': dec i
  let spacedBefore = i < a
  let spacedAfter = e >= text.len or text[e] == ' '
  let leftEnd = i > 0 and (nxIsIdent(text[i - 1]) or text[i - 1] in {')', ']', '}', '"', '\''})
  let binary = leftEnd and (not spacedBefore or spacedAfter)
  let locals = nxLocals(f, lines, line, a)
  var lt, rt = ""
  var j = e
  while j < text.len and text[j] == ' ': inc j
  let re = nxOperandFwd(text, j)
  if re > j: rt = nxTypeOfExpr(f, sc, locals, text[j ..< re], line, 0).typ
  if binary:
    let ls = nxOperandBack(text, i)
    if ls >= i: return
    lt = nxTypeOfExpr(f, sc, locals, text[ls ..< i], line, 0).typ
    if lt.len == 0: return            # (cannot tell which overload: none rather than a guess)
  elif rt.len == 0: return
  var best = 0
  for r in cands:
    let np = r.sym.params.len
    var score = 0
    if binary:
      if np != 2: continue
      let x = nxOpFit(sc, r.sym, 0, lt)
      let y = nxOpFit(sc, r.sym, 1, rt)
      if x == 0 or y == 0: continue
      score = x * 4 + y
    else:
      if np != 1: continue
      score = nxOpFit(sc, r.sym, 0, rt) * 4
      if score == 0: continue
    if score > best:
      best = score
      result = @[r]
    elif score == best: result.add r

proc nxCtorField*(sc: NxScope, lines: seq[string], line, a, e: int): seq[NxRef] =
  ## `Foo(x: 1)`, `Foo(\n  x: 1,`: the field x of Foo, when the word at a..e is a field given in an object
  ## constructor (not the variable x that may also be in scope)
  let text = lines[line]
  var k = e
  while k < text.len and text[k] == ' ': inc k
  if k >= text.len or text[k] != ':' or (k + 1 < text.len and text[k + 1] in {':', '='}): return
  # back to the unclosed `(` (this line, then a few above)
  var l = line
  var c = a - 1
  var depth = 0
  var first = true
  while l >= 0 and line - l <= 20:
    let t = lines[l]
    if c >= t.len: c = t.high
    while c >= 0:
      let ch = t[c]
      if first and ch != ' ':
        if ch notin {'(', ','}: return               # (x: int in a proc's parameters is after a word too)
        first = false
      if ch in {')', ']', '}'}: inc depth
      elif ch in {'(', '[', '{'}:
        if depth == 0: break
        dec depth
      elif ch == '"':
        dec c
        while c >= 0 and t[c] != '"': dec c
      dec c
    if c >= 0: break
    dec l
    if l >= 0:
      c = lines[l].high
      let tl = lines[l].strip
      if first and tl.len > 0 and tl[^1] notin {'(', ','}: return
  if l < 0 or c < 0 or lines[l][c] != '(': return
  let t = lines[l]
  var ee = c
  if ee > 0 and t[ee - 1] == ']':                    # Box[int](v: 1)
    var d = 0
    var q = ee - 1
    while q >= 0:
      if t[q] == ']': inc d
      elif t[q] == '[':
        dec d
        if d == 0: break
      dec q
    if q < 0: return
    ee = q
  var aa = ee
  while aa > 0 and nxIsIdent(t[aa - 1]): dec aa
  if aa == ee: return
  let tn = t[aa ..< ee]
  if nxTypeSyms(sc, tn).len == 0: return
  let w = nxNorm(text[a ..< e])
  for r in nxFields(sc, tn):
    if nxNorm(r.sym.name) == w: result.add r

proc nxTypeExprMember*(lines: seq[string], line, a, e: int): NxSym =
  ## the word at a..e as a name declared inside a type written out: a parameter of a proc type (`cb: proc (s:
  ## Stream, bufLen: int)`, `MatchProc = proc (request: Request)`) or a field of a tuple type (`var res: tuple[
  ## consumed: int, done: bool]`) — itself, with the type written for it; else a symbol without a name
  let text = lines[line]
  var k = e
  while k < text.len and text[k] == ' ': inc k
  if k >= text.len or text[k] notin {':', ',', '='} or (k + 1 < text.len and text[k + 1] in {':', '='}): return
  # back to the bracket that is still open (this line, then a few above)
  var l = line
  var c = a - 1
  var depth = 0
  var opener = '\0'
  while l >= 0 and line - l <= 12 and opener == '\0':
    let t = lines[l]
    if c >= t.len: c = t.high
    while c >= 0:
      let ch = t[c]
      if ch in {')', ']'}: inc depth
      elif ch in {'(', '['}:
        if depth == 0:
          opener = ch
          break
        dec depth
      elif ch == '"':
        dec c
        while c >= 0 and t[c] != '"': dec c
      dec c
    if opener != '\0': break
    dec l
    if l >= 0: c = lines[l].high
  if opener == '\0' or l < 0: return
  # what is in front of it: proc / iterator for parameters, tuple for fields
  var b = c
  while b > 0 and lines[l][b - 1] == ' ': dec b
  var w0 = b
  while w0 > 0 and nxIsIdent(lines[l][w0 - 1]): dec w0
  let kw = lines[l][w0 ..< b]
  let isParam = opener == '(' and kw in ["proc", "iterator", "func"]
  if not (isParam or (opener == '[' and kw == "tuple")): return
  # its text up to the closing bracket, and the type of the name there
  var whole = lines[l][c .. ^1]
  var l2 = l
  while nxMatchClose(whole, 0) < 0 and l2 + 1 < lines.len and l2 - l < 20:
    inc l2
    whole.add " " & lines[l2].strip
  let ce = nxMatchClose(whole, 0)
  if ce < 0: return
  let w = lines[line][a ..< e]
  for p in nxParseParams(whole[1 ..< ce]):
    if p.name.strip(chars = {'*', '`'}) == w:
      return NxSym(name: w, kind: (if isParam: nxParam else: nxField), typ: (if p.typ.len > 0: p.typ
                   else: nxLiteralType(p.default)), value: p.default, line: line, col: a)

proc nxTupleFieldOf*(f: NxFile, sc: NxScope, typ, w: string): seq[NxRef] =
  ## a field of an anonymous tuple a routine returns (splitFile(p).name: `tuple[dir, name, ext: string]`):
  ## where that routine writes it
  for r in sc.refs:
    template s: untyped = r.sym
    if s.kind notin NxRoutineKinds or s.ret.len == 0 or nxStripMods(s.ret) != typ: continue
    let ls = nxFileLines(r.file.path)
    for p in nxParseParams(typ[6 ..< ^1]):
      if nxNorm(p.name) != nxNorm(w): continue
      var fl = s.line
      var fc = 0
      if ls.len > 0:
        let (pl, pc) = nxLocate(ls, p.name, s.line, min(s.line + 12, ls.high), (s.line, max(0, ls[s.line].find("tuple"))))
        fl = pl
        fc = pc
      let g = NxFile(path: r.file.path, module: r.file.module,
                     syms: @[NxSym(name: p.name, kind: nxField, typ: p.typ, line: fl, col: fc, owner: s.name)])
      return @[NxRef(file: g, idx: 0)]
    return

proc nxHeaderLast*(lines: openArray[string], s: NxSym): (string, int) =
  ## a routine's header as one line (up to its `=` or where it ends) and its last line
  var t = ""
  var bal = 0
  var l = s.line
  while l < lines.len and l - s.line < 16:
    let c = nxCodeOf(lines[l])
    t.add (if t.len > 0: " " else: "") & c
    bal += nxBalance(c)
    if c.endsWith("=") or (bal <= 0 and not (c.endsWith(",") or c.endsWith(":") or c.endsWith("(") or
                                               c.endsWith("{.") or c.len == 0)):
      break
    inc l
  (t, min(l, lines.high))

proc nxIsForward*(lines: openArray[string], s: NxSym): bool =
  ## a routine declared without a body (a forward declaration: its body comes later)
  if s.kind notin NxRoutineKinds or s.made or s.endLine > s.line or s.line >= lines.len: return false
  let (h, _) = nxHeaderLast(lines, s)
  let po = h.find('(')
  let pc = if po >= 0: nxMatchClose(h, po) else: -1
  pc > 0 and nxFindTop(h, '=', pc + 1) < 0

func nxSameSig(a, b: NxSym): bool =
  ## a forward declaration and its routine: the same parameters and result (owned(X) and owned X alike)
  if a.kind != b.kind or a.name != b.name or a.params.len != b.params.len or
     a.generics.replace(" ", "") != b.generics.replace(" ", "") or
     nxStripValMods(a.ret).replace(" ", "") != nxStripValMods(b.ret).replace(" ", ""): return false
  for k in 0 ..< a.params.len:
    if a.params[k].name != b.params[k].name or a.params[k].typ.replace(" ", "") != b.params[k].typ.replace(" ", ""):
      return false
  true

proc nxForwardOf*(f: NxFile, lines: openArray[string], r: NxSym): int =
  ## the forward declaration of a routine with a body: same name, kind and signature, earlier, without one (or -1)
  result = -1
  if r.kind notin NxRoutineKinds or r.made: return
  for j in 0 ..< f.syms.len:
    template s: untyped = f.syms[j]
    if s.line < r.line and s.name == r.name and not s.made and nxSameSig(s, r) and nxIsForward(lines, s): return j

proc nxBodyOf*(f: NxFile, lines: openArray[string], fw: NxSym): int =
  ## the routine a forward declaration declares: the later one with the same name, kind and signature (or -1)
  result = -1
  for j in 0 ..< f.syms.len:
    template s: untyped = f.syms[j]
    if s.line > fw.line and s.name == fw.name and not s.made and nxSameSig(s, fw) and not nxIsForward(lines, s):
      return j

proc nxParamAt(lines: openArray[string], r: NxSym, name: string): NxSym =
  ## a routine's parameter where its header writes it
  var at = (r.line, max(0, lines[r.line].find('(')))
  for p in r.params:
    let nm = p.name.strip(chars = {'`'})
    let (pl, pc) = nxLocate(lines, nm, r.line, min(lines.high, r.line + 15), at)
    at = (pl, pc + nm.len)
    if nxNorm(nm) == nxNorm(name):
      return NxSym(name: nm, kind: nxParam, typ: p.typ, value: p.default, line: pl, col: pc)

func nxInInitializer(lines: openArray[string], declLine, line: int): bool =
  ## is `line` in the value of the let/var declared on `declLine` (`var value =⏎ if c: value …`), where the
  ## name is not declared yet: the lines between are all indented further than the declaration's
  if line <= declLine or line >= lines.len or line - declLine > 60: return false
  let ind = lines[declLine].len - lines[declLine].strip(trailing = false).len
  for l in declLine + 1 .. line:
    let t = lines[l].strip(trailing = false)
    if t.len == 0: continue
    if lines[l].len - t.len <= ind: return false
  true

proc nxLocalRoutine(locals: seq[NxSym], w: string, line: int): seq[NxSym] =
  ## a routine declared inside the one around `line` by that name (it hides the module's)
  for i in countdown(locals.high, 0):
    template s: untyped = locals[i]
    if s.kind in NxRoutineKinds and nxNorm(s.name) == nxNorm(w) and s.line <= line: return @[s]

func nxCmdStart(text: string, a: int): bool =
  ## does a statement start at `a` — a command call can (add s, x): at the line's start, after `discard`, or after
  ## the `:` of a one-line if/elif/else/of/while/for
  let pre = text[0 ..< a].strip
  if pre.len == 0 or pre == "discard": return true
  if not pre.endsWith(":"): return false
  var w = 0
  while w < pre.len and nxIsIdent(pre[w]): inc w
  pre[0 ..< w] in ["if", "elif", "else", "of", "while", "for", "when", "except", "finally", "try"]

proc nxCallArgs(lines: seq[string], line, e: int): (bool, seq[string]) =
  ## the arguments of the call whose name ends at `e` (`name(…)`, `name[T](…)`, over a few lines too): (a call
  ## with brackets, its arguments as written)
  let text = lines[line]
  var k = e
  if k < text.len and text[k] == '[':
    let ge = nxMatchClose(text, k)
    if ge < 0: return
    k = ge + 1
  let a0 = if e > 0: nxWordAt(text, e - 1)[0] else: 0
  if k < text.len and text[k] == ' ' and k == e and k + 1 < text.len and
     (nxDotBefore(text, a0) or nxCmdStart(text, a0)):
    # a command call after a dot: s.addInt i, x.add "a" — its arguments, to the end of the line
    var j = k + 1
    while j < text.len and text[j] == ' ': inc j
    # (result.add $x, s.add (a mod 100).intToStr(2), n.expectKind {a, b}: a prefix operator with nothing between it
    # and its operand, or a bracket, starts an argument too)
    let prefixed = j + 1 < text.len and j == k + 1 and
                   ((text[j] in {'$', '-', '~', '!'} and text[j + 1] notin {' ', '='} + NxOpChars) or
                    text[j] in {'(', '[', '{'})
    if j < text.len and (nxIsIdent(text[j]) or text[j] in {'"', '\'', '@'} or prefixed):
      var w = j
      while w < text.len and nxIsIdent(text[w]): inc w
      if text[j .. w - 1] notin ["and", "or", "in", "notin", "is", "isnot", "of", "div", "mod", "shl", "shr",
                                 "xor", "as", "not"]:
        var rest = text[j .. ^1]
        let hash = nxFindTop(rest, '#')
        if hash >= 0: rest = rest[0 ..< hash]
        rest = rest.strip
        if rest.endsWith(":") or rest.endsWith("="): return       # (a block or an assignment follows: not args)
        result[0] = true
        for a in nxSplitTop(rest, {','}): result[1].add a.strip
        return
  if k >= text.len or text[k] != '(': return
  var s = text[k .. ^1]
  var ce = nxMatchClose(s, 0)
  var j = line + 1
  while ce < 0 and j < lines.len and j <= line + 8:
    s.add " " & lines[j].strip
    ce = nxMatchClose(s, 0)
    inc j
  if ce < 0: return
  result[0] = true
  let inner = s[1 ..< ce].strip
  if inner.len > 0:
    for a in nxSplitTop(inner, {','}): result[1].add a.strip

func nxNamedAt(a: string): int =
  ## a named argument (`trailingSep = false`): where its `=` is, else -1 — not the `=` of `>=`, `<=`, `!=`, `==`
  let eq = nxFindTop(a, '=')
  if eq > 0 and (eq + 1 >= a.len or a[eq + 1] != '=') and a[eq - 1] notin {'<', '>', '!', '=', '.', '+', '-', '*', '/'} and
     a[0 ..< eq].strip.len > 0 and a[0 ..< eq].strip.allCharsInSet(IdentChars + {'`'}):
    return eq
  -1

proc nxNarrowCall(f: NxFile, sc: NxScope, locals: seq[NxSym], lines: seq[string], line, e: int,
                  cands: seq[NxRef], recv: string): seq[NxRef] =
  ## of several overloads, the ones that take the call's arguments best — their number (defaults and varargs
  ## counted), each one's type where it is known, named ones by name, the receiver of a method call — as the
  ## compiler picks (an exact type before a conversion, before a generic). All of them when nothing tells them apart
  result = cands
  if cands.len < 2: return
  let (isCall, args) = nxCallArgs(lines, line, e)
  if not isCall and recv.len == 0: return
  let off = if recv.len > 0: 1 else: 0
  var argT = newSeq[string](args.len)
  var known = newSeq[bool](args.len)
  var best: seq[NxRef]
  var bestScore = -1
  var arity: seq[NxRef]                # (the routines that take this many arguments, whatever their types)
  for r in cands:
    let s = r.sym
    if s.kind notin NxRoutineKinds: continue
    if isCall and not nxArgsFit(s, args.len + off): continue
    if isCall and recv.len == 0:
      var named = false
      for a in args:
        if nxNamedAt(a) > 0: named = true
      if not named: arity.add r
    var score = 1
    if recv.len > 0:
      if s.params.len == 0: continue
      let c = nxCompatP(sc, s.params[0], s.generics, recv)
      if c == 0: continue
      score += c
    var ok = true
    for j, a in args:
      let eq = nxNamedAt(a)
      if eq > 0:
        # a named argument: the routine has a parameter by that name
        let nm = a[0 ..< eq].strip
        var has = false
        for p in s.params:
          if nxNorm(p.name) == nxNorm(nm): has = true
        if not has:
          ok = false
          break
        continue
      var pi = j + off
      if pi >= s.params.len:
        if s.params.len > 0 and s.params[^1].typ.startsWith("varargs"): pi = s.params.high
        else:
          ok = false
          break
      let lit = nxLiteralType(a)
      if lit in ["int", "float"]:
        # (a number literal goes into any number type)
        let pb = nxResolveAlias(sc, nxBaseName(nxStripMods(s.params[pi].typ)))
        if pb in NxInts or pb in NxFloats or pb in ["Natural", "Positive", "SomeNumber", "SomeInteger",
                                                     "SomeFloat", "SomeOrdinal", "Ordinal"]:
          score += (if (lit == "int") == (pb in NxInts or pb in ["Natural", "Positive"]): 3 else: 2)
          continue
      if a == "nil": continue
      if not known[j]:
        known[j] = true
        let v = nxTypeOfExpr(f, sc, locals, a, line, 1)
        argT[j] = v.typ
        # (a type passed: high(int64) is the typedesc overload, not the one of an openArray)
        if v.typ.len == 0 and v.typeName.len > 0: argT[j] = "typedesc[" & v.typeName & "]"
      let at = argT[j]
      if at.len == 0 or (at.len <= 2 and at[0] in {'A'..'Z'}): continue     # (unknown, or a generic T)
      var prm = s.params[pi]
      if prm.typ.len == 0 and prm.default.len > 0 and nxLiteralType(prm.default).len == 0:
        # (sep = DirSep, val = Future[void].default: the type of the default, where the routine is declared)
        prm.typ = nxTypeOfExpr(r.file, nxScope(r.file), @[], prm.default, s.line, 2).typ
        if prm.typ.len == 0: continue
      let c = nxCompatP(sc, prm, s.generics, at)
      if c == 0:
        ok = false
        break
      score += c
    if not ok: continue
    if score > bestScore:
      best = @[r]
      bestScore = score
    elif score == bestScore: best.add r
  if best.len > 0: result = best
  elif arity.len > 0 and arity.len < cands.len:
    # (no overload takes these types as ned reads them — a range of an enum, a converter —: the ones that take
    # this many arguments are still the only ones the call can be; the others (and types: a conversion takes one)
    # cannot)
    var conv = false
    for r in cands:
      if r.sym.kind notin NxRoutineKinds and args.len == 1: conv = true
    let code = nxCodeOf(lines[line])
    # (a block after the call — foo(x):⏎ body, foo(x) do: — is one more argument)
    if not conv and not code.endsWith(":") and " do" notin code: result = arity

const NxBuiltinPragmas = ["varargs", "error", "warning", "hint", "pop", "push", "size", "header", "line", "align",
                          "emit", "compile", "link", "global", "base", "final", "pure", "union", "packed", "thread",
                          "noinit", "borrow", "closure", "cursor", "used", "experimental", "inject", "gensym", "dirty",
                          "magic", "raises", "tags", "importc", "exportc", "dynlib", "discardable", "deprecated",
                          "inline", "noSideEffect", "gcsafe", "nimcall", "cdecl", "stdcall", "bycopy", "byref",
                          "threadvar", "compileTime", "noreturn", "importcpp", "importjs", "nodecl", "incompleteStruct",
                          "requiresInit", "acyclic", "inheritable", "shallow", "effectsOf", "rtl", "extern", "benign"]

var nxReorders: Table[string, bool]      # file and stamp → it asks for {.experimental: "codeReordering".}

proc nxDropLater(f: NxFile, lines: seq[string], line: int, rs: var seq[NxRef]) =
  ## of several overloads, those this module declares below `line` are not seen there: Nim reads a module from the
  ## top (convert(Weeks, Seconds, n) above `template convert(d: Duration, …)` is the proc). Not in a template's
  ## or a generic routine's body (bound where it is used), nor a routine a forward declaration above announces,
  ## nor in a module that reorders its code
  if rs.len < 2: return
  var later: seq[int]
  for i, r in rs:
    if r.file.path == f.path and r.sym.line > line and not r.sym.local and not r.sym.made and
       r.sym.kind in NxRoutineKinds + {nxConst, nxLet, nxVar}:
      later.add i
  if later.len == 0 or later.len == rs.len: return
  let ri = nxEnclosing(f, line)
  if ri >= 0 and (f.syms[ri].kind in {nxTemplate, nxMacro} or nxIsGenericRoutine(f.syms[ri])): return
  let rk = f.path & "\t" & f.stamp
  if rk notin nxReorders:
    if nxReorders.len > 200: nxReorders.clear()
    var re = false
    for l in lines:
      if "codeReordering" in l: re = true
    nxReorders[rk] = re
  if nxReorders[rk]: return
  # (runnableExamples are a module of their own that imports this one: all of it)
  var ind = lines[line].len - lines[line].strip(trailing = false).len
  var l = line - 1
  while l >= 0 and ind > 0:
    let t = lines[l].strip(trailing = false)
    if t.len > 0 and t[0] != '#' and lines[l].len - t.len < ind:
      if t.startsWith("runnableExamples"): return
      ind = lines[l].len - t.len
    dec l
  for i in countdown(later.high, 0):
    let fw = nxForwardOf(f, lines, rs[later[i]].sym)
    if fw >= 0 and f.syms[fw].line < line: continue
    rs.delete(later[i])

proc nxTargets*(f: NxFile, lines: seq[string], line, col: int): (seq[NxRef], seq[NxSym], string) =
  ## the declarations the word at line:col refers to: (index symbols, locals, module path)
  let f = nxAt(f, lines, line)
  let sc = nxScope(f)
  let text = lines[line]
  let (a, e) = nxWordAt(text, col)
  if a >= e:
    if col < text.len and text[col] in NxOpChars: return (nxOpTargets(f, lines, line, col), @[], "")
    return
  let w = text[a ..< e]
  # a symbol named inside defined(…) / declared(…): what it means is that magic's (a define, not a declaration)
  for magic in ["defined", "declared"]:
    let pre = text[0 ..< a].strip(leading = false)
    if pre.endsWith(magic & "(") and w != magic:
      for r in nxLookup(sc, magic):
        if r.sym.kind in NxRoutineKinds: result[0].add r
      if result[0].len > 0: return
  # on an import line: the module
  let tl = text.strip
  var prevOpen = false              # (the line goes on an import from the line above: `std/[a,⏎ b]`)
  if line > 0:
    let pl = lines[line - 1].strip
    prevOpen = pl.endsWith(",") or pl.endsWith("[") or pl.endsWith("import")
  if tl.startsWith("import ") or tl.startsWith("from ") or tl.startsWith("include ") or prevOpen:
    for im in f.imports:
      if im.line == line or (im.line < line and line - im.line < 20):
        if nxModuleName(im.spec) == w or im.spec.endsWith("/" & w):
          let p = nxResolve(f.path, im.spec)
          if p.len > 0: return (@[], @[], p)
    # a name of `from m import a, b` (or of `import m except a`): m's own, not one of this module's that has it too
    var best = -1
    for k, im in f.imports:
      if im.line <= line and line - im.line < 20 and (best < 0 or im.line > f.imports[best].line): best = k
    if best >= 0:
      let im = f.imports[best]
      var named = false
      for x in im.only & im.excepts:
        if nxNorm(x.strip(chars = {'`', ' '})) == nxNorm(w): named = true
      if named:
        let p = nxResolve(f.path, im.spec)
        if p.len > 0:
          var got: seq[NxRef]
          var seen: HashSet[string]
          nxExports(p, 0, seen, got)
          for r in got:
            if nxNorm(r.sym.name) == nxNorm(w): result[0].add r
          if result[0].len > 0: return
  block pragma:
    # {.importc, varargs.}: a pragma the compiler knows, not the type varargs (nor macros' error, seq's pop …)
    if w notin NxBuiltinPragmas: break pragma
    let open = text.rfind("{.", last = a)
    var above = false
    if open < 0:
      # (a pragma list that starts on a line above: {.header: "<stdio.h>",⏎ importc: "snprintf", varargs.})
      var l2 = line - 1
      while l2 >= 0 and line - l2 <= 3 and not above:
        let t2 = nxCodeOf(lines[l2])
        let o2 = t2.rfind("{.")
        if o2 >= 0 and t2.rfind(".}") < o2: above = true
        elif not t2.endsWith(","): break
        dec l2
      if not above: break pragma
    elif text.rfind(".}", last = a) > open: break pragma
    var q = a - 1
    while q >= 0 and text[q] == ' ': dec q
    var r = e
    while r < text.len and text[r] == ' ': inc r
    if ((q >= 1 and (text[q] == ',' or (text[q] == '.' and text[q - 1] == '{'))) or (q < 0 and above)) and
       (r >= text.len or text[r] in {',', ':', '.'}):
      return
  let own = nxSymAt(f, line, a)
  if own >= 0 and nxNorm(f.syms[own].name) == nxNorm(w):
    if nxIsForward(lines, f.syms[own]):
      let b = nxBodyOf(f, lines, f.syms[own])                    # a forward declaration's name: the routine it declares
      if b >= 0: return (@[NxRef(file: f, idx: int32(b))], @[], "")
    return (@[NxRef(file: f, idx: int32(own))], @[], "")       # a declaration's own name: itself (this overload, this field)
  block made:
    # a parameter of a routine a template call on this line makes (zipImpl(s1, s2, …) makes zip(s1, s2)): itself
    if own < 0 and line in f.byLine:
      for i in f.byLine[line]:
        let s = f.syms[i]
        if not s.made or s.kind notin NxRoutineKinds: continue
        for p in s.params:
          if nxNorm(p.name) == nxNorm(w):
            return (@[], @[NxSym(name: w, kind: nxParam, typ: p.typ, value: p.default, line: line, col: a)], "")
  block fwdHeader:
    # a parameter on a later line of a forward declaration's header: itself
    for s in f.syms:
      if s.line < line and line <= s.line + 15 and s.endLine == s.line and s.kind in NxRoutineKinds and not s.made:
        if nxHeaderLast(lines, s)[1] >= line:
          let p = nxParamAt(lines, s, w)
          if p.name.len > 0 and p.line == line and p.col == a: return (@[], @[p], "")
  if e < text.len and (text[e] == ':' or text[e] == ' '):
    let cf = nxCtorField(sc, lines, line, a, e)
    if cf.len > 0: return (cf, @[], "")
  if e < text.len and text[e] == ':' and not (e + 1 < text.len and text[e + 1] == ':'):
    # a named argument — formatErrorIndexBound(i, len: s.len) —: the call's parameter, not a routine or a
    # variable that has the name too (a routine's header is not a call: its parameters are declared there)
    var q = a - 1
    while q >= 0 and text[q] == ' ': dec q
    if q >= 0 and text[q] in {'(', ','}:
      var d = 0
      var k = q
      var opener = -1
      while k >= 0:
        let ch = text[k]
        if ch in {')', ']', '}'}: inc d
        elif ch in {'(', '[', '{'}:
          if d == 0:
            opener = k
            break
          dec d
        dec k
      let tl = text.strip
      var header = false
      for kw in ["proc ", "func ", "method ", "iterator ", "template ", "macro ", "converter "]:
        if tl.startsWith(kw) or tl.startsWith("of " & kw): header = true
      if not header:
        # (a header over several lines: its later lines declare parameters too)
        let ri = nxEnclosing(f, line)
        if ri >= 0 and f.syms[ri].kind in NxRoutineKinds and line <= nxHeaderLast(lines, f.syms[ri])[1]: header = true
      if opener > 0 and text[opener] == '(' and nxIsIdent(text[opener - 1]) and not header and
         "proc (" notin text[0 ..< opener] and "proc(" notin text[0 ..< opener]:
        return (@[], @[], "")
      if opener >= 0 and text[opener] == '(' and not header and
         (opener == 0 or text[opener - 1] notin IdentChars + {']', ')', '`', '.', '\x80'..'\xFF'}):
        # $(slice: s, len: n), return (a: 1, b: 2): a label of the tuple it makes, not the `len` in scope
        var w0 = opener
        while w0 > 0 and text[w0 - 1] == ' ': dec w0
        var w1 = w0
        while w1 > 0 and nxIsIdent(text[w1 - 1]): dec w1
        if text[w1 ..< w0] notin ["proc", "func", "iterator", "method", "converter", "template", "macro"]:
          return (@[], @[], "")
  block typeExpr:
    # a parameter of a proc type, a field of a tuple type: itself
    let m = nxTypeExprMember(lines, line, a, e)
    if m.name.len > 0: return (@[], @[m], "")
  let locals = nxLocals(f, lines, line, e)
  if nxDotBefore(text, a):
    let recv = nxReceiver(text, a - 1)
    let v = nxTypeOfExpr(f, sc, locals, recv, line, 0)
    if v.module.len > 0:
      var got: seq[NxRef]
      var seen: HashSet[string]
      nxExports(v.module, 0, seen, got)
      for r in got:
        if nxNorm(r.sym.name) == nxNorm(w): result[0].add r
      return
    if v.typeName.len > 0:
      for r in nxLookup(sc, w):
        if r.sym.kind == nxEnumVal and r.sym.owner == v.typeName: result[0].add r
      if result[0].len > 0: return
    # a routine declared inside this one (shape.addQuadratic(…) calling a nested proc): it hides the module's
    # (nxLocalRoutine — not a closure here: one holding `locals` was never freed, a list of locals at every call)
    # (a type in front: int.high, Color.low — the routine takes the type, a typedesc)
    let vTyp = if v.typ.len == 0 and v.typeName.len > 0: "typedesc[" & v.typeName & "]" else: v.typ
    if vTyp.len > 0:
      let vt = nxConstrained(f, line, vTyp)
      for fr in nxFields(sc, vt):
        if nxNorm(fr.sym.name) == nxNorm(w) and nxVisible(f, fr): return (@[fr], @[], "")
      if nxStripMods(vt).startsWith("tuple["):
        let tf = nxTupleFieldOf(f, sc, nxStripMods(vt), w)
        if tf.len > 0: return (tf, @[], "")
      let lr = nxLocalRoutine(locals, w, line)
      if lr.len > 0: return (@[], lr, "")
      var best: seq[NxRef]
      var bestScore = 0
      var cands: seq[NxRef]
      for r in nxLookup(sc, w):
        if r.sym.kind in NxRoutineKinds and r.sym.params.len > 0: cands.add r
      nxDropLater(f, lines, line, cands)
      for r in cands:
        let c = nxCompatP(sc, r.sym.params[0], r.sym.generics, vt)
        if c > bestScore:
          best = @[r]
          bestScore = c
        elif c == bestScore and c > 0: best.add r
      if best.len > 1: best = nxNarrowCall(f, sc, locals, lines, line, e, best, vt)
      if best.len > 0: return (best, @[], "")
    # unknown receiver: any routine of that name
    let lr = nxLocalRoutine(locals, w, line)
    if lr.len > 0: return (@[], lr, "")
    for r in nxLookup(sc, w):
      if r.sym.kind in NxRoutineKinds or r.sym.kind == nxField: result[0].add r
    nxDropLater(f, lines, line, result[0])
    if result[0].len == 0:
      for r in nxLookup(sc, w):
        if r.sym.kind == nxType: result[0].add r          # x.float: a conversion
    return
  # `x` in quote do: the macro's own x (the NimNode), not one the quoted code declares
  let quoted = a > 0 and text[a - 1] == '`' and e < text.len and text[e] == '`' and nxQuoteStart(lines, line) >= 0
  for i in countdown(locals.high, 0):
    let s = locals[i]
    if quoted and nxQuoteStart(lines, s.line) >= 0 and
       not (s.line == line and s.col == a and s.kind notin NxRoutineKinds): continue   # (its own declaration: itself)
    # `var node = node`: a local is only visible after its own declaration (its name counts as itself)
    if nxNorm(s.name) == nxNorm(w) and (s.line < line or (s.line == line and a <= s.col + s.name.len) or
                                        (s.kind in {nxParam, nxResult} and s.line == line) or
                                        (s.kind == nxForVar and s.endLine > 0 and a > s.endLine) or
                                        (s.kind in {nxLet, nxVar} and s.endLine > 0 and s.line == line and
                                         a > s.endLine)) and
       not (s.kind in {nxLet, nxVar, nxConst} and s.endLine <= 0 and s.line < line and
            nxInInitializer(lines, s.line, line)):
      var s2 = locals[i]
      if s2.kind == nxParam and s2.ret.len > 0 and s2.line == line and s2.col == a and '|' notin s2.ret:
        # (a macro's parameter where it is declared: the type written there — a {.multisync.} one stays the
        # synchronous one, as everywhere in its body)
        s2.typ = s2.ret
      if s2.kind == nxParam and not (s2.line == line and s2.col == a):
        # a parameter of a routine declared before (forward), used in its body: the one its forward declaration
        # writes (as the compiler binds it; where it is written in this header, itself)
        let ri = nxEnclosing(f, line)
        if ri >= 0 and s2.line >= f.syms[ri].line and s2.line <= nxHeaderLast(lines, f.syms[ri])[1]:
          let fw = nxForwardOf(f, lines, f.syms[ri])
          if fw >= 0:
            let p = nxParamAt(lines, f.syms[fw], s2.name)
            if p.name.len > 0:
              s2.line = p.line
              s2.col = p.col
      return (@[], @[s2], "")
  # a module name, unless a declaration has the same name (std/private/since and its `since` template)
  let qualified = e < text.len and text[e] == '.'
  if w in sc.modules and qualified: return (@[], @[], sc.modules[w])
  result[0] = nxLookup(sc, w)
  # a bare name is not a field (fields are reached with a dot), unless nothing else has that name
  var nonField: seq[NxRef]
  for r in result[0]:
    if r.sym.kind != nxField: nonField.add r
  if nonField.len > 0: result[0] = nonField
  block own:
    # (a type, const, var or let of this module hides an imported one of that name: times' own Time, not posix's)
    var mine = false
    for r in result[0]:
      if r.file.path == f.path and r.sym.kind in {nxType, nxConst, nxLet, nxVar} and not r.sym.local: mine = true
    if mine:
      var keep: seq[NxRef]
      for r in result[0]:
        if r.file.path == f.path or r.sym.kind notin {nxType, nxConst, nxLet, nxVar}: keep.add r
      result[0] = keep
  nxDropLater(f, lines, line, result[0])
  if result[0].len == 0 and w in sc.modules: return (@[], @[], sc.modules[w])
  if result[0].len == 0:
    # in a template: a name its body does not declare is the one where it is called (not a named argument)
    var k = e
    while k < text.len and text[k] == ' ': inc k
    if not (k + 1 < text.len and text[k] == '=' and text[k + 1] != '='):
      let s = nxTemplateFree(f, lines, w, line)
      if s.name.len > 0: return (@[], @[s], "")
  if result[0].len > 1:
    # a call: its arguments pick among overloads — parseJson("{}") is the string one, setLen(s, 0) the string's or
    # the seq's by what s is
    var k = e
    while k < text.len and text[k] == ' ': inc k
    if k < text.len and text[k] in {'(', '['}:          # (hasKey[A, B](t, key): its explicit generics skipped)
      result[0] = nxNarrowCall(f, sc, locals, lines, line, k, result[0], "")
    elif k > e and k < text.len and nxCmdStart(text, a):
      result[0] = nxNarrowCall(f, sc, locals, lines, line, e, result[0], "")    # add result, x: a command call
  # own declarations first, then imports, then system
  result[0].sort(proc(x, y: NxRef): int = cmp(nxRank(f, x), nxRank(f, y)))
