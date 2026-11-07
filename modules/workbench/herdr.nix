# herdr on the server: the package, its configuration, and its server as a
# user unit that runs from boot, so the sessions are there when the laptop
# connects and stay when it goes. The configuration is Fedora's, keys and all
# (the tmux keymap, the Catppuccin theme, agents resumed after a restart); it
# matters on the server when you ssh in and run `herdr` there, and when the
# laptop attaches with the server's keybindings (`herdr --remote
# --remote-keybindings server`). With the default, local keybindings, the
# laptop's own herdr configuration applies; sharing this file with the laptop
# is a matter for the glue (Task 5.2).
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
        settings = {
          onboarding = false;

          theme = {
            # "catppuccin" is the Mocha variant; there is no "catppuccin-mocha"
            # and auto_switch stays off, so the terminal can never pull the UI
            # into Latte. The accent is the user's, as everywhere
            # (docs/style.md).
            name = "catppuccin";
            custom.accent = config.ravnix.theme.roles.accent;
          };

          terminal.default_shell = shell;

          # tmux's default keymap, reproduced (Fedora, 2026-08-23). Every
          # binding below is checked by `herdr config check`, which reports
          # a conflict as "kept keys.X, disabled keys.Y" rather than failing.
          keys = {
            prefix = "ctrl+b";

            # session and client
            detach = "prefix+d";
            help = "prefix+?";
            reload_config = "prefix+shift+r";

            # tmux windows are herdr tabs
            new_tab = "prefix+c";
            rename_tab = "prefix+,";
            close_tab = "prefix+&";
            next_tab = "prefix+n";
            previous_tab = "prefix+p";
            # herdr tabs are 1-based and it refuses "prefix+0..9", so there is
            # no prefix+0.
            switch_tab = "prefix+1..9";

            # panes. tmux's % splits side by side and " stacks; herdr calls
            # those split_vertical and split_horizontal, which reads
            # backwards, but the keys behave as tmux's do.
            split_vertical = "prefix+%";
            split_horizontal = "prefix+\"";
            close_pane = "prefix+x";
            zoom = "prefix+z";
            cycle_pane_next = "prefix+o";
            last_pane = "prefix+;";
            # Not ctrl+hjkl: ctrl+h is ASCII backspace, which a global binding
            # would eat in some programs.
            focus_pane_left = "prefix+left";
            focus_pane_down = "prefix+down";
            focus_pane_up = "prefix+up";
            focus_pane_right = "prefix+right";
            edit_scrollback = "prefix+[";

            # workspaces have no tmux equivalent; sessions are the closest
            workspace_picker = "prefix+s";
            rename_workspace = "prefix+$";
            previous_workspace = "prefix+(";
            next_workspace = "prefix+)";
            new_workspace = "prefix+shift+n";
            close_workspace = "prefix+shift+w";
            # displaced by the two above, moved rather than lost
            settings = "prefix+shift+s";
            open_notification_target = "prefix+shift+o";
          };

          # An agent's conversation is resumed (`claude --resume <id>`) when
          # the server restarts, instead of a fresh agent. This is the
          # default, stated so that it survives a change of the default.
          # experimental.pane_history stays off: it writes the scrollback,
          # which can hold secrets, into the home directory.
          session.resume_agents_on_restore = true;

          ui = {
            show_agent_labels_on_pane_borders = true;
            agent_panel_sort = "spaces";
            status_indicators = "dots";
            # Fedora sends these to dunst ("system"). The server has no
            # notification service; "terminal" asks the terminal the laptop
            # attaches with to show them, which is where a person is. What
            # must reach the phone with the lid closed goes to Matrix (Task
            # 5.6), not through here.
            toast.delivery = "terminal";
          };
        };
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
