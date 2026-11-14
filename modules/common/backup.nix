# The host's backup to the NAS, for home-manager: restic, as the user, from
# a user unit and its timer, to the rest-server on the NAS
# (deploy/compose/restic), over the LAN or NetBird's route to it. It is on
# only where ravnix.backup.nas is set (modules/options/backup.nix), and the
# repository is derived there from ravnix.services.restic-server and the
# host's one name, which is also the login's user.
#
# The server takes new data and refuses to delete any (`--append-only`), so
# this host can add snapshots and never remove one: no `restic forget`, no
# `prune`, nothing that would let a compromised host, or one of its agents,
# take its own history down with it. Pruning is the NAS's job, per host and
# by the retention file (ravnix-retention), and so is the copy to Internxt,
# whose credential no host has. The repository is created on the NAS too
# (`restic init --copy-chunker-params`, so `restic copy` to the estate's
# Internxt repository deduplicates); a host never runs `restic init`.
#
# What is backed up: ravnix.backup.nas.paths (the home by default), minus
# ~/.cache, every directory tagged with CACHEDIR.TAG, and exclude, plus
# keep, the paths taken back from inside an exclude (./backup-excludes.nix
# says why that is an option of its own and how the patterns are made).
#
# The secrets, with ravnix.backup.nas.secrets = "rbw" (the default). Both
# are items of the vault, read by rbw at each run, and in no file, unit or
# store path:
#   - the repository password, which opens every snapshot: restic asks for it
#     through --password-command, a script that runs `rbw get`, so it goes
#     from rbw to restic through a pipe and is in no environment;
#   - the rest-server login, which only lets the host append: its user is
#     the host name, and its password the item's. restic reads both from
#     RESTIC_REST_USERNAME and RESTIC_REST_PASSWORD (it has no command for
#     them), set for the restic process alone, as nextcloud-sync passes its
#     password. Not in the URL, which is in the store.
#
# When the vault is locked, nothing can be read, so the run stops before it
# starts restic, says so, and exits 75 (../workbench/unlocked.nix). A failed
# run is tried again every 30 minutes, so the backup is made soon after the
# next ai-unlock; exit 3, restic's "snapshot saved, but some files could not
# be read", is not retried, since a retry would read the same files again.
#
# With ravnix.backup.nas.secrets = "file", for a host that backs up
# unattended, the NixOS side runs the backup instead, as a system unit
# (./backup-system.nix), and this module adds no unit, no timer and no
# program; it still checks the paths.
{
  config,
  lib,
  pkgs,
  ...
}@args:
let
  cfg = config.ravnix.backup.nas;
  rbw = lib.getExe' config.programs.rbw.package "rbw";
  script = import ./backup-script.nix { inherit lib pkgs; } {
    inherit cfg rbw;
    home = config.home.homeDirectory;
  };
  backup = script.package;
  onNixos = (args.osConfig or null) != null;
in
{
  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      {
        assertions =
          map (message: {
            assertion = false;
            inherit message;
          }) script.problems
          ++ [
            {
              assertion = cfg.secrets != "file" || onNixos;
              message = "ravnix.backup.nas.secrets is \"file\", which needs a system unit to hand the root-only file over: use nixosModules.common, not home-manager alone.";
            }
          ];
      }
      (lib.mkIf (cfg.secrets == "rbw") {
        # For a run by hand: `ravnix-backup`, or `systemctl --user start
        # ravnix-backup` to have it in the journal.
        home.packages = [ backup ];

        systemd.user.services.ravnix-backup = {
          Unit = {
            # No path in it: systemd would read a % in one as a specifier.
            Description = "Backup of the home to the NAS (restic)";
            # A switch must not start a backup by restarting the unit.
            X-SwitchMethod = "keep-old";
          };
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe backup;
            Restart = "on-failure";
            RestartSec = "30min";
            RestartPreventExitStatus = "3";
            Nice = 10;
            IOSchedulingClass = "idle";
          };
        };
        systemd.user.timers.ravnix-backup = {
          Unit.Description = "Backup of the home to the NAS, on its calendar";
          Timer = {
            OnCalendar = cfg.onCalendar;
            Persistent = true;
            RandomizedDelaySec = "10min";
          };
          Install.WantedBy = [ "timers.target" ];
        };
      })
    ]
  );
}
