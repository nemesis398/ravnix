# khal's colors, from the roles. khal draws ikhal with the terminal's ANSI
# palette unless the `[palette]` section gives each element a 24-bit color;
# this one is written from the roles. Rendered with the Mauve and the Teal
# accent, the config holds only palette colors and only the accent slots move:
# the day under the cursor, a focused button, the frame of what has focus,
# today. A focused row is Surface1, an alert is Crust on Red.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  server = import ./helpers/server.nix { inherit self inputs lib; };
  colors = import ./helpers/colors.nix { inherit pkgs lib; };

  mauve = (server "mauve" { }).config;
  teal = (server "teal" { }).config;
  sky = (server "sky" { }).config;
  inherit (mauve.ravnix.theme) palette roles;

  textOf = c: c.xdg.configFile."khal/config".text;

  # key='', '', '', '#fg', '#bg' lines of the palette, as key -> { fg, bg }.
  entriesOf =
    c:
    let
      # No other section has a line of this form.
      parse = builtins.match "([^=]+)='', '', '[a-z,]*', '(#[0-9a-f]{6})', '(#[0-9a-f]{6})'";
    in
    lib.listToAttrs (
      map (m: lib.nameValuePair (lib.elemAt m 0) {
        fg = lib.elemAt m 1;
        bg = lib.elemAt m 2;
      }) (lib.filter (m: m != null) (map parse (lib.splitString "\n" (textOf c))))
    );
  e = entriesOf mauve;
  et = entriesOf teal;

  accentFg = [
    "bright"
    "today"
    "frame focus"
    "frame focus color"
    "frame focus top"
    "mark"
  ];
  accentBg = [
    "button focused"
    "today focus"
    "editcp"
  ];
  want = {
    "list" = {
      fg = roles.text;
      bg = roles.canvas;
    };
    "list focused" = {
      fg = roles.text;
      bg = roles.selected;
    };
    "header" = {
      fg = roles.label;
      bg = roles.dock;
    };
    "alert" = {
      fg = roles.deepest;
      bg = palette.red;
    };
    "frame" = {
      fg = roles.line;
      bg = roles.canvas;
    };
  };
  entries = lib.attrNames e;
  noAnsi = lib.hasInfix "light red" (textOf mauve);

  extra =
    lib.optional (e == { }) "the config has no [palette] section"
    ++ lib.concatMap (
      k:
      lib.optional (e.${k}.fg or null != roles.accent) "${k} text is ${toString (e.${k}.fg or null)}, not the accent"
      ++ lib.optional (et.${k}.fg or null != teal.ravnix.theme.roles.accent) "${k} text does not follow the accent"
    ) accentFg
    ++ lib.concatMap (
      k:
      lib.optional (e.${k}.bg or null != roles.accent) "${k} fill is ${toString (e.${k}.bg or null)}, not the accent"
      ++ lib.optional (et.${k}.bg or null != teal.ravnix.theme.roles.accent) "${k} fill does not follow the accent"
    ) accentBg
    # Text on an accent fill is Crust.
    ++ lib.concatMap (
      k: lib.optional (e.${k}.fg or null != roles.deepest) "${k}: text on the accent fill is not Crust"
    ) accentBg
    ++ lib.concatMap (
      k: lib.optional ((e.${k} or null) != want.${k}) "${k} is not ${builtins.toJSON want.${k}}"
    ) (lib.attrNames want)
    # At most one accent fill per list: a focused button, today, the cursor are
    # three different lists; the list rows themselves never are.
    ++ lib.optional (
      (e."list focused".bg or null) == roles.accent || (e.list.bg or null) == roles.accent
    ) "a list row is an accent fill"
    # Every element ikhal's dark theme draws has an entry.
    ++ lib.optional (lib.length entries < 30) "only ${toString (lib.length entries)} elements are themed"
    ++ lib.optional noAnsi "an ANSI color name is left in the config";
in
colors.check "theme-khal" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
  sky = textOf sky;
}
