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

*nedls: Restart the server* and *nedls: Show its log* are in the command palette.

## Build the .vsix yourself

```sh
cd editors/vscode
npm install
npx @vscode/vsce package --out vscode-nedls.vsix
```
