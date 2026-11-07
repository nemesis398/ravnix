# Matrix in iamb, on the server. The profile is your own account on
# ravnix.matrix.homeserver (ravnix.matrix.userId); the bots that post
# notifications are another thing and live in ravnix.matrix.rooms.
#
# iamb has no way to read a password from a command, so the first login is by
# hand (README.md): iamb asks for the password in the terminal, logs in, and
# keeps the session in ~/.local/share/iamb. The session survives restarts, and
# is part of the home volume.
#
# Style (docs/style.md, rule 9, an exception): iamb has no theme setting. It
# draws with the terminal's 16 ANSI colors, which the terminal sets to
# Catppuccin Mocha (modules/theme), and with plain single-line borders, so it
# follows the style without a setting of its own.
{ config, lib, ... }:
let
  os = config;
  user = os.ravnix.user.username;
  matrix = os.ravnix.matrix;
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
    };
  };
}
