#!/usr/bin/env bash
# Runs the exporter's loop from deploy/compose/paperless/docker-compose.yaml,
# as docker-compose config resolved it, against stubs, for
# tests/deploy/paperless-compose.nix. Usage: paperless-exporter-loop.sh SCRIPT
#
# The loop's paths under /usr/src/paperless are moved into a scratch root.
# The stubs: `date` prints a fake clock; `sleep` moves the clock to the
# next of a list of times and, when the list is used up, ends the loop with
# SIGTERM, as `docker stop` does; `python3` logs its directory and arguments
# and exits with $STUB_PYTHON_RC; `curl` logs its arguments and its standard
# input. Each case gives a start time, the times the loop wakes at, and what
# must have happened.
set -euo pipefail
script=$(realpath -- "${1:?usage: paperless-exporter-loop.sh SCRIPT}")
failed=0
fail() { echo "FAIL (exporter loop, $tc): $*" >&2; failed=1; }

work=$(mktemp -d -p "${TMPDIR:-/tmp}" exporter-loop.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
stubs=$work/stubs
mkdir -p "$stubs"
stub() { # NAME, with its body on standard input
  { printf '#!%s\nset -euo pipefail\n' "$BASH"; cat; } > "$stubs/$1"
  chmod +x "$stubs/$1"
}
stub date <<'EOF'
read -r day time < "$STUB/clock"
case $* in
  +%F) echo "$day" ;;
  +%H:%M) echo "$time" ;;
  *) echo "date stub: unexpected arguments: $*" >&2; exit 2 ;;
esac
EOF
stub sleep <<'EOF'
echo "$*" >> "$STUB/sleeps"
if [ -s "$STUB/times" ]; then
  head -n 1 "$STUB/times" > "$STUB/clock"
  sed -i 1d "$STUB/times"
else
  kill -TERM "$PPID"
fi
EOF
stub python3 <<'EOF'
echo "$(pwd) $*" >> "$STUB/python"
exit "${STUB_PYTHON_RC:-0}"
EOF
stub curl <<'EOF'
echo "$*" >> "$STUB/curl.args"
cat >> "$STUB/curl.stdin"
EOF

url='https://kuma.example.org/api/push/s3cr3tT0ken?status=up'

# run CASE START TIMES... : runs the loop from START, waking at each of TIMES.
run() {
  tc=$1
  STUB=$work/$tc
  root=$STUB/root
  mkdir -p "$root/src" "$root/data" "$root/export"
  echo "$2" > "$STUB/clock"
  shift 2
  printf '%s\n' "$@" > "$STUB/times"
  [ $# -gt 0 ] || : > "$STUB/times"
  : > "$STUB/python"
  : > "$STUB/sleeps"
  : > "$STUB/curl.args"
  : > "$STUB/curl.stdin"
  sed "s|/usr/src/paperless|$root|g" "$script" > "$STUB/loop.sh"
  [ -z "${STATE:-}" ] || echo "$STATE" > "$root/data/exporter.last"
  status=0
  export STUB
  PATH=$stubs:$PATH KUMA_PUSH_URL=${PUSH-$url} STUB_PYTHON_RC=${RC:-0} \
    timeout 20 "$BASH" "$STUB/loop.sh" > "$STUB/out" 2> "$STUB/err" || status=$?
  [ "$status" = 0 ] || { fail "the loop exited $status"; cat "$STUB/out" "$STUB/err" >&2; }
}
runs() { # COUNT: document_exporter ran COUNT times, each as it must
  local n
  n=$(wc -l < "$STUB/python")
  [ "$n" = "$1" ] || fail "document_exporter ran $n times, not $1"
  if [ "$n" -gt 0 ] && grep -vxF "$root/src manage.py document_exporter $root/export --no-progress-bar --skip-checks" "$STUB/python"; then
    fail "document_exporter ran another way"
  fi
}
pushes() { # COUNT: the push went out COUNT times, never with the URL on argv
  local n
  n=$(grep -c . "$STUB/curl.args" || true)
  [ "$n" = "$1" ] || fail "curl ran $n times, not $1"
  if grep -qF 's3cr3tT0ken' "$STUB/curl.args"; then fail "the push URL is on curl's command line"; fi
  if [ "$1" -gt 0 ]; then
    n=$(grep -cxF "url = \"$url\"" "$STUB/curl.stdin" || true)
    [ "$n" = "$1" ] || fail "curl read the URL $n times on its standard input, not $1"
  fi
}
sleeps_are_60() {
  if grep -vxF 60 "$STUB/sleeps"; then fail "the loop sleeps another time than 60 s"; fi
}

# Two days: it runs at 02:30 each day, not before and not twice.
run daily '2026-03-10 01:00' '2026-03-10 02:29' '2026-03-10 02:30' '2026-03-10 02:31' \
  '2026-03-10 23:59' '2026-03-11 00:00' '2026-03-11 02:29' '2026-03-11 02:30' '2026-03-11 02:31'
runs 2
pushes 2
sleeps_are_60
grep -qx 2026-03-11 "$root/data/exporter.last" || fail "the last run's day is not recorded"

# A failed export pushes nothing.
RC=1 run failure '2026-03-10 02:29' '2026-03-10 02:30' '2026-03-10 02:31'
runs 1
pushes 0
grep -q 'document_exporter failed' "$STUB/err" || fail "a failed export is not reported"

# No push URL, no push.
PUSH='' run no-url '2026-03-10 02:29' '2026-03-10 02:30'
runs 1
pushes 0

# A restart after the day's run does not run again; one before it waits.
STATE=2026-03-10 run restart-after '2026-03-10 09:00' '2026-03-10 09:01'
runs 0
STATE=2026-03-09 run restart-before '2026-03-10 01:00' '2026-03-10 01:01'
runs 0

# A day it missed (the NAS was off at 02:30) is caught up when it starts.
STATE=2026-03-09 run catch-up '2026-03-10 09:00' '2026-03-10 09:01'
runs 1
pushes 1

# The spring-forward night has no 02:30 in Europe/Berlin: it runs at 03:00.
run spring-forward '2026-03-29 01:58' '2026-03-29 01:59' '2026-03-29 03:00' '2026-03-29 03:01'
runs 1

# The fall-back night has two: it runs once.
run fall-back '2026-10-25 02:29' '2026-10-25 02:30' '2026-10-25 02:59' '2026-10-25 02:30' '2026-10-25 02:31'
runs 1

[ "$failed" = 0 ]
