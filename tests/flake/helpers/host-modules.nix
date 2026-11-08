# What a NixOS configuration needs besides ravnix's own modules to be
# evaluated in a test: the template's me.nix, and a state version, a boot
# loader and a root file system. Being in a subdirectory of an area, this file
# is no check itself (lib/discover-checks.nix).
#
#   inputs.nixpkgs.lib.nixosSystem {
#     inherit system;
#     modules = import ./helpers/host-modules.nix { inherit lib; } ++ [ ... ];
#   }
{ lib }:
[
  ../../../templates/default/me.nix
  {
    system.stateVersion = "26.05";
    # The template's values are placeholders and warn about it (the options
    # tests check that they do); here each warning would be printed again by
    # every evaluation.
    warnings = lib.mkForce [ ];
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
  }
]
