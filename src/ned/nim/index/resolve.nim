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

proc nxLocalRoutine(locals: seq[NxSym], w: string, line: int): seq[NxSym] =
  ## a routine declared inside the one around `line` by that name (it hides the module's)
  for i in countdown(locals.high, 0):
    template s: untyped = locals[i]
    if s.kind in NxRoutineKinds and nxNorm(s.name) == nxNorm(w) and s.line <= line: return @[s]

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
  block typeExpr:
    # a parameter of a proc type, a field of a tuple type: itself
    let m = nxTypeExprMember(lines, line, a, e)
    if m.name.len > 0: return (@[], @[m], "")
  let locals = nxLocals(f, lines, line, e)
  if a > 0 and text[a - 1] == '.':
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
    if v.typ.len > 0:
      let vt = nxConstrained(f, line, v.typ)
      for fr in nxFields(sc, vt):
        if nxNorm(fr.sym.name) == nxNorm(w) and nxVisible(f, fr): return (@[fr], @[], "")
      if nxStripMods(vt).startsWith("tuple["):
        let tf = nxTupleFieldOf(f, sc, nxStripMods(vt), w)
        if tf.len > 0: return (tf, @[], "")
      let lr = nxLocalRoutine(locals, w, line)
      if lr.len > 0: return (@[], lr, "")
      var best: seq[NxRef]
      var bestScore = 0
      for r in nxLookup(sc, w):
        if r.sym.kind notin NxRoutineKinds or r.sym.params.len == 0: continue
        let c = nxCompatP(sc, r.sym.params[0], r.sym.generics, vt)
        if c > bestScore:
          best = @[r]
          bestScore = c
        elif c == bestScore and c > 0: best.add r
      if best.len > 0: return (best, @[], "")
    # unknown receiver: any routine of that name
    let lr = nxLocalRoutine(locals, w, line)
    if lr.len > 0: return (@[], lr, "")
    for r in nxLookup(sc, w):
      if r.sym.kind in NxRoutineKinds or r.sym.kind == nxField: result[0].add r
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
                                        (s.kind == nxForVar and s.endLine > 0 and a > s.endLine)):
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
  if result[0].len == 0 and w in sc.modules: return (@[], @[], sc.modules[w])
  if result[0].len == 0:
    # in a template: a name its body does not declare is the one where it is called (not a named argument)
    var k = e
    while k < text.len and text[k] == ' ': inc k
    if not (k + 1 < text.len and text[k] == '=' and text[k + 1] != '='):
      let s = nxTemplateFree(f, lines, w, line)
      if s.name.len > 0: return (@[], @[s], "")
  if result[0].len > 1:
    # a call: its first argument picks among overloads  parseJson("{}") → the string one
    var k = e
    while k < text.len and text[k] == ' ': inc k
    if k < text.len and text[k] == '(':
      let ce = nxMatchClose(text, k)
      let args = if ce > k: text[k + 1 ..< ce] else: text[k + 1 .. ^1]
      let first = nxSplitTop(args, {','})[0].strip
      if first.len > 0 and nxFindTop(first, '=') < 0:
        let at = nxTypeOfExpr(f, sc, locals, first, line, 0).typ
        if at.len > 0:
          var best: seq[NxRef]
          var bestScore = 0
          for r in result[0]:
            if r.sym.kind notin NxRoutineKinds or r.sym.params.len == 0: continue
            let c = nxCompatP(sc, r.sym.params[0], r.sym.generics, at)
            if c > bestScore:
              best = @[r]
              bestScore = c
            elif c == bestScore and c > 0: best.add r
          if best.len > 0: result[0] = best
  # own declarations first, then imports, then system
  result[0].sort(proc(x, y: NxRef): int = cmp(nxRank(f, x), nxRank(f, y)))
