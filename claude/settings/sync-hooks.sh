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
# The file: a missing or empty one counts as {}, and a missing one is made
# only when there is something to add, with mode 600. An existing one keeps
# its mode. A symlink is followed and the file it names updated, unless that
# file is in the store, where home-manager owns it whole (immutable
# settings), and then it is left alone. Settings it cannot read (broken
# JSON, no object, hooks that are no object) fail the step and stay as they
# were.
#
# Claude Code writes the file too, at any time and without a lock. So the
# step reads a copy, builds the new file beside it, and moves it into place
# only while the file is still byte for byte the copy it read; when it is
# not, the step reads it again, up to five times, and then fails without
# writing. A file the move cannot replace, a mount point, is written in
# place. What is left is the moment between that last comparison and the
# move (README, Known gaps).
#
# Tests: tests/sync-hooks.test.sh, run with bash and no arguments.

set -u

file=$1 prefix=$2 entries=$3 store=${4:-/nix/store}

fail() {
    printf 'ravnix: cannot put the Claude Code hooks into %s: %s\n' "$file" "$1" >&2
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

target=$file
if [[ -L $file ]]; then
    target=$(readlink -f -- "$file") || fail "the symlink names nothing"
    [[ $target != "$store"/* ]] || exit 0
fi

if [[ ! -e $target ]] && [[ $(jq 'length' "$entries") == 0 ]]; then
    exit 0
fi

dir=${target%/*}
mkdir -p -- "$dir" || fail "cannot make $dir"
copy=$(mktemp "$target.ravnix.XXXXXX") || fail "cannot write beside it"
tmp=$(mktemp "$target.ravnix.XXXXXX") || { rm -f -- "$copy"; fail "cannot write beside it"; }
trap 'rm -f -- "$copy" "$tmp" "$tmp.err"' EXIT

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

for _ in 1 2 3 4 5; do
    # The copy this try reads, with the file's mode; none when it is missing.
    had=""
    if [[ -e $target ]]; then
        cp -p -- "$target" "$copy" || fail "cannot read it"
        had=1
    fi

    if [[ -n $had && -s $copy ]]; then
        jq --arg prefix "$prefix" --slurpfile ours "$entries" "$filter" "$copy" >"$tmp" 2>"$tmp.err"
    else
        jq -n --arg prefix "$prefix" --slurpfile ours "$entries" "{} | $filter" >"$tmp" 2>"$tmp.err"
    fi
    status=$?
    why=$(<"$tmp.err")
    [[ $status == 0 ]] || fail "${why:-jq failed}"

    if [[ -n $had ]]; then
        # Unchanged as JSON: the file stays as it is, byte for byte. With
        # Claude Code off no merge reformats it first, and nothing here
        # should either.
        jq -e -n --slurpfile new "$tmp" --slurpfile old "$copy" \
            '$new == $old or ($old == [] and $new == [{}])' >/dev/null 2>&1 && exit 0
        chmod --reference="$copy" -- "$tmp" || fail "cannot keep its mode"
        if [[ ! -f $target ]] || ! cmp -s -- "$copy" "$target"; then
            continue
        fi
    else
        chmod 600 -- "$tmp" || fail "cannot set its mode"
        [[ ! -e $target && ! -L $target ]] || continue
    fi

    # rename(2) fails with EBUSY when the file is a mount point, as a file
    # bind-mounted by impermanence is; then it is written in place, as
    # home-manager's own merge does.
    mv -fT -- "$tmp" "$target" 2>/dev/null || cat -- "$tmp" >"$target" ||
        fail "cannot write the new file"
    exit 0
done

fail "it changed during each of five tries, written at the same time by another program, such as a running Claude Code; it stays as that program left it"
