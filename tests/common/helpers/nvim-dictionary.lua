-- How the editor's LanguageTool code reads and appends to the dictionary
-- (modules/common/nvim/lua/ravnix_languagetool.lua), against the lines that
-- ravnix-dict reads one way and an older Lua read another: run by
-- tests/common/nvim-dictionary.nix as `nvim --headless -l THIS LUA_DIR FILE`.
-- tools/ravnix-dict/tests/dict_test.odin
-- (the_editor_and_the_core_read_lang_alike) checks the core on the same
-- lines, so the two cannot drift apart unnoticed.
local lua_dir, file = arg[1], arg[2]
package.path = lua_dir .. "/?.lua;" .. package.path
package.preload.ravnix = function()
  return { dictionary = file }
end
local lt = require("ravnix_languagetool")

local failures = {}
local function check(ok, what)
  if not ok then
    table.insert(failures, what)
  end
end

local lines = {
  "Spaced | lang = de",
  "Twice | lang=de | lang=en",
  "Empty | lang=",
  "Commas | lang= , ,",
  "Upper | LANG=de",
  "Mixed | lang=en | heard=x",
  "Both | lang=de",
  "Both | lang=fr",
  "Free",
  "Both2 | lang=de",
  "Both2",
  "# comment",
  "| lang=de",
  "Tab\there",
  ("x"):rep(257),
  "C# | lang = EN , de",
}
vim.fn.writefile(lines, file)
local want = {
  ["de-DE"] = { "Spaced", "Twice", "Empty", "Commas", "Upper", "Both", "Free", "Both2", "C#" },
  ["en-US"] = { "Twice", "Empty", "Commas", "Upper", "Mixed", "Free", "Both2", "C#" },
  ["fr-FR"] = { "Empty", "Commas", "Upper", "Both", "Free", "Both2" },
}
for lang, words in pairs(want) do
  local got = lt.words(lang)
  check(vim.deep_equal(got, words), lang .. ": " .. vim.inspect(got) .. ", not " .. vim.inspect(words))
end

-- What add leaves out: every word ravnix-dict refuses.
vim.fn.writefile({}, file)
local refused = { "#hash", "tab\tx", ("y"):rep(257), " spaced ", "a|b", "<<<<<<< HEAD", "=======", "line\nbreak", "" }
local added = lt.add({ ["de-DE"] = vim.list_extend({ "ok", ("z"):rep(256), "C#", "Open WebUI" }, refused) })
table.sort(added)
local expected = { "C#", "Open WebUI", "ok", ("z"):rep(256) }
table.sort(expected)
check(vim.deep_equal(added, expected), "added " .. vim.inspect(added))
check(#vim.fn.readfile(file) == 4, "wrote " .. vim.inspect(vim.fn.readfile(file)))

-- A host without a dictionary (ravnix.dictionary.file = null): no words,
-- and an add that says why it wrote nothing.
lt.dictionary = nil
check(#lt.words("de-DE") == 0, "words without a dictionary: " .. vim.inspect(lt.words("de-DE")))
local none, failure = lt.add({ ["de-DE"] = { "Wort" } })
check(#none == 0 and failure ~= nil and failure:find("ravnix.dictionary.file", 1, true), "add without a dictionary: " .. vim.inspect({ none, failure }))
lt.dictionary = file

if #failures > 0 then
  io.stderr:write(table.concat(failures, "\n") .. "\n")
  os.exit(1)
end
print("nvim-dictionary: the editor reads and writes the dictionary as ravnix-dict does")
