#!/usr/bin/env bash
# worktree-subagent-stop.sh: SubagentStop hook (claude/README.md). Sweeps the
# idle agent worktrees of the stopping subagent's repository, removing each
# one, with its branch, that nothing needs any more.
#
# Why: for a subagent worktree that a WorktreeCreate hook made, Claude Code
# 2.1.281 never calls WorktreeRemove. Its cleanup needs a value that a stub
# always leaves undefined, so it logs "Hook-based agent worktree kept", and
# every isolated subagent would leave a checkout, a node_modules and a branch
# behind.
#
# Why a sweep of the others, and never the stopping agent's own worktree:
# SubagentStop fires at every turn end of a subagent, not once at its end,
# and a stopped subagent can be resumed with SendMessage. Removing its
# worktree at the stop would leave the resumed agent without its cwd. So a
# stop looks at the OTHER agent worktrees of the same main checkout, and a
# worktree becomes a candidate only after a grace period without activity.
#
# An agent worktree (<main>/.claude/worktrees/agent-*, registered with git) is
# removed only when all of these hold, and is kept otherwise:
#   - it is not the worktree the hook's cwd is in, nor agent-<agent_id>;
#   - it is not locked (`git worktree lock`);
#   - it has been idle for longer than CLAUDE_WORKTREE_AGENT_GRACE_HOURS
#     (whole hours, default 24; 0 is for tests). Idle time runs from the
#     newest mtime of HEAD, index and logs/HEAD in its git admin dir,
#     <common>/worktrees/<id>/. Those change on every checkout, commit, add,
#     reset and index refresh, and three stats cost nothing. The working tree
#     is not walked: with a node_modules that takes seconds, and a tree that
#     passes the next check holds no edit that did not go through git;
#   - `git status --porcelain` is empty, untracked files included;
#   - HEAD has no commit that no other ref reaches (a local branch, a tag, a
#     remote-tracking branch), so deleting the branch loses nothing.
# Its branch goes too, but only when it is named worktree-*. The removal is
# `git worktree remove` without --force, so a file that appeared after the
# check stops it.
#
# Once every check has passed, and just before the removal, it runs the
# worktree's .claude/worktree-teardown the way worktree-remove.sh does, with
# the same limit (CLAUDE_WORKTREE_TEARDOWN_TIMEOUT). A worktree that is kept
# is never torn down. A teardown that fails or runs out of time is logged and
# the worktree still goes; a removal that git refuses after the teardown ran
# leaves the worktree without what the teardown took away.
#
# Backstop: Claude's own startup sweep, cleanupStaleAgentWorktrees, part of
# the cleanupPeriodDays retention sweep (default 30 days), covers the same
# directory names (agent-a<hex>, and wf_, wf-, bridge-, job-, bg-) in the
# repository a session starts in. It removes one whose directory mtime is
# older than the cutoff, whose tree is clean and whose HEAD is on a remote,
# with its worktree-<name> branch, through git directly, not through a hook.
#
# It must never block or slow a subagent's end: it always exits 0 and prints
# nothing on stdout. The hook itself runs jq and one git call; the sweep runs
# detached (setsid) under a flock on <common>/worktrees, so concurrent stops
# never sweep the same repository twice, and a stop that finds the lock taken
# simply skips.
#
# Every decision about an agent worktree is logged to
# ${XDG_STATE_HOME:-~/.local/state}/claude-worktree-hooks.log:
#   <time> subagent-stop <name> <path> <removed|kept|failed> <seconds>s <reason>

set -uo pipefail

exec 1>&2

log_file="${XDG_STATE_HOME:-$HOME/.local/state}/claude-worktree-hooks.log"

log() { # log <path> <outcome> <reason>
    mkdir -p -- "${log_file%/*}" 2>/dev/null
    printf '%s subagent-stop %s %s %s %ss %s\n' "$(date -Is)" "${1##*/}" "$1" \
        "$2" "$SECONDS" "$3" >>"$log_file" 2>/dev/null
}

# The teardown's limit, as in worktree-remove.sh. The sweep is detached, so no
# hook timeout binds it, but it holds the lock on <common>/worktrees meanwhile.
teardown_limit=${CLAUDE_WORKTREE_TEARDOWN_TIMEOUT:-30}
[[ $teardown_limit =~ ^[1-9][0-9]*$ ]] || teardown_limit=30

# teardown: the same function as in worktree-remove.sh, for the record in wt.
# Its stdin is closed here for a second reason: consider runs inside the loop
# that reads `git worktree list`, and a teardown reading stdin would eat it.
teardown() {
    local td="$wt/.claude/worktree-teardown" name=${wt##*/} rc why
    td_note=""
    [[ -e $td ]] || return 0
    if [[ ! -f $td || ! -x $td ]]; then
        printf 'worktree-subagent-stop: %s is not an executable file, not running it\n' "$td" >&2
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
}

# consider: decide about one worktree record of `git worktree list`. Reads
# main, self, self_name, grace, now, and the record: wt, sha, ref, locked, prunable.
consider() {
    local admin newest m f status unique idle td_note=""
    [[ ${wt##*/} == agent-* && ${wt%/*} -ef $main/.claude/worktrees ]] || return 0
    ((prunable)) && return 0
    [[ -d $wt ]] || return 0
    if [[ ( -n $self && $wt -ef $self ) || ${wt##*/} == "$self_name" ]]; then
        log "$wt" kept "it is the stopping agent's own worktree"
        return 0
    fi
    if ((locked)); then
        log "$wt" kept "it is locked"
        return 0
    fi
    if ! admin=$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null); then
        log "$wt" kept "cannot find its git admin dir"
        return 0
    fi
    newest=0
    for f in HEAD index logs/HEAD; do
        m=$(stat -c %Y -- "$admin/$f" 2>/dev/null) || continue
        ((m > newest)) && newest=$m
    done
    if ((now - newest < grace * 3600)); then
        log "$wt" kept "active $(((now - newest) / 60)) min ago, within the ${grace} h grace"
        return 0
    fi
    if ! status=$(git -C "$wt" --no-optional-locks status --porcelain --untracked-files=normal 2>/dev/null); then
        log "$wt" kept "git status failed"
        return 0
    fi
    if [[ -n $status ]]; then
        log "$wt" kept "uncommitted changes or untracked files"
        return 0
    fi
    if ! unique=$(git -C "$main" for-each-ref --format='^%(objectname)' ${ref:+--exclude="$ref"} |
        git -C "$main" rev-list --stdin -n 1 "$sha" 2>/dev/null); then
        log "$wt" kept "cannot tell whether HEAD has unique commits"
        return 0
    fi
    if [[ -n $unique ]]; then
        log "$wt" kept "HEAD has commits no other ref reaches"
        return 0
    fi
    teardown
    if ! git -C "$main" worktree remove -- "$wt" 2>/dev/null; then
        log "$wt" failed "git worktree remove refused${td_note:+ ($td_note)}"
        return 0
    fi
    idle="idle $(((now - newest) / 3600)) h${td_note:+; $td_note}"
    if [[ $ref == refs/heads/worktree-* ]]; then
        if git -C "$main" branch -D -- "${ref#refs/heads/}" >/dev/null 2>&1; then
            log "$wt" removed "$idle; branch ${ref#refs/heads/} deleted"
        else
            log "$wt" removed "$idle; branch ${ref#refs/heads/} could not be deleted"
        fi
    else
        log "$wt" removed "$idle"
    fi
}

# The detached half: worktree-subagent-stop.sh --sweep <main> <self-top> <self-name>
if [[ ${1:-} == --sweep ]]; then
    main=$2 self=$3 self_name=$4
    grace=${CLAUDE_WORKTREE_AGENT_GRACE_HOURS:-24}
    [[ $grace =~ ^[0-9]+$ ]] || grace=24
    now=$(date +%s)
    wt="" sha="" ref="" locked=0 prunable=0
    while IFS= read -r -d '' line; do
        case $line in
            "worktree "*) wt=${line#worktree } sha="" ref="" locked=0 prunable=0 ;;
            "HEAD "*) sha=${line#HEAD } ;;
            "branch "*) ref=${line#branch } ;;
            locked | "locked "*) locked=1 ;;
            prunable | "prunable "*) prunable=1 ;;
            "") [[ -n $wt ]] && consider; wt="" ;;
        esac
    done < <(git -C "$main" worktree list --porcelain -z 2>/dev/null)
    [[ -n $wt ]] && consider
    exit 0
fi

input=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || exit 0
agent=$(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null) || agent=""
[[ -n $cwd && -d $cwd ]] || exit 0

{ IFS= read -r top && IFS= read -r common; } < <(
    git -C "$cwd" rev-parse --path-format=absolute --show-toplevel --git-common-dir 2>/dev/null
) || exit 0
main=${common%/*}
# Nothing to sweep: leave before spawning anything.
compgen -G "$main/.claude/worktrees/agent-*" >/dev/null || exit 0
[[ -d $common/worktrees ]] || exit 0

setsid -f flock -n "$common/worktrees" "$BASH" "${BASH_SOURCE[0]}" --sweep \
    "$main" "$top" "${agent:+agent-$agent}" </dev/null >/dev/null 2>&1
exit 0
