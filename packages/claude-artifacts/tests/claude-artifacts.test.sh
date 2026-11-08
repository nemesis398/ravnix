#!/usr/bin/env bash
# Tests for claude-artifacts (packages/claude-artifacts), run by the check
# bin-claude-artifacts. claude is a stand-in that prints what it was started
# with, because the contract is exactly that: the variable that switches the
# Artifact tool off is gone, the settings re-list the three artifact skills,
# every argument passes through unchanged, and the secrets of the table reach
# claude (the launcher loads them through with-secret-env, as the interactive
# `claude` function does, because it is not that function). rbw is a stand-in
# with two items.
#
# CLAUDE_ARTIFACTS_UNDER_TEST=<file> tests another copy; by default it is the
# claude-artifacts on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=$(readlink -f "${CLAUDE_ARTIFACTS_UNDER_TEST:-$(type -P claude-artifacts)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/claude-artifacts-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/.config/ravnix"
# One line per argument, then the variable and the secrets, so an argument with
# a space or a newline in it shows.
cat >"$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf 'arg:%s\n' "$a"; done
printf 'disable:%s\n' "${CLAUDE_CODE_DISABLE_ARTIFACT-<unset>}"
printf 'token:%s|%s\n' "${FIRST_TOKEN-<unset>}" "${SECOND_TOKEN-<unset>}"
exit "${STUB_RC:-0}"
STUB
cat >"$SB/bin/rbw" <<'STUB'
#!/usr/bin/env bash
case $1 in
    unlocked) [[ ${RBW_LOCKED:-0} == 0 ]] ;;
    get)
        case $3 in
            "First item") echo plain-1 ;;
            "Second item") echo "two words" ;;
            *) exit 1 ;;
        esac ;;
esac
STUB
sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/claude" "$SB/bin/rbw"
chmod +x "$SB/bin/claude" "$SB/bin/rbw"
# The table the module writes into the user's config.
printf '%s\n' 'FIRST_TOKEN=First item' 'SECOND_TOKEN=Second item' >"$SB/.config/ravnix/secret-env"

# run [ENV=VAL ...] -- ARGS: sets $out, $rc.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    out=$(env -i HOME="$SB" PATH="$SB/bin" "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1)
    rc=$?
    # The same with stderr apart, for the notes.
    err=$(env -i HOME="$SB" PATH="$SB/bin" "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1 >/dev/null)
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: $out"; fi; }

echo "claude-artifacts"

run CLAUDE_CODE_DISABLE_ARTIFACT=1 -- -p "hello world"
check "the variable that switches the Artifact tool off is removed" '[[ $out == *"disable:<unset>"* ]]'
check "the arguments pass through unchanged, after the settings" \
    '[[ $out == *$'"'"'arg:-p\narg:hello world\n'"'"'* ]]'
run -- --resume
check "it works with the variable unset as well" '[[ $rc == 0 && $out == *"disable:<unset>"* ]]'
settings=$(printf '%s\n' "$out" | sed -n '2p')
check "--settings comes first and holds JSON" '[[ $out == "arg:--settings"* && -n $settings ]]'
check "the settings are valid JSON" 'printf "%s" "${settings#arg:}" | python3 -c "import json,sys; json.load(sys.stdin)"'
check "the three artifact skills are switched on" \
    '[[ $settings == *"artifact-design\":\"on\""* && $settings == *"artifact-capabilities\":\"on\""* && $settings == *"artifact-diagramming\":\"on\""* ]]'
run -- 'a b' '' -- '*' $'multi\nline'
check "empty, dashed and multi-line arguments survive" \
    '[[ $out == *$'"'"'arg:a b\narg:\narg:--\narg:*\narg:multi\nline\n'"'"'* ]]'
run STUB_RC=7 -- x
check "claude's exit status is the script's" '[[ $rc == 7 ]]'
run PATH="$SB/nobin" -- x
check "without claude on the PATH it fails, and says which command" '[[ $rc -ne 0 && $out == *claude* ]]'

# ── the secrets ────────────────────────────────────────────────────────────
run -- x
check "the secrets of the table reach claude, which on Fedora a launcher got from the shell" \
    '[[ $out == *"token:plain-1|two words"* && -z $err ]]'
check "a secret is no argument of claude: the argument vector is what the caller gave" \
    '[[ $out == *$'"'"'arg:x\ndisable:'"'"'* && $(printf "%s\n" "$out" | sed -n "/^arg:/p") != *plain-1* ]]'
printf '%s\n' 'FIRST_TOKEN=First item' 'SECOND_TOKEN=No such item' >"$SB/bad"
run RAVNIX_SECRET_ENV="$SB/bad" -- x
check "when one item cannot be read claude gets none of them, and the note names the item" \
    '[[ $rc == 0 && $out == *"token:<unset>|<unset>"* && $err == *"SECOND_TOKEN: rbw cannot read the item"* ]]'
run RBW_LOCKED=1 -- x
check "a locked vault: claude starts without the secrets, and the note says to unlock" \
    '[[ $rc == 0 && $out == *"token:<unset>|<unset>"* && $err == *"ai-unlock"* ]]'
run RAVNIX_SECRET_ENV="$SB/no-such-table" -- x
check "without a table claude still starts, with a note" \
    '[[ $rc == 0 && $out == *"arg:--settings"* && $err == *"there is no $SB/no-such-table"* ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
