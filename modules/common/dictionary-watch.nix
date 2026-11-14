# The watcher of the dictionary (tools/ravnix-dict, "The watcher"): a user
# service that runs `ravnix-dict sync`, started by a path unit whenever the
# dictionary or a word list in a file changes (Handy's settings store, the
# prose skill's dictionary), and by a timer every 15 minutes for what no
# file shows: LanguageTool's list in the cloud, and a change that came while
# a sync ran (systemd merges a start into the one that runs).
#
# A sync that writes a list changes the file it watches, and the path unit
# starts one more sync, which finds every list in step and writes nothing.
#
# The service runs the wrapper of ./dictionary.nix, so the shell and the
# watcher sync the same adapters with the same state: XDG_STATE_HOME is
# set to home-manager's, which is the shell's too.
{ config, lib, ... }:
let
  cfg = config.ravnix.dictionary;
  name = "ravnix-dict-sync";
  watched = [
    cfg.file
  ]
  ++ lib.optional cfg.adapters.handy cfg.paths.handy
  ++ lib.optional cfg.adapters.prose cfg.paths.prose;
in
{
  config = lib.mkIf cfg.watch {
    systemd.user.services.${name} = {
      Unit = {
        Description = "Sync the dictionary with the tools' word lists (ravnix-dict)";
        # No checkout of the private flake yet (a fresh install, a VM test):
        # nothing to sync, and no failure. ravnix-dict itself refuses a
        # missing dictionary, which by hand is the right answer.
        ConditionPathExists = cfg.file;
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} sync";
        Environment = [ "XDG_STATE_HOME=${config.xdg.stateHome}" ];
        # A sync waits up to a minute for another run, may stop and start
        # Handy, and the first one adds every word to LanguageTool, a request
        # each, waiting out its rate limit.
        TimeoutStartSec = "20min";
        Nice = 10;
      };
    };

    systemd.user.paths.${name} = {
      Unit.Description = "Watch the dictionary and the tools' word lists";
      Path = {
        PathChanged = watched;
        Unit = "${name}.service";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.timers.${name} = {
      Unit.Description = "Sync the dictionary with the lists no file shows";
      Timer = {
        OnStartupSec = "2min";
        OnUnitInactiveSec = "15min";
        Unit = "${name}.service";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
