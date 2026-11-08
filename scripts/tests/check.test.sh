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
state=""
record=""

# Creates a repository holding the gate's scripts and one clean file, all
# committed, with ravnix.denyList pointing at a deny list outside it. bin is
# a directory, first on PATH in gate, that holds a fake nix logging its
# arguments to $bin/nix.log; tmp is the gate's TMPDIR, state its
# XDG_STATE_HOME, and record the file there that remembers the verified
# downloads.
new_repo() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	repo="$dir/repo"
	list="$dir/deny-list.txt"
	bin="$dir/bin"
	tmp="$dir/tmp"
	state="$dir/state"
	record="$state/ravnix/claude-code-verified"
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

# Makes the fake nix's flake check exit with $1. For the claude-code step it
# builds a fake claude-code-verify, which logs its arguments to
# $bin/verify.log and exits with $2 (default 0), and a fake download, and it
# evaluates the version to 1.2.3. With $3 set to "no-download", the build of
# the download prints nothing.
fake_nix() {
	local download="echo '$bin/download'"
	[[ "${3:-}" != no-download ]] || download=":"
	write_script "$bin/nix" "printf '%s\n' \"\$*\" >>'$bin/nix.log'" \
		'case "$*" in' \
		"*'flake check'*) exit $1 ;;" \
		"*'build'*'.#claude-code-verify'*) echo '$bin/verify' ;;" \
		"*'build'*'.#claude-code.download'*) $download ;;" \
		"*'eval'*'.#claude-code.version'*) printf '1.2.3' ;;" \
		"*) echo \"fake nix: unexpected arguments: \$*\" >&2; exit 64 ;;" \
		'esac'
	write_script "$bin/verify/bin/claude-code-verify" \
		"printf '%s\n' \"\$*\" >'$bin/verify.log'" "exit ${2:-0}"
	: >"$bin/download"
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
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" scripts/check.sh "$@"
}
# Writes the record of verified downloads, one line per argument.
remember() {
	mkdir -p "${record%/*}"
	printf '%s\n' "$@" >"$record"
}
# expect_record <line>...: the record holds exactly these lines.
expect_record() {
	local want got
	want="$(printf '%s\n' "$@")"
	got="$(cat -- "$record" 2>/dev/null)" || got="(no record)"
	[[ "$got" == "$want" ]] || {
		printf '  expected the record to hold:\n%s\n  it holds:\n%s\n' "$want" "$got"
		return 1
	}
}
expect_no_record() {
	[[ ! -e "$record" ]] || {
		echo "  expected no record, there is: $(cat -- "$record" 2>&1)"
		return 1
	}
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

the_full_gate_adds_nix_flake_check_and_the_claude_code_check() {
	new_repo
	gate
	expect_status 0
	expect_out "all 5 steps passed"
	[[ "$(cat "$bin/nix.log")" == *"flake check"* ]] || {
		echo "  expected nix flake check, the fake nix got: $(cat "$bin/nix.log" 2>/dev/null)"
		return 1
	}
	[[ "$(cat "$bin/verify.log" 2>/dev/null)" == "$bin/download 1.2.3" ]] || {
		echo "  expected claude-code-verify on the download and its version, it got: $(cat "$bin/verify.log" 2>/dev/null)"
		return 1
	}
}

the_gate_never_lets_nix_write_the_lock_file() {
	new_repo
	gate
	expect_status 0
	local line
	while IFS= read -r line; do
		[[ "$line" == *--no-update-lock-file* ]] || {
			echo "  nix ran without --no-update-lock-file: $line"
			return 1
		}
	done <"$bin/nix.log"
}

the_fast_gate_does_not_verify_claude_code() {
	new_repo
	gate --fast
	expect_status 0
	[[ ! -e "$bin/verify.log" ]] || {
		echo "  the fast gate ran claude-code-verify"
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
	expect_out "hosts.nix:1:deny-list.txt:2"
}

a_staged_leak_under_a_clean_work_tree_fails_the_gate() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	printf 'address = "192.0.2.1";\n' >"$repo/hosts.nix"
	gate --fast
	expect_status 1
	expect_out "hosts.nix:1:deny-list.txt:2"
}

an_unstaged_leak_in_a_tracked_file_fails_the_gate() {
	new_repo
	printf 'mail alice@example.org\n' >>"$repo/a.md"
	gate --fast
	expect_status 1
	expect_out "a.md:2:deny-list.txt:1"
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
	expect_out "notes:link:deny-list.txt:1"
}

a_staged_file_name_holding_an_entry_fails_the_gate() {
	new_repo
	stage 'docs/alice@example.org.md' 'clean'
	gate --fast
	expect_status 1
	expect_out "docs/alice@example.org.md:name:deny-list.txt:1"
}

a_path_with_spaces_is_snapshotted() {
	new_repo
	stage 'docs/a b/c d.md' 'mail alice@example.org'
	gate --fast
	expect_status 1
	expect_out "docs/a b/c d.md:1:deny-list.txt:1"
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
	# The list is named as the gate was told, by its file name.
	expect_out "hosts.nix:1:.deny:2"
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

# The claude-code step.

a_claude_code_mismatch_fails_the_full_gate() {
	new_repo
	fake_nix 0 1
	gate
	expect_status 1
	expect_err "claude-code failed (exit 1)"
	expect_no_out "steps passed"
}

an_unreachable_manifest_fails_the_full_gate_and_says_so() {
	new_repo
	fake_nix 0 3
	gate
	expect_status 3
	expect_err "release manifest is unreachable"
	expect_err "Claude Code 1.2.3, downloaded as $bin/download, was never verified here"
	expect_err "claude-code failed (exit 3)"
	expect_no_record
}

a_verifier_that_cannot_run_fails_the_full_gate() {
	new_repo
	fake_nix 0 2
	gate
	expect_status 2
	expect_err "claude-code failed (exit 2)"
	expect_no_record
}

# The record of verified downloads.

a_verified_download_is_recorded() {
	new_repo
	fake_nix 0 0
	gate
	expect_status 0
	expect_record "1.2.3 $bin/download"
	gate
	expect_status 0
	expect_record "1.2.3 $bin/download"
}

a_new_download_joins_the_record() {
	new_repo
	remember "1.2.2 /nix/store/older-claude"
	fake_nix 0 0
	gate
	expect_status 0
	expect_record "1.2.2 /nix/store/older-claude" "1.2.3 $bin/download"
}

an_unreachable_manifest_passes_for_a_download_verified_before() {
	new_repo
	remember "1.2.3 $bin/download"
	fake_nix 0 3
	gate
	expect_status 0
	expect_err "release manifest is unreachable"
	expect_err "Claude Code 1.2.3, downloaded as $bin/download, was verified on an earlier run"
	expect_out "steps passed"
	expect_record "1.2.3 $bin/download"
}

an_unreachable_manifest_fails_for_a_download_never_verified() {
	new_repo
	# The same download as another version, and the version as another
	# download: neither is this pair.
	remember "1.2.2 $bin/download" "1.2.3 /nix/store/other-claude" "1.2.3 $bin/download-x"
	fake_nix 0 3
	gate
	expect_status 3
	expect_err "was never verified here"
	expect_err "claude-code failed (exit 3)"
	expect_no_out "steps passed"
}

a_mismatch_fails_and_records_nothing() {
	new_repo
	fake_nix 0 1
	gate
	expect_status 1
	expect_no_record
}

a_mismatch_forgets_the_download_it_had_verified_before() {
	new_repo
	remember "1.2.2 /nix/store/older-claude" "1.2.3 $bin/download"
	fake_nix 0 1
	gate
	expect_status 1
	expect_err "no longer recorded as verified"
	expect_record "1.2.2 /nix/store/older-claude"
}

a_mismatch_it_cannot_rewrite_the_record_for_deletes_the_record() {
	new_repo
	remember "1.2.2 /nix/store/older-claude" "1.2.3 $bin/download"
	# No file beside the record can be made, as on a full disk; the directory
	# stays writable, so the record itself can go.
	write_script "$bin/mktemp" \
		'case "$*" in *claude-code-verified*) exit 1 ;; esac' \
		"exec '$(command -v mktemp)' \"\$@\""
	fake_nix 0 1
	gate
	expect_status 1
	expect_err "no longer recorded as verified"
	expect_no_record
}

a_mismatch_it_cannot_forget_says_to_delete_the_record() {
	new_repo
	remember "1.2.3 $bin/download"
	chmod 555 "${record%/*}"
	fake_nix 0 1
	gate
	chmod 755 "${record%/*}"
	expect_status 1
	expect_err "could not be removed from $record; delete that file"
}

a_version_it_could_not_read_back_is_not_recorded() {
	new_repo
	write_script "$bin/nix" "printf '%s\n' \"\$*\" >>'$bin/nix.log'" \
		'case "$*" in' \
		"*'flake check'*) exit 0 ;;" \
		"*'build'*'.#claude-code-verify'*) echo '$bin/verify' ;;" \
		"*'build'*'.#claude-code.download'*) echo '$bin/download' ;;" \
		"*'eval'*'.#claude-code.version'*) printf '1.2.3 beta' ;;" \
		'esac'
	gate
	expect_status 0
	expect_err "could not record Claude Code 1.2.3 beta as verified"
	expect_no_record
}

a_corrupt_record_counts_as_empty() {
	new_repo
	mkdir -p "${record%/*}"
	local bad
	# The pair itself is in each one, so only the shape of the whole record
	# can tell: a NUL byte, a line of one word, an empty line, a CR line end.
	for bad in '1.2.4 /x\0y' '1.2.4' '' '1.2.4 /x\r'; do
		printf "1.2.3 %s\\n$bad\\n" "$bin/download" >"$record"
		fake_nix 0 3
		gate
		expect_status 3
		expect_err "was never verified here"
	done
	fake_nix 0 0
	gate
	expect_status 0
	expect_record "1.2.3 $bin/download"
}

a_record_without_a_final_newline_still_counts() {
	new_repo
	mkdir -p "${record%/*}"
	printf '1.2.3 %s' "$bin/download" >"$record"
	fake_nix 0 3
	gate
	expect_status 0
	expect_err "was verified on an earlier run"
}

a_record_that_cannot_be_written_does_not_fail_a_verified_download() {
	new_repo
	mkdir -p "$record"
	fake_nix 0 0
	gate
	expect_status 0
	expect_err "could not record Claude Code 1.2.3 as verified"
	[[ -d "$record" && -z "$(ls -A -- "$record")" ]] || {
		echo "  the record's path, a directory, was changed"
		return 1
	}
	fake_nix 0 3
	gate
	expect_status 3
	expect_err "was never verified here"
}

without_xdg_state_home_the_record_lives_under_home() {
	new_repo
	local home="${repo%/*}/home"
	mkdir -p "$home"
	fake_nix 0 0
	capture in_repo env -u XDG_STATE_HOME PATH="$bin:$PATH" TMPDIR="$tmp" HOME="$home" scripts/check.sh
	expect_status 0
	[[ "$(cat -- "$home/.local/state/ravnix/claude-code-verified" 2>&1)" == "1.2.3 $bin/download" ]] || {
		echo "  expected the record under \$HOME/.local/state"
		return 1
	}
	# A relative XDG_STATE_HOME is no base directory (XDG Base Directory).
	fake_nix 0 3
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" HOME="$home" XDG_STATE_HOME=state scripts/check.sh
	expect_status 0
	expect_err "was verified on an earlier run"
	[[ ! -e "$repo/state" ]] || {
		echo "  the gate wrote a record under a relative XDG_STATE_HOME"
		return 1
	}
}

a_download_nix_does_not_build_fails_the_full_gate() {
	new_repo
	fake_nix 0 0 no-download
	gate
	expect_status 1
	expect_err "no download"
	[[ ! -e "$bin/verify.log" ]] || {
		echo "  claude-code-verify ran without a download"
		return 1
	}
}

a_failing_flake_check_skips_the_claude_code_check() {
	new_repo
	fake_nix 3
	gate
	expect_status 3
	[[ ! -e "$bin/verify.log" ]] || {
		echo "  claude-code-verify ran after a failed flake check"
		return 1
	}
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
	the_full_gate_adds_nix_flake_check_and_the_claude_code_check
	the_gate_never_lets_nix_write_the_lock_file
	the_fast_gate_does_not_verify_claude_code
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
	a_claude_code_mismatch_fails_the_full_gate
	an_unreachable_manifest_fails_the_full_gate_and_says_so
	a_verifier_that_cannot_run_fails_the_full_gate
	a_verified_download_is_recorded
	a_new_download_joins_the_record
	an_unreachable_manifest_passes_for_a_download_verified_before
	an_unreachable_manifest_fails_for_a_download_never_verified
	a_mismatch_fails_and_records_nothing
	a_mismatch_forgets_the_download_it_had_verified_before
	a_mismatch_it_cannot_rewrite_the_record_for_deletes_the_record
	a_mismatch_it_cannot_forget_says_to_delete_the_record
	a_version_it_could_not_read_back_is_not_recorded
	a_corrupt_record_counts_as_empty
	a_record_without_a_final_newline_still_counts
	a_record_that_cannot_be_written_does_not_fail_a_verified_download
	without_xdg_state_home_the_record_lives_under_home
	a_download_nix_does_not_build_fails_the_full_gate
	a_failing_flake_check_skips_the_claude_code_check
	the_full_gate_without_nix_fails_before_any_step
	a_missing_shellcheck_fails_before_any_step
)

run_tests "${tests[@]}"
