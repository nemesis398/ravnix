# Handy's theme as the browser computes it (packages/handy, theme.nix): the
# frontend is built from the patched source, as the Handy build does, and its
# stylesheets are loaded into Helium, headless, under the settings that used to
# win over the appended block: Handy's own theme set to "light" (data-theme),
# and none at all, in a browser whose color preference is light.
# tests/desktop/handy-theme.nix reads the generated text; this one asks the
# cascade, because App.css comes after the block in the stylesheet and a plain
# declaration there beats a plain declaration here:
#
#   - color-scheme is dark (it was `light dark`, and `light` under data-theme),
#     so the native controls are dark;
#   - the log surface and both scrollbar thumb colors are the solid roles
#     (they were mixes with black and transparency, and followed the setting);
#   - the scrollbar thumb is square (a pseudo-element `*` does not match);
#   - Tailwind's white and black, which the switch knob, the radio mark and
#     the dialog scrim read, are Text and Crust;
#   - the overlay's surface is the background color, whatever the setting.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  handy = self.packages.${system}.handy;
  inherit (import ../../lib/default-theme.nix { inherit lib; }) roles palette;

  # "#rrggbb" as the string a browser serializes a computed color to.
  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "rgb(${byte 0}, ${byte 2}, ${byte 4})";

  expected = {
    scheme = "dark";
    background = rgb roles.canvas;
    logSurface = rgb roles.dock;
    thumb = rgb roles.line;
    thumbHover = rgb roles.placeholder;
    white = rgb roles.text;
    black = rgb palette.crust;
    thumbRadius = "0px";
    overlaySurface = rgb roles.canvas;
  };

  script = pkgs.writeText "probe.js" ''
    const norm = (v) => {
      const d = document.createElement("div");
      d.style.color = v;
      document.body.appendChild(d);
      return getComputedStyle(d).color;
    };
    const root = getComputedStyle(document.documentElement);
    const prop = (n) => norm(root.getPropertyValue(n).trim());
    const out = {
      scheme: root.colorScheme,
      background: prop("--color-background"),
      logSurface: prop("--color-log-surface"),
      thumb: prop("--scrollbar-thumb"),
      thumbHover: prop("--scrollbar-thumb-hover"),
      white: prop("--color-white"),
      black: prop("--color-black"),
      thumbRadius: getComputedStyle(document.getElementById("t"), "::-webkit-scrollbar-thumb").borderRadius,
      overlaySurface: prop("--s-surface"),
    };
    document.body.textContent = "RESULT " + JSON.stringify(out);
  '';
in
pkgs.runCommand "desktop-handy-theme-cascade"
  {
    nativeBuildInputs = [
      pkgs.bun
      pkgs.nodejs
      pkgs.writableTmpDirAsHomeHook
      pkgs.jq
      pkgs.gnugrep
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    cp -r ${handy.src} s
    chmod -R u+w s
    ( cd s
      ${handy.themePatch}
      cp -R ${handy.frontendDeps}/node_modules .
      chmod -R u+w node_modules
      patchShebangs node_modules
      bun run build >../build.log 2>&1 ) || { cat build.log; exit 1; }
    cp s/dist/assets/main-*.css main.css
    cp s/dist/assets/overlay-*.css overlay.css
    cp ${script} probe.js

    # The overlay's surface is read from the overlay's stylesheet, the rest
    # from the main one; both under the same settings.
    page() { # page NAME THEMEATTR -> the probe's JSON
      cat > "$1.html" <<HTML
    <!doctype html><html $2><head>
    <link rel="stylesheet" href="main.css"><link rel="stylesheet" href="overlay.css">
    <style>#t { width: 50px; height: 50px; overflow: scroll; }</style>
    </head><body><div id="t"><div style="height:500px"></div></div>
    <script src="probe.js"></script></body></html>
    HTML
      export HOME=$TMPDIR/home-$1 XDG_CONFIG_HOME=$TMPDIR/config-$1
      mkdir -p "$HOME" "$XDG_CONFIG_HOME"
      ${self.packages.${system}.helium}/bin/helium --headless=new --no-sandbox --disable-gpu \
        --virtual-time-budget=5000 --allow-file-access-from-files \
        --user-data-dir="$TMPDIR/profile-$1" --dump-dom "file://$PWD/$1.html" 2>/dev/null \
        | grep -o 'RESULT {.*}' | sed 's/^RESULT //' || true
    }
    expected='${builtins.toJSON expected}'
    for case in 'light data-theme="light"' 'system '; do
      name=''${case%% *}; attr=''${case#* }
      got=$(page "$name" "$attr")
      [ -n "$got" ] || { fail "$name: the probe wrote no result"; continue; }
      echo "$name: $got"
      for k in $(echo "$expected" | jq -r 'keys[]'); do
        want=$(echo "$expected" | jq -r --arg k "$k" '.[$k]')
        have=$(echo "$got" | jq -r --arg k "$k" '.[$k]')
        [ "$want" = "$have" ] || fail "$name: $k is '$have', not '$want'"
      done
    done

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
