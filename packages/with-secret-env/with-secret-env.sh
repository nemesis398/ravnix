#!/usr/bin/env bash
# with-secret-env: run a command with the secrets of ravnix.shell.secretEnv in
# its environment and in nobody else's.
#
#   with-secret-env [--table FILE] [--report] [--] COMMAND [ARGS...]
#
# The table is a file of NAME=item lines, which the ravnix module writes from
# ravnix.shell.secretEnv (the item is the name or id of a Bitwarden item, never
# a value). It is --table, else $RAVNIX_SECRET_ENV, else
# ${XDG_CONFIG_HOME:-~/.config}/ravnix/secret-env. Lines that are not
# NAME=item (comments, blank lines, a lowercase name) are not part of it.
#
# Each item is read with `rbw get`, one child process each. The values stay in
# shell variables until the last read is done, and only then are they exported
# at once and the command is started with `exec`. That order matters: an `rbw
# get` is a child, and one started after an export would carry the values read
# before it. A value is passed by `export`, a builtin, so it is on no command
# line and `ps` does not show it; it is never written to a file or printed;
# what rbw writes to stderr is thrown away, so a failing rbw cannot spill one;
# and this script does not trace, whatever bash -x, SHELLOPTS or PS4 say.
#
# It is all or nothing. If one item cannot be read, none of the secrets is
# exported: the command starts without them and the note names the item. An
# item whose value is empty is not a secret; it is named and left unset, and
# the others are set. A vault that is locked, an rbw that is not installed and
# a table that is not there are not errors either: the command starts without
# the secrets and the note says why. It never asks for a password, so a
# launcher in a script does not stop at a prompt; `ai-unlock` unlocks the
# vault first.
#
# --report puts two variables into the command's environment, names only:
# WITH_SECRET_ENV_LOADED, the names that were set, or WITH_SECRET_ENV_WHY, why
# none was. claude-bg uses them to compare the tokens with a running service.
#
# This is the one place that loads the table for a launcher (claude-artifacts,
# claude-bg). The `claude` function of the interactive shell
# (modules/common/bash/secrets.bash) is the other reader of the same table's
# source and keeps its own loop; it differs in one respect, noted in the
# README: it sets the secrets that could be read and names the others.

# Nothing below may be traced: the values are in variables here.
set +x +T
set -uo pipefail

usage() {
    printf 'usage: with-secret-env [--table FILE] [--report] [--] COMMAND [ARGS...]\n'
}

table=${RAVNIX_SECRET_ENV:-} report=""
while (($#)); do
    case $1 in
        --table)
            (($# >= 2)) || { usage >&2; exit 2; }
            table=$2
            shift 2 ;;
        --report) report=1; shift ;;
        --) shift; break ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
done
(($#)) || { usage >&2; exit 2; }
[[ -n $table ]] || table=${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/secret-env

say() { printf 'with-secret-env: %s\n' "$1" >&2; }

names=() pairs=() failed=() why="" quiet=""
if ! type -P rbw >/dev/null; then
    why="rbw is not installed"
elif [[ ! -r $table ]]; then
    why="there is no $table"
elif ! rbw unlocked >/dev/null 2>&1 </dev/null; then
    why="the vault is locked, so the command starts without its secrets; run ai-unlock first"
else
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.+)$ ]] || continue
        name=${BASH_REMATCH[1]} item=${BASH_REMATCH[2]}
        if value=$(rbw get -- "$item" 2>/dev/null </dev/null); then
            if [[ -n $value ]]; then
                pairs+=("$name=$value")
                names+=("$name")
            else
                say "$name: the item is empty, so it is not set"
            fi
        else
            failed+=("$name")
            say "$name: rbw cannot read the item \"$item\""
        fi
    done <"$table"
    unset line name item value
    if ((${#failed[@]})); then
        why="rbw could not read ${failed[*]}, so none of the secrets is set"
        pairs=() names=()
    elif ((${#names[@]} == 0)); then
        # An empty table is a choice (no secretEnv); only an empty item was
        # named above.
        why="the secret table names no secrets"
        quiet=1
    fi
fi

if [[ -n $why ]]; then
    [[ -n $quiet ]] || say "$why"
    [[ -z $report ]] || export WITH_SECRET_ENV_WHY="$why"
else
    # Only now, when no child is left to start; never a bare `export`, which
    # would list the whole environment.
    export "${pairs[@]}"
    [[ -z $report ]] || export WITH_SECRET_ENV_LOADED="${names[*]}"
fi
unset pairs names failed
exec "$@"
