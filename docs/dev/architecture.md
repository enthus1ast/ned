# Architecture

How the source becomes a program, how the program spends its time, and where its state lives. The map of the
folders is in [Building › The source](../guide/building.md#the-source); this page is about how the parts fit.

## Three programs from one source

| program | source | what it is |
|---|---|---|
| `ned` | [`src/ned.nim`](../../src/ned.nim) | the editor |
| `nedfmt` | [`src/nedfmt.nim`](../../src/nedfmt.nim) | the formatters as a command: it imports `ned/format/fmtcli` and nothing of the editor |
| `nedls` | [`src/nedls.nim`](../../src/nedls.nim) | the engines as a language server: it `include`s the whole of `ned.nim`, then `src/ned/nedls/*.nim` |

`nedls` is the editor without its `main`: [`src/nedls.nims`](../../src/nedls.nims) defines `nedNoMain`, and the
last line of `ned.nim` runs `main()` only `when isMainModule and not defined(nedNoMain)`. So nedls answers with the
very code the editor runs — its buffers, its index, its checks — and a fix to the editor's Nim features reaches
nedls at its next build. The test drivers of [`tests/engine`](../../tests/engine) are made the same way
(`build.sh` writes a file that includes `ned.nim` and `driver.nim`, built with `-d:nedNoMain`).

`src/ned.nims` (and the same in `nedls.nims`, `nedfmt.nims`) sets what a release build needs: `--opt:speed`, no stack
or line traces, ORC, and link-time optimisation with `-d:lto`.

## Included parts, in order

`src/ned.nim` imports a handful of modules (below) and then **includes** about 270 files, one after another. An
included file is pasted into `ned.nim` where it stands: the whole editor is one Nim module with one namespace.
Every part can call every other part and use the global state without imports, exports (`*`) or import cycles —
the editor's parts call each other in every direction (the UI calls the engines, the engines' answers open
popups, the plugins call the editor and the editor calls them). The price is that **order matters**: a file sees
only what was included before it.

The order follows the layers the parts build on:

| layer | files (in `src/ned/`) |
|---|---|
| the core | `core/types`, `core/state`, `core/utils`, `core/themes`, `core/screen`, `core/termcaps`, `core/keys`, `core/languages`, `core/highlight`, `core/lexgeneric`, `core/lexers`, `core/todos`, `core/messages` |
| the text | `editor/buffer`, `editor/loadsave`, `editor/softwrap`, `editor/motion`, `editor/editing`, `editor/find` |
| announced ahead | `app/forward` |
| settings, files, saving | `config/settings`, `config/session`, `project/files`, `editor/safewrite`, `editor/swap`, `editor/localhistory`, `editor/buffers`, `project/remote`, `editor/save` |
| programs, servers, Nim | `run/process`, `run/checks`, `git/repos`, `lsp/client`, `lsp/handlers`, `nim/project`, `nim/nimsuggest`, `nim/engine`, `nim/answers`, `nim/enginechecks` … |
| the interface | `ui/actions`, `ui/pickers`, `ui/prompts`, `ui/render`, `ui/regions`, `ui/dialogs`, `ui/menus`, `ui/forms`, `ui/layout`, `ui/menubar`, the bars and docks |
| terminal, assistant, views | `term/pty`, `term/vt`, `term/panel`, `ai/*` … `ui/editorview`, `ui/popups`, `ui/split` |
| the frame | `ui/frame` (`render`) |
| keys and features | `app/commands`, `app/input`, `keymaps/*`, `debug/*`, `ui/mouse`, the C side (`c/*`), refactors, tests, `app/keyboard`, more of git |
| last | `nim/worker`, `plugins/perms`, `plugins/host`, `ui/telescope`, `app/commandlist`, `app/control`, `term/termhost`, `app/update`, `app/main` |

`app/main.nim` comes last because it calls everything; `app/commandlist.nim` comes near the end because each
command names a proc defined somewhere above it.

### Forward declarations

When a file must call a proc that is defined further down, the proc is declared ahead — its signature without a
body — and defined later with the same signature. Most of these declarations are in
[`src/ned/app/forward.nim`](../../src/ned/app/forward.nim), included right after the basic editing files. There
are more in `ui/actions.nim` (the pickers' actions), `ui/render.nim`, `ui/menus.nim` (the context menus' builders),
and at the top of some files. Before adding one, search for it (`grep -rn "^proc name(" src/ned`): a proc declared
twice ahead is a compile error. `forward.nim` also holds a few variables that early files need
(`wkWorkerMode`, `ffiQueue`).

## Modules compiled on their own

Some parts are real Nim modules: imported, compiled separately (in parallel, on more than one core), and usable
by other programs (`import ned/nim/index`; `ned.nimble` installs the sources for that). They take text and give
answers; they never touch the editor's state. They are unit-tested without the editor in
[`tests/unit`](../../tests/unit).

| module | what it does |
|---|---|
| `core/text` | UTF-8 runes, display widths, grapheme clusters, the pool of characters made of several code points |
| `core/encodings` | what a file's bytes are (UTF-8, BOM, UTF-16, Windows-1252 …) and the conversions |
| `core/editorconfig` | `.editorconfig` files |
| `core/images` | PNG, JPEG, GIF and BMP decoded; half blocks, sixel, kitty and iTerm2 output |
| `editor/regex` | the regular expressions of Find and Replace (ned does not use `std/re`) |
| `editor/binfmt`, `editor/asmview` | executables read (ELF, Mach-O, PE), their symbols; disassembly for Compiler Explorer |
| `format/formatters` | the formatters: Nim in nph's style, C, JSON, Markdown, CSS, YAML, TOML, HTML, SQL (each an included file of the module) |
| `format/fmtcli` | nedfmt's command line (also `ned --format`) |
| `nim/index` | ned's Nim engine (its parts are included files of `nim/index/`) — see [Engines](engines.md) |
| `nim/arccopies`, `nim/nifread` | where ARC/ORC copies; Nim 3's NIF files read |
| `c/cindex`, `c/cnim`, `c/cchecks` | ned's C/C++ engine; a C header as Nim; the C checks (imported by `c/cengine.nim`) |
| `web/web` | the CSS, HTML, SQL, JavaScript and JSON engines (it imports and re-exports `web/*engine`, `web/*data`) |
| `testing/gcovdata` | coverage data read |
| `version` | `NedVersion`: the version of ned, nedfmt and nedls (`ned.nimble` says the same) |

The editor plugs into a module through hooks the module exports: the Nim index reads open buffers through
`nxBufferStamp` and `nxBufferLines` (set in `nim/engine.nim`), notes its timings through `nxTrace`, and asks
`nxCacheTidyHere` whether this process tidies the disk cache.

Two modules — or a module and the editor — must not define the same top-level name (the same proc signature, the
same type or variable), even a private one: the formatter's self-test in the UI suite merges every file of ned
into one and compiles it ([Pitfalls](pitfalls.md#two-modules-with-the-same-top-level-name)).

### Windows

On Windows, `ned.nim` imports [`src/ned/sys/winos.nim`](../../src/ned/sys/winos.nim) *as* `os` (std/os, with `/`
in the paths it makes) and [`src/ned/sys/winposix.nim`](../../src/ned/sys/winposix.nim) *as* `posix` (the POSIX
calls ned makes, done with Win32, the C runtime and ConPTY). The rest of ned stays one program for every system; a
POSIX call that is new to ned must exist in `winposix` too, or be inside `when not defined(windows)`.

## State

[`core/types.nim`](../../src/ned/core/types.nim) has the shared types; [`core/state.nim`](../../src/ned/core/state.nim)
the shared state, as global variables. The ones you meet everywhere:

| variable | what it is |
|---|---|
| `bufs`, `curBuf`, `buf()` | the open buffers (one per tab), the index of the one in front, and that buffer |
| `focus` | where keys go: `fEditor`, `fTree` (the left dock), `fRight` (the right dock), `fPanel` |
| `rootDir` | the project folder |
| `needRender` | something changed on screen: the next round draws a frame |
| `grid`, `prevGrid`, `scrW`, `scrH` | the frame being drawn, and what the terminal shows (see [Rendering](rendering.md)) |
| `theme` | the colours in use |
| `cfg…` (`cfgTabSize`, `cfgWrap` …) | settings copied into plain variables by `applySettings`, so hot code never looks up JSON |
| `jobs`, `servers`, `nimSugs` | the programs ned runs, the language servers, the nimsuggest processes |
| `sideView`, `rightView`, `panelKind` | what the docks and the bottom panel show |

Besides these, each part keeps its own state next to its code, with a prefix of its own — which makes it easy to
search for:

| prefix | part |
|---|---|
| `nx` | the Nim index (`nim/index`, and the glue in `nim/engine.nim`) |
| `wk` | the engine worker (`nim/worker.nim`) |
| `ns`, `or`, `mn` | nimsuggest, the compiler oracle, the names macros make |
| `lsp`, `ls`, `lx` | the language-server client; nedls; nedls for languages other than Nim |
| `plug` | the plugin host |
| `ca`, `gfx` | the cursor's glide, pictures drawn by the terminal (`core/screen.nim`) |
| `ts`, `pick` | Telescope's finders, the picker |
| `mb` | multibuffers |
| `dbg`, `dap` | the debugger |
| `ctl` | the remote-control socket |
| `ai`, `mcp` | the assistant, MCP servers |
| `hx`, `vim`, `emacs` | the keymaps |
| `cEng`, `cx` | the C engine |

A buffer is known by its `id` (`bufById`), not by its index in `bufs`: tabs close and move, so a callback that runs
later (a job finishing, a server answering) keeps the id and looks the buffer up again — it may be gone. Many
tables are keyed by buffer id for the same reason (`semMaps`, `copyMarks`, `picViews`, `multiBufs` …).

What lasts between sessions is written by [`config/session.nim`](../../src/ned/config/session.nim) to
`state.json` (recent files, cursor positions, the layout, bookmarks, breakpoints); the settings are
`config.json` ([Recipes › Add a setting](recipes.md#add-a-setting)). Where every file lives:
[Files ned uses](../guide/files.md).

## Starting

`main` in [`app/main.nim`](../../src/ned/app/main.nim), in order:

1. the command line: `--version`, `--check`, `--format`, `--lint`, `--doc-settings`, `--engine-worker` (this
   process becomes the [engine worker](engines.md#the-engine-worker)), `--term-host` (a [kept
   terminal](integrations.md#the-terminal)) … and the files, with `FILE:LINE:COL` and `+LINE`;
2. a ned already running for you (`NED_SOCKET` set, as in ned's own terminal): the files are sent to it and this
   process ends (`remoteMain`);
3. the languages, the state, the project folder (a folder argument, or the project the first file belongs to),
   the settings, the project's Nim toolchain, the theme, the commands (`initCommands`);
4. the files opened, the signal handlers (`SIGWINCH` for a resize; `SIGHUP` and `SIGTERM` keep every unsaved edit
   in its recovery file and quit; `SIGQUIT` and `SIGPIPE` ignored), the tools looked up, the project's file list
   started in the background, the remote-control socket opened;
5. raw mode (`enterRaw`: the alternate screen, the mouse, bracketed paste, focus events, and the questions to the
   terminal about what it can do — `core/termcaps.nim`);
6. the last session, the layout, the kept terminals, the unsaved edits of last time (hot exit), recovery files;
7. `mainLoop`.

`smark("…")` notes each step for `ned --startup-time`. On the way out ned writes `state.json`, removes its
recovery files when it quit normally, and stops its threads, terminals, servers, plugins and the engine worker. A
crash runs `emergencySave` (every unsaved buffer to its recovery file) and prints the stack trace.

## The main loop

`mainLoop` is one thread doing everything in **rounds**. A round must stay short — a key is not read while a round
runs — so everything slow is either another process or done a slice at a time. In order:

1. **The terminal gone or a signal**: every unsaved edit to its recovery file, then quit.
2. **A resize**: the grid made again.
3. **A frame**, when `needRender` is set ([below](#frame-pacing)), then a frame of the cursor's glide when one is
   due (`caPump`).
4. **The wait**: `poll` on the terminal's input, every job's output, the language servers (and their input when
   there is something to write), nimsuggest, MCP servers, the remote-control socket, the plugin hosts, notebooks,
   terminals, the git watcher, the engine worker and the debugger. How long it waits is worked out each round:
   two seconds when nothing is due, the time until the next thing that is (the hover delay, a toast to remove, a
   plugin's timer, a pause before the language server is told about an edit …), and zero while there is
   background work left. When the terminal has lost the focus (`ui.pauseWhenAway`), what only serves the screen
   waits.
5. **Input**: the keys and clicks that came, through `handleKey`. A burst (a paste, a held key) stops after
   about 50 ms to draw a frame, and goes on in the next round (`inputBacklog`).
6. **Background work, in slices**, only when no key is waiting: the project's file list (8 ms), the built-in
   search (8 ms), *Format all*, highlighting up to the screen (6 ms), the TODO tags, a C wrapper check.
7. **Programs and sockets**: jobs' output and endings (`pumpJobs`: each job's `onDone` runs here), the
   remote-control socket, terminals, ended processes, MCP, plugins, notebooks, the large-file viewer, Compiler
   Explorer and the other live views.
8. **One heavy piece of work a round**: the type and parameter hints, the C signature hints, the language
   server's extras, the engine reading imports, semantic colours, AI suggestions, next-edit suggestions, git's
   change marks, blame. `roomLeft()` allows it only within 8 ms of the round's start; otherwise `workDeferred` makes
   the next round come at once.
9. **nimsuggest**: its answers; one over its memory limit, or idle too long, stopped.
10. **Hover** when the cursor came to rest on a name after moving (not typing).
11. **Checks while you type**, after a pause: the compiler on the unsaved text (`typingCheck`), the engine's own
    checks, the compiler oracle, the names macros make, the web engines' checks.
12. **git**: `git status` when the watcher saw a change (or every few seconds while the Git or Files dock shows it).
13. **Language servers**: their answers read (8 ms at most), what waits written, a server that died started again
    (after three deaths it is given up), the buffers changed 120 ms ago sent to them.
14. **Recovery files** for buffers changed and left alone for 600 ms; every two seconds the files changed on disk,
    the theme's clock and auto-save.

Every round is inside a `try`: an exception becomes `internalError` (written to `errors.log` in the state folder,
said once on the status bar), never a crash. Key handling and drawing have the same guard.

With nothing due, `poll` waits two seconds and nothing is drawn: ned uses no CPU while idle.

### Frame pacing

A frame asked for by a key or a click is drawn at once, at the start of the next round. Frames nothing asked for —
an AI answer streaming in, a terminal's output, a job printing — come 60 a second at most, or 30 when the terminal is
slow (`slowTerminal()` in `core/screen.nim` measures how fast it takes bytes): `frameHeld` holds them and shortens
the wait until the frame is due.

### Background work in slices

Anything that may take long is written as a *pump*: a proc that does a bounded amount (a few milliseconds, a few
files, a chunk of lines) and remembers where it stopped. The main loop calls it each round and keeps the wait short
while there is more (a condition in the timeout list, or a `…NextDueMs` / `…Pending` proc of the part). Examples:
`pumpScan`, `pumpSearch`, `hlPump`, `todoPump`, `plugPump`, `lfPump`, `semImportsPump`. What cannot be cut into
slices goes to another process: a job (`startJob`), the engine worker, a language server.

ned has one other thread: the recovery files' writer ([`editor/swap.nim`](../../src/ned/editor/swap.nim)), because an
`fsync` on a phone's flash can take hundreds of milliseconds. Programs are started with `spawnProc` and `startJob`
([`run/process.nim`](../../src/ned/run/process.nim)): fork and exec (not `std/osproc`: Termux's C library has no
`posix_spawn` on older Android), a process group of their own so a whole build can be stopped, non-blocking pipes,
and a lower priority for what runs in the background.

### timedWork and the performance report

Each piece of work in the loop is wrapped in `timedWork("what it is"): …` (a template in
[`core/screen.nim`](../../src/ned/core/screen.nim)). Work over 30 ms is kept in `slowWork`, which
*Help › Performance…* ([`app/perfreport.nim`](../../src/ned/app/perfreport.nim)) shows by name, with the frames
(time to make, bytes sent, time the terminal took), the rounds over 50 ms, the engine's timings and the memory.
Work that returns from the middle uses `defer: noteWork("…", t0)` instead. The name is shown to the person using
ned: write it in plain words.

Two environment variables record it for measuring:

| variable | what is written |
|---|---|
| `NED_PERF_LOG=file` | the performance report, when ned exits |
| `NED_PERF_TRACE=file` | every round over 4 ms: when, how long, the processor time it really had, the heap, and each named piece over 0.5 ms (work inside other work marked `›`, the time no name covers as `(not named)`) |

[`tests/perf/rounds.py`](../../tests/perf/rounds.py) reads the trace while it drives ned through a real session on
its own source, and fails when a round is longer than [`tests/perf/budget.json`](../../tests/perf/budget.json)
allows ([Testing](testing.md#performance)).
