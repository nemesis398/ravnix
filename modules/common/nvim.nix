# Neovim with LazyVim, reproducible: every plugin, language server and
# formatter comes from the Nix store, and the editor never goes to the
# network, not at startup and not afterwards. A home-manager module of its
# own: a host's common module imports it, and tests/common/nvim.nix imports
# it by itself.
#
# The choice: the LazyVim distribution as it is, with lazy.nvim loading its
# plugins from a directory of the store, and nixpkgs as the lockfile. nixvim
# was the other way, and is not used: it would turn the whole Lua config
# into Nix, LazyVim included (it is a distribution of lazy.nvim specs, not a
# set of nixvim plugins), and a new flake input would pin a second set of
# plugin versions beside nixpkgs'. Here the Lua stays Lua, as the upstream
# documents it, there is no input beyond nixpkgs, and the plugin versions are
# the ones the flake lock gives nixpkgs, LazyVim's own among them. The price
# is a list below that names each plugin LazyVim and its extras use; the
# `store` probe of tests/common/nvim.nix fails if one is missing, and its
# `lsp` probes fail if a language server is.
#
#   lua/ravnix.lua      generated here: the plugin directory, the parsers, the
#                       theme's colors, the dictionary. Nothing else in the
#                       config is generated, so it reads as plain Lua.
#   lazy.nvim           takes each plugin from the plugin directory (init.lua,
#                       dev.path with fallback off), installs and checks for
#                       nothing, and keeps its lockfile in the state directory.
#   Mason               off. Language servers, formatters and linters are the
#                       Nix packages in extraPackages, on the editor's PATH,
#                       and LazyVim enables each server of its `servers` table
#                       without Mason (lua/plugins/store.lua).
#   treesitter          the parsers and queries below are built by Nix; the
#                       nvim-treesitter plugin is pointed at them.
#   catppuccin          Catppuccin Mocha in the accent of ravnix.theme, set up
#                       by the lazy.nvim spec in lua/plugins/catppuccin.lua.
#                       The catppuccin/nix port of Neovim is not used: it
#                       installs a second copy of the plugin outside
#                       lazy.nvim, and the accent needs per-group overrides it
#                       cannot take (docs/style.md, rule 9).
#
# Nix is served by nil, not nixd. nil starts at once and needs no
# configuration; nixd evaluates the flake for its option completion, which is
# slow to start and wants settings per project. LazyVim's own Nix extra uses
# nil, and so does this.
#
# Your own settings go in a file of yours below ~/.config/nvim, set with
# xdg.configFile."nvim/lua/plugins/mine.lua" (a lazy.nvim spec) or
# xdg.configFile."nvim/lua/user/options.lua" (options, read last). Spelling in
# another language than English is such a setting: it needs the language's
# word list from the Vim runtime in ~/.local/share/nvim/site/spell/.
#
# Exceptions to docs/style.md (rule 9): none. Floats have a single line
# (winborder, lazy.nvim's ui.border, and the which-key and noice windows that
# name a border of their own, in lua/plugins/borders.lua), the accent is on
# the line number of the cursor, directories and every float's frame;
# corners are square and the colors opaque, and nothing moves.
#
# Known gaps, found and not fixed:
#   - The plugin list below is kept by hand. A LazyVim update that adds a
#     plugin, or an extra turned on in init.lua, fails the `store` probe
#     until the plugin is named here; one that drops a plugin leaves it
#     in the closure unnoticed.
#   - Only the extras in init.lua have their plugins and servers. Another
#     extra needs its entries here, and its grammar in the list below.
#   - A language that is not in the grammar list below has no treesitter
#     highlighting and cannot get it by :TSInstall, since there is neither a
#     C compiler nor the tree-sitter CLI on the editor's PATH.
#   - Neovim's German word list (and any other language's) is not shipped: it
#     is a download from the Vim project's server with no versioned URL.
#   - The LanguageTool credentials read the user name from rbw with
#     `rbw get --field username`. The test answers that with a stand-in
#     script; it has not been run against a vault.
#   - Opening a file from a file manager (a desktop entry) is the desktop
#     shape's business and is not set up here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vp = pkgs.vimPlugins;
  theme = config.ravnix.theme;

  # Parsers and queries, by the name nvim-treesitter gives the language.
  # LazyVim's own list, plus what its extras ask for (json5, ninja, rst,
  # nix) and the languages edited here: Odin, and what git opens an editor
  # for. A language that is not here has no treesitter highlighting; the
  # `store` probe fails if one that LazyVim asks for is missing.
  grammars = [
    "bash"
    "c"
    "diff"
    "gitcommit"
    "git_rebase"
    "html"
    "javascript"
    "jsdoc"
    "json"
    "json5"
    "lua"
    "luadoc"
    "luap"
    "markdown"
    "markdown_inline"
    "ninja"
    "nix"
    "odin"
    "printf"
    "python"
    "query"
    "regex"
    "rst"
    "toml"
    "tsx"
    "typescript"
    "vim"
    "vimdoc"
    "xml"
    "yaml"
  ];

  # A plugin and everything it depends on, once each.
  closure =
    plugins:
    map (item: item.plugin) (
      lib.genericClosure {
        startSet = map (plugin: {
          key = plugin.outPath;
          inherit plugin;
        }) plugins;
        operator =
          item:
          map (plugin: {
            key = plugin.outPath;
            inherit plugin;
          }) (item.plugin.dependencies or [ ]);
      }
    );

  treesitter = pkgs.symlinkJoin {
    name = "nvim-treesitter-with-parsers";
    paths = closure [ (vp.nvim-treesitter.withPlugins (p: map (language: p.${language}) grammars)) ];
  };

  # Every plugin LazyVim, its extras and lua/plugins use, by the name
  # lazy.nvim gives it: the last part of the repository's name. mini.nvim is
  # one repository for all its modules.
  plugins = {
    "lazy.nvim" = vp.lazy-nvim;
    "LazyVim" = vp.LazyVim;
    "snacks.nvim" = vp.snacks-nvim;
    "catppuccin" = vp.catppuccin-nvim;
    "nvim-lspconfig" = vp.nvim-lspconfig;
    "nvim-treesitter" = treesitter;
    "nvim-treesitter-textobjects" = vp.nvim-treesitter-textobjects;
    "nvim-ts-autotag" = vp.nvim-ts-autotag;
    "ts-comments.nvim" = vp.ts-comments-nvim;
    "lazydev.nvim" = vp.lazydev-nvim;
    "conform.nvim" = vp.conform-nvim;
    "nvim-lint" = vp.nvim-lint;
    "blink.cmp" = vp.blink-cmp;
    "friendly-snippets" = vp.friendly-snippets;
    "flash.nvim" = vp.flash-nvim;
    "gitsigns.nvim" = vp.gitsigns-nvim;
    "grug-far.nvim" = vp.grug-far-nvim;
    "todo-comments.nvim" = vp.todo-comments-nvim;
    "trouble.nvim" = vp.trouble-nvim;
    "which-key.nvim" = vp.which-key-nvim;
    "persistence.nvim" = vp.persistence-nvim;
    "plenary.nvim" = vp.plenary-nvim;
    "bufferline.nvim" = vp.bufferline-nvim;
    "lualine.nvim" = vp.lualine-nvim;
    "noice.nvim" = vp.noice-nvim;
    "nui.nvim" = vp.nui-nvim;
    "mini.ai" = vp.mini-nvim;
    "mini.icons" = vp.mini-nvim;
    "mini.surround" = vp.mini-nvim;
    "SchemaStore.nvim" = vp.SchemaStore-nvim;
    "render-markdown.nvim" = vp.render-markdown-nvim;
    "markdown-preview.nvim" = vp.markdown-preview-nvim;
    "venv-selector.nvim" = vp.venv-selector-nvim;
  };

  pluginDir = pkgs.linkFarm "nvim-plugins" (
    lib.mapAttrsToList (name: path: { inherit name path; }) plugins
  );

  # Read by init.lua and the plugin specs as require("ravnix").
  data = {
    plugins = toString pluginDir;
    treesitter = toString treesitter;
    colors = theme.roles;
    dictionary = config.ravnix.dictionary.file;
  };

  # The config directory: the Lua of this module, and the generated file.
  nvimConfig = pkgs.runCommand "nvim-config" { } ''
    cp -r ${./nvim} $out
    chmod -R u+w $out
    rm $out/marksman.toml
    cat > $out/lua/ravnix.lua <<'EOF'
    -- Generated by modules/common/nvim.nix.
    return ${lib.generators.toLua { } data}
    EOF
  '';
in
{
  imports = [
    ../theme/options.nix
    ../options/dictionary.nix
  ];

  config = {
    programs.neovim = {
      enable = true;
      # The providers are for plugins written against them; LazyVim has none.
      withNodeJs = false;
      withPython3 = false;
      withRuby = false;
      withPerl = false;
      # init.lua is in the config directory below.
      sideloadInitLua = true;
      extraPackages = with pkgs; [
        # What LazyVim calls.
        git
        ripgrep
        fd
        # Lua
        lua-language-server
        stylua
        # Shell
        bash-language-server
        shellcheck
        shfmt
        # Nix
        nil
        nixfmt
        statix
        # Odin (ols brings odinfmt)
        ols
        # Markdown
        marksman
        markdownlint-cli2
        markdown-toc
        ltex-ls-plus
        # JSON and prettier's languages
        vscode-langservers-extracted
        prettier
        # Python
        pyright
        ruff
      ];
    };

    xdg.configFile = {
      "nvim" = {
        source = nvimConfig;
        # So a file of the user's own can sit beside these.
        recursive = true;
      };
      "marksman/config.toml".source = ./nvim/marksman.toml;
    };
  };
}
