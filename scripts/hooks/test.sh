#!/usr/bin/env bash
# Tests for the Claude Code hooks in scripts/hooks/: stop-gate.sh, the Stop
# hook that runs the fast gate before the agent may stop, and
# no-verify-guard.sh, the PreToolUse hook that refuses Bash commands which
# would skip or redirect the git hooks. Each Stop hook test builds its own git
# repository in a temporary directory, copies the hook into it and feeds it
# the JSON document Claude Code sends on stdin; a fake gate, named by
# RAVNIX_GATE_CMD, stands in for scripts/check.sh. Each guard test feeds the
# guard one command. Run it with:
#
#   bash scripts/hooks/test.sh
#
# Ported from phyllon's scripts/hooks/test.sh.

# The commands given to the guard are text for it to read, not for this
# shell to expand.
# shellcheck disable=SC2016

hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$hooks_dir/../.." && pwd)"
guard="$hooks_dir/no-verify-guard.sh"
# shellcheck source=scripts/tests/lib.sh
. "$src/scripts/tests/lib.sh"

# The hook runs whatever this names; each test points it at its own fake gate.
unset RAVNIX_GATE_CMD RAVNIX_GATE_TIMEOUT

command -v jq >/dev/null 2>&1 || {
	echo "test.sh: jq not found; install jq to run these tests" >&2
	exit 1
}

# Set by new_repo for the test that is running.
repo=""
gate=""
markers=""

# Creates a repository with one tracked file and the hook under test, and a
# fake gate outside it that passes. Changing the fake gate does not change the
# repository's fingerprint. markers is where the hook keeps its markers.
new_repo() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	repo="$dir/repo"
	gate="$dir/fake-gate"
	git init -q -b main "$repo"
	git -C "$repo" config user.name test
	git -C "$repo" config user.email test@example.invalid
	mkdir -p "$repo/modules" "$repo/scripts/hooks"
	printf '{ }\n' >"$repo/modules/a.nix"
	printf 'result\n.superpowers/\n' >"$repo/.gitignore"
	git -C "$repo" add modules/a.nix .gitignore
	cp -p "$hooks_dir/stop-gate.sh" "$repo/scripts/hooks/"
	markers="$repo/.git/ravnix-gate"
	gate_passes
}

gate_passes() {
	write_script "$gate" "echo 'fake gate ran' >>'$(dirname "$gate")/calls'" 'exit 0'
}

gate_fails() {
	write_script "$gate" "echo 'fake gate ran' >>'$(dirname "$gate")/calls'" 'echo boom' 'exit 1'
}

gate_calls() {
	if [[ -f "$(dirname "$gate")/calls" ]]; then
		wc -l <"$(dirname "$gate")/calls" | tr -d ' '
	else
		echo 0
	fi
}

# Runs the hook from / with $1 on stdin and PATH set to $2 if given.
run_input() {
	local input="$1" path="${2:-$PATH}"
	capture env -C / PATH="$path" RAVNIX_GATE_CMD="$gate" \
		"$repo/scripts/hooks/stop-gate.sh" <<<"$input"
}

# Runs the hook with a Stop event for $1 (the cwd field) and $2 (the
# stop_hook_active field), and PATH set to $3 if given.
run_hook() {
	run_input "$(jq -nc --arg cwd "$1" --argjson active "$2" \
		'{session_id: "test", hook_event_name: "Stop", cwd: $cwd, stop_hook_active: $active}')" \
		"${3:-}"
}

# Prints a directory with a fake $1 that exits with $2, to put first on PATH.
fake_tool() {
	local bin
	bin="$(mktemp -d -p "$scratch")"
	write_script "$bin/$1" "exit $2"
	echo "$bin"
}

# Prints a directory that holds only the named tools, for a PATH without the
# others.
tool_bin() {
	local bin tool
	bin="$(mktemp -d -p "$scratch")"
	for tool in "$@"; do
		ln -s "$(command -v "$tool")" "$bin/$tool"
	done
	echo "$bin"
}

expect_file() {
	[[ -f "$1" ]] || {
		echo "  expected $1 to exist"
		return 1
	}
}
expect_no_file() {
	[[ ! -e "$1" ]] || {
		echo "  expected $1 not to exist"
		return 1
	}
}
expect_calls() {
	[[ "$(gate_calls)" == "$1" ]] || {
		echo "  expected the gate to run $1 times, it ran $(gate_calls)"
		return 1
	}
}
expect_stdout_line() {
	[[ -n "$out" ]] || {
		echo "  expected a line on stdout"
		return 1
	}
}
# Claude Code shows a Stop hook's systemMessage to the user, and reads stdout
# as JSON only when it holds nothing but one object.
expect_message() {
	jq -se --arg m "$1" 'length == 1 and (.[0].systemMessage | contains($m))' \
		<<<"$out" >/dev/null 2>&1 || {
		echo "  expected stdout to be one JSON object whose systemMessage contains '$1', got: $out"
		return 1
	}
}

# The Stop hook.

gate_green_lets_the_agent_stop() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	expect_calls 1
	expect_file "$markers/green"
	expect_no_file "$markers/red"
}

gate_red_blocks_the_stop() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	expect_err boom
	expect_file "$markers/red"
	expect_no_file "$markers/green"
	# Claude Code lets a Stop hook's exit 2 through when stdout is empty and
	# stderr says a file is missing, which the gate's output can say.
	expect_stdout_line
}

unchanged_files_skip_the_gate() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	gate_fails
	run_hook "$repo" false
	expect_status 0
	expect_calls 1
}

a_repeated_red_stop_is_let_through() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	run_hook "$repo" true
	expect_status 0
	expect_calls 1
	expect_message "still red"
}

a_new_stop_after_a_red_one_runs_the_gate() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
}

a_repeated_red_stop_after_a_change_runs_the_gate() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	printf '{ a = 1; }\n' >"$repo/modules/a.nix"
	run_hook "$repo" true
	expect_status 2
	expect_calls 2
}

a_green_run_after_a_red_one_clears_the_red_marker() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	printf '{ fixed = true; }\n' >"$repo/modules/a.nix"
	gate_passes
	run_hook "$repo" false
	expect_status 0
	expect_file "$markers/green"
	expect_no_file "$markers/red"
}

the_gate_runs_without_colors() {
	new_repo
	write_script "$gate" "echo \"TERM=\$TERM NO_COLOR=\$NO_COLOR\"" 'exit 1'
	capture env -C / TERM=xterm-256color NO_COLOR= RAVNIX_GATE_CMD="$gate" \
		"$repo/scripts/hooks/stop-gate.sh" <<<'{"cwd": "'"$repo"'", "stop_hook_active": false}'
	expect_status 2
	expect_err "TERM=dumb NO_COLOR=1"
}

# The gate reads the index and the tracked files, so an untracked file does
# not count until it is staged.
a_new_untracked_file_skips_the_gate() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	printf 'notes\n' >"$repo/docs.md"
	gate_fails
	run_hook "$repo" false
	expect_status 0
	expect_calls 1
	git -C "$repo" add docs.md
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
	expect_no_file "$markers/green"
}

# A log the agent's tools keep writing must not send a red stop back forever.
a_changing_untracked_file_does_not_keep_a_red_stop_blocked() {
	new_repo
	gate_fails
	run_hook "$repo" false
	expect_status 2
	printf 'line 1\n' >"$repo/build.log"
	run_hook "$repo" true
	expect_status 0
	expect_message "still red"
	expect_calls 1
}

a_renamed_file_runs_the_gate_again() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	git -C "$repo" mv modules/a.nix modules/b.nix
	run_hook "$repo" false
	expect_status 0
	expect_calls 2
}

a_deleted_tracked_file_runs_the_gate_again() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	rm "$repo/modules/a.nix"
	gate_fails
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
	expect_err boom
}

a_staged_change_runs_the_gate_again() {
	new_repo
	printf 'draft\n' >"$repo/notes.md"
	run_hook "$repo" false
	expect_status 0
	# The work tree is the same; only the index changes.
	git -C "$repo" add notes.md
	gate_fails
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
}

an_ignored_file_skips_the_gate() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	mkdir -p "$repo/.superpowers"
	printf 'state\n' >"$repo/.superpowers/x"
	ln -s /nix/store/x "$repo/result"
	gate_fails
	run_hook "$repo" false
	expect_status 0
	expect_calls 1
}

every_kind_of_file_runs_the_gate() {
	local path missed=()
	local paths=(
		docs/index.md modules/x.nix flake.lock LICENSE scripts/check.sh
		scripts/hooks/stop-gate.sh .githooks/pre-commit .claude/settings.json
		tools/x/main.odin tests/area/name.nix
	)
	for path in "${paths[@]}"; do
		new_repo
		mkdir -p "$(dirname "$repo/$path")"
		printf 'tracked\n' >>"$repo/$path"
		git -C "$repo" add -- "$path"
		run_hook "$repo" false
		expect_status 0
		# Changed in the work tree only.
		printf '\n# changed\n' >>"$repo/$path"
		gate_fails
		run_hook "$repo" false
		[[ "$status" == 2 ]] || missed+=("$path")
	done
	((${#missed[@]} == 0)) || {
		echo "  a change to these did not run the gate: ${missed[*]}"
		return 1
	}
}

a_changed_deny_list_runs_the_gate_again() {
	new_repo
	local list="$scratch/deny-$RANDOM.txt"
	printf 'alice@example.org\n' >"$list"
	git -C "$repo" config ravnix.denyList "$list"
	run_hook "$repo" false
	expect_status 0
	printf '198.51.100.\n' >>"$list"
	gate_fails
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
}

setting_the_deny_list_runs_the_gate_again() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	local list="$scratch/deny-$RANDOM.txt"
	printf 'alice@example.org\n' >"$list"
	git -C "$repo" config ravnix.denyList "$list"
	gate_fails
	run_hook "$repo" false
	expect_status 2
	expect_calls 2
}

another_gate_command_runs_the_gate() {
	new_repo
	run_hook "$repo" false
	expect_status 0
	# A green run of another gate, such as a hand run with
	# RAVNIX_GATE_CMD=/bin/true, must not count for this one.
	gate="$(dirname "$gate")/other-gate"
	write_script "$gate" 'echo "other gate ran"' 'exit 1'
	run_hook "$repo" false
	expect_status 2
	expect_err "other gate ran"
}

without_a_gate_command_the_hook_runs_the_fast_gate() {
	new_repo
	write_script "$repo/scripts/check.sh" "printf '%s\n' \"\$*\" >'$repo/../args'"
	capture env -C / "$repo/scripts/hooks/stop-gate.sh" \
		<<<'{"cwd": "'"$repo"'", "stop_hook_active": false}'
	expect_status 0
	[[ "$(cat "$repo/../args")" == "--fast" ]] || {
		echo "  expected scripts/check.sh --fast, it got: $(cat "$repo/../args")"
		return 1
	}
}

a_linked_worktree_is_gated_in_its_own_tree() {
	new_repo
	git -C "$repo" commit -qm init
	local tree
	tree="$(mktemp -d -p "$scratch")/tree"
	git -C "$repo" worktree add -q -b other "$tree"
	gate_fails
	run_hook "$tree" false
	expect_status 2
	expect_file "$(git -C "$tree" rev-parse --absolute-git-dir)/ravnix-gate/red"
	expect_no_file "$markers/red"
}

a_cwd_outside_the_repository_gates_the_hook_own_checkout() {
	new_repo
	gate_fails
	run_hook "$scratch" false
	expect_status 2
	expect_file "$markers/red"
}

a_gate_past_its_deadline_blocks_the_stop() {
	new_repo
	write_script "$gate" 'sleep 10'
	local start=$SECONDS
	capture env -C / RAVNIX_GATE_TIMEOUT=1 RAVNIX_GATE_CMD="$gate" \
		"$repo/scripts/hooks/stop-gate.sh" <<<'{"cwd": "'"$repo"'", "stop_hook_active": false}'
	expect_status 2
	expect_err "timed out after 1 s"
	expect_file "$markers/red"
	((SECONDS - start < 8)) || {
		echo "  the hook waited $((SECONDS - start)) s for the gate"
		return 1
	}
}

a_bad_deadline_blocks_the_stop() {
	new_repo
	capture env -C / RAVNIX_GATE_TIMEOUT=soon RAVNIX_GATE_CMD="$gate" \
		"$repo/scripts/hooks/stop-gate.sh" <<<'{"stop_hook_active": false}'
	expect_status 2
	expect_err "RAVNIX_GATE_TIMEOUT"
	expect_calls 0
}

the_hook_timeout_exceeds_the_gate_deadline() {
	local settings="$src/.claude/settings.json"
	local hook_timeout deadline kill_after
	hook_timeout="$(jq -r '.hooks.Stop[0].hooks[0].timeout // 600' "$settings")"
	# shellcheck disable=SC2016 # the pattern matches a literal ${...}
	deadline="$(sed -n 's/^deadline="\${RAVNIX_GATE_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' \
		"$hooks_dir/stop-gate.sh")"
	kill_after="$(sed -n 's/^kill_after=\([0-9][0-9]*\)$/\1/p' "$hooks_dir/stop-gate.sh")"
	[[ -n "$deadline" && -n "$kill_after" ]] || {
		echo "  found no default deadline or kill_after in stop-gate.sh"
		return 1
	}
	((hook_timeout > deadline + kill_after)) || {
		echo "  the Stop hook timeout ($hook_timeout s) does not exceed the gate's" \
			"deadline plus kill_after ($deadline + $kill_after s)"
		return 1
	}
}

a_missing_timeout_blocks_the_stop() {
	new_repo
	run_input '{"stop_hook_active": false}' "$(tool_bin bash cat jq)"
	expect_status 2
	expect_err "timeout not found"
	expect_calls 0
}

a_missing_jq_blocks_the_stop() {
	new_repo
	run_input '{"stop_hook_active": false}' "$(tool_bin bash cat)"
	expect_status 2
	expect_err "jq not found"
	expect_calls 0
}

# A tool call resets Claude Code's cap on consecutive stop-hook continuations,
# so a hook that cannot work would otherwise block every stop for good.
a_missing_jq_on_a_repeated_stop_is_let_through() {
	new_repo
	run_input '{"hook_event_name": "Stop", "stop_hook_active": true}' "$(tool_bin bash cat)"
	expect_status 0
	expect_message "jq not found"
	expect_calls 0
}

invalid_json_blocks_the_first_stop() {
	new_repo
	run_input 'not json'
	expect_status 2
	expect_err "could not read"
	expect_calls 0
}

an_unexpected_failure_blocks_the_stop() {
	new_repo
	# A file where the marker directory goes makes mkdir fail after the gate
	# ran green.
	touch "$markers"
	run_hook "$repo" false
	expect_status 2
	expect_err "failed unexpectedly"
}

an_unexpected_failure_on_a_repeated_stop_is_let_through() {
	new_repo
	touch "$markers"
	run_hook "$repo" true
	expect_status 0
	expect_message "failed unexpectedly (exit 1) while writing the gate markers"
	expect_message "The stop goes through unchecked."
}

# A command that fails with exit 2 must not pass for a deliberate block.
a_failure_with_exit_2_blocks_the_first_stop() {
	new_repo
	run_hook "$repo" false "$(fake_tool sort 2):$PATH"
	expect_status 2
	expect_err "failed unexpectedly (exit 2) while computing the fingerprint"
	expect_calls 0
	expect_stdout_line
}

a_failure_with_exit_2_on_a_repeated_stop_is_let_through() {
	new_repo
	run_hook "$repo" true "$(fake_tool sort 2):$PATH"
	expect_status 0
	expect_message "failed unexpectedly (exit 2) while computing the fingerprint"
	expect_message "scripts/hooks/stop-gate.sh </dev/null"
	expect_calls 0
}

# The settings that wire both hooks.

the_settings_wire_both_hooks_and_the_plugin() {
	local settings="$src/.claude/settings.json"
	jq -e '
		(.enabledPlugins["superpowers@claude-plugins-official"] == true) and
		(.hooks.Stop[0].hooks[0].command | endswith("/scripts/hooks/stop-gate.sh")) and
		([.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command
			| endswith("/scripts/hooks/no-verify-guard.sh")] | any)
	' "$settings" >/dev/null || {
		echo "  .claude/settings.json does not enable superpowers and wire stop-gate.sh" \
			"and no-verify-guard.sh"
		return 1
	}
}

# The PreToolUse guard.

# Runs the guard on a Bash tool call of the command $1, with PATH set to $2
# if given.
guard_input() {
	printf '%s' "$1" | jq -Rsc \
		'{session_id: "test", hook_event_name: "PreToolUse", tool_name: "Bash",
		  tool_input: {command: ., description: "test"}}'
}
run_guard() {
	capture env PATH="${2:-$PATH}" "$guard" <<<"$(guard_input "$1")"
}

# Commands the guard must refuse, one per line of the array.
refused=(
	'git commit --no-verify -m x'
	'git commit -n -m x'
	'git commit -nm x'
	'git commit -anm x'
	'git commit -am x -n'
	'git commit -m x -n'
	'git commit --no-veri -m x'
	'git commit --no-verify'
	'git commit -n'
	'git push --no-verify'
	'git push --no-verify origin main'
	'git push origin main --no-verify'
	'git merge --no-verify topic'
	'git pull --no-verify'
	'git am --no-verify patch.mbox'
	'git rebase --no-verify main'
	'git -c core.hooksPath=/dev/null commit -m x'
	'git -c core.hookspath=/dev/null commit'
	'git -c CORE.HOOKSPATH=/dev/null commit'
	'git -c core.hooksPath=.githooks status'
	'git -c core.hooksPath commit'
	'git -ccore.hooksPath=/dev/null commit'
	'git --config-env=core.hooksPath=HOOKS commit'
	'git --config-env core.hooksPath=HOOKS commit'
	'git -c include.path=/tmp/x commit'
	'git -c includeIf.onbranch:main.path=/tmp/x commit'
	"git -c alias.ci='commit --no-verify' ci -m x"
	"git -c alias.ci='!git commit -n -m x' ci"
	'git config core.hooksPath /dev/null'
	"git config core.hooksPath ''"
	'git config --local core.hooksPath hooks'
	'git config --global core.hooksPath /tmp'
	'git config --file .git/config core.hooksPath /dev/null'
	'git config --add core.hooksPath /dev/null'
	'git config --replace-all core.hooksPath /dev/null'
	'git config set core.hooksPath /dev/null'
	'git config set --all core.hooksPath x'
	'git config --unset core.hooksPath'
	'git config --unset-all core.hooksPath'
	'git config unset core.hooksPath'
	'git config --remove-section core'
	'git config remove-section core'
	'git config --rename-section core old'
	'git config --edit'
	'git config -e'
	'cd /tmp/repo && git commit -n -m y'
	'true; git commit --no-verify'
	'false || git commit -n'
	'echo msg | git commit -n -F -'
	'git status & git commit -n'
	'FOO=1 git commit -n'
	'env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x'
	'export GIT_CONFIG_KEY_0=core.hooksPath'
	"GIT_CONFIG_PARAMETERS=\"'core.hooksPath=/dev/null'\" git commit -m x"
	'/usr/bin/git commit -n'
	'git -C /tmp/repo commit -n'
	'git --git-dir=.git --work-tree=. commit -n'
	'git --no-pager -C x commit --no-verify'
	'timeout 60 git commit -n -m x'
	'sudo git commit -n'
	'command git commit -n'
	'xargs git commit -n'
	"bash -c 'git commit --no-verify -m x'"
	'sh -c "git commit -n"'
	"bash -lc 'git push --no-verify'"
	"bash -o pipefail -c 'git commit -n'"
	'eval git commit -n'
	"eval 'git commit -n'"
	'echo "$(git commit -n -m x)"'
	'x=$(git commit --no-verify)'
	'x=`git commit --no-verify`'
	'(cd repo && git commit -n)'
	'{ git commit -n; }'
	'if true; then git commit -n; fi'
	'git commit -m x &>/dev/null -n'
	'git commit -m x 2>&1 --no-verify'
	"git rebase -x 'git commit --amend --no-verify' main"
	"git rebase --exec 'git commit --amend -n' main"
	"cat <(git commit -n)"
	$'git add a\ngit commit -n -m x'
	$'git commit \\\n  --no-verify -m x'
	"git commit -m \"\$(cat <<'EOF'
subject
EOF
)\" --no-verify"
	'git "commit" "-n"'
	"git 'commit' '--no-verify'"
	'git c""ommit -n'
	'g""it commit -n'
	'git config include.path /tmp/evil.cfg'
	'git config include.path x'
	'git config --local include.path ../evil.cfg'
	'git config --global include.path x'
	'git config --file .git/config include.path x'
	'git config --add include.path x'
	'git config --replace-all include.path x'
	'git config set include.path x'
	'git config set --all include.path x'
	'git config Include.Path x'
	'git config includeIf.gitdir:~/.path /tmp/evil.cfg'
	'git config includeIf.gitdir:x.path y'
	'git config --unset include.path'
	'git config --rename-section old include'
	'git config --rename-section old core'
	'git config --rename-section old includeIf.gitdir:x'
	"git config alias.ci 'commit --no-verify' && git ci -m x"
	"git config alias.ci 'commit --no-verify'"
	"git config --global alias.ci '!git commit -n -m x'"
	"git config set alias.ci 'push --no-verify'"
	'git config alias.ci commit && git ci -n -m x'
	'git config alias.CI commit && git ci -n -m x'
	'/usr/libexec/git-core/git-commit -n -m x'
	'git-commit --no-verify -m x'
	'git-push --no-verify'
	'git-config core.hooksPath /dev/null'
	"bash <<'EOF'
git commit --no-verify -m x
EOF"
	"sh <<-EOF
	git commit -n -m x
	EOF"
	'bash -s <<<"git commit -n -m x"'
	'nix-shell --run "git commit -n -m x"'
	"nix-shell -p hello --command 'git push --no-verify'"
	"script -q -c 'git commit -n -m x' /dev/null"
	"su -c 'git commit --no-verify -m x' user"
	"flock /tmp/lock -c 'git commit -n -m x'"
)

# Commands the guard must let through.
allowed=(
	'git commit -m x'
	'git commit -m "mention --no-verify and -n in the message"'
	"git commit -m '-n'"
	'git commit -m --no-verify'
	'git commit -mn'
	'git commit -F msg.txt'
	'git commit -F -n'
	'git commit -C HEAD'
	'git commit --amend --no-edit'
	'git commit --verbose -m x'
	'git commit -v -m x'
	'git commit -- -n'
	'git commit --message=--no-verify'
	'git commit --message --no-verify'
	"git commit -m \"\$(cat <<'EOF'
feat: add the guard

It refuses git commit --no-verify and git commit -n, and
git -c core.hooksPath=/dev/null commit (see AGENTS.md).
EOF
)\""
	"git commit -F - <<'EOF'
docs: say why

git push --no-verify skips the gate.
EOF"
	'git log -n 3'
	'git log --oneline -n 3'
	'git log -n3 --format=%H'
	'git push -n'
	'git push -n origin main'
	'git push --dry-run origin main'
	'git push origin main'
	'git push --verbose'
	'git config --get core.hooksPath'
	'git config core.hooksPath'
	'git config core.hooksPath .githooks'
	'git config --local core.hooksPath .githooks'
	'git config get core.hooksPath'
	'git config --list'
	'git config --show-origin --get-all core.hooksPath'
	'git config ravnix.denyList /x/deny-list.txt'
	'git config --unset ravnix.denyList'
	'git config --remove-section ravnix'
	'git -c user.name=x commit -m y'
	'git -c color.ui=never log -n 1'
	'git -C /tmp/x status'
	'git status'
	'git diff --no-ext-diff'
	'git merge topic'
	'git rebase -x "make test" main'
	'git rebase --exec "git log -n 1" main'
	'git notes add -m x'
	'git stash push -m x'
	'echo "git commit --no-verify"'
	"echo 'git commit -n'"
	"rg -n 'no-verify' scripts/"
	'rg -n -e --no-verify scripts/'
	"cat <<'EOF' >notes.md
git commit --no-verify
git -c core.hooksPath=/dev/null commit
EOF"
	"cat <<-EOF >notes.md
	git commit -n
	EOF"
	'git commit -m x # --no-verify'
	'ls -la'
	''
	'cd ~/Git/ravnix && scripts/check.sh --fast'
	'git worktree add -b task/x .worktrees/x'
	'git grep -n hooksPath'
	'git commit -m "$(printf %s -n)"'
	'git show HEAD -n 1'
	'git config user.email x@example.org'
	'git config --get include.path'
	'git config --get-all include.path'
	'git config get include.path'
	'git config include.path'
	'git config --list --show-origin'
	'git config core.hooksPath .githooks/'
	'git config core.hooksPath ./.githooks'
	'git config alias.st status'
	"git config alias.ci 'commit -v'"
	'git config alias.st status && git st -s'
	'git config --rename-section old new'
	'git-lfs install'
	'git-commit -m x'
	"bash <<'EOF'
git status
EOF"
	"cat <<'EOF' | sh
echo hi
EOF"
	'nix-shell --run "git log -n 3"'
	'nix develop -c git status'
)

expect_refused() {
	local command missed=()
	for command in "$@"; do
		run_guard "$command"
		[[ "$status" == 2 && "$err" == *"refused"* ]] || missed+=("$command (exit $status)")
	done
	((${#missed[@]} == 0)) || {
		printf '  the guard let through: %s\n' "${missed[@]}"
		return 1
	}
}

the_guard_refuses_commands_that_skip_the_hooks() {
	expect_refused "${refused[@]}"
}

the_guard_lets_ordinary_commands_through() {
	local command wrong=()
	for command in "${allowed[@]}"; do
		run_guard "$command"
		[[ "$status" == 0 ]] || wrong+=("$command (exit $status: $err)")
	done
	((${#wrong[@]} == 0)) || {
		printf '  the guard refused: %s\n' "${wrong[@]}"
		return 1
	}
}

a_refusal_says_why_and_what_to_do() {
	run_guard 'git commit --no-verify -m x'
	expect_status 2
	expect_err "--no-verify"
	expect_err "AGENTS.md"
	run_guard 'git config core.hooksPath /dev/null'
	expect_status 2
	expect_err "core.hooksPath"
}

other_tools_are_let_through() {
	capture "$guard" <<<'{"tool_name": "Write", "tool_input": {"file_path": "x", "content": "git commit -n"}}'
	expect_status 0
}

without_jq_git_commands_are_refused_and_others_let_through() {
	local path
	path="$(tool_bin bash cat)"
	run_guard 'git commit -n' "$path"
	expect_status 2
	expect_err "jq not found"
	run_guard 'git status' "$path"
	expect_status 2
	run_guard 'ls -la ~/Git/project' "$path"
	expect_status 0
	run_guard 'command -v jq' "$path"
	expect_status 0
}

invalid_input_refuses_git_and_lets_the_rest_through() {
	capture "$guard" <<<'not json, git commit -n'
	expect_status 2
	capture "$guard" <<<'not json at all'
	expect_status 0
	capture "$guard" <<<''
	expect_status 0
}

a_huge_command_is_judged_quickly() {
	local body start
	body="$(head -c 300000 /dev/zero | tr '\0' 'a' | fold -w 100)"
	start=$SECONDS
	run_guard "cat <<'EOF' >big.txt
$body
git commit -n
EOF
git status"
	expect_status 0
	run_guard "git commit -m '$body' -n"
	expect_status 2
	((SECONDS - start < 20)) || {
		echo "  the guard took $((SECONDS - start)) s for two 300 kB commands"
		return 1
	}
}

a_deeply_nested_command_is_still_judged() {
	run_guard "bash -c \"bash -c 'bash -c \\\"git commit -n\\\"'\""
	expect_status 2
}

unbalanced_quotes_do_not_hide_a_bypass() {
	run_guard "git commit -n -m 'unterminated"
	expect_status 2
	run_guard 'git commit --no-verify -m "unterminated'
	expect_status 2
}

tests=(
	gate_green_lets_the_agent_stop
	gate_red_blocks_the_stop
	unchanged_files_skip_the_gate
	a_repeated_red_stop_is_let_through
	a_new_stop_after_a_red_one_runs_the_gate
	a_repeated_red_stop_after_a_change_runs_the_gate
	a_green_run_after_a_red_one_clears_the_red_marker
	the_gate_runs_without_colors
	a_new_untracked_file_skips_the_gate
	a_changing_untracked_file_does_not_keep_a_red_stop_blocked
	a_renamed_file_runs_the_gate_again
	a_deleted_tracked_file_runs_the_gate_again
	a_staged_change_runs_the_gate_again
	an_ignored_file_skips_the_gate
	every_kind_of_file_runs_the_gate
	a_changed_deny_list_runs_the_gate_again
	setting_the_deny_list_runs_the_gate_again
	another_gate_command_runs_the_gate
	without_a_gate_command_the_hook_runs_the_fast_gate
	a_linked_worktree_is_gated_in_its_own_tree
	a_cwd_outside_the_repository_gates_the_hook_own_checkout
	a_gate_past_its_deadline_blocks_the_stop
	a_bad_deadline_blocks_the_stop
	the_hook_timeout_exceeds_the_gate_deadline
	a_missing_timeout_blocks_the_stop
	a_missing_jq_blocks_the_stop
	a_missing_jq_on_a_repeated_stop_is_let_through
	invalid_json_blocks_the_first_stop
	an_unexpected_failure_blocks_the_stop
	an_unexpected_failure_on_a_repeated_stop_is_let_through
	a_failure_with_exit_2_blocks_the_first_stop
	a_failure_with_exit_2_on_a_repeated_stop_is_let_through
	the_settings_wire_both_hooks_and_the_plugin
	the_guard_refuses_commands_that_skip_the_hooks
	the_guard_lets_ordinary_commands_through
	a_refusal_says_why_and_what_to_do
	other_tools_are_let_through
	without_jq_git_commands_are_refused_and_others_let_through
	invalid_input_refuses_git_and_lets_the_rest_through
	a_huge_command_is_judged_quickly
	a_deeply_nested_command_is_still_judged
	unbalanced_quotes_do_not_hide_a_bypass
)

run_tests "${tests[@]}"
