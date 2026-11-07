#!/usr/bin/env bash
# The gate. The git hooks and the Claude Code Stop hook run it, and there is
# no CI behind it: what it does not check, nothing does.
#
#   scripts/check.sh --fast   the fast steps, which .githooks/pre-commit and
#                             the Stop hook run
#   scripts/check.sh          the fast steps and then the slow ones, which
#                             .githooks/pre-push runs
#
# The fast steps:
#   - boundary: scripts/check-public.sh with the deny list that git config
#     ravnix.denyList names, over the index (what the next commit holds,
#     read from git's objects, so an unstaged edit cannot hide a staged
#     value) and over each tracked file whose work-tree copy differs from it.
#     Untracked files are not read. Without ravnix.denyList the step says it
#     was skipped and passes, so a clone without a private flake still works.
#   - style: scripts/check-style.sh over the same two sets: a hex color
#     outside modules/theme/, a radius other than 0, anything translucent
#     but the inside of the lock ring, a transition or animation, a Mermaid
#     init block that is not the shared one (docs/style.md). It needs rg and
#     runs without a deny list.
#   - shellcheck: every tracked shell script, found by its extension (.sh,
#     .bash) or by its shebang (sh, bash, dash, ksh), hooks included: the
#     staged copy, and the work-tree copy where it differs.
# The slow steps:
#   - flake: nix flake check, which builds every check of the flake.
#   - claude-code: claude-code-verify checks the Claude Code download that
#     packages.claude-code was made from, for the version in ravnix's own
#     flake.lock, against Anthropic's release manifest. A private flake whose
#     claude-code input ravnix's follows checks its own version itself. The
#     check needs the network, so it runs here and not in the
#     build sandbox (tools/claude-code-verify/README.md). Each verified
#     pair of version and download is recorded in
#     ${XDG_STATE_HOME:-$HOME/.local/state}/ravnix/claude-code-verified. An
#     unreachable manifest (exit 3) passes the gate for a pair recorded
#     there and fails it for any other: the check is the only one there is,
#     and a push that bumps Claude Code would otherwise go out unverified. A
#     mismatch (exit 1) always fails, and removes the pair from the record.
#
# The gate stops at the first failing step and exits with that step's status,
# and with 0 when every step passed.
#
# Changing this file so it checks less needs the maintainer's explicit
# approval (AGENTS.md, rule 6).

set -euo pipefail
shopt -s inherit_errexit

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/git-snapshot.sh
. scripts/lib/git-snapshot.sh

fail() {
	printf 'check.sh: %s\n' "$@" >&2
	exit 1
}

mode=full
case "$#:${1:-}" in
0:) ;;
1:--fast) mode=fast ;;
*)
	echo "usage: scripts/check.sh [--fast]" >&2
	exit 2
	;;
esac

# The steps, in order. A new check is a function step_NAME below and its name
# in one of these lists.
fast_steps=(boundary style shellcheck)
slow_steps=(flake claude-code)
steps=("${fast_steps[@]}")
[[ "$mode" == fast ]] || steps+=("${slow_steps[@]}")

# Find every tool before the first step, so a missing one fails at once.
command -v git >/dev/null 2>&1 || fail "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	fail "$root is not a git work tree; the gate checks what git tracks."
deny_list="$(ravnix_deny_list)" || exit 2
command -v rg >/dev/null 2>&1 || fail "rg not found. Install ripgrep."
command -v shellcheck >/dev/null 2>&1 || fail "shellcheck not found. Install ShellCheck."
if [[ "$mode" == full ]]; then
	command -v nix >/dev/null 2>&1 ||
		fail "nix not found on PATH, and the full gate runs nix flake check." \
			"Outside NixOS, open a new shell or source" \
			"/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh."
fi

work="$(mktemp -d -p "${TMPDIR:-/tmp}" ravnix-check.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT

# The index as files, and the tracked files whose work-tree copy differs.
staged=()
while IFS= read -r -d '' path; do
	staged+=("$path")
done < <(ravnix_snapshot_index "$work/index")
wait $! || fail "could not lay out the index."
unstaged=()
while IFS= read -r -d '' path; do
	[[ -f "$path" || -L "$path" ]] && unstaged+=("$path")
done < <(git diff --name-only -z --no-renames --diff-filter=AMTU)
wait $! || fail "git diff failed."

step_boundary() {
	if [[ -z "$deny_list" ]]; then
		ravnix_skip_note check.sh
		return 0
	fi
	local status=0 s=0
	echo "the index (what the next commit holds):"
	(cd "$work/index" && "$root/scripts/check-public.sh" "$deny_list" .) || status=$?
	if ((${#unstaged[@]} > 0)); then
		echo "unstaged changes in the work tree (${#unstaged[@]} files):"
		scripts/check-public.sh "$deny_list" "${unstaged[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	((status != 0)) || echo "no value from the deny list found"
	return "$status"
}

step_style() {
	local status=0 s=0 theme=()
	# The shared Mermaid theme of the index, when the index has one, so a
	# commit that changes it and docs/style.md together is judged as a whole.
	[[ ! -f "$work/index/docs/mermaid-theme.json" ]] ||
		theme=(RAVNIX_MERMAID_THEME="$work/index/docs/mermaid-theme.json")
	echo "the index (what the next commit holds):"
	(cd "$work/index" && env "${theme[@]}" "$root/scripts/check-style.sh" .) || status=$?
	if ((${#unstaged[@]} > 0)); then
		echo "unstaged changes in the work tree (${#unstaged[@]} files):"
		scripts/check-style.sh "${unstaged[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	((status != 0)) || echo "no style rule broken"
	return "$status"
}

# Whether the file $1 is a shell script.
is_shell() {
	local first=""
	case "$1" in
	*.sh | *.bash) return 0 ;;
	esac
	[[ -f "$1" && ! -L "$1" ]] || return 1
	IFS= read -r -n 256 first <"$1" 2>/dev/null || true
	[[ "$first" =~ ^#![[:space:]]*[^[:space:]]*/(env[[:space:]]+(-[^[:space:]]*[[:space:]]+)*)?(ba|da|k)?sh([[:space:]]|$) ]]
}

step_shellcheck() {
	local scripts=() path status=0 s=0
	for path in "${staged[@]}"; do
		is_shell "$work/index/$path" && scripts+=("$path")
	done
	echo "the index: ${#scripts[@]} shell scripts"
	if ((${#scripts[@]} > 0)); then
		(cd "$work/index" && shellcheck --external-sources -- "${scripts[@]}") || status=$?
	fi
	scripts=()
	for path in "${unstaged[@]}"; do
		if [[ ! -L "$path" ]] && is_shell "$path"; then
			scripts+=("$path")
		fi
	done
	if ((${#scripts[@]} > 0)); then
		echo "unstaged changes in the work tree: ${#scripts[@]} shell scripts"
		shellcheck --external-sources -- "${scripts[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	return "$status"
}

# nix as every slow step runs it: flakes on, and the lock file never written.
nix_() {
	nix --extra-experimental-features 'nix-command flakes' "$@" --no-update-lock-file
}

step_flake() {
	nix_ flake check --print-build-logs --keep-going
}

# The record of the pairs the claude-code step verified: one line
# "<version> <download>" each, nothing secret. It is a cache: a record lost
# or unwritable only makes a run with the manifest unreachable fail. A
# record with any line of another shape counts as empty, and the next write
# replaces it.
verified_record() {
	local dir="${XDG_STATE_HOME:-}"
	# A relative XDG_STATE_HOME is to be ignored (XDG Base Directory).
	[[ "$dir" == /* ]] || dir="${HOME:+$HOME/.local/state}"
	[[ "$dir" == /* ]] || return 1
	printf '%s/ravnix/claude-code-verified\n' "$dir"
}

# Prints the pairs of record $1, or nothing when it is missing, unreadable
# or corrupt.
verified_pairs() {
	local shape='[^[:space:][:cntrl:]]+ /[^[:cntrl:]]*'
	[[ -f "$1" && -r "$1" ]] || return 0
	! LC_ALL=C grep -a -q -v -x -E -- "$shape" "$1" || return 0
	LC_ALL=C grep -a -x -E -- "$shape" "$1" || true
}

# Whether record $1 holds pair $2.
was_verified() {
	local line
	while IFS= read -r line; do
		[[ "$line" != "$2" ]] || return 0
	done < <(verified_pairs "$1")
	return 1
}

# Writes record $1 with pair $2 added (when not empty) and pair $3 removed,
# through a temporary file beside it.
rewrite_record() {
	local file="$1" add="$2" drop="$3" tmp line
	mkdir -p -- "${file%/*}" 2>/dev/null || return 1
	tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)" || return 1
	if {
		while IFS= read -r line; do
			[[ "$line" == "$add" || "$line" == "$drop" ]] || printf '%s\n' "$line"
		done < <(verified_pairs "$file")
		[[ -z "$add" ]] || printf '%s\n' "$add"
	} >"$tmp" && mv -fT -- "$tmp" "$file" 2>/dev/null; then
		return 0
	fi
	rm -f -- "$tmp"
	return 1
}

step_claude-code() {
	local verify download version status=0 record pair
	verify="$(nix_ build --no-link --print-out-paths .#claude-code-verify)"
	download="$(nix_ build --no-link --print-out-paths .#claude-code.download)"
	version="$(nix_ eval --raw .#claude-code.version)"
	if [[ -z "$download" || ! -f "$download" ]]; then
		echo "check.sh: nix built no download for .#claude-code.download" >&2
		return 1
	fi
	echo "Claude Code $version, downloaded as $download"
	"$verify/bin/claude-code-verify" "$download" "$version" || status=$?
	pair="$version $download"
	record="$(verified_record)" || record=""
	# A pair the record could not hold as one line of its shape is never
	# written: reading it back would make the whole record corrupt.
	local recordable=1
	[[ "$version" =~ ^[^[:space:][:cntrl:]]+$ && "$download" == /* && "$download" != *[[:cntrl:]]* ]] ||
		recordable=""
	case "$status" in
	0)
		[[ -n "$record" && -n "$recordable" ]] && rewrite_record "$record" "$pair" "" ||
			printf 'check.sh: %s\n' \
				"could not record Claude Code $version as verified${record:+ in $record};" \
				"with the manifest unreachable, a later run fails for it." >&2
		;;
	1)
		# A pair that stayed recorded would pass a later run with the manifest
		# unreachable, so the whole record goes when the pair cannot.
		if [[ -n "$record" ]] && was_verified "$record" "$pair"; then
			if rewrite_record "$record" "" "$pair" || rm -f -- "$record" 2>/dev/null; then
				printf 'check.sh: %s\n' \
					"Claude Code $version, verified on an earlier run, is no longer recorded as verified." >&2
			else
				printf 'check.sh: %s\n' \
					"Claude Code $version, verified on an earlier run, could not be removed from $record; delete that file." \
					"Until then a run with the manifest unreachable passes for it." >&2
			fi
		fi
		;;
	3)
		if [[ -n "$record" ]] && was_verified "$record" "$pair"; then
			printf 'check.sh: %s\n' \
				"Anthropic's release manifest is unreachable, but Claude Code $version, downloaded as $download, was verified on an earlier run (recorded in $record)." \
				"The gate passes for it, as it would for no other download." >&2
			status=0
		else
			printf 'check.sh: %s\n' \
				"Anthropic's release manifest is unreachable, and Claude Code $version, downloaded as $download, was never verified here${record:+ (no record of it in $record)}." \
				"The gate fails rather than let an unverified binary out; push again once" \
				"downloads.claude.ai answers." >&2
		fi
		;;
	esac
	return "$status"
}

for name in "${steps[@]}"; do
	printf '\n==> %s\n' "$name"
	# A subshell with errexit, so a failing command inside the step fails it.
	set +e
	(
		set -e
		"step_$name"
	)
	status=$?
	set -e
	if ((status != 0)); then
		printf '\ncheck.sh: %s failed (exit %d)\n' "$name" "$status" >&2
		exit "$status"
	fi
done

if [[ -z "$deny_list" ]]; then
	printf '\ncheck.sh: all %d steps passed, but the public-boundary check was SKIPPED (ravnix.denyList is not set)\n' "${#steps[@]}"
else
	printf '\ncheck.sh: all %d steps passed\n' "${#steps[@]}"
fi
