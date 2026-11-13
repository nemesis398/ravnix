# The stylesheet of Helium's DevTools (packages/helium-devtools-frontend,
# stylesheet.nix), as a laptop host hands it over: the Helium a desktop host
# installs carries a frontend whose stylesheet is made from that host's theme.
#
#   - With the default accent it is the stylesheet that works on Fedora
#     (fixtures/helium-devtools/fedora-catppuccin-mocha.css, from the Fedora
#     repository's commit bc31106), declaration for declaration and color for
#     color, the OKLab ramps included, in rgb() instead of hex. The one
#     declaration that differs is --sys-color-inverse-primary: Fedora had
#     Catppuccin Latte's Mauve, which is no color of the theme module, and it
#     is now what DevTools itself gives it in dark mode, tone 40 of the
#     primary ramp.
#   - It holds no hex color, every corner token is 0, and the style check
#     finds nothing in it but the three translucent tokens DevTools draws over
#     its own canvases (listed as an exception in modules/desktop/apps.nix).
#   - Another accent gives another stylesheet: the accent tokens and the
#     primary ramp follow it, while the purple ramp and the keyword color stay
#     Mauve, which is a hue of the syntax and no accent.
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
  heliumOf = h: lib.findFirst (p: lib.getName p == "helium") null h.config.environment.systemPackages;
  stylesheetOf = h: (heliumOf h).devtoolsFrontend.stylesheet;

  mauve = mkHost [ ];
  teal = mkHost [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  inherit (mauve.config.ravnix.theme) font;

  # "#rrggbb" as the rgb() the stylesheet writes.
  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "rgb(${byte 0} ${byte 2} ${byte 4})";
  inherit (mauve.config.ravnix.theme) palette;
  root = ":root.theme-with-dark-background";
in
pkgs.runCommand "desktop-helium-devtools-stylesheet"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.ripgrep
      pkgs.gnugrep
      pkgs.diffutils
    ];
    mauve = stylesheetOf mauve;
    teal = stylesheetOf teal;
    fedora = ./fixtures/helium-devtools/fedora-catppuccin-mocha.css;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    decls=${./helpers/css-declarations.py}

    echo "==> the default accent gives Fedora's stylesheet"
    python3 -I "$decls" "$fedora" \
      | sed 's/^\(${root} | --sys-color-inverse-primary\): .*/\1: rgb(89 75 112) !important/' > want
    python3 -I "$decls" "$mauve" > got || fail "the stylesheet cannot be read"
    [ "$(wc -l < want)" -gt 300 ] || fail "the Fedora stylesheet gave only $(wc -l < want) declarations"
    diff -u want got || fail "the stylesheet of the default accent is not Fedora's (want is Fedora's)"

    for name in mauve teal; do
      f=''${!name}
      echo "==> $name: no hex, square, the font, the style check"
      if grep -nE '#[0-9a-fA-F]{3,8}\b' "$f"; then fail "$name: a hex color in the stylesheet"; fi
      corners=$(grep -cE '^\s*--sys-shape-corner-[a-z-]+: 0 !important;$' "$f" || true)
      [ "$corners" = 6 ] || fail "$name: $corners corner tokens are 0, not 6"
      if grep -E -- '--sys-shape-corner-' "$f" | grep -vE ': 0 !important;$'; then fail "$name: a corner token is not 0"; fi
      grep -qF -- "--default-font-family: '${font}', monospace !important;" "$f" || fail "$name: the font is not ${font}"
      mkdir -p "style-$name"
      cp "$f" "style-$name/devtools.css"
      hits=$(cd "style-$name" && bash ${self}/scripts/check-style.sh . 2>/dev/null || true)
      printf '%s\n' "$hits" | sed 's/^/  style: /'
      [ "$(printf '%s\n' "$hits" | grep -c ':opacity$')" = 3 ] || fail "$name: the style check does not find exactly the three translucent tokens"
      if printf '%s\n' "$hits" | grep -v ':opacity$' | grep -q .; then fail "$name: the style check finds more than translucency"; fi
      for t in color-background-opacity-50 color-background-opacity-80 app-color-strokestyle; do
        grep -qE -- "^\s*--$t: rgb\(.* / [0-9]+%\) !important;$" "$f" || fail "$name: --$t is not the translucent token"
      done
    done

    echo "==> another accent, another stylesheet"
    cmp -s "$mauve" "$teal" && fail "Teal and Mauve give the same stylesheet"
    want() { # FILE NAME: TOKEN VALUE
      grep -qF -- "  --$3: $4 !important;" "$2" || fail "$1: --$3 is not $4: $(grep -F -- "--$3:" "$2")"
    }
    want teal "$teal" sys-color-primary '${rgb palette.teal}'
    want teal "$teal" ref-palette-primary80 '${rgb palette.teal}'
    want teal "$teal" ref-palette-tertiary80 '${rgb palette.teal}'
    want teal "$teal" sys-color-state-focus-ring '${rgb palette.teal}'
    want teal "$teal" sys-color-surface1 'color-mix(in srgb, ${rgb palette.teal} 4%, ${rgb palette.base})'
    want teal "$teal" legacy-accent-color '${rgb palette.teal}'
    want teal "$teal" ref-palette-purple80 '${rgb palette.mauve}'
    want teal "$teal" sys-color-purple '${rgb palette.mauve}'
    want teal "$teal" sys-color-token-keyword '${rgb palette.mauve}'
    want mauve "$mauve" sys-color-primary '${rgb palette.mauve}'
    if grep -E -- '--sys-color-(primary|tertiary|state-focus-ring|on-surface-primary):' "$teal" | grep -qF '${rgb palette.mauve}'; then
      fail "teal: an accent token is still Mauve"
    fi

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
