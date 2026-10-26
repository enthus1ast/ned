# Engines

ned understands several languages by itself: Nim with its own engine, C and C++ with another, CSS, HTML, SQL,
JavaScript and JSON with the web engines. They answer at once and without a compiler or a server; the compiler
and language servers fill in where they cannot. `nedls` offers the same answers to other editors. This page
explains how each is built, how a request flows through it, and how their accuracy is guarded.

One rule runs through all of them: **no answer rather than a wrong one**. Where an engine cannot be sure — a name
it cannot find, a macro, a generic it does not follow, a `when` it cannot decide, a C macro it does not expand — it
says nothing and leaves it to the compiler (whose word wins on a line where both speak).

## The Nim engine: src/ned/nim/index

[`src/ned/nim/index.nim`](../../src/ned/nim/index.nim) is a module of its own (other programs can
`import ned/nim/index`); its parts are files included from `src/ned/nim/index/`. It works on text — lines in,
answers out — and reads the editor's open buffers only through two hooks the editor sets: `nxBufferStamp` and
`nxBufferLines`.

### What it holds

| type | what it is |
|---|---|
| `NxFile` | one parsed file: its declarations (`syms`), imports, exports, pragmas it defines, the bodies of `when` branches left out, and a `stamp` that says which text it was made from |
| `NxSym` | one declaration: name, kind (proc, type, field, enum value, const, let, var …), exported or not, where, the end of its body, generics, parameters, return type, type or value, pragmas, doc comment, owner |
| `NxScope` | what a file can see: references (`NxRef`: a file and a declaration's index) to its own names, its imports' exported names and system's, in one array sorted by a hash of the normalised name; the modules it imports; what it depends on |
| `nxFiles`, `nxScopes` | the parsed files and the scopes, by path; trimmed when they take too much memory |

### The parts, in the order they build on each other

| file | what it does |
|---|---|
| `index/lex.nim`, `index/text.nim` | Nim's tokens; small text helpers (strings and comments taken out) |
| `index/parse.nim` | `nxParse(lines, path)`: a tolerant declaration parser — routines, types, fields, enum values, consts, lets, vars, imports, doc comments — that copes with half-typed code. `when` branches are decided with the project's defines (what `nim dump` said) and the ones left out are recorded |
| `index/nimscript.nim`, `index/switches.nim` | what `.nims` and `.nimble` files see (system's NimScript API, nimble's API) and the compiler's switches (generated from `nim --fullhelp` by `tests/tools/genswitches.py`) |
| `index/macrosyms.nim` | the names a module's top-level macro calls make, from the compiler's expansion (`nim/macronames.nim` runs it) |
| `index/scope.nim` | `nxLoad(path)`: a file parsed, from the open buffer when there is one, else from disk, kept while its stamp is the same; `nxScope(f)`: imports resolved the way the compiler resolves them (the toolchain's search paths, `--path`, nimble packages — the version the project locks, else the newest), exports followed |
| `index/diskcache.nim` | library and package files parsed once, kept in `~/.cache/ned/index`; used only when made from the same text, by the same parser, with the same defines |
| `index/locals.nim` | inside a routine: parameters, `result`, the lets, vars and loop variables before the cursor |
| `index/types.nim` | what an expression's type is (`nxTypeOfExpr`), what a type offers (fields, routines by method-call syntax), generics, aliases |
| `index/complete.nim` | completion (`nxComplete`: ranked by closeness and by the type expected at the cursor), signature help, documentation as Markdown (`nxDoc`, `nxRstToMd`) |
| `index/resolve.nim` | `nxTargets`: what the name at a place refers to — overloads, operators, constructor fields, tuple fields |
| `index/consteval.nim`, `index/layout.nim`, `index/raises.nim`, `index/effects.nim`, `index/concepts.nim` | compile-time values; a type's memory layout; what a routine can raise; whether it has side effects; which types satisfy a concept |
| `index/hover.nim`, `index/expand.nim` | hover (`nxHover`), go to definition (`nxDefinition`), a template call written out |
| `index/typos.nim` | names that are surely misspelled, told at once |

Work that may take long is done in steps: completion's list is made a slice at a time (`nxCompletionPrepare`,
`nxCompletionPending`), and the imports of the file in front are read a few at a time while you are idle
(`engineWarm`). `nxTrace` reports how long each part took to `NED_PERF_TRACE`.

The index is tested without the editor in [`tests/unit/tindex.nim`](../../tests/unit/tindex.nim) (and
`tdiskcache`, `tlayout`, `teffects`, `tversions` …): each case writes a small file, loads it with `nxLoad`, and asks.

### The editor's side: src/ned/nim/*.nim

| file | what it does |
|---|---|
| [`nim/engine.nim`](../../src/ned/nim/engine.nim) | when the engine serves a buffer (`nimEngineOn`: a Nim file, `nim.ide` not `off` and Nim not handed to nimlangserver, under 60 000 lines, not in large-file mode); `nxFileFor(b)` (an unsaved buffer is read as if it lived in the project); the toolchain (`nim dump` of each project, the standard library's folder); `engineTypos` (misspelled names and the engine's checks) |
| [`nim/answers.nim`](../../src/ned/nim/answers.nim) | the index's answers made into the editor's: `engineComplete`, `engineHover`, `engineSignature`, `engineDefinition`, `engineReferences`, `engineRename` |
| `nim/enginechecks.nim` | the checks while you type: code after a return, a field or proc that is not there (with the name meant), a wrong number of arguments, a value neither used nor discarded, unused locals and imports, a var that can be a let, a deprecated or too-new library name (`nim/nimapis.nim`, made by `.github/ci/nimapis.py`). Rules can be turned off in `.ned/lint.json`; `ned --lint` runs them from the command line (`app/lint.nim`) |
| `nim/semantic.nim`, `nim/highlights.nim`, `nim/reflens.nim`, `nim/outline.nim` | colours by meaning, the uses of a name lit, reference counts beside declarations, the outline |
| `nim/fixes.nim`, `nim/quickfixes.nim`, `nim/rewrites.nim`, `nim/refactors.nim`, `nim/refactor/*` | quick fixes (Alt+Enter) and refactorings: each worked out from the text (and the compiler's message) as a list of edits, so it can be listed, previewed, applied — and offered by nedls |
| `nim/typingcheck.nim` | the compiler on the unsaved text after a pause (`nim check -` on a private copy, in the file's folder) |
| `nim/nimsuggest.nim`, `nim/nimsuggestread.nim` | nimsuggest for what only the compiler knows (`nim.nimsuggest`) — see [Integrations](integrations.md#nimsuggest) |
| `nim/compileranswers.nim`, `nim/oracle.nim`, `nim/macronames.nim` | the compiler asked once where the engine has no answer (nimsuggest off); asked in the background about the lines around the screen (`nim.compilerOracle`, answers kept on disk by each line's text); the names macros make |
| `nim/toolchain.nim`, `nim/nimony.nim`, `nim/nim3checks.nim` | one Nim per project (`nim.toolchain`); Nim 3 (Nimony) |
| [`nim/worker.nim`](../../src/ned/nim/worker.nim) | the engine worker, below |

### A request, step by step: hover

1. Alt+H, or the cursor coming to rest on a name (the main loop's auto hover), calls `cmdHover` in
   [`editor/navigation.nim`](../../src/ned/editor/navigation.nim).
2. Files with a hover of their own answer first (assembly, NIF, `.nimble`, `atlas.config`); a selected expression
   gets its type; the problems on the line, review comments and ARC copies are put above whatever comes next.
3. On a name in a Nim file with the engine on, `engineHover` (`nim/answers.nim`) gets the buffer's `NxFile`
   (`nxFileFor`), asks `nxHover(f, lines, line, col)`, which resolves the name (`nxTargets`) and gives its
   declaration and doc comment as Markdown; the engine adds the concepts a type satisfies, and — for overloads it
   cannot tell apart — the one the compiler said this call picks.
4. When the engine has nothing: nimsuggest (an asynchronous request: its answer opens the popup a few rounds
   later), the keyword's documentation, or the compiler asked once.
5. Other languages go to the C engine, the web engines, the language server (`textDocument/hover`, asynchronous)
   or the server for code embedded in a string. Plugins' hovers join in (`plugHover`).
6. `showHoverAuto` puts the Markdown in the hover popup, drawn by `drawHover` (`ui/popups.nim`).

nedls answers `textDocument/hover` with the same `engineHover` (`lsHover` in `nedls/features.nim`).

### The engine worker

With `nim.engineWorker` on, what takes long to work out — the type and parameter hints, the engine's checks and
misspelled names, the reference counts, the web engines' checks — is worked out by a **second ned process**
(`ned --engine-worker`: the same program, `workerMain` in [`nim/worker.nim`](../../src/ned/nim/worker.nim)) on
another processor core. Completion, hover and go to definition stay in the editor, where the index answers them at
once.

They talk in JSON lines. The editor sends `init` (the folder, the settings, what `nim dump` said), `doc` (a
file's whole text), `edits` (the changes since the version the worker has — `rawReplace` logs them in
`b.wkLog`), `close`, `hints` (16-line chunks), `checks`, `settings`, `dump`. The worker answers `hints`, `checks`,
`resync` (the edits did not fit: send the whole text) and `error`. An answer for a text that has changed since is
dropped and asked again. With `NED_WK_VERIFY=1` (the UI tests and the fuzzer set it) the worker checks that its
copy is the editor's text, every time.

A worker that stops is started again; one that stops four times in ten minutes is given up, and the editor works
it out itself, in slices, as before (*Help › Performance* says why). After ten minutes with nothing to do it is
stopped and its memory given back. nedls and the engine drivers have no worker (`nedNoMain`).

## The C and C++ engine

| file | what it does |
|---|---|
| [`c/cindex.nim`](../../src/ned/c/cindex.nim) (a module) | an index of C files and the headers they include: functions, structs and members, unions, enums, typedefs, macros, globals, parameters and locals, and their doc comments. Text in, answers out: completion (members after `.` and `->`), hover, definition, type definition, references, outline, signature help, colours, which header declares a name, and for C++ classes, bases, derived classes and overrides. It reads C as a person skimming it would: the preprocessor is not run, every `#if` branch is read, macros are not expanded; templates are read past; `std::` names come from a list |
| `c/cchecks.nim` (a module) | checks with no compiler: an `#include` nothing of which is used, a struct whose fields in another order take less room, a printf- or scanf-style format against its arguments |
| [`c/cengine.nim`](../../src/ned/c/cengine.nim) | the editor's side (`c.engine`: `auto` uses it when clangd is not installed; `builtin`, `clangd`, `both`): completion, hover, F12 through `#include`s, rename, the outline, the C compiler's errors while you type, a missing `#include` added; the flags from `compile_commands.json` and the compiler's own macros |
| `c/cnim.nim` (a module), `c/c2nim.nim` | a C header as Nim declarations |
| `c/headers.nim`, `c/nimside.nim`, `c/types.nim`, `c/cdocs.nim`, `c/navigation.nim` | Nim's side of C: `importc` wrappers checked against their headers, C types as Nim types, a wrapper's C documentation |
| `c/emit.nim`, `c/emitclangd.nim` | C in `{.emit.}`: ned's own engine, or clangd through a hidden C document with the C at the same lines and columns |

The engine as a program for the comparisons is [`tests/engine/cdriver.nim`](../../tests/engine/cdriver.nim);
`tests/unit/tcindex.nim`, `tcchecks.nim` and `tcnim.nim` test it as a library.

## The web engines

[`src/ned/web/web.nim`](../../src/ned/web/web.nim) is a module that imports and re-exports one engine per language:
`cssengine`, `htmlengine`, `sqlengine`, `jsengine` (with `jsdata`: the standard, browser and Node names) and
`jsonengine` (with schemas: `package.json`, `tsconfig.json`, ned's own settings), and their data (`webdata`,
`webcommon`). Each works on a document's lines; text embedded in another file is given at its own columns with
the rest blank, so positions need no mapping either way. They know the project, not only the file: the class
names of its stylesheets, the tables its SQL creates.

The editor's side is [`web/webui.nim`](../../src/ned/web/webui.nim) (`web.engine`: `auto` uses them when no
language server does the job): completion, hover, definition, references, rename, and the checks after a pause
(`webChecksPump`), in `.css`, `.html`, `.sql`, `.js`, `.json` files and where those languages are embedded (an HTML
`<style>` or `<script>`, Nim strings). The JSON schema of ned's settings file is made from the settings'
definitions. Tests: `tests/unit/tweb.nim`, `twebdata.nim`, `tjs.nim`, `tjson.nim`, `twebfuzz.nim`.

## nedls

`nedls` ([`src/nedls.nim`](../../src/nedls.nim)) is the editor without its screen: it includes `ned.nim` and the
files of [`src/ned/nedls/`](../../src/ned/nedls):

| file | what it does |
|---|---|
| `nedls/rpc.nim` | JSON-RPC over stdio with `Content-Length` framing; stdout carries only the protocol, logs go to stderr |
| `nedls/docs.nim` | each open document is a ned `Buffer` (`lsDocs`), so the engine reads the unsaved text exactly as in the editor; positions converted (UTF-16 code units, or UTF-8 when both sides speak it — ned's columns are bytes); edits as LSP `TextEdit`s |
| `nedls/server.nim` | the lifecycle, the settings (`workspace/configuration`), the project and its toolchain, the dispatch of every message (`lsHandleRequest`), the main loop |
| `nedls/features.nim` | completion, hover, signature help, definition, references, rename, symbols, semantic tokens, inlay hints, formatting — each the editor's own proc, put in LSP's shapes |
| `nedls/more.nim` | call and type hierarchies, selection ranges, code lenses, document links, imports changed when a file is renamed, implementations |
| `nedls/diags.nim` | the problems: misspelled names at once, the compiler on the unsaved text after a pause, `nim check` on save — published when they change |
| `nedls/actions.nim` | code actions: what Alt+Enter offers, each found by running it on ned's buffer and undoing it (`lsDryRun`) |
| `nedls/langs.nim` | the other languages (C, C++, JavaScript, HTML, CSS, SQL, JSON) with ned's engines for them (`lxHandle`) |

### How a request flows

1. The client writes a message; the main loop (`lsMainLoop`) reads stdin and splits messages.
2. `lsHandle` sorts it: an answer to one of nedls's own requests, a notification (`didOpen`, `didChange` …), or a
   request.
3. `lsHandleRequest` asks `lxHandle` first: a document in another language is answered by ned's engine for it.
   Otherwise `case meth` picks the handler.
4. The handler finds the document (`lsDocOf(params)`: its `Buffer` is `d.b`), converts the position (`lsToPos`),
   calls the editor's proc and converts the result.
5. `lsReply` writes the answer. A handler that raises answers with an error; the server goes on.

Between messages the loop runs the compiler's checks, idle work and publishes problems. `nedls --lint` runs the
engine's checks over files instead.

## Adding a feature to an engine and to nedls

1. **The engine.** Write the logic in the engine's module (`nim/index/*.nim`, `c/cindex.nim`, `web/*engine.nim`)
   as a proc that takes text and positions and returns an answer — exported with `*`, touching no editor state.
   Give it unit tests in `tests/unit/` (for the Nim index, a case in `tindex.nim`).
2. **The editor.** Call it from the editor's side (`nim/answers.nim`, `c/cengine.nim`, `web/webui.nim`) and show the
   answer (a popup, a hint, a problem, a command in `app/commandlist.nim`). Add a UI test.
3. **nedls.** A feature that an existing LSP request covers (hover, completion …) usually reaches nedls through
   the editor's proc with no change. A new kind of request needs: the capability in `lsInitialize`
   (`nedls/server.nim`), an `of "textDocument/…":` line in `lsHandleRequest`, the handler in `nedls/features.nim`
   or `nedls/more.nim` (and in `nedls/langs.nim` for other languages), and a check in
   [`tests/lsp/tnedls.py`](../../tests/lsp/tnedls.py).
4. **Accuracy.** When the change touches what the scoreboard measures, run it (below) and compare with the
   minimums.

## The scoreboard

[`tests/engine/scoreboard.py`](../../tests/engine/scoreboard.py) asks ned's engines and the reference tools the same
questions on a fixed set of files and checks each score against its minimum in
[`tests/engine/scoreboard.json`](../../tests/engine/scoreboard.json). CI runs it on every push (the *engine
scoreboard* job of `.github/workflows/tests.yml`); a part whose tool is missing is left out and says so.

| part | compared with | script |
|---|---|---|
| Nim: type hints, go to definition, variables' types, member completion, references | nimsuggest, on standard-library modules | `compare.py` (the engine driver from `tests/engine/build.sh`) |
| Nim as you type: the compiler's errors found, clean files with no wrong error | `nim check` | `diagcompare.py` |
| nedls: hover (there, the same declaration, its doc), completion, signature help | nimsuggest | `parity.py` |
| C and C++: definition, member completion, hover's parameters | clangd, on Lua's and tinyxml2's sources | `ccompare.py` (`cdriver.nim`) |
| nedls against nimlangserver | nimlangserver | `lspversus.py` |
| the Nim formatter: lines the same, files formatted | nph | `tests/format/vsnph.py` |

```sh
tests/engine/build.sh ./ned-engine                       # the Nim engine as a program
nim c -d:release -o:nedls src/nedls.nim
nim c -d:release -o:ned-cengine tests/engine/cdriver.nim
python3 tests/engine/scoreboard.py --engine ./ned-engine --nedls ./nedls --cdriver ./ned-cengine \
  --c-files /tmp/lua/lapi.c /tmp/lua/lvm.c --cpp-files /tmp/tinyxml2/tinyxml2.cpp --n 40
```

The longer comparisons — the whole standard library, nimble packages and the compiler — and the numbers behind the
README's *How good it is* are described in [tests/engine/README.md](../../tests/engine/README.md).
