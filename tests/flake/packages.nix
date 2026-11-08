# The convention every package of ravnix relies on: each packages/NAME/
# default.nix is the package NAME, a function for callPackage
# (lib/discover-packages.nix), and flake.nix gives it to packages.<system> and
# to the overlay as pkgs.ravnix.NAME. This test runs the discovery on the
# fixture trees in ./fixtures/packages and builds what it finds, then checks
# that the flake and nixosModules.common wire the real packages/ in.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  discover = import ../../lib/discover-packages.nix { inherit lib; };
  discoverFile = ../../lib/discover-packages.nix;
  fixtures = ./fixtures/packages;
  refusals = import ./helpers/refusals.nix { inherit lib; };

  tree = discover (fixtures + "/tree") { };
  empty = discover (fixtures + "/empty") { };
  missing = discover (fixtures + "/no-such-directory") { };
  # What flake.nix does with the packages: every one is called with the
  # overlay's final, and finds the others under ravnix.
  overlay = final: _: { ravnix = lib.mapAttrs (_: file: final.callPackage file { }) tree; };
  built = (pkgs.extend overlay).ravnix;

  # The same expression in a fresh nix-instantiate, for the messages.
  expression = tree: taken: ''
    let
      lib = import ${inputs.nixpkgs}/lib;
    in
    builtins.attrNames (import ${discoverFile} { inherit lib; } ${fixtures}/${tree} ${taken})
  '';

  # The flake's real packages/: whatever is in it, the flake gives it out.
  real = lib.attrNames (discover ../../packages { });
  overlaid = pkgs.extend self.overlays.default;
  twice = overlaid.extend self.overlays.default;

  me = ../../templates/default/me.nix;
  base = [
    self.nixosModules.common
    me
    {
      system.stateVersion = "26.05";
      warnings = lib.mkForce [ ];
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
    }
  ];
  host =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = base ++ modules;
    }).pkgs;
  plain = host [ ];
  applied = host [ { nixpkgs.overlays = [ self.overlays.default ]; } ];

  # A configuration whose pkgs is read-only, as a NixOS VM test node is
  # (tests/common/shell.nix): no module may define nixpkgs.overlays there,
  # nixosModules.common included, so whoever gives the pkgs applies the
  # overlay.
  readOnly =
    pkgs':
    builtins.tryEval (
      (inputs.nixpkgs.lib.nixosSystem {
        modules = base ++ [
          "${inputs.nixpkgs}/nixos/modules/misc/nixpkgs/read-only.nix"
          { nixpkgs.pkgs = pkgs'; }
        ];
      }).pkgs
    );
  readOnlyPlain = readOnly pkgs;
  readOnlyOverlaid = readOnly overlaid;

  failures =
    lib.optional
      (
        builtins.attrNames tree != [
          "alpha"
          "beta"
        ]
      )
      "expected the packages alpha and beta (README.md is no package, helper.nix inside beta is its own), found: ${toString (builtins.attrNames tree)}"
    ++ lib.optional (
      tree ? alpha && tree.alpha != fixtures + "/tree/alpha/default.nix"
    ) "the package alpha does not point at alpha/default.nix"
    ++ lib.optional (empty != { }) "a packages directory with only a README gave packages"
    ++ lib.optional (missing != { }) "a missing packages directory gave packages"
    ++ lib.optional (
      !lib.all lib.isDerivation (lib.attrValues built)
    ) "a discovered package is no derivation"
    # The flake wires the real packages/ in, however many there are.
    ++ lib.optional (
      lib.attrNames overlaid.ravnix != real
    ) "pkgs.ravnix has ${toString (lib.attrNames overlaid.ravnix)}, packages/ has ${toString real}"
    ++ lib.optional (
      lib.attrNames twice.ravnix != real
    ) "the overlay applied twice gives ${toString (lib.attrNames twice.ravnix)}, not ${toString real}"
    ++ lib.optional (
      !lib.all (name: self.packages.${system} ? ${name}) real
    ) "packages.${system} lacks a package of packages/"
    ++ lib.optional (!self.packages.${system} ? claude-code) "packages.${system} lost claude-code"
    ++ lib.optional (
      !lib.all (name: self.packages.${system}.${name} == overlaid.ravnix.${name}) real
    ) "a package of packages.${system} is not the one of pkgs.ravnix"
    # nixosModules.common brings the overlay, so a host and its home-manager
    # configuration have pkgs.ravnix, and a host that applies it too changes
    # nothing.
    ++ lib.optional (
      !plain ? ravnix || lib.attrNames plain.ravnix != real
    ) "a host with nixosModules.common has no pkgs.ravnix of packages/"
    ++ lib.optional (
      !applied ? ravnix || lib.attrNames applied.ravnix != real
    ) "a host that applies the overlay again no longer has pkgs.ravnix"
    ++ lib.optional (
      !readOnlyPlain.success || readOnlyPlain.value ? ravnix
    ) "a host with read-only pkgs and nixosModules.common does not evaluate, or invents pkgs.ravnix"
    ++ lib.optional (
      !readOnlyOverlaid.success || lib.attrNames readOnlyOverlaid.value.ravnix != real
    ) "a host with read-only pkgs that has the overlay does not have pkgs.ravnix of packages/";
in
pkgs.runCommand "flake-packages"
  {
    nativeBuildInputs = [
      pkgs.nix
      pkgs.gnugrep
    ];
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        test "$(cat ${built.alpha})" = alpha
        # A sibling is found under ravnix.
        test "$(cat ${built.beta})" = "beta after alpha"

        ${refusals [
          {
            name = "x.nix directly in packages/";
            expression = expression "stray" "{ }";
            messages = [
              "packages/: x.nix is no package"
              "packages/NAME with a default.nix"
            ];
          }
          {
            name = "a package directory without default.nix";
            expression = expression "no-default" "{ }";
            messages = [
              "packages/: broken has no default.nix"
              "(packages/README.md)"
            ];
          }
          {
            name = "a symlink in packages/";
            expression = expression "symlink" "{ }";
            messages = [
              "packages/: beta is a symlink, and no package"
            ];
          }
          {
            name = "a package named after a tool";
            expression = expression "tool-clash" ''{ hello = "the tool tools/hello"; }'';
            messages = [
              "packages/: hello would be packages.hello, which is the tool tools/hello"
              "rename the package"
            ];
          }
          {
            name = "a package named claude-code";
            expression = expression "reserved" ''{ claude-code = "Claude Code itself"; }'';
            messages = [
              "packages/: claude-code would be packages.claude-code, which is Claude Code itself"
            ];
          }
        ]}
        touch $out
      ''
  )
