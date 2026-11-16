#!/usr/bin/env bash
# atuin-root-login: log root in to the atuin account the user is logged in to,
# so root's shell history goes into the same shared timeline.
#
#   atuin-root-login ITEM
#
# ITEM is the name or id of the Bitwarden item that holds the account: its
# username, its password, and the recovery key (the bip39 words of `atuin
# key`) alone in its notes. Run it as the user, in a terminal, with the vault
# unlocked (ai-unlock); sudo asks for the user's password or key as it does
# for any command.
#
# root cannot use the user's rbw, so the user reads the three values and hands
# them to the root half of this script through sudo. The secrets travel in
# exactly two places, a pipe and shell variables:
#
#   - not on a command line: sudo's and atuin's arguments hold the program, the
#     flags and `-p -`, which makes atuin read the password from its standard
#     input; the item's name is the only thing the user types;
#   - not in a file: nothing is written but atuin's own key file under
#     /root/.local/share, which is atuin's login;
#   - not in the environment of any process but atuin: the recovery key reaches
#     atuin as ATUIN_ENCRYPTION_KEY, set for that one command;
#   - not in a trace or an error message: tracing is turned off, whatever bash
#     -x, SHELLOPTS or PS4 say, and what rbw writes to stderr is thrown away.
#
# The root half is this script again with --as-root, which sudo starts by its
# store path; it refuses to run unless it is root. Its standard input is the
# username, the recovery key and then the password, a line each; atuin takes
# the rest of the input as the password.

# Nothing below may be traced: the values are in variables here.
set +x +T
set -uo pipefail

usage() {
    printf 'usage: atuin-root-login ITEM\n'
}

say() { printf 'atuin-root-login: %s\n' "$1" >&2; }

if [[ ${1:-} == --as-root ]]; then
    (($# == 1)) || { usage >&2; exit 2; }
    if [[ $(id -u) != 0 ]]; then
        say "--as-root is for sudo to start; run atuin-root-login ITEM as yourself"
        exit 1
    fi
    IFS= read -r user || { say "no username on the standard input"; exit 1; }
    IFS= read -r key || { say "no recovery key on the standard input"; exit 1; }
    # root's own atuin: its home and its config, whatever sudo kept.
    export HOME=/root
    unset XDG_CONFIG_HOME XDG_DATA_HOME ATUIN_CONFIG_DIR ATUIN_DB_PATH ATUIN_KEY_PATH ATUIN_SESSION ATUIN_PASSWORD
    umask 077
    # atuin reads the rest of the standard input as the password.
    ATUIN_ENCRYPTION_KEY=$key atuin login --username="$user" -p - || exit
    unset key
    # The first sync, so the shared history shows at once.
    atuin sync
    exit
fi

case ${1:-} in
    -h | --help) usage; exit 0 ;;
    -* | '') usage >&2; exit 2 ;;
esac
(($# == 1)) || { usage >&2; exit 2; }
item=$1

type -P rbw >/dev/null || { say "rbw is not installed"; exit 1; }
if ! rbw unlocked >/dev/null 2>&1 </dev/null; then
    say "the vault is locked; run ai-unlock first"
    exit 1
fi

# One value of the item, or an exit with the field's name and never its
# content. rbw's stderr is thrown away so that it cannot spill a value.
read_field() { # read_field VAR FIELD
    local value
    if ! value=$(rbw get --field "$2" -- "$item" 2>/dev/null </dev/null); then
        say "rbw cannot read the $2 of \"$item\""
        exit 1
    fi
    # The ends: a note ends in a newline and may start with a blank line.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ -z $value ]]; then
        say "the $2 of \"$item\" is empty"
        exit 1
    fi
    if [[ $value == *$'\n'* ]]; then
        say "the $2 of \"$item\" has more than one line; it must be one line"
        exit 1
    fi
    printf -v "$1" '%s' "$value"
}

username="" password="" key=""
read_field username username
read_field key notes
# The password is read like the others; a password cannot hold a newline here
# either, since atuin takes the input to its end and drops the last one only.
read_field password password

self=$(readlink -f -- "$0")
# printf is a builtin: nothing here starts a process that has a value in its
# arguments. sudo reads its own password from the terminal, not from the pipe.
printf '%s\n%s\n%s\n' "$username" "$key" "$password" | sudo -- "$self" --as-root
status=("${PIPESTATUS[@]}")
unset username password key
exit "${status[1]}"
