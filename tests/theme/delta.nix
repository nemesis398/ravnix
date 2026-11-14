# delta's colors, from the roles (git's pager, lazygit's diff renderer). A
# diff line is a wash of its state hue over Base with the syntax colors kept,
# the words that changed a stronger wash, and nothing is plain ANSI red or
# green bold. delta's own defaults paint file names and hunk headers Blue,
# which is the busy state, so those are set too: a file name is Subtext1, a
# hunk's position the accent. Rendered with the Mauve and the Teal accent, the
# git config holds only palette colors (and the washes) and only the accent
# slots move.
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
  color = import ../../modules/theme/color.nix { inherit lib; };

  configOf = accent: (hm [ { ravnix.theme.accent = lib.mkForce accent; } ]).config;
  mauve = configOf "mauve";
  teal = configOf "teal";
  inherit (mauve.ravnix.theme) palette roles;

  textOf = c: builtins.readFile c.xdg.configFile."git/config".source;
  deltaOf = c: c.programs.git.settings.delta;
  d = deltaOf mauve;
  dt = deltaOf teal;

  wash =
    percent: hue:
    color.mix {
      over = roles.canvas;
      tint = hue;
      inherit percent;
    };
  washes = lib.concatMap (hue: map (p: wash p hue) [ 20 35 ]) [
    palette.green
    palette.red
  ];

  ansi = [
    "red"
    "green"
    "yellow"
    "blue"
    "magenta"
    "cyan"
    "white"
  ];

  extra =
    lib.optional (
      d.minus-style != "syntax ${wash 20 palette.red}"
    ) "a removed line is not Red washed 20 % over Base: ${toString d.minus-style}"
    ++ lib.optional (
      d.plus-style != "syntax ${wash 20 palette.green}"
    ) "an added line is not Green washed 20 % over Base: ${toString d.plus-style}"
    ++ lib.optional (
      d.minus-emph-style != "bold syntax ${wash 35 palette.red}"
    ) "a removed word is not Red washed 35 %: ${toString d.minus-emph-style}"
    ++ lib.optional (
      d.plus-emph-style != "bold syntax ${wash 35 palette.green}"
    ) "an added word is not Green washed 35 %: ${toString d.plus-emph-style}"
    # Nothing is left of the ANSI names the old config used (red bold, green
    # bold, yellow): every color of a style is a hex.
    ++ lib.concatMap (
      k:
      let
        bare = lib.filter (w: lib.elem w ansi) (lib.splitString " " (toString d.${k}));
      in
      lib.optional (bare != [ ]) "${k} still names an ANSI color: ${toString d.${k}}"
    ) (lib.filter (k: lib.hasSuffix "-style" k) (lib.attrNames d))
    # The hunk's position and the file name are not delta's default Blue.
    ++ lib.optional (
      !lib.hasInfix roles.accent (toString d.hunk-header-line-number-style)
    ) "the hunk position is not the accent"
    ++ lib.optional (
      !lib.hasInfix teal.ravnix.theme.roles.accent (toString dt.hunk-header-line-number-style)
    ) "the hunk position does not follow the accent"
    ++ lib.optional (!lib.hasInfix roles.label (toString d.file-style)) "the file name is not Subtext1"
    ++ lib.optional (!lib.hasInfix roles.label (toString d.hunk-header-file-style)) "the hunk's file is not Subtext1"
    # Frames are Surface2, not the default blue box.
    ++ lib.optional (
      !lib.hasInfix roles.line (toString d.hunk-header-decoration-style)
    ) "the hunk header's decoration is not Surface2"
    ++ lib.optional (
      !lib.hasInfix roles.line (toString d.file-decoration-style)
    ) "the file decoration is not Surface2"
    # No yellow as decoration: Yellow means pending.
    ++ lib.optional (lib.hasInfix "yellow" (toString d.hunk-header-style)) "the hunk header is yellow"
    ++ lib.optional (d.syntax-theme != "Catppuccin Mocha") "the syntax theme is not Catppuccin Mocha";
in
colors.check "theme-delta" {
  inherit palette extra;
  allowed = washes;
  mauve = textOf mauve;
  teal = textOf teal;
}
