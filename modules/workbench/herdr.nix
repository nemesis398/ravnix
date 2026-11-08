# herdr on the server: the package, its configuration, and its server as a
# user unit that runs from boot, so the sessions are there when the laptop
# connects and stay when it goes. The configuration is Fedora's, keys and all
# (the tmux keymap, the Catppuccin theme, agents resumed after a restart); it
# matters on the server when you ssh in and run `herdr` there. The laptop's
# main terminal attaches with `herdr --remote`, which draws the UI and reads
# the keys on the laptop, so the settings are a file of their own
# (./herdr-settings.nix) that the laptop reads too (modules/glue/terminal.nix).
#
# The server's environment is every pane's environment, so the unit sets the
# user's shell and a PATH that has the user's profile; the shell's own startup
# files (modules/common) do the rest.
#
# A switch must not end the sessions: restarting the server restarts every
# pane at once. The unit therefore keeps the running server whatever changes
# (X-SwitchMethod=keep-old), and it runs herdr through the user's profile, so
# a new herdr is started by restarting the unit on purpose
# (`systemctl --user restart herdr-server`), never by a switch. `herdr status
# server` says `server_binary_stale` while the running one is older than the
# installed one. Updating herdr is a flake bump on its own, never in the same
# run as a Claude Code roll (Task 6.1).
{
  config,
  lib,
  utils,
  ...
}:
let
  os = config;
  user = os.ravnix.user.username;
  profile = "/etc/profiles/per-user/${user}/bin";
  # The login shell of the account, by its stable path.
  shell = utils.toShellPath os.users.users.${user}.shell;
in
{
  home-manager.users.${user} =
    { config, ... }:
    {
      programs.herdr = {
        enable = true;
        # Shared with the laptop, whose `herdr --remote` reads them
        # (./herdr-settings.nix); the panes' shell is the server's alone,
        # merged in key by key, so a `terminal` table of the shared
        # settings keeps its other keys here (tests/glue/terminal-shapes.nix
        # checks both, and that the shared ones set no shell).
        settings = lib.recursiveUpdate (import ./herdr-settings.nix {
          accent = config.ravnix.theme.roles.accent;
        }) { terminal.default_shell = shell; };
      };

      systemd.user.services.herdr-server = {
        Unit = {
          Description = "herdr server: the terminal sessions and their agents";
          # A switch leaves the running server alone (see the header).
          X-SwitchMethod = "keep-old";
        };
        Service = {
          ExecStart = "${profile}/herdr server";
          # Always: `herdr server stop` is how a restart onto a new herdr
          # starts, and the server comes back and resumes the agents.
          Restart = "always";
          RestartSec = 2;
          Environment = [
            "SHELL=${shell}"
            "PATH=${profile}:/run/current-system/sw/bin"
          ];
        };
        Install.WantedBy = [ "default.target" ];
      };
    };
}
