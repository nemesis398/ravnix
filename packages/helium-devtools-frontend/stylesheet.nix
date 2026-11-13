# The stylesheet of Helium's DevTools, made from the theme: the Fedora
# stylesheet (its repository's commit bc31106, catppuccin-mocha.css) with
# every color read from the theme module instead of written in hex, so the
# user's accent reaches it. The token list, the order, the selectors and the
# comments are Fedora's; tests/desktop/helium-devtools-stylesheet.nix compares
# the two declaration by declaration.
#
#   theme   { palette, roles, font } of config.ravnix.theme
#
# What is not Fedora's: colors are rgb(r g b), not hex (docs/style.md), the
# accent is roles.accent where Fedora had Mauve as the accent (Mauve stays where
# it is a hue of its own: the purple ramp and the keyword color), and
# --sys-color-inverse-primary, which Fedora set to Catppuccin Latte's Mauve
# (no color of the theme), is tone 40 of the primary ramp, DevTools' own value
# in dark mode.
{ lib, theme }:
let
  oklab = import ./oklab.nix { inherit lib; };
  inherit (theme) palette roles font;

  black = [
    0
    0
    0
  ];
  white = [
    255
    255
    255
  ];
  css = bytes: "rgb(${lib.concatMapStringsSep " " toString bytes})";
  translucent =
    bytes: percent: "rgb(${lib.concatMapStringsSep " " toString bytes} / ${toString percent}%)";

  r = lib.mapAttrs (_: oklab.bytes) roles;
  p = lib.mapAttrs (_: oklab.bytes) palette;

  # A hue palette: tone 80 is the color, mixed in OKLab toward Crust below
  # and toward white above; 0 is black, 10 Crust, 100 white.
  hueTone =
    color: tone:
    if tone == 0 then
      black
    else if tone == 10 then
      r.deepest
    else if tone < 80 then
      oklab.mix color r.deepest ((tone - 10) / 70.0)
    else if tone == 80 then
      color
    else if tone < 100 then
      oklab.mix white color ((tone - 80) / 20.0)
    else
      white;

  # A gray palette: the Mocha grays at their tones, 30 halfway between
  # Surface0 and Surface1, and above Text toward white.
  grays = {
    "0" = black;
    "10" = r.deepest;
    "15" = r.dock;
    "20" = r.canvas;
    "25" = r.wash;
    "30" = oklab.mix r.selected r.wash 0.5;
    "35" = r.selected;
    "40" = r.line;
    "50" = r.muted;
    "60" = r.placeholder;
    "70" = p.overlay2;
    "80" = r.label;
    "90" = r.text;
    "100" = white;
  };
  grayTone = tone: grays.${toString tone} or (oklab.mix white r.text ((tone - 90) / 10.0));

  hueTones = [
    0
    10
    20
    30
    40
    50
    60
    70
    80
    90
    95
    99
    100
  ];
  ramp =
    name: what: toneOf: tones:
    "  /* ${name}: ${what} */\n"
    + lib.concatMapStrings (
      tone: "  --ref-palette-${name}${toString tone}: ${css (toneOf tone)} !important;\n"
    ) tones;
  hue =
    name: what: color:
    ramp name what (hueTone color) hueTones;
  gray = name: ramp name "gray" grayTone;

  a = css r.accent;
  # A surface of Base tinted with a color, as Fedora mixes it.
  tint = color: percent: "color-mix(in srgb, ${css color} ${toString percent}%, ${css r.canvas})";
in
''
  /*
   * Catppuccin Mocha for Helium's DevTools: the accent, square corners,
   * ${font}.
   *
   * Linked last into every DevTools HTML entry point by build-frontend.py.
   * Made by packages/helium-devtools-frontend/stylesheet.nix from the theme
   * module, so a new accent is a new stylesheet. DevTools draws everything
   * from the design tokens in design_system_tokens.css and
   * application_tokens.css; this file overrides those tokens and adds nothing
   * else. Every declaration is !important, because the stock ones sit behind
   * more specific selectors (:root.platform-linux,
   * :root.baseline-grayscale.theme-with-dark-background).
   *
   * Colors apply in dark mode only (DevTools Settings > Appearance > Theme:
   * Dark, or System preference on this dark desktop). Light mode stays stock.
   */

  /* ── Shape and type: every mode ─────────────────────────────────────── */

  :root {
    --sys-shape-corner-extra-small: 0 !important;
    --sys-shape-corner-small: 0 !important;
    --sys-shape-corner-medium-small: 0 !important;
    --sys-shape-corner-medium: 0 !important;
    --sys-shape-corner-large: 0 !important;
    --sys-shape-corner-full: 0 !important;

    --default-font-family: '${font}', monospace !important;
    --monospace-font-family: '${font}', monospace !important;
    --source-code-font-family: '${font}', monospace !important;
  }

  /* About 80 rules hard-code a radius instead of using the tokens above. This
   * catches them in the main document; square-shadow-roots.js adds the same
   * rule to every shadow root, which a document stylesheet cannot reach. */
  *,
  *::before,
  *::after {
    border-radius: 0 !important;
  }

  /* ── Colors: dark mode ──────────────────────────────────────────────── */

  :root.theme-with-dark-background {
    /*
     * Reference palettes. Everything else, the Performance panel's category
     * colors included, derives from these tones. Hue palettes: tone 80 is the
     * Catppuccin color, mixed in OKLab toward Crust below and toward white
     * above. Gray palettes run through the Mocha grays (10 Crust, 15 Mantle,
     * 20 Base, 25 Surface0, 35 Surface1, 40 Surface2, 50/60/70 Overlay0-2,
     * 80 Subtext1, 90 Text).
     */
''
+ hue "primary" "the accent" r.accent
+ gray "secondary" [
  0
  10
  15
  20
  25
  30
  35
  40
  50
  60
  70
  80
  90
  95
  99
  100
]
+ hue "tertiary" "the accent" r.accent
+ gray "neutral" [
  0
  10
  15
  20
  25
  30
  40
  50
  60
  70
  80
  90
  94
  95
  98
  99
  100
]
+ gray "neutral-variant" [
  0
  10
  20
  30
  40
  50
  60
  70
  80
  90
  95
  99
  100
]
+ hue "error" "red" p.red
+ hue "blue" "blue" p.blue
+ hue "cyan" "sky" p.sky
+ hue "green" "green" p.green
+ hue "indigo" "lavender" p.lavender
+ hue "orange" "peach" p.peach
+ ramp "pink" "pink" (hueTone p.pink) (lib.sort lib.lessThan (hueTones ++ [ 55 ]))
+ hue "purple" "mauve" p.mauve
+ hue "yellow" "yellow" p.yellow
+ ''

    /*
     * System colors, pinned where the derived tone would layer the surfaces
     * differently from the rest of the desktop: panels on Base, toolbars and
     * tab strips on Mantle, raised things on Surface0.
     */
    --sys-color-cdt-base-container: ${css r.canvas} !important;
    --sys-color-base-container: ${css r.canvas} !important;
    --sys-color-cdt-base: ${css r.dock} !important;
    --sys-color-base: ${css r.dock} !important;
    --sys-color-surface: ${css r.dock} !important;
    --sys-color-omnibox-container: ${css r.dock} !important;
    --sys-color-base-container-elevated: ${css r.wash} !important;
    --sys-color-neutral-container: ${css r.wash} !important;
    --sys-color-header-container: ${css r.wash} !important;
    --sys-color-surface-variant: ${css r.selected} !important;
    --sys-color-surface1: ${tint r.accent 4} !important;
    --sys-color-surface2: ${tint r.accent 6} !important;
    --sys-color-surface3: ${tint r.accent 8} !important;
    --sys-color-surface4: ${tint r.accent 10} !important;
    --sys-color-surface5: ${tint r.accent 12} !important;

    --sys-color-on-surface: ${css r.text} !important;
    --sys-color-on-base: ${css r.text} !important;
    --sys-color-on-surface-subtle: ${css r.label} !important;
    --sys-color-on-surface-secondary: ${css r.secondary} !important;
    --sys-color-on-surface-primary: ${a} !important;
    --sys-color-on-surface-light: ${css r.placeholder} !important;
    --sys-color-on-surface-light-graphics: ${css r.muted} !important;

    --sys-color-primary: ${a} !important;
    --sys-color-on-primary: ${css r.deepest} !important;
    --sys-color-primary-bright: ${a} !important;
    --sys-color-secondary: ${css r.label} !important;
    --sys-color-on-secondary: ${css r.deepest} !important;
    --sys-color-tertiary: ${a} !important;
    --sys-color-on-tertiary: ${css r.deepest} !important;
    --sys-color-error: ${css p.red} !important;
    --sys-color-on-error: ${css r.deepest} !important;
    --sys-color-error-bright: ${css p.red} !important;

    --sys-color-tonal-container: ${tint r.accent 22} !important;
    --sys-color-on-tonal-container: ${css r.text} !important;
    --sys-color-tertiary-container: ${tint r.accent 22} !important;
    --sys-color-on-tertiary-container: ${css r.text} !important;
    --sys-color-error-container: ${tint p.red 22} !important;
    --sys-color-on-error-container: ${css p.red} !important;
    --sys-color-yellow-container: ${tint p.yellow 20} !important;
    --sys-color-on-yellow-container: ${css p.yellow} !important;

    --sys-color-surface-yellow: ${tint p.yellow 14} !important;
    --sys-color-surface-yellow-high: ${tint p.yellow 22} !important;
    --sys-color-surface-error: ${tint p.red 16} !important;
    --sys-color-surface-green: ${tint p.green 14} !important;
    --sys-color-on-surface-yellow: ${css p.yellow} !important;
    --sys-color-on-surface-error: ${css p.red} !important;
    --sys-color-on-surface-green: ${css p.green} !important;

    --sys-color-inverse-surface: ${css r.text} !important;
    --sys-color-inverse-on-surface: ${css r.deepest} !important;
    --sys-color-inverse-primary: ${css (hueTone r.accent 40)} !important;

    --sys-color-outline: ${css r.muted} !important;
    --sys-color-neutral-outline: ${css r.line} !important;
    --sys-color-tonal-outline: ${tint r.accent 50} !important;
    --sys-color-error-outline: ${css p.red} !important;
    --sys-color-divider: ${css r.wash} !important;
    --sys-color-on-base-divider: ${css r.wash} !important;
    --sys-color-divider-on-tonal-container: ${css r.selected} !important;
    --sys-color-divider-prominent: ${css r.line} !important;

    --sys-color-state-focus-ring: ${a} !important;
    --sys-color-state-focus-select: ${tint r.accent 40} !important;
    --sys-color-state-text-highlight: ${a} !important;
    --sys-color-state-on-text-highlight: ${css r.deepest} !important;
    --sys-color-state-header-hover: ${css r.wash} !important;
    --sys-color-state-on-header-hover: ${css r.text} !important;

    /* Accents for icons and text: the Catppuccin colors themselves. */
    --sys-color-blue-bright: ${css p.blue} !important;
    --sys-color-green-bright: ${css p.green} !important;
    --sys-color-orange-bright: ${css p.peach} !important;
    --sys-color-yellow-bright: ${css p.yellow} !important;
    --sys-color-cyan-bright: ${css p.sky} !important;
    --sys-color-purple-bright: ${css p.mauve} !important;
    --sys-color-pink-bright: ${css p.pink} !important;
    --sys-color-neutral-bright: ${css r.muted} !important;
    --sys-color-blue: ${css p.blue} !important;
    --sys-color-green: ${css p.green} !important;
    --sys-color-orange: ${css p.peach} !important;
    --sys-color-yellow: ${css p.yellow} !important;
    --sys-color-cyan: ${css p.sky} !important;
    --sys-color-purple: ${css p.mauve} !important;
    --sys-color-pink: ${css p.pink} !important;
    --sys-color-on-blue: ${css r.deepest} !important;
    --sys-color-on-green: ${css r.deepest} !important;
    --sys-color-on-orange: ${css r.deepest} !important;
    --sys-color-on-yellow: ${css r.deepest} !important;
    --sys-color-on-cyan: ${css r.deepest} !important;
    --sys-color-on-purple: ${css r.deepest} !important;
    --sys-color-on-pink: ${css r.deepest} !important;

    /* Syntax, after Catppuccin's style guide, as in Neovim. */
    --sys-color-token-keyword: ${css p.mauve} !important;
    --sys-color-token-string: ${css p.green} !important;
    --sys-color-token-string-special: ${css p.pink} !important;
    --sys-color-token-number: ${css p.peach} !important;
    --sys-color-token-atom: ${css p.peach} !important;
    --sys-color-token-builtin: ${css p.red} !important;
    --sys-color-token-type: ${css p.yellow} !important;
    --sys-color-token-definition: ${css p.blue} !important;
    --sys-color-token-variable: ${css r.text} !important;
    --sys-color-token-variable-special: ${css p.red} !important;
    --sys-color-token-property: ${css p.lavender} !important;
    --sys-color-token-property-special: ${css p.teal} !important;
    --sys-color-token-tag: ${css p.blue} !important;
    --sys-color-token-attribute: ${css p.yellow} !important;
    --sys-color-token-attribute-value: ${css p.green} !important;
    --sys-color-token-pseudo-element: ${css p.pink} !important;
    --sys-color-token-comment: ${css p.overlay2} !important;
    --sys-color-token-meta: ${css r.placeholder} !important;
    --sys-color-token-subtle: ${css r.placeholder} !important;
    --sys-color-token-deleted: ${css p.red} !important;
    --sys-color-token-inserted: ${css p.green} !important;

    /* Legacy tokens that application_tokens.css still hard-codes as RGB. The
     * two background ones and the stroke style are translucent on purpose:
     * DevTools draws them over its own canvases (the Network, Performance and
     * Profiler timelines), as the stock values are (the exception is listed
     * in modules/desktop/apps.nix). */
    --color-background: ${css r.canvas} !important;
    --color-background-opacity-50: ${translucent r.canvas 50} !important;
    --color-background-opacity-80: ${translucent r.canvas 80} !important;
    --color-background-elevation-1: ${css r.dock} !important;
    --color-background-elevation-2: ${css r.wash} !important;
    --color-text-primary: ${css r.text} !important;
    --color-text-secondary: ${css r.secondary} !important;
    --color-text-disabled: ${css r.muted} !important;
    --color-primary: ${a} !important;
    --color-primary-old: ${a} !important;
    --color-primary-variant: ${a} !important;
    --color-red: ${css p.red} !important;
    --color-error-text: ${css p.red} !important;
    --color-scrollbar-other: ${css r.selected} !important;
    --color-scrollbar-other-hover: ${css r.line} !important;
    --legacy-accent-color: ${a} !important;
    --legacy-focus-ring-inactive-shadow-color: ${css r.line} !important;
    --app-color-strokestyle: ${translucent r.accent 10} !important;
    --app-color-toolbar-background: ${css r.dock} !important;
  }
''
