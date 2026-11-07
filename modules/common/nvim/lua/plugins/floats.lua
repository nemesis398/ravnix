-- How floats look (docs/style.md): a single thin line around each, and fully
-- opaque, with no dimmed backdrop behind.
--
-- Neovim's `winborder`, lazy.nvim's `ui.border` and `ui.backdrop`, and the
-- popup menu's `pumblend` are set in init.lua and config/options.lua. This
-- file sets the windows of the plugins that choose their own border or blend:
-- which-key's preset and noice's views name a border, noice's "mini" view (the
-- short messages) and snacks' notifications blend into the text below, and
-- snacks dims the editor behind its float and zen windows. Snacks follows
-- `winborder` for the rest.
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
        mini = { win_options = { winblend = 0 } },
      },
    },
  },
  {
    "folke/snacks.nvim",
    opts = {
      styles = {
        notification = { wo = { winblend = 0 } },
        -- A snacks float has no border of its own; `true` takes `winborder`.
        float = { backdrop = false, border = true },
        zen = { backdrop = false },
      },
    },
  },
}
