#!/usr/bin/env bash
# web-route.sh: PreToolUse hook for WebSearch (claude/README.md; the ravnix
# module wires it with the matcher "WebSearch"). While the user's SearXNG
# answers, it denies the built-in WebSearch and tells the model to run
# `searx '<query>'` through Bash instead. While SearXNG does not answer, or no
# SearXNG is configured, it says nothing and WebSearch runs as usual.
#
# Why: SearXNG returns the raw hits from engines the user chose, and the
# `searx` CLI cuts them to a list of title, URL and snippet. WebSearch stays as
# the fallback, because a search that cannot run is worse than one that runs
# the old way.
#
# The base URL is SEARXNG_URL, as it is for `searx`, else the skill value
# web.searxngUrl, read from RAVNIX_SKILL_VALUES, else from
# ${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json, which the ravnix
# module renders from ravnix.claude.skillValues. With neither it routes
# nothing and probes nothing.
#
# The probe is GET $SEARXNG_URL/healthz with a 2 second limit, and any 2xx
# counts as up. The answer is cached for 60 seconds in
# $XDG_STATE_HOME/web-route/reachable (default ~/.local/state), one line:
#
#   <epoch seconds> <up|down>
#
# so a burst of searches costs one probe, and a down answer costs nothing for
# the next minute. The epoch is in the file, not in its mtime, so the check
# needs no process and a test can write an old entry. `searx` writes the same
# file with "down" when a search fails: /healthz can answer while /search does
# not (json switched off, the limiter, an error page from a proxy), and without
# that the model would be bounced to `searx`, fail, and be bounced again.
#
# Fails open on everything: a missing curl or jq, a missing `searx` (denying
# would leave the model with no search at all), no URL, unreadable input or
# skill values, an unwritable state directory, a query that is empty. Every
# one of them prints nothing and exits 0. It never exits 2, because that would
# block the call.
#
# The deny uses hookSpecificOutput.permissionDecision, the PreToolUse format
# in https://code.claude.com/docs/en/hooks. The reason reaches the model, so it
# carries the command to run, with the query single-quoted so a query with a
# quote or a $ survives the shell. The call's allowed_domains and
# blocked_domains have no flag in `searx`; SearXNG takes them as site: terms in
# the query, and the reason says so.
#
# Tests: tests/web-route.test.sh, run with bash and no arguments.

set -u

state=${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/web-route
cache=$state/reachable
ttl=60

# Nothing to route to without the CLI, the probe or the JSON tool. The explicit
# path covers a hook whose PATH lacks ~/.local/bin while the Bash tool's has it.
command -v curl >/dev/null && command -v jq >/dev/null || exit 0
command -v searx >/dev/null || [[ -x ${HOME:-/nonexistent}/.local/bin/searx ]] || exit 0

base=${SEARXNG_URL:-}
if [[ -z $base ]]; then
    values=${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/ravnix/skill-values.json}
    [[ -f $values && -r $values ]] &&
        base=$(jq -r '(.web.searxngUrl)? | strings' "$values" 2>/dev/null </dev/null)
fi
base=${base%/}
# A URL with white space or a control character in it is no URL to probe.
[[ -n $base && $base != *[[:space:][:cntrl:]]* ]] || exit 0

printf -v now '%(%s)T' -1
status=""
if read -r stamp word 2>/dev/null <"$cache" \
    && [[ $stamp =~ ^[0-9]+$ && $word =~ ^(up|down)$ ]] \
    && ((now >= stamp && now - stamp < ttl)); then
    status=$word
else
    code=$(curl -s -o /dev/null --connect-timeout 2 --max-time 2 \
        -w '%{http_code}' "$base/healthz" </dev/null 2>/dev/null)
    [[ $code == 2?? ]] && status=up || status=down
    # The braces come first so the shell's own "no such directory" goes to
    # /dev/null too: a redirection is opened before a later 2> takes effect.
    if { [[ -d $state ]] || mkdir -p "$state"; } 2>/dev/null \
        && { printf '%s %s\n' "$now" "$status" >"$cache.$$"; } 2>/dev/null; then
        mv -f "$cache.$$" "$cache" 2>/dev/null
    fi
    rm -f "$cache.$$" 2>/dev/null
fi
[[ $status == up ]] || exit 0

# SearXNG answers, so build the deny from the hook input on stdin. Anything
# jq cannot read, or any call that is not a WebSearch with a query, produces
# no output and so no decision. The query and the domains are cleaned first:
# control and separator characters become single spaces, the way `searx` cleans
# its output, and a domain must look like one.
jq -c --arg sq "'" '
    def clean: tostring | gsub("[\\p{Cc}\\p{Cf}\\p{Z}]+"; " ") | sub("^ "; "") | sub(" $"; "");
    def domains($k): [(.tool_input[$k] // [])[]? | clean | select(test("^[A-Za-z0-9._-]+$"))];
    select(.tool_name == "WebSearch")
    | ((.tool_input.query // "") | clean) as $q
    | select($q != "")
    | (domains("allowed_domains") | map("site:" + .) | join(" OR ")) as $allow
    | (domains("blocked_domains") | map("-site:" + .) | join(" ")) as $block
    | ([$allow, $block] | map(select(. != "")) | join(" ")) as $terms
    | "WebSearch is replaced by the self-hosted SearXNG while it answers, and it answers now. Run this through Bash instead:\n\n"
      + "  searx " + $sq + ($q | split($sq) | join($sq + "\\" + $sq + $sq)) + $sq + "\n\n"
      + "It prints numbered hits (title, URL, snippet). -n N asks for more than 8, -t day|week|month|year limits the age, -l de picks a language, -c it|science|news a category. "
      + "To read a hit, use defuddle or WebFetch. If searx exits 2, SearXNG is down: run WebSearch again, which is let through for the next minute."
      + (if $terms == "" then ""
         else "\nThe call asked to filter by domain; put this in the query: " + $terms end)
    | {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: .}}
' 2>/dev/null
exit 0
