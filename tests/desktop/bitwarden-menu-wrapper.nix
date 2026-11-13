# What the wrapped `bwm` (packages/bitwarden-menu) puts on its PATH, and what
# its copies do to the clipboard history, without a network and without a vault.
#
#   - nixpkgs' bitwarden-menu has no `bw` in its closure; the wrapper puts the
#     official CLI on bwm's PATH, with wtype and fuzzel (the type library and the
#     menu of config.ini), so `bwm` works with nothing else installed. Shown by
#     running a program through the wrapper, with the real `bwm` swapped for a
#     stand-in that runs its arguments.
#   - bwm copies a secret by running plain `wl-copy` (read from its source here,
#     so a change upstream fails this check) and clears it by running the same
#     again with empty input. The wrapper puts a `wl-copy` first on PATH that
#     adds `--sensitive`. A real Wayland compositor (Sway, headless, in the
#     sandbox) with the history watcher of the Sway config shows that a plain
#     copy is stored by cliphist (the control) and a copy through the wrapper
#     is not, and that bwm's clear leaves the history as it was.
#   - the pinentry of config.ini (pinentry-qt) opens a window on Wayland;
#   - the real `bwm` starts (`-V`) with only what the wrapper gives it.
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
  package = host.pkgs.ravnix.bitwarden-menu;
  # The same wrapper around a program that runs its arguments, so what bwm
  # would see on PATH can be asked for.
  probe = package.override {
    bitwarden-menu = hostPkgs.writeShellScriptBin "bwm" ''exec "$@"'' // {
      version = "stand-in";
      meta = {
        description = "runs its arguments";
        license = lib.licenses.mit;
        mainProgram = "bwm";
      };
    };
  };
in
pkgs.runCommand "desktop-bitwarden-menu-wrapper"
  {
    nativeBuildInputs = [
      hostPkgs.sway-unwrapped
      hostPkgs.wl-clipboard
      hostPkgs.cliphist
      hostPkgs.coreutils
      hostPkgs.gnugrep
      hostPkgs.gnused
    ];
    inherit package probe;
    inherit (hostPkgs) wtype fuzzel;
    bitwardenCli = hostPkgs.bitwarden-cli;
    bitwardenMenu = hostPkgs.bitwarden-menu;
    wlClipboard = hostPkgs.wl-clipboard;
    pinentry = hostPkgs.pinentry-qt;
    swayConfig = ../../modules/desktop/sway/config;
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR/run XDG_CACHE_HOME=$TMPDIR/cache XDG_CONFIG_HOME=$TMPDIR/config
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
    chmod 700 "$XDG_RUNTIME_DIR"

    # --- PATH
    # A PATH of nothing else: whatever resolves, the wrapper gave.
    run_in() { env -i PATH="${hostPkgs.coreutils}/bin" HOME="$HOME" "$probe/bin/bwm" "$@"; }
    where() { env -i PATH="${hostPkgs.coreutils}/bin" HOME="$HOME" "$probe/bin/bwm" ${hostPkgs.bash}/bin/sh -c "command -v $1" 2>&1 || true; }
    [ "$(where bw)" = "$bitwardenCli/bin/bw" ] || fail "bw on bwm's PATH is '$(where bw)', not $bitwardenCli/bin/bw"
    [ "$(where wtype)" = "$wtype/bin/wtype" ] || fail "wtype on bwm's PATH is '$(where wtype)'"
    [ "$(where fuzzel)" = "$fuzzel/bin/fuzzel" ] || fail "fuzzel on bwm's PATH is '$(where fuzzel)'"
    shim=$(where wl-copy)
    case "$shim" in
      "$wlClipboard"/*) fail "wl-copy on bwm's PATH is wl-clipboard's own ($shim), not the one that marks copies sensitive" ;;
      /nix/store/*/bin/wl-copy) ;;
      *) fail "no wl-copy on bwm's PATH: '$shim'" ;;
    esac
    # The real bw runs from there (no vault, no network: its version).
    env -i PATH="${hostPkgs.coreutils}/bin" HOME="$HOME" "$probe/bin/bwm" ${hostPkgs.bash}/bin/sh -c 'bw --version' > "$TMPDIR/bwv" 2>&1 || fail "bw does not run from bwm's PATH: $(cat "$TMPDIR/bwv")"
    grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' "$TMPDIR/bwv" || fail "bw --version printed: $(cat "$TMPDIR/bwv")"
    # The wrapper keeps the caller's PATH after its own (an editor started from bwm).
    [ "$(env -i PATH="${hostPkgs.coreutils}/bin" "$probe/bin/bwm" ${hostPkgs.bash}/bin/sh -c 'command -v ls')" = "${hostPkgs.coreutils}/bin/ls" ] || fail "the caller's PATH is lost behind the wrapper's"

    # --- the real bwm starts on its own
    env -i PATH="${hostPkgs.coreutils}/bin" HOME="$HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$package/bin/bwm" -V > "$TMPDIR/ver" 2>&1 || fail "bwm -V failed: $(cat "$TMPDIR/ver")"
    grep -q "${hostPkgs.bitwarden-menu.version}" "$TMPDIR/ver" || fail "bwm -V printed: $(cat "$TMPDIR/ver")"

    # --- bwm copies with plain `wl-copy`
    src=$(echo "$bitwardenMenu"/lib/python*/site-packages/bwm/__init__.py)
    grep -qF '["wl-copy"]' "$src" || fail "bwm no longer looks for a plain [\"wl-copy\"] in $src: the wrapper's wl-copy may not be the one it runs"

    # --- the clipboard history
    export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman LIBSEAT_BACKEND=noop
    printf 'exec_always true\n' > "$TMPDIR/sway.conf"
    sway --config "$TMPDIR/sway.conf" > "$TMPDIR/sway.log" 2>&1 &
    sway_pid=$!
    trap 'kill $sway_pid $(jobs -p) 2>/dev/null || true' EXIT
    for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break; sleep 0.1; done
    [ -S "$XDG_RUNTIME_DIR/wayland-1" ] || { cat "$TMPDIR/sway.log"; fail "sway did not start"; exit 1; }
    export WAYLAND_DISPLAY=wayland-1

    # The watchers of the Sway session, as its configuration starts them.
    grep -c '^exec wl-paste --type .* --watch cliphist store$' "$swayConfig" > "$TMPDIR/n"
    [ "$(cat "$TMPDIR/n")" = 2 ] || fail "the Sway config no longer starts the two cliphist watchers this check copies"
    sed -n 's/^exec \(wl-paste --type .* --watch cliphist store\)$/\1/p' "$swayConfig" | while IFS= read -r cmd; do
      eval "$cmd" &
    done
    sleep 1
    history() { cliphist list 2>/dev/null | cut -f2- ; }
    wait_for() { # wait_for PATTERN: the history shows it within 5 s
      for _ in $(seq 1 50); do history | grep -qF -- "$1" && return 0; sleep 0.1; done
      return 1
    }
    settle() { sleep 1; }

    # The control: a plain copy is recorded, so the watcher works at all.
    printf 'control-entry' | wl-copy
    wait_for control-entry || fail "control: a plain copy never reached the history (the check cannot see anything)"

    # A copy through bwm's PATH is not recorded.
    run_in2() { env -i PATH="${hostPkgs.coreutils}/bin" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY=wayland-1 "$probe/bin/bwm" ${hostPkgs.bash}/bin/sh -c "$1"; }
    run_in2 "printf 'hunter2-secret' | wl-copy"
    settle
    history | grep -qF hunter2-secret && fail "the secret copied through bwm's wl-copy is in the clipboard history"
    # ... and it is on the clipboard, for the paste.
    [ "$(wl-paste --no-newline 2>/dev/null)" = hunter2-secret ] || fail "the secret is not on the clipboard after the copy: '$(wl-paste --no-newline 2>&1)'"

    # What bwm's clear (wl-copy with empty input, after 30 s) does to the history.
    before=$(history)
    run_in2 "wl-copy < /dev/null"
    settle
    after=$(history)
    printf 'history before the clear:\n%s\nafter:\n%s\n' "$before" "$after"
    # The stand-in marks the clear sensitive too, so cliphist ignores it; a
    # clear that reached cliphist as a plain one would delete the entry before.
    [ "$before" = "$after" ] || fail "bwm's clear changed the history"
    [ -z "$(wl-paste --no-newline 2>/dev/null || true)" ] || fail "the clear left something on the clipboard"
    history | grep -qF hunter2-secret && fail "the secret is in the history after the clear"

    # --- the pinentry of config.ini draws a window on Wayland (not on screen: the
    # compositor is headless), asked the way bwm asks: no terminal, no options.
    (printf 'SETDESC Enter Password\nGETPIN\n'; sleep 8) | "$pinentry/bin/pinentry-qt" > "$TMPDIR/pin.out" 2> "$TMPDIR/pin.err" &
    pin_pid=$!
    seen=
    for _ in $(seq 1 60); do
      if SWAYSOCK=$(echo "$XDG_RUNTIME_DIR"/sway-ipc.*) swaymsg -t get_tree 2>/dev/null | grep -q '"pid": '"$pin_pid"; then seen=1; break; fi
      sleep 0.2
    done
    [ -n "$seen" ] || fail "pinentry-qt opened no window on Wayland: $(cat "$TMPDIR/pin.err" | head -5)"
    kill $pin_pid 2>/dev/null || true

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
