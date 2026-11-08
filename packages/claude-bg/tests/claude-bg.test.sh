#!/usr/bin/env bash
# Tests for claude-bg (packages/claude-bg), run by the check bin-claude-bg.
#
# Why fakes: the contract is which supervisor gets restarted and what the
# session is started with, and a real `claude daemon stop` would cut into
# the user's running sessions. So claude and rbw are stubs that log their calls,
# and CLAUDE_BG_PROC points at a fake /proc with one directory per process,
# holding comm, a NUL-separated cmdline and a NUL-separated environ.
#
# Run:  bash claude-bg.test.sh      (exit 0 = all green)
# CLAUDE_BG_UNDER_TEST=<file> tests another copy, for mutation runs; by default
# it is the claude-bg on the PATH.
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

# The checks are eval'd, so their $ expand at check time.
# shellcheck disable=SC2016

set -uo pipefail

SUT=${CLAUDE_BG_UNDER_TEST:-$(type -P claude-bg)}
SUT=$(readlink -f "$SUT")
BASH_BIN=$(type -P bash)

SB=$(mktemp -d "${TMPDIR:-/tmp}/claude-bg-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin"
cat >"$SB/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG"
if [[ $1 == daemon && $2 == stop ]]; then exit "${STOP_RC:-0}"; fi
# Record the token the session would see.
printf 'session COOLIFY_API_TOKEN=%s\n' "${COOLIFY_API_TOKEN-}" >>"$LOG"
EOF
cat >"$SB/bin/rbw" <<'EOF'
#!/usr/bin/env bash
printf 'rbw %s\n' "$*" >>"$LOG"
case $1 in
    unlocked) [[ ${RBW_LOCKED:-0} == 0 ]] ;;
    unlock) exit "${RBW_UNLOCK_RC:-0}" ;;
    get)
        # rbw get -- ITEM: the item name is the one thing the table holds.
        printf 'rbw get %s\n' "$3" >>"$LOG"
        # Whether a token is already in the environment of this child.
        for v in $(compgen -e); do [[ $v == *_API_TOKEN ]] && printf 'rbw sees %s\n' "$v" >>"$LOG"; done
        case $3 in
            "Coolify token") printf 'coolify-new\n' ;;
            "Plane token") printf 'plane-1\n' ;;
            "Empty item") ;;
            "Item=with=equals") printf 'eq-value\n' ;;
            # A value that starts with a dash, and one that holds a newline:
            # compared with the supervisor's environment byte for byte.
            "Dash token") printf '%s\n' '-n' ;;
            "Lines token") printf '%s\n' '-e' 'line2' ;;
            *) exit 1 ;;
        esac ;;
    *) exit 0 ;;
esac
EOF
# The build sandbox has no /usr/bin/env, so the stubs name the bash that runs
# the tests.
sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/claude" "$SB/bin/rbw"
chmod +x "$SB/bin/claude" "$SB/bin/rbw"

# The secret table the ravnix module writes from ravnix.shell.secretEnv: the
# name of a variable, and the name or id of the Bitwarden item that holds it.
cat >"$SB/secret-env" <<'EOF'
COOLIFY_API_TOKEN=Coolify token
PLANE_API_TOKEN=Plane token
EMPTY_API_TOKEN=Empty item
EOF

# proc PID COMM "ARG0 ARG1 ..." "K=V K=V ..."
proc() {
    local d="$SB/proc/$1"
    mkdir -p "$d"
    printf '%s\n' "$2" >"$d/comm"
    : >"$d/cmdline"; : >"$d/environ"
    local x
    for x in $3; do printf '%s\0' "$x" >>"$d/cmdline"; done
    for x in $4; do printf '%s\0' "$x" >>"$d/environ"; done
}

# run [ENV=VAL ...] -- ARGS: runs the script, sets $out (stderr) and $log
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    : >"$SB/log"
    out=$(env -i HOME="$SB" PATH="$SB/bin" LOG="$SB/log" \
        CLAUDE_BG_PROC="$SB/proc" CLAUDE_BG_SECRETS="$SB/secret-env" \
        "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1 >/dev/null)
    log=$(<"$SB/log")
}
has()    { [[ $log == *"$1"* ]]; }
says()   { [[ $out == *"$1"* ]]; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "    out: $out
    log: $log"; fi; }

echo "claude-bg"

rm -rf "$SB/proc"; mkdir -p "$SB/proc"
run -- -n probe "do it"
check "no supervisor: nothing is stopped, and claude --bg gets the args" \
    '! has "daemon stop" && has "--bg -n probe do it"'
check "the session is started with the token from the file" \
    'has "session COOLIFY_API_TOKEN=coolify-new"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run --json-path x" "COOLIFY_API_TOKEN=coolify-new PLANE_API_TOKEN=plane-1"
run -- x
check "a supervisor with every token is left alone" '! has "daemon stop"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run" "PLANE_API_TOKEN=plane-1"
run -- x
check "a supervisor lacking a token is restarted, keeping its workers" \
    'has "daemon stop --any --keep-workers" && says "lacked COOLIFY_API_TOKEN"'
check "the restart names only the missing token" '! says "lacked COOLIFY_API_TOKEN PLANE"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run" "COOLIFY_API_TOKEN=coolify-old PLANE_API_TOKEN=plane-1"
run -- x
check "a supervisor holding an older value is restarted" 'has "daemon stop --any --keep-workers"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run" ""
run -- x
check "an empty token in the file is not demanded of the supervisor" \
    'says "lacked COOLIFY_API_TOKEN PLANE_API_TOKEN;" && ! says "lacked COOLIFY_API_TOKEN PLANE_API_TOKEN EMPTY"'

rm -rf "$SB/proc"
proc 100 claude "claude -p please run claude daemon run" ""
run -- x
check "a claude whose prompt mentions daemon run is not the supervisor" '! has "daemon stop"'

rm -rf "$SB/proc"
proc 100 bash "claude daemon run" ""
run -- x
check "a process that is not claude is not the supervisor" '! has "daemon stop"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run" ""
run STOP_RC=1 -- x
check "a failed stop is reported, and the session still starts" \
    'says "daemon stop --any --keep-workers failed" && has "--bg x"'

rm -rf "$SB/proc"
proc 100 claude "claude daemon run" "COOLIFY_API_TOKEN=held"
run RBW_LOCKED=1 RBW_UNLOCK_RC=1 -- x
check "locked rbw: syncs, then asks to unlock" 'has "rbw sync" && has "rbw unlock"'
check "a refused unlock keeps the supervisor and names what it holds" \
    '! has "daemon stop" && says "rbw stayed locked; this session gets the tokens the background service holds: COOLIFY_API_TOKEN"'

rm -rf "$SB/proc"; mkdir -p "$SB/proc"
run RBW_LOCKED=1 RBW_UNLOCK_RC=1 -- x
check "a refused unlock with no supervisor says the session has no tokens" \
    'says "starts without the tokens: rbw stayed locked" && has "--bg x"'

run CLAUDE_BG_SECRETS="$SB/missing.env" -- x
check "a missing secret table is named" 'says "there is no $SB/missing.env"'

run -- x
check "every item of the table is read with rbw get, by its name" \
    'has "rbw get Coolify token" && has "rbw get Plane token" && has "rbw get Empty item"'

check "no rbw child sees a token: they are exported after the last read, not as they come" '! has "rbw sees"'

printf '%s\n' 'COOLIFY_API_TOKEN=Coolify token' 'PLANE_API_TOKEN=No such item' >"$SB/partial"
run CLAUDE_BG_SECRETS="$SB/partial" -- x
check "an item rbw cannot read is named, and no token is set (all or nothing), but the session starts" \
    'says "PLANE_API_TOKEN: rbw cannot read the item \"No such item\"" && has "session COOLIFY_API_TOKEN=" && ! has "session COOLIFY_API_TOKEN=coolify-new" && has "--bg x" && ! has "rbw sees"'
check "and the note says why the session starts without them" \
    'says "starts without the tokens: rbw could not read PLANE_API_TOKEN, so none of the secrets is set"'

printf '%s\n' '# a comment' '' 'lower=Coolify token' 'NOEQUALS' '1BAD=Coolify token' 'COOLIFY_API_TOKEN=' 'PLANE_API_TOKEN=Plane token' >"$SB/messy"
run CLAUDE_BG_SECRETS="$SB/messy" -- x
check "comments, blank lines and lines that are not NAME=item are not part of the table" \
    '! has "rbw get Coolify token" && has "rbw get Plane token" && ! says "cannot read"'

printf '%s\n' 'COOLIFY_API_TOKEN=Item=with=equals' >"$SB/equals"
run CLAUDE_BG_SECRETS="$SB/equals" -- x
check "an item name may hold an equals sign: the name ends at the first one" \
    'has "rbw get Item=with=equals" && has "session COOLIFY_API_TOKEN=eq-value"'

: >"$SB/emptytable"
run CLAUDE_BG_SECRETS="$SB/emptytable" -- x
check "an empty table loads nothing, says so, and still starts the session" \
    'says "starts without the tokens: the secret table names no secrets" && has "--bg x"'

printf '%s\n' 'EMPTY_API_TOKEN=Empty item' >"$SB/onlyempty"
run CLAUDE_BG_SECRETS="$SB/onlyempty" -- x
check "an item with an empty value is named and is not a token" \
    'says "EMPTY_API_TOKEN: the item is empty" && says "names no secrets" && has "session COOLIFY_API_TOKEN="'

run CLAUDE_BG_SECRETS="$SB/missing.env" PATH="$SB/nobin" -- x
check "without claude on the PATH it says so" '[[ $out == *"claude is not installed"* ]]'

printf '%s\n' 'DASH_API_TOKEN=Dash token' 'LINES_API_TOKEN=Lines token' >"$SB/odd"
rm -rf "$SB/proc"
proc 100 claude "claude daemon run" ""
printf '%s\0' 'DASH_API_TOKEN=-n' $'LINES_API_TOKEN=-e\nline2' >"$SB/proc/100/environ"
run CLAUDE_BG_SECRETS="$SB/odd" -- x
check "a supervisor holding a token that starts with a dash and one with a newline, byte for byte, is left alone" \
    '! has "daemon stop" && ! says "lacked" && has "--bg x"'
printf '%s\0' 'DASH_API_TOKEN=-n' $'LINES_API_TOKEN=-e\nline3' >"$SB/proc/100/environ"
run CLAUDE_BG_SECRETS="$SB/odd" -- x
check "a token that differs only after its first newline makes the supervisor stale" \
    'has "daemon stop --any --keep-workers" && says "lacked LINES_API_TOKEN" && ! says "lacked DASH_API_TOKEN"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
