# Handy's interface in the theme: the CSS that the package appends to Handy's
# own, made from ravnix.theme (docs/style.md).
#
#   theme   { palette, roles, font } of config.ravnix.theme
#
# Handy's colors are all in src/styles/theme.css as `--light-color-*` and
# `--dark-color-*` pairs, and the active `--color-*` tokens and the overlay's
# `--s-*` read from those. The block below comes last in the file, so it wins
# at equal specificity and nothing of Handy's own CSS has to be edited:
#
#   - Both palettes get the same values, the dark ones: whatever Handy's
#     `theme` setting says (system, light, dark), and whatever the GTK
#     preference is, the interface is the Mocha one. That is the pin to dark;
#     the setting stays in the UI and has no visible effect.
#   - text is Text, background Base, the brand color and the primary action the
#     accent; error is Red, warning Peach, success Green (the state hues).
#   - Handy mixes its mid grey into transparency for secondary text, edges and
#     hover fills; those tokens become solid roles instead (opaque, docs/
#     style.md).
#   - The font is the one family of the system (Tailwind's default family, which the page
#     inherits, and Handy's own --font-ui, --font-display and --font-cjk-subset
#     stacks; the overlay's --s-font).
#   - App.css is imported before its own rules, so what it sets again after this
#     block (color-scheme, the log surface, the scrollbar thumb, which it mixes
#     into transparency) is taken with !important; `*` does not match the
#     scrollbar thumb, so that gets a rule of its own.
#   - Every radius is 0: Tailwind's scale, then every element.
#
# Colors are rgb(r g b), as in the DevTools stylesheet, so the CSS holds no hex.
{ lib, theme }:
let
  inherit (theme) palette roles font;

  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "rgb(${byte 0} ${byte 2} ${byte 4})";

  # Each color of the palette, for both pairs.
  pairs = {
    text = roles.text;
    background = roles.canvas;
    logo-primary = roles.accent;
    warning = palette.peach;
    error = palette.red;
    moss = palette.green;
    plum = roles.text;
    wordmark-stroke = roles.text;
    mascot-line = roles.canvas;
  };
  pairLines = lib.concatStringsSep "\n  " (
    lib.concatMap (name: [
      "--light-color-${name}: ${rgb pairs.${name}};"
      "--dark-color-${name}: ${rgb pairs.${name}};"
    ]) (lib.attrNames pairs)
  );

  # Tailwind's default radius scale; the utilities rounded-sm to rounded-3xl
  # read it. rounded-full is a literal, and the last rule below takes it.
  scale = lib.concatMapStringsSep "\n  " (n: "--radius-${n}: 0;") [
    "xs"
    "sm"
    "md"
    "lg"
    "xl"
    "2xl"
    "3xl"
    "4xl"
  ];
in
{
  css = ''

    /* ravnix: Handy in the theme of the system (packages/handy/theme.nix). */
    :root {
      color-scheme: dark !important;

      ${pairLines}

      --color-background-ui: ${rgb roles.accent};
      --color-mid-gray: ${rgb roles.placeholder};
      --color-ink-2: ${rgb roles.secondary};
      --color-ink-3: ${rgb roles.placeholder};
      --color-line-strong: ${rgb roles.line};
      --color-line: ${rgb roles.wash};
      --color-wash: ${rgb roles.wash};
      --color-plum-pick: ${rgb roles.accent};
      --color-plum-faint: ${rgb roles.wash};

      /* App.css comes after this block and sets these again, by the media
         query and by data-theme, so a plain declaration here would lose. */
      --color-log-surface: ${rgb roles.dock} !important;
      --scrollbar-thumb: ${rgb roles.line} !important;
      --scrollbar-thumb-hover: ${rgb roles.placeholder} !important;

      ${scale}

      --default-font-family: "${font}", monospace;
      --font-sans: "${font}", monospace;
      --font-ui: "${font}", monospace;
      --font-display: "${font}", monospace;
      --font-cjk-subset: "Handy CJK Subset", "${font}", monospace;
    }

    *,
    *::before,
    *::after,
    ::-webkit-scrollbar-thumb {
      border-radius: 0 !important;
    }
  '';

  # The recording overlay sets its own surface and tint after it imports
  # theme.css, so these come last in its file.
  overlayCss = ''

    /* ravnix: an opaque surface and a solid tint (packages/handy/theme.nix). */
    :root {
      --s-surface: var(--color-background);
      --s-accent-soft: ${rgb roles.wash};
      --s-font: "${font}", monospace;
    }
  '';
}
