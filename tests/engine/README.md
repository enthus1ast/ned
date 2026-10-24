# ned's engines against nimsuggest and clangd

[The C engine against clangd](#c-ned-against-clangd) is further down.

## Nim: ned against nimsuggest

The numbers in the README's *How good it is* come from here. `compare.py` asks ned's built-in engine and
nimsuggest the same questions about one file and counts where they agree:

1. **type hints** — every `let` / `var` / `const` written without a type: ned's hint against nimsuggest's
   `inlayHints`;
2. **go to definition** at random identifiers, against nimsuggest's `def`;
3. **the types of the variables** among them, against the type `def` reports;
4. **member completion** at random `x.member` places: is the member written there offered right after the dot?

```sh
./build.sh                                   # the engine driver, from this checkout's source → ./ned-engine
./compare.py ~/src/myproject/src/app.nim     # one file
./corpus.sh /tmp/out 120                     # the standard library, nimble packages and the compiler
```

`NED_PKGS` is the nimble packages folder (default `~/.nimble/pkgs2`); `corpus.txt` lists the files, and a
package that is not installed is skipped (`nimble install chronos jsony pixie jester cligen karax vmath` for
all of them). nimsuggest comes from `PATH`.

### What the editor answers: parity.py (6.22)

`parity.py` asks nedls — ned's engine as a language server, so what ned's editor answers too — and nimsuggest the
same questions. In a `.nim`, at `--n` random places: is there a hover where nimsuggest's `def` knows the name, does
it name the same declaration (file and line) and show its doc comment, is a name nimsuggest's `sug` offers offered,
is the signature help just inside `name(` that routine's. In a `.nims`, a `.nimble` and a plugin (nimsuggest reads a
script as a program, so there the file's own API is the reference): does every name of system's NimScript part,
nimble's API and ned's plugin API used in it have a hover with its doc comment, is it offered by completion, does go
to definition reach it, and are the tasks in the outline.

```sh
nim c -d:release -o:/tmp/nedls src/nedls.nim
tests/engine/parity.py --nedls /tmp/nedls --n 40 ~/Nim/lib/pure/json.nim ~/Nim/config/config.nims \
  ~/Nim/dist/atlas/atlas.nimble examples/plugins/*/plugin.nim*
```

It prints each file's misses (`--show K` of each kind) and the totals; `--min-hover P` makes it exit 1 when a share is
under P (for CI), `--json OUT` writes the counts. 6.22, `--n 40`, on parseutils, strformat, json, paths, times,
sequtils, tables, ospaths2, the compiler's lineinfos and options, atlas.nim and its context.nim, nimble.nim, Nim's,
atlas' and nimble's config.nims and .nimble files and the five example plugins:

| | |
|---|---|
| hover where nimsuggest knows the name · the same declaration · its doc comment | 370/370 · 367/370 · 91/92 |
| completion · signature help | 353/354 · 99/99 |
| scripts and plugins: API names with a hover and its doc · offered · go to definition | 160/160 · 160/160 · 136/136 |
| scripts and plugins: names with a hover · tasks in the outline | 444/444 · 3/3 |

The three declarations that differ: `x.string.dup(normalizePath)` (ned offers the three overloads), `setLen` under
ARC (nimsuggest names seqs_v2's, ned system's declaration) and a field nimsuggest takes for the iterator `items`.

### Speed and memory

`bench.nim` reads files and everything they import, answers again after an edit, completes at the end, and
prints the time and the memory held:

```sh
nim r -d:release tests/engine/bench.nim ~/Nim/compiler/semexprs.nim ~/Nim/compiler/vm.nim
```

On five of the Nim compiler's modules and ned itself (462 files read, 21 700 declarations), 6.6 against 6.5.1 —
names kept in one sorted index per scope instead of a table, positions as 32-bit numbers, at most 12 scopes:

| | 6.5.1 | 6.6 |
|---|---|---|
| semexprs.nim: read with its 123 imports · after an edit · completion | 203 · 5.5 · 11.3 ms | 198 · 5.4 · 11.3 ms |
| memory after all six | 27.7 MB | 22.4 MB |
| ned with 25 compiler modules opened one after another | 82 MB | 46 MB |

`NED_NS_CACHE=/tmp/ns-cache` keeps nimsuggest's answers: the next run on unchanged files (with the same
nimsuggest) asks it nothing, so comparing a new build of the engine over the whole corpus takes a minute instead
of an hour. The times reported for nimsuggest are the ones it took when it answered.

Where the two disagree, either can be the one that is wrong: nimsuggest answers nothing (`:`) inside some
templates, and it crashes on some files (the count is in each report; it is started again). Types are compared
after small differences in how they are written are taken out: `system.int` is `int`, `lent string` is
`string`, `array[0..1, T]` is `array[2, T]`, `tuple[a, b: int]` is `tuple[a: int, b: int]`, pragmas of proc
types are left out.

## C: ned against clangd

`ccompare.py` asks ned's C engine (`cdriver.nim`, the engine as a program) and clangd the same questions about
C and C++ files:

1. **go to definition** at random identifiers — is ned's first answer the file and line of clangd's?
2. **hover** at the same places, where clangd's is a function's or a method's — are the parameter types the same
   (of several overloads, the same one)?
3. **member completion** right after `->` and `.` — is the member written there offered?

```sh
nim c -d:release -o:/tmp/ned-cengine tests/engine/cdriver.nim
cd ~/src/openssh && python3 ~/ned/tests/engine/ccompare.py /tmp/ned-cengine /tmp/out ssh.c sftp.c … --bg-index
```

For clangd to be at its best, the files' folder needs a `compile_commands.json` (`bear -- make`, or CMake's
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`); ned gets its `-I`, `-D` and `-U`, and the compiler's own macros
(`cc -dM -E`, `c++ -dM -E -x c++` for C++), as the editor does. `--bg-index` lets clangd index the whole project
first, so that it knows the bodies in the other `.c` files (ned looks them up when asked). Code the configuration
leaves out (`#ifdef` branches not taken — clangd reports them) is not asked about: clangd has no answer there, only
a guess by name.

Last run (clangd 18.1.3, `--n 40`, no `--bg-index`), ned 6.24 → 6.25 where they differ:

| | OpenSSH (18 files) | zsh (12 files) | Lua (8 files) |
|---|---|---|---|
| go to definition: the same answer | 90.8% → 91.1% (656 of 720) | 89.1% (427 of 479) | 94.0% (299 of 318) |
| hover: the same parameters | 84.2% → 94.7% (108 of 114) | 89.3% (50 of 56) | 95.5% (21 of 22) |
| member completion: ned · clangd | 98.7% · 99.1% (of 226) | 100% · 94.2% (of 156) | 98.1% · 91.3% (of 104) |
| a file's first answer: ned · clangd | 10 → 8 ms · 0.18 s | 9 ms · 0.14 s | 5 ms · 0.08 s |
| each answer after: ned · clangd | 0.3–0.6 ms · 0.3 ms | 0.5 ms · 0.3 ms | 0.24 ms · 0.4 ms |
| memory at the end: ned · clangd | 48 → 70 MB · 149 MB | 36 → 48 MB · 112 MB | 16 → 22 MB · 65 MB |

| C++ | tinyxml2 (2 files, `--n 200`) | LevelDB (14 files) |
|---|---|---|
| go to definition: the same answer | 80.8% → 87.8% (338 of 385) | 93.6% → 93.8% (454 of 484) |
| hover: the same parameters | 82.6% → 95.9% (116 of 121) | 97.8% → 98.9% (88 of 89) |
| member completion: ned · clangd | 99.2% · 96.2% (of 132) | 90.1% · 98.4% (of 182) |
| a file's first answer: ned · clangd | 28 ms · 0.14 s | 2 ms · 0.34 s |
| memory at the end: ned · clangd | 11 MB · 142 MB | 12 MB · 249 MB |

(The memory ned 6.25 takes more: the macros of every header it reads, kept to work out the `#if`s of the next
file. With clangd 22 and `--bg-index`, ned 6.5 agreed with it at 97.8% on OpenSSH and 97.3% on zsh: the background
index knows the bodies in the other files.)

Where they differ, it is mostly what only the build decides. ned works out `#if` — the compiler's macros,
`compile_commands.json`'s `-D` and `-U`, the `#define`s of the file and of the headers it includes — but a macro
defined only where ned does not look (a `config.h` not generated yet, a flag with no `compile_commands.json`) is
not known: both branches are read, and of two that declare the same name the first is taken. A header's `#if`s do
not see the macros the file including it defines before the `#include`. A name that is also a macro (`#define
stdout stdout`) goes to the declaration, not the macro. Branches that open or close a brace differently (`#ifdef X
 if (a) { #else  if (b) {`) are read as the first, as ctags does. Declarations made by macros are read
(`DECLARE_GETTER(width, int)` declares `get_width`), and so are macros used as expressions (`#define atime tv[0]`,
`P_OPERAND(p)->l`). In C++, dependent types, `decltype` and concepts are not understood, and of overloads whose
arguments ned cannot tell apart, the first is taken.
