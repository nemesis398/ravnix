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

      # Packages, found like tools: every packages/<name>/default.nix is a
      # function for callPackage and becomes the package <name>
      # (lib/discover-packages.nix; packages/README.md has the rest). Packages
      # and tools go under pkgs.ravnix by overlays.default, built with the
      # package set of whoever applies the overlay (lib/ravnix-packages.nix).
      # packages.<system> takes its packages from the same overlay, so the
      # two are the same package.
      ravnixPackages = import ./lib/ravnix-packages.nix { inherit lib; } {
        packagesDir = ./packages;
        toolsDir = ./tools;
      };
      # End of the packages.

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
      # The desktop, for the laptop shape: Sway and what runs on it; and the
      # glue that makes the two hosts one system. Every file and directory of
      # modules/desktop/ and of modules/glue/ is imported by that directory's
      # default.nix, so a module is added without editing this file
      # (lib/import-dir.nix). Each brings nixosModules.common, whose
      # home-manager, options and overlay those modules read; the key keeps a
      # host that lists both from getting two copies. The import goes one way:
      # common must never import desktop or glue (or a shape that does), and
      # nothing a shape imports (desktop, glue, workbench) may import a shape,
      # since a cycle overflows the stack, and keys do not stop it.
      nixosModules.desktop = {
        key = "ravnix/nixosModules.desktop";
        imports = [
          self.nixosModules.common
          ./modules/desktop
        ];
      };
      nixosModules.glue = {
        key = "ravnix/nixosModules.glue";
        imports = [
          self.nixosModules.common
          ./modules/glue
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

      # The laptop shape, huginn: the common module, the desktop, the glue,
      # the disk layout of hosts/laptop/disko.nix and the boot. A private flake
      # imports it with the hardware module of its laptop, such as the one
      # below. Each carries a key, so a second import adds nothing: the
      # common module that the shape, the desktop and the glue all bring is
      # loaded once.
      nixosModules.laptop = {
        key = "ravnix/nixosModules.laptop";
        imports = [
          (import ./hosts/laptop { inherit self inputs; })
          self.nixosModules.desktop
          self.nixosModules.glue
        ];
      };
      # The Lenovo IdeaPad Pro 5 16AHP9: the 780M, PRIME offload to the RTX
      # 4050 with runtime power management, its kernel parameters and initrd.
      nixosModules.hardware-ideapad-pro-5-16ahp9 = {
        key = "ravnix/nixosModules.hardware-ideapad-pro-5-16ahp9";
        imports = [ ./modules/hardware/ideapad-pro-5-16ahp9 ];
      };
      # The server's side: herdr's server, aerc, iamb, khal and vdirsyncer,
      # Podman and the toolchains, a copy of Nextcloud, Claude Code's Remote
      # Control (modules/workbench). It brings nixosModules.common along.
      nixosModules.workbench = {
        key = "ravnix/nixosModules.workbench";
        imports = [ (import ./modules/workbench { inherit self; }) ];
      };
      # The server shape, muninn: the common module, the workbench and the
      # glue, an ssh daemon that takes keys only, and Nix with flakes. A
      # private flake adds how it boots (hosts/server/default.nix).
      nixosModules.server = {
        key = "ravnix/nixosModules.server";
        imports = [ (import ./hosts/server { inherit self; }) ];
      };
      # The server as a virtual machine, imported beside the server shape:
      # one disk layout and boot for its three images (qcow2 for Proxmox,
      # VMDK, OVA, from system.build.images), and the home volume as a
      # second disk (hosts/server/images.nix).
      nixosModules.server-vm = {
        key = "ravnix/nixosModules.server-vm";
        imports = [ ./hosts/server/images.nix ];
      };

      packages.${system} =
        # A tool named claude-code is an error of lib/ravnix-packages.nix, which
        # packagesOf runs through.
        tools.packages // ravnixPackages.packagesOf pkgs // { claude-code = claudeCode; };
      # Every package and tool as pkgs.ravnix.<name>, so a module reads
      # pkgs.ravnix.<name> and never needs `self`. nixosModules.common applies
      # it, and applying it a second time (a host that lists it too) changes
      # nothing (lib/ravnix-packages.nix).
      overlays.default = ravnixPackages.overlay;
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
