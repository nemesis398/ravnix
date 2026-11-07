-- What the LanguageTool checks (lua/plugins/languagetool.lua) read and write
-- outside the editor: the credentials, and ravnix.dictionary.file.
--
-- Credentials, in this order: LANGUAGETOOL_API_KEY, LANGUAGETOOL_USERNAME and
-- LANGUAGETOOL_SERVER from the environment, then the same names in
-- ~/.config/languagetool/credentials, then the Bitwarden entry through rbw if
-- the vault is unlocked: the entry named "LanguageTool" (or the one
-- LANGUAGETOOL_RBW_ITEM names) holds the API key as its password and the
-- account name as its user name. The key is never written anywhere.
--
-- The dictionary has one entry per line: `word`, or `word | lang=de,en |
-- heard=...`. A word with `lang` is known to the checks of those languages
-- only; a line starting with `#` and an empty line are skipped, and so is a
-- line that is nothing but fields.
local M = {}

M.dictionary = require("ravnix").dictionary
M.default_server = "https://api.languagetoolplus.com"

local function rbw(args)
  local ok, r = pcall(function()
    return vim.system(vim.list_extend({ "rbw", "get" }, args)):wait()
  end)
  local out = ok and r.code == 0 and vim.trim(r.stdout) or ""
  return out ~= "" and out or nil
end

-- An empty variable is an unset one.
local function env(name)
  local value = vim.env[name]
  return value ~= "" and value or nil
end

---@return { key?: string, user?: string, server: string }
function M.credentials()
  local c = {
    key = env("LANGUAGETOOL_API_KEY"),
    user = env("LANGUAGETOOL_USERNAME"),
    server = env("LANGUAGETOOL_SERVER"),
  }
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
  if not c.key and vim.fn.executable("rbw") == 1 and vim.system({ "rbw", "unlocked" }):wait().code == 0 then
    local item = env("LANGUAGETOOL_RBW_ITEM") or "LanguageTool"
    c.key = rbw({ item })
    c.user = c.user or rbw({ "--field", "username", item })
  end
  if c.server == nil or c.server == "" then
    c.server = M.default_server
  end
  return c
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
---left out.
---@param by_language table<string, string[]> de-DE = { "Wort" }
---@return string[] added
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
  if #new > 0 then
    vim.fn.mkdir(vim.fn.fnamemodify(M.dictionary, ":h"), "p")
    vim.fn.writefile(new, M.dictionary, "a")
  end
  return added
end

return M
