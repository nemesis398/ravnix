# The watcher of the dictionary (tools/ravnix-dict, "The watcher"): a user
# service that runs `ravnix-dict sync`, started by a path unit whenever the
# dictionary or a word list in a file changes (Handy's settings store, the
# prose skill's dictionary), and by a timer every 15 minutes for what no
# file shows: LanguageTool's list in the cloud, and a change that came while
# a sync ran (systemd merges a start into the one that runs). It syncs only
# after a first sync by hand has finished: the first merge is the user's.
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
  # Only where it has work: a host without a dictionary gets no unit.
  config = lib.mkIf (cfg.watch && cfg.file != null) {
    systemd.user.services.${name} = {
      Unit = {
        Description = "Sync the dictionary with the tools' word lists (ravnix-dict)";
        # Both must be there, or the run is skipped, which is no failure:
        #  - the dictionary: no checkout of the private flake yet (a fresh
        #    install, a VM test) is nothing to sync. ravnix-dict itself
        #    refuses a missing dictionary, which by hand is the right answer;
        #  - the known list of a finished sync: the first merge, which takes
        #    every tool's words into the dictionary and gives every tool the
        #    rest, is a `ravnix-dict sync` by hand, after the junk is struck
        #    (tools/ravnix-dict/README.md, "The first sync"). Until then the
        #    watcher writes nothing to any tool.
        ConditionPathExists = [
          cfg.file
          "${config.xdg.stateHome}/ravnix-dict/known"
        ];
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
