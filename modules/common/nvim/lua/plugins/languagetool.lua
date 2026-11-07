-- LanguageTool grammar and spelling checks, on demand.
--
-- Nothing runs until asked: <leader>cg checks the current buffer as German,
-- <leader>ce as English, and pressing the same key again stops the check. The
-- language is fixed per check because ltex's "auto" mode turns spelling off.
--
-- The checks go to LanguageTool Premium (api.languagetoolplus.com), so the
-- buffer's text leaves the machine. The ltex-ls-plus server itself is a local
-- Java process from the Nix store. It checks on open and on save, not on every
-- edit, to keep the API request count down.
--
-- The credentials and the dictionary, ravnix.dictionary.file, are read in
-- lua/ravnix_languagetool.lua. The "Add to dictionary" code action appends to
-- the dictionary, so every tool that reads it learns the word too.
--
-- While a check runs, Vim's own spell check is off in that buffer, so a typo is
-- not underlined twice.

local lt = require("ravnix_languagetool")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "LanguageTool" })
end

-- ltex asks the client to run this when you pick "Add ... to dictionary".
-- arguments[1].words is { ["de-DE"] = { "Wort", ... } }.
vim.lsp.commands["_ltex.addToDictionary"] = function(command, ctx)
  local added = lt.add(command.arguments[1].words or {})
  if #added == 0 then
    return
  end
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if client then
    local lang = client.settings.ltex.language
    client.settings.ltex.dictionary = { [lang] = lt.words(lang) }
    client:notify("workspace/didChangeConfiguration", { settings = client.settings })
  end
  notify("Added to " .. lt.dictionary .. ": " .. table.concat(added, ", "))
end

local function toggle(lang)
  local bufnr = vim.api.nvim_get_current_buf()
  local name = "ltex_" .. lang:sub(1, 2)

  -- A running check on this buffer is stopped either way: the same key turns
  -- it off, the other key switches the language.
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if client.name:match("^ltex_") then
      vim.lsp.buf_detach_client(bufnr, client.id)
      if vim.tbl_isempty(client.attached_buffers) then
        client:stop()
      end
      vim.wo.spell = vim.b[bufnr].ltex_spell_before ~= false
      if client.name == name then
        notify("Check off")
        return
      end
    end
  end

  local c = lt.credentials()
  if not c.key or not c.user then
    notify("No API key or username: set LANGUAGETOOL_API_KEY and LANGUAGETOOL_USERNAME, or unlock rbw", vim.log.levels.ERROR)
    return
  end

  local base = vim.lsp.config.ltex_plus
  vim.b[bufnr].ltex_spell_before = vim.wo.spell
  vim.wo.spell = false
  vim.lsp.start({
    name = name,
    cmd = base.cmd,
    get_language_id = base.get_language_id,
    root_dir = vim.fs.root(bufnr, ".git") or vim.fn.getcwd(),
    settings = {
      ltex = {
        enabled = base.settings.ltex.enabled,
        language = lang,
        checkFrequency = "save",
        languageToolHttpServerUri = c.server,
        languageToolOrg = { username = c.user, apiKey = c.key },
        dictionary = { [lang] = lt.words(lang) },
      },
    },
  }, { bufnr = bufnr })
  notify("Checking as " .. lang .. " (again on every save)")
end

return {
  {
    "neovim/nvim-lspconfig",
    -- Left to the toggle above: started by itself, ltex_plus would check every
    -- markdown buffer as en-US with the local engine.
    opts = { servers = { ltex_plus = { enabled = false } } },
    keys = {
      { "<leader>cg", function() toggle("de-DE") end, desc = "LanguageTool German (toggle)" },
      { "<leader>ce", function() toggle("en-US") end, desc = "LanguageTool English (toggle)" },
    },
  },
}
