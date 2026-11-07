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
#   - shellcheck: every tracked shell script, found by its extension (.sh,
#     .bash) or by its shebang (sh, bash, dash, ksh), hooks included: the
#     staged copy, and the work-tree copy where it differs.
# The slow step:
#   - flake: nix flake check, which builds every check of the flake.
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
# in one of these lists; the style check, scripts/check-style.sh, joins the
# fast ones once it exists.
fast_steps=(boundary shellcheck)
slow_steps=(flake)
steps=("${fast_steps[@]}")
[[ "$mode" == fast ]] || steps+=("${slow_steps[@]}")

# Find every tool before the first step, so a missing one fails at once.
command -v git >/dev/null 2>&1 || fail "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	fail "$root is not a git work tree; the gate checks what git tracks."
deny_list="$(ravnix_deny_list)" || exit 2
[[ -z "$deny_list" ]] || command -v rg >/dev/null 2>&1 ||
	fail "rg not found. Install ripgrep."
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

step_flake() {
	nix --extra-experimental-features 'nix-command flakes' \
		flake check --no-update-lock-file --print-build-logs --keep-going
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
