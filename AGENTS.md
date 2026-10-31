# Working on ned — for AI agents (and people)

ned is a terminal code editor and Nim IDE written in Nim, standard library only. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and [docs/guide/building.md](docs/guide/building.md) for the long version; this
page is what an agent needs to change ned safely. How each part works, recipes and pitfalls:
[docs/dev](docs/dev/README.md).

## Build

```sh
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim        # the editor (about 7 minutes)
nim c -d:release --opt:speed -d:strip -o:nedfmt src/nedfmt.nim  # the formatter on its own
nim c -d:release -o:nedls src/nedls.nim                         # the Nim engine as a language server
nim c -d:release --hints:off --compileOnly:on src/ned.nim       # a quick check that it compiles (about 2 minutes)
nim c --stackTrace:on --lineTrace:on -o:ned_debug src/ned.nim   # with stack traces (the fuzzer uses it)
```

Nim 2.2 or newer. Cross builds need zig (`pip install ziglang`): `tests/build/termux.sh` (the Termux `.deb`),
`tests/build/windows.sh` (the Windows zip), `tests/build/cross.sh` (every target). Pass `-g0` to `zig cc` (the
scripts do): with debug information, ned's biggest C file needs more than 6 GB to compile.

## How the source is put together

- `src/ned.nim` `include`s most files in order — each sees what the files before it declare. A proc used before
  the file that defines it is included needs a forward declaration in `src/ned/app/forward.nim` (look there
  first: it may exist already, and a second one is an error).
- Some parts are modules of their own (compiled separately, imported): the Nim index (`src/ned/nim/index`), the
  formatters, the regular expressions, `core/text`, the C index, `editor/asmview`, `editor/binfmt` …
  `tests/ui`'s formatter self-test merges every file and module into one — two modules may not both define the
  same top-level name.
- ned's own plugins are in `plugins/<name>/plugin.nims` (off until turned on in the Plugins dock), read into ned when
  it is built — a change to one needs a new build to show in the editor. Their list is `PlugBundledNames` in
  `src/ned/plugins/host.nim`; each has its checks in `tests/plugins/bundled/test_<name>.py`.
- Settings: `defS(…)` in `src/ned/config/settings.nim`, with a description a person can act on. Commands:
  `add(…)` in `src/ned/app/commandlist.nim` (and the menus in `src/ned/ui/menubar.nim`). The plugin API:
  `src/ned/plugins/lib/nedplugin.nim` and `nedlsp.nim`, every exported proc with a `##` doc comment.
- **Closures made in a loop share the loop's variables** — a `let` copy inside the loop too. Every menu item, job
  callback or button made in a loop then acts on the last iteration's value. Use a factory proc
  (`proc act(v: T): Action = (proc() = use(v))`) or `capture v:` (std/sugar; inside it `result` is the lambda's
  own, so collect into a local variable).
- `nim check` and the engine must see what ned sees: a plugin's source gets `--path:` to the plugin library, an
  included file is checked through the module that includes it.

## Test

```sh
for t in tests/unit/t*.nim; do nim r -d:release --hints:off "$t" || break; done   # unit (nimble test)
python3 tests/plugins/tplugins.py ./ned --native      # the plugin host, the API, the examples
python3 tests/plugins/tbundled.py --native            # ned's own plugins (plugins/), in nim e and compiled
python3 tests/lsp/tnedls.py ./nedls                   # nedls: every feature, then random edits
python3 tests/editors/check.py ./nedls                # the set-ups for Neovim, Helix and Zed
python3 tests/tour/check.py                           # the Nim tour's lessons: every cell, every exercise
python3 tests/plugins/tsandbox.py ./ned && python3 tests/ai/tredact.py ./ned && python3 tests/update/tupdate.py ./ned
python3 tests/smoke/commands.py ./ned && python3 tests/smoke/commands.py ./ned --plugins   # every command, every plugin
python3 tests/smoke/commands.py ./ned --menus        # every item of every menu, picked with the keys
python3 tests/hostile/thostile.py ./ned ./nedls      # plugins, the remote control, nedls and the screen fed nonsense
sh tests/format/parsecheck.sh "$(dirname "$(dirname "$(readlink -f "$(command -v nim)")")")"   # the formatter
python3 tests/ui/run.py ./ned [t_name …]              # the editor through tmux: ~1300 checks, about an hour
python3 .github/ci/pty_smoke.py ./ned && python3 .github/ci/bench.py ./ned && python3 tests/perf/rounds.py ./ned
python .github/ci/win_smoke.py ned.exe nedls.exe nedfmt.exe   # on Windows (pip install pywinpty)
NEDBIN=./ned_debug bash tests/fuzz/batch.sh 120 mixed palette hex   # random input; no crash, no internal error
nim c -d:release --checks:on -r tests/fuzz/parsers.nim 20     # every reader and formatter fed broken text: no crash
python3 tests/docs/apiref.py --check && python3 tests/docs/links.py && python3 tests/docs/names.py  # the docs
python3 tests/docs/comments.py                       # every file and routine says what it is
python3 tests/docs/wiring.py ./ned                   # every menu item's command exists, every setting declared and read
python3 tests/memory/bufids.py                       # every table kept per open file is let go when its tab closes
python3 tests/memory/memprobe.py OUT                 # a ned that logs each table's size: soak.py OUT --mem-log M, --diff M
python3 tests/engine/scoreboard.py --engine E --nedls ./nedls --cdriver C --c-files … --cpp-files …  # minimum scores
python3 tests/engine/nifgrade.py MAIN.nim --nim NIM24 --driver E   # Go to definition against Nim 2.4's own NIF
```

A change to a setting or a command: `ned --doc-settings > docs/reference/settings.md` and
`ned --doc-commands > docs/reference/commands.md` (with an empty `XDG_CONFIG_HOME`, so no one's settings get in);
to the plugin API: `python3 tests/docs/apiref.py`. CI fails when they are out of date. A UI test is a
`t_<version>_<topic>` function in `tests/ui/suite.py`, added to the `tests` list at its end; it drives keys and
mouse clicks (`click(x, y)`, columns and rows from 1) and reads the screen back. Run the UI suite on a quiet
machine: under load a few timing-sensitive tests can fail, and pass alone.

## Write

- Documentation lives in `docs/` (the README is an overview). Plain words: say what happens for the person using
  ned, not how it is implemented; British spelling as the rest; no marketing.
- Every file starts with a comment saying what it is, and every routine (proc, func, method, iterator, converter,
  template, macro — local ones too) says what it does and how: a `##` first in its body, or a `#` line above a
  one-line one. `python3 tests/docs/comments.py` checks it (CI too); `--list` shows what is missing.
- Comments say why, in the same plain style. Keep a change small and in the style of the code around it.
- A release: the version in `src/ned/version.nim`, `ned.nimble`, `editors/vscode/package.json`,
  `editors/zed/extension.toml` and `editors/zed/Cargo.toml` (and the file names in the README), a
  *What's new* section at the top of the README (the one before moves to CHANGELOG.md), every test above passing.
