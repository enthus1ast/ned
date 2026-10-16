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
C files:

1. **go to definition** at random identifiers — is ned's first answer the file and line of clangd's?
2. **member completion** right after `->` and `.` — is the member written there offered?

```sh
nim c -d:release -o:/tmp/ned-cengine tests/engine/cdriver.nim
cd ~/src/openssh && python3 ~/ned/tests/engine/ccompare.py /tmp/ned-cengine /tmp/out ssh.c sftp.c … --bg-index
```

For clangd to be at its best, the files' folder needs a `compile_commands.json` (`bear -- make`, or CMake's
`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`); ned gets its `-I` folders, as the editor does. `--bg-index` lets clangd
index the whole project first, so that it knows the bodies in the other `.c` files (ned looks them up when asked).
Code the configuration leaves out (`#ifdef` branches not taken — clangd reports them) is not asked about: clangd
has no answer there, only a guess by name.

Last run (clangd 22, ned 6.5, `--n 40`):

| | OpenSSH (18 files) | zsh (12 files) |
|---|---|---|
| go to definition: the same answer | 97.8% (635 of 649) | 97.3% (465 of 478) |
| member completion: ned · clangd | 100% · 95.1% (of 183) | 99.4% · 97.4% (of 156) |
| a file's first answer: ned · clangd | 13 ms · 0.17 s | 13 ms · 0.21 s |
| each answer after: ned · clangd | 0.33 ms · 0.2 ms | 0.46 ms · 0.3 ms |
| memory at the end: ned · clangd | 37 MB · 274 MB | 31 MB · 160 MB |

Where they differ, it is mostly what only the build's configuration decides: ned does not run the preprocessor,
so of two `#ifdef` branches that declare the same name it takes the first (`#ifndef HAVE_STRUCT_ADDRINFO` and the
system's own), and a name that is also a macro (`#define stdout stdout`) goes to the declaration, not the macro.
Branches it does decide: `#if 0`, C++-only code (`__cplusplus`, `extern "C++"`), and the compiler's target
(`__x86_64__`, `_WIN32` … from `cc -dM -E`). Branches that open or close a brace differently (`#ifdef X  if (a) {
#else  if (b) {`) are read as the first, as ctags does. Declarations made by macros (`local_list1(foo);`) are not
understood; macros used as expressions are (`#define atime tv[0]`, `P_OPERAND(p)->l`).
