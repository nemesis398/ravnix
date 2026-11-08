#!/usr/bin/env bash
# The stand-in for chrome-devtools-mcp in wrapper.test.sh. It writes what the
# wrapper handed it to $STUB_LOG, as it was while the server ran (the profile
# exists only then), and then does what $STUB_MODE says:
#
#   (unset)  exit with $STUB_RC (default 0)
#   echo     answer every line of stdin with "got LINE"
#   wait     say "ready" in the log, and wait for TERM; on TERM write "TERM"
#            to the log and exit 143

log=${STUB_LOG:?the test sets STUB_LOG}

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
	printf 'mode:%s\n' "$(stat -c %a -- "$dir" 2>/dev/null || true)"
	if [[ -f $dir/Default/Preferences ]]; then
		printf 'prefs:%s\n' "$(cat -- "$dir/Default/Preferences")"
	fi
} >>"$log"

case ${STUB_MODE:-} in
echo)
	while IFS= read -r line; do printf 'got %s\n' "$line"; done
	;;
wait)
	trap 'echo TERM >>"$log"; exit 143' TERM
	echo ready >>"$log"
	while :; do sleep 0.05; done
	;;
esac
exit "${STUB_RC:-0}"
