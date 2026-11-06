## Nim test coverage's own parts (src/ned/testing/gcovdata): the rewrite of Nim's C that keeps each statement's
## count on its own .nim line, gcov's three output formats, the procs no test reaches — and, when gcc and gcov are
## installed, a real build whose counts are checked line by line.
## Run: nim r tests/unit/tgcov.nim (with nim on PATH)

import std/[os, osproc, streams, strutils, tables, json, unittest]
import ../../src/ned/testing/gcovdata

# a file filter for the gcov readers that keeps every file
proc keepAll(f: string): string = f

const CalcSrc = """## calc
import std/strutils

type Shape* = enum circle, square, tri

template twice*(x: untyped): untyped =
  x * 2

proc classify*(x: int): string =
  if x > 5:
    result = "big"
  elif x < 0:
    result = "neg"
  else:
    result = "small"

proc area*(s: Shape, a: int): int =
  case s
  of circle:
    result = 3 * a * a
  of square:
    result = a * a
  of tri:
    result = a * a div 2

proc safeDiv*(a, b: int): int =
  try:
    result = a div b
  except DivByZeroError:
    result = 0
  finally:
    discard

proc neverCalled*(x: int): int =
  var s = 0
  for i in 0 ..< x:
    s += i
  s

func first*[T](xs: openArray[T]): T =
  xs[0]

iterator upto*(n: int): int =
  var i = 0
  while i < n:
    yield i
    inc i

proc useTwice*(x: int): int = twice(x) + 1

proc loud*(s: string,
           bang = "!"): string =
  ## shouts
  s.toUpperAscii &
    bang

proc `=~`*(a, b: Shape): bool =
  ord(a) == ord(b)

proc fwd(x: int): int
proc fromC(x: cint): cint {.importc: "abs", header: "<stdlib.h>".}
proc atCompileTime(): int {.compileTime.} =
  42

proc fwd(x: int): int =
  x

when isMainModule:
  proc onlyMain() =
    echo classify(3)
  onlyMain()
"""

const CalcTest = """import std/unittest
import calc

suite "calc":
  test "classify":
    check classify(10) == "big"
    check classify(1) == "small"
  test "area":
    check area(square, 3) == 9
  test "div":
    check safeDiv(4, 2) == 2
  test "first":
    check first([1, 2]) == 1
    var s = 0
    for i in upto(3): s += i
    check s == 3
    check useTwice(2) == 5
"""

suite "the C rewrite (gcc)":
  const C = "#include \"nimbase.h\"\nint x;\n#line 10 FX_1\n\tnimln_(10);\tif (a) goto LA1_;\n\n" &
            "#line 11 FX_1\n\tresult = 1;\t}\n\tgoto LA2_;\nLA1_: ;\n#define M(a) \\\n  (a)\n#line 13 FX_1\n" &
            "\tcall(1,\\\n  2);\n\tafter();\n"
  test "the lines after a statement's first go to a file of their own":
    let r = covRewriteC(C)
    let ls = r.splitLines
    check ls[0] == "#include \"nimbase.h\""
    check ls[2] == "#line 10 FX_1"
    check ls[3] == "\tnimln_(10);\tif (a) goto LA1_;"
    check ls[4] == "#line 1 \"" & CovBleedFile & "\""
    check r.count("#line 1 \"" & CovBleedFile & "\"") == 3
    # a line a backslash continues is never split
    check "\tcall(1,\\\n  2);\n#line 1 \"" & CovBleedFile & "\"\n\tafter();" in r
  test "no trailing newline, empty input":
    check covRewriteC("a\nb") == "a\nb"
    check covRewriteC("") == ""

suite "C lines to Nim lines (clang)":
  const C = "#define FX_1 \"/p/src/a.nim\"\n#define FX_2 \"/lib/system.nim\"\nint f(void) {\n#line 7 FX_1\n" &
            "\tnimln_(7); x = 1;\n\tgoto LA1_;\n#line 9 \"/p/src/b.nim\"\n\ty();\n#line 3 FX_2\n\tz();\n}\n"
  test "each anchor: the line after a #line":
    let m = covLineMap(C)
    check m == {5: ("/p/src/a.nim", 7), 8: ("/p/src/b.nim", 9), 10: ("/lib/system.nim", 3)}.toTable
  test "an lcov of C lines: each anchor's count on its .nim line":
    var h: CovHits
    let lcov = "SF:/c/x.c\nFN:3,f\nDA:3,2\nDA:5,2\nDA:6,2\nDA:8,0\nDA:10,2\nend_of_record\n" &
               "SF:/c/other.c\nDA:5,9\nend_of_record\n"
    parseLcovMapped(newStringStream(lcov), h, proc(f: string): string = (if f.startsWith("/p/"): f else: ""),
                    proc(cf: string): Table[int, (string, int)] = (if cf == "/c/x.c": covLineMap(C) else: initTable[int, (string, int)]()))
    check h == {"/p/src/a.nim": {7: 2}.toTable, "/p/src/b.nim": {9: 0}.toTable}.toTable

suite "gcov's output":
  test "JSON: lines of the files a map keeps, counts summed, nested counts ignored":
    let doc1 = """{"format_version": "1", "current_working_directory": "/proj", "data_file": "a.gcda", "files": [""" &
      """{"file": "/proj/src/a.nim", "functions": [{"name": "f", "start_line": 3, "execution_count": 2}], "lines": [""" &
      """{"line_number": 3, "count": 2, "unexecuted_block": false, "branches": [{"count": 99, "fallthrough": true}]},""" &
      """{"line_number": 4, "count": 0, "unexecuted_block": true, "branches": []}]},""" &
      """{"file": "/lib/system.nim", "lines": [{"line_number": 1, "count": 5}]},""" &
      """{"lines": [{"line_number": 7, "count": 1}], "file": "src/b.nim"}]}"""
    let doc2 = """{"current_working_directory": "/other", "files": [{"file": "/proj/src/a.nim", "lines": [""" &
      """{"line_number": 3, "count": 1}, {"line_number": 5, "count": 0}]}]}"""
    var h: CovHits
    # a file filter that keeps only the files under /proj/ (the others give an empty name, which drops them)
    proc onlyProj(f: string): string = (if f.startsWith("/proj/"): f else: "")
    parseGcovJson(newStringStream(doc1 & "\n" & doc2 & "\n"), h, onlyProj)
    check h["/proj/src/a.nim"] == {3: 3, 4: 0, 5: 0}.toTable
    check h["/proj/src/b.nim"] == {7: 1}.toTable      # (relative: the document's folder; lines before the name)
    check "/lib/system.nim" notin h
  test "intermediate text (llvm-cov gcov -i)":
    var h: CovHits
    parseGcovIntermediate(newStringStream("file:src/calc.nim\nfunction:9,2,classify\nlcount:9,2\nlcount:13,0\n" &
                                          "file:/lib/x.nim\nlcount:1,1\n"), h,
                          proc(f: string): string = (if f.endsWith("calc.nim"): f else: ""), "/p")
    check h == {"/p/src/calc.nim": {9: 2, 13: 0}.toTable}.toTable
  test "the classic .gcov text":
    var h: CovHits
    parseGcovText(newStringStream("        -:    0:Source:/p/a.nim\n        -:    0:Graph:x.gcno\n" &
                                  "        2:    9:proc classify*(x: int): string =\n    #####:   13:    result = 1\n" &
                                  "       1*:   22:    result = a\n        1:   22-block  0\n        -:   23:  of x:\n" &
                                  "    =====:   24:  y\n"), h, keepAll)
    check h["/p/a.nim"] == {9: 2, 13: 0, 22: 1, 24: 0}.toTable
  test "any of them, told apart by how the file starts":
    let f = getTempDir() / ("ned-tgcov-" & $getCurrentProcessId())
    for (text, want) in [("{\"files\": [{\"file\": \"/a.nim\", \"lines\": [{\"line_number\": 2, \"count\": 4}]}]}", 4),
                         ("file:/a.nim\nlcount:2,5\n", 5), ("        3:    2:x\n", -1)]:
      writeFile(f, text)
      var h: CovHits
      parseGcovFile(f, h, keepAll)
      if want > 0: check h["/a.nim"][2] == want
      else: check h.len == 0                         # (no Source: line: nothing to count it under)
    removeFile(f)

suite "the procs no test reaches":
  let lines = CalcSrc.splitLines
  let spans = nimRoutineSpans(lines)
  proc span(name: string): CovSpan =
    ## the span the reader found for the routine of that name; one that starts at -1 when there is none
    for s in spans:
      if s.name == name: return s
    CovSpan(first: -1)
  test "routines with bodies, not templates, forward declarations, C imports or compile-time procs":
    var names: seq[string]
    for s in spans: names.add s.name
    check names == @["classify", "area", "safeDiv", "neverCalled", "first", "upto", "useTwice", "loud", "=~", "fwd"]
  test "the lines that would hold code":
    check span("classify").code == @[8, 9, 10, 11, 12, 14]          # not `else:`
    check span("area").code == @[16, 17, 19, 21, 23]                 # not the `of` lines
    check span("safeDiv").code == @[25, 27, 29]                      # not try / except / finally / discard
    check span("neverCalled").code == @[33, 34, 35, 36, 37]
    check span("upto").code == @[42, 43, 44, 46]                     # not `yield`
    check span("useTwice").code == @[48]
    check span("loud").code == @[50, 53]                             # one statement over two lines; the doc comment
    check span("loud").first == 50 and span("loud").last == 54
    check span("=~").code == @[56, 57]                               # (a name with = in it)
    check span("fwd").code == @[64, 65]
  test "lines that hold no code of their own (whole words: not typeCount, blockSize)":
    for t in ["", "# x", "else:", "of a, b:", "except ValueError:", "finally:", "try:", "when T is int:", "type R = int",
              "const k = 3", "block:", "static: echo 1", "yield x", "discard", "template t() = 1", "import os"]:
      check covNoCodeLine(t)
    for t in ["typeCount += 1", "blockSize = 4", "result = x", "elif x < 0:", "ofs = 1", "discard f()", "typeof(x)",
              "tryAgain()", "constants.add 1"]:
      check not covNoCodeLine(t)
  test "when isMainModule, static: and inactive branches are left out":
    check span("onlyMain").first == -1
    let some = nimRoutineSpans(lines, [(8, 14)])
    for s in some: check s.name != "classify"

proc realBuild(clang: bool): Table[int, int] =
  ## calc's tests built as ned builds them (gcc: the C rewritten, gcov · clang: source-based coverage, the anchors
  ## mapped), run, counted: calc.nim's line → count. Empty when the tools are missing (the test is skipped)
  let d = getTempDir() / ("ned-tgcov-build-" & $getCurrentProcessId() & (if clang: "-clang" else: ""))
  let nc = d / "cache"
  createDir(d / "src")
  createDir(d / "tests")
  writeFile(d / "src" / "calc.nim", CalcSrc)
  writeFile(d / "tests" / "tcalc.nim", CalcTest)
  writeFile(d / "tests" / "config.nims", "switch(\"path\", \"$projectDir/../src\")\n")
  defer: removeDir(d)
  let extra = if clang: "--cc:clang " & getEnv("NED_TEST_CLANG_FLAGS") & " " else: ""
  let (o1, c1) = execCmdEx("nim c --compileOnly -d:nimBetterRun --hints:off --warnings:off --debugger:off --lineDir:on " &
                           "--opt:none --stackTrace:on --lineTrace:on --passC:-O0 --passC:--coverage --passL:--coverage " &
                           extra & "--nimcache:" & quoteShell(nc) & " -o:" & quoteShell(nc / "tcalc") & " " &
                           quoteShell(d / "tests" / "tcalc.nim"))
  doAssert c1 == 0, o1
  let build = parseJson(readFile(nc / "tcalc.json"))
  let cwd = build["currentDir"].getStr
  var deps: seq[string]
  for it in build["depfiles"]: deps.add it[0].getStr
  doAssert normalizedPath(d / "src" / "calc.nim") in deps        # (-d:nimBetterRun: every module it is built from)
  for it in build["compile"]:
    let cfile = it[0].getStr
    var cmd = it[1].getStr
    if clang: cmd = cmd.replace(" --coverage", " -fprofile-instr-generate -fcoverage-mapping")
    elif cfile.startsWith(nc) and cmd.endsWith(cfile):
      let cov = cfile[0 ..< ^2] & ".cov.c"
      writeFile(cov, covRewriteC(readFile(cfile)))
      cmd = cmd[0 ..< cmd.len - cfile.len] & quoteShell(cov)
    let (o2, c2) = execCmdEx(cmd, workingDir = cwd)
    doAssert c2 == 0, o2
  var link = build["linkcmd"].getStr
  if clang: link = link.replace(" --coverage", " -fprofile-instr-generate")
  let (o3, c3) = execCmdEx(link, workingDir = cwd)
  if c3 != 0 and clang and "clang_rt.profile" in o3:
    echo "    (clang's profile runtime is not installed: skipped)"
    return
  doAssert c3 == 0, o3
  let env = if clang: "LLVM_PROFILE_FILE=" & quoteShell(nc / "t-%p.profraw") & " " else: ""
  doAssert execCmdEx(env & quoteShell(nc / "tcalc"), workingDir = d / "tests").exitCode == 0
  let calc = normalizedPath(d / "src" / "calc.nim")
  var h: CovHits
  let keep = proc(f: string): string = (if f == calc: f else: "")
  if clang:
    let (o4, c4) = execCmdEx("llvm-profdata merge -sparse -o " & quoteShell(nc / "t.profdata") & " " & nc &
                             "/*.profraw && llvm-cov export -format=lcov -instr-profile=" & quoteShell(nc / "t.profdata") &
                             " " & quoteShell(nc / "tcalc") & " > " & quoteShell(nc / "t.lcov"))
    doAssert c4 == 0, o4
    parseLcovMappedFile(nc / "t.lcov", h, keep, proc(cf: string): Table[int, (string, int)] = covLineMap(readFile(cf)))
  else:
    let (js, c4) = execCmdEx("gcov --json-format --stdout " & quoteShell(nc) & "/*.gcda 2>/dev/null")
    doAssert c4 == 0
    parseGcovJson(newStringStream(js), h, keep)
  h.getOrDefault(calc)

proc checkCalc(t: Table[int, int]) =
  ## checks the per-line counts of the calc example after classify(10), classify(1), area, safeDiv(4, 2) and the rest
  ## were run: which lines ran, how often, which never, and that lines holding no code have no count
  # classify(10), classify(1): both conditions, "big" and "small" ran; "neg" never; `else:` holds no code
  check t.getOrDefault(9) == 2 and t.getOrDefault(10) == 2 and t.getOrDefault(11) == 1
  check t.getOrDefault(12) == 1 and t.getOrDefault(13, -1) == 0 and t.getOrDefault(15) == 1
  check 14 notin t and 16 notin t
  # area(square, …): only its branch; the `of` lines hold no code
  check t.getOrDefault(20, -1) == 0 and t.getOrDefault(22) == 1 and t.getOrDefault(24, -1) == 0
  check 19 notin t and 21 notin t and 23 notin t
  # safeDiv(4, 2): the except branch never ran
  check t.getOrDefault(28) == 1 and t.getOrDefault(30, -1) == 0
  # neverCalled: not in the C at all (and the line after safeDiv does not borrow its count)
  for l in 34 .. 39: check l notin t
  # the iterator's body, inlined in the test; the template's code counts on the line that uses it. (The `while`
  # line: Nim 2.2 marks each test of its condition with it, Nim 2.4 only the first — it ran, either way)
  check t.getOrDefault(45) >= 1 and t.getOrDefault(47) >= 3 and t.getOrDefault(49) == 1 and 7 notin t
  check 1 notin t

suite "a real build":
  test "gcc and gcov: each statement's count on its own line":
    if findExe("nim").len == 0 or findExe("gcov").len == 0 or findExe("gcc").len == 0 or
       "clang" in execCmdEx("gcc --version")[0].toLowerAscii: skip()      # (macOS's and Termux's gcc is clang)
    else: checkCalc(realBuild(clang = false))
  test "clang, source-based: the same counts":
    if findExe("nim").len == 0 or findExe("clang").len == 0 or findExe("llvm-cov").len == 0 or
       findExe("llvm-profdata").len == 0: skip()
    else:
      let t = realBuild(clang = true)
      if t.len > 0:
        checkCalc(t)
        check t.getOrDefault(47) == 3                             # (`inc i` ran three times)
