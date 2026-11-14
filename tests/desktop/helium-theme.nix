# Helium's own theme (packages/helium-theme, `themeExtension` of
# packages/helium): the browser's frame is in the roles of the theme module and
# loads at every start, with no click at helium://extensions.
#
#   - The Helium a desktop host puts on the PATH passes exactly one
#     --load-extension, naming the theme directory of that host; the Helium of
#     the Chrome DevTools MCP server (the package without it) passes none.
#   - The manifest is a Chromium theme in the roles: Mantle for the frame, the
#     address bar and the buttons, Base for the toolbar, the accent on the
#     icons and the address. With the default accent the host's theme is
#     self.packages.helium-theme; another accent changes the accent entries
#     and nothing else.
#   - Run for real, headless: the host's Helium makes the theme the profile's
#     theme (extensions.theme in Preferences names the directory), also from a
#     read-only store path; the same browser without the flag has none. That is
#     the claim the wrapper rests on: Google Chrome 137 and later ignore
#     --load-extension, and Helium, a Chromium build without Google's branding,
#     has to be shown to honor it.
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

  mauve = mkHost [ ];
  teal = mkHost [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  inherit (mauve.config.ravnix.theme) roles;
  tealRoles = teal.config.ravnix.theme.roles;

  themeDirOf = h: (heliumOf h).themeExtension;
  colorsOf = h: (builtins.fromJSON (builtins.readFile "${themeDirOf h}/manifest.json")).theme.colors;
  rgbOf =
    hex:
    map (i: lib.fromHexString (builtins.substring i 2 (lib.removePrefix "#" hex))) [
      0
      2
      4
    ];

  plain = self.packages.${system}.helium;
  host = heliumOf mauve;

  page = pkgs.writeText "blank.html" "<!doctype html><title>x</title><body>x</body>";
in
assert
  themeDirOf mauve == self.packages.${system}.helium-theme
  || throw "a host with the default accent does not use self.packages.helium-theme";
assert
  colorsOf mauve == {
    frame = rgbOf roles.dock;
    frame_inactive = rgbOf roles.dock;
    frame_incognito = rgbOf roles.selected;
    frame_incognito_inactive = rgbOf roles.selected;
    bookmark_text = rgbOf roles.text;
    tab_background_text = rgbOf roles.label;
    tab_background_text_inactive = rgbOf roles.secondary;
    tab_background_text_incognito = rgbOf roles.label;
    tab_background_text_incognito_inactive = rgbOf roles.secondary;
    tab_text = rgbOf roles.text;
    toolbar = rgbOf roles.canvas;
    toolbar_button_icon = rgbOf roles.accent;
    omnibox_text = rgbOf roles.accent;
    omnibox_background = rgbOf roles.dock;
    ntp_background = rgbOf roles.canvas;
    ntp_link = rgbOf roles.accent;
    ntp_text = rgbOf roles.text;
    button_background = rgbOf roles.dock;
  }
  || throw "the theme's colors are not the roles";
assert
  colorsOf teal == colorsOf mauve // lib.genAttrs [ "toolbar_button_icon" "omnibox_text" "ntp_link" ] (_: rgbOf tealRoles.accent)
  || throw "teal changes something besides the accent entries";
assert
  rgbOf tealRoles.accent != rgbOf roles.accent || throw "teal and mauve are the same color";
pkgs.runCommand "desktop-helium-theme"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.python3
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    # The wrappers.
    [ "$(grep -o -- '--load-extension=' ${host}/bin/helium | wc -l)" = 1 ] \
      || fail "the host's Helium does not pass exactly one --load-extension"
    grep -qF -- '--load-extension=${themeDirOf mauve}' ${host}/bin/helium \
      || fail "the host's Helium does not load its theme directory"
    ! grep -q -- '--load-extension' ${plain}/bin/helium \
      || fail "the Helium without a theme passes --load-extension"
    [ -s ${themeDirOf mauve}/manifest.json ] || fail "the theme directory has no manifest"

    # Headless, for real. Preferences is written when the browser exits, which
    # --dump-dom does after the page is done.
    run() { # run NAME BROWSER -> the profile's Preferences
      export HOME=$TMPDIR/home-$1 XDG_CONFIG_HOME=$TMPDIR/config-$1
      mkdir -p "$HOME" "$XDG_CONFIG_HOME"
      "$2/bin/helium" --headless=new --no-sandbox --disable-gpu --virtual-time-budget=5000 \
        --user-data-dir="$TMPDIR/profile-$1" --dump-dom file://${page} >/dev/null 2>&1 || true
      echo "$TMPDIR/profile-$1/Default/Preferences"
    }
    theme() { # theme PREFERENCES KEY
      python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("extensions",{}).get("theme",{}).get(sys.argv[2],""))' "$1" "$2"
    }
    prefs=$(run themed ${host})
    [ -e "$prefs" ] || fail "the browser wrote no Preferences"
    [ "$(theme "$prefs" pack)" = "${themeDirOf mauve}" ] \
      || fail "the browser did not take the theme: pack is '$(theme "$prefs" pack)'"
    [ -n "$(theme "$prefs" id)" ] || fail "the theme has no extension id"
    prefs=$(run bare ${plain})
    [ -e "$prefs" ] || fail "the browser without the flag wrote no Preferences"
    [ -z "$(theme "$prefs" id)" ] || fail "the browser without the flag has a theme"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
