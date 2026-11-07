#!/usr/bin/env bash
# Tests for session-preflight.sh, one directory up.
#
# Why fixtures instead of a real session: the hook's whole contract is a tree
# of files under one root, whatever `netbird status --json` prints, and one
# JSON object or nothing on stdout. Driving the hook directly lets each case
# give it exactly the tree and the netbird it needs, and none of it touches
# the real ~/Nextcloud or the real mesh.
#
# The environment is built from nothing (env -i): HOME, TZ=UTC, the skill
# values in RAVNIX_SKILL_VALUES, and a PATH of two directories. The values
# file is written for each run: nextcloud.root is the case's tree,
# vault.root the vault in it, netbird.managementUrl and netbird.whenDown
# those below; VALUES=<file> gives a run another file instead, and
# VALUES=none none at all. One directory of the PATH holds links to
# the tools the hook uses (find, sort, jq, timeout, date) and nothing else, so
# a hook that starts calling another tool fails here first, with something on
# stderr. The other holds a stub netbird that prints a fixture; leaving it out
# of PATH is how "not installed" is simulated.
#
# Run:  bash session-preflight.test.sh     (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit. The two
# hanging-netbird cases take about 3 and 4 s, the rest well under a second.

set -uo pipefail

SELF=$(readlink -f "$0")
HOOK=${SELF%/*/*}/session-preflight.sh
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }
ENV_BIN=$(type -P env) || { echo "the tests need env, which is not installed" >&2; exit 2; }
JQ_BIN=$(type -P jq)   || { echo "the tests need jq, which is not installed" >&2; exit 2; }

pass=0
fail=0
CASE="" PROBLEMS=""
ERR="" RC=0 OUT="" SYS="" CTX="" ELAPSED=0

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'stdout: %s\nstderr: %s\n' "$(cat -v "$ROOT/out")" "$ERR" | sed 's/^/       | /'; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/session-preflight-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

# The tools the hook may call, with and without jq.
TOOLS=$ROOT/tools NO_JQ=$ROOT/no-jq STUBS=$ROOT/stubs
mkdir -p "$TOOLS" "$NO_JQ" "$STUBS" "$ROOT/home" "$ROOT/nb"
for tool in find sort jq timeout date; do
    bin=$(type -P "$tool") || { echo "the tests need $tool, which is not installed" >&2; exit 2; }
    ln -s "$bin" "$TOOLS/$tool"
    [ "$tool" = jq ] || ln -s "$bin" "$NO_JQ/$tool"
done

# The stub netbird: prints the file NB_OUT names (on stderr with NB_STDERR=1)
# and exits with NB_RC. NB_HANG=1 first waits in a child process, which would
# hold the hook's pipe open if timeout signaled netbird alone; NB_HANG=term
# also ignores SIGTERM, so only timeout's SIGKILL ends it.
{
    printf '#!%s\n' "$BASH"
    printf 'SLEEP=%q CAT=%q\n' "$(type -P sleep)" "$(type -P cat)"
    cat <<'EOF'
[ "$*" = "status --json" ] || { echo "stub netbird: unexpected arguments: $*" >&2; exit 2; }
case ${NB_HANG:-} in
    1)    "$SLEEP" 30 ;;
    term) trap '' TERM; "$SLEEP" 30 ;;
esac
if [ -n "${NB_OUT:-}" ]; then
    if [ -n "${NB_STDERR:-}" ]; then "$CAT" -- "$NB_OUT" >&2; else "$CAT" -- "$NB_OUT"; fi
fi
exit "${NB_RC:-0}"
EOF
} >"$STUBS/netbird"
chmod +x "$STUBS/netbird"

# What Claude Code 2.1.281 sends a SessionStart hook on stdin. The hook ignores it.
PAYLOAD='{"session_id":"5e55100e-0000-4000-8000-000000000001","transcript_path":"/home/alice/.claude/projects/-home-alice/5e55100e-0000-4000-8000-000000000001.jsonl","cwd":"/home/alice","hook_event_name":"SessionStart","source":"startup"}'

# The management server the fixtures' peer is enrolled with, and what fails
# while the mesh is down, as the skill values give them.
MESH=https://netbird.example.org:443
DOWN_NOTE='While the mesh is down, the deploy server refuses every request.'

# skill_values <root>: writes the values file of a run whose tree is <root>
# (none when <root> is empty), and prints its path.
# shellcheck disable=SC2016  # the $ are jq's
skill_values() {
    "$JQ_BIN" -n --arg nc "${1%/}" --arg mesh "$MESH" --arg note "$DOWN_NOTE" '
        (if $nc == "" then {} else {nextcloud: {root: $nc}, vault: {root: ($nc + "/Notes")}} end)
        + {netbird: {managementUrl: $mesh, whenDown: $note}}' >"$ROOT/values.json"
    printf '%s' "$ROOT/values.json"
}

# run_hook [VAR=value...]: runs the hook with the tool and stub directories on
# PATH, HOME, TZ=UTC, RAVNIX_SKILL_VALUES (see above), and the given pairs; a
# later PATH= or RAVNIX_SKILL_VALUES= overrides the default. Sets RC, OUT, ERR
# and ELAPSED (whole seconds, rounded up).
run_hook() {
    local t0 t1 values
    printf '%s' "$PAYLOAD" >"$ROOT/in"
    case ${VALUES:-} in
        "") values=$(skill_values "${NC:-}") ;;
        none) values=$ROOT/no-such-values.json ;;
        *) values=$VALUES ;;
    esac
    t0=$EPOCHREALTIME
    "$ENV_BIN" -i PATH="$TOOLS:$STUBS" HOME="$ROOT/home" TZ=UTC \
        RAVNIX_SKILL_VALUES="$values" "$@" "$BASH" "$HOOK" \
        <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
    t1=$EPOCHREALTIME
    ELAPSED=$(( (${t1//[.,]/} - ${t0//[.,]/} + 999999) / 1000000 ))
    OUT=$(<"$ROOT/out")
    ERR=$(<"$ROOT/err")
}

begin()   { CASE=$1; PROBLEMS=""; }
problem() { PROBLEMS+="${PROBLEMS:+; }$1"; }
verdict() { if [ -z "$PROBLEMS" ]; then ok; else bad "$PROBLEMS"; fi; }

# expect_silent: exit 0, nothing on stderr, and not one byte on stdout.
expect_silent() {
    [ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
    [ -z "$ERR" ]   || problem "expected nothing on stderr"
    [ -s "$ROOT/out" ] && problem "expected no output at all"
    verdict
}

# expect_json: exit 0, nothing on stderr, and stdout one line holding one
# object of exactly the SessionStart shape, with a one-line systemMessage and
# a context under 10,000 characters. Sets SYS and CTX. Does not give the
# verdict, so a case can add its own checks first.
expect_json() {
    SYS="" CTX=""
    [ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
    [ -z "$ERR" ]   || problem "expected nothing on stderr"
    if [ "$(wc -l <"$ROOT/out")" -ne 1 ]; then
        problem "expected exactly one line on stdout"
    elif ! "$JQ_BIN" -e '
        type == "object" and (keys == ["hookSpecificOutput", "systemMessage"])
        and (.systemMessage | type == "string" and length > 0 and (test("\n") | not))
        and (.hookSpecificOutput | keys == ["additionalContext", "hookEventName"])
        and .hookSpecificOutput.hookEventName == "SessionStart"
        and (.hookSpecificOutput.additionalContext | type == "string" and length <= 10000)' \
        "$ROOT/out" >/dev/null 2>&1; then
        problem "stdout is not one SessionStart object with a one-line systemMessage and a context of at most 10000 characters"
    else
        SYS=$("$JQ_BIN" -r .systemMessage "$ROOT/out")
        CTX=$("$JQ_BIN" -r .hookSpecificOutput.additionalContext "$ROOT/out")
    fi
}

sys_is()  { [ "$SYS" = "$1" ] || problem "systemMessage is \"$SYS\", expected \"$1\""; }
has()     { case $CTX in *"$1"*) ;; *) problem "context lacks \"$(printf '%s' "$1" | head -c 120 | cat -v)\"" ;; esac; }
lacks()   { case $CTX in *"$1"*) problem "context has \"$1\"" ;; esac; }
entries() { local n; n=$(grep -c '^- /' <<<"$CTX"); [ "$n" -eq "$1" ] || problem "expected $1 listed copies, got $n"; }

# mk <root> <relative path>...: creates empty files, and their folders.
mk() {
    local r=$1 p
    shift
    for p in "$@"; do
        mkdir -p -- "$r/$(dirname -- "$p")"
        : >"$r/$p"
    done
}

# --- the fixture trees ------------------------------------------------------------

STAMP='(conflicted copy 2026-09-24 101500)'

# CLEAN has originals, names that only look like conflicts, and conflicted
# copies in the folders the scan skips. Nothing in it may be reported.
CLEAN=$ROOT/clean/Nextcloud
clean_files=(
    "Notes/Work/Note.md"
    "Documents/Meeting (conflict).md"
    "memory/shop/conflict-resolution.md"
    "memory/notes/conflicted-copies-explained.md"
    "Dotfiles/repo/.git/objects/ab $STAMP"
    "Dotfiles/app/node_modules/pkg/index $STAMP.js"
    "Dotfiles/.claude/worktrees/w1/f $STAMP.md"
    "Dotfiles/tool/__pycache__/m_conflict-20200101-120000.pyc"
)
mk "$CLEAN" "${clean_files[@]}"

# FULL is CLEAN plus one conflicted copy of every shape.
FULL=$ROOT/full/Nextcloud
mk "$FULL" "${clean_files[@]}" \
    "Notes/Work/Note $STAMP.md" \
    "Dotfiles/stow/Makefile" "Dotfiles/stow/Makefile $STAMP" \
    "Dotfiles/.bashrc" "Dotfiles/.bashrc $STAMP" \
    "memory/set/m.md" "memory/set/m $STAMP.md" \
    "memory/set/m $STAMP (conflicted copy 2026-09-25 090000).md" \
    "Documents/report $STAMP.pdf" \
    "Documents/data.csv" "Documents/data_conflict-20200101-120000.csv" \
    "Documents/archive.tar.gz" "Documents/archive.tar_conflict-20200101-120000.gz" \
    "Documents/Readme.md" "Documents/Readme (case clash from 2026-09-24 101500).md" \
    "notes.txt" "notes $STAMP.txt"
FULL_SYS="10 Nextcloud conflicted copies: Documents 4, Dotfiles 2, vault 1, memory 2, Nextcloud 1"

# MANY has 30 copies in one folder, LONG 25 copies with names and folders
# long enough that 20 of them overflow the context limit.
MANY=$ROOT/many/Nextcloud
for i in $(seq -w 1 30); do mk "$MANY" "Dotfiles/many/f$i.md" "Dotfiles/many/f$i $STAMP.md"; done
LONG=$ROOT/long/Nextcloud
deep=$(printf 'd%.0s' {1..60})
deep="$deep/$deep/$deep/$deep/$deep/$deep/$deep/$deep"
for i in $(seq -w 1 25); do mk "$LONG" "Dotfiles/$deep/$(printf 'x%.0s' {1..190})$i $STAMP.md"; done

# CTRL has a name with a newline in it, HOME_NC a copy under the default root.
CTRL=$ROOT/ctrl/Nextcloud
mk "$CTRL" "Documents/a"$'\n'"b.md" "Documents/a"$'\n'"b $STAMP.md"
mk "$ROOT/home/Nextcloud" "memory/x $STAMP.md"

# --- the netbird fixtures ------------------------------------------------------------

# netbird status --json from 0.79.0 on a peer, 2026-09-24, trimmed.
NB_BASE='{"management":{"url":"https://netbird.example.org:443","connected":true,"error":""},"signal":{"url":"https://netbird.example.org:443","connected":true,"error":""},"sessionExpiresAt":"2026-09-25T11:18:46.802896359Z","daemonStatus":"Connected","daemonVersion":"0.79.0","cliVersion":"0.79.0","profileName":"default","fqdn":"huginn.example.org","peers":{"total":3,"connected":2}}'

# iso <seconds from now>: that time in RFC 3339 UTC, with nanoseconds as netbird prints it.
iso() { date -u -d "@$((EPOCHSECONDS + $1))" +%Y-%m-%dT%H:%M:%S.802896359Z; }
# at <seconds from now> <format>: that time in UTC in the given date format.
at() { TZ=UTC date -d "@$((EPOCHSECONDS + $1))" "+$2"; }

# fixture <name> <text>: writes a netbird output and prints its path.
fixture() { printf '%s\n' "$2" >"$ROOT/nb/$1"; printf '%s' "$ROOT/nb/$1"; }
# nb <name> <jq filter>: NB_BASE with the filter applied, as a fixture.
nb() { fixture "$1" "$("$JQ_BIN" -c "$2" <<<"$NB_BASE")"; }

HEALTHY=$(nb healthy ".sessionExpiresAt = \"$(iso 72000)\"")
NEEDS_LOGIN=$(fixture needs-login 'Daemon status: NeedsLogin

Run UP command to log in with SSO (interactive login):

 netbird up

If you are running a self-hosted version and no SSO provider has been configured in your Management Server,
you can use a setup-key:

 netbird up --management-url <YOUR_MANAGEMENT_URL> --setup-key <YOUR_SETUP_KEY>
')

LOGIN_SYS="NetBird needs a login (NeedsLogin): run netbird up --management-url $MESH"

# --- conflicted copies ------------------------------------------------------------------

echo "conflicted copies"

begin "originals, look-alike names, and copies inside .git, node_modules, __pycache__ and .claude/worktrees print nothing"
NC=$CLEAN run_hook NB_OUT="$HEALTHY"
expect_silent

begin "every shape of copy is listed with its original, and the summary counts them per tree"
NC=$FULL run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "$FULL_SYS"
entries 10
has "- $FULL/Notes/Work/Note $STAMP.md"$'\n'"  original: Note.md"
has "- $FULL/Dotfiles/stow/Makefile $STAMP"$'\n'"  original: Makefile"
has "- $FULL/Dotfiles/.bashrc $STAMP"$'\n'"  original: .bashrc"
has "- $FULL/memory/set/m $STAMP.md"$'\n'"  original: m.md"
has "- $FULL/memory/set/m $STAMP (conflicted copy 2026-09-25 090000).md"$'\n'"  original: m $STAMP.md, itself a conflicted copy"
has "- $FULL/Documents/report $STAMP.pdf"$'\n'"  original missing: report.pdf"
has "- $FULL/Documents/data_conflict-20200101-120000.csv"$'\n'"  original: data.csv"
has "- $FULL/Documents/archive.tar_conflict-20200101-120000.gz"$'\n'"  original: archive.tar.gz"
has "- $FULL/Documents/Readme (case clash from 2026-09-24 101500).md"$'\n'"  original: Readme.md"
has "- $FULL/notes $STAMP.txt"$'\n'"  original: notes.txt"
for skip in conflict-resolution conflicted-copies-explained "Meeting (conflict)" \
    /.git/ node_modules __pycache__ .claude/worktrees "more; this lists"; do
    lacks "$skip"
done
verdict

begin "the context says which side is which and how to resolve without losing the server's version"
NC=$FULL run_hook NB_OUT="$HEALTHY"
expect_json
has "The conflicted copy holds this machine's version and was never uploaded"
has "the original, in the same folder, holds the server's version"
has "remove only the conflicted copy, never the original"
has "Raise them with the user before you work in those trees"
has "In the vault ($FULL/Notes) change nothing without the user's go-ahead."
has "Where the original is missing, the copy may hold the only version"
verdict

begin "a trailing slash on the root changes nothing"
NC=$FULL/ run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "$FULL_SYS"
entries 10
verdict

begin "one copy is counted in the singular"
NC=$CTRL run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "1 Nextcloud conflicted copy: Documents 1"
verdict

begin "a newline in a name is shown as ?, so a name cannot add lines to the context"
NC=$CTRL run_hook NB_OUT="$HEALTHY"
expect_json
has "- $CTRL/Documents/a?b $STAMP.md"$'\n'"  original: a?b.md"
[ "$(wc -l <<<"$CTX" | tr -d ' ')" -eq "$(( $(wc -l <<<"${CTX%%$'\n- '*}") + 2 ))" ] ||
    problem "the list has more than two lines for one copy"
verdict

begin "30 copies: 20 are listed, the rest counted, and the summary has all 30"
NC=$MANY run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "30 Nextcloud conflicted copies: Dotfiles 30"
entries 20
has "- and 10 more; this lists them all: find $MANY -name"
has "- $MANY/Dotfiles/many/f20 $STAMP.md"
lacks "f21 $STAMP"
verdict

begin "20 very long paths are cut to the context limit, after the instructions and the summary"
NC=$LONG run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "25 Nextcloud conflicted copies: Dotfiles 25"
has "never the original"
case $CTX in *$'\n[cut here to stay under the hook context limit]') ;; *) problem "the context does not end with the cut note" ;; esac
[ "${#CTX}" -le 10000 ] || problem "context is ${#CTX} characters"
verdict

begin "PREFLIGHT_NEXTCLOUD_ROOT wins over nextcloud.root"
NC=$CLEAN run_hook NB_OUT="$HEALTHY" PREFLIGHT_NEXTCLOUD_ROOT="$ROOT/home/Nextcloud"
expect_json
sys_is "1 Nextcloud conflicted copy: memory 1"
has "- $ROOT/home/Nextcloud/memory/x $STAMP.md"
verdict

begin "with neither PREFLIGHT_NEXTCLOUD_ROOT nor nextcloud.root nothing is scanned, not even ~/Nextcloud"
NC="" run_hook NB_OUT="$HEALTHY"
expect_silent

begin "without any skill values nothing is scanned"
NC=$FULL VALUES=none run_hook NB_OUT="$HEALTHY"
expect_silent

begin "the values are read from ~/.config/ravnix/skill-values.json without RAVNIX_SKILL_VALUES"
mkdir -p "$ROOT/home/.config/ravnix"
skill_values "$FULL" >/dev/null
cp "$ROOT/values.json" "$ROOT/home/.config/ravnix/skill-values.json"
printf '%s' "$PAYLOAD" >"$ROOT/in"
"$ENV_BIN" -i PATH="$TOOLS:$STUBS" HOME="$ROOT/home" TZ=UTC NB_OUT="$HEALTHY" "$BASH" "$HOOK" \
    <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
RC=$? OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
expect_json
sys_is "$FULL_SYS"
verdict

begin "and from XDG_CONFIG_HOME when it is set"
"$ENV_BIN" -i PATH="$TOOLS:$STUBS" HOME="$ROOT/home" TZ=UTC NB_OUT="$HEALTHY" XDG_CONFIG_HOME="$ROOT/elsewhere" \
    "$BASH" "$HOOK" <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
RC=$? ERR=$(<"$ROOT/err")
expect_silent
rm -r -- "$ROOT/home/.config"

for bad_values in 'not json' '[1,2]' '{"nextcloud":"x"}' '{"nextcloud":{"root":42}}' '{"nextcloud":{"root":["/"]}}'; do
    begin "skill values without a usable root ($bad_values) scan nothing"
    printf '%s\n' "$bad_values" >"$ROOT/bad-values.json"
    NC=$FULL VALUES=$ROOT/bad-values.json run_hook NB_OUT="$HEALTHY"
    expect_silent
done

begin "without vault.root the vault's copies count under their folder, and the vault rule is left out"
"$JQ_BIN" 'del(.vault)' "$(skill_values "$FULL")" >"$ROOT/no-vault.json"
NC=$FULL VALUES=$ROOT/no-vault.json run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "10 Nextcloud conflicted copies: Documents 4, Dotfiles 2, Notes 1, memory 2, Nextcloud 1"
lacks "In the vault"
has "remove only the conflicted copy, never the original"
verdict

begin "vault.rule replaces the vault's default rule, on one line"
"$JQ_BIN" '.vault.rule = "Delete a note only with the vault tool,\nnever with rm."' "$(skill_values "$FULL")" >"$ROOT/rule-vault.json"
NC=$FULL VALUES=$ROOT/rule-vault.json run_hook NB_OUT="$HEALTHY"
expect_json
has "In the vault ($FULL/Notes): Delete a note only with the vault tool, never with rm."
lacks "change nothing without the user's go-ahead"
verdict

for bad_rule in 42 '""' '["x"]' null; do
    begin "a vault.rule that is no text ($bad_rule) leaves the default rule"
    # shellcheck disable=SC2016  # the $r is jq's
    "$JQ_BIN" --argjson r "$bad_rule" '.vault.rule = $r' "$(skill_values "$FULL")" >"$ROOT/bad-rule.json"
    NC=$FULL VALUES=$ROOT/bad-rule.json run_hook NB_OUT="$HEALTHY"
    expect_json
    has "In the vault ($FULL/Notes) change nothing without the user's go-ahead."
    verdict
done

begin "a vault.root with a trailing slash is the same vault"
"$JQ_BIN" '.vault.root += "/"' "$(skill_values "$FULL")" >"$ROOT/slash-vault.json"
NC=$FULL VALUES=$ROOT/slash-vault.json run_hook NB_OUT="$HEALTHY"
expect_json
sys_is "$FULL_SYS"
verdict

begin "a root that does not exist prints nothing"
NC=$ROOT/nowhere/Nextcloud run_hook NB_OUT="$HEALTHY"
expect_silent

begin "without jq the skill values cannot be read, so nothing is scanned"
NC=$FULL run_hook NB_OUT="$HEALTHY" PATH="$NO_JQ:$STUBS"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ -z "$ERR" ]   || problem "expected nothing on stderr"
case $OUT in *"conflicted"*) problem "it scanned without the values" ;; esac
verdict

begin "without jq only PREFLIGHT_NEXTCLOUD_ROOT is read, and the conflicts still reach the model, as plain text"
NC=$FULL run_hook NB_OUT="$HEALTHY" PATH="$NO_JQ:$STUBS" PREFLIGHT_NEXTCLOUD_ROOT="$FULL"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ -z "$ERR" ]   || problem "expected nothing on stderr"
CTX=$OUT
case $OUT in "Session preflight, a SessionStart hook"*) ;; *) problem "stdout is not the plain context" ;; esac
entries 10
has "NetBird: cannot tell whether the mesh is up: jq is not installed"
verdict

# --- NetBird ---------------------------------------------------------------------------

echo "NetBird"
NC=$CLEAN

begin "connected, with the session ending in 20 h, prints nothing"
run_hook NB_OUT="$HEALTHY"
expect_silent

begin "stdin closed instead of the payload changes nothing"
"$ENV_BIN" -i PATH="$TOOLS:$STUBS" HOME="$ROOT/home" TZ=UTC RAVNIX_SKILL_VALUES="$(skill_values "$CLEAN")" \
    NB_OUT="$HEALTHY" "$BASH" "$HOOK" <&- >"$ROOT/out" 2>"$ROOT/err"
RC=$? ERR=$(<"$ROOT/err")
expect_silent

begin "the session ending in 50 min warns with the local time, and netbird login --extend as the fix"
run_hook NB_OUT="$(nb soon ".sessionExpiresAt = \"$(iso 3000)\"")"
expect_json
sys_is "NetBird session ends at $(at 3000 %H:%M) (in 50 min): run netbird login --extend"
has "NetBird: this machine's SSO session ends at $(at 3000 '%H:%M UTC'), in 50 min, and the mesh goes down with it."
has 'the deploy server refuses every request'
has "\`netbird login --extend\` renews the session for another 24 h without dropping the tunnel; \`netbird up\` does not, even after \`netbird down\`."
has "ask the user to run it"
lacks "Nextcloud conflicted"
verdict

begin "the session ending in 1 h 30 min warns in hours and minutes"
run_hook NB_OUT="$(nb soon90 ".sessionExpiresAt = \"$(iso 5400)\"")"
expect_json
sys_is "NetBird session ends at $(at 5400 %H:%M) (in 1 h 30 min): run netbird login --extend"
verdict

begin "the session ending in exactly 1 h says 1 h"
run_hook NB_OUT="$(nb soon60 ".sessionExpiresAt = \"$(iso 3600)\"")"
expect_json
sys_is "NetBird session ends at $(at 3600 %H:%M) (in 1 h): run netbird login --extend"
verdict

begin "the session ending in 1 h 55 min warns, just inside 2 h"
run_hook NB_OUT="$(nb edge-in ".sessionExpiresAt = \"$(iso 6900)\"")"
expect_json
sys_is "NetBird session ends at $(at 6900 %H:%M) (in 1 h 55 min): run netbird login --extend"
verdict

begin "the session ending in 2 h 5 min prints nothing yet"
run_hook NB_OUT="$(nb edge-out ".sessionExpiresAt = \"$(iso 7500)\"")"
expect_silent

begin "an expiry with a +02:00 offset is read as the same instant"
run_hook NB_OUT="$(nb offset ".sessionExpiresAt = \"$(TZ=Etc/GMT-2 date -d "@$((EPOCHSECONDS + 3000))" +%Y-%m-%dT%H:%M:%S.5+02:00)\"")"
expect_json
sys_is "NetBird session ends at $(at 3000 %H:%M) (in 50 min): run netbird login --extend"
verdict

begin "a session that ended an hour ago counts as not connected"
run_hook NB_OUT="$(nb expired ".sessionExpiresAt = \"$(iso -3600)\"")"
expect_json
sys_is "NetBird down: run netbird up"
has "NetBird: this machine is off the mesh (its SSO session ended at $(at -3600 '%Y-%m-%d %H:%M UTC'))."
has "The fix is \`netbird up\`."
verdict

begin "management not connected warns with the daemon status and the error"
run_hook NB_OUT="$(nb down '.management.connected = false | .management.error = "context deadline exceeded" | .signal.connected = false | .daemonStatus = "Idle"')"
expect_json
sys_is "NetBird down: run netbird up"
has "off the mesh (management server not connected; daemon status Idle; error: context deadline exceeded)"
has "While the mesh is down, the deploy server refuses every request."
verdict

begin "not connected wins over a session that has hours left"
run_hook NB_OUT="$(nb down-far ".management.connected = false | .sessionExpiresAt = \"$(iso 72000)\"")"
expect_json
sys_is "NetBird down: run netbird up"
verdict

begin "NeedsLogin prose on stderr, as cobra prints it, warns with the full management URL"
run_hook NB_OUT="$NEEDS_LOGIN" NB_STDERR=1 NB_RC=0
expect_json
sys_is "$LOGIN_SYS"
has "the daemon reports NeedsLogin"
has "\`netbird up --management-url https://netbird.example.org:443\`"
has "https://api.netbird.io:443, the default"
verdict

begin "NeedsLogin prose on stdout warns the same way"
run_hook NB_OUT="$NEEDS_LOGIN" NB_RC=1
expect_json
sys_is "$LOGIN_SYS"
verdict

begin "connected to another management server warns with that server"
run_hook NB_OUT="$(nb wrong '.management.url = "https://api.netbird.io:443" | .signal.url = "https://signal.netbird.io:443"')"
expect_json
sys_is "NetBird on the wrong server: https://api.netbird.io:443"
has "enrolled with https://api.netbird.io:443, not with https://netbird.example.org:443"
has "\`netbird down\`, then \`netbird up --management-url https://netbird.example.org:443\`"
verdict

begin "the wrong server wins over not connected, since a bare netbird up would reconnect to it"
run_hook NB_OUT="$(nb wrong-down '.management.url = "https://api.netbird.io:443" | .management.connected = false')"
expect_json
sys_is "NetBird on the wrong server: https://api.netbird.io:443"
verdict

begin "the right server without its port or with a trailing slash prints nothing"
run_hook NB_OUT="$(nb noport ".management.url = \"https://netbird.example.org/\" | .sessionExpiresAt = \"$(iso 72000)\"")"
expect_silent

begin "a netbird.managementUrl without its port matches the peer's server with :443"
"$JQ_BIN" '.netbird.managementUrl = "https://netbird.example.org"' "$(skill_values "$CLEAN")" >"$ROOT/noport-value.json"
VALUES=$ROOT/noport-value.json run_hook NB_OUT="$(nb withport ".sessionExpiresAt = \"$(iso 72000)\"")"
expect_silent

for form in '""' '"0001-01-01T00:00:00Z"' 'null' 'del'; do
    begin "a setup-key peer, sessionExpiresAt $form, prints nothing"
    if [ "$form" = del ]; then filter='del(.sessionExpiresAt)'; else filter=".sessionExpiresAt = $form"; fi
    run_hook NB_OUT="$(nb setup-key "$filter")"
    expect_silent
done

begin "without netbird.whenDown the warning says nothing of what fails"
"$JQ_BIN" 'del(.netbird.whenDown)' "$(skill_values "$CLEAN")" >"$ROOT/no-note.json"
VALUES=$ROOT/no-note.json run_hook NB_OUT="$(nb down-nonote '.management.connected = false')"
expect_json
sys_is "NetBird down: run netbird up"
lacks "refuses every request"
has "The fix is \`netbird up\`."
verdict

begin "without netbird.managementUrl a peer on any server is not called wrong"
"$JQ_BIN" 'del(.netbird.managementUrl)' "$(skill_values "$CLEAN")" >"$ROOT/no-mesh.json"
VALUES=$ROOT/no-mesh.json run_hook NB_OUT="$(nb any-server ".management.url = \"https://api.netbird.io:443\" | .sessionExpiresAt = \"$(iso 72000)\"")"
expect_silent

begin "without netbird.managementUrl NeedsLogin names no server, and says which value to set"
VALUES=$ROOT/no-mesh.json run_hook NB_OUT="$NEEDS_LOGIN" NB_RC=1
expect_json
sys_is "NetBird needs a login (NeedsLogin): run netbird up --management-url <your server>"
has "https://api.netbird.io:443, the default"
has "netbird.managementUrl"
lacks "netbird.example.org"
verdict

begin "netbird not installed prints nothing"
run_hook PATH="$TOOLS"
expect_silent

# --- netbird output it cannot read -----------------------------------------------

echo "netbird output it cannot read"

begin "a netbird that hangs is cut off after 3 s with a mild note, not an alarm"
run_hook NB_OUT="$HEALTHY" NB_HANG=1
expect_json
sys_is "NetBird state unknown (status timed out)"
has "did not answer within 3 s"
has "Nothing is known to be wrong."
[ "$ELAPSED" -ge 3 ] || problem "returned after $ELAPSED s, before the 3 s timeout could fire"
[ "$ELAPSED" -le 5 ] || problem "took $ELAPSED s"
verdict

begin "a netbird that ignores SIGTERM is killed a second later"
run_hook NB_OUT="$HEALTHY" NB_HANG=term
expect_json
sys_is "NetBird state unknown (status timed out)"
[ "$ELAPSED" -ge 4 ] || problem "returned after $ELAPSED s, before SIGKILL could fire"
[ "$ELAPSED" -le 6 ] || problem "took $ELAPSED s"
verdict

begin "truncated JSON is a mild note quoting the first line"
run_hook NB_OUT="$(fixture truncated '{"management":{"url":"https://netbird.example.org:443","connected":tr')"
expect_json
sys_is "NetBird state unknown (status unreadable)"
has 'printed no usable JSON (exit 0, first line: {"management":'
has "Nothing is known to be wrong."
lacks "off the mesh"
verdict

begin "the daemon's error text is quoted, with its exit code"
run_hook NB_OUT="$(fixture no-daemon 'Error: failed to connect to daemon error: context deadline exceeded
If the daemon is not running please run:
netbird service install
netbird service start')" NB_STDERR=1 NB_RC=1
expect_json
sys_is "NetBird state unknown (status unreadable)"
has "(exit 1, first line: Error: failed to connect to daemon error: context deadline exceeded)"
verdict

begin "no output at all is a mild note"
run_hook NB_RC=1
expect_json
sys_is "NetBird state unknown (status unreadable)"
has "printed nothing (exit 1)"
verdict

for bad_json in '[1,2]' '"Connected"' '{"management":{"connected":"true","url":"https://netbird.example.org:443"}}' '{"management":null}'; do
    begin "JSON of the wrong shape ($bad_json) is a mild note"
    run_hook NB_OUT="$(fixture shape "$bad_json")"
    expect_json
    sys_is "NetBird state unknown (status unreadable)"
    verdict
done

begin "an expiry that is not RFC 3339 (tomorrow) is a mild note, not an alarm"
run_hook NB_OUT="$(nb tomorrow '.sessionExpiresAt = "tomorrow"')"
expect_json
sys_is "NetBird state unknown (session end unreadable)"
has 'sessionExpiresAt is "tomorrow"'
verdict

begin "an expiry that looks like RFC 3339 but is no date is a mild note"
run_hook NB_OUT="$(nb baddate '.sessionExpiresAt = "2026-13-45T99:99:99Z"')"
expect_json
sys_is "NetBird state unknown (session end unreadable)"
verdict

# --- both at once -------------------------------------------------------------------

echo "both at once"

begin "conflicts and an ending session share one line, NetBird first in the context"
NC=$FULL run_hook NB_OUT="$(nb both ".sessionExpiresAt = \"$(iso 3000)\"")"
expect_json
sys_is "$FULL_SYS · NetBird session ends at $(at 3000 %H:%M) (in 50 min): run netbird login --extend"
nb_at=${CTX%%NetBird: this machine*} cf_at=${CTX%%Nextcloud conflicted copies:*}
[ "${#nb_at}" -lt "${#cf_at}" ] || problem "the conflict list is not last"
entries 10
verdict

# --- summary ----------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
