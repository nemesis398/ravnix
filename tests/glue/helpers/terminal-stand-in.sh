#!/usr/bin/env bash
# A stand-in for herdr, ssh and sleep, for the tests of the terminal glue's
# commands (terminal.test.bash). The first argument is the program it stands
# in for; the rest are the arguments the command gave it. FAKE_DIR holds its
# state, per program NAME and per call K (1, 2, ...):
#
#   NAME.calls    written by it: one line per call, the arguments joined by
#                 spaces
#   NAME.K.argv   written by it: the arguments of call K, each followed by a
#                 NUL
#   NAME.K.run    seconds call K takes, slept for real before it answers
#   NAME.K.out    text call K prints
#   NAME.K.err    text call K prints on standard error
#   NAME.K.status the exit status of call K; without it, 0
#   sleep.max     for sleep: after this many calls, end the command that
#                 called it (SIGTERM to the parent), since its loop never
#                 ends by itself
set -u
name="$1"
shift
d="${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$d/$name.calls"
k=$(wc -l <"$d/$name.calls")
printf '%s\0' "$@" >"$d/$name.$k.argv"

if [ -f "$d/$name.$k.run" ]; then sleep "$(<"$d/$name.$k.run")"; fi
if [ -f "$d/$name.$k.out" ]; then cat "$d/$name.$k.out"; fi
if [ -f "$d/$name.$k.err" ]; then cat "$d/$name.$k.err" >&2; fi
if [ "$name" = sleep ] && [ -f "$d/sleep.max" ] && [ "$k" -ge "$(<"$d/sleep.max")" ]; then
	kill -TERM "$PPID"
fi
rc=0
if [ -f "$d/$name.$k.status" ]; then rc=$(<"$d/$name.$k.status"); fi
exit "$rc"
