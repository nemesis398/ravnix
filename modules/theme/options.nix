# The ravnix.theme.* options: the data every module that draws something reads
# its colors, line widths, font and sizes from. It uses nothing of NixOS or
# home-manager, so nixosModules.theme and homeModules.theme both import it,
# and a user sets the accent once in their me.nix for both.
#
#   palette    the 26 colors of Catppuccin Mocha, by name, as "#rrggbb"
#   accent     which of the eight accents; default "mauve"
#   roles      the style spec's role names, each a "#rrggbb": deepest (Crust),
#              dock (Mantle), canvas (Base), wash (Surface0), selected
#              (Surface1), line (Surface2), muted (Overlay0), placeholder
#              (Overlay1), secondary (Subtext0), label (Subtext1), text
#              (Text), and accent
#   lineWidth  { frame = 1; marker = 2; } in px: no other widths, except the
#              lock ring, which is a gauge
#   font       the one family
#   fontSize   terminal (and editor, notifications) 9 pt, launcher and menus
#              11 pt, bar 14 px, ui (GTK and Qt applications) 11 pt
#
# Everything but the accent is read-only. The state hues are not roles: read
# them from the palette (red, peach, yellow, green, blue, maroon), where the
# style spec gives each a meaning of its own.
#
# There is one accent per host. A user sets it once, as ravnix.theme.accent in
# me.nix, which reaches NixOS through nixosModules.options. Inside NixOS,
# home-manager takes the host's accent as its own default (osConfig), so the
# two cannot diverge by a forgotten line; setting it to another value in
# home-manager fails an assertion.
{
  config,
  lib,
  ...
}@args:
let
  inherit (lib) mkOption types;
  palette = import ./palette.nix;
  cfg = config.ravnix.theme;

  # The accent of the NixOS host this is evaluated inside, when there is one
  # and it has the option. osConfig is read from args and is no formal
  # argument: only home-manager inside NixOS provides it, and the module
  # system does not honor a default on a formal one (NixOS and evalModules
  # would fail on it).
  osConfig = args.osConfig or null;
  hostAccent = if osConfig == null then null else osConfig.ravnix.theme.accent or null;

  accents = [
    "mauve"
    "lavender"
    "pink"
    "flamingo"
    "rosewater"
    "teal"
    "sky"
    "sapphire"
  ];
  # The message of a refused accent is this description, so it names the
  # accents that are allowed and why the others are not.
  accentType = types.enum accents // {
    description = "one of ${
      lib.concatMapStringsSep ", " (a: ''"${a}"'') accents
    }; Red, Maroon, Peach, Yellow, Green and Blue carry a state, so they cannot be the accent";
  };
in
{
  options.ravnix.theme = {
    palette = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      description = "The colors of Catppuccin Mocha by name, as #rrggbb.";
    };
    accent = mkOption {
      type = accentType;
      default = if hostAccent != null then hostAccent else "mauve";
      defaultText = lib.literalMD "the accent of the NixOS host when home-manager runs inside one, else `\"mauve\"`";
      description = ''
        The one accent: focus and place, never a state. It marks the frame of
        a floating thing, the active workspace, a non-default mode, the icon
        of every bar module, the clock, the prompt, matches, the cursor and
        a selection.
      '';
    };
    roles = mkOption {
      type = types.attrsOf types.str;
      readOnly = true;
      description = "The style spec's role names, each a #rrggbb; accent follows the accent option.";
    };
    lineWidth = mkOption {
      type = types.attrsOf types.int;
      readOnly = true;
      description = "Line widths in px: frame 1, marker 2.";
    };
    font = mkOption {
      type = types.str;
      readOnly = true;
      description = "The one font family.";
    };
    fontSize = mkOption {
      type = types.attrsOf types.int;
      readOnly = true;
      description = "Font sizes: terminal 9 pt, launcher 11 pt, bar 14 px, ui 11 pt.";
    };
  };

  config.assertions = lib.optional (hostAccent != null) {
    assertion = cfg.accent == hostAccent;
    message = "ravnix.theme.accent is \"${cfg.accent}\" in home-manager and \"${hostAccent}\" in NixOS; there is one accent per host. Set it once, as ravnix.theme.accent in me.nix, and leave it out of the home-manager configuration.";
  };

  config.ravnix.theme = {
    inherit palette;
    roles = {
      deepest = palette.crust;
      dock = palette.mantle;
      canvas = palette.base;
      wash = palette.surface0;
      selected = palette.surface1;
      line = palette.surface2;
      muted = palette.overlay0;
      placeholder = palette.overlay1;
      secondary = palette.subtext0;
      label = palette.subtext1;
      text = palette.text;
      accent = palette.${cfg.accent};
    };
    lineWidth = {
      frame = 1;
      marker = 2;
    };
    font = "JetBrainsMono Nerd Font";
    fontSize = {
      terminal = 9;
      launcher = 11;
      bar = 14;
      ui = 11;
    };
  };
}
