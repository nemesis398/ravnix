# aerc's colors, from the roles. The styleset is our own (the Catppuccin port
# has no accent, draws the border in Crust, which is invisible on Base, and
# marks links and diff hunks in Blue, a state hue). Rendered with the Mauve
# and the Teal accent, the styleset holds only palette colors and only the
# accent slots move: the selected tab, the border of a focused thing, links
# and search results.
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
  inherit (mauve.ravnix.theme) palette roles;

  files = c: lib.filterAttrs (n: _: lib.hasInfix "aerc/stylesets/" n) c.home.file;
  textOf =
    c:
    let
      f = files c;
    in
    if lib.attrNames f == [ "${c.xdg.configHome}/aerc/stylesets/ravnix" ] then
      f."${c.xdg.configHome}/aerc/stylesets/ravnix".text
    else
      throw "aerc has the stylesets ${toString (lib.attrNames f)}, want only ravnix";

  # name=#rrggbb lines, as name -> color.
  slotsOf =
    text:
    lib.listToAttrs (
      map (m: lib.nameValuePair (lib.elemAt m 0) (lib.elemAt m 1)) (
        lib.filter (m: m != null) (map (builtins.match "([^=#]+)=(#[0-9a-f]{6})") (lib.splitString "\n" text))
      )
    );
  s = slotsOf (textOf mauve);
  st = slotsOf (textOf teal);

  accentSlots = [
    "tab.selected.bg"
    "msglist_result.fg"
    "url.fg"
  ];
  want = {
    "default.fg" = roles.text;
    "default.bg" = roles.canvas;
    "tab.bg" = roles.dock;
    "tab.selected.fg" = roles.deepest;
    # The frame must show on Base: Surface2, never Crust.
    "border.fg" = roles.line;
    "msglist_*.selected.bg" = roles.selected;
    "dirlist_*.selected.bg" = roles.wash;
    "error.fg" = palette.red;
    "warning.fg" = palette.peach;
    "diff_add.fg" = palette.green;
    "diff_del.fg" = palette.red;
  };
  blue = palette.blue;

  extra =
    lib.concatMap (
      k:
      lib.optional (s.${k} or null != roles.accent) "${k} is ${toString (s.${k} or null)}, not the accent"
      ++ lib.optional (st.${k} or null != teal.ravnix.theme.roles.accent) "${k} does not follow the accent"
    ) accentSlots
    ++ lib.concatMap (
      k: lib.optional (s.${k} or null != want.${k}) "${k} is ${toString (s.${k} or null)}, want ${want.${k}}"
    ) (lib.attrNames want)
    ++ lib.optional (lib.elem blue (lib.attrValues s)) "Blue (a state) is used as a link or hunk color"
    ++ lib.optional (s."border.fg" or null == palette.crust) "the border is Crust, invisible on Base"
    ++ lib.optional (
      (mauve.programs.aerc.extraConfig.ui.styleset-name or null) != "ravnix"
    ) "ui.styleset-name is not ravnix"
    ++ lib.optional mauve.catppuccin.aerc.enable "the catppuccin port of aerc is still on"
    ++ lib.optional (
      (mauve.programs.aerc.extraConfig.ui.border-char-vertical or null) != "│"
    ) "the border is not the single light line";
in
colors.check "theme-aerc" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
}
