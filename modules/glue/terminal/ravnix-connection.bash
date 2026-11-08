#!/usr/bin/env bash
# ravnix-connection: the main connection, which the user unit of that name
# runs (modules/glue/terminal.nix). It asks the server for the account's uid
# and then forwards each of the glue's sockets from the laptop's runtime
# directory to the server's, for as long as the connection holds; then it
# connects again, for as long as it runs.
#
#   - After a connection that held a while and dropped, at once: that is a
#     suspend or a new network, and the forwards are back as soon as the
#     server answers.
#   - After an attempt that failed at the start, after a wait that doubles
#     from 1 s up to `cap`, so a laptop that is offline tries every few
#     seconds rather than every second. Once the network is back, the next
#     attempt is at most `cap` seconds away.
#   - What went wrong goes to the journal once, not once per attempt: each
#     message is said once until a connection holds again. ssh's own words
#     are the reason, its last line.
#
# The loop is here and not in systemd's Restart= with RestartSteps=: systemd
# counts the restarts since the unit was started and never starts that
# count over after a connection that held, so after a few drops in a day
# every drop would wait the longest time, and each restart logs lines of its
# own.

# Filled in when the command is built (./scripts.nix), a shell word each:
# the ssh and the sleep to run, the server's ssh alias, and the sockets, by
# name.
ssh=@ssh@
sleep=@sleep@
alias=@alias@
sockets=(@sockets@)

# A connection that ran this many seconds had held. More than ssh's
# ConnectTimeout (5 s), so an attempt that waited for it is none.
attached=10
# The longest wait between two attempts, in seconds.
cap=8

: "${XDG_RUNTIME_DIR:?ravnix-connection: XDG_RUNTIME_DIR is not set; the sockets are forwarded from there}"

# Each connection is its own, never a multiplexed one: a master that another
# program started could be gone or stale.
own=(-o ControlMaster=no -o ControlPath=none)

# What ssh says, kept to find its last line; removed when the command ends.
said=$(mktemp -p "$XDG_RUNTIME_DIR" ravnix-connection.XXXXXX)
trap 'rm -f -- "$said"' EXIT

# The messages said since the last connection that held.
declare -A seen=()
say() {
	if [[ -z ${seen[$1]+said} ]]; then
		seen[$1]=1
		printf 'ravnix-connection: %s\n' "$1" >&2
	fi
}

# The last line ssh said, without the CR that ends some of them, or its
# status when it said nothing.
reason() {
	local line why="ssh ended with $1"
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		if [[ -n $line ]]; then why=$line; fi
	done <"$said"
	printf '%s' "$why"
}

delay=0
while :; do
	started=$SECONDS
	status=0
	uid=$("$ssh" "${own[@]}" "$alias" id -u 2>"$said") || status=$?
	if ((status == 0)) && ! [[ $uid =~ ^[0-9]+$ ]]; then
		status=1
		# One line, quoted: the reason is the last line of what was said.
		printf 'the server gave no uid: %q\n' "$uid" >"$said"
	fi
	if ((status == 0)); then
		say "forwarding the sockets to the server (uid $uid)"
		forwards=()
		for name in "${sockets[@]}"; do
			forwards+=(-R "/run/user/$uid/$name:$XDG_RUNTIME_DIR/$name")
		done
		"$ssh" -N "${own[@]}" -o ExitOnForwardFailure=yes "${forwards[@]}" "$alias" 2>"$said" || status=$?
	fi
	why=$(reason "$status")
	if ((SECONDS - started >= attached)); then
		printf 'ravnix-connection: the connection ended after %s s: %s; connecting again\n' "$((SECONDS - started))" "$why" >&2
		seen=()
		delay=0
		continue
	fi
	say "not forwarding to the server: $why (trying again, at most $cap s apart)"
	if ((delay == 0)); then
		delay=1
	else
		delay=$((delay * 2 > cap ? cap : delay * 2))
	fi
	"$sleep" "$delay"
done
