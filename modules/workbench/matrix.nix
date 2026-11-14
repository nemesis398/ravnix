# Matrix in iamb, on the server. The profile is your own account on
# ravnix.matrix.homeserver (ravnix.matrix.userId); the bots that post
# notifications are another thing and live in ravnix.matrix.rooms.
#
# iamb has no way to read a password from a command, so the first login is by
# hand (README.md): iamb asks for the password in the terminal, logs in, and
# keeps the session in ~/.local/share/iamb. The session survives restarts, and
# is part of the home volume.
#
# Style (docs/style.md): iamb 0.13 has a `theme` table (a color, a background
# and modifiers per element, hex colors, a line style for borders), written
# here from the roles. Windows are bordered in a plain line, Surface2 and the
# accent when focused; the focused tab is the one accent fill of its strip; the
# prompt and the unread marker are the accent; the selected row is Surface1.
# Names are one color, not iamb's rainbow of ANSI hues, and encryption is a
# quiet icon, not a Green or Red. The theme goes in with the account, because
# a configuration without a profile is not one iamb starts from.
{ config, lib, ... }:
let
  os = config;
  user = os.ravnix.user.username;
  matrix = os.ravnix.matrix;
  inherit (os.ravnix.theme) roles;

  # An element: a color, and the rest of what iamb takes.
  fg = color: { inherit color; };
  on = background: color: { inherit color background; };
  bold = style: style // { modifiers = [ "bold" ]; };
  border = color: {
    inherit color;
    line = "plain";
  };
  unread = number: name: {
    number = number;
    inherit name;
    labels = fg roles.muted;
  };

  theme = {
    default = on roles.canvas roles.text;
    selected = {
      background = roles.selected;
    };
    cmdbar = {
      default = on roles.dock roles.text;
      prompt = bold (fg roles.accent);
      completions = on roles.dock roles.text;
      error = fg os.ravnix.theme.palette.red;
      info = fg roles.secondary;
    };
    msgbar.default = on roles.canvas roles.text;
    messages = {
      default = fg roles.text;
      blockquote = fg roles.muted;
      code = on roles.wash roles.text;
      code_block = (on roles.wash roles.text) // {
        line = "plain";
      };
      emphasis.modifiers = [ "italic" ];
      ruler = fg roles.line;
      strong.modifiers = [ "bold" ];
      table = (fg roles.line) // {
        line = "plain";
      };
    };
    timeline = {
      default = fg roles.text;
      date = fg roles.secondary;
      time = fg roles.muted;
      unread_marker = bold (fg roles.accent);
      state = fg roles.muted;
      notice = fg roles.secondary;
      redacted = fg roles.muted;
    };
    # One color for every name; an empty palette turns the rainbow off.
    users = (fg roles.label) // {
      colors = [ ];
    };
    completion = {
      default = on roles.dock roles.text;
      selected = on roles.selected roles.text;
    };
    windows = {
      default = on roles.canvas roles.text;
      border = border roles.line;
      border_focused = border roles.accent;
      title = fg roles.label;
    };
    tabs = {
      title = on roles.dock roles.muted;
      title_focused = bold (on roles.accent roles.deepest);
    };
    encryption = {
      icon_encrypted = fg roles.secondary;
      icon_unencrypted = fg roles.muted;
      icon_unknown = fg roles.muted;
    };
    rooms = {
      default = fg roles.text;
      labels = fg roles.muted;
      notification = unread (bold (fg roles.accent)) (bold (fg roles.text));
      mention = unread (bold (fg roles.accent)) (bold (fg roles.text));
      unread = unread (fg roles.muted) (fg roles.secondary);
      marked_unread = unread (fg roles.accent) (fg roles.text);
    };
  };
in
{
  home-manager.users.${user}.programs.iamb = {
    enable = true;
    settings = lib.optionalAttrs (matrix.userId != null) {
      default_profile = "main";
      profiles.main = {
        user_id = matrix.userId;
        url = matrix.homeserver;
      };
      inherit theme;
    };
  };
}
