-- nedls in Neovim, in one call:
--
--     require('nedls').setup({ settings = { nedls = { parameterHints = 'all' } } })
--
-- Neovim 0.11 and newer: the configuration in lsp/nedls.lua, with what you give merged in, then vim.lsp.enable.
-- Neovim 0.10: the same configuration, started with vim.lsp.start for each Nim buffer.
-- Options besides the server's own (cmd, filetypes, settings, init_options, on_attach, capabilities …):
--   inlay_hints = true   turn Neovim's inlay hints on in the buffers nedls attaches to
--   languages = { 'c', 'cpp', … }   more filetypes nedls answers for: ned's own engines for C, C++, JavaScript,
--                        HTML, CSS, SQL and JSON (turn the other servers for those off, or both answer)

local M = {}

local function base()
  -- (lsp/nedls.lua, from the same plugin folder: one place for the configuration)
  local here = debug.getinfo(1, 'S').source:sub(2)
  local file = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(here)), 'lsp', 'nedls.lua')
  local ok, cfg = pcall(dofile, file)
  if ok and type(cfg) == 'table' then
    return cfg
  end
  return { cmd = { 'nedls' }, filetypes = { 'nim', 'nims', 'nimble' } }
end

local function inlay(bufnr)
  if vim.lsp.inlay_hint and vim.lsp.inlay_hint.enable then
    pcall(vim.lsp.inlay_hint.enable, true, { bufnr = bufnr })
  end
end

function M.setup(opts)
  opts = opts or {}
  local hints = opts.inlay_hints ~= false
  local more = opts.languages or {}
  opts.inlay_hints, opts.languages = nil, nil
  local cfg = vim.tbl_deep_extend('force', base(), opts)
  cfg.filetypes = vim.list_extend(vim.deepcopy(cfg.filetypes), more)
  local attach = cfg.on_attach
  cfg.on_attach = function(client, bufnr)
    if hints then
      inlay(bufnr)
    end
    if attach then
      attach(client, bufnr)
    end
  end

  if vim.lsp.config and vim.lsp.enable then
    vim.lsp.config('nedls', cfg)
    vim.lsp.enable('nedls')
    return
  end

  -- Neovim 0.10: started for each buffer of those filetypes, one server per project folder
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('nedls', { clear = true }),
    pattern = cfg.filetypes,
    callback = function(ev)
      local fname = vim.api.nvim_buf_get_name(ev.buf)
      local root = vim.fs.root(ev.buf, function(name)
        return name:match('%.nimble$') ~= nil
      end) or vim.fs.root(ev.buf, { 'nim.cfg', 'config.nims', '.git' }) or vim.fs.dirname(fname)
      local start = vim.tbl_extend('force', cfg, { name = 'nedls', root_dir = root })
      start.root_markers, start.filetypes = nil, nil
      vim.lsp.start(start, { bufnr = ev.buf })
    end,
  })
end

return M
