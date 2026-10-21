# ── concepts: which types satisfy one. The new syntax (Nim 2: `concept` with routines on `Self`) as the compiler
#    matches it — for each routine it asks for, one of that name in scope whose parameters and result match with Self
#    the type; the old one (`concept x, y` with expressions about x) in its common forms: `x.f is T`, `f(x)`,
#    `x < y is bool`, `x.field`. Three answers: yes, no, cannot tell — a type is said to satisfy a concept only on a
#    yes ──

type
  NxSat* = enum nsNo, nsUnsure, nsYes      ## (ordered: all of → the least, any of → the most)

  NxCpReq = object                         # (new syntax) one routine the concept asks for
    kind: NxKind
    name: string
    params: seq[string]                    # their types, as written (with Self)
    ret: string

  NxConcept* = object
    known*: bool                           # the engine can read it
    why*: string                           # (not known) what it cannot read
    name*: string
    newStyle*: bool
    gens: seq[string]                      # its own generic parameters (C[T] = concept …)
    reqs: seq[NxCpReq]                     # (new syntax)
    vars: seq[string]                      # (old syntax) the values that stand for the type: concept x, y
    varMut: bool                           #   concept var x
    stmts: seq[string]                     #   its statements
    file: NxFile

  NxCpEnv = object                         # a type being tried against a concept
    sc: NxScope                            # where routines are looked up
    self: string                           # the type
    vars: seq[string]
    varMut: bool
    gens: seq[string]
    binds: Table[string, string]           # the concept's generic parameters, bound by a match
    steps: int

const NxCpOpChars = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '|', '=', '%', '&', '$', '@', '~'}

proc nxCpAll(a, b: NxSat): NxSat = min(a, b)
proc nxCpAny(a, b: NxSat): NxSat = max(a, b)

func nxIsConcept*(s: NxSym): bool =
  s.kind == nxType and (s.typ == "concept" or s.typ.startsWith("concept ") or s.typ.startsWith("concept\t"))

proc nxConceptOf*(r: NxRef): NxConcept =
  ## a concept's requirements, read from its declaration
  template s: untyped = r.sym
  result.name = s.name
  result.file = r.file
  if not nxIsConcept(s): return NxConcept(why: "not a concept")
  result.gens = nxGenericNames(s.generics)
  let lines = nxLayLinesRef(r.file.path).lines
  if s.line >= lines.len: return NxConcept(why: "not read")
  let head = s.typ[7 .. ^1].strip
  result.newStyle = head.len == 0
  # its body: the lines below its header, indented more than it
  let hl = lines[s.line]
  let ind = hl.len - hl.strip(trailing = false).len
  var body: seq[string]
  var l = s.line + 1
  var joined = ""
  var depth = 0
  while l < lines.len:
    let raw = lines[l]
    let t = nxCodeOf(raw).strip
    if t.len > 0 and raw.len - raw.strip(trailing = false).len <= ind and depth == 0: break
    if t.len > 0:
      joined.add (if joined.len > 0: " " else: "") & t
      for ch in t:
        if ch in {'(', '['}: inc depth
        elif ch in {')', ']'}: dec depth
      if depth <= 0 and not t.endsWith(",") and not t.endsWith(":"):
        body.add joined
        joined = ""
        depth = 0
    inc l
  if joined.len > 0: body.add joined
  if result.newStyle:
    for t in body:
      let (kw, ke) = nxName(t, 0)
      var k: NxKind
      case kw
      of "proc": k = nxProc
      of "func": k = nxFunc
      of "iterator": k = nxIterator
      of "template": k = nxTemplate
      of "macro": k = nxMacro
      of "converter": k = nxConverter
      of "method": k = nxMethod
      else: return NxConcept(why: "a statement it cannot read: " & t, name: s.name)
      let (nm, ne) = nxName(t, ke)
      if nm.len == 0: return NxConcept(why: "a routine it cannot read: " & t, name: s.name)
      var req = NxCpReq(kind: k, name: nm)
      var q = ne
      while q < t.len and t[q] == ' ': inc q
      if q < t.len and t[q] == '[': return NxConcept(why: "a generic routine: " & t, name: s.name)
      if q < t.len and t[q] == '(':
        let pc = nxMatchClose(t, q)
        if pc < 0: return NxConcept(why: "a routine it cannot read: " & t, name: s.name)
        for p in nxParseParams(t[q + 1 ..< pc]):
          if p.typ.len == 0: return NxConcept(why: "a parameter without a type: " & t, name: s.name)
          req.params.add p.typ
        q = pc + 1
      var rest = t[q .. ^1].strip
      let pg = rest.find("{.")
      if pg >= 0: rest = rest[0 ..< pg].strip
      if rest.startsWith(":"): req.ret = rest[1 .. ^1].strip
      elif rest.len > 0: return NxConcept(why: "a routine it cannot read: " & t, name: s.name)
      result.reqs.add req
  else:
    for v0 in nxSplitTop(head, {','}):
      var v = v0.strip
      if v.startsWith("var "):
        result.varMut = true
        v = v[4 .. ^1].strip
      if v.len == 0 or not v.allCharsInSet(IdentChars) or v.startsWith("type") or ' ' in v:
        return NxConcept(why: "a concept parameter it cannot read: " & v0.strip, name: s.name)
      result.vars.add v
    result.stmts = body
  result.known = true

proc nxCpKindOf(sc: NxScope, t: string): string =
  ## what a type is: "object", "ref", "enum", "distinct", "tuple", "ptr", a builtin's own name … "" not known
  let x = nxStripValMods(t).strip
  if x in ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float",
           "float32", "float64", "bool", "char", "string", "cstring", "pointer"]: return x
  if x.startsWith("seq["): return "seq"
  if x.startsWith("array["): return "array"
  if x.startsWith("set["): return "set"
  if x.startsWith("tuple[") or x.startsWith("("): return "tuple"
  if x.startsWith("ref "): return "ref"
  if x.startsWith("ptr "): return "ptr"
  if not x.allCharsInSet(IdentChars + {'.'}): return ""
  let refs = nxTypeSyms(sc, x)
  if refs.len != 1 or refs[0].sym.generics.len > 0: return ""
  let d = refs[0].sym.typ.strip
  if d.startsWith("object") or d.startsWith("tuple"): return (if d.startsWith("tuple"): "tuple" else: "object")
  if d.startsWith("ref object") or d.startsWith("ref "): return "ref"
  if d.startsWith("ptr "): return "ptr"
  if d.startsWith("enum"): return "enum"
  if d.startsWith("distinct "): return "distinct"
  if d.startsWith("concept"): return "concept"
  if d.len > 0 and d.allCharsInSet(IdentChars + {'.'}) and d != x: return nxCpKindOf(sc, d)     # (an alias)
  ""

proc nxCpSame(sc: NxScope, a, b: string): bool =
  let x = nxStripValMods(a).strip
  let y = nxStripValMods(b).strip
  if x.len == 0 or y.len == 0: return false
  for m in ["ref ", "ptr ", "static[", "typedesc["]:
    if x.startsWith(m) != y.startsWith(m): return false            # (nxRsSame looks through them)
  nxRsSame(x, y) or (x.allCharsInSet(IdentChars) and y.allCharsInSet(IdentChars) and
                     nxNorm(nxResolveAlias(sc, x)) == nxNorm(nxResolveAlias(sc, y)))

proc nxCpConstraint(sc: NxScope, cons, t: string): NxSat =
  ## does type `t` fit a generic parameter's constraint (`SomeInteger`, `object`, `A | B` …)
  if cons.strip.len == 0: return nsYes
  result = nsNo
  let k = nxCpKindOf(sc, t)
  for alt0 in nxAlternatives(cons):
    let alt = alt0.strip
    var r = nsUnsure
    var cls = false
    for (c, members) in NxTypeClasses:
      if alt == c:
        cls = true
        r = (if t.strip in members.split(' ') or nxResolveAlias(sc, t.strip) in members.split(' '): nsYes
             elif c in ["SomeOrdinal", "Ordinal"] and k == "enum": nsYes
             elif k.len > 0: nsNo else: nsUnsure)
    if not cls:
      case alt
      of "object": r = (if k == "object": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "tuple": r = (if k == "tuple": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "enum": r = (if k == "enum": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "ref": r = (if k == "ref": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "ptr": r = (if k == "ptr": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "distinct": r = (if k == "distinct": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "seq": r = (if k == "seq": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "array": r = (if k == "array": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "set": r = (if k == "set": nsYes elif k.len > 0: nsNo else: nsUnsure)
      of "string", "int", "float", "bool", "char", "cstring", "pointer", "int8", "int16", "int32", "int64", "uint",
         "uint8", "uint16", "uint32", "uint64", "float32", "float64":
        r = (if nxCpSame(sc, alt, t): nsYes elif k.len > 0: nsNo else: nsUnsure)
      else:
        if nxCpSame(sc, alt, t): r = nsYes
        elif nxCpKindOf(sc, alt) in ["object", "enum", "distinct", "ref"] and k.len > 0 and
             not nxIsSubtype(sc, t, alt): r = nsNo
    result = nxCpAny(result, r)

proc nxCpGenerics(r: NxRef): seq[(string, string)] =
  ## a routine's generic parameters and their constraints: [T: SomeInteger, U] → (T, SomeInteger), (U, "")
  for p in nxParseParams(r.sym.generics.strip(chars = {'[', ']', ' '})):
    if p.name.len > 0: result.add (p.name.strip, p.typ.strip)

func nxCpMods(t: string): string =
  ## the modifier a type is written with: "var", "sink", "lent", "out" — "" none
  let x = t.strip
  for m in ["var ", "sink ", "lent2 ", "lent ", "out ", "owned "]:
    if x.startsWith(m): return m.strip
  ""

proc nxCpTypeMatch(env: var NxCpEnv, cand: NxRef, f, a: string, structural: bool, isSelf = false): NxSat =
  ## does a candidate routine's parameter of type `a` take the type `f` (what the concept asks, Self replaced —
  ## `isSelf`: it was Self itself): the compiler's concept match (`structural`: the same type, or one derived from it,
  ## a generic parameter that takes it) or an overload's (a call written in an old concept: numbers convert too)
  inc env.steps
  var fv = f.strip
  var av = a.strip
  let fm = nxCpMods(fv)
  let am = nxCpMods(av)
  if am == "var" and fm != "var": return nsUnsure   # (a var parameter: a value cannot go there; the compiler …)
  if fm != am and structural:
    if fm.len > 0 and not isSelf: return nsUnsure
    if am.len > 0 and not isSelf:
      # (lent T, sink T against a type without it: the compiler binds no generic parameter through it)
      let inner = nxStripValMods(av)
      for (n, _) in nxCpGenerics(cand):
        if inner == n: return nsNo
  fv = nxStripValMods(fv)
  av = nxStripValMods(av)
  if fv.len == 0 or av.len == 0: return nsUnsure
  # (the concept's own generic parameters: bound by the first match, then held to it)
  if fv in env.gens:
    if fv in env.binds: fv = env.binds[fv]
    else:
      env.binds[fv] = av
      return nsYes
  if av in ["untyped", "typed"]: return (if structural: nsNo else: nsYes)
  if av in ["auto", "any"]: return nsYes
  let gens = nxCpGenerics(cand)
  var names: seq[string]
  for (n, _) in gens: names.add n
  for (n, cons) in gens:
    if av == n: return nxCpConstraint(env.sc, cons, fv)
  if names.len > 0 and nxRsHasWord(av, names):
    var b: Table[string, string]
    nxUnify(av, fv, names, b)
    let sub = nxSubst(av, b)
    if nxRsHasWord(sub, names): return nsUnsure
    for (n, cons) in gens:
      if n in b and nxCpConstraint(env.sc, cons, b[n]) != nsYes: return nsUnsure
    if nxCpSame(env.sc, sub, fv): return nsYes
    if nxBaseName(sub) != nxBaseName(fv) and nxCpKindOf(env.sc, fv).len > 0 and nxCpKindOf(env.sc, sub).len > 0:
      return nsNo
    return nsUnsure
  # a type class or a union written as the parameter
  var isClass = '|' in av or " or " in av
  for (c, _) in NxTypeClasses:
    if av == c: isClass = true
  if isClass or av in ["object", "tuple", "enum", "ref", "ptr", "distinct"]: return nxCpConstraint(env.sc, av, fv)
  if nxCpSame(env.sc, av, fv): return nsYes
  if nxIsSubtype(env.sc, fv, av): return nsYes        # (an object derived from the parameter's)
  let kf = nxCpKindOf(env.sc, fv)
  let ka = nxCpKindOf(env.sc, av)
  if kf == "concept" or ka == "concept" or kf.len == 0 or ka.len == 0: return nsUnsure
  if not structural:
    # (a call: an int goes where an int64 or a float is wanted, a string to openArray[char] …)
    if (kf in NxInts or kf in NxFloats) and (ka in NxInts or ka in NxFloats): return nsUnsure
  if av.startsWith("openArray[") or av.startsWith("varargs["): return (if structural: nsNo else: nsUnsure)
  if kf in ["seq", "array", "set", "tuple"] and kf == ka: return nsUnsure       # (their elements: not compared)
  nsNo

proc nxCpReqMatch(env: var NxCpEnv, req: NxCpReq): NxSat =
  ## (new syntax) a routine of that name in scope whose parameters and result match, Self being the type
  result = nsNo
  let selfB = {"Self": env.self}.toTable
  for cand in nxLookup(env.sc, req.name):
    let cs = cand.sym
    if cs.kind notin NxRoutineKinds or cs.name != req.name: continue
    case req.kind
    of nxProc, nxFunc:
      if cs.kind notin {nxProc, nxFunc, nxTemplate, nxMacro, nxMethod, nxConverter}: continue
    else:
      if cs.kind != req.kind: continue
    # (as many parameters; more only with defaults)
    if cs.params.len < req.params.len: continue
    var extra = true
    for k in req.params.len ..< cs.params.len:
      if cs.params[k].default.len == 0: extra = false
    if not extra: continue
    let saved = env.binds
    var r = nsYes
    for k in 0 ..< req.params.len:
      let f = nxSubst(req.params[k], selfB)
      var pt = cs.params[k].typ
      if pt.len == 0: pt = nxLiteralType(cs.params[k].default)
      r = nxCpAll(r, nxCpTypeMatch(env, cand, f, pt, true, nxStripValMods(req.params[k]) == "Self"))
      if r == nsNo: break
    if r != nsNo:
      let fr = nxSubst(req.ret, selfB)
      if fr.len == 0: r = nxCpAll(r, (if cs.ret.strip.len == 0 or cs.ret.strip == "void": nsYes else: nsNo))
      elif cs.ret.strip.len == 0: r = nsNo
      elif cs.ret.strip == "auto": r = nxCpAll(r, nsUnsure)
      else: r = nxCpAll(r, nxCpTypeMatch(env, cand, fr, cs.ret, true, nxStripValMods(req.ret) == "Self"))
    if r == nsYes: return nsYes
    env.binds = saved
    result = nxCpAny(result, r)

func nxCpLiteral(e: string): string =
  ## the type of a literal: 1 → int, "a" → string …
  nxLiteralType(e)

proc nxCpExpr(env: var NxCpEnv, e0: string, depth = 0): (NxSat, string)

proc nxCpCall(env: var NxCpEnv, name: string, args: seq[string], fieldOk: bool, depth: int): (NxSat, string) =
  ## (old syntax) a call `name(args)` (args[0] the receiver of `x.name`): does it compile, and its type
  var types: seq[string]
  var sat = nsYes
  for a in args:
    let (s, t) = nxCpExpr(env, a, depth + 1)
    if s == nsNo: return (nsNo, "")
    sat = nxCpAll(sat, s)
    types.add t
  if sat != nsYes: return (nsUnsure, "")
  # x[i] on the system's own containers: the compiler's built-in indexing (not the generic magic `[]` of system.nim,
  # which takes anything on paper)
  var builtinIdx = false
  if name == "[]" and types.len == 2:
    let k0 = nxCpKindOf(env.sc, types[0])
    if k0 in ["seq", "array", "string", "cstring", "tuple"] or types[0].startsWith("openArray["):
      if k0 == "tuple" or nxCpKindOf(env.sc, types[1]) notin NxInts: return (nsUnsure, "")
      if k0 in ["string", "cstring"]: return (nsYes, "char")
      let ta = nxTypeArgs(nxStripValMods(types[0]))
      if ta.len == 0: return (nsUnsure, "")
      return (nsYes, ta[^1])
    builtinIdx = true
  # a field: x.name
  if fieldOk and args.len == 1:
    for fr in nxFields(env.sc, types[0]):
      if nxNorm(fr.sym.name) == nxNorm(name) and fr.sym.typ.len > 0: return (nsYes, fr.sym.typ)
  var best = nsNo
  var rets: seq[string]
  for cand in nxLookup(env.sc, name):
    let cs = cand.sym
    if cs.kind notin NxRoutineKinds or cs.name != name: continue
    if cs.params.len < types.len and not (cs.params.len > 0 and cs.params[^1].typ.startsWith("varargs")): continue
    if cs.kind in {nxTemplate, nxMacro}:
      best = nxCpAny(best, nsUnsure)                 # (what it expands to decides)
      continue
    if builtinIdx and "magic" in cs.pragmas: continue      # (ArrGet: the compiler's, for arrays only)
    var ok = true
    for k in types.len ..< cs.params.len:
      if cs.params[k].default.len == 0: ok = false
    if not ok: continue
    var r = nsYes
    for k in 0 ..< types.len:
      let pt = cs.params[min(k, cs.params.high)].typ
      if pt.startsWith("varargs"):
        r = nxCpAll(r, nsUnsure)
        continue
      r = nxCpAll(r, nxCpTypeMatch(env, cand, types[k], (if pt.len > 0: pt else: nxLiteralType(cs.params[k].default)),
                                   false))
      if r == nsNo: break
    if r == nsYes:
      var rt = cs.ret.strip
      let gens = nxCpGenerics(cand)
      if gens.len > 0:
        var names: seq[string]
        for (n, _) in gens: names.add n
        var b: Table[string, string]
        for k in 0 ..< min(types.len, cs.params.len): nxUnify(cs.params[k].typ, types[k], names, b)
        rt = nxSubst(rt, b)
        if nxRsHasWord(rt, names): rt = ""
      if rt in ["auto", "untyped", "typed"]: rt = ""
      rets.add rt
    best = nxCpAny(best, r)
  if best != nsYes: return (best, "")
  # (the overloads that fit must agree on what they give)
  for x in rets:
    if x != rets[0]: return (nsYes, "")
  (nsYes, rets[0])

proc nxCpExpr(env: var NxCpEnv, e0: string, depth = 0): (NxSat, string) =
  ## (old syntax) does expression `e0` compile for the type, and what type it has ("" not known)
  if depth > 8 or env.steps > 400: return (nsUnsure, "")
  var e = e0.strip
  while e.len >= 2 and e[0] == '(' and nxMatchClose(e, 0) == e.high: e = e[1 ..< e.high].strip
  if e.len == 0: return (nsUnsure, "")
  # x is T (outside brackets)
  var isK = -1
  block:
    var d = 0
    var q = 0
    while q + 4 <= e.len:
      if e[q] in {'(', '['}: inc d
      elif e[q] in {')', ']'}: dec d
      elif d == 0 and e[q ..< q + 4] == " is ":
        isK = q
        break
      inc q
  if isK > 0:
    let (s, t) = nxCpExpr(env, e[0 ..< isK], depth + 1)
    if s != nsYes: return (s, "")
    let want = e[isK + 4 .. ^1].strip
    if t.len == 0: return (nsUnsure, "")
    let r = nxCpConstraint(env.sc, want, t)
    return (r, "bool")
  # binary operators (outside brackets): the lowest-binding first written
  var depthB = 0
  var inStr = false
  var opAt = -1
  var opEnd = -1
  var k = 0
  while k < e.len:
    let ch = e[k]
    if ch == '"': inStr = not inStr
    elif inStr: discard
    elif ch in {'(', '['}: inc depthB
    elif ch in {')', ']'}: dec depthB
    elif depthB == 0 and ch == ' ' and k + 1 < e.len and e[k + 1] in NxCpOpChars:
      var q = k + 1
      while q < e.len and e[q] in NxCpOpChars: inc q
      if q < e.len and e[q] == ' ' and opAt < 0:
        opAt = k + 1
        opEnd = q
    inc k
  if opAt > 0:
    let op = e[opAt ..< opEnd]
    if op in ["!=", ">", ">="]:                   # (the system's templates: a > b is b < a …)
      let flip = case op
                 of "!=": "=="
                 of ">": "<"
                 else: "<="
      let (s, _) = nxCpCall(env, flip, (if op == "!=": @[e[0 ..< opAt], e[opEnd .. ^1]]
                                         else: @[e[opEnd .. ^1], e[0 ..< opAt]]), false, depth)
      return (s, "bool")
    if op == "=": return (nsUnsure, "")
    return nxCpCall(env, op, @[e[0 ..< opAt - 1], e[opEnd .. ^1]], false, depth)
  # a literal, one of the concept's values
  let lt = nxCpLiteral(e)
  if lt.len > 0: return (nsYes, lt)
  if e in env.vars: return (nsYes, env.self)
  if e.startsWith("not "):
    let (s, _) = nxCpExpr(env, e[4 .. ^1], depth + 1)
    return (s, "bool")
  # a call or member chain, read from its end: recv.name(args), recv.name, name(args), recv[i]
  if e.endsWith(")"):
    var o = e.high
    var d = 0
    while o >= 0:
      if e[o] == ')': inc d
      elif e[o] == '(':
        dec d
        if d == 0: break
      dec o
    if o <= 0: return (nsUnsure, "")
    var args: seq[string]
    if o + 1 < e.high:
      for p in nxSplitTop(e[o + 1 ..< e.high], {','}): args.add p.strip
    let ne = o
    var ns = ne
    while ns > 0 and nxIsIdent(e[ns - 1]): dec ns
    if ns == ne: return (nsUnsure, "")
    let name = e[ns ..< ne]
    if ns > 0 and e[ns - 1] == '.':
      return nxCpCall(env, name, @[e[0 ..< ns - 1]] & args, false, depth)
    if ns > 0: return (nsUnsure, "")
    return nxCpCall(env, name, args, false, depth)
  if e.endsWith("]"):
    let ob = block:
      var o = e.high
      var d = 0
      while o >= 0:
        if e[o] == ']': inc d
        elif e[o] == '[':
          dec d
          if d == 0: break
        dec o
      o
    if ob <= 0: return (nsUnsure, "")
    return nxCpCall(env, "[]", @[e[0 ..< ob], e[ob + 1 ..< e.high]], false, depth)
  let dot = e.rfind('.')
  if dot > 0 and e[dot + 1 .. ^1].allCharsInSet(IdentChars) and nxFindTop(e, ' ') < 0:
    return nxCpCall(env, e[dot + 1 .. ^1], @[e[0 ..< dot]], true, depth)
  # a command: name x
  let sp = e.find(' ')
  if sp > 0 and e[0 ..< sp].allCharsInSet(IdentChars) and e[0 ..< sp] notin NxKeywords:
    var args: seq[string]
    for p in nxSplitTop(e[sp + 1 .. ^1], {','}): args.add p.strip
    return nxCpCall(env, e[0 ..< sp], args, false, depth)
  (nsUnsure, "")

func nxCpIsCheck(st: string): bool =
  ## a statement `… is T` (outside brackets)
  var d = 0
  var q = 0
  while q + 4 <= st.len:
    if st[q] in {'(', '['}: inc d
    elif st[q] in {')', ']'}: dec d
    elif d == 0 and st[q ..< q + 4] == " is ": return true
    inc q
  false

proc nxSatisfies*(cpt: NxConcept, sc: NxScope, typ: string): NxSat =
  ## does type `typ` satisfy the concept, with the routines scope `sc` sees: yes, no, or cannot tell
  if not cpt.known or typ.len == 0: return nsUnsure
  var env = NxCpEnv(sc: sc, self: typ, vars: cpt.vars, varMut: cpt.varMut, gens: cpt.gens)
  if nxCpKindOf(sc, typ) == "concept": return nsUnsure
  result = nsYes
  if cpt.newStyle:
    for req in cpt.reqs:
      result = nxCpAll(result, nxCpReqMatch(env, req))
      if result == nsNo: return
  else:
    if cpt.varMut: return nsUnsure
    for st in cpt.stmts:
      let (kw, _) = nxName(st, 0)
      if kw in NxKeywords and kw notin ["not"]: return nsUnsure
      var (s, t) = nxCpExpr(env, st)
      # (a bool the compiler can work out must be true — x.isSwizzle, a {.compileTime.} call: not worked out here;
      # an `is` is, and a value of another type only has to compile)
      if s == nsYes and (t == "bool" or t.len == 0) and not nxCpIsCheck(st): s = nsUnsure
      result = nxCpAll(result, s)
      if result == nsNo: return
  if env.steps > 400: result = nsUnsure

const NxCpBuiltins = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float",
                      "float32", "float64", "bool", "char", "string", "cstring"]

proc nxCpTypesOf(f: NxFile): seq[NxRef] =
  ## the types a file declares that a concept can be tried on: not generic, not local, not a concept
  for i in 0 ..< f.syms.len:
    template s: untyped = f.syms[i]
    if s.kind == nxType and not s.local and not s.made and s.generics.len == 0 and not nxIsConcept(s) and
       s.name.len > 0 and s.name.allCharsInSet(IdentChars):
      result.add NxRef(file: f, idx: int32(i))

proc nxCpBuiltinsUsed(f: NxFile): seq[string] =
  ## the system's types a file names in its declarations (int, string, float …)
  var seen: HashSet[string]
  var texts: seq[string]
  for s in f.syms:
    texts.add s.typ
    texts.add s.ret
    for p in s.params: texts.add p.typ
  for t in texts:
    var k = 0
    while k < t.len:
      if nxIsIdent(t[k]) and (k == 0 or not nxIsIdent(t[k - 1])):
        var e = k
        while e < t.len and nxIsIdent(t[e]): inc e
        let w = t[k ..< e]
        if w in NxCpBuiltins and w notin seen:
          seen.incl w
          result.add w
        k = e
      else: inc k

var nxCpImplCache: Table[string, (float, seq[(string, NxRef)], int, int)]
  ## concept → (when worked out, the types that satisfy it, how many do not, how many the engine cannot tell)

proc nxConceptImpls*(cr: NxRef, files: seq[string], here: NxFile, ms = 400):
    (seq[(string, NxRef)], int, int, bool) =
  ## the types that satisfy concept `cr`: those the files declare (each tried with what its own module sees) and the
  ## system's types `here` names (with what `here` sees) — (name, declaration) of each, how many do not, how many
  ## the engine cannot tell, and whether it ran out of its `ms` milliseconds first
  let key = cr.file.path & ":" & $cr.sym.line & ":" & cr.sym.name & ":" & nxCurStamp(cr.file.path) & ":" &
            (if here != nil: here.path & ":" & nxCurStamp(here.path) else: "") & ":" & $files.len & ":" & $nxGen
  if key in nxCpImplCache and epochTime() - nxCpImplCache[key][0] < 10:
    let x = nxCpImplCache[key]
    return (x[1], x[2], x[3], false)
  let cpt = nxConceptOf(cr)
  if not cpt.known or cpt.gens.len > 0: return (@[], 0, 0, false)
  let t0 = getMonoTime()
  var no, unsure = 0
  var cut = false
  var seen: HashSet[string]
  for p in files:
    if (getMonoTime() - t0).inMilliseconds > ms:
      cut = true
      break
    let g = nxLoad(p)
    if g == nil: continue
    let ts = nxCpTypesOf(g)
    if ts.len == 0: continue
    let sc = nxScope(g)
    for t in ts:
      let k = g.path & ":" & $t.sym.line
      if k in seen: continue
      seen.incl k
      case nxSatisfies(cpt, sc, t.sym.name)
      of nsYes: result[0].add (t.sym.name, t)
      of nsNo: inc no
      of nsUnsure: inc unsure
  if here != nil and not cut:
    let sc = nxScope(here)
    for b in nxCpBuiltinsUsed(here):
      case nxSatisfies(cpt, sc, b)
      of nsYes:
        var decl = NxRef()
        for r in nxTypeSyms(sc, b):
          decl = r
          break
        result[0].add (b, decl)
      of nsNo: inc no
      of nsUnsure: inc unsure
  result[1] = no
  result[2] = unsure
  result[3] = cut
  if not cut:
    if nxCpImplCache.len > 64: nxCpImplCache.clear()
    nxCpImplCache[key] = (epochTime(), result[0], no, unsure)

proc nxConceptsOf*(t: NxRef, here: NxFile, ms = 200): seq[NxRef] =
  ## the concepts in scope (the type's module's, and `here`'s) that type `t` surely satisfies
  if t.file == nil or t.sym.kind != nxType or nxIsConcept(t.sym) or t.sym.generics.len > 0: return
  # (tried where the question is asked when the type is seen there — the routines `here` sees count — else in its
  # own module)
  var sc = nxScope(t.file)
  if here != nil and here.path != t.file.path:
    let hs = nxScope(here)
    for r in nxTypeSyms(hs, t.sym.name):
      if r.file.path == t.file.path and r.sym.line == t.sym.line: sc = hs
  let t0 = getMonoTime()
  var seen: HashSet[string]
  for scx in [sc, (if here != nil: nxScope(here) else: nil)]:
    if scx == nil: continue
    for r in scx.refs:
      if not nxIsConcept(r.sym) or r.sym.generics.len > 0: continue
      let k = r.file.path & ":" & $r.sym.line
      if k in seen: continue
      seen.incl k
      if (getMonoTime() - t0).inMilliseconds > ms: return
      if nxSatisfies(nxConceptOf(r), sc, t.sym.name) == nsYes: result.add r

proc nxConceptHover*(r: NxRef, files: seq[string], here: NxFile): string =
  ## the hover's line about concepts: on a concept, the types that satisfy it; on a type, the concepts it satisfies
  if r.file == nil or r.sym.kind != nxType: return
  if nxIsConcept(r.sym):
    let cpt = nxConceptOf(r)
    if not cpt.known or cpt.gens.len > 0: return
    let (yes, no, unsure, _) = nxConceptImpls(r, files, here)
    if yes.len > 0:
      var names: seq[string]
      for (n, _) in yes:
        if names.len >= 12:
          names.add "… " & $(yes.len - 12) & " more"
          break
        names.add "`" & n & "`"
      result = "**satisfied by:** " & names.join(", ")
      if unsure > 0: result.add " (" & $unsure & " more the engine cannot tell)"
    elif no > 0 and unsure == 0:
      result = "**satisfied by:** none of the project's types"
  else:
    var names: seq[string]
    for c in nxConceptsOf(r, here):
      names.add "`" & c.sym.name & "`"
    if names.len > 0: result = "**satisfies:** " & names.join(", ")
