## The Nim index on its own, without the editor: declarations, completion, definitions, types, hover,
## template expansion, operators and misspelled names. Run: nim r tests/unit/tindex.nim (nim on PATH)

import std/[os, strutils, unittest, sequtils]
import ../../src/ned/nim/index

proc realOf(p: string): string =
  ## the path a symbolic link points to; any other path as it is
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
  ## the column of the nth (from 0) place of the word on the line; the test fails when it is not there
  var k = -1
  for _ in 0 .. nth: k = ls[line].find(word, k + 1)
  doAssert k >= 0, word & " not on line " & $line
  k

# the labels of the completion's items, in order
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
    # the type the engine gives the expression e in the file just made
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
  # the compile-time value of the expression e in the file, as text
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
  ## the best (lowest) rank the label has among the completion's items; the largest number when it is not offered
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

  test "a call written over several lines: the argument on a line of its own (6.10)":
    let c = expectAt("paint(\n      ")
    check "shade" in c.first and "red" in c.first and "count" notin c.first and "count" in c.labels
    let d = expectAt("paint(shade,\n      ")
    check "count" in d.first and "nat" in d.first and "shade" notin d.first
    check "title" in expectAt("g(count,\n      ").first and "count" notin expectAt("g(count,\n      ").first
    let e = expectAt("g(count, # the count (an int, not a string)\n\n      ")      # (a comment, a blank line)
    check "title" in e.first and "count" notin e.first
    check "count" in expectAt("paint(shade,\n      times = ").first
    check "title" in expectAt("discard P(\n      name: ").first
    check "q" in expectAt("paint(shade, size(\n      ").first        # (the innermost call: size's argument)
    check "count" in expectAt("paint(\n      shade, ").first           # (the line goes on after an argument)
    check "title" in expectAt("g(count.min(\n        3),\n      ").first   # (a bracket opened and closed above)
    let m = expectAt("paint(shade,\n      q.")                         # (member completion)
    check m.member and "n" in m.first and "size" in m.first and "s" notin m.first
    check expectAt("echo(\n      ").first.len == 0                    # (echo takes anything)
    check expectAt("discard 1 # as paint(").labels.len > 0          # (a `(` in a comment: no call, no crash)

  test "a parameter's default in a routine's header: the parameter's type (6.10)":
    let c = expectAt("proc inner(c: Color = ")
    check "red" in c.first and "blue" in c.first and "count" notin c.first
    check "count" in expectAt("proc inner*[T](x: T; n: int = ").first and
          "title" notin expectAt("proc inner*[T](x: T; n: int = ").first
    check "red" in expectAt("proc inner(a: int,\n      c: Color = ").first
    check "red" in expectAt("let cb = proc (c: Color = ").first
    check "title" in expectAt("proc `+++`(a: P, b: string = ").first
    check "pp" in expectAt("func inner(a: int, p: P = ").first
    check expectAt("proc inner(a: int, b = ").first.len == 0                # (no type written: the default makes it)
    check expectAt("template inner(body: untyped = ").first.len == 0
    check "red" in expectAt("proc inner(c: static[Color] = ").first
    check expectAt("proc paint(c: Color, times: ").first.len == 0             # (a type is written there: no value)
    check expectAt("proc paint(c: Color,\n      times: ").first.len == 0

# ── what nimsuggest says and the engine did not (6.10) ──

proc typeAt(f: NxFile, ls: seq[string], line: int, name: string): string =
  ## the type of a name as the code on `line` sees it
  nxTypeOfName(f, nxScope(f), nxLocals(f, ls, line, ls[line].len), name, line, 0).typ

proc exprAt(f: NxFile, ls: seq[string], line: int, e: string): string =
  ## the type of the expression e as the code on that line sees it, with the locals there
  nxTypeOfExpr(f, nxScope(f), nxLocals(f, ls, line, ls[line].len), e, line, 0).typ

const ChronosLike = "type\n  Future*[T] = ref object of RootObj\n  InternalRaisesFuture*[T, E] = ref object of Future[T]\n" &
  "  Loop = proc (s: int): Future[void] {.\n    async: (raises: []).}\n  Holder = object\n" &
  "    fut: Future[void].Raising([ValueError])\n    many: seq[Future[int].Raising([ValueError, IOError])]\n" &
  "    close: proc (s: int) {.async: (raises: []).}\n" &
  "macro Raising*[T](F: typedesc[Future[T]], E: typed): untyped = discard\n" &
  "proc newFutureImpl[T](): Future[T] = discard\n" &
  "proc newInternalRaisesFutureImpl[T, E](): InternalRaisesFuture[T, E] = discard\n" &
  "template newFuture*[T](): auto =\n  when declared(InternalRaisesFutureRaises):\n" &
  "    newInternalRaisesFutureImpl[T, InternalRaisesFutureRaises]()\n  else:\n    newFutureImpl[T]()\n" &
  "proc fetch(n: int): Future[string] {.async: (raises: [ValueError, IOError]).} = discard\n" &
  "proc ping() {.async: (raises: []).} = discard\nproc plain() {.async.} = discard\n" &
  "proc rawOne(): Future[int] {.async: (raw: true, raises: [ValueError]).} =\n  let f0 = newFuture[int]()\n  return f0\n" &
  "proc notRaw(): Future[int] =\n  let f1 = newFuture[int]()\n  return f1\n" &
  "proc use(h: Holder, loop: Loop) =\n  let a = fetch(1)\n  let b = ping()\n  let c = plain()\n  let d = loop(1)\n" &
  "  let e = h.close(1)\n  let g = h.fut\n  echo Future[void].\n"

suite "engine fixes against nimsuggest (6.10)":
  test "chronos' raises futures: what its async macro and Raising make":
    let (f, ls) = fixture(ChronosLike)
    let u = ls.len - 2                                     # (the last line: echo Future[void].)
    check typeAt(f, ls, u, "a") == "InternalRaisesFuture[string, (ValueError, IOError)]"
    check typeAt(f, ls, u, "b") == "InternalRaisesFuture[void, void]"
    check typeAt(f, ls, u, "c") == "Future[void]"         # (a plain {.async.} with no result written)
    check typeAt(f, ls, u, "d") == "InternalRaisesFuture[void, void]"      # (a proc type's {.async: …}, an alias)
    check typeAt(f, ls, u, "e") == "InternalRaisesFuture[void, void]"      # (a field of a proc type)
    check typeAt(f, ls, u, "g") == "InternalRaisesFuture[void, (ValueError,)]"
    check exprAt(f, ls, u, "h.many[0]") == "InternalRaisesFuture[int, (ValueError, IOError)]"
    let raw = ls.find("  let f0 = newFuture[int]()")
    check typeAt(f, ls, raw + 1, "f0") == "InternalRaisesFuture[int, InternalRaisesFutureRaises]"
    check typeAt(f, ls, ls.find("  let f1 = newFuture[int]()") + 1, "f1") == "Future[int]"
    check "Raising" in nxComplete(f, ls, u, ls[u].len).labels

  test "overloads with numbers: a generic before a conversion, an integer literal goes into any number type":
    let (f, ls) = fixture("proc p(x: uint32, pq: float32, n: Natural, m: int) =\n  let a = min(x, x)\n" &
                          "  let b = max(0, pq)\n  let c = min(n, m)\n  let d = max(1, m)\n  echo a\n")
    check typeAt(f, ls, 5, "a") == "uint32" and typeAt(f, ls, 5, "b") == "float32"
    check typeAt(f, ls, 5, "c") == "int" and typeAt(f, ls, 5, "d") == "int"

  test "a tuple type's field before a proc of that name; a bare `seq` has no known element":
    let (f, ls) = fixture("proc month(x: string): char = 'a'\ntype D = tuple[year, month: int]\n" &
                          "proc p(d: D, ws: var seq) =\n  type L = tuple[a, month: float]\n  var l: L\n" &
                          "  let m = d.month\n  let m2 = l.month\n  let w = ws[0]\n  echo m\n")
    check typeAt(f, ls, 8, "m") == "int" and typeAt(f, ls, 8, "m2") == "float"
    check typeAt(f, ls, 8, "w") == ""

  test "system's fields iterator: the fields' one type, or `when f is T:`; converters in member completion":
    let (f, ls) = fixture("import std/strutils\ntype\n  O = object\n    a, b: string\n  Mixed = object\n    s: string\n" &
                          "    k: bool\n  Hv = distinct seq[string]\nconverter toS(v: Hv): string = \"\"\n" &
                          "proc p(o: O, x: Mixed, h: Hv) =\n  for f in o.fields: echo f\n  for g in x.fields:\n" &
                          "    when g is string:\n      echo g\n    echo g\n  echo h.\n")
    check typeAt(f, ls, 10, "f") == "string"
    check typeAt(f, ls, 13, "g") == "string" and typeAt(f, ls, 14, "g") == ""
    let c = nxComplete(f, ls, 15, ls[15].len)
    check "toS" in c.labels and "parseInt" in c.labels        # (string's routines, through the converter)

  test "multisync: only an `X | AsyncX` parameter is the synchronous one; `when s is AsyncSock` on ref types":
    let (f, ls) = fixture("type\n  Sock = ref object\n    a: int\n  AsyncSock = ref object\n    b: int\n" &
                          "proc send(s: Sock | AsyncSock, url: string | int) {.multisync.} =\n" &
                          "  let v =\n    when s is AsyncSock: 1.5\n    else: \"x\"\n  echo v\n")
    check typeAt(f, ls, 9, "s") == "Sock"
    let (_, l1, _) = nxTargets(f, ls, 5, colOf(ls, 5, "s:"))
    check l1.len == 1 and l1[0].typ == "Sock"                 # (also where it is declared)
    let (_, l2, _) = nxTargets(f, ls, 5, colOf(ls, 5, "url"))
    check l2.len == 1 and l2[0].typ == "string | int"
    check typeAt(f, ls, 9, "v") == "string"

suite "the scope of a file being edited":
  test "an edit keeps what the imports bring and has its own names as they are now; new imports, new names":
    let p = dir / "edited.nim"
    writeFile(p, "")
    var text = "from std/strutils import toUpperAscii\nproc first(x: int): int = x\n"
    var stamp = 1
    nxBufferStamp = proc(q: string): string = (if q == p: "buf" & $stamp else: "")
    nxBufferLines = proc(q: string): seq[string] = (if q == p: text.split('\n') else: @[])
    let sc1 = nxScope(nxLoad(p))
    check nxLookup(sc1, "first").len == 1 and nxLookup(sc1, "toUpperAscii").len > 0
    check nxLookup(sc1, "toLowerAscii").len == 0
    # (an edit: another proc, the same imports — the imported names kept as they were)
    text = "from std/strutils import toUpperAscii\nproc second(x: int): int = x\n"
    inc stamp
    let sc2 = nxScope(nxLoad(p))
    check sc2 != sc1 and sc2.ikey == sc1.ikey
    check nxLookup(sc2, "second").len == 1 and nxLookup(sc2, "first").len == 0
    check nxLookup(sc2, "toUpperAscii").len > 0 and nxLookup(sc2, "toLowerAscii").len == 0
    # (the same number of names imported, other ones: made again)
    text = "from std/strutils import toLowerAscii\nproc second(x: int): int = x\n"
    inc stamp
    let sc3 = nxScope(nxLoad(p))
    check sc3.ikey != sc2.ikey
    check nxLookup(sc3, "toLowerAscii").len > 0 and nxLookup(sc3, "toUpperAscii").len == 0
    # (the same text asked again: the same scope)
    check nxScope(nxLoad(p)) == sc3
    nxBufferStamp = nil
    nxBufferLines = nil

suite "Nim 3 (Nimony)":
  test "import (path / module) {.cyclic.}: the module's path, not its parentheses and pragma":
    let (f, _) = fixture("import (std / strutils) {.cyclic.}\nimport std/os\n")
    var specs: seq[string]
    for im in f.imports: specs.add im.spec
    check "std/strutils" in specs and "std/os" in specs

  test "nil ref T: its fields after a dot, as for ref T":
    let (f, ls) = fixture("type\n  Node = object\n    value: int\n    next: nil ref Node\n" &
                          "var n: nil ref Node\necho n.\n")
    let c = nxComplete(f, ls, 5, ls[5].len)
    check "value" in c.labels and "next" in c.labels

  test "names matched as written (nxExact): fooBar is not foobar; ignoreStyle brings Nim 2's rule back":
    nxExact = true
    defer:
      nxExact = false
      nxForgetFiles()
    nxForgetFiles()
    let (f, _) = fixture("proc fooBar(x: int): int = x\nlet a = fooBar(1)\n")
    let sc = nxScope(f)
    check nxLookup(sc, "fooBar").len == 1
    check nxLookup(sc, "foobar").len == 0 and nxLookup(sc, "foo_bar").len == 0
    let (g, _) = fixture("{.feature: \"ignoreStyle\".}\nproc fooBar(x: int): int = x\n")
    let sg = nxScope(g)
    check nxLookup(sg, "foo_bar").len == 1

suite "NimScript: config.nims and a .nimble (6.19)":
  proc scriptFixture(name, text: string): (NxFile, seq[string]) =
    ## a NimScript file (config.nims, a .nimble) of that name with that text in a folder of its own, loaded by the
    ## index, with its lines
    let m = dir / ("ns" & $getCurrentProcessId() & "_" & $n)
    inc n
    createDir(m)
    writeFile(m / name, text)
    (nxLoad(m / name), text.split('\n'))

  test "a program does not see NimScript's procs; config.nims does":
    let (f, ls) = fixture("import std/os\nlet d = thisD\n")
    check "thisDir" notin nxComplete(f, ls, 1, ls[1].len).labels
    let (g, gs) = scriptFixture("config.nims", "let d = thisD\n")
    check "thisDir" in nxComplete(g, gs, 0, gs[0].len).labels

  test "a .nimble sees nimble's API: namedBin, taskRequires, before, strutils":
    let (f, ls) = scriptFixture("x.nimble", "version = \"1.0\"\nnamedBin[\"a\"] = \"b\"\n" &
                                "taskRequires \"test\", \"unittest2\"\nbefore install:\n  echo \"x\".toUpperAscii\n")
    check "namedBin" in nxHover(f, ls, 1, 1)
    check "taskRequires" in nxHover(f, ls, 2, 1)
    check "before" in nxHover(f, ls, 3, 1)
    check nxHover(f, ls, 4, colOf(ls, 4, "toUpperAscii")).len > 0

  test "switches: completion, values, hover":
    let (f, ls) = scriptFixture("config.nims", "--op\n--opt:sp\nswitch(\"thre\n")
    check "opt" in nxComplete(f, ls, 0, ls[0].len).labels
    check "speed" in nxComplete(f, ls, 1, ls[1].len).labels
    check "threads" in nxComplete(f, ls, 2, ls[2].len).labels
    check "optimize" in nxHover(f, ls, 1, 3)

suite "concepts at a call (6.20)":
  test "an argument whose type does not satisfy the concept: said on hover, with what it lacks":
    let (f, ls) = fixture("type\n  Shape = concept\n    proc area(s: Self): float\n  Foo = object\n  Sq = object\n" &
                          "proc area(s: Sq): float = 1.0\n" &
                          "proc total[T: Shape](a: T): float = a.area\n" &
                          "let x = Foo()\necho total(x)\necho total(Sq())\n")
    let h = nxHover(f, ls, 8, colOf(ls, 8, "total"))
    check "Not a match" in h
    check "`Foo` is not a `Shape`" in h
    check "area(Foo): float" in h
    check "Not a match" notin nxHover(f, ls, 9, colOf(ls, 9, "total"))

suite "NimScript, plugins and doc comments (6.22)":
  proc scriptAt(name, text: string): (NxFile, seq[string]) =
    ## a NimScript file of that name with that text in a folder of its own, loaded by the index, with its lines
    let m = dir / ("s622_" & $n)
    inc n
    createDir(m)
    writeFile(m / name, text)
    (nxLoad(m / name), text.split('\n'))

  test "a .nims sees system's NimScript part: exec, cpFile — with their docs":
    let (f, ls) = scriptAt("build.nims", "mode = ScriptMode.Verbose\nexec \"nim c x.nim\"\ncpF\n")
    let h = nxHover(f, ls, 1, 1)
    check "Executes an external process" in h
    check "system · NimScript" in h
    check "cpFile" in nxComplete(f, ls, 2, ls[2].len).labels

  test "a task's name: hover (how it runs, its description), the file's tasks":
    let (f, ls) = scriptAt("build.nims", "task build, \"build it\":\n  exec \"nim c x\"\n")
    check "`nim build` runs it — build it" in nxHover(f, ls, 0, 6)
    let (g, gs) = scriptAt("p.nimble", "version = \"1.0\"\ntask test, \"run the tests\":\n  exec \"nim r t\"\n")
    check "`nimble test` runs it — run the tests" in nxHover(g, gs, 1, 6)
    let t = nxScriptTasks(gs)
    check t.len == 1 and t[0].name == "test" and t[0].line == 1 and t[0].desc == "run the tests"

  test "a doc comment on the declaration's line, going on below; a line ending in \\ joined (as nim doc does)":
    let (f, ls) = fixture("iterator oddNumbers(a: openArray[int]): int = ## hwad \\\n  ## hello\n" &
                          "  for x in a:\n    if x mod 2 == 1: yield x\n" &
                          "const flag* = defined(linux) or\n    defined(macosx) ## \\\n  ## Whether it is a Unix\n" &
                          "  ## we know.\n" &
                          "for o in oddNumbers([1, 2, 3]): echo o, flag\n")
    let h = nxHover(f, ls, 8, colOf(ls, 8, "oddNumbers"))
    check "hwad hello" in h
    check "\\" notin h.split("```")[^1]
    check "Whether it is a Unix we know" in nxHover(f, ls, 8, colOf(ls, 8, "flag")).splitWhitespace.join(" ")

  test "a constant whose value is on the lines below: the ## after the value is its doc":
    let (f, ls) = fixture("const\n  Sep* =\n    when defined(windows): '\\\\'\n    else: '/'\n" &
                          "    ## The separator.\n    ## Of paths.\n  Other* = 1\necho Sep, Other\n")
    check "The separator. Of paths." in nxHover(f, ls, 7, colOf(ls, 7, "Sep")).splitWhitespace.join(" ")
    check "separator" notin nxHover(f, ls, 7, colOf(ls, 7, "Other"))

  test "a name in `from m import a, b`: m's own (not this module's of that name)":
    let (f, ls) = fixture("from std/strutils import strip, split\n" &
                          "proc strip(x: int): int = x\necho strip(\" a \")\n")
    let h = nxHover(f, ls, 0, colOf(ls, 0, "strip"))
    check "std/strutils" in h
    check "x: int" notin h

  test "an import written `std / [os, strutils]` (spaces around the /), as atlas does":
    let (f, ls) = fixture("import std / [strutils, os]\nfrom std / sets import toHashSet\n" &
                          "echo \"a\".strip, dirExists(\"x\"), toHashSet([1])\n")
    check "std/strutils" in nxHover(f, ls, 2, colOf(ls, 2, "strip"))
    check "std/os" in nxHover(f, ls, 2, colOf(ls, 2, "dirExists"))
    check "std/sets" in nxHover(f, ls, 2, colOf(ls, 2, "toHashSet"))

  test "`## \\` at a declaration's end, its ## lines below at the declaration's own indentation (6.23)":
    let (f, ls) = fixture("const\n  blank*: string = \"about:blank\" ## \\\n  ##  Blank page string.\n" &
                          "  ## * RFC 6694\n  openCmd: string =\n    when defined(windows):\n      \"start\"\n" &
                          "    else:\n      \"open\" ## \\\n  ## Opens a file\n  ## the OS's way.\n" &
                          "  other = 1\n\n## not a doc of other\necho blank, openCmd, other\n")
    let h = nxHover(f, ls, 14, colOf(ls, 14, "blank")).splitWhitespace.join(" ")
    check "Blank page string." in h and "RFC 6694" in h and "\\" notin h.split("```")[^1]
    check "Opens a file the OS's way." in nxHover(f, ls, 14, colOf(ls, 14, "openCmd")).splitWhitespace.join(" ")
    check "not a doc" notin nxHover(f, ls, 14, colOf(ls, 14, "other"))

  test "a do block's parameters are known inside it":
    let (f, ls) = fixture("proc each(a: seq[int], cb: proc(x: int)) = discard\n" &
                          "each(@[1]) do (item: int):\n  echo item + 1\n")
    check "item: int" in nxHover(f, ls, 2, colOf(ls, 2, "item"))

  test "signature help on a routine of the file itself; go to definition on a forward declaration: its body":
    let (f, ls) = fixture("proc later(a: int, b: string): int\n" &
                          "echo later(1, \"x\")\n" &
                          "proc later(a: int, b: string): int =\n  a + b.len\n")
    let sh = nxSignatureHelp(f, ls, 1, colOf(ls, 1, "1"))
    check sh.overloads.len >= 1
    let d = nxDefinition(f, ls, 0, colOf(ls, 0, "later"))
    check d.len == 1 and d[0][1] == 2

  test "a plugin: import nedplugin resolves (ned's plugin API) — its procs documented":
    let keep = nxPluginLibDir
    nxPluginLibDir = currentSourcePath().parentDir.parentDir.parentDir / "src" / "ned" / "plugins" / "lib"
    defer: nxPluginLibDir = keep
    let (f, ls) = scriptAt("plugin.nims", "import nedplugin\n\nproc go(b: Buf) =\n  message(\"hi\")\n  b.\n")
    let h = nxHover(f, ls, 3, 3)
    check "plugin API" in h
    check "status line" in h
    let c = nxComplete(f, ls, 4, ls[4].len).labels
    check "lineComment" in c and "setCursor" in c

suite "6.25":
  test "a generic routine's instance on hover, its arguments over several lines":
    let (f, ls) = fixture("proc pairOf[T](a, b: T): (T, T) = (a, b)\n" &
                          "let p = pairOf(\n  3,\n  4)\n")
    let h = nxHover(f, ls, 1, colOf(ls, 1, "pairOf"))
    check "**Here:**" in h and "T = int" in h

  test "a chain's type, step by step (the chain hints)":
    let (f, ls) = fixture("import std/[sequtils, strutils]\nlet xs = @[1, 2, 3]\n")
    let sc = nxScope(f)
    check nxTypeOfExpr(f, sc, @[], "xs.mapIt(it * 2)", 1, 0).typ == "seq[int]"
    check nxTypeOfExpr(f, sc, @[], "xs.mapIt(it * 2).mapIt($it)", 1, 0).typ == "seq[string]"

  test "a let whose value is a call chain over the lines below: the whole chain's type":
    let (f, ls) = fixture("import std/[sequtils, strutils]\nlet xs = @[1, 2, 3]\nlet r = xs\n  .mapIt(it * 2)\n" &
                          "  .mapIt($it)\n  .join(\", \")\n")
    var v = ""
    for s in f.syms:
      if s.name == "r": v = s.value
    check v.startsWith("xs.mapIt") and v.endsWith(".join(\", \")")
    check nxTypeOfExpr(f, nxScope(f), @[], v, 2, 0).typ == "string"


suite "Nim 2.4 (6.33)":
  test "a sum type: its branches make values, and `of Branch(x, y)` names the branch's fields":
    let (f, ls) = fixture("type\n  Node = ref object\n    case\n    of AddOpr, SubOpr:\n      a, b: Node\n" &
                          "    of Value:\n      val: int\n\nproc eval(n: Node): int =\n  case n\n" &
                          "  of Value(v): v\n  of AddOpr(a, b): eval(a) + eval(b)\n  of SubOpr(a, b): eval(a) - eval(b)\n\n" &
                          "let tree = AddOpr(a: Value(val: 40), b: Value(val: 2))\n")
    var names: seq[string]
    for s in f.syms:
      if s.kind == nxProc and s.made: names.add s.name & "(" & s.params.mapIt(it.name).join(", ") & "): " & s.ret
    check names == @["AddOpr(a, b): Node", "SubOpr(a, b): Node", "Value(val): Node"]
    check typeAt(f, ls, 14, "tree") == "Node"
    let vs = nxLocals(f, ls, 10, colOf(ls, 10, "v", 1))
    check vs.anyIt(it.name == "v" and it.typ == "int")
    let ab = nxLocals(f, ls, 11, colOf(ls, 11, "eval"))
    check ab.anyIt(it.name == "a" and it.typ == "Node")
  test "Nim 2.4's operator characters, and an import marked {.cyclic.}":
    let (f, _) = fixture("import std/strutils {.cyclic.}\nproc `☆`(x, y: int): int = x * y\n")
    check f.imports.len == 1 and f.imports[0].spec == "std/strutils"
    check f.syms.anyIt(it.name == "☆")
  test "an import in a one-line when branch: the branch that applies (found by nifgrade.py: std/os in ned's files)":
    let (f, _) = fixture("when defined(windows): import std/strutils\nelse: import std/os\n" &
                         "when not defined(windows): import std/times\n")
    check f.imports.anyIt(it.spec == "std/os") and f.imports.anyIt(it.spec == "std/times")
    check not f.imports.anyIt(it.spec == "std/strutils")
  test "an enum type exported by its name brings its values (std/os: PathComponent and pcFile)":
    let (f, ls) = fixture("import std/os\nlet k = pcFile\n")
    check nxDefinition(f, ls, 1, 9).len == 1

removeDir(dir)
