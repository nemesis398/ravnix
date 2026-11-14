# Claude Code in the colors of the roles, on both hosts. Claude Code reads a
# custom theme from <configDir>/themes/<slug>.json, a name, a base theme and
# overrides, and selects it with `theme = "custom:<slug>"`; this module writes
# the file from ravnix.theme and the setting, so the one big thing on screen
# all day is no longer Anthropic's orange. Nothing here is a hex color: every
# slot reads a role or a palette entry.
#
# How the tokens are mapped (docs/style.md):
#   - the accent marks focus and place: the brand color and the spinner, the
#     prompt's border, the permission and suggestion highlights, a mode (auto
#     accept, plan, fast, bash), a skill, the progress bar, the mascot;
#   - state keeps its hue whatever the accent is: success Green, error Red,
#     warning Peach, a background task Blue; a diff line is a wash of Green or
#     Red over Base, its changed words a stronger wash;
#   - a row is a Surface wash: the user's message, a bash or memory message;
#   - nothing moves: a shimmer is the color it shimmers from, and the rainbow
#     of the ultrathink animation is one color, the accent;
#   - the text selection is Surface1, not an accent fill, because Claude
#     Code cannot give the selected text Crust (Text on the accent measures
#     about 1.4 to 1).
#
# An exception (docs/style.md, rule 9, decided by the maintainer on
# 2026-11-15): the eight colors Claude Code gives its subagents (red, blue,
# green, yellow, purple, orange, pink, cyan) keep their own hues, so a "red"
# agent is Red and an "orange" one Peach. That color is a name the user picks
# for an agent, which labels who it is and says nothing about its state, so it
# is neither a state nor the accent. The palette's hue stands in for each
# name; Mauve is left out (it is the default accent) and "purple" is Lavender.
# professionalBlue and chromeYellow follow the same reading.
#
# The slots are the tokens of the dark base theme in Claude Code 2.1.319, and
# Claude Code drops a name its base theme lacks, so a token it renames falls
# back to dark's value and is not an error. tests/theme/claude.nix lists the
# names it knows.
{ config, lib, ... }:
let
  inherit (config.ravnix.theme) palette roles;
  color = import ../theme/color.nix { inherit lib; };
  cfg = config.programs.claude-code;

  wash =
    percent: hue:
    color.mix {
      over = roles.canvas;
      tint = hue;
      inherit percent;
    };

  accent = roles.accent;
  overrides = {
    # Place and focus.
    claude = accent;
    claudeShimmer = accent;
    claudeBlue_FOR_SYSTEM_SPINNER = accent;
    claudeBlueShimmer_FOR_SYSTEM_SPINNER = accent;
    permission = accent;
    permissionShimmer = accent;
    suggestion = accent;
    remember = accent;
    promptBorder = accent;
    promptBorderShimmer = accent;
    autoAccept = accent;
    autoAcceptShimmer = accent;
    skill = accent;
    bashBorder = accent;
    planMode = accent;
    ide = accent;
    merged = accent;
    fastMode = accent;
    fastModeShimmer = accent;
    effortUltra = accent;
    briefLabelClaude = accent;
    rate_limit_fill = accent;
    clawd_body = accent;

    # Text.
    text = roles.text;
    inverseText = roles.deepest;
    inactive = roles.placeholder;
    inactiveShimmer = roles.placeholder;
    subtle = roles.muted;
    briefLabelYou = roles.label;

    # State.
    success = palette.green;
    error = palette.red;
    warning = palette.peach;
    warningShimmer = palette.peach;
    background = palette.blue;
    diffAdded = wash 20 palette.green;
    diffRemoved = wash 20 palette.red;
    diffAddedDimmed = wash 10 palette.green;
    diffRemovedDimmed = wash 10 palette.red;
    diffAddedWord = wash 35 palette.green;
    diffRemovedWord = wash 35 palette.red;

    # Surfaces.
    clawd_background = roles.canvas;
    userMessageBackground = roles.wash;
    userMessageBackgroundHover = roles.selected;
    composerSidebarBackground = roles.dock;
    selectionBg = roles.selected;
    bashMessageBackgroundColor = roles.wash;
    memoryBackgroundColor = roles.wash;
    rate_limit_empty = roles.wash;

    # The exception above: the hue a subagent's name says, whatever its state.
    red_FOR_SUBAGENTS_ONLY = palette.red;
    blue_FOR_SUBAGENTS_ONLY = palette.blue;
    green_FOR_SUBAGENTS_ONLY = palette.green;
    yellow_FOR_SUBAGENTS_ONLY = palette.yellow;
    purple_FOR_SUBAGENTS_ONLY = palette.lavender;
    orange_FOR_SUBAGENTS_ONLY = palette.peach;
    pink_FOR_SUBAGENTS_ONLY = palette.pink;
    cyan_FOR_SUBAGENTS_ONLY = palette.teal;
    professionalBlue = palette.blue;
    chromeYellow = palette.yellow;
  }
  # Nothing runs through a rainbow, shimmer included.
  // lib.listToAttrs (
    lib.concatMap
      (hue: [
        (lib.nameValuePair "rainbow_${hue}" accent)
        (lib.nameValuePair "rainbow_${hue}_shimmer" accent)
      ])
      [
        "red"
        "orange"
        "yellow"
        "green"
        "blue"
        "indigo"
        "violet"
      ]
  );
in
{
  config = lib.mkIf cfg.enable {
    home.file."${cfg.configDir}/themes/ravnix.json".text = builtins.toJSON {
      name = "ravnix";
      base = "dark";
      inherit overrides;
    };
    programs.claude-code.settings.theme = "custom:ravnix";
  };
}
