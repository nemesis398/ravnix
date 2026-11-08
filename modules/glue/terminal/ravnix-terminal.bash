#!/usr/bin/env bash
# ravnix-terminal: what the main key runs in its ghostty, herdr's own remote
# attach to the server (modules/glue/terminal.nix). herdr --remote ends with 0
# on a detach, which closes the window, and with another status when the
# connection drops: then it attaches again.

# Filled in when the command is built (./scripts.nix), a shell word each:
# the herdr and the sleep to run, and the server's ssh alias.
herdr=@herdr@
sleep=@sleep@
alias=@alias@

while :; do
	started=$SECONDS
	status=0
	"$herdr" --remote "$alias" || status=$?
	if [ "$status" = 0 ]; then
		exit 0
	fi
	printf 'ravnix-terminal: herdr ended with %s; attaching to the server again\n' "$status" >&2
	if ((SECONDS - started < 5)); then
		"$sleep" 1
	fi
done
