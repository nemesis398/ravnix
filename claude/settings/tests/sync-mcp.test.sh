#!/usr/bin/env bash
# Tests for sync-mcp.sh, one directory up: the activation step that puts
# ravnix's MCP servers into Claude Code's user-scope config, keeps every
# server and every key it did not write, and removes the servers it wrote
# before and no longer declares.
#
# Each case writes a config file, a servers file and a state file into a
# directory of its own and runs the script on them; nothing outside that
# directory is read or written. The servers are made up (example.test is
# reserved for documentation), and so are the variables they name.
#
# Run:  bash sync-mcp.test.sh          (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

# The checks are strings that check evals, and jq filters, so their $ expand
# later.
# shellcheck disable=SC2016
set -uo pipefail

SELF=$(readlink -f "$0")
SYNC=${SELF%/*/*}/sync-mcp.sh
JQ_BIN=$(type -P jq) || { echo "the tests need jq, which is not installed" >&2; exit 2; }

pass=0
fail=0
CASE=""
RC=0 ERR=""

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'rc: %s\nstderr: %s\nfile: %s\nstate: %s\n' "$RC" "$ERR" "$(cat "$F" 2>/dev/null)" "$(cat "$T" 2>/dev/null)" | sed 's/^/       | /'; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sync-mcp-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

STORE=$ROOT/store
mkdir -p "$STORE"

# ravnix's servers as the module renders them: a bearer token and a plain
# value, both as references; the store holds nothing else.
OURS='{
  "alpha": {"type": "http", "url": "https://mcp.example.test/mcp",
            "headers": {"Authorization": "Bearer ${EXAMPLE_TOKEN}", "x-example": "${EXAMPLE_VALUE}"}},
  "beta": {"type": "stdio", "command": "example-mcp", "args": ["--flag", "x y"], "env": {"EXAMPLE": "${EXAMPLE_VALUE}"}}
}'

# A server that Claude Code added itself (`claude mcp add --scope user`).
ADDED='{"type": "http", "url": "https://added.example.test/mcp"}'

# A config as Claude Code leaves it: much besides the servers, a project
# with a server of its own (local scope), non-ASCII text and numbers.
CONFIG='{
  "numStartups": 322,
  "firstStartTime": "2026-01-01T00:00:00.000Z",
  "oauthAccount": {"emailAddress": "alice@example.test", "organizationRole": null},
  "cachedExtraUsageDisabledReason": 0.1,
  "projects": {
    "/home/alice/p": {
      "allowedTools": [],
      "history": [{"display": "ünï ✓ \"q\"", "pastedContents": {}}],
      "lastCost": 0.123456789,
      "mcpServers": {"local": {"type": "http", "url": "https://local.example.test"}}
    }
  },
  "mcpServers": {"added": '"$ADDED"'}
}'

# setup <config JSON or "none"> [<servers JSON> [<state JSON or "none">]]: a
# fresh case directory with .claude.json (none: no file), servers.json
# (default: OURS) and state.json (default: none, no file).
setup() {
    D=$(mktemp -d "$ROOT/case.XXXXXX")
    F=$D/.claude.json S=$D/servers.json T=$D/state/servers.json
    [[ $1 == none ]] || printf '%s\n' "$1" >"$F"
    printf '%s\n' "${2:-$OURS}" >"$S"
    if [[ ${3:-none} != none ]]; then mkdir -p "$D/state"; printf '%s\n' "$3" >"$T"; fi
}

# sync [file]: runs the script. Sets RC and ERR.
sync() {
    "$BASH" "$SYNC" "${1:-$F}" "$T" "$S" "$STORE" 2>"$D/err"
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

# refused <config file> <what it names>: passes when the script failed,
# named that file on stderr, and left the config and no temporary file.
refused() {
    if [[ $RC -ne 0 && $ERR == *"$2"* ]] && cmp -s "$F" "$D/before" && [[ -z $(find "$D" -name '.claude.json.*' -print -quit) ]]; then ok
    else bad "expected a failure that names $2 and leaves the config and no temporary file behind"; fi
}

# q <jq filter>: the filter's result on the config file, compact.
q() { "$JQ_BIN" -c "$1" "$F"; }
# servers: the names in the config's mcpServers, sorted, one per line.
servers() { "$JQ_BIN" -r '.mcpServers // {} | keys[]' "$F"; }
# state: the names in the state file, compact.
state() { "$JQ_BIN" -c . "$T"; }

echo "what it keeps"

setup "$CONFIG"
"$JQ_BIN" -S 'del(.mcpServers)' "$F" >"$D/rest-before"
sync
CASE="a server Claude Code added stays, ravnix's two join it, and no other key changes"
check '[[ $(servers | tr "\n" " ") == "added alpha beta " ]] &&
    [[ $(q ".mcpServers.added") == "$("$JQ_BIN" -c . <<<"$ADDED")" ]] &&
    "$JQ_BIN" -S "del(.mcpServers)" "$F" | cmp -s - "$D/rest-before"'

CASE="a project's own servers (local scope) are not touched"
check '[[ $(q ".projects[\"/home/alice/p\"].mcpServers | keys") == "[\"local\"]" ]]'

CASE="the servers are in the file as declared, references and all"
check '[[ $(q ".mcpServers.alpha") == "$("$JQ_BIN" -c .alpha <<<"$OURS")" && $(q ".mcpServers.beta") == "$("$JQ_BIN" -c .beta <<<"$OURS")" ]] &&
    [[ $(q ".mcpServers.alpha.headers.Authorization") == "\"Bearer \${EXAMPLE_TOKEN}\"" ]]'

CASE="the state file names the servers ravnix put in, and only those"
check '[[ $(state) == "[\"alpha\",\"beta\"]" ]]'

cp "$F" "$D/first"
sync
CASE="a second run changes nothing, byte for byte"
check 'cmp -s "$F" "$D/first"'

setup '{"mcpServers": {"alpha": {"type": "sse", "url": "https://old.example.test/sse", "headers": {"x-old": "1"}, "stale": true}, "added": '"$ADDED"'}}'
sync
CASE="a declared server replaces a same-named one whole, no key of the old one is left"
check '[[ $(q ".mcpServers.alpha") == "$("$JQ_BIN" -c .alpha <<<"$OURS")" && $(q ".mcpServers.added.url") == "\"https://added.example.test/mcp\"" ]]'

setup '{"mcpServers": {"added": '"$ADDED"', "zeta": {"type": "http", "url": "https://zeta.example.test"}}}'
sync
CASE="a server it did not write is left where it was, and a new one goes after it"
check '[[ $(q ".mcpServers | keys_unsorted | join(\" \")") == "\"added zeta alpha beta\"" ]]'

CASE="a name with a dot, a space, a quote and non-ASCII letters is one key like any other"
NAMES='{"a.b": {"type": "http", "url": "https://a.example.test"}, "with space": {"type": "http", "url": "https://b.example.test"}, "qu\"ote": {"type": "http", "url": "https://c.example.test"}, "ünï": {"type": "http", "url": "https://d.example.test"}, "__proto__": {"type": "http", "url": "https://e.example.test"}}'
setup '{"mcpServers": {}}' "$NAMES"
sync
check '[[ $(q ".mcpServers | length") == 5 && $(q ".mcpServers[\"qu\\\"ote\"].url") == "\"https://c.example.test\"" && $(q ".mcpServers[\"ünï\"].url") == "\"https://d.example.test\"" ]]'
cp "$F" "$D/first"
sync
CASE="and a second run with such names changes nothing"
check 'cmp -s "$F" "$D/first"'

echo "what it removes"

setup '{"mcpServers": {"alpha": {"type": "http", "url": "https://old.example.test"}, "gone": {"type": "http", "url": "https://gone.example.test"}, "added": '"$ADDED"'}}' "$OURS" '["alpha","gone"]'
sync
CASE="a server ravnix put in earlier and no longer declares goes; one it never wrote stays"
check '[[ $(servers | tr "\n" " ") == "added alpha beta " ]] && [[ $(state) == "[\"alpha\",\"beta\"]" ]]'

setup "$CONFIG" '{}' '["alpha","beta"]'
"$JQ_BIN" '.mcpServers += {"alpha": {"type": "http", "url": "https://old.example.test"}}' "$F" >"$D/x" && mv "$D/x" "$F"
sync
CASE="with nothing declared every server ravnix wrote goes, the state file empties and the others stay"
check '[[ $(servers) == added ]] && [[ $(state) == "[]" ]]'

setup '{"model": "x", "mcpServers": {"alpha": {"type": "http", "url": "https://old.example.test"}}}' '{}' '["alpha"]'
sync
CASE="when nothing is left, an empty mcpServers stays as Claude Code writes it"
check '[[ $(q ".mcpServers") == "{}" && $(q .model) == "\"x\"" ]]'

setup '{"model": "x"}' '{}'
cp "$F" "$D/before"
sync
CASE="nothing declared, nothing written before: the file is left byte for byte and no state file appears"
check 'cmp -s "$F" "$D/before" && [[ ! -e $T ]]'

setup "$CONFIG" '{}'
cp "$F" "$D/before"
sync
CASE="the same with servers of Claude Code's own in it"
check 'cmp -s "$F" "$D/before" && [[ ! -e $T ]]'

setup '{"mcpServers": {"alpha": '"$ADDED"'}}' "$OURS" '["gone"]'
sync
CASE="a name from the state that is not declared and not in the file is no trouble"
check '[[ $(servers | tr "\n" " ") == "alpha beta " ]] && [[ $(state) == "[\"alpha\",\"beta\"]" ]]'

setup "$CONFIG" "$OURS" '["alpha","beta"]'
"$JQ_BIN" '.mcpServers += $o[0]' --slurpfile o "$S" "$F" >"$D/x" && mv "$D/x" "$F"
cp "$F" "$D/before"
sync
CASE="a file that already holds the servers is left alone, and the state file is brought up to date"
check 'cmp -s "$F" "$D/before" && [[ $(state) == "[\"alpha\",\"beta\"]" ]]'

echo "the file"

setup none
sync
CASE="a missing file is made, with ravnix's servers only and mode 600"
check '[[ $(stat -c %a "$F") == 600 && $(q "keys") == "[\"mcpServers\"]" && $(servers | tr "\n" " ") == "alpha beta " ]]'

setup none '{}'
sync
CASE="a missing file with no servers to add stays missing, and so does the state file"
check '[[ ! -e $F && ! -e $T ]]'

setup none '{}' '["alpha"]'
sync
CASE="a missing file with only names to take out stays missing, and the state file empties"
check '[[ ! -e $F && $(state) == "[]" ]]'

setup ''
: >"$F"
sync
CASE="an empty file counts as {}"
check '[[ $(servers | tr "\n" " ") == "alpha beta " ]]'

setup '{"model": "x"}'
chmod 640 "$F"
sync
CASE="the file keeps its mode"
check '[[ $(stat -c %a "$F") == 640 ]]'

setup '{"model": "x"}'
mv "$F" "$D/real.json"; ln -s real.json "$F"
sync
CASE="a link outside the store: the file it names is updated, the link stays"
check '[[ -L $F && $(readlink "$F") == real.json && $("$JQ_BIN" -r ".mcpServers | keys | length" "$D/real.json") == 2 ]]'

setup none
printf '{"model": "x"}\n' >"$STORE/claude.json"; chmod 444 "$STORE/claude.json"
ln -s "$STORE/claude.json" "$F"
sync
CASE="a link into the store is left alone, and so is the state"
check '[[ -L $F && $(cat "$STORE/claude.json") == "{\"model\": \"x\"}" && ! -e $T ]]'

setup '{"model": "x"}'
mkdir "$D/bin"
# Only the rename onto the config fails; the state file's goes through.
printf '#!%s\ncase "$*" in *"%s") exit 1 ;; esac\nexec %s "$@"\n' "$BASH" "$F" "$(type -P mv)" >"$D/bin/mv"; chmod +x "$D/bin/mv"
# shellcheck disable=SC2034  # the check's eval reads it
inode=$(stat -c %i "$F")
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$T" "$S" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="when the rename fails (a file bind-mounted by impermanence), it is written in place"
check '[[ $(stat -c %i "$F") == "$inode" && $(servers | tr "\n" " ") == "alpha beta " && $(q .model) == "\"x\"" ]] &&
    [[ -z $(find "$D" -name ".claude.json.*" -print -quit) ]]'

big=$("$JQ_BIN" -cn '{projects: ([range(20000) | {key: "/home/alice/project-\(.)", value: {history: [{display: "prompt \(.)"}]}}] | from_entries)}')
setup "$big"
sync
CASE="a file far above the 128 KiB of one argument works"
check '[[ $(q ".projects | length") == 20000 && $(servers | tr "\n" " ") == "alpha beta " ]]'

hugeservers=$("$JQ_BIN" -cn '[range(3000) | {key: "server-\(.)", value: {type: "http", url: "https://s\(.).example.test/mcp", headers: {Authorization: "Bearer ${EXAMPLE_TOKEN}"}}}] | from_entries')
setup '{"model": "x"}' "$hugeservers"
sync
CASE="and so do thousands of servers, which no command line could hold"
check '[[ $(q ".mcpServers | length") == 3000 && $(state | "$JQ_BIN" "length") == 3000 ]]'

for bad_json in '{"model": ' '[1,2]' '"text"' '{"mcpServers": [1]}' '{"mcpServers": "none"}'; do
    setup "$bad_json"
    cp "$F" "$D/before"
    sync
    CASE="a config it cannot read ($bad_json) fails the step, names the file, and stays as it was"
    refused "$F" "$F"
done

echo "the state file"

for bad_state in '{"alpha": 1}' '[1]' '"alpha"' '["alpha",' ; do
    setup '{"model": "x"}' "$OURS" "$bad_state"
    cp "$F" "$D/before"
    sync
    CASE="a state file it cannot read ($bad_state) fails the step, names the state file, and leaves the config"
    refused "$F" "$T"
done

setup '{"model": "x"}' "$OURS" ''
: >"$T"
sync
CASE="an empty state file counts as no servers written before"
check '[[ $(servers | tr "\n" " ") == "alpha beta " && $(state) == "[\"alpha\",\"beta\"]" ]]'

setup '{"model": "x"}'
CASE="the directory of the state file is made when it is missing"
rm -rf "$D/state"
T=$D/deep/er/state.json
sync
check '[[ $(state) == "[\"alpha\",\"beta\"]" ]]'

echo "what it refuses to add"

for bad_servers in '[]' '"x"' '{"a": 1}' '{"a": null}' '{"a": []}' '{"a": {"type": "http"}, "b": "x"}'; do
    setup '{"model": "x"}' "$bad_servers"
    cp "$F" "$D/before"
    sync
    CASE="servers that are not an object of objects ($bad_servers) are refused, and the config stays"
    refused "$F" "$S"
done

echo "a writer at the same time"

setup '{"model": "x"}'
for _ in 1 2 3 4; do "$BASH" "$SYNC" "$F" "$T" "$S" "$STORE" 2>>"$D/err" & done
wait
RC=0 ERR=$(<"$D/err")
CASE="four runs at once leave one whole file, each server in it once, and no temporary file"
check '[[ $(servers | tr "\n" " ") == "alpha beta " && $(q .model) == "\"x\"" && $(state) == "[\"alpha\",\"beta\"]" ]] &&
    [[ -z $(find "$D" -name ".claude.json.*" -print -quit) && -z $(find "$D/state" -name "servers.json.*" -print -quit) ]]'

# A fake jq: the real one, and after the step's main filter has read the
# file, a write as Claude Code makes it, a whole new file moved into place.
# Every run of the filter writes once more while $D/writes counts below
# $1.
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
        printf '{"model": "x", "mcpServers": {"claude-%s": {"type": "http", "url": "https://c.example.test"}}}\n' \$n >"$F.claude"
        mv -f "$F.claude" "$F"
    fi ;;
esac
exit \$rc
EOF
    chmod +x "$D/bin/jq"
}

setup '{"model": "x"}'
fake_writer 1
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$T" "$S" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a write between its read and its rename is kept, and ravnix's servers go in on top of it"
check '[[ $(servers | tr "\n" " ") == "alpha beta claude-1 " ]]'

setup '{"model": "x"}'
fake_writer 99
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$T" "$S" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a file that changes at every try fails the step, keeps the other writer's last write, and records no name it never wrote"
if [[ $RC -ne 0 && $ERR == *"$F"*"changed"* ]] && [[ $(servers) == "claude-$(<"$D/writes")" ]] &&
    [[ -z $(find "$D" -name '.claude.json.*' -print -quit) ]] && [[ $(state) == '["alpha","beta"]' ]]; then ok
else bad "expected a failure that says the file changed, with the last foreign write in place, no temporary file, and the names recorded before the write (so that a later run can take them out)"; fi

setup none
fake_writer 1
PATH="$D/bin:$PATH" "$BASH" "$SYNC" "$F" "$T" "$S" "$STORE" 2>"$D/err"; RC=$? ERR=$(<"$D/err")
CASE="a file made by another writer after a missing one was read is kept too"
check '[[ $(servers | tr "\n" " ") == "alpha beta claude-1 " ]]'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
