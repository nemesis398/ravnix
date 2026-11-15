# sway-game-mode against a real Sway, headless, with real windows (foot): the
# watcher enters mode "game" when a window of the list gains focus and leaves
# it when focus goes anywhere else, an empty workspace included; resize and
# passthrough are left alone; SIGTERM leaves "game"; `--leave` clears what a
# killed watcher left behind; and Sway going away ends the watcher with 1.
# The unit tests (tools/sway-game-mode/tests) cover the protocol against a
# stand-in; this is the check that the stand-in is Sway.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  inherit ((pkgs.extend self.overlays.default).ravnix) sway-game-mode;
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
in
pkgs.runCommand "desktop-sway-game-mode"
  {
    nativeBuildInputs = [
      pkgs.sway
      pkgs.foot
      pkgs.jq
      pkgs.coreutils
      pkgs.gnugrep
    ];
    SWAY_GAME_MODE = lib.getExe sway-game-mode;
    SWAY = lib.getExe pkgs.sway;
    SWAYMSG = lib.getExe' pkgs.sway "swaymsg";
    FOOT = lib.getExe pkgs.foot;
    JQ = lib.getExe pkgs.jq;
  }
  ''
    export HOME=$PWD/home XDG_RUNTIME_DIR=$PWD/run FONTCONFIG_FILE=${fontsConf}
    mkdir -p $HOME $XDG_RUNTIME_DIR /build/fontconfig-cache
    chmod 700 $XDG_RUNTIME_DIR
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
    export WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS=/dev/null
    cat > sway.conf <<'EOF'
    seat * hide_cursor when-typing enable
    seat * hide_cursor 8000
    output HEADLESS-1 resolution 800x600
    mode "game" {
        bindsym Mod4+Shift+Escape mode "default"
    }
    mode "resize" {
        bindsym Escape mode "default"
    }
    mode "passthrough" {
        bindsym Mod4+Shift+Escape mode "default"
    }
    EOF
    "$SWAY" -c sway.conf > sway.log 2>&1 &
    sway=$!
    for _ in $(seq 100); do
      export SWAYSOCK=$(echo $XDG_RUNTIME_DIR/sway-ipc.*.sock)
      [ -S "$SWAYSOCK" ] && break
      sleep 0.1
    done
    [ -S "$SWAYSOCK" ] || { cat sway.log >&2; echo "Sway did not start" >&2; exit 1; }
    ok=0
    bash ${./helpers/sway-game-mode-e2e.sh} 2>&1 | tee $out || ok=1
    kill $sway 2>/dev/null || true
    grep -q '^FAIL' $out && ok=1
    [ "$(grep -c '^PASS' $out)" -ge 20 ] || { echo "too few cases ran" >&2; ok=1; }
    exit $ok
  ''
