# Evaluates home-manager with ravnix's common module the way a host's
# glue does, without a host: the options and the theme beside it, and the
# template's me.nix as the user. Being in a subdirectory of an area, this
# file is no check itself (lib/discover-checks.nix).
#
#   hm = import ./helpers/hm.nix { inherit self inputs pkgs lib; };
#   (hm [ module ... ]).config      the home-manager configuration
{
  self,
  inputs,
  pkgs,
  ...
}:
modules:
inputs.home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    self.homeModules.options
    self.homeModules.theme
    self.homeModules.common
    ../../../templates/default/me.nix
    { home.stateVersion = "26.05"; }
  ]
  ++ modules;
}
