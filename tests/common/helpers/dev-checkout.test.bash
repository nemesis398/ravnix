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
	expect_err "WARNING"
	expect_err "OFF"
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
	expect_err "WARNING"
	expect_err "OFF"
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

# The checkout is the repository at that path and no other: a directory that
# lies inside another repository (an empty submodule directory, a clone that
# failed after mkdir, a home directory under git) is not it, and the other
# repository's hooks are none of this tool's business.
it_leaves_an_enclosing_repository_alone_for_a_subdirectory() {
	fresh
	local repo
	repo="$(new_repo repo)"
	mkdir "$repo/sub"
	capture ravnix-dev-checkout "$repo/sub" /deny.txt
	expect_status 0
	[[ -z "$(config_of "$repo" core.hooksPath)" ]]
	[[ -z "$(config_of "$repo" ravnix.denyList)" ]]
	expect_err "WARNING"
	expect_err "$repo/sub"
	expect_err "top level"
	expect_err "$repo"
}

it_leaves_the_repository_of_an_uninitialized_submodule_directory_alone() {
	fresh
	local parent library
	library="$(new_repo library)"
	parent="$(new_repo parent)"
	git -C "$parent" -c protocol.file.allow=always submodule add -q "$library" ravnix
	git -C "$parent" submodule deinit -q -f ravnix
	[[ -d "$parent/ravnix" && -z "$(ls -A "$parent/ravnix")" ]]
	capture ravnix-dev-checkout "$parent/ravnix" /deny.txt
	expect_status 0
	[[ -z "$(config_of "$parent" core.hooksPath)" ]]
	[[ -z "$(config_of "$parent" ravnix.denyList)" ]]
	expect_err "WARNING"
	expect_err "$parent/ravnix"
}

it_leaves_a_home_directory_under_git_alone() {
	fresh
	local home
	home="$(new_repo home)"
	mkdir -p "$home/src/ravnix"
	capture ravnix-dev-checkout "$home/src/ravnix"
	expect_status 0
	[[ -z "$(config_of "$home" core.hooksPath)" ]]
	expect_err "WARNING"
}

it_configures_a_repository_inside_another_one_by_its_own_top_level() {
	fresh
	local outer inner
	outer="$(new_repo outer)"
	mkdir "$outer/vendor"
	inner="$(new_repo "outer/vendor/inner")"
	capture ravnix-dev-checkout "$inner" /deny.txt
	expect_status 0
	[[ "$(config_of "$inner" core.hooksPath)" == .githooks ]]
	[[ -z "$(config_of "$outer" core.hooksPath)" ]]
	[[ -z "$err" ]]
}

it_leaves_the_inside_of_the_git_directory_alone() {
	fresh
	local repo
	repo="$(new_repo repo)"
	capture ravnix-dev-checkout "$repo/.git" /deny.txt
	expect_status 0
	[[ -z "$(config_of "$repo" core.hooksPath)" ]]
	expect_err "WARNING"
}

it_leaves_a_bare_repository_alone() {
	fresh
	git init -q --bare "$scratch/bare.git"
	capture ravnix-dev-checkout "$scratch/bare.git" /deny.txt
	expect_status 0
	[[ -z "$(config_of "$scratch/bare.git" core.hooksPath)" ]]
	expect_err "WARNING"
}

it_leaves_the_repository_behind_a_symbolic_link_to_a_subdirectory_alone() {
	fresh
	local repo
	repo="$(new_repo repo)"
	mkdir "$repo/sub"
	ln -s "$repo/sub" "$scratch/link"
	capture ravnix-dev-checkout "$scratch/link"
	expect_status 0
	[[ -z "$(config_of "$repo" core.hooksPath)" ]]
	expect_err "WARNING"
}

it_takes_a_path_with_a_trailing_slash_or_dot_dot_for_the_same_checkout() {
	fresh
	local repo
	repo="$(new_repo repo)"
	mkdir "$scratch/elsewhere"
	capture ravnix-dev-checkout "$repo/"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	git -C "$repo" config --unset core.hooksPath
	capture ravnix-dev-checkout "$scratch/elsewhere/../repo"
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ -z "$err" ]]
}

it_does_not_let_an_inherited_git_dir_point_it_at_another_repository() {
	fresh
	local repo other
	repo="$(new_repo repo)"
	other="$(new_repo other)"
	GIT_DIR="$other/.git" GIT_WORK_TREE="$other" capture ravnix-dev-checkout "$repo" /deny.txt
	expect_status 0
	[[ "$(config_of "$repo" core.hooksPath)" == .githooks ]]
	[[ -z "$(config_of "$other" core.hooksPath)" ]]
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
	expect_err "WARNING"
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
	it_leaves_an_enclosing_repository_alone_for_a_subdirectory
	it_leaves_the_repository_of_an_uninitialized_submodule_directory_alone
	it_leaves_a_home_directory_under_git_alone
	it_configures_a_repository_inside_another_one_by_its_own_top_level
	it_leaves_the_inside_of_the_git_directory_alone
	it_leaves_a_bare_repository_alone
	it_leaves_the_repository_behind_a_symbolic_link_to_a_subdirectory_alone
	it_takes_a_path_with_a_trailing_slash_or_dot_dot_for_the_same_checkout
	it_does_not_let_an_inherited_git_dir_point_it_at_another_repository
	it_configures_a_checkout_that_is_a_linked_work_tree
	it_takes_an_absolute_path_only_so_nothing_reads_as_an_option
	it_says_so_and_still_succeeds_when_the_configuration_cannot_be_written
	it_ignores_the_users_own_git_configuration
	it_refuses_wrong_usage
	it_stays_quiet_when_all_is_well
)

run_tests "${tests[@]}"
