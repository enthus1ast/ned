# Building, tasks and performance

```sh
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim      # what you need
```

`src/ned.nims` (picked up automatically) turns on `--opt:speed` for release builds. Add `-d:lto` for link-time
optimisation: 5–10% less time in the engine and the formatter, a 7% smaller binary and 1.5 MB less memory at
start, for a build that takes about twice as long (gcc, or clang with a linker that does LTO); the release binaries
are built with it. `-d:useMalloc` (the C library's allocator) saves about 3 MB with a big file open but makes the
engine and the formatter 20% slower: not used, but yours to add where memory matters most. The nimble file has
tasks:

| task | |
|---|---|
| `nimble release` | optimised `./ned` |
| `nimble termux` | build into `$PREFIX/bin` |
| `nimble termuxdeb` · `nimble windowszip` | the Termux package (`.deb`) · the Windows zip — cross-built with zig (below) |
| `nimble local` | build into `~/.local/bin` |
| `nimble debug` | debug build with stack traces |
| `nimble typecheck` | `nim check` only |
| `nimble android` | verify it compiles for Android/arm64 (C generation only) |
| `nimble test` | the unit tests: the Nim and C indexes, the formatters, the regular expressions, ARC/ORC copies |
| `nimble uitest` | the whole editor driven through tmux (needs tmux; see [tests/README.md](../../tests/README.md)) |
| `nimble bench` | render a 200 000-line file off-screen and print frame timings and bytes |
| `nimble perf` | startup time, memory and frame times, then the longest waits while working on ned's own source (opening, scrolling, typing, completion, a new import) and the memory with the engine worker — each checked against its budget (needs python3; the second part on Linux) |
| `nimble smoke` | build and run the non-interactive checks |
| `nimble nedfmt` · `nimble nedls` | build the formatter and the language server on their own |
| `nimble lsptest` | nedls driven by a test client: every feature, then 2000 random edits |
| `nimble parsecheck` | the formatter over 463 files of Nim's own source, each checked by Nim's parser |
| `nimble tools` | install nimlangserver, nph and inim |

## Packages and other platforms

ned cross-compiles with [zig](https://ziglang.org) as the C compiler (`pip install ziglang` gives you one), so one
Linux machine builds every release:

| script | what it makes |
|---|---|
| `tests/build/termux.sh [OUTDIR]` (`nimble termuxdeb`) | ned, nedls and nedfmt for Termux (Android, arm64) and `ned_<version>_aarch64.deb` — on the phone: `pkg install ./ned_*.deb` |
| `tests/build/windows.sh [OUTDIR]` (`nimble windowszip`) | `ned.exe`, `nedfmt.exe` and `nedls.exe` for Windows x86-64, and `ned-<version>-windows-x86_64.zip` |
| `tests/build/cross.sh [OUTDIR]` | ned for every target this machine reaches — gcc, clang, macOS arm64 and x86_64, Android/Linux arm64, Windows x86_64 — with nedfmt and nedls; one line per target, exit status 1 when one fails |

By hand, a target is a zig wrapper and four options — Windows, for instance:

```sh
printf '#!/bin/sh\nexec zig cc -target x86_64-windows-gnu "$@"\n' > zcc && chmod +x zcc
nim c -d:release --os:windows --cpu:amd64 --cc:clang --clang.exe:./zcc --clang.linkerexe:./zcc -o:ned.exe src/ned.nim
```

(`aarch64-macos`, `x86_64-macos` with `--os:macosx`; `aarch64-linux-musl` with `--os:android --cpu:arm64` for
Termux.) GitHub Actions does the same natively on each platform: `.github/workflows/build.yml` builds Linux
(x86_64, arm64), macOS (arm64, x86_64), Termux, Windows (native and WSL), runs each in a pseudo-terminal, and
attaches the programs to the release when a tag such as `v6.24.0` is pushed. On every push, `tests.yml` also tests
the native Windows build: the unit tests that do not need a POSIX system, and `.github/ci/win_smoke.py` — `ned.exe`
started in a Windows console (ConPTY), typed into, saved and quit; `nedls.exe` answering hover and the file's
symbols; `nedfmt.exe` formatting.

## Nim's package list

`nimble install ned` works once ned is in Nim's package list ([nim-lang/packages](https://github.com/nim-lang/packages),
whose `packages.json` has no `ned` yet). The entry to add there, in a pull request:

```json
{
  "name": "ned",
  "url": "https://github.com/foxoman/ned",
  "method": "git",
  "tags": ["editor", "ide", "terminal", "tui", "termux", "lsp", "formatter", "nim"],
  "description": "Terminal code editor and Nim IDE for Termux, Linux, macOS and Windows: a built-in Nim engine, an nph-style formatter, an AI assistant, plugins in NimScript",
  "license": "GPL-3.0-or-later",
  "web": "https://github.com/foxoman/ned"
}
```

`nimble install` builds `ned`, `nedfmt` and `nedls` into `~/.nimble/bin` (checked: from a clean `NIMBLE_DIR`, the
three start and answer `--version`). Until the entry is in, `nimble install https://github.com/foxoman/ned` does the
same.

## Why it is fast

A cell grid with per-cell diffing (only changed cells are sent, inside synchronized-output
frames, colours carried along a row and unchanged stretches skipped), scrolling done by the terminal itself (a
scroll region: only the new lines are sent), incremental per-line highlighting with a background pass, nothing done
per frame that depends on file size, file indexing and project search in the background, the engine's hints,
checks and counts in the engine worker (a second ned on another core, `nim.engineWorker`), language servers and git
in separate processes with non-blocking pipes and a
lower priority than ned, and zero CPU while idle. Files over 40 000 lines skip the language server so typing stays
instant; a 1-million-line file scrolls and edits normally.

*Help › Performance…* shows how ned does on your device: frames (made in, bytes sent, how long the terminal took),
the terminal's speed, the moments ned could not read input and what kept it busy, the engine's timings, memory and
what runs in the background, with the settings that would make it lighter. `NED_PERF_LOG=file` writes it when ned
exits; `NED_PERF_TRACE=file` writes every round of its main loop over 4 ms with what it did (and how much of it the
processor gave ned — the rest it waited), which is what `tests/perf/rounds.py` reads (`--one-core`: ned, its worker
and what they run on one core, a phone's stand-in). `ned --bench FILE` gives the time and bytes per frame without a terminal, and
`ned --startup-time [file …]` where the time goes when ned starts, and the memory it uses (see the 5.22 notes); CI
checks those numbers on every push.

## The source

ned is one program in about 310 files, standard library only:

```
src/ned.nim            the program: the parts below, in the order they build on each other
src/ned/
  core/                types, global state, themes, the cell grid and terminal output, keys, languages, highlighting
  editor/              the buffer and its undo tree, editing, cursors, selection by structure, surround, next edits, find …
  ui/                  drawing: layout, menus, dialogs, pickers, docks, the file tree, the panel, the editor view
  nim/                 the Nim IDE: the engine's glue, quick fixes, refactorings, codegen, nimble, examples …
  nim/index/           the Nim index — a module of its own: parsing, scopes, types, completion, hover, typos
  format/              the formatters (Nim, JSON, Markdown, CSS, HTML, SQL — a module of their own) and Format all
  web/                 ned's own CSS, HTML, SQL and JavaScript: what they know, completion, hover, problems (a module)
  lsp/                 the language-server client, code actions, inlay hints, servers for code inside strings
  ai/                  the assistant: requests, agent tools, MCP, chats, inline suggestions
  plugins/             the plugin host (its processes, the API) and the library plugins import (lib/nedplugin.nim)
  sys/                 Windows: its POSIX calls done with Win32 and the C runtime (winposix), std/os with '/' (winos)
  git/  term/  debug/  c/  run/  testing/  project/  config/  keymaps/  app/
tests/                 unit tests, the UI suite, the fuzzer, the engine comparison, the plugins, cross builds
examples/showcase.nim  one Nim file that tours what ned does for Nim
examples/plugins/      the example plugins
```

Most files are parts of the program (`include`d in order: each sees the ones before it). The Nim index, the
formatters, the regular expressions, `core/text` and `core/editorconfig` are modules: they compile on their own, in
parallel, and other programs can import them (`import ned/nim/index`). `nim/nimapis.nim` — what each Nim release
added to the standard library — is made by `.github/ci/nimapis.py` from the releases' libraries. The tests are described in
[tests/README.md](../../tests/README.md); GitHub runs them on every push.
