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
# SUDO ASKS ON THE SCREEN FIRST. sudo runs without a terminal too: a program
# of the user's, or a command the server sends over the laptop-access link
# (modules/glue/laptop-access.nix), which runs any command as the user. There
# the cue goes to the caller's standard error, nobody at the laptop sees it,
# and the key's blink looks like the blink of a git push: one touch out of
# habit and the command is root. So sudo's auth stack has one line before
# pam_u2f, pam_exec of ravnix-tap-ask (tools/ravnix-tap-ask), as root:
#
#   auth [success=ignore default=1] pam_exec.so quiet quiet_log seteuid ravnix-tap-ask
#
# A sudo over ssh, which on the laptop is the server's link, is refused at
# once: no popup, no tap, one line in the journal. The tool tells it by the
# login session logind put sudo in, which the caller cannot change from
# inside it, then by an sshd ancestor and SSH_CONNECTION. For a local sudo,
# when the user has a mapping and a FIDO key is plugged in, the tool shows a
# fuzzel popup on the socket the session's own Sway listens on, run as the
# user through setpriv, never as root: the command line (a longer one than
# fits gets no popup), the user, and a terminal or the program that ran it.
# Allow (exit 0) goes on to pam_u2f, and the key blinks. Deny, Esc, no answer
# in 30 s, an Allow sooner than a second (typed through), a locked screen, no
# session, or any failure exits non-zero, which jumps over the one pam_u2f
# line: the rest of the stack runs as before, so a terminal sudo asks for the
# password, and a sudo without a terminal fails because it cannot ask. A jump
# changes no result of the stack, so a failure of the tool can only skip the
# tap, never grant anything. Only sudo has the line: swaylock and tuigreet
# are the laptop's own screen, and polkit is below.
#
# POLKIT has no popup of ours. pkexec over the link would otherwise get one:
# with a terminal (script), pkexec runs its own text agent, polkit-1's stack
# runs pam_u2f, and the cue goes to the link. So polkit refuses, before any
# authentication, a subject outside a local, active session (an ssh login
# has no seat, so it is not local); root is left alone, since it gains
# nothing. A local request is one from the user's session on the laptop,
# where Sway's polkit agent shows its dialog, the action named, before the
# key blinks. polkit counts a process outside any session (a unit of the
# user's systemd) as the user's display session, so such a request is local.
#
# WHAT THIS DOES NOT DO. The popup and the refusals are consent against a
# mistaken touch, not a defense against a hostile link. The link runs any
# command as the user, and a program that runs as the user can leave the ssh
# session (systemd-run --user, swaymsg exec) so that its sudo or pkexec is a
# local one, answer the popup itself (Sway lets any client type, as wtype
# does), and blink the key for a sudo of its own. What it cannot do is touch
# the key. The real fix is an allowlist forced command on the link's key, so
# that the link runs only what it is for: a separate task
# (modules/glue/laptop-access.nix, tools/ravnix-tap-ask/README.md).
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
# renamed machine. With the fixed value, a mapping made anywhere with the same
# -o and -i works on every machine with this origin; copy it to
# ~/.config/Yubico/u2f_keys. Enroll once, on any machine:
#
#   mkdir -p ~/.config/Yubico
#   pamu2fcfg -o pam://ravnix -i pam://ravnix > ~/.config/Yubico/u2f_keys
#   chmod 600 ~/.config/Yubico/u2f_keys
#
# The chmod matters: pam_u2f 1.4.0 refuses a mapping owned by someone else,
# but only warns in the journal about one that others may write, and whoever
# can write it can add a key of their own. NixOS's home is 700, which covers
# it as long as it stays so.
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
  sudo = config.security.pam.services.sudo;
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

    # polkit refuses a subject outside a local, active session (POLKIT,
    # above). polkit runs the rules files in the order of their names, and
    # NixOS's 10-nixos.rules comes before polkit's 50-default.rules, whose
    # rule makes wheel the admin; the first rule that decides wins.
    security.polkit.extraConfig = ''
      // ravnix (modules/desktop/u2f.nix): no polkit authentication, and so no
      // tap, for a subject outside a local, active session, such as an ssh
      // login. Root is left alone.
      polkit.addRule(function (action, subject) {
        if (subject.user != "root" && (!subject.local || !subject.active)) {
          return polkit.Result.NO;
        }
      });
    '';

    # sudo asks on the screen first (SUDO ASKS ON THE SCREEN FIRST, above).
    # The order is relative to pam_u2f's, as NixOS advises, so that the jump
    # of one line skips exactly that one.
    security.pam.services.sudo.rules.auth.ravnix-tap-ask = lib.mkIf sudo.u2f.enable {
      order = sudo.rules.auth.u2f.order - 10;
      control = "[success=ignore default=1]";
      modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
      # quiet: a denial prints no "failed: exit code 1" to the caller;
      # quiet_log: nor to the journal, at every sudo without the key;
      # seteuid: the tool runs as root, so that the user cannot trace it.
      args = [
        "quiet"
        "quiet_log"
        "seteuid"
        "${pkgs.ravnix.ravnix-tap-ask}/bin/ravnix-tap-ask"
      ];
    };
  };
}
