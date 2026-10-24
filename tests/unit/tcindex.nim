## ned's C engine as a library: declarations, members after -> and ., locals, documentation comments, definitions,
## signature help, occurrences. Run: nim r tests/unit/tcindex.nim
import std/[unittest, strutils, os, tables, sets]
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

const ShapesHpp = """
#pragma once
#include <string>
#include <vector>
#include <memory>

namespace geo {

/// A point in the plane.
struct Point {
  double x = 0, y = 0;   // where it is
  Point() = default;
  Point(double x, double y) : x(x), y(y) {}
  /// Its distance from the origin, squared.
  double norm() const;
  static Point origin() { return Point{}; }
  bool operator==(const Point& o) const { return x == o.x && y == o.y; }
};

/// Something with an area.
class Shape {
public:
  virtual ~Shape() {}
  /// The area it covers.
  virtual double area() const = 0;
  std::string name;
protected:
  int id_ = 0;
};

class Circle final : public Shape {
public:
  explicit Circle(double r);
  double area() const override;
  Point center;
private:
  double r_;
};

template <typename T>
class Box {
public:
  T value;
  T& get() { return value; }
  void set(const T& v) { value = v; }
};

namespace detail {
  extern int counter;
  int next();
}

enum class Color : unsigned char { Red, Green, Blue };

constexpr double kPi = 3.14159;

template <typename T>
T&& pass(T&& x) noexcept { return static_cast<T&&>(x); }

}  // namespace geo
"""

const MainCpp = """
#include "shapes.hpp"
#include <iostream>

using namespace geo;
using Real = double;

double Point::norm() const {
  return x * x + y * y;
}

Circle::Circle(double r) : Shape(), r_(r) {
  name = "circle";
}

double Circle::area() const {
  Real k = 3.14159;
  return k * r_ * this->r_;
}

int geo::detail::counter = 0;

int geo::detail::next() { return ++counter; }

int main() {
  auto c = new Circle(2.0);
  auto p = Point{1, 2};
  Box<Point> box;
  Circle &ref = *c;
  std::vector<Point> pts;
  auto u = std::make_unique<Circle>(1.0);
  for (const auto &q : pts) {
    double d = q.norm();
  }
  c->area();
  p.norm();
  box.get().x;
  box.value.y;
  ref.center.y = 2;
  u->center.x;
  pts[0].y;
  pts.push_back(p);
  geo::detail::next();
  Color col = Color::Red;
  const Shape *s = static_cast<Shape*>(c);
  Shape *none = nullptr;
  none->name;
  std::cout << p.x << s->name << std::endl;
  return 0;
}
"""

suite "C++":
  let cdir = getTempDir() / "ned_tcindex_cpp"
  createDir(cdir)
  writeFile(cdir / "shapes.hpp", ShapesHpp)
  writeFile(cdir / "main.cpp", MainCpp)
  cxDirs = @[cdir]
  let m = cxLoad(cdir / "main.cpp", MainCpp, "cpp1")
  let ml = MainCpp.splitLines
  let hl = ShapesHpp.splitLines
  let files = cxClosure(m)
  let hdr = block:
    var r: CxFile
    for g in files:
      if g.path.endsWith("shapes.hpp"): r = g
    r
  proc labelsAt(f: CxFile, l, c: int): seq[string] =
    for it in cxComplete(f, l, c)[0]: result.add it.label
  proc after(ls: seq[string], line, what: string): (int, int) =
    ## the line holding `line`, and the column just past `what` on it
    let l = lineOf(ls, line)
    (l, ls[l].find(what) + what.len)

  test "the header read as C++: namespaces, classes, members, bases, templates, enum class":
    check m.cpp and hdr != nil and hdr.cpp
    var names: seq[string]
    for s in hdr.syms: names.add $s.kind & " " & s.name & " " & s.owner & " " & s.scope
    for want in ["cxNamespace geo  ", "cxStruct Point  geo", "cxField x geo::Point geo::Point",
                 "cxMethod norm geo::Point geo::Point", "cxMethod origin geo::Point geo::Point",
                 "cxMethod operator== geo::Point geo::Point", "cxClass Shape  geo", "cxMethod area geo::Shape geo::Shape",
                 "cxField name geo::Shape geo::Shape", "cxClass Circle  geo", "cxMethod Circle geo::Circle geo::Circle",
                 "cxClass Box  geo", "cxField value geo::Box geo::Box", "cxMethod get geo::Box geo::Box",
                 "cxNamespace detail  geo", "cxFunc next  geo::detail", "cxVar counter  geo::detail",
                 "cxEnum Color  geo", "cxEnumConst Red geo::Color geo::Color"]:
      checkpoint want
      check want in names
    for s in hdr.syms:
      if s.name == "Circle" and s.kind == cxClass: check s.bases == @["Shape"]
      if s.name == "Box": check s.tparams == @["T"]
      if s.name == "Point" and s.kind == cxStruct: check s.doc == "A point in the plane."
      if s.name == "x" and s.kind == cxField: check s.typ == "double" and s.doc == "where it is"
      if s.name == "get": check s.typ == "T &"
    # the main file: methods defined outside their class, `using`
    var defs: seq[string]
    for s in m.syms:
      if s.kind == cxMethod: defs.add s.name & " " & s.owner & " " & $s.isDef
    check "norm Point true" in defs and "Circle Circle true" in defs and "area Circle true" in defs
    check m.usings.len == 1 and m.usings[0][0] == "geo"

  test "members after . and -> (inherited ones, through auto, templates, references, smart pointers, range-for)":
    var (l, c) = after(ml, "c->area();", "c->")
    let circle = labelsAt(m, l, c)
    for want in ["area", "center", "r_", "name", "id_"]:
      checkpoint want
      check want in circle
    check "Circle" notin circle and "~Shape" notin circle and "operator==" notin circle
    (l, c) = after(ml, "p.norm();", "p.")
    check labelsAt(m, l, c) == @["x", "y", "norm", "origin"]
    (l, c) = after(ml, "box.get().x;", "box.get().")
    check labelsAt(m, l, c) == @["x", "y", "norm", "origin"]
    (l, c) = after(ml, "box.value.y;", "box.")
    check labelsAt(m, l, c) == @["value", "get", "set"]
    (l, c) = after(ml, "box.value.y;", "box.value.")
    check "norm" in labelsAt(m, l, c)
    (l, c) = after(ml, "ref.center.y = 2;", "ref.center.")
    check "norm" in labelsAt(m, l, c)
    (l, c) = after(ml, "u->center.x;", "u->")
    check "center" in labelsAt(m, l, c) and "area" in labelsAt(m, l, c)
    (l, c) = after(ml, "u->center.x;", "u->center.")
    check "x" in labelsAt(m, l, c)
    (l, c) = after(ml, "double d = q.norm();", "q.")
    check "norm" in labelsAt(m, l, c)
    (l, c) = after(ml, "pts[0].y;", "pts[0].")
    check "y" in labelsAt(m, l, c)
    (l, c) = after(ml, "pts.push_back(p);", "pts.")
    check "push_back" in labelsAt(m, l, c) and "size" in labelsAt(m, l, c)
    (l, c) = after(ml, "none->name;", "none->")
    check "area" in labelsAt(m, l, c)
    (l, c) = after(ml, "std::cout << p.x << s->name", "s->")
    check "name" in labelsAt(m, l, c) and "area" in labelsAt(m, l, c)
    let (items, member, typ) = cxComplete(m, l, c)
    check member and typ == "const Shape *" and items.len > 0

  test "in a method: the class's members bare and after this->, its base's too":
    var (l, c) = after(ml, "return k * r_ * this->r_;", "this->")
    let these = labelsAt(m, l, c)
    check "r_" in these and "center" in these and "name" in these
    let l2 = lineOf(ml, "return k * r_ * this->r_;")
    let bare = labelsAt(m, l2, 2)
    for want in ["k", "r_", "center", "name", "area", "Point", "Circle", "Real", "kPi", "pass", "nullptr", "class"]:
      checkpoint want
      check want in bare
    check "value" notin bare                        # (Box's, not Circle's)
    let l3 = lineOf(ml, "return x * x + y * y;")
    check "x" in labelsAt(m, l3, 2) and "norm" in labelsAt(m, l3, 2)
    # a namespace's function written outside it: its namespace's names
    let l4 = lineOf(ml, "int geo::detail::next()")
    check "counter" in labelsAt(m, l4, ml[l4].find("++") + 2)

  test "after :: — a namespace's names, an enum class's constants, a class's members, the library's":
    var (l, c) = after(ml, "geo::detail::next();", "geo::")
    let geo = labelsAt(m, l, c)
    for want in ["Point", "Shape", "Circle", "Box", "detail", "Color"]:
      checkpoint want
      check want in geo
    (l, c) = after(ml, "geo::detail::next();", "geo::detail::")
    check labelsAt(m, l, c) == @["counter", "next"]
    (l, c) = after(ml, "Color col = Color::Red;", "Color::")
    check labelsAt(m, l, c) == @["Red", "Green", "Blue"]
    (l, c) = after(ml, "std::cout << p.x", "std::")
    let std = labelsAt(m, l, c)
    for want in ["string", "vector", "unique_ptr", "make_unique", "cout", "endl", "sort", "lock_guard"]:
      checkpoint want
      check want in std
    let (items, _, _) = cxComplete(m, l, c)
    for it in items:
      if it.label == "vector": check "<vector>" in it.detail
    # a class's static members by its name
    let src = "#include \"shapes.hpp\"\nvoid f() {\n  geo::Point::\n}\n"
    let g = cxLoad(cdir / "f.cpp", src, "cpp2")
    let sl = src.splitLines
    let pl = labelsAt(g, 2, sl[2].len)
    check "origin" in pl and "norm" in pl and "Point" notin pl

  test "hover and go to definition: methods (their body outside the class), auto, inherited members":
    var (l, c) = after(ml, "p.norm();", "p.n")
    let ts = cxTargets(m, l, c)
    check ts.len == 2 and ts[0][0] == m and ts[0][1].isDef and ts[1][0] == hdr and not ts[1][1].isDef
    let h = cxHover(m, l, c)
    check "```cpp" in h and "double Point::norm() const" in h and "Its distance from the origin, squared." in h
    check "method of geo::Point" in h
    # from the body outside the class: its declaration (jump), and back
    let ld = lineOf(ml, "double Point::norm() const {")
    let tj = cxTargets(m, ld, ml[ld].find("norm"), jump = true)
    check tj.len == 2 and tj[0][0] == hdr and tj[1][0] == m
    let lh = lineOf(hl, "  double norm() const;")
    let hb = cxLoad(cdir / "shapes.hpp", ShapesHpp, "hpp1")                # (the header, open)
    let tb = cxTargets(hb, lh, hl[lh].find("norm"), jump = true)
    check tb.len == 1 and tb[0][0] == hb                     # (the header does not include main.cpp: …)
    let (bf, bk) = cxBodyIn([cdir / "main.cpp"], "norm", cxMethod, tb[0][1].owner)   # … the project's files do
    check bf != nil and bf.syms[bk].isDef and bf.syms[bk].line == ld
    # an inherited field, a pure virtual method overridden
    (l, c) = after(ml, "s->name", "s->n")
    let tn = cxTargets(m, l, c)
    check tn.len == 1 and tn[0][1].kind == cxField and tn[0][1].owner == "geo::Shape"
    (l, c) = after(ml, "c->area();", "c->a")
    let ta = cxTargets(m, l, c)
    check ta.len == 2 and ta[0][0] == m and ta[0][1].isDef and ta[1][1].owner == "geo::Circle"
    # auto: the type it has
    let lc = lineOf(ml, "auto c = new Circle(2.0);")
    let hc = cxHover(m, lc, ml[lc].find("c ="))
    check "Circle *c" in hc and "local of main" in hc
    # a member in a method's body, the class by its name, an enum class's constant, a namespace's function
    let la = lineOf(ml, "return k * r_ * this->r_;")
    let tr = cxTargets(m, la, ml[la].find("r_"))
    check tr.len == 1 and tr[0][1].kind == cxField and tr[0][0] == hdr
    let tt = cxTargets(m, la, ml[la].rfind("r_"))
    check tt.len == 1 and tt[0][1].kind == cxField
    let lp = lineOf(ml, "Box<Point> box;")
    let tp = cxTargets(m, lp, 3)
    check tp.len == 1 and tp[0][1].kind == cxClass and tp[0][1].name == "Box"
    (l, c) = after(ml, "Color col = Color::Red;", "Color::R")
    let tc = cxTargets(m, l, c)
    check tc.len == 1 and tc[0][1].kind == cxEnumConst
    (l, c) = after(ml, "geo::detail::next();", "geo::detail::n")
    let tx = cxTargets(m, l, c)
    check tx.len == 2 and tx[0][0] == m and tx[0][1].isDef and tx[1][0] == hdr
    let hcl = cxHover(m, lc, ml[lc].find("Circle") + 1)
    check "class Circle : Shape" in hcl and "Something" notin hcl and "in geo" in hcl and "double area() const" in hcl

  test "C stays C: extern \"C\", #ifdef __cplusplus, a C file next to it":
    let src = "#ifdef __cplusplus\nextern \"C\" {\n#endif\nint c_api(int x);\n#ifdef __cplusplus\n}\n#endif\n" &
              "#ifndef __cplusplus\nint only_c;\n#endif\nnamespace ns { class K { public: int v; }; }\n"
    let g = cxLoad(cdir / "api.hpp", src, "cpp3")
    var names: seq[string]
    for s in g.syms: names.add $s.kind & " " & s.name
    check "cxFunc c_api" in names and "cxClass K" in names and "cxField v" in names and "cxVar only_c" notin names
    let gc = cxLoad(cdir / "api.h", src, "c3")
    names.setLen(0)
    for s in gc.syms: names.add $s.kind & " " & s.name
    check not gc.cpp and "cxFunc c_api" in names and "cxVar only_c" in names
    check cxInactiveIn(src, cpp = true).len == 1 and cxInactiveIn(src).len == 2
    # the C++ library's headers by name; its names' hover
    let inc = cxLoad(cdir / "inc.cpp", "#include <vec\n", "cpp4")
    check "vector" in labelsAt(inc, 0, 13)
    let (l, c) = after(ml, "std::vector<Point> pts;", "std::v")
    check "a growable array" in cxHover(m, l, c)
    # an emit's C++: the .nim file's own lines, everything but the C++ blank
    let emit = "\n\n\nstruct Acc {\n  int total;\n  void add(int n) { total += n; }\n};\nvoid use(Acc &a) {\n  a.\n}\n"
    let e = cxLoad(cdir / "lib.nim", emit, "emit1", cpp = true)
    check labelsAt(e, 8, 4) == @["total", "add"]
  cxDirs = @[]

suite "C hover: values, layouts, expansions (6.23)":
  let src = "#define SIZE 16\n#define TWICE(x) ((x) * 2)\n" &
            "enum color { RED, GREEN = 5, BLUE, MASK = 1 << 4, BOTH = GREEN | MASK };\n" &
            "struct point { int x, y; };\nstruct item {\n  char name[SIZE];\n  struct point *where;\n  double weight;\n" &
            "  unsigned char flags;\n  struct point at;\n  long counts[3];\n};\n" &
            "int use(void) { return TWICE(SIZE) + BLUE; }\n"
  let d = getTempDir() / "ned_tcindex_623"
  createDir(d)
  writeFile(d / "s.c", src)
  let f = cxLoad(d / "s.c", src, "s623")
  test "an enum constant's value (implicit, and an expression of others)":
    check "**= 6**" in cxHover(f, 2, src.split('\n')[2].find("BLUE"))
    check "**= 21** (0x15)" in cxHover(f, 2, src.split('\n')[2].find("BOTH"))
  test "a struct's size, alignment, offsets and padding (64-bit); a field's offset; an array shown as written":
    let h = cxHover(f, 4, 8)
    check "**72 bytes**, aligned to 8" in h
    check "at: offset 36, 8 bytes" in h and "· 3 bytes of padding" in h and "counts: offset 48, 24 bytes" in h
    let hf = cxHover(f, 5, 8)
    check "char name[SIZE]" in hf and "offset 0 · 16 bytes" in hf
  test "a macro's value; a function-like macro's expansion where it is used":
    check "**= 16** (0x10)" in cxHover(f, 0, 9)
    let l = src.split('\n')[12]
    check "Expands to:\n```c\n((SIZE) * 2)\n```" in cxHover(f, 12, l.find("TWICE"))
    check cxEvalConst(@[f], "(SIZE << 2) | 1") == (true, 65'i64)

suite "the preprocessor's #if, worked out; declarations macros make (6.25)":
  let d = getTempDir() / "ned_tcindex_625"
  createDir(d)
  cxDirs = @[d]
  proc names(g: CxFile): seq[string] =
    for s in g.syms: result.add s.name
  proc lineOf2(src, t: string): int = lineOf(src.splitLines, t)

  test "macros #defined before, in the file and in its headers; -D and -U; arithmetic, defined(), function-like":
    writeFile(d / "conf.h", "#ifndef CONF_H\n#define CONF_H\n#define HAVE_THING 1\n#define LEVEL (2 + 1)\n" &
              "#define VERSION(a, b) ((a) * 100 + (b))\n#undef GONE\n#endif\n")
    cxDefines = @["-DUSE_FAST", "-DWIDTH=64", "-UOLD_API"]
    let src = "#include \"conf.h\"\n#define LOCAL 0\n" &
              "#if HAVE_THING\nint thing_on;\n#else\nint thing_off;\n#endif\n" &
              "#if LEVEL >= 3 && defined(USE_FAST)\nint fast_three;\n#elif LEVEL == 2\nint two;\n#else\nint other;\n#endif\n" &
              "#ifdef OLD_API\nint old_api;\n#endif\n" &
              "#if LOCAL\nint local_on;\n#endif\n" &
              "#if VERSION(2, 5) >= 205 && WIDTH / 2 == 32\nint new_enough;\n#endif\n" &
              "#ifdef GONE\nint gone;\n#endif\n" &
              "#ifdef SOMETHING_UNKNOWN\nint maybe_a;\n#else\nint maybe_b;\n#endif\n"
    let g = cxLoad(d / "a.c", src, "pp1")
    let ns = names(g)
    for want in ["thing_on", "fast_three", "new_enough", "maybe_a", "maybe_b"]:
      checkpoint want
      check want in ns
    for gone in ["thing_off", "two", "other", "old_api", "local_on", "gone"]:
      checkpoint gone
      check gone notin ns
    # what the editor dims: the branches left out (not the one not known)
    let sl = src.splitLines
    proc dimmed(l: int): bool =
      for (a, b) in g.inactive:
        if l >= a and l <= b: return true
    check dimmed(lineOf(sl, "int thing_off;")) and dimmed(lineOf(sl, "int two;")) and dimmed(lineOf(sl, "int old_api;"))
    check not dimmed(lineOf(sl, "int thing_on;")) and not dimmed(lineOf(sl, "int maybe_a;"))
    check cxInactiveIn(src, path = d / "a.c") == g.inactive
    cxDefines = @[]

  test "the compiler's own macros (the target): a function declared in both branches is found once, the active one":
    cxPredef = {"__x86_64__": "1", "__linux__": "1", "__GNUC__": "13", "__STDC_VERSION__": "201710L",
                "__SIZEOF_POINTER__": "8"}.toTable
    cxPredefSet = true
    let src = "#ifdef _WIN32\nvoid sleep_ms(unsigned ms);\nvoid win_only(void);\n#else\nvoid sleep_ms(int ms);\n" &
              "void posix_only(void);\n#endif\n#if __STDC_VERSION__ >= 201112L && __SIZEOF_POINTER__ == 8\nint c11_64;\n#endif\n" &
              "#if defined(__clang__) || (defined(__GNUC__) && __GNUC__ < 4)\nint old_or_clang;\n#endif\n" &
              "void use(void) { sleep_ms(1); }\n"
    let g = cxLoad(d / "b.c", src, "pp2")
    let ns = names(g)
    check "posix_only" in ns and "win_only" notin ns and "c11_64" in ns and "old_or_clang" notin ns
    let sl = src.splitLines
    let l = lineOf(sl, "sleep_ms(1)")
    let ts = cxTargets(g, l, sl[l].find("sleep_ms"))
    check ts.len == 1 and ts[0][1].line == lineOf(sl, "void sleep_ms(int ms);")
    check "int ms" in cxHover(g, l, sl[l].find("sleep_ms"))
    cxPredefSet = false

  test "a header's guard is taken; a macro changed in a branch not known is not known after it":
    writeFile(d / "guard.h", "#ifndef GUARD_H\n#define GUARD_H\n#ifdef MAYBE_X\n#define MODE 1\n#else\n" &
              "#define MODE 2\n#endif\n#define ALWAYS 7\n#endif\n")
    let src = "#include \"guard.h\"\n#if ALWAYS == 7\nint seven;\n#else\nint not_seven;\n#endif\n" &
              "#if MODE == 2\nint mode2;\n#else\nint mode1;\n#endif\n"
    let g = cxLoad(d / "c.c", src, "pp3")
    let ns = names(g)
    check "seven" in ns and "not_seven" notin ns
    check "mode2" in ns and "mode1" in ns                  # (MODE: 1 or 2, as MAYBE_X is — not known)

  test "a file compile_commands.json gives all the flags of: a macro defined nowhere is not defined":
    let src = "#ifdef HAVE_NOTHING_LIKE_IT\nint nope;\n#else\nint yes;\n#endif\n"
    var g = cxLoad(d / "s.c", src, "pp4")
    check "nope" in names(g) and "yes" in names(g)
    cxStrictFiles.incl d / "s.c"
    g = cxLoad(d / "s.c", src, "pp5")
    check "nope" notin names(g) and "yes" in names(g)
    cxStrictFiles.clear()

  test "a macro that makes declarations: a getter, a name, a type, # and ##; hover says which macro":
    writeFile(d / "decl.h", "#define DECLARE_GETTER(name, T) T get_##name(void);\n" &
              "#define FN_NAME my_func\n#define Node struct node\n#define MAKE(n) const char *n##_str = #n;\n" &
              "#define LIB_API extern\n#define API(x) lib_##x\n")
    let src = "#include \"decl.h\"\nstruct node { int value; struct node *next; };\n" &
              "DECLARE_GETTER(width, int)\nDECLARE_GETTER(label, const char *)\nint FN_NAME(void);\n" &
              "Node *head;\nMAKE(alpha)\nLIB_API int API(open)(const char *path);\n" &
              "void f(void) {\n  get_width();\n  head->value = 1;\n  lib_open(alpha_str);\n}\n"
    let g = cxLoad(d / "e.c", src, "pp6")
    let sl = src.splitLines
    var byName: Table[string, CxSym]
    for s in g.syms: byName[s.name] = s
    check "get_width" in byName and "get_label" in byName and "my_func" in byName and "alpha_str" in byName
    check "lib_open" in byName and "FN_NAME" notin byName
    check byName["get_width"].kind == cxFunc and byName["get_width"].typ == "int"
    check byName["get_width"].viaMacro == "DECLARE_GETTER" and byName["get_width"].line == lineOf(sl, "DECLARE_GETTER(width")
    check byName["get_label"].typ == "const char *"
    check byName["lib_open"].params.len == 1 and byName["lib_open"].params[0].name == "path"
    # completion, hover, go to definition from a use
    let l = lineOf(sl, "  get_width();")
    var labels: seq[string]
    for it in cxComplete(g, l, 5)[0]: labels.add it.label
    check "get_width" in labels and "my_func" in labels
    let h = cxHover(g, l, 4)
    check "int get_width()" in h and "declared by the macro DECLARE_GETTER" in h
    let ts = cxTargets(g, l, 4)
    check ts.len == 1 and ts[0][1].line == lineOf(sl, "DECLARE_GETTER(width")
    # a macro as a declaration's type: its members
    let lh = lineOf(sl, "head->value")
    labels.setLen(0)
    for it in cxComplete(g, lh, sl[lh].find("value"))[0]: labels.add it.label
    check labels == @["value", "next"]
  cxDirs = @[]

suite "C++: overloads and template specialisations (6.25)":
  let d = getTempDir() / "ned_tcindex_625cpp"
  createDir(d)
  cxDirs = @[d]
  let hdr = """
#include <string>
/// Prints a number.
struct Printer {
  /// A number.
  void print(int n);
  /// A string.
  void print(const char *s);
  /// A number with its precision.
  void print(double d, int prec = 2);
  void print(const std::string &s, bool upper);
};
/// The area of a rectangle.
int area(int w, int h);
/// The area of a circle.
double area(double r);
template <typename T> struct Hash { int generic; };
/// Hashes ints.
template <> struct Hash<int> { int forInt; unsigned seed() const; };
template <typename T> struct Box { T value; T get() const; };
/// A box of a pointer.
template <typename T> struct Box<T*> { T *ptr; bool null() const; };
struct Point { int x, y; };
"""
  let src = """
#include "ovl.hpp"
void Printer::print(int n) {}
void Printer::print(const char *s) {}
void Printer::print(double d, int prec) {}
int area(int w, int h) { return w * h; }
double area(double r) { return 3.14 * r * r; }
unsigned Hash<int>::seed() const { return 7; }
void use() {
  Printer p;
  const char *name = "x";
  double radius = 2.0;
  p.print("x");
  p.print(3);
  p.print(1.5, 3);
  p.print(name);
  area(radius);
  area(1, 2);
  Hash<int> h;
  Hash<long> g;
  Box<Point*> b;
  Box<int> bi;
  h.forInt;
  g.generic;
  b.ptr;
  bi.value;
  p.print(radius, 
}
"""
  writeFile(d / "ovl.hpp", hdr)
  let m = cxLoad(d / "use.cpp", src, "ovl1")
  let sl = src.splitLines
  let hl = hdr.splitLines
  proc at(t, w: string): (int, int) =
    let l = lineOf(sl, t)
    (l, sl[l].find(w))
  proc labelsAt(l, c: int): seq[string] =
    for it in cxComplete(m, l, c)[0]: result.add it.label

  test "go to definition and hover pick the overload by the number and the types of the arguments":
    var (l, c) = at("p.print(\"x\");", "print")
    var ts = cxTargets(m, l, c)
    check ts.len > 0 and ts[0][1].params.len == 1 and ts[0][1].params[0].typ == "const char *"
    check "A string." in cxHover(m, l, c)
    (l, c) = at("p.print(3);", "print")
    ts = cxTargets(m, l, c, jump = true)
    check ts[0][1].params.len == 1 and ts[0][1].params[0].typ == "int" and ts[0][1].isDef and ts[0][0] == m
    check "A number." in cxHover(m, l, c)
    (l, c) = at("p.print(1.5, 3);", "print")
    check cxTargets(m, l, c)[0][1].params.len == 2 and "A number with its precision." in cxHover(m, l, c)
    (l, c) = at("p.print(name);", "print")
    check cxTargets(m, l, c)[0][1].params[0].typ == "const char *"
    (l, c) = at("area(radius);", "area")
    ts = cxTargets(m, l, c)
    check ts[0][1].params.len == 1 and "The area of a circle." in cxHover(m, l, c)
    (l, c) = at("area(1, 2);", "area")
    check cxTargets(m, l, c)[0][1].params.len == 2 and "The area of a rectangle." in cxHover(m, l, c)
    # every overload still listed, the one picked first
    check cxTargets(m, l, c).len >= 4

  test "overloads: an enum's, a template's, a const method's — by what the arguments are":
    let src2 = """
enum Err { OK, BAD };
bool check(const char *what, Err a, Err b);
bool check(const char *what, bool a, bool b);
template <class T> bool check(const char *what, T a, T b);
struct Node { Node *first(); const Node *first() const; const Node *next() const; Node *next(); };
void put(int n);
void put(long long n);
void put(const char *s);
void run(const Node *cn, Node *nn) {
  check("x", OK, BAD);
  check("y", 1, 2);
  bool ok = true;
  check("z", true, ok);
  cn->first();
  nn->first();
  nn->next()->first();
  cn->next()->first();
  put(static_cast<long long>(1));
  put((long long)(2));
  put(nullptr);
}
"""
    let g = cxLoad(d / "ovl2.cpp", src2, "ovl2")
    let s2 = src2.splitLines
    proc firstAt(t, w: string): CxSym =
      let l = lineOf(s2, t)
      cxTargets(g, l, s2[l].find(w))[0][1]
    check firstAt("check(\"x\", OK, BAD);", "check").params[1].typ == "Err"
    check firstAt("check(\"y\", 1, 2);", "check").tparams == @["T"]
    check firstAt("check(\"z\", true, ok);", "check").params[1].typ == "bool"     # (a function before a template)
    check firstAt("cn->first();", "first").text.endsWith(" const")
    check not firstAt("nn->first();", "first").text.endsWith(" const")
    check not firstAt("nn->next()->first();", "first").text.endsWith(" const")
    check firstAt("cn->next()->first();", "first").text.endsWith(" const")
    check firstAt("put(static_cast<long long>(1));", "put").params[0].typ == "long long"
    check firstAt("put(nullptr);", "put").params[0].typ == "const char *"

  test "signature help: the overload the arguments typed so far fit":
    let l = lineOf(sl, "  p.print(radius, ")
    let (s, active) = cxSignature(m, l, sl[l].len)
    check s.name == "print" and s.params.len == 2 and s.params[0].typ == "double" and active == 1
    let l2 = lineOf(sl, "p.print(1.5, 3);")
    let (s2, a2) = cxSignature(m, l2, sl[l2].find("3)"))
    check s2.params.len == 2 and s2.params[0].typ == "double" and a2 == 1
    # (every argument: the parameters' names before them, ned's inlay hints)
    let l3 = lineOf(sl, "p.print(\"x\");")
    check cxSignature(m, l3, sl[l3].find("(") + 1, whole = true)[0].params[0].typ == "const char *"
    check cxSignature(m, l2, sl[l2].find("(") + 1, whole = true)[0].params[0].typ == "double"
    let l4 = lineOf(sl, "p.print(3);")
    check cxSignature(m, l4, sl[l4].find("(") + 1, whole = true)[0].params[0].typ == "int"

  test "a template's specialisation: go to definition, hover and its members":
    var (l, c) = at("Hash<int> h;", "Hash")
    var ts = cxTargets(m, l, c)
    check ts.len > 0 and ts[0][1].spec == "int" and ts[0][1].line == lineOf(hl, "template <> struct Hash<int>")
    check "Hashes ints." in cxHover(m, l, c) and "struct Hash<int>" in cxHover(m, l, c)
    (l, c) = at("h.forInt;", "forInt")
    check labelsAt(l, c) == @["forInt", "seed"]
    (l, c) = at("g.generic;", "generic")
    check labelsAt(l, c) == @["generic"]
    (l, c) = at("b.ptr;", "ptr")
    check labelsAt(l, c) == @["ptr", "null"]
    (l, c) = at("bi.value;", "value")
    check labelsAt(l, c) == @["value", "get"]
    (l, c) = at("Box<Point*> b;", "Box")
    ts = cxTargets(m, l, c)
    check ts[0][1].spec == "T*" and "A box of a pointer." in cxHover(m, l, c)
    # a specialisation's method defined outside it: its own class's
    var owner = ""
    for s in m.syms:
      if s.name == "seed" and s.isDef: owner = s.owner
    check owner == "Hash<int>"
    check cxxSpecMatch("T*", @["T"], @["Point *"]) == (true, @["Point"])
    check cxxSpecMatch("T, T", @["T"], @["int", "long"])[0] == false
    check cxxSpecMatch("std::vector<T>", @["T"], @["std::vector<Box<int>>"]) == (true, @["Box<int>"])
  cxDirs = @[]
