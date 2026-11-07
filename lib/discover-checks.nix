# Finds the checks in a tests directory: every <area>/<name>.nix in it is the
# check <area>-<name>. A file directly in the directory, a file that does not
# end in .nix and anything in a subdirectory of an area (helpers, fixtures)
# is no check. Two files that give the same name are an error, never a silent
# override. Returns an attribute set from check names to file paths, and an
# empty one when the directory does not exist.
{ lib }:
dir:
let
  areas = lib.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir));
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
else if clashes != [ ] then
  throw "tests/: more than one file gives the check name ${lib.concatStringsSep ", " clashes}"
else
  builtins.listToAttrs found
