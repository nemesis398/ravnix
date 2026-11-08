# Finds the modules in a module directory (modules/desktop, modules/glue):
# every NAME.nix directly in it, and every NAME/default.nix, other than the
# directory's own default.nix, which is the module that imports them. Returns
# their paths in the order of their names, to be the `imports` of that module.
# A subdirectory without a default.nix holds data for a module (sway/config),
# and a file that is no .nix file is none; neither is imported.
#
# `label` is the directory's path in the repository, as in "modules/desktop",
# which the error message names.
#
# A symlink directly in the directory is an error, never a silent skip: what it
# points at may be a module or not, and the import must not depend on which.
{ lib }:
label: dir:
let
  entries = builtins.readDir dir;
  links = lib.attrNames (lib.filterAttrs (_: type: type == "symlink") entries);
  isModule =
    name: type:
    if type == "regular" then
      lib.hasSuffix ".nix" name && name != "default.nix"
    else
      type == "directory" && builtins.pathExists (dir + "/${name}/default.nix");
in
if links != [ ] then
  throw "${label}/: ${lib.concatStringsSep ", " links} is a symlink; a module is a file ${label}/NAME.nix or a directory ${label}/NAME with a default.nix"
else
  map (name: dir + "/${name}") (lib.attrNames (lib.filterAttrs isModule entries))
