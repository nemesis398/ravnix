# The host's backup to the NAS where it must run unattended, for NixOS:
# ravnix.backup.nas.secrets = "file". The same script as the user unit of
# ./backup.nix (./backup-script.nix), from a system unit and its timer, every
# day, whether or not anyone has unlocked the vault.
#
# The two secrets, the repository password and the rest-server login, are
# in a file only root can read, ravnix.backup.nas.secretsFile, written once
# by hand from the password manager. This is a deliberate exception to
# secrets from rbw at runtime, as the Nix builder's key is
# (ravnix.nixBuilder.sshKey): the backup runs unattended, for example on
# muninn while its vault is locked, so the secrets have to be on disk.
#
# The file stays out of the user's reach while the backup runs, too. systemd
# loads it as the credential ravnix-backup (LoadCredential=) into
# /run/credentials/ravnix-backup.service/ and gives the unit's user, alone,
# an ACL on that directory. Run as the login user, every process of that
# user, its agents among them, could read both secrets there for as long as
# the run lasts, and restic's environment with them. So the unit runs under
# a UID of its own, DynamicUser=: no account to keep, a UID that owns
# nothing outside the unit's own directories, and systemd's hardening that
# comes with it (ProtectSystem=strict, NoNewPrivileges=, PrivateTmp=). A
# dedicated static user would do as well, at the cost of an account that
# lives on. That UID reads the home through CAP_DAC_READ_SEARCH and no other
# capability (restic's documented way to back up as a non-root user), keeps
# restic's cache in its CacheDirectory=, and the snapshots carry the same
# host, paths, owners and modes as the user unit's; only their `username`
# field names the unit's user instead of the login user.
#
# Before the run, a step as root (ExecStartPre=+) refuses the file unless it
# is root's and mode 600, with one line. A missing file fails the start
# (AssertPathExists=, which names the path in the journal); one that cannot
# be loaded, or lacks a line, fails the run with one line too. Nothing
# falls back to rbw.
#
# The unit is a system unit because a user unit cannot load a file that
# only root can read. It keeps the user unit's name, ravnix-backup, and
# restic's command line, so idle-suspend, which looks for the process by
# name (`pgrep -f '^restic '`, any user), still sees the run.
{ config, lib, pkgs, ... }:
let
  cfg = config.ravnix.backup.nas;
  user = config.ravnix.user.username;
  script = import ./backup-script.nix { inherit lib pkgs; } {
    inherit cfg;
    home = config.users.users.${user}.home;
  };

  # ravnix-backup-check FILE: refuses, with one line, a file that is not
  # root's or not mode 600. Run as root before the backup.
  check = pkgs.writeShellApplication {
    name = "ravnix-backup-check";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      file=$1
      if ! found=$(stat -c '%u %a' -- "$file" 2>/dev/null); then
        echo "the backup's secrets file $file cannot be read by stat" >&2
        exit 1
      fi
      if [ "$found" != "0 600" ]; then
        echo "the backup's secrets file $file is owner and mode $found, not root's with mode 600: install it again, as ravnix.backup.nas.secretsFile says" >&2
        exit 1
      fi
    '';
  };
in
{
  config = lib.mkIf (cfg != null && cfg.secrets == "file") {
    systemd.services.ravnix-backup = {
      description = "Backup of the home to the NAS (restic), from the root-only file";
      # A switch must not start a backup by restarting the unit.
      restartIfChanged = false;
      unitConfig.AssertPathExists = cfg.secretsFile;
      serviceConfig = {
        Type = "oneshot";
        DynamicUser = true;
        AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
        CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
        ProtectHome = "read-only";
        CacheDirectory = "ravnix-backup";
        ExecStartPre = "+${lib.getExe check} ${cfg.secretsFile}";
        ExecStart = lib.getExe script.package;
        LoadCredential = [ "ravnix-backup:${cfg.secretsFile}" ];
        Restart = "on-failure";
        RestartSec = "30min";
        RestartPreventExitStatus = "3";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };
    systemd.timers.ravnix-backup = {
      description = "Backup of the home to the NAS, on its calendar";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
