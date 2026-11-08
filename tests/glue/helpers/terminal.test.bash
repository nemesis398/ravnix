#!/usr/bin/env bash
# Tests for the terminal glue's two commands (modules/glue/terminal/):
# ravnix-terminal, which the main key runs, and ravnix-connection, the main
# connection. They run against stand-ins for herdr, ssh and sleep
# (terminal-stand-in.sh), which record each call and answer from files in
# FAKE_DIR, so a wait is recorded instead of waited for. The commands come
# from modules/glue/terminal/scripts.nix, built with the stand-ins; the
# environment names the builds:
#
#   TERMINAL           ravnix-terminal, with the stand-ins for herdr and sleep
#   TERMINAL_NOHERDR   the same with a herdr that does not exist
#   CONNECTION         ravnix-connection, with the stand-ins for ssh and
#                      sleep, forwarding ravnix-link.sock and sk-agent.sock
#   CONNECTION_NOSSH   the same with an ssh that does not exist
#   CONNECTION_ODD     the same forwarding `odd name.sock` and `it's.sock`
#
#   bash tests/glue/helpers/terminal.test.bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

: "${TERMINAL:?}" "${TERMINAL_NOHERDR:?}" "${CONNECTION:?}" "${CONNECTION_NOSSH:?}" "${CONNECTION_ODD:?}"

# The clear-screen sequence ravnix-terminal writes before an attempt that
# follows a wait.
clear=$'\033[H\033[2J\033[3J'

fresh() {
	local d
	for d in fake run tmp; do
		if [[ -e "${scratch:?}/$d" ]]; then rm -r -- "${scratch:?}/$d"; fi
		mkdir -p "$scratch/$d"
	done
	export FAKE_DIR="$scratch/fake" XDG_RUNTIME_DIR="$scratch/run" TMPDIR="$scratch/tmp"
}

# answer NAME K FIELD VALUE: call K of NAME answers with VALUE (run, out,
# err, status).
answer() { printf '%s' "$4" >"$FAKE_DIR/$1.$2.$3"; }
# The number of calls of NAME.
calls() { if [[ -f "$FAKE_DIR/$1.calls" ]]; then wc -l <"$FAKE_DIR/$1.calls"; else echo 0; fi; }
# The waits, in order, on one line.
sleeps() { if [[ -f "$FAKE_DIR/sleep.calls" ]]; then paste -sd' ' "$FAKE_DIR/sleep.calls"; fi; }
# The arguments of call K of NAME, in ARGV.
argv() { mapfile -d '' -t ARGV <"$FAKE_DIR/$1.$2.argv"; }
# has_args ARG...: ARGV holds these arguments, one after the other.
has_args() {
	local i j n=$#
	local want=("$@")
	for ((i = 0; i + n <= ${#ARGV[@]}; i++)); do
		for ((j = 0; j < n; j++)); do
			[[ ${ARGV[i + j]} == "${want[j]}" ]] || continue 2
		done
		return 0
	done
	echo "  expected the arguments '${want[*]}' in a row, got: ${ARGV[*]}"
	return 1
}
expect_calls() {
	[[ "$(calls "$1")" == "$2" ]] || {
		echo "  expected $2 call(s) of $1, got $(calls "$1")"
		return 1
	}
}
expect_sleeps() {
	[[ "$(sleeps)" == "$1" ]] || {
		echo "  expected the waits '$1', got '$(sleeps)'"
		return 1
	}
}
# count_of TEXT IN: how often TEXT occurs in IN.
count_of() {
	local rest="$2" n=0
	while [[ $rest == *"$1"* ]]; do
		rest="${rest#*"$1"}"
		n=$((n + 1))
	done
	echo "$n"
}
expect_err_times() {
	local n
	n="$(count_of "$2" "$err")"
	[[ "$n" == "$1" ]] || {
		echo "  expected '$2' $1 time(s) on stderr, got $n: $err"
		return 1
	}
}

# --- ravnix-terminal ---------------------------------------------------------

test_terminal_detach_closes_the_window() {
	fresh
	capture timeout 60 "$TERMINAL"
	expect_status 0
	expect_calls herdr 1
	argv herdr 1
	[[ "${ARGV[*]}" == "--remote ravnix-server" ]] || {
		echo "  herdr got: ${ARGV[*]}"
		return 1
	}
	expect_sleeps ""
	expect_no_out "$clear"
}

test_terminal_shows_what_herdr_says() {
	fresh
	answer herdr 1 err "lost connection to remote Herdr: broken pipe"
	answer herdr 1 status 1
	capture timeout 60 "$TERMINAL"
	expect_status 0
	expect_err "lost connection to remote Herdr: broken pipe"
	expect_calls herdr 2
}

test_terminal_attaches_again_after_any_other_status() {
	fresh
	answer herdr 1 status 2
	answer herdr 2 status 127
	answer herdr 3 status 130
	answer herdr 4 status 255
	capture timeout 60 "$TERMINAL"
	expect_status 0
	expect_calls herdr 5
	local s
	for s in 2 127 130 255; do expect_err "herdr ended with $s"; done
}

test_terminal_two_windows_at_once_are_two_attaches() {
	fresh
	local a="$scratch/fake/a" b="$scratch/fake/b" sa=0 sb=0
	mkdir -p "$a" "$b"
	printf 1 >"$a/herdr.1.status"
	printf 1 >"$b/herdr.1.status"
	printf 1 >"$a/herdr.1.run"
	FAKE_DIR="$a" timeout 60 "$TERMINAL" >/dev/null 2>&1 &
	local pa=$!
	FAKE_DIR="$b" timeout 60 "$TERMINAL" >/dev/null 2>&1 &
	local pb=$!
	wait "$pa" || sa=$?
	wait "$pb" || sb=$?
	[[ $sa == 0 && $sb == 0 ]] || {
		echo "  the windows ended with $sa and $sb"
		return 1
	}
	[[ $(wc -l <"$a/herdr.calls") == 2 && $(wc -l <"$b/herdr.calls") == 2 ]] || {
		echo "  herdr calls: $(wc -l <"$a/herdr.calls") and $(wc -l <"$b/herdr.calls")"
		return 1
	}
}

# --- ravnix-connection -------------------------------------------------------

test_connection_forwards_both_sockets_on_a_connection_of_its_own() {
	fresh
	answer ssh 1 out 1000
	answer ssh 2 status 255
	echo 1 >"$FAKE_DIR/sleep.max"
	capture timeout 60 "$CONNECTION"
	expect_calls ssh 2
	argv ssh 1
	has_args -o ControlMaster=no
	has_args -o ControlPath=none
	has_args ravnix-server id -u
	argv ssh 2
	has_args -N
	has_args -o ControlMaster=no
	has_args -o ControlPath=none
	has_args -o ExitOnForwardFailure=yes
	has_args -R "/run/user/1000/ravnix-link.sock:$XDG_RUNTIME_DIR/ravnix-link.sock"
	has_args -R "/run/user/1000/sk-agent.sock:$XDG_RUNTIME_DIR/sk-agent.sock"
	[[ ${ARGV[-1]} == ravnix-server ]] || {
		echo "  the forwarding ssh does not end with the alias: ${ARGV[*]}"
		return 1
	}
}

test_connection_refuses_what_is_no_uid() {
	local bad
	for bad in "" abc -1 "1000 1001" $'1000\n1001' ../0 "1000;id"; do
		fresh
		answer ssh 1 out "$bad"
		echo 1 >"$FAKE_DIR/sleep.max"
		capture timeout 60 "$CONNECTION"
		expect_calls ssh 1 || {
			echo "  for the uid '$bad'"
			return 1
		}
		expect_err "the server gave no uid"
	done
}

test_connection_passes_each_socket_name_as_one_word() {
	fresh
	answer ssh 1 out 1000
	answer ssh 2 status 255
	echo 1 >"$FAKE_DIR/sleep.max"
	capture timeout 60 "$CONNECTION_ODD"
	argv ssh 2
	has_args -R "/run/user/1000/odd name.sock:$XDG_RUNTIME_DIR/odd name.sock"
	has_args -R "/run/user/1000/it's.sock:$XDG_RUNTIME_DIR/it's.sock"
}

test_connection_two_at_once_keep_apart() {
	fresh
	local a="$scratch/fake/a" b="$scratch/fake/b" p q
	mkdir -p "$a" "$b"
	for p in "$a" "$b"; do
		printf 1000 >"$p/ssh.1.out"
		printf 1 >"$p/ssh.2.run"
		printf 255 >"$p/ssh.2.status"
		echo 1 >"$p/sleep.max"
	done
	FAKE_DIR="$a" timeout 60 "$CONNECTION" >/dev/null 2>&1 &
	p=$!
	FAKE_DIR="$b" timeout 60 "$CONNECTION" >/dev/null 2>&1 &
	q=$!
	wait "$p" || true
	wait "$q" || true
	[[ $(wc -l <"$a/ssh.calls") == 2 && $(wc -l <"$b/ssh.calls") == 2 ]] || {
		echo "  ssh calls: $(wc -l <"$a/ssh.calls") and $(wc -l <"$b/ssh.calls")"
		return 1
	}
	[[ -z "$(ls -A "$XDG_RUNTIME_DIR")" ]] || {
		echo "  left in the runtime directory: $(ls -A "$XDG_RUNTIME_DIR")"
		return 1
	}
}

tests=(
	test_terminal_detach_closes_the_window
	test_terminal_shows_what_herdr_says
	test_terminal_attaches_again_after_any_other_status
	test_terminal_two_windows_at_once_are_two_attaches
	test_connection_forwards_both_sockets_on_a_connection_of_its_own
	test_connection_refuses_what_is_no_uid
	test_connection_passes_each_socket_name_as_one_word
	test_connection_two_at_once_keep_apart
)
run_tests "${tests[@]}"
