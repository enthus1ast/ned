# nedls in Neovim

[ned](https://github.com/foxoman/ned)'s own Nim engine in Neovim, as a language server: completion with
documentation and the import it adds, hover, signature help, definition, references, rename, call and type
hierarchy, inlay hints, semantic colours, formatting, quick fixes and refactorings, problems as you type (and the
whole project's, when Neovim asks for them), and workspace symbols — with no nimsuggest or nimlangserver.

## Install

1. nedls itself: `nimble install ned` builds `ned`, `nedfmt` and `nedls`; or take `nedls` from a ned release. It
   must be on `PATH` (or give its full path in `cmd`).
2. The configuration, one of:
   - **Neovim 0.11 or newer, by hand:** copy [`lsp/nedls.lua`](lsp/nedls.lua) to `~/.config/nvim/lsp/nedls.lua`
     and add `vim.lsp.enable('nedls')` to your `init.lua`.
   - **As a plugin** (Neovim 0.10 too): put this folder on `runtimepath` — with lazy.nvim,
     `{ dir = '/path/to/ned/editors/nvim' }` — and call `require('nedls').setup()`.
3. If nimlangserver is set up too (nvim-lspconfig's `nim_langserver`), turn it off — two servers answer twice.

Open a `.nim` file: `:checkhealth vim.lsp` shows nedls attached.

## Settings

Change what you like with `vim.lsp.config` (0.11) or in `setup`:

```lua
vim.lsp.config('nedls', {
  settings = { nedls = { parameterHints = 'all', raisesHints = true } },
})

-- or, with the plugin:
require('nedls').setup({
  settings = { nedls = { parameterHints = 'all' } },
  inlay_hints = true,                 -- Neovim's inlay hints on where nedls attaches
  languages = { 'c', 'cpp', 'json' }, -- ned's own engines for these too (turn their other servers off)
})
```

| setting | default | what it does |
|---|---|---|
| `inlayHints` | `true` | type hints after `let`/`var`/`const`, and parameter names in calls |
| `parameterHints` | `literals` | parameter names before literal arguments, `all`, or `off` |
| `raisesHints` | `false` | what a routine can raise, after its header |
| `checkOnSave` | `true` | `nim check` the file when it is saved |
| `liveDiagnostics` | `true` | check the unsaved text while typing |
| `workspaceDiagnostics` | `true` | when Neovim asks for the whole workspace's problems, ned's checks go over the project's files that are not open too |
| `formatLineLength` | — | the formatter's line length (40–240); not given: ned's `nim.format.lineLength`, else `.editorconfig` |
| `nedSettings` | `true` | (in `init_options`) also read ned's own settings files |

Inlay hints show after `vim.lsp.inlay_hint.enable()`. Neovim 0.12's `vim.lsp.buf.workspace_diagnostics()` asks
for every file's problems at once: nedls answers with what it knows, and its checks of the files that are not open
come in while it is idle. Workspace symbols (`vim.lsp.buf.workspace_symbol()`, or a picker's) find the project's
names, and the names its imports export for a query of three letters or more; `Shape.wid` finds the fields of
`Shape` that start with `wid`.
