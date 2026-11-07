#!/usr/bin/env bash
# Tests for scripts/tests/lib.sh, the runner every shell test file uses. Each
# test writes a small test file that sources lib.sh and runs it. Run it with:
#
#   bash scripts/tests/lib.test.sh

# The test file's code is for the inner shell to expand, not this one.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

# Runs a test file whose body is the arguments, with its own TMPDIR.
inner_tmp=""
run_file() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	inner_tmp="$dir/tmp"
	mkdir -p "$inner_tmp"
	write_script "$dir/inner.test.sh" ". '$here/lib.sh'" "$@"
	capture env TMPDIR="$inner_tmp" "$dir/inner.test.sh"
}

no_tests_fail_the_run() {
	run_file 'run_tests'
	expect_status 1
	expect_said "no tests"
}

an_empty_test_list_fails_the_run() {
	run_file 'tests=()' 'run_tests "${tests[@]}"'
	expect_status 1
	expect_said "no tests"
}

a_failing_test_fails_the_run() {
	run_file 'good() { :; }' 'bad() { false; }' 'run_tests good bad'
	expect_status 1
	expect_said "PASS good"
	expect_said "FAIL bad"
	expect_said "1 of 2 tests failed"
}

passing_tests_pass_the_run() {
	run_file 'one() { :; }' 'two() { :; }' 'run_tests one two'
	expect_status 0
	expect_said "all 2 tests passed"
}

a_test_ends_at_its_first_failing_command() {
	run_file 't() { false; echo reached; }' 'run_tests t'
	expect_status 1
	expect_no_out "reached"
}

the_scratch_directory_is_removed() {
	run_file 'one() { :; }' 'run_tests one'
	expect_status 0
	[[ -z "$(find "$inner_tmp" -mindepth 1 -print -quit)" ]] || {
		echo "  lib.sh left files in TMPDIR: $(ls -A "$inner_tmp")"
		return 1
	}
}

tests=(
	no_tests_fail_the_run
	an_empty_test_list_fails_the_run
	a_failing_test_fails_the_run
	passing_tests_pass_the_run
	a_test_ends_at_its_first_failing_command
	the_scratch_directory_is_removed
)

run_tests "${tests[@]}"
