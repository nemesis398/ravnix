#!/usr/bin/env bash
# sync-mcp.sh: puts ravnix's MCP servers into Claude Code's user-scope
# config, an activation step of homeModules.claude-code (claude/README.md).
#
#   sync-mcp.sh CONFIG STATE SERVERS [STORE [LEGACY]]
#
# CONFIG is Claude Code's own config file (~/.claude.json, or
# <configDir>/.claude.json when the config directory is not ~/.claude),
# STATE the file where this step records which servers it put in, SERVERS a
# JSON object of ravnix's servers by name, each the JSON object that Claude
# Code's mcpServers holds, STORE the Nix store (default /nix/store), and
# LEGACY the path of the old <configDir>/.config.json (none: not checked).
#
# Why not home-manager's programs.claude-code.mcpServers: it renders the
# servers into a plugin of its own, which Claude Code reports in the scope
# "plugin" under the name plugin:hm:NAME, and whose tools are called
# mcp__plugin_hm_NAME__TOOL instead of mcp__NAME__TOOL. Every permission rule
# and skill that names a server's tools would stop matching. A server in the
# user scope, which is where `claude mcp add --scope user` puts one, keeps
# its name and its tools, and `claude mcp remove` and `claude mcp get` work
# on it.
#
# What it does: removes from CONFIG's mcpServers the servers STATE names
# that SERVERS no longer declares, puts every server of SERVERS in, replacing
# a server of the same name whole, and records the names of SERVERS in STATE.
# Every other server (one that `claude mcp add` wrote) and every other key
# stays as it was, and a second run changes nothing. A server in a project's
# own list (projects.PATH.mcpServers, the local scope) is not touched. A
# server is told as ravnix's by its name in STATE, since Claude Code may drop
# a marker inside the entry; a file of STATE lost means that servers dropped
# from SERVERS afterwards stay until `claude mcp remove`.
#
# A file whose JSON would not change is not written at all, so its own
# layout stays too, and a run with nothing declared and nothing recorded
# neither makes CONFIG nor STATE.
#
# The values: SERVERS comes from the Nix store, and its headers and
# variables are references (`Bearer ${NAME}`) that Claude Code resolves from
# its environment; the module refuses anything else at evaluation
# (modules/options/claude.nix). This step checks only the shape, an object
# of objects.
#
# The file: a missing or empty one counts as {}, and a missing one is made
# only when there is something to add, with mode 600, as Claude Code makes
# it. An existing one keeps its mode. A symlink is followed and the file it
# names updated, unless that file is in the store, where it cannot be
# written. A config it cannot read (broken JSON, no object, an mcpServers
# that is no object) fails the step and stays as it was.
#
# Claude Code writes CONFIG too, often. How the step changes it without
# losing such a write is cas.sh, which it shares with sync-hooks.sh: Claude
# Code saves CONFIG under a lock (a directory CONFIG.lock, made with mkdir),
# re-reading the file under it, so the step takes the same lock, on CONFIG as
# given, and keeps it until the new file is in place; it also compares a copy
# before the move, for writers that take no lock. The config must be exactly
# one JSON document. What is left is two programs that take a stale lock in
# the same moment, and a writer that takes no lock and writes between the
# step's last comparison and its move (README, Known gaps).
#
# STATE is written around that: before CONFIG with the old names and the new
# ones, so that a run that dies half-way still knows every server it may
# have put in, and after it with the new ones only. It must be exactly one
# JSON list of names as well, or the step fails and leaves it as it was.
#
# Two places where Claude Code may not read CONFIG at all, and the step says
# so on stderr (it still writes CONFIG): with LEGACY, an old
# <configDir>/.config.json, which Claude Code 2.1.319 reads instead of CONFIG
# when it is not empty, or when it is writable and CONFIG does not exist yet;
# and with CLAUDE_CODE_CUSTOM_OAUTH_URL set, when it reads
# .claude-custom-oauth.json instead. A CONFIG that is a link into the store is
# left alone with a message as well.
#
# Tests: tests/sync-mcp.test.sh, run with bash and no arguments.

set -u

file=$1 state=$2 servers=$3 store=${4:-/nix/store} legacy=${5:-}

fail() {
    printf 'ravnix: cannot put the MCP servers into %s: %s\n' "$file" "$1" >&2
    exit 1
}

warn() {
    printf 'ravnix: %s\n' "$1" >&2
}

# shellcheck source=claude/settings/cas.sh
. "${BASH_SOURCE[0]%/*}/cas.sh"

jq -es 'length == 1 and (.[0] | type == "object" and all(.[]; type == "object"))' "$servers" >/dev/null 2>&1 ||
    fail "$servers holds something other than one JSON object of servers"

# names_in FILE: the names in a state file, sorted, as a compact JSON list.
# Fails unless the file is exactly one JSON list of strings.
# shellcheck disable=SC2016  # the $ are jq's
names_in() {
    jq -sec 'if length == 1 and (.[0] | type == "array" and all(.[]; type == "string"))
        then .[0] | unique else error("no list of names") end' "$1" 2>/dev/null
}

# The names recorded by the last run. An empty (zero-byte) or missing file
# records none.
prev='[]'
if [[ -s $state ]]; then
    prev=$(names_in "$state") ||
        fail "$state is not one JSON list of server names; delete it to start over, and the servers ravnix put in earlier stay until claude mcp remove"
fi
names=$(jq -c 'keys' "$servers") || fail "cannot read $servers"
# shellcheck disable=SC2016
union=$(jq -cn --argjson a "$prev" --argjson b "$names" '$a + $b | unique') ||
    fail "cannot join the names in $state with those in $servers"

# write_state <JSON list>: the state file with these names, unless it holds
# them already. None is made for an empty list.
write_state() {
    local want=$1 cur='' stmp
    if [[ -s $state ]]; then
        cur=$(names_in "$state") || fail "$state is not one JSON list of server names"
    fi
    [[ $cur == "$want" ]] && return 0
    [[ $want == '[]' && ! -e $state ]] && return 0
    mkdir -p -- "${state%/*}" || fail "cannot make ${state%/*}"
    stmp=$(mktemp "$state.XXXXXX") || fail "cannot write beside $state"
    if ! { printf '%s\n' "$want" >"$stmp" && mv -fT -- "$stmp" "$state"; }; then
        rm -f -- "$stmp"
        fail "cannot write $state"
    fi
}

if ! cas_resolve "$file" "$store"; then
    warn "not putting the MCP servers into $file: it is a link into the Nix store ($cas_target), which cannot be written"
    exit 0
fi

if [[ ! -e $cas_target && $names == '[]' ]]; then
    write_state "$names"
    exit 0
fi

# Where Claude Code may read something else (see the header).
if [[ -n $legacy && -f $legacy ]]; then
    if [[ -s $legacy ]] || { (( 0$(stat -c %a -- "$legacy") & 0222 )) && [[ ! -e $cas_target ]]; }; then
        warn "Claude Code reads $legacy instead of $file while that old file stays as it is, so the MCP servers put into $file may not show; move its content into $file or remove it"
    fi
fi
if [[ -n ${CLAUDE_CODE_CUSTOM_OAUTH_URL-} ]]; then
    warn "CLAUDE_CODE_CUSTOM_OAUTH_URL is set, and then Claude Code reads ${file%.json}-custom-oauth.json instead of $file, so the MCP servers put into $file may not show"
fi

# Before the file, so that no server in it is ever missing from the state.
if [[ $union != "$prev" ]]; then write_state "$union"; fi

# $ours[0] is the declared servers, $prev the names this step wrote last.
# Position stays where it was for a server that is replaced, and a new one
# goes last. An empty mcpServers that was not there is not made.
# shellcheck disable=SC2016
filter='
if type != "object" then error("the config is no JSON object") else . end
| (.mcpServers // {}) as $old
| if ($old | type) != "object" then error("its mcpServers are no JSON object") else . end
| ($ours[0] | keys) as $declared
| ($prev - $declared) as $drop
| ($old | with_entries(select(.key | IN($drop[]) | not)) + $ours[0]) as $new
| if $new == {} and has("mcpServers") == false then . else .mcpServers = $new end'

cas_apply "$file" "$filter" --argjson prev "$prev" --slurpfile ours "$servers"

write_state "$names"
