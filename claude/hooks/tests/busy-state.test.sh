#!/usr/bin/env bash
# Tests for busy-state.sh, one directory up: the hook that writes busy or
# idle per Claude Code session for claude-roll.
#
# The hook runs with env -i: HOME and XDG_STATE_HOME point into the
# sandbox, and PATH is a directory of links to the tools it may use (cat,
# jq, mkdir, mktemp, mv, rm), so a hook that starts calling another tool
# fails here first, and leaving jq out is how "no jq" is simulated.
#
# Run:  bash busy-state.test.sh          (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

set -uo pipefail

SELF=$(readlink -f "$0")
HOOK=${SELF%/*/*}/busy-state.sh
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }
ENV_BIN=$(type -P env) || { echo "the tests need env" >&2; exit 2; }
BASH_BIN=$(type -P bash) || BASH_BIN=$BASH

pass=0
fail=0
CASE=""
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n       %s\n' "$CASE" "$1"; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/busy-state-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

TOOLS=$ROOT/tools NO_JQ=$ROOT/no-jq
mkdir -p "$TOOLS" "$NO_JQ"
for tool in cat jq mkdir mktemp mv rm; do
	bin=$(type -P "$tool") || { echo "the tests need $tool" >&2; exit 2; }
	ln -s "$bin" "$TOOLS/$tool"
	[ "$tool" = jq ] || ln -s "$bin" "$NO_JQ/$tool"
done

SID=0a1b2c3d-1111-4222-8333-444455556666
STATE=$ROOT/state
BUSY=$STATE/ravnix/claude-busy

# run EVENT [SESSION] [PATH] [extra env...]: runs the hook with the input of
# that event; OUT and RC hold what it printed and how it exited.
OUT="" RC=0
run() {
	local event=$1 session=${2-$SID} path=${3:-$TOOLS}
	shift 3 2>/dev/null || shift $#
	local input
	input=$(printf '{"session_id":"%s","hook_event_name":"%s","prompt":"x"}' "$session" "$event")
	run_raw "$input" "$path" XDG_STATE_HOME="$STATE" "$@"
}
run_raw() {
	local input=$1 path=$2
	shift 2
	OUT=$(printf '%s' "$input" | "$ENV_BIN" -i HOME="$ROOT/home" PATH="$path" "$@" "$BASH_BIN" "$HOOK" 2>&1)
	RC=$?
}
word() { [ -f "$BUSY/$SID" ] && "$TOOLS/cat" "$BUSY/$SID"; }
expect_word() {
	local got
	got=$(word)
	if [ "$got" = "$1" ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "file: '$got' (want '$1'), rc $RC, output '$OUT'"; fi
}
nothing_written() {
	local n
	n=$(find "$ROOT" -path "$ROOT/tools" -prune -o -path "$ROOT/no-jq" -prune -o -type f -print | wc -l)
	if [ "$n" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "files: $n, rc $RC, output '$OUT'"; fi
}
clean() { rm -rf -- "${STATE:?}" "${ROOT:?}/home" "${ROOT:?}/x"; }

echo "busy-state.sh"

CASE="a prompt makes the session busy"
clean; run UserPromptSubmit; expect_word busy
CASE="Stop makes it idle"
run Stop; expect_word idle
CASE="StopFailure makes it idle"
run UserPromptSubmit; run StopFailure; expect_word idle
CASE="SessionStart makes it idle"
run UserPromptSubmit; run SessionStart; expect_word idle
CASE="SessionEnd removes the file"
run SessionEnd
if [ ! -e "$BUSY/$SID" ] && [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "file left or rc $RC"; fi
CASE="SessionEnd for a session without a file"
run SessionEnd; nothing_written
CASE="no temporary file is left"
clean; run UserPromptSubmit; run Stop
n=$(find "$BUSY" -type f | wc -l)
if [ "$n" = 1 ]; then ok; else bad "$n files in $BUSY"; fi

CASE="an event it does not handle writes nothing"
clean; run PreToolUse; nothing_written

for odd in "" "../../x" "x; rm -r ~" "$SID/../x" "${SID}0" "--help" "0a1b2c3d_1111-4222-8333-444455556666"; do
	CASE="session id '$odd' is not used"
	clean; run UserPromptSubmit "$odd"; nothing_written
done
CASE="a session id with a newline is not used"
clean; run_raw "$(printf '{"session_id":"%s\\nx","hook_event_name":"UserPromptSubmit"}' "$SID")" "$TOOLS" XDG_STATE_HOME="$STATE"; nothing_written
CASE="a session id that is no string is not used"
clean; run_raw '{"session_id":["a"],"hook_event_name":"UserPromptSubmit"}' "$TOOLS" XDG_STATE_HOME="$STATE"; nothing_written

for raw in "" "{" "not json" "null" "[]" '{"hook_event_name":"Stop"}'; do
	CASE="input '$raw' writes nothing"
	clean; run_raw "$raw" "$TOOLS" XDG_STATE_HOME="$STATE"; nothing_written
done

CASE="a huge prompt is read whole"
clean
big=$(head -c 1048576 /dev/zero | tr '\0' 'x')
run_raw "{\"session_id\":\"$SID\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$big\"}" "$TOOLS" XDG_STATE_HOME="$STATE"
expect_word busy

CASE="without jq it does nothing"
clean; run UserPromptSubmit "$SID" "$NO_JQ"; nothing_written

CASE="without XDG_STATE_HOME it writes under HOME"
clean
run_raw "{\"session_id\":\"$SID\",\"hook_event_name\":\"UserPromptSubmit\"}" "$TOOLS"
if [ "$("$TOOLS/cat" "$ROOT/home/.local/state/ravnix/claude-busy/$SID" 2>/dev/null)" = busy ] && [ "$RC" = 0 ]; then ok; else bad "rc $RC, output '$OUT'"; fi

CASE="without HOME or XDG_STATE_HOME it does nothing"
clean
OUT=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$SID" | "$ENV_BIN" -i PATH="$TOOLS" "$BASH_BIN" "$HOOK" 2>&1)
RC=$?
nothing_written

CASE="a state directory it cannot make: exit 0, silent"
clean
mkdir -p "$ROOT/x"
: >"$ROOT/x/state"
run_raw "{\"session_id\":\"$SID\",\"hook_event_name\":\"UserPromptSubmit\"}" "$TOOLS" XDG_STATE_HOME="$ROOT/x/state"
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok; else bad "rc $RC, output '$OUT'"; fi

CASE="concurrent prompts and stops leave one word and no temporary file"
clean
for i in $(seq 1 40); do
	if ((i % 2)); then ev=UserPromptSubmit; else ev=Stop; fi
	printf '{"session_id":"%s","hook_event_name":"%s"}' "$SID" "$ev" |
		"$ENV_BIN" -i HOME="$ROOT/home" PATH="$TOOLS" XDG_STATE_HOME="$STATE" "$BASH_BIN" "$HOOK" &
done
wait
got=$(word)
n=$(find "$BUSY" -type f | wc -l)
if { [ "$got" = busy ] || [ "$got" = idle ]; } && [ "$n" = 1 ]; then ok; else bad "file '$got', $n files"; fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
