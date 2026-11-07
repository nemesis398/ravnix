-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

-- Indent with real tab characters, shown 8 columns wide. The width is only a
-- display setting: change 'tabstop' and every file re-indents on screen, without
-- touching the file. shiftwidth=0 follows 'tabstop'. An ftplugin that sets its
-- own style still wins: YAML, Python and Markdown keep spaces (2 or 4). An
-- existing space-indented file keeps its spaces, but new lines get tabs.
-- conform runs shfmt with tabs when 'expandtab' is off; prettier and stylua
-- keep their own style.
vim.opt.expandtab = false
vim.opt.tabstop = 8
vim.opt.shiftwidth = 0
vim.opt.softtabstop = 0

-- Markdown indents with 4 spaces. LazyVim turns Vim's Markdown
-- style off, which left Markdown on the 8-column tabs above. 4 is the one width
-- that nests a list under both "-" (needs 2 to 5) and "1." (needs 3 to 6), so
-- ordered and unordered lists combine at any depth. See plugins/markdown.lua.
vim.g.markdown_recommended_style = 1

-- 'list' stays on for trailing spaces and non-breaking spaces, but a tab is
-- drawn as blank space instead of "> ".
vim.opt.listchars = { tab = "  ", trail = "-", nbsp = "+" }

-- A block cursor in every mode, as in vi: no thin bar in insert
-- mode, no underline in replace mode.
vim.opt.guicursor = "a:block"

-- No mouse (LazyVim turns it on for every mode). A click no longer
-- moves the cursor or opens a menu, and a drag selects text in the terminal, as
-- in any other terminal program, so it copies without Neovim's visual mode.
vim.opt.mouse = ""

-- No formatting on save: saving reformatted whole files (shfmt rewrote every
-- line of a shell script), so a one-line change became a whole-file diff.
-- Format on request with <leader>cf; <leader>uf turns it back on for a while.
vim.g.autoformat = false

-- Keep 20 lines between the cursor and the top or bottom edge before the view
-- scrolls (LazyVim's default is 4, and 999 would keep the cursor
-- centered all the time). Neovim caps it at half the window height.
vim.opt.scrolloff = 20

-- 'scrolloff' stops working at the end of the file: Neovim never scrolls past
-- the last line on its own, so the cursor sinks to the bottom edge there. This
-- scrolls on into the empty space after the file, keeping the same distance
-- from the bottom, as <C-e> would by hand. Only in normal file windows, not in
-- floats, the explorer, pickers or terminals.
vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinResized" }, {
  group = vim.api.nvim_create_augroup("scrolloff_past_eof", { clear = true }),
  callback = function()
    if vim.bo.buftype ~= "" or vim.api.nvim_win_get_config(0).relative ~= "" then
      return
    end
    local height = vim.api.nvim_win_get_height(0)
    local so = math.min(vim.wo.scrolloff, math.floor((height - 1) / 2))
    local overshoot = vim.fn.winline() - (height - so)
    if overshoot > 0 and vim.fn.line("w$") == vim.fn.line("$") then
      local view = vim.fn.winsaveview()
      view.topline = view.topline + overshoot
      vim.fn.winrestview(view)
    end
  end,
})

-- Nothing moves, so no smooth scrolling, no animated indent guides and no
-- animated window resizes. One switch covers everything snacks animates.
vim.g.snacks_animate = false

-- Spell-check English. LazyVim turns spell on for markdown, text and commit
-- messages. Another language needs its word list, which is not part of Neovim
-- (it would be downloaded at the first use, and this editor never goes to the
-- network): add it in lua/user/options.lua, with the list itself under
-- ~/.local/share/nvim/site/spell/. Add a word with `zg`, step with `]s`.
vim.opt.spelllang = { "en" }

-- The line-length marker sits one column past 'textwidth': 81
-- everywhere, 73 in a commit message, whose ftplugin sets textwidth=72. A
-- buffer that sets textwidth=0 shows no marker at all. `gq` wraps to the same
-- width.
vim.opt.textwidth = 80
vim.opt.colorcolumn = "+1"

-- 'textwidth' is there for the marker and for `gq`, not to break lines while
-- you type, so the 't' flag goes everywhere but in commit messages (comments
-- keep 'c' and still wrap). The markdown, text and python ftplugins add 't'
-- back, and Obsidian shows a single newline as a line break, so a note typed
-- here would otherwise render as ragged 80-column lines.
-- Registered here, not in autocmds.lua: that file loads on VeryLazy, too late
-- for a file opened before it fires, and an autocmd registered at this point
-- still runs after the ftplugin's (verified headless).
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("textwidth_no_autowrap", { clear = true }),
  callback = function(ev)
    if vim.bo[ev.buf].filetype ~= "gitcommit" then
      vim.opt_local.formatoptions:remove("t")
    end
  end,
})

-- Your own options come last, in lua/user/options.lua (put the file there with
-- home-manager's xdg.configFile."nvim/lua/user/options.lua").
pcall(require, "user.options")
