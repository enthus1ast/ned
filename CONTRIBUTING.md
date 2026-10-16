# Contributing to ned

Thank you for wanting to make ned better. Bug reports, ideas, themes, documentation and code are all welcome.

## Reporting a problem

- Run `ned --check` (or *Help › Check setup*) first: it shows which tools ned found and how to install the ones
  that are missing.
- *Help › Copy info for bug report* puts ned's version, your terminal, OS and the relevant settings on the
  clipboard — paste that into the issue.
- If ned ever showed **Internal error**, attach `~/.local/state/ned/errors.log`.
- Say what you did, what you expected and what happened instead. A small file that shows the problem is worth a
  thousand words; a screenshot helps for anything you can see.
- A security problem? Please don't open a public issue — see [SECURITY.md](SECURITY.md).

## Building

```sh
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim     # Nim 2.2 or newer, nothing else
nimble typecheck                                            # about 6 seconds: does it compile?
nimble debug                                                # ./ned_debug, with stack traces
```

ned uses **only Nim's standard library** (not `std/re` either: it has its own regular expressions in
`src/ned/editor/regex.nim`). Please keep it that way — one binary, nothing to install, and it builds on Termux.

## How the source is laid out

`src/ned.nim` is the program: it imports the few real modules (`ned/core/text`, `ned/editor/regex`,
`ned/format/formatters`, `ned/nim/index`) and **includes** everything else in order. An included file sees only
what was included before it — when a file needs something defined later, it is declared ahead in
`src/ned/app/forward.nim` or `src/ned/ui/actions.nim`.

| folder | what |
|---|---|
| `core/` | types, global state, themes, the cell grid and terminal output, keys, languages, highlighting |
| `editor/` | buffers, editing, cursors, search, clipboard, completion, navigation |
| `nim/` | the Nim IDE: the built-in engine (`nim/index`, also usable as a library), checks, quick fixes, refactors |
| `c/` | ned's own C engine (`cindex.nim`: text in, answers out), C interop: headers, importc wrappers, `{.emit.}` C, clangd |
| `format/` | the built-in formatters (Nim in nph's style, C, JSON, Markdown, CSS) — text in, text out |
| `lsp/` `ai/` `git/` `debug/` `term/` `run/` `testing/` | what their names say |
| `ui/` `app/` | drawing, docks, dialogs, menus, the palette, the main loop |

## Tests

Every release passes all of them; please run the ones near your change (and add one for it):

```sh
nimble test                                        # unit tests: the Nim and C engines, the formatters, the regexes
python3 tests/ui/run.py ./ned t_63_format          # UI tests by name (--list shows them); all: nimble uitest
python3 tests/themes/contrast.py                   # a theme's colours, checked for contrast
```

The UI tests drive ned through tmux exactly like a person would — keys in, the screen read back
([tests/README.md](tests/README.md) explains them, the fuzzer, the engines' comparisons with nimsuggest and
clangd, and the cross builds). A change to something you can see wants a UI test; a change to an engine or a
formatter wants a unit test.

## A few rules ned keeps

- **Your work is never lost**: saves are atomic, unsaved edits have recovery files, and a file ned is not sure
  about is left alone (the formatters check their own result and refuse rather than change your code).
- **Secrets stay secret**: API keys and passwords never go on a command line or into a log; text that is checked
  goes to private temporary files (a 0700 folder) that are removed afterwards.
- **Fast on a phone**: nothing slow on the main loop; big files have a large-file mode; memory is measured
  (`nimble perf` checks the budget in `.github/ci/bench-budget.json`).
- **Plain words** in the interface and the docs: say what happens, not how it is implemented.

## Themes

A theme is one line in `src/ned/core/themes.nim` (`mkTheme(name, dark, bg, fg, accent, …)`), or a JSON file in
`~/.config/ned/themes/` for your own. A built-in theme must pass `tests/themes/contrast.py`: text 7:1 against the
background, keywords, types, strings and the like 4.5:1, comments 3:1, and syntax colours that are easy to tell
apart.

## Pull requests

- One topic per pull request; say what it changes for the person using ned.
- `nimble typecheck`, `nimble test` and the UI tests near your change pass.
- New settings go in `src/ned/config/settings.nim` with a description a person can act on.
- Update `README.md` (the feature) and, for a release, `CHANGELOG.md`.

By contributing you agree that your work is released under ned's [MIT licence](LICENSE).
