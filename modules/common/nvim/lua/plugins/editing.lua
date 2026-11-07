-- A quieter editor.
--
-- No auto-closing brackets: LazyVim's mini.pairs is off, and so is blink's
-- auto_brackets, which would otherwise append "()" to an accepted function.
--
-- Completion stays hidden until asked for: <C-Space> opens the menu, <Tab> and
-- <S-Tab> cycle through it (wrapping at the ends), <CR> inserts the selected
-- item. Nothing is preselected, so <CR> on an untouched menu is a plain
-- newline. With the menu closed, <Tab> still jumps through a snippet or indents.
--
-- The command line sits at the bottom again instead of in a popup in the middle
-- of the screen. noice stays for messages and notifications; it cannot hand the
-- command line back to Neovim while it keeps those, so it draws it there itself.
--
-- The status line keeps mode, file name, diagnostic counts and the cursor
-- position. Branch, project root, git diff counts, scroll percentage and clock
-- are gone. The "recording @q" notice stays, because with the command line at
-- the bottom nothing else shows that a macro is recording.
--
-- Diagnostics show in full, wrapped, for the line the cursor is on: the message
-- runs on virtual lines below it, broken at word boundaries to fit the window.
-- Other lines keep only the underline and the sign column marker. A message
-- longer than the room is never cut off, unlike the old end-of-line text.

-- Break a diagnostic message so that it fits beside its column. The
-- virtual_lines handler puts each "\n"-separated piece on its own line, after a
-- six-character connector ("└──── ") that starts at the diagnostic's column.
local function wrap_diagnostic(d)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local width = math.max(30, info.width - info.textoff - (d.col or 0) - 8)
  local out = {}
  for para in (d.message .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
        table.insert(out, line)
        line = word
      else
        line = line == "" and word or line .. " " .. word
      end
    end
    if line ~= "" then
      table.insert(out, line)
    end
  end
  return table.concat(out, "\n")
end

return {
  { "nvim-mini/mini.pairs", enabled = false },
  {
    "saghen/blink.cmp",
    opts = {
      completion = {
        accept = { auto_brackets = { enabled = false } },
        menu = { auto_show = false },
        ghost_text = { enabled = false },
        list = { selection = { preselect = false, auto_insert = true } },
      },
      keymap = {
        preset = "enter",
        ["<Tab>"] = { "select_next", "snippet_forward", "fallback" },
        ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
      },
    },
  },
  {
    "folke/noice.nvim",
    opts = {
      cmdline = { view = "cmdline" },
      presets = { command_palette = false },
    },
  },
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      local s = opts.sections
      -- LazyVim's own diagnostics component, found by name so its icons stay.
      local diagnostics = "diagnostics"
      for _, c in ipairs(s.lualine_c) do
        if c[1] == "diagnostics" then
          diagnostics = c
        end
      end
      s.lualine_b = {}
      s.lualine_c = { diagnostics, { LazyVim.lualine.pretty_path() } }
      s.lualine_x = {
        -- Copied from LazyVim's lualine_x: shows only while a macro records.
        {
          function() return require("noice").api.status.mode.get() end,
          cond = function() return package.loaded["noice"] and require("noice").api.status.mode.has() end,
          color = function() return { fg = Snacks.util.color("Constant") } end,
        },
      }
      s.lualine_y = { { "location", padding = { left = 1, right = 1 } } }
      s.lualine_z = {}
    end,
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      -- No inline hints (parameter names, types) from any language server.
      -- None of today's servers sends them unasked, so this guards against the
      -- next one. <leader>uh still shows them per buffer.
      inlay_hints = { enabled = false },
      diagnostics = {
        virtual_text = false,
        virtual_lines = { current_line = true, format = wrap_diagnostic },
      },
    },
  },
}
