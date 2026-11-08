# The convention every package of ravnix relies on: each packages/NAME/
# default.nix is the package NAME, a function for callPackage
# (lib/discover-packages.nix), and each tools/NAME the tool NAME. The flake
# gives them to packages.<system> and, through lib/ravnix-packages.nix, to the
# overlay as pkgs.ravnix.NAME. This test runs the discovery and the overlay on
# the fixture trees in ./fixtures and builds what they find, then checks that
# the flake and nixosModules.common wire the real packages/ and tools/ in.
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
  discoverTools = import ../../lib/discover-tools.nix { inherit lib; };
  ravnixPackages = import ../../lib/ravnix-packages.nix { inherit lib; };
  discoverFile = ../../lib/discover-packages.nix;
  fixtures = ./fixtures/packages;
  refusals = import ./helpers/refusals.nix { inherit lib; };

  tree = discover (fixtures + "/tree") { };
  empty = discover (fixtures + "/empty") { };
  missing = discover (fixtures + "/no-such-directory") { };
  # The overlay of the flake, made from the fixture packages and no tools:
  # every one is called with the overlay's final, and finds the others under
  # ravnix.
  fixtureOverlay =
    (ravnixPackages {
      packagesDir = fixtures + "/tree";
      toolsDir = fixtures + "/no-such-directory";
    }).overlay;
  built = (pkgs.extend fixtureOverlay).ravnix;

  # The same expressions in a fresh nix-instantiate, for the messages.
  expression = tree: taken: ''
    let
      lib = import ${inputs.nixpkgs}/lib;
    in
    builtins.attrNames (import ${discoverFile} { inherit lib; } ${fixtures}/${tree} ${taken})
  '';
  packagesExpression = packagesDir: toolsDir: ''
    let
      lib = import ${inputs.nixpkgs}/lib;
    in
    builtins.attrNames
      (import ${self}/lib/ravnix-packages.nix { inherit lib; } {
        packagesDir = ${packagesDir};
        toolsDir = ${toolsDir};
      }).files
  '';

  # The flake's real packages/ and tools/: whatever is in them, the flake
  # gives it out. Only the names of the tools are read, which needs none of
  # the arguments that building them does.
  real = lib.attrNames (discover ../../packages { });
  toolNames = lib.attrNames (discoverTools ../../tools { }).packages;
  everything = lib.sort lib.lessThan (real ++ toolNames);
  overlaid = pkgs.extend self.overlays.default;
  twice = overlaid.extend self.overlays.default;
  sameTool = name: overlaid.ravnix.${name}.drvPath == self.packages.${system}.${name}.drvPath;

  hostModules = import ./helpers/host-modules.nix { inherit lib; };
  host =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.common ] ++ modules;
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
        modules = hostModules ++ [
          self.nixosModules.common
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
    # The flake wires the real packages/ and tools/ in, however many there are.
    ++ lib.optional (
      toolNames == [ ]
    ) "tools/ holds no tool, so the check that tools reach pkgs.ravnix would check nothing"
    ++
      lib.optional (lib.attrNames overlaid.ravnix != everything)
        "pkgs.ravnix has ${toString (lib.attrNames overlaid.ravnix)}, packages/ and tools/ have ${toString everything}"
    ++
      lib.optional (lib.attrNames twice.ravnix != everything)
        "the overlay applied twice gives ${toString (lib.attrNames twice.ravnix)}, not ${toString everything}"
    ++ lib.optional (
      !lib.all (name: self.packages.${system} ? ${name}) (real ++ toolNames)
    ) "packages.${system} lacks a package of packages/ or a tool"
    ++ lib.optional (!self.packages.${system} ? claude-code) "packages.${system} lost claude-code"
    # claude-code stays out of pkgs.ravnix: it is the download the gate verifies,
    # and packages.claude-code is its only route.
    ++ lib.optional (overlaid.ravnix ? claude-code) "pkgs.ravnix holds claude-code"
    ++ lib.optional (
      !lib.all (name: self.packages.${system}.${name} == overlaid.ravnix.${name}) real
    ) "a package of packages.${system} is not the one of pkgs.ravnix"
    ++
      lib.optional (!lib.all sameTool toolNames)
        "a tool of packages.${system} is not the derivation of the same tool in pkgs.ravnix: ${
          toString (lib.filter (name: !sameTool name) toolNames)
        }"
    ++ lib.optional (
      !lib.all (name: twice.ravnix.${name}.drvPath == overlaid.ravnix.${name}.drvPath) toolNames
    ) "applying the overlay twice changed a tool"
    # nixosModules.common brings the overlay, so a host and its home-manager
    # configuration have pkgs.ravnix, and a host that applies it too changes
    # nothing.
    ++ lib.optional (
      !plain ? ravnix || lib.attrNames plain.ravnix != everything
    ) "a host with nixosModules.common has no pkgs.ravnix of packages/ and tools/"
    ++ lib.optional (
      !applied ? ravnix || lib.attrNames applied.ravnix != everything
    ) "a host that applies the overlay again no longer has pkgs.ravnix"
    ++ lib.optional (
      !readOnlyPlain.success || readOnlyPlain.value ? ravnix
    ) "a host with read-only pkgs and nixosModules.common does not evaluate, or invents pkgs.ravnix"
    ++
      lib.optional
        (!readOnlyOverlaid.success || lib.attrNames readOnlyOverlaid.value.ravnix != everything)
        "a host with read-only pkgs that has the overlay does not have pkgs.ravnix of packages/ and tools/";
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
            name = "a package named after a tool of this repository";
            expression = packagesExpression "${fixtures}/real-tool" "${self}/tools";
            messages = [
              "packages/: claude-code-verify would be packages.claude-code-verify, which is the tool tools/claude-code-verify"
            ];
          }
          {
            name = "a tool named claude-code";
            expression = packagesExpression "${fixtures}/tree" "${./fixtures/tools}";
            messages = [
              "tools/claude-code is a tool, and packages.claude-code is Claude Code itself; rename the tool"
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
