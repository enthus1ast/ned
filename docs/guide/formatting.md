# Formatting

Alt+F (*Format document*) formats the file; with lines selected, only those lines. `"editor.formatOnSave": true`
formats on every save — only the lines you changed with `"editor.formatOnSaveScope": "changed"` — and
*Format: preview the change* shows the result side by side first. *Format: every file in the project…* does a
whole project, with a review.

Which formatter: ned's own for Nim, C and C++ (when clang-format is not chosen), JSON, Markdown tables, CSS, HTML,
SQL, YAML and TOML; a language server's formatting when one offers it; your own command for any language in the
`formatters` setting (`{"python": "ruff format -"}`), which always wins.

- [Nim](#nim) — nph's style, your layout settings, `# fmt: off`
- [C and C++](#c-and-c) — clang-format's styles in ned's own formatter, or clang-format
- [From the shell: nedfmt](#from-the-shell-nedfmt)
- [Other languages](#other-languages)

## Nim

Alt+F (*Format document*) and `"editor.formatOnSave": true` use ned's own formatter. It formats the way nph does:
- 2-space indentation, and spaces around operators and after commas;
- one statement per line, with a blank line after multi-line routines and types;
- `proc f()` with an empty parameter list, and long import lists packed (one module a line when they are paths
  such as `std/os`);
- `if` and `case` written out on several lines unless every branch is a plain value;
- calls, parameter lists and collections wrapped at 88 columns, with a trailing comma when they take
  several lines;
- comments kept, and a trailing comment that does not fit moved under its line (a lone `## doc` line under
  a statement joins it when it fits);
- a long `from x import …` with the names on the next line.

With several lines selected, Alt+F (or *Format selection*) formats only those lines, at their indentation.
Statements between `# fmt: off` and `# fmt: on`, and one ending in `# fmt: skip` (black's and ruff's comments;
nph's `#!fmt: off` too), are left as written and only moved to their new indentation.

Its layout is yours to choose (settings, Nim section):

| setting | default | |
|---|---|---|
| `nim.format.lineLength` | 88 | where lines wrap (80 and 100 are common too); not written in your settings or the project's: a file's `.editorconfig` `max_line_length` |
| `nim.format.params` | `fit` | a routine's parameters: `fit` — on one line, else all on the next line or one per line (nph) · `onePerLine` — one per line when too long · `always` — one per line when there are two or more · `keep` — your line breaks |
| `nim.format.arguments` | `fit` | a call's arguments: the same four (`fit` packs them on the next lines) |
| `nim.format.collections` | `fit` | array, seq, table, set and tuple literals: the same four |
| `nim.format.imports` | `keep` | `sort` — std/, pkg/, others, ./relative · `merge` — sorted, and `std/a` + `std/b` → `std/[a, b]` (module initialisation follows import order: keep it if that matters) |
| `nim.format.align` | off | line up object field types and the `=` of const / let / var members |
| `nim.format.alignComments` | off | the comments at the end of lines that follow each other at one column (the one they share when there is room, else two after the longest line) |
| `nim.format.magicTrailingComma` | off | a list ending in a comma before its bracket, written one element a line or on one line, stays one element per line (black, ruff) |
| `nim.format.normalizeNumbers` | off | `0x`, `0b`, `0o` in lower case, hex digits in upper case, `e` for an exponent (ruff) |
| `nim.format.docCode` | off | the Nim in ```` ```nim ```` fences and `.. code-block:: nim` blocks of `##` comments formatted too |
| `nim.format.reflowDocComments` | off | re-wrap a `##` paragraph with a line longer than the line length (lists, tables and code stay) |
| `nim.format.reflowComments` | off | the same for `#` paragraphs of prose — what reads as commented-out code, lists, TODOs and `# ned:` directives stay; a banner's rule (`# ── Section ────`) is cut to fit |
| `nim.format.maxBlankLines` | 1 | empty lines kept in a row (up to 3) |
| `nim.formatEmitC` | on | the C in `{.emit: """…""".}` formatted too: clang-format while clangd is the C engine (your `.clang-format`), else ned's own C formatter in `c.format.style` at the Nim's indentation and line length |
| `editor.formatOnPaste` | `indent` | pasted lines take the indentation of where they go · `format` — and pasted Nim is formatted · `off` |

### Before and after

What each setting does to the same code — what `nedfmt` writes with the setting in the project's
`.ned/settings.json`.

**`nim.format.params`** — `fit` (the default, nph's layout) puts the parameters on one line if they fit, else on the
next line, else one per line; `onePerLine` goes straight to one per line; `always` does that even when it fits:

```nim
proc connect(host: string, port: int, timeout: float, retries: int, verbose: bool): Connection =
```

| `fit` | `onePerLine` |
|---|---|
| <pre>proc connect(<br>    host: string, port: int, timeout: float, retries: int, verbose: bool<br>): Connection =</pre> | <pre>proc connect(<br>    host: string,<br>    port: int,<br>    timeout: float,<br>    retries: int,<br>    verbose: bool,<br>): Connection =</pre> |

With `always`, `proc short(a: int, b: int): int` too becomes `proc short(` ⏎ `a: int,` ⏎ `b: int,` ⏎ `): int =`.
`keep` leaves the line breaks you wrote.

**`nim.format.arguments`** — the same four for a call. `fit` packs the arguments on the next line:

```nim
let conn = openConnection(defaultHost, defaultPort, timeout = 30.0, retries = 5, verbose = true, logFile = path)
```

| `fit` | `onePerLine` |
|---|---|
| <pre>let conn = openConnection(<br>  defaultHost, defaultPort, timeout = 30.0, retries = 5, verbose = true, logFile = path<br>)</pre> | <pre>let conn = openConnection(<br>  defaultHost,<br>  defaultPort,<br>  timeout = 30.0,<br>  retries = 5,<br>  verbose = true,<br>  logFile = path,<br>)</pre> |

**`nim.format.collections`** — the same four for array, seq, table, set and tuple literals. At a line length of 50,
`const primes = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43]` and `const sizes = [8, 16, 32]`:

| `fit` | `always` |
|---|---|
| <pre>const primes = [<br>  2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41,<br>  43,<br>]<br>const sizes = [8, 16, 32]</pre> | <pre>const primes = [<br>  2,<br>  3,<br>  …<br>  43,<br>]<br>const sizes = [<br>  8,<br>  16,<br>  32,<br>]</pre> |

`onePerLine` writes `primes` as `always` does and leaves `sizes`, which fits, on one line. `keep` leaves
`let t = {"a": 1,` ⏎ `"b": 2, "c": 3}` as it is, where `fit` joins it: `let t = {"a": 1, "b": 2, "c": 3}`.

**`nim.format.imports`**:

```nim
import strutils, ./util, std/os
import pkg/jsony
import std/tables
```

| `keep` | `sort` | `merge` |
|---|---|---|
| as written | <pre>import std/os, strutils, ./util<br>import pkg/jsony<br>import std/tables</pre> | <pre>import std/[os, tables], pkg/jsony, strutils, ./util</pre> |

`sort` orders the modules of each `import`: `std/` first, then `pkg/`, the others, and `./` relative ones last;
`merge` also joins imports that follow each other into one.

**`nim.format.align`** and **`nim.format.alignComments`**:

| off (the default) | on |
|---|---|
| <pre>type Point = object<br>  x: int<br>  name: string<br>  visible: bool<br><br>const<br>  width = 80<br>  maxHeight = 24</pre> | <pre>type Point = object<br>  x:       int<br>  name:    string<br>  visible: bool<br><br>const<br>  width     = 80<br>  maxHeight = 24</pre> |
| <pre>var<br>  x = 0 # the column<br>  lineNumber = 1 # the line, from 1</pre> | <pre>var<br>  x = 0           # the column<br>  lineNumber = 1  # the line, from 1</pre> |

**`nim.format.magicTrailingComma`** — a comma before the closing bracket keeps the list one element a line:

| off (nph) | on (black, ruff) |
|---|---|
| <pre>let flags = [optA, optB]<br>call(first, second)</pre> | <pre>let flags = [<br>  optA,<br>  optB,<br>]<br>call(<br>  first,<br>  second,<br>)</pre> |

— from `let flags = [optA, optB,]` and `call(` ⏎ `first,` ⏎ `second,` ⏎ `)`.

**`nim.format.normalizeNumbers`** — `0Xff'u8` → `0xFF'u8`, `1E10` → `1e10`, `0B1010` → `0b1010` (a literal with a
suffix of your own, `0xdeadbeef'big`, is left alone).

**`nim.format.docCode`** — the code in a doc comment formatted too:

| off | on |
|---|---|
| <pre>  ## &#96;&#96;&#96;nim<br>  ## echo area( 3,4 )<br>  ## &#96;&#96;&#96;</pre> | <pre>  ## &#96;&#96;&#96;nim<br>  ## echo area(3, 4)<br>  ## &#96;&#96;&#96;</pre> |

**`nim.format.reflowDocComments`** and **`nim.format.reflowComments`** — a paragraph with a line that is too long is
wrapped again (here at a line length of 60):

| off | on |
|---|---|
| <pre>  ## Reads the configuration from &#96;s&#96;, which holds the text of a settings file, and returns it with every default filled in.</pre> | <pre>  ## Reads the configuration from &#96;s&#96;, which holds the text<br>  ## of a settings file, and returns it with every default<br>  ## filled in.</pre> |
| <pre># This module keeps the list of open files, and saves it with the session when the editor quits normally.</pre> | <pre># This module keeps the list of open files, and saves it<br># with the session when the editor quits normally.</pre> |

**`nim.format.maxBlankLines`** — three empty lines between two statements become one (the default), or two with
`2`.

**`nim.format.lineLength`** — where lines wrap. `proc render(view: View, width, height: int, theme: Theme): string`
fits at 88; at 60 it is written `proc render(` ⏎ `view: View, width, height: int, theme: Theme` ⏎ `): string =`.

### How it stays safe

It works on tokens and checks every result before writing it: the same tokens in the same order (doc comments
included), the same block structure, and line breaks only where Nim's parser reads the line on — after `,` `(` `[`
`{` `{.` `=` `:`, an operator or `import`, before a closing bracket, a `.` or a branch, or where you already had one;
a line break your code needs, between two statements, always stays. If anything would differ, it changes nothing
and names the file, so you can report it. Long string literals and code with statements inside brackets (a lambda's
body, `do` blocks) keep their layout. All seven layout settings (`fit`, `onePerLine`, `always`, `keep`, other widths,
alignment) are checked with Nim's own parser over the 3,800 files of Nim's compiler, standard library and tests:
only files Nim cannot read in the first place come out read differently.

**Nim's own parser as a second check** (`nim.format.verify`, `nedfmt --verify`). Where the compiler's sources are
installed — choosenim and source builds have them, or `nimble install compiler` — ned builds a small checker from
them once (in the background, about half a minute) and asks it whether each formatted file parses to the same
syntax tree as before, comments and layout aside. A file it reads differently is left alone. The formatter's own
token and block check runs anyway; this one is for when you want the compiler's word on it. `nimble parsecheck`
runs it over 463 files of Nim's compiler and standard library.

### Compared with nph

How it compares with nph, on Nim's compiler and standard library:

| | built-in | nph |
|---|---|---|
| lines identical to nph's output | 99.8% of 198 000 | — |
| same code for Nim's parser (463 files) | all | all |
| semexprs.nim, 3 598 lines | 14 ms | 24 ms |
| strutils.nim, 3 069 lines | 7.5 ms | 10.5 ms |
| json.nim, 1 398 lines | 4 ms | 6.5 ms |
| json.nim, already formatted | 4 ms | 6.5 ms |

Both measured on the same (slow) machine; nph's times include starting the program, which ned also has to do when
it runs nph. Where the two still differ — about two lines in a thousand — it is mostly a token nph rewrites (a
`tuple` with comments, `s.fromHex[:int16]`), a long call's arguments, or a comment inside a parenthesized
condition.

To use nph or nimpretty instead, set `"nim.formatter": "nph"` (or `"nimpretty"`), or pick *Nim: format with nph*
in the palette. Your own `formatters` entry for `nim` always wins.

## C and C++

ned's own **C formatter** (used for the emits, and for `.c` files when clang-format is not installed or
`c.formatter` is `builtin`) lays C out in clang-format's styles — `c.format.style`: `LLVM`, `Google`, `Chromium`,
`Mozilla`, `WebKit`, `Microsoft`, `GNU`, `Linux`, or `auto` (the default): the project's `.clang-format`, read with
its `BasedOnStyle` and common keys, and without one `keep` — indented by the braces, spaces evened out (after
commas and keywords, around assignments and comparisons, none inside brackets), your line breaks kept.
`c.format.options` adds clang-format keys over the style. `// clang-format off` … `on` and `#if 0` blocks stay as
written. On Lua's sources 96.4% of the lines come out as clang-format 18 writes them in LLVM's style (the other
styles: 86–96%; `tests/format/cfmtcompare.py`). Like the Nim one, it checks that the code is the same token for
token, or changes nothing. `c.formatter`: `auto` (clang-format while clangd is the C engine, else ned's own),
`clang-format`, `builtin`.

The styles it knows, and what each changes:

| style | indent | braces | short functions on one line | pointers | column limit |
|---|---|---|---|---|---|
| `LLVM` | 2 | attached | all | `int *p` | 80 |
| `Google` | 2 | attached | all | `int* p` | 80 |
| `Chromium` | 2 | attached | empty ones | `int* p` | 80 |
| `Mozilla` | 2 | a function's and a type's on their own line | none | `int* p` | 80 |
| `WebKit` | 4 | a function's on its own line | all | `int* p` | none |
| `Microsoft` | 4 | each on its own line | none | `int *p` | 120 |
| `GNU` | 2 | each on its own line, indented | none | `int *p` | 79 |
| `Linux` | 8 (tabs) | a function's on its own line | none | `int *p` | 80 |

The same code in four of them (what `nedfmt` writes; `…` is the last two lines, re-indented):

```c
struct point { int x; int y; };
static int dist(struct point *a, struct point *b) {
    if (a == NULL || b == NULL) return -1;
    int dx = a->x - b->x, dy = a->y - b->y;
    return dx * dx + dy * dy;
}
```

| `LLVM` | `Linux` |
|---|---|
| <pre>struct point {<br>  int x;<br>  int y;<br>};<br>static int dist(struct point *a, struct point *b) {<br>  if (a == NULL &#124;&#124; b == NULL)<br>    return -1;<br>  …<br>}</pre> | <pre>struct point {<br>	int x;<br>	int y;<br>};<br>static int dist(struct point *a, struct point *b)<br>{<br>	if (a == NULL &#124;&#124; b == NULL)<br>		return -1;<br>	…<br>}</pre> |

| `GNU` | `Mozilla` |
|---|---|
| <pre>struct point<br>{<br>  int x;<br>  int y;<br>};<br>static int<br>dist (struct point *a, struct point *b)<br>{<br>  if (a == NULL &#124;&#124; b == NULL)<br>    return -1;<br>  …<br>}</pre> | <pre>struct point<br>{<br>  int x;<br>  int y;<br>};<br>static int<br>dist(struct point* a, struct point* b)<br>{<br>  if (a == NULL &#124;&#124; b == NULL)<br>    return -1;<br>  …<br>}</pre> |

`keep` only re-indents (by 2 here) and evens out the spaces: `struct point { int x; int y; };` and
`if (a == NULL || b == NULL) return -1;` stay on one line. On top of a style, `c.format.options` takes
clang-format's keys — `{"PointerAlignment": "Left", "BreakBeforeBraces": "Allman",
"AllowShortIfStatementsOnASingleLine": true}` over `LLVM` gives `struct point* a`, every brace on its own line and
`if (a == NULL || b == NULL) return -1;` on one line.

A `.clang-format` in the file's folder or above it is read when `c.format.style` is `auto`: `BasedOnStyle` and
`IndentWidth`, `UseTab`, `TabWidth`, `ColumnLimit`, `ContinuationIndentWidth`, `BreakBeforeBraces` (and
`BraceWrapping`), `PointerAlignment`, `DerivePointerAlignment`, `SpaceBeforeParens`, `IndentCaseLabels`,
`SpacesBeforeTrailingComments`, `AlignTrailingComments`, `AlignConsecutiveMacros` / `Assignments` / `Declarations`,
`AlignAfterOpenBracket`, `AlignOperands`, `AlignEscapedNewlines`, `AllowShortFunctionsOnASingleLine`,
`AllowShortIfStatementsOnASingleLine`, `AllowShortLoopsOnASingleLine`, `AllowShortBlocksOnASingleLine`,
`AllowShortCaseLabelsOnASingleLine`, `Cpp11BracedListStyle`, `SpaceAfterCStyleCast`, `BreakBeforeBinaryOperators`,
`AlwaysBreakAfterReturnType`, `IndentBraces`, `KeepEmptyLinesAtTheStartOfBlocks`, `MaxEmptyLinesToKeep`. Keys it
does not know are left to the style.

How close it is: `python3 tests/format/cfmtcompare.py ./nedfmt FILE.c … --style LLVM` formats the files with both
and counts the lines that come out the same. On 40 files of Lua with clang-format 18: LLVM 96.4% (97.7% with
`ColumnLimit: 0`), WebKit 96.2%, Microsoft 96.3%, Chromium 95.2%, Mozilla 94.9%, Google 94.1%, GNU 86.5%; zsh
96.1% and OpenSSH 93.6% in LLVM's style. Most of the rest is how a long braced initializer list is packed into
columns, and a few line-break choices.

**C in a Nim file's `{.emit: """…""".}`** is formatted with the Nim file (`nim.formatEmitC`): by clang-format
while clangd is the C engine, else by ned's own in `c.format.style`, at the Nim file's indentation and its line
length less the block's.

## From the shell: nedfmt

From the shell: **`nedfmt`** — the same formatters as a small program of their own (`nimble install` builds it
next to ned; `ned --format` is the same command) — with nph's options:

```sh
nedfmt src/ tests/                 # format in place (in a git repository: the files git knows, not ignored ones)
nedfmt --check .                   # CI: exit 1 when a file would change, nothing written
nedfmt --diff x.nim                # a unified diff of what would change
cat x.nim | nedfmt -               # stdin to stdout (--stdin-name=path/x.nim: its kind and its project's settings)
nedfmt --outDir:out src/           # write beside, the originals untouched (--out:FILE for one file)
nedfmt --install-hook              # a git pre-commit hook: the staged Nim files must be formatted
nedfmt --verify src/               # check every Nim result with Nim's own parser too (below)
```

`--exclude`, `--extend-exclude` and `--include` take regular expressions, and nph's `.nph.toml` (exclude,
extend-exclude, include) is read too, so a project set up for nph needs nothing new; files named on the command
line are always taken. The layout settings (`nim.format.*`) come from your settings and the project's
`.ned/settings.json`; where neither sets the line length, a file's `.editorconfig` `max_line_length` does — as in
the editor, where `.nph.toml`'s excludes also keep a file from being formatted on save or by *Format: every file in
the project*. Exit status: 0 done, 1 `--check` found files to change, 2 a file was left alone (the
formatter was not sure of it) or could not be read, 3 wrong arguments. The hook checks what is staged, not your
working copy; a file the formatter is not sure of does not stop the commit, and `git commit --no-verify` skips it.
*Format: every file in the project…* does it from the editor, with a review first (see the 5.24 notes).

## Other languages

JSON, Markdown (tables), CSS, HTML and SQL have built-in formatters too, used when prettier (or a formatter of
yours) is not installed: HTML blocks on lines of their own and indented, what `<pre>`, `<script>`, `<style>` and
`<textarea>` hold kept as it is, templates (`{{ }}`, `{% %}`, `{expr}`) untouched; SQL one clause a line, keywords in
upper case, strings, comments and placeholders untouched. Like the others they check their result, or change
nothing.
