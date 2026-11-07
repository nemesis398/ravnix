#!/usr/bin/env bash
# worktree-remove.sh: WorktreeRemove hook (claude/README.md). Removes a worktree
# that worktree-create.sh made, and its branch when that is safe.
#
# Why: with a WorktreeCreate hook registered, Claude Code leaves removal to
# this hook too. It fires on ExitWorktree "remove", on a clean interactive
# exit and when the user picks "Remove" in the exit dialog, never at the end
# of `claude -p -w`. Claude has already decided by then (ExitWorktree has its
# own discard confirmation, and the dialog is the user's choice), so the
# worktree goes with --force, uncommitted work and all.
#
# The branch is different: Claude never deletes it, and neither does the
# built-in for a hook-made worktree. This hook deletes it only when it is
# named worktree-* and its tip has no commit that no other ref reaches (a
# local branch, a tag, a remote-tracking branch), and then with
# `git branch -D`. Not with `git branch -d`: that compares against the main
# checkout's HEAD, so a commit-free worktree based on an origin/main that is
# ahead of the local main would keep its branch forever. A branch with unique
# commits is kept and named on stderr; the worktree is still gone and the
# exit is 0.
#
# Before the removal it runs the repository's own teardown,
# <worktree>/.claude/worktree-teardown, the inverse of the .claude/worktree-setup
# that worktree-create.sh ran, which may drop the worktree's database.
# It has to run first because the script lives in the worktree. A teardown that
# fails or runs out of time only warns, on stderr and in the log, and the
# worktree goes anyway: whatever the setup made outside the worktree may then
# stay behind, which is no worse than having no teardown at all, and a worktree
# that a broken teardown keeps from being removed would be worse. A worktree
# that is already gone gets no teardown, since its script went with it.
#
# Exit 0 means removed, and a path that is already gone counts as removed
# (its registration is pruned). Non-zero makes Claude keep the worktree with
# a warning. Claude runs this with its cwd inside the worktree, so the first
# thing it does is leave.
#
# One line per run goes to ${XDG_STATE_HOME:-~/.local/state}/claude-worktree-hooks.log:
#   <time> remove <name> <path> <removed|gone|failed> <seconds>s [note]

set -uo pipefail

exec 1>&2
cd / || exit 1

log_file="${XDG_STATE_HOME:-$HOME/.local/state}/claude-worktree-hooks.log"
wt="" td_note=""

log() {
    mkdir -p -- "${log_file%/*}" 2>/dev/null
    printf '%s remove %s %s %s %ss%s\n' "$(date -Is)" "${wt:+${wt##*/}}" "${wt:--}" \
        "$1" "$SECONDS" "${2:+ $2}" >>"$log_file" 2>/dev/null
}

fail() {
    log failed "$1"
    printf 'worktree-remove: %s\n' "$1" >&2
    exit 1
}

# How long a teardown may run: CLAUDE_WORKTREE_TEARDOWN_TIMEOUT whole seconds,
# default 30, then SIGTERM to its process group and SIGKILL 5 s later. This
# hook is registered with a 60 s timeout, and a hook Claude kills keeps its
# worktree, so the teardown gets at most 35 s and `git worktree remove` of a
# tree with a node_modules keeps 25. A teardown that starts node and runs one
# DROP DATABASE takes about a second; with a connect and a close that each
# give up after 5 s, only a DROP that hangs on a live server needs this limit.
teardown_limit=${CLAUDE_WORKTREE_TEARDOWN_TIMEOUT:-30}
[[ $teardown_limit =~ ^[1-9][0-9]*$ ]] || teardown_limit=30

# teardown: run <wt>/.claude/worktree-teardown under the same conditions as
# worktree-create.sh runs the setup: an executable file, in the worktree, with
# stdin closed, its stdout on stderr, and WORKTREE_MAIN, WORKTREE_PATH and
# WORKTREE_NAME set. The name is the directory name with each + turned back
# into /, which undoes how worktree-create.sh flattened it (its names cannot
# contain +). Sets td_note for the log; it never fails the caller.
# worktree-subagent-stop.sh carries the same function.
teardown() {
    local td="$wt/.claude/worktree-teardown" name=${wt##*/} rc why
    td_note=""
    [[ -e $td ]] || return 0
    if [[ ! -f $td || ! -x $td ]]; then
        printf 'worktree-remove: %s is not an executable file, not running it\n' "$td" >&2
        return 0
    fi
    (cd -- "$wt" && exec timeout -k 5 "$teardown_limit" env WORKTREE_MAIN="$main" \
        WORKTREE_PATH="$wt" WORKTREE_NAME="${name//+//}" "$td") </dev/null
    rc=$?
    if ((rc == 0)); then
        td_note="teardown ran"
        return 0
    fi
    # timeout exits 124 after SIGTERM, 137 when it had to send SIGKILL.
    if ((rc == 124 || rc == 137)); then
        why="timed out after $teardown_limit s"
    else
        why="failed with exit $rc"
    fi
    td_note="teardown $why; what it cleans up outside the worktree may be left behind"
    printf 'worktree-remove: .claude/worktree-teardown %s; removing the worktree anyway, and what it cleans up outside the worktree may be left behind\n' "$why" >&2
}

wt=$(jq -r '.worktree_path // empty' 2>/dev/null) || fail "stdin is not the WorktreeRemove JSON"
[[ $wt == /* ]] || fail "worktree_path is not an absolute path: ${wt:-(none)}"

if [[ ! -e $wt && ! -L $wt ]]; then
    # Gone already. The main checkout is whatever holds .claude/worktrees.
    main=${wt%/.claude/worktrees/*}
    if [[ $main != "$wt" && -d $main ]]; then
        git -C "$main" worktree prune
    fi
    log gone
    exit 0
fi

common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    fail "not inside a git repository: $wt"
main=${common%/*}
top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || fail "not a git work tree: $wt"
[[ $top != "$main" ]] || fail "refusing to remove the main checkout $main"

branch=$(git -C "$wt" symbolic-ref -q --short HEAD) || branch=""

teardown

git -C "$main" worktree remove --force -- "$wt" || fail "git worktree remove failed for $wt${td_note:+ ($td_note)}"

note=""
if [[ $branch == worktree-* ]]; then
    # Commits of the branch that no other ref reaches.
    if ! unique=$(git -C "$main" for-each-ref --format='^%(objectname)' --exclude="refs/heads/$branch" |
        git -C "$main" rev-list --stdin -n 1 "refs/heads/$branch"); then
        note="branch $branch kept: cannot tell whether it has unique commits"
        printf 'worktree-remove: kept %s; cannot tell whether it has unique commits\n' "$branch" >&2
    elif [[ -n $unique ]]; then
        note="branch $branch kept: it has commits no other ref reaches"
        printf 'worktree-remove: kept %s; it has commits no other ref reaches\n' "$branch" >&2
    elif git -C "$main" branch -D -- "$branch"; then
        note="branch $branch deleted"
    else
        note="branch $branch kept: git branch -D failed"
    fi
fi
log removed "$td_note${td_note:+${note:+; }}$note"
exit 0
