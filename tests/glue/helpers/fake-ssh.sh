#!/usr/bin/env bash
# A stand-in for ssh, for the tests of ravnix-laptop. FAKE_DIR holds its
# state. It records the call and then does what the files there say:
#
#   argv        written by the stand-in: the arguments of the last call, each
#               followed by a NUL
#   calls       written by the stand-in: one line per call
#   sleep       seconds to wait before anything else (to be signalled)
#   log         text it writes to the file given with -E, where the real ssh
#               writes its own messages
#   stdout      text it prints
#   stderr      text it prints on standard error, as a remote command's would
#   ssherr      text it prints on standard error last, after everything the
#               command printed (the `stderr` file, and what `run` writes), as
#               the real ssh does when the session ends in the middle of a
#               command (clientloop.c quit_message: "Connection to X closed by
#               remote host." or "Read from remote host X: ...", ending in CR
#               LF). It is not in the -E file, which holds ssh's log, and so it
#               is the command's stderr that holds it
#   run         if it exists: the last argument is run by bash -c, as the
#               remote shell would run it, and its status is the status
#   stdin.out   written by the stand-in when `stdin` exists: standard input
#   status      the exit status; without it, the command's under `run`, else 0
set -u
d="${FAKE_DIR:?}"
printf '%s\0' "$@" >"$d/argv"
echo call >>"$d/calls"

logfile=""
prev=""
for a in "$@"; do
	if [ "$prev" = -E ]; then logfile="$a"; fi
	prev="$a"
done

if [ -f "$d/sleep" ]; then sleep "$(<"$d/sleep")"; fi
if [ -f "$d/log" ] && [ -n "$logfile" ]; then cat "$d/log" >>"$logfile"; fi
if [ -f "$d/stdout" ]; then cat "$d/stdout"; fi
if [ -f "$d/stderr" ]; then cat "$d/stderr" >&2; fi
if [ -f "$d/stdin" ]; then cat >"$d/stdin.out"; fi

rc=0
if [ -f "$d/run" ]; then
	bash -c "${!#}" || rc=$?
fi
if [ -f "$d/ssherr" ]; then cat "$d/ssherr" >&2; fi
if [ -f "$d/status" ]; then rc=$(<"$d/status"); fi
exit "$rc"
