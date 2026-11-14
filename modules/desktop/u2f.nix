# A tap on a security key instead of the password (ravnix.security.u2f,
# modules/options/security.nix). It ports the Fedora setup, where authselect's
# with-pam-u2f puts `auth sufficient pam_u2f.so cue` ahead of pam_unix in
# system-auth and password-auth: a tap or the password, everywhere the user
# authenticates.
#
# WHERE IT REACHES. security.pam.u2f.enable is the default of every PAM
# service's own u2f.enable, and NixOS puts the u2f rule ahead of pam_unix in
# each service with default rules: swaylock (its service: swaylock.nix), sudo,
# su, polkit-1 and login (the console), and the rest of them as on Fedora
# (passwd, chsh, chfn and their kin; run0 and a unit's PAMName carry the line
# but never authenticate through it), all but sshd and cups (below). greetd has
# no rules of its own; its stacks are substacks of `login`, so tuigreet runs
# login's u2f line first, and login's session part still starts the keyring
# (pam_gnome_keyring, greetd.nix).
# After a tap no password reaches pam_gnome_keyring's auth part, so only a
# passwordless login keyring opens by itself; with a password on it, the
# keyring asks for it the first time an application wants a secret. The early
# pam_unix that hands a typed password to the keyring comes after pam_u2f, so
# a password login still unlocks it. tests/desktop/u2f.nix reads every one of
# these files. su authenticates the account it switches to, so `su` to root
# looks for root's mapping in /root and, without one, asks for root's password
# as before; sudo authenticates the user who runs it.
#
# THE LINE. `sufficient`: a tap is enough, and a failure (no key, a key that is
# not enrolled, no ~/.config/Yubico/u2f_keys, no touch in time) is ignored and
# the next module, the password, decides. `cue`: pam_u2f shows "Please touch
# the FIDO authenticator." once it has found an enrolled key plugged in; with
# no such key it shows nothing and fails at once, so the password prompt
# follows without a wait. No pinverification on purpose: a password typed by
# habit into a PIN prompt counts as a wrong FIDO2 PIN, and eight of those
# block FIDO2 on the key for good. userpresence stays at the key's default,
# which for a YubiKey is a touch. Never nouserok or alwaysok: with
# `sufficient` either would turn a missing mapping into a login.
#
# THE MAPPING is pam_u2f's own per-user default, ~/.config/Yubico/u2f_keys
# (in $XDG_CONFIG_HOME when a process that is not setuid has it set), opened
# as the user. NixOS's authfile option takes only an absolute path, which
# would be one file for every user and read as root, so it is left unset.
# polkit's helper unit is given the home and the key's hidraw device by
# NixOS's polkit module when security.pam.u2f is on.
#
# THE ORIGIN is fixed (pam://ravnix unless the user picks another), and the
# appid with it: pamu2fcfg binds a credential to its origin, which defaults to
# pam:// and the host name, so a hostname-bound mapping breaks on a new or
# renamed machine. Enroll with the same value:
#
#   mkdir -p ~/.config/Yubico
#   pamu2fcfg -o pam://ravnix -i pam://ravnix > ~/.config/Yubico/u2f_keys
#
# WHAT IT COSTS. With the key plugged in, every prompt waits for the touch
# first, until the key gives up (its own timeout: pam_u2f and libfido2 set
# none), and only then asks for the password. To use the password with the key
# plugged in, pull the key or let it time out. A key plugged in after the
# password prompt has appeared is not asked again until the next attempt.
# tuigreet shows the cue as its message and hides the input while it waits;
# with --remember it starts that at once for the remembered user. swaylock
# asks PAM only after Enter, so there it is Enter and then the touch, and a
# password typed with the key plugged in is checked only after the key's
# timeout (swaylock.nix).
#
# Only the laptop: the desktop is not part of the server shape, which never
# has the key, so the option changes nothing there.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.security.u2f;
in
{
  config = lib.mkIf cfg.enable {
    security.pam.u2f = {
      enable = true;
      control = "sufficient";
      settings = {
        cue = true;
        origin = cfg.origin;
        appid = cfg.origin;
      };
    };

    # pamu2fcfg, for the enrollment. NixOS adds the package for its man pages
    # too; it is named here because the enrollment depends on it.
    environment.systemPackages = [ pkgs.pam_u2f ];

    # Not for a login from elsewhere: the key is at the laptop, and a remote
    # prompt would wait for a touch there, or take one meant for a prompt on
    # the laptop. sshd asks PAM for no password today (password and
    # keyboard-interactive logins are off), so this only keeps a later change
    # from opening that door.
    security.pam.services.sshd.u2f.enable = lib.mkIf config.services.openssh.enable false;

    # Nor for CUPS's web interface, which asks PAM from an HTTP request: the
    # cue goes into an HTTP error, and nobody at the laptop learns what a
    # blink is for. It listens on localhost alone today, so the request is a
    # local program's, the very case sudo's popup is for; a wider
    # listenAddresses would make it a remote one. The password still works.
    security.pam.services.cups.u2f.enable = lib.mkIf config.services.printing.enable false;
  };
}
