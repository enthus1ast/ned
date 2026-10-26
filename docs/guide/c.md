# C and C++: ned's own engine

C files get an IDE without installing anything: ned reads the file and the headers it includes, the way a person
skimming them does, and answers from that — about 15 ms the first time a file is opened (with every header it
includes), under a millisecond after.

- **Completion**: locals, parameters, the file's and its headers' functions, types, macros and enum constants, and
  **members after `.` and `->`** — through typedefs, pointers, arrays, casts, calls and macros (`opts->`,
  `list.items[i].`, `get(x)->`, `P_OPERAND(p)->`), and in designated initializers (`{ .x = 1, .`), each with its type
  and comment beside the list. After `goto`, the function's labels; in `#include "` and `<`, the headers there.
  A function (or a macro that takes arguments) is written with its call: `area(width, height)` with each parameter
  to type over, Tab to the next — only the parentheses for C++ overloads, and nothing more where a `(` is there
  already. After two letters, the list also has the names of headers the file does not include — the project's
  own headers and the standard ones (`printf` *#include <stdio.h>*, `util_sum` *#include "util.h"*): choosing one
  adds the `#include` after the file's others.
- **Hover**: the declaration on one line, where it is, and the comment that documents it (`/** … */`, `///` or `//`
  above it, `/**< … */` after it); a definition without a comment shows its prototype's from the header. A struct
  lists its fields with its size, alignment, each field's offset and the padding between them (64-bit); a field
  shows its offset and size, an enum constant its value, a macro its value, the use of a function-like macro what
  it expands to.
- **Go to definition (F12)** through `#include`s: the file's folder, the project's `include/`, `inc/`, `src/` and
  `lib/`, the `-I` folders of `compile_commands.json`, `C_INCLUDE_PATH` and `CPATH`, then the compiler's own. On a
  function or global declared in a header, its definition — in the project's other `.c` files too (a system
  header's declaration stays); on a definition's name, its prototype, and back; on `goto x`, the label.
- **References (Alt+Q) and rename (F2, with a preview)**: what the name names, not every word spelt the same — a
  local, parameter or label in its function, anything else across the project's C files, each use checked by the
  engine: a field `x` of another struct, a `static` function of another file or a local of another function with
  the same name is not among them. A call of a function in a file that has no prototype of it in sight still
  counts; a name the engine does not know matches the uses it does not know either. Never inside strings or
  comments. A name declared outside the project (in the system's headers) is not renamed.
- **The uses of the name under the cursor** are marked in the file (`editor.highlightOccurrences`) by the same
  rule: the field of one struct, not another's of the same name.
- **Signature help** on `(` and `,` with the parameter being typed marked, in a call written over several lines
  too; the parameters' names before literal arguments (inlay hints: `area(width: 3, height: 4)`, on each line of a
  call that takes several); the **outline** with each struct's fields; the **call hierarchy** (callers and calls);
  **header ⇄ source** (*C: switch between header and source*, Go › *Header ⇄ source (C)*).
- **Symbols**: in the file (Ctrl+T) and in the project (Ctrl+P `#`), from the engine: functions, types, macros,
  globals, a struct's fields as `point.x`, an enum's constants.
- **Go to type definition**: on a variable, a parameter, a field or a call, the struct (union, enum, class) its type
  is — through a typedef to the struct's body —; on a typedef's name, what it names.
- **Colours by what a name is** (`nim.semanticColors`): parameters, globals (in bold, with `nim.richColors`),
  macros, fields, enum constants, types and functions each in their colour, as the engine knows them — not by
  their case or the `(` after them.
- **Errors while you type**: the C compiler (`cc -fsyntax-only`) checks the unsaved text — a private copy, removed
  after — with `compile_commands.json`'s `-D`s, and Alt+Enter offers **the compiler's own fixes** (its fix-its:
  `.` → `->`, a misspelt member, a missing `;`, a printf format); ned's own checks are there at once — an unused
  `#include`, a struct's padding, a printf format (see [Checks while you type](#checks-while-you-type)).
- **Alt+Enter adds a missing `#include`**, with no compiler too: on a name the engine does not know, the header
  that declares it — one of the project's (`"util.h"`, `"net/sock.h"` from an include folder) or a standard one
  (`printf` → `<stdio.h>`, `size_t` → `<stddef.h>`); and on the compiler's "implicit declaration of function".
- **Refactors (Alt+Enter)**: on a `switch` on an enum (or in its body), *Add the missing cases* — each with its
  `break;`, before `default:`, an `enum class`'s with their scope; with an expression selected, *Extract into a
  variable* — its name asked, the variable declared before the statement with the type the engine knows (`int x =
  p->x;`; C++: `auto`), not in a loop's condition or the body of an `if` without braces; on an `if` with an `else`,
  *Invert the if* — the condition turned round (`a == b` → `a != b`, `!p` → `p`, else `!(…)`) and the two branches
  swapped.
- **Format selection**: with lines selected, Alt+F formats only those with ned's C formatter (see
  [Formatting](formatting.md#c-and-c)).

## The preprocessor's `#if`, worked out

ned works out `#if`, `#ifdef`, `#ifndef`, `#elif` and `#else` the way the compiler would, from what it knows: the
`-D` and `-U` flags of `compile_commands.json`, the macros the file `#define`s above the `#if` and those of the
headers it includes before it, and the compiler's own (`__linux__`, `__x86_64__`, `_WIN32`, `__GNUC__`,
`__STDC_VERSION__`, `__SIZEOF_POINTER__` …, asked once of `cc -dM -E` and `c++ -dM -E`; with no compiler installed,
those of the system ned runs on). Conditions can use `defined(X)`, numbers, arithmetic, comparisons and macros that
take arguments (`#if VERSION(2, 5) >= 205`); a header's include guard counts as taken.

A branch left out is dimmed, and what it declares is not offered, shown or gone to: of a function declared in both
branches of `#ifdef _WIN32 … #else … #endif`, you get the one that is compiled here. A condition that names a macro
ned does not know (`#ifdef HAVE_FOO` with nothing defining it) is not decided, and every branch of it is read, as
before. When `compile_commands.json` lists the file with all its flags, a macro defined nowhere is taken as not
defined, as the compiler takes it.

A header's `#if`s see the macros of the headers it includes, and those your files set before including it: with
`#define USE_FAST` (or `#undef`) before `#include "config.h"`, the header's `#ifdef USE_FAST` branch is the one read —
through the headers in between too. A header read with different macros from different files is kept each way (a
few ways each).

## Declarations macros make

A macro that declares something is expanded where it is used at file level, and what it declares is in the
index: with `#define DECLARE_GETTER(name, T) T get_##name(void);`, the line `DECLARE_GETTER(width, int)` declares
`get_width` — completion offers it, hover shows `int get_width()` and says which macro declared it, go to definition
goes to the line that uses the macro. The same for a macro that stands for a declaration's name (`int FN_NAME(void);`)
or type (`#define Node struct node` — `head->` offers the struct's members), `#` and `##` included. Macros used inside
a function's body (`local_list1(foo);`) are not expanded.

## Checks while you type

With ned's engine answering for a C file, it checks it at once, with no compiler, and only where it is sure:

- **An `#include` nothing of which is used** — "nothing from <string.h> is used here"; Alt+Enter: *Remove the
  #include*. A header counts as used when the file (or a project header it includes) uses a name the header
  declares, or one of the headers it includes does — a macro in an `#if` too. It says nothing for a header it could
  not read whole, one that defines a feature macro (`_GNU_SOURCE` …) or only macros, an `#include` inside an `#if`
  it could not decide or inside a body, nor at all in a file that uses a name ned cannot place.
- **A struct that would take less room with its fields ordered by size** — "struct point: 32 bytes, 24 with its
  fields ordered by size" (64-bit); Alt+Enter: *Order the fields*, the largest alignment first, each field's comments
  moving with it. Not for bit-fields, a flexible array member, packed or aligned structs, a struct with a struct or
  union written inside it, a struct whose first field is a struct (a "base"), nor one a brace list fills in order
  (`= { 1, 2.0, 'c' }`) in the file, the project's headers it includes or the other open files.
- **printf and scanf formats** (`printf`, `fprintf`, `sprintf`, `snprintf`, `dprintf`, `asprintf`, `syslog`, `err`,
  `warn`, `scanf`, `fscanf`, `sscanf`) against their arguments: how many conversions and how many arguments (`%%`
  is none, a `*` width or precision takes one), and a conversion against an argument whose type is known for sure —
  `%d` for a string, a `double` or a `long`, `%s` for a number, `%ld` for an `int`, `%d` for `strlen(s)` (a
  `size_t`); for scanf, a variable instead of its address. Alt+Enter offers the conversion the argument takes
  (*Use %zu*), or *Pass &n*. A format made by a macro, or one that numbers its arguments (`%1$s`), is not checked.

Where the compiler's check says something on the same line, its message is shown instead (for a format, Alt+Enter
still offers ned's fix: gcc's message comes with none). `c.engineChecks` turns
them on and off: `{"unusedIncludes": true, "padding": true, "formats": true}`, or `false` for none. A line with
`// ned: ignore` (or `// ned: ignore[c-format]`) is not checked.

## C++

C++ is read too — in `.cpp`, `.cc`, `.cxx`, `.hpp` files, a `.h` with classes, namespaces or templates in it,
and emits when `nim.backend` is cpp: classes, structs and unions with their access sections and bases, methods in
the class or outside it (`Ret Class::method(…)`, constructor init lists), operators, nested classes, namespaces
(nested, `a::b`, `inline`, anonymous, `using namespace`, `using T = …`), templates (a class template's arguments put
in for its parameters: `Box<Point>`'s `value` is a `Point`), references, `auto` (range-for too), `enum class`,
`extern "C"`. Completion after `.`, `->` (smart pointers too) and `::`, a class's members in its methods, `std::`'s
common names; hover and F12 from a call to a method's body, then its declaration; errors from `c++ -std=c++17`.

**Overloads**: on a call to an overloaded function or method, go to definition, hover, signature help and the
parameters' names before the arguments take the overload its arguments fit — by how many there are (default values
count) and, where ned knows them, their types: a number, a string, `nullptr`, a variable's or a cast's type, an enum's
constant; a function template takes what it is given; of two methods that differ in `const` only, the one the object
calls. When no overload fits better than the others, all of them are listed, as before. **Specialisations**: a use of
a class template whose arguments fit an explicit or partial specialisation (`template <> struct Hash<int> { … }`,
`template <typename T> struct Box<T*> { … }`) goes to it, its hover is the specialisation's, and its members are
completed from it. Dependent types, `decltype`, concepts and structured bindings are not understood — clangd answers
those.

**The type hierarchy** (Go › *Type hierarchy*) of a class — or of a value's class: the classes it derives from
(theirs above them) and those the project derives from it, in a list to go to. **Go to implementation** on a
method: its overrides in the classes derived from its class (their bodies where the project has them), one at once;
on a class: the classes derived from it.

## Which engine

`c.engine` chooses: `auto` (the default: ned's engine when clangd is not installed, clangd when it is), `builtin`,
`clangd`, or `both`. How it compares with clangd is measured in
[tests/engine](../../tests/engine/README.md#c-ned-against-clangd).

**See also**: ned's C formatter in clang-format's styles, and `.clang-format` — [Formatting](formatting.md#c-and-c);
the machine code of a C or C++ file as you type — [Compiler Explorer](compiler-explorer.md); debugging C with gdb or
lldb-dap — [Running, testing and debugging](run-and-debug.md#the-debugger); C in Nim's `{.emit}` and Nim's C
interop — [the Nim IDE](nim.md#other-nim-features).
