-- What the LanguageTool checks (lua/plugins/languagetool.lua) read and write
-- outside the editor: the credentials, and ravnix.dictionary.file.
--
-- Credentials, one by one, in this order: LANGUAGETOOL_API_KEY,
-- LANGUAGETOOL_USERNAME and LANGUAGETOOL_SERVER from the environment, then the
-- Bitwarden entry through rbw if the vault is unlocked (the entry named
-- "LanguageTool", or the one LANGUAGETOOL_RBW_ITEM names: the API key is its
-- password and the account name its user name), then the same names in
-- ~/.config/languagetool/credentials for a machine without rbw.
--
-- The API key is kept in memory and goes to the server in the one place it
-- must: the server's configuration. It is not in the settings of the
-- client, so `:checkhealth vim.lsp` does not print it; it is not in a
-- command line; the variable is taken out of the editor's environment when
-- this file loads, so nothing the editor starts afterwards inherits it; and
-- nothing here writes it down.
--
-- The dictionary has one entry per line: `word`, or `word | lang=de,en |
-- heard=...`. A word with `lang` is known to the checks of those languages
-- only; a line starting with `#` and an empty line are skipped, and so is a
-- line that is nothing but fields.
local M = {}

M.dictionary = require("ravnix").dictionary
M.default_server = "https://api.languagetoolplus.com"
-- How long rbw may take to answer. A vault that locks between the question
-- whether it is unlocked and the request would otherwise open a prompt that
-- blocks the editor.
M.rbw_timeout_ms = 5000

-- An empty variable is an unset one.
local function env(name)
  local value = vim.env[name]
  return value ~= "" and value or nil
end

local remembered = env("LANGUAGETOOL_API_KEY")
vim.env.LANGUAGETOOL_API_KEY = nil

---Runs rbw. Returns its result, or nil when it fails, is missing, or does not
---answer in time (it is killed then).
local function run_rbw(args)
  local ok, process = pcall(vim.system, vim.list_extend({ "rbw" }, args), { text = true })
  if not ok then
    return nil
  end
  local result = process:wait(M.rbw_timeout_ms)
  return result.code == 0 and result or nil
end

---What rbw prints, or nil.
local function rbw(args)
  local result = run_rbw(args)
  local out = result and vim.trim(result.stdout or "") or ""
  return out ~= "" and out or nil
end

---@return { key?: string, user?: string, server: string }
function M.credentials()
  local c = {
    key = env("LANGUAGETOOL_API_KEY") or remembered,
    user = env("LANGUAGETOOL_USERNAME"),
    server = env("LANGUAGETOOL_SERVER"),
  }
  remembered = c.key
  vim.env.LANGUAGETOOL_API_KEY = nil

  -- What the environment left out, from the vault, and only while it is
  -- unlocked: a locked one would open a prompt.
  if (not c.key or not c.user) and vim.fn.executable("rbw") == 1 and run_rbw({ "unlocked" }) then
    local item = env("LANGUAGETOOL_RBW_ITEM") or "LanguageTool"
    c.key = c.key or rbw({ "get", item })
    c.user = c.user or rbw({ "get", "--field", "username", item })
  end

  local file = vim.fn.expand("~/.config/languagetool/credentials")
  if vim.fn.filereadable(file) == 1 then
    local map = { LANGUAGETOOL_API_KEY = "key", LANGUAGETOOL_USERNAME = "user", LANGUAGETOOL_SERVER = "server" }
    for _, line in ipairs(vim.fn.readfile(file)) do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      v = v and v:gsub("^[\"']", ""):gsub("[\"']$", "") or ""
      if k and map[k] and v ~= "" and not c[map[k]] then
        c[map[k]] = v
      end
    end
  end

  if c.server == nil or c.server == "" then
    c.server = M.default_server
  end
  return c
end

---What a client gets in answer to ltex's `workspace/configuration` request,
---and in a `workspace/didChangeConfiguration`, with the key in it. The
---settings of the client itself never hold the key.
---@param settings table the client's settings (client.settings.ltex)
---@param c { key: string, user: string }
function M.with_key(settings, c)
  local full = vim.deepcopy(settings)
  full.languageToolOrg = { username = c.user, apiKey = c.key }
  return full
end

---Handlers and the init hook that give a client the key without keeping it in
---the client's settings.
---@param c { key: string, user: string }
function M.client_config(c)
  local default = vim.lsp.handlers["workspace/configuration"]
  return {
    handlers = {
      ["workspace/configuration"] = function(err, params, ctx)
        local result = default(err, params, ctx)
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        for i, item in ipairs(params and params.items or {}) do
          if client and item.section == "ltex" and type(result[i]) == "table" then
            result[i] = M.with_key(client.settings.ltex, c)
          end
        end
        return result
      end,
    },
    on_init = function(client)
      client:notify("workspace/didChangeConfiguration", {
        settings = { ltex = M.with_key(client.settings.ltex, c) },
      })
    end,
  }
end

---One line of the dictionary: the word and the languages it is limited to.
---@return string? word, string[]? languages
local function parse(line)
  if line:match("^%s*#") then
    return nil
  end
  local fields = vim.split(line, "|", { plain = true })
  local word = vim.trim(fields[1])
  if word == "" then
    return nil
  end
  local languages
  for i = 2, #fields do
    local list = vim.trim(fields[i]):match("^lang=(.+)$")
    if list then
      languages = vim.tbl_map(function(language)
        return vim.trim(language):lower()
      end, vim.split(list, ",", { plain = true }))
    end
  end
  return word, languages
end

local function lines()
  if vim.fn.filereadable(M.dictionary) ~= 1 then
    return {}
  end
  local ok, read = pcall(vim.fn.readfile, M.dictionary)
  return ok and read or {}
end

---Whether the dictionary has a last line that is not closed by a line break:
---what is appended would join it.
local function open_last_line()
  local file = io.open(M.dictionary, "rb")
  if not file then
    return false
  end
  local size = file:seek("end")
  local last
  if size and size > 0 then
    file:seek("set", size - 1)
    last = file:read(1)
  end
  file:close()
  return last ~= nil and last ~= "\n"
end

---The words that the checks of `lang` (de-DE, en-US) know.
---@param lang string
---@return string[]
function M.words(lang)
  local words, seen = {}, {}
  for _, line in ipairs(lines()) do
    local word, languages = parse(line)
    if word and not seen[word] and (languages == nil or vim.tbl_contains(languages, lang:sub(1, 2):lower())) then
      seen[word] = true
      table.insert(words, word)
    end
  end
  return words
end

---Appends words to the dictionary, each limited to its language and none
---twice. A word that would break the line format (a bar, a line break) is
---left out. The dictionary is shared with every tool that reads it, so what
---is there stays as it is: a last line without a line break is closed first,
---and when the file cannot be written nothing is.
---@param by_language table<string, string[]> de-DE = { "Wort" }
---@return string[] added, string? failure
function M.add(by_language)
  local added, new = {}, {}
  for lang, words in pairs(by_language) do
    local known = {}
    for _, word in ipairs(M.words(lang)) do
      known[word] = true
    end
    for _, word in ipairs(words) do
      if not known[word] and not word:find("[|\r\n]") and vim.trim(word) ~= "" then
        known[word] = true
        table.insert(added, word)
        table.insert(new, ("%s | lang=%s"):format(word, lang:sub(1, 2):lower()))
      end
    end
  end
  if #new == 0 then
    return added
  end
  if open_last_line() then
    table.insert(new, 1, "")
  end
  local ok, status = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(M.dictionary, ":h"), "p")
    return vim.fn.writefile(new, M.dictionary, "a")
  end)
  if not ok or status ~= 0 then
    return {}, "cannot write " .. M.dictionary
  end
  return added
end

return M
