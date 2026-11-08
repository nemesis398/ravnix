#!/usr/bin/env bash
# ravnix-terminal: what the main key runs in its ghostty, herdr's own remote
# attach to the server (modules/glue/terminal.nix). herdr --remote ends with 0
# on a detach, which closes the window, and with another status when the
# connection drops or cannot be made: then it attaches again.
#
#   - After a herdr that ran a while, which was attached and lost the
#     connection, at once: that is a suspend or a new network, and the
#     session is back as soon as the server answers.
#   - After one that ended at the start, which found no server, after a wait
#     that doubles from 1 s up to `cap`, so a laptop that is offline tries
#     every few seconds rather than every second. Once the network is back,
#     the next attempt is at most `cap` seconds away.
#   - Before each attempt after a wait, it clears the window: it then shows
#     the last attempt's error and one line of this command, not a page of
#     the same error. herdr's own error stays on the screen: it is what says
#     why (no route, a refused key, a host key that does not match).
#
# Ctrl+C during a wait ends the command, and the window with it.

# Filled in when the command is built (./scripts.nix), a shell word each:
# the herdr and the sleep to run, and the server's ssh alias.
herdr=@herdr@
sleep=@sleep@
alias=@alias@

# A herdr that ran this many seconds was attached. More than ssh's
# ConnectTimeout (5 s), so an attempt that waited for it is no session.
attached=10
# The longest wait between two attempts, in seconds.
cap=8

delay=0
while :; do
	started=$SECONDS
	status=0
	"$herdr" --remote "$alias" || status=$?
	if ((status == 0)); then
		exit 0
	fi
	if ((SECONDS - started >= attached)); then
		delay=0
		printf 'ravnix-terminal: herdr ended with %s; attaching to the server again\n' "$status" >&2
		continue
	fi
	if ((delay == 0)); then
		delay=1
	else
		delay=$((delay * 2 > cap ? cap : delay * 2))
	fi
	printf 'ravnix-terminal: herdr ended with %s at the start; trying again in %s s (Ctrl+C closes the window)\n' "$status" "$delay" >&2
	"$sleep" "$delay"
	# The next attempt's error on a clear window: \e[3J drops the
	# scrollback as well, where the earlier ones would pile up.
	printf '\033[H\033[2J\033[3J'
done
