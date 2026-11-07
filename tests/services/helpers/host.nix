# Evaluates a NixOS host made of ravnix's options, the template's me.nix and
# the given modules, so a check can read what a service module puts into the
# host's configuration. The host is evaluated, never built. Being in a
# subdirectory of an area, this file is no check itself
# (lib/discover-checks.nix).
#
#   host = import ./helpers/host.nix { inherit inputs lib self; };
#   (host [ module ... ]).config   the host's configuration
#   (host [ module ... ]).failed   the messages of its failed assertions
{
  inputs,
  lib,
  self,
}:
modules:
let
  evaluated = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.options
      ../../../templates/default/me.nix
      {
        # Just enough of a host for its configuration to evaluate.
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = lib.trivial.release;
      }
    ]
    ++ modules;
  };
in
{
  inherit (evaluated) config;
  failed = map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions);
}
