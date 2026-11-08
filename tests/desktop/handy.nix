# Handy's launcher and its hold-to-talk driver (packages/handy-launch,
# packages/handy-ptt), run against stand-ins for Handy, pgrep, pactl and
# notify-send:
#
#   handy-launch  pins Handy to the iGPU through two variables, puts the wtype
#                 of ravnix first on PATH, and passes its arguments on
#   handy-ptt     `down` starts a take and `up` ends it, by Handy's PipeWire
#                 capture stream and not by counting presses, and `up` follows
#                 the mode `down` used
#
# The stand-in Handy is a shell process that logs every signal and every call.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  stub = name: body: pkgs.writeShellScriptBin name body;

  # The stand-in for Handy: logs its environment and arguments, and exits.
  fakeHandy = pkgs.writeShellScriptBin "handy" ''
    {
      echo "args: $*"
      echo "egl: ''${__EGL_VENDOR_LIBRARY_FILENAMES-unset}"
      echo "vk: ''${VK_DRIVER_FILES-unset}"
      echo "prime: ''${__NV_PRIME_RENDER_OFFLOAD-unset}"
      echo "path: $PATH"
    } > "$HANDY_LOG"
    exit "''${HANDY_EXIT:-0}"
  '';
  fakeWtype = pkgs.writeShellScriptBin "wtype" "exit 0";

  launch = pkgs.callPackage ../../packages/handy-launch {
    handy = fakeHandy;
    wtype = fakeWtype;
  };

  # pgrep prints the pid in $FAKE_PID_FILE, and fails when there is none.
  fakePgrep = stub "pgrep" ''
    [ -s "$FAKE_PID_FILE" ] || exit 1
    cat "$FAKE_PID_FILE"
  '';
  # Handy's capture stream exists while $FAKE_RECORDING exists.
  fakePactl = stub "pactl" ''
    if [ -e "$FAKE_RECORDING" ]; then
      echo "Source Output #1"
      echo "	application.name = \"cpal-pulseaudio-$(cat "$FAKE_PID_FILE")\""
    else
      echo "Source Output #1"
      echo "	application.name = \"some other app\""
    fi
  '';
  fakeNotify = stub "notify-send" ''echo "$*" >> "$CALLS"'';
  fakeLaunch = stub "handy-launch" ''echo "launch $*" >> "$CALLS"'';

  ptt = pkgs.callPackage ../../packages/handy-ptt {
    procps = fakePgrep;
    pulseaudio = fakePactl;
    libnotify = fakeNotify;
    ravnix.handy-launch = fakeLaunch;
  };
in
pkgs.runCommand "desktop-handy"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    work=$(mktemp -d)
    export HOME=$work/home XDG_RUNTIME_DIR=$work/run
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

    # ---- handy-launch
    export HANDY_LOG=$work/handy.log
    ${launch}/bin/handy-launch --start-hidden || fail "handy-launch exits non-zero with a good Handy"
    grep -qx 'args: --start-hidden' "$HANDY_LOG" || fail "handy-launch does not pass its arguments on: $(cat "$HANDY_LOG")"
    grep -q '^egl: .*/share/glvnd/egl_vendor.d/50_mesa.json$' "$HANDY_LOG" || fail "the EGL vendor is not Mesa's: $(grep '^egl' "$HANDY_LOG")"
    grep -q '^vk: .*/share/vulkan/icd.d/radeon_icd.x86_64.json$' "$HANDY_LOG" || fail "Vulkan is not pinned to RADV: $(grep '^vk' "$HANDY_LOG")"
    grep -qx 'prime: unset' "$HANDY_LOG" || fail "handy-launch sets the NVIDIA offload variable"
    grep -q '^path: ${fakeWtype}/bin:' "$HANDY_LOG" || fail "the wtype of ravnix is not first on PATH: $(grep '^path' "$HANDY_LOG" | cut -c1-120)"
    # An argument with a space and an empty argument arrive whole.
    ${launch}/bin/handy-launch "a b" "" || true
    grep -qx 'args: a b ' "$HANDY_LOG" || fail "arguments with a space or empty are mangled: $(grep '^args' "$HANDY_LOG")"
    # The exit status is Handy's.
    HANDY_EXIT=7 ${launch}/bin/handy-launch && fail "handy-launch hides Handy's exit status" || [ $? = 7 ] || fail "handy-launch changed Handy's exit status"

    # ---- handy-ptt
    export CALLS=$work/calls FAKE_PID_FILE=$work/pid FAKE_RECORDING=$work/recording
    state=$XDG_RUNTIME_DIR/handy-ptt.mode
    reset() { : > "$CALLS"; : > "$FAKE_PID_FILE"; rm -f "$FAKE_RECORDING" "$state" "$work/usr2"; }

    # A process that stands for Handy and logs the toggle signal.
    start_handy() {
      bash -c 'trap "echo usr2 >> '"$work"'/usr2" USR2; echo ready > '"$work"'/ready; while :; do sleep 0.05; done' &
      handy_pid=$!
      echo "$handy_pid" > "$FAKE_PID_FILE"
      for _ in $(seq 1 50); do [ -e "$work/ready" ] && break; sleep 0.05; done
      rm -f "$work/ready"
    }
    stop_handy() { kill "$handy_pid" 2>/dev/null || true; wait "$handy_pid" 2>/dev/null || true; }
    signals() { sleep 0.3; if [ -e "$work/usr2" ]; then wc -l < "$work/usr2"; else echo 0; fi; }

    # usage errors
    reset
    ${ptt}/bin/handy-ptt >/dev/null 2>&1 && fail "no arguments are accepted" || [ $? = 2 ] || fail "usage error is not status 2"
    ${ptt}/bin/handy-ptt sideways >/dev/null 2>&1 && fail "an unknown direction is accepted" || [ $? = 2 ] || fail "usage error is not status 2"
    ${ptt}/bin/handy-ptt down loud >/dev/null 2>&1 && fail "an unknown mode is accepted" || [ $? = 2 ] || fail "usage error is not status 2"

    # Handy is not running: a press starts it and says so, a release does nothing.
    reset
    ${ptt}/bin/handy-ptt up clean || fail "up without Handy fails"
    [ ! -s "$CALLS" ] || fail "up without Handy starts something: $(cat "$CALLS")"
    ${ptt}/bin/handy-ptt down || fail "down without Handy fails"
    grep -q '^launch --start-hidden$' "$CALLS" || fail "down without Handy does not start it hidden: $(cat "$CALLS")"
    grep -q 'Handy was not running' "$CALLS" || fail "down without Handy does not say so"

    # down, plain, not recording: one toggle signal, and the mode is remembered
    reset; start_handy
    ${ptt}/bin/handy-ptt down || fail "down fails"
    [ "$(signals)" = 1 ] || fail "down plain sent $(signals) toggle signals, not 1"
    [ "$(cat "$state")" = plain ] || fail "down plain did not remember its mode: $(cat "$state" 2>/dev/null)"
    # a second press while the stream is open must not toggle again
    touch "$FAKE_RECORDING"
    ${ptt}/bin/handy-ptt down || true
    [ "$(signals)" = 1 ] || fail "down while recording toggled again ($(signals) signals)"
    # up ends the take with a signal and forgets the mode
    ${ptt}/bin/handy-ptt up || fail "up fails"
    [ "$(signals)" = 2 ] || fail "up did not send the second signal ($(signals))"
    [ ! -e "$state" ] || fail "up left the mode file behind"
    stop_handy

    # down clean goes through Handy's own command line, and up follows the mode
    # down used even when sway fires the release of another binding
    reset; start_handy
    ${ptt}/bin/handy-ptt down clean || fail "down clean fails"
    grep -qx 'launch --toggle-post-process' "$CALLS" || fail "down clean did not call Handy's post-process toggle: $(cat "$CALLS")"
    [ "$(signals)" = 0 ] || fail "down clean sent a signal"
    [ "$(cat "$state")" = clean ] || fail "down clean did not remember its mode"
    touch "$FAKE_RECORDING"
    : > "$CALLS"
    ${ptt}/bin/handy-ptt up plain || fail "up fails"
    grep -qx 'launch --toggle-post-process' "$CALLS" || fail "up plain after down clean did not follow the clean mode: $(cat "$CALLS")"
    [ "$(signals)" = 0 ] || fail "up plain after down clean sent a plain signal"
    stop_handy

    # a mode file with anything else in it is ignored
    reset; start_handy
    echo "rm -rf /" > "$state"
    touch "$FAKE_RECORDING"
    ${ptt}/bin/handy-ptt up clean || fail "up with a garbage mode file fails"
    grep -qx 'launch --toggle-post-process' "$CALLS" || fail "a garbage mode file changed the mode: $(cat "$CALLS")"
    stop_handy

    # a tap: the release comes and the stream never opens; nothing is toggled
    reset; start_handy
    ${ptt}/bin/handy-ptt up || fail "up on a quick tap fails"
    [ "$(signals)" = 0 ] || fail "up with no stream sent a signal"
    stop_handy

    # no XDG_RUNTIME_DIR: the mode file falls back to /run/user/UID, which the
    # sandbox lacks, so the script must not take the first press for a crash
    reset; start_handy
    (unset XDG_RUNTIME_DIR; ${ptt}/bin/handy-ptt up || true) 2>/dev/null
    stop_handy

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
