#!/usr/bin/env bash
# sync-hooks.sh: puts ravnix's hook entries into Claude Code's settings
# file, an activation step of homeModules.claude-code (claude/README.md).
#
#   sync-hooks.sh SETTINGS PREFIX ENTRIES [STORE]
#
# SETTINGS is the settings file, PREFIX the directory every command of
# ravnix's hooks starts with (<configDir>/ravnix/), ENTRIES a JSON object of
# ravnix's entries by event, and STORE the Nix store (default /nix/store).
#
# Why not home-manager's own merge: it merges the declared settings into the
# file with `$dynamic * $static`, which replaces a whole array. Declaring
# hooks there would drop, at every switch, each entry another tool wrote
# under the same event, such as herdr's SessionStart entry, and would leave
# behind the entries of a hook that ravnix no longer declares.
#
# So a hook is ravnix's when its command starts with PREFIX, quoted or not;
# only ravnix writes there. The step removes every such hook, adds ENTRIES,
# and drops a group, an event or the hooks key left empty. Every other hook
# and every other key stays as it was, and a second run changes nothing.
# A file whose JSON would not change is not written at all, so its own
# layout stays too.
#
# ENTRIES must hold ravnix's own hooks only: command hooks whose command
# starts with PREFIX, in groups with at least one hook. Anything else would
# not be told as ravnix's at the next run, and would be added once more at
# every switch, so the step refuses it and changes nothing.
#
# The file: a missing or zero-byte one counts as {}, and a missing one is made
# only when there is something to add, with mode 600. An existing one keeps
# its mode. A symlink is followed and the file it names updated, unless that
# file is in the store, where home-manager owns it whole (immutable
# settings), and then it is left alone. Settings it cannot read (broken
# JSON, no document or two, no object, hooks that are no object) fail the
# step and stay as they were.
#
# Claude Code writes the file too, at any time. How the step changes it
# without losing such a write (a lock beside the file, a copy it compares
# before the move, exactly one JSON document) is cas.sh, which it shares with
# sync-mcp.sh. What is left is the moment between the last comparison and the
# move (README, Known gaps).
#
# Tests: tests/sync-hooks.test.sh, run with bash and no arguments.

set -u

file=$1 prefix=$2 entries=$3 store=${4:-/nix/store}

fail() {
    printf 'ravnix: cannot put the Claude Code hooks into %s: %s\n' "$file" "$1" >&2
    exit 1
}

# cas.sh sits beside this file. ${BASH_SOURCE[0]%/*} is the name itself when
# the step is run by its bare name from its own directory, hence the ".".
here=${BASH_SOURCE[0]%/*}
[[ $here != "${BASH_SOURCE[0]}" ]] || here=.
# A failed `.` does not stop a script, and everything below needs cas.sh.
# shellcheck source=claude/settings/cas.sh
. "$here/cas.sh" || {
    printf 'ravnix: cannot load cas.sh from %s\n' "$here" >&2
    exit 1
}

# shellcheck disable=SC2016  # the $ are jq's
mine='def mine: type == "object" and ((.command? // "") | tostring | ltrimstr("'"'"'") | startswith($prefix));'

# shellcheck disable=SC2016
jq -e --arg prefix "$prefix" "$mine"'
    type == "object" and all(.[];
        type == "array" and all(.[];
            type == "object" and (.hooks | type) == "array" and (.hooks | length) > 0
            and all(.hooks[]; mine and .type == "command" and (.command | type) == "string")))' \
    "$entries" >/dev/null 2>&1 ||
    fail "$entries holds something other than ravnix's own command hooks under $prefix"

cas_resolve "$file" "$store" || exit 0

if [[ ! -e $cas_target ]] && [[ $(jq 'length' "$entries") == 0 ]]; then
    exit 0
fi

# shellcheck disable=SC2016
filter="$mine"'
def strip:
    if type == "object" and (.hooks | type) == "array"
    then .hooks |= map(select(mine | not)) | select(.hooks != [])
    else . end;
if type != "object" then error("the settings are no JSON object") else . end
| (.hooks // {}) as $old
| if ($old | type) != "object" then error("its hooks are no JSON object") else . end
| ($old | map_values(if type == "array" then map(strip) else . end)) as $kept
| (reduce ($ours[0] | to_entries[]) as $e ($kept; .[$e.key] = ((.[$e.key] // []) + $e.value))
   | with_entries(select(.value != []))) as $hooks
| if $hooks == {} then del(.hooks) else .hooks = $hooks end'

cas_apply "$file" "$filter" --arg prefix "$prefix" --slurpfile ours "$entries"
