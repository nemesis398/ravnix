#!/usr/bin/env bash
# prune-claude-tmp.sh: SessionStart hook (claude/README.md). Deletes the parts
# of Claude Code's temporary directory, /tmp/claude-<uid>, that belong to
# Claude sessions which are no longer running.
#
# Why: where /tmp is RAM with a per-user quota, a full share makes every Bash
# call in every session fail with a bare exit 1, and clipboard tools that
# stage through /tmp stop working without a word. One dead session's
# scratchpad has held 6.8 GiB. Sessions that run clean up after themselves;
# this covers the ones that ended without doing so.
#
# An entry is deleted only when all of these hold:
#   - it is not the starting session's own folder (session_id on stdin),
#   - no process has a file open in it, or its working directory inside it,
#   - nothing is mounted anywhere inside it: a session that died with a
#     mount in its scratchpad would otherwise be pruned through the mount,
#     and with a network share that deletes what the share holds,
#   - nothing in it was modified in the last PRUNE_TMP_MAX_AGE_MIN minutes
#     (default 1440, 24 hours), and find could look at all of it.
# Entries are the session folders under each project folder, the per-session
# folders under bash-edit-diff, and any other top-level entry. Project folders
# themselves are never removed. A symlink goes as a link.
#
# The root is /tmp/claude-<uid> and nothing else. It must be a directory,
# not a symlink and not reached through one, owned by that uid and of mode
# 700, as Claude Code makes it; anything else is refused with a
# systemMessage. PRUNE_TMP_ROOT may name the root, written with runs of
# slashes or a trailing slash, and any other value is refused too: a wrong
# root would be pruned as if it held Claude's folders, and the busy check
# does not see what a socket or a foreign process keeps alive there.
#
# Whenever it cannot be sure, it prunes nothing: without jq, because it could
# not tell its own session; without /proc, because it could see neither the
# busy folders nor the mounts; with a PRUNE_TMP_MAX_AGE_MIN that is not a
# whole number of minutes from 1 up; without a log it can write. rm keeps to
# one file system as well. That stops it at a mount of another file system
# that appears while it runs, but not at a bind mount of the same one, so
# the reading of the mounts below is the defence that counts.
#
# Deletions are logged to ${XDG_STATE_HOME:-~/.local/state}/claude-prune-tmp.log,
# never to /tmp, one line each with the name shell-quoted. PRUNE_TMP_DRY_RUN=1
# prints what would go on stderr and deletes nothing. It always exits 0, and
# prints one JSON systemMessage when it deleted something or refused the
# root, else nothing.
# Tests: tests/prune-claude-tmp.test.sh, run with bash and no arguments.

set -u

command -v jq >/dev/null || exit 0

# refuse <why>: says in one line why nothing was pruned, and stops.
refuse() {
    jq -cn --arg m "prune-claude-tmp pruned nothing: ${1//[[:cntrl:]]/?}." '{systemMessage: $m}' 2>/dev/null
    exit 0
}

uid=$(id -u 2>/dev/null)
[[ $uid =~ ^[0-9]+$ ]] || exit 0
root=/tmp/claude-$uid
if [[ -n ${PRUNE_TMP_ROOT:-} ]]; then
    given=$PRUNE_TMP_ROOT
    while [[ $given == *//* ]]; do given=${given//\/\//\/}; done
    [[ $given == / ]] || given=${given%/}
    [[ $given == "$root" ]] || refuse "PRUNE_TMP_ROOT=$PRUNE_TMP_ROOT is not $root, the only directory it prunes"
fi
[[ -e $root || -L $root ]] || exit 0
[[ ! -L $root ]] || refuse "$root is a symbolic link"
[[ -d $root ]] || refuse "$root is not a directory"
[[ $(stat -c %u -- "$root" 2>/dev/null) == "$uid" ]] || refuse "$root is not owned by uid $uid"
mode=$(stat -c %a -- "$root" 2>/dev/null)
[[ $mode == 700 ]] || refuse "$root has mode $mode, not 700"
# /proc names open files and working directories by their physical path.
[[ $(cd -P -- "$root" 2>/dev/null && pwd) == "$root" ]] || refuse "$root is reached through a symbolic link"

max_age_min=${PRUNE_TMP_MAX_AGE_MIN:-1440}
[[ $max_age_min =~ ^[1-9][0-9]{0,8}$ ]] || exit 0
dry_run=${PRUNE_TMP_DRY_RUN:-0}

if [[ -n ${XDG_STATE_HOME:-} ]]; then
    state=$XDG_STATE_HOME
elif [[ -n ${HOME:-} ]]; then
    state=$HOME/.local/state
else
    exit 0
fi
log=$state/claude-prune-tmp.log
if [[ $dry_run != 1 ]]; then
    { mkdir -p -- "$state" && : >>"$log"; } 2>/dev/null || exit 0
fi

# The first JSON value on stdin names the session; anything else names none.
self=$(jq -rn '(try input catch null) | .session_id? | strings' 2>/dev/null) || self=""

# Mark every first- and second-level entry under $root that a process holds
# open or sits in, or that has a mount inside it. Only this user's processes
# are readable, which is enough: nobody else can own files in the root, which
# is the user's and 0700. The names end in NUL, so a newline in one cannot
# split it. The root holds no glob character, being /tmp/claude-<digits>.
declare -A busy=()
mark() {
    local rel=${1#"$root"/} first rest
    first=${rel%%/*}
    busy[$first]=1
    if [[ $rel == */* ]]; then
        rest=${rel#*/}
        busy[$first/${rest%%/*}]=1
    fi
}
[[ -r /proc/self/mountinfo ]] || exit 0
while IFS= read -r -d '' target; do
    [[ $target == "$root"/* ]] && mark "$target"
done < <(find /proc/[0-9]*/fd /proc/[0-9]*/cwd -maxdepth 1 -lname "$root/*" -printf '%l\0' 2>/dev/null)
# The fifth field of mountinfo is the mount point, with a space, a tab, a
# newline and a backslash written as octal escapes.
while read -r _ _ _ _ point _; do
    point=${point//\\040/ }
    point=${point//\\011/$'\t'}
    point=${point//\\012/$'\n'}
    point=${point//\\134/\\}
    [[ $point == "$root"/* ]] && mark "$point"
done </proc/self/mountinfo

count=0
freed_kib=0

prune() {
    local rel=$1 path="$root/$1" size recent
    [[ -n ${busy[$rel]:-} ]] && return
    [[ -n $self && ${rel##*/} == "$self" ]] && return
    # A find that fails saw only part of the entry, so its age is unknown.
    recent=$(find "$path" -mmin "-$max_age_min" -print -quit 2>/dev/null) || return
    [[ -n $recent ]] && return
    # The leading digits only: du prints the name after them, and a name may
    # hold a newline.
    size=$(du -sk -- "$path" 2>/dev/null)
    size=${size%%[!0-9]*}
    size=${size:-0}
    if [[ $dry_run == 1 ]]; then
        printf 'would delete %s (%s KiB)\n' "$rel" "$size" >&2
        return
    fi
    if rm -rf --one-file-system -- "$path" 2>/dev/null; then
        count=$((count + 1))
        freed_kib=$((freed_kib + size))
        printf '%s %q %s KiB\n' "$(date -Is)" "$rel" "$size" >>"$log" 2>/dev/null
    fi
}

shopt -s nullglob dotglob
for top in "$root"/*; do
    name=${top##*/}
    if [[ -d $top && ! -L $top && ( $name == -* || $name == bash-edit-diff ) ]]; then
        for sub in "$top"/*; do
            prune "$name/${sub##*/}"
        done
    else
        prune "$name"
    fi
done

if ((count > 0)); then
    jq -cn --arg m "Pruned $count dead Claude temp folder(s) from $root, $((freed_kib / 1024)) MiB. List: $log" \
        '{systemMessage: $m}' 2>/dev/null
fi
exit 0
