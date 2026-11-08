#!/usr/bin/env bash
# searx: web search through the user's self-hosted SearXNG, printed as a numbered
# list that is cheap to read. Companion to the web-route hook, which sends the
# built-in WebSearch here whenever SearXNG answers.
#
#   searx [-n N] [-l LANG] [-t day|week|month|year] [-c CATEGORY] [--] QUERY...
#
# Why it exists. The user's web policy lets SearXNG replace the built-in
# WebSearch whenever it answers. SearXNG returns the raw hits from the engines
# the user chose, and this script cuts them down to what a search is for:
# pick a URL. The raw JSON is about 17 KB for 20 hits, mostly thumbnails,
# engine lists and scores; the list is about 2.5 KB for 8. Reading a page is a
# separate step (defuddle, WebFetch).
#
# Output, one entry per hit:
#   1. Title
#      https://example.org/page
#      Snippet cut at about 200 characters.
# Control and format characters (ESC, bidi overrides, zero-width) and every
# kind of space are folded into single spaces, so nothing a page puts in its
# title can move the cursor or hide text from the reader.
#
# Exit codes:  0 results   1 no results   2 SearXNG unreachable, an HTTP
# error, or no results while engines failed (the reason is on stderr)
# 64 bad usage. 2 is the one a caller may
# answer by falling back to another search; 64 is the caller's own mistake.
#
# Exit 2 also tells the web-route hook (claude/hooks/web-route.sh) to
# stand aside. The hook denies WebSearch while SearXNG's /healthz answers, and
# /healthz can answer while /search does not (json switched off, the limiter,
# a proxy error page). Without this, the model would be sent here, fail, and be
# sent here again. So a failed search writes "<epoch> down" to the hook's cache,
# $XDG_STATE_HOME/web-route/reachable, and WebSearch goes through for the
# cache's 60 seconds before the hook probes again.
#
# The base URL is SEARXNG_URL, else the skill value web.searxngUrl, read from
# RAVNIX_SKILL_VALUES or ${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json,
# which the ravnix module renders from ravnix.claude.skillValues (the same
# order the web-route hook uses). With neither there is nothing to ask: exit 2,
# so the caller falls back to another search. No URL is built in.
# SEARX_TIMEOUT (seconds, default 8) exists for the tests, which cannot wait
# eight seconds per case.
#
# SearXNG returns one page of about 20 hits and this script reads that page
# only, so -n above what the page holds prints what it holds.
#
# Tests: tests/searx.test.sh in this package (the check bin-searx).

set -uo pipefail

usage() {
    cat <<'USAGE'
usage: searx [-n N] [-l LANG] [-t day|week|month|year] [-c CATEGORY] [--] QUERY...

  Searches the web through the self-hosted SearXNG and prints a numbered list:
  title, URL, snippet (about 200 characters).

  -n N         number of results (default 8; SearXNG returns about 20 per page)
  -l LANG      result language: de, en, de-DE, or all
  -t RANGE     only results from the last day, week, month or year
  -c CATEGORY  one or more categories, comma separated: general, it, science,
               news, images, videos, files, music, social media, map
  -h, --help   this text

  SEARXNG_URL  the base URL of SearXNG. Without it the skill value web.searxngUrl
               is used (RAVNIX_SKILL_VALUES names the file), and without that
               there is no search: exit 2.

  A query that starts with a dash goes after --. Flags may come before or
  after the query.

  exit 0  results
  exit 1  no results, and every engine answered
  exit 2  SearXNG unreachable, an HTTP error, or no results while engines
          failed (reason on stderr)
  exit 64 bad usage

  Reading a result: defuddle parse URL --md -o FILE, or WebFetch for one answer.
USAGE
}

# The write is atomic (a rename), because the hook reads the file without a lock.
# Every failure here is ignored: a missing state directory must not turn a
# failed search into a different failure.
mark_down() {
    local dir=${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/web-route
    mkdir -p "$dir" 2>/dev/null || return 0
    { printf '%(%s)T down\n' -1 >"$dir/reachable.$$"; } 2>/dev/null \
        && mv -f "$dir/reachable.$$" "$dir/reachable" 2>/dev/null
    rm -f "$dir/reachable.$$" 2>/dev/null
    return 0
}

fail() { # fail CODE MESSAGE
    printf 'searx: %s\n' "$2" >&2
    (($1 == 2)) && mark_down
    exit "$1"
}

n=8 lang="" range="" cats="" query=()
while (($#)); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        -n|-l|-t|-c)
            (($# >= 2)) || fail 64 "$1 needs a value (searx --help)"
            case $1 in
                -n) n=$2 ;;
                -l) lang=$2 ;;
                -t) range=$2 ;;
                -c) cats=$2 ;;
            esac
            shift 2 ;;
        --) shift; query+=("$@"); break ;;
        -?*) fail 64 "unknown option $1 (searx --help)" ;;
        *) query+=("$1"); shift ;;
    esac
done

[[ $n =~ ^[1-9][0-9]{0,2}$ ]] || fail 64 "-n takes a positive number, not '$n'"
[[ -z $lang || $lang =~ ^[A-Za-z0-9_-]+$ ]] || fail 64 "-l takes a language code like de or en-US, not '$lang'"
[[ -z $range || $range =~ ^(day|week|month|year)$ ]] || fail 64 "-t takes day, week, month or year, not '$range'"
[[ -z $cats || $cats =~ ^[A-Za-z0-9\ _,-]+$ ]] || fail 64 "-c takes category names like general or it,science, not '$cats'"
q="${query[*]}"
[[ $q =~ [^[:space:]] ]] || fail 64 "no query (searx --help)"

base=${SEARXNG_URL:-}
if [[ -z $base ]]; then
    values=${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/skill-values.json}
    [[ -f $values && -r $values ]] &&
        base=$(jq -r '(.web.searxngUrl)? | strings' "$values" 2>/dev/null </dev/null)
fi
base=${base%/}
if [[ -z $base ]]; then
    printf 'searx: no SearXNG URL: set SEARXNG_URL, or web.searxngUrl in ravnix.claude.skillValues\n' >&2
    exit 2
fi
timeout=${SEARX_TIMEOUT:-8}

args=(--data-urlencode "q=$q" --data-urlencode "format=json")
[[ -n $lang ]]  && args+=(--data-urlencode "language=$lang")
[[ -n $range ]] && args+=(--data-urlencode "time_range=$range")
[[ -n $cats ]]  && args+=(--data-urlencode "categories=$cats")

# The status code rides on a last line of its own, so one variable holds both
# and no temporary file is needed. A curl that cannot connect leaves it empty.
resp=$(curl -s -L --max-redirs 3 --max-time "$timeout" -G \
        -H 'Accept: application/json' "${args[@]}" \
        -w $'\n%{http_code}' "$base/search" </dev/null)
rc=$?
if ((rc != 0)); then
    case $rc in
        6)  why="cannot resolve the host" ;;
        7)  why="connection refused" ;;
        28) why="no answer within ${timeout}s" ;;
        35|51|58|60) why="TLS error" ;;
        *)  why="curl exit $rc" ;;
    esac
    fail 2 "cannot reach $base: $why"
fi
code=${resp##*$'\n'}
body=${resp%$'\n'*}

if [[ $code != 200 ]]; then
    case $code in
        403) hint=" (SearXNG answers 403 when search.formats lacks json, or when the limiter blocks this client)" ;;
        429) hint=" (rate limited)" ;;
        *)   hint="" ;;
    esac
    fail 2 "HTTP $code from $base/search$hint"
fi
jq -e '.results | type == "array"' >/dev/null 2>&1 <<<"$body" \
    || fail 2 "$base/search did not answer with SearXNG JSON"

# One jq program does it all. \p{Cc} and \p{Cf} are the control and format
# characters, \p{Z} every separator (NBSP, line and paragraph separators
# included), so a title cannot carry a line break or an escape sequence. A cut
# at 200 backs up to the last space when that costs less than a quarter of the
# text, so a snippet rarely ends in half a word.
out=$(jq -r --argjson n "$n" '
    def clean: (. // "") | tostring
        | gsub("[\\p{Cc}\\p{Cf}\\p{Z}]+"; " ") | sub("^ "; "") | sub(" $"; "");
    def cut($max): if length > $max
        then (.[0:$max]) as $c
            | ($c | sub(" [^ ]*$"; "")) as $w
            | (if ($w | length) >= ($max * 3 / 4) then $w else $c end) + "..."
        else . end;
    [.results[] | select((.url | type) == "string" and (.url | test("\\S")))]
    | .[:$n] | to_entries[]
    | "\(.key + 1). \(.value.title | clean | cut(200) | if . == "" then "(untitled)" else . end)\n"
      + "   \(.value.url | gsub("[\\p{Cc}\\p{Cf}\\p{Z}]+"; ""))"
      + (.value.content | clean | cut(200) | if . == "" then "" else "\n   " + . end)
' <<<"$body") || fail 2 "could not read the results from $base/search"

if [[ -z $out ]]; then
    down=$(jq -r '[.unresponsive_engines[]? | "\(.[0]) (\(.[1]))"] | join(", ")' <<<"$body" 2>/dev/null)
    msg="no results for '$q'"
    # No hits while engines failed (rate limits, CAPTCHAs) says nothing about
    # the web, only that SearXNG could not ask it: a failure, so the hook lets
    # WebSearch stand in (2026-10-21). No hits from engines that all
    # answered stays a plain exit 1.
    [[ -n $down ]] && fail 2 "$msg. Engines that did not answer: $down"
    printf 'searx: %s\n' "$msg" >&2
    exit 1
fi
printf '%s\n' "$out"
