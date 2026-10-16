# ── types: what an expression is, and what a type offers ──

proc nxStripMods*(t: string): string =
  ## "var seq[int]" → "seq[int]", "sink Foo" → "Foo", "ref Foo" → "Foo", "static[int]" → "int"
  result = t.strip
  var changed = true
  while changed:
    changed = false
    for m in ["var ", "sink ", "lent ", "ref ", "ptr ", "out ", "owned "]:
      if result.startsWith(m):
        result = result[m.len .. ^1].strip
        changed = true
    if result.startsWith("static[") and result.endsWith("]"):
      result = result[7 ..< result.high]
      changed = true
    if result.startsWith("owned(") and result.endsWith(")"):
      result = result[6 ..< result.high].strip
      changed = true

proc nxBaseName*(t: string): string =
  let s = nxStripMods(t)
  var e = 0
  while e < s.len and (nxIsIdent(s[e]) or s[e] == '.'): inc e
  result = s[0 ..< e]
  let d = result.rfind('.')
  if d >= 0: result = result[d + 1 .. ^1]       # module.Type

proc nxTypeArgs*(t: string): seq[string] =
  let s = nxStripMods(t)
  let b = s.find('[')
  if b < 0: return
  let e = nxMatchClose(s, b)
  if e < 0: return
  for p in nxSplitTop(s[b + 1 ..< e], {','}): result.add p.strip

proc nxTypeSyms*(sc: NxScope, name: string): seq[NxRef] =
  for r in nxLookup(sc, name):
    if r.sym.kind == nxType: result.add r

proc nxObjectDef*(sc: NxScope, typ: string, depth = 0): (NxRef, string) =
  ## the type declaration behind `typ`, following aliases and `ref X` / `ptr X` definitions
  if depth > 6: return
  let b = nxBaseName(typ)
  if b.len == 0: return
  for r in nxTypeSyms(sc, b):
    let def = r.sym.typ
    let sm = nxStripMods(def)
    if def.contains("object") or def.startsWith("enum") or def.startsWith("tuple") or def.startsWith("concept") or
       def.startsWith("distinct") or def.len == 0:
      return (r, def)
    if sm.len > 0 and nxBaseName(sm) != b:
      let deeper = nxObjectDef(sc, sm, depth + 1)
      if deeper[0].file != nil: return deeper
    return (r, def)

proc nxFields*(sc: NxScope, typ: string, depth = 0): seq[NxRef] =
  ## the fields of an object or tuple type, including inherited ones
  if depth > 8: return
  let (r, def) = nxObjectDef(sc, typ)
  if r.file == nil: return
  let owner = r.sym.name
  for i, s in r.file.syms:
    if s.kind == nxField and s.owner == owner: result.add NxRef(file: r.file, idx: i)
  let k = def.find(" of ")
  if k >= 0:
    let base = def[k + 4 .. ^1].strip
    if base.len > 0 and base notin ["RootObj", "RootRef"]:
      # the base type is looked up from the file that declares this type
      let sc2 = if r.file == sc.own or r.file.path == "": sc else: nxScope(r.file)
      result.add nxFields(sc2, base, depth + 1)
  if def.startsWith("tuple["):
    discard     # tuple[...] fields were recorded as fields of the alias already

proc nxAncestors*(sc: NxScope, child: string): seq[string] =
  ## the base types of an object type, nearest first (normalized names), memoized per scope
  let key = nxBaseName(child)
  if key.len == 0: return
  if key in sc.anc: return sc.anc[key]
  sc.anc[key] = @[]                 # guards against cycles while we work
  var cur = key
  var csc = sc
  for depth in 0 .. 8:
    let (r, def) = nxObjectDef(csc, cur)
    if r.file == nil: break
    let k = def.find(" of ")
    if k < 0: break
    let base = nxBaseName(def[k + 4 .. ^1])
    if base.len == 0 or nxNorm(base) in result: break
    result.add nxNorm(base)
    cur = base
    if r.file != csc.own: csc = nxScope(r.file)
  sc.anc[key] = result

proc nxIsSubtype*(sc: NxScope, child, parent: string): bool =
  let anc = nxAncestors(sc, child)
  if nxNorm(nxBaseName(parent)) in anc: return true
  # Stream = ref StreamObj: a StringStream (ref StringStreamObj, an object of StreamObj) is one
  let (pr, _) = nxObjectDef(sc, parent)
  pr.file != nil and nxNorm(pr.sym.name) in anc

proc nxElemType*(t: string): string =
  ## what indexing or iterating yields
  let s = nxStripMods(t)
  let b = nxBaseName(s)
  let args = nxTypeArgs(s)
  case b
  of "seq", "openArray", "varargs", "set", "HashSet", "OrderedSet", "UncheckedArray", "Deque", "SinglyLinkedList",
     "DoublyLinkedList", "HeapQueue", "Option":
    if args.len > 0: args[0] else: ""
  of "array": (if args.len > 1: args[1] elif args.len == 1: args[0] else: "")
  of "string", "cstring": "char"
  of "Table", "TableRef", "OrderedTable", "OrderedTableRef": (if args.len > 1: args[1] else: "")
  of "CountTable", "CountTableRef": "int"
  of "JsonNode": "JsonNode"
  else: ""

const NxTypeClasses* = [
  ("SomeInteger", "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 byte Natural Positive"),
  ("SomeSignedInt", "int int8 int16 int32 int64 Natural Positive"),
  ("SomeUnsignedInt", "uint uint8 uint16 uint32 uint64 byte"),
  ("SomeFloat", "float float32 float64"),
  ("SomeNumber", "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 byte float float32 float64 Natural Positive"),
  ("SomeOrdinal", "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 byte char bool Natural Positive"),
  ("Ordinal", "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 byte char bool Natural Positive"),
  ("SomeSet", "set HashSet OrderedSet")]

const
  NxInts* = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte",
            "Natural", "Positive", "BiggestInt", "BiggestUInt", "range", "csize_t", "cint", "clong", "Ordinal"]
  NxFloats* = ["float", "float32", "float64", "BiggestFloat", "cfloat", "cdouble"]

proc nxResolveAlias*(sc: NxScope, name: string): string =
  ## follow `type A = B` aliases to the type they name (distinct types stay themselves)
  if name in sc.alias: return sc.alias[name]
  result = name
  defer: sc.alias[name] = result
  for _ in 0 .. 5:
    var nxt = ""
    for r in nxTypeSyms(sc, result):
      let raw = r.sym.typ.strip
      if raw.startsWith("ref ") or raw.startsWith("ptr "): break       # TableRef is not a Table
      let d = nxStripMods(raw)
      let b = nxBaseName(d)
      if b.len > 0 and b != result and not d.startsWith("distinct") and d.find("object") < 0 and
         not d.startsWith("enum") and not d.startsWith("tuple") and not d.startsWith("concept"):
        nxt = b
      break
    if nxt.len == 0: return
    result = nxt

proc nxConstraintFit*(sc: NxScope, generics, name, rb: string): int =
  ## a generic parameter `name` with its constraint ([T: SomeInteger], [T: float32 | float64]) against an
  ## argument of type `rb`: 2 fits · 0 cannot · 1 cannot tell (a concept, an enum for SomeOrdinal …)
  var cons = ""
  for p in nxParseParams(generics.strip(chars = {'[', ']', ' '})):
    if nxNorm(p.name) == nxNorm(name): cons = p.typ
  if cons.len == 0: return 1
  let ra = nxResolveAlias(sc, rb)
  var known = true
  for alt0 in cons.split('|'):
    let alt = alt0.strip
    var cls = false
    for (c, members) in NxTypeClasses:
      if alt == c:
        cls = true
        if rb in members.split(' ') or ra in members.split(' '): return 2
        if c in ["SomeOrdinal", "Ordinal"]: known = false       # an enum is ordinal too
    if cls: continue
    if nxNorm(alt) == nxNorm(rb) or nxNorm(alt) == nxNorm(ra): return 2
    if alt notin NxInts and alt notin NxFloats and alt notin ["string", "cstring", "char", "bool"]: known = false
  if known: 0 else: 1

proc nxCompat*(sc: NxScope, paramType, generics, recv: string): int =
  ## can a value of type `recv` be the first argument of a routine whose first parameter is `paramType`?
  ## 3 exact · 2 related (subtype, openArray, type class, alias, wider number) · 1 generic · 0 no
  let p = nxStripMods(paramType)
  if p.len == 0: return 1
  var pb = nxBaseName(p)
  var rb = nxBaseName(recv)
  if rb.len == 0: return 1
  if nxNorm(pb) == nxNorm(rb) or (pb in ["float", "float64"] and rb in ["float", "float64"]): return 3
  if pb.len > 0 and pb notin ["openArray", "varargs", "auto", "typed", "untyped", "any"] and
     not (pb.len <= 2 and pb[0] in {'A'..'Z'}):
    # aliases (BiggestInt = int64) and numbers that convert without a cast (int → int64, float32 → float)
    let pa = nxResolveAlias(sc, pb)
    let ra = nxResolveAlias(sc, rb)
    if nxNorm(pa) == nxNorm(ra): return 2
    if (pa in NxInts or pb in NxInts) and (ra in NxInts or rb in NxInts): return 2
    if (pa in NxFloats or pb in NxFloats) and (ra in NxFloats or rb in NxFloats): return 2
  case pb
  of "openArray", "varargs":
    if rb in ["seq", "array", "openArray", "varargs"]: return 2
    if rb in ["string", "cstring"]:
      let a = nxTypeArgs(p)
      if a.len > 0 and a[0] == "char": return 2
      if a.len > 0 and a[0].len in 1 .. 2 and a[0][0] in {'A'..'Z'}: return 1     # openArray[T] takes a string too
    return 0
  of "auto", "typed", "untyped", "any", "RootObj": return 1
  of "typedesc", "type": return 0
  else: discard
  for (cls, members) in NxTypeClasses:
    if pb == cls: return (if rb in members.split(' '): 2 else: 0)
  if pb.len == 0: return 0
  if pb.len <= 2 and pb[0] in {'A'..'Z'}:
    # T, K, V, U — a generic parameter (a bare T is held to its constraint: [T: SomeInteger] takes no string)
    return (if p == pb: min(1, nxConstraintFit(sc, generics, pb, rb)) else: 1)
  let g = generics.strip(chars = {'[', ']'})
  if g.len > 0:
    for part in nxSplitTop(g, {',', ';'}):
      let gn = part.split(':')[0].strip
      if nxNorm(gn) == nxNorm(pb): return (if p == pb: min(1, nxConstraintFit(sc, generics, pb, rb)) else: 1)
  if nxIsSubtype(sc, recv, p): return 2
  0

proc nxGenericNames*(generics: string): seq[string] =
  ## "[A, B: SomeInteger; N: static int]" → A, B, N
  let g = generics.strip(chars = {'[', ']', ' '})
  for part in nxSplitTop(g, {',', ';'}):
    let gn = part.split(':')[0].strip
    if gn.len > 0 and nxIsIdent(gn[0]): result.add gn

proc nxTupleTypes*(t: string): seq[string] =
  ## "tuple[kind: PathComponent, path: string]" or "(A, B)" → the element types
  let s = nxStripMods(t)
  if s.startsWith("tuple[") and s.endsWith("]"):
    for p in nxParseParams(s[6 ..< s.high]): result.add p.typ
  elif s.startsWith("(") and s.endsWith(")"):
    for p in nxSplitTop(s[1 ..< s.high], {','}): result.add p.strip


proc nxUnify*(p, a: string, names: seq[string], res: var Table[string, string], depth = 0) =
  ## match a parameter type against an argument type, binding the routine's generic parameters
  if depth > 6: return
  let ps = nxStripMods(p)
  let av = nxStripMods(a)
  if ps.len == 0 or av.len == 0: return
  if (ps.startsWith("(") or ps.startsWith("tuple[")) and (av.startsWith("(") or av.startsWith("tuple[")):
    # (A, B) against (string, int)
    let pp = nxTupleTypes(ps)
    let aa = nxTupleTypes(av)
    for k in 0 ..< min(pp.len, aa.len): nxUnify(pp[k], aa[k], names, res, depth + 1)
    return
  let pb = nxBaseName(ps)
  if pb in names and ps.find('[') < 0:
    if pb notin res: res[pb] = av
    return
  let pargs = nxTypeArgs(ps)
  if pargs.len == 0: return
  let ab = nxBaseName(av)
  let aargs = nxTypeArgs(av)
  if pb in ["openArray", "varargs"]:
    if ab in ["string", "cstring"]: nxUnify(pargs[0], "char", names, res, depth + 1)
    elif aargs.len > 0: nxUnify(pargs[0], aargs[^1], names, res, depth + 1)
    return
  if aargs.len == 0: return
  if nxNorm(pb) == nxNorm(ab) or (pb.endsWith("Ref") and pb[0 ..< ^3] == ab) or
     (ab.endsWith("Ref") and ab[0 ..< ^3] == pb):
    for i in 0 ..< min(pargs.len, aargs.len): nxUnify(pargs[i], aargs[i], names, res, depth + 1)

proc nxSubst*(t: string, b: Table[string, string]): string =
  ## replace generic parameter names (whole words) in a type
  if b.len == 0: return t
  var i = 0
  while i < t.len:
    if nxIsIdent(t[i]) and (i == 0 or not (nxIsIdent(t[i - 1]) or t[i - 1] == '.')):
      var e = i
      while e < t.len and nxIsIdent(t[e]): inc e
      let w = t[i ..< e]
      result.add (if w in b: b[w] else: w)
      i = e
    else:
      result.add t[i]
      inc i

proc nxLiteralType*(v: string): string =
  ## the type of a literal default value: 1 → int, 1.0 → float, "x" → string …
  let s = v.strip
  if s.len == 0: return ""
  if s[0] == '"': return "string"
  if s[0] == '\'': return "char"
  if s in ["true", "false"]: return "bool"
  if s[0] in Digits or (s[0] == '-' and s.len > 1 and s[1] in Digits):
    if '\'' in s: return s[s.find('\'') + 1 .. ^1]
    if '.' in s or 'e' in s: return "float"
    return "int"
  ""

proc nxCompatP*(sc: NxScope, prm: NxParam, generics, recv: string): int =
  ## nxCompat for a parameter that may have only a default value (`initialSize = 32`)
  if prm.typ.len == 0:
    if prm.default.len == 0: return 1
    let lt = nxLiteralType(prm.default)
    if lt.len == 0: return 0
    return min(1, nxCompat(sc, lt, "", recv))     # legal, but nobody writes 5.instantiationInfo
  nxCompat(sc, prm.typ, generics, recv)

proc nxBindings*(s: NxSym, recv: string, genArgs: seq[string] = @[]): Table[string, string] =
  ## generic parameters of routine `s` bound from explicit [args] or from its first argument's type
  if recv.startsWith("typedesc[") and s.params.len > 0 and nxStripMods(s.params[0].typ) == "typedesc":
    result[s.params[0].name] = recv[9 ..< ^1]          # proc none(T: typedesc): Option[T]
  let names = nxGenericNames(s.generics)
  if names.len == 0: return
  if genArgs.len > 0:
    for i in 0 ..< min(names.len, genArgs.len): result[names[i]] = genArgs[i]
  elif recv.len > 0 and s.params.len > 0:
    nxUnify(s.params[0].typ, recv, names, result)

proc nxTypeBindings*(sc: NxScope, typ: string): Table[string, string] =
  ## a generic object's parameters bound from a concrete type: Table[A, B] + Table[string, int]
  let args = nxTypeArgs(typ)
  if args.len == 0: return
  for r in nxTypeSyms(sc, nxBaseName(typ)):
    let names = nxGenericNames(r.sym.generics)
    for i in 0 ..< min(names.len, args.len):
      if args[i] != names[i]: result[names[i]] = args[i]
    return

proc nxExpandAlias*(sc: NxScope, t: string): string =
  ## an alias written out: Config → OrderedTableRef[string, OrderedTableRef[string, string]],
  ## MultipartEntries → openArray[tuple[name, content: string]] ("" when `t` is a type of its own)
  var cur = nxStripMods(t)
  for _ in 0 .. 4:
    var nxt = ""
    for r in nxTypeSyms(sc, nxBaseName(cur)):
      let d = r.sym.typ.strip
      if d.len == 0 or d.startsWith("distinct") or d.find("object") >= 0 or d.startsWith("enum") or
         d.startsWith("concept") or d.startsWith("proc") or d.startsWith("ptr ") or d.startsWith("ref "):
        break
      nxt = nxSubst(d, nxTypeBindings(sc, cur))
      break
    if nxt.len == 0 or nxt == cur: break
    result = nxt
    cur = nxStripMods(nxt)
    if nxElemType(cur).len > 0: break

type NxVal* = object
  typ*: string                 # the value's type ("" = unknown)
  module*: string              # it is a module (its path)
  typeName*: string            # it is a type itself (typedesc)
  routine*: string             # a routine name not called yet

proc nxTypeOfExpr*(f: NxFile, sc: NxScope, locals: seq[NxSym], e: string, line, depth: int): NxVal

proc nxFindRange*(s: string): int =
  ## a top-level `..` (a .. b, a ..< b), or -1
  var depth = 0
  var i = 0
  while i + 1 < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif c == '.' and s[i + 1] == '.' and depth == 0: return i
    inc i
  -1

proc nxFlat*(s: string): string =
  ## the expression with strings and bracket contents blanked, to look for top-level operators
  result = newString(s.len)
  var depth = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      for q in i .. nxCharEnd(s, i): result[q] = '_'
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      result[i] = '_'
      inc i
      while i < s.len and s[i] != '"':
        result[i] = '_'
        if s[i] == '\\' and i + 1 < s.len:
          inc i
          result[i] = '_'
        inc i
      if i < s.len: result[i] = '_'
    elif c in {'(', '[', '{'}:
      result[i] = (if depth == 0: c else: '_')
      inc depth
    elif c in {')', ']', '}'}:
      dec depth
      result[i] = (if depth == 0: c else: '_')
    else: result[i] = (if depth > 0: '_' else: c)
    inc i

proc nxIsGenericName*(t: string, generics: string): bool =
  let b = nxStripMods(t)
  b.len > 0 and b.find('[') < 0 and b in nxGenericNames(generics)

proc nxArgsFit*(s: NxSym, nargs: int): bool =
  ## can `s` be called with `nargs` arguments (defaults and varargs counted; -1: not known)
  if nargs < 0: return true
  var req = 0
  var va = false
  for p in s.params:
    if p.typ.startsWith("varargs"): va = true
    elif p.default.len == 0: inc req
  nargs >= req and (va or nargs <= s.params.len)

proc nxInferAuto*(fp: NxFile, s: NxSym, depth: int): string
proc nxVisible*(f: NxFile, r: NxRef): bool

proc nxCallType*(f: NxFile, sc: NxScope, locals: seq[NxSym], name: string, recv: string, line, depth: int,
                genArgs: seq[string] = @[], nargs = -1, argExprs: seq[string] = @[]): string =
  ## the result type of calling `name`, with `recv` as its first argument when that is known (and `nargs`
  ## arguments in all, receiver included, when that is known: readLine(f) is not readLine(f, s)); `argExprs`, the
  ## arguments after the first, tell overloads apart when the first does not: recv(sock, 10) is not recv(sock, buf, 10)
  var recv = recv
  if recv.len > 0 and nxTypeArgs(nxStripMods(recv)).len == 0 and nxStripMods(recv) notin NxInts and
     nxStripMods(recv) notin NxFloats and nxStripMods(recv) notin ["string", "char", "bool", "cstring"]:
    # Vec2 = GVec2[float32]: the generic it stands for binds T
    let ex = nxExpandAlias(sc, recv)
    if ex.len > 0 and nxTypeArgs(ex).len > 0: recv = ex
  for k in countdown(locals.high, 0):
    # a routine declared inside this one: what its header says
    let s = locals[k]
    if s.kind in NxRoutineKinds and nxNorm(s.name) == nxNorm(name) and s.line <= line:
      if s.ret.len > 0 and s.ret notin ["auto", "untyped", "typed"] and s.generics.len == 0: return nxStripMods(s.ret)
      break
  var best: NxRef
  var bestScore = -1
  var rets: HashSet[string]
  var anyFits = false
  var cands: seq[(NxRef, int)]
  for r in nxLookup(sc, name):
    let s = r.sym
    if s.kind in NxRoutineKinds and s.kind != nxIterator and s.ret.len > 0 and nxArgsFit(s, nargs): anyFits = true
  for r in nxLookup(sc, name):
    let s = r.sym
    if s.kind notin NxRoutineKinds or s.kind == nxIterator or s.ret.len == 0: continue
    if anyFits and not nxArgsFit(s, nargs): continue
    rets.incl s.ret
    var score = 1
    if recv.len > 0: score = (if s.params.len == 0: 0 else: nxCompatP(sc, s.params[0], s.generics, recv))
    let generic = s.ret in ["auto", "untyped", "typed"] or nxIsGenericName(s.ret, s.generics)
    let total = score * 2 + (if generic: 0 else: 1)
    cands.add (r, total)
    if total > bestScore:
      bestScore = total
      best = r
  if argExprs.len > 0 and cands.len > 1:
    # several overloads take the first argument: the others decide
    var tied: seq[NxRef]
    var tiedRets: HashSet[string]
    for (r, t) in cands:
      if t == bestScore:
        tied.add r
        tiedRets.incl r.sym.ret
    if tied.len > 1 and tiedRets.len > 1:
      var argT = newSeq[string](argExprs.len)
      var known = newSeq[bool](argExprs.len)
      var best2 = -1
      for r in tied:
        var sc2 = 0
        var ok = true
        for j in 0 ..< argExprs.len:
          let e = argExprs[j]
          if j + 1 >= r.sym.params.len or nxFindTop(e, '=') >= 0: continue
          if not known[j]:
            known[j] = true
            argT[j] = nxTypeOfExpr(f, sc, locals, e, line, depth + 1).typ
          if argT[j].len == 0: continue
          let c = nxCompatP(sc, r.sym.params[j + 1], r.sym.generics, argT[j])
          if c == 0:
            ok = false
            break
          sc2 += c
        if ok and sc2 > best2:
          best2 = sc2
          best = r
  if best.file == nil: return ""
  if bestScore < 2:
    # nothing accepts that argument (our guess about it may be off): trust only a result all overloads share
    if rets.len != 1: return ""
  let s = best.sym
  var b = nxBindings(s, recv, genArgs)
  if argExprs.len > 0 and s.generics.len > 0 and genArgs.len == 0:
    # T bound by a later argument: convert(Seconds, Nanoseconds, x) is x's type
    let names = nxGenericNames(s.generics)
    for j, e in argExprs:
      if j + 1 >= s.params.len: break
      if nxFindTop(e, '=') >= 0: continue
      let pt = s.params[j + 1].typ
      var needs = false
      for n in names:
        if n notin b:
          for w in pt.split({'[', ']', ',', ' ', '(', ')', ':'}):
            if w == n: needs = true
      if needs:
        let at = nxTypeOfExpr(f, sc, locals, e, line, depth + 1).typ
        if at.len > 0: nxUnify(pt, at, names, b)
  var rt = nxStripMods(nxSubst(s.ret, b))
  if rt == "auto":
    rt = nxStripMods(nxSubst(nxInferAuto(best.file, s, depth + 1), b))
    if rt.len == 0: return ""
  if rt in ["auto", "untyped", "typed", "typedesc"]: return ""
  if nxIsGenericName(rt, s.generics):
    # unbound `T`: the receiver's element is the usual answer (seq[T].pop)
    return (if recv.len > 0: nxElemType(recv) else: "")
  rt

proc nxProcRet*(t: string): string =
  ## what a proc type returns: "proc (x: int): string {.closure.}" → "string"
  let s = t.strip
  let a = s.find('(')
  if a < 0: return ""
  let e = nxMatchClose(s, a)
  if e < 0: return ""
  var rest = s[e + 1 .. ^1].strip
  if not rest.startsWith(":"): return ""
  rest = rest[1 .. ^1]
  let pr = rest.find("{.")
  if pr >= 0: rest = rest[0 ..< pr]
  rest.strip

proc nxCommonRet*(sc: NxScope, name: string): string =
  ## what every overload of `name` returns, when that is one type (so a call can be typed without its receiver)
  var rets: HashSet[string]
  for r in nxLookup(sc, name):
    let s = r.sym
    if s.kind notin NxRoutineKinds or s.kind == nxIterator: continue
    if s.ret.len == 0 or s.ret in ["auto", "untyped", "typed"] or nxIsGenericName(nxStripMods(s.ret), s.generics): return ""
    var hasGen = false
    for g in nxGenericNames(s.generics):
      if s.ret.find(g) >= 0: hasGen = true
    if hasGen: return ""
    rets.incl nxStripMods(s.ret)
  if rets.len == 1:
    for x in rets: return x
  ""

proc nxIterVarType*(f: NxFile, sc: NxScope, locals: seq[NxSym], expr: string, slot, slots, line, depth: int): string =
  ## the type of loop variable `slot` (of `slots`) in  for … in expr
  if depth > 16: return
  var x = expr.strip
  if x.endsWith(":"): x = x[0 ..< ^1].strip
  if x.len == 0: return
  let rg = nxFindRange(x)
  if rg > 0:
    let lt = nxTypeOfExpr(f, sc, locals, x[0 ..< rg], line, depth + 1).typ
    return (if lt.len > 0: lt else: "int")
  # split  recv.name(args) / name(args) / value
  var head = x
  var args = ""
  var called = false
  if x.endsWith(")"):
    var d = 0
    var j = x.high
    while j >= 0:
      if x[j] == ')': inc d
      elif x[j] == '(':
        dec d
        if d == 0: break
      dec j
    if j > 0:
      head = x[0 ..< j].strip
      args = x[j + 1 ..< x.high]
      called = true
  var e = head.len
  var a = e
  while a > 0 and nxIsIdent(head[a - 1]): dec a
  let name = head[a ..< e]
  var recvExpr = ""
  var itName = ""
  var hasIter = false
  for r in nxLookup(sc, name):
    if r.sym.kind == nxIterator: hasIter = true
  if hasIter and a > 1 and head[a - 1] == '.' and not called:
    # a.fields: the object's field wins over the iterator of that name
    let rt0 = nxTypeOfExpr(f, sc, locals, head[0 ..< a - 1], line, depth + 1).typ
    if rt0.len > 0:
      for fr in nxFields(sc, rt0):
        if nxNorm(fr.sym.name) == nxNorm(name):
          hasIter = false
          break
  if a > 0 and head[a - 1] == '.' and not called and not hasIter and
     name notin ["pairs", "mpairs", "items", "mitems", "keys", "values", "mvalues", "countup", "countdown"]:
    recvExpr = x                                 # a field, a proc call without (): the value's own items
  elif a > 0 and head[a - 1] == '.':
    itName = name
    recvExpr = head[0 ..< a - 1]
  elif a == 0 and called and name.len > 0:
    itName = name
    let ps = nxSplitTop(args, {','})
    if ps.len > 0 and nxFindTop(ps[0], '=') < 0: recvExpr = ps[0].strip
  else:
    recvExpr = x
  var ct = if recvExpr.len > 0: nxTypeOfExpr(f, sc, locals, recvExpr, line, depth + 1).typ else: ""
  var base = nxBaseName(ct)
  const Known = ["seq", "openArray", "varargs", "array", "string", "cstring", "set", "HSlice", "Slice",
                 "CountTable", "CountTableRef", "StringTableRef", "Table", "TableRef", "OrderedTable",
                 "OrderedTableRef", "JsonNode", "HashSet", "OrderedSet", "Deque", "UncheckedArray"]
  if ct.len > 0 and base notin Known:
    let ex = nxExpandAlias(sc, ct)               # Config = OrderedTableRef[…]
    if ex.len > 0:
      ct = ex
      base = nxBaseName(ct)
  if ct.len > 0 and base notin Known and itName notin ["countup", "countdown"]:
    # a type of its own (HttpHeaders, a user's tree): the iterator it has says what it yields
    let want = if itName.len > 0: itName elif slots >= 2: "pairs" else: "items"
    for r in nxLookup(sc, want):
      let s = r.sym
      if s.kind != nxIterator or s.ret.len == 0 or s.params.len == 0: continue
      if nxCompatP(sc, s.params[0], s.generics, ct) < 2: continue
      let rt = nxStripMods(nxSubst(s.ret, nxBindings(s, ct)))
      if nxIsGenericName(rt, s.generics): continue
      if slots >= 2:
        let parts = nxTupleTypes(rt)
        return (if slot < parts.len: parts[slot] else: "")
      return rt
  let targs = nxTypeArgs(ct)
  let a0 = if targs.len > 0: targs[0] else: ""
  let a1 = if targs.len > 1: targs[1] else: ""
  let kv =
    if base in ["CountTable", "CountTableRef"]: (a0, "int")
    elif base == "StringTableRef": ("string", "string")
    elif base in ["Table", "TableRef", "OrderedTable", "OrderedTableRef"]: (a0, a1)
    elif base == "JsonNode": ("string", "JsonNode")
    else: ("int", nxElemType(ct))
  case itName
  of "pairs", "mpairs":
    let (k, v) = kv
    if slots >= 2: return (if slot == 0: k else: v)
    return "(" & k & ", " & v & ")"
  of "keys": return kv[0]
  of "values", "mvalues": return kv[1]
  of "items", "mitems":
    let el = nxElemType(ct)
    if slots >= 2:
      # for k, v in items(pairsOfThings): each name takes one element of the tuple
      let parts = nxTupleTypes(el)
      return (if slot < parts.len: parts[slot] else: "")
    return el
  of "countup", "countdown": return (if ct.len > 0: ct else: "int")
  of "":
    if slots >= 2:
      let (k, v) = kv
      return (if slot == 0: k else: v)
    return nxElemType(ct)
  else: discard
  # an iterator by that name: what it yields
  for r in nxLookup(sc, itName):
    let s = r.sym
    if s.kind != nxIterator or s.ret.len == 0: continue
    if ct.len > 0 and s.params.len > 0 and nxCompatP(sc, s.params[0], s.generics, ct) == 0: continue
    var rt = nxStripMods(nxSubst(s.ret, nxBindings(s, ct)))
    if nxIsGenericName(rt, s.generics): rt = nxElemType(ct)
    if slots >= 2:
      let parts = nxTupleTypes(rt)
      return (if slot < parts.len: parts[slot] else: "")
    return rt
  # a call that returns a collection
  let vt = nxTypeOfExpr(f, sc, locals, x, line, depth + 1).typ
  if slots >= 2: return (if slot == 0: "int" else: nxElemType(vt))
  nxElemType(vt)

proc nxTypeOfName*(f: NxFile, sc: NxScope, locals: seq[NxSym], name: string, line, depth: int): NxVal =
  if depth > 14: return
  for i in countdown(locals.high, 0):
    let s = locals[i]
    if nxNorm(s.name) == nxNorm(name) and s.line <= line:
      if s.kind in NxRoutineKinds: return NxVal(routine: name)
      if s.typ.len > 0:
        if s.kind == nxParam and '|' in s.typ:
          # client: HttpClient | AsyncHttpClient — its members are those of the first
          let alts = nxSplitTop(s.typ, {'|'})
          if alts.len > 1: return NxVal(typ: alts[0].strip)
        return NxVal(typ: s.typ)
      if s.kind == nxForVar:
        # only the locals declared before the loop can appear in its header
        var before: seq[NxSym]
        for k in 0 ..< i:
          if locals[k].line < s.line or (locals[k].line == s.line and locals[k].kind != nxForVar): before.add locals[k]
        if s.slots < 0:
          let whole = nxIterVarType(f, sc, before, s.value, 0, 1, s.line, depth + 1)
          let parts = nxTupleTypes(whole)
          return NxVal(typ: (if s.slot < parts.len: parts[s.slot] else: ""))
        return NxVal(typ: nxIterVarType(f, sc, before, s.value, s.slot.int, max(1, s.slots.int), s.line, depth + 1))
      if s.value.len > 0:
        var k0 = i
        while k0 > 0 and locals[k0 - 1].line == s.line and locals[k0 - 1].slots < 0: dec k0
        let v = nxTypeOfExpr(f, sc, locals[0 ..< k0], s.value, s.line, depth + 1)
        if s.slots < 0:
          let parts = nxTupleTypes(v.typ)
          return NxVal(typ: (if s.slot < parts.len: parts[s.slot] else: ""))
        return v
      return
  if name in sc.modules: return NxVal(module: sc.modules[name])
  for r in nxLookup(sc, name):
    let s = r.sym
    case s.kind
    of nxType: return NxVal(typeName: s.name)
    of nxConst, nxLet, nxVar:
      if s.typ.len > 0: return NxVal(typ: s.typ)
      if s.value.len > 0:
        let sc2 = if r.file == sc.own: sc else: nxScope(r.file)
        let v = nxTypeOfExpr(r.file, sc2, @[], s.value, s.line, depth + 1)
        if s.slots < 0:
          let parts = nxTupleTypes(v.typ)
          return NxVal(typ: (if s.slot < parts.len: parts[s.slot] else: ""))
        return v
    of nxEnumVal: return NxVal(typ: s.owner)
    of NxRoutineKinds: return NxVal(routine: s.name)
    else: discard

proc nxLambdaType*(f: NxFile, sc: NxScope, locals: seq[NxSym], fn, argT: string, line, depth: int): string =
  ## what a function passed to map … returns for an argument of type argT: proc (w: string): int = …,
  ## w => w.len (sugar), or a proc's name
  let t = fn.strip
  if t.startsWith("proc"):
    var sig = t
    let eq = nxFindTop(t, '=')
    if eq > 0: sig = t[0 ..< eq]
    return nxProcRet(sig)
  let arrow = t.find("=>")
  if arrow > 0:
    var ps = t[0 ..< arrow].strip.strip(chars = {'(', ')'})
    let body = t[arrow + 2 .. ^1].strip
    var loc = locals
    let names = nxSplitTop(ps, {','})
    if names.len > 0:
      let nm = names[0].split(':')[0].strip
      let declared = if ':' in names[0]: names[0].split(':')[1].strip else: argT
      loc.add NxSym(name: nm, kind: nxParam, typ: declared, line: line)
    return nxTypeOfExpr(f, sc, loc, body, line, depth + 1).typ
  if t.allCharsInSet(IdentChars): return nxCallType(f, sc, locals, t, argT, line, depth, @[], 1)
  ""

proc nxTemplateCall*(f: NxFile, sc: NxScope, locals: seq[NxSym], name, recvType, argText: string, line,
                    depth: int): (bool, string) =
  ## the standard library's templates and higher-order procs whose result depends on code passed to them:
  ## s.mapIt(it.len) is a seq[int], s.map(w => w.len) too
  const Known = ["mapIt", "filterIt", "anyIt", "allIt", "countIt", "sortedByIt", "newSeqWith", "map", "filter",
                 "zip", "concat", "deduplicate", "foldl", "foldr", "applyIt", "keepItIf"]
  if name notin Known: return (false, "")
  var args = nxSplitTop(argText, {','})
  var recvT = recvType
  if recvT.len == 0:
    if args.len == 0: return (false, "")
    recvT = nxTypeOfExpr(f, sc, locals, args[0], line, depth + 1).typ
    args = args[1 .. ^1]
  let el = nxElemType(recvT)
  let it = NxSym(name: "it", kind: nxLet, typ: el, line: line)
  proc opType(k: int): string =
    if k >= args.len or el.len == 0: return ""
    nxTypeOfExpr(f, sc, locals & @[it], args[k], line, depth + 1).typ
  case name
  of "mapIt":
    let t = opType(args.high)
    (true, (if t.len > 0: "seq[" & t & "]" else: ""))
  of "filterIt", "sortedByIt", "filter", "deduplicate", "concat":
    (true, (if el.len > 0: "seq[" & el & "]" else: ""))
  of "anyIt", "allIt": (true, "bool")
  of "countIt": (true, "int")
  of "applyIt", "keepItIf": (true, "")
  of "newSeqWith":
    let t = if args.len > 0: nxTypeOfExpr(f, sc, locals, args[^1], line, depth + 1).typ else: ""
    (true, (if t.len > 0: "seq[" & t & "]" else: ""))
  of "map":
    if args.len == 0: return (false, "")
    let t = nxLambdaType(f, sc, locals, args[^1], el, line, depth)
    (true, (if t.len > 0: "seq[" & t & "]" else: ""))
  of "zip":
    if args.len == 0: return (false, "")
    let e2 = nxElemType(nxTypeOfExpr(f, sc, locals, args[0], line, depth + 1).typ)
    (true, (if el.len > 0 and e2.len > 0: "seq[(" & el & ", " & e2 & ")]" else: ""))
  of "foldl", "foldr":
    if args.len >= 2: return (true, nxTypeOfExpr(f, sc, locals, args[1], line, depth + 1).typ)
    (true, el)
  else: (false, "")

var nxAutoCache*: Table[string, string]     # "path:line:stamp" → what an `auto` routine returns

proc nxInferAuto*(fp: NxFile, s: NxSym, depth: int): string =
  ## an `auto` routine's result type, from its body: a one-line `= expr`, `result = …`, `return …`, or the
  ## last expression in it
  if depth > 6 or fp == nil: return ""
  let key = fp.path & ":" & $s.line & ":" & fp.stamp
  if key in nxAutoCache: return nxAutoCache[key]
  nxAutoCache[key] = ""                                # (a routine that calls itself: no answer, no loop)
  var ls: seq[string]
  try:
    ls = if nxBufferLines != nil and nxBufferStamp(fp.path).len > 0: nxBufferLines(fp.path) else: readFile(fp.path).split('\n')
  except CatchableError: return ""
  if s.line >= ls.len: return ""
  var cands: seq[(int, int, string)]                 # (line, column, expression)
  let hdr = ls[s.line]
  let pe = hdr.find('(')
  let close = if pe >= 0: nxMatchClose(hdr, pe) else: -1
  let eq = nxFindTop(hdr, '=', max(0, close + 1))
  if eq > 0 and hdr[eq + 1 .. ^1].strip.len > 0 and (eq + 1 >= hdr.len or hdr[eq + 1] != '='):
    cands.add (s.line, eq + 1, hdr[eq + 1 .. ^1].strip)
  else:
    var lastExpr = (-1, 0, "")
    for l in s.line + 1 .. min(s.endLine, ls.high):
      let raw = ls[l]
      let t = raw.strip
      if t.len == 0 or t.startsWith("#"): continue
      let c = raw.len - raw.strip(trailing = false).len
      if t.startsWith("result = "): cands.add (l, c + 9, t[9 .. ^1])
      elif t.startsWith("return "): cands.add (l, c + 7, t[7 .. ^1])
      else: lastExpr = (l, c, t)
    if cands.len == 0 and lastExpr[0] >= 0:
      let t = lastExpr[2]
      let w = t.split({' ', '(', ':'})[0]
      if w notin ["for", "while", "if", "when", "case", "let", "var", "const", "discard", "echo", "doAssert",
                  "assert", "raise", "break", "continue", "block", "try", "of", "else", "elif", "except", "finally"] and
         nxFindTop(t, '=') < 0:
        cands.add lastExpr
  let sc = nxScope(fp)
  for (l, c, e) in cands:
    let t = nxTypeOfExpr(fp, sc, nxLocals(fp, ls, l, c), e, l, depth + 1).typ
    if t.len > 0 and t != "auto":
      nxAutoCache[key] = t
      return t
  ""

proc nxTypeOfExpr*(f: NxFile, sc: NxScope, locals: seq[NxSym], e: string, line, depth: int): NxVal =
  if depth > 16: return
  var s = e.strip
  if s.len == 0: return
  if s.startsWith("if ") or s.startsWith("when ") or s.startsWith("case ") or s.startsWith("try:") or
     s.startsWith("block:"):
    # if c: a else: b — the first branch's value (case k: a …, try: a except: b, block: a …: one written
    # for a value that goes on in the lines below)
    let fl2 = nxFlat(s)
    let colon = fl2.find(":")
    if colon > 0 and colon + 1 < s.len and s[colon + 1] == ' ':
      var e = s.len
      for stop in [" elif ", " else:", " except", " …", " finally:"]:
        let k = fl2.find(stop, colon)
        if k > 0 and k < e: e = k
      return nxTypeOfExpr(f, sc, locals, s[colon + 1 ..< e], line, depth + 1)
    return
  # await x, waitFor x: what the Future holds
  for kw in ["await ", "waitFor "]:
    if s.startsWith(kw):
      let ft = nxTypeOfExpr(f, sc, locals, s[kw.len .. ^1], line, depth + 1).typ
      let st = nxStripMods(ft)
      if nxBaseName(st) in ["Future", "FutureEx", "InternalRaisesFuture"]:
        let a = nxTypeArgs(st)
        return NxVal(typ: (if a.len > 0: a[0] else: "void"))
      return NxVal(typ: ft)       # (in a {.multisync.} proc the plain call is the one that runs)
  if s.startsWith("%*"): return NxVal(typ: "JsonNode")
  # top-level operators decide the type before anything else
  let fl = nxFlat(s)
  for op in [" == ", " != ", " <= ", " >= ", " < ", " > ", " not ", " in ", " notin ", " is ", " isnot ", " of "]:
    if op in fl: return NxVal(typ: "bool")
  if fl.startsWith("not "): return NxVal(typ: "bool")
  for op in [" and ", " or ", " xor "]:
    let k = fl.find(op)
    if k > 0:
      # bool, or bits of an integer: flags and 0xFF
      let lt = nxTypeOfExpr(f, sc, locals, s[0 ..< k], line, depth + 1).typ
      return NxVal(typ: (if nxResolveAlias(sc, lt) in NxInts: lt else: "bool"))
  if s[0] == '$' or " & " in fl:
    if s[0] == '$': return NxVal(typ: "string")
    let ak = fl.find(" & ")
    let lt = nxTypeOfExpr(f, sc, locals, s[0 ..< ak], line, depth + 1)
    if lt.typ.len > 0: return (if nxStripMods(lt.typ) == "char": NxVal(typ: "string") else: lt)
    # (the left side unknown: the right one says whether these are strings or sequences)
    let rt = nxTypeOfExpr(f, sc, locals, s[ak + 3 .. ^1], line, depth + 1).typ
    let rb = nxBaseName(rt)
    if rb in ["seq", "array"]: return NxVal(typ: "seq[" & nxElemType(rt) & "]")
    if rb in ["string", "char", "cstring"] or s[0] == '"' or s[ak + 3 .. ^1].strip.startsWith("\""):
      return NxVal(typ: "string")
    return
  block ops:
    # a + b, t1 - t2 …: numbers keep the left operand's type (an untyped literal takes the other side's: 5 * x;
    # Natural - 1 is an int); other types: what their operator returns
    var k = -1
    var op = ""
    var opLen = 0
    for cand in [" + ", " - ", " * ", " div ", " mod ", " shl ", " shr ", " ^ ", " % "]:
      let q = fl.find(cand)
      if q > 0 and (k < 0 or q < k):
        k = q
        op = cand.strip
        opLen = cand.len
    if k < 0 and s[0] notin {'"', '\''}:
      # written without spaces: len-1, 60*60, 2^18
      for q in 1 ..< fl.len - 1:
        if fl[q] in {'+', '-', '*', '^'} and (nxIsIdent(fl[q - 1]) or fl[q - 1] in {')', ']'}) and
           (nxIsIdent(fl[q + 1]) or fl[q + 1] in {'(', '[', '\''}):
          if fl[q] in {'+', '-'} and fl[q - 1] in {'e', 'E'} and q >= 2 and fl[q - 2] in Digits: continue   # 1e-5
          k = q
          op = $fl[q]
          opLen = 1
          break
    if k > 0:
      let leftE = s[0 ..< k].strip
      let lt = nxTypeOfExpr(f, sc, locals, leftE, line, depth + 1).typ
      let lr = nxResolveAlias(sc, nxStripMods(lt))
      if lt.len > 0 and lr notin NxInts and lr notin NxFloats and lr notin ["char", "string", "cstring"]:
        # (the right operand picks among the overloads: Time - Duration is a Time, Time - Time a Duration)
        let rt = nxCallType(f, sc, locals, op, lt, line, depth, @[], 2, @[s[k + opLen .. ^1].strip])
        if rt.len > 0: return NxVal(typ: rt)
      if lr in ["string", "cstring"] and op == "%": return NxVal(typ: "string")     # "$1 is $2" % [a, b]
      if lr in NxInts or lr in NxFloats or lr == "char":
        var t = nxStripMods(lt)
        let rightE = s[k + opLen .. ^1].strip
        if leftE.len > 0 and leftE[0] in Digits and leftE.allCharsInSet(Digits + {'_'}):
          # 5 * x: x's type
          let rt = nxTypeOfExpr(f, sc, locals, rightE, line, depth + 1).typ
          let rr = nxResolveAlias(sc, nxStripMods(rt))
          if rr in NxInts or rr in NxFloats: t = nxStripMods(rt)
        elif rightE.len > 0 and not rightE.allCharsInSet(Digits + {'_', '.'}) and lr != "char":
          # a * b of two number types: the wider one (uint8 * uint32 is a uint32, int * float a float) — a bare
          # literal on the right takes the left's type
          let rt = nxTypeOfExpr(f, sc, locals, rightE, line, depth + 1).typ
          let rr = nxResolveAlias(sc, nxStripMods(rt))
          proc width(x: string): int =
            case x
            of "int8", "uint8", "byte": 8
            of "int16", "uint16": 16
            of "int32", "uint32", "float32", "cint", "cuint", "cfloat": 32
            else: 64
          if (rr in NxFloats and lr notin NxFloats) or
             (((rr in NxInts and lr in NxInts) or (rr in NxFloats and lr in NxFloats)) and width(rr) > width(lr)):
            t = nxStripMods(rt)
        if t in ["Natural", "Positive"] or nxResolveAlias(sc, t) == "range": t = "int"     # (a range's sums are its base type's)
        elif lr == "char" and op in ["+", "-"]: t = "char"
        return NxVal(typ: t)
  if s[0] notin {'[', '(', '{', '@'}:
    let rk = nxFindRange(s)
    if rk > 0:
      # a .. b, a ..< b: a slice of the ends' type
      let lt = nxTypeOfExpr(f, sc, locals, s[0 ..< rk], line, depth + 1).typ
      return NxVal(typ: (if lt.len > 0: "HSlice[" & lt & ", " & lt & "]" else: ""))
    let dk = fl.find(" / ")
    if dk > 0:
      # integers divided with / give a float (div keeps them integers); a path joined with / stays a string
      let lt = nxTypeOfExpr(f, sc, locals, s[0 ..< dk], line, depth + 1).typ
      let rt = nxResolveAlias(sc, lt)
      if rt in NxInts: return NxVal(typ: "float")
      if rt in NxFloats or rt == "string": return NxVal(typ: lt)
  if s.startsWith("cast["):
    let ce = nxMatchClose(s, 4)
    if ce > 4: return NxVal(typ: s[5 ..< ce].strip)
  if s.startsWith("case ") or s.startsWith("block"): return
  if s.len > 1 and s[0] in {'-', '+', '~', '!', '?', '^', '%'} and s[1] notin {' ', '=', '"'} and
     (s[1] notin Digits):
    # -m, ~flags: a prefix operator — a number keeps its type; another type, what its operator returns
    var k = 0
    while k < s.len and s[k] in NxOpChars: inc k
    let rest = s[k .. ^1]
    if rest.len > 0 and nxFindTop(rest, ' ') < 0:
      let rt = nxTypeOfExpr(f, sc, locals, rest, line, depth + 1).typ
      if rt.len > 0:
        let rr = nxResolveAlias(sc, nxStripMods(rt))
        if rr in NxInts or rr in NxFloats: return NxVal(typ: nxStripMods(rt))
        let ct = nxCallType(f, sc, locals, s[0 ..< k], rt, line, depth, @[], 1, @[])
        if ct.len > 0: return NxVal(typ: ct)
  # literals
  if s[0] == '"' or s.startsWith("r\"") or s.startsWith("fmt\"") or s.startsWith("&\""):
    if s.endsWith("\""): return NxVal(typ: "string")
  if s[0] == '\'': return NxVal(typ: "char")
  if s[0] in Digits or (s[0] == '-' and s.len > 1 and s[1] in Digits):
    # 5, 1.5, 2e3, 0xFF, 5'i64, 2u8, 1.5'f32 … (a literal followed by more is an expression: below)
    var j = (if s[0] == '-': 1 else: 0)
    var isFloat = false
    let based = j + 1 < s.len and s[j] == '0' and s[j + 1] in {'x', 'X', 'b', 'B', 'o', 'O', 'c', 'C'}
    if based:
      j += 2
      while j < s.len and (s[j] in HexDigits or s[j] == '_'): inc j
    else:
      while j < s.len and (s[j] in Digits or s[j] == '_'): inc j
      if j + 1 < s.len and s[j] == '.' and s[j + 1] in Digits:
        isFloat = true
        inc j
        while j < s.len and (s[j] in Digits or s[j] == '_'): inc j
      if j < s.len and s[j] in {'e', 'E'} and j + 1 < s.len and s[j + 1] in Digits + {'+', '-'}:
        isFloat = true
        inc j
        if s[j] in {'+', '-'}: inc j
        while j < s.len and s[j] in Digits: inc j
    var k = j
    let apos = k < s.len and s[k] == '\''
    if apos: inc k
    let sufStart = k
    while k < s.len and s[k] in IdentChars: inc k
    if k == s.len:
      let suf = s[sufStart ..< k].toLowerAscii
      let t = case suf
        of "": (if isFloat: "float" else: "int")
        of "i8": "int8"
        of "i16": "int16"
        of "i32": "int32"
        of "i64": "int64"
        of "u": "uint"
        of "u8": "uint8"
        of "u16": "uint16"
        of "u32": "uint32"
        of "u64": "uint64"
        of "f", "f32": "float32"
        of "d", "f64": "float64"
        of "f128": "float128"
        else: (if apos: s[sufStart ..< k] else: "")      # a user's literal: 12'big
      if t.len > 0: return NxVal(typ: t)
  if s in ["true", "false"]: return NxVal(typ: "bool")
  if s == "nil": return
  if s.startsWith("@["):
    let ce = nxMatchClose(s, 1)
    if ce == s.high:
      let inner = s[2 ..< ce].strip
      if inner.len == 0: return NxVal(typ: "seq")
      let first = nxSplitTop(inner, {','})[0]
      let et = nxTypeOfExpr(f, sc, locals, first, line, depth + 1).typ
      return NxVal(typ: "seq[" & et & "]")
  if s[0] == '[':
    let ce = nxMatchClose(s, 0)
    if ce == s.high:
      let items = nxSplitTop(s[1 ..< ce], {','})
      var n = 0
      for it in items:
        if it.strip.len > 0: inc n
      let et = nxTypeOfExpr(f, sc, locals, items[0], line, depth + 1).typ
      return NxVal(typ: (if et.len > 0: "array[" & $n & ", " & et & "]" else: ""))
  if s[0] == '{':
    let ce = nxMatchClose(s, 0)
    if ce == s.high:
      let first = nxSplitTop(s[1 ..< ce], {','})[0]
      let kc = nxFindTop(first, ':')
      if kc >= 0:
        # {"a": 1, "b": 2}: an array of (key, value) pairs, as toTable takes it
        var n = 0
        for it in nxSplitTop(s[1 ..< ce], {','}):
          if it.strip.len > 0: inc n
        let kt = nxTypeOfExpr(f, sc, locals, first[0 ..< kc], line, depth + 1).typ
        let vt = nxTypeOfExpr(f, sc, locals, first[kc + 1 .. ^1], line, depth + 1).typ
        return NxVal(typ: (if kt.len > 0 and vt.len > 0: "array[" & $n & ", (" & kt & ", " & vt & ")]" else: "array"))
      let rk = nxFindRange(first)             # {'0'..'9'}: a set of chars
      let et = nxTypeOfExpr(f, sc, locals, (if rk > 0: first[0 ..< rk] else: first), line, depth + 1).typ
      return NxVal(typ: (if et.len > 0: "set[" & et & "]" else: ""))
  if s[0] == '(':
    let ce = nxMatchClose(s, 0)
    if ce == s.high:
      let inner = s[1 ..< ce]
      let parts = nxSplitTop(inner, {','})
      let ii = inner.strip
      for kw in ["if ", "when ", "case ", "block", "try"]:
        if ii.startsWith(kw): return nxTypeOfExpr(f, sc, locals, ii, line, depth + 1)
      var named = false                 # (x: 1, y: 2): a name before the first colon
      let c0 = nxFindTop(parts[0], ':')
      if c0 > 0:
        let nm = parts[0][0 ..< c0].strip
        named = nm.len > 0 and nm.allCharsInSet(IdentChars + {'`'})
      if parts.len > 1 or named:
        # a tuple: (a, b) or (x: 1, y: 2)
        var ts: seq[string]
        for p in parts:
          let c = if named: nxFindTop(p, ':') else: -1
          let t = nxTypeOfExpr(f, sc, locals, (if c >= 0: p[c + 1 .. ^1] else: p), line, depth + 1).typ
          ts.add (if c >= 0: p[0 ..< c].strip & ": " & t else: t)
        return NxVal(typ: (if named: "tuple[" & ts.join(", ") & "]" else: "(" & ts.join(", ") & ")"))
      return nxTypeOfExpr(f, sc, locals, inner, line, depth + 1)
  # a chain: name(.name | (args) | [idx])*
  var i = 0
  var v: NxVal
  if s[0] in {'"', '\'', '@', '[', '(', '{'} and not s.startsWith("\"\"\""):
    # a literal or a bracketed expression in front of a call: "a,b".split(','), @[3, 1].sorted, (a + b).abs
    var pe = -1
    if s[0] == '"':
      var j = 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      if j < s.len: pe = j + 1
    elif s[0] == '\'':
      let ce = nxCharEnd(s, 0)
      if ce > 0: pe = ce + 1
    elif s[0] == '@':
      if s.len > 1 and s[1] == '[' and nxMatchClose(s, 1) > 0: pe = nxMatchClose(s, 1) + 1
    elif nxMatchClose(s, 0) > 0: pe = nxMatchClose(s, 0) + 1
    if pe <= 0 or pe >= s.len or s[pe] notin {'.', '['}: return
    v = nxTypeOfExpr(f, sc, locals, s[0 ..< pe], line, depth + 1)
    if v.typ.len == 0: return
    i = pe
  elif s[0] in Digits:
    # 5.Natural, 2.5.float32, 10'i64.abs: the number, then the rest
    var pe = 0
    while pe < s.len and (s[pe] in HexDigits + {'_', 'x', 'X', 'o', 'O'}): inc pe
    if pe + 1 < s.len and s[pe] == '.' and s[pe + 1] in Digits:
      inc pe
      while pe < s.len and (s[pe] in Digits + {'_'}): inc pe
    if pe < s.len and s[pe] == '\'':
      inc pe
      while pe < s.len and s[pe] in IdentChars: inc pe
    if pe >= s.len or s[pe] != '.' or pe + 1 >= s.len or s[pe + 1] notin IdentStartChars: return
    v = nxTypeOfExpr(f, sc, locals, s[0 ..< pe], line, depth + 1)
    if v.typ.len == 0: return
    i = pe
  else:
    let (nm, ni) = nxName(s, 0)
    if nm.len == 0: return
    i = ni
    v = nxTypeOfName(f, sc, locals, nm, line, depth + 1)
  var recvForCall = ""
  var genArgs: seq[string]
  while i < s.len:
    while i < s.len and s[i] == ' ': inc i
    if i >= s.len: break
    let c = s[i]
    if c == '(':
      let ce = nxMatchClose(s, i)
      if ce < 0: return NxVal()
      if v.typeName.len > 0:
        v = NxVal(typ: v.typeName)             # Foo(...) builds a Foo (or converts to it)
      elif v.routine.len > 0:
        var recv = recvForCall
        let argText = s[i + 1 ..< ce]
        if recv.len == 0:
          # the first argument picks the overload and binds generic parameters:  some(5) → Option[int]
          let ps = nxSplitTop(argText, {','})
          if ps.len > 0 and ps[0].strip.len > 0 and nxFindTop(ps[0], '=') < 0:
            recv = nxTypeOfExpr(f, sc, locals, ps[0], line, depth + 1).typ
        let (known, kt) = nxTemplateCall(f, sc, locals, v.routine, recvForCall, argText, line, depth)
        if known:
          v = NxVal(typ: kt)
        elif v.routine == "toSeq" and argText.strip.len > 0:
          let el = nxIterVarType(f, sc, locals, argText, 0, 1, line, depth + 1)
          v = NxVal(typ: (if el.len > 0: "seq[" & el & "]" else: "seq"))
        else:
          var nargs = (if recvForCall.len > 0: 1 else: 0)
          var rest: seq[string]             # the arguments after the first
          for a in nxSplitTop(argText, {','}):
            if a.strip.len > 0:
              inc nargs
              if nargs > 1: rest.add a.strip
          v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recv, line, depth, genArgs, nargs, rest))
      elif v.typ.len > 0:
        # calling a proc-typed value (or an alias of a proc type): what it returns
        var pt = nxStripMods(v.typ)
        if not pt.startsWith("proc"):
          for r in nxTypeSyms(sc, nxBaseName(pt)):
            if r.sym.typ.strip.startsWith("proc"): pt = r.sym.typ.strip
            break
        v = NxVal(typ: (if pt.startsWith("proc"): nxProcRet(pt) else: ""))
      i = ce + 1
      recvForCall = ""
      genArgs.setLen(0)
    elif c == '[':
      let ce = nxMatchClose(s, i)
      if ce < 0: return NxVal()
      if v.routine.len > 0:
        # a.unsafe[x, y]: a routine without generic parameters is called first, then indexed
        var anyGeneric = false
        for r in nxLookup(sc, v.routine):
          if r.sym.kind in NxRoutineKinds and r.sym.generics.len > 0: anyGeneric = true
        if not anyGeneric:
          v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recvForCall, line, depth, @[],
                                    (if recvForCall.len > 0: 1 else: 0)))
          recvForCall = ""
          if v.typ.len == 0: return NxVal()
      if v.routine.len > 0:
        genArgs.setLen(0)                      # explicit generic arguments: newSeq[int]()
        for a in nxSplitTop(s[i + 1 ..< ce], {','}): genArgs.add a.strip
      elif v.typeName.len > 0: discard         # Foo[int](…)
      else:
        let inner = s[i + 1 ..< ce].strip
        let tt = nxTupleTypes(v.typ)
        if inner.len == 0:
          # p[] — what a ref or ptr points to
          let st = nxStripMods(v.typ)
          var nt = st
          if v.typ.strip.startsWith("ref ") or v.typ.strip.startsWith("ptr "): nt = st
          else:
            for r in nxTypeSyms(sc, nxBaseName(st)):
              let d = r.sym.typ.strip
              if d.startsWith("ref ") or d.startsWith("ptr "):
                let target = nxStripMods(d)
                if not target.startsWith("object"): nt = nxSubst(target, nxTypeBindings(sc, st))
              break
          v = NxVal(typ: nt)
        elif nxFindRange(inner) >= 0: discard    # a slice keeps the type: s[1 .. 3]
        elif tt.len > 0 and inner.len > 0 and inner.allCharsInSet(Digits):
          let k = parseInt(inner)              # t[1] of a tuple
          v = NxVal(typ: (if k < tt.len: tt[k] else: ""))
        else:
          var el = nxElemType(v.typ)
          if el.len == 0 and v.typ.len > 0:
            let ex = nxExpandAlias(sc, v.typ)
            if ex.len > 0: el = nxElemType(ex)
          if el.len == 0 and v.typ.len > 0: el = nxCallType(f, sc, locals, "[]", v.typ, line, depth)   # its own `[]`
          v = NxVal(typ: el)
      i = ce + 1
    elif c == '{':
      # x{key}: the type's `{}` accessor (JsonNode{"a", "b"})
      let ce = nxMatchClose(s, i)
      if ce < 0: return NxVal()
      v = NxVal(typ: (if v.typ.len > 0: nxCallType(f, sc, locals, "{}", v.typ, line, depth) else: ""))
      i = ce + 1
    elif c == '.':
      inc i
      let (m, mi) = nxName(s, i)
      if m.len == 0: return NxVal()
      i = mi
      # a pending routine without parentheses is called first (command syntax)
      if v.routine.len > 0:
        v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recvForCall, line, depth, genArgs,
                                  (if recvForCall.len > 0: 1 else: 0)))
        genArgs.setLen(0)
      if v.module.len > 0:
        var got: seq[NxRef]
        var seen: HashSet[string]
        nxExports(v.module, 0, seen, got)
        var nv = NxVal()
        for r in got:
          if nxNorm(r.sym.name) == nxNorm(m):
            case r.sym.kind
            of nxType: nv = NxVal(typeName: r.sym.name)
            of NxRoutineKinds: nv = NxVal(routine: r.sym.name)
            of nxConst, nxLet, nxVar: nv = NxVal(typ: r.sym.typ)
            of nxEnumVal: nv = NxVal(typ: r.sym.owner)
            else: discard
            break
        v = nv
        recvForCall = ""
      elif v.typeName.len > 0:
        # Enum.value, or a routine taking typedesc
        var nv = NxVal()
        for r in nxLookup(sc, m):
          if r.sym.kind == nxEnumVal and r.sym.owner == v.typeName: nv = NxVal(typ: v.typeName)
          elif r.sym.kind in NxRoutineKinds and nv.typ.len == 0:
            nv = NxVal(routine: m)
            recvForCall = "typedesc[" & v.typeName & "]"
        v = nv
      elif v.typ.len > 0:
        var found = false
        let st = nxStripMods(v.typ)
        if st.startsWith("tuple[") and st.endsWith("]"):
          for p in nxParseParams(st[6 ..< st.high]):
            if nxNorm(p.name) == nxNorm(m):
              v = NxVal(typ: p.typ)
              found = true
              break
          if found:
            continue
        var bt = v.typ
        if nxTypeArgs(nxStripMods(bt)).len == 0:
          let ex = nxExpandAlias(sc, bt)            # HttpClient = HttpClientBase[Socket]: socket is a Socket
          if ex.len > 0: bt = ex
        for fr in nxFields(sc, bt):
          if nxNorm(fr.sym.name) == nxNorm(m) and nxVisible(f, fr):     # (a private field of another module: its proc)
            v = NxVal(typ: nxSubst(fr.sym.typ, nxTypeBindings(sc, bt)))
            found = true
            break
        if not found:
          var isType = false
          if not (i < s.len and s[i] == '('):
            for r in nxLookup(sc, m):
              if r.sym.kind == nxType:
                isType = true                  # x.int, fd.AsyncFD: a conversion
              break
          if isType:
            v = NxVal(typ: m)
            recvForCall = ""
          else:
            recvForCall = v.typ
            v = NxVal(routine: m)
      else:
        # (the receiver's type is not known: when every `m` returns the same type, that is the answer)
        let cr = nxCommonRet(sc, m)
        if cr.len == 0: return NxVal()
        v = NxVal(typ: cr)
        if i < s.len and s[i] == '(':
          let ce = nxMatchClose(s, i)
          if ce < 0: return NxVal()
          i = ce + 1
    elif c == '"' and v.routine.len > 0 and i > 0 and s[i - 1] != ' ':
      # headers.getOrDefault"Location", fmt"…": a call with a string
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      let recv = if recvForCall.len > 0: recvForCall else: "string"
      v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recv, line, depth, genArgs,
                                (if recvForCall.len > 0: 2 else: 1)))
      recvForCall = ""
      genArgs.setLen(0)
      i = j + 1
    else: break
  let opWord = if i < s.len and i > 0 and s[i - 1] == ' ': nxName(s, i)[0] else: ""
  if opWord in ["div", "mod", "shl", "shr", "and", "or", "xor"]:
    # s.len div 2: the left operand's type
    if v.routine.len > 0:
      v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recvForCall, line, depth, genArgs,
                                (if recvForCall.len > 0: 1 else: 0)))
    return v
  if opWord notin ["in", "notin", "is", "isnot", "of", "as", "not"] and i < s.len and i > 0 and s[i - 1] == ' ' and
     s[i] in IdentChars + {'"', '\'', '@'} and (v.typeName.len > 0 or v.routine.len > 0):
    # command syntax: BiggestUInt 1, newSeq 3, readFile path …
    if v.typeName.len > 0: return NxVal(typ: v.typeName)
    let args = nxSplitTop(s[i .. ^1], {','})
    let recv = if recvForCall.len > 0: recvForCall
               else: nxTypeOfExpr(f, sc, locals, args[0], line, depth + 1).typ
    return NxVal(typ: nxCallType(f, sc, locals, v.routine, recv, line, depth, genArgs,
                                 args.len + (if recvForCall.len > 0: 1 else: 0)))
  if v.routine.len > 0 and i >= s.len and recvForCall.len > 0:
    v = NxVal(typ: nxCallType(f, sc, locals, v.routine, recvForCall, line, depth, genArgs, 1))
  v

proc nxReceiver*(line: string, dot: int): string =
  ## the expression in front of the `.` at `dot`: foo, foo.bar(1)[0], "text", Foo(x: 1) …
  var i = dot - 1
  while i >= 0:
    let c = line[i]
    if nxIsIdent(c) or c == '.': dec i
    elif c in {')', ']', '}'}:
      let open = case c
        of ')': '('
        of ']': '['
        else: '{'
      var depth = 0
      var j = i
      while j >= 0:
        if line[j] == c: inc depth
        elif line[j] == open:
          dec depth
          if depth == 0: break
        dec j
      if j < 0: break
      i = j - 1
      if i >= 0 and line[i] == '@': dec i
    elif c == '"':
      var j = i - 1
      while j >= 0 and line[j] != '"': dec j
      if j < 0: break
      i = j - 1
    elif c == '\'':
      var j = i - 1
      while j >= 0 and line[j] != '\'': dec j
      if j < 0: break
      i = j - 1
    else: break
  line[i + 1 ..< dot].strip
