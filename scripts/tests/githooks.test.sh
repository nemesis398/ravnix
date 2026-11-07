#!/usr/bin/env bash
# Tests for the git hooks in .githooks/: pre-commit runs the fast gate,
# commit-msg checks the message against the deny list, and pre-push checks
# every commit the push sends, then runs the full gate. Each test builds a
# git repository in a temporary directory with copies of the hooks and the
# gate, core.hooksPath set to .githooks and a deny list of made-up values
# beside it. A fake nix stands in for the real one. Run it with:
#
#   bash scripts/tests/githooks.test.sh

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

zero=0000000000000000000000000000000000000000

# Set by new_repo for the test that is running.
repo=""
list=""
bin=""

new_repo() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	repo="$dir/repo"
	list="$dir/deny-list.txt"
	bin="$dir/bin"
	printf '%s\n' 'alice@example.org' '198.51.100.' >"$list"
	git init -q -b main "$repo"
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example.invalid
	mkdir -p "$repo/scripts/lib" "$repo/.githooks"
	cp -p "$src/scripts/check.sh" "$src/scripts/check-public.sh" "$src/scripts/check-style.sh" "$repo/scripts/"
	cp -p "$src/scripts/lib/git-snapshot.sh" "$repo/scripts/lib/"
	cp -p "$src/.githooks/pre-commit" "$src/.githooks/commit-msg" \
		"$src/.githooks/pre-push" "$repo/.githooks/"
	printf 'clean\n' >"$repo/a.md"
	git -C "$repo" add -A
	git -C "$repo" commit -qm init
	git -C "$repo" config core.hooksPath .githooks
	git -C "$repo" config ravnix.denyList "$list"
	# The full gate's claude-code step builds the verifier and the download,
	# reads the version and runs the verifier; this nix answers with ones
	# that pass, so a test here sees the hooks and nothing of that step.
	write_script "$bin/nix" "printf '%s\n' \"\$*\" >>'$bin/nix.log'" \
		'case "$*" in' \
		"*'build'*'.#claude-code-verify'*) echo '$bin/verify' ;;" \
		"*'build'*'.#claude-code.download'*) echo '$bin/download' ;;" \
		"*'eval'*'.#claude-code.version'*) printf '1.2.3' ;;" \
		'esac'
	write_script "$bin/verify/bin/claude-code-verify" \
		"printf '%s\n' \"\$*\" >'$bin/verify.log'" "exit 0"
	: >"$bin/download"
}

in_repo() {
	cd "$repo" && env PATH="$bin:$PATH" "$@"
}
commit() {
	capture in_repo git commit "$@"
}
head_sha() {
	git -C "$repo" rev-parse HEAD
}
expect_head() {
	[[ "$(head_sha)" == "$1" ]] || {
		echo "  expected HEAD to stay at $1, it is $(head_sha)"
		return 1
	}
}

# Commits what is staged with the hooks switched off, as a commit made
# elsewhere or by a rebase would arrive.
commit_without_hooks() {
	git -C "$repo" config --unset core.hooksPath
	git -C "$repo" commit -q "$@"
	git -C "$repo" config core.hooksPath .githooks
}

# Writes $2 into $repo/$1 and stages it.
stage() {
	mkdir -p "$(dirname "$repo/$1")"
	printf '%s\n' "$2" >"$repo/$1"
	git -C "$repo" add -- "$1"
}

# Runs pre-push as git would for pushing $1 (a local sha) to a remote ref
# whose old value is $2, to the remote named $3 (origin by default).
pre_push() {
	local remote="${3:-origin}"
	capture in_repo .githooks/pre-push "$remote" "https://example.invalid/repo.git" \
		< <(printf 'refs/heads/main %s refs/heads/main %s\n' "$1" "$2")
}

expect_full_gate() {
	[[ "$(cat "$bin/nix.log" 2>/dev/null)" == *"flake check"* ]] || {
		echo "  expected the full gate (nix flake check) to run"
		return 1
	}
	[[ -f "$bin/verify.log" ]] || {
		echo "  expected the full gate to verify the Claude Code download"
		return 1
	}
}
expect_no_gate() {
	[[ ! -s "$bin/nix.log" ]] || {
		echo "  expected the full gate not to run"
		return 1
	}
}

the_hooks_are_executable() {
	local hook
	for hook in pre-commit commit-msg pre-push; do
		[[ -x "$src/.githooks/$hook" ]] || {
			echo "  .githooks/$hook is not executable, so git would skip it"
			return 1
		}
	done
}

# pre-commit.

a_clean_commit_goes_through() {
	new_repo
	stage b.md 'clean too'
	commit -m 'add b'
	expect_status 0
	expect_said "all 3 steps passed"
	expect_no_gate
}

a_commit_with_a_staged_leak_is_refused() {
	new_repo
	local before
	before="$(head_sha)"
	stage hosts.nix 'address = "198.51.100.7";'
	commit -m 'add hosts'
	expect_status 1
	expect_said "hosts.nix:1:198.51.100."
	expect_head "$before"
}

a_staged_leak_under_a_clean_work_tree_is_refused() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	printf 'address = "192.0.2.1";\n' >"$repo/hosts.nix"
	commit -m 'add hosts'
	expect_status 1
	expect_said "hosts.nix:1:198.51.100."
}

commit_all_with_an_unstaged_leak_is_refused() {
	new_repo
	printf 'mail alice@example.org\n' >>"$repo/a.md"
	commit -a -m 'edit a'
	expect_status 1
	expect_said "a.md:2:alice@example.org"
}

a_commit_of_named_paths_is_checked() {
	new_repo
	printf 'mail alice@example.org\n' >>"$repo/a.md"
	commit -m 'edit a' -- a.md
	expect_status 1
	expect_said "a.md:2:alice@example.org"
}

without_a_deny_list_a_commit_goes_through_with_a_note() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	stage hosts.nix '198.51.100.7'
	commit -m 'add hosts'
	expect_status 0
	expect_said "SKIPPED"
}

# commit-msg.

a_message_holding_an_entry_is_refused() {
	new_repo
	local before
	before="$(head_sha)"
	stage b.md 'clean'
	commit -m 'docs: write to Alice@Example.org'
	expect_status 1
	expect_said "message:1:alice@example.org"
	expect_head "$before"
}

an_entry_in_the_message_body_is_refused() {
	new_repo
	stage b.md 'clean'
	commit -m 'docs: add b' -m 'Reachable at 198.51.100.7.'
	expect_status 1
	expect_said "message:3:198.51.100."
}

a_clean_message_goes_through() {
	new_repo
	stage b.md 'clean'
	commit -m 'docs: add b' -m 'Nothing personal.'
	expect_status 0
}

an_entry_below_the_scissors_line_is_ignored() {
	new_repo
	printf '%s\n' 'docs: remove the address' '' \
		'# ------------------------ >8 ------------------------' \
		'# Do not modify or remove the line above.' \
		'-address = "198.51.100.7";' >"$repo/msg"
	capture in_repo .githooks/commit-msg msg
	expect_status 0
}

an_entry_in_a_comment_above_the_scissors_line_is_refused() {
	new_repo
	printf '%s\n' 'docs: add b' '# alice@example.org' >"$repo/msg"
	capture in_repo .githooks/commit-msg msg
	expect_status 1
	expect_said "message:2:alice@example.org"
}

cut='# ------------------------ >8 ------------------------'

a_cut_line_with_another_comment_character_is_not_a_cut() {
	new_repo
	printf '%s\n' 'docs: add b' '; ------------------------ >8 ------------------------' \
		'alice@example.org' >"$repo/msg"
	capture in_repo .githooks/commit-msg msg
	expect_status 1
	expect_said "message:3:alice@example.org"
	# With ; as git's comment character, the same line is the cut line.
	git -C "$repo" config core.commentChar ';'
	capture in_repo .githooks/commit-msg msg
	expect_status 0
}

a_line_that_only_resembles_the_cut_line_is_not_a_cut() {
	new_repo
	local line
	for line in '# ----- >8 -----' "$cut trailing" " $cut" '## ------------------------ >8 ------------------------'; do
		printf '%s\n' 'docs: add b' "$line" 'alice@example.org' >"$repo/msg"
		capture in_repo .githooks/commit-msg msg
		[[ "$status" == 1 ]] || {
			echo "  cut at: $line"
			return 1
		}
	done
}

# Git keeps what follows a cut line in a message given with -F or -m, and
# commit-msg stops reading there; pre-push reads the whole message.
a_value_below_a_forged_cut_line_is_refused_at_the_push() {
	new_repo
	stage b.md 'clean'
	printf '%s\n' 'docs: add b' '' "$cut" 'mail alice@example.org' >"$repo/msg"
	commit -F msg
	expect_status 0
	local by_file
	by_file="$(head_sha)"
	[[ "$(git -C "$repo" log -1 --format=%B)" == *alice@example.org* ]] || {
		echo "  git did not keep the text below the cut line"
		return 1
	}
	stage c.md 'clean'
	commit -m 'docs: add c' -m "$cut" -m 'mail alice@example.org'
	expect_status 0
	local by_option
	by_option="$(head_sha)"
	pre_push "$by_option" "$zero"
	expect_status 1
	expect_said "messages/$by_file:4:alice@example.org"
	expect_said "messages/$by_option:5:alice@example.org"
	expect_no_gate
}

a_pushed_ref_name_holding_an_entry_is_refused() {
	new_repo
	capture in_repo .githooks/pre-push origin https://example.invalid/repo.git \
		< <(printf 'refs/heads/for-alice@example.org %s refs/heads/for-alice@example.org %s\n' \
			"$(head_sha)" "$zero")
	expect_status 1
	expect_said "alice@example.org"
	expect_no_gate
}

the_commit_msg_hook_without_a_deny_list_passes_with_a_note() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	printf 'mail alice@example.org\n' >"$repo/msg"
	capture in_repo .githooks/commit-msg msg
	expect_status 0
	expect_said "SKIPPED"
}

the_commit_msg_hook_without_a_message_file_fails() {
	new_repo
	capture in_repo .githooks/commit-msg no-such-file
	expect_status 2
	capture in_repo .githooks/commit-msg
	expect_status 2
}

# pre-push.

a_clean_push_runs_the_full_gate() {
	new_repo
	pre_push "$(head_sha)" "$zero"
	expect_status 0
	expect_full_gate
}

a_pushed_commit_with_a_leak_is_refused() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	commit_without_hooks -m 'add hosts'
	local leak
	leak="$(head_sha)"
	pre_push "$leak" "$zero"
	expect_status 1
	expect_said "commits/$leak/hosts.nix:1:198.51.100."
	expect_no_gate
}

a_leak_added_and_removed_within_the_push_is_refused() {
	new_repo
	stage hosts.nix 'address = "198.51.100.7";'
	commit_without_hooks -m 'add hosts'
	local leak
	leak="$(head_sha)"
	stage hosts.nix 'address = "192.0.2.1";'
	commit_without_hooks -m 'fix hosts'
	pre_push "$(head_sha)" "$zero"
	expect_status 1
	expect_said "commits/$leak/hosts.nix:1:198.51.100."
}

a_leak_in_a_pushed_message_is_refused() {
	new_repo
	stage b.md 'clean'
	commit_without_hooks -m 'docs: ask alice@example.org'
	local leak
	leak="$(head_sha)"
	pre_push "$leak" "$zero"
	expect_status 1
	expect_said "messages/$leak:1:alice@example.org"
}

commits_the_remote_has_are_not_checked_again() {
	new_repo
	stage hosts.nix '198.51.100.7'
	commit_without_hooks -m 'add hosts'
	local leak
	leak="$(head_sha)"
	git -C "$repo" rm -q hosts.nix
	commit_without_hooks -m 'remove hosts'
	pre_push "$(head_sha)" "$leak"
	expect_status 0
	# A new branch: what refs/remotes/origin/ holds is not checked again.
	git -C "$repo" update-ref refs/remotes/origin/main "$leak"
	pre_push "$(head_sha)" "$zero"
	expect_status 0
}

an_unknown_remote_sha_falls_back_to_the_remote_tracking_refs() {
	new_repo
	stage hosts.nix '198.51.100.7'
	commit_without_hooks -m 'add hosts'
	pre_push "$(head_sha)" 1111111111111111111111111111111111111111
	expect_status 1
	expect_said "hosts.nix:1:198.51.100."
}

a_push_to_a_url_checks_the_whole_history() {
	new_repo
	stage hosts.nix '198.51.100.7'
	commit_without_hooks -m 'add hosts'
	git -C "$repo" update-ref refs/remotes/origin/main "$(head_sha)"
	stage b.md 'clean'
	commit_without_hooks -m 'add b'
	pre_push "$(head_sha)" "$zero" "https://example.invalid/other.git"
	expect_status 1
	expect_said "hosts.nix:1:198.51.100."
}

a_deletion_sends_nothing_to_check() {
	new_repo
	pre_push "$zero" "$(head_sha)"
	expect_status 0
	expect_full_gate
}

a_merge_resolution_that_adds_a_leak_is_refused() {
	new_repo
	git -C "$repo" switch -q -c topic
	stage a.md 'topic'
	commit_without_hooks -m 'topic'
	git -C "$repo" switch -q main
	stage a.md 'main'
	commit_without_hooks -m 'main'
	git -C "$repo" merge -q topic >/dev/null 2>&1 || true
	stage a.md 'resolved, mail alice@example.org'
	commit_without_hooks -m 'merge topic'
	local merge
	merge="$(head_sha)"
	pre_push "$merge" "$zero"
	expect_status 1
	expect_said "commits/$merge/a.md:1:alice@example.org"
}

a_license_in_a_pushed_commit_passes() {
	new_repo
	stage LICENSE 'Copyright (C) 2026 Alice Example <alice@example.org>'
	commit_without_hooks -m 'add the license'
	pre_push "$(head_sha)" "$zero"
	expect_status 0
}

a_pushed_annotated_tag_with_a_leak_in_its_message_is_refused() {
	new_repo
	git -C "$repo" tag -a -m 'release for alice@example.org' v1
	local tag
	tag="$(git -C "$repo" rev-parse v1)"
	capture in_repo .githooks/pre-push origin https://example.invalid/repo.git \
		< <(printf 'refs/tags/v1 %s refs/tags/v1 %s\n' "$tag" "$zero")
	expect_status 1
	expect_said "alice@example.org"
}

without_a_deny_list_the_push_check_is_skipped_and_the_gate_runs() {
	new_repo
	git -C "$repo" config --unset ravnix.denyList
	stage hosts.nix '198.51.100.7'
	commit_without_hooks -m 'add hosts'
	pre_push "$(head_sha)" "$zero"
	expect_status 0
	expect_said "SKIPPED"
	expect_full_gate
}

pre_push_leaves_no_files_behind() {
	new_repo
	local tmp="$scratch/pre-push-tmp"
	mkdir -p "$tmp"
	capture in_repo env TMPDIR="$tmp" .githooks/pre-push origin https://example.invalid/repo.git \
		< <(printf 'refs/heads/main %s refs/heads/main %s\n' "$(head_sha)" "$zero")
	expect_status 0
	stage hosts.nix '198.51.100.7'
	commit_without_hooks -m 'add hosts'
	capture in_repo env TMPDIR="$tmp" .githooks/pre-push origin https://example.invalid/repo.git \
		< <(printf 'refs/heads/main %s refs/heads/main %s\n' "$(head_sha)" "$zero")
	expect_status 1
	[[ -z "$(find "$tmp" -mindepth 1 -print -quit)" ]] || {
		echo "  pre-push left files in its TMPDIR: $(ls -A "$tmp")"
		return 1
	}
}

a_failing_full_gate_fails_the_push() {
	new_repo
	write_script "$bin/nix" "exit 4"
	pre_push "$(head_sha)" "$zero"
	expect_status 4
}

tests=(
	the_hooks_are_executable
	a_clean_commit_goes_through
	a_commit_with_a_staged_leak_is_refused
	a_staged_leak_under_a_clean_work_tree_is_refused
	commit_all_with_an_unstaged_leak_is_refused
	a_commit_of_named_paths_is_checked
	without_a_deny_list_a_commit_goes_through_with_a_note
	a_message_holding_an_entry_is_refused
	an_entry_in_the_message_body_is_refused
	a_clean_message_goes_through
	an_entry_below_the_scissors_line_is_ignored
	an_entry_in_a_comment_above_the_scissors_line_is_refused
	a_cut_line_with_another_comment_character_is_not_a_cut
	a_line_that_only_resembles_the_cut_line_is_not_a_cut
	a_value_below_a_forged_cut_line_is_refused_at_the_push
	a_pushed_ref_name_holding_an_entry_is_refused
	the_commit_msg_hook_without_a_deny_list_passes_with_a_note
	the_commit_msg_hook_without_a_message_file_fails
	a_clean_push_runs_the_full_gate
	a_pushed_commit_with_a_leak_is_refused
	a_leak_added_and_removed_within_the_push_is_refused
	a_leak_in_a_pushed_message_is_refused
	commits_the_remote_has_are_not_checked_again
	an_unknown_remote_sha_falls_back_to_the_remote_tracking_refs
	a_push_to_a_url_checks_the_whole_history
	a_deletion_sends_nothing_to_check
	a_merge_resolution_that_adds_a_leak_is_refused
	a_license_in_a_pushed_commit_passes
	a_pushed_annotated_tag_with_a_leak_in_its_message_is_refused
	without_a_deny_list_the_push_check_is_skipped_and_the_gate_runs
	pre_push_leaves_no_files_behind
	a_failing_full_gate_fails_the_push
)

run_tests "${tests[@]}"
