#!/usr/bin/env bash
# Tests for prune-claude-tmp.sh, one directory up.
#
# Why a private /tmp: the hook deletes, and it prunes one directory only,
# /tmp/claude-<uid>. So the suite runs itself in namespaces of its own, which
# unshare makes without privilege. The first, as its root, mounts an empty
# tmpfs on /tmp. The second maps an unused uid, FAKE_UID, and runs the suite
# as that uid with no capabilities, so file permissions hold as for any
# user. /tmp/claude-$FAKE_UID is then the hook's real default root and a
# throwaway tree at once: no case can reach the /tmp of the machine, and the
# suite refuses to start unless /tmp is its own tmpfs and id -u is FAKE_UID.
# Without unprivileged user namespaces it cannot run, and fails saying so.
#
# The cases with a mount, and the one without /proc, nest two namespaces
# more (in_mount_ns): the third, as its root, mounts, and the fourth runs the
# hook as FAKE_UID again, where that mount is.
#
# The environment is built from nothing (env -i): PATH, HOME, and the pairs
# a case gives. Ages are set with touch: "old" is two days, past the default
# limit of 24 hours, and "new" is now. A busy folder is one that a sleep(1)
# started by the test holds, as its working directory or through an open
# file; the test waits until /proc shows it before the hook runs.
#
# Run:  bash prune-claude-tmp.test.sh          (exit 0 = all green)

# The checks are strings that check evals, so their $ expand there.
# shellcheck disable=SC2016
set -uo pipefail

SELF=$(readlink -f "$0")
HOOK=${SELF%/*/*}/prune-claude-tmp.sh
FAKE_UID=3999999
MARK=.prune-claude-tmp-test
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }
for tool in env jq find touch sleep date du rm mkdir wc stat id mount unshare; do
    type -P "$tool" >/dev/null || { echo "the tests need $tool, which is not installed" >&2; exit 2; }
done

if [[ ${1:-} != --inside ]]; then
    exec unshare -rm "$BASH" -c '
        mount -t tmpfs tmpfs /tmp || {
            echo "prune-claude-tmp.test.sh: cannot mount a private /tmp in a user namespace, which every case needs" >&2
            exit 2
        }
        : >"/tmp/$3"
        exec unshare --user --map-user="$2" --map-group="$2" "$BASH" "$1" --inside
    ' prune-test "$SELF" "$FAKE_UID" "$MARK"
fi
if [[ $(id -u) != "$FAKE_UID" || ! -e /tmp/$MARK || $(stat -f -c %T /tmp) != tmpfs ]]; then
    echo "prune-claude-tmp.test.sh: refusing to run, /tmp is not the suite's own tmpfs" >&2
    exit 2
fi

ENV_BIN=$(type -P env) JQ_BIN=$(type -P jq)

pass=0
fail=0
CASE=""
RC=0 OUT="" ERR=""
PIDS=()

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'rc: %s\nstdout: %s\nstderr: %s\n' "$RC" "$OUT" "$ERR" | sed 's/^/       | /'; }

ROOT=$(mktemp -d /tmp/prune-test.XXXXXX)
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
}
trap cleanup EXIT

# The tools the hook may use; NO_JQ lacks jq, OTHER_ID has an id that names
# another uid.
TOOLS=$ROOT/tools NO_JQ=$ROOT/no-jq OTHER_ID=$ROOT/other-id
mkdir -p "$TOOLS" "$NO_JQ" "$OTHER_ID"
for tool in find date du rm mkdir stat id; do
    ln -s "$(type -P "$tool")" "$TOOLS/$tool"
    ln -s "$(type -P "$tool")" "$NO_JQ/$tool"
    [[ $tool == id ]] || ln -s "$(type -P "$tool")" "$OTHER_ID/$tool"
done
ln -s "$JQ_BIN" "$TOOLS/jq"
ln -s "$JQ_BIN" "$OTHER_ID/jq"
printf '#!%s\necho 4000000\n' "$BASH" >"$OTHER_ID/id"
chmod +x "$OTHER_ID/id"

T=/tmp/claude-$FAKE_UID     # the root the hook prunes
OUTSIDE=/tmp/outside        # on the same tmpfs as the root
LOG=$ROOT/home/.local/state/claude-prune-tmp.log
SID=6f0b2c1e-0000-4000-8000-000000000001

# fresh: an empty root (mode 700, as Claude Code makes it) and home, every
# helper process stopped.
fresh() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    PIDS=()
    chmod -R u+rwx -- "$T" "$ROOT/home" 2>/dev/null
    rm -rf -- "$T" "${ROOT:?}/home" "$OUTSIDE" /tmp/real-root /tmp/link /tmp/run-user /tmp/elsewhere /tmp/claude-4000000
    mkdir -m 700 "$T"
    mkdir -p "$ROOT/home"
}

# make <path relative to the root>...: a folder with one file in it, aged old.
make() {
    local rel
    for rel; do
        mkdir -p -- "$T/$rel"
        printf 'x\n' >"$T/$rel/f"
        age old "$T/$rel"
    done
}

# age old|new|<minutes> <path>: sets the mtime of the path and everything in it.
age() {
    local when
    case $1 in
        old) when=@$(( $(date +%s) - 2 * 86400 )) ;;
        new) when=@$(date +%s) ;;
        *)   when=@$(( $(date +%s) - $1 * 60 )) ;;
    esac
    find "$2" -exec touch -h -d "$when" {} +
}

# hold_cwd <dir>, hold_fd <file>: a sleep that has the directory as its
# working directory, or the file open, until fresh stops it.
hold_cwd() {
    (cd -- "$1" && exec sleep 60) &
    PIDS+=("$!")
    wait_for "/proc/$!/cwd" "$1"
}
hold_fd() {
    sleep 60 3<"$1" &
    PIDS+=("$!")
    wait_for "/proc/$!/fd/3" "$1"
}
wait_for() {
    local i
    for ((i = 0; i < 200; i++)); do
        [[ $(readlink -- "$1" 2>/dev/null) == "$(cd -P -- "${2%/*}" && pwd)/${2##*/}" ]] && return
        sleep 0.01
    done
    echo "no process held $2" >&2
}

# run [stdin] [VAR=value...]: runs the hook on its default root; the stdin
# defaults to a payload with session_id $SID. Sets RC, OUT and ERR.
run() {
    local input=${1-"{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionStart\"}"}
    shift || true
    printf '%s' "$input" >"$ROOT/in"
    "$ENV_BIN" -i PATH="$TOOLS" HOME="$ROOT/home" "$@" "$BASH" "$HOOK" \
        <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
    OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
}

# in_mount_ns <root script> [VAR=value...]: runs <root script> as the root of
# a new user and mount namespace, then the hook as FAKE_UID in a namespace
# nested in that one, where the script's mounts are. The mounts end with the
# namespace. Sets RC, OUT and ERR.
in_mount_ns() {
    local setup=$1
    shift
    printf '{}' >"$ROOT/in"
    unshare -rm "$BASH" -c '
        eval "$1" || exit 99
        exec unshare --user --map-user="$2" --map-group="$2" "${@:3}"
    ' in-mount-ns "$setup" "$FAKE_UID" "$ENV_BIN" -i PATH="$TOOLS" HOME="$ROOT/home" "$@" "$BASH" "$HOOK" \
        <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
    OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
    [[ $RC != 99 ]] || ERR="the mount of this case failed: $ERR"
}

# check <condition>: the case passes when the condition holds, the hook
# exited 0 and wrote nothing to stderr.
check() {
    if   [ "$RC" -ne 0 ]; then bad "expected exit 0"
    elif [ -n "$ERR" ];   then bad "expected nothing on stderr"
    elif ! eval "$1";     then bad "failed: $1"
    else ok; fi
}

gone() { local rel; for rel; do [[ ! -e $T/$rel && ! -L $T/$rel ]] || return 1; done; }
kept() { local rel; for rel; do [[ -e $T/$rel || -L $T/$rel ]] || return 1; done; }
silent() { [[ -z $OUT ]]; }
# said <n>: stdout is one JSON object whose systemMessage reports n folders.
said() {
    [[ $("$JQ_BIN" -r '.systemMessage | strings' <<<"$OUT" 2>/dev/null) == "Pruned $1 dead Claude temp folder(s) from "* ]] &&
        [[ $("$JQ_BIN" -s length <<<"$OUT" 2>/dev/null) == 1 ]]
}
logged() { [[ -f $LOG ]] && [[ $(wc -l <"$LOG") -eq $1 ]]; }
# refused <text>: stdout is one systemMessage that says nothing was pruned
# and holds <text>.
refused() {
    local m
    m=$("$JQ_BIN" -r '.systemMessage | strings' <<<"$OUT" 2>/dev/null) &&
        [[ $m == "prune-claude-tmp pruned nothing: "* && $m == *"$1"* ]] &&
        [[ $("$JQ_BIN" -s length <<<"$OUT" 2>/dev/null) == 1 ]]
}

# --- what goes ------------------------------------------------------------------

echo "what goes"

fresh
make -proj/dead-1 -proj/dead-2
run
CASE="dead old session folders go, are logged, and are reported once"
check 'gone -proj/dead-1 -proj/dead-2 && kept -proj && said 2 && logged 2'

fresh
make -proj/dead
run
CASE="the report names the root and the log"
check '[[ $("$JQ_BIN" -r .systemMessage <<<"$OUT") == *"from $T,"*"List: $LOG" ]]'

fresh
make bash-edit-diff/dead-sess
run
CASE="a per-session folder under bash-edit-diff goes, bash-edit-diff stays"
check 'gone bash-edit-diff/dead-sess && kept bash-edit-diff && said 1'

fresh
make stray-dir
printf 'x\n' >"$T/stray-file"; age old "$T/stray-file"
run
CASE="any other top-level entry, a folder or a file, goes when it is dead"
check 'gone stray-dir stray-file && said 2'

fresh
make -proj/dead
mkdir -p "$OUTSIDE"; printf 'keep\n' >"$OUTSIDE/f"
ln -s "$OUTSIDE" "$T/-proj/link"; age old "$T/-proj/link"
ln -s "$OUTSIDE" "$T/top-link"; age old "$T/top-link"
run
CASE="a symlink goes as a link, and what it points to stays"
check 'gone -proj/link top-link && [[ -f $OUTSIDE/f ]] && said 3'

fresh
make '-proj/with space' '-proj/-dash' $'-proj/new\nline' '-a b/sess' "-proj/quote\"back\\slash"
run
CASE="names with spaces, a leading dash, a newline, a quote or a backslash go too"
check 'gone "-proj/with space" -proj/-dash $'"'"'-proj/new\nline'"'"' "-a b/sess" "-proj/quote\"back\\slash" && said 5'

# --- what stays -----------------------------------------------------------------

echo "what stays"

fresh
make -proj/recent
age new "$T/-proj/recent"
run
CASE="a folder modified within 24 hours stays"
check 'kept -proj/recent && silent'

fresh
make -proj/deep
mkdir -p "$T/-proj/deep/a/b"; printf 'x\n' >"$T/-proj/deep/a/b/new"
age old "$T/-proj/deep"; age new "$T/-proj/deep/a/b/new"
run
CASE="one recent file deep inside keeps the whole folder"
check 'kept -proj/deep/a/b/new && silent'

fresh
make "-proj/$SID" "bash-edit-diff/$SID" -proj/dead
run
CASE="the starting session's own folders stay, however old"
check 'kept "-proj/$SID" "bash-edit-diff/$SID" && gone -proj/dead && said 1'

fresh
make -proj/busy-cwd -proj/dead
hold_cwd "$T/-proj/busy-cwd"
run
CASE="a folder that a process works in stays"
check 'kept -proj/busy-cwd && gone -proj/dead && said 1'

fresh
make -proj/busy-deep
mkdir -p "$T/-proj/busy-deep/x/y"; age old "$T/-proj/busy-deep"
hold_cwd "$T/-proj/busy-deep/x/y"
run
CASE="a process working deeper inside keeps the folder too"
check 'kept -proj/busy-deep && silent'

fresh
make -proj/busy-fd bash-edit-diff/busy-fd stray
hold_fd "$T/-proj/busy-fd/f"
hold_fd "$T/bash-edit-diff/busy-fd/f"
hold_fd "$T/stray/f"
run
CASE="a folder in which a process holds a file open stays, at every level"
check 'kept -proj/busy-fd bash-edit-diff/busy-fd stray && silent'

fresh
make $'-proj/busy\nnewline' $'-proj/busy'
hold_cwd "$T/-proj/busy"$'\n'"newline"
run
CASE="a busy folder with a newline in its name stays, and its look-alike goes"
check 'kept $'"'"'-proj/busy\nnewline'"'"' && gone -proj/busy && said 1'

fresh
mkdir -p "$T/-proj-empty" "$T/-proj-full"; make -proj-full/dead
age old "$T/-proj-empty"; age old "$T/-proj-full"
run
CASE="project folders are never removed, empty or not"
check 'kept -proj-empty -proj-full && gone -proj-full/dead && said 1'

fresh
make -proj/locked
mkdir -p "$T/-proj/locked/sealed"; printf 'x\n' >"$T/-proj/locked/sealed/new"
age old "$T/-proj/locked"; age new "$T/-proj/locked/sealed/new"
chmod 000 "$T/-proj/locked/sealed"
run
chmod 755 "$T/-proj/locked/sealed"
CASE="a folder with a part find cannot read stays: its age is unknown"
check 'kept -proj/locked/sealed/new && silent'

# A mount inside a dead folder: a session that died with something mounted
# in its scratchpad. Pruning through the mount would delete what is mounted
# there, and with a network share that is someone's files. The bind mounts
# come from $OUTSIDE, on the same file system as the root, which rm
# --one-file-system does not stop at: there the hook's reading of the mounts
# is the only defence, and these cases fail without it.
echo "mounts"

# bind <dir>: the root script of a case, a bind mount of $OUTSIDE on <dir>.
bind() { printf 'mount --bind %q %q' "$OUTSIDE" "$1"; }
outside() { mkdir -p "$OUTSIDE"; printf 'keep\n' >"$OUTSIDE/keep"; age old "$OUTSIDE"; }
outside_kept() { [[ -f $OUTSIDE/keep ]]; }

fresh
outside
make -proj/dead-mount -proj/dead
mkdir -p "$T/-proj/dead-mount/mnt"; age old "$T/-proj/dead-mount"
in_mount_ns "$(bind "$T/-proj/dead-mount/mnt")"
CASE="a dead folder with a bind mount in it stays whole, and so does what is mounted there"
check 'outside_kept && kept -proj/dead-mount/f -proj/dead-mount/mnt && gone -proj/dead && said 1'

fresh
outside
make -proj/deep-mount
mkdir -p "$T/-proj/deep-mount/a/b/mnt"; age old "$T/-proj/deep-mount"
in_mount_ns "$(bind "$T/-proj/deep-mount/a/b/mnt")"
CASE="a mount deeper inside keeps the folder too"
check 'outside_kept && kept -proj/deep-mount/f && silent'

fresh
outside
make '-proj/dead mount' $'-proj/dead\tmount'
mkdir -p "$T/-proj/dead mount/mnt" "$T/-proj/dead"$'\t'"mount/mnt"
age old "$T/-proj"
in_mount_ns "$(bind "$T/-proj/dead mount/mnt")"
CASE="a mount whose path holds a space still keeps its folder, and only that one"
check 'outside_kept && kept "-proj/dead mount/f" && gone $'"'"'-proj/dead\tmount'"'"' && said 1'

fresh
outside
make stray-mount
mkdir -p "$T/stray-mount/mnt"; age old "$T/stray-mount"
in_mount_ns "$(bind "$T/stray-mount/mnt")"
CASE="a mount in a top-level entry keeps the entry"
check 'outside_kept && kept stray-mount/f && silent'

fresh
make -proj/tmpfs-mount
mkdir -p "$T/-proj/tmpfs-mount/mnt"; age old "$T/-proj/tmpfs-mount"
in_mount_ns "$(printf 'mount -t tmpfs tmpfs %q && echo keep >%q && touch -d @0 %q %q' \
    "$T/-proj/tmpfs-mount/mnt" "$T/-proj/tmpfs-mount/mnt/keep" "$T/-proj/tmpfs-mount/mnt/keep" "$T/-proj/tmpfs-mount/mnt")"
CASE="a mount of another file system keeps its folder too"
check 'kept -proj/tmpfs-mount/f && silent'

# Without /proc no nested namespace can map a uid, so this case runs the
# hook as the root of its namespace, uid 0, on that uid's own root.
fresh
rm -rf -- /tmp/claude-0
mkdir -m 700 /tmp/claude-0 && mkdir -p /tmp/claude-0/-proj/dead && age old /tmp/claude-0
printf '{}' >"$ROOT/in"
unshare -rm "$BASH" -c 'mount -t tmpfs tmpfs /proc || exit 99; exec "$@"' without-proc \
    "$ENV_BIN" -i PATH="$TOOLS" HOME="$ROOT/home" "$BASH" "$HOOK" <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
RC=$? OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
[[ $RC != 99 ]] || ERR="cannot hide /proc in a user namespace: $ERR"
CASE="without /proc it sees neither busy folders nor mounts, so nothing is pruned"
check '[[ -e /tmp/claude-0/-proj/dead ]] && silent'
rm -rf -- /tmp/claude-0

# --- the root -------------------------------------------------------------------

# Every refusal case is a dry run as well, so a hook that lost its guard
# lists what it would delete instead of deleting it.
echo "the root"

fresh
make -proj/dead
run "" PRUNE_TMP_DRY_RUN=1
CASE="the default root is /tmp/claude-<uid>"
if [[ $RC -eq 0 && -z $OUT && $ERR == *"would delete -proj/dead ("* ]] && kept -proj/dead; then ok
else bad "expected a dry run of the default root to list -proj/dead"; fi

for given in "$T" "/tmp//claude-$FAKE_UID" "$T/" "$T//" "//tmp/claude-$FAKE_UID"; do
    fresh
    make -proj/dead
    run "" PRUNE_TMP_ROOT="$given"
    CASE="PRUNE_TMP_ROOT=$given is the same root, so it prunes"
    check 'gone -proj/dead && said 1'
done

for given in / // //. /tmp "$T/." "/tmp/./claude-$FAKE_UID" "$T/.." "$T/-proj" "/tmp/elsewhere/claude-$FAKE_UID"; do
    fresh
    make -proj/dead
    mkdir -p /tmp/elsewhere && mkdir -m 700 "/tmp/elsewhere/claude-$FAKE_UID"
    run "" PRUNE_TMP_ROOT="$given" PRUNE_TMP_DRY_RUN=1
    CASE="PRUNE_TMP_ROOT=$given is refused, by name"
    check 'kept -proj/dead && refused "PRUNE_TMP_ROOT=$given is not $T"'
done

fresh
make -proj/dead
mkdir -m 700 /tmp/run-user
printf 'x\n' >/tmp/run-user/agent.sock; age old /tmp/run-user
run "" PRUNE_TMP_ROOT=/tmp/run-user PRUNE_TMP_DRY_RUN=1 XDG_RUNTIME_DIR=/tmp/run-user
CASE="a runtime directory, user-owned and 0700 like the root, is refused"
check '[[ -f /tmp/run-user/agent.sock ]] && kept -proj/dead && refused "PRUNE_TMP_ROOT=/tmp/run-user is not $T"'

fresh
make -proj/dead
ln -s "$T" /tmp/link
run "" PRUNE_TMP_ROOT=/tmp/link PRUNE_TMP_DRY_RUN=1
CASE="a symlink to the root is refused"
check 'kept -proj/dead && refused "PRUNE_TMP_ROOT=/tmp/link is not $T"'

fresh
make -proj/dead
mv "$T" /tmp/real-root
ln -s /tmp/real-root "$T"
run "" PRUNE_TMP_DRY_RUN=1
CASE="a root that is itself a symlink is refused"
check '[[ -e /tmp/real-root/-proj/dead ]] && refused "$T is a symbolic link"'

fresh
make -proj/dead
chmod 755 "$T"
run "" PRUNE_TMP_DRY_RUN=1
CASE="a root that is not mode 700 is refused"
check 'kept -proj/dead && refused "$T has mode 755, not 700"'

fresh
mkdir -m 700 /tmp/claude-4000000 && mkdir -p /tmp/claude-4000000/-proj/dead
age old /tmp/claude-4000000
"$ENV_BIN" -i PATH="$OTHER_ID" HOME="$ROOT/home" PRUNE_TMP_DRY_RUN=1 "$BASH" "$HOOK" <<<"{}" >"$ROOT/out" 2>"$ROOT/err"
RC=$? OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
CASE="a root not owned by the uid it is named for is refused"
check '[[ -e /tmp/claude-4000000/-proj/dead ]] && refused "/tmp/claude-4000000 is not owned by uid 4000000"'

fresh
rmdir "$T"
run
CASE="a root that does not exist yet: silent"
check 'silent'

fresh
rmdir "$T"
printf 'x\n' >"$T"
run "" PRUNE_TMP_DRY_RUN=1
CASE="a root that is a file is refused, and the file stays"
check '[[ -f $T ]] && refused "$T is not a directory"'

fresh
run
CASE="an empty root: silent, and no log is written"
check 'silent && [[ ! -s $LOG ]]'

# --- the input and the settings ---------------------------------------------------

echo "the input and the settings"

for input in '' 'not json' '[1,2]' '{"session_id":42}' '{"session_id":null}'; do
    fresh
    make -proj/dead
    run "$input"
    CASE="stdin without a usable session_id (${input:-empty}) still prunes the dead"
    check 'gone -proj/dead && said 1'
done

fresh
make "-proj/$SID" -proj/dead
run "{\"session_id\":\"$SID\"} {\"session_id\":\"other\"}"
CASE="of two JSON values on stdin only the first names the session"
check 'kept "-proj/$SID" && gone -proj/dead && said 1'

fresh
make -proj/two-hours
age 120 "$T/-proj/two-hours"
run "" PRUNE_TMP_MAX_AGE_MIN=60
CASE="PRUNE_TMP_MAX_AGE_MIN=60 lets a folder of two hours go"
check 'gone -proj/two-hours && said 1'

fresh
make -proj/two-hours
age 120 "$T/-proj/two-hours"
run "" PRUNE_TMP_MAX_AGE_MIN=
CASE="an empty PRUNE_TMP_MAX_AGE_MIN is the default, 24 hours"
check 'kept -proj/two-hours && silent'

for bad_age in 0 -5 24h 1.5 ' 60' 060 abc 99999999999999999999; do
    fresh
    make -proj/dead
    run "" PRUNE_TMP_MAX_AGE_MIN="$bad_age"
    CASE="PRUNE_TMP_MAX_AGE_MIN=$bad_age is no age: nothing is pruned"
    check 'kept -proj/dead && silent'
done

fresh
make -proj/dead
run "" PRUNE_TMP_DRY_RUN=1
CASE="a dry run deletes nothing, writes no log and says what would go on stderr"
if [[ $RC -eq 0 && -z $OUT && $ERR == *"would delete -proj/dead ("*" KiB)"* && ! -e $LOG ]] && kept -proj/dead; then
    ok
else
    bad "expected the folder kept, no log, and a line on stderr"
fi

fresh
make -proj/dead
run "" XDG_STATE_HOME="$ROOT/state"
CASE="XDG_STATE_HOME moves the log"
check 'gone -proj/dead && [[ -s $ROOT/state/claude-prune-tmp.log && ! -e $LOG ]] && said 1'
rm -rf -- "${ROOT:?}/state"

fresh
make -proj/dead
run "" HOME=
CASE="without HOME or XDG_STATE_HOME there is no log, so nothing is pruned"
check 'kept -proj/dead && silent'

fresh
make -proj/dead
mkdir -p "$ROOT/home/.local"; printf 'x\n' >"$ROOT/home/.local/state"
run
CASE="a log that cannot be written stops the pruning"
check 'kept -proj/dead && silent'

fresh
make "-proj/$SID" -proj/dead
"$ENV_BIN" -i PATH="$NO_JQ" HOME="$ROOT/home" "$BASH" "$HOOK" \
    <<<"{\"session_id\":\"$SID\"}" >"$ROOT/out" 2>"$ROOT/err"
RC=$? OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
CASE="without jq the hook cannot tell its own session, so nothing is pruned"
check 'kept "-proj/$SID" -proj/dead && silent'

fresh
make -proj/dead-a -proj/dead-b -proj/dead-c
for i in 1 2 3; do
    "$ENV_BIN" -i PATH="$TOOLS" HOME="$ROOT/home" "$BASH" "$HOOK" \
        <<<"{}" >"$ROOT/out.$i" 2>"$ROOT/err.$i" &
    PIDS+=("$!")
done
crc=0
for p in "${PIDS[@]}"; do wait "$p" || crc=1; done
PIDS=()
RC=$crc OUT=$(cat "$ROOT"/out.*) ERR=$(cat "$ROOT"/err.*)
CASE="three runs at once all exit 0, print valid JSON or nothing, and leave nothing dead"
check 'gone -proj/dead-a -proj/dead-b -proj/dead-c && "$JQ_BIN" -e -s "all(.[]; .systemMessage | type == \"string\")" <<<"$OUT" >/dev/null'
rm -f -- "$ROOT"/out.* "$ROOT"/err.*

# --- summary ----------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
