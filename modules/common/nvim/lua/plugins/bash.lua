-- Shell support.
--
-- LazyVim core already FORMATS shell via shfmt, so there is no conform wiring
-- here. The only thing core lacks is the shell LSP, so we add `bashls`.
-- ShellCheck *diagnostics* are surfaced by bashls itself once the `shellcheck`
-- binary is on PATH, as it is: the editor's PATH holds bash-language-server,
-- shellcheck and shfmt (modules/common/nvim.nix).

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        -- bashls already attaches to `sh`/`bash`; zsh is intentionally NOT added
        -- (zsh != bash syntax — bashls/shfmt/shellcheck don't parse it).
        bashls = {
          settings = {
            bashIde = {
              -- upstream default: only index real shell scripts (the old
              -- "*@(*)" extglob made bashls parse every file as shell).
              globPattern = "**/*@(.sh|.inc|.bash|.command)",
            },
          },
        },
      },
    },
  },
}
