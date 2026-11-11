# Pitfalls

The lessons that cost time, from [AGENTS.md](../../AGENTS.md), the history of ned's releases and the comments in its
code. Read this before your first change.

## In the source

### Closures made in a loop share its variables

A closure made inside a loop does not capture the loop variable's value at that moment: every closure made by the
loop shares one variable, and sees its **last** value. A `let` copy made inside the loop body does not help — it is
shared too. Every menu item, button, job callback or picker action made this way acts on the last item. (6.24.1 fixed
menus whose every item did the last one's action.)

```nim
# wrong: every item opens the last file
for p in paths:
  items.add mi(p, "", proc() = discard openFile(p))

# right: a factory proc — each call makes a closure of its own
proc openAct(p: string): Action = (proc() = discard openFile(p))
for p in paths:
  items.add mi(p, "", openAct(p))

# also right: std/sugar's capture
for p in paths:
  capture p:
    items.add mi(p, "", proc() = discard openFile(p))
```

Inside `capture`, the body runs in a proc of its own: `result` there is that proc's, not yours — collect into a
local variable (as above) instead of `result.add`. The code has many examples: `openAct` in `ui/menubar.nim`,
`tsGoTo` and `tsCmdAct` in `ui/telescope.nim`, `capture kk:` in `ui/popupdraw.nim`.

### One forward declaration only

A proc used above the file that defines it is declared ahead in `src/ned/app/forward.nim` — or in `ui/actions.nim`,
`ui/render.nim`, `ui/menus.nim` or at the top of a file. It may be there already: search first
(`grep -rn "^proc name(" src/ned`). A proc declared ahead twice does not compile, and the definition must have the
same signature as the declaration.

### The include order

`src/ned.nim` includes the editor's files in order, and a file sees only what was included before it. A new file goes
after everything it uses and before everything that uses it; when two files need each other, one of them gets a
forward declaration. For the same reason `nim check src/ned/editor/buffer.nim` alone fails with unknown names: an
included file is checked through the module that includes it (`nimble typecheck`, or
`nim c --compileOnly:on src/ned.nim`). The engine and `nim check` must see what ned sees — a plugin's source needs
`--path:` to the plugin library.

### Two modules with the same top-level name

The UI test `t_521_format_self` merges all of ned — every included file and every module — into one file
(`ned_single_file` in `tests/ui/harness.py`), formats it, and compiles the result. Two modules that each define the
same name at the top level (a proc with the same parameters, a type, a variable or constant), even a private one,
compile on their own but clash in the merged file. Give helpers names with the module's prefix.

The same goes for what a module imports: all of `std/unicode` beside `std/strutils` makes `splitWhitespace`
ambiguous in the merged file. Import only what is used (`from std/unicode import Rune, toUTF8`). And the formatter
must format the merged file as well: when it refuses ("would change the block structure"), the new code has a shape
it gets wrong. That is a formatter bug to report, and meanwhile the code is written more plainly.

The merging understands the shapes the source uses: `include x` at the left margin, `import` lists of ned's own
modules (a list may go on to the next line after a trailing comma), `export` lists, `staticRead("file")` next to the
source, and `currentSourcePath().parentDir`, `.plugSrcUp(n)` and `.nxSrcUp` to find files at compile time. A new way of
doing any of these needs `ned_single_file` taught as well.

### Change text only through replaceText

`replaceText` (and `setContent` for a whole new text) keeps everything that depends on the text in step: the undo
history, every cursor, the `changeId` that tells highlighting, outlines, hints and checks to look again, the
language server's copy, the engine worker's copy (`wkLog`), git's marks, problems' lines, bookmarks, folds and
breakpoints. Assigning `b.lines` (or one of its lines) directly skips all of it: the screen shows stale colours, the
worker answers about another text, and undo corrupts the file. Edits go inside `beginEdit` / `endEdit`; several
cursors are edited from the last to the first.

### Keep a buffer's id, not its index

A callback that runs later — a job that finishes, a server's answer, a timer, a plugin's call — must not keep an index
into `bufs`: tabs close and move in between. Keep `b.id`, look the buffer up with `bufById` when the callback runs,
and do nothing when it is `nil`.

### What you keep per file, or per project, must go

A global table keyed by a buffer's id (`Table[int, …]`, `HashSet[int]`) keeps its entry after the tab closes unless
it is in [`editor/bufforget.nim`](../../src/ned/editor/bufforget.nim): a closed buffer's id is never used again, so
the entry stays for good (6.32.2 found sixty, and ned grew by a megabyte or two at each file closed).
`python3 tests/memory/bufids.py` finds them. What is kept by a file's path or by a project — the words of its files,
the compiler's answers, an index of headers — goes in `projectForget` (the same file) when another folder is
opened, or has a bound (`if t.len > N: t.clear()`): a long session goes through many projects. Something keyed by a
file's version or a line number makes a new key at every edit — give it a bound too.

### Never hold up the main loop

A round that takes long is a moment when keys are not read. So no `sleep`, no waiting for a program to finish (start
it with `startJob` and handle the result in its `onDone`), nothing per frame that grows with the file's or the
project's size, and anything long cut into slices ([Architecture](architecture.md#background-work-in-slices)).
Wrap the work in `timedWork("what it is")` so *Help › Performance* can name it.

Two things follow:

- State changed outside key handling (a timer, a pump, a socket) must set `needRender = true`, or the screen shows
  it only at the next key.
- Work that needs another round soon must say so in the main loop's wait (a condition in `mainLoop`'s timeout list,
  or a `…NextDueMs` proc of its part). Otherwise the loop may sleep for two seconds.

### A slice must not start from the beginning

A pump that does a bounded amount each round (`if msSince(t0) >= budget: return false`) is only as short as the step
between two looks at the clock — and that step must not grow with how far it got. A scope's names (`sc.refs`, an
`NxRefs`) are its own list and its layers': `sc.refs[i]` counts through the layers to the i-th each time, one at a
time past a layer the scope partly hides (an included file's). Walked that way a slice at a time, the completion
list and the semantic colours took 20–40 ms a round on ned's own source, more the further they got (6.45). Walk them
with `for r in sc.refs`, or, across rounds, with `nxNext(sc.refs, at, r)` and an `NxRefsAt` kept between them.

### Big texts: no copies on the way

A whole file is easily megabytes. Joining its lines (`allText`), putting the result in a `JsonNode`, turning that
into a string with `$` and adding it to a write buffer is four copies at once — for 7 MB, 54 MB for a moment — and
memory taken is not always given back (see [Memory](architecture.md#memory)). What sends a whole file writes it
straight into the queue a line at a time: `wkSendDoc` (the engine worker, which reads it back the same way:
`wkDocInPlace`) and `lspNotifyText` (a language server: `LspTextMark` stands for the text in the message). Write
buffers go through `pipeWrite`, read buffers through `eachLine` (`core/utils.nim`).

### Deep nesting needs a limit

A reader that calls itself for each bracket inside a bracket runs out of stack on input no person writes but a
program might (minified data, a fuzzer): the Nim formatter stopped with a crash at about 10 000 nested brackets
(6.45). Give such a reader a depth (`XMaxDepth`, `FmtMaxNest`, the JSON check's 200) past which it gives up on that
part — and says so once, not once for every bracket around it.

### applySettings runs in other processes too

The engine worker (`ned --engine-worker`) and nedls apply the settings with the same `applySettings`. Nothing there may
write to the terminal or open the interface unless `gRaw` is set (ned is in raw mode, drawing).

### Starting programs

- Use `startJob` or `spawnProc` (`run/process.nim`), not `std/osproc`: a fork and exec of its own (Termux's C library
  has no `posix_spawn` on older Android), a process group (so a build's children stop with it), non-blocking pipes.
- `spawnProc` raises `OSError` when the command would run the code of a folder you have not trusted (the compiler,
  nimble, nimsuggest … in a folder with `security.folderTrust` asking). Handle it.
- A setting that starts programs must be in `riskyProjectKey` ([Recipes](recipes.md#add-a-setting)).
- Secrets never go on a command line or into a log: an API key goes in a private temporary file (`privTmp`, in a
  0700 folder) that the program reads (`curl -H @file`).

### Positions are bytes

A column (`Pos.col`) is a byte offset into the line's UTF-8, also in the plugin API. Screen columns come from
`visColOf` / `colAtVis`; whole characters (an emoji sequence, an accent) from `nextCluster` / `prevCluster`. The
Language Server Protocol counts UTF-16 units unless both sides agree on UTF-8: convert with `lspPos` /
`fromLspPos` (the editor) or `lsToPos` (nedls). An edit sent to a server that takes changes is converted when it is
made (`rawReplace` keeps it in `b.lspLog`), in the line as it was before it: by the time it is sent, the line may
have changed again.

### A server's "end of the file"

A language server is given the text with its last line end (`allText & "\n"`), so the end of the file is, for it,
the line after ned's last: `(lines.len, 0)`. A whole-file edit ends there (the HTML and CSS servers' formatting).
`lspEditOf` turns a server's edit into ned's positions with that in mind; use it for any edit a server sends.

### The same file by two paths

macOS's `/var` is `/private/var`, Termux's `/sdcard` is `/storage/emulated/0`, and a project may be reached through a
symbolic link: a compiler names a file by its real path, the editor by the one it was given. Where a path from a
program is compared with a file of ned's, compare their real paths too (`expandFilename`), as the assembly view
does.

### Windows

On Windows `std/os` is replaced by `src/ned/sys/winos.nim` (paths with `/`) and `std/posix` by
`src/ned/sys/winposix.nim`. A POSIX call ned has not used before must exist there too, or be inside
`when not defined(windows)`. Paths are written with `/` everywhere.

## Building

### zig's -g0 and memory

`zig cc` writes debug information unless it is given `-g0`; with it, ned's biggest C file needs more than 6 GB to
compile and the compiler is killed (`dmesg` says `oom-kill`). The scripts in `tests/build` pass `-g0`: keep it. On a
machine with little memory (or two cores), build one program at a time, and never during the UI suite.

### `| tail` hides the exit status

`nim c … 2>&1 | tail -20` exits with `tail`'s status, so a failed build looks like a good one. Use `set -o pipefail`,
or check that the program it should make exists and is newer than the sources.

### Plugins are compiled into ned

ned's own plugins (`plugins/<name>/plugin.nims`) and the plugin library (`nedplugin.nim`, `nedlsp.nim`) are read into
the binary when it is built (`staticRead`). A change to one shows in the editor only after a new build.

### Nim 2.4 is not Nim 2.2

GitHub's checks and Termux use the newest Nim; test a change that reads what Nim makes with both. What differs:

- **C names**: `shout_u0__app` (2.2: `shout__app_u1`) — `nimDemangle` in `editor/binfmt.nim` reads both.
- **`#line`**: a Nim line's C is spread over several C lines under one `#line`, so the C compiler counts on and gives
  the later ones the Nim lines below (an emit's text, though, is right as counted). A build whose debug information
  or assembly ned reads goes through `nimDebugBuildCmd` (`nim/toolchain.nim`): `--compileOnly`, `ned --c-lines`
  (`debug/clines.nim`: copies of the C put right, which Nim's list of commands then compiles), `nim jsonscript`.
- **`nim c -` (stdin)**: 2.4.0's separate code generator cannot find the project; `nimStdinFlags()` turns it off.
- **nimsuggest**: `result` is declared on the body's first line, `use` leaves some uses out, types print as
  `Option[%.T]`; the engine scoreboard keeps 2.2's as its yardstick.
- **coverage**: gcov counts a `while` line once, where 2.2 counted each check.
- **NIF**: an array type is `array[0..1, T]` (ned shows `array[2, T]`), a name a template made is declared on the
  template's line.

### Never `pkill -f` a pattern that matches your own shell

`pkill -f ned` matches every process whose command line contains "ned" — the shell running your command
(`bash -c "… ned …"`), your editor, a test run's tmux server — and kills them with it. Kill by process id, use
`pkill -x ned` (the program's name only), or stop the tests' tmux server with `tmux -L <socket> kill-server`.

## Keys and terminals

### Keys a terminal never sends

Alt+key arrives as ESC followed by the key, and three of those start a terminal's string instead: ESC P (Alt+Shift+P)
starts a DCS, ESC ] (Alt+]) an OSC, ESC _ (Alt+Shift+-) an APC. `parseKey` reads them as the terminal's answers, so
those keys never arrive (that is why Telescope is Alt+Shift+F). Without the kitty keyboard protocol, more never come
as themselves:

| pressed | arrives as |
|---|---|
| Ctrl+Shift+letter | Ctrl+letter |
| Ctrl+I, Ctrl+M, Ctrl+H, Ctrl+[ | Tab, Enter, Backspace, Escape |
| Ctrl+Tab, Ctrl+Enter, Ctrl+Backspace, Shift+Enter | the key without the modifier |
| Ctrl+digit, Ctrl+punctuation | mostly nothing |

`keyTerminalProblem` in `app/keyboard.nim` has the list and warns about a `keys` setting that uses one.

### ned inside ned

In ned's terminal `NED_SOCKET` is set, so `ned FILE` opens the file in the ned you are in. Start a separate one with
`ned --new`; the UI tests clear `NED_SOCKET` for the ned they run.

### Pictures in tmux

Inside tmux, pictures are drawn in cells (half blocks), never with kitty's, iTerm2's or sixel's protocol: tmux would
not pass them on. The UI tests see the cells.

## Tests

### Plugin data persists between UI test runs

The UI harness gives each test settings and state of its own (`XDG_CONFIG_HOME`, `XDG_STATE_HOME` in the scratch
folder) but not `XDG_DATA_HOME` or `XDG_CACHE_HOME`. The plugins' data folders (`~/.local/share/ned/plugins/<name>`),
the index's disk cache and the compiled plugin hosts are shared with your own ned and between runs. A plugin that
remembers something in its data folder (on or off, a list, a count) starts the next run with it: a test that depends
on it clears that folder first, as `t_629_indent_plugins` does.

### The tests' settings are not ned's defaults

`setup` writes the tests' own defaults (nimsuggest on, folder trust off, the cursor's glide off, hot exit off …). A
test of a default sets that key to `None` in `setup({...})`, which removes it.

### palette() presses Escape first

The `palette()` helper starts with Escape, which drops the selection and extra cursors. To run a command on a
selection, open the palette yourself: `keys('C-p'); text('>Name'); keys('Enter')`.

### Timing

Under load (a build running, a busy CI machine) timing-sensitive UI tests fail and then pass alone. Wait for what you
expect with `wait_for` and `wait_until` rather than sleeping; run a failed test alone before calling it a bug. The first
`tests/perf/rounds.py` after a build can be slow (cold caches): run it again.

### What the machine has

A test passes or fails by what is installed. GitHub's runners have clangd, gh, the HTML, CSS, JSON and SQL language
servers, Nim 2.4 and the newest git; your machine may have none of them, or prettier and an older git. A test of
ned's own engine or of a tool missing starts ned without the others (`path_without`, `no_web_servers`,
`usr_bin_without` in `tests/ui/harness.py`); a test of a server says it `need`s it. Run a test that fails only on
GitHub with the runner's tools first: Nim 2.4 on PATH, `NED_TEST_PATH` at the language servers, `GITHUB_ACTIONS=true`
(the runner takes it out, as GitHub sets it). With `NED_UI_FULL=1`, which CI sets, a failure's whole screen is in the
log.

### Other programs change their words

ned reads what git, nimble and compilers print. git 2.56 quotes the end of a bisect (`is the first 'bad' commit`), and
ned missed it; clang on macOS names its own labels `Ltmp0`, not `.L0`. Read both the old and the new wording, and
test with the newest version of the tool as well (building git from its source takes a few minutes).

### The fuzzer as root

Random keys can save files anywhere ned may write. As root the fuzzer refuses to start without a throwaway user
(`NED_FUZZ_USER`).

## Documentation

### Regenerate the references

After a change to a setting (its text, default or options — a new theme is a new option of `theme`) or to a command
(its name or keys):

```sh
XDG_CONFIG_HOME=$(mktemp -d) ./ned --doc-settings > docs/reference/settings.md
XDG_CONFIG_HOME=$(mktemp -d) ./ned --doc-commands > docs/reference/commands.md
```

The empty `XDG_CONFIG_HOME` matters: your own themes, for one, would otherwise be listed among the `theme` setting's
options in the reference.
After a change to the plugin API's doc comments: `python3 tests/docs/apiref.py`. CI fails when any of them is out of
date.

### Links

`python3 tests/docs/links.py` checks every relative link and `#anchor` in the Markdown. It skips fenced code blocks
but not inline code: a link written inside backticks (text in square brackets, then a path in round ones) is still
checked. Anchors are GitHub's: the heading in
lower case, spaces as `-`, other punctuation dropped.

### Plain words

Documentation and the interface say what happens for the person using ned, not how it is implemented; British
spelling; no marketing. Code comments say why, in the same style.
