# Finds the Odin tools in a tools directory: every <dir>/default.nix in it is
# the tool <dir>, a function of { buildOdinTool, pkgs, lib, ... } that
# returns buildOdinTool { name = "<dir>"; ... }. A directory whose name starts
# with "_" is the tool named without it, built and checked but given no
# package: that is the template. Returns { packages; checks; }, with the
# package <name> and the checks <name>-tests and <name>-bench of each tool,
# and both empty when the directory does not exist.
#
# A tool directory without default.nix, a .nix file or a symlink directly
# in the directory, and two directories that give one name are errors,
# never a silent skip or override. The names come from the directories, so one
# broken tool fails its own checks and leaves the others' evaluable.
{ lib }:
dir: args:
let
  entries = builtins.readDir dir;
  dirs = lib.attrNames (lib.filterAttrs (_: type: type == "directory") entries);
  strays = lib.attrNames (
    lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) entries
  );
  links = lib.attrNames (lib.filterAttrs (_: type: type == "symlink") entries);
  withoutFile = lib.filter (d: !builtins.pathExists (dir + "/${d}/default.nix")) dirs;
  nameOf = lib.removePrefix "_";
  names = map nameOf dirs;
  clashes = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);

  load =
    d:
    let
      tool = import (dir + "/${d}/default.nix") args;
    in
    if !(builtins.isAttrs tool && tool ? name && tool ? package && tool ? checks) then
      throw "tools/${d}/default.nix does not return buildOdinTool { ... }"
    else if tool.name != nameOf d then
      throw "tools/${d}/default.nix names its tool ${tool.name}; a tool takes its directory's name, ${nameOf d}"
    else
      tool;
  tools = lib.genAttrs dirs load;

  packages = lib.listToAttrs (
    map (d: lib.nameValuePair (nameOf d) tools.${d}.package) (
      lib.filter (d: !lib.hasPrefix "_" d) dirs
    )
  );
  checks = lib.listToAttrs (
    lib.concatMap (
      d:
      map (kind: lib.nameValuePair "${nameOf d}-${kind}" tools.${d}.checks."${nameOf d}-${kind}") [
        "tests"
        "bench"
      ]
    ) dirs
  );
in
if !builtins.pathExists dir then
  {
    packages = { };
    checks = { };
  }
else if strays != [ ] then
  throw "tools/: ${lib.concatStringsSep ", " strays} is no tool; a tool is a directory tools/NAME with a default.nix"
else if links != [ ] then
  throw "tools/: ${lib.concatStringsSep ", " links} is a symlink, and no tool; a tool is a directory tools/NAME with a default.nix"
else if withoutFile != [ ] then
  throw "tools/: ${lib.concatStringsSep ", " withoutFile} has no default.nix; every tool directory needs one (tools/README.md)"
else if clashes != [ ] then
  throw "tools/: more than one directory gives the tool name ${lib.concatStringsSep ", " clashes}"
else
  { inherit packages checks; }
