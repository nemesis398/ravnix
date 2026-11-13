# Helium's DevTools in the theme (packages/helium-devtools-frontend): the
# frontend a laptop host builds, the parser it is built with, which launchers
# start Helium with it and which does not, and how DevTools then look in a
# running Helium.
#
#   - The frontend is Helium's own: 859 files read from the unpatched binary
#     and resources.pak of Helium's tarball, the two theme files, both linked
#     into all 8 HTML entry points (the script before DevTools' own module
#     script, the stylesheet before <body>), and .complete. The stylesheet
#     overrides every corner token the stock tokens file defines, so a corner
#     token a new Helium adds is not left round.
#   - build-frontend.py on a truncated, empty, missing or foreign binary, and on
#     a pak that is empty or cut short, fails, and leaves no frontend behind.
#     A pak cut at the start of a resource once wrote that resource as an
#     empty file and finished with exit status 0.
#   - The Helium of the host's PATH, which helium.desktop and every web app
#     run, is the one wrapper that passes --custom-devtools-frontend, exactly
#     once and naming the frontend; there is no second helium on the PATH.
#     The headless Helium of the Chrome DevTools MCP server does not pass it.
#   - Headless, over the Chrome DevTools Protocol, as on Fedora: the host's
#     Helium opens DevTools dark, with every shadow root carrying the square
#     sheet, no element rounded, the accent as the primary color and the
#     theme's font. The MCP server's Helium opens the stock DevTools. The
#     same browser given the frontend of a Teal host has Teal as its primary.
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
  heliumsOf = ps: lib.filter (p: lib.getName p == "helium") ps;

  host = mkHost [ ];
  teal = mkHost [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  config = host.config;
  user = config.ravnix.user.username;
  hm = config.home-manager.users.${user};
  palette = config.ravnix.theme.palette;

  helium = lib.head (heliumsOf config.environment.systemPackages);
  frontend = helium.devtoolsFrontend;
  tealFrontend = (lib.head (heliumsOf teal.config.environment.systemPackages)).devtoolsFrontend;
  mcp = hm.ravnix.claude.mcpServers.chrome-devtools.command;

  # Every package the user reaches by name: the system's and the user's.
  allPackages =
    config.environment.systemPackages ++ config.users.users.${user}.packages ++ hm.home.packages;
  heliumCount = builtins.length (heliumsOf allPackages);

  profile = pkgs.buildEnv {
    name = "huginn-helium-launchers";
    paths = config.environment.systemPackages;
    pathsToLink = [
      "/bin"
      "/share/applications"
    ];
    ignoreCollisions = true;
  };

  rgbComma =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: toString (lib.fromHexString (builtins.substring i 2 h));
    in
    "rgb(${byte 0}, ${byte 2}, ${byte 4})";

  python = pkgs.python3.withPackages (ps: [
    ps.brotli
    ps.websockets
  ]);
in
pkgs.runCommand "desktop-helium-devtools"
  {
    nativeBuildInputs = [
      python
      pkgs.jq
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gnutar
      pkgs.xz
      pkgs.findutils
      pkgs.diffutils
    ];
    inherit frontend tealFrontend profile;
    heliumPkg = helium;
    tarball = helium.src;
    buildScript = ../../packages/helium-devtools-frontend/build-frontend.py;
    js = ../../packages/helium-devtools-frontend/square-shadow-roots.js;
    stylesheet = frontend.stylesheet;
    probe = ./helpers/devtools-probe.py;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"

    echo "==> the frontend"
    [ "$(cat "$frontend/.complete")" = "859 files, 8 entry points themed" ] \
      || fail ".complete says: $(cat "$frontend/.complete" 2>&1)"
    files=$(find "$frontend" -type f ! -name .complete | wc -l)
    [ "$files" = 859 ] || fail "the frontend holds $files files, not 859"
    for f in catppuccin-mocha.css square-shadow-roots.js; do
      [ -e "$frontend/$f" ] || fail "the frontend has no $f"
    done
    cmp -s "$frontend/catppuccin-mocha.css" "$stylesheet" || fail "the frontend's stylesheet is not the package's"
    cmp -s "$frontend/square-shadow-roots.js" "$js" || fail "the frontend's script is not the package's"
    html=$(find "$frontend" -name '*.html' | sort)
    [ "$(printf '%s\n' "$html" | wc -l)" = 8 ] || fail "the frontend has $(printf '%s\n' "$html" | wc -l) HTML files, not 8"
    for h in $html; do
      n=''${h#"$frontend/"}
      grep -qF '<script type="module" src="./square-shadow-roots.js"></script>' "$h" || fail "$n does not load the script"
      grep -qF '<link href="./catppuccin-mocha.css" rel="stylesheet">' "$h" || fail "$n does not link the stylesheet"
      first=$(grep -o '<script type="module"[^>]*>' "$h" | head -1)
      [ "$first" = '<script type="module" src="./square-shadow-roots.js">' ] || fail "$n runs $first before the square script"
      tr -d '\n' < "$h" | grep -q 'catppuccin-mocha.css" rel="stylesheet">\s*<body' || fail "$n does not link the stylesheet right before <body>"
    done
    for t in $(grep -o -- '--sys-shape-corner-[a-z-]*:' "$frontend/design_system_tokens.css" | sort -u); do
      grep -qF -- "  $t 0 !important;" "$stylesheet" || fail "the stock corner token ''${t%:} is not 0 in the stylesheet"
    done

    echo "==> the parser, on what it must refuse"
    mkdir -p tar
    tar -xJf "$tarball" -C tar --strip-components=1 --wildcards '*/helium' '*/resources.pak'
    mkdir -p tool bad
    cp "$buildScript" tool/build-frontend.py
    : > tool/catppuccin-mocha.css
    : > tool/square-shadow-roots.js
    build() { python3 -I tool/build-frontend.py "$@"; }
    build tar/helium tar/resources.pak "$PWD/ok" > ok.log || fail "the parser fails on Helium's own files: $(cat ok.log)"
    grep -q '859 files, 8 entry points themed' ok.log || fail "the parser says: $(cat ok.log)"

    head -c 100000000 tar/helium > bad/half
    head -c 1000 tar/helium > bad/head
    : > bad/empty
    cp ${pkgs.coreutils}/bin/coreutils bad/foreign
    : > bad/pak-empty
    head -c 1000 tar/resources.pak > bad/pak-head
    # The pak cut where the frontend's last resource starts: every resource
    # before it is whole, and that one is gone.
    cut=$(python3 -I -c '
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("b", "tool/build-frontend.py")
    b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
    table = b.resource_table(open("tar/helium", "rb").read())
    index = b.pak_resources(open("tar/resources.pak", "rb").read())
    print(max(index[rid][0] for _, rid in table))
    ')
    head -c "$cut" tar/resources.pak > bad/pak-cut
    refuse() { # NAME BINARY PAK
      rm -rf "$PWD/out-$1"
      if build "$2" "$3" "$PWD/out-$1" > "$1.log" 2>&1; then
        fail "the parser accepts $1: $(tail -1 "$1.log")"
      fi
      [ ! -e "$PWD/out-$1" ] || fail "the parser leaves a frontend behind for $1"
      if find . -maxdepth 1 -name '.build-*' | grep -q .; then fail "the parser leaves its build directory behind for $1"; fi
      echo "  $1: $(tail -1 "$1.log")"
    }
    refuse truncated-binary bad/half tar/resources.pak
    refuse binary-header-only bad/head tar/resources.pak
    refuse empty-binary bad/empty tar/resources.pak
    refuse missing-binary bad/none tar/resources.pak
    refuse foreign-binary bad/foreign tar/resources.pak
    refuse empty-pak tar/helium bad/pak-empty
    refuse truncated-pak tar/helium bad/pak-head
    refuse pak-cut-at-a-resource tar/helium bad/pak-cut
    refuse missing-pak tar/helium bad/none

    echo "==> the launchers"
    [ ${toString heliumCount} = 1 ] || fail "the user has ${toString heliumCount} packages named helium, not 1"
    wrapper=$heliumPkg/bin/helium
    [ "$(grep -o -- '--custom-devtools-frontend=' "$wrapper" | wc -l)" = 1 ] || fail "the host's Helium does not pass --custom-devtools-frontend exactly once"
    grep -qF -- "--custom-devtools-frontend=file://$frontend/" "$wrapper" || fail "the host's Helium does not pass the frontend"
    [ "$(readlink -f "$profile/bin/helium")" = "$(readlink -f "$wrapper")" ] || fail "helium on the PATH is not the host's Helium"
    launchers=$(grep -l '^Exec=.*helium' "$profile"/share/applications/*.desktop)
    for d in $launchers; do
      grep '^Exec=' "$d" | while IFS= read -r line; do
        case $line in "Exec=helium "*|"Exec=helium") ;; *) echo "FAIL: $(basename "$d") runs $line"; exit 1;; esac
      done || failed=1
    done
    for d in helium webapp-claude webapp-apple-music; do
      printf '%s\n' "$launchers" | grep -q "/$d.desktop$" || fail "no launcher $d.desktop runs helium"
    done
    [ "$(grep -h '^Exec=' $launchers | wc -l)" -ge 5 ] || fail "fewer than 5 Exec lines run helium"

    echo "==> the MCP server's Helium"
    browser=$(grep -o '/nix/store/[a-z0-9]*-helium-[^/"]*/bin/helium' ${mcp} | sort -u)
    [ "$(printf '%s\n' "$browser" | wc -l)" = 1 ] && [ -n "$browser" ] || fail "the MCP wrapper names no single Helium: $browser"
    [ "$browser" != "$wrapper" ] || fail "the MCP server runs the host's Helium"
    if grep -q -- '--custom-devtools-frontend' "$browser"; then fail "the MCP server's Helium passes --custom-devtools-frontend"; fi

    echo "==> DevTools in a running Helium"
    look() { # NAME HELIUM [FLAG]
      python3 -I "$probe" "$2" "$TMPDIR/profile-$1" "''${@:3}" > "$1.json" || { fail "$1: the probe failed"; echo '{}' > "$1.json"; }
      echo "  $1: $(cat "$1.json")"
    }
    look host "$wrapper"
    look mcp "$browser"
    look teal "$browser" "--custom-devtools-frontend=file://$tealFrontend/"
    q() { jq -r "$2" "$1.json"; }
    for n in host teal; do
      [ "$(q $n .dark)" = true ] || fail "$n: DevTools is not dark"
      [ "$(q $n .link)" = true ] || fail "$n: the page does not link the stylesheet"
      [ "$(q $n '.roots > 20')" = true ] || fail "$n: only $(q $n .roots) shadow roots, DevTools did not draw"
      [ "$(q $n '.squared == .roots')" = true ] || fail "$n: $(q $n .squared) of $(q $n .roots) shadow roots carry the square sheet"
      [ "$(q $n .rounded)" = 0 ] || fail "$n: $(q $n .rounded) elements are rounded"
      [ "$(q $n .corner)" = 0 ] || fail "$n: the corner token is $(q $n .corner)"
      [ "$(q $n .font)" = "'${config.ravnix.theme.font}', monospace" ] || fail "$n: the font is $(q $n .font)"
    done
    [ "$(q host .primary)" = '${rgbComma palette.mauve}' ] || fail "host: the primary color is $(q host .primary), not the accent"
    [ "$(q teal .primary)" = '${rgbComma palette.teal}' ] || fail "teal: the primary color is $(q teal .primary), not Teal"
    [ "$(q mcp .link)" = false ] || fail "mcp: the MCP server's DevTools link the stylesheet"
    [ "$(q mcp .squared)" = 0 ] || fail "mcp: the MCP server's DevTools carry the square sheet"
    [ "$(q mcp '.roots > 20')" = true ] || fail "mcp: only $(q mcp .roots) shadow roots, the stock DevTools did not draw"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
