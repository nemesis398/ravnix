-- Probes run inside the real editor by tests/common/nvim.nix:
--
--   PROBE=store ... nvim --headless -c 'luafile nvim-probe.lua'
--   PROBE=style PROBE_ACCENT='#rrggbb' PROBE_BASE='#rrggbb' ...
--   PROBE=lsp PROBE_FILE=/path/to/file PROBE_SERVER=name PROBE_BINARY=exe ...
--   PROBE=treesitter PROBE_FILES='/path/a /path/b' ...
--   PROBE=options PROBE_FILE=/path/to/note.md ...
--
-- A probe runs once the editor has started (the loop is running, so
-- lazy.nvim's VeryLazy has fired), prints what it found, and exits 0 when
-- every check holds and 1 at the first that does not.

local probe = vim.env.PROBE

local function fail(message)
  io.stderr:write("PROBE " .. probe .. " FAILED: " .. message .. "\n")
  vim.cmd("cquit 1")
end

local function check(condition, message)
  if not condition then
    error(message, 0)
  end
end

local function color(hex)
  return tonumber(hex:sub(2), 16)
end

local function fg(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
end

local probes = {}

-- The plugins and tools come from the store, and nothing was fetched.
function probes.store()
  local plugins = require("lazy.core.config").plugins
  local count = 0
  for name, plugin in pairs(plugins) do
    count = count + 1
    check(plugin.dir:find("^/nix/store/") ~= nil, name .. " is at " .. plugin.dir)
    check(vim.uv.fs_stat(plugin.dir) ~= nil, name .. " is missing from " .. plugin.dir)
  end
  check(count > 30, "only " .. count .. " plugins: LazyVim did not load")
  for _, name in ipairs({ "LazyVim", "snacks.nvim", "blink.cmp", "nvim-lspconfig", "catppuccin" }) do
    check(plugins[name] ~= nil, name .. " is not among the plugins")
  end

  check(plugins["mason.nvim"] == nil, "mason.nvim is enabled")
  check(plugins["mason-lspconfig.nvim"] == nil, "mason-lspconfig.nvim is enabled")
  check(vim.fn.exists(":Mason") == 0, ":Mason exists")

  local data = vim.fn.stdpath("data")
  -- lazy.nvim makes its (empty) root directory.
  check(#vim.fn.glob(data .. "/lazy/*", false, true) == 0, "lazy.nvim installed plugins into " .. data .. "/lazy")
  check(vim.uv.fs_stat(data .. "/mason") == nil, "something installed into " .. data .. "/mason")
  local install = require("lazy.core.config").options.install
  check(install.missing == false, "lazy.nvim would install missing plugins")
  check(require("lazy.core.config").options.checker.enabled == false, "lazy.nvim checks for updates")

  -- The formatters and linters LazyVim calls are Nix ones too.
  for _, tool in ipairs({ "git", "rg", "fd", "stylua", "shfmt", "shellcheck", "odinfmt" }) do
    local path = vim.fn.exepath(tool)
    check(path:find("^/nix/store/") ~= nil or path:find("^/run/current-system/") ~= nil, tool .. " is " .. (path == "" and "missing" or path))
  end
end

-- Every parser LazyVim asks for is there, so nothing is downloaded, and a
-- file's syntax is highlighted by treesitter from the Nix-built parsers.
function probes.treesitter()
  -- Loads on the first file; make it certain.
  require("lazy").load({ plugins = { "nvim-treesitter" } })
  local installed = LazyVim.treesitter.get_installed()
  check(next(installed) ~= nil, "nvim-treesitter found no parser")
  local missing = {}
  for _, language in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed or {}) do
    if not installed[language] then
      table.insert(missing, language)
    end
  end
  check(#missing == 0, "no parser for " .. table.concat(missing, ", "))
  for _, file in ipairs(vim.split(vim.env.PROBE_FILES, " ")) do
    vim.cmd.edit(vim.fn.fnameescape(file))
    check(vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil, file .. " is not highlighted by treesitter")
  end
end

-- The options of the config: the editing style, and the Markdown links.
function probes.options()
  check(vim.o.mouse == "", "the mouse is on")
  check(vim.o.tabstop == 8 and not vim.o.expandtab, "indentation is not tabs of 8")
  check(vim.o.scrolloff == 20, "scrolloff is " .. vim.o.scrolloff)
  check(vim.g.autoformat == false, "autoformat is on")
  check(vim.o.textwidth == 80, "textwidth is " .. vim.o.textwidth)
  vim.cmd.edit(vim.fn.fnameescape(vim.env.PROBE_FILE))
  check(vim.fn.maparg("gf", "n", false, true).buffer == 1, "gf does not follow Markdown links")
  check(vim.o.spelllang == "en", "spelllang is " .. vim.o.spelllang)
end

-- The credentials and the dictionary of the LanguageTool checks: what is read
-- from where, and the lines that cannot be read as a word. rbw is a stand-in
-- script on the PATH of the test (an entry "LanguageTool", user and password).
function probes.languagetool()
  local lt = require("ravnix_languagetool")
  local dictionary = lt.dictionary

  -- No dictionary yet, not even its directory.
  check(vim.fn.filereadable(dictionary) == 0, "the dictionary exists before the test")
  check(#lt.words("de-DE") == 0, "a missing dictionary has words")
  local added = lt.add({ ["de-DE"] = { "Wort", "Wort", "Zwei|Teile", "", "  ", "Zeile\nzwei" } })
  check(vim.deep_equal(added, { "Wort" }), "added " .. vim.inspect(added))
  check(vim.deep_equal(vim.fn.readfile(dictionary), { "Wort | lang=de" }), "wrote " .. vim.inspect(vim.fn.readfile(dictionary)))
  check(#lt.add({ ["de-DE"] = { "Wort" } }) == 0, "a known word was added again")
  check(#lt.add({ ["en-US"] = { "Wort" } }) == 1, "a word known in German was not added for English")

  -- A hand-written file: comments, blanks, fields, a line that is nothing but
  -- fields, a Windows line break, a word known in two languages.
  vim.fn.writefile({ "# comment", "", "Alpha", "Beta | lang=de", "Gamma | lang=de,en | heard=x", "| lang=de", "  Delta  | lang=EN  ", "Eps\r", "Alpha" }, dictionary)
  check(vim.deep_equal(lt.words("de-DE"), { "Alpha", "Beta", "Gamma", "Eps" }), "German: " .. vim.inspect(lt.words("de-DE")))
  check(vim.deep_equal(lt.words("en-US"), { "Alpha", "Gamma", "Delta", "Eps" }), "English: " .. vim.inspect(lt.words("en-US")))

  -- Credentials: the environment first, then the file, then rbw; an entry
  -- named by LANGUAGETOOL_RBW_ITEM; a locked vault gives nothing.
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. "/.config/languagetool", "p")
  vim.env.HOME = home
  local names = { "LANGUAGETOOL_API_KEY", "LANGUAGETOOL_USERNAME", "LANGUAGETOOL_SERVER", "LANGUAGETOOL_RBW_ITEM", "FAKE_RBW_LOCKED" }
  local function reset()
    for _, name in ipairs(names) do
      vim.env[name] = nil
    end
  end
  local function credentials(label, expected)
    local c = lt.credentials()
    check(vim.deep_equal(c, expected), label .. ": " .. vim.inspect(c))
  end
  reset()
  credentials("rbw", { key = "password of LanguageTool", user = "username of LanguageTool", server = lt.default_server })
  vim.env.LANGUAGETOOL_RBW_ITEM = "Other"
  credentials("named entry", { key = "password of Other", user = "username of Other", server = lt.default_server })
  vim.env.FAKE_RBW_LOCKED = "1"
  credentials("locked", { server = lt.default_server })
  reset()
  vim.fn.writefile({ "# a comment", "LANGUAGETOOL_API_KEY=\"fromfile\"", "  LANGUAGETOOL_USERNAME = 'filer' ", "LANGUAGETOOL_SERVER=https://lt.example/", "junk" }, home .. "/.config/languagetool/credentials")
  credentials("file", { key = "fromfile", user = "filer", server = "https://lt.example/" })
  vim.env.LANGUAGETOOL_API_KEY = "fromenv"
  credentials("environment over file", { key = "fromenv", user = "filer", server = "https://lt.example/" })
  vim.env.LANGUAGETOOL_SERVER = ""
  credentials("empty server", { key = "fromenv", user = "filer", server = "https://lt.example/" })
  vim.fn.delete(home, "rf")
  reset()
end

-- Mocha in the accent, and a single line around everything that floats.
function probes.style()
  local lazy = require("lazy.core.config")
  check(lazy.options.ui.border == "single", "lazy.nvim ui.border is " .. tostring(lazy.options.ui.border))
  check(vim.o.winborder == "single", "winborder is " .. vim.o.winborder)
  check(vim.g.colors_name == "catppuccin-mocha", "colorscheme is " .. tostring(vim.g.colors_name))

  local base = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  check(base == color(vim.env.PROBE_BASE), ("Normal background is %x, not Base"):format(base or 0))
  local accent = color(vim.env.PROBE_ACCENT)
  for _, group in ipairs({ "CursorLineNr", "Directory", "FloatBorder" }) do
    check(fg(group) == accent, ("%s is %x, not the accent"):format(group, fg(group) or 0))
  end

  -- One Neovim float, opened without a border of its own, gets the line.
  local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 10,
    height = 2,
  })
  local border = vim.api.nvim_win_get_config(win).border
  check(type(border) == "table" and border[1] == "┌", "a plain float has no single-line border")
  vim.api.nvim_win_close(win, true)

  -- No plugin is told to round its corners, and the two whose preset or
  -- views name a border of their own are set to the single line.
  local rounded = {}
  local function walk(value, path)
    if type(value) == "table" then
      for key, inner in pairs(value) do
        walk(inner, path .. "." .. tostring(key))
      end
    elseif value == "rounded" then
      table.insert(rounded, path)
    end
  end
  for name, plugin in pairs(lazy.plugins) do
    walk(require("lazy.core.plugin").values(plugin, "opts", false), name)
  end
  check(#rounded == 0, "rounded: " .. table.concat(rounded, ", "))
  check(LazyVim.opts("which-key.nvim").win.border == "single", "which-key has its preset's border")
  for _, view in ipairs({ "popup", "cmdline_popup", "cmdline_input", "confirm", "hover", "signature" }) do
    check(LazyVim.opts("noice.nvim").views[view].border.style == "single", "noice " .. view .. " has its own border")
  end

  check(vim.g.snacks_animate == false, "snacks animates")
  check(vim.o.guicursor == "a:block", "the cursor is not a block in every mode")
end

-- Opening the file starts the language server, from the store, within 10 s.
function probes.lsp()
  local started = vim.uv.hrtime()
  vim.cmd.edit(vim.fn.fnameescape(vim.env.PROBE_FILE))
  local bufnr = vim.api.nvim_get_current_buf()
  local client
  local ok = vim.wait(10000, function()
    client = vim.lsp.get_clients({ bufnr = bufnr, name = vim.env.PROBE_SERVER })[1]
    return client ~= nil and client.initialized == true and client.server_capabilities ~= nil
  end, 50)
  check(ok, vim.env.PROBE_SERVER .. " did not start within 10 s for " .. vim.env.PROBE_FILE)
  -- Some servers start through a function, so the binary is named by the test.
  local cmd = vim.fn.exepath(vim.env.PROBE_BINARY)
  check(cmd:find("^/nix/store/") ~= nil, vim.env.PROBE_SERVER .. " runs " .. cmd .. ", not a store binary")
  local seconds = (vim.uv.hrtime() - started) / 1e9
  check(seconds < 10, ("%s took %.1f s"):format(client.name, seconds))
  io.stdout:write(("PROBE lsp %s started in %.2f s: %s\n"):format(client.name, seconds, cmd))
end

vim.defer_fn(function()
  local ok, err = xpcall(probes[probe], debug.traceback)
  if not ok then
    fail(tostring(err))
    return
  end
  io.stdout:write("PROBE " .. probe .. " OK\n")
  vim.cmd("qa!")
end, 0)
