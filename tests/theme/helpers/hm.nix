# Evaluates home-manager with ravnix's theme module the way a user's
# configuration does, without a host. Being in a subdirectory of an area, this
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
    self.homeModules.theme
    {
      home = {
        username = "alice";
        homeDirectory = "/home/alice";
        stateVersion = "26.05";
      };
    }
  ]
  ++ modules;
}
