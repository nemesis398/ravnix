-- Odin: the `ols` language server and its formatting.
--
-- LazyVim has no Odin extra, so `ols` is listed here, and on save it formats
-- the buffer. It runs odinfmt with no config file unless one sits in a parent
-- directory of the file, and odinfmt's own default `character_width` is 100,
-- so a call you broke by hand was joined back into one long line (97 columns
-- without a config, 34 with one at 80).
--
-- conform wins over the LSP fallback, so mapping `odin` to odinfmt here makes
-- it the formatter we configure. It always reads the one `odinfmt.json` next to
-- this config, for every project; a project's own odinfmt.json is ignored on
-- purpose, so the same code formats the same way everywhere.
return {
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { ols = {} } },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = { odin = { "odinfmt" } },
      formatters = {
        odinfmt = {
          args = { "-stdin", "-config:" .. vim.fn.stdpath("config") .. "/odinfmt.json" },
        },
      },
    },
  },
}
