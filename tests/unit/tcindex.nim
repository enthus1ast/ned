## ned's C engine as a library: declarations, members after -> and ., locals, documentation comments, definitions,
## signature help, occurrences. Run: nim r tests/unit/tcindex.nim
import std/[unittest, strutils, os, tables]
import ../../src/ned/c/cindex

const Src = """
#include "pt.h"

/* A point in the plane. */
typedef struct point {
  int x, y;      /* where it is */
  char *name;
} Point;

struct list {
  struct list *next;
  Point p;
  union { int i; float f; } u;
};

enum color { RED, GREEN = 2, BLUE };

/// Adds two numbers.
static int add(int a, int b) {
  return a + b;
}

int main(int argc, char **argv) {
  Point pt = {1, 2, "a"};
  struct list *head = 0;
  Point *pp = &pt;
  for (int i = 0; i < argc; i++) {
    head = head->next;
  }
  return add(pt.x, 2);
}
"""

proc lineOf(ls: seq[string], t: string): int =
  for i, x in ls:
    if t in x: return i
  -1

let dir = getTempDir() / "ned_tcindex"
createDir(dir)
writeFile(dir / "pt.h", "/** Scales a point. */\nPoint scale(Point p, int k);\n")
writeFile(dir / "a.c", Src)
let f = cxLoad(dir / "a.c", Src, "t1")
let ls = Src.splitLines

suite "C engine":
  test "declarations: structs and their fields, typedefs, enums, functions with their comments":
    var names: seq[string]
    for s in f.syms: names.add $s.kind & " " & s.name
    for want in ["cxStruct point", "cxField x", "cxField y", "cxField name", "cxTypedef Point", "cxStruct list",
                 "cxField next", "cxField p", "cxField u", "cxEnum color", "cxEnumConst GREEN", "cxFunc add",
                 "cxFunc main", "cxParam argv", "cxLocal pt", "cxLocal head", "cxLocal pp", "cxLocal i"]:
      checkpoint want
      check want in names
    for s in f.syms:
      if s.name == "add": check s.doc == "Adds two numbers."
      if s.name == "Point": check s.doc == "A point in the plane."
      if s.name == "x": check s.typ == "int" and s.owner == "point" and s.doc == "where it is"
      if s.name == "next": check s.typ == "struct list *"
      if s.name == "head" and s.kind == cxLocal: check s.typ == "struct list *"

  test "members after -> and ., through typedefs and pointers":
    let l = lineOf(ls, "head = head->next;")
    let c = ls[l].find("next")
    let (items, member, typ) = cxComplete(f, l, c)
    check member
    check typ == "struct list *"
    var labels: seq[string]
    for it in items: labels.add it.label
    check labels == @["next", "p", "u"]
    check cxTypeOfExpr(cxClosure(f), f, "head->p", l) == "Point"
    check cxTypeOfExpr(cxClosure(f), f, "pp->name", l) == "char *"
    check cxTypeOfExpr(cxClosure(f), f, "head->u.f", l) == "float"

  test "definition, hover and signature help — a header's declaration with its comment":
    let l = lineOf(ls, "return add(pt.x, 2);")
    let ts = cxTargets(f, l, ls[l].find("add") + 1)
    check ts.len == 1 and ts[0][1].kind == cxFunc and ts[0][1].isDef
    check "Adds two numbers." in cxHover(f, l, ls[l].find("add") + 1)
    let tx = cxTargets(f, l, ls[l].find(".x") + 1)
    check tx.len == 1 and tx[0][1].kind == cxField and tx[0][1].name == "x"
    let (s, active) = cxSignature(f, l, ls[l].find("2);"))
    check s.name == "add" and active == 1
    # what the included header declares
    writeFile(dir / "b.c", "#include \"pt.h\"\nvoid g(Point q) { scale(q, 2); }\n")
    let g = cxLoad(dir / "b.c", readFile(dir / "b.c"), "t2")
    let h = cxHover(g, 1, 20)
    check "Point scale(Point p, int k)" in h and "Scales a point." in h

  test "occurrences: not in comments or strings":
    check cxOccurrences(@["int pt = 1; /* pt */ char *s = \"pt\"; pt++;"], "pt") == @[(0, 4), (0, 37)]

  test "anonymous structs named by their typedef, in two headers at once":
    writeFile(dir / "opt.h", "typedef struct {\n  int port;\n  char *host;\n} Options;\n")
    writeFile(dir / "glob2.h", "typedef struct {\n  int gl_pathc;\n  char **gl_pathv;\n} glob2_t, *globp;\n")
    let src = "#include \"opt.h\"\n#include \"glob2.h\"\nOptions options;\nvoid f(globp g) {\n" &
              "  options.port = 1;\n  g->gl_pathc = 0;\n}\n"
    let g = cxLoad(dir / "c.c", src, "t3")
    let sl = src.splitLines
    var labels: seq[string]
    for it in cxComplete(g, 4, sl[4].find("port"))[0]: labels.add it.label
    check labels == @["port", "host"]
    labels.setLen(0)
    for it in cxComplete(g, 5, sl[5].find("gl_pathc"))[0]: labels.add it.label
    check labels == @["gl_pathc", "gl_pathv"]
    # the typedef, not the struct it names
    let ts = cxTargets(g, 2, 2)
    check ts.len > 0 and ts[0][1].kind == cxTypedef and ts[0][1].line == 3

  test "parameters where they are written, labels, a definition's own name, #ifdef __cplusplus":
    let src = "int twice(int);\n#ifdef __cplusplus\nint twice(long);\n#endif\n" &
              "int twice(int n,\n          int unused)\n{\n  if (n < 0) goto out;\n  return n * 2;\nout:\n  return 0;\n}\n"
    let g = cxLoad(dir / "d.c", src, "t4")
    let sl = src.splitLines
    let l = lineOf(sl, "if (n < 0)")
    let tn = cxTargets(g, l, sl[l].find("n <"))
    check tn.len == 1 and tn[0][1].kind == cxParam and tn[0][1].line == 4 and tn[0][1].col == 14
    let tu = cxTargets(g, 5, sl[5].find("unused"))
    check tu.len == 1 and tu[0][1].kind == cxParam and tu[0][1].line == 5
    let tl = cxTargets(g, l, sl[l].find("out"))
    check tl.len == 1 and tl[0][1].kind == cxLabel and tl[0][1].line == lineOf(sl, "out:")
    # go to definition on the definition's own name: the prototype (C's, not the C++ overload)
    let td = cxTargets(g, 4, 4, jump = true)
    check td.len == 2 and td[0][1].line == 0 and not td[0][1].isDef and td[1][1].isDef
    var protos = 0
    for s in g.syms:
      if s.name == "twice" and not s.isDef: inc protos
    check protos == 1
    var labels: seq[string]
    for it in cxComplete(g, l, sl[l].len - 1)[0]: labels.add it.label
    check labels == @["out"]

  test "#if branches the compiler's target decides; types from headers in locals":
    cxPredef = {"__x86_64__": "1", "__linux__": "1", "__GNUC__": "13"}.toTable
    cxPredefSet = true
    let src = "#ifndef __x86_64__\nint narrow;\n#else\nint wide;\n#endif\n" &
              "#if defined(_WIN32) || defined(__APPLE__)\nint other;\n#elif __GNUC__ >= 4 && defined __linux__\nint maybe;\n#endif\n" &
              "#if defined(__linux__) && !defined(_WIN32)\nint lin;\n#endif\n" &
              "void f(void) {\n  Thing **pp = 0;\n  (void)pp;\n}\n"
    let g = cxLoad(dir / "e.c", src, "t5")
    var names: seq[string]
    for s in g.syms: names.add s.name
    check "wide" in names and "narrow" notin names and "other" notin names and "maybe" in names and "lin" in names
    check "pp" in names
    cxPredefSet = false

  test "designated initializers, #include completion":
    let src = "typedef struct { int x, y; } Pt;\nstruct box { Pt at; int w; };\nstatic struct box all[] = {\n" &
              "  { .at = { .x = 1 }, .w = 2 },\n};\nvoid f(void) {\n  struct box b = { .w = 1, .at = { .y = 2 } };\n}\n"
    let g = cxLoad(dir / "f.c", src, "t6")
    let sl = src.splitLines
    proc labelsAt(l, c: int): seq[string] =
      for it in cxComplete(g, l, c)[0]: result.add it.label
    check labelsAt(6, sl[6].find(".w") + 1) == @["at", "w"]
    check labelsAt(6, sl[6].find(".y") + 1) == @["x", "y"]
    check labelsAt(3, sl[3].find(".at") + 1) == @["at", "w"]
    check labelsAt(3, sl[3].find(".x") + 1) == @["x", "y"]
    let tw = cxTargets(g, 6, sl[6].find(".w") + 1)
    check tw.len == 1 and tw[0][1].kind == cxField and tw[0][1].line == 1
    cxDirs = @[dir]
    let h = cxLoad(dir / "h.c", "#include \"p\n", "t7")
    var hl: seq[string]
    for it in cxComplete(h, 0, 11)[0]: hl.add it.label
    check "pt.h" in hl
    cxDirs = @[]

  test "#if branches whose braces differ, struct x; declared, a local struct { … }, a macro as receiver":
    let src = "struct opaque;\nstruct tv { long sec, usec; };\nint g(int a) {\n#ifdef HAVE_X\n  if (a) {\n#else\n" &
              "  if (!a) {\n#endif\n    a++;\n  }\n  return a;\n}\nint after(void) {\n  struct tv t[2];\n" &
              "#define atime t[0]\n  static const struct { const char *name; int v; } tab[] = {{\"x\", 1}};\n" &
              "  atime.sec = tab[0].v;\n  return 0;\n}\n"
    let g = cxLoad(dir / "g.c", src, "t8")
    let sl = src.splitLines
    var fn = ""
    for s in g.syms:
      if s.kind == cxFunc and s.name == "g": fn = $s.endLine
    check fn == "11"                                   # g's body closes where it does
    var after = false
    for s in g.syms:
      if s.name == "after" and s.kind == cxFunc and s.isDef: after = true
    check after
    let l = lineOf(sl, "atime.sec")
    proc labelsAt(l, c: int): seq[string] =
      for it in cxComplete(g, l, c)[0]: result.add it.label
    check labelsAt(l, sl[l].find("sec")) == @["sec", "usec"]
    check labelsAt(l, sl[l].find(".v") + 1) == @["name", "v"]
    let to = cxTargets(g, 0, 8)
    check to.len == 1 and to[0][1].kind == cxStruct and not to[0][1].isDef

  test "macros: portability prototypes, function-like receivers, export markers, f(…) MACRO {":
    let src = "#define mod_export\n#define _(Args) Args\n#define VA_DCL\ntypedef union upat *Upat;\n" &
              "union upat { long l; char *s; };\n#define P_OPERAND(p) ((Upat)(p) + 1)\n" &
              "extern char *ztrdup _((const char *s));\nmod_export Upat first;\n" &
              "mod_export void\nzwarn(const char *fmt)\nVA_DCL\n{\n  first->l = 0;\n  P_OPERAND(first)->l = 1;\n}\n"
    let g = cxLoad(dir / "m.c", src, "t9")
    let sl = src.splitLines
    var zt, zw = false
    for s in g.syms:
      if s.name == "ztrdup" and s.kind == cxFunc and s.params.len == 1 and s.params[0].name == "s": zt = true
      if s.name == "zwarn" and s.kind == cxFunc and s.isDef: zw = true
    check zt and zw
    proc labelsAt(l, c: int): seq[string] =
      for it in cxComplete(g, l, c)[0]: result.add it.label
    let l1 = lineOf(sl, "first->l = 0")
    check labelsAt(l1, sl[l1].find("l =")) == @["l", "s"]
    let l2 = lineOf(sl, "P_OPERAND(first)->l")
    check labelsAt(l2, sl[l2].find("l =")) == @["l", "s"]
