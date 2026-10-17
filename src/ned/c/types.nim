# ── C type ↔ Nim type ──

proc cNimFor(ctype: string): seq[string] =
  ## the Nim types that match a C type that is not a pointer (empty: not one ned knows)
  let t = ctype.replace("signed ", "").replace(" int", "").strip
  case t
  of "int", "signed": @["cint", "int32"]
  of "unsigned": @["cuint", "uint32"]
  of "short": @["cshort", "int16"]
  of "unsigned short": @["cushort", "uint16"]
  of "long": @["clong"]
  of "unsigned long": @["culong"]
  of "long long": @["clonglong", "int64"]
  of "unsigned long long": @["culonglong", "uint64"]
  of "char": @["cchar", "char"]
  of "unsigned char": @["cuchar", "uint8", "byte", "char"]
  of "float": @["cfloat", "float32"]
  of "double": @["cdouble", "float64", "float"]
  of "long double": @["clongdouble"]
  of "size_t": @["csize_t", "uint"]
  of "ssize_t", "ptrdiff_t", "intptr_t", "off_t": @["int", "clong", "int64"]
  of "uintptr_t": @["uint", "csize_t"]
  of "int8_t": @["int8"]
  of "uint8_t": @["uint8", "byte"]
  of "int16_t": @["int16", "cshort"]
  of "uint16_t": @["uint16", "cushort"]
  of "int32_t": @["int32", "cint"]
  of "uint32_t": @["uint32", "cuint"]
  of "int64_t": @["int64", "clonglong"]
  of "uint64_t": @["uint64", "culonglong"]
  of "bool", "_Bool": @["bool"]
  else: @[]

const NimPrimitives = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
  "float", "float32", "float64", "bool", "char", "byte", "cint", "cuint", "clong", "culong", "cshort", "cushort",
  "clonglong", "culonglong", "cchar", "cschar", "cuchar", "cfloat", "cdouble", "clongdouble", "csize_t", "Natural",
  "Positive"]

proc nimIsPointer(t: string): bool =
  let x = t.strip
  x.startsWith("ptr ") or x.startsWith("var ") or x == "pointer" or x == "cstring" or x == "cstringArray" or
    x.startsWith("ref ") or x.startsWith("proc") or x.startsWith("ptr[") or x.startsWith("UncheckedArray")

proc ffiProblem(ctype, nimType: string, isReturn: bool): (string, string) =
  ## (what is wrong, the Nim type to use) — ("", "") when it fits or cannot be told
  let n = nimType.strip
  let c = ctype.strip
  if c.len == 0 or n.len == 0 or c == "fnptr": return
  let stars = c.count('*')
  let base = c.replace("*", "").strip
  if stars == 0:
    if c == "void":
      return (if isReturn: ("the C function returns nothing", "") else: ("", ""))
    let want = cNimFor(base)
    if nimIsPointer(n):
      if want.len > 0: return ("C passes " & base & " by value, not a pointer", want[0])
      return
    if want.len == 0 or n in want: return
    if n in NimPrimitives or n == "string":
      let why = case n
        of "int", "uint":
          if base in ["size_t", "uintptr_t"]: "C's " & base & " is unsigned"
          else: "Nim's " & n & " is pointer-sized (64 bits on most machines)"
        of "float": "Nim's float is 64 bits"
        of "bool": "C's " & base & " is not a bool"
        else: ""
      return ("C has " & base & (if why.len > 0: "; " & why else: ""), want[0])
    return
  # pointers
  let charLike = base in ["char", "unsigned char", "signed char"]
  if n == "string" or n.startsWith("seq[") or n.startsWith("openArray"):
    if n.startsWith("openArray"): return
    return ("C takes " & c & ": a Nim " & (if n == "string": "string" else: "seq") & " is not one",
            if charLike and stars == 1: "cstring" elif charLike and stars == 2: "cstringArray" else: "pointer")
  if not nimIsPointer(n) and n in NimPrimitives:
    let w = cNimFor(base)
    let fix = if charLike and stars == 1: "cstring"
              elif base == "void": "pointer"
              elif w.len > 0: "ptr " & w[0]
              else: "ptr " & n
    return ("C takes a pointer (" & c & "), not a value", fix)
  if charLike and stars == 2 and n == "cstring": return ("C takes " & c & " (a pointer to strings)", "cstringArray")
  ("", "")

proc ffiCheckDecls(path: string, lines: seq[string], decls: seq[NimFfi]): seq[Diag] =
  ## the wrappers that do not fit their C declaration
  let dirs = cIncludeDirs(path, lines)
  let here = parentDir(path)
  var checked = 0
  for d in decls:
    if d.kind notin ["proc", "func", "var", "let"]: continue
    inc checked
    if checked > 400: break
    # its header's declaration — or, with no header, its definition in emitted C
    let (cp, _) = if d.header.len > 0: cDeclFor(d.header, d.cname, dirs, here) else: ffiCDecl(d, path, lines, false)
    if cp.kind.len == 0: continue
    template warn(at0, e0: Pos, why, use: string) =
      result.add Diag(line: at0.line, col: at0.col, eline: e0.line, ecol: e0.col, sev: 2,
                      msg: why & (if use.len > 0: " — use " & use else: "") & "  (" & extractFilename(cp.path) & ":" &
                           $(cp.line + 1) & ": " & cp.text & ")", src: "C header")
    let nameAt = Pos(line: d.line, col: d.nameCol)
    let nameEnd = Pos(line: d.line, col: d.nameCol + d.name.len)
    if d.kind in ["var", "let"]:
      if cp.kind == "variable" and d.ret.len > 0:
        let (m, fix) = ffiProblem(cp.ret, d.ret, false)
        if m.len > 0: warn(d.retAt, d.retEnd, m, fix)
      continue
    if cp.kind != "function": continue
    var nimCount = 0
    var vaParam = -1
    for i, p in d.params:
      nimCount += (if p[1].strip.startsWith("openArray") or p[1].strip.startsWith("varargs"): 2 else: 1)
      if p[1].strip.startsWith("varargs") and cp.varargs: vaParam = i
    if vaParam >= 0:
      # varargs[T] is a Nim array (a pointer and a length), not C's `...`: the {.varargs.} pragma is
      let p = d.params[vaParam]
      warn(p[2], p[3], p[1].strip & " is a Nim array, not C's … — " & cPrettyProto(cp, d.cname) &
           " wants its parameters, then {.varargs.} (Alt+Enter rewrites the wrapper from C)", "")
      continue
    if cp.varargs and not d.varargs:
      warn(nameAt, nameEnd, "C's " & d.cname & " takes more arguments after these (…): add {.varargs.}", "")
    if nimCount != cp.params.len:
      warn(nameAt, nameEnd, "C's " & d.cname & " takes " & $cp.params.len & " parameter" &
           (if cp.params.len == 1: "" else: "s") & ", this " & $nimCount, "")
    else:
      for i, p in d.params:
        let (m, fix) = ffiProblem(cParamType(cp.params[i]), p[1], false)
        if m.len > 0: warn(p[2], p[3], "parameter " & p[0] & ": " & m, fix)
    if d.ret.len > 0:
      let (m, fix) = ffiProblem(cp.ret, d.ret, true)
      if m.len > 0: warn(d.retAt, d.retEnd, "result: " & m, fix)

proc ffiCheck(b: Buffer) =
  ## check this Nim file's importc wrappers against their C headers (on open and save)
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or not cfgCheckWrappers: return
  if b.lines.len > 60000 or b.largeOn: return
  var any = false
  for l in b.lines:
    if "importc" in l:
      any = true
      break
  if not any:
    if b.path in diagsFfi: diagsFfi.del b.path
    return
  try:
    let ds = ffiCheckDecls(b.path, b.lines, nimFfiDecls(b.lines))
    if ds.len > 0: diagsFfi[b.path] = ds
    elif b.path in diagsFfi: diagsFfi.del b.path
  except CatchableError as e:
    internalError("C header check", e)
  needRender = true
