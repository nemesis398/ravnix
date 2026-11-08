#!/usr/bin/env bash
# ravnix-connection: the main connection, which the user unit of that name
# runs (modules/glue/terminal.nix). It asks the server for the account's uid
# and then forwards each of the glue's sockets from the laptop's runtime
# directory to the server's.

# Filled in when the command is built (./scripts.nix), a shell word each:
# the ssh to run, the server's ssh alias, and the sockets, by name.
ssh=@ssh@
alias=@alias@
sockets=(@sockets@)

# Each connection is its own, never a multiplexed one: a master that another
# program started could be gone or stale.
own=(-o ControlMaster=no -o ControlPath=none)
uid=$("$ssh" "${own[@]}" "$alias" id -u)
if ! [[ $uid =~ ^[0-9]+$ ]]; then
	printf 'ravnix-connection: the server gave no uid: %s\n' "$uid" >&2
	exit 1
fi
forwards=()
for name in "${sockets[@]}"; do
	forwards+=(-R "/run/user/$uid/$name:$XDG_RUNTIME_DIR/$name")
done
exec "$ssh" -N "${own[@]}" -o ExitOnForwardFailure=yes "${forwards[@]}" "$alias"
