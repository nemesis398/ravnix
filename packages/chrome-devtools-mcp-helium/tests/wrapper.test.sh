#!/usr/bin/env bash
# Tests for chrome-devtools-mcp-helium, the wrapper that runs the Chrome
# DevTools MCP server against a headless Helium whose built-in uBlock Origin is
# switched off (packages/chrome-devtools-mcp-helium). The first twelve tests
# are the ones the Fedora setup had for the wrapper it was carried over from;
# the rest cover what the port changed (the server and the browser are store
# paths, no npx; a directory of its own for every launch, with a TMPDIR in it)
# and the edge cases that are cheap to hit: odd arguments and paths, a link or
# a stuck directory among the old launches, two wrappers at once, every stop
# signal (also one that comes before the server has started), a server that is
# killed, a TMPDIR that is unusable in each way, an
# environment that would switch the browser's sandbox off.
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
# directory: TMPDIR, CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP (the directory it uses
# when TMPDIR is no good, /tmp in life) and XDG_RUNTIME_DIR are set to it, so
# no test touches the real /tmp, the real runtime directory or a real home.
# The environment is built from nothing (env -i), and PATH names no directory,
# so the wrapper has to bring its own tools.
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
PREFIX=cdh.
# The longest directory, in bytes, that the wrapper puts a launch in (TMP_MAX in
# the script). A test with a sandbox over it would make the wrapper fall back to
# the real /tmp.
TMP_MAX=40

sb=""
log=""
dir=""
launch=""
stdin=/dev/null

# A fresh sandbox for the test that calls it. t is the TMPDIR the wrapper is
# given, f the fallback it uses when that is no good, r the runtime directory.
setup() {
	sb="$(mktemp -d -p "$scratch" XXX)"
	if ((${#sb} + 2 > TMP_MAX)); then
		echo "  the sandbox $sb is too long for the wrapper to use (${TMP_MAX} bytes at most for a directory)"
		echo "  and it would fall back to the real /tmp; run this with a shorter TMPDIR"
		return 1
	fi
	mkdir -p "$sb/t" "$sb/f" "$sb/r"
	log="$sb/server.log"
	: >"$log"
	stdin=/dev/null
}

# env for one wrapper run, as an array: nothing but what the wrapper is told.
# Later assignments win, so a test passes its own value of any of these.
wrapper_env() {
	wenv=(env -i PATH=/nonexistent TMPDIR="$sb/t" CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP="$sb/f"
		XDG_RUNTIME_DIR="$sb/r" STUB_LOG="$log" "$@")
}

# run [VAR=value...] -- [ARGS...]: one wrapper run, stdin from $stdin. Sets
# status, out, err, dir (the profile the server was given), launch (the
# directory it is in) and log.
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
	launch="${dir%/profile}"
}

# A PID that is gone: the PID of a process that has ended and been waited for.
dead_pid() {
	local pid
	sleep 0 &
	pid=$!
	wait "$pid"
	printf '%s' "$pid"
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

# Fails unless the directory $1 holds nothing.
expect_empty() {
	[[ -z "$(ls -A -- "$1")" ]] || {
		echo "  $1 is not empty: $(find "$1" -mindepth 1 -maxdepth 1 -printf '%f ' | head -c 200) ..."
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
	wrapper_env STUB_LOG="$waiting_log" STUB_MODE=wait "$@"
	set -m
	"${wenv[@]}" "$UNDER_TEST" </dev/null >/dev/null 2>"$sb/$name.err" &
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

every_launch_gets_a_fresh_directory_in_tmpdir_named_for_the_wrapper() {
	setup
	run -- x
	[[ "$dir" =~ ^"$sb/t/$PREFIX"[0-9]+\.[A-Za-z0-9]{6}/profile$ ]] || {
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

the_launch_is_removed_after_the_server_exits() {
	setup
	run -- x
	expect_status 0
	[[ -n "$dir" && ! -e "$dir" && ! -e "$launch" ]] || {
		echo "  the launch $launch is still there"
		return 1
	}
}

every_launch_gets_its_own_directory() {
	setup
	run -- x
	local first="$launch"
	run -- x
	[[ -n "$launch" && "$launch" != "$first" ]] || {
		echo "  both launches used $launch"
		return 1
	}
}

the_servers_exit_status_is_passed_on_and_the_launch_still_goes() {
	setup
	run STUB_RC=3 -- x
	expect_status 3
	[[ -n "$dir" && ! -e "$launch" ]]
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

a_launch_whose_wrapper_is_gone_is_removed_by_the_next_launch() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	mkdir -p "$sb/t/${PREFIX}$dead.AAAAAA/profile/Default" "$sb/t/${PREFIX}$dead.AAAAAA/t"
	run -- x
	[[ ! -e "$sb/t/${PREFIX}$dead.AAAAAA" ]]
}

a_launch_whose_wrapper_still_runs_is_left_alone() {
	setup
	# $$ is the test file's own process, which is running.
	mkdir -p "$sb/t/${PREFIX}$$.BBBBBB/profile/Default"
	run -- x
	[[ -d "$sb/t/${PREFIX}$$.BBBBBB" ]]
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

after_sigterm_the_launch_is_removed() {
	setup
	local profile
	start_waiting a
	profile="$(sed -n 's/^dir://p' "$sb/a.log")"
	[[ -d "$profile" ]]
	kill -TERM "$wrapper_pid"
	finish "$wrapper_pid"
	[[ -n "$profile" && ! -e "${profile%/profile}" ]]
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
		[[ ! -e "${profile%/profile}" ]] || {
			echo "  after SIG$sig the launch is still there"
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
	run CHROME_DEVTOOLS_HELIUM="$sb/t" -- x
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

the_launch_and_what_is_in_it_are_private_to_the_user() {
	setup
	run -- x
	[[ "$(logged launchmode)" == 700 && "$(logged mode)" == 700 && "$(logged tmpmode)" == 700 ]] || {
		echo "  modes: launch '$(logged launchmode)', profile '$(logged mode)', TMPDIR '$(logged tmpmode)'"
		return 1
	}
}

# The server writes the files of its tools below os.tmpdir() and never removes
# them, and its file tools may read and write there: the directory must be one
# of the launch, empty at the start, and not the caller's.
the_servers_tmpdir_is_an_empty_directory_of_the_launch() {
	setup
	run -- x
	[[ "$(logged tmpdir)" == "$launch/t" ]] || {
		echo "  the server's TMPDIR is '$(logged tmpdir)', not $launch/t"
		return 1
	}
	[[ "$(logged tmpentries)" == 0 ]] || {
		echo "  the server's TMPDIR held $(logged tmpentries) entries at the start"
		return 1
	}
}

files_the_server_leaves_in_its_tmpdir_go_with_the_launch() {
	setup
	run -- x
	expect_status 0
	# The stand-in left a directory and a file in its TMPDIR, as the server does.
	grep -q . "$log"
	[[ ! -e "$launch" ]]
	expect_empty "$sb/t"
	expect_empty "$sb/r"
}

the_runtime_directory_is_not_written_to() {
	setup
	run -- x
	expect_status 0
	expect_empty "$sb/r"
	start_waiting a
	[[ "$(sed -n 's/^dir://p' "$sb/a.log")" != "$sb/r"* ]]
	[[ "$(sed -n 's/^tmpdir://p' "$sb/a.log")" != "$sb/r"* ]]
	kill -TERM "$wrapper_pid"
	finish "$wrapper_pid"
	expect_empty "$sb/r"
}

a_tmpdir_with_spaces_is_fine() {
	setup
	local odd="$sb/t/a b"
	mkdir -p "$odd"
	run TMPDIR="$odd" -- x
	expect_status 0
	[[ "$dir" == "$odd/$PREFIX"*/profile ]] || {
		echo "  the profile is $dir"
		return 1
	}
	[[ "$(logged tmpdir)" == "$launch/t" && ! -e "$launch" ]]
}

# Chromium keeps its singleton socket under TMPDIR, and a path over what a
# socket can hold makes the browser exit at once, which the server reports as
# "Target closed". So the wrapper does not trust a long TMPDIR.
a_tmpdir_that_is_too_long_is_not_used() {
	setup
	local filler long
	filler="$(printf '%080d' 0 | tr 0 x)"
	long="$sb/t/$filler"
	mkdir -p "$long"
	run TMPDIR="$long" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]] || {
		echo "  the profile is $dir, not under $sb/f"
		return 1
	}
	[[ "$(logged tmpdir)" == "$launch/t" ]]
	expect_err "not using TMPDIR="
	[[ ! -e "$launch" ]]
}

# The limit is on the bytes of the directory: the longest one that fits is
# used, one byte more is passed over.
the_longest_tmpdir_that_fits_is_used_and_one_byte_more_is_not() {
	setup
	local fits over
	fits="$sb/$(printf '%0*d' $((TMP_MAX - ${#sb} - 1)) 0 | tr 0 x)"
	over="${fits}y"
	((${#fits} == TMP_MAX)) || {
		echo "  the test's own directory is ${#fits} bytes, not $TMP_MAX"
		return 1
	}
	mkdir -p "$fits" "$over"
	run TMPDIR="$fits" -- x
	expect_status 0
	[[ "$dir" == "$fits/$PREFIX"* ]] || {
		echo "  a directory of $TMP_MAX bytes was passed over: $err"
		return 1
	}
	run TMPDIR="$over" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"* ]] || {
		echo "  a directory of $((TMP_MAX + 1)) bytes was used"
		return 1
	}
	expect_err "not using TMPDIR="
}

# 'ä' is one character and two bytes: a directory of $TMP_MAX characters with
# one of them is over the limit in bytes, in a UTF-8 locale too.
a_tmpdir_is_measured_in_bytes_not_in_characters() {
	setup
	local umlauts wide
	umlauts="$(printf '%0*d' $((TMP_MAX - ${#sb} - 1)) 0 | sed 's/0/ä/g')"
	wide="$sb/$umlauts"
	mkdir -p "$wide"
	run LC_ALL=C.UTF-8 TMPDIR="$wide" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"* ]] || {
		echo "  a directory of $(printf '%s' "$wide" | wc -c) bytes was used"
		return 1
	}
	expect_err "not using TMPDIR="
}

a_tmpdir_that_is_missing_or_unset_falls_back() {
	setup
	run TMPDIR="$sb/does-not-exist" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	expect_err "$sb/does-not-exist"
	run TMPDIR= -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	expect_no_err "TMPDIR"
}

a_tmpdir_that_cannot_be_written_is_passed_over() {
	setup
	((EUID != 0)) || {
		echo "  this test needs a user that a mode can keep out: it is root"
		return 1
	}
	mkdir -p "$sb/ro"
	chmod 500 "$sb/ro"
	run TMPDIR="$sb/ro" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	expect_err "no writable directory"
}

a_tmpdir_in_the_runtime_directory_is_passed_over() {
	setup
	mkdir -p "$sb/r/in"
	run TMPDIR="$sb/r/in" -- x
	expect_status 0
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	expect_err "runtime directory"
	# The runtime directory itself, and a link to it, are in it too.
	ln -s "$sb/r" "$sb/lk"
	run TMPDIR="$sb/r" -- x
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	run TMPDIR="$sb/lk" -- x
	[[ "$dir" == "$sb/f/$PREFIX"*/profile ]]
	expect_err "runtime directory"
	expect_empty "$sb/r/in"
}

with_no_usable_directory_the_wrapper_stops_before_the_server() {
	setup
	run TMPDIR="$sb/missing" CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP="$sb/also-missing" -- x
	((status != 0)) || {
		echo "  the wrapper succeeded"
		return 1
	}
	expect_err "no usable directory"
	[[ ! -s "$log" ]] || {
		echo "  the server ran"
		return 1
	}
}

a_link_among_the_old_launches_is_removed_and_its_target_is_not() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	mkdir -p "$sb/precious/Default"
	echo keep >"$sb/precious/Default/data"
	ln -s "$sb/precious" "$sb/t/${PREFIX}$dead.LINKED"
	run -- x
	[[ ! -e "$sb/t/${PREFIX}$dead.LINKED" && ! -L "$sb/t/${PREFIX}$dead.LINKED" ]] || {
		echo "  the link was left"
		return 1
	}
	[[ "$(cat "$sb/precious/Default/data")" == keep ]] || {
		echo "  the link's target was emptied"
		return 1
	}
}

# One launch that cannot be removed (a directory below it that cannot be
# written) must not stop the next one, or a stuck leftover would lock the user
# out of the server for good.
a_leftover_that_cannot_be_removed_does_not_stop_the_next_launch() {
	setup
	((EUID != 0)) || {
		echo "  this test needs a user that a mode can keep out: it is root"
		return 1
	}
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	mkdir -p "$sb/t/${PREFIX}$dead.STUCK00/sub"
	echo x >"$sb/t/${PREFIX}$dead.STUCK00/sub/file"
	chmod a-w "$sb/t/${PREFIX}$dead.STUCK00/sub"
	run -- x
	expect_status 0
	[[ -s "$log" ]] || {
		echo "  the server never ran"
		return 1
	}
	expect_err "could not remove"
	[[ -d "$sb/t/${PREFIX}$dead.STUCK00" ]]
}

files_and_other_names_among_the_old_launches_are_left_alone() {
	setup
	local dead
	sleep 0 &
	dead=$!
	wait "$dead"
	: >"$sb/t/${PREFIX}$dead.FILE00"
	mkdir -p "$sb/t/other-$dead" "$sb/t/cdh$dead"
	run -- x
	[[ -f "$sb/t/${PREFIX}$dead.FILE00" && -d "$sb/t/other-$dead" && -d "$sb/t/cdh$dead" ]]
}

two_wrappers_at_once_keep_to_their_own_launches() {
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
	# The second launch swept, and must have left the first one's directory.
	[[ -d "$p1" && -d "$p2" ]] || {
		echo "  a profile is missing while both wrappers run"
		return 1
	}
	kill -TERM "$first" "$second"
	finish "$first"
	finish "$second"
	[[ ! -e "${p1%/profile}" && ! -e "${p2%/profile}" ]]
	expect_empty "$sb/t"
}

# The server that dies under the wrapper, as it does when its browser takes it
# down: the wrapper reports how it died and cleans up all the same.
a_server_that_is_killed_leaves_nothing_behind_and_its_status_is_passed_on() {
	setup
	run STUB_MODE=crash -- x
	((status == 137)) || {
		echo "  the wrapper exited with $status, not 137"
		return 1
	}
	[[ -n "$dir" && ! -e "$launch" ]]
	expect_empty "$sb/t"
}

a_wrapper_with_no_server_arguments_and_a_closed_stdin_still_works() {
	setup
	stdin="$sb/empty"
	: >"$stdin"
	run STUB_MODE=echo --
	expect_status 0
	expect_args --executablePath "$DEFAULT_BROWSER" --userDataDir "$dir" --headless \
		--no-usage-statistics --no-performance-crux
	[[ ! -e "$launch" ]]
}

# Puppeteer adds --no-sandbox when this is "true", and a shell rc written for
# another project may export it. The browser's sandbox is not the caller's to
# switch off through the environment.
the_environment_cannot_switch_the_browsers_sandbox_off() {
	setup
	run PUPPETEER_DANGEROUS_NO_SANDBOX=true CHROME_DEVEL_SANDBOX=/nowhere/chrome-sandbox -- x
	expect_status 0
	[[ "$(logged nosandbox)" == unset ]] || {
		echo "  PUPPETEER_DANGEROUS_NO_SANDBOX is '$(logged nosandbox)' in the server"
		return 1
	}
	[[ "$(logged sandboxhelper)" == unset ]] || {
		echo "  CHROME_DEVEL_SANDBOX is '$(logged sandboxhelper)' in the server"
		return 1
	}
}

# A stop signal that comes before the handler is in place ends the wrapper by
# default, and the exit trap then removes the launch from under a server that
# keeps running. So the handler is installed before anything it protects is
# made: the order of the trace is the proof.
the_stop_handler_is_installed_before_the_launch_and_the_server() {
	setup
	wrapper_env
	capture "${wenv[@]}" "$BASH" -x "$UNDER_TEST"
	expect_status 0
	local trap_line launch_line server_line
	trap_line="$(grep -n 'trap .*TERM INT HUP' <<<"$err" | head -n 1 | cut -d: -f1)"
	launch_line="$(grep -n 'mktemp -d' <<<"$err" | head -n 1 | cut -d: -f1)"
	server_line="$(grep -n -e '--executablePath' <<<"$err" | head -n 1 | cut -d: -f1)"
	[[ -n $trap_line && -n $launch_line && -n $server_line ]] || {
		echo "  the trace lacks the trap ('$trap_line'), the launch ('$launch_line') or the server ('$server_line')"
		return 1
	}
	((trap_line < launch_line && launch_line < server_line)) || {
		echo "  the lines of the trace are: handler $trap_line, launch $launch_line, server $server_line"
		return 1
	}
}

# A stop that reaches the wrapper the moment the server has started is passed
# on, whichever of the wrapper's next two statements it falls between.
a_stop_that_comes_with_the_server_reaches_it() {
	setup
	run STUB_MODE=parentstop -- x
	((status == 143)) || {
		echo "  the wrapper exited with $status, not 143"
		return 1
	}
	grep -qx TERM "$log" || {
		echo "  the server never got the stop"
		return 1
	}
	[[ -n $dir && ! -e "$launch" ]]
}

# The sweep of a big leftover takes a while, and a stop that comes during it
# finds no server to pass it to. It is passed on once the server exists, and
# the wrapper ends the way it does for any stop: the leftovers are swept, its
# own launch is gone, it exits 143.
a_stop_during_the_sweep_is_passed_on_when_the_server_exists() {
	setup
	local dead
	dead="$(dead_pid)"
	mkdir -p "$sb/t/${PREFIX}$dead".{1..4000}
	wrapper_env STUB_MODE=wait
	set -m
	"${wenv[@]}" "$UNDER_TEST" </dev/null >/dev/null 2>"$sb/sweep.err" &
	local wrapper_pid=$!
	set +m
	local _
	# The sweep goes through the names in the order of the glob, ".1" first.
	for _ in $(seq 500); do
		[[ ! -e "$sb/t/${PREFIX}$dead.1" ]] && break
		sleep 0.01
	done
	[[ ! -e "$sb/t/${PREFIX}$dead.1" ]] || {
		echo "  the sweep never began"
		kill -KILL "$wrapper_pid"
		return 1
	}
	# The server cannot exist yet: 4000 leftovers are still to go.
	[[ -e "$sb/t/${PREFIX}$dead.999" ]] || {
		echo "  the sweep was over before the stop was sent"
		kill -KILL "$wrapper_pid"
		return 1
	}
	kill -TERM "$wrapper_pid"
	local wrapper_status=0
	wait "$wrapper_pid" || wrapper_status=$?
	((wrapper_status == 143)) || {
		echo "  the wrapper exited with $wrapper_status, not 143 (99 is a server that got no stop)"
		return 1
	}
	expect_empty "$sb/t"
}

tests=(
	the_server_gets_the_browser_the_profile_and_the_privacy_flags
	every_launch_gets_a_fresh_directory_in_tmpdir_named_for_the_wrapper
	the_profile_starts_with_ubo_switched_off
	the_launch_is_removed_after_the_server_exits
	every_launch_gets_its_own_directory
	the_servers_exit_status_is_passed_on_and_the_launch_still_goes
	stdin_reaches_the_server_and_its_stdout_comes_back
	a_missing_browser_is_named_and_the_server_never_starts
	a_launch_whose_wrapper_is_gone_is_removed_by_the_next_launch
	a_launch_whose_wrapper_still_runs_is_left_alone
	sigterm_reaches_the_server_and_the_wrapper_exits_with_its_status
	after_sigterm_the_launch_is_removed
	sigint_and_sighup_are_passed_on_as_a_stop
	the_browser_can_be_overridden
	an_empty_browser_override_means_the_default
	a_browser_that_cannot_be_run_is_refused
	the_server_is_told_not_to_look_for_updates
	arguments_reach_the_server_as_they_are
	the_launch_and_what_is_in_it_are_private_to_the_user
	the_servers_tmpdir_is_an_empty_directory_of_the_launch
	files_the_server_leaves_in_its_tmpdir_go_with_the_launch
	the_runtime_directory_is_not_written_to
	a_tmpdir_with_spaces_is_fine
	a_tmpdir_that_is_too_long_is_not_used
	the_longest_tmpdir_that_fits_is_used_and_one_byte_more_is_not
	a_tmpdir_is_measured_in_bytes_not_in_characters
	a_tmpdir_that_is_missing_or_unset_falls_back
	a_tmpdir_that_cannot_be_written_is_passed_over
	a_tmpdir_in_the_runtime_directory_is_passed_over
	with_no_usable_directory_the_wrapper_stops_before_the_server
	a_link_among_the_old_launches_is_removed_and_its_target_is_not
	a_leftover_that_cannot_be_removed_does_not_stop_the_next_launch
	files_and_other_names_among_the_old_launches_are_left_alone
	two_wrappers_at_once_keep_to_their_own_launches
	a_server_that_is_killed_leaves_nothing_behind_and_its_status_is_passed_on
	a_wrapper_with_no_server_arguments_and_a_closed_stdin_still_works
	the_environment_cannot_switch_the_browsers_sandbox_off
	the_stop_handler_is_installed_before_the_launch_and_the_server
	a_stop_that_comes_with_the_server_reaches_it
	a_stop_during_the_sweep_is_passed_on_when_the_server_exists
)
run_tests "${tests[@]}"
