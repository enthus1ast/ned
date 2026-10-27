# Nim tour · 16 of 16 · Calling C
# notebook: compiled
#
# Nim compiles to C, so C's libraries are a declaration away: `importc` says a proc (or a type, or a variable) is
# C's, and `header` which header declares it. No glue code, no wrapper library — the call is a plain C call. The
# other way round works too: `exportc` gives a Nim proc a name C code can call.
#
# In ned: Nim › C interop goes to a wrapper's C declaration, checks wrappers against their headers, and wraps a
# whole C header for you (c2nim).

# %% A first C function
# `strlen` from <string.h>. C's types have Nim names: cint, clong, cdouble, csize_t, cstring (a C string: a pointer
# to chars ending with a zero byte). A Nim string passes as a cstring as it is.
proc strlen(s: cstring): csize_t {.importc, header: "<string.h>".}
echo strlen("hello, C")
#> 8

# %% Another name, and C's maths
# `importc: "name"` gives the C name when the Nim one differs.
proc cPow(x, y: cdouble): cdouble {.importc: "pow", header: "<math.h>".}
proc cAbs(x: cint): cint {.importc: "abs", header: "<stdlib.h>".}
echo cPow(2, 10), " ", cAbs(-7)
#> 1024.0 7

# %% Varargs: printf
# `{.varargs.}` lets a C function take any number of arguments, as printf does. (printf and echo write to the same
# place, in order.)
proc printf(format: cstring) {.importc, varargs, header: "<stdio.h>".}
printf("%s has %d letters, pi is about %.3f\n", "nim", 3.cint, 3.14159)
#> nim has 3 letters, pi is about 3.142

# %% C code in the file: emit
# `{.emit.}` puts C code into the C file Nim writes. Here a C function, then its Nim declaration — `nodecl`, since
# no header declares it.
{.emit: """/*INCLUDESECTION*/
static int add_in_c(int a, int b) { return a + b; }
""".}
proc addInC(a, b: cint): cint {.importc: "add_in_c", nodecl.}
echo addInC(40, 2)
#> 42

# %% C structs
# An `object` with `importc` is a C struct: its fields are read and written as C's. Here `div` from <stdlib.h>,
# which gives back a struct div_t with a quotient and a remainder.
type DivT {.importc: "div_t", header: "<stdlib.h>".} = object
  quot, rem: cint
proc cDiv(a, b: cint): DivT {.importc: "div", header: "<stdlib.h>".}
let d = cDiv(17, 5)
echo "17 / 5 = ", d.quot, " remainder ", d.rem
#> 17 / 5 = 3 remainder 2

# %% Pointers and callbacks: qsort
# C's qsort sorts any array: it takes a pointer to the first item and a C function that compares two. `addr` gives
# a pointer, `{.cdecl.}` makes a Nim proc callable from C, and `cast` reads the pointers C hands back.
proc qsort(base: pointer, count, size: csize_t, compare: proc (a, b: pointer): cint {.cdecl.})
  {.importc, header: "<stdlib.h>".}
proc byValue(a, b: pointer): cint {.cdecl.} =
  let x = cast[ptr cint](a)[]
  let y = cast[ptr cint](b)[]
  cint(x > y) - cint(x < y)
var arr = [cint 5, 3, 9, 1, 7]
qsort(addr arr[0], csize_t(arr.len), csize_t(sizeof(cint)), byValue)
echo arr
#> [1, 3, 5, 7, 9]

# %% Nim for C: exportc
# `exportc` keeps a Nim proc's name in C, so C code can call it — here C emitted into a proc's body.
# `{.emit: ["…", x, "…"].}` puts a Nim name into the C code.
proc triple(x: cint): cint {.exportc: "nim_triple", cdecl.} = x * 3
proc askC(): cint =
  {.emit: ["extern int nim_triple(int); ", result, " = nim_triple(14);"].}
echo askC()
#> 42

# %% Exercise: shout with C
# Declare C's `toupper` from <ctype.h> (it takes and gives a cint: a character's code) and use it in `shout`, which
# gives back the text in capitals. As it is, `shout` gives the text back unchanged.
proc shout(s: string): string =
  s
echo shout("hello, nim")
# Check:
if shout("hello, nim") == "HELLO, NIM" and shout("") == "": echo "✓ ", shout("you called C")
else: echo "not yet: shout(\"hello, nim\") gives \"", shout("hello, nim"), "\""
# Answer:
  # proc toupper(c: cint): cint {.importc, header: "<ctype.h>".}
  # proc shout(s: string): string =
  #   for c in s:
  #     result.add char(toupper(cint(ord(c))))
  # echo shout("hello, nim")
