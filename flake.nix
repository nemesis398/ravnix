{
  description = "Ravnix: a NixOS flake that makes a laptop and a server one system";

  # Every input a later part of ravnix needs is declared here, so that work
  # adds files instead of editing this one and its lock at the same time.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;

      # Checks are found, not listed: every tests/<area>/<name>.nix is the
      # check <area>-<name> (lib/discover-checks.nix). Each such file is a
      # function of { self, inputs, pkgs, lib, system, ... } that returns a
      # derivation; it takes what it needs and ends its argument set with
      # `...`, so an argument added here later breaks no test.
      checkArgs = {
        inherit
          self
          inputs
          pkgs
          lib
          system
          ;
      };
      discovered = lib.mapAttrs (_: file: import file checkArgs) (
        import ./lib/discover-checks.nix { inherit lib; } ./tests
      );

      ownChecks = {
        # The shell tests, scripts/tests/*.test.sh and scripts/hooks/test.sh,
        # run in the build sandbox with the tools they need.
        scripts-tests =
          pkgs.runCommand "scripts-tests"
            {
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  ./scripts
                  ./.githooks
                  ./.claude/settings.json
                  ./docs/mermaid-theme.json
                  ./docs/style.md
                ];
              };
              nativeBuildInputs = [
                pkgs.git
                pkgs.jq
                pkgs.ripgrep
                pkgs.shellcheck
              ];
            }
            ''
              cp -r "$src" src
              chmod -R u+w src
              # The sandbox has no /usr/bin/env.
              patchShebangs src >/dev/null
              cd src
              export HOME="$TMPDIR"
              status=0
              for test in scripts/tests/*.test.sh scripts/hooks/test.sh; do
                echo "==> $test"
                bash "$test" || status=1
              done
              [ "$status" = 0 ]
              touch "$out"
            '';
      };
      clashes = lib.attrNames (lib.intersectAttrs ownChecks discovered);

      # Odin tools, found like checks: every
      # tools/<name>/default.nix is the package <name> and the checks
      # <name>-tests and <name>-bench (lib/discover-tools.nix, built by
      # buildOdinTool in lib/odin.nix); a directory that starts with "_", the
      # template, gets its checks and no package. tools/README.md has the rest.
      odin = import ./lib/odin.nix { inherit pkgs lib; };
      tools = import ./lib/discover-tools.nix { inherit lib; } ./tools {
        inherit (odin) buildOdinTool;
        inherit pkgs lib;
      };
      toolClashes = lib.attrNames (lib.intersectAttrs tools.checks (discovered // ownChecks));
      # End of the Odin tools.

      # Claude Code: the claude-code input's package with the download it was
      # made from, which the full gate verifies against Anthropic's release
      # manifest for the version in this flake's own lock (lib/claude-code.nix,
      # tools/claude-code-verify). A private flake whose claude-code input
      # this one follows builds and checks the version of its own lock.
      claudeCode = import ./lib/claude-code.nix {
        inherit lib;
      } inputs.claude-code.packages.${system}.claude-code;
    in
    {
      # The typed ravnix.* options, one module for NixOS and home-manager.
      nixosModules.options = ./modules/options;
      homeModules.options = ./modules/options;
      # The Mocha palette, the roles, the accent option, and the style in the
      # applications; catppuccin/nix comes along, so a user imports one.
      nixosModules.theme = ./modules/theme/nixos.nix;
      # The key keeps one copy when it is imported more than once, as a
      # shared module of nixosModules.common and by a host: without it each
      # import loads catppuccin's function module again.
      homeModules.theme = {
        key = "ravnix/homeModules.theme";
        imports = [
          inputs.catppuccin.homeModules.catppuccin
          ./modules/theme
        ];
      };
      # The shell, the prompt, git, the command-line tools, Claude Code and the
      # user's account, for both hosts. nixosModules.common brings home-manager,
      # the options and the theme along; homeModules.common needs
      # homeModules.options and homeModules.theme beside it, and brings
      # homeModules.claude-skills (so Claude Code, its hooks and its skills)
      # along, because the `claude` function of its shell starts that build.
      # Each carries a key, so a host and a private flake can both import it
      # and get one copy, not two.
      nixosModules.common = {
        key = "ravnix/nixosModules.common";
        imports = [ (import ./modules/common/nixos.nix { inherit self; }) ];
      };
      homeModules.common = {
        key = "ravnix/homeModules.common";
        imports = [
          ./modules/common
          self.homeModules.claude-skills
        ];
      };
      # Claude Code from packages.claude-code, and the skill
      # framework: the skill values, the hooks and the status line
      # (claude/README.md). claude-skills brings claude-code along, whose
      # activation step puts its hooks into the settings. Each carries a
      # key, so a second import adds nothing.
      homeModules.claude-code = {
        key = "ravnix/homeModules.claude-code";
        imports = [
          ./modules/common/claude-code.nix
          (
            { lib, pkgs, ... }:
            {
              programs.claude-code.package =
                lib.mkDefault
                  self.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
            }
          )
        ];
      };
      homeModules.claude-skills = {
        key = "ravnix/homeModules.claude-skills";
        imports = [
          self.homeModules.claude-code
          ./modules/common/claude-skills.nix
        ];
      };
      packages.${system} =
        if tools.packages ? claude-code then
          throw "tools/claude-code is a tool, and packages.claude-code is Claude Code itself; rename the tool"
        else
          tools.packages // { claude-code = claudeCode; };
      checks.${system} =
        if clashes != [ ] then
          throw "tests/: ${toString clashes} is already a check of flake.nix; pick another name"
        else if toolClashes != [ ] then
          throw "tools/: ${toString toolClashes} is already a check of tests/ or flake.nix; rename the tool or the test"
        else
          discovered // ownChecks // tools.checks;
      templates.default = {
        path = ./templates/default;
        description = "A private flake with your personal values, built on ravnix";
      };
    };
}
