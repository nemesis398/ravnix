# fzf's colors, from the roles. fzf takes them in FZF_DEFAULT_OPTS, which
# home-manager writes from programs.fzf.colors. Rendered with the Mauve and
# the Teal accent, the option holds only palette colors, and the accent slots
# (match, pointer, prompt, marker, info, spinner) are the only ones that move.
# The selection is a Surface1 row, not fzf's ANSI-256 grey.
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
  sky = configOf "sky";
  inherit (mauve.ravnix.theme) palette roles;

  optsOf = c: c.home.sessionVariables.FZF_DEFAULT_OPTS;
  # --color name:#rrggbb,... as name -> color.
  slotsOf =
    c:
    let
      m = builtins.match ".*--color ([^ ]+).*" (optsOf c);
    in
    if m == null then
      { }
    else
      lib.listToAttrs (
        map (
          kv:
          let
            p = lib.splitString ":" kv;
          in
          lib.nameValuePair (lib.head p) (lib.last p)
        ) (lib.splitString "," (lib.head m))
      );
  s = slotsOf mauve;
  st = slotsOf teal;

  accentSlots = [
    "hl"
    "hl+"
    "info"
    "prompt"
    "pointer"
    "marker"
    "spinner"
  ];
  extra =
    lib.optional (s == { }) "FZF_DEFAULT_OPTS has no --color"
    ++ lib.concatMap (
      k:
      lib.optional (s.${k} or null != roles.accent) "${k} is ${toString (s.${k} or null)}, not the accent"
      ++ lib.optional (st.${k} or null != teal.ravnix.theme.roles.accent) "${k} does not follow the accent"
    ) accentSlots
    ++ lib.optional (s.fg or null != roles.text) "fg is not Text"
    ++ lib.optional (s.bg or null != roles.canvas) "bg is not Base"
    ++ lib.optional (s."bg+" or null != roles.selected) "the selected row is not Surface1"
    ++ lib.optional (s."fg+" or null != roles.text) "the selected row's text is not Text"
    ++ lib.optional (s.border or null != roles.line) "border is not Surface2"
    # The match is the accent and nothing reads as a state: no slot is a warm
    # hue, Blue or Green.
    ++ lib.concatMap (
      k:
      lib.optional (lib.elem s.${k} (
        map (n: palette.${n}) [
          "red"
          "maroon"
          "peach"
          "yellow"
          "green"
          "blue"
        ]
      )) "${k} is a state hue"
    ) (lib.attrNames s);
in
colors.check "theme-fzf" {
  inherit palette extra;
  mauve = optsOf mauve;
  teal = optsOf teal;
  sky = optsOf sky;
}
