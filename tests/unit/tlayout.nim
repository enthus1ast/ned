## The engine's memory layouts (sizes, alignments, field offsets) and exception hints. The layouts are checked
## against the compiler's own sizeof / alignof / offsetOf when `nim` is on PATH.
## Run: nim r tests/unit/tlayout.nim

import std/[os, osproc, strutils, tables, sets, algorithm, unittest]
import ../../src/ned/nim/index

proc realOf(p: string): string =
  result = p
  try:
    if symlinkExists(p): result = expandFilename(p)
  except OSError: discard

proc nimLib(): string =
  let nim = findExe("nim")
  if nim.len == 0: return ""
  let prefix = nim.realOf.parentDir.parentDir
  for cand in [prefix / "lib", prefix / "lib" / "nim", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand

nxInitDefines()
let lib = nimLib()
if lib.len > 0: nxSetToolchain(lib, @[], @[])

let dir = getTempDir() / ("ned_tlayout_" & $getCurrentProcessId())
createDir(dir)
var n = 0

proc fixture(text: string): NxFile =
  inc n
  let p = dir / ("f" & $n & ".nim")
  writeFile(p, text)
  nxLoad(p)

proc layoutOf(f: NxFile, name: string): NxLayout =
  for i, s in f.syms:
    if s.kind == nxType and s.name == name: return nxLayoutOf(NxRef(file: f, idx: int32(i)))
  doAssert false, name & " not declared"

proc offsets(l: NxLayout): seq[(string, int)] =
  for r in l.rows:
    if r.name.len > 0 and r.size >= 0: result.add (r.name, r.offset)

# every rule the layouts follow, in one module: what the compiler says of each is compared below
const Synthetic = """
type
  E1 = enum e1a, e1b, e1c
  E2 = enum e2a = 0, e2b = 300
  E3 = enum e3a = -1, e3b
  E4 = enum e4a = 0, e4b = 70000
  E5 {.size: sizeof(cint).} = enum e5a, e5b
  E6 = enum e6a = (10, "ten"), e6b = "bee", e6c
  Basic = object
    b: bool
    c: char
    i8: int8
    i16: int16
    i32: int32
    i64: int64
    i: int
    u: uint
    f32: float32
    f: float
    s: string
    cs: cstring
    p: pointer
    sq: seq[int]
    r: ref int
    pt: ptr int8
  Padded = object
    flag: bool
    count: int
    small: int16
  Sets = object
    a: set[E1]
    b: set[range[0..15]]
    c: set[range[0..31]]
    d: set[range[0..63]]
    e: set[char]
    f: set[range[0..99]]
    g: set[uint16]
  Arrays = object
    a: array[3, int16]
    b: array[E1, int8]
    c: array[-2..2, int32]
    d: array[char, bool]
  Tup = tuple[a: int8, b: int, c: char]
  WithTuples = object
    t: Tup
    u: (int8, int32, int8)
  Dist = distinct int16
  R1 = range[0..255]
  R2 = range[0'u8..200'u8]
  R3 = range['a'..'z']
  R4 = range[e1a..e1b]
  Ranges = object
    a: R1
    b: R2
    c: R3
    d: R4
    e: Dist
  Procs = object
    cl: proc (x: int): int
    nc: proc (x: int): int {.nimcall.}
    cd: proc () {.cdecl.}
    it: iterator (): int
  NcProc = proc (a: pointer) {.nimcall, gcsafe.}
  WithNc = object
    a: NcProc
    b: int8
  Gen[T] = object
    x: T
    y: int8
  GenInt16 = Gen[int16]
  GenNested = Gen[Gen[int8]]
  Pair[A, B] = object
    a: A
    b: B
  PairUse = object
    p: Pair[int8, int64]
    q: Pair[string, char]
  Fixed[N: static int; T] = object
    data: array[N, T]
    len: int8
  FixedUse = Fixed[5, int16]
  Kind = enum kInt, kStr, kNone, kNested
  Variant = object
    case kind: Kind
    of kInt: i: int
    of kStr:
      s: string
      x: int8
    of kNone: discard
    of kNested:
      case sub: bool
      of true: big: array[3, int64]
      of false: small: int8
    after: int8
  Variant2 = object
    tag: int16
    case k: bool
    of true:
      a: int8
    else:
      b: array[12, int8]
      c: int32
  Pk {.packed.} = object
    a: int8
    b: int64
    c: int16
  PkCase {.packed.} = object
    a: int8
    case k: bool
    of true: x: int64
    of false: y: int8
  U {.union.} = object
    a: int8
    b: int64
    c: array[3, int32]
  Al = object
    a: int8
    b {.align(16).}: int8
    c: int32
  Base = object of RootObj
    a: int8
  Derived = object of Base
    b: int8
  Derived2 = object of Derived
    c: int64
  Inh {.inheritable.} = object
    z: int8
  InhPure {.inheritable, pure.} = object
    z: int8
  FromInh = object of Inh
    w: int16
  Node = ref object
    kids: seq[Node]
    name: string
    flag: bool
  NodeObj = object
    v: int8
    next: ref NodeObj
  NodeRef = ref NodeObj
  ShapeObj = object of RootObj
    name: string
  Shape = ref ShapeObj
  Circle = ref object of Shape
    r: float32
  Flex = object
    data: UncheckedArray[int]
  FlexMore = object
    len: int
    data: UncheckedArray[int16]
  Empty = object
  Whens = object
    a: int8
    when defined(windows):
      w: int64
    elif defined(posix):
      p: int32
    else:
      o: int16
    b: int8
  Alias = Padded
  Exc = object of CatchableError
    code: int8
"""

suite "memory layout (engine)":
  let f = fixture(Synthetic)
  let word = layoutOf(f, "Basic").word

  test "basic sizes, padding, sorted size":
    if word == 8:
      let p = layoutOf(f, "Padded")
      check p.ok and p.size == 24 and p.align == 8
      check p.offsets == @[("flag", 0), ("count", 8), ("small", 16)]
      check p.rows[0].pad == 7 and p.rows[2].pad == 6
      check p.plain and p.sorted == 16
      let b = layoutOf(f, "Basic")
      check b.ok and b.size == 120

  test "enums by their values, sets by their element's count":
    check layoutOf(f, "E1").size == 1
    check layoutOf(f, "E2").size == 2
    check layoutOf(f, "E3").size == 4
    check layoutOf(f, "E4").size == 4
    check layoutOf(f, "E5").size == 4
    let s = layoutOf(f, "Sets")
    check s.ok
    check s.offsets == @[("a", 0), ("b", 2), ("c", 4), ("d", 8), ("e", 16), ("f", 48), ("g", 61)]

  test "case objects, packed, union, align, inheritance":
    if word == 8:
      let v = layoutOf(f, "Variant")
      check v.ok and v.size == 48
      check ("big", 16) in v.offsets and ("after", 40) in v.offsets
      check not v.plain
      check layoutOf(f, "Pk").size == 11
      check layoutOf(f, "U").size == 16
      check layoutOf(f, "Al").size == 32 and layoutOf(f, "Al").align == 16
      check layoutOf(f, "Derived").size == 24
      check layoutOf(f, "Derived2").offsets == @[("c", 24)]
      check layoutOf(f, "InhPure").size == 1
      check layoutOf(f, "FromInh").offsets == @[("w", 16)]

  test "ref objects: the pointer, and the object it points to":
    let n = layoutOf(f, "Node")
    check n.ok and n.viaPtr == "ref" and n.size == word
    if word == 8: check n.objSize == 40
    let r = layoutOf(f, "NodeRef")
    check r.ok and r.viaPtr == "ref" and r.offsets == @[("v", 0), ("next", word)]
    let c = layoutOf(f, "Circle")
    check c.ok and c.viaPtr == "ref"

  test "generics with their arguments, a when it can decide":
    if word == 8:
      check layoutOf(f, "GenInt16").size == 4
      check layoutOf(f, "GenNested").size == 3
      check layoutOf(f, "FixedUse").size == 12
      check layoutOf(f, "PairUse").size == 40
    check not layoutOf(f, "Gen").ok                   # (no arguments: no layout)
    check layoutOf(f, "Whens").ok

  test "nothing when it cannot be sure":
    let g = fixture("type\n  C {.importc: \"struct c\", header: \"<c.h>\".} = object\n    x: cint\n" &
                    "  B {.bycopy.} = object\n    x: int\n  Bits = object\n    a {.bitsize: 3.}: cint\n" &
                    "  Unknown = object\n    x: NoSuchType\n  W = object\n    when someConst:\n      x: int\n" &
                    "  M {.myMacro.} = object\n    x: int\n")
    for t in ["C", "B", "Bits", "Unknown", "W", "M"]:
      check not layoutOf(g, t).ok

  test "the hover text":
    let t = nxLayoutText(layoutOf(f, "Padded"), "Padded")
    check "Memory layout" in t and "flag: bool" in t and "padding" in t

  test "the hover of a type: where it is declared, where it is used (G[int16] binds T), a built-in type":
    if lib.len == 0: skip()
    else:
      let src = "type\n  G[T] = object\n    x: T\n    y: int8\nvar g: G[int16]\nvar n: int\n"
      let g = fixture(src)
      let ls = src.split('\n')
      check "Memory layout" notin nxHover(g, ls, 1, 3)              # (G alone: its T is not known)
      let used = nxHover(g, ls, 4, ls[4].find("G[") + 1)
      check (if word == 8: "4 bytes, align 2" in used else: "Memory layout" in used)
      check ("Memory:** " & $word & " bytes") in nxHover(g, ls, 5, ls[5].find("int") + 1)
      nxLayoutOn = false
      check "Memory" notin nxHover(g, ls, 4, ls[4].find("G[") + 1)
      nxLayoutOn = true

proc againstCompiler(cpu: string) =
  ## the engine's layout of every type of Synthetic and the compiler's sizeof / alignof / offsetOf, for `cpu`
  let f = fixture(Synthetic)
  var prog = Synthetic
  var want: Table[string, string]
  var k = 0
  for i, s in f.syms:
    if s.kind != nxType or s.generics.len > 0: continue
    let l = nxLayoutOf(NxRef(file: f, idx: int32(i)))
    check l.ok
    if not l.ok: continue
    let o = if l.viaPtr.len > 0: "typeof(default(" & s.name & ")[])" else: s.name
    prog.add "static: echo \"L|" & s.name & "|\", sizeof(" & s.name & "), \"|\", alignof(" & s.name & ")\n"
    want["L|" & s.name] = $l.size & "|" & $l.align
    if l.viaPtr.len > 0:
      prog.add "static: echo \"P|" & s.name & "|\", sizeof(" & o & "), \"|\", alignof(" & o & ")\n"
      want["P|" & s.name] = $l.objSize & "|" & $l.objAlign
    if l.path == f.path:
      for r in l.rows:
        if r.name.len == 0 or r.size < 0: continue
        prog.add "static: echo \"O|" & s.name & "." & r.name & "|\", offsetOf(" & o & ", " & r.name & ")\n"
        want["O|" & s.name & "." & r.name] = $r.offset
    inc k
  let p = dir / ("against_" & cpu & ".nim")
  writeFile(p, prog)
  let (outp, code) = execCmdEx("nim check --cpu:" & cpu & " --hints:off --warnings:off --colors:off " & quoteShell(p))
  check code == 0
  var got: Table[string, string]
  for l in outp.splitLines:
    let parts = l.split('|')
    if parts.len >= 3 and parts[0] in ["L", "P", "O"]:
      got[parts[0] & "|" & parts[1]] = parts[2 .. ^1].join("|")
  check k >= 40
  for key, v in want:
    if got.getOrDefault(key) != v:
      checkpoint key & ": the compiler says " & got.getOrDefault(key) & ", the engine " & v
      check false

suite "memory layout (against the compiler)":
  let have = findExe("nim").len > 0 and lib.len > 0
  test "sizeof, alignof and offsetOf of every type above (64-bit)":
    if not have: skip()
    elif "amd64" in nxDefines or "arm64" in nxDefines: againstCompiler(if "arm64" in nxDefines: "arm64" else: "amd64")
    else: skip()

  test "… and on i386 (32-bit: 4-byte pointers, int64 and float aligned to 4)":
    if not have: skip()
    else:
      let keep = nxDefines
      nxDefines.excl "amd64"
      nxDefines.excl "arm64"
      nxDefines.incl "i386"
      try: againstCompiler("i386")
      finally: nxDefines = keep


# ── exception hints ──

const RaisesSrc = """
import std/strutils

proc load(s: string): int =
  result = parseInt(s)

proc safe(s: string): int =
  try:
    result = parseInt(s)
  except ValueError:
    result = 0

proc check(x: int) =
  if x < 0:
    raise newException(IOError, "negative")
  echo x

proc rethrow(s: string) =
  try:
    discard parseInt(s)
  except ValueError:
    echo "bad"
    raise

proc rethrowTwo(s: string) =
  try:
    discard parseInt(s)
  except ValueError, KeyError:
    raise

proc catchAll() =
  try:
    check(1)
    discard load("2")
  except:
    discard

proc exceptAs(s: string) =
  try:
    discard parseInt(s)
  except ValueError as e:
    raise e

proc rec(n: int): int =
  if n < 0: raise newException(KeyError, "neg")
  if n == 0: return 0
  result = rec(n - 1)

proc defects(x: int) =
  doAssert x > 0
  assert x > 1
  echo x

iterator upTo(n: int): int =
  for i in 0 ..< n:
    if i > 5: raise newException(KeyError, "k")
    yield i

proc usesIter() =
  for x in upTo(3): echo x

proc declared(s: string) {.raises: [IOError].} =
  if s.len == 0: raise newException(IOError, "empty")

proc callsDeclared() =
  declared("x")
  check(2)

proc callsParam(f: proc ()) =
  f()

proc twice[T](x: T): T = x

proc nested(s: string): int =
  try:
    result = load(s)
  except IOError:
    result = 1
  finally:
    check(result)
"""

suite "exception hints (engine)":
  let f = fixture(RaisesSrc)
  let lines = RaisesSrc.split('\n')
  proc raisesOf(name: string): NxRaises =
    for i, s in f.syms:
      if s.name == name and s.kind in NxRoutineKinds: return nxRaisesOf(NxRef(file: f, idx: int32(i)))
    doAssert false, name
  proc list(name: string): string =
    let r = raisesOf(name)
    if not r.known: return "?"
    var names: seq[string]
    for e in r.excs: names.add e.name
    names.sort()
    names.join(",")

  test "raise statements, the routines called, what a try catches":
    if lib.len == 0: skip()
    else:
      check list("load") == "ValueError"
      check list("safe") == ""
      check list("check") == "IOError"
      check list("catchAll") == ""
      check list("nested") == "IOError,ValueError"

  test "a bare raise: the one type its except names, else Exception; raise e: e's type":
    if lib.len == 0: skip()
    else:
      check list("rethrow") == "ValueError"
      check list("rethrowTwo") == "Exception"
      check list("exceptAs") == "ValueError"

  test "recursion cut, Defects left out, iterators, a declared list":
    if lib.len == 0: skip()
    else:
      check list("rec") == "KeyError"
      check list("defects") == ""
      check list("usesIter") == "KeyError"
      check list("declared") == "IOError"
      check list("callsDeclared") == "IOError"

  test "not known: a proc parameter called; no hint on a generic or declared routine":
    if lib.len == 0: skip()
    else:
      check list("callsParam") == "?"
      for s in f.syms:
        if s.name == "twice" or s.name == "declared": check not nxRaisesHintable(f, lines, s)
        if s.name == "load": check nxRaisesHintable(f, lines, s)

  test "where the hint goes: before the = of the header":
    for s in f.syms:
      if s.name == "load":
        let (l, c) = nxRaisesHintAt(lines, s)
        check l == s.line and lines[l][0 ..< c] == "proc load(s: string): int"

suite "exception hints (against the compiler's {.effects.})":
  test "every routine above the engine is sure of":
    if findExe("nim").len == 0 or lib.len == 0: skip()
    else:
      let f = fixture(RaisesSrc)
      var ls = RaisesSrc.split('\n')
      var want: seq[(string, string)]
      var ins: seq[(int, seq[string])]
      for i, s in f.syms:
        if s.kind notin {nxProc, nxFunc, nxIterator} or not nxRaisesHintable(f, ls, s) or s.endLine <= s.line: continue
        let r = nxRaisesOf(NxRef(file: f, idx: int32(i)))
        if not r.known: continue
        var names: seq[string]
        for e in r.excs: names.add e.name
        names.sort()
        want.add (s.name, names.join(","))
        var bodyInd = 2
        for k in s.line + 1 .. s.endLine:
          if ls[k].strip.len > 0:
            bodyInd = ls[k].len - ls[k].strip(trailing = false).len
            break
        ins.add (s.endLine, @[spaces(bodyInd) & "{.effects.}", "{.hint: \"NEDEND " & s.name & "\".}"])
      check want.len >= 8
      for k in countdown(ins.high, 0):
        var at = ins[k][0] + 1
        for x in ins[k][1]:
          ls.insert(x, at)
          inc at
      let p = dir / "effects.nim"
      writeFile(p, ls.join("\n"))
      let (outp, _) = execCmdEx("nim check --hint:all:off --hint:User:on --warnings:off --colors:off " & quoteShell(p))
      var cur: seq[string]
      var got: Table[string, string]
      for l in outp.splitLines:
        let h = l.find("Hint: ")
        if h < 0 or not l.endsWith("[User]"): continue
        var what = l[h + 6 ..< l.len - 6].strip
        if what.startsWith("NEDEND "):
          cur.sort()
          got[what[7 .. ^1]] = cur.join(",")
          cur = @[]
          continue
        if what.startsWith("ref "): what = what[4 .. ^1]
        if not what.endsWith("Effect") and what notin cur: cur.add what
      for (name, l) in want:
        if got.getOrDefault(name, "(not printed)") != l:
          checkpoint name & ": the compiler says " & got.getOrDefault(name, "(not printed)") & ", the engine " & l
          check false

removeDir(dir)
