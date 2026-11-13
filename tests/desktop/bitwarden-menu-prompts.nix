# What bwm asks fuzzel (packages/bitwarden-menu): bwm 0.6.0 gives a question and
# hides typed input only for the menus it knows by name, dmenu, rofi, bemenu and
# wofi (bwm/menu.py, dmenu_cmd). With `fuzzel --dmenu` every question was fuzzel's
# bare "> ", and the `Password` and `Verify password` prompts of an item whose
# password is typed by hand showed it. The package patches menu.py to know
# fuzzel too: `--prompt=TEXT` and `--lines=N` for every menu, `--password` for the
# ones that read a secret.
#
# The check imports bwm.menu of the package, with the interpreter and the
# site directories of its own `bwm` (read from the head of bin/.bwm-wrapped), and
# asks dmenu_cmd for the command of each kind of prompt with fuzzel, and with
# the three menus it already knew, which must come out as upstream's. Then it
# starts the real fuzzel, headless, with the command bwm built for `Password`, and
# requires that fuzzel takes every flag.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostPkgs = inputs.nixpkgs.legacyPackages.${system};
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = (import ../flake/helpers/host-modules.nix { inherit lib; }) ++ [
      self.nixosModules.desktop
    ];
  };
in
pkgs.runCommand "desktop-bitwarden-menu-prompts"
  {
    nativeBuildInputs = [
      hostPkgs.sway-unwrapped
      hostPkgs.fuzzel
      hostPkgs.coreutils
      hostPkgs.gnugrep
    ];
    package = host.pkgs.ravnix.bitwarden-menu;
    probe = ./helpers/bwm-prompts.py;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR/run XDG_CACHE_HOME=$TMPDIR/cache XDG_CONFIG_HOME=$TMPDIR/config
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
    chmod 700 "$XDG_RUNTIME_DIR"

    # The interpreter and the site directories of bwm itself: the first three
    # lines of its entry script are the shebang and the path set-up.
    entry="$package/bin/.bwm-wrapped"
    python=$(sed -n '1s/^#! *//p' "$entry")
    { sed -n '3p' "$entry" | sed 's/^import sys;import site;import functools;sys.argv\[0\] = [^;]*;/import sys;import site;import functools;/'; cat "$probe"; } > "$TMPDIR/probe.py"
    "$python" -I "$TMPDIR/probe.py" "$TMPDIR" > "$TMPDIR/probe.out" 2> "$TMPDIR/probe.err" || fail "the prompts of bwm: $(cat "$TMPDIR/probe.out" "$TMPDIR/probe.err")"
    cat "$TMPDIR/probe.out"

    # fuzzel takes the command bwm builds for `Password`.
    export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman LIBSEAT_BACKEND=noop
    printf 'exec_always true\n' > "$TMPDIR/sway.conf"
    sway --config "$TMPDIR/sway.conf" > "$TMPDIR/sway.log" 2>&1 &
    sway_pid=$!
    trap 'kill $sway_pid $(jobs -p) 2>/dev/null || true' EXIT
    for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.1; done
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { cat "$TMPDIR/sway.log"; fail "sway did not start"; exit 1; }
    export WAYLAND_DISPLAY=wayland-1
    [ -s "$TMPDIR/password.argv" ] || fail "the probe wrote no command for Password"
    mapfile -t argv < "$TMPDIR/password.argv"
    printf 'fuzzel command: %s\n' "''${argv[*]}"
    # The empty list a password prompt gets: fuzzel takes its input from stdin
    # and has nothing to show; it must stay up, waiting for typing, not exit
    # with a complaint about a flag.
    : | "''${argv[@]}" > "$TMPDIR/fuzzel.out" 2> "$TMPDIR/fuzzel.err" &
    fz=$!
    sleep 2
    cat "$TMPDIR/fuzzel.err"
    if kill -0 $fz 2>/dev/null; then
      kill $fz 2>/dev/null || true
    else
      wait $fz && rc=0 || rc=$?
      # An empty list may end the menu at once; a complaint about a flag is what fails.
      if grep -qE 'invalid option|missing required argument|error: --' "$TMPDIR/fuzzel.err"; then
        fail "fuzzel refused the flags of bwm's command: $(cat "$TMPDIR/fuzzel.err")"
      fi
    fi

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
