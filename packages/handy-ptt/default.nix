# Hold-to-talk for Handy, driven by two key bindings of the Sway configuration:
#
#   bindsym --no-repeat $mod+d exec handy-ptt down [clean]
#   bindsym --release   $mod+d exec handy-ptt up   [clean]
#
# Without the second argument the text is Handy's plain transcription. With
# `clean` the same recording goes through Handy's post-processing. `down`
# remembers its mode and `up` follows it, because the stop must reach the
# binding that started the take (sway fires a --release bind for whichever key
# comes up first).
#
# Handy only offers a toggle, and a bare toggle on press and on release
# inverts for good once one of them is dropped, for example a press that lands
# while Handy is still transcribing the last recording. Then every release
# STARTS a recording. So the truth is Handy's PipeWire capture stream, which
# exists exactly while it records: `down` toggles only when no stream is open,
# `up` only when one is.
#
# The plain toggle is SIGUSR2. Handy does not take SIGUSR1 for the cleaned one
# on Linux (WebKitGTK's garbage collector sends it to its own threads), so
# `clean` goes through Handy's single-instance command line,
# `--toggle-post-process`, which forwards to the running Handy and exits. It
# goes through handy-launch, so the process stays off the NVIDIA card.
#
# The script is carried over from the Fedora setup as it was (a POSIX shell
# script), and runs without errexit, nounset and pipefail on purpose:
# `pactl ... | grep -q` would be a failure under pipefail whenever grep stops
# reading early, and `pgrep` fails when Handy is not running, which the script
# handles itself. shellcheck still runs on it at build time.
#
# Changes from the original:
#
#   - the helper commands come from the store (pgrep, pactl, notify-send,
#     handy-launch) and no longer from ~/.local/bin;
#   - a direction other than down or up is a usage error at once. The original
#     said so only while Handy ran, and otherwise exited 0 silently, so a typo
#     in the key binding looked like Handy being off;
#   - Handy is found by the name of its process, `.handy-wrapped`, and no
#     longer as `handy`. On Fedora Handy is /usr/bin/handy and the process is
#     called handy. In nixpkgs bin/handy is a binary wrapper that execs
#     bin/.handy-wrapped, and the kernel names a process after the file it
#     runs, so `pgrep -x handy` never found it and every key press took Handy
#     for stopped (found in review 2026-11-08; the first test had replaced
#     pgrep). The name is the file's, whatever argv[0] is: the wrapper has
#     --inherit-argv0, so the command line holds the name Handy was started
#     by, the full path from handy-launch and a bare `handy` from a shell. The
#     name fits the 15 characters the kernel keeps. A Handy that a rebuild has
#     since replaced is still the one that runs, and still the one to signal.
#   - a mode file that cannot be written (no XDG_RUNTIME_DIR and no
#     /run/user/UID) does not stop the take or print an error: `down` toggles
#     all the same and `up` takes its own argument for the mode.
{
  lib,
  writeShellApplication,
  procps,
  pulseaudio,
  libnotify,
  gnugrep,
  coreutils,
  # The packages of ravnix: handy-launch is one.
  ravnix,
}:
let
  # The name of Handy's process (see above); `handy` is the unwrapped build.
  # pgrep -x takes the whole name, so `handy-launch`, `handy-ptt` and the
  # WebKit processes do not match. pgrep is told the user (-u): another user's
  # Handy on the same machine is not the one to signal (kill would fail with
  # EPERM, and the take would never start).
  handyProcess = "\\.handy-wrapped|handy";
in
writeShellApplication {
  name = "handy-ptt";
  runtimeInputs = [
    procps
    pulseaudio
    libnotify
    gnugrep
    coreutils
    ravnix.handy-launch
  ];
  bashOptions = [ ];
  text = ''
    case "''${1:-}" in
    down | up) ;;
    *) echo "usage: handy-ptt down|up [clean]" >&2; exit 2 ;;
    esac
    mode=''${2:-plain}
    case "$mode" in
    plain | clean) ;;
    *) echo "usage: handy-ptt down|up [clean]" >&2; exit 2 ;;
    esac

    state=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/handy-ptt.mode

    pid=$(pgrep -o -x -u "$(id -u)" -- ${lib.escapeShellArg handyProcess})
    if [ -z "$pid" ]; then
        [ "$1" = down ] || exit 0
        notify-send -a Handy "Handy was not running" "Starting it now; hold the key again in a few seconds."
        exec handy-launch --start-hidden
    fi

    recording() { pactl list source-outputs 2>/dev/null | grep -q "cpal-pulseaudio-$pid\""; }

    toggle() {
        if [ "$mode" = clean ]; then
            handy-launch --toggle-post-process
        else
            kill -USR2 "$pid"
        fi
    }

    case "$1" in
    down)
        if ! recording; then
            { printf '%s\n' "$mode" > "$state"; } 2>/dev/null
            toggle
        fi ;;
    up)
        # The stop must reach the binding that started the take, so `up` takes
        # the mode `down` used, not its own argument.
        if [ -r "$state" ]; then
            read -r saved < "$state"
            case "$saved" in plain | clean) mode=$saved ;; esac
        fi
        # A quick tap can release before the stream is open, so give it a moment.
        # The forwarded CLI call opens the stream a little later than a signal.
        i=0
        while ! recording; do
            i=$((i + 1)); [ "$i" -gt 8 ] && exit 0
            sleep 0.1
        done
        toggle
        rm -f "$state" ;;
    *)
        echo "usage: handy-ptt down|up [clean]" >&2; exit 2 ;;
    esac
  '';
}
