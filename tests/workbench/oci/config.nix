# The server shape in its container form, as a private flake builds it, with
# the template's placeholder values and nothing of anyone's: the image that
# tests/workbench/oci.nix inspects, and that tests/workbench/oci.md ran on a
# Docker host.
#
# Not set here, because a private flake sets them: the keys that may log in
# (a placeholder, which is no key), the time zone and the host name.
{
  self,
  inputs,
  lib,
  system,
  # More modules, for a test that needs the shape to be set another way.
  extraModules ? [ ],
  ...
}:
inputs.nixpkgs.lib.nixosSystem {
  modules = [
    self.nixosModules.server
    self.nixosModules.server-oci
    ../../../templates/default/me.nix
  ]
  ++ extraModules
  ++ [
    (
      { config, ... }:
      {
        nixpkgs.hostPlatform = system;
        system.stateVersion = "26.05";

        # The template's values are placeholders and warn about it (the
        # options tests check that they do); here the warnings are noise.
        warnings = lib.mkForce [ ];

        # One language and not the toolchain of each: the image is the same
        # in every other way, and a test image should not be ten gigabytes
        # (tests/common/nvim.nix runs the editor with every language).
        ravnix.editor.languages = lib.mkForce [ "nix" ];

        # A key that is only the shape of one: the test logs in with a key
        # it makes itself.
        users.users.${config.ravnix.user.username}.openssh.authorizedKeys.keys = [
          config.ravnix.user.signingKey
        ];
      }
    )
  ];
}
