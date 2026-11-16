# git-lfs on both shapes. A repository that uses LFS marks the filter
# `required`, so a clone without git-lfs on the PATH and the filter in git's
# configuration fails instead of checking out pointer files. The common module
# turns it on for both shapes, evaluated here on the laptop and on the server
# as home-manager sees them, and the filter is read from home-manager's git settings.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  user = (import ../../templates/default/me.nix).ravnix.user.username;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../templates/default/me.nix
      { system.stateVersion = "26.05"; }
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
    ];
  };
  server = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [ self.nixosModules.server ];
  };
  homeOf = s: s.config.home-manager.users.${user};

  each =
    name: s:
    let
      home = homeOf s;
      git = home.programs.git;
      filter = git.iniContent.filter.lfs or { };
    in
    lib.optional (!git.lfs.enable) "${name}: programs.git.lfs.enable is off"
    ++ lib.optional (!(filter.required or false)) "${name}: git's filter.lfs.required is not true, so a clone of an LFS repository would not fail loudly"
    ++ lib.optional (!(lib.hasInfix "git-lfs" (filter.clean or ""))) "${name}: git's filter.lfs.clean does not run git-lfs"
    ++ lib.optional (lib.getName git.lfs.package != "git-lfs") "${name}: the package behind the filter is ${lib.getName git.lfs.package}, not git-lfs";

  failures = each "huginn" laptop ++ each "muninn" server;
in
pkgs.runCommand "common-git-lfs" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
