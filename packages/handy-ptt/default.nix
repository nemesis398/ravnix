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
# Changes from the original: the helper commands come from the store (pgrep,
# pactl, notify-send, handy-launch) and no longer from ~/.local/bin; and a
# direction other than down or up is a usage error at once. The original said
# so only while Handy ran, and otherwise exited 0 silently, so a typo in the
# key binding looked like Handy being off.
{
  writeShellApplication,
  procps,
  pulseaudio,
  libnotify,
  gnugrep,
  coreutils,
  # The packages of ravnix: handy-launch is one.
  ravnix,
}:
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

    pid=$(pgrep -x handy | head -n 1)
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
            printf '%s\n' "$mode" > "$state"
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
