# What the editor's closure holds, by the languages a host asks for
# (ravnix.editor.languages). The default is every language. Dropping Odin
# takes out `ols` and with it the Odin compiler, LLVM and clang (2.3 GiB of
# the 3.9 GiB), dropping LanguageTool takes out its JDK, and the editor of a
# host that wants Lua and Nix only holds none of the other tools. A language
# the option does not know is refused.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  nvimUser = import ./helpers/nvim-user.nix { inherit self lib; };

  evaluated =
    extra:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        (nvimUser extra)
        {
          home = {
            username = "alice";
            homeDirectory = "/home/alice";
          };
        }
      ];
    };
  editorOf = extra: (evaluated extra).config.programs.neovim.finalPackage;

  everything = (evaluated { }).config.ravnix.editor.languages;
  without = language: lib.filter (l: l != language) everything;

  # The names in the closure of a package, without the hashes.
  closureOf =
    name: package:
    pkgs.runCommand "closure-${name}" { closure = pkgs.closureInfo { rootPaths = [ package ]; }; } ''
      sed 's|^/nix/store/[a-z0-9]*-||' "$closure/store-paths" | sort > "$out"
    '';

  all = closureOf "all" (editorOf { });
  noOdin = closureOf "no-odin" (editorOf {
    ravnix.editor.languages = lib.mkForce (without "odin");
  });
  noLanguageTool = closureOf "no-languagetool" (editorOf {
    ravnix.editor.languages = lib.mkForce (without "languagetool");
  });
  luaAndNix = closureOf "lua-and-nix" (editorOf {
    ravnix.editor.languages = lib.mkForce [
      "lua"
      "nix"
    ];
  });

  # One definition of the list, with no me.nix beside it, is the value. The
  # editor module brings the options it reads (the list, the dictionary, the
  # theme) by itself.
  lone = closureOf "lone" (
    (inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        ../../modules/common/nvim.nix
        {
          home = {
            username = "alice";
            homeDirectory = "/home/alice";
            stateVersion = "26.05";
          };
          ravnix.dictionary.file = "/home/alice/dictionary.txt";
          ravnix.editor.languages = [
            "lua"
            "nix"
          ];
        }
      ];
    }).config.programs.neovim.finalPackage
  );

  unknown = builtins.tryEval (
    builtins.deepSeq
      (evaluated { ravnix.editor.languages = lib.mkForce [ "cobol" ]; }).config.ravnix.editor.languages
      true
  );

  # Each language on its own gives an editor: the module knows every name the
  # option offers (it also refuses to evaluate if the two lists differ).
  eachAlone = map (
    language: (editorOf { ravnix.editor.languages = lib.mkForce [ language ]; }).drvPath
  ) everything;
in
assert lib.assertMsg (!unknown.success) "a language the option does not know (cobol) was accepted";
assert lib.assertMsg (
  builtins.length (lib.unique eachAlone) == builtins.length everything
) "two languages gave the same editor";
pkgs.runCommand "common-nvim-closure"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    inherit
      all
      noOdin
      noLanguageTool
      luaAndNix
      lone
      ;
  }
  ''
    status=0
    has()  { grep -qE "$2" "$1"; }
    must_have() {
      has "$1" "$2" || { echo "$3: $2 is not in the closure" >&2; status=1; }
    }
    must_lack() {
      if has "$1" "$2"; then
        echo "$3: the closure holds:" >&2
        grep -E "$2" "$1" >&2
        status=1
      fi
    }

    # Every language: the tools are there, so what follows is not vacuous.
    for tool in '^ols-' '^odin-' '^llvm-' '^ltex-ls-plus-' '^pyright-' '^lua-language-server-' '^nil-' '^marksman-'; do
      must_have "$all" "$tool" "every language"
    done

    # Without Odin: no Odin toolchain, and everything else stays.
    must_lack "$noOdin" '^(ols|odin|llvm|clang|lld)[-0-9]' "without odin"
    must_have "$noOdin" '^ltex-ls-plus-' "without odin"
    must_have "$noOdin" '^pyright-' "without odin"

    # Without LanguageTool: no ltex-ls-plus.
    must_lack "$noLanguageTool" '^ltex-ls-plus-' "without languagetool"
    must_have "$noLanguageTool" '^ols-' "without languagetool"

    # Lua and Nix only: none of the other languages' tools, and theirs stay.
    must_lack "$luaAndNix" '^(ols|odin|llvm|clang|lld|ltex-ls-plus|pyright|ruff|marksman|bash-language-server|shellcheck|shfmt|prettier|markdownlint-cli2|markdown-toc|vscode-langservers-extracted)[-0-9]' "lua and nix"
    for tool in '^lua-language-server-' '^stylua-' '^nil-' '^nixfmt-' '^statix-'; do
      must_have "$luaAndNix" "$tool" "lua and nix"
    done

    # One plain definition (no mkForce, no me.nix) narrows the same way.
    must_lack "$lone" '^(ols|odin|llvm|clang|lld|ltex-ls-plus|pyright|ruff|marksman|bash-language-server|shellcheck|shfmt|prettier|markdownlint-cli2|markdown-toc|vscode-langservers-extracted)[-0-9]' "one definition"
    for tool in '^lua-language-server-' '^nil-'; do
      must_have "$lone" "$tool" "one definition"
    done

    [ "$status" = 0 ]
    touch "$out"
  ''
