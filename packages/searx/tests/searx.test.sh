#!/usr/bin/env bash
# Tests for searx (packages/searx), run by the check bin-searx.
#
# Why a fake server instead of a curl stub: the contract is what goes over the
# wire (the query encoded, the parameters named right, the base URL joined
# without a double slash) and how the answer is cut down, and only a real curl
# talking to a real socket proves the first part. So a ten-line Python server
# on 127.0.0.1 stands in for SearXNG and answers by the q parameter: a normal
# page, an empty one, a 403, an HTML page, a redirect, a request that never
# finishes, and a page of hostile titles. It logs every request as one JSON
# line, request line included (Python's handler quietly folds a leading //
# into /, so the parsed path would hide a doubled slash), so a case can assert
# what the script sent. Nothing leaves the machine.
#
# The timeout case holds a request open instead of aiming at a closed port: a
# refused connection fails at once and would pass whatever the timeout was.
# That case asserts a lower bound on the elapsed time for that reason.
#
# Run:  bash searx.test.sh          (exit 0 = all green)
# SEARX_UNDER_TEST=<file> tests another copy, for mutation runs; by default it
# is the searx on the PATH. The script runs with an empty PATH, so what its
# package gives it (curl, jq, coreutils) is all it has.
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

# The checks are eval'd, so their $ expand at check time, and the variables
# they read look unused to shellcheck.
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=${SEARX_UNDER_TEST:-$(type -P searx)}
SUT=$(readlink -f "$SUT")
BASH_BIN=$(type -P bash)
[ -f "$SUT" ] || { echo "missing $SUT" >&2; exit 2; }
for t in curl jq python3; do
    type -P "$t" >/dev/null || { echo "the tests need $t, which is not installed" >&2; exit 2; }
done

SB=$(mktemp -d "${TMPDIR:-/tmp}/searx-test.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$SB"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

cat >"$SB/server.py" <<'EOF'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

LOG, PORTFILE = sys.argv[1], sys.argv[2]

NASTY = [
    {"title": "Plain title", "url": "https://example.org/plain", "content": "A plain snippet."},
    {"title": "Line\nbreak\tand \x1b[31mescape\x1b[0m", "url": "https://example.org/ctl",
     "content": "bell\x07 and\r\nCRLF"},
    {"title": "Bidi ‮evil‬ and zero​width", "url": "https://example.org/bidi",
     "content": "nbsp here and sep"},
    {"title": "Long words", "url": "https://example.org/long",
     "content": " ".join("word%03d" % i for i in range(60))},
    {"title": "No spaces", "url": "https://example.org/nospace", "content": "x" * 500},
    {"title": None, "url": "https://example.org/notitle", "content": None},
    {"title": "No URL", "content": "dropped"},
    {"title": "Split URL", "url": "https://example.org/a\nb", "content": "the url had a newline"},
    {"title": "T" * 300, "url": "https://example.org/longtitle", "content": ""},
]


def page(count):
    return {"query": "q", "results": [
        {"title": "Result %d" % i, "url": "https://example.org/%d" % i,
         "content": "Snippet %d" % i, "engines": ["x"], "score": 1.0, "thumbnail": "https://t/%d" % i}
        for i in range(1, count + 1)], "unresponsive_engines": []}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json", extra=None):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlsplit(self.path)
        params = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": u.path, "params": params, "raw": self.requestline}) + "\n")
        q = params.get("q", "")
        if u.path == "/old/search":
            return self.send(301, "", extra={"Location": "/search?" + u.query})
        if q == "hang":
            time.sleep(30)
        elif q == "forbidden":
            self.send(403, "Forbidden", "text/plain")
        elif q == "ratelimit":
            self.send(429, "Too Many Requests", "text/plain")
        elif q == "html":
            self.send(200, "<html><body>captive portal</body></html>", "text/html")
        elif q == "empty":
            self.send(200, {"results": [], "unresponsive_engines":
                            [["brave", "too many requests"], ["duckduckgo", "CAPTCHA"]]})
        elif q == "nothing":
            self.send(200, {"results": [], "unresponsive_engines": []})
        elif q == "nasty":
            self.send(200, {"results": NASTY, "unresponsive_engines": []})
        elif q == "many":
            self.send(200, page(30))
        else:
            self.send(200, page(12))


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
with open(PORTFILE, "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
EOF

: >"$SB/requests.log"
mkdir -p "$SB/nopath"
python3 -I "$SB/server.py" "$SB/requests.log" "$SB/port" &
SERVER_PID=$!
for _ in $(seq 100); do [ -s "$SB/port" ] && break; sleep 0.05; done
[ -s "$SB/port" ] || { echo "the fake server did not start" >&2; exit 2; }
URL=http://127.0.0.1:$(<"$SB/port")

# A port nothing listens on: bind to 0, read the number, close the socket.
DEAD=http://127.0.0.1:$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

# run [ENV=VAL ...] -- ARGS: runs the script; sets $out (stdout), $err (stderr),
# $rc, and $reqs (how many requests the fake server has seen so far).
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    out=$(env -i HOME="$SB" PATH="$SB/nopath" SEARXNG_URL="$URL" \
        "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>"$SB/err")
    rc=$?
    err=$(<"$SB/err")
    reqs=$(wc -l <"$SB/requests.log")
}
# last NAME: a parameter of the newest request the server logged.
last() { tail -n 1 "$SB/requests.log" | jq -r --arg k "$1" '.params[$k] // "<unset>"'; }
entries() { grep -cE '^[0-9]+\. ' <<<"$out"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: $out
    err: $err"; fi; }

echo "searx"

run -- --help
check "--help prints usage and exits 0" '[[ $rc == 0 && $out == "usage: searx"* && -z $err && $reqs == 0 ]]'
run -- -h
check "-h is the same" '[[ $rc == 0 && $out == "usage: searx"* ]]'

run -- bash printf builtin
check "a query returns 8 numbered results and exits 0" '[[ $rc == 0 && $(entries) == 8 && $out == "1. Result 1"* && -z $err ]]'
check "an entry is title, URL, snippet on three lines" \
    '[[ $(sed -n 1,3p <<<"$out") == "1. Result 1
   https://example.org/1
   Snippet 1" ]]'
check "the words of the query are joined with spaces" '[[ $(last q) == "bash printf builtin" ]]'
check "the request asks for the json format on /search" \
    '[[ $(last format) == json && $(tail -n 1 "$SB/requests.log" | jq -r .path) == /search ]]'
check "no language, range or category is sent unless asked for" \
    '[[ $(last language) == "<unset>" && $(last time_range) == "<unset>" && $(last categories) == "<unset>" ]]'
check "the thumbnails and scores of the raw page stay out of the output" \
    '[[ $out != *thumbnail* && $out != *t/1* && $out != *score* ]]'

run -- -n 3 foo
check "-n 3 prints three results" '[[ $rc == 0 && $(entries) == 3 ]]'
run -- foo -n 2
check "flags after the query work too" '[[ $rc == 0 && $(entries) == 2 && $(last q) == foo ]]'
run -- -n 50 foo
check "-n above the page prints the whole page" '[[ $rc == 0 && $(entries) == 12 ]]'
run -- many
check "the default of 8 holds on a page of 30" '[[ $(entries) == 8 ]]'
run -- -n 30 many
check "-n 30 prints 30 on a page of 30" '[[ $(entries) == 30 ]]'

run -- -l de -t week -c science,it ünï
check "-l, -t and -c become language, time_range and categories" \
    '[[ $(last language) == de && $(last time_range) == week && $(last categories) == science,it ]]'
check "a non-ASCII query survives the round trip" '[[ $(last q) == "ünï" ]]'
run -- 'c++ & friends=100%'
check "reserved characters in a query are encoded" '[[ $(last q) == "c++ & friends=100%" ]]'
run -- -- -n
check "-- lets a query start with a dash" '[[ $rc == 0 && $(last q) == "-n" ]]'

run SEARXNG_URL="$URL/" -- foo
check "a trailing slash on the base URL does not double" \
    '[[ $rc == 0 && $(tail -n 1 "$SB/requests.log" | jq -r .raw) == "GET /search?"* ]]'
run SEARXNG_URL="$URL/old" -- foo
check "a redirect from the base URL is followed" '[[ $rc == 0 && $(entries) == 8 ]]'

run -- -n 20 nasty
check "hostile pages: eight hits, the one without a URL dropped" '[[ $rc == 0 && $(entries) == 8 ]]'
check "no control byte survives except the newlines" \
    '! printf "%s" "$out" | LC_ALL=C grep -qaP "[\x00-\x09\x0b-\x1f\x7f]"'
check "no bidi, zero-width, no-break space or line separator survives" \
    '! printf "%s" "$out" | LC_ALL=C grep -qaP "\xe2\x80[\xae\xac\x8b\xa8\xa9]|\xc2\xa0"'
check "every line is an entry head or an indented detail" \
    '! grep -qvE "^([0-9]+\. |   )" <<<"$out"'
check "newlines, tabs and escape bytes in a title become single spaces" \
    '[[ $(grep -m1 "^2\. " <<<"$out") == "2. Line break and [31mescape [0m" ]]'
check "bidi and zero-width characters in a title are replaced by a space" \
    '[[ $(grep -m1 "^3\. " <<<"$out") == "3. Bidi evil and zero width" ]]'
check "a snippet loses its control and separator characters" \
    '[[ $(grep -m1 "nbsp" <<<"$out") == "   nbsp here and sep" ]]'
check "a long snippet is cut to about 200 characters" \
    'l=$(grep -m1 "word000" <<<"$out"); (( ${#l} > 150 && ${#l} <= 206 )) && [[ $l == *"..." ]]'
check "the cut backs up to the end of a whole word" \
    'l=$(grep -m1 "word000" <<<"$out"); [[ $l =~ word[0-9]{3}\.\.\.$ ]]'
check "a snippet without spaces is cut at exactly 200" \
    'l=$(grep -m1 "xxxx" <<<"$out"); [[ $l == "   $(printf "x%.0s" $(seq 200))..." ]]'
check "a hit with no title is called (untitled) and has no snippet line" \
    '[[ $(grep -A2 "^6\. " <<<"$out") == "6. (untitled)
   https://example.org/notitle
7. Split URL" ]]'
check "a newline inside a URL is removed" '[[ $out == *"   https://example.org/ab"$'"'"'\n'"'"'* ]]'
check "a long title is cut like a snippet" \
    'l=$(grep -m1 "^8\. " <<<"$out"); [[ $l == "8. $(printf "T%.0s" $(seq 200))..." ]]'

run -- nothing
check "no results from engines that all answered: exit 1, nothing on stdout" '[[ $rc == 1 && -z $out ]]'
check "no results: stderr names the query" '[[ $err == "searx: no results for '"'"'nothing'"'"'" ]]'
run -- empty
check "no results while engines failed: exit 2, nothing on stdout" '[[ $rc == 2 && -z $out ]]'
check "no results while engines failed: stderr names the query and the engines that did not answer" \
    '[[ $err == *"no results for '"'"'empty'"'"'"* && $err == *"brave (too many requests)"* && $err == *"duckduckgo (CAPTCHA)"* ]]'

run -- forbidden
check "HTTP 403: exit 2 with a hint about the json format" \
    '[[ $rc == 2 && -z $out && $err == *"HTTP 403"* && $err == *"search.formats"* ]]'
run -- ratelimit
check "HTTP 429: exit 2, rate limited" '[[ $rc == 2 && $err == *"HTTP 429"* && $err == *"rate limited"* ]]'
run -- html
check "a 200 that is not SearXNG JSON: exit 2" '[[ $rc == 2 && -z $out && $err == *"did not answer with SearXNG JSON"* ]]'

run SEARXNG_URL="$DEAD" -- foo
check "nothing listening: exit 2, connection refused" \
    '[[ $rc == 2 && -z $out && $err == *"cannot reach $DEAD"* && $err == *"connection refused"* ]]'

start=$SECONDS
run SEARX_TIMEOUT=1 -- hang
check "a request that never finishes: exit 2 after the timeout, not before" \
    '[[ $rc == 2 && $err == *"no answer within 1s"* ]] && (( SECONDS - start >= 1 && SECONDS - start < 6 ))'
start=$SECONDS
run SEARX_TIMEOUT=2 -- hang
check "the timeout is the one asked for" '(( SECONDS - start >= 2 ))'

# A failed search tells the web-route hook to let WebSearch through for a
# minute (see the header of searx). The hook reads "<epoch> down" from
# $XDG_STATE_HOME/web-route/reachable.
CACHE=$SB/.local/state/web-route/reachable
now() { printf '%(%s)T' -1; }
rm -rf "$SB/.local"
run SEARXNG_URL="$DEAD" -- foo
check "exit 2 marks SearXNG down for the web-route hook" \
    '[[ $(<"$CACHE") =~ ^([0-9]+)\ down$ ]] && (( $(now) - BASH_REMATCH[1] < 5 ))'
rm -rf "$SB/.local"
run -- forbidden
check "an HTTP error marks it down too" '[[ $(<"$CACHE") == *" down" ]]'
rm -rf "$SB/.local"
run XDG_STATE_HOME="$SB/xdg" -- forbidden
check "XDG_STATE_HOME decides where" '[[ $(<"$SB/xdg/web-route/reachable") == *" down" && ! -e "$CACHE" ]]'
rm -rf "$SB/.local"
: >"$SB/notadir"
run XDG_STATE_HOME="$SB/notadir" -- forbidden
check "an unwritable state directory does not change the exit code or the message" \
    '[[ $rc == 2 && $(wc -l <<<"$err") == 1 && $err == "searx: HTTP 403"* ]]'
rm -rf "$SB/.local"
run -- foo
check "a search that works leaves the cache alone" '[[ $rc == 0 && ! -e "$CACHE" ]]'
run -- nothing
check "no results from engines that all answered is not a failure: cache untouched" '[[ $rc == 1 && ! -e "$CACHE" ]]'
run -- empty
check "no results while engines failed marks SearXNG down" '[[ $rc == 2 && $(<"$CACHE") == *" down" ]]'
rm -rf "$SB/.local"
run -- -n x foo
check "a usage error leaves the cache alone" '[[ $rc == 64 && ! -e "$CACHE" ]]'

before=$(wc -l <"$SB/requests.log")
usage_fail() { # usage_fail DESCRIPTION ARGS...
    local what=$1; shift
    run -- "$@"
    check "$what: exit 64, a message, no request" \
        '[[ $rc == 64 && -z $out && $err == searx:* ]] && (( $(wc -l <"$SB/requests.log") == before ))'
}
usage_fail "no query"
usage_fail "an empty query" "  "
usage_fail "-n with a word" -n many foo
usage_fail "-n 0" -n 0 foo
usage_fail "-n with no value" foo -n
usage_fail "-t with an unknown range" -t decade foo
usage_fail "-l with a shell metacharacter" -l 'de;rm' foo
usage_fail "-c with a shell metacharacter" -c 'it$(x)' foo
usage_fail "an unknown option" -x foo

# No URL is built in: SEARXNG_URL, else the skill value web.searxngUrl, from
# the file RAVNIX_SKILL_VALUES names or, without it, from
# $XDG_CONFIG_HOME/ravnix/skill-values.json. With none of them nothing is asked
# and the exit code is 2, the one a caller answers with another search.
values=$SB/skill-values.json
printf '{"web":{"searxngUrl":"%s/"}}\n' "$URL" >"$values"
printf '{"web":{"searxngUrl":"%s"}}\n' "$DEAD" >"$SB/dead-values.json"
rm -rf "$SB/.local"

run SEARXNG_URL= RAVNIX_SKILL_VALUES="$values" -- foo
check "without SEARXNG_URL the skill value web.searxngUrl is the base URL" \
    '[[ $rc == 0 && $(entries) == 8 && $(tail -n 1 "$SB/requests.log" | jq -r .raw) == "GET /search?"* ]]'
run RAVNIX_SKILL_VALUES="$SB/dead-values.json" -- foo
check "SEARXNG_URL wins over the skill value" '[[ $rc == 0 && $(entries) == 8 ]]'
run SEARXNG_URL="$DEAD" RAVNIX_SKILL_VALUES="$values" -- foo
check "SEARXNG_URL wins over a skill value that would work" '[[ $rc == 2 && $err == *"cannot reach $DEAD"* ]]'
mkdir -p "$SB/xdg/ravnix"
cp "$values" "$SB/xdg/ravnix/skill-values.json"
run SEARXNG_URL= XDG_CONFIG_HOME="$SB/xdg" -- foo
check "without RAVNIX_SKILL_VALUES the file under XDG_CONFIG_HOME is read" '[[ $rc == 0 && $(entries) == 8 ]]'
mkdir -p "$SB/.config/ravnix"
cp "$values" "$SB/.config/ravnix/skill-values.json"
run SEARXNG_URL= -- foo
check "without XDG_CONFIG_HOME the file under ~/.config is read" '[[ $rc == 0 && $(entries) == 8 ]]'
rm -rf "$SB/.config" "$SB/.local"

before=$(wc -l <"$SB/requests.log")
no_url() { # no_url DESCRIPTION [ENV=VAL ...]
    local what=$1; shift
    run SEARXNG_URL= "$@" -- foo
    check "$what: exit 2, both settings named, no request, the cache left alone" \
        '[[ $rc == 2 && -z $out && $err == *SEARXNG_URL* && $err == *web.searxngUrl* && $err != *"cannot reach"* ]] &&
         (( $(wc -l <"$SB/requests.log") == before )) && [[ ! -e "$CACHE" ]]'
}
no_url "no setting at all"
no_url "a skill values file that does not exist" RAVNIX_SKILL_VALUES="$SB/nowhere.json"
printf 'not json at all' >"$SB/bad.json"
no_url "a skill values file that is no JSON" RAVNIX_SKILL_VALUES="$SB/bad.json"
printf '{"web":{"searxngUrl":42}}' >"$SB/number.json"
no_url "a URL that is a number" RAVNIX_SKILL_VALUES="$SB/number.json"
printf '{"web":"a string"}' >"$SB/webstring.json"
no_url "web that is no object" RAVNIX_SKILL_VALUES="$SB/webstring.json"
printf '{"web":{"searxngUrl":""}}' >"$SB/empty.json"
no_url "an empty URL" RAVNIX_SKILL_VALUES="$SB/empty.json"
printf '[1,2]' >"$SB/array.json"
no_url "a skill values file that is an array" RAVNIX_SKILL_VALUES="$SB/array.json"
no_url "a skill values file that is a directory" RAVNIX_SKILL_VALUES="$SB"

# The default timeout, which takes the whole eight seconds to show.
start=$SECONDS
run SEARX_TIMEOUT= -- hang
check "the default timeout is 8 seconds" \
    '[[ $rc == 2 && $err == *"no answer within 8s"* ]] && (( SECONDS - start >= 8 && SECONDS - start < 20 ))'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
