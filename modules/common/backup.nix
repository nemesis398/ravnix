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
# The secrets. Both are items of the vault, read by rbw at each run, and in
# no file, unit or store path:
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
# restic runs by the name `restic`, from PATH, so its command line starts
# with `restic ` and idle-suspend sees it (packages/energy, `pgrep -f
# '^restic '`) and does not suspend the laptop under it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.backup.nas;
  home = config.home.homeDirectory;
  rbw = lib.getExe' config.programs.rbw.package "rbw";

  # ~/.cache goes through the same builder, so a glob character in the
  # home is escaped there too.
  excludes = import ./backup-excludes.nix { inherit lib; } {
    inherit home;
    inherit (cfg) paths keep;
    exclude = [ "~/.cache" ] ++ cfg.exclude;
  };
  expand =
    p:
    if p == "~" then
      home
    else if lib.hasPrefix "~/" p then
      home + lib.removePrefix "~" p
    else
      p;

  # restic splits the command on blanks; a store path has none.
  password = pkgs.writeShellScript "ravnix-backup-password" ''
    exec ${rbw} get -- ${lib.escapeShellArg cfg.passwordItem}
  '';

  backup = pkgs.writeShellApplication {
    name = "ravnix-backup";
    runtimeInputs = [
      pkgs.restic
      pkgs.coreutils
    ];
    text = ''
      ${import ../workbench/unlocked.nix {
        inherit rbw;
        what = "the backup's login";
      }}
      item=${lib.escapeShellArg cfg.loginItem}
      login=$(${rbw} get -- "$item") || {
        echo "rbw could not read the password of the item $item" >&2
        exit 1
      }
      if [ -z "$login" ]; then
        echo "the item $item has no password: the host's login at the rest-server" >&2
        exit 1
      fi
      export RESTIC_REPOSITORY=${lib.escapeShellArg cfg.repository}
      export RESTIC_PASSWORD_COMMAND=${password}
      RESTIC_REST_USERNAME=${lib.escapeShellArg cfg.host} RESTIC_REST_PASSWORD=$login \
        restic backup --host ${lib.escapeShellArg cfg.host} --exclude-caches \
          ${lib.escapeShellArgs (map (p: "--exclude=${p}") excludes.patterns)} \
          -- ${lib.escapeShellArgs (map expand cfg.paths)}
    '';
  };
in
{
  config = lib.mkIf (cfg != null) {
    assertions = map (message: {
      assertion = false;
      inherit message;
    }) excludes.problems;

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
  };
}
