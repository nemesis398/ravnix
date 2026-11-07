#!/usr/bin/env bash
# statusline.sh: the Claude Code status line (claude/README.md; the ravnix
# module wires it as the statusLine command). Prints one line, every part
# only when its data exists:
#   [<host> · ][bg · ]<model> <effort> · ctx <n>% · 5h <n>% ↻<HH:MM> ·
#   wk <n>% ↻<Mo> · <Model> <n>% ... · cache <n>m · credits <used>/<limit> € ·
#   <short id>
#
# Why: the line answers "can I keep going, and what does the next turn cost"
# without opening /usage. The limits and the cache age are what otherwise
# surprise a long session, the first as a refusal and the second as a bill.
#
# The host stays on screen only where it tells something. The machines where
# ordinary sessions run are quiet: the skill value statusline.quietHosts
# lists them, each a name without a domain, matched whole and in its case.
# Any other machine prints its name at the front, on the accent fill,
# because a session on another machine or over SSH looks the same as a
# local one otherwise. Where a session runs is place, and place gets the
# accent (docs/style.md): reverse video on the bright magenta slot, which
# the theme gives the accent, so the name takes the terminal's background.
# Without the list, or when it cannot be read, every machine prints its tag:
# a tag too many costs a few columns, a tag too few hides where the session
# runs. The tag prints even when stdin is empty or garbage and jq is missing.
#
# The skill values are the JSON file that RAVNIX_SKILL_VALUES names, else
# ${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json, which the ravnix
# module renders from ravnix.claude.skillValues.
#
# The host is $HOSTNAME without a domain. Bash keeps an inherited HOSTNAME
# (some distributions' /etc/profile export one, and the tests set one), and
# an empty one falls back to the kernel's name. Either way it names the
# machine this script runs on, which is where the session runs.
#
# `bg` marks a background worker. Claude Code removes CLAUDE_CODE_SESSION_KIND
# from the environment of every command it runs, this one included, so the
# script reads it from its parent's environment, which is the claude process.
#
# The rest comes from the session JSON on stdin, in the same jq call that
# reads the quiet hosts:
#   - model.display_name, then effort.level, which is absent on a model
#     without the effort parameter;
#   - context_window.used_percentage, null before the first response. Like
#     the percentage /context prints, it is of autoCompactWindow, not of the
#     model's 1M window: 32k in use at a 500k window reads 6%, not 3%;
#   - rate_limits.five_hour and .seven_day, each {used_percentage, resets_at}
#     with resets_at in epoch seconds, sent to claude.ai subscribers after the
#     first response. A percentage turns yellow at 70 and red at 90, judged on
#     the rounded number that is printed;
#   - prompt_cache, from the first response on: warm, ttl ("5m" or "1h") and
#     expires_at. expires_at minus the ttl is when the cache was last written
#     or read, so its age is now minus that. A cache past expires_at, or not
#     warm, is cold, and recache_tokens_if_cold (null right after a
#     compaction) is what the next turn rewrites. The age moves only when the
#     script runs again, which is after a message, at expires_at, and every
#     refreshInterval seconds if the statusLine setting has one;
#   - the first 8 characters of session_id, the id that `claude --bg` prints
#     and `claude attach` takes.
# Per-model weekly windows (rate_limits.model_scoped[] by display_name, then
# seven_day_opus and seven_day_sonnet, each {utilization, resets_at}) and
# extra_usage (amounts in minor units of its currency) are the shapes of the
# usage reply behind /usage. Claude Code 2.1.302 does not put them into the
# status line payload, so those parts print only once it does.
# Control characters are dropped, so nothing in the JSON can move the cursor.
#
# Claude Code reruns this after every assistant message, shows it only on
# exit 0, and cancels a run the next refresh overtakes. So it starts no
# process but that one jq and always exits 0. NO_COLOR (set and not empty)
# turns the colors off. No set -e or -u: the host must print whatever fails.

# Control characters are dropped from the name, as from the JSON below.
host=${HOSTNAME//[[:cntrl:]]/}
host=${host%%.*}
if [[ -z $host ]]; then
    read -r host 2>/dev/null </proc/sys/kernel/hostname
    host=${host//[[:cntrl:]]/}
    host=${host%%.*}
fi
host=${host:-?}

color_on=1
[[ -n ${NO_COLOR:-} ]] && color_on=""

values=${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/skill-values.json}
[[ -f $values && -r $values ]] || values=/dev/null

kind=${CLAUDE_CODE_SESSION_KIND:-}
if [[ -z $kind ]] && mapfile -d '' -t parent_env 2>/dev/null </proc/"$PPID"/environ; then
    for kv in "${parent_env[@]}"; do
        if [[ $kv == CLAUDE_CODE_SESSION_KIND=* ]]; then
            kind=${kv#*=}
            break
        fi
    done
fi
# One output line: q when the host is quiet and t when it gets its tag, a
# tab, and the parts joined. Only the first JSON value on stdin is read, and
# input that does not parse counts as none. Every path step carries a ?, so a
# field of the wrong type, or input that is no object at all, drops a part
# instead of failing; values that do not parse, or hold no list of names,
# make no host quiet. The jq variables ($c, $n, ...) must reach jq
# unexpanded.
# shellcheck disable=SC2016
prog='
def quiet:
    ($values | try fromjson catch null)
    | [(objects | .statusline? | objects | .quietHosts? | arrays | .[] | strings)]
    | any(.[]; . == $host);
def text(f): ((f)? | select(type == "string")) // "" | gsub("[[:cntrl:]]"; "");
def used: (.used_percentage? // .utilization?) | numbers;
def lim:
    round as $n
    | (if $n >= 90 then "\u001b[1;31m" elif $n >= 70 then "\u001b[33m" else "" end) as $k
    | if $k != "" and $c != "" then "\($k)\($n)%\u001b[0m" else "\($n)%" end;
def hm: strflocaltime("%H:%M");
def wd: localtime | ["Su","Mo","Tu","We","Th","Fr","Sa"][.[6]];
def win(name; fmt):
    objects as $o
    | ($o | used) as $p
    | (($o | .resets_at? | numbers | fmt)? // "") as $r
    | "\(name) \($p | lim)" + (if $r != "" then " ↻\($r)" else "" end);
def cents: [round, 0] | max | . as $m | "\($m / 100 | floor).\(("0" + "\($m % 100)")[-2:])";
def cold($p):
    "cache cold" + ((($p | .recache_tokens_if_cold | numbers | select(. > 0)) // null)
        | if . then " (next turn rewrites ~\([(. / 1000 | round), 1] | max)k)" else "" end);
def cache:
    (.prompt_cache? | objects | select(.caching_observed != false)) as $p
    | $p.warm as $warm
    | (if ($p.expires_at | type) == "number" then $p.expires_at else null end) as $exp
    | ({"5m": 300, "1h": 3600}[($p.ttl | strings) // ""] // 3600) as $ttl
    | now as $now
    | if $warm == true and $exp != null and $exp > $now then
          "cache \([$now - ($exp - $ttl), 0] | max | . / 60 | floor)m"
      elif $warm == false or ($warm == true and $exp != null) then cold($p)
      else empty end;
def credits:
    (.rate_limits? | objects | .extra_usage? | objects | select(.is_enabled == true)) as $x
    | ($x | .used_credits? | numbers) as $u
    | (($x | .monthly_limit? | numbers) // null) as $l
    | (text($x | .currency) | .[0:8] | ascii_upcase) as $cur
    | "credits " + ($u | cents)
      + (if $l then "/" + ($l | round | if . % 100 == 0 then "\(. / 100)" else cents end) else "" end)
      + ({"EUR": " €", "USD": " $", "GBP": " £"}[$cur] // (if $cur != "" then " " + $cur else "" end));
def scoped:
    ((.rate_limits? | objects | .model_scoped? | arrays | .[] | objects) as $m
        | {n: text($m | .display_name), o: $m}),
    (.rate_limits? | objects
        | (.seven_day_opus? | objects | {n: "Opus", o: .}),
          (.seven_day_sonnet? | objects | {n: "Sonnet", o: .}))
    | select(.n != "" and (.o | used) != null);
def body:
[ (text(.model?.display_name) as $m | text(.effort?.level) as $e
       | if $m != "" and $e != "" then "\($m) \($e)" else $m end),
  (((.context_window?.used_percentage)? | numbers | round | "ctx \(.)%")),
  (.rate_limits? | objects | .five_hour? | win("5h"; hm)),
  (.rate_limits? | objects | .seven_day? | win("wk"; wd)),
  ([scoped] | reduce .[] as $e ([]; if any(.[]; .n == $e.n) then . else . + [$e] end)
      | .[] | "\(.n) \(.o | used | lim)"),
  cache,
  credits,
  (text(.session_id) | .[0:8])
] | map(select(. != "")) | join(" · ");

(try input catch null) as $in
| "\(if quiet then "q" else "t" end)\t\($in | body)"'
quiet="" body=""
IFS=$'\t' read -r quiet body <<<"$(jq -nr --arg c "$color_on" --arg host "$host" \
    --rawfile values "$values" "$prog" 2>/dev/null)"

line=""
if [[ $quiet != q ]]; then
    if [[ -n $color_on ]]; then
        line=$'\e[7;95m'$host$'\e[0m'
    else
        line=$host
    fi
fi
[[ $kind == bg ]] && line+=${line:+ · }bg
[[ -n $body ]] && line+=${line:+ · }$body

printf '%s\n' "$line"
exit 0
