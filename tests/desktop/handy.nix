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
# handy-ptt gets stand-ins that look like ravnix's Handy (packages/handy, 0.10.0
# on nixpkgs' recipe) to pgrep, and the real pgrep. What the wrapped stand-in
# shares with that Handy, and what is only assumed:
#
#   shared (and asserted below against the real package, so a bump or a change
#   in nixpkgs fails this check instead of silently outdating the stand-in)
#     - bin/handy is a small ELF wrapper made by makeCWrapper, and it execs
#       bin/.handy-wrapped with --inherit-argv0: the process is named
#       .handy-wrapped (the kernel names it after the file) and its argv[0] is
#       the name it was started by, the full path of bin/handy from
#       handy-launch, a bare `handy` from a shell
#     - the store path is called handy-VERSION, and VERSION is 0.10.0
#     - the command line has --start-hidden and --toggle-post-process
#       (`handy --help`), and a second Handy forwards --toggle-post-process to
#       the running one; SIGUSR2 is the plain toggle; the model catalog
#       parses and addresses every model as repository/filename, the form
#       Handy's settings name a model by (read in the source)
#     - Handy names its PulseAudio client cpal-pulseaudio-PID, the stream
#       handy-ptt watches: the string is in the built program and in the
#       vendored handy-cpal source, with the process id (0.9.8, on cpal 0.16,
#       had no such client at all, so handy-ptt never saw a take with it)
#     - the transcription worker that 0.10.0 starts beside the app names its
#       process Handy-worker, which the pattern does not take (a decoy below)
#     - the wrapper does not set WEBKIT_DISABLE_DMABUF_RENDERER, which would
#       override 0.10.0's own choice of WebKit renderer (packages/handy)
#   and the launcher of ravnix runs this Handy, not nixpkgs' 0.9.8
#   only modeled (the stand-in is a 40-line C program, Handy is a Tauri
#   application): the signal handling, and the stream itself, which the pactl
#   stand-in fakes under the name asserted above
#
# The check builds ravnix's Handy from source (no binary cache has it): about
# half an hour at cores 4, paid again by the full gate after a nixpkgs bump.
#
# The unwrapped stand-in is a program named `handy`, the other branch of the
# pattern. The first version of this test replaced pgrep and never met the name
# .handy-wrapped.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  stub = name: body: pkgs.writeShellScriptBin name body;

  # ravnix's Handy and its launcher, as the laptop shape installs them.
  handy = self.packages.${system}.handy;
  realLaunch = self.packages.${system}.handy-launch;

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
    ravnix.handy = fakeHandy;
    wtype = fakeWtype;
  };

  # The stand-in program: counts SIGUSR2 in $FAKE_DIR/usr2 and says it is ready
  # in $FAKE_DIR/ready.
  handyC = pkgs.writeText "handy.c" ''
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
  '';

  # Handy, as nixpkgs packages it: bin/handy is a binary wrapper around
  # bin/.handy-wrapped. The name carries a version, as every store path of
  # Handy does.
  realHandy = pkgs.runCommandCC "handy-9.9.9" { nativeBuildInputs = [ pkgs.makeBinaryWrapper ]; } ''
    mkdir -p $out/bin
    $CC -O1 -Wall -Werror -o $out/bin/.handy-wrapped ${handyC}
    makeBinaryWrapper $out/bin/.handy-wrapped $out/bin/handy \
      --inherit-argv0 --prefix XDG_DATA_DIRS : /nonexistent/share
  '';

  # Handy without a wrapper: the process is named handy.
  plainHandy = pkgs.runCommandCC "handy-9.9.8" { } ''
    mkdir -p $out/bin
    $CC -O1 -Wall -Werror -o $out/bin/handy ${handyC}
  '';

  # The real pgrep, which logs its arguments first: handy-ptt must ask for the
  # user's own processes.
  recordingPgrep = stub "pgrep" ''
    echo "$*" >> "$PGREP_LOG"
    exec ${pkgs.procps}/bin/pgrep "$@"
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
    procps = recordingPgrep;
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
      pkgs.jq
      pkgs.findutils
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

    # ---- the stand-in matches ravnix's Handy (see the header)
    n=${handy}
    [ -x "$n/bin/.handy-wrapped" ] || fail "Handy has no bin/.handy-wrapped any more: handy-ptt looks for that process name"
    [ "$(head -c 4 "$n/bin/handy" | tail -c 3)" = ELF ] || fail "Handy's bin/handy is no ELF wrapper any more"
    grep -aq -- '/bin/.handy-wrapped' "$n/bin/handy" || fail "Handy's bin/handy does not exec bin/.handy-wrapped any more"
    grep -aq -- '--inherit-argv0' "$n/bin/handy" || fail "Handy's bin/handy does not inherit argv0 any more: the stand-in's wrapper must change with it"
    case $n in */*-handy-[0-9]*) ;; *) fail "Handy is not in a store path called handy-VERSION: $n";; esac
    case $n in */*-handy-0.10.0) ;; *) fail "ravnix's Handy is not 0.10.0, the version whose settings huginn takes over from Fedora: $n";; esac
    # The launcher of ravnix runs this Handy.
    grep -q "$n/bin/handy" ${realLaunch}/bin/handy-launch || fail "handy-launch does not run ravnix's Handy ($n): $(grep exec ${realLaunch}/bin/handy-launch)"
    # The flags handy-launch and handy-ptt pass exist. --help is answered by
    # clap before any window or GTK comes up.
    "$n/bin/handy" --help > "$work/help" 2>&1 || fail "handy --help fails: $(head -5 "$work/help")"
    for flag in --start-hidden --toggle-post-process; do
      grep -q -- "^ *$flag " "$work/help" || fail "handy --help has no $flag: $(cat "$work/help")"
    done
    # A second Handy started with --toggle-post-process forwards it to the
    # running one (the single-instance plugin), and SIGUSR2 is the plain
    # toggle; the help text does not say either.
    src=${handy.src}/src-tauri/src
    grep -q 'a == "--toggle-post-process"' "$src/lib.rs" || fail "Handy no longer forwards --toggle-post-process to the running instance"
    grep -q 'SIGUSR2 => ("transcribe", "SIGUSR2")' "$src/signal_handle.rs" || fail "SIGUSR2 is no longer Handy's plain toggle"
    grep -q 'PR_SET_NAME, c"Handy-worker"' "$src/engine_supervisor/worker.rs" || fail "Handy's transcription worker is no longer named Handy-worker: the decoy below models the wrong name"
    # Handy's settings name the model as repository/filename: the selected
    # model is looked up by that id in the map of models, which is keyed by
    # the catalog entry's id for its default file (catalog/mod.rs, From for
    # ModelDescriptor) and gets the id of every other file found on disk in
    # managers/model.rs (render_model_info). Settings carried over from
    # another install find their model only while both say repository/filename
    # and every catalog entry has both: the catalog parses, holds models, and
    # each has a repository and files that each have a .gguf filename. No
    # particular model is asserted.
    catalog=$src/catalog/catalog.json
    grep -qF 'id: format!("{}/{}", m.repository, default_filename),' "$src/catalog/mod.rs" \
      || fail "Handy's catalog no longer keys a model by repository/filename: settings carried over may not find theirs"
    # The arm and the line after it, through a file: a pipe into grep -q can
    # fail under pipefail when grep stops reading early.
    { grep -A1 -F '(ModelSource::HuggingFace { repo_id, .. }, Some(f)) => {' "$src/managers/model.rs" || true; } > "$work/id-on-disk"
    grep -qF 'format!("{}/{}", repo_id, f.filename)' "$work/id-on-disk" \
      || fail "Handy no longer names a model file found on disk repository/filename: settings carried over may not find theirs"
    jq -e '
      (.models | type == "array" and length > 0)
      and all(.models[];
        (.repository | type == "string" and test("^[^/]+/[^/]+$"))
        and (.files | type == "object" and length > 0)
        and all(.files[]; .filename | type == "string" and endswith(".gguf")))
    ' "$catalog" > /dev/null || fail "Handy's model catalog does not parse, or an entry lacks a repository or a .gguf filename"
    # handy-ptt sees a take by Handy's capture stream, cpal-pulseaudio-PID with
    # the pid of the process pgrep finds. Capture runs in the main process.
    grep -aq 'cpal-pulseaudio-' "$n/bin/.handy-wrapped" || fail "Handy no longer names its PulseAudio client cpal-pulseaudio-PID: handy-ptt cannot see a take"
    pulse=$(find ${handy.cargoDeps}/ -path '*/handy-cpal-*/src/host/pulseaudio/mod.rs' | head -1)
    [ -n "$pulse" ] || fail "Handy's vendored crates have no handy-cpal PulseAudio host"
    [ -z "$pulse" ] || grep -q 'format!("cpal-pulseaudio-{}", std::process::id())' "$pulse" || fail "handy-cpal no longer names its client cpal-pulseaudio-<process id>: $pulse"
    # The wrapper leaves the WebKit renderer to Handy, and keeps the updater off.
    ! grep -aq WEBKIT_DISABLE_DMABUF_RENDERER "$n/bin/handy" || fail "the wrapper sets WEBKIT_DISABLE_DMABUF_RENDERER, which overrides Handy's renderer choice"
    grep -aq HANDY_DISABLE_UPDATER "$n/bin/handy" || fail "the wrapper no longer turns Handy's updater off"

    # ---- handy-ptt
    export PGREP_LOG=$work/pgrep.log
    : > "$PGREP_LOG"
    export CALLS=$work/calls FAKE_PID_FILE=$work/pid FAKE_RECORDING=$work/recording
    state=$XDG_RUNTIME_DIR/handy-ptt.mode
    reset() { : > "$CALLS"; : > "$FAKE_PID_FILE"; rm -f "$FAKE_RECORDING" "$state" "$work/usr2"; }

    # The stand-in for Handy, started with the process name it must have: the
    # wrapper execs, so $! is the pid of the process that pgrep must find, and
    # that process has to look like the real one (.handy-wrapped behind the
    # wrapper, handy without one).
    export FAKE_DIR=$work
    start_handy_with() {
      local comm=$1
      shift
      rm -f "$work/ready"
      "$@" &
      handy_pid=$!
      for _ in $(seq 1 100); do [ -e "$work/ready" ] && break; sleep 0.05; done
      [ -e "$work/ready" ] || fail "the stand-in for Handy did not start"
      echo "$handy_pid" > "$FAKE_PID_FILE"
      [ "$(cat /proc/$handy_pid/comm)" = "$comm" ] \
        || fail "the stand-in is called $(cat /proc/$handy_pid/comm), not $comm: it does not look like ravnix's Handy"
    }
    start_handy() { start_handy_with .handy-wrapped ${realHandy}/bin/handy; }
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
    start_handy_with .handy-wrapped handy
    PATH=$old_path
    ${ptt}/bin/handy-ptt down || fail "down fails for a Handy started by name"
    [ "$(signals)" = 1 ] || fail "down did not find a Handy started by its bare name ($(signals) signals)"
    stop_handy

    # A Handy without a wrapper is a process named handy: the other branch of
    # the pattern.
    reset
    start_handy_with handy ${plainHandy}/bin/handy
    ${ptt}/bin/handy-ptt down || fail "down fails for an unwrapped Handy"
    [ "$(signals)" = 1 ] || fail "down did not find an unwrapped Handy, named handy ($(signals) signals)"
    stop_handy

    # a tap: the release comes and the stream never opens; nothing is toggled
    reset; start_handy
    ${ptt}/bin/handy-ptt up || fail "up on a quick tap fails"
    [ "$(signals)" = 0 ] || fail "up with no stream sent a signal"
    stop_handy

    # Handy is found by what it is, not by what its command line says: a
    # process that carries the path of Handy as its argv[0] but is another
    # program (here the plain stand-in under another name, so its process name
    # is `other`) is not Handy. A matcher on the command line (pgrep -f) would
    # take it. (sleep would not do: coreutils is one binary that reads argv[0].)
    reset
    ln -s ${plainHandy}/bin/handy "$work/other"
    mkdir -p "$work/decoy"
    (export FAKE_DIR=$work/decoy; exec -a "${realHandy}/bin/.handy-wrapped" "$work/other") &
    decoy=$!
    for _ in $(seq 1 100); do
      [ -e "$work/decoy/ready" ] && break
      sleep 0.05
    done
    [ "$(cat /proc/$decoy/comm 2>/dev/null)" = other ] || fail "the look-alike is called $(cat /proc/$decoy/comm 2>/dev/null), not other"
    tr '\0' ' ' < /proc/$decoy/cmdline | grep -q '/bin/.handy-wrapped' || fail "the look-alike does not carry Handy's path in its command line, so it proves nothing"
    ${ptt}/bin/handy-ptt down || fail "down with a look-alike fails"
    grep -q 'Handy was not running' "$CALLS" || fail "a process that only carries Handy's path was taken for Handy"
    kill "$decoy"; wait "$decoy" 2>/dev/null || true

    # Handy 0.10.0 runs its transcription in a child process that it names
    # Handy-worker. pgrep -x is case-sensitive and takes the whole name, so the
    # worker is not taken for Handy, even when it is the older process (pgrep
    # -o picks the oldest match).
    reset
    ln -s ${plainHandy}/bin/handy "$work/Handy-worker"
    mkdir -p "$work/worker"
    (export FAKE_DIR=$work/worker; exec "$work/Handy-worker") &
    worker=$!
    for _ in $(seq 1 100); do
      [ -e "$work/worker/ready" ] && break
      sleep 0.05
    done
    [ "$(cat /proc/$worker/comm 2>/dev/null)" = Handy-worker ] || fail "the worker decoy is called $(cat /proc/$worker/comm 2>/dev/null), not Handy-worker"
    ${ptt}/bin/handy-ptt down || fail "down with only a worker fails"
    grep -q 'Handy was not running' "$CALLS" || fail "a process named Handy-worker was taken for Handy"
    reset; start_handy
    ${ptt}/bin/handy-ptt down || fail "down with a worker beside Handy fails"
    [ "$(signals)" = 1 ] || fail "down beside an older Handy-worker sent $(signals) signals to Handy, not 1"
    # The stand-in opens its log at start, so an empty one means no signal.
    [ ! -s "$work/worker/usr2" ] || fail "down signalled the worker, not Handy"
    stop_handy
    kill "$worker"; wait "$worker" 2>/dev/null || true

    # A runtime directory that cannot be used, which neither stops the take nor
    # prints an error into the session: the mode file cannot be written, `down`
    # still toggles, and `up` has no mode to follow and takes its own argument.
    # Once with XDG_RUNTIME_DIR pointing at nothing, which runs everywhere, and
    # once with it unset, which needs /run/user/UID to be absent too (the
    # fallback) and says so when it is skipped.
    unusable() { # unusable LABEL VAR=VALUE... (or unset)
      local label=$1
      shift
      reset; start_handy
      (env "$@" ${ptt}/bin/handy-ptt down 2> "$work/err") || fail "$label: down fails"
      [ "$(signals)" = 1 ] || fail "$label: down sent $(signals) toggle signals, not 1"
      [ ! -s "$work/err" ] || fail "$label: down prints: $(cat "$work/err")"
      touch "$FAKE_RECORDING"
      : > "$CALLS"
      (env "$@" ${ptt}/bin/handy-ptt up clean 2> "$work/err") || fail "$label: up fails"
      grep -qx 'launch --toggle-post-process' "$CALLS" || fail "$label: up without a mode file did not take its own argument: $(cat "$CALLS")"
      [ ! -s "$work/err" ] || fail "$label: up prints: $(cat "$work/err")"
      stop_handy
    }
    unusable "XDG_RUNTIME_DIR is a missing directory" XDG_RUNTIME_DIR="$work/does/not/exist"
    if [ ! -e "/run/user/$(id -u)" ]; then
      unusable "XDG_RUNTIME_DIR is unset" -u XDG_RUNTIME_DIR
    else
      echo "skipped: XDG_RUNTIME_DIR unset case, /run/user/$(id -u) exists and the mode file would be written there"
    fi

    # pgrep was asked for the user's own processes only, every time.
    [ -s "$PGREP_LOG" ] || fail "handy-ptt never called pgrep"
    if grep -v -- " -u $(id -u) " "$PGREP_LOG" | grep -q .; then
      fail "handy-ptt called pgrep without -u $(id -u): $(grep -v -- " -u $(id -u) " "$PGREP_LOG" | head -1)"
    fi

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
