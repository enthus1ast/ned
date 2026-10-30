## ── a C header as Nim: its functions, structs, unions, enums, typedefs, #define constants and globals as Nim
##    declarations that import them (importc, header) — from what ned's own C engine reads of it, with no c2nim or
##    libclang needed. What it cannot say for sure (a function-like macro, a type another header declares) is said
##    in a comment, or declared opaque, so the file compiles ──

import std/[strutils, tables, sets, os]
import cindex

const NimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
  "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot",
  "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc",
  "ptr", "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var",
  "when", "while", "xor", "yield"]

type CnCtx = object
  f: CxFile
  hdr: string                          # the name of the const that holds the header
  used: HashSet[string]                # Nim names given (normalized: Nim's rules)
  names: Table[string, string]         # a C type name (tag or typedef) → its Nim name
  structs: OrderedTable[string, int]          # a struct's or union's key (its owner name in the index) → its sym
  opaque: seq[string]                  # names used but declared by no one here: declared opaque
  known: HashSet[string]               # C type names this header declares
  anonN: int

func cnNorm(s: string): string =
  ## Nim's identity of a name: its first letter as it is, the rest without case and underscores
  if s.len == 0: return
  result.add s[0]
  for c in s[1 .. ^1]:
    if c != '_': result.add c.toLowerAscii

func cnValid(s: string): string =
  ## a C name as a valid Nim identifier: no leading, trailing or doubled underscores
  var t = s.strip(chars = {'_'})
  while "__" in t: t = t.replace("__", "_")
  if t.len == 0: t = "x"
  if t[0] in Digits: t = "n" & t
  t

proc cnName(cx: var CnCtx, c: string): string =
  ## a Nim name for a C one, not taken yet (style-insensitively): the C name when it can be
  var n = cnValid(c)
  var k = 2
  while cnNorm(n) in cx.used:
    n = cnValid(c) & $k
    inc k
  cx.used.incl cnNorm(n)
  n

# a name in backticks when it is a Nim keyword (`type`, `end` …), so it can be used as an identifier
func cnQuote(n: string): string = (if n in NimKeywords: "`" & n & "`" else: n)

func cnStripQuals(t: string): string =
  ## a C type without its qualifiers and storage words (const, volatile, restrict, extern, static, inline, register,
  ## _Noreturn and their __ forms), whole words only
  var r = " " & t & " "
  for q in ["const", "volatile", "restrict", "__restrict", "__restrict__", "extern", "static", "inline", "__inline",
            "__inline__", "register", "_Noreturn", "__extension__"]:
    r = r.replace(" " & q & " ", " ")
  r.strip

const CBasic = {"void": "void", "char": "cchar", "signed char": "int8", "unsigned char": "uint8",
  "short": "cshort", "short int": "cshort", "signed short": "cshort", "unsigned short": "cushort",
  "unsigned short int": "cushort", "int": "cint", "signed": "cint", "signed int": "cint", "unsigned": "cuint",
  "unsigned int": "cuint", "long": "clong", "long int": "clong", "signed long": "clong", "unsigned long": "culong",
  "unsigned long int": "culong", "long long": "clonglong", "long long int": "clonglong",
  "unsigned long long": "culonglong", "unsigned long long int": "culonglong", "float": "cfloat",
  "double": "cdouble", "long double": "clongdouble", "_Bool": "bool", "bool": "bool", "size_t": "csize_t",
  "ssize_t": "int", "ptrdiff_t": "int", "intptr_t": "int", "uintptr_t": "uint", "int8_t": "int8",
  "int16_t": "int16", "int32_t": "int32", "int64_t": "int64", "uint8_t": "uint8", "uint16_t": "uint16",
  "uint32_t": "uint32", "uint64_t": "uint64", "wchar_t": "Utf16Char", "off_t": "int64", "time_t": "int64",
  "FILE": "File"}.toTable

proc cnType(cx: var CnCtx, t0: string): string =
  ## a C type as Nim's: `const char *` → cstring, `struct point *` → ptr point, `int **` → ptr ptr cint …
  var t = cnStripQuals(t0).replace("\t", " ")
  while "  " in t: t = t.replace("  ", " ")
  var stars = 0
  t = t.strip
  while t.endsWith("*"):
    inc stars
    t = t[0 ..< t.high].strip
  t = cnStripQuals(t)
  var base = ""
  if t.startsWith("struct ") or t.startsWith("union ") or t.startsWith("enum "):
    let nm = t.split(' ', 1)[1].strip
    base = cx.names.getOrDefault(nm, "")
    if base.len == 0 and nm.startsWith("(anonymous"): base = "pointer"
    elif base.len == 0:
      if nm notin cx.opaque: cx.opaque.add nm
      base = cnValid(nm)
  elif t in CBasic: base = CBasic[t]
  elif t in cx.names: base = cx.names[t]
  else:
    if t.len > 0 and t notin cx.opaque: cx.opaque.add t
    base = cnValid(t)
  if base == "void":
    if stars == 0: return ""
    base = "pointer"
    dec stars
  if base == "File" and stars > 0: dec stars                 # (FILE * is Nim's File)
  if base == "cchar" and stars > 0:
    if stars >= 2:
      base = "cstringArray"
      stars -= 2
    else:
      base = "cstring"
      dec stars
  result = base
  for _ in 0 ..< stars: result = "ptr " & result

func cnSplitTop(s: string, sep = ','): seq[string] =
  ## s split at the separators outside brackets
  var depth = 0
  var cur = ""
  for c in s:
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    if c == sep and depth == 0:
      result.add cur.strip
      cur = ""
    else: cur.add c
  if cur.strip.len > 0: result.add cur.strip

proc cnParamOf(cx: var CnCtx, p: string, i: int): (string, string) =
  ## `const char *name` → ("name", "cstring") — an unnamed one gets a name of its own
  var s = p.strip
  var e = s.len
  while e > 0 and s[e - 1] in IdentChars: dec e
  var name = s[e .. ^1]
  var typ = s[0 ..< e].strip
  if name.len == 0 or typ.len == 0 or typ.strip(chars = {'*', ' '}) in ["const", "struct", "union", "enum", "unsigned",
                                                                         "signed", "long", "short"] or
     name in ["int", "char", "long", "short", "double", "float", "unsigned", "signed", "void"]:
    (name, typ) = ("a" & $(i + 1), s)
  (cnQuote(cnValid(name)), cx.cnType(typ))

proc cnFnPtr(cx: var CnCtx, ret, params: string): string =
  ## a pointer to a C function as a Nim proc type
  var ps: seq[string]
  let parts = cnSplitTop(params)
  var va = false
  for i, p in parts:
    if p == "void" and parts.len == 1: break
    if p == "...":
      va = true
      continue
    let (n, t) = cx.cnParamOf(p, i)
    ps.add n & ": " & (if t.len > 0: t else: "pointer")
  let r = cx.cnType(ret)
  "proc (" & ps.join(", ") & ")" & (if r.len > 0: ": " & r else: "") & " {.cdecl" & (if va: ", varargs" else: "") & ".}"

proc cnDeclLine(cx: CnCtx, s: CxSym): string =
  ## the whole declaration from the header (it can go over a few lines), up to its `;`
  var l = s.line
  while l < cx.f.lines.len and l < s.line + 12:
    result.add cx.f.lines[l].strip & " "
    if ';' in cx.f.lines[l]: break
    inc l
  result = result.strip

func cnLiteral(v0: string, consts: HashSet[string]): string =
  ## a #define's value as a Nim constant expression ("" when it is not one): 3, 0x1fU, 1.5f, "text", 'c',
  ## (1 << 4) | FLAG …
  var v = v0.strip
  if v.len == 0: return
  if v[0] == '"' and v.endsWith("\"") and v.len >= 2: return v
  if v.len == 3 and v[0] == '\'' and v[2] == '\'': return v
  var o = ""
  var i = 0
  while i < v.len:
    let c = v[i]
    if c in Digits or (c == '.' and i + 1 < v.len and v[i + 1] in Digits):
      var j = i
      while j < v.len and (v[j] in HexDigits or v[j] in {'x', 'X', '.'} or
            (v[j] in {'e', 'E', 'p', 'P'} and j + 1 < v.len and v[j + 1] in {'+', '-'} + Digits) or
            (v[j] in {'+', '-'} and j > 0 and v[j - 1] in {'e', 'E', 'p', 'P'} and not v[i .. j].startsWith("0x"))):
        inc j
      var num = v[i ..< j]
      var k = j
      while k < v.len and v[k] in {'u', 'U', 'l', 'L', 'f', 'F'}: inc k
      let suffix = v[j ..< k].toLowerAscii
      if num.toLowerAscii.startsWith("0x"):
        if num.len <= 2: return ""
      elif num.len > 1 and num[0] == '0' and num.allCharsInSet(Digits): num = "0o" & num[1 .. ^1]
      elif ('e' in suffix or 'f' in suffix) and '.' notin num and 'e' notin num.toLowerAscii and
           not num.toLowerAscii.startsWith("0x"):
        num.add ".0"
      if num.toLowerAscii.startsWith("0x") and 'f' in suffix: discard
      o.add num
      if 'u' in suffix and not num.contains('.'): o.add "'u"
      i = k
    elif c in IdentStartChars:
      var j = i
      while j < v.len and v[j] in IdentChars: inc j
      let w = v[i ..< j]
      if w notin consts: return ""
      o.add cnValid(w)
      i = j
    elif v.continuesWith("<<", i): (o.add " shl "; i += 2)
    elif v.continuesWith(">>", i): (o.add " shr "; i += 2)
    elif c == '|': (o.add " or "; inc i)
    elif c == '&': (o.add " and "; inc i)
    elif c == '^': (o.add " xor "; inc i)
    elif c == '~': (o.add "not "; inc i)
    elif c == '%': (o.add " mod "; inc i)
    elif c == '/': (o.add " div "; inc i)
    elif c in {'(', ')', '+', '-', '*', ' '}:
      o.add c
      inc i
    else: return ""
  while "  " in o: o = o.replace("  ", " ")
  o.strip

func cnEnumValue(v: string, known: Table[string, int64]): (bool, int64) =
  ## an enum constant's value when ned can work it out: 4, -1, 0x10, 1 << 3, A | B (of constants before it)
  let t = v.strip
  if t.len == 0: return (false, 0)
  try:
    for op in ["|", "<<", "+"]:
      let parts = t.split(op)
      if parts.len == 2:
        let (ok1, a) = cnEnumValue(parts[0].strip(chars = {'(', ')', ' '}), known)
        let (ok2, b) = cnEnumValue(parts[1].strip(chars = {'(', ')', ' '}), known)
        if not (ok1 and ok2): return (false, 0)
        case op
        of "|": return (true, a or b)
        of "<<": return (true, a shl b)
        else: return (true, a + b)
    var s = t.strip(chars = {'(', ')', ' '})
    while s.len > 0 and s[^1] in {'u', 'U', 'l', 'L'}: s.setLen(s.len - 1)
    if s in known: return (true, known[s])
    if s.toLowerAscii.startsWith("0x"): return (true, int64(parseHexInt(s)))
    if s.toLowerAscii.startsWith("-0x"): return (true, -int64(parseHexInt(s[1 .. ^1])))
    return (true, int64(parseBiggestInt(s)))
  except ValueError: return (false, 0)

proc cxNimBindings*(f: CxFile, headerPath, headerSpec: string): (string, int) =
  ## the header's declarations as a Nim module: (its text, how many declarations). headerSpec: how the generated
  ## file names the header — `<zlib.h>` for a system one, else a path next to the Nim file
  var cx = CnCtx(f: f)
  let stem = cnValid(splitFile(headerPath).name.replace('-', '_').replace('.', '_'))
  cx.hdr = cx.cnName(stem & "H")
  # the names first: every struct, union, enum and typedef this header declares (a type may be used before it is
  # declared — Nim's one type section takes them in any order)
  var typedefOf: Table[string, string]           # a struct's key → the typedef that names it (the first)
  for i, s in f.syms:
    case s.kind
    of cxStruct, cxUnion, cxEnum:
      if s.name.startsWith("(anonymous"): continue
      if s.kind in {cxStruct, cxUnion} and (s.name notin cx.structs or s.isDef): cx.structs[s.name] = i
      cx.known.incl s.name
    of cxTypedef:
      cx.known.incl s.name
      for kw in ["struct ", "union ", "enum "]:
        if s.typ.startsWith(kw):
          let tag = s.typ[kw.len .. ^1].strip
          if tag notin typedefOf: typedefOf[tag] = s.name
    else: discard
  var out0: seq[string]
  var types, consts, procs, vars: seq[string]
  var count = 0
  var constNames: HashSet[string]
  # structs and unions: an object each (a typedef of the same name is the same type)
  for key, i in cx.structs:
    cx.names[key] = cx.cnName(key)            # (a typedef of another name: an alias of it, below)
  # each typedef: another name for a type here, a basic type, a pointer to a function
  var aliases: seq[(CxSym, string)]
  for s in f.syms:
    if s.kind != cxTypedef or s.name in cx.names: continue
    var tag = ""
    for kw in ["struct ", "union ", "enum "]:
      if s.typ.startsWith(kw): tag = s.typ[kw.len .. ^1].strip
    if tag.len > 0 and tag in cx.names:
      cx.names[s.name] = cx.cnName(s.name)
      aliases.add (s, cx.names[tag])
    elif tag.len > 0 and s.typ.startsWith("enum "): discard        # (below, with the enums)
    else:
      cx.names[s.name] = cx.cnName(s.name)
      aliases.add (s, "")
  # enums: a Nim enum when its values rise and ned can work them out, else its constants
  var enumKeys: seq[(string, CxSym)]
  for s in f.syms:
    if s.kind == cxEnum and s.isDef: enumKeys.add (s.name, s)
  for (key, s) in enumKeys:
    var vals: seq[(string, string, int64, bool)]  # (C name, as written, value, known)
    var known: Table[string, int64]
    var next = 0'i64
    var rising = true
    var last = low(int64)
    for c in f.syms:
      if c.kind != cxEnumConst or c.owner != key: continue
      var v = next
      var ok = true
      if c.init.len > 0: (ok, v) = cnEnumValue(c.init, known)
      if not ok: rising = false
      known[c.name] = v
      vals.add (c.name, c.init, v, ok)
      if v <= last: rising = false
      last = v
      next = v + 1
    let td = typedefOf.getOrDefault(key, "")
    let cname = if s.text.startsWith("enum {") and td.len > 0: td elif td.len > 0: td else: key
    let nimName = cx.cnName(cname)
    cx.names[key] = nimName
    if td.len > 0: cx.names[td] = nimName
    inc count
    if rising and vals.len > 0:
      var body = "  " & nimName & "* {.size: sizeof(cint).} = enum" & (if s.doc.len > 0: "  ## " & s.doc.splitLines[0] else: "")
      for (n, _, v, _) in vals:
        let nn = cx.cnName(n)
        body.add "\n    " & nn & " = " & $v
      types.add body
    else:
      # (values that fall or repeat, or that ned cannot work out: constants of the type)
      types.add "  " & nimName & "* = cint"
      for (n, written, v, ok) in vals:
        let nn = cx.cnName(n)
        constNames.incl n
        consts.add "  " & nn & "* = " & nimName & "(" & (if ok: $v else: cnLiteral(written, constNames)) & ")"
  # (a typedef of an enum by another name: an alias of it)
  for s in f.syms:
    if s.kind == cxTypedef and s.typ.startsWith("enum ") and s.name notin cx.names:
      let tag = s.typ["enum ".len .. ^1].strip
      if tag in cx.names:
        cx.names[s.name] = cx.cnName(s.name)
        aliases.add (s, cx.names[tag])
  # the objects
  for key, i in cx.structs:
    let s = f.syms[i]
    let nimName = cx.names[key]
    let anon = s.text.startsWith("struct {") or s.text.startsWith("union {")
    let td = typedefOf.getOrDefault(key, "")
    let cRef = if anon: (if td.len > 0: td else: key) elif s.kind == cxUnion: "union " & key else: "struct " & key
    let union = s.kind == cxUnion
    inc count
    if not s.isDef:
      types.add "  " & nimName & "* {.importc: \"" & cRef & "\", header: " & cx.hdr & ", incompleteStruct.} = object"
      continue
    var body = "  " & nimName & "* {.importc: \"" & cRef & "\", header: " & cx.hdr & (if union: ", union" else: "") &
               ", bycopy.} = object" & (if s.doc.len > 0: "  ## " & s.doc.splitLines[0] else: "")
    var nf = 0
    for fld in f.syms:
      if fld.kind != cxField or fld.owner != key: continue
      inc nf
      var t = fld.typ
      var dims: seq[string]
      if fld.dims.len > 0:
        for d in fld.dims.split(']'):
          let x = d.strip(chars = {'[', ' '})
          if x.len > 0: dims.add x
        for _ in dims:
          if t.endsWith("*"): t = t[0 ..< t.high].strip
      var nt = ""
      if t.startsWith("union (anonymous") or t.startsWith("struct (anonymous"):
        # a struct or union inside without a name: one of its own on the Nim side
        let inner = t.split(' ', 1)[1].strip
        if inner notin cx.names:
          inc cx.anonN
          let iname = cx.cnName(nimName & "_" & fld.name)
          cx.names[inner] = iname
          var ib = "  " & iname & "* {." & (if t.startsWith("union"): "union, " else: "") & "bycopy.} = object"
          for g in f.syms:
            if g.kind == cxField and g.owner == inner:
              ib.add "\n    " & cnQuote(cnValid(g.name)) & "*: " & cx.cnType(g.typ)
          types.add ib
        nt = cx.names[inner]
      else: nt = cx.cnType(t)
      if nt.len == 0: nt = "pointer"
      for k in countdown(dims.high, 0):
        let dv = cnLiteral(dims[k], constNames)
        nt = "array[" & (if dv.len > 0: dv else: dims[k]) & ", " & nt & "]"
      let fname = cnQuote(cnValid(fld.name))
      var fp: seq[string]
      if fname != fld.name: fp.add "importc: \"" & fld.name & "\""
      if fld.bits.len > 0: fp.add "bitsize: " & fld.bits
      body.add "\n    " & fname & "*" & (if fp.len > 0: " {." & fp.join(", ") & ".}" else: "") & ": " & nt
    if nf == 0: body.add "\n    discard"
    types.add body
  # the typedefs
  for (s, target) in aliases:
    let nimName = cx.names[s.name]
    inc count
    if target.len > 0:
      types.add "  " & nimName & "* = " & target
      continue
    if s.typ.endsWith("(*)") or "(*" in s.typ:
      # a pointer to a function: its parameters from the header's own line
      let line = cx.cnDeclLine(s)
      let k = line.find("(*")
      let ret = line[0 ..< max(0, k)].replace("typedef", "").strip
      let pa = line.find('(', line.find(')', k) + 1)
      let pe = line.rfind(')')
      if k > 0 and pa > 0 and pe > pa:
        types.add "  " & nimName & "* = " & cx.cnFnPtr(ret, line[pa + 1 ..< pe])
      else:
        types.add "  " & nimName & "* = pointer  # a pointer to a function: " & line
      continue
    let nt = cx.cnType(s.typ)
    types.add "  " & nimName & "* {.importc: \"" & s.name & "\", header: " & cx.hdr & ".} = " &
              (if nt.len > 0: nt else: "object")
  # #define constants
  for s in f.syms:
    if s.kind != cxMacro: continue
    let t = s.text
    let rest = t["#define ".len .. ^1].strip
    let sp = rest.find({' ', '\t'})
    if s.params.len > 0 or (rest.len > s.name.len and rest[s.name.len] == '('):
      consts.add "  # " & t & "  — a macro with arguments: write it as a template or a proc"
      continue
    if sp < 0: continue                          # (an include guard, a flag with no value)
    let v = cnLiteral(rest[sp .. ^1], constNames)
    if v.len == 0: continue
    constNames.incl s.name
    inc count
    consts.add "  " & cx.cnName(s.name) & "* = " & v & (if s.doc.len > 0: "  ## " & s.doc.splitLines[0] else: "")
  # functions and globals
  var done: HashSet[string]
  for s in f.syms:
    case s.kind
    of cxFunc:
      if s.weak or s.name in done: continue
      done.incl s.name
      var ps: seq[string]
      for i, p in s.params:
        if p.typ == "void" and s.params.len == 1: break
        var t = cx.cnType(p.typ)
        if t.len == 0: t = "pointer"
        let n = if p.name.len > 0: cnQuote(cnValid(p.name)) else: "a" & $(i + 1)
        ps.add n & ": " & t
      var ret = cx.cnType(s.typ)
      let nimName = cx.cnName(s.name)
      inc count
      var prags = "importc: \"" & s.name & "\", header: " & cx.hdr
      if s.varargs: prags.add ", varargs"
      var d = "proc " & cnQuote(nimName) & "*(" & ps.join("; ") & ")" & (if ret.len > 0: ": " & ret else: "") &
              " {." & prags & ".}"
      if s.doc.len > 0:
        for dl in s.doc.splitLines:
          if dl.strip.len > 0: d.add "\n  ## " & dl.strip
      procs.add d
    of cxVar:
      if s.name in done: continue
      done.incl s.name
      let t = cx.cnType(s.typ)
      inc count
      vars.add "var " & cnQuote(cx.cnName(s.name)) & "* {.importc: \"" & s.name & "\", header: " & cx.hdr & ".}: " &
               (if t.len > 0: t else: "pointer")
    else: discard
  # the types other headers declare: opaque, so the file compiles (replace them with the real ones)
  var opaqueDecl: seq[string]
  for o in cx.opaque:
    if o in cx.names or o in CBasic or o.len == 0: continue
    let n = cx.cnName(o)
    cx.names[o] = n
    opaqueDecl.add "  " & n & "* {.importc: \"" & o & "\", header: " & cx.hdr & ", incompleteStruct.} = object" &
                   "  # (another header's)"
  out0.add "## " & extractFilename(headerPath) & " for Nim — made by ned from the header (Nim: wrap a C header). Check it:"
  out0.add "## pointers that are arrays, out parameters (var), who frees what are not in a header."
  out0.add ""
  if headerSpec.startsWith("<"):
    out0.add "const " & cx.hdr & " = \"" & headerSpec & "\""
  else:
    out0.add "import std/os"
    out0.add ""
    out0.add "const " & cx.hdr & " = currentSourcePath().parentDir() / \"" & headerSpec & "\""
  out0.add "# {.passL: \"-l" & stem & "\".}   # (the library these functions are in, when they are not compiled in)"
  out0.add ""
  if types.len > 0 or opaqueDecl.len > 0:
    out0.add "type"
    for t in opaqueDecl: out0.add t
    for t in types: out0.add t
    out0.add ""
  var anyConst = false
  for c in consts:
    if not c.strip.startsWith("#"): anyConst = true
  if consts.len > 0:
    if anyConst: out0.add "const"
    for c in consts: out0.add (if anyConst: c else: c.strip)
    out0.add ""
  for v in vars: out0.add v
  if vars.len > 0: out0.add ""
  for p in procs: out0.add p
  (out0.join("\n") & "\n", count)
