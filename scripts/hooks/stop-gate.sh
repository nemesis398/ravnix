#!/usr/bin/env bash
# The Claude Code Stop hook. It runs the fast gate, scripts/check.sh --fast,
# before the agent may stop, but only when something the gate reads changed
# since the last green run. It exits 0 to let the agent stop and 2, with the
# gate's output on stderr, to send it back to work.
#
# The fingerprint is a SHA-256 over the gate command, the index (what the
# next commit holds), the deny list that git config ravnix.denyList names,
# and the path and contents of every tracked and untracked (not ignored) file:
# the public-boundary check reads every file, so every file counts. A green run
# writes it to ravnix-gate/green in the work tree's git directory, a red run
# to ravnix-gate/red. A stop whose fingerprint matches ravnix-gate/green skips
# the gate.
#
# The gate gets a deadline below the hook's timeout in .claude/settings.json,
# because Claude Code discards a timed-out Stop hook and lets the agent stop. A
# gate past its deadline counts as red.
#
# A stop that a red gate already sent back (stop_hook_active is true) with
# nothing changed since is let through with a note to the user, so the agent
# is not sent back forever. When the hook itself cannot work (no jq, unreadable
# input, any unexpected failure), it blocks the first stop and lets a repeated
# one through with a note, because Claude Code's cap on stop-hook
# continuations resets on every tool call.
#
# The gate runs in the work tree Claude is in (the cwd field) when that is a
# work tree of this repository, such as a linked worktree, and in this
# script's own checkout otherwise.
#
# Environment:
#   RAVNIX_GATE_CMD      path of an executable that replaces
#                        scripts/check.sh --fast as the gate. Only
#                        scripts/hooks/test.sh sets it.
#   RAVNIX_GATE_TIMEOUT  the gate's deadline in seconds, 300 by default. Only
#                        scripts/hooks/test.sh sets it.
#
# Ported from phyllon's scripts/hooks/stop-gate.sh. Changing this file so it
# checks less needs the maintainer's explicit approval (AGENTS.md, rule 6).

set -euo pipefail
shopt -s inherit_errexit

input=""
active=""
# Set by block and let_through, so on_exit can tell their exits from a failing
# command's, whatever its status. step names what the hook was doing.
decided=""
step="reading the hook input"

# Our own messages only: escapes what they can contain for a JSON string.
json_string() {
	local s="$*"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\t'/\\t}"
	printf '"%s"' "$s"
}

# Lets the agent stop with a note. Claude never sees stderr from a hook that
# exits 0, and a Stop hook's plain stdout goes only to the debug log; the
# systemMessage of a JSON object, alone on stdout, is shown to the user.
let_through() {
	decided=1
	printf '{"systemMessage": %s}\n' "$(json_string "stop-gate: $*")"
	exit 0
}

# Exit 2 sends the agent back with stderr as the reason. Claude Code treats a
# Stop hook's exit 2 as a non-blocking error when stdout is empty and stderr
# says a file is missing ("No such file or directory"), which the gate's output
# can say, so every block also prints a line on stdout.
block() {
	decided=1
	echo "stop-gate: blocking the stop; the reason is on stderr"
	printf 'stop-gate: %s\n' "$@" >&2
	exit 2
}

# Whether Claude Code already continued because of a stop hook. Until jq has
# read the input, a pattern on the raw input stands in for it.
repeated() {
	if [[ -n "$active" ]]; then
		[[ "$active" == true ]]
	else
		[[ "$input" =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*true ]]
	fi
}

# The hook cannot do its job: block the first stop, let a repeated one through.
# $1 says what went wrong, the other arguments what to do about it; one
# sentence each, since block prints each on its own line.
fail() {
	if repeated; then
		let_through "$1" "The stop goes through unchecked." "${@:2}"
	fi
	block "$@"
}

# Fail closed: a failing command would otherwise end the hook with its own
# status, which lets the agent stop unchecked, or blocks with no stdout line
# and without the let-through when that status is 2. A deliberate exit 0 needs
# no flag, since a failing command never exits 0.
# shellcheck disable=SC2329 # the EXIT trap calls it
on_exit() {
	local rc=$?
	if [[ -z "$decided" ]] && ((rc != 0)); then
		trap - EXIT
		fail "the hook failed unexpectedly (exit $rc) while $step." \
			"To see why, run scripts/hooks/stop-gate.sh </dev/null by hand or read Claude Code's debug log."
	fi
}
trap on_exit EXIT

input="$(cat)"

command -v jq >/dev/null 2>&1 ||
	fail "jq not found, and this hook needs it to read Claude Code's input." \
		"Install jq."
active="$(jq -r '.stop_hook_active // false' <<<"$input")" ||
	fail "could not read stop_hook_active from the hook input."
cwd="$(jq -r '.cwd // empty' <<<"$input")" ||
	fail "could not read cwd from the hook input."

step="looking for the tools it needs"
command -v timeout >/dev/null 2>&1 || fail "timeout not found." "Install GNU coreutils."
deadline="${RAVNIX_GATE_TIMEOUT:-300}"
kill_after=30
[[ "$deadline" =~ ^[1-9][0-9]*$ ]] ||
	fail "RAVNIX_GATE_TIMEOUT must be a whole number of seconds, not '$deadline'."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found." "Install GNU coreutils."
sha256() { sha256sum | cut -d ' ' -f 1; }

step="finding the work tree to check"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "$cwd" && -d "$cwd" ]]; then
	own="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
	if top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" &&
		common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
		[[ "$common" == "$own" ]]; then
		root="$top"
	fi
fi
cd "$root"

# One record per file, sorted by path: the path, then the hash of its contents.
# A tracked file deleted from the work tree is recorded as missing.
records() {
	local path
	git ls-files -z --cached --others --exclude-standard |
		LC_ALL=C sort -zu |
		while IFS= read -r -d '' path; do
			printf '%s\0' "$path"
			if [[ -L "$path" ]]; then
				printf 'symlink '
				readlink -- "$path" | sha256
			elif [[ -f "$path" ]]; then
				sha256 <"$path"
			else
				echo missing
			fi
		done
}

# The deny list: its path and contents, or that there is none.
deny_list() {
	local list
	list="$(git config --path --get ravnix.denyList || true)"
	printf 'deny-list\0%s\0' "$list"
	if [[ -n "$list" && -f "$list" ]]; then
		sha256 <"$list"
	else
		echo none
	fi
}

if [[ -n "${RAVNIX_GATE_CMD:-}" ]]; then
	gate=("$RAVNIX_GATE_CMD")
else
	gate=(scripts/check.sh --fast)
fi
# The gate command is part of the fingerprint, so a green run of another gate
# does not count for this one.
step="computing the fingerprint"
fp="$({
	printf 'gate\0%s\0' "${gate[*]}"
	printf 'index\0'
	git ls-files --stage -z
	deny_list
	records
} | sha256)"
markers="$(git rev-parse --absolute-git-dir)/ravnix-gate"
green="$markers/green"
red="$markers/red"

if [[ -f "$green" && "$(<"$green")" == "$fp" ]]; then
	exit 0
fi

if repeated && [[ -f "$red" && "$(<"$red")" == "$fp" ]]; then
	let_through "the gate is still red and nothing it checks changed since," \
		"so the stop goes through. Run scripts/check.sh --fast to see the errors."
fi

step="running the gate"
status=0
start=$SECONDS
# The output goes to Claude, so no color codes. timeout signals the gate's
# whole process group.
output="$(TERM=dumb NO_COLOR=1 \
	timeout --kill-after="$kill_after" "$deadline" "${gate[@]}" </dev/null 2>&1)" ||
	status=$?

step="writing the gate markers"
mkdir -p "$markers"
if ((status == 0)); then
	printf '%s\n' "$fp" >"$green"
	rm -f "$red"
	exit 0
fi

printf '%s\n' "$fp" >"$red"
rm -f "$green"
printf '%s\n' "$output" >&2
# 124 after TERM, 137 when it took KILL.
if ((status == 124 || status == 137)) && ((SECONDS - start >= deadline)); then
	block "the gate (${gate[*]}) timed out after $deadline s and counts as red." \
		"Find what hangs or is slow in its output above."
fi
block "the gate (${gate[*]}) failed with exit $status. Fix what it reports above." \
	"Stop only once the gate is green."
