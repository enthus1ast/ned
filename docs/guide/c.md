# C and C++: ned's own engine

C files get an IDE without installing anything: ned reads the file and the headers it includes, the way a person
skimming them does, and answers from that — about 15 ms the first time a file is opened (with every header it
includes), under a millisecond after.

- **Completion**: locals, parameters, the file's and its headers' functions, types, macros and enum constants, and
  **members after `.` and `->`** — through typedefs, pointers, arrays, casts, calls and macros (`opts->`,
  `list.items[i].`, `get(x)->`, `P_OPERAND(p)->`), and in designated initializers (`{ .x = 1, .`), each with its type
  and comment beside the list. After `goto`, the function's labels; in `#include "` and `<`, the headers there.
- **Hover**: the declaration on one line, where it is, and the comment that documents it (`/** … */`, `///` or `//`
  above it, `/**< … */` after it); a definition without a comment shows its prototype's from the header. A struct
  lists its fields with its size, alignment, each field's offset and the padding between them (64-bit); a field
  shows its offset and size, an enum constant its value, a macro its value, the use of a function-like macro what
  it expands to.
- **Go to definition (F12)** through `#include`s: the file's folder, the project's `include/`, `inc/`, `src/` and
  `lib/`, the `-I` folders of `compile_commands.json`, `C_INCLUDE_PATH` and `CPATH`, then the compiler's own. On a
  function or global declared in a header, its definition — in the project's other `.c` files too (a system
  header's declaration stays); on a definition's name, its prototype, and back; on `goto x`, the label.
- **References (Alt+Q) and rename (F2, with a preview)**: a local, parameter or label in its function, anything else
  across the project's C files — never inside strings or comments. A name declared outside the project (in the
  system's headers) is not renamed.
- **Signature help** on `(` and `,` with the parameter being typed marked; the parameters' names before literal
  arguments (inlay hints: `area(width: 3, height: 4)`); the **outline** with each struct's fields; symbols in the
  file (Ctrl+T); the **call hierarchy** (callers and calls); **header ⇄ source** (*C: switch between header and
  source*, Go › *Header ⇄ source (C)*).
- **Errors while you type**: the C compiler (`cc -fsyntax-only`) checks the unsaved text — a private copy, removed
  after — with `compile_commands.json`'s `-D`s; **Alt+Enter adds a missing `#include`** for a standard function,
  type or macro (`printf` → `<stdio.h>`, `size_t` → `<stddef.h>`), and offers **the compiler's own fixes** (its
  fix-its: `.` → `->`, a misspelt member, a missing `;`, a printf format).

It does not run the preprocessor: every `#if` branch is read, except where the answer is known without one — `#if 0`,
C++-only code (`#ifdef __cplusplus`, `extern "C++" { … }`) and the compiler's target (`__x86_64__`, `__linux__`,
`_WIN32` … as `cc -dM -E` reports them) —, and of branches that open a brace each (`#ifdef X  if (a) {  #else  if (b)
{`) the first, as ctags does. Macros used as expressions are expanded for the types (`#define atime tv[0]`), as are
export markers (`mod_export int x;`) and prototypes written through a macro (`int f _((int a));`); declarations a
macro makes (`local_list1(foo);`) are not understood.

**C++** is read too — in `.cpp`, `.cc`, `.cxx`, `.hpp` files, a `.h` with classes, namespaces or templates in it,
and emits when `nim.backend` is cpp: classes, structs and unions with their access sections and bases, methods in
the class or outside it (`Ret Class::method(…)`, constructor init lists), operators, nested classes, namespaces
(nested, `a::b`, `inline`, anonymous, `using namespace`, `using T = …`), templates (a class template's arguments put
in for its parameters: `Box<Point>`'s `value` is a `Point`), references, `auto` (range-for too), `enum class`,
`extern "C"`. Completion after `.`, `->` (smart pointers too) and `::`, a class's members in its methods, `std::`'s
common names; hover and F12 from a call to a method's body, then its declaration; errors from `c++ -std=c++17`.
Overloads are listed, not resolved; dependent types, `decltype`, concepts, specializations and structured bindings
are not understood — clangd answers those.

`c.engine` chooses: `auto` (the default: ned's engine when clangd is not installed, clangd when it is), `builtin`,
`clangd`, or `both`. How it compares with clangd is measured in [tests/engine](../../tests/engine/README.md#c-ned-against-clangd).

**See also**: ned's C formatter in clang-format's styles, and `.clang-format` — [Formatting](formatting.md#c-and-c);
the machine code of a C or C++ file as you type — [Compiler Explorer](compiler-explorer.md); debugging C with gdb or
lldb-dap — [Running, testing and debugging](run-and-debug.md#the-debugger); C in Nim's `{.emit}` and Nim's C
interop — [the Nim IDE](nim.md#other-nim-features).
