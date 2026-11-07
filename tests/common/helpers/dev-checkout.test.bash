#!/usr/bin/env bash
# Tests for ravnix-dev-checkout, which the home-manager activation runs when
# ravnix.dev.checkout is set. It must never fail the activation over a
# checkout that is not there yet, and it must change nothing but the
# checkout's own git configuration. Run it with ravnix-dev-checkout and git
# on PATH:
#
#   bash tests/common/helpers/dev-checkout.test.bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

# Empties the scratch directory, so that no test sees another one's repository.
# The tests that make a repository unwritable have put the write bit back.
fresh() {
	find "$scratch" -mindepth 1 -maxdepth 1 ! -name '.*' -exec chmod -R u+rwX {} + \
		-exec rm -r -- {} +
	cd "$scratch"
}

# A repository in $scratch/NAME, with one commit, and its path on stdout.
new_repo() {
	local dir="$scratch/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q -b main
	git -C "$dir" -c user.name=t -c user.email=t@example.org \
		commit -q --allow-empty -m init
	printf '%s' "$dir"
}

# The value git holds for KEY in the repository at DIR, empty when unset.
config_of() {
	git -C "$1" config --local --get "$2" || true
}

it_turns_the_hooks_on_and_names_the_deny_list() {
	fresh
	local repo
	repo="$(new_repo repo)"
	capture ravnix-dev-checkout "$repo" /deny/list.txt
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ "$(config_of "$repo" ravnix.denyList)" == /deny/list.txt ]]
}

it_leaves_the_deny_list_alone_when_none_is_given() {
	fresh
	local repo
	repo="$(new_repo repo)"
	git -C "$repo" config ravnix.denyList /by/hand.txt
	capture ravnix-dev-checkout "$repo"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ "$(config_of "$repo" ravnix.denyList)" == /by/hand.txt ]]
}

it_sets_no_deny_list_when_none_is_given() {
	fresh
	local repo
	repo="$(new_repo repo)"
	capture ravnix-dev-checkout "$repo"
	expect_status 0
	[[ -z "$(config_of "$repo" ravnix.denyList)" ]]
}

it_can_run_twice_and_changes_a_stale_value() {
	fresh
	local repo
	repo="$(new_repo repo)"
	git -C "$repo" config core.hooksPath /somewhere/else
	capture ravnix-dev-checkout "$repo" /one.txt
	capture ravnix-dev-checkout "$repo" /two.txt
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ "$(config_of "$repo" ravnix.denyList)" == /two.txt ]]
	# One value each, not a list that grew.
	[[ "$(git -C "$repo" config --local --get-all core.hooksPath | wc -l)" == 1 ]]
	[[ "$(git -C "$repo" config --local --get-all ravnix.denyList | wc -l)" == 1 ]]
}

it_does_not_fail_the_activation_for_a_checkout_that_is_not_there_yet() {
	fresh
	capture ravnix-dev-checkout "$scratch/not-cloned-yet" /deny.txt
	expect_status 0
	expect_err "$scratch/not-cloned-yet"
	expect_err "does not exist"
	# Nothing is created for it.
	[[ ! -e "$scratch/not-cloned-yet" ]]
}

it_does_not_fail_for_a_directory_that_is_no_repository() {
	fresh
	mkdir "$scratch/plain"
	capture ravnix-dev-checkout "$scratch/plain" /deny.txt
	expect_status 0
	expect_err "$scratch/plain"
	expect_err "not a git repository"
	# No repository is made, and no file is written into it.
	[[ -z "$(ls -A "$scratch/plain")" ]]
}

it_does_not_fail_for_a_file_in_place_of_the_checkout() {
	fresh
	: >"$scratch/a-file"
	capture ravnix-dev-checkout "$scratch/a-file"
	expect_status 0
	expect_err "$scratch/a-file"
}

it_copes_with_spaces_quotes_and_glob_characters_in_the_path() {
	fresh
	local repo
	repo="$(new_repo "we ird 'dir' \$HOME *?[x]")"
	capture ravnix-dev-checkout "$repo" "/deny list/it's *.txt"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ "$(config_of "$repo" ravnix.denyList)" == "/deny list/it's *.txt" ]]
}

it_works_through_a_symbolic_link() {
	fresh
	local repo
	repo="$(new_repo repo)"
	ln -s "$repo" "$scratch/link"
	capture ravnix-dev-checkout "$scratch/link"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
}

it_configures_the_repository_a_subdirectory_belongs_to() {
	fresh
	local repo
	repo="$(new_repo repo)"
	mkdir "$repo/sub"
	capture ravnix-dev-checkout "$repo/sub"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
}

it_configures_a_checkout_that_is_a_linked_work_tree() {
	fresh
	local repo
	repo="$(new_repo repo)"
	git -C "$repo" worktree add -q "$scratch/tree" -b feature
	capture ravnix-dev-checkout "$scratch/tree" /deny.txt
	expect_status 0
	# The configuration is shared with the main work tree, which is what
	# hooks in either one read.
	[[ "$(config_of "$scratch/tree" core.hooksPath)" == .githooks ]]
	[[ "$(config_of "$repo" ravnix.denyList)" == /deny.txt ]]
}

it_takes_an_absolute_path_only_so_nothing_reads_as_an_option() {
	fresh
	local repo
	repo="$(new_repo repo)"
	cd "$repo"
	capture ravnix-dev-checkout .
	expect_status 2
	capture ravnix-dev-checkout --help
	expect_status 2
	capture ravnix-dev-checkout -- "$repo"
	expect_status 2
	# Nothing was configured by the refused calls.
	[[ -z "$(config_of "$repo" core.hooksPath)" ]]
}

it_says_so_and_still_succeeds_when_the_configuration_cannot_be_written() {
	fresh
	local repo
	repo="$(new_repo repo)"
	chmod a-w "$repo/.git/config"
	chmod a-w "$repo/.git"
	capture ravnix-dev-checkout "$repo" /deny.txt
	chmod u+w "$repo/.git" "$repo/.git/config"
	expect_status 0
	expect_err "$repo"
	expect_err "could not"
}

it_ignores_the_users_own_git_configuration() {
	fresh
	local repo
	repo="$(new_repo repo)"
	# A global core.hooksPath would be read by `git config` queries of the
	# local file only if the tool asked for the merged value.
	printf '[core]\n\thooksPath = /global\n' >"$scratch/global"
	GIT_CONFIG_GLOBAL="$scratch/global" capture ravnix-dev-checkout "$repo"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
}

it_refuses_wrong_usage() {
	fresh
	capture ravnix-dev-checkout
	expect_status 2
	expect_err "usage"
	capture ravnix-dev-checkout a b c
	expect_status 2
	capture ravnix-dev-checkout ""
	expect_status 2
}

it_stays_quiet_when_all_is_well() {
	fresh
	local repo
	repo="$(new_repo repo)"
	capture ravnix-dev-checkout "$repo" /deny.txt
	expect_status 0
	[[ -z "$out" && -z "$err" ]] || {
		echo "  expected no output, got: $out $err"
		return 1
	}
}

tests=(
	it_turns_the_hooks_on_and_names_the_deny_list
	it_leaves_the_deny_list_alone_when_none_is_given
	it_sets_no_deny_list_when_none_is_given
	it_can_run_twice_and_changes_a_stale_value
	it_does_not_fail_the_activation_for_a_checkout_that_is_not_there_yet
	it_does_not_fail_for_a_directory_that_is_no_repository
	it_does_not_fail_for_a_file_in_place_of_the_checkout
	it_copes_with_spaces_quotes_and_glob_characters_in_the_path
	it_works_through_a_symbolic_link
	it_configures_the_repository_a_subdirectory_belongs_to
	it_configures_a_checkout_that_is_a_linked_work_tree
	it_takes_an_absolute_path_only_so_nothing_reads_as_an_option
	it_says_so_and_still_succeeds_when_the_configuration_cannot_be_written
	it_ignores_the_users_own_git_configuration
	it_refuses_wrong_usage
	it_stays_quiet_when_all_is_well
)

run_tests "${tests[@]}"
