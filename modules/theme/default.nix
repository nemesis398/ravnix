# The theme module for home-manager: the ravnix.theme.* options (options.nix),
# and what is written into the applications that take a color, a width or a
# font from them. docs/style.md holds the rules; this is the one place that
# turns them into values, so no other module writes a hex color.
#
#   ghostty, fuzzel and dunst are generated from the roles: their settings are
#   set here, and apply when the host enables the program. catppuccin/nix has
#   a port of each, and none is used, because each differs from the port in
#   the rows of the style spec's table (a translucent fuzzel, a Surface2
#   selection, a 2 px dunst frame, ghostty's Text selection) or has no accent.
#   GTK, Qt, the cursor and the fonts are in gtk-qt.nix and fonts.nix.
#
#   catppuccin/nix is switched on with the flavor and the accent of the
#   options, but with autoEnable off: a module that wants a port for its
#   program (bat, btop, lazygit, eza, Neovim) turns that one on, and a port
#   that does not follow the style spec never changes a program by accident.
#
# Setting the same key as a module here is a conflict on purpose: a program
# that cannot follow the style is an exception, listed in the module that
# installs it (docs/style.md, rule 9).
{ config, lib, ... }:
let
  cfg = config.ravnix.theme;
  inherit (cfg)
    palette
    roles
    font
    fontSize
    lineWidth
    ;

  # fuzzel writes colors as rrggbbaa, without a #; every one is opaque.
  fuzzel = hex: "${lib.removePrefix "#" hex}ff";
in
{
  imports = [
    ./options.nix
    ./fonts.nix
    ./gtk-qt.nix
  ];

  catppuccin = {
    enable = true;
    autoEnable = false;
    flavor = "mocha";
    inherit (cfg) accent;
  };

  # Terminal colors: black is Surface1, red Red, green Green, yellow Yellow,
  # blue Blue, magenta Pink, cyan Teal, white Subtext1; the bright set is
  # Surface2, Red, Green, Yellow, Blue, the accent in the magenta slot, Teal,
  # Subtext0. Selection and cursor are an accent block with Crust text.
  programs.ghostty.settings = {
    font-family = font;
    font-size = fontSize.terminal;
    window-padding-x = 14;
    window-padding-y = 14;
    window-decoration = false;
    background = roles.canvas;
    foreground = roles.text;
    cursor-style = "block";
    cursor-style-blink = false;
    cursor-color = roles.accent;
    cursor-text = roles.deepest;
    selection-background = roles.accent;
    selection-foreground = roles.deepest;
    palette = [
      "0=${palette.surface1}"
      "1=${palette.red}"
      "2=${palette.green}"
      "3=${palette.yellow}"
      "4=${palette.blue}"
      "5=${palette.pink}"
      "6=${palette.teal}"
      "7=${palette.subtext1}"
      "8=${palette.surface2}"
      "9=${palette.red}"
      "10=${palette.green}"
      "11=${palette.yellow}"
      "12=${palette.blue}"
      "13=${roles.accent}"
      "14=${palette.teal}"
      "15=${palette.subtext0}"
    ];
  };

  # Base, a 1 px accent frame with square corners, the selection one step up
  # the ladder (Surface1), matches in the accent, fixed 50 characters wide.
  programs.fuzzel.settings = {
    main = {
      font = "${font}:size=${toString fontSize.launcher}";
      width = 50;
      icon-theme = "Papirus-Dark";
    };
    border = {
      width = lineWidth.frame;
      radius = 0;
    };
    colors = {
      background = fuzzel roles.canvas;
      text = fuzzel roles.text;
      prompt = fuzzel roles.label;
      placeholder = fuzzel roles.placeholder;
      input = fuzzel roles.text;
      match = fuzzel roles.accent;
      selection = fuzzel roles.selected;
      selection-text = fuzzel roles.text;
      selection-match = fuzzel roles.accent;
      counter = fuzzel roles.placeholder;
      border = fuzzel roles.accent;
    };
  };

  # Base, a 1 px accent frame, and a stacked pair separated by the frame
  # color. A critical notification is Peach, whatever the accent is.
  services.dunst.settings = {
    global = {
      font = "${font} ${toString fontSize.terminal}";
      frame_width = lineWidth.frame;
      frame_color = roles.accent;
      separator_color = "frame";
      highlight = roles.accent;
    };
    urgency_low = {
      background = roles.canvas;
      foreground = roles.text;
    };
    urgency_normal = {
      background = roles.canvas;
      foreground = roles.text;
    };
    urgency_critical = {
      background = roles.canvas;
      foreground = roles.text;
      frame_color = palette.peach;
    };
  };
}
