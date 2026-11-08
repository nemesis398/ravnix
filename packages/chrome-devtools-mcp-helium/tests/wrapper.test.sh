#!/usr/bin/env bash
# Tests for chrome-devtools-mcp-helium, the wrapper that runs the Chrome
# DevTools MCP server against a headless Helium whose built-in uBlock Origin is
# switched off (packages/chrome-devtools-mcp-helium). The first twelve tests
# are the ones the Fedora setup had for the wrapper it was carried over from;
# the rest cover what the port changed (the server and the browser are store
# paths, no npx; the profile's root) and the edge cases that are cheap to hit:
# odd arguments and paths, a symlink among the old profiles, two wrappers at
# once, every stop signal.
#
# The server is a stand-in (stub-server.sh) and so is the browser, because the
# wrapper only checks that the browser is executable. The check
# common-chrome-devtools-mcp-helium (tests/common/chrome-devtools-mcp-helium.nix)
# builds the wrapper with both and runs this file with
#
#   UNDER_TEST       the wrapper
#   DEFAULT_BROWSER  the stand-in browser the wrapper was built with
#
# Every path the wrapper reads is a throwaway tree of the test's scratch
# directory: TMPDIR and XDG_RUNTIME_DIR are set to it, so no test touches the
# real /tmp or a real home. The environment is built from nothing (env -i), and
# PATH names no directory, so the wrapper has to bring its own tools.
#
# The end-to-end proof against the real Helium is the VM test
# desktop-chrome-devtools-mcp (tests/desktop/chrome-devtools-mcp.nix).

# The lines checked later are for eval to read, and a trap's quotes are its own.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

: "${UNDER_TEST:?run this through the check common-chrome-devtools-mcp-helium}"
: "${DEFAULT_BROWSER:?run this through the check common-chrome-devtools-mcp-helium}"
UBO=blockjmkbacgjkknlgpkjjiijinjdanf
PREFIX=chrome-devtools-helium.

sb=""
log=""
dir=""
stdin=/dev/null

# A fresh sandbox for the test that calls it: the roots the wrapper puts its
# profile under, and the stand-in log.
setup() {
	sb="$(mktemp -d -p "$scratch" sb.XXXXXX)"
	# The wrapper passes over a root of more than 60 characters and falls back to
	# /tmp, which no test may touch. So the sandbox must be short enough to be
	# used: run the file with a short TMPDIR.
	if ((${#sb} + 4 > 60)); then
		echo "  the sandbox $sb is too long for the wrapper to use (60 characters at most for a root)"
		echo "  and it would fall back to the real /tmp; run this with a shorter TMPDIR"
		return 1
	fi
	mkdir -p "$sb/tmp" "$sb/run"
	log="$sb/server.log"
	: >"$log"
	stdin=/dev/null
}

# env for one wrapper run, as an array: nothing but what the wrapper is told.
wrapper_env() {
	wenv=(env -i PATH=/nonexistent TMPDIR="$sb/tmp" XDG_RUNTIME_DIR="$sb/run" STUB_LOG="$log" "$@")
}

# run [VAR=value...] -- [ARGS...]: one wrapper run, stdin from $stdin. Sets
# status, out, err, dir (the profile the server was given) and log.
run() {
	local vars=()
	while (($# > 0)) && [[ "$1" != -- ]]; do
		vars+=("$1")
		shift
	done
	shift
	: >"$log"
	wrapper_env "${vars[@]}"
	capture "${wenv[@]}" "$UNDER_TEST" "$@" <"$stdin"
	dir="$(sed -n 's/^dir://p' "$log" | head -n 1)"
}

# The lines of the log that start with $1, without it.
logged() { sed -n "s/^$1://p" "$log"; }

# Fails unless the server was given exactly these arguments, in this order.
expect_args() {
	local want got
	want="$(printf 'arg:%q\n' "$@")"
	got="$(grep '^arg:' "$log" || true)"
	[[ "$got" == "$want" ]] || {
		echo "  the server got other arguments."
		echo "  expected:"
		printf '%s\n' "$want" | sed 's/^/    /'
		echo "  got:"
		printf '%s\n' "$got" | sed 's/^/    /'
		return 1
	}
}

# Starts a wrapper whose server waits for a signal, in the background and in
# its own process group (job control), because a plain background job of a
# script ignores SIGINT and the wrapper could not trap it. Sets wrapper_pid and
# waits until the server is up. The first argument names the log.
start_waiting() {
	local name="$1"
	shift
	local waiting_log="$sb/$name.log"
	: >"$waiting_log"
	set -m
	env -i PATH=/nonexistent TMPDIR="$sb/tmp" XDG_RUNTIME_DIR="$sb/run" STUB_LOG="$waiting_log" \
		STUB_MODE=wait "$@" "$UNDER_TEST" </dev/null >/dev/null 2>"$sb/$name.err" &
	wrapper_pid=$!
	set +m
	local _
	for _ in $(seq 200); do
		grep -qx ready "$waiting_log" && return 0
		sleep 0.05
	done
	echo "  the stand-in server of $name did not come up"
	return 1
}

# Waits for the wrapper to end and sets wrapper_status.
finish() {
	wrapper_status=0
	wait "$1" || wrapper_status=$?
}

the_server_gets_the_browser_the_profile_and_the_privacy_flags() {
	setup
	run -- --slim
	expect_status 0
	expect_args --executablePath "$DEFAULT_BROWSER" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux --slim
}

the_profile_is_a_fresh_directory_in_tmpdir_named_for_the_wrapper() {
	setup
	run -- x
	[[ "$dir" =~ ^"$sb/tmp/$PREFIX"[0-9]+\.[A-Za-z0-9]{6}$ ]] || {
		echo "  the profile is $dir"
		return 1
	}
}

the_profile_starts_with_ubo_switched_off() {
	setup
	run -- x
	[[ "$(logged prefs | jq -c ".extensions.settings[\"$UBO\"].disable_reasons")" == "[1]" ]] || {
		echo "  Preferences: $(logged prefs)"
		return 1
	}
}

the_profile_is_removed_after_the_server_exits() {
	setup
	run -- x
	expect_status 0
	[[ -n "$dir" && ! -e "$dir" ]] || {
		echo "  the profile $dir is still there"
		return 1
	}
}

every_launch_gets_its_own_profile() {
	setup
	run -- x
	local first="$dir"
	run -- x
	[[ -n "$dir" && "$dir" != "$first" ]] || {
		echo "  both launches used $dir"
		return 1
	}
}

the_servers_exit_status_is_passed_on_and_the_profile_still_goes() {
	setup
	run STUB_RC=3 -- x
	expect_status 3
	[[ -n "$dir" && ! -e "$dir" ]]
}

stdin_reaches_the_server_and_its_stdout_comes_back() {
	setup
	stdin="$sb/stdin"
	printf 'ping\npong\n' >"$stdin"
	run STUB_MODE=echo -- x
	expect_status 0
	expect_out "got ping"
	expect_out "got pong"
}

a_missing_browser_is_named_and_the_server_never_starts() {
	setup
	run CHROME_DEVTOOLS_HELIUM="$sb/missing" -- x
	((status != 0)) || {
		echo "  the wrapper succeeded"
		return 1
	}
	expect_err "$sb/missing"
	[[ ! -s "$log" ]] || {
		echo "  the server ran"
		return 1
	}
}

a_profile_whose_wrapper_is_gone_is_removed_by_the_next_launch() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	mkdir -p "$sb/tmp/${PREFIX}$dead.AAAAAA/Default"
	run -- x
	[[ ! -e "$sb/tmp/${PREFIX}$dead.AAAAAA" ]]
}

a_profile_whose_wrapper_still_runs_is_left_alone() {
	setup
	# $$ is the test file's own process, which is running.
	mkdir -p "$sb/tmp/${PREFIX}$$.BBBBBB/Default"
	run -- x
	[[ -d "$sb/tmp/${PREFIX}$$.BBBBBB" ]]
}

sigterm_reaches_the_server_and_the_wrapper_exits_with_its_status() {
	setup
	start_waiting a
	kill -TERM "$wrapper_pid"
	finish "$wrapper_pid"
	grep -qx TERM "$sb/a.log"
	((wrapper_status == 143)) || {
		echo "  the wrapper exited with $wrapper_status"
		return 1
	}
}

after_sigterm_the_profile_is_removed() {
	setup
	start_waiting a
	local profile
	profile="$(sed -n 's/^dir://p' "$sb/a.log")"
	[[ -d "$profile" ]]
	kill -TERM "$wrapper_pid"
	finish "$wrapper_pid"
	[[ -n "$profile" && ! -e "$profile" ]]
}

sigint_and_sighup_are_passed_on_as_a_stop() {
	setup
	local sig profile
	for sig in INT HUP; do
		start_waiting "$sig"
		profile="$(sed -n 's/^dir://p' "$sb/$sig.log")"
		kill -"$sig" "$wrapper_pid"
		finish "$wrapper_pid"
		grep -qx TERM "$sb/$sig.log" || {
			echo "  SIG$sig did not reach the server as a stop"
			return 1
		}
		((wrapper_status == 143)) || {
			echo "  after SIG$sig the wrapper exited with $wrapper_status"
			return 1
		}
		[[ ! -e "$profile" ]] || {
			echo "  after SIG$sig the profile is still there"
			return 1
		}
	done
}

the_browser_can_be_overridden() {
	setup
	write_script "$sb/other-browser" 'exit 0'
	run CHROME_DEVTOOLS_HELIUM="$sb/other-browser" -- x
	expect_status 0
	expect_args --executablePath "$sb/other-browser" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux x
}

an_empty_browser_override_means_the_default() {
	setup
	run CHROME_DEVTOOLS_HELIUM= -- x
	expect_status 0
	expect_args --executablePath "$DEFAULT_BROWSER" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux x
}

a_browser_that_cannot_be_run_is_refused() {
	setup
	: >"$sb/not-executable"
	run CHROME_DEVTOOLS_HELIUM="$sb/not-executable" -- x
	((status != 0))
	expect_err "$sb/not-executable"
	[[ ! -s "$log" ]]
	# A directory is no browser either.
	run CHROME_DEVTOOLS_HELIUM="$sb/tmp" -- x
	((status != 0))
	[[ ! -s "$log" ]]
}

the_server_is_told_not_to_look_for_updates() {
	setup
	run -- x
	[[ "$(logged noupdate)" == 1 ]] || {
		echo "  CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS is '$(logged noupdate)' in the server"
		return 1
	}
}

arguments_reach_the_server_as_they_are() {
	setup
	local newline=$'line one\nline two'
	run -- 'two words' '' '*' "$newline" '--flag=a b' "-n" '$HOME' '`id`'
	expect_status 0
	expect_args --executablePath "$DEFAULT_BROWSER" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux \
		'two words' '' '*' "$newline" '--flag=a b' "-n" '$HOME' '`id`'
}

the_profile_is_private_to_the_user() {
	setup
	run -- x
	[[ "$(logged mode)" == 700 ]] || {
		echo "  the profile's mode is '$(logged mode)'"
		return 1
	}
}

a_tmpdir_with_spaces_is_fine() {
	setup
	local odd="$sb/tmp/a b  c"
	mkdir -p "$odd"
	run TMPDIR="$odd" -- x
	expect_status 0
	[[ "$dir" == "$odd/$PREFIX"* ]] || {
		echo "  the profile is $dir"
		return 1
	}
	[[ "$(logged tmpdir)" == "$odd" ]]
	[[ ! -e "$dir" ]]
}

# Chromium keeps its singleton socket under TMPDIR, and a path over about a
# hundred characters makes the browser exit at once, which the server reports
# as "Target closed". So the wrapper does not trust a long TMPDIR.
a_tmpdir_that_is_too_long_is_not_used() {
	setup
	local filler long
	filler="$(printf '%080d' 0 | tr 0 x)"
	long="$sb/tmp/$filler"
	mkdir -p "$long"
	run TMPDIR="$long" -- x
	expect_status 0
	[[ "$dir" == "$sb/run/$PREFIX"* ]] || {
		echo "  the profile is $dir, not under $sb/run"
		return 1
	}
	[[ "$(logged tmpdir)" == "$sb/run" ]] || {
		echo "  the server's TMPDIR is '$(logged tmpdir)'"
		return 1
	}
	expect_err "TMPDIR"
	[[ ! -e "$dir" ]]
}

a_tmpdir_that_is_missing_or_unset_falls_back_to_the_runtime_directory() {
	setup
	run TMPDIR="$sb/does-not-exist" -- x
	expect_status 0
	[[ "$dir" == "$sb/run/$PREFIX"* ]]
	expect_err "$sb/does-not-exist"
	run TMPDIR= -- x
	expect_status 0
	[[ "$dir" == "$sb/run/$PREFIX"* ]]
	expect_no_err "TMPDIR"
}

the_server_runs_with_the_tmpdir_the_profile_is_in() {
	setup
	run -- x
	[[ "$(logged tmpdir)" == "$sb/tmp" ]]
}

a_link_among_the_old_profiles_is_removed_and_its_target_is_not() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	mkdir -p "$sb/precious/Default"
	echo keep >"$sb/precious/Default/data"
	ln -s "$sb/precious" "$sb/tmp/${PREFIX}$dead.LINKED"
	run -- x
	[[ ! -e "$sb/tmp/${PREFIX}$dead.LINKED" && ! -L "$sb/tmp/${PREFIX}$dead.LINKED" ]] || {
		echo "  the link was left"
		return 1
	}
	[[ "$(cat "$sb/precious/Default/data")" == keep ]] || {
		echo "  the link's target was emptied"
		return 1
	}
}

files_and_other_names_among_the_old_profiles_are_left_alone() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	: >"$sb/tmp/${PREFIX}$dead.FILE00"
	mkdir -p "$sb/tmp/other-$dead" "$sb/tmp/chrome-devtools-helium$dead"
	run -- x
	[[ -f "$sb/tmp/${PREFIX}$dead.FILE00" && -d "$sb/tmp/other-$dead" && -d "$sb/tmp/chrome-devtools-helium$dead" ]]
}

two_wrappers_at_once_keep_to_their_own_profiles() {
	setup
	local first second p1 p2
	start_waiting one
	first=$wrapper_pid
	p1="$(sed -n 's/^dir://p' "$sb/one.log")"
	start_waiting two
	second=$wrapper_pid
	p2="$(sed -n 's/^dir://p' "$sb/two.log")"
	[[ -n "$p1" && -n "$p2" && "$p1" != "$p2" ]] || {
		echo "  the profiles are '$p1' and '$p2'"
		return 1
	}
	# The second launch swept, and must have left the first one's profile.
	[[ -d "$p1" && -d "$p2" ]] || {
		echo "  a profile is missing while both wrappers run"
		return 1
	}
	kill -TERM "$first" "$second"
	finish "$first"
	finish "$second"
	[[ ! -e "$p1" && ! -e "$p2" ]]
}

a_wrapper_with_no_server_arguments_and_a_closed_stdin_still_works() {
	setup
	stdin="$sb/empty"
	: >"$stdin"
	run STUB_MODE=echo --
	expect_status 0
	expect_args --executablePath "$DEFAULT_BROWSER" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux
	[[ ! -e "$dir" ]]
}

tests=(
	the_server_gets_the_browser_the_profile_and_the_privacy_flags
	the_profile_is_a_fresh_directory_in_tmpdir_named_for_the_wrapper
	the_profile_starts_with_ubo_switched_off
	the_profile_is_removed_after_the_server_exits
	every_launch_gets_its_own_profile
	the_servers_exit_status_is_passed_on_and_the_profile_still_goes
	stdin_reaches_the_server_and_its_stdout_comes_back
	a_missing_browser_is_named_and_the_server_never_starts
	a_profile_whose_wrapper_is_gone_is_removed_by_the_next_launch
	a_profile_whose_wrapper_still_runs_is_left_alone
	sigterm_reaches_the_server_and_the_wrapper_exits_with_its_status
	after_sigterm_the_profile_is_removed
	sigint_and_sighup_are_passed_on_as_a_stop
	the_browser_can_be_overridden
	an_empty_browser_override_means_the_default
	a_browser_that_cannot_be_run_is_refused
	the_server_is_told_not_to_look_for_updates
	arguments_reach_the_server_as_they_are
	the_profile_is_private_to_the_user
	a_tmpdir_with_spaces_is_fine
	a_tmpdir_that_is_too_long_is_not_used
	a_tmpdir_that_is_missing_or_unset_falls_back_to_the_runtime_directory
	the_server_runs_with_the_tmpdir_the_profile_is_in
	a_link_among_the_old_profiles_is_removed_and_its_target_is_not
	files_and_other_names_among_the_old_profiles_are_left_alone
	two_wrappers_at_once_keep_to_their_own_profiles
	a_wrapper_with_no_server_arguments_and_a_closed_stdin_still_works
)
run_tests "${tests[@]}"
