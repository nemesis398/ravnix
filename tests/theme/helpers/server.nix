# The server shape, evaluated and never built, with the template's me.nix and
# the accent given: the way a check reads what muninn's modules write for the
# user. Being in a subdirectory of an area, this file is no check itself
# (lib/discover-checks.nix).
#
#   server = import ./helpers/server.nix { inherit self inputs lib; };
#   (server "teal").config                 the user's home-manager configuration
{
  self,
  inputs,
  lib,
  ...
}:
let
  me = import ../../../templates/default/me.nix;
  user = me.ravnix.user.username;
in
accent: extra:
let
  host = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.server
      ../../../templates/default/me.nix
      {
        # Just enough of a host for its configuration to evaluate.
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "26.05";
        warnings = lib.mkForce [ ];
        ravnix.editor.languages = lib.mkForce [ "nix" ];
        ravnix.theme.accent = lib.mkForce accent;
      }
      extra
    ];
  };
in
{
  inherit host;
  config = host.config.home-manager.users.${user};
}
