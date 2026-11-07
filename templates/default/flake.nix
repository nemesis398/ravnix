# Your private ravnix flake: the values that make ravnix yours. Keep it in a
# private repository of your own; it holds names and addresses, never a
# secret (those come from your Bitwarden through rbw at runtime).
#
# Fill in me.nix, adjust backups.toml and dictionary.txt, then run
#   nix flake check
{
  description = "My private ravnix flake: my personal values";

  inputs = {
    ravnix = {
      url = "github:nemesis398/ravnix";
      # ravnix uses the Claude Code input declared below, so its revision
      # lives in this flake's lock and an update touches only that line.
      inputs.claude-code.follows = "claude-code";
    };
    # The nixpkgs that ravnix locks and tests with. Updating ravnix
    # (`nix flake update ravnix`) moves it along.
    nixpkgs.follows = "ravnix/nixpkgs";
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { ravnix, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;

      # me.nix against ravnix's options, with the assertions a host build
      # checks: a typo in an option name, a malformed value or a missing one
      # fails here.
      me = lib.evalModules {
        modules = [
          lib.genericModules.assertions
          ravnix.nixosModules.options
          ./me.nix
        ];
      };
      failed = map (a: a.message) (lib.filter (a: !a.assertion) me.config.assertions);
    in
    {
      # The two hosts join here once ravnix ships their shapes: huginn, the
      # laptop, and muninn, the server, each built from ravnix's host shape
      # and ./me.nix.

      checks.${system} =
        let
          hasDenyList = builtins.pathExists ./deny-list.txt;
        in
        {
          # Every value evaluates, and each one that is still a documentation
          # placeholder (an example.org name, a 192.0.2.x address) is named in
          # a warning. So is a deny list that ravnix.dev.denyList promises
          # and this flake does not track.
          me =
            if failed != [ ] then
              throw "me.nix:\n${lib.concatMapStrings (m: "- ${m}\n") failed}"
            else
              lib.warnIf (me.config.ravnix.dev.denyList != null && !hasDenyList)
                "ravnix.dev.denyList is set, but this flake tracks no deny-list.txt, so checks.public-boundary is off: git add deny-list.txt."
                (
                  lib.foldr lib.warn (builtins.deepSeq me.config.ravnix (
                    pkgs.runCommand "me" { } "touch $out"
                  )) me.config.warnings
                );
        }
        # If you contribute to ravnix, keep a deny-list.txt of your own values
        # here (one per line, `#` for comments) and `git add deny-list.txt`: a
        # flake sees only the files git tracks. This check then proves that
        # none of them is in the ravnix you build from.
        // lib.optionalAttrs hasDenyList {
          public-boundary = pkgs.runCommand "public-boundary" { nativeBuildInputs = [ pkgs.ripgrep ]; } ''
            cd ${ravnix}
            bash ${ravnix}/scripts/check-public.sh ${./deny-list.txt} .
            touch $out
          '';
        };
    };
}
