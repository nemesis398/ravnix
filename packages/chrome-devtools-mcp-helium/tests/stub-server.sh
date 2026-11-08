#!/usr/bin/env bash
# The stand-in for chrome-devtools-mcp in wrapper.test.sh. It writes what the
# wrapper handed it to $STUB_LOG, as it was while the server ran (the profile
# exists only then), and then does what $STUB_MODE says:
#
#   (unset)  exit with $STUB_RC (default 0)
#   crash    kill itself with SIGKILL, as a server whose browser took it down
#   echo     answer every line of stdin with "got LINE"
#   wait     say "ready" in the log, and wait for TERM; on TERM write "TERM"
#            to the log and exit 143; gives up (exit 99) after ten seconds
#            without a TERM, so that a test cannot hang
#   parentstop  as wait, but first send TERM to its parent, the wrapper, as a
#            stop that comes the moment the server starts; gives up (exit 99)
#            after five seconds without a TERM

log=${STUB_LOG:?the test sets STUB_LOG}

# How many entries (hidden ones too) a directory holds.
count_entries() {
	local entries
	shopt -s nullglob dotglob
	entries=("$1"/*)
	echo "${#entries[@]}"
}

# Field 22 of /proc/PID/stat, the start time of PID in clock ticks since boot
# (counted after the command name, which may hold spaces and parentheses).
starttime() {
	local stat fields
	stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
	read -ra fields <<<"${stat##*) }"
	printf '%s' "${fields[19]:-}"
}

prev=
dir=
for a in "$@"; do
	[[ $prev != --userDataDir ]] || dir=$a
	prev=$a
done

{
	for a in "$@"; do printf 'arg:%q\n' "$a"; done
	printf 'dir:%s\n' "$dir"
	printf 'tmpdir:%s\n' "${TMPDIR-unset}"
	printf 'noupdate:%s\n' "${CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS-unset}"
	printf 'nosandbox:%s\n' "${PUPPETEER_DANGEROUS_NO_SANDBOX-unset}"
	printf 'sandboxhelper:%s\n' "${CHROME_DEVEL_SANDBOX-unset}"
	printf 'owner:%s\n' "$(cat -- "${dir%/*}/owner" 2>/dev/null || echo none)"
	printf 'wrapperstart:%s\n' "$(starttime "$PPID")"
	printf 'mode:%s\n' "$(stat -c %a -- "$dir" 2>/dev/null || true)"
	printf 'launchmode:%s\n' "$(stat -c %a -- "${dir%/*}" 2>/dev/null || true)"
	printf 'tmpmode:%s\n' "$(stat -c %a -- "${TMPDIR-/nonexistent}" 2>/dev/null || true)"
	printf 'tmpentries:%s\n' "$(count_entries "${TMPDIR-/nonexistent}")"
	if [[ -f $dir/Default/Preferences ]]; then
		printf 'prefs:%s\n' "$(cat -- "$dir/Default/Preferences")"
	fi
} >>"$log"

# What the server's tools do: leave a file in os.tmpdir(), which nothing cleans.
if [[ -d ${TMPDIR-/nonexistent} ]]; then
	mkdir -p -- "$TMPDIR/chrome-devtools-mcp-stub"
	echo screenshot >"$TMPDIR/chrome-devtools-mcp-stub/screenshot.png"
fi

case ${STUB_MODE:-} in
crash)
	kill -KILL $$
	;;
echo)
	while IFS= read -r line; do printf 'got %s\n' "$line"; done
	;;
wait)
	trap 'echo TERM >>"$log"; exit 143' TERM
	echo ready >>"$log"
	for _ in $(seq 200); do sleep 0.05; done
	exit 99
	;;
parentstop)
	trap 'echo TERM >>"$log"; exit 143' TERM
	kill -TERM "$PPID"
	echo ready >>"$log"
	for _ in $(seq 100); do sleep 0.05; done
	exit 99
	;;
esac
exit "${STUB_RC:-0}"
