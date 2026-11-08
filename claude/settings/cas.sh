# shellcheck shell=bash
# cas.sh: how sync-hooks.sh and sync-mcp.sh change a JSON file that Claude
# Code writes too. They source this file; it is not run by itself.
#
# The two steps put a few keys into a file of Claude Code's own
# (~/.claude/settings.json, ~/.claude.json) and keep the rest. Claude Code
# writes those files at any time, so this file is the one place that says how
# to change them without losing its writes, and both steps get every fix at
# once.
#
#   cas_resolve FILE STORE
#       Sets cas_target to the file to write: FILE, or the file a symlink
#       FILE names. Returns 1 when that file is in STORE (home-manager owns it
#       whole, and it cannot be written).
#   cas_apply FILE FILTER [JQ_ARGS...]
#       Puts the result of the jq FILTER, run on the document in cas_target
#       with JQ_ARGS, into it. Returns 0 when it is in place, or was in place
#       already. The caller defines `fail MESSAGE`, which prints and exits 1.
#
# What cas_apply does, in this order:
#
# 1. It takes Claude Code's lock. Claude Code saves its config under a
#    proper-lockfile lock: a directory made with mkdir beside the file, the
#    path as given with ".lock" added (~/.claude.json.lock), which goes stale
#    after 10 s without a touch. Under that lock it reads the file again and
#    applies its change to what it read, so it loses nothing that a writer
#    holding the lock wrote. The step makes the same directory, on FILE (not
#    on the file a link names, as Claude Code does) and keeps it until the
#    new file is in place, and removes it when it exits. While a fresh lock
#    stands, it waits with a growing pause (0.2 s, doubling, 4 s at most, in
#    all about 20 s) and then fails without writing. A stale lock is taken
#    over. Two programs that both take a stale lock in the same moment can
#    both hold it; the comparison below is for that and for writers that
#    take no lock.
# 2. It reads a copy of the file and requires exactly one JSON document in
#    it. A zero-byte file counts as {}; a file of whitespace, or of two
#    documents, fails the step, since jq would otherwise read nothing, or
#    both, and call the file unchanged or rewrite both.
# 3. It builds the new file beside it, and when its JSON does not differ from
#    the copy's, leaves the file as it is, byte for byte.
# 4. It moves the new file over the old one only while the file is still byte
#    for byte the copy it read; otherwise it reads again, up to five times,
#    pausing a little longer after each miss (0.1 s, doubling), then fails
#    without writing. A file that rename cannot replace, a mount point, is
#    written in place.
#
# The existing file keeps its mode; a new one gets 600. Every file made
# beside the target is removed on exit, success or not.
#
# The waits can be set for a test, in seconds, as lists: RAVNIX_CAS_LOCK_DELAYS
# (default "0.2 0.4 0.8 1.6 3.2 4 4 4") and RAVNIX_CAS_TRY_DELAYS (default
# "0.1 0.2 0.4 0.8").
#
# Tests: tests/sync-hooks.test.sh and tests/sync-mcp.test.sh, which cover it
# through the two steps.

cas_target=''
cas_lock_dir=''
cas_held=''
cas_copy=''
cas_tmp=''

# Seconds after which a lock counts as stale, as in Claude Code.
cas_stale=10

cas_resolve() {
    local file=$1 store=$2
    cas_target=$file
    if [[ -L $file ]]; then
        cas_target=$(readlink -f -- "$file") || fail "the symlink names nothing"
        [[ $cas_target != "$store"/* ]] || return 1
    fi
    return 0
}

# Removes what cas_apply made, and the lock if this process holds it. Runs
# on exit, so a failure leaves nothing behind.
cas_cleanup() {
    [[ -z $cas_copy ]] || rm -f -- "$cas_copy"
    [[ -z $cas_tmp ]] || rm -f -- "$cas_tmp" "$cas_tmp.err"
    cas_copy='' cas_tmp=''
    if [[ -n $cas_held ]]; then
        rmdir -- "$cas_lock_dir" 2>/dev/null
        cas_held=''
    fi
}

# Takes the lock, or fails after the waits.
cas_lock() {
    local delay now mtime
    # shellcheck disable=SC2086  # a list of numbers
    for delay in ${RAVNIX_CAS_LOCK_DELAYS-0.2 0.4 0.8 1.6 3.2 4 4 4} ''; do
        while :; do
            if mkdir -- "$cas_lock_dir" 2>/dev/null; then
                cas_held=1
                return 0
            fi
            [[ -d $cas_lock_dir ]] || fail "cannot make the lock $cas_lock_dir"
            # Gone since mkdir looked: try again at once.
            mtime=$(stat -c %Y -- "$cas_lock_dir" 2>/dev/null) || continue
            now=$(date +%s)
            ((now - mtime >= cas_stale)) || break
            # Stale: its holder died or hangs. Take it over.
            rmdir -- "$cas_lock_dir" 2>/dev/null || [[ ! -d $cas_lock_dir ]] ||
                fail "cannot remove the stale lock $cas_lock_dir"
        done
        [[ -n $delay ]] || break
        sleep "$delay"
    done
    fail "the lock $cas_lock_dir is held by another program, such as a running Claude Code, and stayed held while it waited; nothing was written"
}

cas_apply() {
    local file=$1 filter=$2 try status why had
    local -a pauses
    shift 2
    # shellcheck disable=SC2206  # a list of numbers
    pauses=(${RAVNIX_CAS_TRY_DELAYS-0.1 0.2 0.4 0.8})
    # Exactly one document: jq -s makes a list of them.
    # shellcheck disable=SC2016  # the $ are jq's
    local one='def __one: if length != 1 then error("it holds \(length) JSON documents, not one") else .[0] end;'

    mkdir -p -- "${cas_target%/*}" || fail "cannot make ${cas_target%/*}"
    cas_lock_dir=$file.lock
    trap cas_cleanup EXIT
    cas_lock
    cas_copy=$(mktemp "$cas_target.ravnix.XXXXXX") || fail "cannot write beside it"
    cas_tmp=$(mktemp "$cas_target.ravnix.XXXXXX") || fail "cannot write beside it"

    for ((try = 0; try < 5; try++)); do
        if ((try > 0)); then sleep "${pauses[try - 1]:-0}"; fi
        # A lock that is held a long time must not turn stale.
        touch -- "$cas_lock_dir" 2>/dev/null

        # The copy this try reads, with the file's mode; none when it is
        # missing.
        had=""
        if [[ -e $cas_target ]]; then
            cp -p -- "$cas_target" "$cas_copy" || fail "cannot read it"
            had=1
        fi

        if [[ -n $had && -s $cas_copy ]]; then
            jq -s "$@" "$one __one | ( $filter )" "$cas_copy" >"$cas_tmp" 2>"$cas_tmp.err"
        else
            jq -n "$@" "{} | ( $filter )" >"$cas_tmp" 2>"$cas_tmp.err"
        fi
        status=$?
        why=$(<"$cas_tmp.err")
        [[ $status == 0 ]] || fail "${why:-jq failed}"

        if [[ -n $had ]]; then
            # Unchanged as JSON: the file stays as it is, byte for byte.
            if jq -e -n --slurpfile new "$cas_tmp" --slurpfile old "$cas_copy" \
                '$new == $old or ($old == [] and $new == [{}])' >/dev/null 2>&1; then
                cas_cleanup
                return 0
            fi
            chmod --reference="$cas_copy" -- "$cas_tmp" || fail "cannot keep its mode"
            if [[ ! -f $cas_target ]] || ! cmp -s -- "$cas_copy" "$cas_target"; then
                continue
            fi
        else
            chmod 600 -- "$cas_tmp" || fail "cannot set its mode"
            [[ ! -e $cas_target && ! -L $cas_target ]] || continue
        fi

        # rename(2) fails with EBUSY when the file is a mount point, as a
        # file bind-mounted by impermanence is; then it is written in place,
        # as home-manager's own merge does.
        mv -fT -- "$cas_tmp" "$cas_target" 2>/dev/null || cat -- "$cas_tmp" >"$cas_target" ||
            fail "cannot write the new file"
        cas_cleanup
        return 0
    done

    fail "it changed during each of five tries, written at the same time by another program, such as a running Claude Code; it stays as that program left it"
}
