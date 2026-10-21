# ── memory layout: how a type lies in memory — each field's offset, size and the padding after it, the total size
#    and alignment — worked out the way Nim's C code generator lays it out (compiler/sizealignoffsetimpl.nim), for
#    the platform ned runs on. Nothing when the engine cannot be sure: importc and header types, names it cannot
#    find, generics without their arguments, a `when` it cannot decide, {.bitsize.} ──

var nxLayoutOn* = true                    # nim.memoryLayout: the hover of a type shows its layout

type
  NxLayRow* = object
    depth*: int              # 0: the object's own fields; 1, 2 …: inside the branches of a case
    label*: string           # "name: type" · "(type header)" · "case kind" · "of a, b:"
    name*: string            # a field's name ("" for the others)
    offset*, size*, pad*: int   # size < 0: a heading without a place of its own (a branch)
    line*: int               # the line its field is written on (-1: not a field)
    align*: int              # what it is aligned to (its type's alignment, or its {.align.})
  NxLayout* = object
    ok*: bool
    size*, align*: int
    rows*: seq[NxLayRow]
    viaPtr*: string          # "ref" / "ptr": the type is that pointer, to the object the rows describe
    objSize*, objAlign*: int # (viaPtr) the size and alignment of the object pointed to
    word*: int               # the pointer size it is for (8, or 4 on i386 / 32-bit ARM)
    plain*: bool             # fields only (no case, no when), each on a line of its own: they can be reordered
    sorted*: int             # (plain) its size with the fields sorted by alignment, largest first
    kind*: string            # "object" · "tuple" · "enum" · "" (anything else)
    path*: string            # the file the type is declared in
    declLine*, endLine*: int # its declaration's lines there

  NxLayEnv = ref object      # where a type's text is read: the file (and its scope), the generic arguments bound
    file: NxFile
    sc: NxScope
    binds: Table[string, NxLayArg]
  NxLayArg = object          # a generic argument: its text and where it was written
    text: string
    env: NxLayEnv
  NxSz = object
    ok: bool
    size, align: int
  NxLayCtx = object
    word, i64: int           # pointer size; alignment of 64-bit ints and floats (4 on i386 outside Windows)
    busy: HashSet[string]    # declarations being laid out (a type that contains itself)
    memo: Table[string, NxLayout]
    deps: seq[(string, string)]
    steps: int
  NxRecItem = object         # an object's body: fields and cases (a `when` is decided while reading it)
    isCase: bool
    name, typ: string
    alignP: int              # {.align(N).}
    line, last: int
    branches: seq[NxRecBranch]
  NxRecBranch = object
    label: string
    items: seq[NxRecItem]
  NxAcc = object
    off, maxAlign: int

func nxLayAlignUp(x, a: int): int {.inline.} = (if a <= 1: x else: (x + a - 1) and not (a - 1))

func nxLayAlign(a: var NxAcc, v: int) =
  a.maxAlign = max(a.maxAlign, v)
  a.off = nxLayAlignUp(a.off, v)

func nxLayFinish(a: var NxAcc): int =
  result = nxLayAlignUp(a.off, a.maxAlign) - a.off
  a.off += result

proc nxLayPlatform(): (int, int) =
  ## (pointer size, alignment of int64 / float64): the CPU ned runs on, or the project's when `nim dump` told
  let small = "i386" in nxDefines or "arm" in nxDefines
  let word = if small: 4 elif "amd64" in nxDefines or "arm64" in nxDefines: 8 else: sizeof(int)
  let i64 = if "i386" in nxDefines and "windows" notin nxDefines: 4
            elif nxDefines.len == 0 and sizeof(int) == 4 and defined(i386) and not defined(windows): 4
            else: 8
  (word, i64)

type NxLinesRef* = ref object   # a file's lines, shared (not copied for every look)
  path, stamp: string
  lines*: seq[string]

var nxLayLines: seq[NxLinesRef]   # the files last read for a layout (or for what a routine raises)

proc nxLayLinesRef(path: string): NxLinesRef =
  let st = nxCurStamp(path)
  for x in nxLayLines:
    if x.path == path and x.stamp == st: return x
  result = NxLinesRef(path: path, stamp: st, lines: nxFileLines(path))
  for k in countdown(nxLayLines.high, 0):          # (the file as it was: no use — an open file's 32 last versions
    if nxLayLines[k].path == path: nxLayLines.delete(k)   #  were kept while you typed)
  if nxLayLines.len >= 32: nxLayLines.delete(0)
  nxLayLines.add result

template nxLayLinesOf(path: string): seq[string] = nxLayLinesRef(path).lines

proc nxLayPragmas(p: string): seq[(string, string)] =
  ## "packed, size: sizeof(cint), align(8)" → (packed, ""), (size, sizeof(cint)), (align, 8)
  for part in nxSplitTop(p, {','}):
    let x = part.strip
    if x.len == 0: continue
    let c = nxFindTop(x, ':')
    let b = x.find('(')
    if c > 0 and (b < 0 or c < b): result.add (x[0 ..< c].strip, x[c + 1 .. ^1].strip)
    elif b > 0 and x.endsWith(")"): result.add (x[0 ..< b].strip, x[b + 1 ..< x.high].strip)
    else: result.add (x, "")

proc nxLayIsPragmaTemplate(sc: NxScope, name: string): bool =
  ## a custom pragma (`template name() {.pragma.}`): it marks a declaration, it does not change it
  for r in nxLookup(sc, name):
    if r.sym.kind == nxTemplate and "pragma" in r.sym.pragmas.split({',', ' '}): return true

proc nxLaySize(c: var NxLayCtx, env: NxLayEnv, t0: string, depth: int): NxSz
proc nxLayDecl(c: var NxLayCtx, r: NxRef, args: seq[NxLayArg], depth: int): NxLayout

proc nxLayInt(env: NxLayEnv, e: string): (bool, BiggestInt) =
  ## an integer constant expression (an array's length, an enum's value, a range's bound)
  let x = e.strip
  if x in env.binds:
    let a = env.binds[x]
    return nxLayInt(a.env, a.text)
  for w in x.split({' ', '(', ')', '+', '-', '*', ',', '[', ']'}):
    if w in env.binds: return (false, 0'i64)           # (N + 1 with N a generic parameter: not worked out)
  let v = nxCtEval(env.file, x)
  if v.kind in {ctInt, ctChar, ctBool, ctEnum} and v.big.len == 0: return (true, v.i)
  (false, 0'i64)

proc nxLayTypeRefs(env: NxLayEnv, name: string): seq[NxRef] =
  ## the declaration a type name means here: the file's own one first; several of other modules → none (ambiguous)
  var own, other: seq[NxRef]
  for r in nxTypeSyms(env.sc, name):
    var dup = false
    for x in own & other:
      if x.file.path == r.file.path and x.sym.line == r.sym.line: dup = true
    if dup: continue
    if r.file == env.file or r.file.path == env.file.path: own.add r else: other.add r
  if own.len > 0:
    # (a local type of a routine and a module-level one of the same name: the module's, unless it is the only one)
    var top: seq[NxRef]
    for r in own:
      if not r.sym.local: top.add r
    return (if top.len == 1: top elif own.len == 1: own else: @[])
  if other.len == 1: other else: @[]

proc nxLayEnumRange(c: var NxLayCtx, r: NxRef): (bool, BiggestInt, BiggestInt) =
  ## an enum's lowest and highest ordinal (its values follow its declaration among the file's symbols)
  var n: BiggestInt = 0
  var first = true
  var lo, hi: BiggestInt
  let env = NxLayEnv(file: r.file, sc: nxScope(r.file))
  for k in r.idx + 1 ..< r.file.syms.len:
    let s = r.file.syms[k]
    if s.kind != nxEnumVal or s.owner != r.sym.name: break
    var v = s.value.strip
    if v.startsWith("(") and v.endsWith(")"):
      let parts = nxSplitTop(v[1 ..< v.high], {','})
      v = if parts.len == 2: parts[0].strip else: ""
      if v.len == 0: return
    if v.len > 0 and not (v.startsWith("\"") or v.startsWith("r\"")):
      let (ok, x) = nxLayInt(env, v)
      if not ok: return
      n = x
    if first:
      lo = n
      hi = n
      first = false
    else:
      lo = min(lo, n)
      hi = max(hi, n)
    inc n
  if first: return
  (true, lo, hi)

proc nxLayCard(c: var NxLayCtx, env: NxLayEnv, t0: string, depth: int): BiggestInt =
  ## how many values an ordinal type has (a set's or an array index's), -1 when not known
  result = -1
  if depth > 12: return
  let t = t0.strip
  if t in env.binds:
    let a = env.binds[t]
    return nxLayCard(c, a.env, a.text, depth + 1)
  case t
  of "char", "cchar", "int8", "uint8", "byte", "cuchar", "cschar": return 256
  of "bool": return 2
  of "int16", "uint16", "cshort", "cushort": return 65536
  else: discard
  var rng = t
  if rng.startsWith("range[") and rng.endsWith("]"): rng = rng[6 ..< rng.high]
  let dd = nxFindRange(rng)
  if dd >= 0:
    if rng.find("..<", dd) == dd: return              # (not an ordinal type to the compiler)
    let (oa, a) = nxLayInt(env, rng[0 ..< dd])
    let (ob, b) = nxLayInt(env, rng[dd + 2 .. ^1])
    if not (oa and ob): return
    let n = b - a + 1
    return (if n >= 0: n else: -1)
  if not t.allCharsInSet(IdentChars + {'.'}): return
  let refs = nxLayTypeRefs(env, t)
  if refs.len != 1: return
  let r = refs[0]
  let def = r.sym.typ.strip
  if r.sym.generics.len > 0: return
  if def.startsWith("enum"):
    let (ok, lo, hi) = nxLayEnumRange(c, r)
    if ok: return hi - lo + 1
    return
  let env2 = NxLayEnv(file: r.file, sc: nxScope(r.file))
  if def.startsWith("distinct "): return nxLayCard(c, env2, def[9 .. ^1], depth + 1)
  if def.startsWith("range[") or (nxFindRange(def) >= 0 and '[' notin def):
    return nxLayCard(c, env2, def, depth + 1)
  if def.len > 0 and def.allCharsInSet(IdentChars + {'.'}): return nxLayCard(c, env2, def, depth + 1)

proc nxLayLitType(env: NxLayEnv, e: string): string =
  ## the type of a range's bound: of a literal (0 → int, 0'u8 → uint8, 'a' → char), an enum value, a constant
  let x = e.strip
  if x.len == 0: return
  if x[0] == '\'': return (if nxCharEnd(x, 0) == x.high: "char" else: "")
  var n = x
  if n[0] == '-': n = n[1 .. ^1].strip
  if n.len > 0 and n[0] in Digits:
    let q = n.find('\'')
    var suffix = if q >= 0: n[q + 1 .. ^1] else: ""
    if suffix.len == 0 and not n.startsWith("0x") and not n.startsWith("0X"):
      for k in 1 ..< n.len:
        if n[k] in {'i', 'u', 'f'} and n[k - 1] in Digits:
          suffix = n[k .. ^1]
          break
    let body = if q >= 0: n[0 ..< q] else: n
    if suffix.len == 0:
      return (if '.' in body or (('e' in body or 'E' in body) and not body.startsWith("0x")): "float" else: "int")
    return (case suffix.toLowerAscii
            of "i8": "int8"
            of "i16": "int16"
            of "i32": "int32"
            of "i64": "int64"
            of "u8": "uint8"
            of "u16": "uint16"
            of "u32": "uint32"
            of "u64": "uint64"
            of "u": "uint"
            of "f32": "float32"
            of "f", "f64", "d": "float64"
            else: "")
  if not x.allCharsInSet(IdentChars + {'.'}): return
  let nm = if '.' in x: x[x.rfind('.') + 1 .. ^1] else: x
  var found = ""
  for r in nxLookup(env.sc, nm):
    if r.sym.kind == nxEnumVal:
      if found.len > 0 and found != r.sym.owner: return ""
      found = r.sym.owner
    elif r.sym.kind == nxConst and r.sym.typ.len > 0:
      if found.len > 0 and found != r.sym.typ: return ""
      found = r.sym.typ
    elif r.sym.kind == nxConst:
      let v = nxCtEval(r.file, r.sym.value)
      let t = case v.kind
              of ctInt: (if v.typ.len > 0: v.typ else: (if v.big.len == 0: "int" else: ""))
              of ctChar: "char"
              of ctBool: "bool"
              else: ""
      if t.len == 0 or (found.len > 0 and found != t): return ""
      found = t
  found

proc nxLayProcSize(c: var NxLayCtx, env: NxLayEnv, t: string): NxSz =  # ned: ignore[unused-param]
  ## a proc type: a closure (the default) is a pointer and its environment; another calling convention, a pointer
  let k = t.rfind("{.")
  var closure = true
  if k > 0:
    let e = t.find(".}", k)
    if e < 0: return
    for (n, _) in nxLayPragmas(t[k + 2 ..< e]):
      case n
      of "nimcall", "cdecl", "stdcall", "noconv", "fastcall", "safecall", "syscall", "thiscall", "inline",
         "noinline", "vectorcall", "memtracker": closure = false
      of "closure": closure = true
      of "gcsafe", "raises", "tags", "forbids", "noSideEffect", "sideEffect", "locks", "deprecated", "varargs",
         "thread", "effectsOf", "benign", "noreturn", "discardable", "nosinks": discard
      else: return              # (a pragma of the project's own: it may name a calling convention)
  NxSz(ok: true, size: (if closure: 2 * c.word else: c.word), align: c.word)

proc nxLayTuple(c: var NxLayCtx, env: NxLayEnv, parts: seq[(string, string)], depth: int,
                rows: var seq[NxLayRow]): NxSz =
  ## a tuple: its fields one after the other, each at its alignment (as the C struct it is)
  var acc = NxAcc(maxAlign: 1)
  for (nm, typ) in parts:
    let s = nxLaySize(c, env, typ, depth + 1)
    if not s.ok: return
    nxLayAlign(acc, s.align)
    if rows.len > 0: rows[^1].pad = acc.off - (rows[^1].offset + rows[^1].size)
    rows.add NxLayRow(label: (if nm.len > 0: nm & ": " else: "") & typ, name: nm, offset: acc.off, size: s.size,
                      line: -1, align: s.align)
    acc.off += s.size
  discard nxLayFinish(acc)
  if rows.len > 0: rows[^1].pad = acc.off - (rows[^1].offset + rows[^1].size)
  NxSz(ok: true, size: (if acc.off == 0: 1 else: acc.off), align: acc.maxAlign)

proc nxLayTupleParts(t: string): (bool, seq[(string, string)]) =
  ## "tuple[a, b: int; c: string]" / "(int, string)" → the fields (name, type)
  if t.startsWith("tuple[") and t.endsWith("]"):
    for p in nxParseParams(t[6 ..< t.high]):
      if p.typ.len == 0: return
      result[1].add (p.name.strip(chars = {'*', ' ', '`'}), p.typ)
    result[0] = true
  elif t.startsWith("(") and t.endsWith(")") and nxMatchClose(t, 0) == t.high:
    let inner = t[1 ..< t.high]
    for p in nxSplitTop(inner, {','}):
      let x = p.strip
      if x.len == 0: continue
      if nxFindTop(x, ':') >= 0: return            # (a: int, b: string): a tuple written with names
      result[1].add ("", x)
    result[0] = result[1].len > 0

proc nxLayBasic(c: NxLayCtx, t: string): NxSz =
  ## the types the compiler knows itself (and system's and the C types)
  template sz(n, a: int): NxSz = NxSz(ok: true, size: n, align: a)
  let w = c.word
  case t
  of "int", "uint", "Natural", "Positive", "ByteAddress", "csize_t", "cssize_t", "cptrdiff_t", "cintptr_t",
     "cuintptr_t": sz(w, w)
  of "int8", "uint8", "byte", "char", "bool", "cchar", "cschar", "cuchar", "cbool": sz(1, 1)
  of "int16", "uint16", "cshort", "cushort": sz(2, 2)
  of "int32", "uint32", "float32", "cint", "cuint", "cfloat": sz(4, 4)
  of "int64", "uint64", "float", "float64", "cdouble", "clonglong", "culonglong", "BiggestInt", "BiggestUInt",
     "BiggestFloat": sz(8, c.i64)
  of "clong", "culong": (if "windows" in nxDefines: sz(4, 4) else: sz(w, w))
  of "pointer", "cstring", "cstringArray", "RootRef": sz(w, w)
  of "string": sz(2 * w, w)
  else: NxSz()

proc nxLaySize(c: var NxLayCtx, env: NxLayEnv, t0: string, depth: int): NxSz =
  ## the size and alignment of the type written `t0` in `env`
  if depth > 24 or c.steps > 6000: return
  inc c.steps
  var t = t0.strip
  var changed = true
  while changed:
    changed = false
    for m in ["sink ", "owned ", "lent "]:
      if t.startsWith(m):
        t = t[m.len .. ^1].strip
        changed = true
    if t.startsWith("owned(") and t.endsWith(")"):
      t = t[6 ..< t.high].strip
      changed = true
  if t.len == 0: return
  if t in env.binds:
    let a = env.binds[t]
    return nxLaySize(c, a.env, a.text, depth + 1)
  let w = c.word
  if t.startsWith("ref ") or t.startsWith("ptr ") or t.startsWith("var ") or t == "ref object" or
     t.startsWith("ref object") or t.startsWith("ptr object"):
    return NxSz(ok: true, size: w, align: w)
  if t.startsWith("proc") and (t.len == 4 or t[4] in {' ', '(', '{'}): return nxLayProcSize(c, env, t)
  if t.startsWith("iterator") and (t.len == 8 or t[8] in {' ', '(', '{'}): return nxLayProcSize(c, env, t)
  if t.startsWith("distinct "): return nxLaySize(c, env, t[9 .. ^1], depth + 1)
  if t.startsWith("tuple[") or t.startsWith("("):
    let (ok, parts) = nxLayTupleParts(t)
    if not ok: return
    var rows: seq[NxLayRow]
    return nxLayTuple(c, env, parts, depth, rows)
  # a generic instantiation, a qualified name, a plain name
  var name = t
  var argsText = ""
  let br = t.find('[')
  if br > 0:
    if not t.endsWith("]") or nxMatchClose(t, br) != t.high: return
    name = t[0 ..< br].strip
    argsText = t[br + 1 ..< t.high]
  if name.len == 0 or not name.allCharsInSet(IdentChars + {'.'}): return
  let args = if argsText.len > 0: nxSplitTop(argsText, {','}) else: @[]
  var own = false              # (a type of the file's own with a built-in's name: it wins)
  if name in ["seq", "string", "array", "set", "UncheckedArray", "range", "int", "float", "char", "bool"] or
     nxLayBasic(c, name).ok:
    for r in nxTypeSyms(env.sc, name):
      if r.file.path == env.file.path and r.sym.typ.len > 0: own = true
  if not own:
    case name
    of "seq": return (if args.len == 1: NxSz(ok: true, size: 2 * w, align: w) else: NxSz())
    of "array":
      if args.len != 2: return
      let n = nxLayCard(c, env, args[0], depth + 1)
      let e = nxLaySize(c, env, args[1], depth + 1)
      if not e.ok: return
      var len = n
      if len < 0:
        let (ok, v) = nxLayInt(env, args[0])
        if not ok or v < 0: return
        len = v
      return NxSz(ok: true, size: int(len) * e.size, align: e.align)
    of "set":
      if args.len != 1: return
      let n = nxLayCard(c, env, args[0], depth + 1)
      if n < 0: return
      if n <= 8: return NxSz(ok: true, size: 1, align: 1)
      if n <= 16: return NxSz(ok: true, size: 2, align: 2)
      if n <= 32: return NxSz(ok: true, size: 4, align: 4)
      if n <= 64: return NxSz(ok: true, size: 8, align: c.i64)
      return NxSz(ok: true, size: int((n + 7) div 8), align: 1)
    of "UncheckedArray":
      if args.len != 1: return
      let e = nxLaySize(c, env, args[0], depth + 1)
      return (if e.ok: NxSz(ok: true, size: 0, align: e.align) else: NxSz())
    of "range":
      if args.len != 1: return
      let dd = nxFindRange(args[0])
      if dd < 0 or args[0].find("..<", dd) == dd: return
      let ta = nxLayLitType(env, args[0][0 ..< dd])
      let tb = nxLayLitType(env, args[0][dd + 2 .. ^1])
      if ta.len == 0 or ta != tb: return
      return nxLaySize(c, env, ta, depth + 1)
    of "openArray", "varargs", "typedesc", "static", "auto", "any", "untyped", "typed", "void", "type", "tuple",
       "object", "enum", "proc", "SomeInteger", "SomeNumber", "SomeFloat", "SomeOrdinal", "Ordinal":
      return
    else:
      if args.len == 0:
        let b = nxLayBasic(c, name)
        if b.ok: return b
  let refs = nxLayTypeRefs(env, name)
  if refs.len != 1: return
  var largs: seq[NxLayArg]
  for a in args:
    let x = a.strip
    if x in env.binds: largs.add env.binds[x]       # (a parameter passed on: what it stands for)
    else: largs.add NxLayArg(text: x, env: env)
  let l = nxLayDecl(c, refs[0], largs, depth + 1)
  NxSz(ok: l.ok, size: l.size, align: l.align)

# ── an object's body ──

type NxLogLine = object
  ind: int
  text: string
  line, last: int

proc nxLayLogical(lines: seq[string], a, b: int): seq[NxLogLine] =
  ## the code lines a..b without comments, a line that goes on below (an open bracket, a trailing comma) joined
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
    var ll = NxLogLine(ind: leadWs(lines[l]), text: t, line: l, last: l)
    var guard = 0
    while (depth > 0 or ll.text.endsWith(",")) and ll.last < min(b, lines.high) and guard < 40:
      inc ll.last
      var c2, d2: string
      nxSplitLine(lines[ll.last], st, c2, d2, depth)
      let x = c2.strip
      if x.len > 0: ll.text.add " " & x
      inc guard
    result.add ll
    l = ll.last + 1

proc nxLayWhenTaken(env: NxLayEnv, cond: string): int =
  ## a `when` in an object: 1 compiled here, 0 left out, -1 cannot tell
  result = nxWhen(cond)
  if result < 0:
    let v = nxCtEval(env.file, cond)
    if v.kind == ctBool: result = (if v.i != 0: 1 else: 0)

proc nxLayFieldLine(env: NxLayEnv, ll: NxLogLine, items: var seq[NxRecItem], ok: var bool) =
  ## `a*, b {.align(16).}: T = default` → its fields
  let t = ll.text
  let colon = nxFindTop(t, ':')
  if colon <= 0:
    ok = false
    return
  var typ = t[colon + 1 .. ^1]
  let eq = nxFindTop(typ, '=')
  if eq >= 0: typ = typ[0 ..< eq]
  typ = nxCollapse(typ.strip)
  if typ.len == 0:
    ok = false
    return
  for part in nxSplitTop(t[0 ..< colon], {','}):
    let (n0, prag) = nxStripPragma(part.strip)
    let nm = n0.strip.strip(chars = {'*', ' '}).strip(chars = {'`'})
    if nm.len == 0 or not (nxIsIdent(nm[0]) or n0.strip.startsWith("`")):
      ok = false
      return
    var al = 0
    for (pn, pv) in nxLayPragmas(prag):
      case pn
      of "align":
        let (aok, v) = nxLayInt(env, pv)
        if not aok or v <= 0 or (v and (v - 1)) != 0:
          ok = false
          return
        al = max(al, int(v))
      of "bitsize":
        ok = false                       # bit fields: the C compiler packs them its own way
        return
      else: discard                      # deprecated, cursor, exportc, a custom pragma …: no change to the layout
    items.add NxRecItem(name: nm, typ: typ, alignP: al, line: ll.line, last: ll.last)

proc nxLayBody(env: NxLayEnv, ls: seq[NxLogLine], i: var int, ind: int, ok: var bool, sawWhen: var bool): seq[NxRecItem] =
  ## the fields and cases at indentation `ind` from ls[i] on (a `when` decided and read through)
  template fail() =
    ok = false
    return
  while ok and i < ls.len and ls[i].ind >= ind:
    let ll = ls[i]
    if ll.ind > ind:
      ok = false
      return
    let t = ll.text
    let (w, we) = nxName(t, 0)
    if w in ["of", "else", "elif"]: return            # (the caller's case or when goes on)
    if w == "case":
      var it = NxRecItem(isCase: true, line: ll.line, last: ll.last)
      var head = t[we .. ^1].strip
      if head.endsWith(":"): head = head[0 ..< head.high].strip
      var tmp: seq[NxRecItem]
      nxLayFieldLine(env, NxLogLine(ind: ll.ind, text: head, line: ll.line, last: ll.last), tmp, ok)
      if not ok or tmp.len != 1: fail()
      it.name = tmp[0].name
      it.typ = tmp[0].typ
      it.alignP = tmp[0].alignP
      inc i
      if i >= ls.len or ls[i].ind < ind: fail()
      let ofInd = ls[i].ind
      while ok and i < ls.len and ls[i].ind == ofInd:
        let bt = ls[i].text
        let (bw, _) = nxName(bt, 0)
        if bw notin ["of", "else"]: break
        let c = nxFindTop(bt, ':')
        if c < 0: fail()
        var br = NxRecBranch(label: bt[0 .. c])
        let rest = bt[c + 1 .. ^1].strip
        let bline = ls[i]
        inc i
        if rest.len > 0:
          if rest notin ["discard", "nil"]:
            nxLayFieldLine(env, NxLogLine(ind: bline.ind, text: rest, line: bline.line, last: bline.last), br.items, ok)
        elif i < ls.len and ls[i].ind > ofInd:
          br.items = nxLayBody(env, ls, i, ls[i].ind, ok, sawWhen)
        it.branches.add br
      if it.branches.len == 0: fail()
      result.add it
      if ofInd > ind and i < ls.len and ls[i].ind > ind: fail()
      continue
    if w == "when":
      sawWhen = true
      var taken = false
      var first = true
      while ok and i < ls.len and ls[i].ind == ind:
        let wt = ls[i].text
        let (ww, wwe) = nxName(wt, 0)
        if not (if first: ww == "when" else: ww in ["elif", "else"]): break
        first = false
        var v = 1
        if ww != "else":
          let c = nxFindTop(wt, ':')
          if c < 0: fail()
          v = nxLayWhenTaken(env, wt[wwe ..< c].strip)
          if v < 0 and not taken: fail()
        let c = nxFindTop(wt, ':', wwe)
        let rest = if c >= 0: wt[c + 1 .. ^1].strip else: ""
        let wl = ls[i]
        inc i
        var body: seq[NxRecItem]
        if rest.len > 0:
          if rest notin ["discard", "nil"]:
            nxLayFieldLine(env, NxLogLine(ind: wl.ind, text: rest, line: wl.line, last: wl.last), body, ok)
        elif i < ls.len and ls[i].ind > ind:
          body = nxLayBody(env, ls, i, ls[i].ind, ok, sawWhen)
          if ok and i < ls.len and ls[i].ind > ind: fail()
        if v == 1 and not taken:
          taken = true
          result.add body
      continue
    if t in ["discard", "nil"]:
      inc i
      continue
    if w in ["proc", "func", "method", "iterator", "template", "macro", "type", "const", "let", "var"]:
      ok = false
      return
    nxLayFieldLine(env, ll, result, ok)
    inc i

proc nxLaySubAlign(c: var NxLayCtx, env: NxLayEnv, items: seq[NxRecItem], depth: int): int =
  ## the alignment a case branch asks of the union it is in (its fields' types; {.align.} does not count here)
  result = 1
  for it in items:
    let s = nxLaySize(c, env, it.typ, depth + 1)
    if not s.ok: return -1
    result = max(result, s.align)
    if it.isCase:
      for b in it.branches:
        let a = nxLaySubAlign(c, env, b.items, depth + 1)
        if a < 0: return -1
        result = max(result, a)

proc nxLayFold(c: var NxLayCtx, env: NxLayEnv, items: seq[NxRecItem], packed: bool, acc: var NxAcc,
               rows: var seq[NxLayRow], depth, level: int): bool =
  ## the fields one after the other, each at its alignment; a case: its discriminator, then the union of its
  ## branches (each one a struct starting where the union does)
  var prev = -1                 # the row before, in this list: its padding is up to the next one
  for it in items:
    let s = nxLaySize(c, env, it.typ, depth + 1)
    if not s.ok: return false
    let al = if packed: 1 else: s.align
    nxLayAlign(acc, al)
    if it.alignP > 0: nxLayAlign(acc, it.alignP)
    if prev >= 0: rows[prev].pad = acc.off - (rows[prev].offset + rows[prev].size)
    rows.add NxLayRow(depth: level, label: (if it.isCase: "case " else: "") & it.name & ": " & it.typ,
                      name: it.name, offset: acc.off, size: s.size, line: it.line, align: max(al, it.alignP))
    prev = rows.high
    acc.off += s.size
    if not it.isCase: continue
    var maxChild = 1
    if not packed:
      for b in it.branches:
        let a = nxLaySubAlign(c, env, b.items, depth + 1)
        if a < 0: return false
        maxChild = max(maxChild, a)
    nxLayAlign(acc, maxChild)
    rows[prev].pad = acc.off - (rows[prev].offset + rows[prev].size)
    let start = acc.off
    let head = rows.len
    rows.add NxLayRow(depth: level, label: "(union of the branches)", offset: start, size: 0, line: -1)
    var hi = start
    for b in it.branches:
      rows.add NxLayRow(depth: level + 1, label: b.label, offset: start, size: -1, line: -1)
      var ba = NxAcc(off: start, maxAlign: 1)
      let first = rows.len
      if not nxLayFold(c, env, b.items, packed, ba, rows, depth + 1, level + 2): return false
      discard nxLayFinish(ba)
      for k in countdown(rows.high, first):
        if rows[k].depth == level + 2:
          rows[k].pad = ba.off - (rows[k].offset + rows[k].size)
          break
      hi = max(hi, ba.off)
      acc.maxAlign = max(acc.maxAlign, ba.maxAlign)
    acc.off = max(acc.off, hi)
    rows[head].size = acc.off - start
    prev = head
  true

proc nxLayHasUnchecked(c: var NxLayCtx, env: NxLayEnv, t: string, depth: int): bool =
  ## a field of type UncheckedArray[T] (through aliases and distinct): an object of only that gets a dummy byte first
  if depth > 8: return
  let x = t.strip
  if x in env.binds:
    let a = env.binds[x]
    return nxLayHasUnchecked(c, a.env, a.text, depth + 1)
  if x.startsWith("UncheckedArray["): return true
  if x.startsWith("distinct "): return nxLayHasUnchecked(c, env, x[9 .. ^1], depth + 1)
  if not x.allCharsInSet(IdentChars + {'.'}) or nxLayBasic(c, x).ok: return
  let refs = nxLayTypeRefs(env, x)
  if refs.len == 1 and refs[0].sym.generics.len == 0:
    let d = refs[0].sym.typ.strip
    if d.len > 0 and "object" notin d and not d.startsWith("enum") and not d.startsWith("ref ") and
       not d.startsWith("ptr "):
      return nxLayHasUnchecked(c, NxLayEnv(file: refs[0].file, sc: nxScope(refs[0].file)), d, depth + 1)

proc nxLayDefOf(r: NxRef, lines: seq[string]): (string, int, int, int) =
  ## a type's definition, the first and last line of its body, the indentation the body is deeper than —
  ## also for `Name* {.pragmas.} =` with the definition on the line below (system's RootObj)
  template s: untyped = r.sym
  if s.line >= lines.len: return ("", 0, -1, 0)
  let ind = leadWs(lines[s.line])
  var def = s.typ.strip
  if def.startsWith("proc") or def.startsWith("iterator") or def.startsWith("distinct"):
    # (the parser leaves out the pragmas after `=`: a proc type's calling convention is among them)
    let ll = nxLayLogical(lines, s.line, min(lines.high, s.line + 20))
    if ll.len == 0: return ("", 0, -1, 0)
    let t = ll[0].text
    let k = t.find(s.name)
    let eq = if k >= 0: nxFindTop(t, '=', k + s.name.len) else: -1
    if eq < 0: return ("", 0, -1, 0)
    def = nxCollapse(t[eq + 1 .. ^1].strip)
    if ll.len > 1 and ll[1].text.startsWith("{."): return ("", 0, -1, 0)    # (its pragmas on the line below)
  if def.len > 0: return (def, s.line + 1, min(s.endLine, lines.high), ind)
  if not nxCodeOf(lines[s.line]).endsWith("="): return ("", 0, -1, 0)
  var l = s.line + 1
  while l < lines.len and nxCodeOf(lines[l]).len == 0: inc l
  if l >= lines.len or leadWs(lines[l]) <= ind: return ("", 0, -1, 0)
  let d = nxCodeOf(lines[l])
  var e = l
  var k = l + 1
  while k < lines.len and k - l < 2000:
    if nxCodeOf(lines[k]).len > 0:
      if leadWs(lines[k]) <= ind: break
      e = k
    inc k
  (nxCollapse(d), l + 1, e, leadWs(lines[l]))

proc nxLayObject(c: var NxLayCtx, r: NxRef, env: NxLayEnv, def: string, prags: seq[(string, string)],
                 depth: int, bodyA, bodyB, bodyInd: int): NxLayout =
  ## an object's layout: its header (the type field of an inheritable root, or its base's fields), then its own
  var packed, union, inheritable, pure = false
  for (n, _) in prags:
    case n
    of "packed": packed = true
    of "union": union = true
    of "inheritable": inheritable = true
    of "pure": pure = true
    else: discard
  let lr = nxLayLinesRef(r.file.path)
  template lines: untyped = lr.lines
  if r.sym.line >= lines.len or bodyB >= lines.len: return
  # (pragmas after `object`: the parser leaves them out of the definition — not read, so no layout)
  if "{." in def: return
  let declText = nxCodeOf(lines[r.sym.line])
  let eqAt = declText.find('=', min(r.sym.col, declText.len))
  if eqAt >= 0 and declText.find("{.", eqAt) >= 0: return
  var res = NxLayout(word: c.word, kind: (if def.startsWith("tuple"): "tuple" else: "object"), path: r.file.path,
                     declLine: r.sym.line, endLine: bodyB)
  var acc = NxAcc(maxAlign: 1)
  let ofk = def.find(" of ")
  var hasHeader = false
  if ofk >= 0:
    # object of Base: the base's object (through ref / ptr) comes first, all of it, its padding too
    let base = def[ofk + 4 .. ^1].strip
    var bsz = NxSz()
    var rootLike = false       # (RootObj, or a base with no fields of its own: only the type header)
    var bt = base
    if bt.startsWith("ref ") or bt.startsWith("ptr "): bt = bt[4 .. ^1].strip
    if bt.allCharsInSet(IdentChars + {'.'}):
      let brefs = nxLayTypeRefs(env, bt)
      if brefs.len == 1 and brefs[0].sym.generics.len == 0:
        let bl = nxLayDecl(c, brefs[0], @[], depth + 1)
        if bl.ok and bl.kind == "object":
          bsz = if bl.viaPtr.len > 0: NxSz(ok: true, size: bl.objSize, align: bl.objAlign)
                else: NxSz(ok: true, size: bl.size, align: bl.align)
          rootLike = bl.rows.len == 1 and bl.rows[0].label == "(type header)"
    if not bsz.ok: return
    acc = NxAcc(off: bsz.size, maxAlign: bsz.align)
    res.rows.add NxLayRow(label: (if rootLike: "(type header)" else: "(" & base & ", inherited)"), offset: 0,
                          size: bsz.size, line: -1, align: bsz.align)
    hasHeader = true
  elif inheritable and not pure:
    acc = NxAcc(off: c.word, maxAlign: c.word)
    res.rows.add NxLayRow(label: "(type header)", offset: 0, size: c.word, line: -1, align: c.word)
    hasHeader = true
  # the body
  var ok = true
  var sawWhen = false
  let ls = nxLayLogical(lines, bodyA, bodyB)
  var i = 0
  var items: seq[NxRecItem]
  if ls.len > 0:
    if ls[0].ind <= bodyInd: return
    items = nxLayBody(env, ls, i, ls[0].ind, ok, sawWhen)
  if not ok or i < ls.len: return
  if res.kind == "tuple":
    var parts: seq[(string, string)]
    for it in items:
      if it.isCase or it.alignP > 0: return
      parts.add (it.name, it.typ)
    var rows: seq[NxLayRow]
    let s = nxLayTuple(c, env, parts, depth, rows)
    if not s.ok: return
    res.rows = rows
    res.ok = true
    res.size = s.size
    res.align = s.align
    return res
  if union:
    if hasHeader: return
    for it in items:
      if it.isCase: return
      let s = nxLaySize(c, env, it.typ, depth + 1)
      if not s.ok: return
      var ba = NxAcc(off: 0, maxAlign: 1)
      nxLayAlign(ba, if packed: 1 else: s.align)
      if it.alignP > 0: nxLayAlign(ba, it.alignP)
      res.rows.add NxLayRow(label: it.name & ": " & it.typ, name: it.name, offset: ba.off, size: s.size,
                            line: it.line, align: max(if packed: 1 else: s.align, it.alignP))
      ba.off += s.size
      discard nxLayFinish(ba)
      acc.off = max(acc.off, ba.off)
      acc.maxAlign = max(acc.maxAlign, ba.maxAlign)
  else:
    if packed: acc.maxAlign = 1
    elif not hasHeader and items.len == 1 and not items[0].isCase and
         nxLayHasUnchecked(c, env, items[0].typ, depth + 1):
      acc.off = 1                                   # (C has no empty struct before a flexible array)
    if not nxLayFold(c, env, items, packed, acc, res.rows, depth, 0): return
  let tailFrom = acc.off
  discard nxLayFinish(acc)
  res.ok = true
  res.size = if acc.off == 0: 1 else: acc.off
  res.align = acc.maxAlign
  # the padding after the last row of the top level: up to the end
  for k in countdown(res.rows.high, 0):
    if res.rows[k].depth == 0:
      if res.rows[k].pad == 0 and not union: res.rows[k].pad = res.size - tailFrom
      break
  if union:
    for row in res.rows.mitems: row.pad = 0
  # fields sorted by alignment, largest first: the size then (only for an object of plain fields, each on its own
  # line — what the reorder fix can move)
  var plain = not (packed or union or sawWhen) and items.len > 1
  for it in items:
    if it.isCase or it.last != it.line: plain = false       # (a, b: int on one line: the line moves as one)
  if plain:
    var aligns: seq[int]
    for it in items:
      let s = nxLaySize(c, env, it.typ, depth + 1)
      aligns.add max(s.align, it.alignP)
    var order: seq[int]
    for k in 0 ..< items.len: order.add k
    order.sort(proc(x, y: int): int =
      result = cmp(aligns[y], aligns[x])
      if result == 0: result = cmp(x, y))
    var sorted: seq[NxRecItem]
    for k in order: sorted.add items[k]
    var acc2 = if hasHeader: NxAcc(off: res.rows[0].size, maxAlign: res.rows[0].align) else: NxAcc(maxAlign: 1)
    var rows2: seq[NxLayRow]
    if nxLayFold(c, env, sorted, false, acc2, rows2, depth, 0):
      discard nxLayFinish(acc2)
      res.plain = true
      res.sorted = if acc2.off == 0: 1 else: acc2.off
  res

proc nxLayDecl(c: var NxLayCtx, r: NxRef, args: seq[NxLayArg], depth: int): NxLayout =
  ## the layout of the type `r` declares, with its generic parameters bound to `args`
  if depth > 24: return
  template s: untyped = r.sym
  var key = r.file.path & ":" & $s.line & ":" & s.name
  for a in args: key.add "|" & a.text & "@" & a.env.file.path
  if key in c.memo: return c.memo[key]
  if key in c.busy: return                      # (a type that contains itself)
  c.busy.incl key
  defer: c.busy.excl key
  var seenDep = false
  for (p, _) in c.deps:
    if p == r.file.path: seenDep = true
  if not seenDep: c.deps.add (r.file.path, nxCurStamp(r.file.path))
  let names = nxGenericNames(s.generics)
  if names.len != args.len: return              # (a generic type without its arguments: no layout)
  let env = NxLayEnv(file: r.file, sc: nxScope(r.file))
  for k, n in names: env.binds[n] = args[k]
  let prags = nxLayPragmas(s.pragmas)
  var sizeP = ""
  var magicP = ""
  for (n, v) in prags:
    case n
    of "magic": magicP = v.strip(chars = {'"', ' '})
    of "importc", "importcpp", "importobjc", "header", "bycopy", "incompleteStruct", "completeStruct", "nodecl",
       "importjs", "dynlib", "borrow", "requiresInit", "noinit":
      if n in ["borrow", "requiresInit", "noinit"]: continue
      return
    of "size": sizeP = v
    of "packed", "union", "inheritable", "pure", "final", "acyclic", "shallow", "exportc", "deprecated", "byref",
       "compilerproc", "compilerRtl", "gcsafe", "used", "sendable", "explain", "cursor", "nimcall", "closure",
       "noSideEffect", "raises", "tags", "effectsOf", "thread", "align", "noalias":
      discard
    else:
      if not nxLayIsPragmaTemplate(env.sc, n): return    # (a macro pragma may make another type of it)
  let (def, bodyA, bodyB, bodyInd) = nxLayDefOf(r, nxLayLinesOf(r.file.path))
  var res = NxLayout(word: c.word, path: r.file.path, declLine: s.line, endLine: s.endLine)
  if def.len == 0:
    # the system's magic types (int, string, seq[T], set[T] …): what the compiler knows of them
    if not nxInSystem(r.file.path) or magicP.len == 0: return
    var t = s.name
    if args.len > 0:
      var xs: seq[string]
      for a in args:
        if a.env != args[0].env: return
        xs.add a.text
      t.add "[" & xs.join(", ") & "]"
    let sz = nxLaySize(c, (if args.len > 0: args[0].env else: env), t, depth + 1)
    if not sz.ok: return
    res.ok = true
    res.size = sz.size
    res.align = sz.align
    c.memo[key] = res
    return res
  if magicP.len > 0 and magicP != "Exception": return     # (another type the compiler makes its own way)
  if def.startsWith("enum"):
    res.kind = "enum"
    if sizeP.len > 0:
      let (ok, v) = nxLayInt(env, sizeP)
      if not ok or v notin [1'i64, 2, 4, 8]: return
      res = NxLayout(ok: true, size: int(v), align: (if v == 8: c.i64 else: int(v)), word: c.word, kind: "enum",
                     path: r.file.path, declLine: s.line, endLine: s.endLine)
    else:
      let (ok, lo, hi) = nxLayEnumRange(c, r)
      if not ok: return
      let (sz, al) = if lo < 0: (4, 4)
                     elif hi < 256: (1, 1)
                     elif hi < 65536: (2, 2)
                     elif hi < 4294967296'i64: (4, 4)
                     else: (8, c.i64)
      res.ok = true
      res.size = sz
      res.align = al
  elif sizeP.len > 0: return
  elif def.startsWith("concept"): return
  elif def == "object" or def.startsWith("object ") or def == "tuple" or
       ((def.startsWith("ref object") or def.startsWith("ptr object")) and
        (def.len == 10 or def[10] == ' ')):
    let viaPtr = if def.startsWith("ref "): "ref" elif def.startsWith("ptr "): "ptr" else: ""
    let od = if viaPtr.len > 0: def[4 .. ^1].strip else: def
    res = nxLayObject(c, r, env, od, prags, depth, bodyA, bodyB, bodyInd)
    if not res.ok: return
    if viaPtr.len > 0:
      res.viaPtr = viaPtr
      res.objSize = res.size
      res.objAlign = res.align
      res.size = c.word
      res.align = c.word
  elif def.startsWith("tuple[") or def.startsWith("("):
    let (ok, parts) = nxLayTupleParts(def)
    if not ok: return
    var rows: seq[NxLayRow]
    let sz = nxLayTuple(c, env, parts, depth, rows)
    if not sz.ok: return
    res.ok = true
    res.kind = "tuple"
    res.size = sz.size
    res.align = sz.align
    res.rows = rows
  elif def.startsWith("ref ") or def.startsWith("ptr "):
    # Node = ref NodeObj: a pointer — and the object it points to, when that is known
    res.ok = true
    res.size = c.word
    res.align = c.word
    let target = def[4 .. ^1].strip
    let tr = if target.allCharsInSet(IdentChars + {'.'}): nxLayTypeRefs(env, target) else: @[]
    if tr.len == 1 and tr[0].sym.generics.len == 0:
      let o = nxLayDecl(c, tr[0], @[], depth + 1)
      if o.ok and o.kind == "object" and o.viaPtr.len == 0:
        res.rows = o.rows
        res.viaPtr = def[0 ..< 3]
        res.objSize = o.size
        res.objAlign = o.align
        res.kind = "object"
        res.path = o.path
        res.declLine = o.declLine
        res.endLine = o.endLine
  else:
    # distinct T, an alias, range[a..b], array[…], seq[…], a generic instantiation …
    var inner = def
    if inner.startsWith("distinct "): inner = inner[9 .. ^1].strip
    let sz = nxLaySize(c, env, inner, depth + 1)
    if not sz.ok: return
    res.ok = true
    res.size = sz.size
    res.align = sz.align
    # an alias of an object (or a distinct one): its fields too
    var nm = inner
    var argT = ""
    let br = inner.find('[')
    if br > 0 and inner.endsWith("]"):
      nm = inner[0 ..< br]
      argT = inner[br + 1 ..< inner.high]
    if nm.allCharsInSet(IdentChars + {'.'}) and not nxLayBasic(c, nm).ok and nm notin env.binds:
      let tr = nxLayTypeRefs(env, nm)
      if tr.len == 1:
        var largs: seq[NxLayArg]
        if argT.len > 0:
          for a in nxSplitTop(argT, {','}):
            let x = a.strip
            largs.add (if x in env.binds: env.binds[x] else: NxLayArg(text: x, env: env))
        let o = nxLayDecl(c, tr[0], largs, depth + 1)
        if o.ok and o.kind in ["object", "tuple"]:
          res.rows = o.rows
          res.kind = o.kind
          res.viaPtr = o.viaPtr
          res.objSize = o.objSize
          res.objAlign = o.objAlign
          res.path = o.path                 # (where those fields are written)
          res.declLine = o.declLine
          res.endLine = o.endLine
  c.memo[key] = res
  res

proc nxLayCtxNew(): NxLayCtx =
  let (w, a) = nxLayPlatform()
  NxLayCtx(word: w, i64: a)

proc nxLayoutOf*(r: NxRef, argTexts: seq[string] = @[], at: NxFile = nil): NxLayout =
  ## the memory layout of the type `r` declares (generic arguments written in file `at`); ok = false when not sure
  var c = nxLayCtxNew()
  var args: seq[NxLayArg]
  if argTexts.len > 0:
    let f = if at != nil: at else: r.file
    let env = NxLayEnv(file: f, sc: nxScope(f))
    for a in argTexts: args.add NxLayArg(text: a.strip, env: env)
  try: result = nxLayDecl(c, r, args, 0)
  except CatchableError: result = NxLayout()

proc nxSizeOfType*(f: NxFile, t: string): (bool, int, int) =
  ## the size and alignment of a type written `t` in file `f`
  var c = nxLayCtxNew()
  let s = nxLaySize(c, NxLayEnv(file: f, sc: nxScope(f)), t, 0)
  (s.ok, s.size, s.align)

proc nxLayoutText*(l: NxLayout, name: string): string =
  ## the hover's part: a table of offsets, sizes and padding
  if not l.ok: return
  let bits = if l.word == 4: "32-bit" else: "64-bit"
  if l.rows.len == 0:
    return "**Memory:** " & $l.size & " byte" & (if l.size == 1: "" else: "s") & ", align " & $l.align & " (" & bits & ")"
  let objSize = if l.viaPtr.len > 0: l.objSize else: l.size
  let objAlign = if l.viaPtr.len > 0: l.objAlign else: l.align
  var padTotal = 0
  for r in l.rows:
    if r.size >= 0 and r.label != "(union of the branches)": padTotal += r.pad
  result = "**Memory layout** (" & bits & "): "
  if l.viaPtr.len > 0:
    result.add "a " & l.viaPtr & ", " & $l.word & " bytes, to an object of "
  result.add $objSize & " bytes, align " & $objAlign
  if padTotal > 0: result.add " · " & $padTotal & " bytes of padding"
  result.add "\n```\noffset  size  field\n"
  for r in l.rows:
    let ind = spaces(2 * r.depth)
    var lbl = r.label
    if lbl.len > 44: lbl = lbl[0 ..< 43] & "…"
    if r.size < 0:
      result.add spaces(12) & ind & lbl & "\n"
      continue
    var row = align($r.offset, 6) & align($r.size, 6) & "  " & ind & lbl
    if r.pad > 0: row.add "  +" & $r.pad & " padding"
    result.add row & "\n"
  result.add "```"
  if l.plain and l.sorted < objSize:
    result.add "\nWith the fields sorted by alignment: " & $l.sorted & " bytes (Alt+Enter on its line reorders them)"

var nxLayHoverCache: Table[string, (string, seq[(string, string)])]   # key → (the hover's text, the files it read)

proc nxLayoutHover*(f: NxFile, lines: seq[string], line, col: int, refs: seq[NxRef]): string =
  ## the layout for the hover of a type's name (its declaration, or a use: Foo[int] binds its parameters)
  if not nxLayoutOn or refs.len == 0 or line >= lines.len: return
  let r = refs[0]
  for x in refs:
    if x.sym.kind != nxType or x.file.path != r.file.path or x.sym.line != r.sym.line: return
  let t = lines[line]
  var a = min(col, t.len)
  while a > 0 and nxIsIdent(t[a - 1]): dec a
  var e = a
  while e < t.len and nxIsIdent(t[e]): inc e
  var args: seq[string]
  let atDecl = r.file.path == f.path and r.sym.line == line
  if not atDecl and e < t.len and t[e] == '[':
    let ce = nxMatchClose(t, e)
    if ce > e:
      for p in nxSplitTop(t[e + 1 ..< ce], {','}): args.add p.strip
  let (w, _) = nxLayPlatform()
  let key = r.file.path & ":" & r.file.stamp & ":" & $r.sym.line & ":" & r.sym.name & ":" & args.join(",") & ":" &
            (if args.len > 0: f.path & ":" & f.stamp else: "") & ":" & $w & ":" & $nxGen
  if key in nxLayHoverCache:
    let (txt, deps) = nxLayHoverCache[key]
    var fresh = true
    for (p, st) in deps:
      if nxCurStamp(p) != st:
        fresh = false
        break
    if fresh: return txt
  var c = nxLayCtxNew()
  var largs: seq[NxLayArg]
  if args.len > 0:
    let env = NxLayEnv(file: f, sc: nxScope(f))
    for x in args: largs.add NxLayArg(text: x, env: env)
  var l: NxLayout
  try: l = nxLayDecl(c, r, largs, 0)
  except CatchableError: l = NxLayout()
  result = nxLayoutText(l, r.sym.name)
  if nxLayHoverCache.len >= 256: nxLayHoverCache.clear()
  nxLayHoverCache[key] = (result, c.deps)

include raises
