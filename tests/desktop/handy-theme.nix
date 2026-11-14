# Handy's theme (packages/handy, theme.nix): the colors of the interface come
# from the theme module's roles, the accent follows ravnix.theme.accent, every
# corner is square and the palette is the dark one whatever Handy's own theme
# setting says. The check runs the patch of the package on a copy of Handy's
# source, as the build does before it compiles the frontend, and reads the
# files that come out. It does not build Handy: the patch is the part that is
# ravnix's, and a Rust build of half an hour would add nothing to what is
# asserted here. (The build itself is the check `desktop-handy`.)
#
#   - With the default accent the Handy that nixpkgs-style callPackage gives
#     (self.packages.handy) and the one a host installs are the same
#     derivation, so a host with the default accent does not build Handy twice.
#   - The dark palette is the Mocha roles, in rgb(): text is Text, the
#     background is Base, the brand color and the primary action are the
#     accent, errors are Red, warnings Peach, success Green. The light
#     palette's variables carry the same values, and the active tokens follow.
#   - Teal as the accent gives teal in the brand color and the primary action,
#     and nothing else in the block changes.
#   - The appended block holds no hex color, no rgba(), no `transparent`, no
#     color-mix; the four radius tokens of App.css are 0, and so is the
#     radius of every element.
#   - The recording overlay's surface is opaque and its tint solid.
#   - The primary button's text is the background color (Crust-like on the
#     accent), not white.
#   - A source that no longer holds the text the patch replaces fails the
#     build instead of passing silently.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  mkHost =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ extra;
    };
  handyOf =
    h: (lib.findFirst (p: lib.getName p == "handy-launch") null h.config.environment.systemPackages).handy;

  mauve = mkHost [ ];
  teal = mkHost [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  inherit (mauve.config.ravnix.theme) roles palette;
  tealRoles = teal.config.ravnix.theme.roles;

  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "rgb(${byte 0} ${byte 2} ${byte 4})";

  # The source as Handy's build sees it after unpacking, with the package's
  # patch run in it.
  patched =
    handy:
    pkgs.runCommand "handy-themed-source" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
      cp -r ${handy.src} src-copy
      chmod -R u+w src-copy
      cd src-copy
      ${handy.themePatch}
      mkdir $out
      cp src/styles/theme.css src/App.css src/overlay/RecordingOverlay.css src/components/ui/Button.tsx $out/
      # The block the patch appended to theme.css, and to the overlay's file.
      { diff ${handy.src}/src/styles/theme.css src/styles/theme.css || true; } | sed -n 's/^> //p' > $out/theme-block.css
      { diff ${handy.src}/src/overlay/RecordingOverlay.css src/overlay/RecordingOverlay.css || true; } | sed -n 's/^> //p' > $out/overlay-block.css
    '';
  mauveSrc = patched (handyOf mauve);
  tealSrc = patched (handyOf teal);

in
assert
  (handyOf mauve).drvPath == self.packages.${system}.handy.drvPath
  || throw "a host with the default accent installs another Handy than self.packages.handy";
assert
  (handyOf teal).drvPath != (handyOf mauve).drvPath
  || throw "the accent does not reach Handy: teal and mauve hosts install the same derivation";
pkgs.runCommand "desktop-handy-theme"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
      pkgs.diffutils
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    has() { grep -qF -- "$2" "$1" || fail "$1 lacks: $2"; }
    hasnt() { ! grep -qF -- "$2" "$1" || fail "$1 holds: $2"; }

    block=${mauveSrc}/theme-block.css
    [ -s "$block" ] || fail "the patch appended nothing to theme.css"

    # The dark palette, in the roles.
    has "$block" '--dark-color-text: ${rgb roles.text};'
    has "$block" '--dark-color-background: ${rgb roles.canvas};'
    has "$block" '--dark-color-logo-primary: ${rgb roles.accent};'
    has "$block" '--dark-color-error: ${rgb palette.red};'
    has "$block" '--dark-color-warning: ${rgb palette.peach};'
    has "$block" '--dark-color-moss: ${rgb palette.green};'
    has "$block" '--color-background-ui: ${rgb roles.accent};'
    has "$block" 'color-scheme: dark;'
    has "$block" '--default-font-family: "${mauve.config.ravnix.theme.font}", monospace;'
    has ${mauveSrc}/overlay-block.css '--s-font: "${mauve.config.ravnix.theme.font}", monospace;'
    has "$block" '--font-ui: "${mauve.config.ravnix.theme.font}", monospace;'
    # The light palette carries the same values: the theme setting, "system"
    # or "light" included, shows the dark palette.
    has "$block" '--light-color-text: ${rgb roles.text};'
    has "$block" '--light-color-background: ${rgb roles.canvas};'
    has "$block" '--light-color-logo-primary: ${rgb roles.accent};'
    has "$block" '--light-color-error: ${rgb palette.red};'
    # Solid greys, from the roles, where Handy mixed its mid grey into
    # transparency.
    has "$block" '--color-ink-2: ${rgb roles.secondary};'
    has "$block" '--color-line-strong: ${rgb roles.line};'
    has "$block" '--color-line: ${rgb roles.wash};'
    has "$block" '--color-wash: ${rgb roles.wash};'

    # No hex, no alpha, no mixing in what the patch adds.
    if grep -Eq '#[0-9a-fA-F]{3,8}\b' "$block" ${mauveSrc}/overlay-block.css; then
      fail "the appended CSS holds a hex color"
    fi
    for word in rgba transparent color-mix opacity transition animation; do
      ! grep -q "$word" "$block" ${mauveSrc}/overlay-block.css || fail "the appended CSS holds $word"
    done

    # Square: the four tokens, Tailwind's own scale, and every element.
    for tok in panel card control chip; do
      grep -q -- "--radius-$tok: 0;" ${mauveSrc}/App.css || fail "--radius-$tok is not 0"
    done
    ! grep -Eq -- '--radius-(panel|card|control|chip): [1-9]' ${mauveSrc}/App.css || fail "a radius token kept its size"
    has "$block" '--radius-lg: 0;'
    has "$block" 'border-radius: 0 !important;'

    # The overlay: opaque surface, solid tint.
    has ${mauveSrc}/overlay-block.css '--s-surface: var(--color-background);'
    has ${mauveSrc}/overlay-block.css '--s-accent-soft: ${rgb roles.wash};'

    # The primary button reads on the accent.
    has ${mauveSrc}/Button.tsx 'text-background bg-background-ui'
    hasnt ${mauveSrc}/Button.tsx 'text-white bg-background-ui'

    # The accent follows: teal changes the brand color and the primary action,
    # and nothing else in the block.
    has ${tealSrc}/theme-block.css '--dark-color-logo-primary: ${rgb tealRoles.accent};'
    has ${tealSrc}/theme-block.css '--color-background-ui: ${rgb tealRoles.accent};'
    hasnt ${tealSrc}/theme-block.css '${rgb roles.accent}'
    diff <(sed 's/${rgb tealRoles.accent}/ACCENT/g' ${tealSrc}/theme-block.css) \
         <(sed 's/${rgb roles.accent}/ACCENT/g' "$block") >/dev/null \
      || fail "teal changes something besides the accent in the block"

    # A source that has changed under the patch stops the build: Button.tsx
    # without the text the patch replaces, and a theme.css without the file.
    cp -r ${(handyOf mauve).src} drift
    chmod -R u+w drift
    sed -i 's/text-white bg-background-ui/text-black bg-background-ui/' drift/src/components/ui/Button.tsx
    rc=0
    ( cd drift && ${(handyOf mauve).themePatch} ) >drift.log 2>&1 || rc=$?
    [ "$rc" != 0 ] || fail "the patch passed on a Button.tsx that lacks the text it replaces"

    [ "$failed" = 0 ] || exit 1
    touch $out
  ''
