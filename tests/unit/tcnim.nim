## a C header as Nim, by ned's own C engine (Nim: wrap a C header): the declarations it makes, and a program that
## uses them compiled and run against the C. Run: nim r tests/unit/tcnim.nim

import std/[unittest, strutils, os, osproc]
import ../../src/ned/c/[cindex, cnim]

const Header = """#ifndef T_H
#define T_H
#include <stddef.h>
#include <stdint.h>
#define T_VERSION 3
#define T_FLAGS (1 << 4) | 0x2u
#define T_NAME "demo"
#define T_MAX(a, b) ((a) > (b) ? (a) : (b))
typedef enum { RED, GREEN = 4, BLUE } Color;
enum odd { HIGH = 9, LOW = 1 };
struct point { int x, y; };
typedef struct point point_t;
typedef struct { double w; char name[16]; unsigned flags : 3; const char *label; struct point *at; } box;
typedef int (*cmp_fn)(const void *a, const void *b);
typedef struct node node;
struct node { node *next; void *data; uint32_t len; };
union val { int i; double d; };
struct opaque;
/* the distance between two points, squared */
int dist2(const struct point *a, const struct point *b);
int apply(cmp_fn f, int a, int b);
const char *t_name(void);
int t_sum(int n, ...);
char **t_words(int *count);
struct opaque *t_open(const char *path, unsigned int type);
extern int t_count;
static inline int t_twice(int x) { return 2 * x; }
#endif
"""

const Impl = """#include <stdarg.h>
#include "t.h"
int t_count = 7;
int dist2(const struct point *a, const struct point *b) { int dx = a->x - b->x, dy = a->y - b->y; return dx*dx + dy*dy; }
int apply(cmp_fn f, int a, int b) { return f(&a, &b); }
const char *t_name(void) { return "demo"; }
int t_sum(int n, ...) { va_list ap; va_start(ap, n); int s = 0; for (int i = 0; i < n; i++) s += va_arg(ap, int); va_end(ap); return s; }
static char *words[] = {"a", "b"};
char **t_words(int *count) { *count = 2; return words; }
struct opaque *t_open(const char *path, unsigned int type) { (void)path; (void)type; return 0; }
"""

const Use = """import t
{.compile: "t.c".}
var a = point(x: 1, y: 2)
var b = point(x: 4, y: 6)
doAssert dist2(addr a, addr b) == 25
proc cmp(x, y: pointer): cint {.cdecl.} = cast[ptr cint](x)[] - cast[ptr cint](y)[]
doAssert apply(cmp, 5, 3) == 2
doAssert $t_name() == "demo" and t_count == 7 and t_twice(4) == 8
doAssert t_sum(3, 1.cint, 2.cint, 3.cint) == 6
var n: cint
let ws = t_words(addr n)
doAssert n == 2 and $ws[1] == "b"
doAssert T_VERSION == 3 and T_NAME == "demo" and T_FLAGS == 18
doAssert ord(GREEN) == 4 and ord(BLUE) == 5 and HIGH == odd(9)
var bx: box
bx.flags = 5
bx.at = addr a
doAssert bx.at.y == 2 and bx.flags == 5 and bx.name.len == 16
var v: val
v.i = 3
doAssert sizeof(point_t) == 8 and t_open("x", 1) == nil
echo "ok"
"""

suite "a C header as Nim":
  let dir = getTempDir() / "ned-tcnim-" & $getCurrentProcessId()
  createDir(dir)
  writeFile(dir / "t.h", Header)
  writeFile(dir / "t.c", Impl)
  let f = cxLoad(dir / "t.h", Header, "t", cpp = false)
  let (nimText, n) = cxNimBindings(f, dir / "t.h", "t.h")
  writeFile(dir / "t.nim", nimText)

  test "the declarations":
    check n >= 18
    for want in ["Color* {.size: sizeof(cint).} = enum", "point* {.importc: \"struct point\"", "point_t* = point",
                 "box* {.importc: \"box\"", "name*: array[16, cchar]", "flags* {.bitsize: 3.}: cuint",
                 "cmp_fn* = proc (a: pointer, b: pointer): cint {.cdecl.}", "next*: ptr node",
                 "val* {.importc: \"union val\", header: tH, union, bycopy.}",
                 "opaque* {.importc: \"struct opaque\", header: tH, incompleteStruct.} = object",
                 "proc dist2*(a: ptr point; b: ptr point): cint", "## the distance between two points, squared",
                 "proc t_sum*(n: cint): cint {.importc: \"t_sum\", header: tH, varargs.}",
                 "proc t_words*(count: ptr cint): cstringArray", "proc t_open*(path: cstring; `type`: cuint): ptr opaque",
                 "var t_count* {.importc: \"t_count\", header: tH.}: cint", "T_FLAGS* = (1 shl 4) or 0x2'u",
                 "# #define T_MAX(a, b)"]:
      if want notin nimText: echo "  missing: ", want
      check want in nimText
    # (an enum whose values fall: the type's constants)
    check "odd* = cint" in nimText and "HIGH* = odd(9)" in nimText

  test "a program using them compiles and runs against the C":
    if findExe("nim").len == 0:
      skip()
    else:
      writeFile(dir / "use.nim", Use)
      let (o, code) = execCmdEx("nim c -r --hints:off --nimcache:" & quoteShell(dir / "cache") & " " &
                                quoteShell(dir / "use.nim"))
      if code != 0: echo o
      check code == 0 and o.strip.endsWith("ok")

  removeDir(dir)
