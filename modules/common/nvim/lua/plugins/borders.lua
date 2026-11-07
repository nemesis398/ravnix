-- Floats have a single thin line (docs/style.md): lazy.nvim's `ui.border` and
-- Neovim's `winborder` are set in init.lua, and the windows of the plugins
-- that choose their own border are set here. Snacks follows `winborder`; which-key's
-- preset and noice's views name a border of their own.
local single = { style = "single" }

return {
  { "folke/which-key.nvim", opts = { win = { border = "single" } } },
  {
    "folke/noice.nvim",
    opts = {
      views = {
        popup = { border = single },
        cmdline_popup = { border = single },
        cmdline_input = { border = single },
        confirm = { border = single },
        hover = { border = single },
        signature = { border = single },
      },
    },
  },
}
