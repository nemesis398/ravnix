-- Catppuccin Mocha, with the accent of ravnix.theme.accent (docs/style.md).
--
-- catppuccin.nvim has NO global "accent" switch and NO `color_overrides.accent`
-- key: the accent is applied per highlight group via `custom_highlights`. It
-- marks focus and place, so it goes on the line number of the cursor, on
-- directories, on the frame of every float, and on the builtin variables. The
-- colors come from lua/ravnix.lua, which modules/common/nvim.nix generates from
-- the theme module, so this file names none.
--
-- The catppuccin/nix port of Neovim is not used. It installs its own copy of
-- the plugin outside lazy.nvim and sets it up before LazyVim does; this
-- spec is the one setup, with the flavor fixed at mocha as the theme is.
--
-- LazyVim owns colorscheme application via `opts.colorscheme` below, so there
-- is no extra `vim.cmd.colorscheme` at startup besides the one in `config`.

return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "mocha",
      -- Disable the compiled-highlight cache. With a *function* custom_highlights
      -- block, catppuccin's cache-hash can miss it, so the accent overrides below
      -- silently don't apply on a fresh box until a manual `:Catppuccin compile`.
      -- Live-applying highlights costs ~nothing for an interactive editor and
      -- guarantees the accent is always present.
      compile = { enabled = false },
      -- Accent the groups we actually want in the accent. Add/remove to taste;
      -- lualine's Normal-mode segment already uses it via its integration.
      custom_highlights = function()
        local accent = require("ravnix").colors.accent
        return {
          CursorLineNr = { fg = accent, bold = true },
          Directory = { fg = accent },
          -- Every float's frame; the pickers, which-key and completion link
          -- their borders to it.
          FloatBorder = { fg = accent },
          NoiceConfirmBorder = { fg = accent },
          NoiceCmdlinePopupBorder = { fg = accent },
          ["@variable.builtin"] = { fg = accent },
        }
      end,
      integrations = {
        native_lsp = {
          enabled = true,
          virtual_text = { errors = { "italic" }, hints = { "italic" } },
          underlines = {
            errors = { "underline" },
            hints = { "underline" },
            warnings = { "underline" },
          },
        },
        -- snacks is the primary file/picker UI (explorer + picker), but its
        -- catppuccin integration ships disabled by default — enable it so the
        -- picker/explorer/notifier surfaces are Mocha-tuned like everything else.
        snacks = { enabled = true },
      },
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      -- Apply the scheme AFTER setup so the custom_highlights above are live.
      -- (catppuccin otherwise applies the colorscheme before our opts take
      -- effect, so the accent silently wouldn't show on a fresh box.)
      vim.cmd.colorscheme("catppuccin")
    end,
  },
  -- Tell LazyVim the active scheme so it doesn't fall back to its default.
  { "LazyVim/LazyVim", opts = { colorscheme = "catppuccin" } },
}
