## The engine's effects: which procs can be funcs (no side effects, as the compiler infers them), converters in
## what a routine can raise, and which types satisfy a concept. Checked against the compiler (`func` compiles,
## {.effects.}, `T is C`) when `nim` is on PATH.
## Run: nim r tests/unit/teffects.nim

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

let dir = getTempDir() / ("ned_teffects_" & $getCurrentProcessId())
createDir(dir)
var n = 0

proc fixture(text: string, name = ""): NxFile =
  inc n
  let p = dir / (if name.len > 0: name else: "f" & $n & ".nim")
  writeFile(p, text)
  nxLoad(p)

proc compiles(path: string): (bool, string) =
  let (outp, code) = execCmdEx("nim check --hints:off --warnings:off --colors:off " & quoteShell(path))
  (code == 0 and "Error" notin outp, outp)

# ── can be a func ──

const FuncSrc = """
import std/strutils

var counter = 0
let limit = 10
var tls {.threadvar.}: int
const K = 3

type
  Shape = object
    w, h: int
  Callback = proc (x: int): int {.noSideEffect.}

proc add1(x: int): int = x + 1
proc twice(x: int): int = add1(add1(x)) * K
proc area(s: Shape): int = s.w * s.h
proc upper(s: string): string = s.toUpperAscii & "!"
proc fill(s: var seq[int]) =
  s.add 1
  s.add twice(2)
proc safeParse(s: string): int =
  try:
    result = parseInt(s)
  except ValueError:
    result = 0
proc pureCb(f: Callback): int = f(1)
proc exported*(x: int): int = x * 2
proc recursive(n: int): int =
  if n <= 0: 0 else: recursive(n - 1) + 1

proc bump() = inc counter
proc readsLet(): int = limit
proc readsTls(): int = tls
proc talk(x: int) = echo x
proc callsBump(x: int): int =
  bump()
  x
proc callsParam(f: proc (x: int): int): int = f(1)
proc globalInside(): int =
  var g {.global.} = 0
  inc g
  g
proc writes() = writeFile("x.txt", "x")
proc castOk(): int =
  {.cast(noSideEffect).}:
    inc counter
  1

proc stub() = discard
proc generic[T](x: T): T = x
proc ahead(x: int): int
proc ahead(x: int): int = x
proc withExport(x: int): int {.exportc.} = x
proc outer(): int =
  proc inner(): int = 1
  inner()
"""

suite "can be a func":
  test "procs with no side effects — and only those":
    if lib.len == 0: skip()
    else:
      let f = fixture(FuncSrc)
      let lines = FuncSrc.split('\n')
      let (idx, cut) = nxFuncHints(f, lines)
      check not cut
      var names: seq[string]
      for i in idx: names.add f.syms[i].name
      names.sort()
      check names == @["add1", "area", "castOk", "exported", "fill", "pureCb", "recursive", "safeParse", "twice",
                       "upper"]

  test "a side effect, or not looked at":
    if lib.len == 0: skip()
    else:
      let f = fixture(FuncSrc)
      let lines = FuncSrc.split('\n')
      proc purity(name: string): NxPurity =
        for i, s in f.syms:
          if s.name == name and s.kind in NxRoutineKinds: return nxSideEffectsOf(NxRef(file: f, idx: int32(i)))
        doAssert false, name
      for nm in ["bump", "readsLet", "readsTls", "talk", "callsBump", "callsParam", "globalInside"]:
        let p = purity(nm)
        check p.known and not p.pure
        if not (p.known and not p.pure): echo "  ", nm, ": ", p
      check not purity("writes").pure                # (I/O: a side effect, or not known — never "none")
      check purity("add1").known and purity("add1").pure
      for s in f.syms:
        if s.name in ["stub", "generic", "ahead", "withExport", "inner"]: check not nxFuncHintable(f, lines, s)
        if s.name in ["add1", "exported"]: check nxFuncHintable(f, lines, s)
      for s in f.syms:
        if s.name == "twice":
          let k = nxFuncKeywordAt(lines, s)
          check k == 0 and lines[s.line][k ..< k + 4] == "proc"

  test "strictFuncs on: no hints":
    if lib.len == 0: skip()
    else:
      let src = "{.experimental: \"strictFuncs\".}\nproc add1(x: int): int = x + 1\n"
      let f = fixture(src)
      check nxStrictFuncsOn(f.path, src.split('\n'))
      check nxFuncHints(f, src.split('\n'))[0].len == 0

  test "an edit in an open file: what depends on the routine changed is worked out again":
    if lib.len == 0: skip()
    else:
      var src = "var g = 0\nproc a(): int = 1\nproc b(): int = a() + 1\nproc c(): int = 2\n"
      let p = dir / "open.nim"
      writeFile(p, src)
      var stamp = "v1"
      var lines = src.split('\n')
      nxBufferStamp = proc(path: string): string = (if path == p: stamp else: "")
      nxBufferLines = proc(path: string): seq[string] = (if path == p: lines else: @[])
      proc hinted(): seq[string] =
        let f = nxLoad(p)
        for i in nxFuncHints(f, lines)[0]: result.add f.syms[i].name
        result.sort()
      check hinted() == @["a", "b", "c"]
      lines[1] = "proc a(): int = g"                # (a now uses the global: a and b have side effects)
      stamp = "v2"
      check hinted() == @["c"]
      lines[1] = "proc a(): int = 1 + 1"
      stamp = "v3"
      check hinted() == @["a", "b", "c"]
      nxBufferStamp = nil
      nxBufferLines = nil

suite "can be a func (against the compiler)":
  test "every hinted proc compiles as a func, the others do not":
    if findExe("nim").len == 0 or lib.len == 0: skip()
    else:
      let f = fixture(FuncSrc)
      let lines = FuncSrc.split('\n')
      var ls = lines
      var hinted: HashSet[string]
      for i in nxFuncHints(f, lines)[0]:
        let s = f.syms[i]
        hinted.incl s.name
        let k = nxFuncKeywordAt(ls, s)
        ls[s.line] = ls[s.line][0 ..< k] & "func" & ls[s.line][k + 4 .. ^1]
      check hinted.len >= 8
      let p = dir / "funcs.nim"
      writeFile(p, ls.join("\n"))
      let (ok, outp) = compiles(p)
      check ok
      if not ok: echo outp
      # (and each impure one, as a func, does not compile)
      for nm in ["bump", "readsLet", "talk", "callsParam", "globalInside"]:
        var one = lines
        for s in f.syms:
          if s.name == nm and s.kind == nxProc:
            let k = nxFuncKeywordAt(one, s)
            one[s.line] = one[s.line][0 ..< k] & "func" & one[s.line][k + 4 .. ^1]
        let q = dir / ("impure_" & nm & ".nim")
        writeFile(q, one.join("\n"))
        check not compiles(q)[0]

# ── converters in what a routine can raise ──

const ConvSrc = """
type
  Celsius = object
    v: float
proc parseC(s: string): Celsius =
  if s.len == 0: raise newException(ValueError, "empty")
  result = Celsius(v: 1.0)
converter toC(s: string): Celsius =
  result = parseC(s)
converter toF(c: Celsius): float =
  result = c.v
proc show(c: Celsius): string =
  result = "c"
proc useIt(): string =
  result = show("10")
proc noConv(c: Celsius): string =
  result = show(c)
proc viaVar(): float =
  let c: Celsius = "5"
  result = c.v
proc assigned(): float =
  var c = Celsius(v: 2.0)
  c = "7"
  result = c.v
proc field(): float =
  let b = (c: Celsius(v: 1.0), n: 2)
  result = b.c.v
proc harmless(c: Celsius): float =
  result = c + 1.0
proc plain(x: int): int =
  result = x + 1
"""

suite "converters in exception hints":
  test "a converter that raises, applied unwritten, counted":
    if lib.len == 0: skip()
    else:
      let f = fixture(ConvSrc)
      proc list(name: string): string =
        for i, s in f.syms:
          if s.name == name and s.kind in NxRoutineKinds:
            let r = nxRaisesOf(NxRef(file: f, idx: int32(i)))
            if not r.known: return "?"
            var names: seq[string]
            for e in r.excs: names.add e.name
            names.sort()
            return names.join(",")
        doAssert false, name
      check list("useIt") == "ValueError"
      check list("viaVar") == "ValueError"
      check list("assigned") == "ValueError"
      check list("noConv") == ""
      check list("harmless") == ""                 # (toF raises nothing: it does not matter where it applies)
      check list("plain") == ""

  test "against the compiler's {.effects.}":
    if findExe("nim").len == 0 or lib.len == 0: skip()
    else:
      let f = fixture(ConvSrc)
      var ls = ConvSrc.split('\n')
      var want: Table[string, string]
      var ins: seq[(int, string)]
      for i, s in f.syms:
        if s.kind != nxProc or s.endLine <= s.line: continue
        let r = nxRaisesOf(NxRef(file: f, idx: int32(i)))
        if not r.known: continue
        var names: seq[string]
        for e in r.excs: names.add e.name
        names.sort()
        want[s.name] = names.join(",")
        ins.add (s.endLine, s.name)
      for k in countdown(ins.high, 0):
        ls.insert("{.hint: \"NEDEND " & ins[k][1] & "\".}", ins[k][0] + 1)
        ls.insert("  {.effects.}", ins[k][0] + 1)
      let p = dir / "conveffects.nim"
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
        if what.endsWith("Effect"): continue
        if what notin cur: cur.add what
      check want.len >= 6
      for k, v in want:
        check got.getOrDefault(k, "missing") == v

# ── concepts ──

const ConceptSrc = """
type
  Shape = concept
    proc area(s: Self): float
    proc name(s: Self): string
  Stack = concept
    proc push(s: var Self, x: int)
    proc pop(s: var Self): int
  Scaled = concept
    proc scale(x: Self, by: float): Self
  OldShape = concept s
    s.area is float
  OldLen = concept x
    x.len is int
  Circle = object
    r: float
  Square = object
    side: float
  IntStack = object
    data: seq[int]
  Vec = object
    x, y: float
  Base = object of RootObj
  Kid = object of Base

proc area(c: Circle): float = 3.14 * c.r * c.r
proc name(c: Circle): string = "circle"
proc area(s: Square): float = s.side * s.side
proc push(s: var IntStack, x: int) = s.data.add x
proc pop(s: var IntStack): int = s.data.pop
proc scale(v: Vec, by: float): Vec = Vec(x: v.x * by, y: v.y * by)
proc area(b: Base): float = 1.0
"""

suite "concepts":
  let f = fixture(ConceptSrc)
  let sc = nxScope(f)
  proc cpt(name: string): NxConcept =
    for i, s in f.syms:
      if s.name == name and s.kind == nxType: return nxConceptOf(NxRef(file: f, idx: int32(i)))
    doAssert false, name

  test "the new syntax: routines on Self":
    if lib.len == 0: skip()
    else:
      check cpt("Shape").known and cpt("Shape").newStyle
      check nxSatisfies(cpt("Shape"), sc, "Circle") == nsYes
      check nxSatisfies(cpt("Shape"), sc, "Square") == nsNo        # (no name)
      check nxSatisfies(cpt("Stack"), sc, "IntStack") == nsYes
      check nxSatisfies(cpt("Stack"), sc, "Circle") == nsNo
      check nxSatisfies(cpt("Scaled"), sc, "Vec") == nsYes
      check nxSatisfies(cpt("Scaled"), sc, "Circle") == nsNo

  test "the old syntax: x.f is T, f(x), a type derived from one that has it":
    if lib.len == 0: skip()
    else:
      check not cpt("OldShape").newStyle
      check nxSatisfies(cpt("OldShape"), sc, "Circle") == nsYes
      check nxSatisfies(cpt("OldShape"), sc, "Kid") == nsYes
      check nxSatisfies(cpt("OldShape"), sc, "Vec") == nsNo
      check nxSatisfies(cpt("OldLen"), sc, "string") == nsYes
      check nxSatisfies(cpt("OldLen"), sc, "seq[int]") == nsYes

  test "which types satisfy it, which it satisfies, the hover":
    if lib.len == 0: skip()
    else:
      var shape, circle: NxRef
      for i, s in f.syms:
        if s.name == "Shape" and s.kind == nxType: shape = NxRef(file: f, idx: int32(i))
        if s.name == "Circle" and s.kind == nxType: circle = NxRef(file: f, idx: int32(i))
      let (yes, _, _, cut) = nxConceptImpls(shape, @[f.path], f)
      check not cut
      var names: seq[string]
      for (nm, _) in yes: names.add nm
      check names == @["Circle"]
      var cs: seq[string]
      for c in nxConceptsOf(circle, f): cs.add c.sym.name
      cs.sort()
      check cs == @["OldShape", "Shape"]
      check nxConceptHover(shape, @[f.path], f) == "**satisfied by:** `Circle`"
      check "`Shape`" in nxConceptHover(circle, @[f.path], f)

suite "concepts (against the compiler's `T is C`)":
  test "every answer the engine is sure of":
    if findExe("nim").len == 0 or lib.len == 0: skip()
    else:
      let f = fixture(ConceptSrc)
      let sc = nxScope(f)
      var text = ConceptSrc & "\n"
      var asks: seq[(string, string, NxSat)]
      for i, s in f.syms:
        if not nxIsConcept(s): continue
        let c = nxConceptOf(NxRef(file: f, idx: int32(i)))
        for t in ["Circle", "Square", "IntStack", "Vec", "Base", "Kid", "int", "string", "seq[int]"]:
          let r = nxSatisfies(c, sc, t)
          if r == nsUnsure: continue
          asks.add (t, s.name, r)
          text.add "static: echo \"NEDCPT " & $(asks.len - 1) & " \", " & t & " is " & s.name & "\n"
      check asks.len >= 30
      let p = dir / "conceptcheck.nim"
      writeFile(p, text)
      let (outp, _) = execCmdEx("nim check --hints:off --warnings:off --colors:off " & quoteShell(p))
      var got: Table[int, bool]
      for l in outp.splitLines:
        if l.startsWith("NEDCPT "):
          let parts = l.splitWhitespace
          got[parseInt(parts[1])] = parts[2] == "true"
      for k, (t, c, r) in asks:
        check k in got
        if k in got and got[k] != (r == nsYes): echo "  differ: ", t, " is ", c, " — compiler ", got[k], ", engine ", r
        check got.getOrDefault(k) == (r == nsYes)

removeDir(dir)
