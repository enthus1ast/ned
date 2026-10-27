## The Nim index's references and overloads (6.32), and the bigger refactorings worked out from it: object ⇄ ref
## object, a module split, callback → async, a call's syntax. Each refactoring is a plan of edits, checked here on
## small files. Run: nim r tests/unit/treshape.nim (nim on PATH)

import std/[os, strutils, unittest, sequtils]
import ../../src/ned/nim/index

proc realOf(p: string): string =
  result = p
  try:
    if symlinkExists(p): result = expandFilename(p)
  except OSError: discard

proc nimLib(): string =
  let nim = findExe("nim")
  doAssert nim.len > 0, "put nim on PATH"
  let prefix = nim.realOf.parentDir.parentDir
  for cand in [prefix / "lib", prefix / "lib" / "nim", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand
  doAssert false, "no standard library found near " & nim

nxInitDefines()
nxSetToolchain(nimLib(), @[], @[])

let dir = getTempDir() / ("ned_treshape_" & $getCurrentProcessId())
createDir(dir)
var n = 0

proc fixture(text: string, name = ""): (NxFile, seq[string]) =
  ## a file of its own for each case (the index caches by path and stamp)
  inc n
  let p = dir / (if name.len > 0: name else: "f" & $n & ".nim")
  writeFile(p, text)
  (nxLoad(p), text.split('\n'))

proc colOf(ls: seq[string], line: int, word: string, nth = 0): int =
  var k = -1
  for _ in 0 .. nth: k = ls[line].find(word, k + 1)
  doAssert k >= 0, word & " not on line " & $line
  k

proc targetsAt(f: NxFile, ls: seq[string], line: int, word: string, nth = 0): seq[string] =
  ## where the name at the place is declared: "file:line" (1-based) of each target
  let (rs, lc, _) = nxTargets(f, ls, line, colOf(ls, line, word, nth))
  for r in rs: result.add extractFilename(r.file.path) & ":" & $(r.sym.line + 1)
  for l in lc: result.add "local:" & $(l.line + 1)

proc applied(plan: NxPlan, path: string): seq[string] =
  ## the file as the plan leaves it
  let before = if fileExists(path): readFile(path).split('\n') else: @[]
  nxApplyEdits(before, plan.edits.filterIt(it.path == path))

proc notesText(plan: NxPlan): string =
  for x in plan.notes: result.add $(x.line + 1) & ": " & x.why & "\n"

suite "references and overloads (6.32)":
  test "0..s.len: the receiver of .len is s, not the range":
    let (f, ls) = fixture("let s = \"abc\"\nlet r = 0..s.len - 1\n")
    check targetsAt(f, ls, 1, "len") == @["system.nim:" & $(targetsAt(f, ls, 1, "len")[0].split(':')[1])]
    let t = targetsAt(f, ls, 1, "len")
    check t.len == 1
    # (the string's len, not the one of a slice)
    let lsys = nxFileLines(nimLib() / "system.nim")
    check "x: string" in lsys[parseInt(t[0].split(':')[1]) - 1]

  test "a label of a tuple constructor names nothing in scope":
    let (f, ls) = fixture("let s = \"abc\"\necho $(slice: 1, len: s.len)\n")
    check targetsAt(f, ls, 1, "len") == newSeq[string]()
    check targetsAt(f, ls, 1, "len", 1).len == 1

  test "a let is not visible in its own value over several lines":
    let (f, ls) = fixture("proc p(value: string): string =\n  var value =\n    if value.len > 0: value\n" &
                          "    else: \"x\"\n  result = value\n")
    check targetsAt(f, ls, 2, "value") == @["local:1"]
    check targetsAt(f, ls, 4, "value") == @["local:2"]

  test "a type as an argument picks the typedesc overload":
    let (f, ls) = fixture("let xs = @[1, 2]\nlet a = high(int64)\nlet b = high(xs)\nlet c = int.high\n")
    let lsys = nxFileLines(nimLib() / "system.nim")
    let ta = targetsAt(f, ls, 1, "high")
    check ta.len == 1 and "typedesc" in lsys[parseInt(ta[0].split(':')[1]) - 1]
    let tb = targetsAt(f, ls, 2, "high")
    check tb.len == 1 and "openArray" in lsys[parseInt(tb[0].split(':')[1]) - 1]
    let tc = targetsAt(f, ls, 3, "high")
    check tc.len == 1 and "typedesc" in lsys[parseInt(tc[0].split(':')[1]) - 1]

  test "a declaration below is not seen above it; the number of arguments decides":
    let (f, ls) = fixture("type U = enum uA, uB\ntype R = range[uA..uB]\nproc conv(a, b: R, q: int): int = q\n" &
                          "let x = conv(uA, uB, 3)\ntemplate conv(d: string, u: R): int = 1\nlet y = \"s\".conv(uB)\n")
    check targetsAt(f, ls, 3, "conv") == @[extractFilename(f.path) & ":3"]
    check targetsAt(f, ls, 5, "conv") == @[extractFilename(f.path) & ":5"]

  test "a parameter whose default is a constant does not rule its overload out":
    let (f, ls) = fixture("const Sep = '/'\ntype Pth = distinct string\n" &
                          "proc rel(path, base: string, sep = Sep): string = path\n" &
                          "proc rel(path, base: Pth, sep = Sep): Pth =\n  Pth(rel(path.string, base.string, sep))\n")
    check targetsAt(f, ls, 4, "rel") == @[extractFilename(f.path) & ":3"]

  test "result.add $x, n.expectKind {a, b}: command arguments after a dot pick the overload":
    let (f, ls) = fixture("proc put(s: var string, c: char) = discard\nproc put(s: var string, t: string) = discard\n" &
                          "proc p(): string =\n  result.put $3\n  result.put 'c'\n")
    check targetsAt(f, ls, 3, "put") == @[extractFilename(f.path) & ":2"]
    check targetsAt(f, ls, 4, "put") == @[extractFilename(f.path) & ":1"]

  test "a field of the tuple a routine returns: its declaration is one of its references":
    let (f, ls) = fixture("proc iso(): tuple[week: int, year: int] = (1, 2)\nlet w = iso().week\necho iso().week\n")
    let (rs, _, _) = nxTargets(f, ls, 1, colOf(ls, 1, "week"))
    check rs.len == 1
    let hits = nxReferencesIn(rs[0], @[f.path])
    check hits.len == 3
    check (f.path, 0, colOf(ls, 0, "week")) in hits and (f.path, 2, colOf(ls, 2, "week")) in hits

  test "a when branch whose header is a multi-line string: the branch after it is left out":
    let (f, ls) = fixture("when defined(linux):\n  proc mm(a: pointer) {.importc, header: \"\"\"#ifndef X\n" &
                          "#define X\n#endif\"\"\".}\nelif defined(windows):\n  proc mm(a: pointer) {.importc.}\n")
    check (5, 5) in nxInactiveWhen(f, ls)

  test "a name that starts with block is a name (blockExpr), not a block:":
    let (f, ls) = fixture("import std/macros\nproc impl(n: NimNode): NimNode =\n  var blockExpr = newNimNode(nnkBlockExpr)\n" &
                          "  blockExpr.add(newEmptyNode())\n  result = blockExpr\n")
    let t = targetsAt(f, ls, 3, "add")
    check t.len == 1 and t[0].startsWith("macros.nim:")

  test "when: tuples compared, and an or that an unknown defined() does not stop":
    let (f, ls) = fixture("when (NimMajor, NimMinor) <= (1, 0):\n  let a = 1\nelse:\n  let a = 2\n" &
                          "when defined(neverHeardOf) or true:\n  let b = 1\nelse:\n  let b = 2\n")
    let ina = nxInactiveWhen(f, ls)
    check (1, 1) in ina and (7, 7) in ina

  test "a forward declaration is a reference of the routine it announces":
    let (f, ls) = fixture("proc fw(x: int): int\nproc user(): int = fw(1)\nproc fw(x: int): int = x\n")
    let (rs, _, _) = nxTargets(f, ls, 2, colOf(ls, 2, "fw"))
    check rs.len == 1
    let hits = nxReferencesIn(rs[0], @[f.path])
    check hits.len == 3 and (f.path, 0, colOf(ls, 0, "fw")) in hits

  test "a let in a condition: seen after its ; and in the body":
    let (f, ls) = fixture("proc p(s: string): int =\n  if (let i = s.find('a'); i >= 0):\n    result = i\n")
    check targetsAt(f, ls, 1, "i", 1) == @["local:2"]
    check targetsAt(f, ls, 2, "i") == @["local:2"]

  test "add s, x and if c: add s, x — a command call's arguments pick the overload; a >= is no named argument":
    let (f, ls) = fixture("proc put(s: var string, c: char) = discard\nproc put(s: var string, t: string) = discard\n" &
                          "proc p(x: int): string =\n  put result, 'c'\n  if x > 0: put result, \"s\"\n" &
                          "  result.put if x >= 0: 'a' else: 'b'\n")
    let me = extractFilename(f.path)
    check targetsAt(f, ls, 3, "put") == @[me & ":1"]
    check targetsAt(f, ls, 4, "put") == @[me & ":2"]
    check targetsAt(f, ls, 5, "put") == @[me & ":1"]

  test "a pragma the compiler knows is no type: {.importc, varargs.}":
    let (f, ls) = fixture("proc printf(f: cstring) {.importc,\n  varargs, header: \"<stdio.h>\".}\n")
    check targetsAt(f, ls, 1, "varargs").len == 0

  test "a module's own type hides an imported one of the same name":
    let (f, ls) = fixture("import std/times as tm\ntype Duration = object\n  x: int\nproc z(d: Duration) = discard\n")
    check targetsAt(f, ls, 3, "Duration") == @[extractFilename(f.path) & ":2"]

suite "refactor: object ⇄ ref object":
  test "object → ref object: var defaults get a constructor, result one too; == and copies listed":
    let (f, ls) = fixture("type\n  P = object\n    x: int\n  Holder = object\n    p: P\n\n" &
                          "proc make(): P =\n  ## makes one\n  result.x = 1\n\n" &
                          "proc same(a, b: P): bool = a == b\n\nvar g: P\n" &
                          "proc use() =\n  var q: P\n  q.x = 2\n  let r = q\n  echo r.x, P(x: 3).x\n")
    let plan = nxPlanRefObject(f, ls, 1, colOf(ls, 1, "P"), @[f.path])
    check plan.ok
    let after = plan.applied(f.path)
    check after[1] == "  P = ref object"
    check after[7 .. 9] == @["  ## makes one", "  result = P()", "  result.x = 1"]
    check "var g = P()" in after
    check "  var q = P()" in after
    check "  echo r.x, P(x: 3).x" in after             # (a constructor stays)
    let notes = plan.notesText
    check "the field p starts as nil" in notes
    check "== compares which object it is" in notes
    check "the same object as q" in notes

  test "ref object → object: new(x) becomes x = T(), nil checks listed":
    let (f, ls) = fixture("type R = ref object\n  v: int\n\nproc mk(): R =\n  new(result)\n  result.v = 2\n\n" &
                          "proc chk(r: R): bool = r.isNil or r == nil\nlet q = new(R)\n")
    let plan = nxPlanRefObject(f, ls, 0, colOf(ls, 0, "R"), @[f.path])
    check plan.ok
    let after = plan.applied(f.path)
    check after[0] == "type R = object"
    check after[4] == "  result = R()"
    check after[8] == "let q = R()"
    let notes = plan.notesText
    check "isNil no longer compiles" in notes
    check "== nil no longer compiles" in notes

  test "a ref object that holds itself stays one":
    let (f, ls) = fixture("type Node = ref object\n  next: Node\n  v: int\n")
    let plan = nxPlanRefObject(f, ls, 0, colOf(ls, 0, "Node"), @[f.path])
    check not plan.ok
    check "infinitely large" in plan.msg

  test "the uses in another module of the project":
    let (fa, la) = fixture("type Pt* = object\n  x*: int\n", "pta.nim")
    let (fb, lb) = fixture("import pta\nproc z*(): int =\n  var p: Pt\n  p.x\n", "ptb.nim")
    discard fb
    discard lb
    let plan = nxPlanRefObject(fa, la, 0, colOf(la, 0, "Pt"), @[fa.path, dir / "ptb.nim"])
    check plan.ok
    check plan.applied(dir / "ptb.nim")[2] == "  var p = Pt()"

suite "refactor: split a module":
  test "the selected procs into a new module, imports both ways, what the old one still uses exported":
    let src = "import std/strutils\n\nproc helper(s: string): string =\n  s.toUpperAscii\n\n" &
              "proc shout*(s: string): string = helper(s) & \"!\"\n\nproc main*() =\n  echo helper(\"a\"), shout(\"b\")\n"
    let (f, ls) = fixture(src, "big.nim")
    let target = dir / "small.nim"
    let plan = nxPlanSplit(f, ls, 2, 5, target, @[f.path])
    check plan.ok
    check target in plan.creates
    let newText = plan.applied(target).join("\n")
    check "import std/strutils" in newText
    check "proc helper*(s: string): string =" in newText     # (the old module still calls it)
    check "proc shout*(s: string)" in newText
    let old = plan.applied(f.path)
    check "import small" in old
    check "export shout" in old                              # (it was public: the old module keeps offering it)
    check old.filterIt(it.startsWith("proc helper")).len == 0
    check "proc main*() =" in old

  test "code that uses what stays behind is not moved":
    let (f, ls) = fixture("proc a(): int = 1\nproc b(): int = a() + 1\n")
    let plan = nxPlanSplit(f, ls, 1, 1, dir / "other1.nim", @[f.path])
    check not plan.ok
    check "would import each other" in plan.msg

  test "members of a type section get a section of their own":
    let (f, ls) = fixture("type\n  A* = object\n    x: int\n  B* = object\n    y: int\n\nproc useA*(a: A): int = 1\n")
    let target = dir / "bmod.nim"
    let plan = nxPlanSplit(f, ls, 3, 4, target, @[f.path])
    check plan.ok
    check plan.applied(target)[0 .. 2] == @["type", "  B* = object", "    y: int"]
    let old = plan.applied(f.path)
    check "  A* = object" in old and old.filterIt("B* =" in it).len == 0

suite "refactor: callback → async":
  test "the proc returns a Future, its callback's call a return; async callers await it":
    let src = "import std/asyncdispatch\n\nproc fetch(url: string, cb: proc (r: string)) =\n" &
              "  let data = url & \"!\"\n  cb(data)\n\nproc user() {.async.} =\n" &
              "  fetch(\"a\", proc (r: string) =\n    echo r\n    echo \"done\")\n" &
              "  fetch(\"b\") do (s: string):\n    echo s\n\nproc plain() =\n  fetch(\"c\", proc (r: string) = echo r)\n"
    let (f, ls) = fixture(src)
    let plan = nxPlanAsync(f, ls, 2, colOf(ls, 2, "fetch"), @[f.path])
    check plan.ok
    let after = plan.applied(f.path)
    check after[2] == "proc fetch(url: string): Future[string] {.async.} ="
    check after[4] == "  return data"
    check "  let r = await fetch(\"a\")" in after
    check "    echo \"done\"" notin after and "  echo \"done\"" in after
    check "  let s = await fetch(\"b\")" in after
    check "  fetch(\"c\", proc (r: string) = echo r)" in after    # (not async: left, and listed)
    check "plain is not {.async.}" in plan.notesText

  test "a named callback gets the awaited value; a pragma list gets async":
    let src = "import std/asyncdispatch\n\nproc get(n: int, done: proc (v: int) {.closure.}) {.gcsafe.} =\n" &
              "  done(n * 2)\n\nproc show(v: int) = echo v\n\nproc run() {.async.} =\n  get(3, show)\n"
    let (f, ls) = fixture(src)
    let plan = nxPlanAsync(f, ls, 2, colOf(ls, 2, "get"), @[f.path])
    check plan.ok
    let after = plan.applied(f.path)
    check after[2] == "proc get(n: int): Future[int] {.gcsafe, async.} ="
    check after[3] == "  return n * 2"
    check "  show(await get(3))" in after

  test "a callback called in a loop is listed: return ends the proc there":
    let src = "proc each(xs: seq[int], cb: proc (x: int)) =\n  for x in xs:\n    cb(x)\n"
    let (f, ls) = fixture(src)
    let plan = nxPlanAsync(f, ls, 0, colOf(ls, 0, "each"), @[f.path])
    check plan.ok
    check "returns here now" in plan.notesText
    check "import std/asyncdispatch" in plan.applied(f.path)

  test "a proc without a callback is not changed":
    let (f, ls) = fixture("proc plain(x: int): int = x\n")
    check not nxPlanAsync(f, ls, 0, colOf(ls, 0, "plain"), @[f.path]).ok

suite "refactor: a call's syntax":
  let src = "type O = object\n  h: int\nproc f(a, b: int): int = a + b\nproc g(a: int): int = a\n" &
            "proc h(a: O, b: int): int = b\nlet x = f(1, 2)\necho f(g(3), 4)\ndiscard 5.f(6)\nlet o = O(h: 1)\n" &
            "let y = h(o, 2)\ndiscard g(7)\n"

  test "at the cursor: f(x, y) → x.f(y) → f x, y (a statement only) → f(x, y)":
    let (f, ls) = fixture(src)
    let p1 = nxPlanCallSyntax(f, ls, f.path, 5, 5, colOf(ls, 5, "f"))
    check p1.ok and p1.applied(f.path)[5] == "let x = 1.f(2)"
    # (after discard, two arguments: no command syntax — back to f(x, y))
    let p2 = nxPlanCallSyntax(f, ls, f.path, 7, 7, colOf(ls, 7, "f"))
    check p2.ok and p2.applied(f.path)[7] == "discard f(5, 6)"
    let p3 = nxPlanCallSyntax(f, ls, f.path, 10, 10, colOf(ls, 10, "g"))
    check p3.ok and p3.applied(f.path)[10] == "discard 7.g()"
    let (f4, ls4) = fixture("proc g(a: int): int = a\ndiscard 7.g()\n")
    let p4 = nxPlanCallSyntax(f4, ls4, f4.path, 1, 1, colOf(ls4, 1, "g"))
    check p4.ok and p4.applied(f4.path)[1] == "discard g 7"

  test "a whole selection in one form, inner calls too":
    let (f, ls) = fixture(src)
    let p = nxPlanCallSyntax(f, ls, f.path, 5, 7, 0, ord(cfMethod))
    check p.ok
    let after = p.applied(f.path)
    check after[5] == "let x = 1.f(2)"
    check after[6] == "3.g().f(4).echo()"
    let back = nxPlanCallSyntax(f, ls, f.path, 7, 7, 0, ord(cfPlain))
    check back.applied(f.path)[7] == "discard f(5, 6)"

  test "x.f would reach a field of x: not written that way":
    let (f, ls) = fixture(src)
    let p = nxPlanCallSyntax(f, ls, f.path, 9, 9, colOf(ls, 9, "h"))
    check not p.ok
    let p2 = nxPlanCallSyntax(f, ls, f.path, 9, 9, 0, ord(cfMethod))
    check not p2.ok

  test "the edits of a plan, made bottom up":
    check nxApplyEdits(@["abc", "def"], @[NxEdit(path: "x", line: 0, col: 1, endLine: 1, endCol: 1, text: "-"),
                                           NxEdit(path: "x", line: 1, col: 2, endLine: 1, endCol: 3, text: "!")]) ==
          @["a-e!"]

removeDir(dir)
