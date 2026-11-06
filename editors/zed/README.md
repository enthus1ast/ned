# nedls for Zed

[ned](https://github.com/foxoman/ned)'s own Nim engine in Zed, as a language server: completion with
documentation and the import it adds, hover, signature help, definition, references, rename, inlay hints,
semantic colours, formatting, quick fixes and refactorings, problems as you type (and the whole project's), and
project symbols — with no nimsuggest or nimlangserver.

This extension starts nedls; Zed knows Nim's files and colours from the **Nim** extension, so install that one as
well.

## Install

1. **nedls itself.** With Nim 2.2 or newer: `nimble install https://github.com/foxoman/ned` builds `ned`, `nedfmt`
   and `nedls` into `~/.nimble/bin`. It must be on the `PATH` of your shell, or named in the settings below. The
   extension never downloads it.
2. **The Nim extension**, from Zed's extensions (`zed: extensions`).
3. **This extension**, from Zed's extensions (search for *nedls*) — or as a dev extension: clone
   [github.com/foxoman/nedls-zed](https://github.com/foxoman/nedls-zed), run `zed: install dev extension` and pick
   the folder. Zed builds it; that needs Rust installed with rustup (Zed adds the WebAssembly target it builds for).
4. **nedls for Nim**, in Zed's settings (instead of the Nim extension's nimlangserver), with its colours:

```json
{
  "languages": {
    "Nim": { "language_servers": ["nedls", "!nim", "..."], "semantic_tokens": "combined" }
  }
}
```

## Colours

Two layers. The Nim extension's grammar colours what the text is — keywords, strings, numbers, comments, pragmas.
nedls colours what each name *is*, as ned does: a type, a proc or template, a macro, a parameter, a field, an enum
value, a module, a constant (`readonly`), a deprecated name. Zed asks the server for these only with
`"semantic_tokens": "combined"` (above; `"full"` uses nedls's alone), and draws them in the theme's colours for
`type`, `function`, `variable`, `property` … To change one, add a rule under `global_lsp_settings` — nedls's kinds
are LSP's own: `namespace`, `type`, `enumMember`, `variable`, `parameter`, `property`, `function`, `macro`, with
`declaration`, `readonly`, `static` and `deprecated`:

```json
{
  "global_lsp_settings": {
    "semantic_token_rules": [
      { "token_type": "macro", "foreground_color": "#c792ea" },
      { "token_type": "variable", "token_modifiers": ["readonly"], "style": ["constant"] }
    ]
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
Inlay hints show when `"inlay_hints": {"enabled": true}` is in Zed's settings.

## Other languages

nedls also answers for C, C++, JavaScript, HTML, CSS, SQL and JSON with ned's own engines. To have Zed start it
for those, add them to `languages` in `extension.toml` (of a dev extension), and to `opt_in_languages` so that only
the languages whose `language_servers` name `nedls` get it:

```toml
[language_servers.nedls]
name = "nedls"
languages = ["Nim", "C", "JSON"]
opt_in_languages = ["C", "JSON"]
```

## Where it lives

This extension is its own repository, [github.com/foxoman/nedls-zed](https://github.com/foxoman/nedls-zed) — the
one in Zed's extensions — and a copy of it is in ned's source, `editors/zed`, kept the same (ned's tests check it).
Its version is ned's.

## Licence

GPL-3.0-or-later, as ned ([LICENSE](LICENSE)). Copyright © Sultan Al Isaiee (@foxoman).
