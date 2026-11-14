# btop's colors, from the roles. The theme file is generated (the catppuccin/nix
# port has four box colors and no accent), the configuration selects it, and
# the port is off. Rendered with the Mauve and the Teal accent, the file holds
# only palette colors and the accent slots are the only ones that move.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ../common/helpers/hm.nix { inherit self inputs pkgs lib; };
  colors = import ./helpers/colors.nix { inherit pkgs lib; };

  configOf = accent: (hm [ { ravnix.theme.accent = lib.mkForce accent; } ]).config;
  mauve = configOf "mauve";
  teal = configOf "teal";
  inherit (mauve.ravnix.theme) palette roles;

  textOf = c: builtins.readFile c.xdg.configFile."btop/themes/ravnix.theme".source;
  # theme[name]="#rrggbb" lines, as name -> color.
  slots =
    text:
    lib.listToAttrs (
      map (m: lib.nameValuePair (lib.elemAt m 0) (lib.elemAt m 1)) (
        lib.filter (m: m != null) (map (builtins.match ''theme\[([a-z_]+)]="(#[0-9a-f]{6})".*'') (lib.splitString "\n" text))
      )
    );
  s = slots (textOf mauve);
  st = slots (textOf teal);

  # The theme keys btop 1.4.8 reads, from its own default theme.
  wanted = [
    "main_bg"
    "main_fg"
    "title"
    "hi_fg"
    "selected_bg"
    "selected_fg"
    "inactive_fg"
    "graph_text"
    "meter_bg"
    "proc_misc"
    "cpu_box"
    "mem_box"
    "net_box"
    "proc_box"
    "div_line"
  ]
  ++ lib.concatMap (g: map (p: "${g}_${p}") [ "start" "mid" "end" ]) [
    "temp"
    "cpu"
    "free"
    "cached"
    "available"
    "used"
    "download"
    "upload"
    "process"
  ];
  missing = lib.filter (k: !(s ? ${k})) wanted;

  boxes = [
    "cpu_box"
    "mem_box"
    "net_box"
    "proc_box"
  ];
  followAccent = [
    "hi_fg"
    "selected_fg"
    "cpu_start"
    "process_start"
    "used_start"
    "download_start"
  ];

  extra =
    lib.optional (missing != [ ]) "theme keys missing: ${toString missing}"
    ++ lib.optional (mauve.programs.btop.settings.color_theme or null != "ravnix") "color_theme is not ravnix"
    ++ lib.optional (mauve.catppuccin.btop.enable) "the catppuccin port of btop is still on"
    # Boxes outline in Surface2: btop has no focus, so no box may claim it, and
    # none is a state hue (the port's Green, Maroon and Blue).
    ++ lib.concatMap (
      k: lib.optional (s.${k} or null != roles.line) "${k} is ${toString (s.${k} or null)}, not Surface2"
    ) boxes
    ++ lib.concatMap (
      k:
      lib.optional (s.${k} or null != roles.accent) "${k} is not the accent"
      ++ lib.optional (st.${k} or null != teal.ravnix.theme.roles.accent) "${k} does not follow the accent"
    ) followAccent
    # Warm hues only at the end of a gradient: Peach and Red mean a warning,
    # so no gradient starts or passes through one. btop picks the temperature
    # color at temp / temp_max, so a Peach middle is drawn at about half the
    # critical temperature, an idle machine.
    ++ lib.concatMap (
      k:
      lib.optional (lib.elem s.${k} [
        palette.peach
        palette.red
        palette.maroon
      ]) "${k} is a warm hue before the end of a gradient"
    ) (lib.filter (k: lib.hasSuffix "_start" k || lib.hasSuffix "_mid" k) (lib.attrNames s))
    ++ lib.optional (s.selected_bg != roles.selected) "selected_bg is not Surface1"
    ++ lib.optional (s.main_bg != roles.canvas) "main_bg is not Base";
in
colors.check "theme-btop" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
}
