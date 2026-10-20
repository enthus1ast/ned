# ned's tests

Every release of ned passes all of these. They need nothing that is not on GitHub's runners (see
[`.github/workflows/tests.yml`](../.github/workflows/tests.yml), which runs them on every push).

| folder | what | how long | run |
|---|---|---|---|
| [`unit/`](unit) | the Nim index (compile-time values too, kept on disk, memory layouts and exception hints checked against the compiler, the package versions a build uses), the C index, the formatters and nedfmt, the regular expressions, where ARC/ORC copies, what each Nim release added, columns counted 8 bytes at a time, executables read (ELF, Mach-O, PE) and Nim's names in them — as libraries, without the editor | seconds | `nimble test` |
| [`lsp/`](lsp) | nedls driven by a small LSP client: every feature, then 2000 random edits that must not put it out of step | a minute | `nimble lsptest` |
| [`format/`](format) | the Nim formatter on 463 files of Nim's compiler and standard library, each checked by Nim's own parser | minutes | `nimble parsecheck` |
| [`ui/`](ui) | the whole editor driven through tmux: keys in, the screen read back — every feature, about 1000 checks | ~1 hour | `nimble uitest` |
| [`fuzz/`](fuzz) | random keys, mouse events, pastes, palette commands and resizes; crashes, hangs and internal errors reported | as long as you like | `tests/fuzz/batch.sh 120 mixed vim palette` |
| [`engine/`](engine) | ned's Nim engine against nimsuggest on the standard library, nimble packages and the compiler; its C engine against clangd | ~1 hour | `tests/engine/build.sh && tests/engine/corpus.sh /tmp/out` · `tests/engine/ccompare.py` |
| [`build/`](build) | ned built for every target: gcc, clang, and with zig macOS (arm64, x86_64) and Android/Linux arm64 — nedfmt and nedls too | minutes | `tests/build/cross.sh` |
| [`themes/`](themes) | every built-in theme's colours against its background; ned's own must pass | a second | `python3 tests/themes/contrast.py` |

Speed and memory are checked by [`.github/ci/bench.py`](../.github/ci/bench.py) (`nimble perf`) against the
limits in `bench-budget.json`, and [`.github/ci/pty_smoke.py`](../.github/ci/pty_smoke.py) runs ned in a real
pseudo-terminal.

## The UI tests

```sh
nimble release                                   # ./ned
python3 tests/ui/run.py ./ned                    # all of them
python3 tests/ui/run.py ./ned t_528_refs t_57_ai # some of them (--list shows the names)
```

They need **tmux**, **git**, **python3** and **nim** on PATH. Each test starts ned in a private tmux server, in a
scratch copy of [`ui/fixtures/demo`](ui/fixtures/demo) (made a git repository on the fly), with settings of its own,
and talks to it the way a person would. A mock AI server ([`ui/mocks/mockai.py`](ui/mocks/mockai.py)) answers the
assistant like the real APIs do — including their refusals — so the AI features are tested without a key.

Some tests use optional tools; when one is missing, the test is skipped and says what it needs:

| tool | tests |
|---|---|
| nimlangserver | the language-server mode of the Nim features |
| clangd | C in `{.emit.}`, C interop, clangd's fixes |
| node, vscode-langservers-extracted, sql-language-server | HTML, CSS, SQL and JSON inside Nim strings |
| gdb, lldb, debugpy | debugging |
| pytest, go | the test explorer for Python and Go |
| zsh, fish | the terminal's shell integration (bash is always tested) |
| an en_US hunspell dictionary (`hunspell-en-us`) | spell checking |
| an SSH server | remote folders over SSH: run [`ui/ssh-setup.sh`](ui/ssh-setup.sh) on a throwaway machine (it adds hosts to `~/.ssh/config`), then `NED_TEST_SSH=1` |

What ned sends to the terminal is checked too: [`ui/vt.py`](ui/vt.py), a small terminal model, reads every byte of
a session (scroll regions, colours carried along a row, skipped cells) and the screen it ends up with must be the one
a full redraw draws.

`NED_TEST_PATH` puts more folders on the tests' PATH (where your language servers are, say).
`NED_TEST_DICT` names a dictionary. `--shard 2/4` runs a quarter of the tests (CI runs four parts at once).
A run that fails keeps its scratch folder and says where it is.

## The fuzzer

```sh
nim c -d:release --stackTrace:on --lineTrace:on -o:ned_debug src/ned.nim
NEDBIN=./ned_debug tests/fuzz/batch.sh 120 mixed vim helix emacs palette refactor ai git fixes c
```

Each mode is a two-minute round with a different mix of input (`ai` drives the assistant, `git` a repository with
history, `fixes` code full of compiler errors, `c` C files with ned's own engine and its ligatures, `refactor` procs to change). The fuzzer works in a scratch home of
its own, with a copy of the Nim toolchain (random keys can go to a definition in the standard library and save
it), but random palette commands can run tasks and shell commands in its test project, and random keys can
"save as" anywhere ned may write: give it a throwaway user (`NED_FUZZ_USER=fuzz`, run as root — as root it does
not start without one). Logs go to `/tmp/ned-fuzz-UID-logs`.

## The engine comparison

See [`engine/README.md`](engine/README.md): the numbers in the main README's *How good it is* come from there.
