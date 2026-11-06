# Testing

Every release passes all of these. This page says what each suite guards, how to run it, and how to write a test
for the UI suite. The short list is in [AGENTS.md](../../AGENTS.md#test); [tests/README.md](../../tests/README.md)
has the tables of tools the tests use.

| suite | guards | run | time |
|---|---|---|---|
| [unit](#unit-tests) | the modules on their own: the engines, formatters, regular expressions, encodings, pictures | `nimble test` | seconds |
| [UI](#the-ui-suite) | the whole editor, driven through tmux like a person | `python3 tests/ui/run.py ./ned [t_name …]` | about an hour |
| [plugins](#plugins) | the plugin host, the API, the examples, ned's own plugins | `python3 tests/plugins/tplugins.py ./ned --native` · `python3 tests/plugins/tbundled.py --native` | minutes |
| [nedls](#nedls) | the language server: every feature, then random edits | `python3 tests/lsp/tnedls.py ./nedls` | a minute |
| other editors | nedls's set-ups for Neovim, Helix and Zed in [editors/](../../editors) | `python3 tests/editors/check.py ./nedls` | a second |
| [formatter](#the-formatter) | the Nim formatter never changes what code means | `sh tests/format/parsecheck.sh NIMROOT` | minutes |
| [scoreboard](#the-engine-scoreboard) | the engines' accuracy against nimsuggest, clangd, nimlangserver, nph | `python3 tests/engine/scoreboard.py …` | ~20 minutes |
| [fuzzer](#the-fuzzer) | no crash, hang or internal error under random input | `NEDBIN=./ned_debug bash tests/fuzz/batch.sh 120 mixed palette hex` | as long as you give it |
| [performance](#performance) | start-up, memory, frames, the longest waits | `python3 .github/ci/bench.py ./ned` · `python3 tests/perf/rounds.py ./ned` | minutes |
| [docs](#the-documentation) | references up to date, every link goes somewhere | `python3 tests/docs/apiref.py --check && python3 tests/docs/links.py` | a second |
| [themes](#theme-contrast) | ned's own themes are readable | `python3 tests/themes/contrast.py` | a second |
| tour | the Nim tour's lessons: every cell runs and prints what it says, every exercise's answer passes | `python3 tests/tour/check.py` | a minute or two |
| every command | each command of the palette run in a ned of its own (`--plugins`: with all of ned's plugins on, theirs too): no crash, no internal error, still answering | `python3 tests/smoke/commands.py ./ned` | 15 minutes |
| hostile input | a plugin, the remote control and nedls fed nonsense; control characters on the screen | `python3 tests/hostile/thostile.py ./ned ./nedls` | a few minutes |
| names | every command and setting the menus, key maps, ned's plugins and the docs name exists | `python3 tests/docs/names.py` | a second |
| per-file memory | every global table ned keeps by a buffer's id is let go when its tab closes (`editor/bufforget.nim`), read from the source | `python3 tests/memory/bufids.py` | a second |

Which to run before sending a change: the unit tests, the UI tests near your change (`--list` shows the names; a
test's name says its release and topic), and the suite of the part you touched — the plugin tests for the plugin
host, `tnedls.py` for nedls, `parsecheck.sh` for the Nim formatter. CI runs everything on every push.

## Unit tests

[`tests/unit/`](../../tests/unit): one `t*.nim` file per subject, each importing a module straight from the source
(`import ../../src/ned/nim/index`) and using `std/unittest`. They need no editor and no terminal.

```sh
for t in tests/unit/t*.nim; do nim r -d:release --hints:off "$t" || break; done    # all (nimble test)
nim r -d:release --hints:off tests/unit/tregex.nim                                  # one
```

| file | subject |
|---|---|
| `tindex.nim`, `tdiskcache.nim`, `tlayout.nim`, `teffects.nim`, `tversions.nim`, `tnimapis.nim` | the Nim index: declarations, completion, definitions, types, hover, templates, misspelled names; its disk cache; memory layouts and raises checked against the compiler; package versions; what each Nim release added |
| `tcindex.nim`, `tcchecks.nim`, `tcnim.nim` | the C engine, its checks, a C header as Nim |
| `tformat.nim`, `tfmtcli.nim`, `twebfmt.nim` | the formatters, and nedfmt's command line |
| `tweb.nim`, `twebdata.nim`, `tjs.nim`, `tjson.nim`, `twebfuzz.nim` | the CSS, HTML, SQL, JavaScript and JSON engines |
| `tregex.nim`, `ttext.nim`, `tencodings.nim`, `timages.nim` | regular expressions, widths and graphemes, encodings, pictures |
| `tbinfmt.nim`, `tasmview.nim`, `tnif.nim`, `tgcov.nim`, `tcopies.nim` | executables, disassembly, NIF, coverage data, ARC/ORC copies |
| `twhy.nim`, `treshape.nim`, `tautoindent.nim` | where an exception or a side effect comes from; references, overloads and the bigger refactorings; Nim's indentation as you type |
| `tsecrets.nim`, `tlandlock.nim`, `treleasecheck.nim`, `tsha256.nim` | secrets kept from the AI; the sandbox; a release checked before it is installed (SHA256SUMS, its signature) |
| `tthemeimport.nim`, `ttour.nim` | Zed and Helix themes imported; the Nim tour's lessons as ned reads them |

A case of the Nim index writes a small file to a temporary folder and asks about it (`fixture` and `labels` are
helpers at the top of `tindex.nim`):

```nim
test "the fields of an object after a dot":
  let (f, ls) = fixture("type Point = object\n  x, y: int\nvar p: Point\np.")
  let c = nxComplete(f, ls, 3, ls[3].len)
  check c.member
  check "x" in c.labels and "y" in c.labels
```

`tests/unit/genwidths.py` makes the character-width tables of `core/text`. CI runs the unit tests on Linux and
macOS, and the ones that do not need a POSIX system on Windows.

## The UI suite

[`tests/ui/`](../../tests/ui) drives the whole editor the way a person does: ned runs in a private tmux server, the
test sends keys and mouse events, and reads the screen back (about 1300 checks).

```sh
python3 tests/ui/run.py ./ned                          # all of them
python3 tests/ui/run.py ./ned t_528_refs t_57_ai        # some
python3 tests/ui/run.py --list                         # the names
python3 tests/ui/run.py ./ned --shard 2/4              # every 4th test from the 2nd (CI runs four parts at once)
NED_UI_FULL=1 python3 tests/ui/run.py ./ned t_vim       # a failure prints the whole screen (not 400 characters)
```

It needs tmux, git, python3 and nim on `PATH`. Language servers, clangd, gdb, lldb, debugpy, zsh, fish, a hunspell
dictionary and an SSH server are used when present; a test that needs a missing one is skipped and says what it
needs. `NED_TEST_PATH` adds folders to the tests' `PATH`, `NED_TEST_DICT` names a dictionary, `NED_TEST_SSH=1`
enables the remote-folder tests (after `tests/ui/ssh-setup.sh` on a throwaway machine).

### How it works

| file | what it has |
|---|---|
| [`run.py`](../../tests/ui/run.py) | the runner: a scratch folder (`NED_TEST_TMP`), the mock AI server, each test in turn, `tmux kill-server` after each, the totals. A failed run keeps its scratch folder and says where |
| [`harness.py`](../../tests/ui/harness.py) | what every test uses (below) — `suite.py` runs it into its own namespace |
| [`suite.py`](../../tests/ui/suite.py) | the tests: `t_…` functions, and the `tests` list at the end, which is what a full run runs |
| `vt.py` | a small terminal model: every byte ned sent must give the screen a full redraw gives |
| `fixtures/demo` | the project each test works in: copied to `W` and made a git repository with one commit |
| `mocks/mockai.py` | a mock AI server that answers like the real APIs, refusals included |
| `tmux.conf` | the tmux settings the tests use |

`setup(cfg)` prepares a test: it stops the previous tmux server, copies the demo project to `W` (`TMP/work`),
clears the state folder and the plugins folder, and writes a settings file with the tests' own defaults —
the assistant pointed at the mock server, `nim.nimsuggest` on, folder trust off, the cursor's glide off, hot exit
off, terminals that do not outlive ned, no checks before commits, no linters — then `cfg` on top. A key set to
`None` in `cfg` is removed, so the editor's own default applies.

`start(*files, w=140, h=40, env_extra='')` starts ned in the work copy, in a `w × h` tmux window, with
`XDG_CONFIG_HOME` and `XDG_STATE_HOME` in the scratch folder, `TERM=xterm-256color`, `COLORTERM=truecolor`, an empty
`NED_SOCKET` (never the ned the tests may run inside) and `NED_WK_VERIFY=1` (the engine worker checks its copy of
each text). It waits until ned has drawn its menu bar or status bar, then presses Escape. When ned exits, its exit
status is written to `W/exit`.

### The helpers

| helper | what it does |
|---|---|
| `keys('C-s', 'M-f', 'Escape', 'Enter', 'F12', 'C-End')` | keys by tmux's names, one after another |
| `text('hello')` | literal text, typed |
| `paste('…')` | text arriving as one bracketed paste |
| `palette('Format document')` | a command run by its name through Ctrl+P and `>` |
| `screen()` | the screen as text, rows separated by newlines |
| `screen_ansi()`, `ansi_row(text)` | the screen with its colours (SGR escapes); the row that contains `text` |
| `fg_at(row, word, nth)`, `fg_at_col(row, k)` | the 24-bit foreground colour where a word starts, or at column `k` (as strings `('r', 'g', 'b')`) |
| `bg_at_col(row, k)`, `bg_of(text, word)` | the background colour (in `suite.py`) |
| `click(x, y)` | a left click; **columns and rows count from 1** |
| `press`, `drag`, `release`, `mouse(code, x, y)` | a press, a drag and a release separately, any button |
| `find_on_screen(word)` | the `(x, y)` to click on a word |
| `wait_for(regex, t=8)` | the screen polled until the pattern is on it (True), or `t` seconds (False) |
| `wait_until(pred, t=8)` | the same for anything else: a file's text, git's state |
| `ftext('src/demo.nim')` | a file of the work copy; `git('log --oneline')` runs git there |
| `check(name, cond, info)` | one check: PASS or FAIL, with `info` (the screen, usually) when it fails |
| `need('clangd', 'gdb')` | skip the test when a tool is missing |
| `big_file()`, `ned_source()`, `ned_single_file()` | a million-line file; ned's source as one file; ned as one file that compiles |

### Writing a test

A test is a function named `t_<version>_<topic>` (the release that added it), with a comment saying what it checks,
added to the `tests` list at the end of `suite.py`:

```python
def t_631_sort_lines():
    # the palette's "Sort lines" on a selection: the lines sorted, case aside; one undo step puts them back
    setup({"nim.nimsuggest": False})
    open(W + '/fruit.txt', 'w').write('pear\nApple\nfig\n')
    start('fruit.txt', w=100, h=30)
    keys('C-a'); keys('C-p'); text('>Sort lines')          # (not palette(): it presses Esc, which drops the selection)
    time.sleep(0.4); keys('Enter'); keys('C-s')            # (the list filtered: as palette() waits)
    check('631 sort lines: sorted, case aside',
          wait_until(lambda: ftext('fruit.txt') == 'Apple\nfig\npear\n'), ftext('fruit.txt'))
    keys('C-z'); keys('C-s')
    check('631 sort lines: one undo step', wait_until(lambda: ftext('fruit.txt').startswith('pear')),
          ftext('fruit.txt'))
```

- **Wait for state, do not sleep.** `wait_for` returns as soon as the screen shows what you wait for, and gives the
  slow machine its time; a fixed `time.sleep` is either too long (the suite takes hours) or too short (it fails under
  load). Keep `sleep` for a short settling after a key whose effect cannot be seen. For state outside the screen use
  `wait_until(lambda: 'x' in ftext('a.nim'))`.
- **Name checks so a failure explains itself**: the release, the feature, what should be true.
- **Pass the screen as `info`**, so a failure shows what was there (`NED_UI_FULL=1` shows all of it).
- **Click as a person would**, on touch screens too: `find_on_screen` then `click`, not only keys.
- **`palette()` presses Escape first**, which drops a selection and extra cursors: to run a command on a selection,
  open the palette with `keys('C-p'); text('>Name'); keys('Enter')`.
- **Start from known settings**: give the settings the test depends on in `setup`, rather than relying on defaults
  that may change.

Run the suite on a quiet machine: under load a few timing-sensitive tests fail and then pass alone (ones seen doing it
include `t_522_nim_codegen`, `t_510_workspace`, `t_619_plugins` and `t_521_git`). Run a failed test again alone
before calling it a bug, and never run a build at the same time.

The harness sets `XDG_CONFIG_HOME` and `XDG_STATE_HOME` but not `XDG_CACHE_HOME` or `XDG_DATA_HOME`: the index's disk
cache, the compiled plugin hosts and the plugins' data folders are shared with your own ned and between runs. A test
that depends on a plugin's stored data clears it first
([Pitfalls](pitfalls.md#plugin-data-persists-between-ui-test-runs)).

## Plugins

| script | what it does |
|---|---|
| [`tests/plugins/tplugins.py`](../../tests/plugins/tplugins.py) | the plugin host without the editor: `Host` starts a host the way ned does (`nim e`, or compiled with `--native`) and plays ned's side — registrations, calls, the API. It runs the example plugins, an API test plugin (`fixtures/apitest`), the tutorial's plugin (`examples/plugins/notes`), a language server written in NimScript through `ned --lsp-bridge`, and a plugin in full Nim |
| [`tests/plugins/tbundled.py`](../../tests/plugins/tbundled.py) | ned's own plugins: each one's checks (`tests/plugins/bundled/test_<name>.py`) with `BHost`, which answers more of ned's side (several buffers, the selection, the clipboard, new tabs, saving); also that `plugins/`, `PlugBundledNames`, the first lines and the test files agree |

```sh
python3 tests/plugins/tplugins.py ./ned --native
python3 tests/plugins/tbundled.py --native dial oil         # some of ned's own plugins
```

The UI suite has tests with the real host as well (`t_619_plugins`, `t_622_plugin_api`, `t_626_plugin_permissions` …).

## nedls

[`tests/lsp/tnedls.py`](../../tests/lsp/tnedls.py) is a small LSP client in Python's standard library. It writes a
small Nim project (two modules, an object type, a misspelled name, non-ASCII text before names for the UTF-16
columns), checks every feature nedls has, then makes 2000 random edits that must not put nedls out of step with the
text. The compiler's diagnostics are checked when `nim` is on `PATH`.

```sh
nim c -d:release -o:nedls src/nedls.nim && python3 tests/lsp/tnedls.py ./nedls
python3 tests/lsp/tnedls.py ./nedls --edits 500          # a shorter random run
python3 tests/lsp/tnedls.py ./nedls --bench FILE         # timings and memory on a big file
```

## The formatter

[`tests/format/parsecheck.sh`](../../tests/format/parsecheck.sh) formats 463 files of Nim's compiler and standard
library (`tests/format/corpus.txt`) with `nedfmt --verify`: each result must parse, with Nim's own parser, to the same
tree as the original (comments and layout aside). It needs a Nim with its compiler sources.

```sh
sh tests/format/parsecheck.sh "$(dirname "$(dirname "$(readlink -f "$(command -v nim)")")")"
python3 tests/format/cfmtcompare.py ./nedfmt FILE.c … --style LLVM    # the C formatter against clang-format
python3 tests/format/vsnph.py …                                        # the Nim formatter against nph
```

The UI test `t_521_format_self` formats ned itself — every file merged into one — and compiles the result.

## The engine scoreboard

[`tests/engine/scoreboard.py`](../../tests/engine/scoreboard.py) checks the engines' accuracy against minimums in
`tests/engine/scoreboard.json`. What it compares and how to build the drivers is in
[Engines › The scoreboard](engines.md#the-scoreboard); the longer comparisons are in
[tests/engine/README.md](../../tests/engine/README.md).

## The fuzzer

[`tests/fuzz/fuzz.py`](../../tests/fuzz/fuzz.py) throws random keys, mouse events, pastes, palette commands and
resizes at ned in a private tmux server, and reports crashes, hangs and internal errors (anything written to
`errors.log`). `batch.sh` runs one round per mode and sums up; it exits 1 when anything went wrong.

```sh
nim c -d:release --stackTrace:on --lineTrace:on -o:ned_debug src/ned.nim        # says where an error happened
NEDBIN=./ned_debug bash tests/fuzz/batch.sh 120 mixed vim helix emacs palette refactor ai git fixes c hex web
```

Each mode mixes the input differently (`ai` drives the assistant, `git` a repository with history, `fixes` code
full of compiler errors, `c` C files, `hex` binary files, `kitty` the kitty keyboard protocol, `web` CSS, HTML and
SQL …). It works in a scratch home of its own, but random commands can run tasks and shell commands and save files
anywhere ned may write: give it a throwaway user (`NED_FUZZ_USER=fuzz`; as root it refuses to start without one).
Logs go to `/tmp/ned-fuzz-UID-logs`.

## Performance

| script | what it measures, against what |
|---|---|
| [`.github/ci/bench.py`](../../.github/ci/bench.py) | `ned --startup-time` in a real pseudo-terminal (an empty folder, this repository, a big file, an 80 MB log): the time to the first frame and the memory; `ned --bench`: the time and bytes per frame (scrolling, typing, a far jump); the built-in terminal flooded with output — each against `.github/ci/bench-budget.json` |
| [`tests/perf/rounds.py`](../../tests/perf/rounds.py) | ned on its own source as a project, with `NED_PERF_TRACE` on, while it opens a file, scrolls, types, completes, adds an import and opens another program: the longest round of the main loop in each step, the completion times, and the memory of the editor and its engine worker — against `tests/perf/budget.json` |
| [`.github/ci/pty_smoke.py`](../../.github/ci/pty_smoke.py) | ned in a real pseudo-terminal: it draws a file, the built-in terminal runs a command, piped input is shown, Ctrl+Q quits, the pointer's shape changes |
| [`.github/ci/win_smoke.py`](../../.github/ci/win_smoke.py) | on Windows (`pip install pywinpty`): `ned.exe` in a console (ConPTY), typed into, saved and quit; `nedls.exe` answering; `nedfmt.exe` formatting |

```sh
python3 .github/ci/bench.py ./ned                  # run it from the repository's folder
python3 tests/perf/rounds.py ./ned [--runs 3] [--one-core]     # --one-core: a phone's slow cores as a stand-in
```

The first `rounds.py` after a build can be slow (cold caches): run it again before believing a regression.
`NED_PERF_NO_BUDGET=1` prints the numbers without checking them. *Help › Performance…* and `NED_PERF_LOG` are the
same numbers from a session of yours ([Architecture](architecture.md#timedwork-and-the-performance-report)).

## The documentation

| check | what |
|---|---|
| `python3 tests/docs/apiref.py --check` | [docs/plugins/api.md](../plugins/api.md) is what the plugin API's `##` comments make (without `--check` it writes it) |
| `python3 tests/docs/links.py` | every relative link and `#anchor` in the Markdown of the README, CHANGELOG, CONTRIBUTING, SECURITY, `docs/`, `tests/` and `examples/` goes somewhere |
| `ned --doc-settings`, `ned --doc-commands` | CI compares them with [docs/reference/settings.md](../reference/settings.md) and [commands.md](../reference/commands.md), made with an empty `XDG_CONFIG_HOME` |

## Theme contrast

[`tests/themes/contrast.py`](../../tests/themes/contrast.py) reads the `mkTheme(…)` and `phosphorTheme(…)` lines of
`src/ned/core/themes.nim` and checks ned's own themes (the `OWN` list, and `READ` for themes taken in from others):
text 7:1, keywords, types, strings, numbers, functions, macros, properties and errors 4.5:1, comments and operators
3:1, and no two syntax colours closer than ΔE 12. The other built-in themes are listed for information.

## Cross builds

`tests/build/termux.sh` (the Termux `.deb`), `tests/build/windows.sh` (the Windows zip) and `tests/build/cross.sh`
(every target this machine reaches) build with zig as the C compiler. They pass `-g0`: with debug information ned's
biggest C file needs more than 6 GB to compile. See [Building](../guide/building.md#packages-and-other-platforms).

## Screenshots

Every picture in `screenshots/` — the README's, the guides', the changelog's, the blog post's — is drawn the same way,
in one font: ned's screen captured from tmux with its colours (`tmux capture-pane -e -N -p`), kept as
`screenshots/captures/NAME.ansi`, and drawn cell by cell by [`tests/shots/render.py`](../../tests/shots/render.py) in
the Coder Nerd Font Mono, at twice the size, framed, in 256 colours. The font is not in the repository:
`NED_SHOT_FONT` names its `.ttf`. Python with Playwright (and its Chromium) and Pillow draw them.

- `NED_SHOT_FONT=… python3 tests/shots/render.py [NAME …]` draws the captures again (every one, without a name).
- `NED_SHOT_FONT=… python3 tests/shots/scenes.py [NAME …]` takes the README's, the guides' and the blog post's
  screenshots again with today's ned: each scene drives ned through the UI tests' harness — the mock AI answers its
  assistant — and keeps the screen. It needs tmux, and gdb for the debugger's.
- A new screenshot: a scene in `scenes.py` (set up, drive, `snap(NAME)`) — or, taken by hand, its capture saved as
  `screenshots/captures/NAME.ansi`, then `render.py NAME`. Captures side by side (a theme gallery):
  `NAME@01-label.ansi`, `NAME@02-label.ansi` …, two across, each labelled.
- Name it by topic and release (`undo-tree-615`); its alt text says what it shows, and the theme. It shows a project
  anyone could have (the UI tests' demo project, `examples/`), never a home folder or a machine's name — a terminal
  with a short prompt.

## CI

[`.github/workflows/tests.yml`](../../.github/workflows/tests.yml), on every push and pull request:

| job | what it runs |
|---|---|
| unit | the unit tests on Linux and macOS |
| plugins | ned built; `tplugins.py --native`, `tbundled.py --native`; the references compared with what ned makes; `apiref.py --check`; `links.py` |
| nedls | `tnedls.py`; `parsecheck.sh` when the Nim has its compiler sources |
| ui | the UI suite in four parts at once, with the optional tools installed and `NED_TEST_SSH=1` |
| windows | the unit tests of ned's own logic, the three programs built natively, `win_smoke.py` |
| scoreboard | the engine scoreboard on standard-library modules, Lua and tinyxml2 |
| fuzz, engine | by hand only (*Run workflow*): fuzzing for a given time; the full comparison with nimsuggest |

[`.github/workflows/build.yml`](../../.github/workflows/build.yml) builds ned, nedfmt and nedls for Linux (gcc,
clang, and the oldest Nim supported), macOS, Linux arm64, Termux and Windows (WSL and native), runs the command-line
checks, `pty_smoke.py`, the performance checks and `tnedls.py`, and packages the VS Code extension — to know that
ned builds everywhere; it publishes nothing (`ned --update` and `install.sh` build a new version with nimble).
