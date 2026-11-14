# The host's backup to the NAS where it must run unattended, for NixOS:
# ravnix.backup.nas.secrets = "file". The same script as the user unit of
# ./backup.nix (./backup-script.nix), from a system unit and its timer that
# run it as the user, every day, whether or not anyone has unlocked the
# vault.
#
# The two secrets, the repository password and the rest-server login, are
# in a file only root can read, ravnix.backup.nas.secretsFile, written once
# by hand from the password manager. This is a deliberate exception to
# secrets from rbw at runtime, as the Nix builder's key is
# (ravnix.nixBuilder.sshKey): the backup runs unattended, for example on
# muninn while its vault is locked, so the secrets have to be on disk.
#
# The user's process never reads the file itself. systemd loads it as the
# credential ravnix-backup (LoadCredential=) and hands it to the run alone,
# in $CREDENTIALS_DIRECTORY, which no other process of the user sees and
# which is gone when the run ends. A missing file fails the run before it
# starts (AssertPathExists=, which names the path in the journal); one that
# cannot be loaded, or lacks a line, fails it with one line too. Nothing
# falls back to rbw.
#
# The unit is a system unit because a user unit cannot load a file that
# only root can read. It keeps the user unit's name, ravnix-backup, and
# restic's command line, so idle-suspend still sees the run.
{ config, lib, pkgs, ... }:
let
  cfg = config.ravnix.backup.nas;
  user = config.ravnix.user.username;
  script = import ./backup-script.nix { inherit lib pkgs; } {
    inherit cfg;
    home = config.users.users.${user}.home;
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
        User = user;
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
