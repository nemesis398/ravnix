#!/usr/bin/env bash
# Tests for machine-facts (packages/machine-facts), run by the check
# bin-machine-facts. It reads the machine it runs on, so the cases do not assert
# what the facts are (a build sandbox is no laptop) but what the script does with
# a note: it works only on the block between the two markers, leaves everything
# else byte for byte, treats the live readings as no drift, and refuses a note
# without markers. The sections that cannot read their sources must degrade to
# an empty value and go on.
#
# MACHINE_FACTS_UNDER_TEST=<file> tests another copy; by default it is the
# machine-facts on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=$(readlink -f "${MACHINE_FACTS_UNDER_TEST:-$(type -P machine-facts)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/machine-facts-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/home" "$SB/tmp"
BEGIN='<!-- machine-facts:begin -->' END='<!-- machine-facts:end -->'
VB='<!-- volatile:begin -->' VE='<!-- volatile:end -->'

# run [ENV=VAL ...] -- ARGS: sets $out (stdout), $err, $rc.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    out=$(env -i HOME="$SB/home" TMPDIR="$SB/tmp" PATH="$PATH" "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>"$SB/err")
    rc=$?
    err=$(<"$SB/err")
    # The sandbox has no /etc/machine-id, which one section says on stderr; the
    # script's own messages are what the cases are about.
    err=$(grep -v '^cut: /etc/machine-id' <<<"$err")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:600}
    err: $err"; fi; }

echo "machine-facts"

run -- --help
check "--help prints the header: what it is for, the modes and MACHINE_NOTE" \
    '[[ $rc == 0 && $out == "machine-facts: print the volatile state"* && $out == *"--check"* && $out == *"MACHINE_NOTE"* && $out != *"set -uo pipefail"* ]]'
run -- --bogus
check "an unknown option exits 2 and says so" '[[ $rc == 2 && $err == "unknown option: --bogus (try --help)" ]]'

run --
check "with no argument it prints the block between its markers" \
    '[[ $rc == 0 && $out == "$BEGIN"* && $out == *"$END" ]]'
check "the block has its sections, and the live readings in a region of their own" \
    '[[ $out == *"### Identity"* && $out == *"### Disks"* && $out == *"### Boot chain"* && $out == *"### GPU"* && $out == *"### Right now"* && $out == *"$VB"* && $out == *"$VE"* ]]'
check "nothing of the Fedora system is claimed: no rpm, tuned, flatpak or stow row" \
    '[[ $out != *"tuned"* && $out != *"Flatpak"* && $out != *"Stow"* && $out != *"power-profiles-daemon"* ]]'
check "a section that cannot read its source is empty, not an error: stderr is quiet about sudo" '[[ $err != *"sudo"* ]]'

for mode in --write --check --diff; do
    run -- "$mode"
    check "$mode without MACHINE_NOTE says what to set, exits 2 and touches nothing" \
        '[[ $rc == 2 && $err == "no note: set MACHINE_NOTE, or ravnix.scripts.machineFacts.note" ]]'
done
run MACHINE_NOTE="$SB/missing.md" -- --check
check "a note that is not there is named, exit 2" '[[ $rc == 2 && $err == "note not found: $SB/missing.md" ]]'

NOTE="$SB/note.md"
printf '# Laptop\n\nHand-written above.\n\nNo markers here.\n' >"$NOTE"
before=$(<"$NOTE")
run MACHINE_NOTE="$NOTE" -- --write
check "a note without markers is refused, says where to put them, and is not touched" \
    '[[ $rc == 2 && $err == *"markers not found"* && $err == *"$BEGIN"* && $err == *"$END"* && $(<"$NOTE") == "$before" ]]'
printf '%s\n' "$BEGIN" "Only a begin." >"$NOTE"
run MACHINE_NOTE="$NOTE" -- --write
check "a note with only one marker is refused as well" '[[ $rc == 2 && $err == *"markers not found"* ]]'

printf '# Laptop\n\nHand-written above.\n\n%s\nold block\n%s\n\nHand-written below, with ünïcode and a trailing space \n' "$BEGIN" "$END" >"$NOTE"
run MACHINE_NOTE="$NOTE" -- --diff
check "--diff shows the change and leaves the note alone" \
    '[[ $rc == 0 && $out == *"-old block"* && $(grep -c "^old block$" "$NOTE") == 1 ]]'
run MACHINE_NOTE="$NOTE" -- --check
check "--check on a stale block exits 1 and says DRIFT" '[[ $rc == 1 && $err == *"DRIFT: "* ]]'
run MACHINE_NOTE="$NOTE" -- --write
check "--write says it updated the note" '[[ $rc == 0 && $out == "updated: $NOTE" ]]'
check "above and below the markers the note is byte for byte what it was" \
    '[[ $(sed -n "1,3p" "$NOTE") == $'"'"'# Laptop\n\nHand-written above.'"'"' && $(sed -n "4p" "$NOTE") == "" && $(tail -n 1 "$NOTE") == "Hand-written below, with ünïcode and a trailing space " ]]'
check "inside, the old block is gone and the new one is there" \
    '! grep -q "^old block$" "$NOTE" && grep -q "^### Identity$" "$NOTE" && [[ $(grep -cxF "$BEGIN" "$NOTE") == 1 && $(grep -cxF "$END" "$NOTE") == 1 ]]'
run MACHINE_NOTE="$NOTE" -- --check
check "right after a write the note is current" '[[ $rc == 0 && $out == "note is current" ]]'

cp "$NOTE" "$SB/written.md"
sed -i "/$VB/,/$VE/s/^\*Snapshot taken.*/*Snapshot taken long ago.*/; s/^- Battery: .*/- Battery: 3% Discharging/" "$NOTE"
run MACHINE_NOTE="$NOTE" -- --check
check "a different live reading is no drift: it is excluded by design" '[[ $rc == 0 && $out == "note is current" ]]'
sed -i 's/^### Identity$/### Identity (hand-edited)/' "$NOTE"
run MACHINE_NOTE="$NOTE" -- --check
check "an edit of a structural line inside the markers is drift, with the difference shown" \
    '[[ $rc == 1 && $err == *"DRIFT: "* && $err == *"hand-edited"* ]]'
run MACHINE_NOTE="$NOTE" -- --write
run MACHINE_NOTE="$NOTE" -- --check
check "--write repairs it" '[[ $rc == 0 && $out == "note is current" ]]'
check "the temporary files are gone" '[[ -z $(ls -A "$SB/tmp") ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
