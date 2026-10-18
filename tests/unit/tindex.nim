## The Nim index on its own, without the editor: declarations, completion, definitions, types, hover,
## template expansion, operators and misspelled names. Run: nim r tests/unit/tindex.nim (nim on PATH)

import std/[os, strutils, unittest, sequtils]
import ../../src/ned/nim/index

proc realOf(p: string): string =
  result = p
  try:
    if symlinkExists(p): result = expandFilename(p)
  except OSError: discard

proc nimLib(): string =
  ## the standard library next to the `nim` on PATH (<prefix>/bin/nim → <prefix>/lib)
  let nim = findExe("nim")
  doAssert nim.len > 0, "put nim on PATH"
  let prefix = nim.realOf.parentDir.parentDir
  for cand in [prefix / "lib", prefix / "lib" / "nim", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand
  doAssert false, "no standard library found near " & nim

nxInitDefines()
nxSetToolchain(nimLib(), @[], @[])

let dir = getTempDir() / ("ned_tindex_" & $getCurrentProcessId())
createDir(dir)
var n = 0

proc fixture(text: string): (NxFile, seq[string]) =
  ## a file of its own for each case (the index caches by path and stamp)
  inc n
  let p = dir / ("f" & $n & ".nim")
  writeFile(p, text)
  (nxLoad(p), text.split('\n'))

proc colOf(ls: seq[string], line: int, word: string, nth = 0): int =
  var k = -1
  for _ in 0 .. nth: k = ls[line].find(word, k + 1)
  doAssert k >= 0, word & " not on line " & $line
  k

proc labels(c: NxCompletion): seq[string] = c.items.mapIt(it.label)

suite "declarations":
  test "routines, types, fields, enum values, constants":
    let (f, _) = fixture("type\n  Color* = enum red, green\n  P = object\n    name*: string\n    age: int\n" &
                         "const Limit = 10\nproc greet*(p: P): string = p.name\n")
    var seen: seq[string]
    for s in f.syms: seen.add $s.kind & " " & s.name
    check "nxType Color" in seen
    check "nxEnumVal green" in seen
    check "nxField name" in seen
    check "nxConst Limit" in seen
    check "nxProc greet" in seen
    check f.syms.filterIt(it.name == "greet")[0].exported

suite "completion":
  test "the fields and procs of a value, after a dot":
    let (f, ls) = fixture("type P = object\n  name: string\n  age: int\nproc greet(p: P): string = p.name\n" &
                          "let p = P(name: \"x\")\necho p.\n")
    let c = nxComplete(f, ls, 5, ls[5].len)
    check c.member
    check "name" in c.labels and "age" in c.labels and "greet" in c.labels

  test "the standard library, through an import":
    let (f, ls) = fixture("import std/strutils\nlet s = \"abc\"\necho s.toUpp\n")
    let c = nxComplete(f, ls, 2, ls[2].len)
    check "toUpperAscii" in c.labels

  test "a type declared inside a routine: its fields after a dot":
    let (f, ls) = fixture("proc main() =\n  type Date = tuple[year, month: int]\n  type P = object\n    name: string\n" &
                          "  var d: Date = (1, 2)\n  var p = P(name: \"x\")\n  echo d.\n  echo p.\n")
    check "month" in nxComplete(f, ls, 6, ls[6].len).labels
    check "name" in nxComplete(f, ls, 7, ls[7].len).labels

  test "… and not offered by name in another routine, nor in the outline's module-level names":
    let (f, ls) = fixture("proc a() =\n  type Local = object\n    x: int\n  discard\nproc b() =\n  let v = Lo\n")
    check "Local" notin nxComplete(f, ls, 5, ls[5].len).labels
    check f.syms.filterIt(it.name == "Local")[0].local

  test "a receiver that starts on an earlier line":
    let (f, ls) = fixture("import std/tables\nlet t = {\"a\": 1,\n  \"b\": 2}.\n")
    check "toTable" in nxComplete(f, ls, 2, ls[2].len).labels

  test "two number types: the wider one; an integer converts to an enum":
    let (f, ls) = fixture("type Color = enum red, green\nlet u: uint8 = 3\nlet w = (u * 2'u32).\nlet i = 1\necho i.\n")
    let c = nxComplete(f, ls, 2, ls[2].len)
    check c.receiverType == "uint32"
    check "uint8" in c.labels
    check "Color" in nxComplete(f, ls, 4, ls[4].len).labels

  test "a routine declared inside this one, called with a dot":
    let (f, ls) = fixture("proc outer() =\n  proc addQ(s: var seq[int], x: int) =\n    s.add x\n  var s: seq[int]\n" &
                          "  s.\n  s.addQ(3)\n")
    check "addQ" in nxComplete(f, ls, 4, ls[4].len).labels
    let d = nxDefinition(f, ls, 5, colOf(ls, 5, "addQ"))
    check d.len == 1 and d[0][1] == 1

suite "definitions and types":
  test "go to definition of a proc":
    let (f, ls) = fixture("proc twice(x: int): int = x * 2\necho twice(3)\n")
    let d = nxDefinition(f, ls, 1, colOf(ls, 1, "twice"))
    check d.len == 1 and d[0][1] == 0

  test "the type of a let written without one":
    let (f, ls) = fixture("import std/tables\nlet t = initTable[string, int]()\nlet v = t.getOrDefault(\"a\")\n")
    let sc = nxScope(f)
    check nxTypeOfExpr(f, sc, @[], "t", 1, 0).typ == "Table[string, int]"
    check nxTypeOfExpr(f, sc, @[], "t.getOrDefault(\"a\")", 2, 0).typ == "int"

  test "hover shows the signature":
    let (f, ls) = fixture("proc shout*(s: string): string =\n  ## louder\n  s & \"!\"\necho shout(\"a\")\n")
    let h = nxHover(f, ls, 3, colOf(ls, 3, "shout"))
    check "proc shout*(s: string): string" in h or "proc shout(s: string): string" in h
    check "louder" in h

  test "an operator's overload, by the types of its operands":
    let (f, ls) = fixture("type V = object\n  x: float\nproc `+`(a, b: V): V = V(x: a.x + b.x)\n" &
                          "let v = V(x: 1) + V(x: 2)\nlet n = 1 + 2\n")
    let d = nxDefinition(f, ls, 3, colOf(ls, 3, "+"))
    check d.len == 1 and d[0][1] == 2
    check nxDefinition(f, ls, 4, colOf(ls, 4, "+")).allIt(it[1] != 2)

  test "a field named in a constructor is the field, not a variable of that name":
    let (f, ls) = fixture("type V = object\n  x: float\nlet x = 3\nlet v = V(x: 1)\n")
    let d = nxDefinition(f, ls, 3, colOf(ls, 3, "x"))
    check d.len == 1 and d[0][1] == 1

  test "a forward declaration in one included file, its body in another: one routine, not two overloads":
    let m = dir / ("inc" & $getCurrentProcessId())
    createDir(m)
    writeFile(m / "fwd.nim", "proc twice(x: int): int\n")
    writeFile(m / "body.nim", "proc twice(x: int): int =\n  ## doubles it\n  x * 2\n")
    let text = "include fwd\ninclude body\necho twice(2)\n"
    writeFile(m / "app.nim", text)
    let ls = text.split('\n')
    let h = nxHover(nxLoad(m / "app.nim"), ls, 2, colOf(ls, 2, "twice"))
    check "doubles it" in h
    check "overloads" notin h

  test "typedesc receivers, numbers next to other types, newException, @(…)":
    let (f, ls) = fixture("type Color = enum red, green\nlet q: int32 = 3\nlet z = 0\n")
    let sc = nxScope(f)
    template ty(e: string): string = nxTypeOfExpr(f, sc, @[], e, 2, 0).typ
    check ty("float32.high") == "float32"
    check ty("Color.low") == "Color"
    check ty("high(int8)") == "int8"
    check ty("1 / q.float32") == "float32"
    check ty("0 ..< q") == "HSlice[int32, int32]"
    check ty("newException(ValueError, \"x\")") == "ref ValueError"
    check ty("@({\"a\": \"b\"})") == "seq[(string, string)]"

suite "expansion and misspelled names":
  test "a template call, written out":
    let (f, ls) = fixture("template sq(x: untyped): untyped = x * x\necho sq(3 + 1)\n")
    let (name, text) = nxExpandTemplate(f, ls, 1, colOf(ls, 1, "sq"))
    check name.startsWith("sq")
    check "(3 + 1) * (3 + 1)" in text

  test "a name one letter away from a declared one (inside a routine)":
    let (f, ls) = fixture("proc total(xs: seq[int]): int =\n  for x in xs: result += x\n" &
                          "proc main() =\n  echo toal(@[1])\n")
    let ts = nxTypos(f, ls, 0, ls.high, (-1, -1))
    check ts.len == 1 and ts[0][2] == "toal" and "total" in ts[0][3]

suite "compile-time values":
  let (f, ls) = fixture("type Level = enum low, mid = 5, high\nconst K = 1 shl 10\nconst Mask = 0xFF and not 0x0F\n" &
                        "const Name = \"ned\"\nconst Big = K * K * 4 + 3 div 2\nconst Hi = high(int8)\n" &
                        "const Up = Name.toUpperAscii & $K\nconst IsWin = defined(windows)\nconst Top = high(Level)\n" &
                        "when defined(linux) and K > 1000:\n  discard\n")
  proc ev(e: string): string = nxCtRender(nxCtEval(f, e))
  test "numbers: shl, and, not, div, constants in constants":
    check ev("K") == "1024"
    check ev("Mask") == "240"
    check ev("Big") == "4194305"
    check ev("0b1010 + 0o17 + 0x10") == "41"
    check ev("7 / 2") == "3.5"
    check ev("-3 * 2 + 1") == "-5"
  test "strings, chars, len, $, toUpperAscii":
    check ev("Up") == "\"NED1024\""
    check ev("Name.len") == "3"
    check ev("ord('a') + 1") == "98"
    check ev("chr(66)") == "'B'"
    check ev("Name[0]") == "'n'"
  test "high, low, sizeof; enum values and their ordinals":
    check ev("Hi") == "127"
    check ev("low(int16)") == "-32768"
    check ev("high(uint64)") == "18446744073709551615"
    check ev("sizeof(int32)") == "4"
    check ev("Top") == "high"
    check ev("ord(high)") == "6"
    check ev("mid < high") == "true"
  test "defined() for this platform, comparisons, and / or / not":
    check ev("IsWin") == "false"
    check ev("defined(linux) and not defined(windows)") == (when defined(linux): "true" else: "false")
    check ev("K >= 1024 and Name == \"ned\"") == "true"
  test "what it cannot tell, it does not guess":
    check ev("someVar + 1") == ""
    check ev("f(3)") == ""
  test "an integer keeps its type: unsigned ones wrap, a signed overflow is the compile error it is":
    check ev("255'u8 + 1") == "0"
    check ev("not 0'u8") == "255"
    check ev("high(int8) - 1") == "126"
    check ev("1'i8 shl 7") == "-128"
    check nxCtEval(f, "high(int8) + 1").err.startsWith("over- or underflow: int8 holds -128 .. 127")
    check nxCtEval(f, "high(int) + 1").err.startsWith("over- or underflow: int")
    check nxCtEval(f, "1 div 0").err == "division by zero"
    check nxCtEval(f, "uint8(300)").err == "300 does not fit uint8 (0 .. 255)"
    check ev("int16(high(int8)) + 1") == "128"
  test "hover on a when line: the condition's value here":
    let h = nxHover(f, ls, 9, 1)
    check ("= **" & (when defined(linux): "true" else: "false") & "** here") in h

  test "the when branches left out here: dimmed; a chain followed only as far as it can be told":
    let (g, ls2) = fixture("when defined(windows):\n  proc a() = discard\n  proc b() = discard\n" &
                           "elif defined(linux) or defined(macosx) or defined(android):\n  proc c() = discard\n" &
                           "else:\n  proc d() = discard\n\nwhen isMainModule:\n  echo 1\nelse:\n  echo 2\n" &
                           "when defined(someFlag):\n  echo 3\nelif defined(windows):\n  echo 4\n")
    let r = nxInactiveWhen(g, ls2)
    check (1, 2) in r and (6, 6) in r
    check r.len == 2          # (isMainModule and someFlag: not known here, nothing dimmed)


suite "engine fixes against nimsuggest (6.8)":
  test "code in a when branch left out here: that branch's types, fields and imports":
    let (f, ls) = fixture("when defined(windows):\n  import std/winlean\n  type P = object\n    winOnly: int\n" &
                          "  proc useP(p: P, si: STARTUPINFO) =\n    echo p.\n    echo si.\nelse:\n" &
                          "  type P = object\n    posixOnly: int\nproc other(p: P) =\n  echo p.\n")
    let inWin = nxComplete(f, ls, 5, ls[5].len).labels
    check "winOnly" in inWin
    check "dwFlags" in nxComplete(f, ls, 6, ls[6].len).labels
    let outside = nxComplete(f, ls, 11, ls[11].len).labels
    check "posixOnly" in outside and "winOnly" notin outside
    check f.syms.filterIt(it.name == "useP").len == 0          # (not a declaration of the module here)

  test "a when on a constant of the file: const useWin = defined(windows) or …":
    let (f, _) = fixture("const useWin = defined(windows) or defined(nimdoc)\nwhen useWin:\n  proc a() = discard\n" &
                         "else:\n  proc b() = discard\nwhen not useWin:\n  proc c() = discard\n")
    check f.syms.filterIt(it.name == "a").len == 0
    check f.syms.filterIt(it.name == "b").len == 1 and f.syms.filterIt(it.name == "c").len == 1


  proc tyAt(f: NxFile, ls: seq[string], line: int, name: string): string =
    ## the type of a name as the code on `line` sees it
    nxTypeOfName(f, nxScope(f), nxLocals(f, ls, line, ls[line].len), name, line, 0).typ

  test "inside a macro its parameters are NimNodes (but the declaration shows what is written)":
    let (f, ls) = fixture("import std/macros\nmacro m(cf: string, n = true, k: typed{nkSym}): untyped =\n" &
                          "  echo cf\n  result = newStmtList()\n")
    check tyAt(f, ls, 2, "cf") == "NimNode" and tyAt(f, ls, 2, "n") == "NimNode" and tyAt(f, ls, 2, "k") == "NimNode"
    let (_, locs, _) = nxTargets(f, ls, 1, colOf(ls, 1, "cf"))
    check locs.len == 1 and locs[0].typ == "string"

  test "pragma completion knows {.pragma.} and {.noconv.}; cast[T](x).f() is f's result":
    let (f, ls) = fixture("proc a() {.prag\nproc b() {.noco\nlet y = cast[ptr int](nil).isNil\n")
    check "pragma" in nxComplete(f, ls, 0, ls[0].len).labels
    check "noconv" in nxComplete(f, ls, 1, ls[1].len).labels
    check nxTypeOfExpr(f, nxScope(f), @[], "cast[ptr int](nil).isNil", 2, 0).typ == "bool"

  test "`for _ in`: `_` has a type (for its hint) but is never offered":
    let (f, ls) = fixture("proc p() =\n  for _ in 0 ..< 3:\n    discard\n  let n = 1\n  echo n\n")
    check nxLocals(f, ls, 2, 0, everything = true).anyIt(it.name == "_")
    check tyAt(f, ls, 2, "_") == "int"
    check "_" notin nxComplete(f, ls, 4, 6).labels

  test "a `when` opens no scope; parameters far down a long header":
    var hdr = "proc long(\n"
    for k in 0 .. 15: hdr.add "    p" & $k & ": int,\n"
    let (f, ls) = fixture("proc f() =\n  when true:\n    var a = 1\n  echo a\n" & hdr & "    last: int) =\n  echo last\n")
    let d = nxDefinition(f, ls, 3, colOf(ls, 3, "a"))
    check d.len == 1 and d[0][1] == 2
    let d2 = nxDefinition(f, ls, ls.len - 2, colOf(ls, ls.len - 2, "last"))
    check d2.len == 1 and d2[0][1] == ls.len - 3

  test "an import's module on a continuation line; export of one symbol of a module (export a.foo)":
    let m = dir / ("exp" & $getCurrentProcessId())
    createDir(m)
    writeFile(m / "ma.nim", "proc foo*() = discard\nproc bar*() = discard\n")
    writeFile(m / "mb.nim", "import ma\nexport ma.foo\n")
    let text = "import std/[\n  strutils,\n  sequtils]\nimport mb\nfoo()\nbar()\n"
    writeFile(m / "mc.nim", text)
    let ls = text.split('\n')
    let f = nxLoad(m / "mc.nim")
    let d = nxDefinition(f, ls, 2, colOf(ls, 2, "sequtils"))
    check d.len == 1 and d[0][0].endsWith("sequtils.nim")
    check nxDefinition(f, ls, 4, 0).len == 1
    check nxDefinition(f, ls, 5, 0).len == 0

  test "T.init(…): the overload for that type; `T: type X` too":
    let (f, ls) = fixture("type A = object\ntype B = object\nproc init(T: typedesc[A]): int = 1\n" &
                          "proc init(T: type B): string = \"\"\nlet x = B.init()\nlet y = A.init()\n")
    check nxTypeOfExpr(f, nxScope(f), @[], "B.init()", 4, 0).typ == "string"
    check nxTypeOfExpr(f, nxScope(f), @[], "A.init()", 5, 0).typ == "int"

  test "an exception type of the standard library's: the fields it inherits (msg)":
    let (f, ls) = fixture("type MyErr = object of IOError\nproc f() =\n  var e: ref MyErr\n  var o: ref OSError\n" &
                          "  echo e.\n  echo o.\n")
    check "msg" in nxComplete(f, ls, 4, ls[4].len).labels
    check "msg" in nxComplete(f, ls, 5, ls[5].len).labels and "errorCode" in nxComplete(f, ls, 5, ls[5].len).labels

  test "parameters typed auto; for over an enum type; 0 ..< a cint; 1 .. a Natural":
    let (f, ls) = fixture("type C = enum ca, cb\niterator ids(xs: seq[int]): string = discard\n" &
                          "proc p(v: auto, L: int32, n: Natural) =\n  for id in ids(v): discard\n  for k in C: discard\n" &
                          "  for i in 0 ..< L: discard\n  for j in 1 .. n: discard\n")
    check tyAt(f, ls, 3, "id") == "string"
    check tyAt(f, ls, 4, "k") == "C"
    check tyAt(f, ls, 5, "i") == "int32"
    check tyAt(f, ls, 6, "j") == "int"

  test "an alias of a type in another module (Native* = m1.Request): that module's type":
    let m = dir / ("qal" & $getCurrentProcessId())
    createDir(m)
    writeFile(m / "m1.nim", "type Request* = object\n  client*: int\n")
    let text = "import m1\ntype Native* = m1.Request\ntype Request* = object\n  other*: int\nproc f(n: Native) =\n  echo n.\n"
    writeFile(m / "m2.nim", text)
    let ls = text.split('\n')
    let c = nxComplete(nxLoad(m / "m2.nim"), ls, 5, ls[5].len).labels
    check "client" in c and "other" notin c

  test "a type continued after `|`; Type\"literal\"; type(param) results; module.iterator(…)":
    let (f, ls) = fixture("type\n  S[K, V] = seq[K] |\n    array[2, V]\ntype CT = distinct string\n" &
                          "proc dir[T](at, to: T): type(to) = to\nimport std/strutils\n")
    check f.syms.filterIt(it.name == "array").len == 0
    let sc = nxScope(f)
    check nxTypeOfExpr(f, sc, @[], "CT\"x\"", 5, 0).typ == "CT"
    check nxTypeOfExpr(f, sc, @[], "dir(1.5, 2.5)", 5, 0).typ == "float"
    check nxIterVarType(f, sc, @[], "strutils.split(\"a b\")", 0, 1, 5, 0) == "string"

  test "multisync: its parameters are the synchronous ones (inside `when c is X:` that one)":
    let (f, ls) = fixture("proc h(client: int | string) {.multisync.} =\n  echo client\n  when client is string:\n" &
                          "    echo client\n")
    check tyAt(f, ls, 1, "client") == "int"
    check tyAt(f, ls, 3, "client") == "string"

  test "parameters typed with a union or a type class (V23 = V2 | V3, [S: V2 | V3], a | b)":
    let (f, ls) = fixture("type V2 = object\n  x: int\ntype V3 = object\n  y: int\ntype V23 = V2 | V3\n" &
                          "proc norm(a: V23): int = 0\nproc both(a: V2 | V3): int = 0\nproc t(v: V3) =\n  echo v.\n" &
                          "proc g[S: V2 | V3](a: S) =\n  echo a.\n")
    let c1 = nxComplete(f, ls, 8, ls[8].len).labels
    check "norm" in c1 and "both" in c1
    let c2 = nxComplete(f, ls, 10, ls[10].len).labels
    check "norm" in c2 and "x" in c2 and "y" in c2

  test "parameters of anonymous procs; types declared in a nested routine; conversions":
    let (f, ls) = fixture("proc main() =\n  let cb = proc (fut: seq[int]) =\n    echo fut\n" &
                          "  proc inner() =\n    type P = object\n      field1: int\n    var p: P\n    echo p.\n" &
                          "type RJ = distinct string\ntype WR = range[1..53]\ntype ME = openArray[int]\n" &
                          "proc q(xs: ME, r: RJ, i: int) =\n  echo r.\n  echo i.\n  echo xs.\n")
    check tyAt(f, ls, 2, "fut") == "seq[int]"
    check "field1" in nxComplete(f, ls, 7, ls[7].len).labels
    check "string" in nxComplete(f, ls, 12, ls[12].len).labels
    check "WR" in nxComplete(f, ls, 13, ls[13].len).labels
    check "items" in nxComplete(f, ls, 14, ls[14].len).labels


  test "a parameter of a proc type, a field of a tuple type: the name itself, with its type":
    let (f, ls) = fixture("type\n  Cb = proc (s: string, bufLen: int): bool\n  R = tuple[\n    code: int,\n" &
                          "    matched: bool]\nvar res: tuple[consumed: int, done: bool]\n" &
                          "proc split3(p: string): tuple[dir, name, ext: string] = discard\nlet t = split3(\"x\")\necho t.name\n")
    let (_, l1, _) = nxTargets(f, ls, 1, colOf(ls, 1, "bufLen"))
    check l1.len == 1 and l1[0].typ == "int" and l1[0].line == 1
    let (_, l2, _) = nxTargets(f, ls, 5, colOf(ls, 5, "done"))
    check l2.len == 1 and l2[0].typ == "bool"
    let d = nxDefinition(f, ls, 4, colOf(ls, 4, "matched"))
    check d.len == 1 and d[0][1] == 4                     # (on its own line of the tuple[)
    let (r3, _, _) = nxTargets(f, ls, 8, colOf(ls, 8, "name"))
    check r3.len == 1 and r3[0].sym.line == 6 and r3[0].sym.typ == "string"

  test "quote do: `x`. completes what the quoted code makes x; a use of `x` is the macro's x":
    let (f, ls) = fixture("import std/macros\ntype Params = object\n  val4req: string\n" &
                          "macro m(cf: string): untyped =\n  let apId = ident(\"ap\")\n  result = quote do:\n" &
                          "    var `apId`: Params\n    `apId`.\n    echo `apId`.val4req\n")
    check "val4req" in nxComplete(f, ls, 7, ls[7].len).labels
    let d = nxDefinition(f, ls, 8, colOf(ls, 8, "apId"))
    check d.len == 1 and d[0][1] == 4


  test "values over several lines: a call that goes on, a comment between, when chains, block: locals, long ones":
    var big = "type Cfg = object\n  a, b: int\nvar cfg = Cfg(\n"
    for k in 0 .. 30: big.add "  a: " & $k & ",\n"
    big.add "  b: 1)\n"
    let (f, ls) = fixture(big & "proc acc(x: int, p: ptr int, z: int): string = \"\"\nproc g() =\n  var n = 1\n" &
                          "  var client =\n    when declared(acc):\n      acc(1,\n          addr(n), 3)\n    else:\n" &
                          "      \"\"\n  var msg =\n    \"a is b \" &\n    # what it is\n    \"c\"\n" &
                          "  let lookup = block:\n    var res: array[3, char]\n    res\n" &
                          "  let sep =\n    when defined(windows): 1.5\n    elif defined(nimdoc): 'x'\n    else: \"/\"\n")
    let sc = nxScope(f)
    check nxTypeOfExpr(f, sc, @[], "cfg", 40, 0).typ == "Cfg"
    let last = ls.len - 2
    check tyAt(f, ls, last, "client") == "string"
    check tyAt(f, ls, last, "msg") == "string"
    check tyAt(f, ls, last, "lookup") == "array[3, char]"
    check tyAt(f, ls, last, "sep") == "string"

  test "a template's untyped parameters: what its calls pass (a block too); names bound where it is called":
    let (f, ls) = fixture("type Tab = object\n  data: seq[int]\n" &
                          "template splitCommon(s, maxsplit) =\n  var splits = maxsplit\n  echo splits\n" &
                          "template cellOf(i) = t.data[i]\n" &
                          "template loop(body: untyped) =\n  let (n, done) = body\n  echo n, done\n" &
                          "proc use(s: string, maxsplit: int, t: Tab) =\n  splitCommon(s, maxsplit)\n  echo cellOf(0)\n" &
                          "  loop:\n    let k = 1.5\n    (k, true)\n" &
                          "proc dump(x: int) =\n  template doCopy() =\n    echo copyStart\n  var copyStart = \"\"\n  doCopy()\n" &
                          "const names = [\"doCopy\", \"cellOf\"]\n")
    check tyAt(f, ls, 4, "splits") == "int"
    check tyAt(f, ls, 5, "t") == "Tab"
    check "data" in nxComplete(f, ls, 5, colOf(ls, 5, "data")).labels
    check tyAt(f, ls, 8, "n") == "float" and tyAt(f, ls, 8, "done") == "bool"
    check tyAt(f, ls, 17, "copyStart") == "string"
    let d = nxDefinition(f, ls, 17, colOf(ls, 17, "copyStart"))
    check d.len == 1 and d[0][1] == 18

  test "what a template declares for its arguments: withData(s, fd, value) do: value is ptr T":
    let (f, ls) = fixture("type\n  Key[T] = object\n    data: T\n  Sel[T] = ref object\n    fds: seq[Key[T]]\n" &
                          "  Ad = object\n    readList: seq[int]\n" &
                          "template withData[T](s: Sel[T], fd: int, value, body: untyped) =\n  let fdi = fd\n" &
                          "  var value = addr(s.fds[fdi].data)\n  body\n" &
                          "proc p(sel: Sel[Ad]) =\n  withData(sel, 3, adata) do:\n    echo adata.\n")
    check tyAt(f, ls, 13, "adata") == "ptr Ad"
    check "readList" in nxComplete(f, ls, 13, ls[13].len).labels

  test "for i, (a, b) in …; a for header that goes on below; an iterator declared in the routine":
    let (f, ls) = fixture("type Seg = object\n  y: int\nproc p(segs: seq[(Seg, int16)]) =\n" &
                          "  iterator parts(s: Seg, n: int): uint32 = discard\n" &
                          "  for i, (seg, w) in segs:\n    for k in seg.parts(\n      3\n    ):\n      echo k\n")
    check tyAt(f, ls, 5, "seg") == "Seg" and tyAt(f, ls, 5, "w") == "int16"
    check tyAt(f, ls, 8, "k") == "uint32"

  test "an array's index: range 1..3(M) for array[mA..mC, T], range 0..3(int) for array[4, T]; m[2, 0]":
    let (f, ls) = fixture("type M = enum mA = 1, mB, mC\ntype Mat = object\n  v: array[9, float32]\n" &
                          "proc `[]`(m: Mat, i: int): array[3, float32] = discard\n" &
                          "proc `[]`(m: Mat, i, j: int): float32 = discard\n" &
                          "proc p(names: array[mA..mC, string], xs: array[4, int], m: Mat) =\n" &
                          "  for i, n in names: echo i\n  for j, x in xs: echo j\n  for k in low(xs)..high(xs): echo k\n")
    check tyAt(f, ls, 6, "i") == "range 1..3(M)"
    check tyAt(f, ls, 7, "j") == "range 0..3(int)"
    check tyAt(f, ls, 8, "k") == "range 0..3(int)"
    check nxTypeOfExpr(f, nxScope(f), nxLocals(f, ls, 8, 0), "m[2, 0]", 8, 0).typ == "float32"
    check nxTypeOfExpr(f, nxScope(f), nxLocals(f, ls, 8, 0), "m[2]", 8, 0).typ == "array[3, float32]"

  test "a forward declaration: its parameters are the ones used in the body, its name leads to the body":
    let (f, ls) = fixture("proc start(cmd: string,\n    dir = \"\"): owned(int) {.raises: [].}\n" &
                          "proc start(cmd: string,\n    dir = \"\"): owned int =\n  echo dir\n" &
                          "template mk(a, b: untyped) =\n  proc made(a: int, b: string) = discard\nmk(x1, y1)\n")
    let d = nxDefinition(f, ls, 4, colOf(ls, 4, "dir"))
    check d.len == 1 and d[0][1] == 1                       # (the forward declaration's)
    let d2 = nxDefinition(f, ls, 0, colOf(ls, 0, "start"))
    check d2.len == 1 and d2[0][1] == 2                     # (the routine with the body)
    let (_, l3, _) = nxTargets(f, ls, 1, colOf(ls, 1, "dir"))
    check l3.len == 1 and l3[0].line == 1
    let (_, l4, _) = nxTargets(f, ls, 7, colOf(ls, 7, "x1"))   # (a parameter of what mk makes: itself)
    check l4.len == 1 and l4[0].typ == "int"

  test "another module's type named like one of this module's (posix.Servent here with a Servent): its own":
    let m = dir / ("qt" & $getCurrentProcessId())
    createDir(m)
    writeFile(m / "pm.nim", "type Servent* = object\n  s_name*: cstring\nproc getserv*(): ptr Servent = nil\n")
    let text = "import pm\ntype Servent* = object\n  name*: string\nproc f() =\n  var s = pm.getserv()\n  echo s.\n"
    writeFile(m / "nm.nim", text)
    let ls = text.split('\n')
    let f = nxLoad(m / "nm.nim")
    check nxTypeOfExpr(f, nxScope(f), nxLocals(f, ls, 5, 0), "s", 5, 0).typ == "ptr pm.Servent"
    let c = nxComplete(f, ls, 5, ls[5].len).labels
    check "s_name" in c and "name" notin c

  test "declarations in a since (1, 3, 5): block are the module's; the library of a Nim tree a file is in":
    let (f, _) = fixture("template since(v: (int, int, int), body: untyped) = body\n" &
                         "since (1, 3, 5):\n  template elementType*(a: untyped): typedesc = typeof(a)\n")
    check f.syms.anyIt(it.name == "elementType" and it.exported)
    check nxLibOf(nimLib() / "pure" / "collections") == nimLib()

  test "multisync: `when socket is AsyncSocket: … else: …` as a value, and the parameter in an `else:`":
    let (f, ls) = fixture("type\n  Sock = ref object\n    a: int\n  ASock = ref object\n    b: int\n" &
                          "  FS = object\n  AF = object\n" &
                          "proc openA(): AF = discard\nproc newFS(): FS = discard\n" &
                          "proc send(socket: Sock | ASock) {.multisync.} =\n  let file =\n" &
                          "    when socket is ASock: openA()\n    else: newFS()\n  echo file\n" &
                          "  when socket is Sock:\n    echo socket\n  else:\n    echo socket\n")
    check tyAt(f, ls, 13, "file") == "FS"
    check tyAt(f, ls, 15, "socket") == "Sock" and tyAt(f, ls, 17, "socket") == "ASock"

  test "if c: <made of the branch's own locals> else: (\"\", 1): the else branch's type":
    let (f, ls) = fixture("proc p(c: bool) =\n  let (a, b) = if c:\n      let k = undefinedCall()\n      (k, k)\n" &
                          "    else: (\"\", 1)\n  echo a, b\n")
    check tyAt(f, ls, 5, "a") == "string" and tyAt(f, ls, 5, "b") == "int"

# ── completion ranked by the type the code expects (6.9) ──

const ExpectSrc = "type\n  Color = enum red, green, blue\n  P = object\n    name: string\n  Q = object\n    n: int\n" &
  "    s: string\n  Shape = ref object of RootObj\n  Circle = ref object of Shape\n" &
  "proc paint(c: Color, times: int) = discard\nproc show(p: P) = discard\nproc makeP(): P = P(name: \"m\")\n" &
  "proc size(q: Q): int = q.n\nproc g(a: int, b: string) = discard\nproc g(a: string, b: int) = discard\n" &
  "proc f1(x: int) = discard\nproc f1(x: string) = discard\nproc draw(s: Shape) = discard\n" &
  "proc many(xs: varargs[string]) = discard\nproc total(): int =\n  let count = 3\n  let title = \"x\"\n" &
  "  let shade = green\n  let pp = P(name: \"a\")\n  let q = Q(n: 1)\n  let nat: Natural = 2\n  let c = Circle()\n" &
  "  var s: string\n  "

proc expectAt(tail: string): NxCompletion =
  ## completion at the end of `tail`, written on the last line of a routine that has locals of every kind
  let (f, ls) = fixture(ExpectSrc & tail & "\n")
  nxComplete(f, ls, ls.high - 1, ls[^2].len)

proc first(c: NxCompletion): seq[string] =
  ## the labels offered first: those ranked before every local (what the expected type put in front)
  for it in c.items:
    if it.rank < 0 and it.label notin result: result.add it.label

proc rankOf(c: NxCompletion, label: string): int =
  result = high(int)
  for it in c.items:
    if it.label == label: result = min(result, it.rank)

suite "completion ranked by the expected type":
  test "a call's argument: the values and routines of the parameter's type first, the rest still there":
    let c = expectAt("paint(")
    check "shade" in c.first and "red" in c.first and "blue" in c.first
    check "count" notin c.first and "count" in c.labels and "title" in c.labels
    let d = expectAt("paint(shade, ")
    check "count" in d.first and "nat" in d.first and "size" in d.first     # (a Natural is an int; size returns one)
    check "shade" notin d.first and "title" notin d.first
    check rankOf(d, "len") == 2                     # (system's int routines: one step up only, there are hundreds)
    let e = expectAt("show(")
    check "pp" in e.first and "makeP" in e.first and "P" in e.first and "count" notin e.first

  test "overloads: the type they agree on, or the one of those that fit the arguments so far":
    check expectAt("f1(").first.len == 0          # (int or string: nothing goes first)
    let c = expectAt("g(count, ")
    check "title" in c.first and "s" in c.first and "count" notin c.first
    check "count" in expectAt("g(title, ").first

  test "a named argument, varargs, a subtype, a field in an object constructor":
    check "count" in expectAt("paint(times = ").first
    check "title" in expectAt("many(title, ").first
    check "c" in expectAt("draw(").first
    let p = expectAt("discard P(name: ")
    check "title" in p.first and "count" notin p.first

  test "let x: T = , x = , result = , return , == against a typed value":
    check "title" in expectAt("let t2: string = ").first
    check "count" in expectAt("var n2: int = ").first and "title" notin expectAt("var n2: int = ").first
    check "title" in expectAt("s = ").first
    check "count" in expectAt("result = ").first and "count" in expectAt("return ").first
    let e = expectAt("if shade == ")
    check "red" in e.first and "green" in e.first and "count" notin e.first
    check expectAt("let t3 = ").first.len == 0 and expectAt("echo ").first.len == 0

  test "member completion where a type is expected: that type's members first":
    let c = expectAt("paint(shade, q.")
    check c.member and "n" in c.first and "size" in c.first and "s" notin c.first
    check "s" in expectAt("s = q.").first
    check "name" in expectAt("let nm: string = pp.").first

removeDir(dir)
