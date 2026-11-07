#!/usr/bin/env bash
# sync-mcp.sh: puts ravnix's MCP servers into Claude Code's user-scope
# config, an activation step of homeModules.claude-code (claude/README.md).
#
#   sync-mcp.sh CONFIG STATE SERVERS [STORE]
#
# CONFIG is Claude Code's own config file (~/.claude.json, or
# <configDir>/.claude.json when the config directory is not ~/.claude),
# STATE the file where this step records which servers it put in, SERVERS a
# JSON object of ravnix's servers by name, each the JSON object that Claude
# Code's mcpServers holds, and STORE the Nix store (default /nix/store).
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
# Claude Code writes CONFIG too, often and without a lock. So the step reads
# a copy, builds the new file beside it, and moves it into place only while
# CONFIG is still byte for byte the copy it read; when it is not, the step
# reads it again, up to five times, and then fails without writing. A file
# the move cannot replace, a mount point, is written in place. What is left
# is the moment between that last comparison and the move (README, Known
# gaps).
#
# STATE is written around that: before CONFIG with the old names and the new
# ones, so that a run that dies half-way still knows every server it may
# have put in, and after it with the new ones only.
#
# Tests: tests/sync-mcp.test.sh, run with bash and no arguments.

set -u

file=$1 state=$2 servers=$3 store=${4:-/nix/store}

fail() {
    printf 'ravnix: cannot put the MCP servers into %s: %s\n' "$file" "$1" >&2
    exit 1
}

jq -e 'type == "object" and all(.[]; type == "object")' "$servers" >/dev/null 2>&1 ||
    fail "$servers holds something other than a JSON object of servers"

# The names recorded by the last run, as a sorted JSON list. An empty or
# missing file records none.
prev='[]'
if [[ -s $state ]]; then
    # shellcheck disable=SC2016  # the $ are jq's
    prev=$(jq -ec 'if type == "array" and all(.[]; type == "string") then unique else error("no list of names") end' "$state" 2>/dev/null) ||
        fail "$state is not a JSON list of server names; delete it to start over, and the servers ravnix put in earlier stay until claude mcp remove"
fi
names=$(jq -c 'keys' "$servers") || fail "cannot read $servers"
# shellcheck disable=SC2016
union=$(jq -cn --argjson a "$prev" --argjson b "$names" '$a + $b | unique')

# write_state <JSON list>: the state file with these names, unless it holds
# them already. None is made for an empty list.
write_state() {
    local want=$1 cur='' stmp
    if [[ -s $state ]]; then cur=$(jq -c 'unique' "$state"); fi
    [[ $cur == "$want" ]] && return 0
    [[ $want == '[]' && ! -e $state ]] && return 0
    mkdir -p -- "${state%/*}" || fail "cannot make ${state%/*}"
    stmp=$(mktemp "$state.XXXXXX") || fail "cannot write beside $state"
    if ! { printf '%s\n' "$want" >"$stmp" && mv -fT -- "$stmp" "$state"; }; then
        rm -f -- "$stmp"
        fail "cannot write $state"
    fi
}

target=$file
if [[ -L $file ]]; then
    target=$(readlink -f -- "$file") || fail "the symlink names nothing"
    [[ $target != "$store"/* ]] || exit 0
fi

if [[ ! -e $target && $names == '[]' ]]; then
    write_state "$names"
    exit 0
fi

# Before the file, so that no server in it is ever missing from the state.
if [[ $union != "$prev" ]]; then write_state "$union"; fi

dir=${target%/*}
mkdir -p -- "$dir" || fail "cannot make $dir"
copy=$(mktemp "$target.ravnix.XXXXXX") || fail "cannot write beside it"
tmp=$(mktemp "$target.ravnix.XXXXXX") || { rm -f -- "$copy"; fail "cannot write beside it"; }
trap 'rm -f -- "$copy" "$tmp" "$tmp.err"' EXIT

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

finished=
for _ in 1 2 3 4 5; do
    # The copy this try reads, with the file's mode; none when it is missing.
    had=""
    if [[ -e $target ]]; then
        cp -p -- "$target" "$copy" || fail "cannot read it"
        had=1
    fi

    if [[ -n $had && -s $copy ]]; then
        jq --argjson prev "$prev" --slurpfile ours "$servers" "$filter" "$copy" >"$tmp" 2>"$tmp.err"
    else
        jq -n --argjson prev "$prev" --slurpfile ours "$servers" "{} | $filter" >"$tmp" 2>"$tmp.err"
    fi
    status=$?
    why=$(<"$tmp.err")
    [[ $status == 0 ]] || fail "${why:-jq failed}"

    if [[ -n $had ]]; then
        # Unchanged as JSON: the file stays as it is, byte for byte.
        if jq -e -n --slurpfile new "$tmp" --slurpfile old "$copy" \
            '$new == $old or ($old == [] and $new == [{}])' >/dev/null 2>&1; then
            finished=1
            break
        fi
        chmod --reference="$copy" -- "$tmp" || fail "cannot keep its mode"
        if [[ ! -f $target ]] || ! cmp -s -- "$copy" "$target"; then
            continue
        fi
    else
        chmod 600 -- "$tmp" || fail "cannot set its mode"
        [[ ! -e $target && ! -L $target ]] || continue
    fi

    # rename(2) fails with EBUSY when the file is a mount point; then it is
    # written in place, as home-manager's own merge does.
    mv -fT -- "$tmp" "$target" 2>/dev/null || cat -- "$tmp" >"$target" ||
        fail "cannot write the new file"
    finished=1
    break
done

[[ -n $finished ]] ||
    fail "it changed during each of five tries, written at the same time by another program, such as a running Claude Code; it stays as that program left it"

write_state "$names"
