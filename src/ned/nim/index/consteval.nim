# ── compile-time values: a constant expression worked out the way the compiler would, as far as the index
#    knows the names in it — numbers (with shl, and, xor …), strings, chars, bools, comparisons, enum values,
#    high/low/sizeof/ord/chr/len/min/max, defined()/declared() for this platform ──

type
  NxCtKind* = enum ctNone, ctInt, ctFloat, ctStr, ctBool, ctChar, ctEnum
  NxCt* = object
    kind*: NxCtKind
    i*: BiggestInt
    f*: float
    s*: string            # a string; an enum value's name
    big*: string          # a value too big for an int (high(uint64)): as written
    typ*: string          # an integer's type, when it is not plain int (high(int8), 3'u8, uint16(x))
    err*: string          # ctNone: what the compiler would say instead (an overflow is a compile error)

const
  NxIntMax = 9.2e18                    # a float beyond this does not convert to an int (not worked out)
  NxUnsigned = ["uint8", "byte", "cuchar", "uint16", "cushort", "uint32", "cuint", "uint64", "uint", "csize_t", "culong",
                "culonglong", "BiggestUInt"]

proc nxCtRender*(v: NxCt): string =
  case v.kind
  of ctNone: ""
  of ctInt: (if v.big.len > 0: v.big else: $v.i)
  of ctFloat: $v.f
  of ctStr:
    var r = "\""
    for ch in v.s:
      case ch
      of '"': r.add "\\\""
      of '\\': r.add "\\\\"
      of '\n': r.add "\\n"
      of '\t': r.add "\\t"
      of '\0' .. '\x08', '\x0B' .. '\x1F', '\x7F': r.add "\\x" & toHex(ord(ch), 2)
      else: r.add ch
    r & "\""

  of ctBool: (if v.i != 0: "true" else: "false")
  of ctChar:
    if v.i >= 32 and v.i < 127 and v.i != ord('\''): "'" & char(v.i) & "'"
    else: "'\\x" & toHex(v.i, 2) & "'"
  of ctEnum: v.s

proc ctInt(i: BiggestInt): NxCt = NxCt(kind: ctInt, i: i)
proc ctBool(b: bool): NxCt = NxCt(kind: ctBool, i: (if b: 1 else: 0))

proc nxIntTypeRange(t: string): (bool, BiggestInt, BiggestInt, int, string) =
  ## an integer type's low, high and size in bytes ("", or high as written when it does not fit an int64)
  case t
  of "int8": (true, -128'i64, 127'i64, 1, "")
  of "int16": (true, -32768'i64, 32767'i64, 2, "")
  of "int32", "cint": (true, BiggestInt(low(int32)), BiggestInt(high(int32)), 4, "")
  of "int64", "int", "clong", "clonglong", "BiggestInt": (true, low(int64), high(int64), 8, "")
  of "uint8", "byte", "cuchar": (true, 0'i64, 255'i64, 1, "")
  of "uint16", "cushort": (true, 0'i64, 65535'i64, 2, "")
  of "uint32", "cuint": (true, 0'i64, 4294967295'i64, 4, "")
  of "uint64", "uint", "csize_t", "culong", "culonglong", "BiggestUInt": (true, 0'i64, high(int64), 8, "18446744073709551615")
  of "Natural": (true, 0'i64, high(int64), 8, "")
  of "Positive": (true, 1'i64, high(int64), 8, "")
  of "char", "cchar": (true, 0'i64, 255'i64, 1, "")
  of "bool": (true, 0'i64, 1'i64, 1, "")
  else: (false, 0'i64, 0'i64, 0, "")

proc nxWhenValue(v: string): string =
  ## `when c: a elif d: b else: e` written as a value: the branch compiled here ("" when that cannot be told)
  var rest = v.strip
  while rest.startsWith("when ") or rest.startsWith("elif "):
    let colon = nxFindTop(rest, ':', 5)
    if colon < 0: return ""
    let w = nxWhen(rest[5 ..< colon])
    var e = rest.len
    for stop in [" elif ", " else:"]:
      let q = rest.find(stop, colon)
      if q > 0 and q < e: e = q
    if w == 1: return rest[colon + 1 ..< e].strip
    if w != 0 or e >= rest.len: return ""
    rest = rest[e .. ^1].strip
    if rest.startsWith("else:"): return rest[5 .. ^1].strip
  ""

proc nxEnumOrdinals(r: NxRef): seq[(string, BiggestInt)] =
  ## an enum type's values and their ordinals (an explicit `= n` sets it — `= when defined(macosx): 30 else: 10`
  ## too —; the next count on from it)
  var n: BiggestInt = 0
  for s in r.file.syms:
    if s.kind != nxEnumVal or s.owner != r.sym.name: continue
    var v = s.value.strip
    if v.startsWith("when "): v = nxWhenValue(v)
    if v.startsWith("(") and ',' in v: v = v[1 ..< v.find(',')].strip
    if v.len > 0 and v[0] in Digits + {'-'}:
      try: n = parseBiggestInt(v.replace("_", ""))
      except ValueError: discard
    result.add (s.name, n)
    inc n

proc nxCtEval*(f: NxFile, e: string, depth = 0): NxCt

proc nxCtName(f: NxFile, name: string, depth: int): NxCt =
  ## a name's value: a constant's, an enum value's, true/false
  case name
  of "true": return ctBool(true)
  of "false": return ctBool(false)
  of "nil": return
  # the compiler's own (system declares them with a stand-in value): what ned knows of this platform, or nothing
  of "hostOS": return NxCt(kind: ctStr, s: hostOS)
  of "hostCPU": return NxCt(kind: ctStr, s: hostCPU)
  of "isMainModule", "appType", "cpuEndian", "CompileDate", "CompileTime", "nimvm": return
  else: discard
  if depth > 8: return
  for r in nxLookup(nxScope(f), name):
    case r.sym.kind
    of nxConst:
      if "magic" in r.sym.pragmas: return                 # (its value is the compiler's, not the one written)
      var v = r.sym.value
      if v.len > 0:
        # (a value that goes on over the lines below: `declared(posix_spawn) and⏎ not defined(useFork)`)
        var c = nxCodeOf(v)
        if c.endsWith(" and") or c.endsWith(" or") or c.endsWith(" not") or c.endsWith("(") or c.endsWith(",") or
           c.count('(') > c.count(')'):
          let ls = nxFileLines(r.file.path)
          var l = r.sym.line
          while l + 1 < ls.len and l - r.sym.line < 6 and
                (c.endsWith(" and") or c.endsWith(" or") or c.endsWith(" not") or c.endsWith("(") or c.endsWith(",") or
                 c.count('(') > c.count(')')):
            inc l
            c.add " " & nxCodeOf(ls[l])
          v = c
        return nxCtEval(r.file, v, depth + 1)
    of nxEnumVal:
      for t in nxLookup(nxScope(r.file), r.sym.owner):
        if t.sym.kind == nxType:
          for (n, o) in nxEnumOrdinals(t):
            if n == r.sym.name: return NxCt(kind: ctEnum, i: o, s: n)
      return
    else: discard

proc nxCtEval*(f: NxFile, e: string, depth = 0): NxCt =
  ## e's value at compile time, ctNone when the index cannot tell
  if depth > 8 or e.len == 0 or e.len > 2000: return
  block tuples:
    # (NimMajor, NimMinor) >= (1, 4): two tuples of integers compared, element by element
    let x = e.strip
    if x.len < 7 or x[0] != '(' or x[^1] != ')': break tuples
    let ce = nxMatchClose(x, 0)
    if ce < 0 or ce == x.high: break tuples
    let o = nxMatchClose(x, x.rfind('('))
    if o != x.high: break tuples
    let ro = x.rfind('(')
    let op = x[ce + 1 ..< ro].strip
    if op notin ["<", "<=", ">", ">=", "==", "!="]: break tuples
    let la = nxSplitTop(x[1 ..< ce], {','})
    let ra = nxSplitTop(x[ro + 1 ..< x.high], {','})
    if la.len < 2 or la.len != ra.len: break tuples
    var c = 0
    for k in 0 ..< la.len:
      let a = nxCtEval(f, la[k], depth + 1)
      let b = nxCtEval(f, ra[k], depth + 1)
      if a.kind != ctInt or b.kind != ctInt or a.big.len > 0 or b.big.len > 0: return
      if c == 0: c = cmp(a.i, b.i)
    return ctBool(case op
                  of "<": c < 0
                  of "<=": c <= 0
                  of ">": c > 0
                  of ">=": c >= 0
                  of "==": c == 0
                  else: c != 0)
  # tokens: numbers, strings, chars, names, operators, ( ) [ ] , .
  var toks: seq[string]
  var i = 0
  let s = e
  while i < s.len:
    let c = s[i]
    if c in {' ', '\t', '\n'}: inc i
    elif c == '#': break
    elif c in Digits:
      var j = i
      if c == '0' and j + 1 < s.len and s[j + 1] in {'x', 'X', 'b', 'B', 'o', 'O'}:
        j += 2
        while j < s.len and s[j] in HexDigits + {'_'}: inc j
      else:
        while j < s.len and s[j] in Digits + {'_'}: inc j
        if j + 1 < s.len and s[j] == '.' and s[j + 1] in Digits:
          inc j
          while j < s.len and s[j] in Digits + {'_'}: inc j
        if j < s.len and s[j] in {'e', 'E'}:
          inc j
          if j < s.len and s[j] in {'+', '-'}: inc j
          while j < s.len and s[j] in Digits: inc j
      if j < s.len and s[j] == '\'':
        inc j
        while j < s.len and s[j] in IdentChars: inc j
      elif j < s.len and s[j] in {'i', 'u', 'f'} and j + 1 < s.len and s[j + 1] in Digits:   # 10i64
        while j < s.len and s[j] in IdentChars: inc j
      toks.add s[i ..< j]
      i = j
    elif c == '"' or (c in {'r', 'R'} and i + 1 < s.len and s[i + 1] == '"' and (i == 0 or not nxIsIdent(s[i - 1]))):
      let raw = c != '"'
      var j = i + (if raw: 2 else: 1)
      if s.continuesWith("\"\"\"", i): return      # (a long string: not worked out)
      var lit = ""
      while j < s.len and s[j] != '"':
        if s[j] == '\\' and not raw and j + 1 < s.len:
          inc j
          case s[j]
          of 'n': lit.add '\n'
          of 't': lit.add '\t'
          of 'r': lit.add '\r'
          of '0': lit.add '\0'
          of '\\': lit.add '\\'
          of '"': lit.add '"'
          of '\'': lit.add '\''
          of 'x':
            if j + 2 < s.len:
              try: lit.add char(parseHexInt(s[j + 1 .. j + 2]))
              except ValueError: return
              j += 2
          else: return
        else: lit.add s[j]
        inc j
      if j >= s.len: return
      toks.add "\"" & lit
      i = j + 1
    elif c == '\'':
      var ch = -1
      if i + 2 < s.len and s[i + 1] != '\\' and s[i + 2] == '\'':
        ch = ord(s[i + 1])
        i += 3
      elif i + 3 < s.len and s[i + 1] == '\\' and s[i + 3] == '\'':
        ch = case s[i + 2]
             of 'n': 10
             of 't': 9
             of 'r': 13
             of '0': 0
             of '\\': ord('\\')
             of '\'': ord('\'')
             else: -1
        i += 4
      elif i + 5 < s.len and s.continuesWith("\\x", i + 1) and s[i + 5] == '\'':
        try: ch = parseHexInt(s[i + 3 .. i + 4])
        except ValueError: return
        i += 6
      if ch < 0: return
      toks.add "'" & $ch
    elif nxIsIdent(c):
      var j = i
      while j < s.len and nxIsIdent(s[j]): inc j
      toks.add s[i ..< j]
      i = j
    elif c in {'(', ')', '[', ']', ','}:
      toks.add $c
      inc i
    elif c == '.' and not (i + 1 < s.len and s[i + 1] == '.'):
      toks.add "."
      inc i
    elif c in NxOpChars or c == '@':
      var j = i
      while j < s.len and (s[j] in NxOpChars or s[j] == '@'): inc j
      toks.add s[i ..< j]
      i = j
    elif c == '`': return
    else: return
  var p = 0
  var failed = false
  var errMsg = ""
  proc bad(): NxCt =
    failed = true
    NxCt()
  proc overflow(typ: string): NxCt =
    let (_, lo, hi, _, _) = nxIntTypeRange(if typ.len > 0: typ else: "int")
    errMsg = "over- or underflow: " & (if typ.len > 0: typ else: "int") & " holds " & $lo & " .. " & $hi
    bad()
  proc fit(v: NxCt): NxCt =
    ## an integer kept in its type: an unsigned one wraps around, a signed one that overflows is an error
    result = v
    if v.kind != ctInt or v.typ.len == 0 or v.big.len > 0: return
    let (ok, lo, hi, size, _) = nxIntTypeRange(v.typ)
    if not ok: return
    if v.typ in NxUnsigned:
      if size < 8: result.i = v.i and ((1'i64 shl (8 * size)) - 1)
      elif v.i < 0: return bad()                      # (past int64: not worked out)
    elif v.i < lo or v.i > hi: return overflow(v.typ)
  proc joinTyp(a, b: NxCt): (bool, string) =
    ## the type of `a op b`: the wider one (a range type counts as int); signed with unsigned is not worked out
    let ta = if a.typ in ["Natural", "Positive"]: "int" else: a.typ
    let tb = if b.typ in ["Natural", "Positive"]: "int" else: b.typ
    if ta.len == 0 or tb.len == 0 or ta == tb: return (true, (if ta.len > 0: ta else: tb))
    if (ta in NxUnsigned) != (tb in NxUnsigned): return (false, "")
    let sa = nxIntTypeRange(ta)[3]
    let sb = nxIntTypeRange(tb)[3]
    (true, (if sa >= sb: ta else: tb))

  proc parseNum(t: string): NxCt =
    var n = t.replace("_", "")
    var suffix = ""
    let q = n.find('\'')
    if q >= 0:
      suffix = n[q + 1 .. ^1]
      n = n[0 ..< q]
    elif n.len > 2 and not n.startsWith("0x") and not n.startsWith("0X"):
      for k in 1 ..< n.len:
        if n[k] in {'i', 'u', 'f'} and n[k - 1] in Digits:
          suffix = n[k .. ^1]
          n = n[0 ..< k]
          break
    let typ = case suffix
              of "i8": "int8"
              of "i16": "int16"
              of "i32": "int32"
              of "i64": "int64"
              of "u8": "uint8"
              of "u16": "uint16"
              of "u32": "uint32"
              of "u64": "uint64"
              of "u": "uint"
              else: ""
    let isFloat = suffix.startsWith("f") or suffix.startsWith("d") or
                  (not n.startsWith("0x") and not n.startsWith("0X") and ('.' in n or 'e' in n or 'E' in n))
    try:
      if isFloat: return NxCt(kind: ctFloat, f: parseFloat(n))
      if n.startsWith("0x") or n.startsWith("0X"):
        if n.len > 18: return NxCt(kind: ctInt, big: t)           # (beyond int64: as written)
        return fit(NxCt(kind: ctInt, i: BiggestInt(parseHexInt(n)), typ: typ))
      if n.startsWith("0b") or n.startsWith("0B"): return ctInt(BiggestInt(parseBinInt(n)))
      if n.startsWith("0o") or n.startsWith("0O"): return ctInt(BiggestInt(parseOctInt(n)))
      if n.len > 18: return NxCt(kind: ctInt, big: n)
      return fit(NxCt(kind: ctInt, i: parseBiggestInt(n), typ: typ))
    except ValueError: return bad()

  proc num(v: NxCt): float = (if v.kind == ctFloat: v.f else: float(v.i))
  proc isNum(v: NxCt): bool = v.kind in {ctInt, ctFloat} and v.big.len == 0
  proc ordinal(v: NxCt): bool = v.kind in {ctInt, ctChar, ctBool, ctEnum} and v.big.len == 0

  proc expr(minPrec: int): NxCt
  proc rawArg(): string =
    ## the text of a call's one argument, as written (for high(int8), defined(x), sizeof(T))
    var d = 0
    var parts: seq[string]
    while p < toks.len:
      let t = toks[p]
      if t in ["(", "["]: inc d
      elif t in [")", "]"]:
        if d == 0: break
        dec d
      parts.add t
      inc p
    parts.join("")

  proc call(name: string, args: seq[NxCt], raw: string): NxCt =
    case name
    of "defined":
      return case nxWhen("defined(" & raw & ")")
             of 1: ctBool(true)
             of 0: ctBool(false)
             else: NxCt()            # (not known: `… or defined(x)` can still be told — see binary)
    of "declared":
      if nxLookup(nxScope(f), raw).len > 0: return ctBool(true)
      return bad()
    of "high", "low":
      let (ok, lo, hi, _, bigHi) = nxIntTypeRange(raw)
      if ok:
        if name == "high" and bigHi.len > 0: return NxCt(kind: ctInt, big: bigHi)
        let v = if name == "high": hi else: lo
        return (if raw in ["char", "cchar"]: NxCt(kind: ctChar, i: v) elif raw == "bool": ctBool(v != 0)
                else: NxCt(kind: ctInt, i: v, typ: (if raw in ["int", "int64"]: "" else: raw)))
      for r in nxLookup(nxScope(f), raw):
        if r.sym.kind == nxType:
          let vals = nxEnumOrdinals(r)
          if vals.len > 0:
            let (n, o) = if name == "high": vals[^1] else: vals[0]
            return NxCt(kind: ctEnum, i: o, s: n)
      if args.len == 1 and args[0].kind == ctStr: return bad()
      return bad()
    of "sizeof":
      let (ok, _, _, size, _) = nxIntTypeRange(raw)
      if ok: return ctInt(size)
      case raw
      of "float", "float64", "cdouble", "pointer", "cstring", "BiggestFloat": return ctInt(8)
      of "float32", "cfloat": return ctInt(4)
      else:
        if raw.startsWith("ptr ") or raw.startsWith("ref ") or raw.startsWith("proc"): return ctInt(8)
        return bad()
    else: discard
    if failed: return
    for a in args:
      if a.kind == ctNone: return bad()
    case name
    of "ord":
      if args.len == 1 and ordinal(args[0]): return ctInt(args[0].i)
    of "chr":
      if args.len == 1 and args[0].kind == ctInt and args[0].i in 0 .. 255: return NxCt(kind: ctChar, i: args[0].i)
    of "len":
      if args.len == 1 and args[0].kind == ctStr: return ctInt(args[0].s.len)
    of "abs":
      if args.len == 1 and args[0].kind == ctInt and args[0].i != low(BiggestInt): return ctInt(abs(args[0].i))
      if args.len == 1 and args[0].kind == ctFloat: return NxCt(kind: ctFloat, f: abs(args[0].f))
    of "min", "max":
      if args.len == 2 and isNum(args[0]) and isNum(args[1]):
        let pick = if name == "min": num(args[0]) <= num(args[1]) else: num(args[0]) >= num(args[1])
        return (if pick: args[0] else: args[1])
    of "succ", "pred":
      if args.len == 1 and args[0].kind in {ctInt, ctChar}:
        var v = args[0]
        v.i += (if name == "succ": 1 else: -1)
        return v
    of "$":
      if args.len == 1:
        let a = args[0]
        return NxCt(kind: ctStr, s: (case a.kind
                                     of ctStr: a.s
                                     of ctChar: $char(a.i)
                                     else: nxCtRender(a)))
    of "int", "int64", "int32", "int16", "int8", "uint", "uint8", "uint16", "uint32", "uint64", "Natural", "byte",
       "cint", "csize_t":
      if args.len == 1:
        let a = args[0]
        let v = if a.kind == ctFloat: (if abs(a.f) < NxIntMax: BiggestInt(a.f) else: return bad())
                elif ordinal(a): a.i
                else: return bad()
        let (_, lo, hi, _, _) = nxIntTypeRange(name)
        if v < lo or v > hi:
          errMsg = $v & " does not fit " & name & " (" & $lo & " .. " & $hi & ")"
          return bad()
        return NxCt(kind: ctInt, i: v, typ: (if name in ["int", "int64"]: "" else: name))
    of "float", "float64", "float32", "cfloat", "cdouble":
      if args.len == 1 and isNum(args[0]): return NxCt(kind: ctFloat, f: num(args[0]))
    of "char":
      if args.len == 1 and ordinal(args[0]) and args[0].i in 0 .. 255: return NxCt(kind: ctChar, i: args[0].i)
    of "bool":
      if args.len == 1 and ordinal(args[0]): return ctBool(args[0].i != 0)
    of "toUpperAscii", "toLowerAscii":
      if args.len == 1 and args[0].kind == ctStr:
        return NxCt(kind: ctStr, s: (if name == "toUpperAscii": args[0].s.toUpperAscii else: args[0].s.toLowerAscii))
    of "repeat":
      if args.len == 2 and args[0].kind in {ctStr, ctChar} and args[1].kind == ctInt and args[1].i in 0 .. 10_000:
        let one = if args[0].kind == ctStr: args[0].s else: $char(args[0].i)
        if one.len * args[1].i <= 100_000: return NxCt(kind: ctStr, s: one.repeat(args[1].i))
    else: discard
    bad()

  proc callArgs(name: string): NxCt =
    ## after `name(`: its arguments, then `)`
    let save = p
    var args: seq[NxCt]
    var raw = ""
    if name in ["defined", "declared", "high", "low", "sizeof"]:
      raw = rawArg()
      if p < toks.len and toks[p] == ")": inc p
      else: return bad()
      if name in ["high", "low"]:
        # high(x) of a value: its type's — only for a few literal kinds
        let v = nxCtEval(f, raw, depth + 1)
        if v.kind == ctChar: raw = "char"
        elif v.kind == ctBool: raw = "bool"
      return call(name, @[], raw)
    discard save
    if p < toks.len and toks[p] == ")":
      inc p
      return call(name, args, raw)
    while p < toks.len:
      args.add expr(0)
      if failed: return
      if p < toks.len and toks[p] == ",":
        inc p
        continue
      break
    if p < toks.len and toks[p] == ")": inc p
    else: return bad()
    call(name, args, raw)

  proc primary(): NxCt =
    if p >= toks.len: return bad()
    let t = toks[p]
    inc p
    if t == "(":
      result = expr(0)
      if p < toks.len and toks[p] == ")": inc p
      else: return bad()
    elif t == "-" or t == "+":
      let v = expr(9)                                   # (unary binds tighter than * and +)
      if failed: return
      if t == "+": return v
      case v.kind
      of ctInt: return (if v.big.len > 0: bad() else: fit(NxCt(kind: ctInt, i: -v.i, typ: v.typ)))
      of ctFloat: return NxCt(kind: ctFloat, f: -v.f)
      else: return bad()
    elif t == "not":
      let v = expr(5)
      if failed: return
      if v.kind == ctBool: return ctBool(v.i == 0)
      if v.kind == ctInt and v.big.len == 0: return fit(NxCt(kind: ctInt, i: not v.i, typ: v.typ))
      return bad()
    elif t == "$":
      let v = expr(10)
      if failed: return
      return call("$", @[v], "")
    elif t[0] == '"': result = NxCt(kind: ctStr, s: t[1 .. ^1])
    elif t[0] == '\'': result = NxCt(kind: ctChar, i: parseInt(t[1 .. ^1]))
    elif t[0] in Digits: result = parseNum(t)
    elif nxIsIdent(t[0]):
      if p < toks.len and toks[p] == "(":
        inc p
        result = callArgs(t)
      elif p < toks.len and toks[p] == "[" and t in ["high", "low"]: return bad()
      else:
        result = nxCtName(f, t, depth)
        if result.kind == ctNone:
          # a type name before a dot: int8.high, char.low
          if p + 1 < toks.len and toks[p] == "." and toks[p + 1] in ["high", "low"]:
            let fn = toks[p + 1]
            p += 2
            return call(fn, @[], t)
          return bad()
    else: return bad()
    # postfix: x.len, x.ord, s[0]
    while not failed and p < toks.len:
      if toks[p] == "." and p + 1 < toks.len and nxIsIdent(toks[p + 1][0]):
        let fn = toks[p + 1]
        p += 2
        var args = @[result]
        if p < toks.len and toks[p] == "(":
          inc p
          if p < toks.len and toks[p] == ")": inc p
          else:
            while p < toks.len:
              args.add expr(0)
              if failed: return
              if p < toks.len and toks[p] == ",":
                inc p
                continue
              break
            if p < toks.len and toks[p] == ")": inc p
            else: return bad()
        result = call(fn, args, "")
      elif toks[p] == "[" and result.kind == ctStr:
        inc p
        let ix = expr(0)
        if failed or p >= toks.len or toks[p] != "]" or ix.kind != ctInt: return bad()
        inc p
        if ix.i < 0 or ix.i >= result.s.len: return bad()
        result = NxCt(kind: ctChar, i: ord(result.s[ix.i]))
      else: break

  proc prec(op: string): int =
    case op
    of "and": 4
    of "or", "xor": 3
    of "div", "mod", "shl", "shr", "*", "/", "%": 9
    of "+", "-", "|", "~": 8
    of "&": 7
    of "==", "!=", "<", "<=", ">", ">=", "in", "notin", "is", "isnot": 5
    else: -1

  proc binary(op: string, a, b: NxCt): NxCt =
    if op in ["and", "or"] and (a.kind == ctNone or b.kind == ctNone):
      # (a defined(x) ned cannot tell: `defined(x) or true` is true, `defined(x) and false` false, else unknown)
      let k = if a.kind == ctNone: b else: a
      if k.kind == ctBool and (k.i != 0) == (op == "or"): return k
      return bad()
    if a.kind == ctNone or b.kind == ctNone: return bad()
    case op
    of "&":
      let sa = if a.kind == ctStr: a.s elif a.kind == ctChar: $char(a.i) else: return bad()
      let sb = if b.kind == ctStr: b.s elif b.kind == ctChar: $char(b.i) else: return bad()
      return NxCt(kind: ctStr, s: sa & sb)
    of "and", "or", "xor":
      if a.kind == ctBool and b.kind == ctBool:
        return ctBool(case op
                      of "and": a.i != 0 and b.i != 0
                      of "or": a.i != 0 or b.i != 0
                      else: (a.i != 0) != (b.i != 0))
      if a.kind == ctInt and b.kind == ctInt and a.big.len == 0 and b.big.len == 0:
        let (same, t) = joinTyp(a, b)
        if not same: return bad()
        return fit(NxCt(kind: ctInt, typ: t, i: (case op
                                                   of "and": a.i and b.i
                                                   of "or": a.i or b.i
                                                   else: a.i xor b.i)))
      return bad()
    of "==", "!=", "<", "<=", ">", ">=":
      var c = 0
      if isNum(a) and isNum(b):
        c = cmp(num(a), num(b))
        if a.kind == ctInt and b.kind == ctInt: c = cmp(a.i, b.i)
      elif a.kind == ctStr and b.kind == ctStr: c = cmp(a.s, b.s)
      elif a.kind == b.kind and ordinal(a): c = cmp(a.i, b.i)
      else: return bad()
      return ctBool(case op
                    of "==": c == 0
                    of "!=": c != 0
                    of "<": c < 0
                    of "<=": c <= 0
                    of ">": c > 0
                    else: c >= 0)
    of "in", "notin":
      if a.kind in {ctChar, ctStr} and b.kind == ctStr:
        let has = (if a.kind == ctChar: char(a.i) in b.s else: a.s in b.s)
        return ctBool(if op == "in": has else: not has)
      return bad()
    of "+", "-", "*", "/", "div", "mod", "shl", "shr", "%":
      if not isNum(a) or not isNum(b): return bad()
      if op == "/" or a.kind == ctFloat or b.kind == ctFloat:
        if op in ["div", "mod", "shl", "shr", "%"]: return bad()
        let x = num(a)
        let y = num(b)
        let r = case op
                of "+": x + y
                of "-": x - y
                of "*": x * y
                else: (if y == 0: return bad() else: x / y)
        return NxCt(kind: ctFloat, f: r)
      let x = a.i
      let y = b.i
      let (same, t) = joinTyp(a, b)
      if not same: return bad()
      # past int64: an overflow (a compile error) — an unsigned one is not worked out
      template past(): NxCt = (if t in NxUnsigned: bad() else: overflow(t))
      const Hi = high(BiggestInt)
      const Lo = low(BiggestInt)
      case op
      of "+":
        if (y > 0 and x > Hi - y) or (y < 0 and x < Lo - y): return past()
        return fit(NxCt(kind: ctInt, typ: t, i: x + y))
      of "-":
        if (y < 0 and x > Hi + y) or (y > 0 and x < Lo + y): return past()
        return fit(NxCt(kind: ctInt, typ: t, i: x - y))
      of "*":
        if x == 0 or y == 0: return fit(NxCt(kind: ctInt, typ: t, i: 0))
        if x == Lo or y == Lo: return bad()
        if abs(x) > Hi div abs(y): return past()
        return fit(NxCt(kind: ctInt, typ: t, i: x * y))
      of "div", "mod", "%":
        if y == 0:
          errMsg = "division by zero"
          return bad()
        return fit(NxCt(kind: ctInt, typ: t, i: (if op == "div": x div y else: x mod y)))
      of "shl":
        if y < 0 or y > 62 or x == low(BiggestInt) or (abs(x) shr (62 - y)) != 0:
          if t.len > 0 and t notin ["int", "int64"] and y >= 0 and y < 64:
            return fit(NxCt(kind: ctInt, typ: t, i: (if y < 63: x shl y else: 0)))   # (a narrower type: kept in it)
          return bad()
        if a.typ.len > 0 and a.typ notin NxUnsigned and a.typ notin ["int", "int64"]:
          # (a bit shift never overflows: in a narrower signed type the bits wrap into the sign)
          let bits = 8 * nxIntTypeRange(a.typ)[3]
          var w = (x shl y) and ((1'i64 shl bits) - 1)
          if w >= (1'i64 shl (bits - 1)): w -= (1'i64 shl bits)
          return NxCt(kind: ctInt, typ: a.typ, i: w)
        return fit(NxCt(kind: ctInt, typ: a.typ, i: x shl y))
      else:
        if y < 0 or y > 63: return bad()
        return fit(NxCt(kind: ctInt, typ: a.typ, i: x shr y))
    else: bad()

  proc expr(minPrec: int): NxCt =
    result = primary()
    while not failed and p < toks.len:
      let op = toks[p]
      let pr = prec(op)
      if pr < 0 or pr < minPrec: break
      inc p
      let rhs = expr(pr + 1)
      if failed: return
      result = binary(op, result, rhs)
      if failed: return

  result = expr(0)
  if failed: return NxCt(err: errMsg)
  if p < toks.len: return NxCt()

func nxWhenHeaderEnd(lines: openArray[string], l: int): int =
  ## the line a `when`/`elif` header on line l ends on: its condition may go on over the lines below
  result = l
  var t = lines[l].strip(trailing = false)
  while result + 1 < lines.len and result - l < 6:
    let c = nxCodeOf(t)
    if c.endsWith(":"): break
    if not (c.endsWith(" or") or c.endsWith(" and") or c.endsWith("(") or c.endsWith(",") or
            c.endsWith(" not") or c.count('(') > c.count(')')): break
    inc result
    t.add " " & lines[result].strip

proc nxInactiveWhen*(f: NxFile, lines: openArray[string]): seq[(int, int)] =
  ## the branches of `when` left out on this platform: (first line, last line) of each body. A chain is followed
  ## only as far as its conditions can be told: after one that cannot, nothing more of it is dimmed
  proc condOf(t: string, kw: int): string =
    var c = t[kw .. ^1]
    let h = c.find(" #")
    if h >= 0: c.setLen(h)
    c = c.strip
    if not c.endsWith(":"): return ""                    # (one line, or the condition goes on: not followed)
    c[0 ..< ^1].strip
  # (the lines that start inside a """string""": part of the body they are in, whatever their indentation —
  # a header for importc written out at the left margin)
  var inStr: seq[bool]
  for l in lines:
    if "\"\"\"" in l:
      inStr = newSeq[bool](lines.len)
      var st: NxLexState
      for k in 0 ..< lines.len:
        inStr[k] = st.inTriple
        discard nxLexRuns(lines[k], st, false)
      break
  template inString(k: int): bool = inStr.len > 0 and inStr[k]
  var i = 0
  while i < lines.len:
    let raw = lines[i]
    if raw.len > 2000 or "when " notin raw or inString(i):
      inc i
      continue
    let t = raw.strip(trailing = false)
    let ind = raw.len - t.len
    if not t.startsWith("when "):
      inc i
      continue
    template header(l0, kw: int): (string, int) =
      # the condition of the `when`/`elif` on line l0, and the line its header ends on — a condition may go on over
      # the lines below (`when defined(macosx) or⏎ defined(freebsd):`)
      let hl = nxWhenHeaderEnd(lines, l0)
      var ht = lines[l0].strip(trailing = false)
      for q in l0 + 1 .. hl: ht.add " " & lines[q].strip
      (condOf(ht, kw), hl)
    var (cond, hdrEnd) = header(i, 5)
    var isElse = false
    var anyTrue, unknown = false
    while true:
      let v = if anyTrue: 0
              elif unknown: -1
              elif isElse: 1
              elif cond.len == 0: -1
              else:
                let x = nxCtEval(f, cond)
                if x.kind == ctBool: int(x.i != 0) else: -1
      # the body: the lines below indented further (blank ones inside it too)
      var e = hdrEnd
      var k = hdrEnd + 1
      while k < lines.len and (lines[k].strip.len == 0 or inString(k) or
                               lines[k].len - lines[k].strip(trailing = false).len > ind):
        if lines[k].strip.len > 0: e = k
        inc k
      if v == 0 and e > hdrEnd: result.add (hdrEnd + 1, e)
      if v == 1: anyTrue = true
      if v < 0: unknown = true
      if e + 1 >= lines.len: break
      var nx = e + 1
      while nx < lines.len and lines[nx].strip.len == 0: inc nx
      if nx >= lines.len: break
      let nt = lines[nx].strip(trailing = false)
      if lines[nx].len - nt.len != ind: break
      if nt.startsWith("elif "):
        (cond, hdrEnd) = header(nx, 5)
        isElse = false
      elif nt.startsWith("else:") and nt.strip == "else:":
        isElse = true
        hdrEnd = nx
      else: break
    inc i

proc nxRangeText*(f: NxFile, t: string): string =
  ## a range written as its bounds (an array's index: mJan..mDec, low(Domain).ord..high(Domain).ord, 0 ..< 4, or a
  ## count: 10) as the compiler shows the type — range 1..12(Month), range 0..10(int), range 0..9(int) — or t itself
  ## when its bounds cannot be worked out
  result = t
  var x = t.strip
  if x.startsWith("range[") and x.endsWith("]"): x = x[6 ..< ^1].strip
  let rg = nxFindRange(x)
  if rg < 0:
    if x.len > 0 and (x[0] in Digits or nxIsIdent(x[0])):
      let v = nxCtEval(f, x)                 # (array[4, T], array[N, T] with N a constant)
      if v.kind == ctInt and v.big.len == 0 and v.i > 0: return "range 0.." & $(v.i - 1) & "(int)"
    return
  let excl = x.continuesWith("..<", rg)
  let lo = nxCtEval(f, x[0 ..< rg].strip)
  let hi = nxCtEval(f, x[rg + (if excl: 3 else: 2) .. ^1].strip)
  if lo.kind != hi.kind or lo.big.len > 0 or hi.big.len > 0: return
  let h = hi.i - (if excl: 1 else: 0)
  case lo.kind
  of ctInt: result = "range " & $lo.i & ".." & $h & "(" & (if lo.typ.len > 0: lo.typ else: "int") & ")"
  of ctEnum:
    for r in nxLookup(nxScope(f), lo.s):
      if r.sym.kind == nxEnumVal: return "range " & $lo.i & ".." & $h & "(" & r.sym.owner & ")"
  else: discard

proc nxCtHover*(f: NxFile, e: string): string =
  ## for a hover: "= value", "— a compile error: …", or "" when the index cannot tell
  let v = nxCtEval(f, e)
  if v.kind != ctNone: return "= " & nxCtRender(v)
  if v.err.len > 0: return "— a compile error: " & v.err
  ""
