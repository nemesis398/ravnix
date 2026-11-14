# The login keyring after a login that gave PAM no password
# (ravnix.desktop.keyring.autoUnlock, modules/options/desktop.nix has the
# setup command).
#
# WHY. A password login unlocks the keyring through pam_gnome_keyring
# (greetd.nix): PAM hands the daemon the password the user typed. A YubiKey
# tap gives PAM no password, so the daemon starts with the keyring locked,
# and Helium asks for the keyring's password at every start. A keyring
# without a password would open without one, but gnome-keyring 50 writes a
# passwordless keyring in a plain text format that it cannot read back when
# a secret has a line break, and then loses every item.
#
# HOW. The password is a systemd credential of the user,
# ~/.config/credstore.encrypted/ravnix-keyring-login, which the user manager
# decrypts (through systemd-creds' Varlink service, which holds the host
# key) into the service's $CREDENTIALS_DIRECTORY while it runs and removes
# when it exits. The service runs ravnix-keyring-unlock, which asks the
# running daemon over the session bus whether the login collection is
# locked and, when it is, unlocks it with gnome-keyring's own
# UnlockWithMasterPassword: no second daemon, no prompt, nothing in argv or
# the environment. tools/ravnix-keyring-unlock/README.md has the details.
#
# WHEN. ravnix-keyring.target stands for "the unlock has run" in this
# graphical session. It pulls the service in and waits for it, and it is
# wanted by, and ordered before, graphical-session-pre.target (which Sway's
# sway-session.target starts) and xdg-desktop-autostart.target (the tray
# applets, the Nextcloud client among them). The login layout, which starts
# Helium from the Sway config, waits for it through
# ravnix.desktop.sessionLayout.after. The target stays active for the
# session, so these three starts run the service once; the service itself
# does not stay active, so the decrypted password does not stay in its
# credentials directory. The target is part of graphical-session.target and
# stops with it, so the next login runs the service again.
#
# The service needs nothing of the graphical session, only the session bus.
# Its first call may start the Secret Service: the daemon that PAM started
# for the login waits, without its secrets component, until a client starts
# gnome-keyring-daemon --start through D-Bus, which then hands the work to
# it. That is the same start Helium's first lookup would cause.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.desktop.keyring.autoUnlock;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.gnome.gnome-keyring.enable;
        message = "ravnix.desktop.keyring.autoUnlock needs gnome-keyring: services.gnome.gnome-keyring.enable is off.";
      }
    ];

    systemd.user.targets.ravnix-keyring = {
      description = "The login keyring's unlock has run";
      wants = [ "ravnix-keyring-unlock.service" ];
      after = [ "ravnix-keyring-unlock.service" ];
      # graphical-session.target is said here although it follows from the
      # pre target: a target that is PartOf another is ordered after it by
      # systemd's implicit target dependencies unless the unit orders itself
      # otherwise, and after graphical-session.target while before its pre
      # target is a cycle, which systemd breaks by dropping this target's start.
      before = [
        "graphical-session-pre.target"
        "graphical-session.target"
        "xdg-desktop-autostart.target"
      ];
      wantedBy = [
        "graphical-session-pre.target"
        "xdg-desktop-autostart.target"
      ];
      partOf = [ "graphical-session.target" ];
    };

    systemd.user.services.ravnix-keyring-unlock = {
      description = "Unlock the login keyring with its stored password";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pkgs.ravnix.ravnix-keyring-unlock;
        # Found by name in ~/.config/credstore.encrypted/ (the user
        # manager's $XDG_CONFIG_HOME/credstore.encrypted); a missing file is
        # not an error, the tool reports it.
        LoadCredentialEncrypted = "ravnix-keyring-login";
        # Bounds the wait of the session and the login layout if the bus
        # does not answer; the tool itself gives up after 10 s.
        TimeoutStartSec = "15s";
        # No core dump with the password in it; the tool also makes itself
        # undumpable, which keeps ptrace and /proc/PID/mem out as well.
        LimitCORE = 0;
        UMask = "0077";
        NoNewPrivileges = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
      };
    };

    ravnix.desktop.sessionLayout.after = [ "ravnix-keyring.target" ];
  };
}
