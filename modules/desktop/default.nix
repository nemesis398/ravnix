# The desktop, for NixOS: Sway and what runs on it, which the laptop shape
# imports as nixosModules.desktop. This module imports the rest, so a module is
# added without editing a shared file: every NAME.nix directly in this
# directory and every NAME/default.nix is imported, in the order of their
# names (lib/import-dir.nix). A subdirectory without a default.nix holds data
# for a module (sway/config) and is not imported. A symlink here is an error.
#
# Each of those files is a NixOS module. What belongs to the user's
# home-manager configuration goes through home-manager.sharedModules, which
# nixosModules.common sets up for every user it creates; nixosModules.desktop
# brings nixosModules.common along, so a file can read what it provides:
#
#   { ... }:
#   {
#     home-manager.sharedModules = [ { programs.foot.enable = true; } ];
#   }
#
# A package or tool that ravnix builds is pkgs.ravnix.NAME (packages/NAME,
# tools/NAME), in the NixOS module and in the home-manager one.
{ lib, ... }:
{
  imports = import ../../lib/import-dir.nix { inherit lib; } "modules/desktop" ./.;
}
