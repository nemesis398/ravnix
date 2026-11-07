-- What makes LazyVim run from the Nix store alone.
--
-- Mason is off. It would download language servers and formatters into the
-- user's home, and every one of them is a Nix package already, on the PATH of
-- the editor (modules/common/nvim.nix). LazyVim then enables each server of
-- its `servers` table by itself, so a language server that is not in a
-- LazyVim extra is listed under `servers` in the spec file of its language
-- (lua/plugins/bash.lua, odin.lua).
--
-- Treesitter parsers and queries are built by Nix too. nvim-treesitter
-- looks for what is installed in `install_dir` only, so it is pointed at the
-- directory that holds them; with every parser LazyVim asks for there,
-- nothing is downloaded or compiled.
--
-- A host installs the tools of some languages only (ravnix.editor.languages).
-- What the others would start is turned off here, so that opening a file of
-- such a language is not an error: its servers, and the formatters and linters
-- LazyVim and the extras name for it.
local ravnix = require("ravnix")

local scope = {
  bash = { servers = { "bashls" }, formatters = { "shfmt" } },
  json = { servers = { "jsonls" } },
  lua = { servers = { "lua_ls" }, formatters = { "stylua" } },
  markdown = {
    servers = { "marksman" },
    formatters = { "markdownlint-cli2", "markdown-toc" },
    linters = { "markdownlint-cli2" },
  },
  nix = { servers = { "nil_ls" }, formatters = { "nixfmt" }, linters = { "statix" } },
  odin = { servers = { "ols" }, formatters = { "odinfmt" } },
  python = { servers = { "pyright", "ruff" } },
  web = { formatters = { "prettier" } },
}

local servers, formatters, linters = {}, {}, {}
for language, tools in pairs(scope) do
  if not ravnix.languages[language] then
    for _, name in ipairs(tools.servers or {}) do
      servers[name] = { enabled = false }
    end
    vim.list_extend(formatters, tools.formatters or {})
    vim.list_extend(linters, tools.linters or {})
  end
end

-- `by_ft` is conform's formatters_by_ft or nvim-lint's linters_by_ft: lists of
-- names by filetype, and a list may be a function.
local function prune(by_ft, names)
  for ft, list in pairs(by_ft or {}) do
    if type(list) == "table" then
      by_ft[ft] = vim.tbl_filter(function(name)
        return not vim.tbl_contains(names, name)
      end, list)
    end
  end
end

return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  -- Not the colorscheme, so not in the store.
  { "folke/tokyonight.nvim", enabled = false },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { install_dir = ravnix.treesitter },
  },
  { "neovim/nvim-lspconfig", opts = { servers = servers } },
  -- This file sorts after the others of lua/plugins, so these see what the
  -- spec files of the languages added.
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      prune(opts.formatters_by_ft, formatters)
    end,
  },
  {
    "mfussenegger/nvim-lint",
    opts = function(_, opts)
      prune(opts.linters_by_ft, linters)
    end,
  },
}
