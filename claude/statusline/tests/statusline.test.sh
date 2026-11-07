#!/usr/bin/env bash
# Tests for statusline.sh, one directory up.
#
# Why fixtures instead of Claude Code: the status line's whole contract is the
# session JSON on stdin, a few environment variables, and one line on stdout.
# Driving the script directly lets each case give it exactly the input and
# the environment it needs.
#
# Every run goes through a parent bash, because Claude Code runs the script as
# a child of the claude process and the script reads the session kind from
# its parent's environment. Both environments are built from nothing
# (env -i), so the caller's own HOSTNAME, NO_COLOR, TZ or session kind never
# leak in. TZ is UTC unless a case sets another. The script's PATH holds a
# link to jq and nothing else: that is how a missing jq is simulated, and a
# script that starts calling another tool fails here first, with something on
# stderr.
#
# The quiet hosts come from the ravnix skill values. Every run gets
# RAVNIX_SKILL_VALUES pointing at a file whose statusline.quietHosts is
# ["huginn"], so huginn stands for the machine where ordinary sessions run,
# and every other name for a machine that is not; a case passes its own
# RAVNIX_SKILL_VALUES= to change that.
#
# The cache age is measured against the clock, so every payload is stamped
# with an expiry relative to the moment it is built, 12 minutes and 30
# seconds into a one-hour cache. The half minute keeps a slow run from
# crossing a minute boundary. The reset times are fixed epochs, because the
# script only formats them.
#
# Run:  bash statusline.test.sh          (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

set -uo pipefail

SELF=$(readlink -f "$0")
SL=${SELF%/*/*}/statusline.sh
[ -f "$SL" ] || { echo "missing $SL" >&2; exit 2; }
ENV_BIN=$(type -P env) || { echo "the tests need env, which is not installed" >&2; exit 2; }
JQ_BIN=$(type -P jq)   || { echo "the tests need jq, which is not installed" >&2; exit 2; }
DATE_BIN=$(type -P date) || { echo "the tests need date, which is not installed" >&2; exit 2; }

pass=0
fail=0
CASE=""
ERR="" RC=0

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'stdout: %s\nstderr: %s\n' "$(cat -v "$ROOT/out")" "$ERR" | sed 's/^/       | /'; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

WITH_JQ=$ROOT/with-jq NO_JQ=$ROOT/no-jq
mkdir -p "$WITH_JQ" "$NO_JQ"
ln -s "$JQ_BIN" "$WITH_JQ/jq"

# The skill values every run gets unless it passes its own.
QUIET='{"statusline":{"quietHosts":["huginn"]}}'
printf '%s\n' "$QUIET" >"$ROOT/values.json"

# values <text>: writes <text> to $ROOT/v.json, for a case's own values.
values() { printf '%s\n' "$1" >"$ROOT/v.json"; }

# The colors statusline.sh uses. Change them there and here together. The
# host tag is the accent fill: reverse video on the bright magenta slot,
# where the theme puts the accent (docs/style.md), so the text takes the
# terminal's background.
TAG=$'\e[7;95m' YELLOW=$'\e[33m' RED=$'\e[1;31m' RESET=$'\e[0m'

# run_sl <stdin> [VAR=value...]: runs the script with PATH (the jq-only
# directory), TZ=UTC, RAVNIX_SKILL_VALUES (the quiet huginn above) and the
# given pairs as its whole environment, and sets ERR and RC. A later PATH=,
# TZ= or RAVNIX_SKILL_VALUES= overrides the default. PARENT_KIND, when
# set, goes into the parent's environment only, which is where Claude Code
# leaves CLAUDE_CODE_SESSION_KIND. TZDIR passes through when it is set, as
# in the Nix build sandbox, which has no /usr/share/zoneinfo.
run_sl() {
    local input=$1
    shift
    printf '%s' "$input" >"$ROOT/in"
    "$ENV_BIN" -i ${PARENT_KIND:+"CLAUDE_CODE_SESSION_KIND=$PARENT_KIND"} \
        "$BASH" -c '"$@"; exit $?' parent \
        "$ENV_BIN" -i PATH="$WITH_JQ" TZ=UTC ${TZDIR:+"TZDIR=$TZDIR"} \
        RAVNIX_SKILL_VALUES="$ROOT/values.json" "$@" "$BASH" "$SL" \
        <"$ROOT/in" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
    ERR=$(<"$ROOT/err")
}

# expect <line>: exit 0, nothing on stderr, and stdout exactly <line> plus a newline.
expect() {
    if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
    elif [ -n "$ERR" ];   then bad "expected nothing on stderr"
    elif ! cmp -s "$ROOT/out" <(printf '%s\n' "$1"); then bad "expected: $(printf '%s' "$1" | cat -v)"
    else ok; fi
}

# A payload as Claude Code 2.1.281 sent it to a status line on 2026-09-24,
# after the first response of a background session. Its prompt_cache expiry
# and the 1h ttl are restamped by fresh below.
FULL='{"session_id":"c0ffee00-1234-4abc-8def-000000000001","transcript_path":"/home/alice/.claude/projects/-home-alice-src-demo/c0ffee00-1234-4abc-8def-000000000001.jsonl","cwd":"/home/alice/src/demo","scratchpad_dir":"/tmp/claude-1000/-home-alice-src-demo/c0ffee00-1234-4abc-8def-000000000001/scratchpad","prompt_id":"0b5e55ed-0000-4000-8000-000000000002","session_name":"demo","model":{"id":"claude-haiku-4-5-20251001","display_name":"Haiku 4.5"},"workspace":{"current_dir":"/home/alice/src/demo","project_dir":"/home/alice/src/demo","added_dirs":[]},"version":"2.1.281","output_style":{"name":"default"},"cost":{"total_cost_usd":0.07882099999999999,"total_duration_ms":10252,"total_api_duration_ms":10013,"total_lines_added":0,"total_lines_removed":0},"context_window":{"total_input_tokens":37197,"total_output_tokens":699,"context_window_size":200000,"current_usage":{"input_tokens":10,"output_tokens":699,"cache_creation_input_tokens":37187,"cache_read_input_tokens":0},"used_percentage":19,"remaining_percentage":81},"exceeds_200k_tokens":false,"prompt_cache":{"warm":true,"caching_observed":true,"ttl":"1h","expires_at":1790257283,"requests":1,"misses":0,"expected_rebuilds":0,"hit_ratio":0,"cache_write_tokens":37187,"miss_recache_tokens":0,"last_miss_at":null,"last_miss_cause":null,"miss_causes":{},"recache_tokens_if_cold":37197},"fast_mode":false,"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1790266800},"seven_day":{"used_percentage":6,"resets_at":1790542800}}}'

# fresh: FULL with the cache expiring in 2850 seconds, so its age is 750.
fresh() { jq -c ".prompt_cache.expires_at = $(( $("$DATE_BIN" +%s) + 2850 ))" <<<"$FULL"; }

# edit <jq filter>: fresh with the filter applied, compact.
edit() { fresh | jq -c "$1"; }

# The same instants as the script's local time, from date(1), which is
# independent of jq. A weekday is its first two letters in English.
FIVE_AT=1790266800 WEEK_AT=1790542800
hm()  { TZ=${2:-UTC} "$DATE_BIN" -d "@$1" +%H:%M; }
wd()  { local d; d=$(TZ=${2:-UTC} LC_ALL=C "$DATE_BIN" -d "@$1" +%a); printf '%s' "${d:0:2}"; }

# join <part>...: the parts as the script separates them.
join() { local out=$1; shift; local p; for p; do out+=" · $p"; done; printf '%s' "$out"; }

# The parts of a real payload.
P_MODEL="Haiku 4.5" P_CTX="ctx 19%" P_CACHE="cache 12m" P_SID=c0ffee00
P_5H="5h 30% ↻$(hm $FIVE_AT)" P_WK="wk 6% ↻$(wd $WEEK_AT)"
BODY=$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")

# The host tag the script prints for a host name: none on huginn, the quiet
# host of the default values, else the name on the accent fill.
host_tag() { [ "$1" = huginn ] || printf '%s' "${TAG}$1${RESET}"; }

# The kernel's name for this machine, as the script falls back to it.
read -r kernel_host </proc/sys/kernel/hostname
kernel_host=${kernel_host%%.*}

# --- the host -------------------------------------------------------------------

echo "the host"

CASE="a quiet host prints no host, only the parts of a real payload"
run_sl "$(fresh)" HOSTNAME=huginn
expect "$BODY"

CASE="a domain on a quiet host's name does not make it another host"
run_sl "$(fresh)" HOSTNAME=huginn.lan
expect "$BODY"

CASE="any other host prints as it is, on the accent fill, at the front"
run_sl "$(fresh)" HOSTNAME=build-box
expect "$(host_tag build-box) · $BODY"

CASE="the tag is the name itself: no prefix is dropped, and there is no table of known hosts"
run_sl "$(fresh)" HOSTNAME=old-huginn
expect "${TAG}old-huginn${RESET} · $BODY"

CASE="a domain on the name is dropped before the match"
run_sl "$(fresh)" HOSTNAME=other-host.lan
expect "$(host_tag other-host) · $BODY"

CASE="with no HOSTNAME in the environment, bash's own (the kernel's) name decides"
run_sl "" NO_COLOR=1 RAVNIX_SKILL_VALUES="$ROOT/no-values.json"
expect "$kernel_host"

CASE="an empty HOSTNAME falls back to the kernel's name"
run_sl "" HOSTNAME= NO_COLOR=1 RAVNIX_SKILL_VALUES="$ROOT/no-values.json"
expect "$kernel_host"

CASE="control characters in HOSTNAME are dropped, so the name cannot move the cursor"
run_sl "" HOSTNAME=$'build\e[2J-box\a' NO_COLOR=1
expect "build[2J-box"

CASE="a HOSTNAME of control characters alone counts as none"
run_sl "" HOSTNAME=$'\e\a' NO_COLOR=1 RAVNIX_SKILL_VALUES="$ROOT/no-values.json"
expect "$kernel_host"

CASE="the kernel's name is quiet when the values list it"
values "$(jq -cn --arg h "$kernel_host" '{statusline: {quietHosts: [$h]}}')"
run_sl "" HOSTNAME= NO_COLOR=1 RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect ""

# --- the quiet hosts --------------------------------------------------------------

echo "the quiet hosts"

values '{"statusline":{"quietHosts":["huginn","muninn"]}}'
for h in huginn muninn; do
    CASE="every host statusline.quietHosts lists is quiet ($h of two)"
    run_sl "$(fresh)" HOSTNAME=$h RAVNIX_SKILL_VALUES="$ROOT/v.json"
    expect "$BODY"
done

CASE="a host the list leaves out still gets its tag"
run_sl "$(fresh)" HOSTNAME=build-box RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "$(host_tag build-box) · $BODY"

CASE="without a values file every host gets its tag, huginn too"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/no-values.json"
expect "${TAG}huginn${RESET} · $BODY"

CASE="a values path that is a directory: every host gets its tag"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT"
expect "${TAG}huginn${RESET} · $BODY"

CASE="an empty list makes no host quiet"
values '{"statusline":{"quietHosts":[]}}'
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "${TAG}huginn${RESET} · $BODY"

for bad in '' 'not json' '{"statusline":' '[1,2]' '"huginn"' 'null' '{"statusline":"huginn"}' \
    '{"statusline":{"quietHosts":"huginn"}}' '{"statusline":{"quietHosts":{"huginn":true}}}' \
    '{"statusline":{"quietHosts":[["huginn"]]}}' '{"statusline":{"quietHosts":[{"name":"huginn"}]}}'; do
    CASE="values without a usable list ($bad): the tag prints, and the rest of the line too"
    values "$bad"
    run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
    expect "${TAG}huginn${RESET} · $BODY"
done

CASE="entries that are no string are skipped, and the strings still count"
values '{"statusline":{"quietHosts":[42,null,true,"huginn"]}}'
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "$BODY"

CASE="only the whole name matches, in its own case: no prefix, no longer name, no domain"
values '{"statusline":{"quietHosts":["hug","huginn2","HUGINN","huginn.lan"," huginn"]}}'
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "${TAG}huginn${RESET} · $BODY"

CASE="other keys in the values change nothing"
values '{"web":{"searxngUrl":"http://127.0.0.1:1"},"statusline":{"quietHosts":["huginn"],"other":1}}'
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "$BODY"

CASE="the values are read from ~/.config/ravnix/skill-values.json without RAVNIX_SKILL_VALUES"
mkdir -p "$ROOT/home/.config/ravnix"
printf '%s\n' "$QUIET" >"$ROOT/home/.config/ravnix/skill-values.json"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES= HOME="$ROOT/home"
expect "$BODY"

CASE="XDG_CONFIG_HOME moves the default values file"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES= HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/elsewhere"
expect "${TAG}huginn${RESET} · $BODY"
mkdir -p "$ROOT/elsewhere/ravnix"
cp "$ROOT/home/.config/ravnix/skill-values.json" "$ROOT/elsewhere/ravnix/"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES= HOME="$ROOT/home" XDG_CONFIG_HOME="$ROOT/elsewhere"
expect "$BODY"

CASE="with neither HOME nor RAVNIX_SKILL_VALUES no file is read and the host gets its tag"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES=
expect "${TAG}huginn${RESET} · $BODY"

CASE="a values file that is a large JSON document is read all the same"
jq -cn '{padding: [range(20000) | "x\(.)"], statusline: {quietHosts: ["huginn"]}}' >"$ROOT/v.json"
run_sl "$(fresh)" HOSTNAME=huginn RAVNIX_SKILL_VALUES="$ROOT/v.json"
expect "$BODY"

# --- the session kind -------------------------------------------------------------

echo "the session kind"

CASE="bg in the parent's environment only, as in a real worker, prints bg first on a quiet host"
PARENT_KIND='bg' run_sl "$(fresh)" HOSTNAME=huginn
expect "bg · $BODY"

CASE="bg comes after the host tag on another host"
PARENT_KIND='bg' run_sl "$(fresh)" HOSTNAME=other-host
expect "$(host_tag other-host) · bg · $BODY"

CASE="bg in the script's own environment prints bg too"
run_sl "$(fresh)" HOSTNAME=huginn CLAUDE_CODE_SESSION_KIND=bg
expect "bg · $BODY"

CASE="a parent kind other than bg prints nothing"
PARENT_KIND=daemon run_sl "$(fresh)" HOSTNAME=huginn
expect "$BODY"

# --- input that is not usable -------------------------------------------------------

echo "input that is not usable"

CASE="empty stdin on a quiet host prints an empty line"
run_sl "" HOSTNAME=huginn
expect ""

CASE="empty stdin elsewhere prints the host tag alone"
run_sl "" HOSTNAME=other-host
expect "$(host_tag other-host)"

CASE="malformed JSON prints the host tag alone"
run_sl '{"model": {"display_name": "Opus", ' HOSTNAME=other-host
expect "$(host_tag other-host)"

CASE="malformed JSON on a quiet host prints an empty line: the values are still read"
run_sl '{"model": {"display_name": "Opus", ' HOSTNAME=huginn
expect ""

CASE="stdin that is not UTF-8 prints the host tag alone"
run_sl $'\xff\xfe{"session_id":"x"}' HOSTNAME=other-host
expect "$(host_tag other-host)"

for input in '[1,2]' '"text"' '42' 'null'; do
    CASE="JSON that is not an object ($input) prints the host tag alone"
    run_sl "$input" HOSTNAME=other-host
    expect "$(host_tag other-host)"
done

CASE="of two JSON values only the first counts"
run_sl '{"session_id":"aaaaaaaa-1"} {"session_id":"bbbbbbbb-2","model":{"display_name":"Opus"}}' HOSTNAME=huginn
expect "aaaaaaaa"

CASE="with jq missing from PATH the host tag and bg still print, and nothing reaches stderr"
PARENT_KIND='bg' run_sl "$(fresh)" HOSTNAME=other-host PATH="$NO_JQ"
expect "$(host_tag other-host) · bg"

CASE="with jq missing a quiet host gets its tag too, because the values cannot be read"
PARENT_KIND='bg' run_sl "$(fresh)" HOSTNAME=huginn PATH="$NO_JQ"
expect "$(printf '%s' "${TAG}huginn${RESET}") · bg"

# --- the fields --------------------------------------------------------------------

echo "the fields"

CASE="a missing model drops the model alone"
run_sl "$(edit 'del(.model)')" HOSTNAME=huginn
expect "$(join "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a null used_percentage (before the first response) drops the context alone"
run_sl "$(edit '.context_window.used_percentage = null | .context_window.current_usage = null')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a missing context_window drops the context alone"
run_sl "$(edit 'del(.context_window)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a missing session_id drops the id alone"
run_sl "$(edit 'del(.session_id)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE")"

CASE="fields of the wrong type drop out instead of printing JSON or failing"
run_sl '{"model":"Opus","effort":"high","context_window":[1],"session_id":42,"rate_limits":[1],"prompt_cache":"warm"}' HOSTNAME=huginn
expect ""

CASE="a fractional percentage is rounded"
run_sl "$(edit '.context_window.used_percentage = 41.6')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "ctx 42%" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a percentage of 0 still prints"
run_sl "$(edit '.context_window.used_percentage = 0')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "ctx 0%" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="the context percentage never changes color, whatever it reads"
run_sl "$(edit '.context_window.used_percentage = 95')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "ctx 95%" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="control characters in a field are dropped, so the JSON cannot move the cursor"
# ESC, a newline and CSI (U+009B, written as its UTF-8 bytes), which jq escapes in the JSON.
name=$'Op\e[2J\nus\xc2\x9b'
run_sl "$(fresh | jq -c --arg n "$name" '.model.display_name = $n')" HOSTNAME=huginn
expect "$(join "Op[2Jus" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

# --- the effort ----------------------------------------------------------------------

echo "the effort"

CASE="the effort level follows the model name"
run_sl "$(edit '.model.display_name = "Opus 5.5" | .effort = {"level":"high"}')" HOSTNAME=huginn
expect "$(join "Opus 5.5 high" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a missing effort (a model without the parameter) leaves the model alone"
run_sl "$(edit '.effort = null')" HOSTNAME=huginn
expect "$BODY"

CASE="an effort level that is no string drops out"
run_sl "$(edit '.effort = {"level":3}')" HOSTNAME=huginn
expect "$BODY"

CASE="an effort level without a model is not printed alone"
run_sl "$(edit 'del(.model) | .effort = {"level":"max"}')" HOSTNAME=huginn
expect "$(join "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "$P_SID")"

# --- the rate limits -------------------------------------------------------------------

echo "the rate limits"

CASE="the five-hour reset prints as local HH:MM and the weekly one as a two-letter weekday"
run_sl "$(edit '.rate_limits.five_hour.resets_at = 1790271900 | .rate_limits.seven_day.resets_at = 1790629200')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h 30% ↻$(hm 1790271900)" "wk 6% ↻$(wd 1790629200)" "$P_CACHE" "$P_SID")"

CASE="the reset times follow the local time zone, here India's +05:30"
run_sl "$(fresh)" HOSTNAME=huginn TZ=Asia/Kolkata
expect "$(join "$P_MODEL" "$P_CTX" "5h 30% ↻$(hm $FIVE_AT Asia/Kolkata)" "wk 6% ↻$(wd $WEEK_AT Asia/Kolkata)" "$P_CACHE" "$P_SID")"

CASE="the weekday names run Su to Sa, whatever the language of date(1)"
names=""
want=""
for k in 0 1 2 3 4 5 6; do
    at=$((WEEK_AT + k * 86400))
    run_sl "$(edit ".rate_limits.seven_day.resets_at = $at")" HOSTNAME=huginn
    names+=$(sed -n 's/.*wk 6% ↻\(..\) .*/\1 /p' "$ROOT/out")
    want+="$(wd $at) "
done
if [ "$names" = "$want" ] && [ "$(printf '%s' "$names" | tr ' ' '\n' | sort -u | wc -l)" -eq 7 ]; then ok
else bad "expected seven distinct days $want, got $names"; fi

CASE="a percentage turns yellow at 70, in the number alone"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 70')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h ${YELLOW}70%${RESET} ↻$(hm $FIVE_AT)" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="69.4 rounds to 69 and stays plain"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 69.4')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h 69% ↻$(hm $FIVE_AT)" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="69.5 rounds to 70 and turns yellow, so the color matches the number shown"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 69.5')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h ${YELLOW}70%${RESET} ↻$(hm $FIVE_AT)" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="89 is still yellow"
run_sl "$(edit '.rate_limits.seven_day.used_percentage = 89')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "wk ${YELLOW}89%${RESET} ↻$(wd $WEEK_AT)" "$P_CACHE" "$P_SID")"

CASE="90 turns red"
run_sl "$(edit '.rate_limits.seven_day.used_percentage = 90')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "wk ${RED}90%${RESET} ↻$(wd $WEEK_AT)" "$P_CACHE" "$P_SID")"

CASE="a limit past 100 is printed as it is, in red"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 104')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h ${RED}104%${RESET} ↻$(hm $FIVE_AT)" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a window without resets_at keeps its percentage"
run_sl "$(edit 'del(.rate_limits.five_hour.resets_at)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h 30%" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a resets_at that is no number is left out, the percentage stays"
run_sl "$(edit '.rate_limits.five_hour.resets_at = "soon"')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "5h 30%" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a window without a percentage drops out whole"
run_sl "$(edit 'del(.rate_limits.five_hour.used_percentage)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="a percentage that is a string drops its window"
run_sl "$(edit '.rate_limits.seven_day.used_percentage = "6"')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_CACHE" "$P_SID")"

CASE="a null window (Claude Code drops a lapsed one) drops out alone"
run_sl "$(edit '.rate_limits.five_hour = null')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_WK" "$P_CACHE" "$P_SID")"

CASE="no rate_limits at all (an API key) drops both windows"
run_sl "$(edit 'del(.rate_limits)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_CACHE" "$P_SID")"

CASE="the gateway's spend_limit is not shown"
run_sl "$(edit '.rate_limits = {"spend_limit":{"used_percentage":62.8,"resets_at":1790266800,"used_usd":314.12,"limit_usd":500,"period":"monthly"}}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_CACHE" "$P_SID")"

# --- the per-model windows ---------------------------------------------------------------

echo "the per-model windows"

CASE="model_scoped entries print by display_name, right after the weekly limit"
run_sl "$(edit '.rate_limits.model_scoped = [{"display_name":"Fable","utilization":18,"resets_at":"2026-10-20T10:00:00Z"}]')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Fable 18%" "$P_CACHE" "$P_SID")"

CASE="seven_day_opus and seven_day_sonnet follow, as Opus and Sonnet"
run_sl "$(edit '.rate_limits.model_scoped = [{"display_name":"Fable","utilization":18.4,"resets_at":null}]
    | .rate_limits.seven_day_opus = {"utilization":55,"resets_at":"2026-10-20T10:00:00.000Z"}
    | .rate_limits.seven_day_sonnet = {"utilization":9,"resets_at":null}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Fable 18%" "Opus 55%" "Sonnet 9%" "$P_CACHE" "$P_SID")"

CASE="a null seven_day_sonnet, as the usage reply has it, drops out alone"
run_sl "$(edit '.rate_limits.seven_day_opus = {"utilization":55,"resets_at":null} | .rate_limits.seven_day_sonnet = null')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Opus 55%" "$P_CACHE" "$P_SID")"

CASE="a model_scoped Opus is not printed twice when seven_day_opus is there too"
run_sl "$(edit '.rate_limits.model_scoped = [{"display_name":"Opus","utilization":40,"resets_at":null}]
    | .rate_limits.seven_day_opus = {"utilization":55,"resets_at":null}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Opus 40%" "$P_CACHE" "$P_SID")"

CASE="entries without a name or without a number are skipped, the others stay"
run_sl "$(edit '.rate_limits.model_scoped = [{"display_name":"","utilization":5},{"display_name":"Gap","utilization":null},{"display_name":7,"utilization":6},{"utilization":8},"Fable",{"display_name":"Haiku","utilization":0}]')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Haiku 0%" "$P_CACHE" "$P_SID")"

CASE="an empty model_scoped prints nothing"
run_sl "$(edit '.rate_limits.model_scoped = []')" HOSTNAME=huginn
expect "$BODY"

CASE="a model_scoped that is no array prints nothing"
run_sl "$(edit '.rate_limits.model_scoped = {"display_name":"Fable","utilization":18}')" HOSTNAME=huginn
expect "$BODY"

CASE="a per-model percentage is colored like the other limits"
run_sl "$(edit '.rate_limits.model_scoped = [{"display_name":"Fable","utilization":72,"resets_at":null},{"display_name":"Other","utilization":95,"resets_at":null}]')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Fable ${YELLOW}72%${RESET}" "Other ${RED}95%${RESET}" "$P_CACHE" "$P_SID")"

CASE="control characters in a display_name are dropped"
name=$'Fa\e[2Jble\n'
run_sl "$(fresh | jq -c --arg n "$name" '.rate_limits.model_scoped = [{"display_name":$n,"utilization":18}]')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "Fa[2Jble 18%" "$P_CACHE" "$P_SID")"

# --- the prompt cache ----------------------------------------------------------------------

echo "the prompt cache"

CASE="a warm cache prints its age in minutes, 12 for a 1h cache with 47m30s left"
run_sl "$(fresh)" HOSTNAME=huginn
expect "$BODY"

CASE="a cache written seconds ago reads 0m"
run_sl "$(edit '.prompt_cache.expires_at += 745')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache 0m" "$P_SID")"

CASE="the 5m ttl counts its age from its own length"
run_sl "$(edit '.prompt_cache.ttl = "5m" | .prompt_cache.expires_at -= 2680')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache 2m" "$P_SID")"

CASE="a cache the response reported as not warm is cold, with what the next turn rewrites"
run_sl "$(edit '.prompt_cache.warm = false | .prompt_cache.expires_at = null | .prompt_cache.recache_tokens_if_cold = 180123')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache cold (next turn rewrites ~180k)" "$P_SID")"

CASE="a warm cache past its expiry is cold too, before Claude Code has resent the payload"
run_sl "$(edit '.prompt_cache.expires_at -= 3000')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache cold (next turn rewrites ~37k)" "$P_SID")"

CASE="a cold cache with no size (right after a compaction) says only that it is cold"
run_sl "$(edit '.prompt_cache.warm = false | .prompt_cache.recache_tokens_if_cold = null')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache cold" "$P_SID")"

CASE="a small rewrite is never rounded down to 0k"
run_sl "$(edit '.prompt_cache.warm = false | .prompt_cache.recache_tokens_if_cold = 300')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "cache cold (next turn rewrites ~1k)" "$P_SID")"

CASE="caching_observed false (no caching, or a provider that does not report it) drops the part"
run_sl "$(edit '.prompt_cache.caching_observed = false | .prompt_cache.warm = false')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_SID")"

CASE="no prompt_cache yet (before the first response) drops the part"
run_sl "$(edit 'del(.prompt_cache)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_SID")"

CASE="a prompt_cache that says nothing about warmth drops the part"
run_sl "$(edit 'del(.prompt_cache.warm)')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_SID")"

CASE="an expires_at that is no number on a warm cache drops the part"
run_sl "$(edit '.prompt_cache.expires_at = "soon"')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_SID")"

# --- the usage credits ----------------------------------------------------------------------

echo "the usage credits"

CASE="enabled extra usage prints used and limit in the currency's major unit"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":2000,"used_credits":420,"utilization":21,"currency":"EUR"}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "credits 4.20/20 €" "$P_SID")"

CASE="extra usage that is not enabled prints nothing"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":false,"monthly_limit":2000,"used_credits":420,"currency":"EUR"}')" HOSTNAME=huginn
expect "$BODY"

CASE="a null extra_usage prints nothing"
run_sl "$(edit '.rate_limits.extra_usage = null')" HOSTNAME=huginn
expect "$BODY"

CASE="a limit that is not a whole amount keeps its cents, and 5 cents read 0.05"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":2050,"used_credits":5,"currency":"USD"}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "credits 0.05/20.50 \$" "$P_SID")"

CASE="no monthly limit prints the spend alone, and a currency code without a symbol prints as it is"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":null,"used_credits":1234,"currency":"chf"}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "credits 12.34 CHF" "$P_SID")"

CASE="no currency prints the amounts bare"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":2000,"used_credits":420}')" HOSTNAME=huginn
expect "$(join "$P_MODEL" "$P_CTX" "$P_5H" "$P_WK" "$P_CACHE" "credits 4.20/20" "$P_SID")"

CASE="no used_credits drops the part"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":2000,"used_credits":null,"currency":"EUR"}')" HOSTNAME=huginn
expect "$BODY"

CASE="a used_credits that is a string drops the part"
run_sl "$(edit '.rate_limits.extra_usage = {"is_enabled":true,"monthly_limit":2000,"used_credits":"4.20","currency":"EUR"}')" HOSTNAME=huginn
expect "$BODY"

# --- NO_COLOR --------------------------------------------------------------------

echo "NO_COLOR"

CASE="NO_COLOR=1 prints no escape sequence at all, host tag and limits included"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 95 | .rate_limits.seven_day.used_percentage = 75')" HOSTNAME=build-box NO_COLOR=1
expect "build-box · $(join "$P_MODEL" "$P_CTX" "5h 95% ↻$(hm $FIVE_AT)" "wk 75% ↻$(wd $WEEK_AT)" "$P_CACHE" "$P_SID")"

CASE="an empty NO_COLOR leaves the colors on, as no-color.org defines it"
run_sl "$(edit '.rate_limits.five_hour.used_percentage = 95')" HOSTNAME=build-box NO_COLOR=
expect "$(host_tag build-box) · $(join "$P_MODEL" "$P_CTX" "5h ${RED}95%${RESET} ↻$(hm $FIVE_AT)" "$P_WK" "$P_CACHE" "$P_SID")"

# --- summary ----------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
