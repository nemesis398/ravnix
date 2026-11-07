# Finds the checks in a tests directory: every <area>/<name>.nix in it is the
# check <area>-<name>. A file that does not end in .nix and anything in a
# subdirectory of an area (helpers, fixtures) is no check. A .nix file
# directly in the directory is an error, since it would never run, and so are
# two files that give the same name, never a silent override. Returns an
# attribute set from check names to file paths, and an empty one when the
# directory does not exist.
{ lib }:
dir:
let
  entries = builtins.readDir dir;
  areas = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
  strays = lib.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries
  );
  checksOf =
    area:
    let
      files = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
        builtins.readDir (dir + "/${area}")
      );
    in
    lib.mapAttrsToList (
      name: _: lib.nameValuePair "${area}-${lib.removeSuffix ".nix" name}" (dir + "/${area}/${name}")
    ) files;
  found = lib.concatMap checksOf areas;
  names = map (check: check.name) found;
  clashes = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
in
if !builtins.pathExists dir then
  { }
else if strays != [ ] then
  throw "tests/: ${lib.concatStringsSep ", " strays} would never run; a test goes in tests/AREA/NAME.nix"
else if clashes != [ ] then
  throw "tests/: more than one file gives the check name ${lib.concatStringsSep ", " clashes}"
else
  builtins.listToAttrs found
