-- gf follows the link under the cursor in Markdown.
--
--   web link ([x](https://…), <https://…>, a bare URL, mailto:)  -> browser
--   linked text file, Markdown included                          -> Neovim
--   linked binary file (PDF, image, office document)             -> default app
--
-- Links are found on the cursor's line: [[wikilink]], [text](target),
-- ![image](target), <autolink> and bare URLs. A wikilink resolves as in
-- Obsidian: a bare name is looked up anywhere under the vault root (the
-- nearest directory with .obsidian, .git or .marksman.toml), and a name
-- without an extension means a note. A path link is relative to the file, then
-- to the vault root. "#Heading" jumps to the heading; it matches both
-- [[Note#Heading]] and the slug form [x](note.md#heading). <C-o> goes back.
--
-- Off a link, gf does what it always does. gx still opens web links on its own
-- (Neovim 0.12 finds the URL of a Markdown link even on its label).
--
-- Neither Neovim nor marksman covers this: Neovim's gf breaks on %20 and on
-- wikilinks, and gx hands a relative note path to xdg-open, which opens a
-- second Neovim window. marksman's gd only knows Markdown files; it works too,
-- see marksman.toml next to this config.

local function slug(s)
  s = vim.fn.tolower(vim.trim(s))
  return (s:gsub("[%p]", function(c) return (c == "-" or c == "_") and c or "" end):gsub("%s+", "-"))
end

-- The link the cursor is on: its target and whether it is a wikilink.
local function link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local c = vim.api.nvim_win_get_cursor(0)[2] + 1
  local patterns = {
    { "()!?%[%[(.-)%]%]()", true },
    { "()!?%[[^%]]*%]%((.-)%)()", false },
    { "()<(%a[%w+.-]*:[^>%s]+)>()", false },
    { "()(%a[%w+.-]*://[^%s<>()]+)()", false },
  }
  for _, p in ipairs(patterns) do
    for s, target, e in line:gmatch(p[1]) do
      if c >= s and c < e then
        -- A bare URL ends a sentence without taking its full stop along.
        return p == patterns[4] and (target:gsub("[.,;:!?]+$", "")) or target, p[2]
      end
    end
  end
end

-- Obsidian finds a bare name anywhere in the vault. Dot directories (.git,
-- .obsidian, .trash) are skipped.
local function find_by_name(root, name)
  for path, kind in vim.fs.dir(root, {
    depth = math.huge,
    skip = function(dir) return not vim.startswith(vim.fs.basename(dir), ".") end,
  }) do
    if kind == "file" and vim.fs.basename(path) == name then
      return vim.fs.joinpath(root, path)
    end
  end
end

local function resolve(path, wiki)
  local bufname = vim.api.nvim_buf_get_name(0)
  local dir = vim.fs.dirname(bufname)
  local root = vim.fs.root(0, { ".obsidian", ".git", ".marksman.toml" }) or dir
  local names = { path }
  if wiki then
    table.insert(names, 1, path .. ".md")
  elseif not path:match("%.%w+$") then
    table.insert(names, path .. ".md")
  end
  for _, name in ipairs(names) do
    local tries = vim.startswith(name, "/") and { name, root .. name }
      or { vim.fs.joinpath(dir, name), vim.fs.joinpath(root, name) }
    for _, f in ipairs(tries) do
      if vim.fn.filereadable(f) == 1 then
        return vim.fs.normalize(f)
      end
    end
    if not name:find("/") then
      local f = find_by_name(root, name)
      if f then
        return f
      end
    end
  end
end

-- Text opens in Neovim, anything with a NUL byte in its first 8 KiB in the
-- default app, as git tells text from binary.
local function is_text(file)
  local fd = io.open(file, "rb")
  if not fd then
    return false
  end
  local head = fd:read(8192) or ""
  fd:close()
  return not head:find("\0", 1, true)
end

local function jump_to_heading(anchor)
  local want = slug(anchor)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local h = l:match("^#+%s+(.-)%s*#*%s*$")
    if h and slug(h) == want then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  vim.notify("No heading #" .. anchor, vim.log.levels.WARN)
end

local function follow()
  local target, wiki = link_under_cursor()
  if not target then
    local ok, err = pcall(vim.cmd.normal, { "gf", bang = true })
    if not ok then
      vim.notify((err:gsub("^.-:E", "E")), vim.log.levels.ERROR)
    end
    return
  end

  local path, anchor
  if wiki then
    path, anchor = target:gsub("|.*", ""):match("^([^#]*)#?(.*)$")
  else
    -- Drop a link title ("…") and the <…> around a destination with spaces.
    target = target:gsub('%s+".*"$', ""):gsub("^<(.*)>$", "%1")
    if target:match("^%a[%w+.-]*:") then
      vim.ui.open(target)
      return
    end
    path, anchor = target:match("^([^#]*)#?(.*)$")
    path = vim.uri_decode(path)
  end

  local file = path == "" and vim.api.nvim_buf_get_name(0) or resolve(path, wiki)
  if not file then
    vim.notify("No file for " .. path, vim.log.levels.WARN)
    return
  end
  if not is_text(file) then
    vim.ui.open(file)
    return
  end
  if file ~= vim.api.nvim_buf_get_name(0) then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  if anchor ~= "" then
    jump_to_heading(anchor)
  end
end

vim.keymap.set("n", "gf", follow, { buffer = true, desc = "Follow link" })
vim.b.undo_ftplugin = (vim.b.undo_ftplugin and vim.b.undo_ftplugin .. " | " or "")
  .. "silent! nunmap <buffer> gf"
