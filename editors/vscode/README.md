# nedls for VS Code

[ned](https://github.com/foxoman/ned)'s own Nim engine in VS Code, as a language server: completion with
documentation and the import it adds, hover, signature help, definition, references, rename, call and type
hierarchy, code lens (run a test, a suite, a task), inlay hints, semantic colours, formatting, quick fixes and
refactorings, and problems as you type — the same code ned's editor runs, with no nimsuggest or nimlangserver.
It answers for C, C++, JavaScript, HTML, CSS, SQL and JSON too when you ask it to (`nedls.languages`).

## Install

1. nedls itself: `nimble install ned` builds `ned`, `nedfmt` and `nedls`; or take `nedls` from a ned release.
2. This extension: *Extensions › … › Install from VSIX…* and pick `vscode-nedls-<version>.vsix` (each ned
   release has one, built by its CI).
3. If the Nim extension (nimlangserver) is installed too, turn its language server off, or disable it for the
   workspace — two servers answer twice.

## Settings

| setting | default | what it does |
|---|---|---|
| `nedls.path` | `nedls` | the program: its name on PATH, or its full path |
| `nedls.languages` | `["nim", "nimscript", "nimble"]` | the languages it answers for — add `c`, `cpp`, `javascript`, `html`, `css`, `sql`, `json` |
| `nedls.inlayHints` | `true` | type hints, and parameter names in calls |
| `nedls.parameterHints` | `literals` | parameter names before literal arguments, `all`, or `off` |
| `nedls.raisesHints` | `false` | what a routine can raise, after its header |
| `nedls.checkOnSave` | `true` | `nim check` the file when it is saved |
| `nedls.liveDiagnostics` | `true` | check the unsaved text while typing |
| `nedls.formatLineLength` | — | the formatter's line length; not given: ned's `nim.format.lineLength`, else `.editorconfig` |
| `nedls.nedSettings` | `true` | also read ned's own settings files |
| `nedls.trace.server` | `off` | log the messages between VS Code and nedls (`messages`, or `verbose` with their contents) |

*nedls: Restart the server* and *nedls: Show its log* are in the command palette. A change to `nedls.path` or
`nedls.languages` starts a new server; the other settings go to the running one. If nedls stops on its own, a
message says so, with a button to start it again.

## Build the .vsix yourself

The extension is plain JavaScript with a language client of its own: there is nothing to download or install. From
ned's source, with Python 3:

```sh
bash tests/build/vscode.sh OUTDIR       # OUTDIR/vscode-nedls-<version>.vsix
```

It checks that the extension's version is ned's, and what the `.vsix` holds. To try the extension against a nedls
you built (Node 18 or newer; VS Code itself is played by a stand-in):

```sh
node tests/vscode/test_extension.js ./nedls
```
