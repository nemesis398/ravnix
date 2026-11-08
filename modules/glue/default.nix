# The glue, for NixOS: the pieces that make the two hosts one system, which a
# host imports as nixosModules.glue. This module imports the rest, so a piece
# is added without editing a shared file: every NAME.nix directly in this
# directory and every NAME/default.nix is imported, in the order of their
# names (lib/import-dir.nix). A subdirectory without a default.nix holds data
# for a piece and is not imported. A symlink here is an error.
#
# Each of those files is a NixOS module. What belongs to the user's
# home-manager configuration goes through home-manager.sharedModules, which
# nixosModules.common sets up for every user it creates:
#
#   { ... }:
#   {
#     home-manager.sharedModules = [ { programs.foot.enable = true; } ];
#   }
#
# A package that ravnix builds is pkgs.ravnix.NAME (packages/NAME), in the
# NixOS module and in the home-manager one.
{ lib, ... }:
{
  imports = import ../../lib/import-dir.nix { inherit lib; } "modules/glue" ./.;
}
