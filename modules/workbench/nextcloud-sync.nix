# A copy of your Nextcloud on the server, without a window: a user unit runs
# `nextcloudcmd`, the command-line client that is part of Nextcloud's own, for
# each folder of ravnix.nextcloud.folders, and a timer starts it every five
# minutes (and two minutes after boot, and once for a run missed while the
# server was off). It speaks the sync protocol of the desktop client on the
# laptop, so the two sides see each other's changes the same way, and a
# conflict leaves a "conflicted copy" file as it does there.
#
# Hidden files are part of the copy (`-h`). The command-line client leaves
# them out unless it is told, while a desktop client set to sync them copies
# them, so without -h the copy here would lack the dot directories of a
# folder, such as the .obsidian, .claude and .agents of a notes vault, and a
# commit made from the copy would record them as deleted.
#
# The password. It is the app password named by ravnix.nextcloud.passwordItem
# and it is read from the vault by rbw at the moment of each run. It goes to
# nextcloudcmd in the NC_PASSWORD variable of that one process (the client
# reads it with --non-interactive), never on its command line, which any
# process could read, and never into a file or the unit. The unit stays quiet
# about it: no xtrace.
#
# When the vault is locked. Nothing can read the item, so the run stops before
# it starts anything, says that the vault is locked, and exits with status 75
# (./unlocked.nix). The unit then shows as failed, which is true, and the next
# run after `ai-unlock` works. The alternative, a password kept in a file for
# the unit, would hold the secret where rbw is meant to be the only place it
# lives (the choice Task 1.4 made for the builder's key is right there,
# because the Nix daemon builds unattended; this unit has the user's agent).
# How long the vault stays unlocked is rbw's lock_timeout and Task 4.3's
# design.
#
# Git repositories are not synced through Nextcloud (the design: two machines
# in one synced .git corrupt it), so a `.git` directory is excluded. Since
# hidden files are synced, that exclusion is the only thing that keeps `.git`
# out, and it must match at every depth (README.md says it is not yet checked
# against a real server). The client's own list (lock files, temporary files)
# applies as well.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  user = os.ravnix.user.username;
  cfg = os.ravnix.nextcloud;
  home = os.users.users.${user}.home;
  root = if cfg.localRoot != null then cfg.localRoot else "${home}/Nextcloud";

  exclude = pkgs.writeText "ravnix-nextcloud-exclude.lst" ''
    # Git repositories travel through git, never through Nextcloud.
    .git
  '';
in
{
  options.ravnix.workbench.nextcloudSync.package =
    lib.mkPackageOption pkgs "nextcloud-client" { }
    // {
      description = ''
        The package that provides `nextcloudcmd`, the command-line client of
        Nextcloud.
      '';
    };

  config = lib.mkIf (cfg != null) {
    home-manager.users.${user} =
      { config, ... }:
      let
        rbw = lib.getExe' config.programs.rbw.package "rbw";
        nextcloudcmd = lib.getExe' os.ravnix.workbench.nextcloudSync.package "nextcloudcmd";

        # One run of the client for a folder: the remote folder is synced with
        # the same path under the root.
        syncFolder =
          folder:
          let
            local = if folder == "/" then root else "${root}${folder}";
          in
          ''
            mkdir -p -- ${lib.escapeShellArg local}
            NC_USER=${lib.escapeShellArg cfg.user} NC_PASSWORD=$password \
              ${nextcloudcmd} --non-interactive -h --exclude-anchored ${exclude} \
              --path ${lib.escapeShellArg folder} ${lib.escapeShellArg local} ${lib.escapeShellArg cfg.url} ||
              status=1
          '';

        sync = pkgs.writeShellApplication {
          name = "ravnix-nextcloud-sync";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            ${import ./unlocked.nix {
              inherit rbw;
              what = "the Nextcloud app password";
            }}
            password=$(${rbw} get -- ${lib.escapeShellArg cfg.passwordItem}) || {
              echo "rbw could not read the item ${lib.escapeShellArg cfg.passwordItem}" >&2
              exit 1
            }
            if [ -z "$password" ]; then
              echo "the item ${lib.escapeShellArg cfg.passwordItem} has no password" >&2
              exit 1
            fi
            # A failed folder does not keep the others from syncing; the unit
            # fails if any did.
            status=0
            ${lib.concatMapStrings syncFolder cfg.folders}
            exit "$status"
          '';
        };
      in
      {
        systemd.user.services.nextcloud-sync = {
          Unit = {
            Description = "Nextcloud: sync ${lib.concatStringsSep ", " cfg.folders} with the copy here";
            # A switch must not start a sync by restarting the unit.
            X-SwitchMethod = "keep-old";
          };
          Service = {
            Type = "oneshot";
            ExecStart = lib.getExe sync;
          };
        };
        systemd.user.timers.nextcloud-sync = {
          Unit.Description = "Nextcloud: sync every five minutes";
          Timer = {
            OnCalendar = "*:0/5";
            OnBootSec = "2min";
            Persistent = true;
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
  };
}
