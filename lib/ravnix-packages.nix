# What ravnix puts under pkgs.ravnix, and the overlay that does it: the
# packages of packages/ (lib/discover-packages.nix) and the Odin tools of
# tools/ (lib/discover-tools.nix), each as pkgs.ravnix.NAME. A module reads
# pkgs.ravnix.NAME and never needs `self`, which an auto-imported module of
# modules/desktop or modules/glue does not get.
#
#   ravnixPackages { packagesDir; toolsDir; }
#   => { files; overlay; packagesOf; }
#
# `files` maps each package's name to its default.nix, after the checks below,
# and `overlay` is overlays.default of the flake. The overlay sets the one
# attribute ravnix, to the same value each time, so applying it a second time
# changes nothing. `packagesOf pkgs` is the packages of packages/ (not the
# tools, which the flake builds on its own) as a host that applies the overlay
# to `pkgs` builds them, for packages.<system>.
#
# Everything is built with the overlay's `final`, so the package set of whoever
# applies the overlay decides what the packages are made from, and a package
# that needs another takes `ravnix` and reads ravnix.OTHER. The tools get the
# toolchain of that set too: with a nixpkgs that follows ravnix's, as the
# template's does, the derivation is the one packages.<system>.NAME is, which
# is the one the tool's checks vouch for.
#
# claude-code is not under pkgs.ravnix. packages.claude-code is the download
# that the gate verifies against Anthropic's release manifest, for the version
# in flake.lock, and a second route to it would be one that the verification
# and the update timer do not control. A tool of that name is an error, since
# it would be packages.claude-code, and a package or a tool whose name another
# holds is too (lib/discover-packages.nix has the messages).
{ lib }:
{ packagesDir, toolsDir }:
let
  discoverTools = import ./discover-tools.nix { inherit lib; };
  discoverPackages = import ./discover-packages.nix { inherit lib; };
  odin = pkgs: import ./odin.nix { inherit pkgs lib; };

  # The names of the tools are all that is needed here, and they come from the
  # directories, so the tools are discovered without the arguments that
  # building them takes; nothing evaluates a tool.
  toolNames = lib.attrNames (discoverTools toolsDir { }).packages;
  taken = lib.genAttrs toolNames (name: "the tool tools/${name}") // {
    claude-code = "Claude Code itself";
  };

  files =
    if lib.elem "claude-code" toolNames then
      throw "tools/claude-code is a tool, and packages.claude-code is Claude Code itself; rename the tool"
    else
      discoverPackages packagesDir taken;
in
rec {
  inherit files;
  packagesOf = pkgs: lib.getAttrs (lib.attrNames files) (pkgs.extend overlay).ravnix;
  overlay = final: _prev: {
    ravnix =
      (discoverTools toolsDir {
        inherit (odin final) buildOdinTool;
        pkgs = final;
        inherit lib;
      }).packages
      // lib.mapAttrs (_: file: final.callPackage file { }) files;
  };
}
