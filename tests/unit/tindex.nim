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

removeDir(dir)
