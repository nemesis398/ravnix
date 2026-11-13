#!/usr/bin/env bash
# Tests for vault-commit (modules/glue/vault/), the one entry point the vault
# skills commit through. The git route runs the real git on a repository in
# the scratch directory; the ravnix-link route runs a stand-in that records
# its arguments. The commands come from modules/glue/vault/scripts.nix; the
# environment names the builds:
#
#   VAULT_COMMIT          with the stand-in ravnix-link and no vault built in
#   VAULT_COMMIT_NOLINK   with a ravnix-link that does not exist
#   VAULT_COMMIT_BUILTIN  with the vault /nonexistent/vault built in
#
#   bash tests/glue/helpers/vault-commit.test.bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

: "${VAULT_COMMIT:?}" "${VAULT_COMMIT_NOLINK:?}" "${VAULT_COMMIT_BUILTIN:?}"

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.org
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.org

# A message with what a commit message of the vault holds: umlauts, an en
# dash, quotes of both kinds, and lines.
odd_message=$'vault: Über Grüße – „Entwurf“\n\nZeile mit \'einfachen\' und "doppelten" Anführungszeichen\nund $HOME, `x` und \\n'
odd_note='Notizen/Über Grüße – Entwurf [1].md'

# fresh VIA: a new vault with one commit, skill values with vault.commitVia
# VIA (none when VIA is empty), and an empty record of the stand-in.
fresh() {
	local d
	for d in vault home fake; do
		if [[ -e "${scratch:?}/$d" ]]; then rm -r -- "${scratch:?}/$d"; fi
		mkdir -p "$scratch/$d"
	done
	export HOME="$scratch/home" FAKE_DIR="$scratch/fake" VAULT_COMMIT_VAULT="$scratch/vault"
	unset RAVNIX_SKILL_VALUES XDG_CONFIG_HOME
	vault="$scratch/vault"
	git -C "$vault" init -q
	printf 'alt\n' >"$vault/alt.md"
	git -C "$vault" add -A
	git -C "$vault" commit -qm init
	mkdir -p "$HOME/.config/ravnix"
	if [[ -n ${1:-} ]]; then
		printf '{"vault":{"commitVia":"%s"},"other":1}\n' "$1" >"$HOME/.config/ravnix/skill-values.json"
	fi
}

values() { printf '%s' "$1" >"$HOME/.config/ravnix/skill-values.json"; }
subjects() { git -C "$vault" log --format=%s; }
head_files() { git -C "$vault" -c core.quotePath=false show --format= --name-only HEAD; }
# The arguments of the stand-in's run, in ARGV.
link_argv() { mapfile -d '' -t ARGV <"$FAKE_DIR/link.argv"; }

# --- usage --------------------------------------------------------------------

test_help_and_usage() {
	fresh git
	capture "$VAULT_COMMIT" --help
	expect_status 0
	expect_out "usage: vault-commit MESSAGE [PATH...]"
	capture "$VAULT_COMMIT"
	expect_status 64
	expect_err "no message"
	capture "$VAULT_COMMIT" "" alt.md
	expect_status 64
	expect_err "the message is empty"
	[[ "$(subjects)" == init ]]
}

# --- the skill values ---------------------------------------------------------

test_missing_skill_values_say_where_they_come_from() {
	fresh ""
	capture "$VAULT_COMMIT" "m" alt.md
	expect_status 1
	expect_err "cannot read the skill values"
	expect_err "ravnix.claude.skillValues"
}

test_malformed_skill_values_are_reported() {
	fresh ""
	values '{"vault": {"commitVia": "git"'
	capture "$VAULT_COMMIT" "m" alt.md
	expect_status 1
	expect_err "are not JSON"
	[[ "$(subjects)" == init ]]
}

test_a_missing_or_odd_commit_via_names_the_key() {
	local v
	for v in '{}' '{"vault":{}}' '{"vault":"notes"}' '{"vault":{"commitVia":3}}' '{"vault":{"commitVia":null}}' '[1,2]' '""'; do
		fresh ""
		values "$v"
		capture "$VAULT_COMMIT" "m" alt.md
		expect_status 1 || {
			echo "  for $v"
			return 1
		}
		expect_err "vault.commitVia"
	done
}

test_an_unknown_commit_via_is_refused() {
	local v
	for v in svn GIT 'git ' 'ravnix-link\ngit'; do
		fresh ""
		values "{\"vault\":{\"commitVia\":\"$v\"}}"
		capture "$VAULT_COMMIT" "m" alt.md
		expect_status 1 || {
			echo "  for $v"
			return 1
		}
		expect_err "neither git nor ravnix-link"
	done
	[[ "$(subjects)" == init ]]
}

test_the_values_named_by_the_environment_win() {
	fresh ravnix-link
	printf '{"vault":{"commitVia":"git"}}' >"$scratch/other.json"
	printf 'neu\n' >"$vault/neu.md"
	RAVNIX_SKILL_VALUES="$scratch/other.json" capture "$VAULT_COMMIT" "vault: neu" neu.md
	expect_status 0
	[[ ! -e "$FAKE_DIR/link.argv" ]] || {
		echo "  ravnix-link ran"
		return 1
	}
	[[ "$(subjects)" == $'vault: neu\ninit' ]]
	# XDG_CONFIG_HOME, when set, is where the file is.
	mkdir -p "$scratch/xdg/ravnix"
	printf '{"vault":{"commitVia":"ravnix-link"}}' >"$scratch/xdg/ravnix/skill-values.json"
	fresh git
	XDG_CONFIG_HOME="$scratch/xdg" capture "$VAULT_COMMIT" "m" alt.md
	expect_status 0
	[[ -e "$FAKE_DIR/link.argv" ]]
}

# --- git ----------------------------------------------------------------------

test_git_commits_a_new_note_with_an_odd_name_and_message() {
	fresh git
	mkdir -p "$vault/Notizen"
	printf 'neu\n' >"$vault/$odd_note"
	printf 'nicht dabei\n' >"$vault/anders.md"
	capture "$VAULT_COMMIT" "$odd_message" "$odd_note"
	expect_status 0
	[[ "$(git -C "$vault" log -1 --format=%B)" == "$odd_message" ]] || {
		echo "  the message is: $(git -C "$vault" log -1 --format=%B)"
		return 1
	}
	[[ "$(head_files)" == "$odd_note" ]] || {
		echo "  the commit has: $(head_files)"
		return 1
	}
	# The other file stays out, untracked.
	[[ "$(git -C "$vault" status --porcelain)" == "?? anders.md" ]]
}

test_git_takes_an_absolute_path_inside_the_vault() {
	fresh git
	printf 'neu\n' >"$vault/neu.md"
	capture "$VAULT_COMMIT" "vault: neu" "$vault/neu.md"
	expect_status 0
	[[ "$(head_files)" == neu.md ]]
}

test_a_path_outside_the_vault_is_refused() {
	local p
	fresh git
	for p in /etc/passwd "$scratch/vaultx/a.md" "$vault" "$vault/" ../x.md Notizen/../../x.md ./alt.md "a//b.md" ""; do
		fresh git
		capture "$VAULT_COMMIT" "m" "$p"
		expect_status 64 || {
			echo "  for '$p'"
			return 1
		}
	done
	[[ "$(subjects)" == init ]]
}

test_git_commits_the_removal_of_a_note_that_is_gone() {
	fresh git
	rm -- "$vault/alt.md"
	capture "$VAULT_COMMIT" "vault: weg" alt.md
	expect_status 0
	[[ -z "$(git -C "$vault" ls-files)" ]]
	[[ "$(subjects)" == $'vault: weg\ninit' ]]
}

test_git_without_paths_commits_what_is_staged() {
	fresh git
	printf 'a\n' >"$vault/a.md"
	printf 'b\n' >"$vault/b.md"
	git -C "$vault" add a.md
	capture "$VAULT_COMMIT" "vault: staged"
	expect_status 0
	[[ "$(head_files)" == a.md ]]
	[[ "$(git -C "$vault" status --porcelain)" == "?? b.md" ]]
}

test_nothing_to_commit_is_done() {
	fresh git
	capture "$VAULT_COMMIT" "vault: nichts" alt.md
	expect_status 0
	expect_err "nothing to commit"
	capture "$VAULT_COMMIT" "vault: nichts"
	expect_status 0
	[[ "$(subjects)" == init ]]
}

test_a_path_git_does_not_know_fails() {
	fresh git
	capture "$VAULT_COMMIT" "vault: vertippt" nue.md
	expect_status 1
	expect_err "did not match"
	[[ "$(subjects)" == init ]]
}

test_a_vault_that_is_no_repository_fails() {
	fresh git
	mkdir -p "$scratch/plain"
	VAULT_COMMIT_VAULT="$scratch/plain" capture "$VAULT_COMMIT" "m" alt.md
	expect_status 1
	expect_err "no git repository"
	VAULT_COMMIT_VAULT="$scratch/nowhere" capture "$VAULT_COMMIT" "m" alt.md
	expect_status 1
	expect_err "no git repository"
}

test_a_vault_inside_another_repository_is_refused() {
	fresh git
	# The vault's own .git has not arrived yet; an enclosing repository
	# must not take its commits.
	mkdir -p "$scratch/outer/vault"
	git -C "$scratch/outer" init -q
	printf 'neu\n' >"$scratch/outer/vault/neu.md"
	VAULT_COMMIT_VAULT="$scratch/outer/vault" capture "$VAULT_COMMIT" "m" neu.md
	expect_status 1
	expect_err "not the vault's own"
	[[ -z "$(git -C "$scratch/outer" log --oneline 2>/dev/null)" ]]
}

test_without_a_vault_git_says_which_option() {
	fresh git
	VAULT_COMMIT_VAULT="" capture "$VAULT_COMMIT" "m" alt.md
	expect_status 1
	expect_err "ravnix.link.vault"
	# The vault built in is used when the environment names none.
	VAULT_COMMIT_VAULT="" capture "$VAULT_COMMIT_BUILTIN" "m" alt.md
	expect_status 1
	expect_err "/nonexistent/vault"
}

test_a_hook_that_refuses_fails_with_its_words() {
	fresh git
	write_script "$vault/.git/hooks/pre-commit" 'echo "kein Commit heute" >&2' 'exit 1'
	printf 'neu\n' >"$vault/neu.md"
	capture "$VAULT_COMMIT" "vault: neu" neu.md
	expect_status 1
	expect_err "kein Commit heute"
	[[ "$(subjects)" == init ]]
}

test_concurrent_runs_each_commit() {
	fresh git
	local i pids=() codes=()
	for i in 1 2 3 4 5 6; do
		printf '%s\n' "$i" >"$vault/n$i.md"
	done
	for i in 1 2 3 4 5 6; do
		"$VAULT_COMMIT" "vault: n$i" "n$i.md" >/dev/null 2>"$scratch/err$i" &
		pids+=($!)
	done
	local code
	for i in "${!pids[@]}"; do
		code=0
		wait "${pids[i]}" || code=$?
		codes+=("$code")
	done
	for i in "${!codes[@]}"; do
		[[ ${codes[i]} == 0 ]] || {
			echo "  run $((i + 1)) exited ${codes[i]}: $(cat "$scratch/err$((i + 1))")"
			return 1
		}
	done
	[[ "$(git -C "$vault" log --format=%s | wc -l)" == 7 ]]
	[[ -z "$(git -C "$vault" status --porcelain)" ]]
}

# --- ravnix-link --------------------------------------------------------------

test_ravnix_link_gets_the_message_and_paths_as_given() {
	fresh ravnix-link
	capture "$VAULT_COMMIT" "$odd_message" "$odd_note" "$vault/AI/sessions/x.md" "-n.md"
	expect_status 0
	link_argv
	[[ ${#ARGV[@]} == 5 && ${ARGV[0]} == vault-commit && ${ARGV[1]} == "$odd_message" && ${ARGV[2]} == "$odd_note" && ${ARGV[3]} == AI/sessions/x.md && ${ARGV[4]} == -n.md ]] || {
		echo "  ravnix-link got: $(printf '<%s> ' "${ARGV[@]}")"
		return 1
	}
	# git is not touched: the repository is the server's.
	[[ "$(subjects)" == init ]]
}

test_ravnix_link_without_paths_and_its_exit() {
	fresh ravnix-link
	printf '1' >"$FAKE_DIR/link.status"
	printf 'the commit failed on the server' >"$FAKE_DIR/link.err"
	capture "$VAULT_COMMIT" "vault: staged"
	expect_status 1
	expect_err "the commit failed on the server"
	link_argv
	[[ ${#ARGV[@]} == 2 ]]
	printf '64' >"$FAKE_DIR/link.status"
	capture "$VAULT_COMMIT" "m" a.md
	expect_status 64
}

test_ravnix_link_that_is_not_installed_says_so() {
	fresh ravnix-link
	capture "$VAULT_COMMIT_NOLINK" "m" alt.md
	expect_status 1
	expect_err "ravnix-link is not installed"
}

test_ravnix_link_works_without_a_repository_here() {
	fresh ravnix-link
	rm -r -- "$vault/.git"
	capture "$VAULT_COMMIT" "m" alt.md
	expect_status 0
	[[ -e "$FAKE_DIR/link.argv" ]]
}

tests=(
	test_help_and_usage
	test_missing_skill_values_say_where_they_come_from
	test_malformed_skill_values_are_reported
	test_a_missing_or_odd_commit_via_names_the_key
	test_an_unknown_commit_via_is_refused
	test_the_values_named_by_the_environment_win
	test_git_commits_a_new_note_with_an_odd_name_and_message
	test_git_takes_an_absolute_path_inside_the_vault
	test_a_path_outside_the_vault_is_refused
	test_git_commits_the_removal_of_a_note_that_is_gone
	test_git_without_paths_commits_what_is_staged
	test_nothing_to_commit_is_done
	test_a_path_git_does_not_know_fails
	test_a_vault_that_is_no_repository_fails
	test_a_vault_inside_another_repository_is_refused
	test_without_a_vault_git_says_which_option
	test_a_hook_that_refuses_fails_with_its_words
	test_concurrent_runs_each_commit
	test_ravnix_link_gets_the_message_and_paths_as_given
	test_ravnix_link_without_paths_and_its_exit
	test_ravnix_link_that_is_not_installed_says_so
	test_ravnix_link_works_without_a_repository_here
)
run_tests "${tests[@]}"
