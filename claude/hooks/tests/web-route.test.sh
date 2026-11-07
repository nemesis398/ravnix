#!/usr/bin/env bash
# Tests for web-route.sh, one directory up: the PreToolUse hook that sends
# WebSearch to `searx` while SearXNG answers.
#
# The SearXNG base URL is SEARXNG_URL, else web.searxngUrl from the ravnix
# skill values (RAVNIX_SKILL_VALUES, else
# ${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json); the cases below
# set SEARXNG_URL unless they test the values.
#
# Why a fake server: the hook's contract is JSON on stdin, either one JSON line
# or nothing on stdout, exit 0 always, and a probe that is cached, bounded and
# fails open. A small Python server on 127.0.0.1 plays /healthz and obeys a
# mode file (answer 200, answer 204, answer 500, answer 404, or never finish),
# and logs every request line, so a case can count probes. Nothing leaves the
# machine, and the user's real state directory is never read: XDG_STATE_HOME
# points into the sandbox.
#
# The hook runs with a PATH of links to the tools it may use and nothing else,
# plus a `searx` stub. That is how a missing curl, jq or searx is simulated,
# and a hook that starts calling an unlisted tool fails here first. The cache
# is forged by writing its one line by hand, which is why the hook keeps the
# epoch in the file: no case has to wait a minute.
#
# The hang case holds the probe open and asserts a lower bound on the elapsed
# time. A refused port fails at once and would pass whatever the limit was.
#
# Run:  bash web-route.test.sh          (exit 0 = all green)
# WEB_ROUTE_UNDER_TEST=<file> tests another copy, for mutation runs.
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

# The checks are eval'd, so their $ expand at check time, and the variables
# they read look unused to shellcheck.
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SELF=$(readlink -f "$0")
HOOK=${WEB_ROUTE_UNDER_TEST:-${SELF%/*/*}/web-route.sh}
HOOK=$(readlink -f "$HOOK")
[ -f "$HOOK" ] || { echo "missing $HOOK" >&2; exit 2; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/web-route-test.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$SB"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

# --- the sandbox -----------------------------------------------------------

SYS=$SB/sys STUBS=$SB/stubs
mkdir -p "$SYS" "$STUBS" "$SB/home/.local/bin" "$SB/state"
for t in bash env curl jq mkdir mv rm; do
    p=$(type -P "$t") || { echo "the tests need $t, which is not installed" >&2; exit 2; }
    ln -s "$p" "$SYS/$t"
done
type -P python3 >/dev/null || { echo "the tests need python3" >&2; exit 2; }
# The stubs start with the bash that runs the tests: the Nix build sandbox
# has no /usr/bin/env.
{ printf '#!%s\n' "$BASH"; cat <<'EOF'
printf '%s' "$1" >"$ARGV_OUT"
EOF
} >"$STUBS/searx"
chmod +x "$STUBS/searx"

cat >"$SB/server.py" <<'EOF'
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG, MODE, PORTFILE = sys.argv[1:4]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with open(LOG, "a") as f:
            f.write(self.requestline + "\n")
        mode = open(MODE).read().strip()
        if mode == "hang":
            time.sleep(30)
        code = {"up": 200, "no-content": 204, "500": 500, "404": 404}.get(mode, 200)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
EOF
: >"$SB/probes.log"
echo up >"$SB/mode"
python3 -I "$SB/server.py" "$SB/probes.log" "$SB/mode" "$SB/port" &
SERVER_PID=$!
for _ in $(seq 100); do [ -s "$SB/port" ] && break; sleep 0.05; done
[ -s "$SB/port" ] || { echo "the fake server did not start" >&2; exit 2; }
URL=http://127.0.0.1:$(<"$SB/port")
DEAD=http://127.0.0.1:$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

CACHE=$SB/state/web-route/reachable
now() { printf '%(%s)T' -1; }
mode() { echo "$1" >"$SB/mode"; }
probes() { wc -l <"$SB/probes.log"; }
forge() { mkdir -p "$SB/state/web-route"; printf '%s\n' "$1" >"$CACHE"; }
reset() { rm -rf "$SB/state/web-route"; mode up; : >"$SB/probes.log"; }

# call JSON: the hook with the usual sandbox, JSON on stdin.
# run [ENV=VAL ...] -- JSON: the same with extra environment. Sets $out, $err,
# $rc and $ms (how long the hook took, in milliseconds).
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    local t0=${EPOCHREALTIME//[.,]/}
    out=$(printf '%s' "$1" | env -i HOME="$SB/home" PATH="$STUBS:$SYS" \
        XDG_STATE_HOME="$SB/state" SEARXNG_URL="$URL" ARGV_OUT="$SB/argv" \
        "${envs[@]}" bash "$HOOK" 2>"$SB/err")
    rc=$?
    ms=$(((${EPOCHREALTIME//[.,]/} - t0) / 1000))
    err=$(<"$SB/err")
}
search() { jq -nc --arg q "$1" '{hook_event_name: "PreToolUse", tool_name: "WebSearch", tool_input: {query: $q}}'; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc  ms: $ms
    out: $out
    err: $err
    cache: $(cat "$CACHE" 2>/dev/null)  probes: $(probes)"; fi; }
silent() { [[ $rc == 0 && -z $out && -z $err ]]; }

echo "web-route"

reset
run -- "$(search 'react hooks best practices')"
check "SearXNG up: the call is denied in the PreToolUse format" \
    '[[ $rc == 0 && -z $err ]] && jq -e ".hookSpecificOutput | .hookEventName == \"PreToolUse\" and .permissionDecision == \"deny\"" >/dev/null <<<"$out"'
check "the output is one JSON line and nothing else" '[[ $(wc -l <<<"$out") == 1 ]] && jq -e . >/dev/null <<<"$out"'
check "the reason tells the model to run searx through Bash with the same query" \
    '[[ $(reason) == *"Run this through Bash instead:"* && $(reason) == *"  searx '"'"'react hooks best practices'"'"'"* ]]'
check "the reason says what to do when searx itself fails" '[[ $(reason) == *"If searx exits 2"* ]]'
check "the probe went to /healthz" '[[ $(probes) == 1 && $(<"$SB/probes.log") == "GET /healthz "* ]]'
check "the answer is cached with its epoch" '[[ $(<"$CACHE") =~ ^[0-9]+\ up$ ]]'

run -- "$(search 'second call')"
check "a second call within 60 seconds is denied without probing again" '[[ $(probes) == 1 && $out == *deny* ]]'

# The reason's command must survive the shell exactly. The stub records $1.
# Each case is a query and what the model's shell should receive: the same
# string, except that control characters and runs of spaces collapse to one.
roundtrip() { # roundtrip QUERY WANT
    reset
    run -- "$(search "$1")"
    local cmd want=$2
    cmd=$(reason | grep -m1 '^  searx ')
    rm -f "$SB/argv" "$SB/pwned"
    env -i PATH="$STUBS:$SYS" ARGV_OUT="$SB/argv" bash -c "$cmd"
    check "the command round-trips through the shell: $2" \
        '[[ $(<"$SB/argv") == "$want" && ! -e "$SB/pwned" ]]'
}
roundtrip "it's" "it's"
roundtrip 'a $(touch '"$SB"'/pwned) b' 'a $(touch '"$SB"'/pwned) b'
roundtrip 'say "hi" \ there' 'say "hi" \ there'
roundtrip 'back`touch '"$SB"'/pwned`tick' 'back`touch '"$SB"'/pwned`tick'
roundtrip '*glob* ~ $HOME !bang' '*glob* ~ $HOME !bang'
roundtrip "''" "''"
roundtrip "multi
line	tab  and  spaces" "multi line tab and spaces"

reset
run -- '{"tool_name":"WebSearch","tool_input":{"query":"a\nb\t c"}}'
check "newlines and tabs in a query become single spaces" '[[ $(reason) == *"  searx '"'"'a b c'"'"'"* ]]'

run -- '{"tool_name":"WebSearch","tool_input":{"query":"react","allowed_domains":["docs.example.com","react.dev","bad domain","x;rm"],"blocked_domains":["spam.example.org"]}}'
check "allowed and blocked domains turn into site: terms for the query" \
    '[[ $(reason) == *"site:docs.example.com OR site:react.dev -site:spam.example.org"* ]]'
check "a domain that does not look like one is dropped" '[[ $(reason) != *"bad domain"* && $(reason) != *"x;rm"* ]]'
run -- "$(search plain)"
check "no domain terms when the call had no domain filter" '[[ $(reason) != *"site:"* ]]'

run SEARXNG_URL="$URL/" -- "$(search slash)"
check "a trailing slash on SEARXNG_URL does not double" '[[ $out == *deny* ]]'

# --- SearXNG not answering --------------------------------------------------

reset
run SEARXNG_URL="$DEAD" -- "$(search 'nothing listens')"
check "nothing listening: no output, exit 0, WebSearch runs as usual" 'silent'
check "the down answer is cached" '[[ $(<"$CACHE") =~ ^[0-9]+\ down$ ]]'

for m in 500 404; do
    reset; mode "$m"
    run -- "$(search q)"
    check "/healthz answering $m counts as down" 'silent'
done
reset; mode no-content
run -- "$(search q)"
check "any 2xx counts as up: 204" '[[ $out == *deny* ]]'

reset; mode hang
run -- "$(search q)"
check "a probe that never finishes is cut at 2 seconds" 'silent && (( ms >= 1900 && ms < 3500 ))'
check "and cached as down, so the next call is instant" \
    'run -- "$(search q)"; silent && (( ms < 500 )) && [[ $(probes) == 1 ]]'

# --- the cache --------------------------------------------------------------

reset; : >"$SB/probes.log"
forge "$(( $(now) - 10 )) down"
run -- "$(search q)"
check "a fresh down entry is honored without a probe, though SearXNG is up" 'silent && [[ $(probes) == 0 ]]'

forge "$(( $(now) - 10 )) up"; mode 500
run -- "$(search q)"
check "a fresh up entry is honored without a probe, though SearXNG is down" '[[ $out == *deny* && $(probes) == 0 ]]'

forge "$(( $(now) - 61 )) up"; mode 500
run -- "$(search q)"
check "an entry older than 60 seconds is probed again" 'silent && [[ $(probes) == 1 && $(<"$CACHE") =~ ^[0-9]+\ down$ ]]'

forge "$(( $(now) - 61 )) down"; mode up
run -- "$(search q)"
check "a stale down entry recovers when SearXNG is back" '[[ $out == *deny* && $(<"$CACHE") =~ ^[0-9]+\ up$ ]]'

forge "$(( $(now) - 59 )) down"; : >"$SB/probes.log"
run -- "$(search q)"
check "an entry 59 seconds old is still fresh" 'silent && [[ $(probes) == 0 ]]'

forge "$(( $(now) + 1000 )) down"; : >"$SB/probes.log"
run -- "$(search q)"
check "an entry from the future (clock jump) is not trusted" '[[ $out == *deny* && $(probes) == 1 ]]'

for junk in "garbage" "123" "abc up" "123 maybe" ""; do
    forge "$junk"; : >"$SB/probes.log"
    run -- "$(search q)"
    check "a malformed cache line is probed over: '$junk'" '[[ $out == *deny* && $(probes) == 1 ]]'
done

# --- the URL from the skill values -------------------------------------------

# values JSON: writes the skill values file that RAVNIX_SKILL_VALUES names below.
values() { mkdir -p "$SB/values"; printf '%s\n' "$1" >"$SB/values/v.json"; }

reset
values "{\"web\":{\"searxngUrl\":\"$URL\"}}"
run SEARXNG_URL= RAVNIX_SKILL_VALUES="$SB/values/v.json" -- "$(search q)"
check "without SEARXNG_URL, web.searxngUrl from the skill values is the base" '[[ $out == *deny* && $(probes) == 1 ]]'

reset
mkdir -p "$SB/home/.config/ravnix"
printf '{"web":{"searxngUrl":"%s"}}\n' "$URL" >"$SB/home/.config/ravnix/skill-values.json"
run SEARXNG_URL= -- "$(search q)"
check "the skill values are read from ~/.config/ravnix/skill-values.json by default" '[[ $out == *deny* ]]'
reset
run SEARXNG_URL= XDG_CONFIG_HOME="$SB/elsewhere" -- "$(search q)"
check "XDG_CONFIG_HOME moves the default values file" 'silent && [[ $(probes) == 0 ]]'
rm -rf "$SB/home/.config"

reset
values "{\"web\":{\"searxngUrl\":\"$DEAD\"}}"
run RAVNIX_SKILL_VALUES="$SB/values/v.json" -- "$(search q)"
check "SEARXNG_URL wins over the skill value" '[[ $out == *deny* && $(probes) == 1 ]]'

reset
run SEARXNG_URL= -- "$(search q)"
check "with no URL anywhere, it says nothing and probes nothing" 'silent && [[ $(probes) == 0 ]]'

for v in 'not json' '[1,2]' '"text"' '{"web":"x"}' '{"web":{"searxngUrl":42}}' '{"web":{"searxngUrl":""}}' \
    '{"web":{"searxngUrl":null}}' '{"web":{"searxngUrl":["http://127.0.0.1:1"]}}' \
    "{\"web\":{\"searxngUrl\":\"$URL\\n$URL\"}}"; do
    reset
    values "$v"
    run SEARXNG_URL= RAVNIX_SKILL_VALUES="$SB/values/v.json" -- "$(search q)"
    check "skill values without a usable URL ($v): silent, no probe" 'silent && [[ $(probes) == 0 ]]'
done

reset
run SEARXNG_URL= RAVNIX_SKILL_VALUES="$SB/values/missing.json" -- "$(search q)"
check "a values file that does not exist: silent, no probe" 'silent && [[ $(probes) == 0 ]]'
run SEARXNG_URL= RAVNIX_SKILL_VALUES="$SB" -- "$(search q)"
check "a values path that is a directory: silent, no probe" 'silent && [[ $(probes) == 0 ]]'

# --- failing open -----------------------------------------------------------

reset; : >"$SB/probes.log"
mv "$STUBS/searx" "$SB/searx.away"
run -- "$(search q)"
check "no searx on PATH: no deny, and no probe" 'silent && [[ $(probes) == 0 ]]'
run PATH="$SYS" -- "$(search q)"
check "no searx anywhere: still silent" 'silent && [[ $(probes) == 0 ]]'
printf '#!%s\n' "$BASH" >"$SB/home/.local/bin/searx"; chmod +x "$SB/home/.local/bin/searx"
run PATH="$SYS" -- "$(search q)"
check "searx only in ~/.local/bin (a PATH without it) still counts" '[[ $out == *deny* ]]'
rm -f "$SB/home/.local/bin/searx"
mv "$SB/searx.away" "$STUBS/searx"

reset
mv "$SYS/curl" "$SB/curl.away"
run -- "$(search q)"
check "no curl: silent" 'silent'
mv "$SB/curl.away" "$SYS/curl"
mv "$SYS/jq" "$SB/jq.away"
run -- "$(search q)"
check "no jq: silent" 'silent'
mv "$SB/jq.away" "$SYS/jq"

reset
for case in 'not json at all' '' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    '{"tool_name":"WebFetch","tool_input":{"query":"has a query, but is no WebSearch"}}' \
    '{"tool_name":"WebSearch","tool_input":{}}' '{"tool_name":"WebSearch","tool_input":{"query":"   "}}' \
    '{"tool_name":"WebSearch"}' '[1,2,3]' '{"tool_name":"WebSearch","tool_input":{"query":null}}'; do
    run -- "$case"
    check "input that is not a WebSearch with a query: silent ($(head -c 40 <<<"$case"))" 'silent'
done

reset
: >"$SB/notadir"
run XDG_STATE_HOME="$SB/notadir" -- "$(search q)"
check "an unwritable state directory: still routes, and says nothing on stderr" '[[ $rc == 0 && $out == *deny* && -z $err ]]'
run HOME= XDG_STATE_HOME= -- "$(search q)"
check "no HOME and no XDG_STATE_HOME: no crash" '[[ $rc == 0 && -z $err ]]'

reset
run -- "$(search 'a very long query '"$(printf 'word %.0s' $(seq 400))")"
check "a long query is routed" '[[ $out == *deny* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
