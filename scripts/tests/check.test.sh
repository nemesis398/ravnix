#!/usr/bin/env bash
# Tests for scripts/check.sh, the gate. Each test builds a git repository in
# a temporary directory with copies of the gate's scripts, a deny list of
# made-up values beside it, and runs the gate there. A fake nix stands in for
# the real one, so the full gate runs in seconds. Run it with:
#
#   bash scripts/tests/check.test.sh

# The fixture scripts' code is for the fixture's shell to expand, not this one.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

# Set by new_repo for the test that is running.
repo=""
list=""
bin=""
tmp=""

# Creates a repository holding the gate's scripts and one clean file, all
# committed, with ravnix.denyList pointing at a deny list outside it. bin is
# a directory, first on PATH in gate, that holds a fake nix logging its
# arguments to $bin/nix.log; tmp is the gate's TMPDIR.
new_repo() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	repo="$dir/repo"
	list="$dir/deny-list.txt"
	bin="$dir/bin"
	tmp="$dir/tmp"
	mkdir -p "$tmp"
	printf '%s\n' 'alice@example.org' '198.51.100.' >"$list"
	git init -q -b main "$repo"
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example.invalid
	git -C "$repo" config ravnix.denyList "$list"
	mkdir -p "$repo/scripts/lib"
	cp -p "$src/scripts/check.sh" "$src/scripts/check-public.sh" "$src/scripts/check-style.sh" "$repo/scripts/"
	cp -p "$src/scripts/lib/git-snapshot.sh" "$repo/scripts/lib/"
	printf 'clean\n' >"$repo/a.md"
	git -C "$repo" add -A
	git -C "$repo" commit -qm init
	fake_nix 0
}

# Makes the fake nix exit with $1.
fake_nix() {
	write_script "$bin/nix" "printf '%s\n' \"\$*\" >>'$bin/nix.log'" "exit $1"
}

# Writes $2 into $repo/$1 and stages it.
stage() {
	mkdir -p "$(dirname "$repo/$1")"
	printf '%s\n' "$2" >"$repo/$1"
	git -C "$repo" add -- "$1"
}

in_repo() {
	cd "$repo" && "$@"
}
gate() {
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" scripts/check.sh "$@"
}

# Arguments.

the_fast_gate_passes_on_a_clean_repository() {
	new_repo
	gate --fast
	expect_status 0
	expect_out "all 3 steps passed"
	[[ ! -s "$bin/nix.log" ]] || {
		echo "  the fast gate ran nix: $(cat "$bin/nix.log")"
		return 1
	}
}

the_full_gate_adds_nix_flake_check() {
	new_repo
	gate
	expect_status 0
	expect_out "all 4 steps passed"
	[[ "$(cat "$bin/nix.log")" == *"flake check"* ]] || {
		echo "  expected nix flake check, the fake nix got: $(cat "$bin/nix.log" 2>/dev/null)"
		return 1
	}
}

an_unknown_argument_is_bad_usage() {
	new_repo
	gate --fats
	expect_status 2
	expect_err "usage"
	gate --fast extra
	expect_status 2
}

the_gate_runs_from_any_directory_of_the_checkout() {
	new_repo
	mkdir -p "$repo/docs"
	capture env -C "$repo/docs" PATH="$bin:$PATH" ../scripts/check.sh --fast
	expect_status 0
}

outside_a_git_work_tree_the_gate_fails() {
	new_repo
	local copy="$scratch/no-git"
	mkdir -p "$copy"
	cp -rp "$repo/scripts" "$copy/"
	capture env -C "$copy" PATH="$bin:$PATH" scripts/check.sh --fast
	expect_status 1
	expect_err "not a git work tree"
}

# The boundary step.

a_staged_leak_fails_the_gate() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	gate --fast
	expect_status 1
	expect_out "hosts.nix:1:198.51.100."
}

a_staged_leak_under_a_clean_work_tree_fails_the_gate() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	printf 'address = "192.0.2.1";\n' >"$repo/hosts.nix"
	gate --fast
	expect_status 1
	expect_out "hosts.nix:1:198.51.100."
}

an_unstaged_leak_in_a_tracked_file_fails_the_gate() {
	new_repo
	printf 'mail alice@example.org\n' >>"$repo/a.md"
	gate --fast
	expect_status 1
	expect_out "a.md:2:alice@example.org"
}

an_untracked_file_is_not_checked() {
	new_repo
	printf 'alice@example.org\n' >"$repo/scratch-notes.md"
	gate --fast
	expect_status 0
}

a_leak_in_license_or_authors_passes() {
	new_repo
	stage LICENSE 'Copyright (C) 2026 Alice Example <alice@example.org>'
	stage AUTHORS 'Alice Example <alice@example.org>'
	gate --fast
	expect_status 0
}

a_staged_symlink_to_a_personal_path_fails_the_gate() {
	new_repo
	ln -s /home/alice@example.org/notes "$repo/notes"
	git -C "$repo" add notes
	gate --fast
	expect_status 1
	expect_out "notes:link:alice@example.org"
}

a_staged_file_name_holding_an_entry_fails_the_gate() {
	new_repo
	stage 'docs/alice@example.org.md' 'clean'
	gate --fast
	expect_status 1
	expect_out "docs/alice@example.org.md:name:alice@example.org"
}

a_path_with_spaces_is_snapshotted() {
	new_repo
	stage 'docs/a b/c d.md' 'mail alice@example.org'
	gate --fast
	expect_status 1
	expect_out "docs/a b/c d.md:1:alice@example.org"
}

a_staged_deletion_of_a_leak_passes() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	stage old.md 'alice@example.org'
	git -C "$repo" commit -qm leak
	git -C "$repo" config ravnix.denyList "$list"
	git -C "$repo" rm -q old.md
	gate --fast
	expect_status 0
}

without_a_deny_list_the_boundary_check_is_skipped_with_a_note() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	stage hosts.nix '198.51.100.7'
	gate --fast
	expect_status 0
	expect_said "SKIPPED"
	expect_said "ravnix.denyList"
}

a_deny_list_that_does_not_exist_fails_the_gate() {
	new_repo
	git -C "$repo" config ravnix.denyList "$scratch/moved-away.txt"
	gate --fast
	expect_status 2
	expect_err "cannot read the deny list"
}

a_relative_deny_list_is_read_from_the_top_of_the_checkout() {
	new_repo
	cp "$list" "$repo/.deny"
	git -C "$repo" config ravnix.denyList .deny
	printf '.deny\n' >"$repo/.git/info/exclude"
	stage hosts.nix '198.51.100.7'
	gate --fast
	expect_status 1
	expect_out "hosts.nix:1:198.51.100."
}

the_first_failing_step_ends_the_gate_with_its_status() {
	new_repo
	stage hosts.nix '198.51.100.7'
	write_script "$repo/tool.sh" 'echo $1'
	git -C "$repo" add tool.sh
	gate --fast
	expect_status 1
	expect_no_out "==> shellcheck"
	expect_err "boundary failed"
}

the_snapshot_is_removed_after_the_run() {
	new_repo
	stage hosts.nix '198.51.100.7'
	gate --fast
	expect_status 1
	[[ -z "$(find "$tmp" -mindepth 1 -print -quit)" ]] || {
		echo "  the gate left files in its TMPDIR: $(ls -A "$tmp")"
		return 1
	}
}

# The style step.

a_staged_hex_color_outside_the_theme_fails_the_gate() {
	new_repo
	stage modules/waybar.nix 'accent = "#cba6f7";'
	gate --fast
	expect_status 1
	expect_out "modules/waybar.nix:1:hex-color"
	expect_err "style failed"
}

a_hex_color_in_the_theme_module_passes_the_gate() {
	new_repo
	stage modules/theme/palette.nix 'mauve = "#cba6f7";'
	gate --fast
	expect_status 0
	expect_out "no style rule broken"
}

the_staged_version_of_a_styled_file_is_judged() {
	new_repo
	stage modules/bar.css 'a { border-radius: 4px; }'
	printf 'a { border-radius: 0; }\n' >"$repo/modules/bar.css"
	gate --fast
	expect_status 1
	expect_out "modules/bar.css:1:radius"
}

an_unstaged_style_break_in_a_tracked_file_fails_the_gate() {
	new_repo
	stage modules/bar.css 'a { border-radius: 0; }'
	git -C "$repo" commit -qm bar
	printf 'a { opacity: 0.9; }\n' >"$repo/modules/bar.css"
	gate --fast
	expect_status 1
	expect_out "modules/bar.css:1:opacity"
}

the_style_step_runs_without_a_deny_list() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	stage modules/bar.css 'a { transition: all 1s; }'
	gate --fast
	expect_status 1
	expect_out "modules/bar.css:1:motion"
	expect_said "SKIPPED"
}

the_index_copy_of_the_shared_mermaid_theme_is_used() {
	new_repo
	stage docs/mermaid-theme.json '{"theme": "base"}'
	stage docs/a.md '%%{init: {"theme": "base"}}%%'
	gate --fast
	expect_status 0
	stage docs/a.md '%%{init: {"theme": "dark"}}%%'
	gate --fast
	expect_status 1
	expect_out "docs/a.md:1:mermaid-init"
}

a_style_break_stops_the_gate_before_shellcheck() {
	new_repo
	stage modules/bar.css 'a { border-radius: 4px; }'
	write_script "$repo/tool.sh" 'echo $1'
	git -C "$repo" add tool.sh
	gate --fast
	expect_status 1
	expect_no_out "==> shellcheck"
}

# The shellcheck step.

a_staged_script_with_a_shellcheck_error_fails_the_gate() {
	new_repo
	write_script "$repo/scripts/tool.sh" 'echo $1'
	git -C "$repo" add scripts/tool.sh
	gate --fast
	expect_status 1
	expect_out "SC2086"
}

a_script_without_an_extension_is_found_by_its_shebang() {
	new_repo
	mkdir -p "$repo/.githooks"
	printf '#!/usr/bin/env bash\necho $1\n' >"$repo/.githooks/pre-commit"
	printf '#!/bin/sh\necho $1\n' >"$repo/bin-tool"
	git -C "$repo" add .githooks/pre-commit bin-tool
	gate --fast
	expect_status 1
	expect_out ".githooks/pre-commit"
	expect_out "bin-tool"
}

a_python_script_is_not_shellchecked() {
	new_repo
	printf '#!/usr/bin/env python3\nprint("$1")\n' >"$repo/tool"
	printf 'echo $1\n' >"$repo/notes.txt"
	git -C "$repo" add tool notes.txt
	gate --fast
	expect_status 0
}

the_staged_version_of_a_script_is_checked() {
	new_repo
	write_script "$repo/tool.sh" 'echo $1'
	git -C "$repo" add tool.sh
	write_script "$repo/tool.sh" 'echo "$1"'
	gate --fast
	expect_status 1
	expect_out "SC2086"
}

an_unstaged_script_error_is_checked_too() {
	new_repo
	write_script "$repo/tool.sh" 'echo "$1"'
	git -C "$repo" add tool.sh
	write_script "$repo/tool.sh" 'echo $1'
	gate --fast
	expect_status 1
	expect_out "SC2086"
}

a_sourced_library_is_followed() {
	new_repo
	mkdir -p "$repo/lib"
	printf '# shellcheck shell=bash\nexport greeting=hello\n' >"$repo/lib/vars.sh"
	write_script "$repo/tool.sh" '# shellcheck source=lib/vars.sh' \
		'. "$(dirname "$0")/lib/vars.sh"' 'echo "$greeting"'
	git -C "$repo" add lib/vars.sh tool.sh
	gate --fast
	expect_status 0
}

# The flake step.

a_failing_flake_check_fails_the_full_gate_with_its_status() {
	new_repo
	fake_nix 3
	gate
	expect_status 3
	expect_err "flake failed"
}

the_full_gate_without_nix_fails_before_any_step() {
	new_repo
	rm "$bin/nix"
	local path="" dir
	# PATH without any nix.
	IFS=: read -r -a dirs <<<"$PATH"
	for dir in "${dirs[@]}"; do
		[[ -x "$dir/nix" ]] || path="$path${path:+:}$dir"
	done
	capture in_repo env PATH="$path" scripts/check.sh
	expect_status 1
	expect_err "nix not found"
	expect_no_out "==> boundary"
}

a_missing_shellcheck_fails_before_any_step() {
	new_repo
	local tools="$scratch/tools" tool
	mkdir -p "$tools"
	for tool in bash cat dirname env find git mkdir mktemp readlink realpath rg rm sed sort tr wc; do
		ln -sf "$(command -v "$tool")" "$tools/$tool"
	done
	capture in_repo env PATH="$tools" scripts/check.sh --fast
	expect_status 1
	expect_err "shellcheck not found"
}

tests=(
	the_fast_gate_passes_on_a_clean_repository
	the_full_gate_adds_nix_flake_check
	an_unknown_argument_is_bad_usage
	the_gate_runs_from_any_directory_of_the_checkout
	outside_a_git_work_tree_the_gate_fails
	a_staged_leak_fails_the_gate
	a_staged_leak_under_a_clean_work_tree_fails_the_gate
	an_unstaged_leak_in_a_tracked_file_fails_the_gate
	an_untracked_file_is_not_checked
	a_leak_in_license_or_authors_passes
	a_staged_symlink_to_a_personal_path_fails_the_gate
	a_staged_file_name_holding_an_entry_fails_the_gate
	a_path_with_spaces_is_snapshotted
	a_staged_deletion_of_a_leak_passes
	without_a_deny_list_the_boundary_check_is_skipped_with_a_note
	a_deny_list_that_does_not_exist_fails_the_gate
	a_relative_deny_list_is_read_from_the_top_of_the_checkout
	the_first_failing_step_ends_the_gate_with_its_status
	the_snapshot_is_removed_after_the_run
	a_staged_hex_color_outside_the_theme_fails_the_gate
	a_hex_color_in_the_theme_module_passes_the_gate
	the_staged_version_of_a_styled_file_is_judged
	an_unstaged_style_break_in_a_tracked_file_fails_the_gate
	the_style_step_runs_without_a_deny_list
	the_index_copy_of_the_shared_mermaid_theme_is_used
	a_style_break_stops_the_gate_before_shellcheck
	a_staged_script_with_a_shellcheck_error_fails_the_gate
	a_script_without_an_extension_is_found_by_its_shebang
	a_python_script_is_not_shellchecked
	the_staged_version_of_a_script_is_checked
	an_unstaged_script_error_is_checked_too
	a_sourced_library_is_followed
	a_failing_flake_check_fails_the_full_gate_with_its_status
	the_full_gate_without_nix_fails_before_any_step
	a_missing_shellcheck_fails_before_any_step
)

run_tests "${tests[@]}"
