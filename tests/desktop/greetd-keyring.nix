# The login keyring is unlocked by the login itself (modules/desktop/greetd.nix).
#
# Helium keeps its cookie key in the Secret Service with
# `--password-store=gnome-libsecret`, and gnome-keyring serves it. The keyring
# is encrypted with the login password, so it opens only when the greeter's PAM
# stack hands the password to pam_gnome_keyring. Without that the keyring stays
# locked and Helium asks for its password at every start.
#
# What this reads is the PAM stack greetd runs on an evaluated host: the module
# alone and the laptop shape. NixOS's greetd service has no rules of its own, it
# includes the `login` service in all four stacks, so the keyring has to be in
# `login`: in auth (it takes the password), in session (it starts the daemon and
# unlocks) and in password (it changes the keyring's password with the user's).
# Setting enableGnomeKeyring on the greetd service itself would change nothing.
# The swaylock service must not carry the keyring: that one only checks the
# password. A third host has the Secret Service switched off, and the stack must
# still carry the unlock.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };

  desktop = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [ self.nixosModules.desktop ];
  };
  laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      me
      { system.stateVersion = "26.05"; }
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
    ];
  };
  # The Secret Service switched off by a host: the unlock in the login stack
  # must not hang on it (it is harmless there, the daemon is just not served).
  quiet = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [
      self.nixosModules.desktop
      { services.gnome.gnome-keyring.enable = lib.mkForce false; }
    ];
  };

  textOf = host: service: host.config.security.pam.services.${service}.text;

  # The lines of one PAM stack of a service, as the text of /etc/pam.d/NAME.
  keyringIn =
    host: service: type:
    lib.filter (l: lib.hasPrefix "${type} " l && lib.hasInfix "pam_gnome_keyring.so" l) (
      lib.splitString "\n" (textOf host service)
    );
  # greetd reaches `login` in this stack, by include or by substack.
  reachesLogin =
    host: type:
    lib.any (l: lib.hasPrefix "${type} " l && lib.hasInfix " login " l) (
      lib.splitString "\n" (textOf host "greetd")
    );

  types = [
    "auth"
    "session"
    "password"
  ];

  failures = lib.concatMap (
    {
      name,
      host,
      serves,
    }:
    lib.concatMap (
      type:
      lib.optional (!reachesLogin host type) "${name}: greetd's ${type} does not reach the login service"
      ++ lib.optional (keyringIn host "login" type == [ ]) "${name}: login's ${type} has no pam_gnome_keyring"
    ) types
    ++ lib.optional (
      lib.any (t: keyringIn host "swaylock" t != [ ]) types
    ) "${name}: swaylock unlocks the keyring too"
    ++ lib.optional (
      serves && !host.config.services.gnome.gnome-keyring.enable
    ) "${name}: gnome-keyring is not enabled"
  ) [
    {
      name = "desktop";
      host = desktop;
      serves = true;
    }
    {
      name = "laptop";
      host = laptop;
      serves = true;
    }
    {
      name = "desktop without the Secret Service";
      host = quiet;
      serves = false;
    }
  ];
in
pkgs.runCommand "desktop-greetd-keyring" { } ''
  ${
    if failures == [ ] then
      "echo 'greetd unlocks the login keyring in auth, session and password' > $out"
    else
      ''
        cat >&2 <<'EOT'
        ${lib.concatStringsSep "\n" failures}
        EOT
        exit 1
      ''
  }
''
