# the C files of a Nim 2.4 build put right for the debugger (src/ned/debug/clines.nim): each line of code in a
# function under the `#line` it follows — and, with the Nim that is on PATH, a breakpoint that gdb puts on the right
# instruction

import std/[os, osproc, strutils, unittest]
import ../../src/ned/debug/clines

# (Nim 2.4's C, cut down: a line's C over several lines under one #line)
const Spread = """
#define FX_3 "/w/dbg.nim"
#line 1 FX_3
N_LIB_PRIVATE N_NIMCALL(void, main)(void) {

#line 2 FX_3
	NI total;
	NIM_BOOL* nimErr_;
	nimfr_("main", "/w/dbg.nim");
	{
		nimErr_ = nimErrorFlag();
#line 5 FX_3
		nimln_(5);
		if (nimAddInt(total, 1, &t)) {
			raiseOverflow();
		}
	}
	popFrame();
}
static NI after = 0;
"""

func under(fixed: string, code: string): string =
  ## the line before the first line of `fixed` that is `code` (stripped)
  let ls = fixed.split('\n')
  for i, l in ls:
    if l.strip == code: return (if i > 0: ls[i - 1].strip else: "")
  "(not found)"

suite "#line put right":
  test "every line of code in a function is under the #line it follows":
    let f = cLinesFix(Spread)
    check f.under("NI total;") == "#line 2 FX_3"                 # (right after the #line: not repeated)
    check f.under("NIM_BOOL* nimErr_;") == "#line 2 FX_3"
    check f.under("nimfr_(\"main\", \"/w/dbg.nim\");") == "#line 2 FX_3"
    check f.under("nimErr_ = nimErrorFlag();") == "#line 2 FX_3"
    check f.under("if (nimAddInt(total, 1, &t)) {") == "#line 5 FX_3"
    check f.under("raiseOverflow();") == "#line 5 FX_3"
    check f.under("}") == "#line 5 FX_3"                          # (a block's brace)
    check f.under("popFrame();") == "#line 1 FX_3"                # (the function's end: the proc's line)
    check f.splitLines[^5] == "#line 1 FX_3"                             # (its last brace too)
    check f.under("static NI after = 0;") == "#line 999999 \"generated_not_to_break_here\""   # (after it: no Nim line)
    check f.under("N_LIB_PRIVATE N_NIMCALL(void, main)(void) {") == "#line 1 FX_3"

  test "comments, strings, continued lines and raw strings":
    let c = "#line 3 \"a.nim\"\nvoid f(void) {\n  /* a\n  b } */\n  g(\"}\", '}');\n  h(1, \\\n    2);\n  k();\n}\nint z;\n"
    let f = cLinesFix(c)
    check f.under("b } */") == "/* a"                           # (inside a comment: nothing put in)
    check f.under("g(\"}\", '}');") == "#line 3 \"a.nim\""        # (a brace in a string does not close the function)
    check f.under("2);") == "h(1, \\"                            # (a continued line is not cut)
    check f.under("k();") == "#line 3 \"a.nim\""
    check f.under("int z;") == "#line 999999 \"generated_not_to_break_here\""
    let raw = "#line 3 \"a.nim\"\nvoid f(void) {\n  auto s = R\"x(\n  a\n)x\";\n}\n"
    check cLinesFix(raw) == raw                                  # (a C++ raw string: the file as it is)
    check cLinesFix("int a;\nint b;\n") == "int a;\nint b;\n"     # (no #line: nothing to do)
    let crlf = "#line 4 FX_1\r\nvoid f(void) {\r\n  a();\r\n}\r\n"
    check cLinesFix(crlf).under("a();") == "#line 4 FX_1"

  test "an emit's text keeps its own lines":
    let d = getTempDir() / "ned-tclines-emit"
    createDir(d)
    let nimf = d / "e.nim"
    writeFile(nimf, "echo 1\n{.emit: \"\"\"\nstatic int twice(int x) {\n  int y = x;\n  return y * 2;\n}\n\"\"\".}\n" &
                    "proc f(a: cint): cint =\n  var r: cint\n  {.emit: \"\"\"\n  r = a + 1;\n  r = r * 2;\n  \"\"\".}\n" &
                    "  result = r\n")
    let c = "#define FX_7 \"" & nimf & "\"\n#line 2 FX_7\nstatic int twice(int x) {\n  int y = x;\n  return y * 2;\n}\n" &
            "#line 8 FX_7\nint f(int a) {\n#line 10 FX_7\n\tnimlf_(10, \"e.nim\");\n\t  r = a + 1;\n\t  r = r * 2;\n" &
            "#line 14 FX_7\n\tresult = r;\n\tpopFrame();\n}\n"
    let f = cLinesFix(c)
    check f.under("static int twice(int x) {") == "#line 3 FX_7"       # (a top-level emit: from the line after)
    check f.under("int y = x;") == "static int twice(int x) {"         # (then the C compiler's count: line 4)
    check f.under("r = a + 1;") == "nimlf_(10, \"e.nim\");"            # (line 11, as counted)
    check f.under("r = r * 2;") == "r = a + 1;"
    check f.under("result = r;") == "#line 14 FX_7"                     # (Nim's own C: under its #line)
    check f.under("popFrame();") == "#line 8 FX_7"                     # (the function's end: the proc's line)
    # (names in backquotes: the C names Nim gave them)
    writeFile(nimf, "proc f(a: cint): cint =\n  {.emit: \"\"\"\n  `result` = `a` + 1;\n  `result` *= 2;\n  \"\"\".}\n")
    let g = cLinesFix("#define FX_7 \"" & nimf & "\"\n#line 1 FX_7\nint f(int a_p0) {\n#line 2 FX_7\n\tnimln_(2);\n" &
                      "\t  result = a_p0 + 1;\n\t  result *= 2;\n\tpopFrame();\n}\n")
    check g.under("result = a_p0 + 1;") == "nimln_(2);"
    check g.under("result *= 2;") == "result = a_p0 + 1;"
    removeDir(d)

  test "C of Nim 2.2 (a line's C on one line) stays the same where it counts":
    let c = "#line 1 FX_3\nvoid f(void) {\t\n#line 2 FX_3\n\tNI x;\tx = 1;\t\n#line 3 FX_3\n\tg(x);\t\n}\n"
    let f = cLinesFix(c)
    check f.under("NI x;\tx = 1;") == "#line 2 FX_3"
    check f.under("g(x);") == "#line 3 FX_3"

  test "with this Nim, a breakpoint stops where the line's code is":
    if findExe("nim").len == 0 or findExe("gdb").len == 0:
      skip()
    else:
      let d = getTempDir() / "ned-tclines"
      removeDir(d)
      createDir(d)
      writeFile(d / "dbg.nim", "proc main() =\n  var total = 0\n  for i in 1 .. 5:\n    let sq = i * i\n" &
                                "    total += sq\n  echo total\n\nmain()\n")
      let fl = "--debugger:native --opt:none --hints:off --nimcache:" & quoteShell(d / "nc") & " -o:" &
               quoteShell(d / "dbg") & " " & quoteShell(d / "dbg.nim")
      check execCmdEx("nim c --compileOnly " & fl).exitCode == 0
      check cLinesFixBuild(d / "nc") >= 1
      check fileExists(d / "nc" / "@mdbg.nim.lines.c")
      check execCmdEx("nim jsonscript " & fl).exitCode == 0
      let (o, _) = execCmdEx("gdb -q -nx -batch -ex 'break dbg.nim:5' -ex run -ex 'print i_1' -ex 'print total_1' " &
                             quoteShell(d / "dbg"))
      # (stopped in the loop, the first time round: i is 1, total not yet added to)
      check "$1 = 1" in o and "$2 = 0" in o
      # (built again with nothing changed: no C file to compile, Nim's own files being as it wrote them)
      check execCmdEx("nim c --compileOnly " & fl).exitCode == 0
      check cLinesFixBuild(d / "nc") == 0
      check execCmdEx("nim jsonscript " & fl).exitCode == 0 and fileExists(d / "dbg")
      removeDir(d)
