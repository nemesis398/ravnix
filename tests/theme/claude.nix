# Claude Code's colors, from the roles. The theme is a file in its themes
# directory (a custom theme: a name, a base and overrides, which Claude Code
# reads as `custom:<slug>`), and the settings select it. Rendered with the
# Mauve and the Teal accent, the file has only palette colors, and the accent
# slots are the only ones that move. The state slots keep their hues whatever
# the accent is, nothing shimmers or runs through a rainbow, and a token the
# base theme does not know is no key (Claude Code would drop it silently).
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

  file = c: c.home.file."${c.programs.claude-code.configDir}/themes/ravnix.json";
  textOf = c: builtins.readFile (file c).source;
  themeOf = c: builtins.fromJSON (textOf c);
  o = (themeOf mauve).overrides;
  ot = (themeOf teal).overrides;

  # The tokens that mean "where you are" or "what this is": the accent.
  accentSlots = [
    "claude"
    "claudeShimmer"
    "claudeBlue_FOR_SYSTEM_SPINNER"
    "claudeBlueShimmer_FOR_SYSTEM_SPINNER"
    "permission"
    "permissionShimmer"
    "suggestion"
    "remember"
    "promptBorder"
    "promptBorderShimmer"
    "autoAccept"
    "autoAcceptShimmer"
    "skill"
    "bashBorder"
    "planMode"
    "rate_limit_fill"
    "clawd_body"
    "ide"
    "merged"
    "fastMode"
    "effortUltra"
    "briefLabelClaude"
  ];
  # What must not follow the accent: state, and the neutral ladder.
  fixed = {
    success = palette.green;
    error = palette.red;
    warning = palette.peach;
    warningShimmer = palette.peach;
    text = roles.text;
    inverseText = roles.deepest;
    inactive = roles.placeholder;
    subtle = roles.muted;
    userMessageBackground = roles.wash;
    userMessageBackgroundHover = roles.selected;
    composerSidebarBackground = roles.dock;
    selectionBg = roles.selected;
    rate_limit_empty = roles.wash;
  };

  # Every token the base theme dark has, as the names in the binary of 2.1.319.
  # An unknown name is dropped by Claude Code, so the names are checked here.
  known = lib.splitString " " (builtins.readFile ./helpers/claude-tokens.txt);
  unknown = lib.filter (k: !(lib.elem k known)) (lib.attrNames o);
  rainbows = lib.filter (k: lib.hasPrefix "rainbow_" k) (lib.attrNames o);

  settings = mauve.programs.claude-code.settings;

  # The diff washes are the one place a color is computed: a state hue over
  # Base. Written out once here, so a change of the arithmetic is noticed.
  washes = [
    (color.mix { over = roles.canvas; tint = palette.green; percent = 20; })
    (color.mix { over = roles.canvas; tint = palette.green; percent = 10; })
    (color.mix { over = roles.canvas; tint = palette.green; percent = 35; })
    (color.mix { over = roles.canvas; tint = palette.red; percent = 20; })
    (color.mix { over = roles.canvas; tint = palette.red; percent = 10; })
    (color.mix { over = roles.canvas; tint = palette.red; percent = 35; })
  ];

  extra =
    lib.optional ((themeOf mauve).base != "dark") "base is not dark"
    ++ lib.optional (unknown != [ ]) "tokens Claude Code does not know: ${toString unknown}"
    ++ lib.optional (
      o.diffAdded != "#394545"
    ) "a diff line is ${o.diffAdded}, not 20 % of Green over Base (#394545)"
    ++ lib.optional (
      settings.theme or null != "custom:ravnix"
    ) "settings.theme is ${toString (settings.theme or null)}, not custom:ravnix"
    ++ lib.concatMap (
      k:
      lib.optional (o.${k} or null != roles.accent) "${k} is ${toString (o.${k} or null)}, not the accent"
      ++ lib.optional (ot.${k} or null != teal.ravnix.theme.roles.accent) "${k} does not follow the accent"
    ) accentSlots
    ++ lib.concatMap (
      k:
      lib.optional (o.${k} or null != fixed.${k}) "${k} is ${toString (o.${k} or null)}, want ${fixed.${k}}"
      ++ lib.optional (ot.${k} or null != fixed.${k}) "${k} moves with the accent"
    ) (lib.attrNames fixed)
    # Nothing runs through a rainbow: all of it is one color, so the
    # ultrathink animation has nothing to animate.
    ++ lib.optional (
      rainbows == [ ] || lib.length (lib.unique (map (k: o.${k}) rainbows)) != 1
    ) "the rainbow tokens are not one color"
    # A shimmer is its base color: nothing moves (docs/style.md).
    ++ lib.concatMap (
      k:
      let
        base = lib.removeSuffix "Shimmer" k;
      in
      lib.optional (o.${k} != o.${base}) "${k} differs from ${base}"
    ) (lib.filter (k: lib.hasSuffix "Shimmer" k && o ? ${lib.removeSuffix "Shimmer" k}) (lib.attrNames o));
in
colors.check "theme-claude" {
  inherit palette extra;
  allowed = washes;
  mauve = textOf mauve;
  teal = textOf teal;
}
