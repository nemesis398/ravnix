# fuzzel, the launcher of the Sway session and the menu behind every popup
# (the clipboard history, the power menu, the key cheat sheet, the settings,
# the Wi-Fi list, the calculator and the AI popup all run it in --dmenu mode).
# Its colors, border, width, font and icon theme are the theme module's
# (modules/theme/default.nix): Base, a 1 px accent frame with square corners,
# the selection one step up the ladder, fixed 50 characters wide, and every
# color opaque. This file turns it on and adds what the theme does not say.
#
# NOT CARRIED OVER from the old setup: the translucent background (alpha dd),
# which the style spec forbids, and the Surface2 selection, which is Surface1
# now (the theme module explains both).
{ ... }:
{
  home-manager.sharedModules = [
    {
      programs.fuzzel = {
        enable = true;
        # Applications that ask for a terminal (Terminal=true in their entry)
        # open in the terminal of the session.
        settings.main.terminal = "ghostty -e";
      };
    }
  ];
}
