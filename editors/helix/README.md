# nedls in Helix

[ned](https://github.com/foxoman/ned)'s own Nim engine in Helix, as a language server: completion with
documentation, hover, signature help, definition, references, rename, inlay hints, formatting, quick fixes and
refactorings (Space a), problems as you type, and workspace symbols (Space S) — with no nimsuggest or
nimlangserver.

## Install

1. nedls itself: `nimble install ned` builds `ned`, `nedfmt` and `nedls`; or take `nedls` from a ned release. It
   must be on `PATH` (or give its full path as `command`).
2. Copy the entries of [`languages.toml`](languages.toml) into your own `~/.config/helix/languages.toml` (or a
   project's `.helix/languages.toml`). They replace nimlangserver, Helix's default for Nim.
3. `hx --health nim` shows nedls found.

## Settings

The keys under `[language-server.nedls.config]` go to nedls when it starts: `inlayHints`, `parameterHints`
(`literals`, `all`, `off`), `raisesHints`, `checkOnSave`, `liveDiagnostics`, `workspaceDiagnostics`,
`formatLineLength`, `nedSettings` — `nedls --help` says what each does. Inlay hints show when Helix's
`lsp.display-inlay-hints` is on (`:toggle lsp.display-inlay-hints`).

For C, C++, JavaScript, HTML, CSS, SQL or JSON, nedls answers with ned's own engines too: add it to that
language's `language-servers` (the end of `languages.toml` shows how, next to clangd).
