# wiremix, the audio mixer in the floating terminal, in the colors of the
# roles. wiremix 0.11 has no theme of Catppuccin's, but its config takes a
# `[themes.NAME]` table with a style per element (a foreground, a background,
# modifiers; hex colors work), and it refuses an element it does not know, so
# tests/theme/wiremix.nix holds the names it printed. The theme starts from
# the built-in `plain` (no colors) and sets every element:
#
#   - the accent is the place: the selector, the filled part of a volume bar
#     and a live meter, the tab marker, the frame of an open dropdown or of
#     the help;
#   - the active tab is Crust on the accent, the strip's one fill; the other
#     tabs are Overlay0;
#   - the selected entry of a dropdown is Surface1 with Text;
#   - the empty part of a volume bar and a quiet meter are Surface2, an
#     overloaded meter is Peach (a warning), and nothing else is a state hue.
{ ... }:
{
  home-manager.sharedModules = [
    (
      { config, pkgs, ... }:
      let
        inherit (config.ravnix.theme) palette roles;
        toml = pkgs.formats.toml { };
        on = fg: bg: { inherit fg bg; };
        text = fg: { inherit fg; };

        theme = {
          "inherit" = "plain";
          default_device = text roles.accent;
          default_stream = text roles.accent;
          selector = text roles.accent;
          tab = text roles.muted;
          tab_selected = on roles.deepest roles.accent;
          tab_marker = text roles.accent;
          list_more = text roles.muted;
          node_title = text roles.label;
          node_target = text roles.secondary;
          volume = text roles.text;
          volume_empty = text roles.line;
          volume_filled = text roles.accent;
          meter_inactive = text roles.line;
          meter_active = text roles.accent;
          meter_overload = text palette.peach;
          meter_center_inactive = text roles.line;
          meter_center_active = text roles.accent;
          config_device = text roles.text;
          config_profile = text roles.secondary;
          dropdown_icon = text roles.accent;
          dropdown_border = text roles.accent;
          dropdown_item = text roles.text;
          dropdown_selected = on roles.text roles.selected;
          dropdown_more = text roles.muted;
          help_border = text roles.accent;
          help_item = text roles.text;
          help_more = text roles.muted;
        };
      in
      {
        xdg.configFile."wiremix/wiremix.toml".source = toml.generate "wiremix.toml" {
          theme = "ravnix";
          themes.ravnix = theme;
        };
      }
    )
  ];
}
