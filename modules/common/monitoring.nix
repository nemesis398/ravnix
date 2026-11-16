# The host in the estate's monitoring, for home-manager, from
# ravnix.monitoring (modules/options/monitoring.nix): the units the Fedora
# laptop ran from homelab's installers, under the same names, with their
# secrets read by rbw at each start instead of kept in an env file.
#
#   beszel-agent              the Beszel agent, dialing out to the hub
#   kuma-push.timer           the heartbeat to Uptime Kuma, every 15 minutes
#   backup-age-check.timer    the age of the host's newest snapshot on the
#                             NAS, pushed to a monitor of its own
#
# Why user units, as on Fedora, and not nixpkgs' services.beszel.agent:
# that one is a system unit whose secrets come from an EnvironmentFile on
# disk, and the token here is read by the user's rbw, which only the user's
# manager can ask. A user unit also runs only while the user's manager does,
# and on a laptop without lingering that is while a session is open: the
# laptop roams and is often shut, and the hub and Kuma showing it away then
# is information, not an alarm. The agent is nixpkgs' beszel, whose version
# is the hub's (the two are released and upgraded as a pair).
#
# The dGPU: left to itself the agent runs `nvidia-smi -l 4` wherever
# nvidia-smi is on its PATH, which keeps a hybrid laptop's NVIDIA card awake
# for as long as the agent runs (measured on the IdeaPad: suspended within
# 9 s with the agent stopped, woken at once when it started). The machine's
# hardware module sets ravnix.monitoring.gpuCollector (amd_sysfs on the
# IdeaPad), and the agent then reads that collector and never starts
# nvidia-smi.
#
# While the vault is locked nothing can be read, and each unit says so and
# stops with status 75 (../workbench/unlocked.nix):
#   - the agent is started again after a wait that grows from 10 s to
#     15 minutes, so it comes up after ai-unlock without a burst of restarts
#     while the vault stays locked; once it runs it needs the vault no more;
#   - the heartbeat and the check are not retried: their monitors see no
#     beat, which is what a locked vault means to them. The heartbeat's 75,
#     and curl's statuses for no network (6, 7, 28), do not mark the unit
#     failed, as on Fedora: the missing beat is the signal, and it is read
#     on the other end.
#
# No timer here is made up after a suspend but the check's (Persistent=),
# and none wakes the machine: the heartbeat beats only while a session is
# open, because a catch-up beat after the lid opens would forge presence for
# hours that were not, and the check runs once a day, after the start of
# the manager and after each successful backup (OnSuccess= on
# ravnix-backup.service, while the machine is awake for that anyway).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.monitoring;
  nas = config.ravnix.backup.nas;
  rbw = lib.getExe' config.programs.rbw.package "rbw";
  scripts = import ./monitoring-scripts.nix { inherit lib pkgs; } { inherit rbw; };
  backup = import ./backup-script.nix { inherit lib pkgs; } {
    cfg = nas;
    inherit rbw;
    home = config.home.homeDirectory;
  };
  check = scripts.backupAgeCheck {
    inherit (cfg.backupAge) pushUrlItem maxAgeDays;
    inherit nas backup;
  };
  checkable = nas != null && nas.secrets == "rbw";
in
{
  config = lib.mkMerge [
    (lib.mkIf (cfg.beszel != null) {
      systemd.user.services.beszel-agent = {
        Unit = {
          Description = "Beszel agent, dialing out to the hub";
          Documentation = "https://github.com/henrygd/beszel";
          # Never give up while the vault stays locked.
          StartLimitIntervalSec = 0;
        };
        Service = {
          ExecStart = lib.getExe (scripts.beszelAgent { inherit (cfg.beszel) tokenItem; });
          Environment = [
            "HUB_URL=${cfg.beszel.hubUrl}"
            "KEY_FILE=${pkgs.writeText "beszel-hub-key.pub" "${cfg.beszel.hubKey}\n"}"
            "SYSTEM_NAME=${cfg.beszel.systemName}"
            # A dropped WebSocket never opens the agent's fallback SSH
            # listener, and LISTEN keeps it on loopback should a later
            # version open one anyway.
            "DISABLE_SSH=true"
            "LISTEN=127.0.0.1:45876"
            # No StateDirectory=: in a user unit systemd adopts an existing
            # ~/.config/beszel-agent as the state directory of systemd 253
            # and older, which would put the agent's state beside whatever
            # is there (measured on Fedora). The agent makes DATA_DIR itself.
            "DATA_DIR=%S/beszel-agent"
          ]
          ++ lib.optional (cfg.gpuCollector != null) "GPU_COLLECTOR=${cfg.gpuCollector}";
          Restart = "on-failure";
          RestartSec = "10s";
          RestartSteps = 6;
          RestartMaxDelaySec = "15min";
        };
        Install.WantedBy = [ "default.target" ];
      };
    })

    (lib.mkIf (cfg.kuma != null) {
      systemd.user.services.kuma-push = {
        Unit.Description = "Report this host to Uptime Kuma";
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe (scripts.kumaPush { inherit (cfg.kuma) pushUrlItem units; });
          SuccessExitStatus = "6 7 28 75";
        };
      };
      systemd.user.timers.kuma-push = {
        Unit.Description = "Report this host to Uptime Kuma every 15 minutes";
        Timer = {
          OnStartupSec = "1min";
          OnUnitActiveSec = "900s";
          AccuracySec = "10s";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })

    (lib.mkIf (cfg.backupAge != null) {
      assertions = [
        {
          assertion = checkable;
          message =
            if nas == null then
              "ravnix.monitoring.backupAge is set, but ravnix.backup.nas is not: there is no backup whose age it could check."
            else
              "ravnix.monitoring.backupAge needs ravnix.backup.nas.secrets = \"rbw\": with \"file\" the backup's secrets are root's, and the user's check cannot read the repository.";
        }
      ];
    })

    (lib.mkIf (cfg.backupAge != null && checkable) {
      # For a run by hand, which prints the result.
      home.packages = [ check ];

      systemd.user.services.backup-age-check = {
        Unit.Description = "The age of this host's newest backup on the NAS, to Uptime Kuma";
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe check;
        };
      };
      systemd.user.timers.backup-age-check = {
        Unit.Description = "The backup's age, daily and after the start";
        Timer = {
          OnStartupSec = "3min";
          OnCalendar = "daily";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
      # A successful backup is checked at once, so the monitor hears of it
      # the same day even when the vault was locked at the timer's run.
      systemd.user.services.ravnix-backup.Unit.OnSuccess = [ "backup-age-check.service" ];
    })
  ];
}
