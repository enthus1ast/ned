# ned's tests

Every release of ned passes all of these. They need nothing that is not on GitHub's runners (see
[`.github/workflows/tests.yml`](../.github/workflows/tests.yml), which runs them on every push).

| folder | what | how long | run |
|---|---|---|---|
| [`unit/`](unit) | the Nim index (compile-time values too, kept on disk, memory layouts and exception hints checked against the compiler, the package versions a build uses), the C index, ned's own CSS, HTML and SQL engines, the formatters (HTML and SQL too) and nedfmt, the regular expressions, where ARC/ORC copies, what each Nim release added, columns counted 8 bytes at a time, character widths from Unicode (emoji sequences joined or not — `unit/genwidths.py` makes the tables), executables read (ELF, Mach-O, PE) and Nim's names in them — as libraries, without the editor | seconds | `nimble test` |
| [`lsp/`](lsp) | nedls driven by a small LSP client: every feature, then 2000 random edits that must not put it out of step | a minute | `nimble lsptest` |
| [`vscode/`](vscode) | the VS Code extension's own language client (editors/vscode) under Node, VS Code played by a stand-in: against nedls (every provider, the documents kept in step, problems, cancelling, a restart, shutting down) and against a fake server (questions with buttons, edits that create, rename and delete files, progress, a request nobody knows, a crash); what a `.vsix` holds | seconds | `node tests/vscode/test_extension.js ./nedls` · `python3 tests/vscode/test_vsix.py FILE.vsix` |
| [`editors/`](editors) | nedls's set-ups for Neovim, Helix and Zed (editors/): they parse, pass only settings nedls has, carry ned's version, and start a nedls that answers | a second | `python3 tests/editors/check.py ./nedls` |
| [`plugins/`](plugins) | the plugin host without the editor (the example plugins and an API test plugin, this script playing ned: every registration, call and API request), the LSP bridge, the compiled host and a plugin in full Nim | a minute | `python3 tests/plugins/tplugins.py ./ned --native` |
| [`plugins/bundled/`](plugins/bundled) | ned's own plugins (plugins/: dial, which-key, oil, the languages …), each played through the plugin host as ned runs it, in `nim e` and compiled; every one in ned's list, with what it does and its checks | minutes | `python3 tests/plugins/tbundled.py --native [NAME …]` |
| [`plugins/cookbook/`](plugins/cookbook) | the plugins of the [plugin cookbook](../docs/plugins/cookbook.md): each compiles as NimScript and as Nim, and the page shows each file as it is (`--run`: each started in the plugin host too) | a minute | `python3 tests/plugins/cookbook/check.py [--run]` |
| [`perf/`](perf) | the longest rounds of ned's main loop and completion times on ned's own source (`--one-core`: on one core); speed budgets by hand before a release (`budgets.py`: starting, opening a 50 000-line file, typing and moving in it, as a terminal sees it) | minutes | `python3 tests/perf/rounds.py ./ned` · `python3 tests/perf/budgets.py ./ned` |
| [`soak/`](soak) | a long editing session on a copy of ned's own source, picked at random — and in a second project now and then: memory, internal errors, and ned still answering after hours (`--only type_code,save` for some of the actions, `--revert-minutes` for how often the files go back) | hours | `python3 tests/soak/soak.py ./ned --minutes 180` |
| [`memory/`](memory) | every table ned keeps per open file is let go when its tab closes (read from the source); and, to find what grows in a long session, a build that writes the size of each of its 600-odd tables — the index's and the engine worker's too — every 30 s (`memprobe.py OUT`, then the soak with `--mem-log FILE`, then `memprobe.py --diff FILE` and `--diff FILE.worker`) | seconds | `python3 tests/memory/bufids.py` |
| [`update/`](update) | a release checked before it is installed (SHA256SUMS and its signature), install.sh and `ned --update` against a fake release in a local folder | seconds | `python3 tests/update/tupdate.py ./ned` |
| [`ai/`](ai) | secrets kept from the AI (`ai.redactSecrets`): the real editor and a fake AI provider that writes down every request | a minute | `python3 tests/ai/tredact.py ./ned` |
| [`plugins/tsandbox.py`](plugins/tsandbox.py) | plugins in the Landlock sandbox (`plugins.sandbox`) and `ned --sandbox`: what the kernel refuses (Linux; elsewhere it says why and passes) | a minute | `python3 tests/plugins/tsandbox.py ./ned` |
| [`format/`](format) | the Nim formatter on 463 files of Nim's compiler and standard library, each checked by Nim's own parser; ned's C formatter against clang-format in each of its styles | minutes | `nimble parsecheck` · `python3 tests/format/cfmtcompare.py ./nedfmt FILE.c … --style LLVM` |
| [`ui/`](ui) | the whole editor driven through tmux: keys in, the screen read back — every feature, about 1300 checks | ~1 hour | `nimble uitest` |
| [`fuzz/`](fuzz) | random keys, mouse events, pastes, palette commands and resizes; crashes, hangs and internal errors reported | as long as you like | `tests/fuzz/batch.sh 120 mixed vim palette` |
| [`engine/`](engine) | ned's Nim engine against nimsuggest on the standard library, nimble packages and the compiler; what the editor answers (through nedls) in .nim, .nims, .nimble and plugins against nimsuggest and the APIs' docs; its C engine against clangd | ~1 hour | `tests/engine/build.sh && tests/engine/corpus.sh /tmp/out` · `tests/engine/parity.py FILE…` · `tests/engine/ccompare.py` |
| [`engine/scoreboard.py`](engine/scoreboard.py) | the engines' scoreboard (CI, every push): the Nim engine and nedls against nimsuggest on standard-library modules (definitions, hover, completion, references in the file), the engine's checks as you type against `nim check` (`diagcompare.py`: mistakes made on purpose — found, and no wrong error in clean files), the C engine against clangd on Lua's sources and the C++ one on tinyxml2's — each score against its minimum (`scoreboard.json`); `--readme` writes the numbers into the README | ~20 minutes | `python3 tests/engine/scoreboard.py --engine ned-engine --nedls nedls --cdriver ned-cengine --c-files … --cpp-files …` |
| [`build/`](build) | ned built for every target: gcc, clang, and with zig macOS (arm64, x86_64), Android/Linux arm64 and Windows x86_64 — nedfmt and nedls too; the Termux package and the Windows zip of a release; the VS Code extension's `.vsix` (Python only) | minutes | `tests/build/cross.sh` · `tests/build/termux.sh` · `tests/build/windows.sh` · `tests/build/vscode.sh OUTDIR` |
| [`themes/`](themes) | every built-in theme's colours against its background; ned's own must pass | a second | `python3 tests/themes/contrast.py` |
| [`docs/`](docs) | the documentation: the plugin API reference is what the API's doc comments make (`apiref.py`, `--check`), every link and `#anchor` in the Markdown goes somewhere (`links.py`), every command and setting named — in the menus, the key maps, ned's plugins and the docs — exists (`names.py`); every command a menu item, a button or a tap names is one ned has, every setting is declared, described and read, every request of the plugin library has its handler (`wiring.py`, with a built ned); CI also compares `docs/reference/` with `ned --doc-settings` and `ned --doc-commands` | a second | `python3 tests/docs/apiref.py --check && python3 tests/docs/links.py && python3 tests/docs/names.py && python3 tests/docs/wiring.py ./ned` |
| [`smoke/`](smoke) | every command of the palette run once, each in a ned of its own: no crash, no internal error, ned still answering; `--plugins`: every one of ned's own plugins on together, then each of their commands; `--menus`: every item of every menu and submenu, picked with the keys as a person would | 15 minutes (`--menus` 20) | `python3 tests/smoke/commands.py ./ned` · `… --plugins` · `… --menus` |
| [`hostile/`](hostile) | input that makes no sense or means harm: a plugin calling every API request with arguments of the wrong kinds, broken protocol lines; the remote-control socket; broken JSON-RPC to nedls; control characters in a file and its name — ned stays up and answers | a few minutes | `python3 tests/hostile/thostile.py ./ned ./nedls` |
| [`shots/`](shots) | not a test: the screenshots of the docs, taken again (`scenes.py`: ned driven as the UI tests drive it) or only drawn again from their captures (`render.py`), all in the Coder Nerd Font Mono (`NED_SHOT_FONT`) — see [Screenshots](../docs/dev/testing.md#screenshots) | minutes | `NED_SHOT_FONT=FONT.ttf python3 tests/shots/scenes.py [NAME …]` |

Speed and memory are checked by [`.github/ci/bench.py`](../.github/ci/bench.py) (`nimble perf`) against the
limits in `bench-budget.json`, and [`.github/ci/pty_smoke.py`](../.github/ci/pty_smoke.py) runs ned in a real
pseudo-terminal — on Windows [`.github/ci/win_smoke.py`](../.github/ci/win_smoke.py) in a Windows console (ConPTY,
`pip install pywinpty`), with nedls.exe and nedfmt.exe.

## The UI tests

```sh
nimble release                                   # ./ned
python3 tests/ui/run.py ./ned                    # all of them
python3 tests/ui/run.py ./ned t_528_refs t_57_ai # some of them (--list shows the names)
NED_UI_FULL=1 python3 tests/ui/run.py ./ned t_622_nimscript   # a failure prints the whole screen
```

They need **tmux**, **git**, **python3** and **nim** on PATH. Each test starts ned in a private tmux server, in a
scratch copy of [`ui/fixtures/demo`](ui/fixtures/demo) (made a git repository on the fly), with settings of its own,
and talks to it the way a person would. A mock AI server ([`ui/mocks/mockai.py`](ui/mocks/mockai.py)) answers the
assistant like the real APIs do — including their refusals — so the AI features are tested without a key. Mock
language servers stand in for real ones where a test needs a server's exact answers: `mocklsp.py` (fixed answers),
`mocksync.py` (takes a file's changes, not its whole text, and writes its copy out to be compared with the file).

Some tests use optional tools; when one is missing, the test is skipped and says what it needs:

| tool | tests |
|---|---|
| nimlangserver | the language-server mode of the Nim features |
| clangd | C in `{.emit.}`, C interop, clangd's fixes |
| node, vscode-langservers-extracted, sql-language-server | HTML, CSS, SQL and JSON inside Nim strings (sql-language-server: installed with `vscode-languageserver-protocol` held at 3.17, as [the CI](../.github/workflows/tests.yml) does — what npm gives it today does not start) |
| vscode-js-debug (in `~/.local/share/js-debug`, where the install ned offers when you debug JavaScript puts it) | debugging JavaScript and TypeScript |
| gdb, lldb, debugpy | debugging |
| pytest, go | the test explorer for Python and Go |
| zsh, fish | the terminal's shell integration (bash is always tested) |
| an en_US hunspell dictionary (`hunspell-en-us`) | spell checking |
| an SSH server | remote folders over SSH: run [`ui/ssh-setup.sh`](ui/ssh-setup.sh) on a throwaway machine (it adds hosts to `~/.ssh/config`), then `NED_TEST_SSH=1` |
| Nim 2.4 or newer, its `bin` folder in `NED_TEST_NIM24` (the suite itself runs with an older Nim too) | the compiler's reading (`nim nif`) of unsaved text |

What ned sends to the terminal is checked too: [`ui/vt.py`](ui/vt.py), a small terminal model, reads every byte of
a session (scroll regions, colours carried along a row, skipped cells) and the screen it ends up with must be the one
a full redraw draws.

`NED_TEST_PATH` puts more folders on the tests' PATH (where your language servers are, say).
A test of something that must not be there (ned's own CSS, HTML, JSON and SQL engine; ned's C formatter; the
GitHub CLI missing) starts ned with a PATH without it — `path_without(…)`, `no_web_servers()`, `usr_bin_without(…)`
in [`ui/harness.py`](ui/harness.py) — since a machine may have it, as GitHub's runners have clangd, gh and the
language servers. A test waits for what it reads (`wait_for`, `wait_until`) rather than sleeping a fixed time:
the runners are slower. `GITHUB_ACTIONS` is taken out of the tests' environment, so `ned --lint` writes its
usual lines there too.
`NED_TEST_DICT` names a dictionary. `--shard 2/4` runs a quarter of the tests (CI runs four parts at once).
A run that fails keeps its scratch folder and says where it is.

## The fuzzer

```sh
nim c -d:release --stackTrace:on --lineTrace:on -o:ned_debug src/ned.nim
NEDBIN=./ned_debug tests/fuzz/batch.sh 120 mixed vim helix emacs palette refactor ai git fixes c
```

Each mode is a two-minute round with a different mix of input (`ai` drives the assistant, `git` a repository with
history, `fixes` code full of compiler errors, `c` C files with ned's own engine and its ligatures, `refactor` procs to change,
`hex` binary files and programs, `kitty` keys in the kitty keyboard protocol, emoji sequences and the terminal's answers,
`web` CSS, HTML and SQL files with ned's own engines, jump labels and the picker's preview). The fuzzer works in a scratch home of
its own, with a copy of the Nim toolchain (random keys can go to a definition in the standard library and save
it), but random palette commands can run tasks and shell commands in its test project, and random keys can
"save as" anywhere ned may write: give it a throwaway user (`NED_FUZZ_USER=fuzz`, run as root — as root it does
not start without one). Logs go to `/tmp/ned-fuzz-UID-logs`.

## The parsers' fuzzer

```sh
nim c -d:release --checks:on -r tests/fuzz/parsers.nim 20    # 20 seconds a reader or formatter
```

Real files — ned's own Nim, C, NIF, JSON, CSS, HTML, SQL, Markdown, YAML, TOML — changed at random (bytes, brackets,
quotes and comment markers put in, pieces cut, repeated or dropped) and given to each reader and formatter. A crash
(an index out of range, a range error, a nil, an assertion — what would close the editor) is reported with its input
in `tests/fuzz/found/`. Built with `-d:useMalloc --passC:"-fsanitize=address,undefined -fno-sanitize=null"
--passL:"-fsanitize=address,undefined"` it looks for memory errors too.

## The engine graded by the compiler

`tests/engine/nifgrade.py MAIN.nim --nim NIM24 --driver tests/engine/ned-engine` (the driver: `tests/engine/build.sh`)
has Nim 2.4's `nim nif` read the program, then asks ned's engine for the declaration of each use of a module's name
that the compiler's NIF answers, and lists where they differ.

## The engine comparison

See [`engine/README.md`](engine/README.md): the numbers in the main README's *How good it is* come from there.
