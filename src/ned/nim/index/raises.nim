# ── exceptions: what a routine can raise, as the engine works it out — its raise statements and the routines it calls
#    (their {.raises.}, or what they can raise in turn: recursively, a cycle cut), less what a `try … except` around
#    them catches. Only when the engine is sure of every call in the body: an unknown name, a proc variable, a method,
#    a macro, a template or generic routine whose calls depend on its arguments' types → not known (no answer rather
#    than a wrong one). Defects are not listed, as in the compiler's effects ──

type
  NxExc* = object
    name*: string              # the exception type, as declared
    anc*: seq[string]          # its base types, normalized, nearest first (… CatchableError, Exception, RootObj)
  NxRaises* = object
    known*: bool
    excs*: seq[NxExc]
    why*: string               # (not known) what stopped the engine
    cut*: bool                 # (not known) it ran out of time: asking again may tell

  NxRsCtx = object
    busy: seq[string]          # the routines being worked out (a call back to one of them: cut)
    steps, limit: int          # work done, and allowed, in this request
    cut: bool                  # out of steps: the answer is not kept
    deps: seq[HashSet[string]] # the files each routine being worked out read (for the cache)
    stamps: Table[string, string]
    why: string                # what stopped it (the first thing)
    deadline: MonoTime         # (a request has this long: past it, cut)
    cycleAt: int               # the outermost routine (index in busy) a cycle came back to: those above it are
                               # not kept (their answer waits for its)
    fx: bool                   # side effects instead of exceptions (effects.nim): a side effect is the exception
                               # NxFxMark — a global touched, a routine with side effects called
    impure: bool               # (fx) a side effect found in the routine being read: the rest of it is not read
    modFiles: Table[string, seq[string]]   # (fx) file → the files of its module (include), looked up once a request
    fwdFresh: HashSet[string]  # (fx) the modules whose forward declarations were looked at in this request
    scopes: Table[string, NxScope]   # file → its scope, made (or checked) once a request: checking it stats every
                                     # file it reads, and a routine of a big module asks again and again

  NxRsConv = object            # a converter the body can see that does something (raises, has side effects, or
                               # the engine cannot tell): the compiler applies it, unwritten, where a value of a type
                               # it takes goes where its result type is wanted
    r: NxRef
    eff: NxRaises              # what it raises (or its side effect), known or not
    src: seq[string]           # the types it takes (a union or type class: its members)
    anySrc: bool               # it takes anything (generic, a concept): every value may be converted
    dest: string               # what it makes
    anyDest: bool              # (generic: what it makes depends on what it takes)

  NxRsLine = object           # a statement of a body: its code (lines that go on joined), where it is
    ind: int
    text: string
    line, last, col: int

  NxRsBody = object            # the body being read
    f: NxFile
    sc: NxScope
    lr: NxLinesRef             # (its file's lines: w.lines)
    rs: NxSym
    localNames: HashSet[string]
    tainted: HashSet[string]   # (a generic routine, a template) names whose type is only known where it is used
    genNames: HashSet[string]  # its generic parameters (type names inside it)
    excepts: seq[seq[string]]  # the types caught by the except branches around (innermost last): a bare raise
    convs: seq[NxRsConv]       # the converters it can see that do something (none: the usual case)
    retConv: bool              # (and one of them makes what the routine gives back: return, yield, its last value)

const NxFxMark* = "side effect"   ## (fx) the "exception" a side effect is

var nxRaisesCache: Table[string, (NxRaises, seq[(string, string)])]   # routine → what it raises, the files read

template lines(w: NxRsBody): untyped = w.lr.lines

const
  NxRsBuiltinElems = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte",
                      "float", "float32", "float64", "bool", "char", "string", "cstring", "Natural", "Positive",
                      "BiggestInt", "BiggestFloat", "cint", "cuint", "clong", "csize_t", "pointer", "Rune"]

proc nxExcList*(r: NxRaises): string =
  ## "IOError, OSError"
  var names: seq[string]
  for e in r.excs: names.add e.name
  names.join(", ")

proc nxRsAdd(dst: var seq[NxExc], e: NxExc) =
  ## an exception raised: once each, Defects left out
  if "Defect" in e.anc or e.name == "Defect": return
  for x in dst:
    if nxNorm(x.name) == nxNorm(e.name): return
  dst.add e

func nxRsCatches(e: NxExc, caught: string): bool =
  ## an `except caught:` takes `e` (it, or a type derived from it)
  let c = nxNorm(caught)
  nxNorm(e.name) == c or c in e.anc

# ── a file open in the editor changes with every key: its routines are kept apart, each by its own text — a unit,
#    "\x01" & path & "\x02" & name & "\x02" & its header's hash (& which one of the same header). A unit's stamp is
#    its text's hash and the file's outline's (all that is not inside a routine's body: declarations, imports,
#    headers, pushes). An edit inside one body leaves what the others worked out ──

type NxRsUnitTab = object
  stamp: string                        # the file's stamp they were made for
  byLine: Table[int, string]           # a routine's line → its unit
  now: Table[string, string]           # unit → its stamp

var nxRsUnitTabs: Table[string, NxRsUnitTab]

proc nxRsOpenFile(path: string): bool =
  nxBufferStamp != nil and path.len > 0 and nxBufferStamp(path).len > 0

proc nxRsUnitTabOf(path, st: string): bool =
  ## the units of an open file as it is now (st: its stamp) — false when it cannot be read
  if path in nxRsUnitTabs and nxRsUnitTabs[path].stamp == st: return true
  let f = nxLoad(path)
  if f == nil: return false
  let lines = nxLayLinesRef(path).lines
  var tab = NxRsUnitTab(stamp: st)
  var inBody = newSeq[bool](lines.len)
  var bodies: seq[(int, string, Hash)]          # (line, unit, its text's hash)
  var seen: CountTable[string]
  for s in f.syms:
    if s.kind notin NxRoutineKinds or s.made or s.line >= lines.len: continue
    let e = min(max(s.endLine, s.line), lines.high)
    var h: Hash = 0
    for l in s.line .. e:
      h = h !& hash(lines[l])
      if l > s.line: inBody[l] = true
    let base = "\x01" & path & "\x02" & s.name & "\x02" & $hash(nxHeaderLast(lines, s)[0])
    seen.inc base
    bodies.add (s.line, base & "\x02" & $seen[base], !$h)
  var o: Hash = 0
  for l in 0 ..< lines.len:
    if not inBody[l]: o = o !& hash(lines[l])
  let outline = $(!$o)
  for (l, u, h) in bodies:
    tab.byLine[l] = u
    tab.now[u] = $h & "/" & outline
  if nxRsUnitTabs.len > 16: nxRsUnitTabs.clear()
  nxRsUnitTabs[path] = tab
  true

proc nxRsStamp(c: var NxRsCtx, path: string): string =
  ## a file's stamp — or a unit's (a routine of an open file: "" when it is gone)
  if path notin c.stamps:
    if path.len > 0 and path[0] == '\x01':
      let k = path.find('\x02')
      let file = path[1 ..< k]
      var st = c.stamps.getOrDefault(file)
      if st.len == 0:
        st = nxCurStamp(file)
        c.stamps[file] = st
      c.stamps[path] = (if nxRsUnitTabOf(file, st): nxRsUnitTabs[file].now.getOrDefault(path) else: "")
    else: c.stamps[path] = nxCurStamp(path)
  c.stamps[path]

proc nxRsUnit(c: var NxRsCtx, f: NxFile, line: int): string =
  ## the unit of the routine declared at `line` of `f` when the file is open in the editor ("" otherwise)
  if not nxRsOpenFile(f.path): return ""
  let st = nxRsStamp(c, f.path)
  if st.len == 0 or not nxRsUnitTabOf(f.path, st): return ""
  nxRsUnitTabs[f.path].byLine.getOrDefault(line)

proc nxRsDep(c: var NxRsCtx, path: string) =
  if c.deps.len > 0: c.deps[^1].incl path

proc nxRsScope(c: var NxRsCtx, f: NxFile): NxScope =
  ## the scope of file `f`, made or checked once in a request
  result = c.scopes.getOrDefault(f.path)
  if result == nil:
    result = nxScope(f)
    c.scopes[f.path] = result

proc nxRsExc(sc: NxScope, t0: string): (bool, NxExc) =
  ## the exception type written `t0` (ValueError, ref ValueError, an alias of one), with its base types
  var t = t0.strip
  if t.startsWith("ref "): t = t[4 .. ^1].strip
  if t.startsWith("(") and t.endsWith(")"): t = t[1 ..< t.high].strip
  if t.startsWith("ref "): t = t[4 .. ^1].strip
  if t.len == 0 or not t.allCharsInSet(IdentChars + {'.'}): return
  let (r, _) = nxObjectDef(sc, t)
  if r.file == nil or r.sym.kind != nxType: return
  let name = r.sym.name
  if name == "Exception": return (true, NxExc(name: name, anc: @["RootObj"]))
  let anc = nxAncestors(sc, name)     # (from here: system/exceptions.nim's own scope does not see CatchableError)
  if nxNorm("Exception") notin anc: return
  (true, NxExc(name: name, anc: anc))

var nxRsPushCache: Table[string, (string, seq[(int, bool, string)])]
  ## file → (its stamp, where the {.push raises: […].} in force changes: (line, one in force, its list))

proc nxRsPushRaises(f: NxFile, lines: seq[string], line: int): (bool, string) =
  ## a {.push raises: [...].} in force at `line` (and not popped): (there is one, its list)
  let st = nxCurStamp(f.path)
  if f.path notin nxRsPushCache or nxRsPushCache[f.path][0] != st:
    var stack: seq[(bool, string)]
    var marks: seq[(int, bool, string)]
    proc top(): (bool, string) =
      for k in countdown(stack.high, 0):
        if stack[k][0]: return stack[k]
    for l in 0 ..< lines.len:
      let t = lines[l]
      if t.find("{.") < 0: continue
      let c = nxCodeOf(t)
      if c.startsWith("{.push ") or c.startsWith("{.push:"):
        let r = c.find("raises:")
        if r >= 0:
          let a = c.find('[', r)
          let e = if a >= 0: nxMatchClose(c, a) else: -1
          stack.add (if e > a: (true, c[a + 1 ..< e]) else: (false, ""))
        else: stack.add (false, "")
      elif c.startsWith("{.pop"):
        if stack.len > 0: stack.setLen(stack.len - 1)
      else: continue
      let (h, x) = top()
      marks.add (l, h, x)
    if nxRsPushCache.len > 256: nxRsPushCache.clear()
    nxRsPushCache[f.path] = (st, marks)
  for k in countdown(nxRsPushCache[f.path][1].high, 0):
    let (l, h, x) = nxRsPushCache[f.path][1][k]
    if l < line: return (h, x)

proc nxRsDeclared(r: NxRef, lines: seq[string]): (bool, string) =
  ## the routine's own {.raises: [...].} (or one pushed around it — not on a template or macro): (written, its list)
  let p = r.sym.pragmas
  let k = p.find("raises")
  if k >= 0:
    let a = p.find('[', k)
    let e = if a >= 0: nxMatchClose(p, a) else: -1
    if e > a: return (true, p[a + 1 ..< e])
  if r.sym.kind in {nxTemplate, nxMacro}: return
  nxRsPushRaises(r.file, lines, r.sym.line)

proc nxRsBuiltinType(t0: string): bool =
  ## a value whose `$`, `==`, `items` … are the system's own (none of them raises an exception)
  let t = nxStripMods(t0).strip
  if t.len == 0: return false
  if t in NxRsBuiltinElems: return true
  for p in ["seq[", "array[", "set[", "openArray[", "varargs[", "HSlice[", "Slice[", "range[", "UncheckedArray["]:
    if t.startsWith(p) and t.endsWith("]"):
      let args = nxTypeArgs(t)
      if args.len == 0: return false
      if p == "range[": return true
      for a in args[(if p == "array[": 1 else: 0) .. ^1]:
        if not nxRsBuiltinType(a): return false
      return true
  t.startsWith("ptr UncheckedArray[") or t.startsWith("range ")

proc nxRsRoutine(c: var NxRsCtx, r: NxRef, callPath: string, callLine: int): NxRaises
proc nxRsStmt(c: var NxRsCtx, w: var NxRsBody, ls: seq[NxRsLine], i: var int, exc: var seq[NxExc]): bool

func nxRsFail(why: string): NxRaises = NxRaises(known: false, why: why)

func nxFxImpure(why: string): NxRaises =
  ## (fx) a side effect, known
  NxRaises(known: true, excs: @[NxExc(name: NxFxMark)], why: why)

func nxFxHas*(excs: seq[NxExc]): bool =
  for e in excs:
    if e.name == NxFxMark: return true

func nxFxPragma(p, word: string): bool =
  ## is `word` one of the pragmas in `p` (noSideEffect, not a part of another: sideEffect in noSideEffect is not)
  var k = p.find(word)
  while k >= 0:
    let e = k + word.len
    if (k == 0 or not nxIsIdent(p[k - 1])) and (e >= p.len or not nxIsIdent(p[e])): return true
    k = p.find(word, k + 1)
  false

proc nxFxGlobals(sc: NxScope, name: string): int =
  ## (fx) is `name` a module-level variable here (a var, let or threadvar of a module — the compiler's global
  ## state): 0 no · 1 only such variables · 2 those and something else of that name (a routine, a type …)
  var glob, other = false
  for r in nxLookup(sc, name):
    if r.sym.kind in {nxVar, nxLet} and not r.sym.local: glob = true
    else: other = true
  if not glob: 0 elif other: 2 else: 1

proc nxFxNamesGlobal(sc: NxScope, e: string): bool =
  ## (fx) does expression `e` name a module's variable (a parameter's default value: `nc: var T = nc0`)
  var st: NxLexState
  for (a, b) in nxLexRuns(e, st, false):
    if a > 0 and e[a - 1] == '.': continue
    if nxFxGlobals(sc, e[a ..< b]) > 0: return true

proc nxRsListOf(sc: NxScope, list: string): NxRaises =
  ## a written list [IOError, OSError] as exceptions
  result.known = true
  for part in nxSplitTop(list, {','}):
    let x = part.strip
    if x.len == 0: continue
    let (ok, e) = nxRsExc(sc, x)
    if not ok: return nxRsFail("cannot tell what " & x & " is")
    nxRsAdd(result.excs, e)

proc nxRsCandidates(c: var NxRsCtx, refs: seq[NxRef], callPath: string, callLine: int): NxRaises =
  ## a call that may be any of `refs`: what they raise, when they all agree
  var first = true
  for r in refs:
    let x = nxRsRoutine(c, r, callPath, callLine)
    when defined(nxRsDebug):
      if not x.known and refs.len > 1:
        var ds: seq[string]
        for r in refs: ds.add r.sym.name & "@" & r.file.path.extractFilename & ":" & $(r.sym.line + 1)
        echo "CANDS(failed) ", ds.join(" ")
    if not x.known: return x
    if first:
      result = x
      first = false
    else:
      var same = x.excs.len == result.excs.len
      if same:
        for e in x.excs:
          var hit = false
          for y in result.excs:
            if nxNorm(y.name) == nxNorm(e.name): hit = true
          if not hit: same = false
      if not same: return nxRsFail("overloads of " & r.sym.name & " raise different exceptions")
  if first: return nxRsFail("no routine")
  when defined(nxRsDebug):
    if refs.len > 1:
      var ds: seq[string]
      for r in refs: ds.add r.sym.name & "@" & r.file.path.extractFilename & ":" & $(r.sym.line + 1)
      echo "CANDS ", ds.join(" ")

proc nxRsMerge(dst: var seq[NxExc], r: NxRaises) =
  for e in r.excs: nxRsAdd(dst, e)

proc nxRsArgs(t: string, nameEnd: int): seq[string] =
  ## a call's arguments after the name ending at `nameEnd`: name(a, b) or name a, b
  let k = nameEnd
  if k < t.len and t[k] == '(':
    let e = nxMatchClose(t, k)
    if e < 0: return
    if e > k + 1:
      for p in nxSplitTop(t[k + 1 ..< e], {','}): result.add p.strip
  elif k < t.len and t[k] == ' ':
    let rest = t[k .. ^1].strip
    if rest.len > 0:
      for p in nxSplitTop(rest, {','}): result.add p.strip

func nxRsCanon(t: string): string =
  ## a type as the compiler sees it: the C types and system's aliases are the Nim types they stand for
  result = nxStripMods(t).replace("system.", "").replace(" ", "")
  case result
  of "cint": result = "int32"
  of "cuint": result = "uint32"
  of "cshort": result = "int16"
  of "cushort": result = "uint16"
  of "cschar": result = "int8"
  of "cuchar", "byte": result = "uint8"
  of "cchar": result = "char"
  of "clonglong", "BiggestInt": result = "int64"
  of "culonglong", "BiggestUInt": result = "uint64"
  of "cfloat": result = "float32"
  of "cdouble", "BiggestFloat", "float64": result = "float"
  of "csize_t": result = "uint"
  else: discard

proc nxRsMagicOperand(sc: NxScope, t0: string): bool =
  ## a value the system's comparison and arithmetic operators take as they are (its magic): a number, a char, a bool,
  ## an enum, a ref, a ptr, a pointer, a set, a range or distinct of one of them
  var t = nxStripMods(t0).strip
  for _ in 0 .. 4:
    if t.len == 0: return false
    if t in NxRsBuiltinElems and t != "string": return true
    if t.startsWith("ref ") or t.startsWith("ptr ") or t.startsWith("set[") or t.startsWith("range[") or
       t.startsWith("proc") or t == "pointer" or t == "cstring": return true
    if not t.allCharsInSet(IdentChars + {'.'}): return false
    let refs = nxTypeSyms(sc, t)
    if refs.len != 1: return false
    let d = refs[0].sym.typ.strip
    if d.startsWith("enum") or d.startsWith("ref ") or d.startsWith("ptr ") or d.startsWith("set[") or
       d.startsWith("range["): return true
    if d.startsWith("distinct "): t = d[9 .. ^1].strip
    elif d.len > 0 and d.allCharsInSet(IdentChars + {'.'}): t = d
    else: return false
  false

proc nxRsNominal(sc: NxScope, t0: string): bool =
  ## an object or enum type known by its name (Token, ref Node, var SqlLexer): an argument of another such type does
  ## not convert to it, only one derived from it does
  let t = nxStripMods(t0).strip
  if t.len == 0 or not t.allCharsInSet(IdentChars + {'.'}): return false
  let refs = nxTypeSyms(sc, t)
  if refs.len != 1 or refs[0].sym.generics.len > 0: return false
  let d = refs[0].sym.typ.strip
  d.startsWith("enum") or d == "object" or d.startsWith("object ") or d.startsWith("ref object") or
    d.startsWith("ptr object")

func nxRsSame(a, b: string): bool =
  let x = nxRsCanon(a)
  x.len > 0 and nxNorm(x) == nxNorm(nxRsCanon(b))

proc nxRsExact(cands: seq[NxRef], types: seq[string]): seq[NxRef] =
  ## the candidates whose parameters are exactly the arguments' types (the rest have defaults): the one the compiler
  ## picks — an exact match beats a generic one and one that needs a conversion. None when a type is not known, or
  ## nothing matches so
  if types.len == 0: return
  for t in types:
    if t.len == 0 or t in ["untyped", "typed", "auto"]: return
  for r in cands:
    let ps = r.sym.params
    if ps.len < types.len or r.sym.generics.len > 0: continue
    var ok = true
    for k in 0 ..< ps.len:
      if k < types.len:
        if ps[k].typ.len == 0 or not nxRsSame(ps[k].typ, types[k]): ok = false
      elif ps[k].default.len == 0: ok = false
    if ok: result.add r

proc nxRsProcVar(w: NxRsBody, at: NxFile, typ, name: string, fx = false): NxRaises =
  ## a call through a variable, parameter or field of a proc type: the {.raises.} its type declares, else not known
  ## (the compiler assumes it raises anything). (fx) a side effect unless its type says {.noSideEffect.}
  var t = nxStripMods(typ).strip
  var file = at
  var sc = if at == w.f: w.sc else: nxScope(at)
  for _ in 0 .. 4:
    if t.startsWith("proc") or t.startsWith("iterator"):
      let k = t.rfind("{.")
      if fx:
        # (its own pragmas: after its parameters — not those of a proc type among them, or of its result)
        let po = t.find('(')
        let pc = if po >= 0: nxMatchClose(t, po) else: -1
        let after = if pc > po: t[pc + 1 .. ^1]
                    elif po < 0: t[min(t.len, (if t.startsWith("proc"): 4 else: 8)) .. ^1]
                    else: ""
        if "proc" in after or "iterator" in after: return nxRsFail("a call through " & name)
        if nxFxPragma(after, "noSideEffect"): return NxRaises(known: true)
        return nxFxImpure("a call through " & name)
      if k < 0: break
      let e = t.find(".}", k)
      if e < 0: break
      let p = t[k + 2 ..< e]
      let r = p.find("raises")
      if r < 0: break
      let a = p.find('[', r)
      let b = if a >= 0: nxMatchClose(p, a) else: -1
      if b <= a: break
      return nxRsListOf(sc, p[a + 1 ..< b])
    if not t.allCharsInSet(IdentChars + {'.'}) or t.len == 0: break
    # a proc type's name: its definition (with the pragmas the parser leaves out)
    let refs = nxTypeSyms(sc, t)
    if refs.len != 1: break
    let (def, _, _, _) = nxLayDefOf(refs[0], nxLayLinesOf(refs[0].file.path))
    if def.len == 0: break
    file = refs[0].file
    sc = nxScope(file)
    t = def
  nxRsFail("a proc variable: " & name)

# ── converters: the compiler calls one, unwritten, where a value of a type it takes goes where its result's type is
#    wanted and nothing else makes it fit. Those that do nothing (raise nothing, no side effect) do not matter; for
#    the others every such place is looked at: the converter counted where it surely applies, no answer where the
#    engine cannot tell ──

var nxRsConvCache: Table[string, (NxScope, seq[NxRef])]   # file → (its scope, the converters it can see)

proc nxRsConvertersIn(sc: NxScope, path: string): seq[NxRef] =
  ## the converters scope `sc` sees (read again when the scope was made again)
  let x = nxRsConvCache.getOrDefault(path)
  if x[0] == sc and sc != nil: return x[1]
  for r in sc.refs:
    if r.sym.kind == nxConverter and not r.sym.made: result.add r
  if nxRsConvCache.len > 256: nxRsConvCache.clear()
  nxRsConvCache[path] = (sc, result)

proc nxRsConvSrc(sc: NxScope, t: string, gens: seq[string], into: var NxRsConv, depth = 0) =
  ## the types a converter's parameter takes: a union, an alias of one, a type class — each member
  let x = nxStripMods(t).strip
  if x.len == 0 or depth > 4 or x in gens or x in ["auto", "any", "typed", "untyped", "RootObj"]:
    into.anySrc = true
    return
  for (cls, members) in NxTypeClasses:
    if x == cls:
      if cls in ["SomeOrdinal", "Ordinal"]: into.anySrc = true      # (an enum is one too)
      for m in members.split(' '): into.src.add m
      return
  let alts = nxUnionAlts(sc, x)
  if alts.len > 1:
    for a in alts: nxRsConvSrc(sc, a, gens, into, depth + 1)
    return
  for r in nxTypeSyms(sc, nxBaseName(x)):
    if r.sym.typ.strip.startsWith("concept"):
      into.anySrc = true
      return
  into.src.add x

func nxRsHasWord(t: string, words: seq[string]): bool =
  ## does type `t` name one of `words` (generic parameters: T in seq[T])
  if words.len == 0: return false
  var k = 0
  while k < t.len:
    if nxIsIdent(t[k]) and (k == 0 or not nxIsIdent(t[k - 1])):
      var e = k
      while e < t.len and nxIsIdent(t[e]): inc e
      if t[k ..< e] in words: return true
      k = e
    else: inc k
  false

proc nxRsConvTakes(sc: NxScope, cv: NxRsConv, val: string): bool =
  ## can converter `cv` take a value of type `val` (itself, a member of its union, a type derived from it)
  if cv.anySrc: return true
  let v = nxStripMods(val)
  for s in cv.src:
    if nxRsSame(s, v) or nxIsSubtype(sc, v, s): return true
  false

proc nxRsConvMakes(sc: NxScope, cv: NxRsConv, slot: string): int =
  ## can what converter `cv` makes go where `slot` is wanted: 0 no · 1 it is that type · 2 a part of it is (a
  ## seq of it, a tuple with it: a literal there may be converted) or the engine cannot tell
  let s = nxStripMods(slot)
  if s.len == 0 or cv.anyDest: return 2
  if nxRsSame(s, cv.dest) or nxIsSubtype(sc, cv.dest, s): return 1
  let b = nxNorm(nxBaseName(cv.dest))
  var k = 0
  while k < s.len:
    if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])):
      var e = k
      while e < s.len and nxIsIdent(s[e]): inc e
      if nxNorm(s[k ..< e]) == b: return 2
      k = e
    else: inc k
  0

proc nxRsConvAt(c: var NxRsCtx, w: var NxRsBody, slot, val: string, exc: var seq[NxExc]): bool =
  ## a value of type `val` goes where `slot` is wanted (an argument, an assignment …): the converter that applies
  ## counted — false when the engine cannot tell whether one does
  for cv in w.convs:
    let m = nxRsConvMakes(w.sc, cv, slot)
    if m == 0: continue
    let v = nxStripMods(val)
    if v.len == 0 or nxStripMods(slot).len == 0:
      c.why = "where the converter " & cv.r.sym.name & " may apply"
      return false
    if nxRsSame(nxStripMods(slot), v): continue                       # (taken as it is)
    if m == 1 and nxCompat(w.sc, slot, "", v) >= 1: continue          # (a subtype, a wider number, a generic …)
    if not nxRsConvTakes(w.sc, cv, v): continue
    if m == 2 or not cv.eff.known:
      c.why = "where the converter " & cv.r.sym.name & " may apply"
      return false
    nxRsMerge(exc, cv.eff)                                            # (it applies)
  true

proc nxRsConvTaken(w: NxRsBody, val: string, overloads: seq[NxRef] = @[]): bool =
  ## would one of the converters that do something take a value of type `val` (unknown: maybe) — with
  ## `overloads`, only one whose result one of them takes (+ on ints: a converter from int to Port does not matter)
  for cv in w.convs:
    if val.len > 0 and not nxRsConvTakes(w.sc, cv, val): continue
    if overloads.len == 0: return true
    for r in overloads:
      for p in r.sym.params:
        if nxRsConvMakes(w.sc, cv, p.typ) > 0 and p.typ.len > 0: return true
  false

proc nxRsConvCall(c: var NxRsCtx, w: var NxRsBody, r: NxRef, types, argTexts: seq[string],
                  exc: var seq[NxExc]): bool =
  ## the arguments of a call of `r` (their types: the receiver first, as in `types`): the converters that apply
  ## counted — false when the engine cannot tell
  for at in argTexts:
    if nxFindTop(at, '=') >= 0 or at.endsWith(":"):
      c.why = "a named argument where a converter may apply"
      return false
  let ps = r.sym.params
  let names = nxGenericNames(r.sym.generics)
  var binds: Table[string, string]
  for k in 0 ..< types.len:
    let pk = min(k, ps.high)
    if pk < 0: break
    if k > ps.high and not ps[pk].typ.startsWith("varargs["): break
    var raw = ps[pk].typ
    if raw.len == 0: raw = nxLiteralType(ps[pk].default)
    if raw.startsWith("varargs["):
      let ta = nxTypeArgs(raw)
      if ta.len != 1: continue                       # (varargs[typed, `$`]: each one converted by `$`)
      raw = ta[0]
    let slot = nxSubst(raw, binds)
    # (a generic parameter not bound yet: this argument binds it, as it is)
    if nxRsHasWord(slot, names) or nxStripMods(slot) in ["untyped", "typed", "auto", "any"]:
      if types[k].len > 0: nxUnify(raw, types[k], names, binds)
      continue
    if not nxRsConvAt(c, w, slot, types[k], exc): return false
    if names.len > 0 and types[k].len > 0: nxUnify(raw, types[k], names, binds)
  true

proc nxRsConvSetup(c: var NxRsCtx, w: var NxRsBody, s: NxSym): bool =
  ## the converters the body can see that do something (each one's own effect worked out once) — false when the
  ## engine will not read the body because of one (a converter to bool: every condition may call it)
  for cr in nxRsConvertersIn(w.sc, w.f.path):
    if cr.file.path == w.f.path and cr.sym.line == s.line: continue        # (itself)
    let eff = nxRsRoutine(c, cr, w.f.path, s.line)
    if c.cut: return false
    if eff.known and (if c.fx: not nxFxHas(eff.excs) else: eff.excs.len == 0): continue   # (it does nothing)
    var cv = NxRsConv(r: cr, eff: eff)
    let csc = nxRsScope(c, cr.file)
    let gens = nxGenericNames(cr.sym.generics)
    if cr.sym.params.len == 0: continue
    nxRsConvSrc(csc, cr.sym.params[0].typ, gens, cv)
    cv.dest = nxStripValMods(cr.sym.ret).strip
    if nxRsHasWord(cv.dest, gens): cv.anyDest = true
    if cv.dest.len == 0 or cv.dest in ["auto", "untyped", "typed"]: cv.anyDest = true
    if cv.anyDest or nxRsSame(cv.dest, "bool"):
      c.why = "the converter " & cr.sym.name & (if cv.anyDest: "" else: " to bool")
      return false
    w.convs.add cv
  # (what the routine itself gives back may be converted: `return x`, `yield x`, its last expression)
  for cv in w.convs:
    if s.ret.len > 0 and nxRsConvMakes(w.sc, cv, nxStripValMods(s.ret)) > 0: w.retConv = true
  true

proc nxRsConvLast(c: var NxRsCtx, w: var NxRsBody, ls: seq[NxRsLine], exc: var seq[NxExc]): bool =
  ## (a converter makes what the routine gives back) its last statement, when it is its value: what it is
  var k = ls.high
  while k > 0 and ls[k].ind > ls[0].ind: dec k
  let st = ls[k]
  let (kw, _) = nxName(st.text, 0)
  if kw in ["if", "when", "case", "block", "try"] or st.text.endsWith(":"):
    c.why = "a last value a converter may make"
    return false
  if kw in ["for", "while", "discard", "return", "raise", "var", "let", "const", "result", "break", "continue",
            "defer", "yield", "type", "proc", "func", "template", "iterator", "macro", "converter", "method"] or
     st.text.startsWith("{."):
    return true
  var q = 0
  var depth = 0
  while q < st.text.len:                   # (an assignment: no value)
    let ch = st.text[q]
    if ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif ch == '=' and depth == 0 and (q + 1 >= st.text.len or st.text[q + 1] != '=') and
         (q == 0 or st.text[q - 1] notin NxOpChars): return true
    inc q
  inc c.steps
  let v = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, st.line, st.col), st.text, st.line, 0).typ
  nxRsConvAt(c, w, nxStripValMods(w.rs.ret), v, exc)

proc nxRsConvStmt(c: var NxRsCtx, w: var NxRsBody, st: NxRsLine, decl: bool, exc: var seq[NxExc]): bool =
  ## (converters that do something can be seen) a statement that puts a value somewhere: x = v, x.f = v,
  ## let x: T = v — the converter that applies counted, false when the engine cannot tell
  let t = st.text
  var k = 0
  var depth = 0
  var inStr = false
  var eq = -1
  while k < t.len:
    let ch = t[k]
    if ch == '"': inStr = not inStr
    elif inStr: discard
    elif ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif ch == '=' and depth == 0 and (k + 1 >= t.len or t[k + 1] != '=') and
         (k == 0 or t[k - 1] notin NxOpChars):
      eq = k
      break
    inc k
  if eq < 0: return true
  let locs = nxLocals(w.f, w.lines, st.line, st.col)
  var lhs = t[0 ..< eq].strip
  var slot = ""
  if decl:
    for kw in ["let ", "var ", "const "]:
      if lhs.startsWith(kw): lhs = lhs[kw.len .. ^1].strip
    let col = nxFindTop(lhs, ':')
    if col < 0: return true                          # (its type is the value's: nothing converted)
    slot = lhs[col + 1 .. ^1].strip
    let pe = slot.find("{.")
    if pe >= 0: slot = slot[0 ..< pe].strip
  else:
    if lhs.len == 0 or lhs.startsWith("(") or ',' in lhs: return true
    inc c.steps
    slot = nxTypeOfExpr(w.f, w.sc, locs, lhs, st.line, 0).typ
  inc c.steps
  let val = nxTypeOfExpr(w.f, w.sc, locs, t[eq + 1 .. ^1].strip, st.line, 0).typ
  nxRsConvAt(c, w, slot, val, exc)

proc nxRsIdentKind(c: var NxRsCtx, w: var NxRsBody, line, a, e: int): NxRaises =
  ## the identifier at line:a..e of the body — known (and what it raises, when it is a call) or not
  let t = w.lines[line]
  let name = t[a ..< e]
  var k = e
  while k < t.len and t[k] == ' ': inc k
  let next = if k < t.len: t[k] else: '\0'
  # name: at the start of a statement, nothing after the colon — a call with a block (runnableExamples:, a template)
  let blockArg = next == ':' and t[0 ..< a].strip.len == 0 and nxCodeOf(t[k + 1 .. ^1]).len == 0
  var genCall = false                # newSeq[int](n), initHashSet[T](): a generic routine called with its arguments
  if e < t.len and t[e] == '[':
    let ge = nxMatchClose(t, e)
    if ge > e and ge + 1 < t.len and t[ge + 1] == '(': genCall = true
  let called = (e < t.len and t[e] == '(') or blockArg or genCall
  var nextWord = ""                  # (a keyword operator after the name: x in s, v shr 1 — not a command call)
  if k < t.len and t[k] in IdentStartChars:
    var q = k
    while q < t.len and nxIsIdent(t[q]): inc q
    nextWord = t[k ..< q]
  let cmdCall = e < t.len and t[e] == ' ' and k < t.len and
                (t[k] in IdentStartChars + Digits + {'"', '\'', '@', '[', '{'} or (t[k] == '(' and k > e)) and
                nextWord notin ["and", "or", "xor", "not", "div", "mod", "shl", "shr", "in", "notin", "is", "isnot",
                                "of", "as", "else", "elif", "do", "then"]
  let member = a > 0 and t[a - 1] == '.'
  let strCall = e < t.len and t[e] == '"'          # fmt"…", r"…" (r: a raw string, not a call)
  if strCall and name in ["r", "R"]: return NxRaises(known: true)
  # a named argument or a constructor's field: name = …, name: …
  if not member and not blockArg and next in {'=', ':'} and not (k + 1 < t.len and t[k + 1] in {'=', ':'}):
    var d = 0
    for q in 0 ..< a:
      if t[q] in {'(', '[', '{'}: inc d
      elif t[q] in {')', ']', '}'}: dec d
    if d > 0: return NxRaises(known: true)
  if c.fx and not member and name != "result":
    # a module's variable (a var, let or threadvar of this module or an imported one): global state, a side effect
    let g = nxFxGlobals(w.sc, name)
    if g > 0:
      if nxNorm(name) in w.localNames:
        # (a local of that name hides it — when it is declared before this, in a block around it)
        var vis = false
        for x in nxLocals(w.f, w.lines, line, a):
          if nxNorm(x.name) == nxNorm(name): vis = true
        if not vis: return nxRsFail("a local and a global named " & name)
      elif nxNorm(name) notin w.genNames:
        return (if g == 1: nxFxImpure("it uses the global " & name) else: nxRsFail(name & " may be a global"))
  if not member and (nxNorm(name) in w.localNames or name == "result") and not (called or cmdCall or strCall):
    return NxRaises(known: true)
  if not member and not (called or cmdCall or strCall):
    # a name that is not called: a value (a constant, a type, a variable … or a routine passed on)
    var anyRoutine = false
    var any = false
    for r in nxLookup(w.sc, name):
      any = true
      if r.sym.kind in NxRoutineKinds - {nxTemplate, nxMacro}: anyRoutine = true
      elif r.sym.kind in {nxTemplate, nxMacro}:
        anyRoutine = true                     # (a template without parameters is called without them)
    if any and not anyRoutine: return NxRaises(known: true)
  inc c.steps
  if c.steps > c.limit or getMonoTime() > c.deadline:     # (a step may read a module: the clock every step)
    c.cut = true
    return nxRsFail("out of time")
  if name == "system" and next == '.': return NxRaises(known: true)       # (system.foo: the module)
  if not member and nxNorm(name) in w.genNames and not called: return NxRaises(known: true)   # (a type parameter)
  if member and nxReceiver(t, a - 1) == "system":
    var sys: seq[NxRef]
    for r in nxLookup(w.sc, name):
      if nxInSystem(r.file.path): sys.add r
    if sys.len == 0: return nxRsFail("cannot tell what system." & name & " is")
    var allValues = true
    for r in sys:
      if r.sym.kind in NxRoutineKinds: allValues = false
    if allValues: return NxRaises(known: true)
  let (refs0, locals, modPath) = nxTargets(w.f, w.lines, line, a)
  var refs = refs0
  if refs.len == 0 and member and nxReceiver(t, a - 1) == "system":
    for r in nxLookup(w.sc, name):
      if nxInSystem(r.file.path): refs.add r
  if modPath.len > 0: return NxRaises(known: true)
  if locals.len > 0:
    let s = locals[0]
    if s.kind in NxRoutineKinds: return nxRsFail("a routine declared inside: " & name)
    if called or cmdCall: return nxRsProcVar(w, w.f, s.typ, name, c.fx)
    return NxRaises(known: true)
  if refs.len == 0: return nxRsFail("cannot tell what " & name & " is")
  var routines: seq[NxRef]
  for r in refs:
    if r.sym.kind in NxRoutineKinds: routines.add r
  if routines.len == 0:
    # a type (a conversion, a constructor), a constant, a field, a module-level variable
    for r in refs:
      if c.fx and r.sym.kind in {nxLet, nxVar} and not r.sym.local:
        return nxFxImpure("it uses the global " & name)          # (module.variable)
      if r.sym.kind in {nxLet, nxVar, nxField} and (called or cmdCall):
        var typ = r.sym.typ
        if r.sym.kind == nxField:
          # (a field's proc type can go on below: its pragmas on the next line)
          let flr = nxLayLinesRef(r.file.path)
          template fl: untyped = flr.lines
          var l = r.sym.line + 1
          while l < fl.len and l <= r.sym.line + 4:
            let x = nxCodeOf(fl[l])
            if not x.startsWith("{."): break
            typ.add " " & x
            inc l
        return nxRsProcVar(w, r.file, typ, name, c.fx)       # (a call through a proc-typed variable or field)
      if r.sym.kind == nxType and called:
        # a constructor of an object whose fields have defaults that call something: not looked into
        for fr in nxFields(w.sc, r.sym.name):
          if '(' in fr.sym.value: return nxRsFail("a field default of " & name)
    if w.convs.len > 0 and called:
      # (converters that do something are seen) Obj(f: v): what goes in each field; T(x): a conversion
      for r in refs:
        if r.sym.kind != nxType: continue
        var conv: seq[NxExc]
        let locs = nxLocals(w.f, w.lines, line, a)
        for arg in nxRsArgs(t, e):
          let col = nxFindTop(arg, ':')
          inc c.steps
          let vt = nxTypeOfExpr(w.f, w.sc, locs, (if col >= 0: arg[col + 1 .. ^1] else: arg).strip, line, 0).typ
          if col < 0:
            var one: seq[NxExc]
            if not nxRsConvAt(c, w, r.sym.name, vt, one) or one.len > 0:
              return nxRsFail("a conversion to " & name & " where a converter may apply")
            continue
          var ft = ""
          for fr in nxFields(w.sc, r.sym.name):
            if nxNorm(fr.sym.name) == nxNorm(arg[0 ..< col].strip): ft = fr.sym.typ
          if not nxRsConvAt(c, w, ft, vt, conv): return nxRsFail(c.why)
        return NxRaises(known: true, excs: conv)
    return NxRaises(known: true)
  if routines.len < refs.len:
    var types = 0
    for r in refs:
      if r.sym.kind == nxType: inc types
    if types > 0 and called: return NxRaises(known: true)        # (a conversion to a type of that name)
  if not (called or cmdCall or member or strCall):
    for r in routines:
      if r.sym.kind notin {nxTemplate, nxMacro}: return nxRsFail(name & " passed as a value")
  # echo and other routines with varargs[T, `$`]: each argument is converted — only for types of the system's own
  for r in routines:
    for p in r.sym.params:
      if p.typ.startsWith("varargs[") and nxTypeArgs(p.typ).len > 1:
        for arg in nxRsArgs(t, e):
          if arg.len == 0: continue
          inc c.steps
          let at = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, line, a), arg, line, 0).typ
          if not nxRsBuiltinType(at): return nxRsFail("$ of " & arg)
      if p.default.len > 0 and '(' in p.default and not (p.default.startsWith("defined(") or
         p.default.startsWith("declared(") or p.default.startsWith("sizeof(") or p.default.startsWith("high(") or
         p.default.startsWith("low(") or p.default.startsWith("default(")):
        return nxRsFail("a default argument of " & name)
      if c.fx and p.default.len > 0 and nxFxNamesGlobal(nxRsScope(c, r.file), p.default):
        return nxFxImpure("a default argument of " & name & " uses a global")    # (`nc: var T = nc0`)
  # which overload: every visible one of that name (not only those the index ranks first) whose number of
  # parameters fits the call and whose first one takes the first argument — the one taking all the arguments' types
  # exactly when there is one, else they must agree
  var qualified = false
  var systemOnly = false
  if member:
    let recv = nxReceiver(t, a - 1)
    # (a module's name — unless a parameter or variable of that name hides it: request.send(…) with request a Request)
    qualified = recv in w.sc.modules and nxNorm(recv) notin w.localNames
    systemOnly = recv == "system"
    if systemOnly: qualified = true
  var pool = routines
  if systemOnly:
    pool.setLen(0)
    for r in nxLookup(w.sc, name):
      if r.sym.kind in NxRoutineKinds and nxInSystem(r.file.path):
        pool.add r
  if not qualified:
    pool.setLen(0)
    for r in nxLookup(w.sc, name):
      if r.sym.kind notin NxRoutineKinds: continue
      var dup = false
      for x in pool:
        if x.file.path == r.file.path and x.sym.line == r.sym.line: dup = true
      if not dup: pool.add r
    if pool.len == 0: pool = routines
  var argTexts: seq[string]
  var nargs = -1
  if blockArg: nargs = -1
  elif called and e < t.len and t[e] == '(':
    argTexts = nxRsArgs(t, e)
    nargs = argTexts.len
  elif genCall:
    let ge = nxMatchClose(t, e)
    argTexts = nxRsArgs(t, ge + 1)
    nargs = -1                     # (a void type argument takes a parameter away)
    var gen: seq[NxRef]
    for r in pool:
      if r.sym.generics.len > 0: gen.add r
    pool = gen
  elif cmdCall:
    argTexts = nxRsArgs(t, e)
    nargs = argTexts.len
  elif strCall: nargs = 1
  elif member: nargs = 0
  if member and not qualified and nargs >= 0: inc nargs
  var types: seq[string]
  let locs = nxLocals(w.f, w.lines, line, a)
  if member and not qualified:
    inc c.steps
    types.add nxTypeOfExpr(w.f, w.sc, locs, nxReceiver(t, a - 1), line, 0).typ
  for arg in argTexts:
    if arg.len == 0 or nxFindTop(arg, '=') >= 0 or arg.endsWith(":"):
      types.add ""
      continue
    inc c.steps
    types.add nxTypeOfExpr(w.f, w.sc, locs, arg, line, 0).typ
  var fit: seq[NxRef]
  let firstNominal = types.len > 0 and nxRsNominal(w.sc, types[0])
  for r in pool:
    if not nxArgsFit(r.sym, nargs): continue
    # (the first argument rules one out only between object and enum types: there conversions do not blur it)
    if firstNominal and r.sym.params.len > 0 and r.sym.generics.len == 0 and
       nxRsNominal(nxRsScope(c, r.file), r.sym.params[0].typ) and
       nxCompatP(w.sc, r.sym.params[0], r.sym.generics, types[0]) == 0: continue
    fit.add r
  if fit.len == 0: return nxRsFail("no overload of " & name & " fits the call")
  var chosen = fit
  if fit.len > 1:
    let ex = nxRsExact(fit, types)
    if ex.len > 0: chosen = ex
  if w.convs.len > 0:
    # (converters that do something are seen) its arguments: the converter that applies to one counted
    var conv: seq[NxExc]
    var ts = types
    if strCall and ts.len == 0: ts = @["string"]
    for r in chosen:
      var one: seq[NxExc]
      if not nxRsConvCall(c, w, r, ts, argTexts, one): return nxRsFail(c.why)
      if chosen.len > 1 and one.len > 0: return nxRsFail("a converter may apply to an argument of " & name)
      for x in one: nxRsAdd(conv, x)
    result = nxRsCandidates(c, chosen, w.f.path, line)
    if result.known:
      for x in conv: nxRsAdd(result.excs, x)
    return
  nxRsCandidates(c, chosen, w.f.path, line)

proc nxRsOp(c: var NxRsCtx, w: var NxRsBody, line, a, e: int): NxRaises =
  ## an operator: the overload its operands' types pick (or all visible ones, when they agree)
  let t = w.lines[line]
  let written = t[a ..< e]
  if written in ["=", ":", ".", "..", "::", "{.", ".}", "...", "..<"]: return NxRaises(known: true)
  if written in ["->", "=>"]: return nxRsFail("the " & written & " macro")
  if written == "*" and a > 0 and nxIsIdent(t[a - 1]) and (e >= t.len or t[e] in {':', ',', ' ', '('}) and
     t[0 ..< a].strip.split(' ')[0] in ["let", "var", "const"]:
    return NxRaises(known: true)                        # (an export marker)
  inc c.steps
  if c.steps > c.limit:
    c.cut = true
    return nxRsFail("out of time")
  # its operands' types: an overload taking exactly those is the one (string & string: the system's)
  var op = written
  var swapped = false
  case op                                   # (system's templates: a != b is not (a == b), a > b is b < a …)
  of "!=": op = "=="
  of ">":
    op = "<"
    swapped = true
  of ">=":
    op = "<="
    swapped = true
  else: discard
  var all: seq[NxRef]
  for r in nxLookup(w.sc, op):
    if r.sym.kind in NxRoutineKinds and r.sym.name == op: all.add r
  var opTyped = false                       # (its operands' types known: converters looked at)
  block exact:
    var i = a
    while i > 0 and t[i - 1] == ' ': dec i
    let spacedBefore = i < a
    let spacedAfter = e >= t.len or t[e] == ' '
    let leftEnd = i > 0 and (nxIsIdent(t[i - 1]) or t[i - 1] in {')', ']', '}', '"', '\''})
    let binary = leftEnd and (not spacedBefore or spacedAfter)
    var j = e
    while j < t.len and t[j] == ' ': inc j
    var re = if j < t.len and t[j] == '\'' and nxCharEnd(t, j) > j: nxCharEnd(t, j) + 1    # ('\n')
             else: nxOperandFwd(t, j)
    if re <= j: break exact
    if re + 1 < t.len and t[re] == '\'' and t[re - 1] in Digits and nxIsIdent(t[re + 1]):
      inc re                                     # (a number with its type: 0'i32)
      while re < t.len and nxIsIdent(t[re]): inc re
    let locs = nxLocals(w.f, w.lines, line, a)
    var types: seq[string]
    if binary:
      var ls = nxOperandBack(t, i)
      if i >= 3 and t[i - 1] == '\'':
        for k in countdown(i - 2, max(0, i - 8)):            # (a character: 'a' == c)
          if t[k] == '\'' and nxCharEnd(t, k) == i - 1:
            ls = k
            break
      if ls >= i: break exact
      if ls >= 2 and t[ls - 1] == '\'' and t[ls - 2] in Digits:
        ls = nxOperandBack(t, ls - 1)            # (a number with its type: 5'u8)
      while ls > 0 and t[ls - 1] in {'$', '-', '@', '!', '~', '+'} and
            (ls == 1 or t[ls - 2] in {' ', '(', '[', ',', '{', '='}): dec ls        # (its own prefix operator: $x)
      inc c.steps
      types.add nxTypeOfExpr(w.f, w.sc, locs, t[ls ..< i], line, 0).typ
    inc c.steps
    types.add nxTypeOfExpr(w.f, w.sc, locs, t[j ..< re], line, 0).typ
    if swapped and types.len == 2: types = @[types[1], types[0]]
    if op == "==" and (t[j ..< re].strip == "nil" or (binary and t[nxOperandBack(t, i) ..< i].strip == "nil")):
      return NxRaises(known: true)                # (x == nil: the system's own, for a ref, ptr, proc, cstring)
    let ex = nxRsExact(all, types)
    when defined(nxRsDebug): echo "OPTYPES ", op, " ", types, " exact ", ex.len, " at ", w.f.path.extractFilename, ":", line + 1
    if ex.len > 0: return nxRsCandidates(c, ex, w.f.path, line)
    if w.convs.len > 0:
      # (converters that do something are seen) an operand one of them takes: which overload, and whether it is
      # converted, not worked out
      for ty in types:
        if nxRsConvTaken(w, ty, all): return nxRsFail("an operand the converter may take: " & written)
      opTyped = true
    if op in ["==", "<", "<=", "+", "-", "*", "/", "div", "mod", "shl", "shr", "and", "or", "xor", "not", "<%", "+%",
              "-%", "*%", "/%", "%%", "<=%", "$", "+=", "-=", "*=", "/="]:
      # an enum, a ref, a pointer, a set, a number: the system's own magic (none of which raises)
      var magic = true
      for ty in types:
        if not nxRsMagicOperand(w.sc, ty): magic = false
      if magic:
        var own = false               # (unless the file declares the operator for that type itself)
        for r in all:
          if r.file.path == w.f.path: own = true
        if not own: return NxRaises(known: true)
  if w.convs.len > 0 and not opTyped: return nxRsFail("operands the converter may take: " & written)
  var cands = if op == written: nxOpTargets(w.f, w.lines, line, a) else: @[]
  if cands.len == 0 and op != written: cands = all
  if cands.len == 0:
    for r in nxLookup(w.sc, op):
      if r.sym.kind in NxRoutineKinds and r.sym.name == op: cands.add r
    if cands.len == 0: return NxRaises(known: true)       # (no routine of that name: syntax, like `@` of an array)
    if cands.len > 60: return nxRsFail("the operator " & op)
  nxRsCandidates(c, cands, w.f.path, line)

proc nxRsIndex(c: var NxRsCtx, w: var NxRsBody, line, b: int): NxRaises =
  ## x[i] (or x[i] = v): the `[]` of x's type — the system's own for a seq, array, string, openArray
  let t = w.lines[line]
  let s = nxOperandBack(t, b)
  if s >= b: return NxRaises(known: true)
  let recv = t[s ..< b].strip
  if recv.len == 0: return NxRaises(known: true)
  inc c.steps
  let locals = nxLocals(w.f, w.lines, line, s)
  let v = nxTypeOfExpr(w.f, w.sc, locals, recv, line, 0)
  if v.typeName.len > 0 or v.routine.len > 0: return NxRaises(known: true)   # seq[int], newSeq[int](…): not indexing
  if v.typ.len == 0:
    # a type or a generic routine named there: its [arguments]
    if recv.allCharsInSet(IdentChars + {'.'}):
      var allTypes = true
      var any = false
      for r in nxLookup(w.sc, recv.split('.')[^1]):
        any = true
        if r.sym.kind notin {nxType} + NxRoutineKinds: allTypes = false
      if any and allTypes: return NxRaises(known: true)
    return nxRsFail("cannot tell the type of " & recv)
  if w.convs.len > 0:
    # (converters that do something are seen) an index one of them takes (to an int, an enum …): not worked out
    let ce0 = nxMatchClose(t, b)
    if ce0 < 0: return nxRsFail("an index where a converter may apply")
    for part in nxSplitTop(t[b + 1 ..< ce0], {','}):
      if part.strip.len == 0: continue
      inc c.steps
      let it = nxTypeOfExpr(w.f, w.sc, locals, part.strip, line, 0).typ
      if nxRsConvTaken(w, it): return nxRsFail("an index where a converter may apply")
  let base = nxStripMods(v.typ)
  if base.startsWith("ptr ") or base.startsWith("ref ") or nxRsBuiltinType(base) or
     base.startsWith("seq[") or base.startsWith("array[") or base.startsWith("openArray[") or
     base in ["string", "cstring"] or base.startsWith("varargs[") or base.startsWith("UncheckedArray["):
    return NxRaises(known: true)
  if base.startsWith("tuple[") or base.startsWith("("): return NxRaises(known: true)
  let ce = nxMatchClose(t, b)
  var opName = "[]"
  if ce > b:
    var q = ce + 1
    while q < t.len and t[q] == ' ': inc q
    if q < t.len and t[q] == '=' and not (q + 1 < t.len and t[q + 1] == '='): opName = "[]="
  var cands: seq[NxRef]
  for r in nxLookup(w.sc, opName):
    if r.sym.kind notin NxRoutineKinds or r.sym.params.len == 0: continue
    if nxCompatP(w.sc, r.sym.params[0], r.sym.generics, v.typ) > 0: cands.add r
  if cands.len == 0: return nxRsFail("the " & opName & " of " & v.typ)
  if cands.len > 1 and ce > b:
    # the one taking exactly x's type and the index's
    let idx = nxSplitTop(t[b + 1 ..< ce], {','})
    if idx.len == 1:
      inc c.steps
      let it = nxTypeOfExpr(w.f, w.sc, locals, idx[0].strip, line, 0).typ
      var exact: seq[NxRef]
      for r in cands:
        let ps = r.sym.params
        if r.sym.generics.len == 0 and ps.len >= 2 and nxRsSame(ps[0].typ, v.typ) and nxRsSame(ps[1].typ, it):
          exact.add r
      if exact.len > 0: return nxRsCandidates(c, exact, w.f.path, line)
  nxRsCandidates(c, cands, w.f.path, line)

func nxRsWordBefore(t: string, q: int): string =
  ## the identifier that ends right before t[q]
  var b = q
  while b > 0 and nxIsIdent(t[b - 1]): dec b
  t[b ..< q]

func nxRsQuoted(t: string, a: int): (int, int) =
  ## the backquotes around position `a` of the line when it is inside a quoted name (`callback=`, `==`), else -1
  if a <= 0: return (-1, -1)
  var lb = a - 1
  while lb >= 0 and t[lb] notin {'`', ' ', '(', ')', ',', '"'}: dec lb
  if lb < 0 or t[lb] != '`': return (-1, -1)
  var rb = a
  while rb < t.len and t[rb] notin {'`', ' ', '(', ')', ',', '"'}: inc rb
  if rb >= t.len or t[rb] != '`': return (-1, -1)
  (lb, rb)

proc nxRsConvOperands(c: var NxRsCtx, w: var NxRsBody, line, a, e: int, binary: bool): bool =
  ## (converters that do something are seen) the operands of a keyword operator (x in s, a div b, not x): false
  ## when one may be converted — its type not known, or one a converter takes
  let t = w.lines[line]
  let locs = nxLocals(w.f, w.lines, line, a)
  var ops: seq[string]
  if binary:
    var i = a
    while i > 0 and t[i - 1] == ' ': dec i
    let ls = nxOperandBack(t, i)
    if ls >= i:
      c.why = "operands a converter may take"
      return false
    ops.add t[ls ..< i]
  var j = e
  while j < t.len and t[j] == ' ': inc j
  let re = nxOperandFwd(t, j)
  if re <= j:
    c.why = "operands a converter may take"
    return false
  ops.add t[j ..< re]
  var overloads: seq[NxRef]
  let opName = t[a ..< e]
  for r in nxLookup(w.sc, (if opName in ["in", "notin"]: "contains" else: opName)):
    if r.sym.kind in NxRoutineKinds: overloads.add r
  for x in ops:
    inc c.steps
    if nxRsConvTaken(w, nxTypeOfExpr(w.f, w.sc, locs, x, line, 0).typ, overloads):
      c.why = "operands a converter may take"
      return false
  true

proc nxRsScan(c: var NxRsCtx, w: var NxRsBody, line, fromCol: int, exc: var seq[NxExc], toCol = high(int)): bool =
  ## the calls on one line of the body (from fromCol): what they raise, added to `exc` (false: not sure)
  if line >= w.lines.len: return true
  let t = w.lines[line]
  if w.tainted.len > 0:
    # a generic routine's (or a template's) call on its arguments: which overload, what it raises, is decided where
    # it is used — not here
    var st0: NxLexState
    var hasT, hasCall = false
    for (a, e) in nxLexRuns(t, st0, false):
      if a < fromCol or a >= toCol: continue
      let nm = t[a ..< e]
      if nxNorm(nm) in w.tainted: hasT = true
      elif nm notin NxKeywords:
        for r in nxLookup(w.sc, nm):
          if r.sym.kind in NxRoutineKinds: hasCall = true
    if hasT:
      var st1: NxLexState
      for (a, e) in nxLexRuns(t, st1, true):
        if a >= fromCol and a < toCol and t[a ..< e] notin ["=", ":", ".", "..", "..<"]: hasCall = true
      for q in max(0, fromCol) ..< min(t.len, toCol):
        if t[q] in {'(', '['}: hasCall = true
      if hasCall:
        if c.why.len == 0: c.why = "a call on what its type parameters decide"
        return false
  # (the names inside {. … .} are pragmas, not calls)
  var prag = newSeq[bool](t.len)
  block:
    var q = 0
    while true:
      let k = t.find("{.", q)
      if k < 0: break
      let e2 = t.find(".}", k + 2)
      let stop = if e2 < 0: t.len else: e2 + 2
      for x in k ..< stop: prag[x] = true
      q = stop
  var st: NxLexState
  for (a, e) in nxLexRuns(t, st, false):
    if a < fromCol or a >= toCol or prag[a]: continue
    let name = t[a ..< e]
    if name in NxKeywords:
      case name
      of "proc", "func", "iterator", "method", "template", "macro", "converter":
        if c.why.len == 0: c.why = "an anonymous proc"
        return false                                 # (an anonymous routine: not looked into)
      of "try":
        if c.why.len == 0: c.why = "a try expression"
        return false
      of "raise":
        if c.why.len == 0: c.why = "a raise inside an expression"
        return false
      of "in", "notin":
        # x in y: y's contains — the system's own for sets, a seq, a string, an array of its types
        var q = e
        while q < t.len and t[q] == ' ': inc q
        let ye = nxOperandFwd(t, q)
        if ye <= q: return false
        inc c.steps
        let yt = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, line, a), t[q ..< ye], line, 0).typ
        if not (nxRsBuiltinType(yt) or nxStripMods(yt).startsWith("set[") or nxRsMagicOperand(w.sc, yt)):
          if not (t[q] == '{' or t[q] == '['):
            if c.why.len == 0: c.why = "`in` on " & yt
            return false
        if w.convs.len > 0 and not nxRsConvOperands(c, w, line, a, e, true): return false
      of "and", "or", "not", "xor", "div", "mod", "shl", "shr":
        if w.convs.len > 0 and not nxRsConvOperands(c, w, line, a, e, name != "not"): return false
        var cands: seq[NxRef]
        for r in nxLookup(w.sc, name):
          if r.sym.kind in NxRoutineKinds: cands.add r
        if cands.len > 0:
          let x = nxRsCandidates(c, cands, w.f.path, line)
          if not x.known:
            c.why = x.why
            return false
          nxRsMerge(exc, x)
      else: discard
      continue
    let (qa, qe) = nxRsQuoted(t, a)
    if qa >= 0:
      # (a quoted name: `proc` in a pragma … — not a call; `callback=`(f, cb): one the engine does not follow)
      if qe + 1 < t.len and t[qe + 1] == '(':
        if c.why.len == 0: c.why = "a call by a quoted name"
        return false
      continue
    if a > 0 and t[a - 1] == '\'': continue         # (a number's type: 0'i32)
    let x = nxRsIdentKind(c, w, line, a, e)
    if not x.known:
      c.why = x.why
      return false
    nxRsMerge(exc, x)
  var st2: NxLexState
  for (a, e) in nxLexRuns(t, st2, true):
    if a < fromCol or a >= toCol or prag[a]: continue
    let (qa, qe) = nxRsQuoted(t, a)
    if qa >= 0:
      if qe + 1 < t.len and t[qe + 1] == '(':
        if c.why.len == 0: c.why = "a call by a quoted name"
        return false
      continue                                       # (`==` as a name, not an operator)
    let x = nxRsOp(c, w, line, a, e)
    if not x.known:
      c.why = x.why
      return false
    nxRsMerge(exc, x)
  # indexing: x[i] — a `[` right after a name, a `)` or a `]` (not seq[int] in a type: the receiver tells)
  var st3: NxLexState
  var code = newSeq[bool](t.len)
  for (a, e) in nxLexRuns(t, st3, false):
    for q in a ..< e: code[q] = true
  var inStr = false
  var q = max(fromCol, 1)
  while q < min(t.len, toCol):
    if t[q] == '"': inStr = not inStr
    elif t[q] == '#' and not inStr: break
    elif prag[q]: discard
    elif t[q] == '[' and not inStr and (code[q - 1] or t[q - 1] in {')', ']'}) and
         not (code[q - 1] and nxRsWordBefore(t, q) in NxKeywords):              # (cast[T], addr …)
      let x = nxRsIndex(c, w, line, q)
      if not x.known:
        c.why = x.why
        return false
      nxRsMerge(exc, x)
    elif t[q] == '{' and not inStr and code[q - 1] and not (q + 1 < t.len and t[q + 1] == '.'):
      if c.why.len == 0: c.why = "a {} accessor"
      return false                                   # x{…}: a `{}` of x's type (JsonNode …): not looked into
    inc q
  true

proc nxRsRaiseOf(c: var NxRsCtx, w: var NxRsBody, st: NxRsLine, at: int, exc: var seq[NxExc]): bool =
  ## a raise statement whose expression starts at column `at` of st.line (-1: a bare raise)
  if c.fx:
    # (fx) raising is no side effect: only what its expression calls
    if at < 0: return true
    if not nxRsScan(c, w, st.line, at, exc): return false
    for l in st.line + 1 .. st.last:
      if not nxRsScan(c, w, l, 0, exc): return false
    return true
  if at < 0:
    if w.excepts.len > 0 and w.excepts[^1].len == 1:
      let (ok, e) = nxRsExc(w.sc, w.excepts[^1][0])
      if not ok: return false
      nxRsAdd(exc, e)
    else:
      nxRsAdd(exc, NxExc(name: "Exception", anc: @["RootObj"]))
    return true
  let t = w.lines[st.line]
  var x = t[at .. ^1]
  x = nxCodeOf(x)
  if st.last > st.line:
    for l in st.line + 1 .. st.last: x.add " " & nxCodeOf(w.lines[l])
  x = x.strip
  var typ = ""
  if x.startsWith("newException(") or x.startsWith("newException ("):
    let p = x.find('(')
    let ce = nxMatchClose(x, p)
    if ce < 0: (c.why = "a raise it cannot read"; return false)
    let args = nxSplitTop(x[p + 1 ..< ce], {','})
    if args.len < 2: (c.why = "a raise it cannot read"; return false)
    typ = args[0].strip
    # the message's calls (not newException itself: a template that only makes the object)
    let ne = t.find("newException", at)
    if ne < 0: (c.why = "a raise it cannot read"; return false)
    let p2 = t.find('(', ne)
    if not nxRsScan(c, w, st.line, p2 + 1, exc): return false
    for l in st.line + 1 .. st.last:
      if not nxRsScan(c, w, l, 0, exc): return false
  else:
    inc c.steps
    let v = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, st.line, at), x, st.line, 0)
    typ = v.typ
    if x.startsWith("(ref ") and typ.len == 0:
      let ce = nxMatchClose(x, 0)
      if ce > 0: typ = x[1 ..< ce]
    if typ.len == 0: (c.why = "raise of what it cannot tell the type of: " & x; return false)
    if not nxRsScan(c, w, st.line, at, exc): return false
    for l in st.line + 1 .. st.last:
      if not nxRsScan(c, w, l, 0, exc): return false
  # (ref exceptn)(…) or newException(exceptn, …) with exceptn a parameter typedesc[X]: an X
  var tt = typ.strip
  if tt.startsWith("ref "): tt = tt[4 .. ^1].strip
  if tt.allCharsInSet(IdentChars):
    for x in nxLocals(w.f, w.lines, st.line, at):
      if x.kind == nxParam and nxNorm(x.name) == nxNorm(tt):
        let pt = nxStripMods(x.typ)
        if pt.startsWith("typedesc[") and pt.endsWith("]"): typ = pt[9 ..< pt.high]
        else: (c.why = "raise of a parameter " & tt; return false)
  let (ok, e) = nxRsExc(w.sc, typ)
  if not ok: (c.why = "raise of " & typ; return false)
  nxRsAdd(exc, e)
  true

proc nxRsLines(lines: seq[string], a, b: int): seq[NxRsLine] =
  ## the body's statements: code without comments, a line that goes on below joined (open brackets, a trailing
  ## comma or operator)
  var st: NxLexState
  var code, doc: string
  var l = a
  while l <= min(b, lines.high):
    let wasIn = st.blockDepth > 0 or st.inTriple
    var depth = 0
    nxSplitLine(lines[l], st, code, doc, depth)
    let t = code.strip
    if wasIn or t.len == 0:
      inc l
      continue
    var s = NxRsLine(ind: leadWs(lines[l]), text: t, line: l, last: l, col: leadWs(lines[l]))
    var guard = 0
    while (depth > 0 or s.text.endsWith(",") or s.text.endsWith("&") or s.text.endsWith("+") or
           s.text.endsWith(" and") or s.text.endsWith(" or") or s.text.endsWith("|")) and
          s.last < min(b, lines.high) and guard < 60:
      inc s.last
      var c2, d2: string
      nxSplitLine(lines[s.last], st, c2, d2, depth)
      let x = c2.strip
      if x.len > 0: s.text.add " " & x
      inc guard
    result.add s
    l = s.last + 1

func nxRsHeadColon(t: string): int =
  ## the colon that ends a block statement's head (if c: …, for x in y: …, of a, b: …), -1 when none
  nxFindTop(t, ':')

proc nxRsScanStmt(c: var NxRsCtx, w: var NxRsBody, s: NxRsLine, fromCol: int, exc: var seq[NxExc],
                  toCol = high(int)): bool =
  ## the calls of a statement over its lines
  if not nxRsScan(c, w, s.line, fromCol, exc, (if s.last == s.line: toCol else: high(int))): return false
  for l in s.line + 1 .. s.last:
    if not nxRsScan(c, w, l, 0, exc, (if l == s.last: toCol else: high(int))): return false
  true

proc nxRsBlock(c: var NxRsCtx, w: var NxRsBody, ls: seq[NxRsLine], i: var int, ind: int,
               exc: var seq[NxExc]): bool =
  ## the statements at indentation `ind` (and what is deeper under them) from ls[i] on
  while i < ls.len and ls[i].ind >= ind:
    if c.cut: return false
    if not nxRsStmt(c, w, ls, i, exc):
      if c.fx and nxFxHas(exc): c.impure = true
      return false
    if c.fx and nxFxHas(exc):
      c.impure = true                  # (fx) a side effect: what follows does not change that
      return false
  true

proc nxRsSub(c: var NxRsCtx, w: var NxRsBody, ls: seq[NxRsLine], i: var int, ind: int,
             exc: var seq[NxExc]): bool =
  ## the block under a statement at indentation `ind` (the lines deeper than it)
  if i < ls.len and ls[i].ind > ind: return nxRsBlock(c, w, ls, i, ls[i].ind, exc)
  true

proc nxRsInline(c: var NxRsCtx, w: var NxRsBody, s: NxRsLine, at: int, exc: var seq[NxExc]): bool =
  ## a statement written after a block head's colon (if x: raise …, else: foo()): read as one of its own
  let t = w.lines[s.line]
  var k = at
  while k < t.len and t[k] == ' ': inc k
  if k >= t.len or t[k] == '#': return true
  let one = @[NxRsLine(ind: s.ind + 1, text: nxCodeOf(t[k .. ^1]), line: s.line, last: s.last, col: k)]
  var j = 0
  nxRsStmt(c, w, one, j, exc)

proc nxRsColonCol(w: NxRsBody, s: NxRsLine): int =
  ## where the colon ending the head of statement `s` is on its line (-1: on another line, or none)
  let t = w.lines[s.line]
  var depth = 0
  var k = s.col
  var inStr = false
  while k < t.len:
    let ch = t[k]
    if ch == '"': inStr = not inStr
    elif inStr: discard
    elif ch == '#': return -1
    elif ch == '\'' and nxCharEnd(t, k) > k: k = nxCharEnd(t, k)
    elif ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif ch == ':' and depth == 0 and not (k + 1 < t.len and t[k + 1] == ':'): return k
    inc k
  -1

proc nxRsStmt(c: var NxRsCtx, w: var NxRsBody, ls: seq[NxRsLine], i: var int, exc: var seq[NxExc]): bool =
  ## one statement (and the block under it)
  let s = ls[i]
  let ind = s.ind
  let t = s.text
  let (kw, _) = nxName(t, 0)
  inc i
  if t.startsWith("{."):
    # a pragma statement: {.cast(raises: [X]).}: a block that raises what it says; {.cast(gcsafe).}:,
    # {.gcsafe.}: a block read as usual; {.push ….}, {.warning[…]: off.}: nothing to run
    let pe = t.find(".}")
    if pe < 0:
      c.why = "a pragma it cannot read"
      return false
    let p = t[2 ..< pe]
    let blockFollows = t[pe + 2 .. ^1].strip.startsWith(":")
    if c.fx:
      # (fx) {.cast(noSideEffect).}: a block whose side effects do not count; {.emit.}: C the engine does not read
      if p.startsWith("cast(") and nxFxPragma(p, "noSideEffect"):
        while i < ls.len and ls[i].ind > ind: inc i
        return true
      if p.startsWith("emit"):
        c.why = "an emit"
        return false
      if blockFollows: return nxRsSub(c, w, ls, i, ind, exc)
      return true
    if p.startsWith("cast(") and "raises" in p:
      let a = p.find('[')
      let b = if a >= 0: nxMatchClose(p, a) else: -1
      if b <= a:
        c.why = "a cast pragma"
        return false
      let x = nxRsListOf(w.sc, p[a + 1 ..< b])
      if not x.known:
        c.why = x.why
        return false
      nxRsMerge(exc, x)
      while i < ls.len and ls[i].ind > ind: inc i
      return true
    if blockFollows: return nxRsSub(c, w, ls, i, ind, exc)
    return true
  if c.fx and kw == "asm":
    c.why = "an asm statement"
    return false
  case kw
  of "proc", "func", "iterator", "method", "converter", "template", "macro", "type", "const", "static", "asm",
     "runnableExamples", "mixin", "bind":
    # declared here (a nested routine runs when it is called — a call of it is not followed), or compile time
    while i < ls.len and ls[i].ind > ind: inc i
    return true
  of "when":
    var taken = false
    var nimvm = false
    var j = i - 1
    while j < ls.len and ls[j].ind == ind:
      let (bw, bwe) = nxName(ls[j].text, 0)
      if not (if j == i - 1: bw == "when" else: bw in ["elif", "else"]): break
      var v = 1
      if bw != "else":
        let cc = nxRsHeadColon(ls[j].text)
        if cc < 0: (c.why = "a when it cannot read"; return false)
        let cond = ls[j].text[bwe ..< cc].strip
        if cond == "nimvm": v = 2                   # (when nimvm: the compiler tracks both branches)
        else:
          # (threads are on unless the project says otherwise: Nim 2's default, what the engine assumes too)
          v = nxWhen(cond.replace("compileOption(\"threads\")", "defined(threads)"))
          if v < 0:
            let ct = nxCtEval(w.f, cond)
            if ct.kind == ctBool: v = (if ct.i != 0: 1 else: 0)
          if v < 0 and not taken: (c.why = "when " & cond; return false)
      let colon = nxRsColonCol(w, ls[j])
      i = j + 1
      if v == 2 or (bw == "else" and nimvm):
        nimvm = true
        if colon >= 0 and not nxRsInline(c, w, ls[j], colon + 1, exc): return false
        if not nxRsSub(c, w, ls, i, ind, exc): return false
      elif v == 1 and not taken:
        taken = true
        if colon >= 0 and not nxRsInline(c, w, ls[j], colon + 1, exc): return false
        if not nxRsSub(c, w, ls, i, ind, exc): return false
      else:
        while i < ls.len and ls[i].ind > ind: inc i
      j = i
    return true
  of "try":
    let colon = nxRsColonCol(w, s)
    var tryExc: seq[NxExc]
    if colon >= 0 and not nxRsInline(c, w, s, colon + 1, tryExc): return false
    if not nxRsSub(c, w, ls, i, ind, tryExc): return false
    var after: seq[NxExc]          # raised in the except and finally branches: not caught by this try
    var caughtAll = false
    var caught: seq[string]
    while i < ls.len and ls[i].ind == ind:
      let b = ls[i]
      let (bw, bwe) = nxName(b.text, 0)
      if bw notin ["except", "finally"]: break
      inc i
      var types: seq[string]
      if bw == "except":
        let cc = nxRsColonCol(w, b)
        var head = (if cc >= 0: w.lines[b.line][0 ..< cc] else: b.text).strip
        head = head[6 .. ^1].strip
        let asK = head.find(" as ")
        if asK >= 0: head = head[0 ..< asK].strip
        if head.len == 0 or c.fx: caughtAll = true     # (fx: what is caught does not matter)
        else:
          for p in nxSplitTop(head, {','}):
            let x = p.strip
            let (r, _) = nxObjectDef(w.sc, x)
            if r.file == nil: (c.why = "except " & x; return false)
            types.add r.sym.name
            caught.add r.sym.name
        w.excepts.add types
        let okb = (cc < 0 or nxRsInline(c, w, b, cc + 1, after)) and nxRsSub(c, w, ls, i, ind, after)
        w.excepts.setLen(w.excepts.len - 1)
        if not okb: return false
      else:
        let cc = nxRsColonCol(w, b)
        if cc >= 0 and not nxRsInline(c, w, b, cc + 1, after): return false
        if not nxRsSub(c, w, ls, i, ind, after): return false
    if not caughtAll or c.fx:              # (fx: a side effect is not caught)
      for e in tryExc:
        var hit = false
        for ct in caught:
          if nxRsCatches(e, ct): hit = true
        if not hit: nxRsAdd(exc, e)
    for e in after: nxRsAdd(exc, e)
    return true
  of "raise":
    var k = s.col + 5
    let tl = w.lines[s.line]
    while k < tl.len and tl[k] == ' ': inc k
    let bare = k >= tl.len or tl[k] == '#' or t.strip == "raise"
    return nxRsRaiseOf(c, w, s, (if bare: -1 else: k), exc)
  of "if", "elif", "while", "for", "case", "of", "else", "block", "defer", "except", "finally":
    let colon = nxRsColonCol(w, s)
    let headTo = if colon >= 0: colon else: high(int)
    if kw == "for":
      # for x in expr: the iterator — written (a call) or the one of expr's type (items, pairs)
      let tl = w.lines[s.line]
      let inK = tl.find(" in ", s.col)
      if inK < 0: (c.why = "a for it cannot read"; return false)
      let a = inK + 4
      let iterText = (if colon >= 0: tl[a ..< colon] else: tl[a .. ^1]).strip
      if not nxRsScanStmt(c, w, s, a, exc, headTo): return false
      var explicit = false
      var p = iterText.len
      while p > 0 and iterText[p - 1] == ' ': dec p
      if p > 0 and iterText[p - 1] == ')':
        explicit = true                          # foo(x), x.foo(y): a call (looked at above)
      elif nxFindRange(iterText) >= 0 or ".." in iterText:
        explicit = true                          # 0 ..< n: the system's own
      else:
        var q = p
        while q > 0 and nxIsIdent(iterText[q - 1]): dec q
        if q > 0 and iterText[q - 1] == '.':
          # x.items, x.pairs, s.split(','): is it an iterator?
          let col = a + q
          let (refs, _, _) = nxTargets(w.f, w.lines, s.line, col)
          for r in refs:
            if r.sym.kind == nxIterator: explicit = true
      if not explicit:
        inc c.steps
        let v = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, s.line, a), iterText, s.line, 0)
        if not nxRsBuiltinType(v.typ):
          # the iterator of its type: items (one loop variable) or pairs (two) — the overload taking it exactly
          let vars = nxSplitTop(tl[s.col + 3 ..< inK], {','})
          let itName = if vars.len >= 2: "pairs" else: "items"
          var exact, fits: seq[NxRef]
          if v.typ.len > 0:
            for r in nxLookup(w.sc, itName):
              if r.sym.kind != nxIterator or r.sym.params.len == 0: continue
              if nxRsSame(r.sym.params[0].typ, v.typ): exact.add r
              elif nxCompatP(w.sc, r.sym.params[0], r.sym.generics, v.typ) > 0: fits.add r
          let cands = if exact.len > 0: exact else: fits
          if cands.len == 0:
            c.why = "for … in " & iterText & (if v.typ.len > 0: " (" & v.typ & ")" else: "")
            return false
          let x = nxRsCandidates(c, cands, w.f.path, s.line)
          if not x.known:
            c.why = x.why
            return false
          nxRsMerge(exc, x)
    elif kw notin ["else", "block", "defer", "finally", "except", "of"]:
      if not nxRsScanStmt(c, w, s, s.col + kw.len, exc, headTo): return false
    if colon >= 0 and kw != "of" and not nxRsInline(c, w, s, colon + 1, exc): return false
    if colon >= 0 and kw == "of" and not nxRsInline(c, w, s, colon + 1, exc): return false
    if kw == "case":
      # its branches: `of` / `elif` / `else` at the same indentation (or deeper, the first one says)
      if i < ls.len and ls[i].ind > ind: return nxRsSub(c, w, ls, i, ind, exc)
      return true
    return nxRsSub(c, w, ls, i, ind, exc)
  of "let", "var":
    # its values (one, or a section below)
    if c.fx:
      # (fx) a {.global.} variable is global state: a side effect
      var l = i - 1
      while l < ls.len and (l == i - 1 or ls[l].ind > ind):
        if "{." in ls[l].text and nxFxPragma(ls[l].text, "global"):
          if c.why.len == 0: c.why = "a {.global.} variable"
          nxRsAdd(exc, NxExc(name: NxFxMark))
          return true
        inc l
    if w.convs.len > 0:
      # (converters that do something are seen) let x: T = v — what goes in each one
      var l = i - 1
      while l < ls.len and (l == i - 1 or ls[l].ind > ind):
        if not nxRsConvStmt(c, w, ls[l], true, exc): return false
        inc l
    if not nxRsScanStmt(c, w, s, s.col + kw.len, exc): return false
    let colon = nxRsColonCol(w, s)
    if colon >= 0 and t.endsWith(":"): (c.why = "a block as a value"; return false)
    if i < ls.len and ls[i].ind > ind:
      let sub = ls[i].ind
      while i < ls.len and ls[i].ind >= sub:
        if ls[i].text.endsWith(":") and ls[i].ind == sub: (c.why = "a block as a value"; return false)
        if not nxRsScanStmt(c, w, ls[i], ls[i].col, exc): return false
        inc i
    return true
  of "return", "discard", "yield", "result", "break", "continue":
    if kw in ["break", "continue"]: return true
    if w.retConv and kw in ["return", "yield"] and t.len > kw.len:
      # (a converter makes what the routine gives back) what this gives
      inc c.steps
      let v = nxTypeOfExpr(w.f, w.sc, nxLocals(w.f, w.lines, s.line, s.col), t[kw.len .. ^1].strip, s.line, 0).typ
      if not nxRsConvAt(c, w, nxStripValMods(w.rs.ret), v, exc): return false
    if not nxRsScanStmt(c, w, s, s.col + (if kw == "result": 0 else: kw.len), exc): return false
  else:
    if w.convs.len > 0 and not nxRsConvStmt(c, w, s, false, exc): return false    # (x = v, x.f = v)
    if not nxRsScanStmt(c, w, s, s.col, exc): return false
  if t.endsWith(":") or t.endsWith("do:"):
    # a call with a block (withLock l:, a template's body): the block's statements too
    return nxRsSub(c, w, ls, i, ind, exc)
  # lines deeper than this one that do not belong to a block: an expression that goes on
  while i < ls.len and ls[i].ind > ind:
    if not nxRsScanStmt(c, w, ls[i], ls[i].col, exc): return false
    inc i
  true

proc nxRsBodyStart(lines: seq[string], s: NxSym): (int, int) =
  ## where a routine's body starts: (line, column) — the line after its header, or after `=` on the header's line
  let (h, hl) = nxHeaderLast(lines, s)
  var k = h.find(s.name)
  if k < 0: k = 0
  let p = h.find('(', k)
  var from0 = k + s.name.len
  if p >= 0:
    let pc = nxMatchClose(h, p)
    if pc > p: from0 = pc + 1
  let eq = nxFindTop(h, '=', from0)
  if eq < 0: return (-1, 0)
  let rest = h[eq + 1 .. ^1].strip
  if rest.len == 0: return (hl + 1, 0)
  let col = lines[hl].rfind(rest)
  if col < 0: return (-1, 0)
  (hl, col)

proc nxRsGenericParams(sc: NxScope, s: NxSym): seq[string] =
  ## a routine's generic parameters — the written ones, and the parameters of a type class (A | B, SomeInteger,
  ## auto, a concept …), which make it generic too
  result = nxGenericNames(s.generics)
  for p in s.params:
    let t = nxStripMods(p.typ).strip
    if t.len == 0: continue
    var classy = '|' in t or t in ["auto", "any", "typed", "untyped", "typedesc", "seq", "set", "array", "tuple",
                                    "proc", "object", "enum", "ref", "ptr", "distinct", "range", "openArray",
                                    "varargs", "iterator", "type"] or t.startsWith("static") or
                t.startsWith("typedesc") or t.startsWith("type ") or t.startsWith("type[")
    for (cls, _) in NxTypeClasses:
      if t == cls: classy = true
    if not classy and t.allCharsInSet(IdentChars):
      for r in nxTypeSyms(sc, t):
        if r.sym.typ.startsWith("concept"): classy = true
    if classy: result.add p.name

proc nxRsAnalyse(c: var NxRsCtx, r: NxRef, lr: NxLinesRef): NxRaises =
  ## what the body of routine `r` raises
  template s: untyped = r.sym
  template lines: untyped = lr.lines
  let (bl, bc) = nxRsBodyStart(lines, s)
  if bl < 0: return nxRsFail("no body")
  var w = NxRsBody(f: r.file, sc: nxRsScope(c, r.file), lr: lr, rs: s)
  let gens = nxRsGenericParams(w.sc, s)
  let open = gens.len > 0 or s.kind in {nxTemplate, nxMacro}
  for g in nxGenericNames(s.generics): w.genNames.incl nxNorm(g)
  for x in nxLocals(r.file, lines, min(s.endLine, lines.high), high(int) div 2, everything = true):
    if x.kind in NxRoutineKinds: continue      # (a template or proc declared inside: a call of it, not a value)
    w.localNames.incl nxNorm(x.name)
    if open:
      # the names whose type is decided by the arguments: generic, untyped, or (a local) worked out from them
      # (a seq[T] or openArray[T] is not: the system's len, add, [] are its own whatever T is)
      let pt = nxStripMods(x.typ)
      var dep = pt.len == 0 or pt in ["untyped", "typed", "auto", "any", "typedesc"] or
                pt.startsWith("varargs[untyped") or pt.startsWith("varargs[typed") or pt.startsWith("typedesc")
      for g in gens:
        if x.kind == nxParam and nxNorm(x.name) == nxNorm(g): dep = true       # (a parameter of a type class)
        if nxNorm(pt) == nxNorm(g): dep = true
      if dep and x.kind == nxResult and pt.len > 0 and pt notin gens: dep = false
      if dep: w.tainted.incl nxNorm(x.name)
  if not nxRsConvSetup(c, w, s):
    return nxRsFail(s.name & ": " & (if c.why.len > 0: c.why else: "a converter"))
  var ls: seq[NxRsLine]
  if bc > 0 or bl <= s.line:
    let t = lines[bl]
    ls.add NxRsLine(ind: 1000, text: nxCodeOf(t[bc .. ^1]), line: bl, last: bl, col: bc)
    for x in nxRsLines(lines, bl + 1, s.endLine): ls.add NxRsLine(ind: 1000 + x.ind, text: x.text, line: x.line,
                                                                     last: x.last, col: x.col)
  else:
    ls = nxRsLines(lines, bl, s.endLine)
  if ls.len == 0: return NxRaises(known: true)
  var i = 0
  var exc: seq[NxExc]
  if w.retConv and not nxRsConvLast(c, w, ls, exc):
    return nxRsFail(s.name & ": " & c.why)
  if not nxRsBlock(c, w, ls, i, ls[0].ind, exc):
    if c.fx and (c.impure or nxFxHas(exc)):
      return nxFxImpure(s.name & (if c.why.len > 0: ": " & c.why else: ""))    # (fx: a side effect, sure)
    return nxRsFail(s.name & ": " & (if c.why.len > 0: c.why else: "a statement it cannot read"))
  if i < ls.len: return nxRsFail(s.name & ": a body it cannot read")
  NxRaises(known: true, excs: exc)

const NxRsNoRaise = ["newException", "doAssert", "assert", "likely", "unlikely", "unsafeAddr", "defined", "declared",
                     "compiles", "astToStr", "instantiationInfo", "currentSourcePath", "onFailedAssert", "new",
                     "alloc", "alloc0", "allocShared", "allocShared0", "dealloc", "deallocShared", "realloc",
                     "reallocShared", "create", "createU", "createShared", "createSharedU", "resize", "isNil"]
  ## system routines (templates and generic ones) that raise no exception whatever they are given
const NxFxNoEffect = ["newException", "doAssert", "assert", "likely", "unlikely", "unsafeAddr", "defined", "declared",
                  "compiles", "astToStr", "instantiationInfo", "currentSourcePath", "isNil", "debugEcho", "new",
                  "copyMem", "moveMem", "zeroMem", "cmpMem", "equalMem"]
  ## (fx) system routines (templates and generic ones) without side effects whatever they are given

var nxFxFwdCache: Table[string, (string, Table[string, seq[(string, int)]])]
  ## (fx) a module made of several files (include) → (their stamps, name → the forward declarations in them)

proc nxFxModuleFiles(path: string): seq[string] =
  ## the files of the module `path` belongs to, when it is made of several (include): the includer and what it
  ## includes — @[] for a module of one file
  let top = nxTopIncluder(path)
  let root = if top.len > 0: top else: path
  let incs = nxIncludesOf(root)
  if incs.len == 0: return
  result.add root
  for p in incs:
    if p notin result: result.add p
    for q in nxIncludesOf(p):
      if q notin result: result.add q

proc nxFxForwardElsewhere(c: var NxRsCtx, target: NxRef, callPath: string): int =
  ## (fx) a routine of a module made of several files whose forward declaration is in another of its files, called
  ## from that module (where the compiler may not have seen its body yet): 0 no · 1 yes, declared without side
  ## effects · 2 yes, not so declared
  if target.file.path notin c.modFiles: c.modFiles[target.file.path] = nxFxModuleFiles(target.file.path)
  let files = c.modFiles[target.file.path]
  if files.len == 0 or callPath notin files: return 0
  let root = files[0]
  var st = ""
  if root notin c.fwdFresh:
    for p in files: st.add nxRsStamp(c, p) & ";"
  if root notin c.fwdFresh and (root notin nxFxFwdCache or nxFxFwdCache[root][0] != st):
    var t: Table[string, seq[(string, int)]]
    for p in files:
      let g = nxLoad(p)
      if g == nil: continue
      let gl = nxLayLinesRef(p)
      for j, s in g.syms:
        if s.kind in NxRoutineKinds and not s.made and s.endLine <= s.line and nxIsForward(gl.lines, s):
          t.mgetOrPut(nxNorm(s.name), @[]).add (p, j)
    if nxFxFwdCache.len > 64: nxFxFwdCache.clear()
    nxFxFwdCache[root] = (st, t)
  c.fwdFresh.incl root
  let ts = target.sym
  for (p, j) in nxFxFwdCache[root][1].getOrDefault(nxNorm(ts.name)):
    if p == target.file.path: continue
    let g = nxLoad(p)
    if g == nil or j >= g.syms.len: continue
    let s = g.syms[j]
    if s.name == ts.name and nxSameSig(s, ts):
      return (if s.kind == nxFunc or nxFxPragma(s.pragmas, "noSideEffect"): 1 else: 2)
  0

proc nxRsRewrites(sc: NxScope, prag: string): string =
  ## a pragma of a routine that is a macro, or a template that is not a mere mark ({.pragma.}): what it makes of the
  ## routine is not what is written — its name ("" none; `since` only keeps it or leaves it out)
  if prag.len == 0: return
  for (n, _) in nxLayPragmas(prag):
    if n.len == 0 or not nxIsIdent(n[0]) or n in ["since", "raises", "tags", "inline", "deprecated", "gcsafe"]: continue
    for r in nxLookup(sc, n):
      if r.sym.kind == nxMacro: return n
      if r.sym.kind == nxTemplate and "pragma" notin r.sym.pragmas.split({',', ' '}): return n

proc nxRsRoutine(c: var NxRsCtx, r: NxRef, callPath: string, callLine: int): NxRaises =
  ## what a call of routine `r` (from callPath:callLine) raises
  template s: untyped = r.sym
  let ru = nxRsUnit(c, r.file, s.line)
  nxRsDep(c, if ru.len > 0: ru else: r.file.path)
  let lr = nxLayLinesRef(r.file.path)
  template lines: untyped = lr.lines
  let prag = s.pragmas
  if c.fx:
    # (fx) what it declares: a func or {.noSideEffect.} has none (the compiler checks it), {.sideEffect.} has;
    # the compiler's magic has none (but echo, which says {.sideEffect.}), nor what is imported from C
    if s.kind == nxFunc or nxFxPragma(prag, "noSideEffect"): return NxRaises(known: true)
    if nxFxPragma(prag, "sideEffect"): return nxFxImpure(s.name & " has side effects")
  else:
    let (has, list) = nxRsDeclared(r, lines)
    if has: return nxRsListOf(nxRsScope(c, r.file), list)
  let isSystem = nxInSystem(r.file.path)
  if "magic" in prag or "importc" in prag or "importcpp" in prag or "importjs" in prag or "importobjc" in prag:
    if "exportc" notin prag: return NxRaises(known: true)
  if "effectsOf" in prag: return nxRsFail(s.name & " raises what the routine passed to it does")
  if "borrow" in prag:
    # a distinct type's routine borrowed from its base: the system's own for a number or a string
    if s.params.len > 0:
      var bt = nxStripMods(s.params[0].typ)
      for _ in 0 .. 3:
        let refs = nxTypeSyms(nxRsScope(c, r.file), bt)
        if refs.len != 1: break
        let d = refs[0].sym.typ.strip
        if d.startsWith("distinct "): bt = d[9 .. ^1].strip
        else: break
      if bt in NxRsBuiltinElems: return NxRaises(known: true)
    return nxRsFail(s.name & " is borrowed")
  case s.kind
  of nxMethod: return nxRsFail(s.name & " is a method")
  of nxMacro: return nxRsFail(s.name & " is a macro")
  of nxTemplate:
    if "dirty" in prag: return nxRsFail(s.name & " is a dirty template")
    if not c.fx:
      for l in s.line .. min(s.endLine, lines.high):
        let x = nxCodeOf(lines[l])
        if x.startsWith("try") or x.startsWith("except"):
          return nxRsFail(s.name & " is a template with a try")   # (it may catch what its block raises)
  else: discard
  if (isSystem or r.file.path.endsWith("/std/assertions.nim")) and
     ((c.fx and s.name in NxFxNoEffect) or (not c.fx and s.name in NxRsNoRaise)):
    return NxRaises(known: true)
  if s.kind == nxIterator and (r.file.path.endsWith("/system/iterators.nim") or
                               r.file.path.endsWith("/system/iterators_1.nim")):
    return NxRaises(known: true)     # (the system's items, pairs, countup … over its own types: they raise nothing)
  if "error" in prag.split({',', ' ', ':'}): return NxRaises(known: true)       # (a call of it does not compile)
  # the routine with the body (a forward declaration's: the later one); a call before that body: Exception, as the
  # compiler has not seen it yet
  var target = r
  if nxIsForward(lines, s):
    let b = nxBodyOf(r.file, lines, s)
    if b < 0:
      if isSystem and not c.fx: return NxRaises(known: true)   # (the system's routines without a body are its magic)
      return nxRsFail(s.name & " has no body here")
    target = NxRef(file: r.file, idx: int32(b))
  let fw = nxForwardOf(target.file, lines, target.sym)
  if fw >= 0 and callPath == target.file.path and callLine >= 0 and callLine < target.sym.line:
    let fs = target.file.syms[fw]
    if c.fx:
      # (fx) the compiler knows only what the forward declaration says: no side effects when it says so
      if fs.kind == nxFunc or nxFxPragma(fs.pragmas, "noSideEffect"): return NxRaises(known: true)
      return nxFxImpure(s.name & " is called before its body")
    let (h2, l2) = nxRsDeclared(NxRef(file: target.file, idx: int32(fw)), lines)
    if h2: return nxRsListOf(nxRsScope(c, target.file), l2)
    return NxRaises(known: true, excs: @[NxExc(name: "Exception", anc: @["RootObj"])])
  if c.fx and fw < 0:
    case nxFxForwardElsewhere(c, target, callPath)
    of 1: return NxRaises(known: true)
    of 2: return nxFxImpure(s.name & " is declared ahead in another file of its module")
    else: discard
  let ts = target.sym
  let tu = nxRsUnit(c, target.file, ts.line)       # (a routine of a file being edited: by its own text)
  let key = (if c.fx: "fx:" else: "") &
            (if tu.len > 0: tu else: target.file.path & ":" & nxRsStamp(c, target.file.path) & ":" & $ts.line & ":" &
                                     ts.name) & ":" & $nxGen
  let onStack = c.busy.find(key)
  if onStack >= 0:
    c.cycleAt = min(c.cycleAt, onStack)
    return NxRaises(known: true)             # (a cycle: cut — what it raises comes from elsewhere)
  if key in nxRaisesCache:
    let (res, deps) = nxRaisesCache[key]
    var fresh = true
    for (p, st) in deps:
      if nxRsStamp(c, p) != st:
        fresh = false
        break
    if fresh:
      for (p, _) in deps: nxRsDep(c, p)
      return res
  if c.busy.len > 40: return nxRsFail("calls too deep")
  if prag.len > 0 or target.sym.pragmas.len > 0:
    let rw = nxRsRewrites(nxRsScope(c, r.file), prag & (if target.idx != r.idx: ", " & target.sym.pragmas else: ""))
    if rw.len > 0: return nxRsFail(s.name & " is rewritten by its pragma " & rw)    # ({.hasSimd.}, {.async.} …)
  c.busy.add key
  c.deps.add initHashSet[string]()
  c.deps[^1].incl (if tu.len > 0: tu else: target.file.path)
  var res: NxRaises
  let impure0 = c.impure
  c.impure = false
  try: res = nxRsAnalyse(c, target, lr)
  except CatchableError: res = nxRsFail("an error")
  c.impure = impure0
  let mine = c.deps.pop()
  c.busy.setLen(c.busy.len - 1)
  let partial = c.cycleAt < c.busy.len      # (it came back to a routine still being worked out, below it)
  if c.cycleAt >= c.busy.len: c.cycleAt = high(int)
  when defined(nxRsDebug):
    echo "ROUTINE ", ts.name, "@", target.file.path.extractFilename, ":", ts.line + 1, " → ",
         (if res.known: "[" & nxExcList(res) & "]" else: "? " & res.why)
  for p in mine: nxRsDep(c, p)
  if not c.cut and not partial:
    var deps: seq[(string, string)]
    for p in mine: deps.add (p, nxRsStamp(c, p))
    if nxRaisesCache.len >= 8192: nxRaisesCache.clear()
    nxRaisesCache[key] = (res, deps)
  res

proc nxRaisesOf*(r: NxRef, limit = 4000, ms = 2000): NxRaises =
  ## what routine `r` can raise, as the engine works it out (known = false when it cannot be sure, or when it runs out
  ## of steps or of `ms` milliseconds — the routines it worked out on the way are kept for the next time)
  if r.file == nil or r.sym.kind notin NxRoutineKinds: return nxRsFail("not a routine")
  var c = NxRsCtx(limit: limit, deadline: getMonoTime() + initDuration(milliseconds = ms), cycleAt: high(int))
  c.deps.add initHashSet[string]()
  try: result = nxRsRoutine(c, r, "", -1)
  except CatchableError: result = nxRsFail("an error")
  if c.cut: result = NxRaises(known: false, why: "out of time", cut: true)

proc nxRaisesHintable*(f: NxFile, lines: seq[string], s: NxSym): bool =
  ## a routine whose header can carry the hint: a proc, func, iterator or converter with a body and no {.raises.} of
  ## its own (written or pushed), not generic, not a macro's (async …)
  if s.kind notin {nxProc, nxFunc, nxIterator, nxConverter} or s.made or s.local: return false
  if "raises" in s.pragmas or "importc" in s.pragmas or "magic" in s.pragmas: return false
  if nxRsGenericParams(nxScope(f), s).len > 0: return false
  if s.endLine <= s.line and nxIsForward(lines, s): return false
  for (n, _) in nxLayPragmas(s.pragmas):
    if n notin ["inline", "noinline", "gcsafe", "noSideEffect", "sideEffect", "discardable", "deprecated", "exportc",
                "cdecl", "nimcall", "closure", "noreturn", "used", "benign", "tags", "forbids", "thread", "inl",
                "rtl", "compilerproc", "compilerRtl", "raises", "locks", "stackTrace", "lineTrace", "noinit",
                "procvar", "base", "error", "extern", "codegenDecl", "varargs", "nodecl", "stdcall", "noconv"]:
      return false
  not nxRsPushRaises(f, lines, s.line)[0]

proc nxRaisesHintAt*(lines: seq[string], s: NxSym): (int, int) =
  ## where the hint of routine `s` goes: before the `=` that ends its header — (line, column), line -1 when none
  let (h, hl) = nxHeaderLast(lines, s)
  if hl >= lines.len: return (-1, 0)
  var k = h.find(s.name)
  if k < 0: k = 0
  var from0 = k + s.name.len
  let p = h.find('(', from0)
  if p >= 0:
    let pc = nxMatchClose(h, p)
    if pc > p: from0 = pc + 1
  let eq = nxFindTop(h, '=', from0)
  if eq < 0: return (-1, 0)
  # the same `=` on the header's last line: the one after which the body (or the line's end) comes
  let rest = h[eq + 1 .. ^1].strip
  let t = lines[hl]
  var col = -1
  if rest.len == 0:
    let code = nxCodeOf(t)
    col = t.find(code)
    if col >= 0: col += code.len - 1          # (the line's last code character: the `=`)
    if col < 0 or t[col] != '=': return (-1, 0)
  else:
    let bc = t.rfind(rest)
    if bc < 0: return (-1, 0)
    col = bc - 1
    while col >= 0 and t[col] == ' ': dec col
    if col < 0 or t[col] != '=': return (-1, 0)
  while col > 0 and t[col - 1] == ' ': dec col
  (hl, col)

proc nxRaisesHover*(r: NxRef, ms = 150): string =
  ## "can raise: IOError, OSError" for the hover of a routine ("" when the engine cannot be sure, or not yet: it has
  ## `ms` milliseconds)
  if r.sym.kind notin {nxProc, nxFunc, nxIterator, nxConverter}: return
  if "raises" notin r.sym.pragmas and nxRsGenericParams(nxScope(r.file), r.sym).len > 0: return
  let x = nxRaisesOf(r, 3000, ms)
  if not x.known: return
  if x.excs.len == 0: return "**can raise:** nothing (Defects aside)"
  "**can raise:** " & nxExcList(x)
