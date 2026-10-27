# nedls for Zed

[ned](https://github.com/foxoman/ned)'s own Nim engine in Zed, as a language server: completion with
documentation and the import it adds, hover, signature help, definition, references, rename, inlay hints,
semantic colours, formatting, quick fixes and refactorings, problems as you type (and the whole project's), and
project symbols — with no nimsuggest or nimlangserver.

This extension starts nedls; Zed knows Nim's files and colours from the **Nim** extension, so install that one as
well.

## Install

1. nedls itself: `nimble install ned` builds `ned`, `nedfmt` and `nedls`; or take `nedls` from a ned release. It
   must be on the `PATH` of your shell, or named in the settings below.
2. The **Nim** extension, from Zed's extensions (`zed: extensions`).
3. This extension, as a dev extension: `zed: install dev extension`, and pick `editors/zed`. Zed builds it from
   this folder; that needs Rust installed with rustup (Zed adds the WebAssembly target it builds for).
4. nedls instead of the Nim extension's nimlangserver, in Zed's settings:

```json
{
  "languages": {
    "Nim": { "language_servers": ["nedls", "!nim", "..."] }
  }
}
```

## Settings

Under `lsp.nedls` in Zed's settings: `binary` (the program and its arguments, when it is not `nedls` on
`PATH`), `initialization_options` (read when nedls starts) and `settings` (sent again when they change):

```json
{
  "lsp": {
    "nedls": {
      "binary": { "path": "/home/me/.nimble/bin/nedls" },
      "initialization_options": { "nedSettings": true },
      "settings": { "inlayHints": true, "parameterHints": "all", "workspaceDiagnostics": true }
    }
  }
}
```

The settings are those of `nedls --help`: `inlayHints`, `parameterHints` (`literals`, `all`, `off`),
`raisesHints`, `checkOnSave`, `liveDiagnostics`, `workspaceDiagnostics`, `formatLineLength`, `nedSettings`.
Inlay hints show when `"inlay_hints": {"enabled": true}` is in Zed's settings; nedls's semantic colours when
`"semantic_tokens"` is `"combined"`.

## Other languages

nedls also answers for C, C++, JavaScript, HTML, CSS, SQL and JSON with ned's own engines. To have Zed start it
for those, add them to `languages` in `extension.toml`, and to `opt_in_languages` so that only the languages whose
`language_servers` name `nedls` get it (a Zed too old for `opt_in_languages` starts it for all of them):

```toml
[language_servers.nedls]
name = "nedls"
languages = ["Nim", "C", "JSON"]
opt_in_languages = ["C", "JSON"]
```
