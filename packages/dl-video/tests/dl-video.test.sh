#!/usr/bin/env bash
# Tests for dl-video (packages/dl-video), run by the check bin-dl-video. The
# tools around it are stand-ins, in front of the script's own (see
# tests/bin/helpers/stub-first.nix): systemd-run and systemctl log what they are
# asked and answer from variables, so no unit is started; ffmpeg and ffprobe
# write a file and print durations, so no network is used; notify-send logs the
# notifications. The contract is the unit's name and arguments, the filename
# rules, and the verdict of the worker on a finished, truncated or empty file.
#
# DL_VIDEO_UNDER_TEST=<file> tests another copy; by default it is the dl-video
# on the PATH.

# The checks are eval'd, so their $ expand at check time.
# shellcheck disable=SC2016

set -uo pipefail

SUT=$(readlink -f "${DL_VIDEO_UNDER_TEST:-$(type -P dl-video)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/dl-video-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/work" "$SB/nopath"
stub() { # stub NAME: the script on stdin, made executable, naming this bash
    cat >"$SB/bin/$1"
    sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/$1"
    chmod +x "$SB/bin/$1"
}
stub systemd-run <<'STUB'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >>"$LOG"
exit "${RUN_RC:-0}"
STUB
stub systemctl <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$LOG"
[[ $* == *is-active* && -n ${ACTIVE:-} && $* == *"$ACTIVE.service"* ]]
STUB
stub notify-send <<'STUB'
#!/usr/bin/env bash
printf 'notify %s\n' "$*" >>"$LOG"
STUB
# ffmpeg writes FF_BYTES bytes to its last argument and prints two progress
# blocks the way -progress pipe:1 does; ffprobe answers the two questions the
# script asks: the duration of the source or of the file, and its streams.
stub ffmpeg <<'STUB'
#!/usr/bin/env bash
out=${*: -1}
printf 'ffmpeg %s\n' "$*" >>"$LOG"
head -c "${FF_BYTES:-2048}" /dev/zero >"$out"
printf 'out_time_us=5000000\ntotal_size=1048576\nprogress=continue\nout_time_us=10000000\ntotal_size=2097152\nprogress=end\n'
exit "${FF_RC:-0}"
STUB
stub ffprobe <<'STUB'
#!/usr/bin/env bash
if [[ $* == *format=duration* ]]; then
    if [[ ${*: -1} == "$OUT" ]]; then printf '%s\n' "${PROBE_OUT:-10.0}"; else printf '%s\n' "${PROBE_IN:-10.0}"; fi
elif [[ $* == *stream=index* ]]; then
    [[ ${PROBE_STREAMS:-1} == 0 ]] || printf '0\n1\n'
fi
STUB

# run ENV... -- ARGS: sets $out, $rc, $log. The working directory is $SB/work.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    : >"$SB/log"
    out=$(cd "$SB/work" && env -i HOME="$SB" PATH="$SB/nopath" STUB_PATH="$SB/bin" LOG="$SB/log" \
        "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1)
    rc=$?
    log=$(<"$SB/log")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: $out
    log: $log"; fi; }
unit_of() { sed -n 's/^systemd-run .*--unit=\([^ ]*\) .*/\1/p' <<<"$log"; }
file_of() { sed -n 's/^systemd-run .* --worker [^ ]* \(.*\) dl-video-.*/\1/p' <<<"$log"; }

echo "dl-video: starting the unit"

run -- --help
check "--help prints the usage and exits 0" '[[ $rc == 0 && $out == "usage: dl-video"* && -z $log ]]'
run --
check "no arguments: usage on stderr, exit 2" '[[ $rc == 2 && $out == "usage: dl-video"* ]]'
run -- http://x/v
check "one argument is too few: exit 2" '[[ $rc == 2 && $out == "usage: dl-video"* ]]'
run -- http://x/v a.mp4 extra
check "three arguments are too many: exit 2" '[[ $rc == 2 ]]'
run -- --frobnicate http://x/v a.mp4
check "an unknown option is refused" '[[ $rc == 1 && $out == *"unknown option: --frobnicate"* && -z $log ]]'
run -- not-a-url a.mp4
check "a first argument that is no URL is refused, with the order named" '[[ $rc == 1 && $out == *"first argument is the URL"* && -z $log ]]'
run -- http://x/v ''
check "an empty filename is refused" '[[ $rc == 1 && $out == *"filename must not be empty"* ]]'
run -- http://x/v somewhere/
check "a filename that ends in a slash is refused" '[[ $rc == 1 && $out == *"must not end in a slash"* ]]'
run -- http://x/v nodir/out.mp4
check "a directory that does not exist is refused" '[[ $rc == 1 && $out == *"no such directory: $SB/work/nodir"* ]]'

run -- http://x/v Talk
check "a name with no extension gets .mp4" '[[ $(file_of) == "$SB/work/Talk.mp4" ]]'
run -- http://x/v Talk.part2
check "an extension that is no container keeps its dot and gains .mp4" '[[ $(file_of) == "$SB/work/Talk.part2.mp4" ]]'
run -- http://x/v Show.MKV
check "a container extension is kept, in any case" '[[ $(file_of) == "$SB/work/Show.MKV" ]]'
run -- http://x/v Notes.txt
check ".txt is not a container, so it gains .mp4" '[[ $(file_of) == "$SB/work/Notes.txt.mp4" ]]'
run -- http://x/v 'sub/../Up.mp4'
check "the path is resolved, .. included" '[[ $(file_of) == "$SB/work/Up.mp4" ]]'
check "the file is named on the output, with the commands to watch and stop it" \
    '[[ $out == *"file   $SB/work/Up.mp4"* && $out == *"journalctl --user -fu dl-video-Up"* && $out == *"systemctl --user stop dl-video-Up"* ]]'

run -- http://x/v 'My Video (final) -- 2.mp4'
check "the unit name is a slug: no spaces, no doubled dashes, none at the ends" '[[ $(unit_of) == "dl-video-My-Video-final-2" ]]'
long=$(printf 'x%.0s' $(seq 100))
run -- http://x/v "$long.mp4"
check "the slug is cut at 64 characters" '[[ $(unit_of) == "dl-video-$(printf "x%.0s" $(seq 64))" ]]'
run -- http://x/v '---.mp4'
check "a name with nothing in it for a slug is called video" '[[ $(unit_of) == "dl-video-video" ]]'

run -- http://x/v Unit.mp4
check "the unit stops with SIGINT, so ffmpeg writes its trailer, and has a minute to do it" \
    '[[ $log == *"-p KillSignal=SIGINT -p TimeoutStopSec=60"* && $log == *"--user"* ]]'
check "the worker gets the URL, the file and the unit" '[[ $log == *"--worker http://x/v $SB/work/Unit.mp4 dl-video-Unit" ]]'
check "a failed earlier unit is cleared first" '[[ $log == *"systemctl --user reset-failed dl-video-Unit.service"* ]]'
check "without a session bus address none is passed on" '[[ $log != *DBUS_SESSION_BUS_ADDRESS* ]]'
run DBUS_SESSION_BUS_ADDRESS=unix:path=/x/bus -- http://x/v Unit.mp4
check "the session bus address is passed on, for the notifications" '[[ $log == *"--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/x/bus"* ]]'

run ACTIVE=dl-video-Unit -- http://x/v Unit.mp4
check "a download that is still running under that name is refused" \
    '[[ $rc == 1 && $out == *"dl-video-Unit is already running"* && $log != *systemd-run* ]]'

: >"$SB/work/Taken.mp4"
run -- http://x/v Taken.mp4
check "an existing file is not overwritten" '[[ $rc == 1 && $out == *"file exists, pass -f"* && $log != *systemd-run* ]]'
run -- -f http://x/v Taken.mp4
check "-f overwrites it" '[[ $rc == 0 && $log == *"systemd-run"* ]]'
run -- --force http://x/v Taken.mp4
check "--force is the same" '[[ $rc == 0 && $log == *"systemd-run"* ]]'
run RUN_RC=1 -- http://x/v Fail.mp4
check "systemd-run failing ends the script with an error, before it claims to have started" '[[ $rc != 0 && $out != *"started "* ]]'

echo "dl-video: the worker"

W="$SB/work/W.mp4"
worker() { # worker ENV... : the worker mode on W.mp4
    rm -f "$W"
    run OUT="$W" "$@" -- --worker http://x/v "$W" dl-video-W
}
worker
check "a finished download: ffmpeg copies, nothing is re-encoded, and the verdict is done" \
    '[[ $rc == 0 && $out == "progress "*"done: $W, "* && $log == *"-c copy -y $W"* ]]'
check "the progress lines show the position, the total and the percentage" \
    '[[ $out == *"progress 0:05 of 0:10 (50%), 1.0 MiB"* && $out == *"progress 0:10 of 0:10 (100%), 2.0 MiB"* ]]'
check "the user is told, with the size and the time" '[[ $log == *"notify -a dl-video Download finished W.mp4, "* ]]'
worker PROBE_IN=N/A PROBE_OUT=N/A
check "a source with no duration (a live stream) shows no percentage, and is done" \
    '[[ $rc == 0 && $out == *"progress 0:05, 1.0 MiB"* && $out == *"done: "* ]]'
worker PROBE_IN=100 PROBE_OUT=50
check "a file much shorter than the source is a failure, and is kept" \
    '[[ $rc == 1 && $out == *"failed: truncated, got 50s of 100s (kept $W)"* && -e $W && $log == *"notify -a dl-video -u critical Download failed"* ]]'
worker PROBE_IN=100 PROBE_OUT=99
check "a file within two percent of the source is complete" '[[ $rc == 0 ]]'
worker PROBE_IN=10 PROBE_OUT=8
check "two seconds short on a short video is not truncation: it takes both a 2 s and a 2 % gap" '[[ $rc == 0 ]]'
worker PROBE_IN=10 PROBE_OUT=7
check "three seconds short of ten is" '[[ $rc == 1 && $out == *"failed: truncated, got 7s of 10s"* ]]'
worker PROBE_STREAMS=0
check "ffmpeg exiting 0 on a file with no streams is a failure, and the file is removed" \
    '[[ $rc == 1 && $out == *"ffmpeg exited 0 but wrote no streams"* && ! -e $W ]]'
worker FF_BYTES=0
check "an empty file is the same" '[[ $rc == 1 && ! -e $W ]]'
worker FF_RC=1
check "ffmpeg failing is a failure with its exit status, and the user is told" \
    '[[ $rc == 1 && $out == *"failed after "*"(ffmpeg exit 1)"* && $log == *"notify -a dl-video -u critical Download failed"* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
