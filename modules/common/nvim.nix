# Neovim with LazyVim, reproducible: every plugin, language server and
# formatter comes from the Nix store, and nothing is installed, updated or
# fetched at startup or by the editor on its own. Two things go to the
# network when they are used, and are not hidden: the JSON language server
# downloads a schema when a file names one by URL (a $schema key, or a
# SchemaStore match), and LanguageTool checks the text against its server
# when you turn it on (ravnix.editor.languages, "languagetool"; the toggle
# says so). A home-manager module of its own: a host's common module imports
# it, and tests/common/nvim.nix imports it by itself.
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
# Style (docs/style.md): floats have a single line (winborder, lazy.nvim's
# ui.border, and the which-key, noice and snacks windows that name a border
# or a blend of their own, in lua/plugins/floats.lua); pumblend and winblend
# are 0 and no float dims what is behind it, so every float, menu and
# notification is opaque (lua/config/options.lua, floats.lua; the `opaque`
# probe reads the values in a running editor); the accent is on the line
# number of the cursor, directories and every float's frame; nothing moves.
#
# Exceptions to docs/style.md (rule 9), where a plugin draws a corner the
# config cannot reach:
#   - The help window of trouble.nvim (`?` in a trouble list) is drawn with
#     a hard-coded rounded border; trouble has no option for it.
#   - The spinner snacks.nvim shows beside a running picker is drawn with a
#     hard-coded rounded border; the picker's own windows follow the config.
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
#   - The editor is big: 3.9 GiB with every language. Odin is the heaviest
#     (`ols` brings the Odin compiler with LLVM, lld and clang: 2.3 GiB),
#     then ltex-ls-plus with its JDK (0.9 GiB). A host that does not edit
#     those leaves them out with ravnix.editor.languages; the
#     `common-nvim-closure` check pins that dropping a language drops its
#     tools.
#   - Opening a file from a file manager (a desktop entry) is the desktop
#     shape's business and is not set up here.
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  vp = pkgs.vimPlugins;
  theme = config.ravnix.theme;
  cfg = config.ravnix.editor;

  # The language servers, formatters and linters, by language. A host picks
  # the languages (ravnix.editor.languages); what a language is made of
  # decides what its entry costs in the closure: `ols` brings the Odin
  # compiler with LLVM, 2.3 GiB of the 3.9, ltex-ls-plus a JDK (0.9 GiB).
  # lua/plugins/store.lua turns off in the editor what a language left out
  # would have started.
  installable = with pkgs; {
    bash = [
      bash-language-server
      shellcheck
      shfmt
    ];
    json = [ vscode-langservers-extracted ];
    languagetool = [ ltex-ls-plus ];
    lua = [
      lua-language-server
      stylua
    ];
    markdown = [
      marksman
      markdownlint-cli2
      markdown-toc
    ];
    nix = [
      nil
      nixfmt
      statix
    ];
    # ols brings odinfmt.
    odin = [ ols ];
    python = [
      pyright
      ruff
    ];
    # prettier formats what the web is made of (CSS, HTML, JavaScript,
    # TypeScript, YAML) and JSON.
    web = [ prettier ];
  };

  # The names must be those of the option (modules/options/editor.nix).
  languages =
    assert lib.assertMsg
      (lib.attrNames installable == lib.sort lib.lessThan options.ravnix.editor.languages.default)
      "modules/common/nvim.nix and modules/options/editor.nix name different languages: ${lib.concatStringsSep ", " (lib.attrNames installable)} against ${lib.concatStringsSep ", " options.ravnix.editor.languages.default}";
    installable;

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
    languages = lib.genAttrs cfg.languages (_: true);
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
    ../options/editor.nix
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
      extraPackages =
        # What LazyVim calls.
        [
          pkgs.git
          pkgs.ripgrep
          pkgs.fd
        ]
        ++ lib.concatMap (language: languages.${language}) cfg.languages;
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
