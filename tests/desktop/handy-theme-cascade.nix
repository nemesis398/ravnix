# Handy's theme as the browser computes it (packages/handy, theme.nix): the
# frontend is built from the patched source, as the Handy build does, and its
# stylesheets are loaded into Helium, headless, the way Handy loads them: the
# settings window gets main.css alone and the recording overlay overlay.css
# alone. They must not share a page: overlay.css carries its own copy of
# theme.css, appended block included, after App.css's rules, so a page with
# both would let that copy win on order alone and hide a missing !important.
#
# Three settings, each for both windows:
#   - Handy's own theme set to "light" (data-theme), a light OS preference;
#   - no setting ("system"), a light OS preference;
#   - no setting ("system"), a dark OS preference: huginn's real state, where
#     App.css's prefers-color-scheme rule sets the log surface again.
# The probe reports the preference it ran under, and the case checks it.
#
# tests/desktop/handy-theme.nix reads the generated text; this one asks the
# cascade, because App.css comes after the block in main.css and a plain
# declaration there beats a plain declaration here:
#
#   - color-scheme is dark in both windows;
#   - the log surface and both scrollbar thumb colors are the solid roles
#     (they were mixes with black and transparency, and followed the setting);
#   - the scrollbar thumb is square (a pseudo-element `*` does not match);
#   - Tailwind's white and black, which the switch knob, the radio mark and
#     the dialog scrim read, are Text and Crust;
#   - the overlay's surface and tint are solid roles and its card is square.
#
# The probe's page has a sentinel text color, no role's, so a variable that is
# missing or invalid (it resolves to nothing, and the probe element inherits)
# cannot pass as Text.
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
    main = {
      scheme = "dark";
      background = rgb roles.canvas;
      logSurface = rgb roles.dock;
      thumb = rgb roles.line;
      thumbHover = rgb roles.placeholder;
      white = rgb roles.text;
      black = rgb palette.crust;
      thumbRadius = "0px";
    };
    overlay = {
      scheme = "dark";
      background = rgb roles.canvas;
      overlaySurface = rgb roles.canvas;
      overlayTint = rgb roles.wash;
      cardRadius = "0px";
    };
  };

  # NAME, the attribute of <html>, and 1 for a dark OS preference.
  cases = [
    "light|data-theme=\"light\"|0"
    "system-light||0"
    "system-dark||1"
  ];

  script = pkgs.writeText "probe.js" ''
    // The text color of the page is no role's: a value that resolves to
    // nothing inherits it and shows.
    const sentinel = "rgb(1, 2, 3)";
    document.body.style.color = sentinel;
    const norm = (v) => {
      const d = document.createElement("div");
      d.style.color = v;
      document.body.appendChild(d);
      return getComputedStyle(d).color;
    };
    const root = getComputedStyle(document.documentElement);
    const prop = (n) => norm(root.getPropertyValue(n).trim());
    const radius = (el, pseudo) => (el ? getComputedStyle(el, pseudo).borderRadius : "no element");
    const out = {
      prefersDark: matchMedia("(prefers-color-scheme: dark)").matches,
      scheme: root.colorScheme,
      background: prop("--color-background"),
      logSurface: prop("--color-log-surface"),
      thumb: prop("--scrollbar-thumb"),
      thumbHover: prop("--scrollbar-thumb-hover"),
      white: prop("--color-white"),
      black: prop("--color-black"),
      thumbRadius: radius(document.getElementById("t"), "::-webkit-scrollbar-thumb"),
      overlaySurface: prop("--s-surface"),
      overlayTint: prop("--s-accent-soft"),
      cardRadius: radius(document.querySelector(".scard"), null),
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
    cases=()

    # One window per page, one browser per page. Blink's preferredColorScheme
    # is 0 for dark and 1 for light; the probe reports what it got.
    page() { # page NAME KIND(main|overlay) HTMLATTR DARK -> the probe's JSON
      cat > "$1.html" <<HTML
    <!doctype html><html $3><head>
    <link rel="stylesheet" href="$2.css">
    <style>#t { width: 50px; height: 50px; overflow: scroll; }</style>
    </head><body><div id="t"><div style="height:500px"></div></div>
    <div class="scard"></div>
    <script src="probe.js"></script></body></html>
    HTML
      export HOME=$TMPDIR/home-$1 XDG_CONFIG_HOME=$TMPDIR/config-$1
      mkdir -p "$HOME" "$XDG_CONFIG_HOME"
      ${self.packages.${system}.helium}/bin/helium --headless=new --no-sandbox --disable-gpu \
        --virtual-time-budget=5000 --allow-file-access-from-files \
        --blink-settings=preferredColorScheme=$((1 - $4)) \
        --user-data-dir="$TMPDIR/profile-$1" --dump-dom "file://$PWD/$1.html" 2>/dev/null \
        | grep -o 'RESULT {.*}' | sed 's/^RESULT //' || true
    }
    expected='${builtins.toJSON expected}'
    ${lib.concatMapStringsSep "
" (c: "cases+=('${c}')") cases}
    for kind in main overlay; do
      for case in "''${cases[@]}"; do
        IFS='|' read -r cname attr dark <<<"$case"
        name=$kind-$cname
        got=$(page "$name" "$kind" "$attr" "$dark")
        [ -n "$got" ] || { fail "$name: the probe wrote no result"; continue; }
        echo "$name: $got"
        want_pref=$([ "$dark" = 1 ] && echo true || echo false)
        [ "$(echo "$got" | jq -r .prefersDark)" = "$want_pref" ] \
          || fail "$name: the browser did not run with prefersDark=$want_pref"
        for k in $(echo "$expected" | jq -r --arg kind "$kind" '.[$kind] | keys[]'); do
          want=$(echo "$expected" | jq -r --arg kind "$kind" --arg k "$k" '.[$kind][$k]')
          have=$(echo "$got" | jq -r --arg k "$k" '.[$k]')
          [ "$want" = "$have" ] || fail "$name: $k is '$have', not '$want'"
        done
      done
    done

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
