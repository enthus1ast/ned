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
