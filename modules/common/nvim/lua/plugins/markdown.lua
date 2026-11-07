-- Markdown lint and format rules that allow mixed lists.
--
-- With LazyVim's defaults, ordered and unordered lists could not be combined:
-- markdownlint flagged a bullet nested under "1." (indentation, hard tabs) and
-- a bullet list directly after a numbered one, and prettier re-indented the
-- nesting, put blank lines between the lists and turned tabs into odd spaces.
--
-- 1. markdownlint reads ../../markdownlint.yaml, which turns off the four rules
--    that reject mixed lists. A project with its own markdownlint config keeps
--    that config instead.
-- 2. prettier no longer formats Markdown. <leader>cf runs markdownlint's fixes
--    alone, on every file, plus markdown-toc where the file has a
--    "<!-- toc -->" marker. prettier
--    still formats everything else.
-- 3. The formatter runs with --no-globs: with a project config that lists
--    "globs", markdownlint-cli2 --fix would otherwise fix every Markdown file in
--    the project, not only the buffer.
--
-- Markdown indents with 4 spaces (options.lua), which nests correctly under
-- both "-" and "1.".

local CONFIG = vim.fn.stdpath("config") .. "/markdownlint.yaml"

local PROJECT_CONFIGS = {
  ".markdownlint-cli2.jsonc",
  ".markdownlint-cli2.yaml",
  ".markdownlint-cli2.cjs",
  ".markdownlint-cli2.mjs",
  ".markdownlint.jsonc",
  ".markdownlint.json",
  ".markdownlint.yaml",
  ".markdownlint.yml",
  ".markdownlint.cjs",
  ".markdownlint.mjs",
}

-- markdownlint-cli2 reads its config from the directory it runs in. Run it in
-- the directory of the project's config if there is one, otherwise in the
-- file's own directory with ours.
local function lint_setup(path)
  local dir = path ~= "" and vim.fs.dirname(path) or vim.fn.getcwd()
  local found = vim.fs.find(PROJECT_CONFIGS, { path = dir, upward = true })[1]
  if found then
    return vim.fs.dirname(found), {}
  end
  return dir, { "--config", CONFIG }
end

return {
  {
    "stevearc/conform.nvim",
    opts = function(_, opts)
      opts.formatters_by_ft = opts.formatters_by_ft or {}
      opts.formatters_by_ft.markdown = { "markdownlint-cli2", "markdown-toc" }
      opts.formatters = opts.formatters or {}
      local f = opts.formatters["markdownlint-cli2"] or {}
      -- LazyVim runs it only while the buffer has a markdownlint diagnostic,
      -- which left a clean file with no formatter at all now that prettier is
      -- gone ("no formatter available"). On a clean file --fix changes nothing.
      f.condition = nil
      f.cwd = function(_, ctx)
        return (lint_setup(ctx.filename))
      end
      f.args = function(_, ctx)
        local _, args = lint_setup(ctx.filename)
        return vim.list_extend(args, { "--no-globs", "--fix", "$FILENAME" })
      end
      opts.formatters["markdownlint-cli2"] = f
    end,
  },
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters = {
        -- A function, so the config is looked up for each buffer anew.
        ["markdownlint-cli2"] = function()
          local cwd, args = lint_setup(vim.api.nvim_buf_get_name(0))
          return vim.tbl_extend("force", require("lint.linters.markdownlint-cli2"), {
            cwd = cwd,
            args = vim.list_extend(args, { "-" }),
          })
        end,
      },
    },
  },
}
