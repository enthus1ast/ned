## ned's C checks (no compiler): an #include nothing of which is used, a struct that takes less room with its fields
## ordered by size, printf and scanf formats against their arguments. Run: nim r tests/unit/tcchecks.nim
import std/[unittest, strutils, os, algorithm, osproc, tables]
import ../../src/ned/c/[cindex, cchecks]

let d = getTempDir() / "ned_tcchecks"
removeDir(d)
createDir(d)
cxDirs = @[d]

proc hash0(s: string): int =
  ## a small hash of the text (24 bits), to make the cache key of a test file differ when its text does
  for c in s: result = (result * 31 + ord(c)) and 0xffffff
# reads the C source as a file of the test folder, its cache key made from its name, length and hash
proc load(name, src: string): CxFile = cxLoad(d / name, src, "ck:" & name & ":" & $src.len & ":" & $src.hash0)
proc rules(ps: seq[CkProblem]): seq[string] =
  ## each problem as a line of text — its rule, its line number and its message — to compare with what is expected
  for p in ps: result.add p.rule & " " & $(p.line + 1) & " " & p.msg
proc apply(src: string, fx: CkFix): string =
  ## the text with a fix's edits made (from the last one back)
  var ls = src.splitLines
  var es = fx.edits
  es.sort(proc(a, b: CkEdit): int = cmp((b.line, b.col), (a.line, a.col)))
  for e in es:
    let before = ls[e.line][0 ..< e.col]
    let after = if e.eline < ls.len: ls[e.eline][e.ecol .. ^1] else: ""
    let mid = (before & e.text & after).split('\n')
    ls = ls[0 ..< e.line] & mid & ls[min(e.eline + 1, ls.len) .. ^1]
  ls.join("\n")

suite "C checks: an #include nothing of which is used":
  writeFile(d / "geom.h", "#ifndef GEOM_H\n#define GEOM_H\nstruct pt { int x, y; };\nint dist(struct pt a, struct pt b);\n#endif\n")
  writeFile(d / "color.h", "#ifndef COLOR_H\n#define COLOR_H\nenum color { RED, GREEN };\nconst char *color_name(enum color c);\n#endif\n")
  writeFile(d / "conf.h", "#define HAVE_FAST 1\n#define BUF 64\n")
  writeFile(d / "all.h", "#include \"geom.h\"\n#include \"color.h\"\n")
  writeFile(d / "feat.h", "#define _GNU_SOURCE 1\nint feat_level(void);\n")

  test "a header nothing is used from: the message and the fix that removes it":
    let src = "#include \"geom.h\"\n#include \"color.h\"\n\nint main(void) {\n  struct pt p = {1, 2};\n  return p.x;\n}\n"
    let f = load("a.c", src)
    let ps = ckUnusedIncludes(f)
    check rules(ps) == @["c-unused-include 2 nothing from \"color.h\" is used here"]
    check ps[0].col == src.splitLines[1].find('"') and ps[0].fixes[0].title == "Remove the #include"
    check apply(src, ps[0].fixes[0]) == src.replace("#include \"color.h\"\n", "")

  test "used through what it includes, by a macro, by an #if, by a project header after it; feature macros":
    let src = "#include \"all.h\"\n#include \"conf.h\"\n#include \"feat.h\"\n#if HAVE_FAST\nint fast;\n#endif\n" &
              "int f(void) { return RED; }\n"
    let f = load("b.c", src)
    check ckUnusedIncludes(f).len == 0
    # (a macro, used: the header that defines it)
    let src2 = "#include \"conf.h\"\nchar buf[BUF];\n"
    check ckUnusedIncludes(load("c.c", src2)).len == 0

  test "never when a name is used the engine cannot place, nor for a header not read whole":
    let src = "#include \"geom.h\"\n#include \"color.h\"\nint g(void) { return mystery_function(1); }\n"
    check ckUnusedIncludes(load("d.c", src)).len == 0
    writeFile(d / "broken.h", "#include \"not_there.h\"\nint broken_fn(void);\n")
    let src2 = "#include \"broken.h\"\nint main(void) { return 0; }\n"
    check ckUnusedIncludes(load("e.c", src2)).len == 0
    # (an #include in a branch not known: not looked at)
    let src3 = "#ifdef SOMETHING\n#include \"color.h\"\n#endif\nint main(void) { return 0; }\n"
    check ckUnusedIncludes(load("f.c", src3)).len == 0
    # `// ned: ignore`
    let src4 = "#include \"color.h\" // ned: ignore\nint main(void) { return 0; }\n"
    check ckUnusedIncludes(load("g.c", src4)).len == 0

  test "a system header: by what it brings (the C compiler's headers, when there is one)":
    let (o, code) = execCmdEx("cc -E -Wp,-v -x c /dev/null")
    var sys: seq[string]
    for l in o.splitLines:
      if l.startsWith(" /") and dirExists(l.strip): sys.add l.strip
    if code == 0 and sys.len > 0:
      let was = cxDirs
      cxDirs = @[d] & sys
      cxSysDirs = sys
      # (and its macros, as the editor reads them: the #ifs of the system's headers decided)
      for l in execCmdEx("cc -dM -E -x c /dev/null")[0].splitLines:
        let p = l.splitWhitespace(2)
        if p.len >= 2 and p[0] == "#define": cxPredef[p[1]] = (if p.len > 2: p[2] else: "")
      cxPredefSet = true
      let src = "#include <stdio.h>\n#include <string.h>\n#include <stdlib.h>\n" &
                "int main(void) { printf(\"hi\\n\"); exit(0); }\n"
      let f = load("h.c", src)
      check rules(ckUnusedIncludes(f)) == @["c-unused-include 2 nothing from <string.h> is used here"]
      cxDirs = was
      cxSysDirs = @[]
      cxPredefSet = false

suite "C checks: a struct that takes less room with its fields ordered by size":
  test "the message, and the fix that orders the fields (comments travel with their field)":
    let src = "struct point {\n  char tag;      /* what it is */\n  // where it is\n  double x;\n  char kind;\n" &
              "  double y;\n};\nint use(struct point *p) { return p->tag; }\n"
    let f = load("p.c", src)
    let ps = ckPadding(f)
    check rules(ps) == @["c-padding 1 struct point: 32 bytes, 24 with its fields ordered by size"]
    check ps[0].fixes[0].title == "Order the fields"
    let fixed = apply(src, ps[0].fixes[0])
    check fixed.startsWith("struct point {\n  // where it is\n  double x;\n  double y;\n  char tag;      /* what it is */\n" &
                           "  char kind;\n};\n")
    # (ordered, nothing more to say)
    check ckPadding(load("p2.c", fixed)).len == 0

  test "not for bit-fields, flexible arrays, packed structs, a brace list in order, a struct first (a base)":
    check ckPadding(load("q1.c", "struct a {\n  char c;\n  double d;\n  unsigned f : 3;\n  char e;\n};\n")).len == 0
    check ckPadding(load("q2.c", "struct b {\n  char c;\n  double d;\n  char e;\n  char data[];\n};\n")).len == 0
    check ckPadding(load("q3.c", "struct __attribute__((packed)) c {\n  char c;\n  double d;\n  char e;\n};\n")).len == 0
    check ckPadding(load("q4.c", "struct e {\n  char c;\n  double d;\n  char e;\n};\nstruct e one = { 'a', 1.0, 'b' };\n")).len == 0
    check ckPadding(load("q5.c", "struct e {\n  char c;\n  double d;\n  char e;\n};\nstruct e one = { .d = 1.0 };\n")).len == 1
    check ckPadding(load("q6.c", "struct base { char k; };\nstruct der {\n  struct base b;\n  double d;\n  char e;\n};\n")).len == 0
    check ckPadding(load("q7.c", "typedef struct {\n  char c;\n  double d;\n  char e;\n} Opt;\nOpt o = { 1, 2.0, 3 };\n")).len == 0
    check rules(ckPadding(load("q8.c", "typedef struct {\n  char c;\n  double d;\n  char e;\n} Opt;\n"))) ==
          @["c-padding 1 Opt: 24 bytes, 16 with its fields ordered by size"]

suite "C checks: printf and scanf formats against their arguments":
  # (the C library's printf: a system header's)
  createDir(d / "sys")
  cxSysDirs = @[d / "sys"]
  cxDirs = @[d, d / "sys"]
  writeFile(d / "sys" / "sysio.h", "typedef unsigned long size_t;\nint printf(const char *fmt, ...);\n" &
            "int fprintf(void *f, const char *fmt, ...);\nint snprintf(char *b, size_t n, const char *fmt, ...);\n" &
            "int scanf(const char *fmt, ...);\nsize_t strlen(const char *s);\n")
  test "how many conversions, how many arguments (%% is none, * widths count)":
    let src = "#include <sysio.h>\nvoid f(int n, const char *s) {\n  printf(\"%d %s\\n\", n);\n" &
              "  printf(\"%d\\n\", n, s);\n  printf(\"100%% %*d\\n\", 5, n);\n  snprintf(0, 0, \"%s\", s);\n" &
              "  printf(\"%m\\n\");\n}\n"
    let f = load("fmt1.c", src)
    check rules(ckFormats(f)) == @["c-format 3 %s has no argument: the format wants 2, 1 follows it",
                                   "c-format 4 the format wants 1 argument, 2 follow it — this one is not printed"]

  test "a conversion and an argument whose type is known: messages and fixes":
    let src = "#include <sysio.h>\nvoid f(int n, long l, double x, const char *s, char c, size_t z) {\n" &
              "  printf(\"%d\\n\", \"abc\");\n  printf(\"%s\\n\", 42);\n  printf(\"%d\\n\", x);\n" &
              "  printf(\"%ld\\n\", n);\n  printf(\"%d\\n\", l);\n  printf(\"%-5d|\\n\", strlen(s));\n" &
              "  printf(\"%s\\n\", c);\n  printf(\"%f\\n\", n);\n  printf(\"%d %s %f %c %ld %zu\\n\", n, s, x, c, l, z);\n}\n"
    let f = load("fmt2.c", src)
    let ps = ckFormats(f)
    check rules(ps) == @["c-format 3 %d takes an int, \"abc\" is a string",
                         "c-format 4 %s takes a string, 42 is an int",
                         "c-format 5 %d takes an int, x is a double",
                         "c-format 6 %ld takes a long, n is an int",
                         "c-format 7 %d takes an int, l is a long",
                         "c-format 8 %-5d takes an int, strlen(s) is a size_t",
                         "c-format 9 %s takes a string, c is a char",
                         "c-format 10 %f takes a double, n is an int"]
    var titles: seq[string]
    for p in ps: titles.add (if p.fixes.len > 0: p.fixes[0].title else: "")
    check titles == @["Use %s", "Use %d", "Use %f", "Use %d", "Use %ld", "Use %zu", "Use %c", "Use %d"]
    let fixed = apply(src, ps[5].fixes[0])
    check "printf(\"%-5zu|\\n\", strlen(s));" in fixed

  test "scanf: where to put what it reads; %f for a double; not a project's own printf":
    let src = "#include <sysio.h>\nvoid g(void) {\n  int n;\n  double x;\n  char name[16];\n" &
              "  scanf(\"%d\", n);\n  scanf(\"%f\", &x);\n  scanf(\"%15s %d\", name, &n);\n  scanf(\"%*d %d\", &n);\n}\n"
    let f = load("scan.c", src)
    let ps = ckFormats(f)
    check rules(ps) == @["c-format 6 %d needs where to put what it reads: &n (n is an int)",
                         "c-format 7 %f takes a float *, &x is a double *"]
    check ps[0].fixes[0].title == "Pass &n" and "scanf(\"%d\", &n);" in apply(src, ps[0].fixes[0])
    check ps[1].fixes[0].title == "Use %lf"
    let own = "#include <sysio.h>\n#define printf my_printf\nvoid h(int n) { printf(\"%s\", n); }\n"
    check ckFormats(load("own.c", own)).len == 0
    # (a format the engine cannot read: a macro in it; numbered arguments)
    let other = "#include <sysio.h>\n#define FMT \"%d\"\nvoid k(const char *s) {\n  printf(FMT, s);\n" &
                "  printf(\"%1$s\", 3);\n}\n"
    check ckFormats(load("other.c", other)).len == 0

suite "C refactors: a switch's missing cases, a selection in a variable, an if/else inverted":
  test "a switch on an enum: the cases it does not have, before default:, through a typedef":
    let src = "enum color { RED, GREEN, BLUE };\ntypedef enum { M_A, M_B } Mode;\n" &
              "int f(enum color c, Mode m) {\n  switch (c) {\n  case RED:\n    return 1;\n  default:\n    return 0;\n  }\n" &
              "  switch (m) {\n  }\n  return 2;\n}\n"
    let f = load("sw.c", src)
    let fx = ckFillSwitch(f, 3, 4)
    check fx.len == 1 and fx[0].title == "Add the 2 missing cases (color)"
    check "  case RED:\n    return 1;\n  case GREEN:\n    break;\n  case BLUE:\n    break;\n  default:" in apply(src, fx[0])
    let fm = ckFillSwitch(f, 9, 2)
    check fm.len == 1 and "  switch (m) {\n    case M_A:\n      break;\n    case M_B:\n      break;\n  }" in apply(src, fm[0])
    # (a body on one line: the cases on lines of their own before its `}`)
    let one = "enum e { A, B, C };\nint h(enum e x) {\n  switch (x) { case A: return 1; }\n  return 0;\n}\n"
    let fo = ckFillSwitch(load("sw1.c", one), 2, 4)
    check fo.len == 1 and "  switch (x) { case A: return 1;\n    case B:\n      break;\n    case C:\n      break;\n  }\n" in
          apply(one, fo[0])
    # (every case there; not an enum: nothing)
    let full = "enum e { A, B };\nvoid g(enum e x, int n) {\n  switch (x) { case A: case B: break; }\n  switch (n) {\n  }\n}\n"
    let g = load("sw2.c", full)
    check ckFillSwitch(g, 2, 3).len == 0 and ckFillSwitch(g, 3, 3).len == 0

  test "C++: an enum class's constants with their scope":
    let src = "enum class Color { Red, Green };\nint f(Color c) {\n  switch (c) {\n  case Color::Red: return 1;\n  }\n  return 0;\n}\n"
    let f = cxLoad(d / "sw.cpp", src, "sw.cpp:1", cpp = true)
    let fx = ckFillSwitch(f, 2, 3)
    check fx.len == 1 and "  case Color::Green:\n    break;\n  }" in apply(src, fx[0])

  test "an if/else inverted: the condition turned round, the branches swapped":
    let src = "int f(int a, int *p) {\n  if (a == 1) {\n    return 2;\n  } else {\n    a++;\n    return 3;\n  }\n}\n"
    let fx = ckInvertIf(src.splitLines, 1)
    check fx.len == 1
    check apply(src, fx[0]) == "int f(int a, int *p) {\n  if (a != 1) {\n    a++;\n    return 3;\n  } else {\n    return 2;\n  }\n}\n"
    check ckNegate("!p") == "p" and ckNegate("p->next") == "!p->next" and ckNegate("a < b && c") == "!(a < b && c)" and
          ckNegate("!(x || y)") == "x || y" and ckNegate("n >= 0") == "n < 0" and ckNegate("a + b") == "!(a + b)"
    # (no else, or an else if: not this)
    check ckInvertIf("void g(int a) {\n  if (a) {\n    a = 1;\n  }\n}\n".splitLines, 1).len == 0
    check ckInvertIf("void g(int a) {\n  if (a) {\n    a = 1;\n  } else if (a > 2) {\n    a = 2;\n  }\n}\n".splitLines, 1).len == 0

  test "a selection in a variable of the type the engine knows, declared before its statement":
    let src = "struct pt { int x; double w; };\nint f(struct pt *p, int n) {\n  int r = 0;\n  if (p->w > 2.0)\n" &
              "    r = 1;\n  return r + p->x * n;\n}\n"
    let f = load("ex.c", src)
    let ls = src.splitLines
    var fx = ckExtractVar(f, 5, ls[5].find("p->x"), ls[5].find(" * n"))
    check fx.len == 1 and fx[0].title == "Extract into a variable: int x = p->x;"
    check apply(src, fx[0]).contains("  int x = p->x;\n  return r + x * n;")
    fx = ckExtractVar(f, 3, ls[3].find("p->w"), ls[3].find(" > 2.0"), name = "weight")
    check fx.len == 1 and apply(src, fx[0]).contains("  double weight = p->w;\n  if (weight > 2.0)")
    # (the body of an if without braces; a name being assigned; half an expression: not these)
    check ckExtractVar(f, 4, ls[4].find("1"), ls[4].find(";")).len == 0
    check ckExtractVar(f, 2, ls[2].find("r"), ls[2].find(" = 0")).len == 0
    check ckExtractVar(f, 5, ls[5].find("r + p"), ls[5].find("x * n")).len == 0
    let sum = ckExtractVar(f, 5, ls[5].find("r +"), ls[5].find(";"))
    check sum.len == 1 and sum[0].title == "Extract into a variable: int value = r + p->x * n;"
    let mixed = ckExtractVar(f, 3, ls[3].find("p->w"), ls[3].find(")"))       # (a double against a literal)
    check mixed.len == 1 and mixed[0].title == "Extract into a variable: int value = p->w > 2.0;"
    let src2 = "double g(double w, int n, char *s) {\n  return w * n + 1 + (s - s);\n}\n"
    let g = load("ex2.c", src2)
    let l2 = src2.splitLines
    check ckExtractVar(g, 1, l2[1].find("w * n"), l2[1].find(" + 1")).len == 1 and
          ckExtractVar(g, 1, l2[1].find("w * n"), l2[1].find(" + 1"))[0].title == "Extract into a variable: double value = w * n;"
    check ckExtractVar(g, 1, l2[1].find("(s - s)"), l2[1].find(";")).len == 0      # (a pointer's arithmetic)
cxDirs = @[]
