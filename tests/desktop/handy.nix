# Handy's launcher and its hold-to-talk driver (packages/handy-launch,
# packages/handy-ptt), run against stand-ins for Handy, pactl and notify-send
# and the real pgrep:
#
#   handy-launch  pins Handy to the iGPU through two variables, puts the wtype
#                 of ravnix first on PATH, and passes its arguments on
#   handy-ptt     `down` starts a take and `up` ends it, by Handy's PipeWire
#                 capture stream and not by counting presses, and `up` follows
#                 the mode `down` used
#
# handy-launch gets a shell stand-in that logs its environment and arguments.
# handy-ptt gets a stand-in that looks like nixpkgs' Handy to pgrep: a compiled
# program behind a makeBinaryWrapper wrapper, which is how nixpkgs ships it
# (bin/handy execs bin/.handy-wrapped with --inherit-argv0, so the process is
# named .handy-wrapped and its argv[0] is the name it was started by). The first
# version of this test replaced pgrep and never met that name.
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

  # Handy, as nixpkgs packages it: bin/handy is a binary wrapper around
  # bin/.handy-wrapped, a program that counts SIGUSR2 in $FAKE_DIR/usr2 and
  # says it is ready in $FAKE_DIR/ready. The name carries a version, as every
  # store path of Handy does.
  realHandy = pkgs.runCommandCC "handy-9.9.9" { nativeBuildInputs = [ pkgs.makeBinaryWrapper ]; } ''
    mkdir -p $out/bin
    cat > handy.c <<'EOF'
    #include <fcntl.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>

    static int log_fd = -1;

    static void on_usr2(int sig) {
      (void)sig;
      if (write(log_fd, "usr2\n", 5) < 0) _exit(1);
    }

    int main(void) {
      const char *dir = getenv("FAKE_DIR");
      char path[4096];
      if (!dir) return 2;
      snprintf(path, sizeof path, "%s/usr2", dir);
      log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (log_fd < 0) return 3;
      struct sigaction sa = {.sa_handler = on_usr2};
      sigemptyset(&sa.sa_mask);
      sigaction(SIGUSR2, &sa, NULL);
      snprintf(path, sizeof path, "%s/ready", dir);
      int ready = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (ready < 0 || write(ready, "ready\n", 6) < 0) return 4;
      close(ready);
      for (;;) pause();
    }
    EOF
    $CC -O1 -Wall -Werror -o $out/bin/.handy-wrapped handy.c
    makeBinaryWrapper $out/bin/.handy-wrapped $out/bin/handy \
      --inherit-argv0 --prefix XDG_DATA_DIRS : /nonexistent/share
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

    # The stand-in for Handy, started through its binary wrapper. The wrapper
    # execs, so $! is the pid of the process that pgrep must find, and that
    # process has to look like the real one: named .handy-wrapped.
    export FAKE_DIR=$work
    start_handy_with() {
      rm -f "$work/ready"
      "$@" &
      handy_pid=$!
      for _ in $(seq 1 100); do [ -e "$work/ready" ] && break; sleep 0.05; done
      [ -e "$work/ready" ] || fail "the stand-in for Handy did not start"
      echo "$handy_pid" > "$FAKE_PID_FILE"
      [ "$(cat /proc/$handy_pid/comm)" = .handy-wrapped ] \
        || fail "the stand-in is called $(cat /proc/$handy_pid/comm), not .handy-wrapped: it does not look like nixpkgs' Handy"
    }
    start_handy() { start_handy_with ${realHandy}/bin/handy; }
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

    # Handy started by its bare name from a shell has `handy` as argv[0], not
    # its path (the wrapper inherits it); the process is named the same.
    reset
    old_path=$PATH
    PATH=${realHandy}/bin:$PATH
    start_handy_with handy
    PATH=$old_path
    ${ptt}/bin/handy-ptt down || fail "down fails for a Handy started by name"
    [ "$(signals)" = 1 ] || fail "down did not find a Handy started by its bare name ($(signals) signals)"
    stop_handy

    # a tap: the release comes and the stream never opens; nothing is toggled
    reset; start_handy
    ${ptt}/bin/handy-ptt up || fail "up on a quick tap fails"
    [ "$(signals)" = 0 ] || fail "up with no stream sent a signal"
    stop_handy

    # Handy is found by what it is, not by what its name looks like: a process
    # that only carries the path of Handy in its arguments is not Handy.
    reset
    bash -c 'sleep 30' "${realHandy}/bin/.handy-wrapped" &
    decoy=$!
    ${ptt}/bin/handy-ptt down || fail "down with a look-alike fails"
    grep -q 'Handy was not running' "$CALLS" || fail "a process that only mentions Handy's path was taken for Handy"
    kill "$decoy"; wait "$decoy" 2>/dev/null || true

    # no XDG_RUNTIME_DIR, and no /run/user/UID to fall back on (the sandbox has
    # none): the mode file cannot be written, which must neither stop the take
    # nor print an error into the session. `down` still toggles, and `up` has
    # no mode to follow and takes its own argument.
    if [ ! -e "/run/user/$(id -u)" ]; then
      reset; start_handy
      (unset XDG_RUNTIME_DIR; ${ptt}/bin/handy-ptt down 2> "$work/err") || fail "down without a runtime directory fails"
      [ "$(signals)" = 1 ] || fail "down without a runtime directory sent $(signals) toggle signals, not 1"
      [ ! -s "$work/err" ] || fail "down without a runtime directory prints: $(cat "$work/err")"
      touch "$FAKE_RECORDING"
      : > "$CALLS"
      (unset XDG_RUNTIME_DIR; ${ptt}/bin/handy-ptt up clean 2> "$work/err") || fail "up without a runtime directory fails"
      grep -qx 'launch --toggle-post-process' "$CALLS" || fail "up without a mode file did not take its own argument: $(cat "$CALLS")"
      [ ! -s "$work/err" ] || fail "up without a runtime directory prints: $(cat "$work/err")"
      stop_handy
    fi

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
