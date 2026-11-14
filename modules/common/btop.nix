# btop in the colors of the roles. The catppuccin/nix port is not used: it
# has no accent, and its four box outlines are Mauve, Green, Maroon and Blue,
# three of them state hues used as decoration. This theme is generated from
# ravnix.theme instead (docs/style.md):
#
#   - the accent marks focus and place: the shortcut letters, the selected
#     row's text, and the start of every graph, so a quiet machine draws in
#     the accent;
#   - a box outline is Surface2. btop has no focus that moves between boxes,
#     so no box claims the accent, and none is a state hue;
#   - state is a state hue: a load gradient runs in the accent and turns Peach
#     only at its top, and the temperature one turns Red only at the sensor's
#     critical value (btop draws the middle at half of it, an idle machine), so
#     when something on screen is warm, something is hot;
#   - the selected row is Surface1, the meter background a wash;
#   - the neutral series (the memory kinds, upload) differ in the step they
#     take on the ladder, not in a hue; download is the accent, the one series
#     that stands for place.
{ config, ... }:
let
  inherit (config.ravnix.theme) palette roles;

  slot = name: value: ''theme[${name}]="${value}"'';
  # A gradient is three slots: where it starts, passes the middle, and ends.
  gradient = name: start: mid: end: [
    (slot "${name}_start" start)
    (slot "${name}_mid" mid)
    (slot "${name}_end" end)
  ];
  flat = name: color: gradient name color color color;
  load = name: gradient name roles.accent roles.accent palette.peach;

  theme = builtins.concatStringsSep "\n" (
    [
      (slot "main_bg" roles.canvas)
      (slot "main_fg" roles.text)
      (slot "title" roles.label)
      (slot "hi_fg" roles.accent)
      (slot "selected_bg" roles.selected)
      (slot "selected_fg" roles.accent)
      (slot "inactive_fg" roles.muted)
      (slot "graph_text" roles.secondary)
      (slot "meter_bg" roles.wash)
      (slot "proc_misc" roles.secondary)
      (slot "cpu_box" roles.line)
      (slot "mem_box" roles.line)
      (slot "net_box" roles.line)
      (slot "proc_box" roles.line)
      (slot "div_line" roles.line)
    ]
    ++ gradient "temp" roles.accent roles.accent palette.red
    ++ load "cpu"
    ++ flat "free" roles.muted
    ++ flat "cached" roles.placeholder
    ++ flat "available" roles.secondary
    ++ load "used"
    ++ flat "download" roles.accent
    ++ flat "upload" roles.secondary
    ++ load "process"
  );
in
{
  programs.btop = {
    themes.ravnix = theme + "\n";
    settings.color_theme = "ravnix";
  };
}
