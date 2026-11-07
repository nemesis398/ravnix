-- Right-side Snacks file explorer, and two snacks features switched off.
--
-- neo-tree is replaced by the `editor.snacks_explorer` extra (imported in
-- init.lua) — NOT by any snacks option. That extra also provides the
-- canonical <leader>e / <leader>fe keymaps, so we don't hand-roll keys here.
--
-- The explorer is a snacks *picker* source, so its position/width live under
-- picker.sources.explorer.layout — `width` is a 0..1 fraction of columns. Snacks
-- has no pane-following "dynamic" width. NOTE: the explorer inherits the built-in
-- `sidebar` preset, whose `min_width = 40` survives this partial-layout override,
-- so the effective width is max(30% of columns, 40) — it floors at 40 columns on
-- windows narrower than ~133 cols (add `min_width = N` to the inner layout to lower it).

return {
  {
    "folke/snacks.nvim",
    opts = {
      -- No indent guides and no highlighted current block. Only the
      -- drawing goes: snacks' scope detection stays, so `ii`/`ai` and `[i`/`]i`
      -- still work.
      indent = { enabled = false },
      -- No start screen: `nvim` without a file opens an empty
      -- buffer. Recent files are `<leader>fr`, sessions `<leader>qs`.
      dashboard = { enabled = false },
      picker = {
        ui_select = false, -- keep native vim.ui.select instead of the snacks one
        sources = {
          explorer = {
            layout = { layout = { position = "right", width = 0.30 } },
          },
        },
      },
    },
  },
}
