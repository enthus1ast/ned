-- nedls — ned's Nim engine as a language server — for Neovim 0.11 or newer, in the shape nvim-lspconfig's configs
-- have: a table vim.lsp.config reads when this file is in an `lsp/` folder on 'runtimepath'. Then
--
--     vim.lsp.enable('nedls')
--
-- starts it for Nim, NimScript and .nimble files. Change what you like with vim.lsp.config('nedls', { … }) — the
-- settings are under `settings.nedls` (see editors/nvim/README.md, or `nedls --help`).

---@type vim.lsp.Config
return {
  cmd = { 'nedls' },
  filetypes = { 'nim', 'nims', 'nimble' },
  -- the project: the folder of its .nimble, else of nim.cfg or config.nims, else of .git, else the file's own
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local root = vim.fs.root(bufnr, function(name)
      return name:match('%.nimble$') ~= nil
    end) or vim.fs.root(bufnr, { 'nim.cfg', 'config.nims', '.git' })
    on_dir(root or vim.fs.dirname(fname))
  end,
  -- (read when nedls starts; the same keys under settings.nedls go to the running server when they change)
  init_options = {
    nedSettings = true,
  },
  settings = {
    nedls = {
      inlayHints = true,
      parameterHints = 'literals',
      raisesHints = false,
      checkOnSave = true,
      liveDiagnostics = true,
      workspaceDiagnostics = true,
    },
  },
}
