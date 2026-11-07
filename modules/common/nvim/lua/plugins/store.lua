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
local ravnix = require("ravnix")

return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  -- Not the colorscheme, so not in the store.
  { "folke/tokyonight.nvim", enabled = false },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { install_dir = ravnix.treesitter },
  },
}
