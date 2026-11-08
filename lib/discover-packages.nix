# Finds the packages in a packages directory: every <dir>/default.nix in it is
# the package <dir>, a function for callPackage. Returns an attribute set from
# package names to the path of that default.nix, and an empty one when the
# directory does not exist. The caller builds them: flake.nix gives each to
# the overlay's callPackage as pkgs.ravnix.<dir>, so a package that needs
# another takes `ravnix` and reads ravnix.<other>, and to its own for
# packages.<system>.<dir>.
#
# `taken` maps the names that packages.<system> already gives to who holds
# them, as in { claude-code = "Claude Code itself"; }. A package with one of
# these names is an error, since it would replace what the name stands for.
#
# A directory without default.nix, a .nix file or a symlink directly in the
# directory, and a name in `taken` are errors, never a silent skip or
# override. A file that is no .nix file (the README) and anything inside a
# package directory are no concern of the discovery.
{ lib }:
dir: taken:
let
  entries = builtins.readDir dir;
  dirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
  strays = lib.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries
  );
  links = lib.attrNames (lib.filterAttrs (_: type: type == "symlink") entries);
  withoutFile = lib.filter (d: !builtins.pathExists (dir + "/${d}/default.nix")) dirs;
  held = lib.filter (d: taken ? ${d}) dirs;
in
if !builtins.pathExists dir then
  { }
else if strays != [ ] then
  throw "packages/: ${lib.concatStringsSep ", " strays} is no package; a package is a directory packages/NAME with a default.nix"
else if links != [ ] then
  throw "packages/: ${lib.concatStringsSep ", " links} is a symlink, and no package; a package is a directory packages/NAME with a default.nix"
else if withoutFile != [ ] then
  throw "packages/: ${lib.concatStringsSep ", " withoutFile} has no default.nix; every package directory needs one (packages/README.md)"
else if held != [ ] then
  throw "packages/: ${
    lib.concatMapStringsSep ", " (d: "${d} would be packages.${d}, which is ${taken.${d}}") held
  }; rename the package"
else
  lib.genAttrs dirs (d: dir + "/${d}/default.nix")
