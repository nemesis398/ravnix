#!/usr/bin/env bash
# Tests for sync-hooks.sh, one directory up: the activation step that puts
# ravnix's hook entries into Claude Code's settings file, keeps every entry
# it did not write, and removes the ones it wrote before and no longer does.
#
# Each case writes a settings file and an entries file into a directory of
# its own and runs the script on them; nothing outside that directory is
# read or written. The prefix that marks ravnix's commands is
# /home/alice/.claude/ravnix/, as the module passes it for that home.
#
# Run:  bash sync-hooks.test.sh          (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

# The checks are strings that check evals, and jq filters, so their $ expand
# later.
# shellcheck disable=SC2016
set -uo pipefail

SELF=$(readlink -f "$0")
SYNC=${SELF%/*/*}/sync-hooks.sh
JQ_BIN=$(type -P jq) || { echo "the tests need jq, which is not installed" >&2; exit 2; }

pass=0
fail=0
CASE=""
RC=0 ERR=""

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'rc: %s\nstderr: %s\nfile: %s\n' "$RC" "$ERR" "$(cat "$F" 2>/dev/null)" | sed 's/^/       | /'; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-hooks-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

P=/home/alice/.claude/ravnix/
STORE=$ROOT/store
mkdir -p "$STORE"

# The waits of the lock and of the tries, short: the defaults add up to
# about 20 s (cas.sh).
export RAVNIX_CAS_LOCK_DELAYS="0.02 0.02 0.02"
export RAVNIX_CAS_TRY_DELAYS="0.01 0.01 0.01 0.01"

# ravnix's entries as the module renders them now.
OURS='{
  "SessionStart": [{"hooks": [
    {"type": "command", "command": "/home/alice/.claude/ravnix/hooks/prune-claude-tmp", "timeout": 30},
    {"type": "command", "command": "/home/alice/.claude/ravnix/hooks/session-preflight", "timeout": 10}]}],
  "PreToolUse": [{"matcher": "WebSearch", "hooks": [
    {"type": "command", "command": "/home/alice/.claude/ravnix/hooks/web-route", "timeout": 5}]}],
  "WorktreeCreate": [{"hooks": [
    {"type": "command", "command": "/home/alice/.claude/ravnix/hooks/worktree-create", "timeout": 600}]}]
}'

# herdr's entry, as `herdr integration install claude` writes it.
HERDR='{"matcher": "^(startup|resume|clear|compact|fork)$", "hooks": [{"type": "command", "command": "bash '"'"'/home/alice/.config/herdr/integrations/claude/herdr-agent-state.sh'"'"' session", "timeout": 10}]}'
# An entry the user wired by hand.
MINE='{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-check"}]}'

# setup <settings JSON or "none"> [<entries JSON>]: a fresh case directory
# with settings.json (none: no file) and entries.json (default: OURS).
setup() {
    D=$(mktemp -d "$ROOT/case.XXXXXX")
    F=$D/settings.json E=$D/entries.json
    [[ $1 == none ]] || printf '%s\n' "$1" >"$F"
    printf '%s\n' "${2:-$OURS}" >"$E"
}

# sync [file]: runs the script. Sets RC and ERR.
sync() {
    "$BASH" "$SYNC" "${1:-$F}" "$P" "$E" "$STORE" 2>"$D/err"
    RC=$?
    ERR=$(<"$D/err")
}

# check <condition>: passes when the condition holds, the script exited 0
# and wrote nothing to stderr.
check() {
    if   [ "$RC" -ne 0 ]; then bad "expected exit 0"
    elif [ -n "$ERR" ];   then bad "expected nothing on stderr"
    elif ! eval "$1";     then bad "failed: $1"
    else ok; fi
}

# q <jq filter>: the filter's result on the settings file, compact.
q() { "$JQ_BIN" -c "$1" "$F"; }
# commands <event>: the commands of an event's hooks, in order, one per line.
commands() { "$JQ_BIN" -r --arg e "$1" '.hooks[$e] // [] | .[].hooks[].command' "$F"; }

echo "what it keeps"

setup '{"model": "opus", "env": {"A": "1"}, "permissions": {"allow": ["Bash(ls)"]},
        "hooks": {"SessionStart": ['"$HERDR"'], "PreToolUse": ['"$MINE"'],
                  "Stop": [{"hooks": [{"type": "command", "command": "stop.py"}]}]}}'
sync
CASE="herdr's SessionStart entry and a hand-wired one stay, and ravnix's join them"
check '[[ $(commands SessionStart) == "bash '"'"'/home/alice/.config/herdr/integrations/claude/herdr-agent-state.sh'"'"' session
/home/alice/.claude/ravnix/hooks/prune-claude-tmp
/home/alice/.claude/ravnix/hooks/session-preflight" ]] &&
    [[ $(q ".hooks.SessionStart[0].matcher") == "\"^(startup|resume|clear|compact|fork)$\"" ]] &&
    [[ $(commands PreToolUse) == "my-check
/home/alice/.claude/ravnix/hooks/web-route" ]]'

CASE="an event ravnix does not use, and every other key, are left as they were"
check '[[ $(commands Stop) == stop.py && $(q .model) == "\"opus\"" && $(q .env) == "{\"A\":\"1\"}" && $(q .permissions.allow) == "[\"Bash(ls)\"]" ]]'

cp "$F" "$D/first"
sync
CASE="a second run changes nothing: each entry is there once"
check 'cmp -s "$F" "$D/first" && [[ $(commands SessionStart | wc -l) == 3 ]]'

echo "what it removes"

setup '{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/prune-claude-tmp", "timeout": 30}]}],
  "WorktreeCreate": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/worktree-create", "timeout": 300}]}],
  "SubagentStop": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/worktree-subagent-stop", "timeout": 30}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/old-hook"}, {"type": "command", "command": "stop.py"}]}]}}'
sync
CASE="a stale ravnix entry goes, an event left empty goes, and a changed one is replaced"
check '[[ $(q ".hooks | has(\"SubagentStop\")") == false ]] && [[ $(commands Stop) == stop.py ]] &&
    [[ $(q "[.hooks.WorktreeCreate[].hooks[].timeout]") == "[600]" ]] && [[ $(commands SessionStart | wc -l) == 2 ]]'

setup '{"model": "opus", "hooks": {"SessionStart": ['"$HERDR"', {"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/prune-claude-tmp"}]}],
        "WorktreeCreate": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/worktree-create"}]}]}}' '{}'
sync
CASE="with no entries left (claude-skills or Claude Code off), every ravnix entry goes and herdr's stays"
check '[[ $(commands SessionStart) == "bash '"'"'/home/alice/.config/herdr/integrations/claude/herdr-agent-state.sh'"'"' session" ]] &&
    [[ $(q ".hooks | keys") == "[\"SessionStart\"]" && $(q .model) == "\"opus\"" ]]'

setup '{"hooks": {"WorktreeCreate": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix/hooks/worktree-create"}]}]}}' '{}'
sync
CASE="when nothing is left, the hooks key goes too"
check '[[ $(q "has(\"hooks\")") == false ]]'

echo "how it tells ravnix's entries"

setup '{"hooks": {"PreToolUse": [{"matcher": "WebSearch", "hooks": [
    {"type": "command", "command": "/home/alice/.claude/ravnix/hooks/web-route"},
    {"type": "command", "command": "log-search"}]}]}}'
sync
CASE="in a group of both, the hand-added hook stays and ravnix's is replaced"
check '[[ $(commands PreToolUse) == "log-search
/home/alice/.claude/ravnix/hooks/web-route" ]]'

setup '{"hooks": {"SessionStart": [
    {"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix-old/x"}]},
    {"hooks": [{"type": "command", "command": "bash /home/alice/.claude/ravnix/hooks/prune-claude-tmp"}]},
    {"hooks": [{"type": "prompt", "prompt": "/home/alice/.claude/ravnix/ is not a command"}]}]}}' '{}'
sync
CASE="only a command that starts with the ravnix directory is ravnix's"
check '[[ $(q "[.hooks.SessionStart[].hooks[] | .command // .prompt]") == "[\"/home/alice/.claude/ravnix-old/x\",\"bash /home/alice/.claude/ravnix/hooks/prune-claude-tmp\",\"/home/alice/.claude/ravnix/ is not a command\"]" ]]'

E2='{"SessionStart": [{"hooks": [{"type": "command", "command": "'"'"'/home/a b/.claude/ravnix/hooks/x'"'"'"}]}]}'
setup '{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "'"'"'/home/a b/.claude/ravnix/hooks/old'"'"'"}]}]}}' "$E2"
"$BASH" "$SYNC" "$F" "/home/a b/.claude/ravnix/" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a command quoted for a home with a space is ravnix's too"
check '[[ $(commands SessionStart) == "'"'"'/home/a b/.claude/ravnix/hooks/x'"'"'" ]]'

echo "the file"

setup none
sync
CASE="a missing file is made, with ravnix's entries only and mode 600"
check '[[ $(stat -c %a "$F") == 600 && $(commands SessionStart | wc -l) == 2 ]]'

setup none '{}'
sync
CASE="a missing file with no entries to add stays missing"
check '[[ ! -e $F ]]'

setup ''
: >"$F"
sync
CASE="an empty file counts as {}"
check '[[ $(commands SessionStart | wc -l) == 2 ]]'

setup '{"model": "opus"}'
chmod 640 "$F"
sync
CASE="the file keeps its mode"
check '[[ $(stat -c %a "$F") == 640 ]]'

setup '{"model": "opus"}'
mv "$F" "$D/real.json"; ln -s real.json "$F"
sync
CASE="a settings link outside the store: the file it names is updated, the link stays"
check '[[ -L $F && $(readlink "$F") == real.json && $("$JQ_BIN" -r .model "$D/real.json") == opus ]] &&
    [[ $("$JQ_BIN" "[.hooks.SessionStart[].hooks[]] | length" "$D/real.json") == 2 ]]'

setup none
printf '{"model": "opus"}\n' >"$STORE/settings.json"; chmod 444 "$STORE/settings.json"
ln -s "$STORE/settings.json" "$F"
sync
CASE="a settings link into the store is left alone: home-manager owns that file whole"
check '[[ -L $F && $(cat "$STORE/settings.json") == "{\"model\": \"opus\"}" ]]'

setup '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"stop.py"}]}]}}' '{}'
cp "$F" "$D/before"
sync
CASE="a file it has nothing to change in is left byte for byte, its own layout included"
check 'cmp -s "$F" "$D/before"'

setup '{"model": "opus", "hooks": {"SessionStart": ['"$HERDR"']}}'
for _ in 1 2 3 4; do "$BASH" "$SYNC" "$F" "$P" "$E" "$STORE" 2>>"$D/err" & done
wait
RC=0 ERR=$(<"$D/err")
CASE="four runs at once leave one whole file, each entry in it once, and no temporary file"
check '[[ $(commands SessionStart | wc -l) == 3 && $(q .model) == "\"opus\"" ]] &&
    [[ -z $(find "$D" -name "settings.json.*" -print -quit) ]]'

setup '{"model": "opus"}'
mkdir "$D/bin"; printf '#!%s\nexit 1\n' "$BASH" >"$D/bin/mv"; chmod +x "$D/bin/mv"
# shellcheck disable=SC2034  # the check's eval reads it
inode=$(stat -c %i "$F")
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$P" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="when the rename fails (a file bind-mounted by impermanence), it is written in place"
check '[[ $(stat -c %i "$F") == "$inode" && $(commands SessionStart | wc -l) == 2 && $(q .model) == "\"opus\"" ]] &&
    [[ -z $(find "$D" -name "settings.json.*" -print -quit) ]]'

big=$("$JQ_BIN" -cn '{permissions: {allow: [range(20000) | "Bash(cmd-\(.))"]}}')
setup "$big"
sync
CASE="a file far above the 128 KiB of one argument works"
check '[[ $(q ".permissions.allow | length") == 20000 && $(commands SessionStart | wc -l) == 2 ]]'

for bad_json in '{"model": ' '[1,2]' '"text"' '{"hooks": [1]}' '{"hooks": "none"}' $'\n  \n' '{"model": 1}{"b": 2}' $'{"model": 1}\n{"b": 2}\n'; do
    setup "$bad_json"
    cp "$F" "$D/before"
    sync
    CASE="settings it cannot read, or that are not one JSON document ($(printf '%s' "$bad_json" | tr '\n' ' ')), fail the step, name the file, and stay as they were"
    if [[ $RC -ne 0 && $ERR == *"$F"* ]] && cmp -s "$F" "$D/before" && [[ -z $(find "$D" -name 'settings.json.*' -print -quit) ]]; then ok
    else bad "expected a failure that names the file and leaves it and no temporary file behind"; fi
done

echo "what it refuses to add"

# Only ravnix's own hooks may be in ENTRIES: the step tells its own by the
# prefix, so any other hook would be added again at every run.
for ours_bad in \
    '{"Stop": [{"hooks": [{"type": "command", "command": "python3 -B \"$HOME/x.py\""}]}]}' \
    '{"Stop": [{"hooks": [{"type": "command", "command": "/home/alice/.claude/ravnix-old/x"}]}]}' \
    '{"Stop": [{"hooks": [{"type": "prompt", "prompt": "/home/alice/.claude/ravnix/x"}]}]}' \
    '{"Stop": [{"hooks": [{"type": "command"}]}]}' \
    '{"Stop": [{"hooks": []}]}' \
    '{"Stop": [{"matcher": "x"}]}' \
    '{"Stop": {"hooks": []}}' \
    '{"Stop": ["x"]}' \
    '[]'; do
    setup '{"model": "opus", "hooks": {"SessionStart": ['"$HERDR"']}}' "$ours_bad"
    cp "$F" "$D/before"
    sync
    CASE="entries that are not all ravnix's own hooks ($ours_bad) are refused, and the file stays"
    if [[ $RC -ne 0 && $ERR == *"$E"* ]] && cmp -s "$F" "$D/before" && [[ -z $(find "$D" -name 'settings.json.*' -print -quit) ]]; then ok
    else bad "expected a failure that names the entries file and leaves the settings and no temporary file behind"; fi
done

echo "a writer at the same time"

# A fake jq: the real one, and after the step's main filter has read the
# file, a write as Claude Code makes it, a whole new file moved into place.
# Every run of the filter writes once more while $D/writes counts below
# $LIMIT.
fake_writer() {
    mkdir -p "$D/bin"
    cat >"$D/bin/jq" <<EOF
#!$BASH
"$JQ_BIN" "\$@"; rc=\$?
case " \$* " in
*" --slurpfile ours "*)
    n=\$(( \$(cat "$D/writes" 2>/dev/null || echo 0) + 1 ))
    if (( n <= $1 )); then
        echo \$n >"$D/writes"
        printf '{"model": "opus", "permissions": {"allow": ["Bash(new-%s)"]}}\n' \$n >"$F.claude"
        mv -f "$F.claude" "$F"
    fi ;;
esac
exit \$rc
EOF
    chmod +x "$D/bin/jq"
}

setup '{"model": "opus"}'
fake_writer 1
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$P" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a write between its read and its rename is kept, and ravnix's hooks go in on top of it"
check '[[ $(q .permissions.allow) == "[\"Bash(new-1)\"]" && $(commands SessionStart | wc -l) == 2 ]]'

setup '{"model": "opus"}'
fake_writer 99
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$P" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a file that changes at every try fails the step, and keeps the other writer's last write"
if [[ $RC -ne 0 && $ERR == *"$F"*"changed"* ]] && [[ $(q .permissions.allow) == "[\"Bash(new-$(<"$D/writes"))\"]" && $(q 'has("hooks")') == false ]] &&
    [[ -z $(find "$D" -name 'settings.json.*' -print -quit) ]]; then ok
else bad "expected a failure that says the file changed, with the last foreign write in place and no temporary file"; fi

setup none
fake_writer 1
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$P" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a file made by another writer after a missing one was read is kept too"
check '[[ $(q .permissions.allow) == "[\"Bash(new-1)\"]" && $(commands SessionStart | wc -l) == 2 ]]'

echo "the lock beside the file"

# The same lock as Claude Code takes on its own config, a directory made with
# mkdir beside the file (cas.sh); it is taken here too, for every file the
# step writes.
setup '{"model": "opus"}'
sync
CASE="after a run that wrote there is no lock left"
check '[[ ! -e $F.lock && $(commands SessionStart | wc -l) == 2 ]]'

setup '{"model": "opus"}'
mkdir "$F.lock"
cp "$F" "$D/before"
sync
CASE="a lock that is fresh and never released: the step waits, fails without writing, names the lock, and leaves it"
if [[ $RC -ne 0 && $ERR == *"$F.lock"* && -d $F.lock ]] && cmp -s "$F" "$D/before" && [[ -z $(find "$D" -name 'settings.json.*' -not -name '*.lock' -print -quit) ]]; then ok
else bad "expected a failure that names the lock, with the settings as they were and the other writer's lock left"; fi

setup '{"model": "opus"}'
mkdir "$F.lock"; touch -d '1 minute ago' "$F.lock"
sync
CASE="a stale lock is taken over, and removed after"
check '[[ ! -e $F.lock && $(commands SessionStart | wc -l) == 2 ]]'

export RAVNIX_CAS_LOCK_DELAYS="0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1 0.1"
setup '{"model": "opus"}'
start=$(date +%s%N)
mkdir "$F.lock"
( sleep 0.5 && rmdir "$F.lock" ) &
holder=$!
sync
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
wait "$holder"
export RAVNIX_CAS_LOCK_DELAYS="0.02 0.02 0.02"
CASE="a lock that is released while the step waits: it waits for it (at least the 500 ms it was held, took ${elapsed} ms), then writes"
if [[ $RC -eq 0 && $ERR == "" && $elapsed -ge 500 && $(commands SessionStart | wc -l) == 2 && ! -e $F.lock ]]; then ok
else bad "expected the step to write only after the holder let go, at least 500 ms in, with no lock left"; fi

echo "what it needs beside it"

setup '{"model": "opus"}'
mkdir "$D/lonely"; cp "$SYNC" "$D/lonely/"
cp "$F" "$D/before"
"$BASH" "$D/lonely/sync-hooks.sh" "$F" "$P" "$E" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a step without cas.sh beside it fails and says so, and does not report success"
if [[ $RC -ne 0 && $ERR == *"cannot load cas.sh"* ]] && cmp -s "$F" "$D/before"; then ok
else bad "expected a failure that says cas.sh cannot be loaded, with the settings untouched"; fi

setup '{"model": "opus"}'
( cd "${SYNC%/*}" && "$BASH" sync-hooks.sh "$F" "$P" "$E" "$STORE" ) 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="run by its bare name from inside its own directory, it finds cas.sh"
check '[[ $(commands SessionStart | wc -l) == 2 ]]'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
