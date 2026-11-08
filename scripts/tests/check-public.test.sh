#!/usr/bin/env bash
# Tests for scripts/check-public.sh, the public-boundary check. Each test
# builds a fixture tree and a deny list in a temporary directory and runs the
# check on it. Every value in the fixtures is made up; a real deny-list entry
# never belongs in this repository. Run it with:
#
#   bash scripts/tests/check-public.test.sh
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/../check-public.sh"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

# Set by new_tree for the test that is running.
tree=""
list=""
fake_bin=""

# Creates an empty fixture tree and a deny list holding the arguments, one
# entry per line.
new_tree() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	tree="$dir/tree"
	list="$dir/deny-list.txt"
	mkdir -p "$tree"
	if (($# > 0)); then
		printf '%s\n' "$@" >"$list"
	else
		: >"$list"
	fi
}

# Writes $2 (printf format and arguments follow) into $tree/$1.
put() {
	local path="$tree/$1"
	shift
	mkdir -p "$(dirname "$path")"
	# shellcheck disable=SC2059 # the format is the caller's
	printf "$@" >"$path"
}

# Runs the check from inside $tree with the given arguments.
in_tree() {
	cd "$tree" && "$@"
}
run_check() {
	capture in_tree "$check" "$@"
}

# The cases the plan names.

an_address_in_a_nix_file_is_a_hit() {
	new_tree '198.51.100.'
	put a.nix 'address = "198.51.100.7";\n'
	run_check "$list" .
	expect_status 1
	expect_out "a.nix:1:deny-list.txt:1"
}

a_clean_tree_passes() {
	new_tree '198.51.100.' 'alice@example.org'
	put a.nix 'address = "192.0.2.1";\n'
	put docs/readme.md 'Nothing personal here.\n'
	run_check "$list" .
	expect_status 0
	[[ -z "$out" ]] || {
		echo "  expected no output, got: $out"
		return 1
	}
}

the_author_line_in_license_and_authors_passes() {
	new_tree 'alice@example.org' 'Alice Example'
	put LICENSE 'Copyright (C) 2026 Alice Example <alice@example.org>\n'
	put AUTHORS 'Alice Example <alice@example.org>\n'
	run_check "$list" .
	expect_status 0
}

an_empty_deny_list_is_bad_usage() {
	new_tree
	put a.nix 'x\n'
	run_check "$list" .
	expect_status 2
	expect_err "no entries"
}

a_regex_metacharacter_matches_literally() {
	new_tree 'a.b'
	put near.txt 'axb a-b ab\n'
	run_check "$list" .
	expect_status 0
	put exact.txt 'see a.b here\n'
	run_check "$list" .
	expect_status 1
	expect_out "exact.txt:1:deny-list.txt:1"
	expect_no_out "near.txt"
}

# Matching.

matching_ignores_case() {
	new_tree 'alice@example.org'
	put a.md 'Mail ALICE@Example.ORG\n'
	run_check "$list" .
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
}

matching_folds_the_case_of_non_ascii_letters() {
	new_tree 'ölkännchen'
	put a.md 'ein ÖLKÄNNCHEN\n'
	# The hooks may run in the C locale; the folding must not depend on it.
	capture in_tree env LC_ALL=C "$check" "$list" .
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
}

an_entry_keeps_its_inner_spaces() {
	new_tree 'alice example'
	put joined.md 'aliceexample\n'
	run_check "$list" .
	expect_status 0
	put spaced.md 'Hi Alice Example!\n'
	run_check "$list" .
	expect_status 1
	expect_out "spaced.md:1:deny-list.txt:1"
}

an_entry_that_starts_with_a_dash_is_a_literal() {
	new_tree '--files'
	put a.md 'nothing\n'
	run_check "$list" .
	expect_status 0
	put b.md 'run it with --files here\n'
	run_check "$list" .
	expect_status 1
	expect_out "b.md:1:deny-list.txt:1"
}

blank_lines_comments_and_outer_whitespace_in_the_list_are_ignored() {
	new_tree '# a comment that would match everything: e' '' '   ' \
		'  alice@example.org  ' '	# an indented comment'
	put a.md 'e e e\n'
	run_check "$list" .
	expect_status 0
	put b.md 'alice@example.org\n'
	run_check "$list" .
	expect_status 1
	expect_lines 1
	expect_out "b.md:1:deny-list.txt:4"
}

a_list_of_only_comments_is_bad_usage() {
	new_tree '# one' '' '# two'
	put a.md 'x\n'
	run_check "$list" .
	expect_status 2
	expect_err "no entries"
}

a_list_with_crlf_line_ends_works() {
	new_tree
	printf 'alice@example.org\r\n198.51.100.\r\n' >"$list"
	put a.md 'to alice@example.org\n'
	run_check "$list" .
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
}

a_list_without_a_final_newline_keeps_its_last_entry() {
	new_tree
	printf 'first\nalice@example.org' >"$list"
	put a.md 'alice@example.org\n'
	run_check "$list" .
	expect_status 1
}

every_hit_is_reported_with_its_line() {
	new_tree 'alice' '198.51.100.'
	put a.md 'line one\nalice and alice again\n198.51.100.1 and alice\n'
	put b.md 'alice\n'
	run_check "$list" .
	expect_status 1
	expect_out "a.md:2:deny-list.txt:1"
	expect_out "a.md:3:deny-list.txt:1"
	expect_out "a.md:3:deny-list.txt:2"
	expect_out "b.md:1:deny-list.txt:1"
	# Two matches on one line are one hit.
	expect_lines 4
	expect_err "4 hits"
}

# What is searched.

hidden_files_are_searched() {
	new_tree 'alice'
	put .env 'USER=alice\n'
	put .config/x.toml 'name = "alice"\n'
	run_check "$list" .
	expect_status 1
	expect_out ".env:1:deny-list.txt:1"
	expect_out ".config/x.toml:1:deny-list.txt:1"
}

ignored_files_are_searched() {
	new_tree 'alice'
	put .gitignore 'secret.txt\nbuild/\n'
	put .ignore 'other.txt\n'
	put secret.txt 'alice\n'
	put other.txt 'alice\n'
	put build/out.txt 'alice\n'
	run_check "$list" .
	expect_status 1
	expect_out "secret.txt:1:deny-list.txt:1"
	expect_out "other.txt:1:deny-list.txt:1"
	expect_out "build/out.txt:1:deny-list.txt:1"
}

a_binary_file_is_searched_as_text() {
	new_tree 'alice'
	put blob.bin 'head\0\001\002 alice \0tail\n'
	run_check "$list" .
	expect_status 1
	expect_out "blob.bin:1:deny-list.txt:1"
}

a_huge_file_is_searched_to_its_end() {
	new_tree 'alice@example.org'
	head -c 8000000 /dev/zero | tr '\0' 'x' >"$tree/big.txt"
	printf '\nalice@example.org\n' >>"$tree/big.txt"
	run_check "$list" .
	expect_status 1
	expect_out "big.txt:2:deny-list.txt:1"
}

an_empty_file_passes() {
	new_tree 'alice'
	: >"$tree/empty.txt"
	run_check "$list" .
	expect_status 0
}

a_user_ripgrep_config_does_not_change_the_search() {
	new_tree 'alice'
	put a.md 'Alice\n'
	printf -- '--case-sensitive\n--max-filesize=1\n--type=rust\n' >"$scratch/rgrc"
	capture in_tree env RIPGREP_CONFIG_PATH="$scratch/rgrc" "$check" "$list" .
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
}

# What is excluded, and only that.

only_license_and_authors_at_the_top_are_excluded() {
	new_tree 'alice'
	put LICENSE 'alice\n'
	put AUTHORS 'alice\n'
	put docs/LICENSE-notes.md 'alice\n'
	put vendor/x/LICENSE 'alice\n'
	put vendor/x/AUTHORS 'alice\n'
	put LICENSE.md 'alice\n'
	put AUTHORS.txt 'alice\n'
	run_check "$list" .
	expect_status 1
	expect_out "docs/LICENSE-notes.md:1:deny-list.txt:1"
	expect_out "vendor/x/LICENSE:1:deny-list.txt:1"
	expect_out "vendor/x/AUTHORS:1:deny-list.txt:1"
	expect_out "LICENSE.md:1:deny-list.txt:1"
	expect_out "AUTHORS.txt:1:deny-list.txt:1"
	expect_lines 5
}

the_git_directory_is_excluded() {
	new_tree 'alice'
	put .git/config '[user]\n\tname = alice\n'
	put .git/COMMIT_EDITMSG 'alice\n'
	put sub/.git 'gitdir: /home/alice/repo/.git/worktrees/sub\n'
	put a.md 'clean\n'
	run_check "$list" .
	expect_status 0
	put .github/x.yml 'alice\n'
	put .gitignore 'alice\n'
	run_check "$list" .
	expect_status 1
	expect_out ".github/x.yml:1:deny-list.txt:1"
	expect_out ".gitignore:1:deny-list.txt:1"
}

# What a hit shows. The output goes into logs, transcripts and reports, so a
# hit names the entry by its line in the deny list and never prints its value,
# and the values do not travel on a command line, where any local user could
# read them.

a_hit_names_the_list_line_and_never_prints_the_entry() {
	new_tree '# a comment' 'first-made-up-entry' '' 'zq-made-up-token-7731'
	put a.md 'x\nsee zq-made-up-token-7731 here\n'
	run_check "$list" .
	expect_status 1
	expect_out "a.md:2:deny-list.txt:4"
	expect_lines 1
	expect_no_out "zq-made-up-token"
	expect_no_err "zq-made-up-token"
	expect_err "1 hit"
}

a_link_hit_names_the_list_line_and_never_prints_the_entry() {
	new_tree 'zq-made-up-token-7731'
	ln -s /home/zq-made-up-token-7731/notes "$tree/lnk"
	run_check "$list" .
	expect_status 1
	expect_out "lnk:link:deny-list.txt:1"
	expect_no_out "zq-made-up-token"
	expect_no_err "zq-made-up-token"
}

a_name_hit_names_the_list_line() {
	new_tree 'first-made-up-entry' 'zq-made-up-token-7731'
	put 'notes/zq-made-up-token-7731.md' 'clean\n'
	run_check "$list" .
	expect_status 1
	# The path is the file's own, and it is all the output says of the entry.
	expect_out "notes/zq-made-up-token-7731.md:name:deny-list.txt:2"
	expect_lines 1
}

# A made-up rg that records how it was called and then runs the real one, or
# fails when RG_FAIL is set. For each --file it notes the directory of the
# file and the modes of both. The caller puts fake_bin first on the PATH and
# gives it RG_LOG, the file to write, and REAL_RG, the rg to run.
fake_rg() {
	fake_bin="$(mktemp -d -p "$scratch")"
	{
		printf '#!%s\n' "$BASH"
		cat <<'SCRIPT'
{ printf 'ARGV'; printf ' [%s]' "$@"; printf '\n'; } >>"$RG_LOG"
prev=""
for a in "$@"; do
	if [[ "$prev" == --file ]]; then
		printf 'FILE %s %s %s\n' "$(dirname "$a")" "$(stat -c %a "$a")" \
			"$(stat -c %a "$(dirname "$a")")" >>"$RG_LOG"
	fi
	prev="$a"
done
[[ -z "${RG_FAIL:-}" ]] || exit 2
exec "$REAL_RG" "$@"
SCRIPT
	} >"$fake_bin/rg"
	chmod +x "$fake_bin/rg"
}

the_entries_stay_off_the_command_line_and_in_a_private_file() {
	new_tree 'zq-made-up-token-7731' 'second-made-up-entry'
	put a.md 'zq-made-up-token-7731\n'
	ln -s /home/second-made-up-entry "$tree/lnk"
	fake_rg
	capture in_tree env PATH="$fake_bin:$PATH" RG_LOG="$scratch/rg.log" REAL_RG="$(command -v rg)" "$check" "$list" .
	expect_status 1
	# Every search ran, contents and links (a name that holds an entry is the
	# file's own path, which any search of the file has to be given), and
	# none was handed an entry as an argument.
	local log
	log="$(cat "$scratch/rg.log")"
	[[ "$log" != *zq-made-up-token* && "$log" != *second-made-up-entry* ]] || {
		echo "  an entry was on rg's command line: $log"
		return 1
	}
	local files
	files="$(grep -c '^FILE ' "$scratch/rg.log")"
	((files >= 4)) || {
		echo "  expected the entries to be read from files in every search, got $files: $log"
		return 1
	}
	# Each file is the owner's alone, in a directory that is the owner's alone,
	# and the directory is gone when the check ends.
	[[ -z "$(grep '^FILE ' "$scratch/rg.log" | awk '$3 != "600" || $4 != "700"')" ]] || {
		echo "  an entries file or its directory is open to others: $log"
		return 1
	}
	local dir
	while read -r dir; do
		[[ ! -e "$dir" ]] || {
			echo "  $dir is still there after the check"
			return 1
		}
	done < <(grep '^FILE ' "$scratch/rg.log" | awk '{ print $2 }' | sort -u)
}

the_private_directory_is_removed_when_the_search_fails() {
	new_tree 'zq-made-up-token-7731'
	put a.md 'zq-made-up-token-7731\n'
	fake_rg
	capture in_tree env PATH="$fake_bin:$PATH" RG_LOG="$scratch/rg.log" REAL_RG="$(command -v rg)" RG_FAIL=1 "$check" "$list" .
	expect_status 2
	expect_err "the search failed"
	expect_no_err "zq-made-up-token"
	local dir
	dir="$(grep '^FILE ' "$scratch/rg.log" | awk '{ print $2 }' | sort -u)"
	[[ -n "$dir" && ! -e "$dir" ]] || {
		echo "  the private directory '$dir' is still there after a failed search"
		return 1
	}
}

# Names and links.

a_file_name_holding_an_entry_is_a_hit() {
	new_tree 'alice'
	put notes-for-ALICE.md 'clean\n'
	put alice/readme.md 'clean\n'
	run_check "$list" .
	expect_status 1
	expect_out "notes-for-ALICE.md:name:deny-list.txt:1"
	expect_out "alice/readme.md:name:deny-list.txt:1"
}

the_scanned_directory_own_name_is_not_checked() {
	new_tree 'alice'
	mkdir -p "$tree/alice-work"
	put alice-work/a.md 'clean\n'
	run_check "$list" alice-work
	expect_status 0
}

a_symlink_is_checked_by_its_target_not_followed() {
	new_tree 'alice'
	printf 'alice\n' >"$scratch/outside.txt"
	ln -s "$scratch/outside.txt" "$tree/plain-link"
	run_check "$list" .
	expect_status 0
	ln -s /home/alice/notes "$tree/home-link"
	run_check "$list" .
	expect_status 1
	expect_out "home-link:link:deny-list.txt:1"
	expect_no_out "plain-link"
}

a_dangling_symlink_is_checked_by_its_target() {
	new_tree 'alice'
	ln -s /nonexistent/alice "$tree/dangling"
	run_check "$list" .
	expect_status 1
	expect_out "dangling:link:deny-list.txt:1"
}

# Arguments.

files_can_be_named_one_by_one() {
	new_tree 'alice'
	put a.md 'alice\n'
	put b.md 'clean\n'
	put c.md 'alice\n'
	run_check "$list" a.md b.md
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
	expect_no_out "c.md"
}

license_named_at_the_top_is_excluded_as_a_file_too() {
	new_tree 'alice'
	put LICENSE 'alice\n'
	put AUTHORS 'alice\n'
	put sub/LICENSE 'alice\n'
	run_check "$list" LICENSE ./AUTHORS "$tree/LICENSE"
	expect_status 0
	run_check "$list" sub/LICENSE
	expect_status 1
	expect_out "sub/LICENSE:1:deny-list.txt:1"
}

a_file_inside_a_git_directory_named_by_hand_is_checked() {
	new_tree 'alice'
	put .git/COMMIT_EDITMSG 'alice\n'
	run_check "$list" .git/COMMIT_EDITMSG
	expect_status 1
	expect_out ".git/COMMIT_EDITMSG:1:deny-list.txt:1"
}

a_file_name_is_checked_only_inside_a_directory() {
	new_tree 'alice'
	put alice.md 'clean\n'
	run_check "$list" alice.md
	expect_status 0
}

paths_with_spaces_and_colons_are_reported_whole() {
	new_tree 'alice'
	put 'dir with space/a:b.md' 'x\nalice\n'
	run_check "$list" .
	expect_status 1
	expect_out "dir with space/a:b.md:2:deny-list.txt:1"
}

several_directories_each_exclude_their_own_top() {
	new_tree 'alice'
	put one/LICENSE 'alice\n'
	put two/LICENSE 'alice\n'
	put two/x.md 'alice\n'
	run_check "$list" one two
	expect_status 1
	expect_out "two/x.md:1:deny-list.txt:1"
	expect_lines 1
}

no_path_means_the_current_directory() {
	new_tree 'alice'
	put a.md 'alice\n'
	run_check "$list"
	expect_status 1
	expect_out "a.md:1:deny-list.txt:1"
}

an_absolute_directory_is_reported_with_its_path() {
	new_tree 'alice'
	put a.md 'alice\n'
	run_check "$list" "$tree"
	expect_status 1
	expect_out "$tree/a.md:1:deny-list.txt:1"
}

no_arguments_is_bad_usage() {
	new_tree 'alice'
	run_check
	expect_status 2
	expect_err "usage"
}

an_option_instead_of_a_list_is_bad_usage() {
	new_tree 'alice'
	run_check --help
	expect_status 2
	expect_err "usage"
}

a_missing_list_is_bad_usage() {
	new_tree 'alice'
	run_check "$scratch/no-such-list" .
	expect_status 2
	expect_err "cannot read the deny list"
}

a_directory_as_the_list_is_bad_usage() {
	new_tree 'alice'
	run_check "$tree" .
	expect_status 2
	expect_err "cannot read the deny list"
}

an_unreadable_list_is_bad_usage() {
	(($(id -u) != 0)) || return 0 # root reads it anyway
	new_tree 'alice'
	chmod 000 "$list"
	run_check "$list" .
	expect_status 2
	expect_err "cannot read the deny list"
}

a_missing_path_is_bad_usage() {
	new_tree 'alice'
	put a.md 'clean\n'
	run_check "$list" a.md no-such-file
	expect_status 2
	expect_err "no-such-file"
}

an_unreadable_file_fails_closed() {
	(($(id -u) != 0)) || return 0 # root reads it anyway
	new_tree 'alice'
	put a.md 'clean\n'
	put locked.md 'alice\n'
	chmod 000 "$tree/locked.md"
	run_check "$list" .
	expect_status 2
}

a_missing_ripgrep_fails_closed() {
	new_tree 'alice'
	put a.md 'alice\n'
	local bin tool
	bin="$(mktemp -d -p "$scratch")"
	for tool in bash cat dirname env find readlink realpath sed sort tr wc; do
		ln -s "$(command -v "$tool")" "$bin/$tool"
	done
	capture in_tree env PATH="$bin" "$check" "$list" .
	expect_status 2
	expect_err "rg not found"
}

concurrent_runs_do_not_disturb_each_other() {
	new_tree 'alice'
	local i
	for i in $(seq 1 20); do
		put "f$i.md" 'x\nalice\n'
	done
	local pids=() rc=0
	for i in 1 2 3 4; do
		(
			s=0
			cd "$tree"
			"$check" "$list" . >"$scratch/par$i" 2>/dev/null || s=$?
			echo "$s" >"$scratch/par$i.rc"
		) &
		pids+=($!)
	done
	wait "${pids[@]}"
	for i in 1 2 3 4; do
		[[ "$(cat "$scratch/par$i.rc")" == 1 ]] || rc=1
		[[ "$(wc -l <"$scratch/par$i")" == 20 ]] || rc=1
	done
	((rc == 0)) || {
		echo "  a concurrent run gave another result"
		return 1
	}
}

tests=(
	an_address_in_a_nix_file_is_a_hit
	a_clean_tree_passes
	the_author_line_in_license_and_authors_passes
	an_empty_deny_list_is_bad_usage
	a_regex_metacharacter_matches_literally
	matching_ignores_case
	matching_folds_the_case_of_non_ascii_letters
	an_entry_keeps_its_inner_spaces
	an_entry_that_starts_with_a_dash_is_a_literal
	blank_lines_comments_and_outer_whitespace_in_the_list_are_ignored
	a_list_of_only_comments_is_bad_usage
	a_list_with_crlf_line_ends_works
	a_list_without_a_final_newline_keeps_its_last_entry
	every_hit_is_reported_with_its_line
	hidden_files_are_searched
	ignored_files_are_searched
	a_binary_file_is_searched_as_text
	a_huge_file_is_searched_to_its_end
	an_empty_file_passes
	a_user_ripgrep_config_does_not_change_the_search
	only_license_and_authors_at_the_top_are_excluded
	the_git_directory_is_excluded
	a_file_name_holding_an_entry_is_a_hit
	the_scanned_directory_own_name_is_not_checked
	a_symlink_is_checked_by_its_target_not_followed
	a_dangling_symlink_is_checked_by_its_target
	files_can_be_named_one_by_one
	license_named_at_the_top_is_excluded_as_a_file_too
	a_file_inside_a_git_directory_named_by_hand_is_checked
	a_file_name_is_checked_only_inside_a_directory
	paths_with_spaces_and_colons_are_reported_whole
	several_directories_each_exclude_their_own_top
	no_path_means_the_current_directory
	an_absolute_directory_is_reported_with_its_path
	no_arguments_is_bad_usage
	an_option_instead_of_a_list_is_bad_usage
	a_missing_list_is_bad_usage
	a_directory_as_the_list_is_bad_usage
	an_unreadable_list_is_bad_usage
	a_missing_path_is_bad_usage
	an_unreadable_file_fails_closed
	a_missing_ripgrep_fails_closed
	concurrent_runs_do_not_disturb_each_other
	a_hit_names_the_list_line_and_never_prints_the_entry
	a_link_hit_names_the_list_line_and_never_prints_the_entry
	a_name_hit_names_the_list_line
	the_entries_stay_off_the_command_line_and_in_a_private_file
	the_private_directory_is_removed_when_the_search_fails
)

run_tests "${tests[@]}"
