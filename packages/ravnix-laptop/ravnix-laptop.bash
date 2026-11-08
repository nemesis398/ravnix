#!/usr/bin/env bash
# ravnix-laptop: run a command on huginn, the laptop, from muninn, the server,
# over the NetBird mesh, and return what it printed and how it ended.
#
#   ravnix-laptop [--] COMMAND [ARGUMENT...]
#
# Thin glue over ssh. Everything that decides how ssh behaves is set here, on
# the command line, and none of it comes from the user's ssh configuration
# (-F /dev/null), so the key is the command's own and no agent is asked.
#
# Exit status: the command's own; 64 for a wrong call; 70 when this machine
# cannot even start ssh (no temporary file: EX_SOFTWARE, so that a failure
# here is never taken for the remote command's own exit 1); 75 when the laptop
# cannot be reached (asleep, off, away from the network, or sshd not running:
# "huginn is offline or asleep", sysexits' EX_TEMPFAIL, try again later); 78
# when it is not configured; and 255 when ssh failed for another reason, which
# it says (a refused key, a host key that is not the laptop's). A command that
# itself exits 255 is passed on as 255 without a word, which is told from an
# ssh that failed by the messages ssh wrote, kept apart from the command's own
# output in a file of their own (ssh -E). A session that the laptop closes in
# the middle of a command ends the same way: ssh says "Connection to ... closed
# by remote host." on its own standard error, not in that file, so the
# command's stderr holds the line and the exit status is 255 without a word.

# The values ravnix.laptopAccess and ravnix.hosts.huginn hold, written in
# when the package is built (a shell word each; empty without ravnix):
# huginn's NetBird address, the account on both hosts, the private key, the
# file with the laptop's host key (empty: trust the first one), and the ssh.
baked_address=@address@
baked_user=@user@
baked_identity=@identityFile@
baked_known_hosts=@knownHosts@
ssh=@sshCommand@

usage() {
	cat <<'EOF'
usage: ravnix-laptop [--] COMMAND [ARGUMENT...]

Runs COMMAND on the laptop (huginn) over NetBird and prints what it prints.
Each word is passed on as one word: spaces, quotes, ; and $ in an argument
stay what they are. The exit status is the command's. Standard input goes to
the command.

Exit status 75 means the laptop is offline or asleep. Other statuses:
64 wrong call, 70 no temporary file here, 78 not configured, 255 ssh failed
(it says why).
EOF
}

case "${1-}" in
-h | --help)
	usage
	exit 0
	;;
--) shift ;;
-*)
	echo "ravnix-laptop: unknown option $1" >&2
	usage >&2
	exit 64
	;;
esac
if (($# == 0)); then
	usage >&2
	exit 64
fi

if [[ -z $baked_address || -z $baked_user || -z $baked_identity ]]; then
	echo "ravnix-laptop: not configured: set ravnix.laptopAccess.identityFile and ravnix.hosts.huginn in your private flake" >&2
	exit 78
fi
if [[ ! -r $baked_identity ]]; then
	echo "ravnix-laptop: cannot read the identity file $baked_identity; make it with ssh-keygen -t ed25519 -N '' -f $baked_identity" >&2
	exit 78
fi

# The laptop's host key: the pinned one, or the first one it shows,
# remembered in a file of this command's own, never in the user's known_hosts.
if [[ -n $baked_known_hosts ]]; then
	host_key_options=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$baked_known_hosts")
else
	state=${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}
	if [[ -z $state ]]; then
		echo "ravnix-laptop: neither XDG_STATE_HOME nor HOME is set, so there is nowhere to remember the laptop's host key" >&2
		exit 78
	fi
	if ! mkdir -p -- "$state/ravnix-laptop"; then
		echo "ravnix-laptop: cannot create $state/ravnix-laptop to remember the laptop's host key in" >&2
		exit 78
	fi
	host_key_options=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$state/ravnix-laptop/known_hosts")
fi

# One word for the remote shell, which reads it as bash does: every word of
# the call quoted, so that nothing in an argument is more than an argument.
# Linux takes at most 128 KiB for one word of an exec, here and on the laptop
# (the remote shell is started with this as one).
remote=$(printf '%q ' "$@")
remote=${remote% }
if (($(printf '%s' "$remote" | wc -c) > 120000)); then
	echo "ravnix-laptop: the command line is too long: the laptop's shell takes at most 120000 bytes of it" >&2
	exit 64
fi

# ssh's own messages go to a file, so that they are told from the command's
# stderr. The file is unlinked at once and read through its descriptor, so
# that nothing is left behind however the command ends.
# A failure to make it is this machine's, and must not look like the remote
# command's own exit 1.
if ! log_file=$(mktemp -- "${TMPDIR:-/tmp}/ravnix-laptop.XXXXXX"); then
	echo "ravnix-laptop: cannot make a temporary file in ${TMPDIR:-/tmp} for ssh's messages" >&2
	exit 70
fi
if ! exec 9<>"$log_file"; then
	rm -f -- "$log_file"
	echo "ravnix-laptop: cannot open the temporary file $log_file" >&2
	exit 70
fi
rm -f -- "$log_file"

# ConnectTimeout bounds a laptop that does not answer, ServerAliveInterval and
# ServerAliveCountMax one that stops answering in the middle of a command: four
# seconds of silence. No attempt is repeated, and nothing is asked.
rc=0
"$ssh" -F /dev/null -E "/proc/$$/fd/9" \
	-o BatchMode=yes \
	-o ConnectTimeout=3 -o ConnectionAttempts=1 \
	-o ServerAliveInterval=2 -o ServerAliveCountMax=1 \
	-o IdentitiesOnly=yes -o IdentityAgent=none \
	-o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
	-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
	-o ControlMaster=no -o ControlPath=none \
	-o HostKeyAlias=huginn -o GlobalKnownHostsFile=/dev/null "${host_key_options[@]}" \
	-i "$baked_identity" -l "$baked_user" \
	-- "$baked_address" "$remote" || rc=$?

if ((rc != 255)); then
	exit "$rc"
fi

# 255 is ssh's own failure, and the exit status of a command that ended that
# way too. ssh's messages say which; there are none from a command.
problems=""
while IFS= read -r line; do
	# ssh ends the lines of its messages with CR LF.
	line=${line%$'\r'}
	if [[ -n $line && $line != "Warning: Permanently added "* ]]; then
		problems+="$line"$'\n'
	fi
done < <(cat <&9)
if [[ -z $problems ]]; then
	exit 255
fi

# The laptop answered and refused: not asleep, and no use trying again.
refused='Permission denied|Host key verification failed|IDENTIFICATION HAS CHANGED|Load key|no such identity|bad permissions|Too many authentication failures|No more authentication methods'
# The laptop did not answer, or stopped.
unreachable='timed out|Connection (refused|reset|closed)|No route to host|Network is unreachable|Host is down|Timeout, server .* not responding|Broken pipe'
if [[ ! $problems =~ $refused && $problems =~ $unreachable ]]; then
	echo "ravnix-laptop: huginn is offline or asleep" >&2
	exit 75
fi
echo "ravnix-laptop: ssh to huginn failed:" >&2
printf '%s' "$problems" >&2
exit 255
