# Nim IDE: the built-in engine

ned 5 understands Nim itself. Its index reads your files, the standard library and your nimble packages
as you work. It answers completion, hover, go to definition, signature help, references, rename, the
outline and symbol search immediately, with no compiler run and no server process.

**How it finds things.** Imports are resolved like the compiler resolves them:
1. next to the importing file;
2. `std/…`, and the search paths that `nim dump` reports for your project (so `--path` lines in
   `config.nims` and `nim.cfg` count);
3. the package's `srcDir`, so tests and examples can `import mypkg`;
4. the newest installed version of each nimble package, including `nimbledeps/` and atlas `deps/`.

`export`, `include`, `from … import`, `except` and `import … as` are followed. A file that another one
`include`s sees what its includer sees: the includer's imports, its declarations and its other include files
(the includer is looked for in the file's folder and the one above). `when` branches are evaluated for your
platform and for what your project's config defines (`nim dump` lists it, so a symbol it leaves out is false).
What `nim dump` said is kept (`~/.cache/ned/dump`) with the times of the files it read — the config files, the
`.nimble`, its lock, the package folders, `nim` itself — so the next session has it from the first screen; it is
asked again once a session. Names are compared style-insensitively, as Nim does. Your open, unsaved buffers count
over the files on disk.

**How it knows types.** From declarations, literals and call results, through chains like
`t.getOrDefault(k).len`. Generics are filled in from arguments (`some(5)` is an `Option[int]`,
`initTable[string, int]()` a `Table[string, int]`, `convert(Seconds, Nanoseconds, x)` x's type) and through
aliases (`Vec2 = GVec2[float32]`, so `v.x` is a `float32`). It also handles:
- loop variables (`for k, v in t.pairs`, a type's own `items` and `pairs` iterators) and tuple unpacking
  (`let (a, b) = …`);
- object fields including inherited ones, `ref`/`ptr` dereferences (`t[]`), and `x{…}` / `x[…]`
  accessors;
- values over several lines (`let x = if c:` / `case k` / `try:` / `block:`, or on the line after `=`),
  aliases (`BiggestInt` is `int64`) and conversions in every spelling (`x.float`, `fd.AsyncFD`, `BiggestUInt 1`);
- operators as Nim types them: `/` of integers is a `float`, `a .. b` an `HSlice`, `and`/`or` of integers an
  integer, `5 * x` x's type, `n - 1` of a `Natural` an `int`, `Time - Duration` a `Time`;
- overloads by their number of arguments and by all of their types (`sock.recv(10)` is a `string`,
  `recv(sock, buf, 10)` an `int`), and generic parameters by their constraints (`[T: SomeInteger]`);
- routines inside routines, an async proc's `result` (what its Future holds), a macro's `untyped` arguments
  (`NimNode`s);
- what a template of the file declares (`genVecConstructor(vec, Vec, float32)` makes `vec2`, `vec3` …);
- block scoping: a `let` in one `of` branch is not seen in the next;
- generic objects built with or without their arguments (`Box[int]()`, `Box(val: "x")` is a `Box[string]`), a
  generic routine's instance on hover (`T = int`), what a concept asks of a value of its type, statements after `;`.

**Type hints.** A `let`, `var` or `const` written without a type shows it after its name, in grey:
`let n: int = parseInt(s)`. The engine works them out 16 lines at a time, those on screen first, then ahead of
where you scroll — in a few milliseconds a round, so they are there when the lines come in — and once for each
version of the text: scrolling back works nothing out again. Calls show
their parameters' names before literal arguments — `draw(width: 10, height: 20, filled: true)` (`nim.parameterHints`:
`literals`, `all` or `off`).
`"nim.typeHints": "nimsuggest"` asks nimsuggest instead (when it is turned on); `"editor.inlayHints": false` turns them off.

**Chain hints** (`nim.chainHints`, on by default). When you write a call chain over several lines, with each line
starting with a dot, each line ends with the type of what that step gives:

```nim
let names = people
  .filterIt(it.age > 30)   : seq[Person]
  .mapIt(it.name)          : seq[string]
  .join(", ")
```

The last line has no chain hint when the chain is a `let`'s value, because the `let`'s own hint shows that type.

**The compiler as an oracle in the background** (`nim.compilerOracle`, on by default; with nimsuggest off, the
default). Some things the engine cannot work out by reading the code:

- the type of a `let` whose value comes from a macro or a `when compiles` branch;
- a generic the engine does not follow;
- which of several overloads a call picks.

For these, ned asks the compiler. After a pause in your typing, one nimsuggest run takes all the questions for the
lines around the screen, answers them and quits; no server is kept running. The unsaved text goes to it as a
private copy.

The answers are kept on disk (`~/.cache/ned/oracle`), by the text of each line and by what the file and the
project's modules it imports declare. A line you have not changed keeps its answer when you edit inside other
routines, and still has it the next time you open the file; when a declaration changes — a proc's return type in
another file — the answers that may depend on it are asked again. The answers are used by:

- the type hints;
- the hover of an overloaded call: **Called here — the compiler's choice: …**;
- Go to definition, which goes straight to that overload instead of listing them all;
- the one-question answers of `nim.compilerAnswers`, which are kept the same way.

**Completion: what you chose before comes first.** The items you chose lately are ranked higher, the latest
first. The ranking is per language and is kept between sessions (in the state file, the last 300). It counts most
right after a dot, before you type anything. The type wanted there still counts: in `draw(width = ` an `int` comes
before a `string`.

**Rename (F2)** changes every place that names the same declaration, and shows them all first. 6.25 extends its
reach in three ways:

- **strformat strings**: the name inside the `{…}` of `fmt"…"`, `&"…"` or `fmt("…")` is renamed too, unless a
  local of that name stands in the way. The format part after a `:` is left alone.
- **doc comments**: a name written in backticks in a `##` comment, such as `` `total` `` or `` `total()` ``, is
  renamed in the files whose code names it.
- **your other packages**: the files of a workspace's other folders and of the packages your `nimble.develop`
  names (from `nimble develop`) are included. A declaration in one of them can now be renamed; before 6.25 it was
  refused as outside the project.

**What completion offers:**
- After a `.`: the receiver's fields first, then the procs that take it exactly, then related ones
  (subtypes, `openArray`, wider numbers), then generic ones.
- A bare name: locals, then this module, then imports, then `system`, then keywords.
- `Foo(` lists `Foo`'s fields as `name: `, and after `import` it offers module names.
- Overloads are folded into one entry; the documentation lists every signature.

**How good it is.** The same questions to ned's engine and to nimsuggest, on 23 files of the standard library,
nimble packages and the compiler (see [What's new in 5.25](../../CHANGELOG.md#whats-new-in-525) for the list):

| | ned's engine | nimsuggest |
|---|---|---|
| type hints: the same as nimsuggest's | 99.3% | — |
| go to definition: the same place | 98.9% | — |
| a variable's type: the same | 98.6% | — |
| member completion: the member written there is offered | 98.9% | 74% |
| time for one question | 0.6 ms | 250 ms |

Where nimsuggest answers with a name it made up itself (a gensym'd symbol, an `:anonymous` proc) it counts as no
answer. What still differs is mostly where both answers are defensible (a name a template call declares: ned goes
to the call, nimsuggest into the template; a union-typed parameter, where nimsuggest reports the instance it
compiled), how a type is printed (an alias kept or expanded: `Fixed32` or `int32`), code in `when` branches that are
false here, and nimsuggest answers that point at another symbol on the line. The engine knows chronos' futures that
carry what they raise: a call of an `{.async: (raises: [A, B]).}` routine is an `InternalRaisesFuture[T, (A, B)]`,
as its macro makes it, and so is `Future[T].Raising([A, B])`. The comparison is in [tests/engine](../../tests/engine):
`tests/engine/build.sh && tests/engine/compare.py file.nim` runs it on your own code.

**Errors.** While you type, the compiler checks the unsaved text after a pause (`nim check`, reading it from
stdin in the file's folder: same imports, same config); a misspelled name is marked at once by the engine. On
save, `nim check` runs on the file. See [What's new in 5.26](../../CHANGELOG.md#whats-new-in-526).

**The engine's own checks, at once** (`nim.engineChecks`, on by default), half a second after you stop typing and
before the compiler's check: a field name that is a typo of one the object has (`p.lable` — *did you mean
'label'?*), a call with the wrong number of arguments for every routine of that name in scope, a call whose value is
neither used nor discarded, a literal that can never be the declared type (`let n: int = "3"`), an import nothing in
the file uses, code after a `return`, `raise`, `break` or `continue` in the same block, and a local `let`/`var`
nothing uses. The messages are the compiler's own, so the same quick fixes apply (Alt+Enter: discard the value,
remove the import). Only what the engine can be sure of: not inside templates and macros or what they are given,
not where an overload the engine cannot see could be the one called, not an import whose `$` or `==` code here might
call without naming it, not in `when` branches left out.

6.25 adds three more checks, also worded as the compiler words them, so its quick fixes apply:

- **A `case` over an enum that leaves values out**, without an `else`: *not all cases are covered; missing:
  {blue}*. Alt+Enter, *Add the missing branches*, writes `of blue: discard` for each missing value. The check also
  covers an object's `case kind: Kind`.
- **An argument that can never be the parameter's type**: a literal, or a variable declared with a type, given to
  the only routine of that name that takes that many arguments. For example, `twice("x")` when `twice` takes an
  `int` gives *type mismatch: got 'string' for '"x"' but expected 'int'*. Alt+Enter offers the conversion.
- **A method call whose value is neither used nor discarded**, such as `s.pop()` on its own line. Before 6.25 only
  `f(x)` was checked. Alt+Enter, *Discard the result*, fixes it.

6.32 adds more of the compiler's errors, in its words, before it runs:

- **An assignment it refuses**: to a `let`, a `const`, a `for` loop's variable or a parameter that is not `var` —
  *'n' cannot be assigned to* (rule `assign-let`).
- **A literal of the wrong type** given to a variable declared with a type (`s = 5` where `s` is a string), to
  `result`, or by `return` (*type mismatch: got 'int literal(5)' for '5' but expected 'string'*, rule
  `literal-type`).
- **A member an object of the project does not have**, when nothing of that name is in scope (*undeclared field:
  'colour' for type Point*, rule `field-missing`); a near miss of a field's name is still the typo hint. Not while
  the names that macro calls in the file, or in the project's modules it imports, make are unknown (*Names a macro
  makes*, below): `cfg.getTitle` may be one of them.

The rules are `case-missing`, `arg-type` and `discarded`. On Nim's own compiler and standard library (463 files) and
563 files of 19 nimble packages they report nothing the compiler would not — apart from a few mistakes in generic
code nothing instantiates, which the compiler never looks at; the compiler's word wins on any line where both say
something.

**Hints the compiler does not give** (`nim.engineHints`, on by default, with `nim.engineChecks`): a `var` nothing
changes afterwards — not assigned, not given to a `var` parameter, its address not taken, not touched by a template
or macro it is given to — *'limit' is never changed: it can be a let* (Alt+Enter makes it one, or every one in the
file); a parameter a routine of this module never uses (not an exported routine, a hook, an operator, an `importc`
or `exportc` one, a callback passed around, a stub, a typedesc that only picks the overload); a routine that never
sets its result, never returns a value and does not end in one (*it always returns the default value*); and a name
whose every declaration in scope is `{.deprecated.}`, in the compiler's own words so its quick fix (*Use newSum
instead*) applies. The var hints were checked on Nim's compiler and standard library: each of the 992 was made a
`let` and the file compiled again, with no new error (the few in files that do not compile on their own were read
by hand) — one of them is a loop in the standard library that never moves on.

**Can be a func** (with the hints above). A proc of this module with no side effects — it uses no module variable
(a `var`, `let`, threadvar or `{.global.}`) and calls nothing that has side effects (`echo`, I/O, a proc variable
not declared `{.noSideEffect.}`), as the compiler infers it — is marked *'add1' has no side effects: it can be a
func* (rule `can-be-func`). Alt+Enter makes it a func, or every one in the file; `ned --lint --fix:can-be-func`
does the same from the command line. Only when the engine is sure of every call; not on generic, forward-declared,
nested, importc/exportc/async procs, nor in a file built with strictFuncs. Each of the 1,797 hints on Nim's
compiler, standard library and 19 packages that could be checked was made a func and compiled again: no new error.

**Library names newer than your Nim** (`nim.minVersion`; empty: what the .nimble asks for). With `requires "nim >=
1.6.0"`, a standard-library name or module that Nim 1.6 does not have is marked: *'minmax' is not in Nim 1.6.20 or
older (Nim 2.0.0 has it)*, *module paths is not in Nim 1.6.20 or older*. It knows from a name's `{.since.}` and
from a table of what each release from 1.0 to 2.2.12 added (`.github/ci/nimapis.py` makes it from the releases'
libraries). Code inside a `when` that asks which Nim this is — `NimMajor`, `NimVersion`, `declared(…)`,
`compiles(…)` — is left alone. `"off"` turns it off.

**Memory layout** (`nim.memoryLayout`, on by default). Hover a type's name — where it is declared or where it is
used — and ned shows how it lies in memory: each field's offset, size and the padding after it, the total size and
alignment, as Nim's C code generator lays it out here (64-bit; 32-bit on i386 and ARM). Inheritance, case objects,
`{.packed.}`, `{.union.}`, `{.align.}` and generics given their arguments are followed; when ned cannot be sure
(importc types, unknown names, a `when` it cannot decide) it shows nothing. It matches the compiler's `sizeof`,
`alignof` and `offsetOf` for every one of 1,312 types of the standard library, the compiler and 19 packages. When
sorting an object's fields by alignment would make it smaller, Alt+Enter on its line reorders them, comments moving
with their field (*Reorder fields to save 8 bytes (32 → 24 B)*).

**Exception hints** (`nim.raisesHints`, off by default; View › Editor › Exception hints). A routine without a
`{.raises.}` of its own shows what it can raise before the `=` of its header — `{.raises: [IOError, OSError].}` —
as the engine works it out: its `raise` statements and the routines it calls, less what its `try … except`
catches. A hint appears only when the engine is sure of every call in the body; Defects are not listed, as in the
compiler's effects. Hovering a routine, or a call of it, shows the same list. Converters are counted too: one that
raises, applied where an argument or an assignment needs it, is listed; where ned cannot tell whether one applies,
there is no hint. For 1,422 routines compared with the compiler's `{.effects.}`, they agree.

**Why?** Tap a routine's exception hint — or put the cursor in a routine and run *Nim: why?* (the Nim menu ›
Inspect, the editor's right-click menu, the Nim dock) — and ned shows where an exception comes from: the call in
the routine that raises it, the call in that routine that does, and so on down to the `raise` (or the routine that
declares it in its `{.raises.}`). Each step is a row; Enter goes there. A routine that raises several asks which
one first. For a routine with side effects — one that cannot be a func — it is the same down to the global it
uses or the routine that says it has side effects (`echo`). On a compiler's *can raise an unlisted exception* or
*can have side effects*, Alt+Enter offers *Why?* for it.

**Concepts.** Hover a concept to see the project's types that satisfy it (*satisfied by: `Circle`, `Square`*),
hover a type to see the concepts it satisfies; *Go to implementation* on a concept lists those types. The new
syntax (routines on `Self`) is matched as the compiler matches it, the old one (`concept x, y`) in its common forms
(`x.f is T`, `f(x)`, `x < y is bool`, `x.field`, `x[i]`, `$x`). A type is listed only when ned is sure: for 700
answers compared with the compiler's `T is C`, they agree. A call of a routine that takes a concept, given an
argument whose type is not one, says so on hover, with what the type lacks (*`Foo` is not a `Shape` — it has no
`proc area(s: Foo): float`*).

**Async, raises and gcsafe, before compiling.** The engine's checks say what the compiler would — or what only
shows when the program runs: a discarded Future (`discard fetch()` loses its error: `asyncCheck` it, or `await`
it), `await` outside an `{.async.}` proc, `waitFor` inside one, `os.sleep` in an async proc (it stops every task:
`await sleepAsync`); a routine whose `{.raises: [...].}` leaves out an exception its body can raise (the compiler
refuses it; with `nim.engineHints` on); a `{.gcsafe.}` or `{.thread.}` routine that uses a global
`seq`, `string`, `ref` or `Table` (rules `async`, `raises`, `gcsafe`).

**The package versions your build uses.** The engine reads each nimble package in the version your project builds
with: the package folders your config puts on the path (nimble.paths, atlas' nim.cfg), then the versions
nimble.lock pins, a local `nimbledeps/` or atlas `deps/`, then the newest installed version that meets the
`requires` of your .nimble and of those packages in turn. Only a package nothing asks for uses the newest
installed. Each open project has its own versions, and the Nim dock shows each requirement's version and why, e.g.
`jsony 1.1.5 (nimble.lock)` (also *Nim: language server status*); *Nimble: dependency tree* shows the same versions
as a tree, each package under what requires it, with what that version requires in turn. A package installed while ned
runs — `nimble install` in its terminal or another, `nimble setup`, atlas — is seen within a few seconds: the engine
reads the package folders again, nimsuggest and nimlangserver start again (they read them only when they start),
and the open Nim files are checked again, so an `import` of it is no longer *cannot open file*.

A folder counts as a package only when nimble or atlas made it: under your toolchain's package folders (NIMBLE_DIR,
what `nim dump` reports, the open project's `nimbledeps/` and `deps/`), a nimble folder name with its checksum
(`pkgs2/jsony-1.1.5-<sha1>`), `.nimble/pkgs/name-1.2.3`, a project's `nimbledeps/pkgs2/…`, or the `deps/` of a
project atlas set up (its `nim.cfg` section or `atlas.config`). A folder of yours that is merely called `deps`,
`pkgs` or `pkgs2` is read as your own code, with your project's versions.

**Completion by the expected type.** Where the code expects a type — a call argument (also when the call is
written over several lines), a parameter's default in a routine's header (`proc p(c: Color = `), `let x: T = `, `x = `,
`result = `, `return `, a comparison, a field in `Foo(name: …)` — completion lists what has that type first:
values, enum values, fields and routines returning it, subtypes and numbers that convert without a cast included.
The rest stays in the list behind them. After `p.` in such a place, p's members of that type come first.

**The engine worker** (`nim.engineWorker`, on by default). Type and parameter hints, the engine's checks and
misspelled names, reference counts and ned's own CSS, HTML, SQL and JavaScript checks are worked out by a second
ned on another processor core; the editor sends it the open files' text (then only what changed) and shows the
answers as they come. Typing, scrolling and opening files never wait for them. It also keeps the index's disk cache
tidy. Off: the editor works them out itself, a few ms at a time, as before 6.16.

**The index's memory** (`nim.indexMemory`, 64 MB by default, 0 for no limit). The engine counts what its parsed
files take and keeps them under the budget: above it, the files asked about least recently and not open are
dropped and read again when needed (a library file comes back from the index cache in a few ms). On the whole Nim
repository, a 16 MB budget holds the process at 23 MB instead of 40 MB.

**The compiler's answer, once** (`nim.compilerAnswers`, on by default). With nimsuggest off (the default), a
hover or *Go to definition* the engine has no answer for — a name a macro makes, say — asks the compiler once: one
nimsuggest run for that question, which then quits, so its memory goes with it. The answer is kept until the file
changes; your unsaved text goes to it as a private copy, deleted after.

**Names a macro makes** (`nim.macroNames`, on by default). `makeProcs(Foo, Bar)` at the top of a module declares
`getFoo` and `getBar`, which no reader of the text can see: the compiler expands the file's top-level macro calls
once, in the background (`nim check --expandMacro`, your unsaved text as a private copy, deleted after), and the
project files it imports are expanded the same way. What the expansions declare — routines, types and their fields,
constants — is then known to completion, hover (which says which call made it), signature help, *Go to
definition* (which goes to the call), the type hints and the engine's checks. It runs again only when those calls
change. What they made is kept on disk (`~/.cache/ned/macros`) with what it came from — the file's text, the files it
sees, the macros' own files, the defines and the compiler — so the next time the file is opened as it was, the
names are known at once, without the compiler.

**The index on disk** (`nim.indexCache`, on by default). The engine's reading of the standard library and the
nimble packages is kept in `~/.cache/ned/index`, so a new session — ned's or nedls' — answers its first question
without parsing them again (the whole standard library comes back from the cache in a fifth of the time parsing
it takes). An entry is used only for the very text it was made from, by the same parser, with the same
defines; anything else is read afresh. The project's own files are kept too, as they are on disk
(`nim.indexCacheProject`): reopening a project of hundreds of files reads them instead of parsing them.

**Expansion.** Alt+M on a template or macro call shows what it writes, right under the call, coloured as Nim — it
is not part of the file: nothing is saved, and the line numbers do not move. A template is written out with the
arguments in place by ned's engine, at once; a macro by the compiler (`nim check --expandMacro`), which takes a
moment ("the compiler is expanding it…"). In what it writes:

- a name that leads somewhere — `echo`, a proc of yours, a type — shows its documentation when the mouse rests on
  it, and a click (a tap) goes to where it is declared;
- an error or warning the compiler reports on the call is shown on the generated line it is about (the line with
  the name it quotes), and under the heading when no line has it.

The expansion follows its call when lines are added or removed above it, and is written again a moment after the
call itself changes. Alt+M on the call again — or a tap on the heading — hides it; *Nim: hide every macro
expansion* hides them all. *Nim: expand macro/template in a tab* opens the expansion in a tab of its own instead
(*expand macro one level* too, when nimsuggest is on). Hover on a template call shows the expansion as well.

**ned's engine and nimsuggest.** Since 5.28 nimsuggest is off by default; this is what each gives:

| | ned's engine (the default) | nimsuggest |
|---|---|---|
| completion, hover, signature help, outline | ✓ | ✓ |
| go to definition, references, rename | ✓ | ✓ |
| … of operators (`a + b`), of fields in constructors (`Vec(x: 1)`), of one overload | ✓ | ✓ |
| type definition, go to implementation, type hierarchy | ✓ | — |
| reference counts beside declarations | ✓ | — |
| type hints beside `let`, `var` and loop variables | ✓ | ✓ |
| errors while you type | `nim check` on the unsaved text | ✓ |
| template expansion · macro expansion | at once · `nim check --expandMacro` | ✓ · ✓ |
| quick fixes and code actions (fill in fields, write a forward declaration's body, generate `$`/`==`/hash) | ✓ | — |
| first answer in a 52 000-line file (ned 5.28's source) | at once | 12 s (it compiles the project first) |
| memory with that file open | 30 MB, the whole editor | 600 MB, nimsuggest alone |
| crashes during the comparison above (23 files) | 0 | 52 (started again each time) |

Turn nimsuggest on (`"nim.nimsuggest": true`, when it is installed — it comes with Nim) for a second opinion:
completion where the index cannot tell a receiver's type (inside macros, `auto` results), and errors while you
type in a big project whose `nim check` takes over 10 s. It is restarted past `nim.nimsuggestMaxMB` (1500 by
default).

**Settings.**
- `nim.ide`: `builtin` (the default), `nimlangserver`, or `off`.
- `nim.nimsuggest`: run nimsuggest for the extras above (off by default); `nim.nimsuggestMaxMB` caps its memory.
- `nim.typeHints`: where the type hints come from, `builtin` (the default) or `nimsuggest`.
- `nim.liveDiagnostics`: errors while you type (on by default); `nim.liveDiagnosticsFrom`: `auto`, `compiler`
  or `nimsuggest`.
- `editor.completionDocs`: documentation beside the list. Ctrl+Space toggles it while the list is open,
  Ctrl+↑/↓ scrolls it.
- *Nim: language server status* shows what the engine has indexed and which search paths and packages it
  uses.

## nedls: ned's engine in other editors

**`nedls`** is ned's Nim engine as a language server (LSP over stdin/stdout), for VS Code, Neovim, Helix, Zed,
Emacs, Kate, Sublime — instead of nimlangserver or nimsuggest — and ned's other engines for C, C++, JavaScript,
HTML, CSS, SQL and JSON. Its answers are ned's own: the same code the editor
runs, without its screen. `nimble install` builds it next to ned (or `nimble nedls`, or `nim c -d:release -o:nedls
src/nedls.nim`).

What it does: completion (with documentation, ned's snippets and postfix templates, the import it adds), hover,
signature help with every overload, definition, declaration, type definition, references, highlights, rename,
document and workspace symbols, semantic colours, inlay hints (types and parameter names), folding, formatting
(ned's formatter; a file it is not sure of gets no edits and a message), code actions — what ned's Alt+Enter
offers as an edit: the quick fixes for the compiler's problems and ned's own, the refactorings (generate, inline,
extract, the missing case branches and fields …), Organize imports, Fix all, a rule turned off for the project,
and Fix with AI checked by `nim check` (see [What's new in 6.18](../../CHANGELOG.md#whats-new-in-618)) — and problems: ned's own
checks at once, the compiler on the unsaved text after a pause, `nim check` on save. Positions are UTF-8 when the
editor offers it, else UTF-16.
Also, from 6.27: the call hierarchy (who calls a routine, what it calls), the type hierarchy (an object's bases
and the types built on it), implementations (a base method's overrides), selection ranges (Expand selection),
code lenses (▶ run a test, a suite, a `when isMainModule`, a nimble task — the result as a message), document links
(an import to its module, `staticRead` to its file) and the imports fixed when a file is renamed or moved.
From 6.28: an editor that asks for a document's problems (LSP 3.17's pull diagnostics) gets them when it asks,
and is told when they change; Enter formats the statement just written (on-type formatting, where the editor has
it turned on — not a statement that goes on to the next line); an HTML tag's name and its closing tag's are
renamed together (linked editing); and workspace symbols find the project's C, C++, JavaScript and JSON names too.

From 6.32: an editor that asks for the whole workspace's problems (`workspace/diagnostic`) gets those of the files
that are not open too — ned's own checks, as `ned --lint` makes them, go over the project's files while nedls is
idle (`workspaceDiagnostics`), and the editor's request is answered when something changes; an editor that asks
only now and then is sent them again after a while. Colours come as the edits since the last answer (semantic
token deltas), not the whole file again. Workspace symbols answer at once, from a table nedls makes while it is
idle and keeps up to date as files are edited, saved, created and deleted: the project's names first, the names
its imports export for a query of three letters or more, a name's word starts (`nsv` finds `newShapeValue`), and
`Shape.wid` for the fields of `Shape` (`Shape.ar` also finds the routines that take a `Shape` first).
It starts at about 6 MB, holds a big file with its imports in about 16 MB, and answers a hover in a few
milliseconds and a completion in about 20.

**The other languages.** nedls answers for the languages ned's own engines know, as the editor does: **C and C++**
(completion — a struct's members after `.` and `->`, an `#include`'s files, a function's call with its parameters
to fill in, a name from a header the file does not include with the `#include` added —, hover with the comment over
a declaration, signature help, definition through the `#include`s to a function's body, type definition,
references, highlights and rename by what a name names across the project's files, symbols, semantic tokens,
parameter names before arguments, ned's checks and the C compiler's errors as you type, with its fix-its, a missing
`#include` and ned's refactors as code actions, formatting a range; C++'s type hierarchy and a method's
implementations), **JavaScript** (completion, hover, definition and references across the
modules that import a name, rename, symbols, its checks), **HTML, CSS and SQL** (completion, hover, checks) and
**JSON** (its mistakes as you type; for `package.json`, `tsconfig.json`, `atlas.config`, `atlas.lock`,
`nimble.lock`, ned's settings and `.ned/lint.json`, the keys and values each one takes, with what they mean), and
formatting for each language ned formats (C, JSON, Markdown, CSS, SCSS, YAML, TOML, HTML, SQL). Point your editor
at nedls for those languages too (in VS Code: `nedls.languages`).

Settings (in the editor's `initializationOptions`, or under `nedls` in its settings): `inlayHints` (true),
`parameterHints` (`literals`, `all`, `off`), `raisesHints` (false: what a routine can raise, after its header),
`checkOnSave` (true), `liveDiagnostics` (true), `formatLineLength` (not given: `nim.format.lineLength`, else the
file's `.editorconfig`), `nedSettings` (true: your ned settings apply too), `aiFix` (true: Fix with AI when ned's
settings name a model), `workspaceDiagnostics` (true: for an editor that asks for the whole workspace's problems, ned's
checks go over the files that are not open too). `nedls --lint` checks files from the
command line, as `ned --lint` does.

ned's source has set-ups for other editors in [editors/](../../editors), each with a README that says how to
install it:

- **Neovim:** [editors/nvim](../../editors/nvim/README.md) — `lsp/nedls.lua` for Neovim 0.11's
  `vim.lsp.enable('nedls')` (copy it to `~/.config/nvim/lsp/`), or the folder as a plugin with
  `require('nedls').setup()` (Neovim 0.10 too).
- **Helix:** [editors/helix](../../editors/helix/README.md) — the entries for your `languages.toml`.
- **Zed:** [editors/zed](../../editors/zed/README.md) — an extension that starts nedls for Nim (install it with
  *zed: install dev extension*), next to the Nim extension that gives Zed the language; then
  `"languages": {"Nim": {"language_servers": ["nedls", "!nim", "..."]}}` in Zed's settings.
- **Emacs (eglot):** `(add-to-list 'eglot-server-programs '(nim-mode . ("nedls")))`
- **Kate** (LSP Client › User Server Settings): `{"servers": {"nim": {"command": ["nedls"], "highlightingModeRegex": "^Nim$"}}}`
- **Sublime** (LSP settings): `"clients": {"nedls": {"enabled": true, "command": ["nedls"], "selector": "source.nim"}}`
- **VS Code:** the extension in [editors/vscode](../../editors/vscode/README.md) — each release has it as
  `vscode-nedls-<version>.vsix` (*Extensions › … › Install from VSIX…*). It knows Nim's files, colours them before
  the server does, and passes its settings (`nedls.path`, `nedls.languages`, `nedls.inlayHints` …) on. Turn off the
  Nim extension's own server if you have it.
- **ned itself:** `{"nim.ide": "nimlangserver", "lsp": {"nim": ["nedls"]}}` — mostly for testing nedls; the
  editor has the engine built in anyway.

nedls trusts the folder it is given (it runs `nim dump` and `nim check`, which run the project's `config.nims`):
editors ask about trusting a workspace themselves. `nimble lsptest` drives it with a test client (every feature,
and 2000 random edits that must not put it out of step).

## One Nim per project

`nim.toolchain` (Nim settings; best in the project's `.ned/settings.json`, or *Nim: choose the Nim for this
project…*) is the Nim a project builds with, for every program ned starts — nim, nimble, nimsuggest,
nimlangserver, testament, the terminal: its `bin` folder goes first on PATH. `auto`, the default, keeps the `nim`
on PATH unless the project's .nimble asks for a Nim it is not (`requires "nim >= 2.2"`) and choosenim or grabnim
installed one that is; `path` always keeps PATH's; a version (`"2.0.16"`) or a Nim folder picks one. The status
bar shows the version (`✓ Nim 2.2.12`), and warns — *⚠ Nim 2.0.16: needs nim >= 2.2* — when the Nim in use is not
what the .nimble asks for; a nimsuggest from another Nim than `nim` is a warning too. A project's own
`nim.toolchain` takes effect only in a folder you trust.

## Lint: the engine's checks from the command line and in CI

`ned --lint` runs the engine's checks — a misspelled name, a field that is not there, a wrong number of arguments,
a value neither used nor discarded, an unused import or local, code that never runs, the hints above, deprecated
and too-new library names, and the project's own checks below — over files or folders, without the compiler or a
build (`nedls --lint` is the same):

```sh
ned --lint                          # this folder: the files git knows; path:line:col: warning: … [rule]
ned --lint --format:github src/     # GitHub annotations on the pull request (by itself under GitHub Actions)
ned --lint --format:sarif > ned.sarif   # SARIF 2.1.0, for GitHub code scanning (upload-sarif)
ned --lint --format:json x.nim      # a JSON array, each problem with its rule
ned --lint --severity:hint          # the hints too (var → let, unused parameters); default: warnings and errors
ned --lint --fail-on:error          # exit 1 only for errors (default: warnings too; never)
ned --lint --fix --diff             # what --fix would change, as a diff; nothing written
ned --lint --fix:var-let,deprecated # fix those rules in place (no --fix list: every rule that has a fix)
ned --lint --rules                  # the rules, their default severity, which have a fix
ned --lint --staged                 # the Nim files staged in git, as staged
ned --lint --install-hook           # a git pre-commit hook running that (beside nedfmt's, in one file)
```

**What `--fix` fixes**: a `var` nothing changes becomes a `let` (`var-let`), a deprecated name becomes the one its
message names (`deprecated`), an unused import goes (`unused-import`), a `proc` without side effects becomes a
`func` (`can-be-func`), and an imported package the .nimble does not require is added to its `requires`, with the
version the project builds with (`import-not-required`); in a Nim 3 project (or a file being ported) what Nim 3 needs
changed is made (`nim3`: `except E:`, `raise E`, `{.passive.}`, `low(E)..high(E)`, a named `break`, `x == nil`,
`t()`). Each fix is the editor's quick fix; a file keeps its line endings, and is checked again
afterwards.

**The project's own checks**: an `import` of a package the .nimble does not require (it builds here only because
the package happens to be installed), a package the .nimble requires that nothing imports, an exported routine
nothing in a program uses (a library's exports are for others), and the .nimble itself — a `requires` nimble cannot
read or written twice, a version no installed package meets, a `srcDir` or `bin` that is not there, a Nim
requirement the Nim in use does not meet, and no `version`, `author`, `description` or `license`. In the editor the
import and .nimble checks show while you type, with their quick fix (Alt+Enter: *Add requires "jsony" to
app.nimble*); the two that need the whole project, in `ned --lint` of the project.

**Rules per project** (`.ned/lint.json`, *Nim: lint rules for this project* writes one with every rule):

```json
{"rules": {"var-let": "off", "deprecated": "error", "unused-param": "hint"},
 "exclude": ["generated/", "tests/fixtures/*.nim"]}
```

Each rule is `off`, `hint`, `info`, `warning` or `error`, in the editor, nedls and `ned --lint` alike (a file's
nearest `.ned/lint.json` counts). A line is silenced with `# ned: ignore` (every
rule) or `# ned: ignore[var-let, unused-param]`, the next one with `# ned: ignore-next-line[…]`, a whole file with
`# ned: ignore-file[…]` near its top. Alt+Enter on a problem offers both: *Silence var-let on this line* and *Turn
off var-let for this project*. nedls gives each problem its rule as the diagnostic's `code`.

It reads the project's paths with `nim dump` once (`--no-config`: not, since that reads `config.nims`); ned's own
263 files take under 2 seconds — 7 with `--severity:hint`, since only then does it look for the hints (*can be a
func* among them). Why not in `nedfmt`: nedfmt is the formatter alone (1 MB; ned is 13), while the
checks need the whole engine — so they come with `ned` and `nedls`, which have it. *Nim: lint the project* shows the
same list in the output panel, each problem a link.

**Nim: add a CI workflow (GitHub Actions)…** writes `.github/workflows/ci.yml`: the project's dependencies
(`nimble install --depsOnly`), build and tests on Linux and macOS with the oldest Nim the .nimble allows and the
newest. Two more choices add a job that builds ned from the repository you give (`nim.ciNedRepository`, asked
once; a link with a login in it is refused) and runs `ned --lint --format:github` — and `nedfmt --check`. The file
is written, not committed: read it, then commit and push.

## Nim 3 (Nimony)

A project is Nim 3 when you say so (*Nim › Nim 3 (Nimony) › This project is Nim 3*, kept in its
`.ned/settings.json` as `"nim.compiler": "nimony"`) and `nimony` is on PATH. Then:

- nimony checks the file on save and as you type, and runs it (F5); F12 and *Find references* ask nimony
  (`--def`, `--usages`) where ned's engine cannot tell which symbol a name is — when nimony stops on an error of
  its own there, the status bar says so rather than "no definition". ned's engine reads Nimony's own library, not
  Nim 2's.
- **Tests**: a file in `tests/` with what it should print beside it (`t1.output`) or the messages the compiler
  should give (`t1.msgs`) — the way Nimony's tests are written — is listed in the test explorer and run with
  Nimony's `hastur test` (*Run all tests* runs them all; ✓ or ✗ from what hastur says). hastur's build files go to
  ned's own folder, not into the project.
- **What Nim 3 needs** (also for a Nim 2 file, when you ask: *Nim 3: what this file needs*): each change the
  porting rules call for is a problem in the Problems dock — `except X as e`, `newException`, an unlabeled
  `break` in a block, a template called without `()`, a name written in another case than it is declared (names
  are case-sensitive in Nim 3) … Ctrl+. makes the ones that are mechanical.
- **Contracts**: a call whose arguments break the routine's `{.requires: …}` is an error as you type, the one
  nimony gives when it compiles: `needsPositive(0)` → *contract violated: requires x > 0 (x = 0)*. An argument
  counts when its value is known where the call is: a number, true or false, a `const`, a `let` given one of those
  — and a loop's variable over `a .. b` or `a ..< b` with known ends, held to its first and last value
  (`for i in 0 ..< 3: needsPositive(i)` breaks it when i = 0). A `return` or `result =` of a known value that
  breaks the routine's own `{.ensures: …}` is one too. The rest is left to nimony.
- **Passive procs**: `delay(handle(c))` of a `.passive` proc that takes a `var`, `out` or `lent` parameter is an
  error before you compile — its continuation can outlive the caller; take the parameter as `sink`.
- **NIF**: `.nif` files have their colours (tags, symbols, line information), their routines and types in the
  Outline, and hover: what a tag is (from Nimony's `doc/tags.md`) and where the node comes from in the Nim source
  — F12 goes there, or, on a symbol, to where the NIF declares it. *Nim 3: the NIF of this file beside it* opens
  what nimony made of the file (it checks the file first when there is none yet); each side follows the cursor
  in the other.
- **pnak**, Nim 3's package tool: *Nim 3: pnak fetch* checks out the packages the `.nimble` (or `pnak.nif`) asks
  for in `deps/` and writes `nimony.paths`; *Nim 3: pnak pin* writes `pnak.nif`, the lockfile: every package,
  the ones the project needs and theirs, at its commit. In `pnak.nif` the Outline lists the packages, hover says
  where each one is checked out and at which commit, F12 opens the package's `.nimble`, and the Problems dock
  says when a package has no commit or a branch's name instead of one, is listed twice, is not fetched yet or is
  checked out at another commit. In the `.nimble`, a `requires` the lockfile does not have says so (rule `pnak`).

## Using nimlangserver instead

Set `"nim.ide": "nimlangserver"` (or click *Use nimlangserver instead* in the Nim dock). All nimlangserver
settings are in the settings file under `nim.*`; completion documentation, signature docs and Markdown
hovers work with it too. The rest of this section is about that mode.

## One nimsuggest per project

nimlangserver decides per file which project (nimsuggest process) serves it. Without a mapping, older
versions start a nimsuggest for every file you open. Newer ones pin whichever file you opened first and
restart it after an idle timeout. ned avoids both:

1. Before the server starts, ned picks the **main module**. It uses `nim.projectFile` if you set it.
   Otherwise it takes the `.nimble` package's `srcDir/<name>.nim` (the same module nimlangserver's own
   nimble entry point uses), then a `bin`, `<folder>.nim`, `src/<folder>.nim`, a module with its own
   `.nims`/`.nim.cfg`, `main.nim`, or the only `.nim` file.
2. It sends a `projectMapping` that maps the project's sources to that module. They all share one
   nimsuggest, which is never stopped for being idle.
3. **A folder with several packages** (your home folder, a monorepo) gets one rule per nimble package, added
   as you open its files. Loose scripts share one nimsuggest, started for the first script you open. A
   package file is therefore always checked inside its own package, with its imports and nimble paths.
4. Tests and examples are separate programs. With `nim.maxNimsuggestProcesses` = 1 (the default) they are
   served by the same process. Set it to 2 to give them their own, for complete answers there.
5. ned always names the `nimsuggest` to use: `nim.nimsuggestPath`, or the one on your `PATH`. Without
   that, nimlangserver would use the Nim folder that `nimble dump` reports inside a package, which is
   often not the Nim you use.
6. The server and its nimsuggest children are shut down when ned exits and restarted when you open
   another folder, so processes never pile up. A server that crashes is restarted. If it keeps crashing,
   the built-in nimsuggest client takes over.

Check it in the **Nim dock** (Alt+E › Code intelligence) or with *Nim: language server status*. Change the
main module with *Nim: use current file as main module* (stored in the project's `.ned/settings.json`).
Your own `nim.projectMapping` always wins.

## Other Nim features

- Alt+M shows what the macro/template call under the cursor writes, under it; *in a tab*; *expand one level*; ARC/ORC view
  (`expandArc`); show generated C; check the project; generate docs.
- *Nim: AST view*: the statement at the cursor (or the selection) as the tree a macro gets — `parseStmt(…).treeRepr`
  from Nim's own parser — beside the code, made again after each pause in the typing; on a macro or template call,
  what it expands to under it. *Nim: preview this file's docs*: the module's doc comment and each exported
  declaration with its signature and doc comment as `nim doc` shows them, and whether its runnableExamples passed.
- *Nim: the configuration the compiler ends up with*: `nim dump` for the project's main module — the config files
  read, in order, where they disagree (`--mm:refc` in nim.cfg, `--mm:orc` in config.nims: the last read wins), the
  defined symbols, the search paths, where the output goes.
- Quick fixes (Alt+Enter): *Import std/tables* for `undeclared identifier: 'initTable'` (from an index of
  the standard library's exports, built once and cached), *Remove unused import os*, and fixes worked out from
  the compiler's messages (let → var, discard, conversions, did you mean, export, create the proc, missing case
  branches, raises, ambiguous names, deprecated names), with *Fix all like this in the file*; AI fix (checked
  with `nim check` before it is applied) / explain.
- *Nim: toggle export marker (\*)*, *Nim: open documentation for symbol*, *Nim: REPL*.
- C interop: F12 on an `importc` declaration opens the C prototype (the hover shows it, with the comment that
  documents it in the header — in completion too), the C signature is shown dimmed after each wrapper
  (`nim.cSignatureHints`), `header: "…"` and `importc: "…"` are coloured and have a hover and F12, Alt+Enter
  rewrites a wrapper from its C declaration, and `proc ` + a C name completes a whole new wrapper; wrappers are checked
  against their headers (`nim.checkWrappers`), completion in `header: "…"` and `importc: "…"`, *compile_commands.json
  for clangd*.
- *Nim: wrap a C header…*: Nim for a C header, made by ned's own C engine — nothing to install. Its functions as
  `importc` procs (varargs too), its structs and unions as objects (bit fields, arrays, nested unions, an opaque
  struct as `incompleteStruct`), its enums as Nim enums (as `cint` constants when the values do not rise), its
  function-pointer typedefs as `proc … {.cdecl.}`, its `#define` numbers and strings as constants, its globals as
  `var`s — in a `.nim` beside the header (a system header's: in the project), with a `const …H` naming the header.
  *wrap a C header with c2nim…* uses c2nim (or futhark) instead.
- Code inside strings in its own colours: `{.emit}` as C (C++, JS), `sql"…"`, `re"…"`, `peg"…"`, `parseJson("…")`,
  the `{expressions}` of `fmt"…"` and `&"…"`, and HTML or SQL in triple-quoted strings. `#[html]#` before a string
  marks it; `nim.embeddedLanguages` names your own procs (`{"render": "html"}`).
- C in `{.emit}` edits as C: indentation, `//` comments, completion from its headers and `nimbase.h`, hover,
  F12 between the Nim declaration and the C, C compiler errors on the emit's lines (on save and from builds);
  with clangd installed, clangd's completion, errors while typing, fixes and parameter hints (`nim.emitClangd`).
  A Nim name in an emit's backticks (`` `counter` ``) is completed, has its Nim hover (and the C name it becomes),
  F12 to its declaration, is renamed with the Nim name, and is checked: no such name (with the one meant), a
  routine called there with a number of arguments none of its overloads takes (rule `emit-nim`). An `exportc`
  proc's hover gives its C name.
- HTML, CSS, SQL and JSON in strings go to their language servers: errors on the Nim line, completion, hover,
  fixes.
- **Web pages written in Nim**: templates in Jinja's style — Nimja's `.nimja` (and `.jinja`, `.j2`, `.twig`, `.njk`)
  — are HTML with `{{ expression }}`, `{% statement %}` and `{# comment #}` in their own colours: the code inside as
  Nim, the statement's word (`for`, `endfor`, `extends`, `block` …) as a keyword. Source-code-filter templates
  (`.nimf`, `#? stdtmpl`) have their `#` lines as Nim and the rest as HTML. The **nim-html** plugin (ned's own, in
  the Plugins dock) adds Karax's DSL: completion and hover of tags and attributes in `buildHtml`, Emmet to Karax,
  HTML to Karax and to `std/htmlgen`, and snippets — see [ned's own plugins](../plugins/available.md).
- *Nim: extract selection into a proc*, *change signature…*, *inline this proc*, *move to another module…* (see the
  5.19 notes), *Nim: sort imports*, *Nim: toggle proc ⇄ func*.
- **Bigger refactorings**, each shown as a diff first (side by side for one file, one diff for several) — *Apply it*
  or *Leave it*; Ctrl+Z undoes it file by file, and what it leaves to you is listed after.
  *Refactor: object ⇄ ref object* on a type's name: `T(…)` constructors stay; a `var x: T` that relied on starting
  as a value becomes `var x = T()`, a routine that fills in `result` before giving it one gets `result = T()`; the
  other way `new(x)` becomes `x = T()`. Listed: `==` (it compares which object it is, or the fields, now), copies
  that would share one object, fields that would start as nil, nil checks; a ref object that holds itself stays one.
  *Refactor: split the selected declarations into a new module…*: the selected top-level declarations (or members
  of a type/const/let/var section) go to the module you name; it imports what they use, the old module imports it
  where it still uses them (those get a `*`) and exports again what it exported, so its importers go on as before —
  code that uses what stays behind is not moved (the two would import each other).
  *Refactor: callback → async* on a proc taking a callback `proc (r: T)`: `{.async.}` returning `Future[T]`, the
  callback's call a `return`; in an async proc a call becomes `let r = await f(…)` with the callback's body after it
  (`g(await f(…))` for a named callback); other calls, and a callback called in a loop or before the end, are
  listed. *Refactor: switch call syntax*: the call at the cursor the next way that means the same — `f(x, y)` →
  `x.f(y)` → `f x, y` (a statement only) → `f(x, y)`; with lines selected, every call there one way (asked); not
  where `x.f` would reach a field of `x`.
- Rewrites on Alt+Enter (and in nedls' code actions): *Write the type* of a let/var/const, *Write as `x.f(y)`* ⇄
  *`f(x, y)`*, *Name the arguments*, *Write as a case* ⇄ *Write as if/elif*, *Invert the if*, an integer literal in
  hex, binary, octal or decimal.
- Reference counts after each proc and type (`nim.referenceCounts`); *Nim: exports nothing uses…*. The words of
  the project's files that they look through are kept on disk (`~/.cache/ned/words`), by each file's time, so a
  project opened again shows them without reading every file.
- Completion offers names from standard modules not imported yet, and adds the import (`nim.autoImport`), and
  postfix templates after a `.`: `xs.for`, `c.case` with every value of its enum, `v.if` by its type
  (`nim.postfixCompletion`); with `nim.completeCallArguments` a routine comes with its parameters to fill in
  (Tab to the next). Enter in a `##` comment starts the next line with `##` (`editor.continueComments`).
- Where ARC/ORC copies, after each save: ⧉copy beside what is copied, hover for why (`nim.showCopies`).
- Constants worked out on hover — a `when` too, with its branch left out on this platform dimmed
  (`editor.dimInactiveCode`).
- Debugger panel with gdb: F9 breakpoints, F5 start/continue, F10/F11 stepping (see the 5.2 notes); conditional
  breakpoints, logpoints and stops when a value changes (5.24).
- A .nimble's `requires` completes the package's versions (those installed, and its repository's tags — `git
  ls-remote`, kept a day) after `>=`, `@` …; the hover on a package says what it is, the versions installed, the one
  the project builds with and the newest release; Alt+Enter on `version = "1.2.3"` bumps it (patch, minor, major).
  *Nimble: add a dependency…* picks a package from the list (name, description), then the versions (`>= newest`,
  `^=`, any, one release, `#head`), writes the `requires` line and offers `nimble install -d`; *Nimble: lock file*
  shows what nimble.lock pins and what changed since the last commit. In config.nims and a .nimble, `-d:` completes
  what the project's code asks about (`defined(x)`, `{.intdefine.}`, `{.strdefine: "pkg.name".}`) and `--path:` the
  folders; `--gc:orc` is "deprecated: --mm:orc" and `--threads:on` "the default since Nim 2.0", each with its fix.
- NimScript files (config.nims, a build script for `nim e`, a .nimble) and plugins: system's NimScript part
  (`exec`, `cpFile`, `mkDir`, `switch`, `task` …), nimble's API and ned's plugin API on hover with their docs, in
  completion and signature help; a task's name says how to run it; the tasks in the Outline and *Go to symbol*; a
  module the VM cannot run (osproc, net, asyncdispatch …) is a problem with what to use instead (`nimscript-only`).
- *Nimble: add a dependency by name…* (adds `requires` and offers `nimble install -d`), *dependency tree*, *search packages*, tasks,
  build modes (debug / release / danger), backends (C, C++, JS, ObjC), Nim 3 with Nimony (*Nim › Nim 3 (Nimony)*: see
  [What's new in 6.12](../../CHANGELOG.md#whats-new-in-612)).
- Test explorer (Tests dock) for `std/unittest` suites, with ▶ buttons in the gutter; tests run on save, ✓ or ✗
  beside each (`nim.testOnSave`).
- **Test coverage**: *Test coverage: run and colour the lines that ran* builds the project's Nim tests with coverage, runs each one, and colours
  the line numbers — green ran, red never ran. It runs the test explorer's tests and nimble's `tests/t*.nim`; in the
  explorer, `c` on a test file covers just that one (*Nim: test coverage* covers the file you are in). The count is
  exact per Nim line: with gcc, ned rewrites the generated C so that a statement's extra C lines do not land on the
  Nim lines after it; with clang (Termux, macOS) it uses clang's source-based coverage and maps the C lines back
  through `#line`. Procs no test calls (Nim leaves them out of the binary) count as missed and are named in *Test
  coverage: summary by file*, which shows each file's share and the project's. Only the project's own files count —
  not the standard library, nimble packages, or the tests unless `nim.coverageTestFiles` is on. The C build is kept
  privately between runs, so a second run takes a moment; nothing runs in a folder you have not trusted. Needs gcov
  (it comes with gcc) or, with clang, llvm-cov and llvm-profdata (Termux: `pkg install llvm libcompiler-rt`).
