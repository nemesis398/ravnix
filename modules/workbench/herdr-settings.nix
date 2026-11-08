# herdr's settings, which the server (./herdr.nix) and the laptop
# (modules/glue/terminal.nix) share: on the laptop, `herdr --remote` draws the
# UI, its theme and its sidebar, and reads the keys from these settings, so
# the two must agree. Not a module: a function of the accent, returning the
# value of programs.herdr.settings. The server adds the shell of its panes.
{ accent }:
{
  onboarding = false;

  theme = {
    # "catppuccin" is the Mocha variant; there is no "catppuccin-mocha"
    # and auto_switch stays off, so the terminal can never pull the UI
    # into Latte. The accent is the user's, as everywhere
    # (docs/style.md).
    name = "catppuccin";
    custom.accent = accent;
  };

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
}
