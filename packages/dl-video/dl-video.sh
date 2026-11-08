#!/usr/bin/env bash
# dl-video — stream-copy a remote video to a file, in the background.
#
# WHY A TRANSIENT UNIT: a download of a long video (or of a live HLS/DASH
# manifest) outlives the terminal it was started from. `systemd-run --user`
# gives each download its own service, so closing the terminal does not kill
# it, the log goes to the journal instead of a stray file next to the video,
# and one download can be stopped by name without hunting for a PID. Linger is
# enabled for this user, so a download survives logout too.
#
# WHY -c copy: no re-encode. The container changes, the streams do not, so the
# download is network-bound and costs no CPU. The flip side is that the output
# extension has to name a container the source codecs fit into, which is why
# the default is .mp4 (H.264/AAC, i.e. web video) and why an unrecognized
# extension gets .mp4 appended rather than handed to ffmpeg to choke on.
#
# USAGE:
#   dl-video <URL> <filename>      no known media extension => .mp4 appended
#   dl-video -f <URL> <filename>   overwrite an existing file
#
# The file lands in the current directory unless <filename> carries a path.
#   progress   journalctl --user -fu dl-video-<slug>   (one line every 15 s)
#   stop       systemctl --user stop dl-video-<slug>
#
# Stopping sends SIGINT, not SIGTERM, because ffmpeg treats SIGINT the way it
# treats `q`: it writes the container trailer, so a download stopped early
# stays playable. A SIGTERMed .mp4 has no moov atom and plays nowhere.
set -euo pipefail

# Extensions ffmpeg can pick a muxer for and that a stream copy of web video
# plausibly lands in. Anything else counts as "no ending" and gets .mp4.
readonly CONTAINERS='mp4 m4v mkv webm mov avi ts m2ts mts mpg mpeg ogv flv wmv mp3 m4a aac flac opus ogg wav'

die() { printf 'dl-video: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
usage: dl-video [-f] <URL> <filename>

  Downloads <URL> to <filename> with ffmpeg -c copy, as a background systemd
  user unit. A filename with no known media extension gets .mp4.

  -f, --force   overwrite <filename> if it already exists
  -h, --help    this text
USAGE
}

fmt_elapsed() {
  local s=$1
  if (( s >= 3600 )); then printf '%dh%02dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  else printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )); fi
}

# Whole seconds, empty when the source has no duration (a live stream) or
# cannot be probed. Cut at the dot rather than printf %.0f, because %f honours
# LC_NUMERIC and would print "5,0" under a German locale.
duration() {
  local d
  d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 -- "$1" 2>/dev/null) || return 0
  [[ -z $d || $d == N/A ]] && return 0
  printf '%s' "${d%%.*}"
}

has_streams() {
  [[ -s $1 ]] || return 1
  local n
  n=$(ffprobe -v error -show_entries stream=index -of csv=p=0 -- "$1" 2>/dev/null | grep -c .) || return 1
  (( n > 0 ))
}

notify() {
  command -v notify-send >/dev/null || return 0
  notify-send -a dl-video "$@" || true
}

# --worker is the body of the transient unit, not a public flag.
if [[ ${1-} == --worker ]]; then
  url=$2 out=$3 unit=$4
  start=$SECONDS
  stopped=0

  # A handler, never `trap '' INT`: an IGNORED signal is inherited by children,
  # and ffmpeg must still RECEIVE the SIGINT so it writes the trailer. With a
  # handler, bash defers it until the foreground pipeline has finished, so the
  # reporting below still runs after a `systemctl --user stop`.
  trap 'stopped=1' INT TERM

  # Probed before the transfer, because a finished-but-truncated download is
  # the failure this tool is most likely to hit and ffmpeg does not report it:
  # a source that dies mid-transfer still exits 0 and leaves a valid container
  # holding nothing. Empty for a live stream, which has no duration to compare
  # against, and it doubles as the denominator of the progress percentage.
  want=$(duration "$url")

  rc=0
  # -progress, not -stats: ffmpeg logs its status line at INFO level, so
  # -loglevel warning (which is what keeps the journal readable) throws the
  # progress away silently. -progress writes key=value blocks to stdout
  # regardless of log level. awk folds one block into one line and passes
  # ffmpeg's own warnings and errors through untouched.
  ffmpeg -hide_banner -nostdin -loglevel warning -progress pipe:1 -stats_period 15 \
         -i "$url" -c copy -y "$out" 2>&1 \
    | awk -v want="${want:-0}" '
        /^out_time_us=/ { split($0, a, "="); us = a[2] + 0 }
        /^total_size=/  { split($0, a, "="); sz = a[2] + 0 }
        /^progress=/ {
          s = int(us / 1000000); mb = sz / 1048576
          if (want > 0)
            printf "progress %d:%02d of %d:%02d (%d%%), %.1f MiB\n",
                   s/60, s%60, want/60, want%60, 100*s/want, mb
          else
            printf "progress %d:%02d, %.1f MiB\n", s/60, s%60, mb
          fflush(); next
        }
        /^(frame|fps|bitrate|total_size|out_time[a-z_]*|dup_frames|drop_frames|speed|stream_[^=]*)=/ { next }
        { print; fflush() }
      ' || rc=$?

  elapsed=$(fmt_elapsed $(( SECONDS - start )))
  file=${out##*/}
  size=$(du -h -- "$out" 2>/dev/null | cut -f1)

  if (( stopped )); then
    printf 'stopped on request: %s, %s in %s\n' "$out" "${size:-?}" "$elapsed"
    notify "Download stopped" "$file, ${size:-?} kept"
    exit 0
  fi

  if (( rc == 0 )) && ! has_streams "$out"; then
    rc=1
    printf 'failed: ffmpeg exited 0 but wrote no streams, removing %s\n' "$out" >&2
    rm -f -- "$out"
  fi

  got=''
  if (( rc == 0 )); then got=$(duration "$out"); fi
  if (( rc == 0 )) && [[ -n $want && -n $got ]] \
     && (( got < want - 2 && got * 100 < want * 98 )); then
    rc=1
    printf 'failed: truncated, got %ss of %ss (kept %s)\n' "$got" "$want" "$out" >&2
  fi

  if (( rc == 0 )); then
    printf 'done: %s, %s in %s\n' "$out" "${size:-?}" "$elapsed"
    notify "Download finished" "$file, ${size:-?} in $elapsed"
  else
    printf 'failed after %s (ffmpeg exit %d)\n' "$elapsed" "$rc" >&2
    notify -u critical "Download failed" "$file, see journalctl --user -u $unit"
  fi
  exit "$rc"
fi

force=0
while (( $# )); do
  case $1 in
    -f|--force) force=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    --)         shift; break ;;
    -*)         die "unknown option: $1" ;;
    *)          break ;;
  esac
done

if (( $# != 2 )); then usage >&2; exit 2; fi
url=$1 name=$2

command -v ffmpeg >/dev/null || die 'ffmpeg is not installed'
[[ $url == *://* ]] || die "first argument is the URL, second is the filename (got: $url)"
[[ -n $name ]] || die 'filename must not be empty'

# Resolve the extension. A name whose last dot segment is not a container we
# recognize keeps that segment and gains .mp4 on top, so "Talk.part2" becomes
# "Talk.part2.mp4" rather than a muxer ffmpeg cannot find.
base=${name##*/}
[[ -n $base ]] || die "filename must not end in a slash: $name"
ext=''
if [[ $base == *.* ]]; then ext=${base##*.}; fi
if [[ -z $ext || " $CONTAINERS " != *" ${ext,,} "* ]]; then
  name+=.mp4
  base+=.mp4
fi

out=$(realpath -m -- "$name")
dir=${out%/*}
[[ -d $dir ]] || die "no such directory: $dir"
[[ -w $dir ]] || die "directory is not writable: $dir"
if [[ -e $out ]] && (( ! force )); then
  die "file exists, pass -f to overwrite: $out"
fi

# Slugified, NOT systemd-escape'd. The escape is correct and unreadable: a
# space becomes \x20, so the journalctl and systemctl lines printed below would
# need shell quoting to survive a copy and paste, and pasted bare they would
# silently address a different unit.
stem=${base%.*}
stem=${stem//[^A-Za-z0-9._-]/-}
while [[ $stem == *--* ]]; do stem=${stem//--/-}; done
stem=${stem#-}; stem=${stem%-}; stem=${stem:0:64}
[[ -n $stem ]] || stem=video
unit="dl-video-$stem"

if systemctl --user --quiet is-active "$unit.service" 2>/dev/null; then
  die "$unit is already running (stop it with: systemctl --user stop $unit)"
fi
# A previous failure leaves the unit loaded, and systemd-run refuses a name
# that is still known. Clearing it is what makes a retry just work.
systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true

self=$(realpath -- "${BASH_SOURCE[0]}")
run=(systemd-run --user --quiet --unit="$unit" --description="dl-video: $base"
     -p KillSignal=SIGINT -p TimeoutStopSec=60)
# The user manager does not always carry the session bus, and without it the
# finished notification goes nowhere.
if [[ -n ${DBUS_SESSION_BUS_ADDRESS-} ]]; then
  run+=(--setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS")
fi

"${run[@]}" -- "$self" --worker "$url" "$out" "$unit"

printf 'started  %s.service\n' "$unit"
printf '  file   %s\n' "$out"
printf '  watch  journalctl --user -fu %s\n' "$unit"
printf '  stop   systemctl --user stop %s\n' "$unit"
