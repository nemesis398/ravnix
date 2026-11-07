-- Bootstrap: LazyVim and the plugin specs under lua/plugins/.
--
-- Everything LazyVim needs is in the Nix store: lua/ravnix.lua, which
-- modules/common/nvim.nix generates, names the directory that holds every
-- plugin, and lazy.nvim takes each one from there. Nothing is cloned, built
-- or updated when the editor starts, and the editor never asks the network
-- for anything.
local ravnix = require("ravnix")

-- Neovim's own floats (hover, diagnostics, completion docs) get the same
-- single line as lazy.nvim's below.
vim.o.winborder = "single"

-- The config is a read-only copy in the store, so what LazyVim writes next to
-- it goes to the state directory.
vim.g.lazyvim_json = vim.fn.stdpath("state") .. "/lazyvim.json"

vim.opt.rtp:prepend(ravnix.plugins .. "/lazy.nvim")

require("lazy").setup({
  -- `import` is a spec-entry field, NOT a top-level setup option. Top-level
  -- `import` on setup() is silently ignored by lazy.nvim. The LazyVim
  -- starter's spec form is canonical: one entry installs LazyVim itself
  -- and imports its bundled plugin spec; the following entries import the
  -- extras (lazyvim.json would do it, but the config is read-only) and
  -- tell lazy.nvim to auto-discover user spec files at lua/plugins/*.lua.
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "lazyvim.plugins.extras.coding.blink" },
    { import = "lazyvim.plugins.extras.coding.mini-surround" },
    { import = "lazyvim.plugins.extras.editor.snacks_explorer" },
    { import = "lazyvim.plugins.extras.formatting.prettier" },
    { import = "lazyvim.plugins.extras.lang.json" },
    { import = "lazyvim.plugins.extras.lang.markdown" },
    { import = "lazyvim.plugins.extras.lang.nix" },
    { import = "lazyvim.plugins.extras.lang.python" },
    { import = "plugins" },
  },
  -- Plugins are the directories of the store, by name. "" matches every
  -- plugin; with no fallback, a plugin that is not there is an error, never
  -- a clone.
  dev = { path = ravnix.plugins, patterns = { "" }, fallback = false },
  install = { missing = false },
  -- No plugin needs a luarocks package (those come from Nix), and without
  -- this lazy.nvim would try to install hererocks and report its failure.
  rocks = { enabled = false },
  checker = { enabled = false },
  -- The config cannot change under a running editor.
  change_detection = { enabled = false },
  lockfile = vim.fn.stdpath("state") .. "/lazy-lock.json",
  ui = { border = "single" },
  performance = {
    rtp = {
      disabled_plugins = {
        "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin",
      },
    },
  },
})
