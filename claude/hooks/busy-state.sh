#!/usr/bin/env bash
# busy-state.sh: Claude Code's UserPromptSubmit, Stop, SessionStart and
# SessionEnd hook (claude/README.md). It writes, per session, whether a turn
# is running, as claude-roll's second signal beside herdr's state
# (tools/claude-roll/README.md): herdr can take a running session for idle,
# and claude-roll then holds the session back while this file says busy.
#
#   UserPromptSubmit      busy   a turn starts
#   Stop, StopFailure     idle   it ends, or ends on an error
#   SessionStart          idle   a new session (startup, /clear, a resume)
#   SessionEnd            the file is removed
#
# The file is ${XDG_STATE_HOME:-~/.local/state}/ravnix/claude-busy/<session>,
# one word and a newline, written through a temporary file and a rename. A
# session id that is no UUID is not used as a file name; the hook then does
# nothing. It prints nothing (UserPromptSubmit would put stdout into the
# conversation) and exits 0 whatever happens, so it never blocks a prompt.
#
# What it cannot see: a turn interrupted with Esc ends without Stop, so the
# file says busy until the next prompt's Stop, and claude-roll leaves that
# session on its version until then.
#
# Needs jq; without it the hook does nothing.

{
	input=$(cat)
	command -v jq >/dev/null 2>&1 || exit 0
	IFS=$'\t' read -r event session < <(jq -r '[.hook_event_name // "", .session_id // ""] | @tsv' <<<"$input" 2>/dev/null) || exit 0
	[[ $session =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || exit 0

	state=${XDG_STATE_HOME:-}
	if [[ -z $state ]]; then
		[[ -n ${HOME:-} ]] || exit 0
		state=$HOME/.local/state
	fi
	dir=$state/ravnix/claude-busy
	file=$dir/$session

	case $event in
	UserPromptSubmit) word=busy ;;
	Stop | StopFailure | SessionStart) word=idle ;;
	SessionEnd)
		rm -f -- "$file"
		exit 0
		;;
	*) exit 0 ;;
	esac

	mkdir -p -- "$dir" || exit 0
	tmp=$(mktemp -p "$dir" ".$session.XXXXXX") || exit 0
	if printf '%s\n' "$word" >"$tmp" && mv -f -- "$tmp" "$file"; then
		exit 0
	fi
	rm -f -- "$tmp"
} >/dev/null 2>&1
exit 0
