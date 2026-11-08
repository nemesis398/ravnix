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
# a directory, first on PATH in gate, that holds a fake nix (fake_nix); tmp
# is the gate's TMPDIR, state its XDG_STATE_HOME, and record the file there
# that remembers the verified downloads. The flake has the checks alpha,
# beta and gamma, and they all pass.
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
	cp -p "$src/scripts/lib/git-snapshot.sh" "$src/scripts/lib/flake-outputs.nix" \
		"$src/scripts/lib/check-drv.nix" "$repo/scripts/lib/"
	printf 'clean\n' >"$repo/a.md"
	git -C "$repo" add -A
	git -C "$repo" commit -qm init
	fake_nix 0
	checks_named alpha beta gamma
}

# Writes the fake nix. It logs each call to $bin/nix.log, one line per call
# with its newlines made spaces. What it answers about the flake comes from
# the files of a tree: $bin itself, the work tree as it is now, or the
# snapshot $bin/snap.N that its Nth `flake prefetch` call copied, when the
# call names that snapshot's source, path:/nix/store/fakeN-source:
#
#   names, names.status      what the listing of the checks prints and its
#                            exit status (0); checks_named writes it
#   outputs.status           the exit status of the outputs validation (0),
#                            whose --apply expression it saves in
#                            outputs.apply; outputs.err is its stderr
#   eval.fail                lines "STATUS INSTALLABLE": the evaluation of
#                            that check's derivation fails with STATUS
#   eval.weird               lines "INSTALLABLE TEXT": that evaluation
#                            prints TEXT instead of a derivation
#   build.fail               lines "STATUS INSTALLABLE": that check's status
#
# The other files in $bin, read as they are:
#
#   system, system.status    what `nix config show system` prints
#                            (x86_64-linux) and its exit status (0)
#   prefetch.status          the exit status of `flake prefetch` (0)
#   build.status             the exit status of every check's build ($1)
#   build.barrier            when present, each build waits (10 s at most)
#                            until as many builds run at once as it says (2)
#   build.hang               when present, each build runs for 30 s
#   build.mutate/            a tree's files, which the first build to start
#                            copies over those in $bin: an edit of the work
#                            tree while the gate runs
#   names.hang, outputs.hang when present, the listing or the outputs
#                            validation runs for 30 s, its pid in
#                            names.pid or outputs.pid
#   stubborn                 when present, a call that runs for 30 s
#                            ignores SIGTERM
#   version, no-download     the Claude Code version (1.2.3), and the build
#                            of the download printing nothing
#
# An installable is logged and looked up in the files above with its source
# written as ".", so .#.checks.x86_64-linux."alpha" stands for alpha of any
# tree. A check's evaluation prints /nix/store/fakePID-check.drv and records
# it with the check and its tree in drvs; its build of DRV^* finds them
# there, and logs "start N INSTALLABLE", with N the builds running then,
# and "end INSTALLABLE" to builds.log. Like real nix, it catches SIGINT and
# SIGTERM, says it was interrupted and exits 1. For the claude-code step it
# builds a fake claude-code-verify, which logs its arguments to
# $bin/verify.log and exits with $2 (default 0), and a fake download. With
# $3 set to "no-download", the build of the download prints nothing.
fake_nix() {
	mkdir -p "$bin"
	{
		printf '#!%s\n' "$BASH"
		cat <<'EOF'
d="${0%/*}"
printf '%s' "$*" | tr '\n' ' ' >>"$d/nix.log"
echo >>"$d/nix.log"
interrupted() {
	echo "error: interrupted by the user" >&2
	exit 1
}
trap interrupted INT TERM
code() { cat -- "$d/$1" 2>/dev/null || echo 0; }
# Runs for 30 s, with its pid in $d/$1.pid, ignoring SIGTERM when
# $d/stubborn says so.
hang() {
	[[ ! -e "$d/stubborn" ]] || trap '' TERM
	echo "$$" >"$d/$1.pid"
	for _ in $(seq 300); do sleep 0.1; done
}
tree="$d"
inst=""
for a; do
	case "$a" in
	path:*'#'*)
		src="${a%%#*}"
		inst=".#${a#*#}"
		if [[ "$src" =~ ^path:/nix/store/fake([0-9]+)-source$ ]]; then
			tree="$d/snap.${BASH_REMATCH[1]}"
		else
			tree="$d/no-such-source"
		fi
		;;
	.#*) inst="$a" ;;
	esac
done
# Fails with the status that a line "STATUS INSTALLABLE" of file $1 of the
# tree gives $inst, when it has one.
fail_from() {
	local st i
	while read -r st i; do
		if [[ "$i" == "$inst" ]]; then
			echo "error: $inst failed" >&2
			exit "$st"
		fi
	done < <(cat -- "$tree/$1" 2>/dev/null)
}
case "$*" in
*'config show system'*)
	cat -- "$d/system" 2>/dev/null || echo x86_64-linux
	exit "$(code system.status)"
	;;
*' flake prefetch --json --no-pretty --out-link '*' . '*)
	n=$(($(cat -- "$d/snap.count" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$d/snap.count"
	mkdir -p "$d/snap.$n"
	for f in names names.status outputs.status outputs.err eval.fail eval.weird build.fail; do
		[[ ! -e "$d/$f" ]] || cp -- "$d/$f" "$d/snap.$n/"
	done
	printf '{"hash":"sha256-x","locked":{"path":"/nix/store/decoy"},"storePath":"/nix/store/fake%s-source"}\n' "$n"
	exit "$(code prefetch.status)"
	;;
*' eval --raw --expr '*)
	# The source's store path, read from the JSON in the expression.
	if [[ "$*" =~ \"storePath\":\"([^\"]*)\" ]]; then
		printf '%s' "${BASH_REMATCH[1]}"
		exit 0
	fi
	echo "fake nix: no prefetch JSON given" >&2
	exit 1
	;;
*' eval '*'#.checks.'*)
	if [[ "$inst" != *'"'* ]]; then
		# The listing.
		[[ ! -e "$d/names.hang" ]] || hang names
		cat -- "$tree/names" 2>/dev/null
		st="$(cat -- "$tree/names.status" 2>/dev/null || echo 0)"
		exit "$st"
	fi
	fail_from eval.fail
	while read -r i text; do
		[[ "$i" != "$inst" ]] || { echo "$text"; exit 0; }
	done < <(cat -- "$tree/eval.weird" 2>/dev/null)
	prev=""
	for a; do
		[[ "$prev" != --apply ]] || printf '%s' "$a" >"$d/check.apply"
		prev="$a"
	done
	drv="/nix/store/fake$$-check.drv"
	printf '%s %s %s\n' "$drv" "$tree" "$inst" >>"$d/drvs"
	echo "$drv"
	;;
*' eval '*'#. '*)
	prev=""
	for a; do
		[[ "$prev" != --apply ]] || printf '%s' "$a" >"$d/outputs.apply"
		prev="$a"
	done
	[[ ! -e "$d/outputs.hang" ]] || hang outputs
	[[ ! -e "$tree/outputs.err" ]] || cat -- "$tree/outputs.err" >&2
	echo "packages.x86_64-linux: 2 derivations"
	st="$(cat -- "$tree/outputs.status" 2>/dev/null || echo 0)"
	exit "$st"
	;;
*' build '*'.drv^*'*)
	[[ ! -e "$d/stubborn" ]] || trap '' TERM
	drv=""
	for a; do [[ "$a" != *'.drv^*' ]] || drv="${a%'^*'}"; done
	while read -r path t i; do
		[[ "$path" != "$drv" ]] || { tree="$t"; inst="$i"; }
	done <"$d/drvs"
	if mv -- "$d/build.mutate" "$d/mutating" 2>/dev/null; then
		cp -- "$d/mutating"/* "$d/"
	fi
	mkdir -p "$d/running"
	: >"$d/running/$$"
	running=("$d"/running/*)
	want="$(cat -- "$d/build.barrier" 2>/dev/null)"
	((${#running[@]} < ${want:-2})) || : >"$d/overlapped"
	printf 'start %s %s\n' "${#running[@]}" "$inst" >>"$d/builds.log"
	if [[ -e "$d/build.barrier" ]]; then
		for _ in $(seq 100); do
			[[ ! -e "$d/overlapped" ]] || break
			sleep 0.1
		done
	fi
	if [[ -e "$d/build.hang" ]]; then
		for _ in $(seq 300); do sleep 0.1; done
	fi
	rm -f -- "$d/running/$$"
	printf 'end %s\n' "$inst" >>"$d/builds.log"
	echo "building $inst"
	fail_from build.fail
	exit "$(code build.status)"
	;;
*' build '*'.#claude-code-verify'*) echo "$d/verify" ;;
*' build '*'.#claude-code.download'*) [[ -e "$d/no-download" ]] || echo "$d/download" ;;
*' eval '*'.#claude-code.version'*) cat -- "$d/version" 2>/dev/null || printf '1.2.3' ;;
*) echo "fake nix: unexpected arguments: $*" >&2; exit 64 ;;
esac
EOF
	} >"$bin/nix"
	chmod +x "$bin/nix"
	printf '%s\n' "$1" >"$bin/build.status"
	rm -f -- "$bin/no-download"
	[[ "${3:-}" != no-download ]] || : >"$bin/no-download"
	write_script "$bin/verify/bin/claude-code-verify" \
		"printf '%s\n' \"\$*\" >'$bin/verify.log'" "exit ${2:-0}"
	: >"$bin/download"
}

# The flake's checks are the arguments, as the listing prints them.
checks_named() {
	if (($# == 0)); then
		: >"$bin/names"
	else
		printf 'ok %s\n' "$@" >"$bin/names"
	fi
}
# fail_check STATUS INSTALLABLE: the build of that check exits with STATUS.
fail_check() {
	printf '%s %s\n' "$1" "$2" >>"$bin/build.fail"
}
# fail_eval STATUS INSTALLABLE: the evaluation of that check's derivation
# exits with STATUS.
fail_eval() {
	printf '%s %s\n' "$1" "$2" >>"$bin/eval.fail"
}
# The installables of the checks' builds, in the order they started.
builds() {
	[[ ! -e "$bin/builds.log" ]] || sed -n 's/^start [0-9]* //p' "$bin/builds.log"
}
# expect_builds INSTALLABLE...: exactly these builds ran, in this order.
expect_builds() {
	local want got
	want="$(printf '%s\n' "$@")"
	got="$(builds)"
	[[ "$got" == "${want%$'\n'}" ]] || {
		printf '  expected the builds:\n%s\n  got:\n%s\n' "$want" "$got"
		return 1
	}
}
# The installable of the check named $1, a name that needs no encoding.
check_of() {
	printf '.#.checks.x86_64-linux."%s"' "$1"
}
# Whether process $1 runs: it exists and is no zombie.
alive() {
	local stat
	stat="$(cat -- "/proc/$1/stat" 2>/dev/null)" || return 1
	stat="${stat##*) }"
	[[ "${stat%% *}" != Z ]]
}
# Starts the full gate in the background, in a process group of its own as
# a terminal runs it, so a Ctrl-C (SIGINT to the group) reaches all of it;
# gate_pid is its pid and group. The arguments are more environment.
start_gate() {
	set -m
	(cd "$repo" && exec env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" "$@" scripts/check.sh) \
		>"$scratch/.out" 2>"$scratch/.err" &
	gate_pid=$!
	set +m
}
# Waits (10 s at most) until $1 builds run, and sets running to their pids.
await_builds() {
	local _
	running=()
	for _ in $(seq 100); do
		running=("$bin"/running/*)
		[[ ! -e "${running[0]}" ]] || ((${#running[@]} < $1)) || break
		running=()
		sleep 0.1
	done
	running=("${running[@]##*/}")
	((${#running[@]} == $1)) || {
		echo "  expected $1 builds running, there are ${#running[@]}"
		kill -KILL -- "-$gate_pid" 2>/dev/null || true
		return 1
	}
}
# Waits (10 s at most) until file $1 exists.
await_file() {
	local _
	for _ in $(seq 100); do
		[[ ! -s "$1" ]] || return 0
		sleep 0.1
	done
	echo "  $1 never appeared"
	kill -KILL -- "-$gate_pid" 2>/dev/null || true
	return 1
}
# Waits ($1 tenths of a second at most) for the gate to end, and sets
# status to its exit status.
await_gate() {
	local _
	for _ in $(seq "$1"); do
		alive "$gate_pid" || break
		sleep 0.1
	done
	if alive "$gate_pid"; then
		kill -KILL -- "-$gate_pid" 2>/dev/null || true
		wait "$gate_pid" 2>/dev/null || true
		echo "  the gate was still running; builds: $(builds | tr '\n' ' ')"
		return 1
	fi
	status=0
	wait "$gate_pid" || status=$?
	out="$(cat "$scratch/.out")"
	err="$(cat "$scratch/.err")"
}
# expect_dead PID...: none of these processes runs.
expect_dead() {
	local pid _ alive_=()
	for _ in $(seq 50); do
		alive_=()
		for pid; do
			! alive "$pid" || alive_+=("$pid")
		done
		((${#alive_[@]} > 0)) || return 0
		sleep 0.1
	done
	kill -KILL "${alive_[@]}" 2>/dev/null || true
	echo "  the builds ${alive_[*]} kept running after the gate was interrupted"
	return 1
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

the_full_gate_adds_the_flake_step_and_the_claude_code_check() {
	new_repo
	gate
	expect_status 0
	expect_out "all 5 steps passed"
	expect_builds "$(check_of alpha)" "$(check_of beta)" "$(check_of gamma)"
	[[ -s "$bin/outputs.apply" ]] || {
		echo "  expected the flake step to check the other outputs, the fake nix got: $(cat "$bin/nix.log" 2>/dev/null)"
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
	local line n=0
	while IFS= read -r line; do
		n=$((n + 1))
		# The one call that reads no flake, and refuses the flag.
		[[ "$line" != *" config show system" ]] || continue
		[[ "$line" == *--no-update-lock-file* ]] || {
			echo "  nix ran without --no-update-lock-file: $line"
			return 1
		}
	done <"$bin/nix.log"
	((n > 3)) || {
		echo "  expected the full gate to run nix more than three times, it ran it $n times"
		return 1
	}
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
	expect_err "flake failed (exit 3)"
}

the_flake_step_never_runs_nix_flake_check() {
	new_repo
	gate
	expect_status 0
	# Only these subcommands: never flake check, which holds every check in
	# one evaluator.
	local line
	while IFS= read -r line; do
		line="${line#--extra-experimental-features nix-command flakes }"
		case "$line" in
		"config show system" | "flake prefetch "* | "eval "* | "build "*) ;;
		*)
			echo "  the gate ran another nix command: ${line:0:200}"
			return 1
			;;
		esac
	done <"$bin/nix.log"
}

each_check_is_built_in_a_nix_process_of_its_own() {
	new_repo
	checks_named delta alpha
	gate
	expect_status 0
	# In the order the listing gives, one installable per process.
	expect_builds "$(check_of delta)" "$(check_of alpha)"
	local line rest evals=0 builds_=0
	while IFS= read -r line; do
		case "$line" in
		*" eval --raw path:/nix/store/fake1-source#.checks.x86_64-linux --apply "*) ;;
		*" eval "*"#.checks."*)
			evals=$((evals + 1))
			[[ "$line" == *" eval --raw path:/nix/store/fake1-source#.checks.x86_64-linux.\""*"\" --apply "*" --no-update-lock-file" ]] || {
				echo "  unexpected evaluation of a check: ${line:0:300}"
				return 1
			}
			rest="${line#*#.checks.}"
			[[ "${rest%% --apply *}" != *"#"* ]] || {
				echo "  one nix eval got more than one installable: ${line:0:300}"
				return 1
			}
			;;
		*" build "*".drv^*"*)
			builds_=$((builds_ + 1))
			[[ "$line" == *" build --no-link --print-build-logs --keep-going /nix/store/fake"*"-check.drv^* --no-update-lock-file" ]] || {
				echo "  unexpected build of a check: $line"
				return 1
			}
			;;
		*" build "*".#"*"checks"*)
			echo "  a check was built from its installable, which evaluates it again: $line"
			return 1
			;;
		esac
	done <"$bin/nix.log"
	((evals == 2 && builds_ == 2)) || {
		echo "  expected 2 evaluations and 2 builds of checks, got $evals and $builds_"
		return 1
	}
	expect_out "2 checks built"
}

the_checks_are_listed_by_name_only() {
	new_repo
	gate
	expect_status 0
	# The listing asks for the names alone, so nix evaluates no check.
	local listing
	listing="$(rg -F ' eval --raw path:/nix/store/fake1-source#.checks.x86_64-linux --apply ' "$bin/nix.log")"
	[[ "$listing" == *"builtins.attrNames"* ]] || {
		echo "  unexpected listing of the checks: $listing"
		return 1
	}
	[[ "$(printf '%s\n' "$listing" | wc -l)" == 1 ]] || {
		echo "  expected one listing, got: $listing"
		return 1
	}
}

the_listing_comes_before_any_build() {
	new_repo
	gate
	expect_status 0
	local first
	first="$(rg -n -F '#.checks.x86_64-linux."' "$bin/nix.log" | head -1 | cut -d: -f1)"
	[[ "$(sed -n "1,${first}p" "$bin/nix.log")" == *"config show system"*" eval --raw path:/nix/store/fake1-source#.checks.x86_64-linux --apply "* ]] || {
		echo "  expected the system and the listing before the first build: $(cat "$bin/nix.log")"
		return 1
	}
}

a_failing_check_does_not_stop_the_others_and_is_named() {
	new_repo
	fail_check 100 "$(check_of beta)"
	gate
	expect_status 100
	expect_builds "$(check_of alpha)" "$(check_of beta)" "$(check_of gamma)"
	expect_err "1 of 3 checks failed"
	expect_err "  beta (exit 100)"
	expect_no_err "alpha (exit"
	expect_no_err "gamma (exit"
	expect_err "flake failed (exit 100)"
}

every_failed_check_is_named_and_the_first_status_is_the_steps() {
	new_repo
	checks_named alpha beta gamma delta
	fail_check 1 "$(check_of gamma)"
	fail_check 100 "$(check_of beta)"
	gate
	expect_status 100
	expect_builds "$(check_of alpha)" "$(check_of beta)" "$(check_of gamma)" "$(check_of delta)"
	expect_err "2 of 4 checks failed"
	expect_err "  beta (exit 100)"
	expect_err "  gamma (exit 1)"
	expect_err "flake failed (exit 100)"
}

a_check_that_fails_to_evaluate_counts_as_failed() {
	new_repo
	# A check that throws, or is no derivation, is still listed, since the
	# listing reads names only; the evaluation of its derivation fails, and
	# nothing is built for it.
	fail_eval 1 "$(check_of beta)"
	gate
	expect_status 1
	expect_builds "$(check_of alpha)" "$(check_of gamma)"
	expect_err "error: $(check_of beta) failed"
	expect_err "  beta (exit 1)"
	expect_err "flake failed (exit 1)"
}

a_check_is_evaluated_by_the_derivation_guard() {
	new_repo
	gate
	expect_status 0
	local want
	want="$(cat "$src/scripts/lib/check-drv.nix")"
	[[ "$(cat "$bin/check.apply")" == "$want" ]] || {
		echo "  expected each check's derivation through scripts/lib/check-drv.nix, got: $(cat "$bin/check.apply")"
		return 1
	}
}

an_evaluation_that_prints_no_derivation_fails_the_check() {
	new_repo
	checks_named alpha beta gamma delta epsilon
	# No path, a derivation outside the store, a store path that is no
	# derivation, two lines.
	printf '%s %s\n' \
		"$(check_of beta)" hello \
		"$(check_of gamma)" /tmp/x.drv \
		"$(check_of delta)" /nix/store/abc-x >"$bin/eval.weird"
	gate
	expect_status 1
	expect_builds "$(check_of alpha)" "$(check_of epsilon)"
	expect_err "printed no derivation: hello"
	expect_err "printed no derivation: /tmp/x.drv"
	expect_err "  beta (exit 1)"
	expect_err "  gamma (exit 1)"
	expect_err "  delta (exit 1)"
}

without_the_derivation_guard_the_flake_step_fails() {
	new_repo
	rm -- "$repo/scripts/lib/check-drv.nix"
	gate
	expect_status 1
	expect_err "check-drv.nix"
	expect_builds
}

an_empty_list_of_checks_builds_nothing_and_says_so() {
	new_repo
	checks_named
	gate
	expect_status 0
	expect_builds
	expect_out "0 checks built"
	[[ -s "$bin/outputs.apply" ]] || {
		echo "  the other outputs went unchecked"
		return 1
	}
}

a_check_name_that_needs_quoting_is_quoted() {
	new_repo
	checks_named 'a.b' '50% off' "it's \$HOME" 'ü' '-x#y?z'
	gate
	expect_status 0
	# Quoted for nix's attribute path, and percent-encoded for the flake
	# reference, which decodes its fragment.
	expect_builds \
		"$(check_of a.b)" \
		"$(check_of 50%25%20off)" \
		"$(check_of it%27s%20%24HOME)" \
		"$(check_of %C3%BC)" \
		"$(check_of -x%23y%3Fz)"
	expect_out "5 checks built"
}

a_check_name_nix_cannot_address_fails_and_the_others_run() {
	new_repo
	printf '%s\n' 'ok alpha' 'bad "x\"y"' 'ok gamma' >"$bin/names"
	gate
	expect_status 1
	expect_builds "$(check_of alpha)" "$(check_of gamma)"
	expect_err "1 of 3 checks failed"
	expect_err '"x\"y"'
	expect_err "flake failed (exit 1)"
}

a_listing_line_of_another_shape_fails_the_step() {
	new_repo
	printf '%s\n' 'ok alpha' 'warning: something' >"$bin/names"
	gate
	expect_status 1
	expect_err "warning: something"
	expect_err "flake failed (exit 1)"
}

a_listing_that_fails_fails_the_step_and_the_outputs_are_still_checked() {
	new_repo
	printf '5\n' >"$bin/names.status"
	gate
	expect_status 5
	expect_builds
	expect_err "could not list the checks"
	[[ -s "$bin/outputs.apply" ]] || {
		echo "  the other outputs went unchecked"
		return 1
	}
	expect_err "flake failed (exit 5)"
	[[ ! -e "$bin/verify.log" ]] || {
		echo "  claude-code-verify ran after a failed flake step"
		return 1
	}
}

a_system_nix_cannot_name_fails_the_step_before_any_build() {
	new_repo
	printf '4\n' >"$bin/system.status"
	gate
	expect_status 4
	expect_builds
	expect_err "flake failed (exit 4)"
	local bad
	for bad in '' 'x86_64 linux' '../x' 'x86_64-linux"'; do
		rm -f -- "$bin/system.status"
		printf '%s\n' "$bad" >"$bin/system"
		gate
		expect_status 1
		expect_builds
		expect_err "system"
	done
}

the_other_outputs_are_checked_for_the_system() {
	new_repo
	gate
	expect_status 0
	local apply want
	apply="$(cat "$bin/outputs.apply")"
	want="$(cat "$src/scripts/lib/flake-outputs.nix")"
	[[ "$apply" == "outputs: (($want) \"x86_64-linux\" outputs).report" ]] || {
		echo "  expected the outputs to be checked by scripts/lib/flake-outputs.nix for x86_64-linux, got: $apply"
		return 1
	}
	expect_out "packages.x86_64-linux: 2 derivations"
}

a_bad_output_fails_the_step_and_the_checks_still_run() {
	new_repo
	printf '1\n' >"$bin/outputs.status"
	printf '%s\n' "error: flake output 'apps' is no output the flake step knows" >"$bin/outputs.err"
	gate
	expect_status 1
	expect_builds "$(check_of alpha)" "$(check_of beta)" "$(check_of gamma)"
	expect_err "flake output 'apps' is no output the flake step knows"
	expect_err "the other outputs failed (exit 1)"
	expect_err "flake failed (exit 1)"
	[[ ! -e "$bin/verify.log" ]] || {
		echo "  claude-code-verify ran after a failed flake step"
		return 1
	}
}

a_bad_output_before_a_failing_check_gives_the_status_of_the_outputs() {
	new_repo
	printf '7\n' >"$bin/outputs.status"
	fail_check 100 "$(check_of alpha)"
	gate
	expect_status 7
	expect_err "  alpha (exit 100)"
	expect_err "the other outputs failed (exit 7)"
}

without_a_validator_the_flake_step_fails() {
	new_repo
	rm -- "$repo/scripts/lib/flake-outputs.nix"
	gate
	expect_status 1
	expect_err "flake-outputs.nix"
	[[ ! -e "$bin/outputs.apply" ]] || {
		echo "  the outputs were checked without the validator"
		return 1
	}
}

# One snapshot of the source for the whole step.

the_step_checks_the_tree_it_started_with() {
	new_repo
	fail_check 1 "$(check_of beta)"
	# While alpha builds, the work tree is edited: beta passes now, and a
	# check late is added that fails.
	mkdir -p "$bin/build.mutate"
	checks_named alpha beta gamma late
	mv -- "$bin/names" "$bin/build.mutate/names"
	checks_named alpha beta gamma
	printf '1 %s\n' "$(check_of late)" >"$bin/build.mutate/build.fail"
	gate
	expect_status 1
	[[ -e "$bin/mutating" ]] || {
		echo "  the work tree was never edited during the run"
		return 1
	}
	expect_err "1 of 3 checks failed"
	expect_err "  beta (exit 1)"
	expect_builds "$(check_of alpha)" "$(check_of beta)" "$(check_of gamma)"
}

every_flake_call_of_the_step_reads_one_snapshot() {
	new_repo
	gate
	expect_status 0
	local line n=0 prefetches=0
	while IFS= read -r line; do
		case "$line" in
		*" flake prefetch --json --no-pretty --out-link "*" . "*) prefetches=$((prefetches + 1)) ;;
		*" config show system" | *" eval --raw --expr "* | *" build "*".drv^*"*) ;;
		*"claude-code"*) ;;
		*)
			n=$((n + 1))
			[[ "$line" == *" path:/nix/store/fake1-source#."* ]] || {
				echo "  a call of the flake step read another source: ${line:0:200}"
				return 1
			}
			;;
		esac
	done <"$bin/nix.log"
	((prefetches == 1 && n == 5)) || {
		echo "  expected one prefetch and five calls on the snapshot (listing, outputs, three checks), got $prefetches and $n"
		return 1
	}
}

a_source_nix_cannot_snapshot_fails_the_step_before_any_build() {
	new_repo
	printf '3\n' >"$bin/prefetch.status"
	gate
	expect_status 3
	expect_builds
	expect_err "flake failed (exit 3)"
	[[ ! -e "$bin/outputs.apply" ]] || {
		echo "  the outputs were checked without a snapshot"
		return 1
	}
}

# A Ctrl-C ends the step in every phase, and the step stops every nix
# process it started.

an_interrupt_during_the_listing_ends_the_gate() {
	new_repo
	: >"$bin/names.hang"
	local gate_pid
	start_gate
	await_file "$bin/names.pid"
	kill -INT -- "-$gate_pid"
	await_gate 50
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "$(cat "$bin/names.pid")"
	expect_no_out "--> "
	expect_builds
}

an_interrupt_during_the_outputs_check_ends_the_gate() {
	new_repo
	: >"$bin/outputs.hang"
	local gate_pid
	start_gate
	await_file "$bin/outputs.pid"
	kill -INT -- "-$gate_pid"
	await_gate 50
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "$(cat "$bin/outputs.pid")"
	expect_no_out "--> "
	expect_builds
}

an_outputs_check_that_ignores_sigterm_is_killed() {
	new_repo
	: >"$bin/outputs.hang"
	: >"$bin/stubborn"
	local gate_pid
	start_gate
	await_file "$bin/outputs.pid"
	kill -INT -- "-$gate_pid"
	await_gate 150
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "$(cat "$bin/outputs.pid")"
	expect_err "SIGKILL"
	expect_builds
}

# The checks are built one at a time unless RAVNIX_CHECK_JOBS says 2.

by_default_one_check_builds_at_a_time() {
	new_repo
	checks_named alpha beta gamma delta
	gate
	expect_status 0
	local want
	want="$(printf 'start 1 %s\nend %s\n' \
		"$(check_of alpha)" "$(check_of alpha)" "$(check_of beta)" "$(check_of beta)" \
		"$(check_of gamma)" "$(check_of gamma)" "$(check_of delta)" "$(check_of delta)")"
	[[ "$(cat "$bin/builds.log")" == "$want" ]] || {
		printf '  expected one build at a time, got:\n%s\n' "$(cat "$bin/builds.log")"
		return 1
	}
}

two_jobs_build_two_checks_at_a_time_and_never_more() {
	new_repo
	checks_named alpha beta gamma delta epsilon
	printf '2\n' >"$bin/build.barrier"
	fail_check 100 "$(check_of gamma)"
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS=2 scripts/check.sh
	expect_status 100
	[[ -e "$bin/overlapped" ]] || {
		echo "  no two builds ran at the same time: $(cat "$bin/builds.log")"
		return 1
	}
	! rg -q '^start [3-9]' "$bin/builds.log" || {
		echo "  more than two builds ran at once: $(cat "$bin/builds.log")"
		return 1
	}
	[[ "$(builds | sort)" == "$(printf '%s\n' "$(check_of alpha)" "$(check_of beta)" "$(check_of delta)" "$(check_of epsilon)" "$(check_of gamma)" | sort)" ]] || {
		echo "  expected each check built once: $(builds)"
		return 1
	}
	expect_err "1 of 5 checks failed"
	expect_err "  gamma (exit 100)"
	expect_err "flake failed (exit 100)"
	# Each build's lines are marked with its check.
	expect_out "[beta] building $(check_of beta)"
}

two_jobs_report_the_first_failing_check_in_order() {
	new_repo
	checks_named alpha beta gamma
	: >"$bin/build.barrier"
	fail_check 3 "$(check_of gamma)"
	fail_check 9 "$(check_of beta)"
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS=2 scripts/check.sh
	expect_status 9
	expect_err "2 of 3 checks failed"
}

three_jobs_build_three_checks_at_a_time_and_never_more() {
	new_repo
	checks_named alpha beta gamma delta epsilon zeta
	printf '3\n' >"$bin/build.barrier"
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS=3 scripts/check.sh
	expect_status 0
	[[ -e "$bin/overlapped" ]] || {
		echo "  no three builds ran at the same time: $(cat "$bin/builds.log")"
		return 1
	}
	! rg -q '^start ([4-9]|[1-9][0-9])' "$bin/builds.log" || {
		echo "  more than three builds ran at once: $(cat "$bin/builds.log")"
		return 1
	}
	expect_out "6 checks, 3 at a time"
	expect_out "6 checks built"
}

an_interrupted_gate_stops_the_builds_it_started() {
	new_repo
	: >"$bin/build.hang"
	local gate_pid running=()
	start_gate RAVNIX_CHECK_JOBS=2
	await_builds 2
	kill -INT -- "-$gate_pid"
	await_gate 50
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "${running[@]}"
	# The two that ran, in either order, and no third.
	[[ "$(builds | sort | tr '\n' ' ')" == "$(check_of alpha) $(check_of beta) " ]] || {
		echo "  expected alpha and beta built, and nothing after the Ctrl-C: $(builds | tr '\n' ' ')"
		return 1
	}
}

an_interrupted_gate_stops_in_the_default_mode_too() {
	new_repo
	: >"$bin/build.hang"
	local gate_pid running=()
	start_gate
	await_builds 1
	kill -INT -- "-$gate_pid"
	await_gate 50
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "${running[@]}"
	# The Ctrl-C ends the gate, not just the check it was building.
	expect_builds "$(check_of alpha)"
	expect_no_out "==> claude-code"
}

a_terminated_gate_stops_its_builds() {
	new_repo
	: >"$bin/build.hang"
	local gate_pid running=()
	start_gate
	await_builds 1
	kill -TERM -- "-$gate_pid"
	await_gate 50
	expect_status 143
	expect_dead "${running[@]}"
	expect_builds "$(check_of alpha)"
}

a_build_that_ignores_sigterm_is_killed() {
	new_repo
	: >"$bin/build.hang"
	: >"$bin/stubborn"
	local gate_pid running=()
	start_gate RAVNIX_CHECK_JOBS=2
	await_builds 2
	kill -INT -- "-$gate_pid"
	# 10 s for the builds to stop on SIGTERM, then SIGKILL.
	await_gate 150
	expect_status 130
	# The step ends by its own exit, so the gate names it.
	expect_err "flake failed (exit 130)"
	expect_dead "${running[@]}"
	expect_err "SIGKILL"
}

any_positive_job_count_is_taken() {
	new_repo
	local jobs
	# More jobs than checks, also more than bash's arithmetic holds.
	for jobs in 1000 99999999999999999999999; do
		rm -f -- "$bin/builds.log"
		capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS="$jobs" scripts/check.sh
		expect_status 0
		expect_out "3 checks built"
		[[ "$(builds | sort | tr '\n' ' ')" == "$(check_of alpha) $(check_of beta) $(check_of gamma) " ]] || {
			echo "  with RAVNIX_CHECK_JOBS=$jobs, expected all three built: $(builds | tr '\n' ' ')"
			return 1
		}
	done
}

a_bad_job_count_fails_before_any_step() {
	new_repo
	local jobs
	for jobs in 0 -1 ' 1' 1.5 two 01 +2 2x; do
		capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS="$jobs" scripts/check.sh
		expect_status 2
		expect_err "RAVNIX_CHECK_JOBS"
		expect_no_out "==> boundary"
	done
	# The fast gate runs no check, so it does not read it.
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS=7 scripts/check.sh --fast
	expect_status 0
	# Empty is the default.
	capture in_repo env PATH="$bin:$PATH" TMPDIR="$tmp" XDG_STATE_HOME="$state" RAVNIX_CHECK_JOBS= scripts/check.sh
	expect_status 0
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
	printf '1.2.3 beta' >"$bin/version"
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
	fail_check 3 "$(check_of gamma)"
	gate
	expect_status 3
	expect_no_out "==> claude-code"
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
	the_full_gate_adds_the_flake_step_and_the_claude_code_check
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
	the_flake_step_never_runs_nix_flake_check
	each_check_is_built_in_a_nix_process_of_its_own
	the_checks_are_listed_by_name_only
	the_listing_comes_before_any_build
	a_failing_check_does_not_stop_the_others_and_is_named
	every_failed_check_is_named_and_the_first_status_is_the_steps
	a_check_that_fails_to_evaluate_counts_as_failed
	the_step_checks_the_tree_it_started_with
	every_flake_call_of_the_step_reads_one_snapshot
	a_source_nix_cannot_snapshot_fails_the_step_before_any_build
	an_interrupt_during_the_listing_ends_the_gate
	an_interrupt_during_the_outputs_check_ends_the_gate
	an_outputs_check_that_ignores_sigterm_is_killed
	a_check_is_evaluated_by_the_derivation_guard
	an_evaluation_that_prints_no_derivation_fails_the_check
	without_the_derivation_guard_the_flake_step_fails
	an_empty_list_of_checks_builds_nothing_and_says_so
	a_check_name_that_needs_quoting_is_quoted
	a_check_name_nix_cannot_address_fails_and_the_others_run
	a_listing_line_of_another_shape_fails_the_step
	a_listing_that_fails_fails_the_step_and_the_outputs_are_still_checked
	a_system_nix_cannot_name_fails_the_step_before_any_build
	the_other_outputs_are_checked_for_the_system
	a_bad_output_fails_the_step_and_the_checks_still_run
	a_bad_output_before_a_failing_check_gives_the_status_of_the_outputs
	without_a_validator_the_flake_step_fails
	by_default_one_check_builds_at_a_time
	two_jobs_build_two_checks_at_a_time_and_never_more
	two_jobs_report_the_first_failing_check_in_order
	three_jobs_build_three_checks_at_a_time_and_never_more
	an_interrupted_gate_stops_the_builds_it_started
	an_interrupted_gate_stops_in_the_default_mode_too
	a_terminated_gate_stops_its_builds
	a_build_that_ignores_sigterm_is_killed
	any_positive_job_count_is_taken
	a_bad_job_count_fails_before_any_step
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
