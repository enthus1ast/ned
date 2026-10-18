# ── answers: completion, hover, definition, signature help ──

const NimDocs* = [
  ("inline", "{.inline.} — ask the C compiler to inline this proc"),
  ("noSideEffect", "{.noSideEffect.} — proc may not touch globals or call side-effecting procs (same as `func`)"),
  ("raises", "{.raises: [E].} — the exceptions this proc may raise; checked by the compiler"),
  ("gcsafe", "{.gcsafe.} — does not access GC'ed globals; required for thread procs"),
  ("exportc", "{.exportc: \"name\".} — export with an unmangled C name"),
  ("importc", "{.importc: \"name\".} — bind to an existing C symbol"),
  ("importcpp", "{.importcpp.} — bind to a C++ method/symbol (pattern syntax: \"#.method(@)\")"),
  ("header", "{.header: \"<file.h>\".} — C header to #include for an importc'd symbol"),
  ("dynlib", "{.dynlib: \"lib.so\".} — load the symbol from a shared library at runtime"),
  ("cdecl", "{.cdecl.} — C calling convention"),
  ("nimcall", "{.nimcall.} — default Nim calling convention (no closure environment)"),
  ("closure", "{.closure.} — proc with a hidden environment pointer"),
  ("compileTime", "{.compileTime.} — only available at compile time (macros, const evaluation)"),
  ("used", "{.used.} — silence the 'declared but not used' hint"),
  ("deprecated", "{.deprecated: \"msg\".} — warn on every use"),
  ("push", "{.push pragma.} … {.pop.} — apply pragmas to all following declarations"),
  ("experimental", "{.experimental: \"feature\".} — enable an experimental language feature"),
  ("borrow", "{.borrow.} — reuse the base type's implementation for a distinct type"),
  ("base", "{.base.} — root of a method dispatch hierarchy"),
  ("thread", "{.thread.} — proc may be used as a thread entry point"),
  ("threadvar", "{.threadvar.} — thread-local global variable"),
  ("packed", "{.packed.} — object without padding between fields"),
  ("pure", "{.pure.} — enum values must be qualified (Color.red)"),
  ("size", "{.size: sizeof(cint).} — storage size of an enum"),
  ("union", "{.union.} — C union: all fields share memory"),
  ("bycopy", "{.bycopy.} — always pass this object by value"),
  ("byref", "{.byref.} — always pass this object by reference"),
  ("noinit", "{.noinit.} — skip zero-initialisation of a variable"),
  ("requiresInit", "{.requiresInit.} — variables of this type must be initialised explicitly"),
  ("final", "{.final.} — object type cannot be inherited from"),
  ("inheritable", "{.inheritable.} — allow inheriting from a non-RootObj object"),
  ("acyclic", "{.acyclic.} — tell ORC this type never forms cycles (faster)"),
  ("cursor", "{.cursor.} — non-owning reference: no refcounting for this variable/field"),
  ("emit", "{.emit: \"C code\".} — paste raw backend code"),
  ("discardable", "{.discardable.} — the result may be ignored without `discard`"),
  ("noreturn", "{.noreturn.} — proc never returns (quit, raise)"),
  ("error", "{.error: \"msg\".} — compile error when this symbol is used/instantiated"),
  ("computedGoto", "{.computedGoto.} — faster interpreter loops (case inside while true)"),
  ("global", "{.global.} — a proc-local variable with global lifetime"),
  ("async", "{.async.} — async proc returning a Future (std/asyncdispatch or chronos)"),
  ("booldefine", "{.booldefine.} — const overridable with -d:name=true/false"),
  ("strdefine", "{.strdefine.} — const overridable with -d:name=value"),
  ("intdefine", "{.intdefine.} — const overridable with -d:name=123"),
  ("distinct", "distinct T — a new type with T's representation but no implicit conversions"),
  ("defer", "defer: stmt — run stmt when the current scope exits (like try/finally)"),
  ("mixin", "mixin sym — late binding of a symbol inside generics/templates"),
  ("bind", "bind sym — early binding of a symbol inside templates"),
  ("concept", "concept — describe what a generic type must support"),
  ("lent", "lent T — borrowed, read-only view of a value (no copy)"),
  ("sink", "sink T — the parameter takes ownership (enables moves)"),
  ("static", "static: block — run at compile time · static[T] — compile-time parameter"),
  ("isMainModule", "true only in the module given on the command line"),
  ("result", "implicit return variable of every proc with a return type"),
]

func nimDocFor*(word: string): string =
  for (k, d) in NimDocs:
    if cmpIgnoreCase(k, word) == 0: return d
  ""

type
  NxItem* = object
    label*, detail*: string
    kind*: NxKind
    refs*: seq[NxRef]          # the declarations behind the item (overloads), for documentation
    local*: NxSym              # a local (refs empty)
    rank*: int                 # 0 local · 1 this module · 2 imports · 3 system · 4 guesses
    ufcs*: bool                # offered after `.` as a method-call: the first parameter is the receiver
    insert*: string            # text to insert when it is not the label (`field: ` in a constructor)
  NxCompletion* = object
    member*: bool              # after a `.`
    known*: bool               # the receiver's type was understood
    items*: seq[NxItem]
    receiverType*: string
    recvShape*: string         # what the receiver is, for postfix completion (nxPostfixShape)
    enumVals*: seq[string]     # its values, when it is an enum
    recvIsType*: bool          # the receiver is a type or a module (Color., strutils.)

const NxKeywords* = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
  "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot",
  "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc",
  "ptr", "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
  "when", "while", "xor", "yield"]

proc nxRank*(f: NxFile, r: NxRef): int =
  if r.file == f: 1
  elif r.origin > 0: r.origin.int
  elif nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir / "system"): 3
  else: 2

proc nxShortDetail*(s: NxSym, ufcs = false): string =
  case s.kind
  of NxRoutineKinds:
    result = "(" & nxParamsText(s.params, ufcs) & ")"
    if s.ret.len > 0: result.add ": " & s.ret
  of nxType: result = (if s.typ.len > 0: s.typ else: "type")
  of nxEnumVal: result = s.owner
  of nxField, nxParam, nxForVar, nxResult: result = s.typ
  of nxConst, nxLet, nxVar:
    result = (if s.typ.len > 0: s.typ elif s.value.len > 0: "= " & s.value else: "")
  of nxModule: result = "module"

proc nxVisible*(f: NxFile, r: NxRef): bool =
  ## private declarations are visible in their own module (and the files it includes) only
  if r.sym.exported or r.file == f or r.file.path == f.path: return true
  for g in nxIncluded(f):
    if g == r.file: return true
  # f is itself included: its includer and the includer's other include files are the same module
  let hp = nxIncluderOf(f.path)
  if hp.len > 0:
    if r.file.path == hp: return true
    let h = nxLoad(hp)
    if h != nil:
      for g in nxIncluded(h):
        if g == r.file or g.path == r.file.path: return true
  false

proc nxAddRefs*(items: var seq[NxItem], f: NxFile, refs: seq[NxRef], ufcs = false, rankBias = 0, recv = "",
               binds = initTable[string, string]()) =
  ## one item per name: overloads are folded into it (all of them are in the documentation)
  var at = initTable[string, int]()
  for i, it in items: at[it.label & "/" & $(it.kind in NxRoutineKinds)] = i
  for r in refs:
    let s = r.sym
    if s.kind == nxModule or s.name.len == 0 or not (s.name[0] in {'a'..'z', 'A'..'Z', '_'} or s.name[0] >= '\x80'):
      continue                     # operators are not typed by name
    if ufcs and s.name in NxKeywords: continue        # x.and(y) is legal but nobody writes it
    let key = s.name & "/" & $(s.kind in NxRoutineKinds)
    if key in at:
      items[at[key]].refs.add r
      continue
    at[key] = items.len
    var detail = nxShortDetail(s, ufcs)
    if binds.len > 0: detail = nxSubst(detail, binds)
    elif ufcs and recv.len > 0:
      let b = nxBindings(s, recv)
      if b.len > 0: detail = nxSubst(detail, b)
    items.add NxItem(label: s.name, detail: detail, kind: s.kind, refs: @[r],
                     rank: nxRank(f, r) + rankBias + (if "deprecated" in s.pragmas: 2 else: 0), ufcs: ufcs)

type NxSigHelp* = object
  overloads*: seq[NxRef]
  active*: int                 # the parameter being typed (after removing the receiver for method calls)
  ufcs*: bool
  recv*: string                # method-call syntax: the receiver's type, when known

proc nxSignatureHelp*(f: NxFile, lines: seq[string], line, col: int): NxSigHelp

proc nxModuleItems*(f: NxFile, before: string): seq[NxItem] =
  ## module names to complete in `import …` (before: the line up to the word being typed)
  # the path written so far in front of the word: "std/", "../src/", "pkg/", "demo/" or nothing
  var k = before.len
  while k > 0 and before[k - 1] notin {' ', ',', '['}: dec k
  var prefix = before[k .. ^1]
  if k > 0 and before[k - 1] in {',', ' '} or (k > 0 and before[k - 1] == '['):
    # inside std/[a, b, …]: the path in front of the bracket
    var depth = 0
    var j = before.high
    while j >= 0:
      if before[j] == ']': inc depth
      elif before[j] == '[':
        if depth == 0:
          var s = j
          while s > 0 and before[s - 1] notin {' ', ','}: dec s
          prefix = before[s ..< j] & prefix
          break
        dec depth
      dec j
  var seen: HashSet[string]
  proc addDir(res: var seq[NxItem], dir, detail: string) =
    if not dirExists(dir): return
    try:
      for kind, p in walkDir(dir):
        let nm = extractFilename(p)
        if kind in {pcFile, pcLinkToFile} and nm.endsWith(".nim"):
          let m = nm[0 ..< ^4]
          if m notin seen and m != f.module:
            seen.incl m
            res.add NxItem(label: m, detail: detail, kind: nxModule, rank: 2,
                           local: NxSym(name: m, kind: nxModule, value: p))
        elif kind in {pcDir, pcLinkToDir} and nm.len > 0 and nm[0] notin {'.', '_'} and nm notin seen and
             nm notin ["nimcache", "tests", "private"]:
          seen.incl nm
          res.add NxItem(label: nm, detail: "folder", kind: nxModule, rank: 3,
                         local: NxSym(name: nm, kind: nxModule, value: p))
    except OSError: discard
  let here = parentDir(f.path)
  if prefix.startsWith("std/"):
    let sub = prefix[4 .. ^1]
    for p in nxSearchPaths:
      if p.startsWith(nxLibDir): result.addDir(p / sub, "std")
  elif prefix.startsWith("pkg/"):
    for d in nxPkgDirs:
      let nm = extractFilename(d).split('-')[0]
      if nm notin seen:
        seen.incl nm
        result.add NxItem(label: nm, detail: "package", kind: nxModule, rank: 2, local: NxSym(name: nm, kind: nxModule, value: d))
  elif prefix.len > 0:
    result.addDir(here / prefix, prefix)
    for p in nxSearchPaths: result.addDir(p / prefix, prefix)
  else:
    result.addDir(here, "here")
    for p in nxSearchPaths:
      if not p.startsWith(nxLibDir): result.addDir(p, "path")
    for p in nxSearchPaths:
      if p.startsWith(nxLibDir) and not p.endsWith("/system"): result.addDir(p, "std")
    for d in nxPkgDirs:
      let nm = extractFilename(d).split('-')[0]
      if nm notin seen:
        seen.incl nm
        result.add NxItem(label: nm, detail: "package", kind: nxModule, rank: 2, local: NxSym(name: nm, kind: nxModule, value: d))

const NxPragmas* = [
  ("inline", "inline the routine"), ("noinline", "never inline it"), ("noSideEffect", "a func: no side effects"),
  ("raises", "the exceptions it may raise: raises: [ValueError]"), ("tags", "the effects it has: tags: [IOEffect]"),
  ("gcsafe", "touches no GC'ed global"), ("base", "a method others override"), ("async", "an async proc (asyncdispatch, chronos)"),
  ("closure", "a closure calling convention"), ("nimcall", "Nim's calling convention"), ("cdecl", "C's calling convention"),
  ("stdcall", "stdcall calling convention"), ("importc", "a C function or variable"), ("importcpp", "a C++ one"),
  ("importjs", "a JavaScript one"), ("exportc", "visible to C under this name"), ("exportcpp", "visible to C++"),
  ("dynlib", "from a shared library"), ("header", "the C header that declares it"), ("emit", "C code written as it is"),
  ("deprecated", "warns where it is used: deprecated: \"use x\""), ("discardable", "its result may be ignored"),
  ("noreturn", "never returns"), ("compileTime", "runs at compile time only"), ("used", "no 'declared but not used' hint"),
  ("pure", "an enum whose values need its name"), ("final", "an object nothing inherits from"),
  ("acyclic", "no cycles through this type"), ("bycopy", "passed by value"), ("byref", "passed by reference"),
  ("packed", "no padding between fields"), ("union", "a C union"), ("borrow", "a distinct type's proc from its base"),
  ("booldefine", "set with -d:name=true"), ("intdefine", "set with -d:name=3"), ("strdefine", "set with -d:name=x"),
  ("push", "a pragma for everything until pop"), ("pop", "ends a push"), ("experimental", "an experimental feature"),
  ("error", "a compile-time error where it is used"), ("warning", "a warning where it is used"), ("hint", "a hint"),
  ("global", "a global variable inside a proc"), ("threadvar", "one per thread"), ("noinit", "not zeroed"),
  ("requiresInit", "must be initialized"), ("size", "the C size of an enum or object"), ("align", "alignment"),
  ("cursor", "a non-owning reference (ARC)"), ("noalias", "restrict"), ("inject", "a template's symbol visible outside"),
  ("gensym", "a template's symbol kept hidden"), ("dirty", "a template whose symbols are not bound"),
  ("varargs", "a C function taking ..."), ("pragma", "a pragma of your own: {.pragma: name, ….}"),
  ("noconv", "no calling convention (a C callback)"), ("nodecl", "not declared in the generated C"), ("codegenDecl", "how C declares it"),
  ("passc", "flags for the C compiler"), ("passl", "flags for the linker"), ("compile", "a C file to compile with it"),
  ("link", "a library to link"), ("effectsOf", "its effects are those of a parameter"), ("thread", "runs in a thread"),
  ("sideEffect", "has side effects"), ("enforceNoRaises", "raises nothing"), ("overflowChecks", "on / off"),
  ("boundChecks", "on / off"), ("rangeChecks", "on / off"), ("nilChecks", "on / off"), ("checks", "on / off"),
  ("optimization", "speed / size / none"), ("warnings", "on / off"), ("hints", "on / off"), ("line", "the line errors report")]

proc nxJoinBack(lines: seq[string], line, upto: int): string =
  ## the line up to `upto`, with the lines above joined in front while a bracket closed on it opened there:
  ## `{"a": 1,⏎  "b": 2}.` is one receiver
  proc codeOf(x: string): string =
    ## (a line without its comment)
    var q = '\0'
    for i, c in x:
      if q != '\0':
        if c == q and (i == 0 or x[i - 1] != '\\'): q = '\0'
      elif c in {'"', '\''}: q = c
      elif c == '#': return x[0 ..< i]
    x
  proc balance(x: string): int =
    var q = '\0'
    for i, c in x:
      if q != '\0':
        if c == q and (i == 0 or x[i - 1] != '\\'): q = '\0'
      elif c == '"': q = c
      elif c in {'(', '[', '{'}: inc result
      elif c in {')', ']', '}'}: dec result
  result = lines[line][0 ..< min(upto, lines[line].len)]
  if result.strip.len == 0 or result.strip[0] notin {')', ']', '}'} and balance(result) >= 0: return
  var l = line
  while balance(result) < 0 and l > 0 and line - l < 30:
    dec l
    result = codeOf(lines[l]).strip & " " & result.strip(trailing = false)

proc nxConceptNeeds*(f: NxFile, sc: NxScope, lines: seq[string], line: int, typ: string): seq[string] =
  ## the routines a concept asks of its type — `s.area() is float`, `area(s)` → "area" — when `typ` is the concept
  ## or a generic parameter of the routine around `line` constrained by one ([T: Shape])
  if typ.len == 0 or '[' in typ: return
  var cname = typ
  let ri = nxEnclosing(f, line)
  if ri >= 0:
    let g = f.syms[ri].generics.strip(chars = {'[', ']'})
    for part in nxSplitTop(g, {';', ','}):
      let c = part.find(':')
      if c > 0 and part[0 ..< c].strip == typ: cname = part[c + 1 .. ^1].strip
  for r in nxTypeSyms(sc, cname):
    let def = r.sym.typ.strip
    if not def.startsWith("concept"): return
    var vars: seq[string]
    for v in def[7 .. ^1].split({',', ' '}):
      if v.strip.len > 0: vars.add v.strip
    let src = if r.file == f: lines
              else:
                try: readFile(r.file.path).splitLines() except CatchableError: @[]
    let l0 = r.sym.line
    if l0 >= src.len: return
    let ind0 = src[l0].len - src[l0].strip(trailing = false).len
    var l = l0 + 1
    while l < src.len and (src[l].strip.len == 0 or src[l].len - src[l].strip(trailing = false).len > ind0):
      let t = src[l]
      for v in vars:
        var k = t.find(v & ".")
        while k >= 0:
          if k == 0 or not nxIsIdent(t[k - 1]):
            var e = k + v.len + 1
            while e < t.len and nxIsIdent(t[e]): inc e
            let nm = t[k + v.len + 1 ..< e]
            if nm.len > 0 and nm notin result: result.add nm
          k = t.find(v & ".", k + 1)
        k = t.find("(" & v)
        while k >= 0:
          var a = k
          while a > 0 and nxIsIdent(t[a - 1]): dec a
          let nm = t[a ..< k]
          if nm.len > 0 and nm notin NxKeywords and nm notin result: result.add nm
          k = t.find("(" & v, k + 1)
      inc l
    return

proc nxPostfixShape*(sc: NxScope, typ: string, depth = 0): (string, seq[string]) =
  ## what the receiver is, for postfix completion (`xs.for`, `c.case`, `v.if`): "bool", "int", "float", "char",
  ## "string", "seq" (seq, array, openArray, set, HashSet …), "table", "option", "ref" (ref, ptr, pointer, cstring,
  ## a proc), "enum" with its values, "object" — "" when it cannot be told
  let raw = typ.strip
  if raw.len == 0 or depth > 4: return
  if raw.startsWith("ref ") or raw.startsWith("ptr ") or raw in ["pointer", "cstring"] or raw.startsWith("proc"):
    return ("ref", @[])
  let t = nxStripMods(raw)
  let base = nxBaseName(t)
  if base in ["seq", "array", "openArray", "varargs", "set", "HashSet", "OrderedSet", "Deque", "HeapQueue",
              "SinglyLinkedList", "DoublyLinkedList", "PackedSet", "IntSet", "UncheckedArray"]:
    return ("seq", @[])
  if base in ["Table", "TableRef", "OrderedTable", "OrderedTableRef", "CountTable", "CountTableRef",
              "StringTableRef"]:
    return ("table", @[])
  if base == "Option": return ("option", @[])
  let ra = nxResolveAlias(sc, base)
  if ra == "bool": return ("bool", @[])
  if ra in NxInts: return ("int", @[])
  if ra in NxFloats: return ("float", @[])
  if ra in ["char", "string"]: return (ra, @[])
  if ra != base: return nxPostfixShape(sc, ra, depth + 1)
  for r in nxTypeSyms(sc, ra):
    let def = r.sym.typ.strip
    if def == "enum" or def.startsWith("enum ") or def.startsWith("enum{") or def.startsWith("enum\n"):
      var vals: seq[string]
      for s in r.file.syms:
        if s.kind == nxEnumVal and s.owner == r.sym.name and s.name notin vals:
          vals.add s.name
          if vals.len >= 500: break
      return ("enum", vals)
    if def.startsWith("ref ") or def.startsWith("ptr "): return ("ref", @[])
    if def.startsWith("distinct "): return
    if "object" in def or def.startsWith("tuple"): return ("object", @[])
    let inner = nxBaseName(def)
    if inner.len > 0 and inner != ra:
      return nxPostfixShape(sc, def, depth + 1)
    return

# ── the type expected where a word is completed: the items of that type are offered first ──

const NxNoExpect = ["untyped", "typed", "auto", "any", "typedesc", "type", "void", "RootObj", "RootRef"]

proc nxPlainType(t: string): bool =
  ## a type of the language's own (numbers, string, bool, char…): many routines return one, few are what you want
  let b = nxBaseName(t)
  b in NxInts or b in NxFloats or b in ["string", "cstring", "bool", "char", "seq", "array", "set", "openArray",
                                         "varargs", "pointer"]

proc nxArgTypes(f: NxFile, sc: NxScope, locals: seq[NxSym], args: seq[string], line: int,
                memo: var Table[string, string]): seq[string] =
  ## the types of the arguments written so far ("" unknown), each worked out once
  for a in args:
    let t = a.strip
    if t notin memo:
      memo[t] = (if t.len == 0 or t.len > 200 or nxFindTop(t, '=') > 0: "" else: nxTypeOfExpr(f, sc, locals, t, line, 0).typ)
    result.add memo[t]

func nxArgElem(t: string): string =
  ## what one argument for a parameter of this type is: T for `varargs[T]`, T for `var T`
  let x = nxStripValMods(t)
  if x.startsWith("varargs[") and x.endsWith("]"): x[8 ..< ^1].strip else: x

func nxUncommented(s: string): string =
  ## a line without its comment (strings and characters kept, not stripped: columns stay)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
    elif c == '#': return s[0 ..< i]
    inc i
  s

proc nxOpenParen*(lines: seq[string], line, col: int, back = 30): (int, int) =
  ## the unclosed `(` that (line, col) is inside — on this line or on one of the `back` lines above, brackets in
  ## strings, characters and comments not counted —; (-1, -1) when there is none, or an unclosed `[` / `{` comes first
  var depth = 0
  var l = line
  var ev: seq[int]
  while l >= 0 and line - l <= back:
    let s = if l == line: nxUncommented(lines[l][0 ..< min(col, lines[l].len)]) else: nxUncommented(lines[l])
    ev.setLen(0)
    var i = 0
    while i < s.len:
      let c = s[i]
      if c == '\'' and nxCharEnd(s, i) > i:
        i = nxCharEnd(s, i) + 1
        continue
      if c == '"':
        inc i
        while i < s.len and s[i] != '"':
          if s[i] == '\\': inc i
          inc i
      elif c in {'(', '[', '{', ')', ']', '}'}: ev.add i
      inc i
    for k in countdown(ev.high, 0):
      if s[ev[k]] in {')', ']', '}'}: inc depth
      elif depth > 0: dec depth
      elif s[ev[k]] == '(': return (l, ev[k])
      else: return (-1, -1)
    dec l
  (-1, -1)

func nxJoinedFrom(lines: seq[string], pl, pc, line, col: int): string =
  ## the code from just after (pl, pc) to (line, col), the lines joined by a space (comments dropped)
  if pl == line: return lines[line][min(pc + 1, lines[line].len) ..< min(col, lines[line].len)]
  result = nxUncommented(lines[pl])[min(pc + 1, lines[pl].len) .. ^1]
  for l in pl + 1 ..< line: result.add " " & nxUncommented(lines[l]).strip
  result.add " " & lines[line][0 ..< min(col, lines[line].len)].strip

func nxHeaderKw(w: string): bool =
  ## a word that starts a routine's header
  # (a case, not `w in [a const array]`: such a const here made Nim 2.2.12 report consteval's `{ctInt, ctFloat}`
  # as ambiguous)
  case w
  of "proc", "func", "method", "iterator", "converter", "template", "macro": true
  else: false

func nxHeaderParen(lines: seq[string], pl, pc: int): bool =
  ## is the `(` at (pl, pc) the one of a routine's parameters: `proc p(`, `func q*[T](`, `` proc `+`( ``, `proc (`
  # before the `(`: the keyword, the name (backquoted, exported), the generic parameters — or `proc(` alone
  let code = nxUncommented(lines[pl])
  if pc >= code.len: return                       # (a `(` in a comment)
  var s = code[0 ..< pc].strip(leading = false)
  if s.endsWith("]"):
    var d = 0
    var k = s.high
    while k >= 0:
      if s[k] == ']': inc d
      elif s[k] == '[':
        dec d
        if d == 0: break
      dec k
    if k <= 0: return
    s = s[0 ..< k].strip(leading = false)
  if s.endsWith("*"): s = s[0 ..< ^1].strip(leading = false)
  if s.endsWith("`"):
    let k = s.rfind('`', last = s.high - 1)
    if k < 0: return
    s = s[0 ..< k].strip(leading = false)
  else:
    var k = s.len
    while k > 0 and nxIsIdent(s[k - 1]): dec k
    if k == s.len: return
    if not nxHeaderKw(s[k ..< s.len]): s = s[0 ..< k].strip(leading = false)    # (a name: the keyword before it)
  var w = s.len
  while w > 0 and nxIsIdent(s[w - 1]): dec w
  nxHeaderKw(s[w ..< s.len]) and (w == 0 or s[w - 1] in {' ', '(', '[', ',', '=', ':'})

proc nxHeaderParamType(lines: seq[string], line, col: int): (bool, string) =
  ## where a parameter's default starts in a routine's header — `proc p(a: int, c: Color = `, also over several
  ## lines, `func q*[T](x: T; n = ` —: (true, the type written for it; "" none: the default makes it); (false, "")
  ## when (line, col) is not in a routine's parameters
  let (pl, pc) = nxOpenParen(lines, line, col)
  if pl < 0 or not nxHeaderParen(lines, pl, pc): return
  # the parameter being written: `names: T = ` → T
  let cur = nxSplitTop(nxJoinedFrom(lines, pl, pc, line, col), {',', ';'})[^1].strip
  if not cur.endsWith("="): return
  let body = cur[0 ..< ^1].strip
  let c = nxFindTop(body, ':')
  result[0] = true
  if c < 0: return
  var t = nxStripPragma(body[c + 1 .. ^1])[0].strip
  if t.startsWith("static[") and t.endsWith("]"): t = t[7 ..< ^1].strip
  result[1] = t

proc nxExpectedType*(f: NxFile, sc: NxScope, lines: seq[string], locals: seq[NxSym], line, col: int,
                     h: NxSigHelp): string =
  ## the type the code wants where a word starts at (line, col) — "" when it cannot be told: an argument of a
  ## call where every overload that fits so far wants the same type there (the call may have started on a line
  ## above), a field in an object constructor, a parameter's default in a routine's header, `let x: T = `, `x = `
  ## (x's type), `result = `, `return ` / `yield `, `==` / `!=` / `<` … against a typed operand
  let text = lines[line]
  let b = text[0 ..< min(col, text.len)].strip(leading = false)
  if b.len == 0 and h.overloads.len == 0: return
  # a parameter's default in a routine's header: the parameter's type (none written: nothing expected)
  if b.len > 1 and b[^1] == '=' and b[^2] notin {'<', '>', '!', '=', '+', '-', '*', '/', '&', '|', '^', '%', '~', '.',
                                                  ':'}:
    let (inHeader, pt) = nxHeaderParamType(lines, line, col)
    if inHeader: return pt
  # the arguments written so far in the call around (it may have started on a line above), and the name of this
  # one if it has one
  var callArgs: seq[string]
  var argName = ""
  var argStart = false
  if h.overloads.len > 0:
    var q = b.high
    var d = 0
    while q >= 0:
      if b[q] in {')', ']', '}'}: inc d
      elif b[q] in {'(', '[', '{'}:
        if d == 0: break
        dec d
      elif b[q] == '"':
        dec q
        while q >= 0 and b[q] != '"': dec q
      dec q
    var inner = ""
    var inCall = false
    if q >= 0 and b[q] == '(':
      if nxHeaderParen(lines, line, q): return            # (a routine's own parameters: `proc p(a: int, b: `)
      inner = b[q + 1 .. ^1]
      inCall = true
    elif q < 0:
      # no bracket left open on this line: the call started on a line above — its arguments so far, joined
      let (pl, pc) = nxOpenParen(lines, line, col)
      if pl >= 0 and pl < line:
        if nxHeaderParen(lines, pl, pc): return
        inner = nxJoinedFrom(lines, pl, pc, line, col)
        inCall = true
    if inCall:
      callArgs = nxSplitTop(inner & " ", {','})
      let cur = callArgs.pop.strip            # (the one being written)
      if cur.len == 0: argStart = true
      elif cur.len > 1 and cur[^1] in {'=', ':'} and cur[^2] notin NxOpChars:
        let nm = cur[0 ..< ^1].strip
        if nm.len > 0 and nm.allCharsInSet(IdentChars + {'`'}):     # (name = …, or a constructor's name: …)
          argName = nm
          argStart = true
  if argStart:
    let ctor = h.overloads[0].sym.pragmas == "ned:constructor"
    if ctor:
      # Foo(name: |) — the field's type
      if argName.len == 0: return
      for p in h.overloads[0].sym.params:
        if nxNorm(p.name.strip(chars = {'`', '*'})) == nxNorm(argName): return p.typ
      return
    var memo: Table[string, string]
    let given = if callArgs.len <= 6: nxArgTypes(f, sc, locals, callArgs, line, memo) else: @[]
    var named = false
    for a in callArgs:
      if nxFindTop(a, '=') > 0: named = true      # (an argument by name before: positions no longer tell)
    if named and argName.len == 0: return
    let skip = if h.ufcs: 1 else: 0
    var want = ""
    var any = false
    for r in h.overloads[0 ..< min(h.overloads.len, 40)]:
      let ps = r.sym.params
      var pt = ""
      var k = -1
      if argName.len > 0:
        for i, p in ps:
          if nxNorm(p.name.strip(chars = {'`', '*'})) == nxNorm(argName): k = i
        if k < 0: continue
      else:
        k = h.active + skip
        if k >= ps.len:
          if ps.len > 0 and nxStripMods(ps[^1].typ).startsWith("varargs["): k = ps.high
          else: continue                         # (fewer parameters: does not fit)
      pt = ps[k].typ
      if pt.len == 0 and ps[k].default.len > 0: pt = nxLiteralType(ps[k].default)
      # does it fit the arguments written so far?
      var fits = true
      if argName.len == 0:
        for i, t in given:
          let at = if i + skip < ps.len: i + skip else: ps.high
          if t.len > 0 and at >= 0 and ps[at].typ.len > 0 and
             nxCompat(sc, nxArgElem(ps[at].typ), r.sym.generics, t) == 0:
            fits = false
            break
      if not fits: continue
      any = true
      pt = nxArgElem(pt)
      let pb = nxBaseName(pt)
      if pt.len == 0 or pb in NxNoExpect or nxIsGenericName(pb, r.sym.generics) or
         (pb.len <= 2 and pb.len > 0 and pb[0] in {'A'..'Z'} and nxTypeSyms(sc, pb).len == 0) or
         pt.startsWith("proc") or '|' in pt or pt.startsWith("static"):
        return                                   # (one that takes anything there: nothing to put first)
      if want.len == 0: want = pt
      elif nxNorm(nxFlat(want).replace(" ", "")) != nxNorm(nxFlat(pt).replace(" ", "")): return   # (two types wanted)
    return (if any: want else: "")
  if b.len == 0: return
  if b.endsWith("=") and not b.endsWith("==") and (b.len < 2 or b[^2] notin {'<', '>', '!', '=', '+', '-', '*', '/', '&',
                                                                              '|', '^', '%', '~', '.', ':'}):
    let lhs = b[0 ..< ^1].strip
    for kw in ["proc ", "func ", "method ", "iterator ", "converter ", "template ", "macro ", "type "]:
      if lhs.startsWith(kw): return                              # (a routine's body, a type's definition)
    # let x: T = …, var x: T = …, a name in a var section (x: T = …)
    let c = nxFindTop(lhs, ':')
    if c > 0:
      var names = lhs[0 ..< c].strip
      for kw in ["let ", "var ", "const "]:
        if names.startsWith(kw): names = names[kw.len .. ^1].strip
      for n in names.split(','):
        let n2 = nxStripPragma(n.strip)[0].strip(chars = {'*', '`', ' '})
        if n2.len == 0 or not n2.allCharsInSet(IdentChars): return    # (`if c: x = …`, `of a: …`)
      var t = lhs[c + 1 .. ^1].strip
      let p = t.find("{.")
      if p >= 0: t = t[0 ..< p].strip
      if t.len > 0 and t[0] notin {'"', '\''}: return t
      return
    for kw in ["let ", "var ", "const "]:
      if lhs.startsWith(kw) or (" " & kw) in lhs: return        # (no type written: nothing to expect)
    let target = nxReceiver(lhs, lhs.len)
    if target.len == 0 or target != lhs.strip and not lhs.endsWith(" " & target) and not lhs.endsWith(":" & target):
      return
    return nxTypeOfExpr(f, sc, locals, target, line, 0).typ
  let lastWord = b[max(0, max(b.rfind(' '), b.rfind(':')) + 1) .. ^1]
  if lastWord in ["return", "yield"] and (b == lastWord or b[b.high - lastWord.len] in {' ', ':', ';', '('}):
    for s in locals:
      if s.kind == nxResult: return s.typ
    let ri = nxEnclosing(f, line)
    if ri >= 0 and f.syms[ri].kind == nxIterator and lastWord == "yield": return f.syms[ri].ret
    return
  for op in ["==", "!=", "<=", ">=", "<", ">"]:
    if b.endsWith(op):
      let le = b[0 ..< b.len - op.len].strip(leading = false)
      if le.len == 0 or le[^1] in NxOpChars: return             # (..<, =>, <<)
      let left = nxReceiver(le, le.len)
      if left.len == 0: return
      return nxTypeOfExpr(f, sc, locals, left, line, 0).typ

type NxFitMemo = object
  full, base: Table[string, bool]      # (a type as written → fits; a base type name → fits)
  w, wb, wAlias: string                # the expected type, its base name and what that is an alias of (normalized)
  alts: seq[string]                    # a union's alternatives (normalized base names)
  wInt, wFloat, wList, wChars: bool    # an integer, a float, an openArray / varargs (of char) is expected
  subs: HashSet[string]                # the expected object type and the types inheriting from it (normalized)
  parentMade: bool

proc nxFitInit(sc: NxScope, w: string): NxFitMemo =
  result.w = w
  let b = nxBaseName(w)
  result.wb = nxNorm(b)
  let ra = nxResolveAlias(sc, b)
  result.wAlias = nxNorm(ra)
  result.wInt = b in NxInts or ra in NxInts
  result.wFloat = b in NxFloats or ra in NxFloats
  result.wList = b in ["openArray", "varargs"]
  if result.wList:
    let a = nxTypeArgs(w)
    result.wChars = a.len > 0 and a[0] == "char"
  let alts = nxUnionAlts(sc, w)
  if alts.len > 1:
    for x in alts: result.alts.add nxNorm(nxBaseName(x))

proc nxSubtypeFits(sc: NxScope, m: var NxFitMemo, tb: string): bool =
  ## an object type that inherits from the expected one — the types of the scope that do are worked out once:
  ## `X = object of Y` from Y down, and `PX = ref X` of each
  if not m.parentMade:
    m.parentMade = true
    let (pr, _) = nxObjectDef(sc, m.w)
    if pr.file != nil:
      var kids, refOf: Table[string, seq[string]]
      for r in sc.refs:
        template s: untyped = r.file.syms[r.idx]
        if s.kind != nxType: continue
        let k = s.typ.find(" of ")
        if k > 0 and "object" in s.typ[0 ..< k]:
          kids.mgetOrPut(nxNorm(nxBaseName(s.typ[k + 4 .. ^1])), @[]).add nxNorm(s.name)
        elif s.typ.startsWith("ref ") or s.typ.startsWith("ptr "):
          refOf.mgetOrPut(nxNorm(nxBaseName(s.typ)), @[]).add nxNorm(s.name)
      var todo = @[m.wb, nxNorm(pr.sym.name)]
      var i = 0
      while i < todo.len and i < 5000:
        let x = todo[i]
        inc i
        if x in m.subs: continue
        m.subs.incl x
        for c in kids.getOrDefault(x): todo.add c
        for c in refOf.getOrDefault(x): todo.add c
  nxNorm(tb) in m.subs

proc nxFitsExpected(sc: NxScope, m: var NxFitMemo, t0: string): bool =
  ## can a value of type `t` go where the expected type is wanted: the same type, an alias of it, a number that
  ## converts without a cast, a seq for an openArray, a subtype — with the same type arguments
  if t0.len == 0: return false
  if t0 in m.full: return m.full[t0]
  let t = if t0[0] in {'v', 's', 'l', 'o'}: nxStripValMods(t0) else: t0     # (var T, sink T, lent T …: a T)
  let tb = nxBaseName(t)
  let n = nxNorm(tb)
  if n.len == 0: result = false
  elif n in m.base: result = m.base[n]
  else:
    result = n == m.wb or n in m.alts
    if not result:
      let ta = nxResolveAlias(sc, tb)
      let na = nxNorm(ta)
      result = na == m.wAlias or na in m.alts or
               (m.wInt and (tb in NxInts or ta in NxInts)) or (m.wFloat and (tb in NxFloats or ta in NxFloats)) or
               (m.wList and tb in ["seq", "array", "openArray", "varargs"]) or
               (m.wChars and tb in ["string", "cstring"])
      if not result and not m.wInt and not m.wFloat and not m.wList: result = nxSubtypeFits(sc, m, tb)
    m.base[n] = result
  if result and '[' in m.w and '[' in t and not m.wList:
    let wa = nxTypeArgs(m.w)
    let ta = nxTypeArgs(t)
    if wa.len == ta.len:
      for i in 0 ..< wa.len:
        if nxNorm(nxFlat(wa[i]).replace(" ", "")) != nxNorm(nxFlat(ta[i]).replace(" ", "")) and
           nxCompat(sc, wa[i], "", ta[i]) < 2: result = false
  m.full[t0] = result

proc nxRankExpected*(items: var seq[NxItem], f: NxFile, sc: NxScope, want: string, recv = "") =
  ## put the items whose type (or result type) fits the expected one first — the others keep their place behind them:
  ## locals and this module's declarations first; another module's only when the type is not a number, a string,
  ## a bool … (of those there are hundreds: they move one step up)
  let w = nxStripValMods(want)
  if w.len == 0 or nxBaseName(w) in NxNoExpect: return
  let plain = nxPlainType(w)
  let wb = nxNorm(nxBaseName(w))
  var memo = nxFitInit(sc, w)
  var inferred = 0
  for it in items.mitems:
    if it.detail == "keyword" or it.kind == nxModule: continue
    var fits = false
    if it.refs.len == 0:
      template s: untyped = it.local                 # (no copy of the declaration)
      if s.kind in NxRoutineKinds: fits = nxFitsExpected(sc, memo, s.ret)
      elif s.kind == nxType: fits = not plain and nxNorm(s.name) == wb
      elif s.kind in {nxField, nxParam} and it.insert.len > 0: fits = false     # (`name: ` / `name = `)
      else: fits = nxFitsExpected(sc, memo, s.typ)
    else:
      for r in it.refs:
        template s: untyped = r.file.syms[r.idx]
        case s.kind
        of NxRoutineKinds:
          if s.ret.len == 0 or s.ret == "auto": continue
          if s.generics.len > 0:
            if recv.len == 0: continue                    # (a generic result: what it is depends on the call)
            let rt = nxSubst(nxStripValMods(s.ret), nxBindings(s, recv))
            if nxIsGenericName(nxBaseName(rt), s.generics): continue
            fits = nxFitsExpected(sc, memo, rt)
          else: fits = nxFitsExpected(sc, memo, s.ret)
        of nxType:
          if not plain:
            if nxNorm(s.name) == wb: fits = true
            elif " of " in s.typ: fits = nxSubtypeFits(sc, memo, s.name)   # (only a type that inherits can be one)
        of nxEnumVal: fits = nxFitsExpected(sc, memo, s.owner)
        of nxField: fits = nxFitsExpected(sc, memo, if it.detail.len > 0: it.detail else: s.typ)
        else:
          if s.typ.len > 0: fits = nxFitsExpected(sc, memo, s.typ)
          elif s.value.len > 0:
            var t = nxLiteralType(s.value)
            if t.len == 0 and r.file == f and inferred < 40:
              # (a declaration of this module written without a type: what its value is, for the first few)
              inc inferred
              t = nxTypeOfExpr(f, sc, @[], s.value, s.line, 0).typ
            fits = nxFitsExpected(sc, memo, t)
        if fits: break
    if not fits: continue
    # (a number, a string … expected: the system's and other modules' values and routines of that type are many —
    # one step up only, behind the locals; an enum's values always first)
    it.rank = if it.rank <= 1 or not plain or it.kind == nxEnumVal: -1 else: max(0, it.rank - 1)

proc nxComplete*(f: NxFile, lines: seq[string], line, col: int): NxCompletion =
  let f = nxAt(f, lines, line)             # (code in a `when` branch left out here: as that branch sees it)
  let sc = nxScope(f)
  let text = lines[line]
  var ws = min(col, text.len)
  while ws > 0 and nxIsIdent(text[ws - 1]): dec ws
  let lead = text[0 ..< ws].strip(trailing = false)
  block pragmas:
    # inside {. … .}: pragmas, and the macros and templates that can be used as one ({.async.})
    let po = text[0 ..< ws].rfind("{.")
    if po < 0 or text[po ..< ws].find(".}") >= 0: break pragmas
    let between = text[po + 2 ..< ws]
    let k2 = max(between.rfind(','), between.rfind(' '))
    if k2 >= 0 and between[0 .. k2].count('[') > between[0 .. k2].count(']'): break pragmas   # (raises: [Val…)
    if between.rfind(':') > max(between.rfind(','), -1): break pragmas                     # (deprecated: "…")
    for (p, d) in NxPragmas:
      result.items.add NxItem(label: p, detail: d, kind: nxConst, rank: 0,
                              local: NxSym(name: p, kind: nxConst, typ: "pragma", doc: d))
    var seenP: HashSet[string]
    var parts = @[f]
    parts.add nxIncluded(f)
    for g in parts:
      for (p, pl) in g.pragmas:
        if p notin seenP:
          seenP.incl p
          result.items.add NxItem(label: p, detail: "pragma · " & extractFilename(g.path) & ":" & $(pl + 1),
                                  kind: nxConst, rank: 1, local: NxSym(name: p, kind: nxConst, typ: "pragma"))
    for r in sc.refs:
      if r.sym.kind in {nxMacro, nxTemplate} and r.sym.name notin seenP and r.sym.name.len > 1:
        seenP.incl r.sym.name
        result.items.add NxItem(label: r.sym.name, detail: nxKindWord(r.sym.kind), kind: r.sym.kind, refs: @[r], rank: 2)
    result.known = true
    return
  if (lead.startsWith("import ") or lead.startsWith("include ") or
      (lead.startsWith("from ") and " import " notin lead)) and lead.find('#') < 0:
    # import std/str… → module names
    result.items = nxModuleItems(f, text[0 ..< ws])
    result.known = true
    return
  let locals = nxLocals(f, lines, line, col)
  if ws > 0 and text[ws - 1] == '.' and not (ws > 1 and text[ws - 2] == '.'):
    result.member = true
    let joined = nxJoinBack(lines, line, ws - 1)
    let recv = nxReceiver(joined, joined.len)
    if recv.len == 0: return
    var v = nxTypeOfExpr(f, sc, locals, recv, line, 0)
    if recv.startsWith("`") and nxQuoteStart(lines, line) >= 0:
      # `apId`.… in quote do: the value the code made holds, not the macro's NimNode
      let (x, xe) = nxName(recv, 0)
      let qt = nxQuotedType(f, sc, lines, locals, x, 0)
      if qt.len > 0:
        v = nxTypeOfExpr(f, sc, locals & @[NxSym(name: x, kind: nxLet, typ: qt, line: line)], x & recv[xe .. ^1],
                         line, 0)
    if v.module.len > 0:
      result.known = true
      result.recvIsType = true
      var got: seq[NxRef]
      var seen: HashSet[string]
      nxExports(v.module, 0, seen, got)
      nxAddRefs(result.items, f, got)
      return
    if v.typeName.len > 0:
      result.known = true
      result.recvIsType = true
      result.receiverType = v.typeName
      var vals: seq[NxRef]
      for r in nxLookup(sc, v.typeName):
        if r.sym.kind == nxType:
          for i, s in r.file.syms:
            if s.kind == nxEnumVal and s.owner == v.typeName: vals.add NxRef(file: r.file, idx: int32(i))
      nxAddRefs(result.items, f, vals)
      var tprocs: seq[NxRef]
      for r in sc.refs:
        let s = r.sym
        if s.kind in NxRoutineKinds and s.params.len > 0:
          let p = nxStripMods(s.params[0].typ)
          if p.startsWith("typedesc") or p.startsWith("type "):
            let arg = if p.startsWith("typedesc[") and p.endsWith("]"): p[9 ..< ^1].strip else: ""
            if arg.len == 0 or arg == v.typeName or arg in nxGenericNames(s.generics) or
               (arg.len <= 2 and arg[0] in {'A'..'Z'}) or
               ('[' in arg and nxNorm(nxBaseName(arg)) == nxNorm(nxBaseName(v.typeName)) and
                nxCompat(sc, arg, s.generics, v.typeName) > 0):     # (typedesc[Future[T]] for Future[void])
              tprocs.add r
      nxAddRefs(result.items, f, tprocs, ufcs = true, recv = "typedesc[" & v.typeName & "]")
      return
    var typ = v.typ
    if typ.len == 0 and v.routine.len > 0: typ = nxCallType(f, sc, locals, v.routine, "", line, 0)
    result.receiverType = typ
    typ = nxConstrained(f, line, typ)        # (x: T with [T: Duration | Time]: the members of both)
    result.known = typ.len > 0
    if result.known:
      (result.recvShape, result.enumVals) = nxPostfixShape(sc, typ)
      var flds: seq[NxRef]
      for r in nxFields(sc, typ):
        if nxVisible(f, r): flds.add r
      nxAddRefs(result.items, f, flds, rankBias = -1, binds = nxTypeBindings(sc, typ))
      let st = nxStripMods(typ)
      if st.startsWith("tuple[") and st.endsWith("]"):
        # an anonymous tuple's named fields
        for p in nxParseParams(st[6 ..< st.high]):
          result.items.add NxItem(label: p.name, detail: p.typ, kind: nxField, rank: 0,
                                  local: NxSym(name: p.name, kind: nxField, typ: p.typ, owner: "tuple"))
      # conversions written as calls:  x.float, i.uint8, s.cstring
      let ra = nxResolveAlias(sc, nxBaseName(st))
      let conv = if ra in NxInts or ra in NxFloats or ra in ["char", "bool"]:
                   @["int", "float", "int64", "uint8", "uint", "int32", "float32", "char", "byte", "uint64", "int8",
                     "int16", "uint16", "uint32", "float64"]
                 elif ra == "string": @["cstring"]
                 elif ra == "cstring": @["string"]
                 else: @[]
      for t in conv:
        if t != ra: result.items.add NxItem(label: t, detail: "conversion", kind: nxType, rank: 4,
                                           local: NxSym(name: t, kind: nxType, typ: "converts to " & t))
      var numLike = conv.len > 0 and ra != "string" and ra != "cstring"
      var ownDistinct = ""
      var tsyms: seq[NxRef]
      if '.' in st:
        # posix.Time (another module's type named like one of this module's): that module's
        let (r0, _) = nxObjectDef(sc, st)
        if r0.file != nil: tsyms.add r0
      else: tsyms = nxLookup(sc, nxBaseName(st))
      for r in tsyms:
        if r.sym.kind == nxType and r.sym.typ.strip.startsWith("distinct "):
          ownDistinct = nxBaseName(r.sym.typ.strip[9 .. ^1])
          if conv.len == 0 and (nxResolveAlias(sc, ownDistinct) in NxInts or ownDistinct in NxInts):
            numLike = true
            for t in ["int", "cint", "uint", "int32", "int64"]:
              result.items.add NxItem(label: t, detail: "conversion", kind: nxType, rank: 4,
                                      local: NxSym(name: t, kind: nxType, typ: "converts to " & t))
          elif conv.len == 0 and ownDistinct.len > 0:
            # (a distinct string, RawJson: back to what it is made of, v.string)
            result.items.add NxItem(label: ownDistinct, detail: "conversion", kind: nxType, rank: 4,
                                    local: NxSym(name: ownDistinct, kind: nxType, typ: "converts to " & ownDistinct))
        break
      if numLike:
        # and the distinct numbers in scope: fd.AsyncFD, h.SocketHandle (and back: x.int); and from an integer,
        # this module's enums and its imports': i.Color
        let intLike = ra in NxInts or ownDistinct.len > 0
        var seenD: HashSet[string]
        for r in sc.refs:
          let s = r.sym
          if s.kind != nxType or s.name in seenD or s.name == st: continue
          let def = s.typ.strip
          if def.startsWith("distinct "):
            let b = nxBaseName(def[9 .. ^1])
            if b in NxInts or nxResolveAlias(sc, b) in NxInts:
              seenD.incl s.name
              result.items.add NxItem(label: s.name, detail: "conversion", kind: nxType, rank: 4, refs: @[r])
          elif intLike and r.origin in {1, 2} and (def.startsWith("range[") or def.startsWith("range ")) and
               (r.file == f or s.exported):
            # (yearweek.IsoWeekRange)
            seenD.incl s.name
            result.items.add NxItem(label: s.name, detail: "conversion to the range", kind: nxType, rank: 4,
                                    refs: @[r])
          elif r.origin in {1, 2} and (def == "enum" or def.startsWith("enum ")) and
               (r.file == f or s.exported):
            seenD.incl s.name
            result.items.add NxItem(label: s.name, detail: "conversion to the enum", kind: nxType, rank: 4,
                                    refs: @[r])
    # routines declared inside this one, callable with a dot too
    var seenLocalR: HashSet[string]
    for i in countdown(locals.high, 0):
      let s = locals[i]
      if s.kind notin NxRoutineKinds or s.params.len == 0 or s.line > line or s.name in seenLocalR: continue
      if result.known and nxCompatP(sc, s.params[0], s.generics, typ) == 0: continue
      seenLocalR.incl s.name
      result.items.add NxItem(label: s.name, detail: nxShortDetail(s), kind: s.kind, local: s, rank: 0, ufcs: true)
    var exact, related, generic: seq[NxRef]
    for r in sc.refs:
      let s = r.sym
      if s.kind notin NxRoutineKinds or s.params.len == 0: continue
      if not result.known:
        generic.add r
        continue
      case nxCompatP(sc, s.params[0], s.generics, typ)
      of 3: exact.add r
      of 2: related.add r
      of 1: generic.add r
      else: discard
    nxAddRefs(result.items, f, exact, ufcs = true, recv = typ)
    nxAddRefs(result.items, f, related, ufcs = true, rankBias = 1, recv = typ)
    nxAddRefs(result.items, f, generic, ufcs = true, rankBias = 2, recv = typ)
    # a converter from this type (httpcore's HttpHeaderValues → string): what the type it makes takes, after
    # the type's own (contentLengthHeader.parseInt)
    # (one written for this very type: a converter from a type class or union — pixie's SomePaint, which strings
    # are — would bring every routine of what it makes to every string)
    var convTo: seq[string]
    for r in exact:
      if r.sym.kind == nxConverter and r.sym.ret.len > 0 and r.sym.generics.len == 0 and
         nxNorm(nxBaseName(nxStripMods(r.sym.params[0].typ))) == nxNorm(nxBaseName(nxStripMods(typ))) and
         nxNorm(nxStripMods(r.sym.ret)) != nxNorm(nxStripMods(typ)) and r.sym.ret notin convTo:
        convTo.add r.sym.ret
    if convTo.len > 0:
      var have: HashSet[string]
      for lst in [exact, related, generic]:
        for r in lst: have.incl r.sym.name
      for u in convTo[0 ..< min(convTo.len, 3)]:
        var viaConv: seq[NxRef]
        for r in sc.refs:
          let s = r.sym
          if s.kind notin NxRoutineKinds or s.kind == nxConverter or s.params.len == 0 or s.name in have: continue
          if nxCompatP(sc, s.params[0], s.generics, u) >= 2:
            viaConv.add r
            have.incl s.name
        nxAddRefs(result.items, f, viaConv, ufcs = true, rankBias = 2, recv = u)
    # a concept (x: Shape, or [T: Shape]): what it asks of its type comes first
    if result.known:
      let need = nxConceptNeeds(f, sc, lines, line, nxStripMods(typ))
      if need.len > 0:
        var have: HashSet[string]
        for it in result.items: have.incl it.label
        var reqs: seq[NxRef]
        for nm in need:
          for r in nxLookup(sc, nm):
            if r.sym.kind in NxRoutineKinds and r.sym.name notin have: reqs.add r
        nxAddRefs(result.items, f, reqs, ufcs = true, rankBias = -1)
    # where a type is expected (`f(p.`, `let n: int = p.`, `result = p.` …): the members of that type first
    if result.known:
      let rs = ws - 1 - recv.len
      if rs >= 0 and joined == text[0 ..< ws - 1] and text[rs ..< ws - 1] == recv:
        var before = text[0 ..< rs].strip(leading = false)
        if before.len == 0 and line > 0:
          # (an argument on a line of its own: what the line above ends with — `f(a,⏎  p.`)
          var l2 = line - 1
          while l2 > 0 and line - l2 < 5 and nxCodeOf(lines[l2]).len == 0: dec l2
          let above = nxCodeOf(lines[l2])
          if above.len > 0 and above[^1] in {'(', ','}: before = above
        if before.len > 0 and (before[^1] in {'(', ',', '=', ':', '<', '>'} or before.endsWith("return") or
                               before.endsWith("yield")):
          let h2 = if before[^1] in {'(', ',', '=', ':'}: nxSignatureHelp(f, lines, line, rs) else: NxSigHelp()
          var want = ""
          try: want = nxExpectedType(f, sc, lines, locals, line, rs, h2)
          except CatchableError: want = ""
          if want.len > 0: nxRankExpected(result.items, f, sc, want, recv = typ)
    return
  # a plain name: locals, this module, imports, system, module names, keywords
  var seenLocal: HashSet[string]
  for i in countdown(locals.high, 0):
    let s = locals[i]
    if s.name in seenLocal or s.name == "_": continue
    seenLocal.incl s.name
    var ls = s
    if ls.typ.len == 0 and ls.kind notin NxRoutineKinds and seenLocal.len <= 40:
      # show what the local holds:  c  Circle
      ls.typ = nxTypeOfName(f, sc, locals[0 .. i], s.name, line, 0).typ
    result.items.add NxItem(label: s.name, detail: nxShortDetail(ls), kind: s.kind, local: ls, rank: 0)
  var plain: seq[NxRef]
  let here = nxEnclosing(f, line)
  for r in sc.refs:
    if r.sym.kind == nxField: continue
    if r.sym.local and (r.file != f or here < 0 or nxEnclosing(f, r.sym.line) != here): continue   # (another routine's type)
    plain.add r
  nxAddRefs(result.items, f, plain)
  for m, p in sc.modules:
    result.items.add NxItem(label: m, detail: "module", kind: nxModule, rank: 2,
                            local: NxSym(name: m, kind: nxModule, value: p))
  for k in NxKeywords: result.items.add NxItem(label: k, detail: "keyword", kind: nxModule, rank: 5)
  result.known = true
  # inside an object constructor  Foo(na…  → its fields, as `name: `
  let h = nxSignatureHelp(f, lines, line, col)
  if h.overloads.len > 0 and h.overloads[0].sym.pragmas == "ned:constructor":
    let s = h.overloads[0].sym
    for p in s.params:
      result.items.add NxItem(label: p.name, insert: p.name & ": ", detail: p.typ, kind: nxField, rank: 0,
                              local: NxSym(name: p.name, kind: nxField, typ: p.typ, owner: s.name))
  elif h.overloads.len > 0:
    # inside a call, where an argument starts:  f(x, tim…  → its parameters by name, `timeout = `
    var k = ws - 1
    while k >= 0 and text[k] == ' ': dec k
    if k >= 0 and text[k] in {'(', ','}:
      var given: HashSet[string]                    # (the ones written already)
      var q = k
      var d = 0
      while q >= 0:
        if text[q] in {')', ']'}: inc d
        elif text[q] in {'(', '['}:
          if d == 0: break
          dec d
        dec q
      for a in nxSplitTop(text[max(0, q + 1) ..< ws], {','}):
        let eqk = nxFindTop(a, '=')
        if eqk > 0: given.incl nxNorm(a[0 ..< eqk].strip)
      var seenP: HashSet[string]
      for r in h.overloads:
        let ps = r.sym.params
        for i in (if h.ufcs: 1 else: 0) ..< ps.len:
          let pn = ps[i].name.strip(chars = {'`', '*'})
          if pn.len == 0 or nxNorm(pn) in given or pn in seenP: continue
          seenP.incl pn
          let what = if ps[i].typ.len > 0: ps[i].typ else: "= " & ps[i].default
          result.items.add NxItem(label: pn & " =", insert: pn & " = ", detail: what & " · " & r.sym.name & "'s argument",
                                  kind: nxParam, rank: 1, local: NxSym(name: pn, kind: nxParam, typ: ps[i].typ,
                                  value: ps[i].default))
  # the type the code wants here (an argument, `let x: T = `, `result = ` …): the items of that type first
  var expect = ""
  let leadE = text[0 ..< ws].strip
  if not (leadE == "of" or (leadE.startsWith("of ") and leadE.endsWith(","))):
    try: expect = nxExpectedType(f, sc, lines, locals, line, ws, h)
    except CatchableError: expect = ""
  # `of` in a case on an enum, `x == `, or an enum expected: the enum's values (those no branch has taken yet first)
  block enumValues:
    let lead = text[0 ..< ws].strip
    var et = ""
    var taken: HashSet[string]
    if lead == "of" or (lead.startsWith("of ") and lead.endsWith(",")):
      let ind = leadWs(text)
      var l2 = line - 1
      while l2 >= 0 and line - l2 < 400:
        let t2 = lines[l2].strip
        if t2.len > 0 and leadWs(lines[l2]) <= ind and t2.startsWith("case "):
          var ce = t2[5 .. ^1].strip
          if ce.endsWith(":"): ce = ce[0 ..< ^1].strip
          et = nxTypeOfExpr(f, sc, nxLocals(f, lines, l2, 0), ce, l2, 0).typ
          for l3 in l2 + 1 ..< line:
            let t3 = lines[l3].strip
            if t3.startsWith("of "):
              let c3 = nxFindTop(t3, ':')
              for v in nxSplitTop(t3[3 ..< (if c3 > 0: c3 else: t3.len)], {','}): taken.incl nxNorm(v.strip)
          break
        if t2.len > 0 and leadWs(lines[l2]) < ind and not t2.startsWith("of ") and not t2.startsWith("elif ") and
           not t2.startsWith("else"):
          break
        dec l2
    else:
      for op in ["==", "!="]:
        if lead.endsWith(op):
          var le = lead[0 ..< lead.len - op.len].strip
          let sp = max(le.rfind(' '), le.rfind('('))
          if sp >= 0: le = le[sp + 1 .. ^1]
          if le.len > 0: et = nxTypeOfExpr(f, sc, locals, le, line, 0).typ
      if et.len == 0: et = expect
    if et.len == 0: break enumValues
    let eb = nxBaseName(nxStripMods(et))
    for r in nxTypeSyms(sc, eb):
      if not r.sym.typ.strip.startsWith("enum"): continue
      var keep: seq[NxItem]                 # (the same values among the plain names: once, here)
      for it in result.items:
        if not (it.kind == nxEnumVal and it.refs.len > 0 and it.refs[0].sym.owner == r.sym.name): keep.add it
      result.items = keep
      for i, s2 in r.file.syms:
        if s2.kind == nxEnumVal and s2.owner == r.sym.name:
          let used = nxNorm(s2.name) in taken
          result.items.add NxItem(label: s2.name, detail: r.sym.name & (if used: " · has a branch" else: ""),
                                  kind: nxEnumVal, rank: (if used: 3 else: 0), refs: @[NxRef(file: r.file, idx: int32(i))])
      break
  if expect.len > 0: nxRankExpected(result.items, f, sc, expect)

proc nxRstToMd*(doc0: string): string =
  ## Nim doc comments are RST-flavoured: turn code blocks and ``literals`` into Markdown
  var doc = doc0
  # `text <link>`_  →  `text`   (the link may start on the next line)
  var k = doc.find(">`_")
  while k >= 0:
    let lt = doc.rfind('<', last = k)
    if lt < 0: break
    var st = lt
    while st > 0 and doc[st - 1] in {' ', '\n'}: dec st
    doc = doc[0 ..< st] & "`" & doc[k + 3 .. ^1]
    k = doc.find(">`_", st)
  var outp: seq[string]
  var inBlock = false
  var blockInd = 0
  for l in doc.splitLines:
    let t = l.strip
    if t.startsWith(".. code-block::") or t.startsWith(".. code::"):
      outp.add "```nim"
      inBlock = true
      blockInd = -1
      continue
    if inBlock:
      if t.len == 0:
        outp.add ""
        continue
      let ind = l.len - l.strip(trailing = false).len
      if blockInd < 0: blockInd = ind
      if ind >= blockInd and blockInd > 0:
        outp.add l[min(blockInd, l.len) .. ^1]
        continue
      outp.add "```"
      inBlock = false
    if t.startsWith("```"):
      outp.add t
      continue
    outp.add l.replace("``", "`")
  if inBlock: outp.add "```"
  outp.join("\n").strip

proc nxDoc*(r: NxRef, ufcs = false, withSig = true): string =
  ## Markdown for the documentation panel and hover: signature, doc comment, where it lives
  let s = r.sym
  if withSig: result = "```nim\n" & nxSig(s) & "\n```"
  let dp = s.pragmas.find("deprecated")
  if dp >= 0:
    var why = s.pragmas[dp + 10 .. ^1].strip(chars = {' ', ':'})
    let q = why.find('"', 1)
    why = if why.startsWith("\"") and q > 0: why[1 ..< q] else: ""
    result.add "\n**deprecated**" & (if why.len > 0: " — " & why else: "")
  if s.doc.strip.len > 0: result.add (if result.len > 0: "\n" else: "") & nxRstToMd(s.doc)
  var where = r.file.module
  if nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir):
    where = "std/" & r.file.module
  result.add "\n\n" & where & " · " & extractFilename(r.file.path) & ":" & $(s.line + 1)

proc nxDocItem*(it: NxItem, maxOverloads = 6): string =
  if it.refs.len == 0:
    let s = it.local
    if s.kind == nxModule and s.value.len > 0:
      let g = nxLoad(s.value)
      return "```nim\nimport " & s.name & "\n```\n" & (if g != nil and g.doc.len > 0: nxRstToMd(g.doc) & "\n\n" else: "") &
             s.value
    if it.detail == "keyword": return nimDocFor(it.label)
    if s.kind == nxModule: return "folder " & s.value
    return "```nim\n" & nxSig(s) & (if s.typ.len == 0 and s.value.len > 0 and s.kind != nxForVar: " = " & s.value
                                    elif s.kind == nxForVar: "   # in " & s.value else: "") & "\n```\n" &
           (case s.kind
            of nxParam: "parameter"
            of nxResult: "the routine's result"
            of nxForVar: "loop variable"
            of nxField: "field of " & s.owner
            else: "local " & nxKindWord(s.kind))
  if it.refs.len == 1: return nxDoc(it.refs[0], it.ufcs)
  # a forward declaration and its body are one routine, not two overloads (also when they are in two files of one
  # module: one includes the other, or a third includes both)
  proc moduleOf(path: string): string =
    let inc = nxIncluderOf(path)
    if inc.len > 0: inc else: path
  var it = it
  var uniq: seq[NxRef]
  for r in it.refs:
    var dup = -1
    for k, d in uniq:
      if d.sym.kind == r.sym.kind and nxSig(d.sym) == nxSig(r.sym) and
         (d.file.path == r.file.path or moduleOf(d.file.path) == moduleOf(r.file.path)): dup = k
    if dup < 0: uniq.add r
    elif r.sym.endLine > r.sym.line or (r.sym.doc.len > 0 and uniq[dup].sym.doc.len == 0): uniq[dup] = r
  if uniq.len == 1: return nxDoc(uniq[0], it.ufcs)
  it.refs = uniq
  # overloads: every signature, then the documentation of each (once per distinct text)
  var sigs: seq[string]
  for r in it.refs[0 ..< min(it.refs.len, 12)]: sigs.add nxSig(r.sym)
  result = "```nim\n" & sigs.join("\n") & (if it.refs.len > 12: "\n# … " & $(it.refs.len - 12) & " more" else: "") & "\n```"
  var seenDoc: HashSet[string]
  var shown = 0
  for r in it.refs:
    let d = r.sym.doc.strip
    if d.len == 0 or d in seenDoc: continue
    seenDoc.incl d
    if shown >= maxOverloads: break
    result.add "\n\n**" & nxSig(r.sym) & "**\n" & nxRstToMd(d)
    inc shown
  result.add "\n\n" & $it.refs.len & " overloads · " & it.refs[0].file.module
