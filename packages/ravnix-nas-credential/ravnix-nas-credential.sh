#!/usr/bin/env bash
# ravnix-nas-credential LOGIN FILE USERNAME ITEM [ITEM_USER]
#
# Writes FILE, the credentials file of an SMB account, from the vault of
# LOGIN: `username=USERNAME` and the password of the Bitwarden item ITEM
# (rbw get ITEM [ITEM_USER]). Run as root, by the unit that each NAS mount
# requires (modules/desktop/nas.nix), every time an automount mounts a share.
#
# rbw runs as LOGIN, never as root: setpriv drops to LOGIN's uid, gid and
# groups, with no new privileges and the environment reset to LOGIN's, and
# rbw talks to LOGIN's agent in /run/user/UID. RBW_AGENT names a program that
# fails, so a missing agent is not started inside a system unit, and rbw's
# standard input is /dev/null, so it never prompts. The password goes from
# rbw to this script through a pipe, of which it reads no more than the
# 512-byte limit needs, and from here into the file with printf, a builtin:
# it is on no command line, in no environment and in no output.
#
# Each of the two rbw calls (unlocked, get) has @rbwTimeout@ seconds; the
# unit's start timeout leaves room for both and for the fallback after them.
# timeout runs after the drop, as LOGIN, so it signals rbw as its own user
# and root needs no capability to signal another (the unit holds none).
#
# The file is written whole or not at all: a new one beside it, mode 600,
# then renamed over it. A run that is stopped (SIGTERM, SIGINT, SIGHUP)
# removes its new file; one that a SIGKILL left is removed by a later run
# once it is five minutes old, so that a run never takes another's. When the
# password cannot be read now (the vault is locked or not there, the item is
# missing, empty, of more than one line or longer than mount.cifs takes, rbw
# is too slow), the file of an earlier run is kept and the run exits 0,
# saying so; with no earlier file it exits 1, and the mount fails until a
# later one reads it.
set -uo pipefail
export LC_ALL=C

say() { printf 'ravnix-nas-credential: %s\n' "$*" >&2; }

if (($# < 4 || $# > 5)); then
	say "usage: ravnix-nas-credential LOGIN FILE USERNAME ITEM [ITEM_USER]"
	exit 2
fi
login=$1 file=$2 username=$3 item=$4 item_user=${5-}
if [[ $file != /* || $file == */ ]]; then
	say "usage: FILE must be an absolute path to a file, not $file"
	exit 2
fi
if [[ -z $username || $username == *[$'\n\r']* ]]; then
	say "usage: USERNAME must be one line"
	exit 2
fi

# A new file not yet renamed over FILE, removed however the run ends but by
# SIGKILL: bash runs the EXIT trap when a signal such as SIGTERM ends it too.
tmp=''
trap '[[ -z $tmp ]] || rm -f -- "$tmp"' EXIT

# No password now: keep the earlier file if there is one.
fallback() {
	if [[ -s $file ]]; then
		say "$1; the mounts keep the password read before, in $file"
		exit 0
	fi
	say "$1; $file is not there, so its shares cannot be mounted until it is read"
	exit 1
}

if ! uid=$(id -u -- "$login" 2>/dev/null) || ! gid=$(id -g -- "$login" 2>/dev/null); then
	fallback "there is no user $login"
fi
rbw=$(type -P rbw) env=$(type -P env) false=$(type -P false) timeout=$(type -P timeout)

# rbw ARGS as the login, within the limit, which the login's timeout keeps.
as_login() {
	setpriv --reuid="$uid" --regid="$gid" --init-groups --no-new-privs --reset-env -- \
		"$timeout" @rbwTimeout@ "$env" XDG_RUNTIME_DIR="/run/user/$uid" RBW_AGENT="$false" "$rbw" "$@" \
		</dev/null 2>/dev/null
}

if ! as_login unlocked >/dev/null; then
	fallback "the vault of $login is locked or not running (ai-unlock unlocks it)"
fi
args=(get -- "$item")
[[ -z $item_user ]] || args+=("$item_user")
# 1100 bytes is past any password that passes below; head stops reading
# there, and rbw's next write fails (rbw, in Rust, ignores SIGPIPE and exits
# with an error on EPIPE). So a failed rbw whose output reached the cut was
# cut off by this script, and the password is too long; any other failure
# of rbw is one, however much it printed.
password=$(as_login "${args[@]}" | head -c 1100)
read_status=$?
if ((read_status != 0 && ${#password} < 1100)); then
	fallback "rbw cannot read the item \"$item\" of $login"
fi
# mount.cifs doubles each comma and takes 512 bytes.
commas=${password//[^,]/}
if ((${#password} + ${#commas} > 512)); then
	fallback "the password of \"$item\" is longer than the 512 bytes mount.cifs takes (a comma counts twice)"
fi
if [[ -z $password ]]; then
	fallback "the item \"$item\" has an empty password"
fi
if [[ $password == *$'\n'* ]]; then
	fallback "the password of \"$item\" has more than one line, which a credentials file cannot hold"
fi

umask 077
if ! mkdir -p -- "${file%/*}"; then
	fallback "cannot make the directory of $file"
fi
find "${file%/*}" -maxdepth 1 -type f -name "${file##*/}.??????" -mmin +5 -delete 2>/dev/null
if ! tmp=$(mktemp -- "$file.XXXXXX"); then
	tmp=''
	fallback "cannot write beside $file"
fi
if ! printf 'username=%s\npassword=%s\n' "$username" "$password" >"$tmp" || ! mv -f -- "$tmp" "$file"; then
	fallback "cannot write $file"
fi
tmp=''
say "wrote $file for $username from \"$item\""
