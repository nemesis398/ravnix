-- Probes run inside the real editor by tests/common/nvim.nix:
--
--   PROBE=clean ... nvim --headless -c 'luafile nvim-probe.lua'
--   PROBE=store ...
--   PROBE=style PROBE_ACCENT='#rrggbb' PROBE_BASE='#rrggbb' ...
--   PROBE=opaque ...
--   PROBE=lsp PROBE_FILE=/path/to/file PROBE_SERVER=name PROBE_BINARY=exe ...
--   PROBE=treesitter PROBE_FILES='/path/a /path/b' ...
--   PROBE=options PROBE_FILE=/path/to/note.md ...
--   PROBE=languagetool ...          (rbw is a stand-in script on the PATH)
--   PROBE=toggle PROBE_FILE=... PROBE_SECRET=... PROBE_USER=... PROBE_SERVER_LOG=...
--   PROBE=toggle_missing PROBE_FILE=...
--   PROBE=scoped PROBE_FILES=... PROBE_ABSENT=... PROBE_SERVERS_OFF=...
--                PROBE_FORMATTER_FT_OFF=... PROBE_FILE_KEPT=... PROBE_SERVER_KEPT=...
--
-- A probe runs once the editor has started and every plugin that waits for
-- VeryLazy has been set up. It prints what it found and exits 0 when every
-- check holds and 1 at the first that does not. Any probe also fails when
-- the editor reported an error or a warning, before it or after it: through
-- `:messages`, or a notification that noice or snacks kept. (Not v:errmsg:
-- `silent!` sets it too, and the runtime's own undo_ftplugin lists, run when
-- lazy.nvim fires FileType again for a Markdown buffer, unmap one key twice
-- with `silent!`; that leaves E31 in v:errmsg and is nothing to report.) Set
-- PROBE_EXPECT_FAILURE to run a probe that must fail, so that its output does
-- not read as a failure of the test.

local probe = vim.env.PROBE

local function fail(message)
  local outcome = vim.env.PROBE_EXPECT_FAILURE and "failed, as expected" or "FAILED"
  io.stderr:write(("PROBE %s %s: %s\n"):format(probe, outcome, message))
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

-- lazy.nvim fires VeryLazy from UIEnter when it is done during startup, and
-- --headless attaches no UI, so UIEnter never comes. Fire it, and wait for
-- the plugins that load on VeryLazy: noice, which-key, lualine, bufferline,
-- flash, and the rest of what LazyVim sets up late. (Under a real terminal,
-- run in a pty, the UI is there and this does nothing.)
local function settle()
  if #vim.api.nvim_list_uis() == 0 then
    vim.api.nvim_exec_autocmds("UIEnter", {})
  end
  check(vim.wait(10000, function()
    return vim.g.did_very_lazy == true
  end, 50), "VeryLazy did not fire")
  vim.wait(300)
end

-- What the editor said that it should not have, as a list of lines. A clean
-- start says nothing at all; once a probe has done things (written a file, for
-- one), it is the errors, warnings and failures among the messages.
local allowed = {}
-- PROBE_ALLOW lists text to ignore, separated by "|": a pty with no terminal
-- behind it cannot answer Neovim's queries, and Neovim says so.
for _, text in ipairs(vim.split(vim.env.PROBE_ALLOW or "", "|", { plain = true, trimempty = true })) do
  table.insert(allowed, text)
end
local function allow(text)
  table.insert(allowed, text)
end

local function reported(everything)
  local found = {}
  local function add(source, text)
    text = vim.trim(text or "")
    if text == "" then
      return
    end
    for _, ok in ipairs(allowed) do
      if text:find(ok, 1, true) then
        return
      end
    end
    table.insert(found, ("%s: %s"):format(source, text:sub(1, 600)))
  end
  for line in vim.api.nvim_exec2("messages", { output = true }).output:gmatch("[^\n]+") do
    local lower = line:lower()
    if everything or lower:find("e%d+:") or lower:find("error") or lower:find("warn") or lower:find("fail") or lower:find("not installed") or lower:find("not found") then
      add(":messages", line)
    end
  end
  -- Once noice or snacks have taken the messages over, errors go to their
  -- histories and not to :messages.
  local manager = package.loaded["noice.message.manager"]
  if manager then
    for _, message in pairs(manager.get({}, { history = true })) do
      local kinds = { emsg = true, echoerr = true, lua_error = true, rpc_error = true, wmsg = true }
      if message.level == "warn" or message.level == "error" or kinds[message.kind] then
        add("noice", message:content())
      end
    end
  end
  if _G.Snacks and Snacks.notifier then
    for _, notification in ipairs(Snacks.notifier.get_history()) do
      if notification.level == "warn" or notification.level == "error" then
        add("snacks", notification.msg)
      end
    end
  end
  return found
end

-- Every text the editor keeps about what it said, for a search.
local function everything_said()
  local texts = { vim.api.nvim_exec2("messages", { output = true }).output }
  local manager = package.loaded["noice.message.manager"]
  if manager then
    for _, message in pairs(manager.get({}, { history = true })) do
      table.insert(texts, message:content())
    end
  end
  if _G.Snacks and Snacks.notifier then
    for _, notification in ipairs(Snacks.notifier.get_history()) do
      table.insert(texts, notification.msg)
    end
  end
  return table.concat(texts, "\n")
end

local function wait_for(condition, message, ms)
  check(vim.wait(ms or 10000, condition, 50), message)
end

local probes = {}

-- Nothing more than the start itself: the editor comes up, sets up everything
-- that waits for VeryLazy, and says nothing.
function probes.clean() end

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
  local options = require("lazy.core.config").options
  check(options.install.missing == false, "lazy.nvim would install missing plugins")
  check(options.checker.enabled == false, "lazy.nvim checks for updates")

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

-- All of one editor's descendants, by the process table.
local function descendants()
  local parent = {}
  for name in vim.fs.dir("/proc") do
    if name:match("^%d+$") then
      local file = io.open("/proc/" .. name .. "/stat")
      if file then
        local stat = file:read("a")
        file:close()
        local ppid = stat:match("^%d+ %b() %S+ (%d+)")
        parent[tonumber(name)] = ppid and tonumber(ppid)
      end
    end
  end
  local found, queue = {}, { vim.fn.getpid() }
  while #queue > 0 do
    local pid = table.remove(queue)
    for child, ppid in pairs(parent) do
      if ppid == pid and not found[child] then
        found[child] = true
        table.insert(queue, child)
      end
    end
  end
  return vim.tbl_keys(found)
end

-- The credentials and the dictionary of the LanguageTool checks: what is read
-- from where, and the input that cannot be read as a word, a vault that does
-- not answer, a dictionary that cannot be written. rbw is a stand-in script on
-- the PATH of the test (an entry "LanguageTool", user and password).
function probes.languagetool()
  local function fresh()
    package.loaded["ravnix_languagetool"] = nil
    return require("ravnix_languagetool")
  end
  local lt = fresh()
  local dictionary = lt.dictionary

  local function content()
    local file = io.open(dictionary, "rb")
    local text = file and file:read("a")
    if file then
      file:close()
    end
    return text
  end

  local function write_raw(text)
    local file = assert(io.open(dictionary, "wb"))
    file:write(text)
    file:close()
  end

  -- No dictionary yet, not even its directory.
  check(vim.fn.filereadable(dictionary) == 0, "the dictionary exists before the test")
  check(#lt.words("de-DE") == 0, "a missing dictionary has words")
  local added = lt.add({ ["de-DE"] = { "Wort", "Wort", "Zwei|Teile", "", "  ", "Zeile\nzwei" } })
  check(vim.deep_equal(added, { "Wort" }), "added " .. vim.inspect(added))
  check(content() == "Wort | lang=de\n", "wrote " .. vim.inspect(content()))
  check(#lt.add({ ["de-DE"] = { "Wort" } }) == 0, "a known word was added again")
  check(#lt.add({ ["en-US"] = { "Wort" } }) == 1, "a word known in German was not added for English")

  -- The dictionary is shared: what is in it stays, whatever its last line
  -- looks like.
  local endings = {
    { "a last line without a line break", "Alpha", "Alpha\nNeu | lang=de\n" },
    { "a last comment without a line break", "# end", "# end\nNeu | lang=de\n" },
    { "a last line closed by a carriage return only", "Alpha\r", "Alpha\r\nNeu | lang=de\n" },
    { "a last line with a line break", "Alpha\n", "Alpha\nNeu | lang=de\n" },
    { "an empty file", "", "Neu | lang=de\n" },
    { "a file of one line break", "\n", "\nNeu | lang=de\n" },
  }
  for _, case in ipairs(endings) do
    write_raw(case[2])
    check(vim.deep_equal(lt.add({ ["de-DE"] = { "Neu" } }), { "Neu" }), case[1] .. ": nothing was added")
    check(content() == case[3], case[1] .. ": wrote " .. vim.inspect(content()))
  end

  -- A hand-written file: comments, blanks, fields, a line that is nothing but
  -- fields, a Windows line break, a word known in two languages.
  vim.fn.writefile({ "# comment", "", "Alpha", "Beta | lang=de", "Gamma | lang=de,en | heard=x", "| lang=de", "  Delta  | lang=EN  ", "Eps\r", "Alpha" }, dictionary)
  check(vim.deep_equal(lt.words("de-DE"), { "Alpha", "Beta", "Gamma", "Eps" }), "German: " .. vim.inspect(lt.words("de-DE")))
  check(vim.deep_equal(lt.words("en-US"), { "Alpha", "Gamma", "Delta", "Eps" }), "English: " .. vim.inspect(lt.words("en-US")))

  -- A dictionary that cannot be written is told, and nothing else is.
  lt.dictionary = "/proc/no/such/directory/dictionary.txt"
  local none, failure = lt.add({ ["de-DE"] = { "Wort" } })
  check(#none == 0 and failure ~= nil and failure:find("cannot write", 1, true), "an unwritable dictionary: " .. vim.inspect({ none, failure }))
  lt.dictionary = dictionary

  -- Credentials: the environment first, then rbw, then the file; an entry
  -- named by LANGUAGETOOL_RBW_ITEM; a locked vault, or one that does not
  -- answer, gives nothing and does not hold the editor up.
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. "/.config/languagetool", "p")
  vim.env.HOME = home
  local names = { "LANGUAGETOOL_API_KEY", "LANGUAGETOOL_USERNAME", "LANGUAGETOOL_SERVER", "LANGUAGETOOL_RBW_ITEM", "FAKE_RBW_LOCKED", "FAKE_RBW_HANG" }
  local function reset()
    for _, name in ipairs(names) do
      vim.env[name] = nil
    end
    lt = fresh()
    lt.rbw_timeout_ms = 400
  end
  local function credentials(label, expected)
    local c = lt.credentials()
    check(vim.deep_equal(c, expected), label .. ": " .. vim.inspect(c))
  end
  local vault = { key = "password of LanguageTool", user = "username of LanguageTool", server = lt.default_server }

  reset()
  credentials("rbw", vault)
  vim.env.LANGUAGETOOL_RBW_ITEM = "Other"
  credentials("named entry", { key = "password of Other", user = "username of Other", server = lt.default_server })

  reset()
  vim.env.FAKE_RBW_LOCKED = "1"
  credentials("locked", { server = lt.default_server })

  for _, hang in ipairs({ "unlocked", "get" }) do
    reset()
    vim.env.FAKE_RBW_HANG = hang
    local started = vim.uv.hrtime()
    local c = lt.credentials()
    local seconds = (vim.uv.hrtime() - started) / 1e9
    check(seconds < 3, ("rbw that hangs in `%s` held the editor up for %.1f s"):format(hang, seconds))
    check(c.key == nil, "a hanging rbw gave a key: " .. vim.inspect(c))
    -- The process that did not answer is gone.
    vim.wait(300)
    for _, pid in ipairs(descendants()) do
      local comm = io.open("/proc/" .. pid .. "/comm")
      local name = comm and comm:read("l")
      if comm then
        comm:close()
      end
      check(name ~= "sleep", "an rbw that did not answer is still running (" .. pid .. ")")
    end
  end

  reset()
  vim.env.FAKE_RBW_LOCKED = "1"
  vim.fn.writefile({ "# a comment", "LANGUAGETOOL_API_KEY=\"fromfile\"", "  LANGUAGETOOL_USERNAME = 'filer' ", "LANGUAGETOOL_SERVER=https://lt.example/", "junk" }, home .. "/.config/languagetool/credentials")
  credentials("file", { key = "fromfile", user = "filer", server = "https://lt.example/" })
  vim.env.FAKE_RBW_LOCKED = nil
  credentials("rbw over file", { key = vault.key, user = vault.user, server = "https://lt.example/" })

  reset()
  vim.env.LANGUAGETOOL_API_KEY = "fromenv"
  credentials("environment over rbw and file", { key = "fromenv", user = vault.user, server = "https://lt.example/" })
  check(vim.env.LANGUAGETOOL_API_KEY == nil, "the key is still in the editor's environment")
  credentials("remembered after it left the environment", { key = "fromenv", user = vault.user, server = "https://lt.example/" })
  vim.env.LANGUAGETOOL_SERVER = ""
  credentials("empty server", { key = "fromenv", user = vault.user, server = "https://lt.example/" })

  vim.fn.delete(home, "rf")
  reset()
end

-- The LanguageTool toggle, with ltex-ls-plus itself and a stand-in for the
-- LanguageTool server: it starts, the server gets the credentials, the key is
-- nowhere else (not in the client's settings, not in a command line or the
-- environment of a process the editor started, not in what the editor said,
-- not in a file), the other key switches the language, and the same key
-- stops it and gives the spell checker back.
function probes.toggle()
  local secret, user = vim.env.PROBE_SECRET, vim.env.PROBE_USER
  -- The probe knows the key to look for it; the processes it starts must not
  -- inherit it from here.
  vim.env.PROBE_SECRET = nil
  vim.cmd.edit(vim.fn.fnameescape(vim.env.PROBE_FILE))
  vim.wo.spell = true
  local buffer = vim.api.nvim_get_current_buf()

  local function clients()
    return vim.tbl_filter(function(client)
      return client.name:match("^ltex_") ~= nil
    end, vim.lsp.get_clients({ bufnr = buffer }))
  end
  local function press(keys)
    vim.api.nvim_feedkeys(keys, "mx", false)
  end
  local function server_log()
    local file = io.open(vim.env.PROBE_SERVER_LOG)
    local text = file and file:read("a") or ""
    if file then
      file:close()
    end
    return text
  end
  local function only(name)
    wait_for(function()
      local running = clients()
      return #running == 1 and running[1].name == name
    end, "ltex did not run as " .. name .. " alone: " .. vim.inspect(vim.tbl_map(function(c)
      return c.name
    end, clients())), 30000)
  end

  press(" ce")
  only("ltex_en")
  check(vim.wo.spell == false, "Vim's spell check is on beside the check")
  wait_for(function()
    return server_log():find("apiKey=" .. secret, 1, true) ~= nil
  end, "the server never got the API key:\n" .. server_log(), 60000)
  check(server_log():find("username=" .. user, 1, true), "the server got no user name:\n" .. server_log())

  -- The key is in none of these.
  for _, client in ipairs(clients()) do
    local held = vim.inspect(client.settings) .. vim.inspect(client.config)
    check(not held:find(secret, 1, true), client.name .. " holds the key in its settings or its config")
  end
  check(vim.env.LANGUAGETOOL_API_KEY == nil, "the key is in the editor's environment")
  local children = descendants()
  check(#children > 0, "ltex-ls-plus is not one of the editor's children")
  for _, pid in ipairs(children) do
    for _, what in ipairs({ "cmdline", "environ" }) do
      local file = io.open("/proc/" .. pid .. "/" .. what, "rb")
      local text = file and file:read("a") or ""
      if file then
        file:close()
      end
      if text:find(secret, 1, true) then
        local comm = io.open("/proc/" .. pid .. "/comm")
        local name = comm and comm:read("l") or "?"
        if comm then
          comm:close()
        end
        -- Which entry, by name: the variable, or the argument.
        local names = {}
        for entry in text:gmatch("[^%z]+") do
          if entry:find(secret, 1, true) then
            table.insert(names, (entry:gsub(secret, "<key>")):sub(1, 80))
          end
        end
        error(("the key is in the %s of process %d (%s): %s"):format(what, pid, name, table.concat(names, "; ")), 0)
      end
    end
  end
  check(not everything_said():find(secret, 1, true), "the key is in what the editor said")

  -- The other key switches the language: one check at a time.
  press(" cg")
  only("ltex_de")
  check(vim.wo.spell == false, "Vim's spell check came back while a check runs")

  -- The same key stops it.
  press(" cg")
  wait_for(function()
    return #clients() == 0
  end, "the check did not stop", 30000)
  check(vim.wo.spell == true, "Vim's spell check did not come back")
  check(not everything_said():find(secret, 1, true), "the key is in what the editor said")
end

-- Without credentials, the toggle says so, starts nothing and leaves the spell
-- check alone.
function probes.toggle_missing()
  vim.cmd.edit(vim.fn.fnameescape(vim.env.PROBE_FILE))
  vim.wo.spell = true
  allow("No API key or username")
  vim.api.nvim_feedkeys(" ce", "mx", false)
  vim.wait(500)
  check(#vim.lsp.get_clients({ name = "ltex_en" }) == 0, "a check started with no credentials")
  check(vim.wo.spell == true, "the spell check was turned off")
  check(everything_said():find("No API key or username", 1, true), "the toggle did not say that it has no credentials")
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

  -- So does a snacks float.
  local float = Snacks.win({ text = "x", style = "float" })
  border = vim.api.nvim_win_get_config(float.win).border
  check(type(border) == "table" and border[1] == "┌", "a snacks float has no single-line border")
  float:close()

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

-- Nothing is see-through and nothing dims what is behind it: the effective
-- values of the editor and of the plugins that set up a window, in the
-- running editor, and the windows that a message, a notification and a float
-- really open.
function probes.opaque()
  check(vim.o.pumblend == 0, "pumblend is " .. vim.o.pumblend)
  check(vim.o.winblend == 0, "winblend is " .. vim.o.winblend)
  check(require("lazy.core.config").options.ui.backdrop == 100, "lazy.nvim dims its backdrop")

  -- Every blend and backdrop in the live configuration of the plugins that
  -- open windows. A backdrop is off when it is false or fully transparent.
  local dim = {}
  local function walk(value, path)
    if type(value) ~= "table" then
      return
    end
    for key, inner in pairs(value) do
      local where = path .. "." .. tostring(key)
      if (key == "winblend" or key == "pumblend") and type(inner) == "number" and inner > 0 then
        table.insert(dim, where .. " = " .. inner)
      elseif key == "backdrop" and inner ~= false and inner ~= 100 and inner ~= nil and type(inner) ~= "table" then
        table.insert(dim, where .. " = " .. tostring(inner))
      elseif key == "backdrop" and type(inner) == "table" then
        table.insert(dim, where .. " is a dimmed backdrop")
      else
        walk(inner, where)
      end
    end
  end
  walk(Snacks.config.styles, "snacks.styles")
  walk(Snacks.config.zen, "snacks.zen")
  walk(require("noice.config").options.views, "noice.views")
  walk(require("which-key.config").win, "which-key.win")
  check(#dim == 0, "see-through or dimming: " .. table.concat(dim, ", "))

  -- Windows that really open: a message on write (noice's mini view), a
  -- notification, a float. Each is opaque, and none has a backdrop behind it.
  local file = vim.fn.tempname() .. ".txt"
  vim.cmd.edit(file)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello" })
  vim.cmd("write")
  Snacks.notify("a notification")
  Snacks.notify.error("an error")
  allow("an error")
  local float = Snacks.win({ text = "x", style = "float" })
  vim.wait(600)
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      count = count + 1
      local buffer = vim.api.nvim_win_get_buf(win)
      local name = vim.bo[buffer].filetype
      check(vim.wo[win].winblend == 0, ("a float (%s) has winblend %d"):format(name, vim.wo[win].winblend))
      check(not name:find("backdrop", 1, true), "a float (" .. name .. ") dims what is behind it")
    end
  end
  check(count >= 3, "only " .. count .. " floats opened: the message, the notifications and the float")
  float:close()
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
  -- The binary the client runs. Some servers start through a function, so
  -- the test names that binary, and a command given as a list must agree.
  local cmd = client.config.cmd
  check(type(cmd) ~= "table" or cmd[1] == vim.env.PROBE_BINARY, vim.env.PROBE_SERVER .. " runs " .. vim.inspect(cmd) .. ", not " .. vim.env.PROBE_BINARY)
  local path = vim.fn.exepath(vim.env.PROBE_BINARY)
  check(path:find("^/nix/store/") ~= nil, vim.env.PROBE_SERVER .. " runs " .. path .. ", not a store binary")
  local seconds = (vim.uv.hrtime() - started) / 1e9
  check(seconds < 10, ("%s took %.1f s"):format(client.name, seconds))
  io.stdout:write(("PROBE lsp %s started in %.2f s: %s\n"):format(client.name, seconds, path))
end

-- An editor whose host left languages out: their tools are not there, and the
-- editor does not try to start them. A file of such a language opens without
-- a server, a formatter or a linter and without a word from the editor.
function probes.scoped()
  for _, file in ipairs(vim.split(vim.env.PROBE_FILES, " ")) do
    vim.cmd.edit(vim.fn.fnameescape(file))
    vim.wait(2000)
    check(#vim.lsp.get_clients({ bufnr = 0 }) == 0, file .. " started a language server: " .. vim.inspect(vim.tbl_map(function(c)
      return c.name
    end, vim.lsp.get_clients({ bufnr = 0 })))
    )
  end
  for _, tool in ipairs(vim.split(vim.env.PROBE_ABSENT, " ")) do
    check(vim.fn.exepath(tool) == "", tool .. " is installed: " .. vim.fn.exepath(tool))
  end
  for _, server in ipairs(vim.split(vim.env.PROBE_SERVERS_OFF, " ")) do
    check(not vim.lsp.is_enabled(server), server .. " is enabled")
  end
  local conform = require("conform")
  for _, ft in ipairs(vim.split(vim.env.PROBE_FORMATTER_FT_OFF, " ")) do
    check(#(conform.formatters_by_ft[ft] or {}) == 0, ft .. " has formatters: " .. vim.inspect(conform.formatters_by_ft[ft]))
  end
  -- What is left works.
  vim.cmd.edit(vim.fn.fnameescape(vim.env.PROBE_FILE_KEPT))
  wait_for(function()
    return #vim.lsp.get_clients({ bufnr = 0, name = vim.env.PROBE_SERVER_KEPT }) == 1
  end, vim.env.PROBE_SERVER_KEPT .. " did not start")
end

vim.defer_fn(function()
  local ok, err = xpcall(function()
    settle()
    local startup = reported(true)
    check(#startup == 0, "the editor reported on startup:\n" .. table.concat(startup, "\n"))
    probes[probe]()
    local after = reported()
    check(#after == 0, "the editor reported:\n" .. table.concat(after, "\n"))
  end, debug.traceback)
  if not ok then
    fail(tostring(err))
    return
  end
  io.stdout:write("PROBE " .. probe .. " OK\n")
  vim.cmd("qa!")
end, 0)
