#!/usr/bin/env bash
# Tests for the `ravnix-laptop` command, run against a stand-in for ssh
# (fake-ssh.sh) that records its arguments and answers from files in
# FAKE_DIR; with `run` it even runs the remote command line in a local bash,
# as the remote shell would, so the quoting is tested for real. The command
# comes from packages/ravnix-laptop, built with the stand-in as its ssh. The
# environment names the builds:
#
#   LAPTOP           address 198.51.100.10, user alice, the identity file
#                    IDENTITY, and the laptop's host key HOST_KEY pinned
#   LAPTOP_TOFU      the same without a host key
#   LAPTOP_NOKEY     the same with an identity file that does not exist
#   LAPTOP_NOSSH     the same with an ssh that does not exist
#   LAPTOP_UNBAKED   built with nothing
#
#   bash tests/glue/helpers/ravnix-laptop.test.bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

: "${LAPTOP:?}" "${LAPTOP_TOFU:?}" "${LAPTOP_NOKEY:?}" "${LAPTOP_NOSSH:?}" "${LAPTOP_UNBAKED:?}" "${IDENTITY:?}" "${HOST_KEY:?}"

fresh() {
	local d
	for d in fake tmp state home work; do
		if [[ -e "${scratch:?}/$d" ]]; then rm -r -- "${scratch:?}/$d"; fi
		mkdir -p "$scratch/$d"
	done
	export FAKE_DIR="$scratch/fake" TMPDIR="$scratch/tmp" XDG_STATE_HOME="$scratch/state" HOME="$scratch/home"
	cd "$scratch/work"
}

# The arguments of the last call of the stand-in, in ARGV.
argv() { mapfile -d '' -t ARGV <"$FAKE_DIR/argv"; }
calls() { if [[ -f "$FAKE_DIR/calls" ]]; then wc -l <"$FAKE_DIR/calls"; else echo 0; fi; }
# has_option KEY=VALUE: ssh got `-o KEY=VALUE`.
has_option() {
	local i
	for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
		if [[ ${ARGV[i]} == -o && ${ARGV[i + 1]} == "$1" ]]; then return 0; fi
	done
	echo "  ssh was not given -o $1; it got: ${ARGV[*]}"
	return 1
}
# has_flag FLAG VALUE: ssh got FLAG, then VALUE.
has_flag() {
	local i
	for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
		if [[ ${ARGV[i]} == "$1" && ${ARGV[i + 1]} == "$2" ]]; then return 0; fi
	done
	echo "  ssh was not given $1 $2; it got: ${ARGV[*]}"
	return 1
}
# option_value KEY: the VALUE of the `-o KEY=VALUE` ssh got.
option_value() {
	local i
	for ((i = 0; i + 1 < ${#ARGV[@]}; i++)); do
		if [[ ${ARGV[i]} == -o && ${ARGV[i + 1]} == "$1="* ]]; then
			printf '%s' "${ARGV[i + 1]#"$1="}"
			return 0
		fi
	done
	return 1
}
expect_calls() {
	[[ "$(calls)" == "$1" ]] || {
		echo "  expected $1 call(s) of ssh, got $(calls)"
		return 1
	}
}
expect_no_temp_files() {
	[[ -z "$(ls -A "$TMPDIR")" ]] || {
		echo "  left in TMPDIR: $(ls -A "$TMPDIR")"
		return 1
	}
}

test_runs_the_command_over_ssh() {
	fresh
	echo "hello from huginn" >"$FAKE_DIR/stdout"
	capture "$LAPTOP" echo hello
	expect_status 0
	expect_out "hello from huginn"
	expect_calls 1
	argv
	local n=${#ARGV[@]}
	# The command is one word after the address, behind `--`, so that nothing
	# in it can be read as an option of the local ssh.
	[[ ${ARGV[n - 3]} == -- && ${ARGV[n - 2]} == 198.51.100.10 && ${ARGV[n - 1]} == "echo hello" ]] || {
		echo "  the tail of the call is: ${ARGV[*]:n-3}"
		return 1
	}
	has_flag -l alice
	has_flag -i "$IDENTITY"
}

test_ssh_ignores_every_configuration_file() {
	fresh
	capture "$LAPTOP" true
	argv
	# -F makes ssh skip ~/.ssh/config and /etc/ssh/ssh_config, where a Host *
	# block could hand it the Bitwarden agent, the YubiKey or a ProxyJump.
	has_flag -F /dev/null
}

test_ssh_never_asks_and_never_uses_an_agent() {
	fresh
	capture "$LAPTOP" true
	argv
	has_option BatchMode=yes
	has_option IdentitiesOnly=yes
	has_option IdentityAgent=none
	has_option ForwardAgent=no
	has_option PreferredAuthentications=publickey
	has_option PasswordAuthentication=no
	has_option ClearAllForwardings=yes
	has_option ControlPath=none
}

test_a_sleeping_laptop_is_given_up_on_in_seconds() {
	fresh
	capture "$LAPTOP" true
	argv
	has_option ConnectTimeout=3
	has_option ConnectionAttempts=1
	has_option ServerAliveInterval=2
	has_option ServerAliveCountMax=1
}

test_the_laptops_host_key_is_pinned() {
	fresh
	capture "$LAPTOP" true
	argv
	has_option StrictHostKeyChecking=yes
	has_option HostKeyAlias=huginn
	has_option GlobalKnownHostsFile=/dev/null
	local file
	file=$(option_value UserKnownHostsFile)
	[[ "$(cat "$file")" == "huginn $HOST_KEY" ]] || {
		echo "  the pinned file holds: $(cat "$file")"
		return 1
	}
}

test_without_a_host_key_the_first_one_is_remembered_in_the_state_directory() {
	fresh
	capture "$LAPTOP_TOFU" true
	expect_status 0
	argv
	has_option StrictHostKeyChecking=accept-new
	has_option HostKeyAlias=huginn
	[[ "$(option_value UserKnownHostsFile)" == "$XDG_STATE_HOME/ravnix-laptop/known_hosts" ]]
	[[ -d "$XDG_STATE_HOME/ravnix-laptop" ]]
	# Not in the user's own known_hosts.
	[[ ! -e "$HOME/.ssh" ]]
}

test_the_state_directory_falls_back_to_home() {
	fresh
	unset XDG_STATE_HOME
	capture "$LAPTOP_TOFU" true
	expect_status 0
	argv
	[[ "$(option_value UserKnownHostsFile)" == "$HOME/.local/state/ravnix-laptop/known_hosts" ]]
	[[ -d "$HOME/.local/state/ravnix-laptop" ]]
}

test_without_a_state_directory_it_says_so_and_does_not_call_ssh() {
	fresh
	unset XDG_STATE_HOME HOME
	capture "$LAPTOP_TOFU" true
	expect_status 78
	expect_err "XDG_STATE_HOME"
	expect_calls 0
}

test_a_state_directory_that_cannot_be_made_is_reported() {
	fresh
	: >"$scratch/state/ravnix-laptop"
	capture "$LAPTOP_TOFU" true
	expect_status 78
	expect_err "cannot create"
	expect_calls 0
}

test_every_word_reaches_the_remote_shell_as_one_word() {
	fresh
	: >"$FAKE_DIR/run"
	local -a words=(
		'a b' 'c;d' $'$(touch pwned)' $'`touch pwned`' '"quoted"' "it's" 'back\slash' '*' '~' '#x'
		'&' '|' '>out' '' '-n' '--' $'two\nlines' 'ä – ö' '  lead and trail  ' '!' '{a,b}' $'$HOME'
		'%s' '; touch pwned' '&& touch pwned' $'tab\there' $'\\' "'" '"'
	)
	capture "$LAPTOP" printf '%s\0' "${words[@]}"
	expect_status 0
	local -a got
	mapfile -d '' -t got <"$scratch/.out"
	[[ ${#got[@]} == "${#words[@]}" ]] || {
		echo "  sent ${#words[@]} words, the remote shell got ${#got[@]}"
		return 1
	}
	local i
	for i in "${!words[@]}"; do
		[[ ${got[i]} == "${words[i]}" ]] || {
			echo "  word $i: sent '${words[i]}', got '${got[i]}'"
			return 1
		}
	done
	# Nothing in the words ran.
	[[ -z "$(ls -A "$scratch/work")" ]] || {
		echo "  a word ran: $(ls -A "$scratch/work")"
		return 1
	}
}

test_the_command_name_is_quoted_too() {
	fresh
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" 'echo x; touch pwned'
	# One word: a command with that name, which does not exist.
	[[ $status != 0 ]]
	[[ ! -e pwned ]]
}

test_a_word_that_looks_like_an_option_is_not_one_of_sshs() {
	fresh
	capture "$LAPTOP" -- -oProxyCommand=touch
	expect_status 0
	argv
	local n=${#ARGV[@]} i
	[[ ${ARGV[n - 1]} == -oProxyCommand=touch ]]
	for ((i = 0; i < n - 3; i++)); do
		[[ ${ARGV[i]} != *ProxyCommand* ]] || {
			echo "  ssh got the word as an option: ${ARGV[*]}"
			return 1
		}
	done
}

test_a_huge_argument_goes_through() {
	fresh
	: >"$FAKE_DIR/run"
	local big
	big=$(head -c 100000 /dev/zero | tr '\0' x)
	capture "$LAPTOP" printf %s "$big"
	expect_status 0
	[[ $out == "$big" ]]
}

test_a_command_line_beyond_what_exec_takes_is_refused_before_ssh_runs() {
	fresh
	# Each word is fine on its own; together they are one argument of ssh and,
	# on the laptop, of bash, and Linux takes at most 128 KiB for one.
	local half
	half=$(head -c 70000 /dev/zero | tr '\0' x)
	capture "$LAPTOP" printf %s "$half" "$half"
	expect_status 64
	expect_err "too long"
	expect_no_err "offline or asleep"
	expect_calls 0
}

test_the_exit_status_of_the_command_is_the_commands() {
	fresh
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" sh -c 'exit 3'
	expect_status 3
	capture "$LAPTOP" true
	expect_status 0
	capture "$LAPTOP" false
	expect_status 1
}

test_a_command_that_exits_255_is_told_from_an_ssh_that_failed() {
	fresh
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" sh -c 'exit 255'
	expect_status 255
	[[ -z $err ]]
	# ssh's notice about the host key it has just remembered is no failure.
	echo 'Warning: Permanently added '\''huginn'\'' (ED25519) to the list of known hosts.' >"$FAKE_DIR/log"
	capture "$LAPTOP" sh -c 'exit 255'
	expect_status 255
	[[ -z $err ]]
	capture "$LAPTOP" true
	expect_status 0
	[[ -z $err ]]
}

test_standard_output_and_error_stay_apart() {
	fresh
	echo "to stdout" >"$FAKE_DIR/stdout"
	echo "to stderr" >"$FAKE_DIR/stderr"
	capture "$LAPTOP" true
	expect_out "to stdout"
	expect_no_out "to stderr"
	expect_err "to stderr"
	expect_no_err "to stdout"
}

test_standard_input_reaches_the_command() {
	fresh
	: >"$FAKE_DIR/stdin"
	printf 'some\ndata\n' >"$scratch/in"
	capture "$LAPTOP" cat <"$scratch/in"
	expect_status 0
	[[ "$(cat "$FAKE_DIR/stdin.out")" == $'some\ndata' ]]
}

# What ssh itself says when the laptop cannot be reached.
offline_messages=(
	'ssh: connect to host 198.51.100.10 port 22: Connection timed out'
	'ssh: connect to host 198.51.100.10 port 22: Connection refused'
	'ssh: connect to host 198.51.100.10 port 22: No route to host'
	'ssh: connect to host 198.51.100.10 port 22: Network is unreachable'
	'ssh: connect to host 198.51.100.10 port 22: Host is down'
	'Connection timed out during banner exchange'
	'Connection to 198.51.100.10 port 22 timed out'
	'kex_exchange_identification: Connection closed by remote host'
	'Connection closed by 198.51.100.10 port 22'
	'Connection reset by 198.51.100.10 port 22'
	'Timeout, server 198.51.100.10 not responding.'
	'client_loop: send disconnect: Broken pipe'
)

test_a_laptop_that_cannot_be_reached_is_offline_or_asleep() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	local m
	for m in "${offline_messages[@]}"; do
		printf '%s\n' "$m" >"$FAKE_DIR/log"
		capture "$LAPTOP" true
		expect_status 75 || {
			echo "  for: $m"
			return 1
		}
		expect_err "huginn is offline or asleep"
		[[ -z $out ]]
	done
}

test_the_message_is_one_line_and_names_the_command() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	echo 'ssh: connect to host 198.51.100.10 port 22: Connection timed out' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	[[ "$err" == "ravnix-laptop: huginn is offline or asleep" ]] || {
		echo "  stderr: $err"
		return 1
	}
}

test_output_before_the_link_died_is_kept() {
	fresh
	echo "partial" >"$FAKE_DIR/stdout"
	echo 255 >"$FAKE_DIR/status"
	echo 'Timeout, server 198.51.100.10 not responding.' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 75
	expect_out "partial"
}

test_a_noted_host_key_does_not_hide_a_dead_link() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	printf '%s\n' "Warning: Permanently added 'huginn' (ED25519) to the list of known hosts." \
		'Timeout, server 198.51.100.10 not responding.' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 75
}

# A session that ends in the middle of a command. ssh says so on its own
# standard error (clientloop.c quit_message), not in the file of -E, so the line
# lands among the command's own stderr and the wrapper never sees it: after a
# close ssh has nothing else to say, and the wrapper exits 255 without a word.
# After a reset the goodbye fails as well ("send disconnect: Broken pipe"), and
# that line is in the file, so the wrapper exits 75. Both checked against
# OpenSSH 10.6 and the real wrapper. The stand-in's `ssherr` file is that line.
test_a_session_closed_in_the_middle_of_a_command_is_255_and_silent() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	echo "partial" >"$FAKE_DIR/stdout"
	# What the command wrote before the end, with words that would be
	# taken for ssh's own if the wrapper read this stream.
	printf 'started\nalice@198.51.100.10: Permission denied (publickey).\nConnection timed out\n' >"$FAKE_DIR/stderr"
	printf 'Connection to 198.51.100.10 closed by remote host.\r\n' >"$FAKE_DIR/ssherr"
	capture "$LAPTOP" long-running
	expect_status 255
	expect_out "partial"
	# ssh's line follows the command's own, with ssh's CR LF, and the wrapper
	# adds nothing of its own.
	[[ $err == $'started\nalice@198.51.100.10: Permission denied (publickey).\nConnection timed out\nConnection to 198.51.100.10 closed by remote host.\r' ]] || {
		echo "  stderr: $err"
		return 1
	}
	expect_no_err "ravnix-laptop:"
	# Nothing retries: the command may have done its work.
	expect_calls 1
	# ssh's line comes after everything the command printed, also when the
	# stand-in runs the command itself.
	rm -- "$FAKE_DIR/stderr" "$FAKE_DIR/stdout"
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" sh -c 'echo from the command >&2'
	expect_status 255
	[[ $err == $'from the command\nConnection to 198.51.100.10 closed by remote host.\r' ]] || {
		echo "  stderr: $err"
		return 1
	}
}

test_a_session_reset_in_the_middle_of_a_command_is_75_after_ssh_s_line() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	echo "started" >"$FAKE_DIR/stderr"
	printf 'Read from remote host 198.51.100.10: Connection reset by peer\r\n' >"$FAKE_DIR/ssherr"
	printf 'client_loop: send disconnect: Broken pipe\r\n' >"$FAKE_DIR/log"
	capture "$LAPTOP" long-running
	expect_status 75
	# ssh's line stays where ssh wrote it, ahead of the wrapper's.
	[[ $err == $'started\nRead from remote host 198.51.100.10: Connection reset by peer\r\nravnix-laptop: huginn is offline or asleep' ]] || {
		echo "  stderr: $err"
		return 1
	}
	expect_calls 1
}

# What ssh says when the laptop answers and refuses: not a sleeping laptop.
refusals=(
	'alice@198.51.100.10: Permission denied (publickey).'
	'Host key verification failed.'
	$'@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.'
	$'Load key "/x/key": bad permissions\nalice@198.51.100.10: Permission denied (publickey).'
	'Received disconnect from 198.51.100.10 port 22:2: Too many authentication failures'
	$'alice@198.51.100.10: Permission denied (publickey).\nConnection closed by 198.51.100.10 port 22'
	'no such identity: /x/key: No such file or directory'
)

test_a_laptop_that_refuses_is_not_called_asleep() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	local m
	for m in "${refusals[@]}"; do
		printf '%s\n' "$m" >"$FAKE_DIR/log"
		capture "$LAPTOP" true
		expect_status 255 || {
			echo "  for: $m"
			return 1
		}
		expect_err "ssh to huginn failed"
		expect_no_err "offline or asleep"
		# What ssh said is shown.
		expect_err "${m%%$'\n'*}"
	done
}

test_the_carriage_returns_ssh_ends_its_messages_with_are_dropped() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	printf 'Load key "/x/key": invalid format\r\nalice@198.51.100.10: Permission denied (publickey).\r\n' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 255
	expect_err "Permission denied (publickey)."
	[[ $err != *$'\r'* ]] || {
		echo "  stderr holds a carriage return"
		return 1
	}
	# A warning alone, with its CR LF, is no failure of a command that exits 255.
	printf "Warning: Permanently added 'huginn' (ED25519) to the list of known hosts.\r\n" >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 255
	[[ -z $err ]]
	printf 'Timeout, server 198.51.100.10 not responding.\r\n' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 75
}

test_an_ssh_failure_it_does_not_know_is_reported_as_such() {
	fresh
	echo 255 >"$FAKE_DIR/status"
	echo 'something nobody has seen' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 255
	expect_err "ssh to huginn failed"
	expect_err "something nobody has seen"
	expect_no_err "offline or asleep"
}

test_a_log_of_a_successful_run_is_not_shown() {
	fresh
	echo 'Warning: Permanently added '\''huginn'\'' (ED25519) to the list of known hosts.' >"$FAKE_DIR/log"
	capture "$LAPTOP_TOFU" true
	expect_status 0
	[[ -z $err ]]
}

test_no_arguments_print_the_usage() {
	fresh
	capture "$LAPTOP"
	expect_status 64
	expect_err "usage: ravnix-laptop"
	expect_calls 0
}

test_help_prints_the_usage_on_standard_output() {
	fresh
	capture "$LAPTOP" --help
	expect_status 0
	expect_out "usage: ravnix-laptop"
	capture "$LAPTOP" -h
	expect_status 0
	expect_out "usage: ravnix-laptop"
	expect_calls 0
}

test_a_lone_double_dash_is_no_command() {
	fresh
	capture "$LAPTOP" --
	expect_status 64
	expect_calls 0
}

test_an_unknown_option_is_refused_not_passed_on() {
	fresh
	capture "$LAPTOP" -x true
	expect_status 64
	expect_err "unknown option"
	capture "$LAPTOP" -oProxyCommand=touch
	expect_status 64
	expect_calls 0
}

test_a_command_after_a_double_dash_runs() {
	fresh
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" -- echo hi
	expect_status 0
	expect_out "hi"
}

test_built_with_nothing_it_says_what_to_set() {
	fresh
	capture "$LAPTOP_UNBAKED" true
	expect_status 78
	expect_err "not configured"
	expect_err "ravnix.laptopAccess.identityFile"
	expect_calls 0
}

test_a_missing_identity_file_is_reported_before_ssh_runs() {
	fresh
	capture "$LAPTOP_NOKEY" true
	expect_status 78
	expect_err "/no/such/dir/ravnix-laptop-key"
	expect_calls 0
}

test_it_leaves_nothing_in_the_temporary_directory() {
	fresh
	capture "$LAPTOP" true
	expect_no_temp_files
	echo 255 >"$FAKE_DIR/status"
	echo 'Connection timed out' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 75
	expect_no_temp_files
	echo 'Permission denied (publickey).' >"$FAKE_DIR/log"
	capture "$LAPTOP" true
	expect_status 255
	expect_no_temp_files
	# Not even while ssh is still running, or when the command is killed.
	rm "$FAKE_DIR/status" "$FAKE_DIR/log"
	echo 2 >"$FAKE_DIR/sleep"
	"$LAPTOP" true &
	local pid=$!
	local i
	for i in $(seq 50); do
		if [[ -f "$FAKE_DIR/calls" ]]; then break; fi
		sleep 0.1
	done
	expect_no_temp_files
	kill -TERM "$pid"
	wait "$pid" || true
	expect_no_temp_files
}

test_a_temporary_directory_that_is_not_there_is_this_machines_failure_not_the_commands() {
	fresh
	TMPDIR="$scratch/no/such/dir" capture "$LAPTOP" true
	# 70, and not 1, which is a command's own.
	expect_status 70
	expect_err "cannot make a temporary file"
	expect_err "$scratch/no/such/dir"
	expect_calls 0
	# A directory that cannot be written to is the same.
	mkdir "$scratch/ro"
	chmod 555 "$scratch/ro"
	if [[ ! -w "$scratch/ro" ]]; then
		TMPDIR="$scratch/ro" capture "$LAPTOP" true
		expect_status 70
		expect_calls 0
	fi
	# The command's own 1 is still 1.
	: >"$FAKE_DIR/run"
	capture "$LAPTOP" false
	expect_status 1
}

test_runs_at_the_same_time_do_not_mix_up_their_answers() {
	fresh
	local i
	for i in $(seq 16); do
		mkdir -p "$scratch/c$i"
		if ((i % 2 == 0)); then
			echo 255 >"$scratch/c$i/status"
			echo 'Connection timed out' >"$scratch/c$i/log"
		else
			echo "answer $i" >"$scratch/c$i/stdout"
		fi
		(
			FAKE_DIR="$scratch/c$i"
			rc=0
			"$LAPTOP" true >"$scratch/c$i/out" 2>"$scratch/c$i/err" || rc=$?
			echo "$rc" >"$scratch/c$i/rc"
		) &
	done
	wait
	for i in $(seq 16); do
		if ((i % 2 == 0)); then
			[[ "$(cat "$scratch/c$i/rc")" == 75 ]] || {
				echo "  run $i: exit $(cat "$scratch/c$i/rc")"
				return 1
			}
			[[ "$(cat "$scratch/c$i/err")" == *"offline or asleep"* && ! -s "$scratch/c$i/out" ]]
		else
			[[ "$(cat "$scratch/c$i/rc")" == 0 ]] || {
				echo "  run $i: exit $(cat "$scratch/c$i/rc")"
				return 1
			}
			[[ "$(cat "$scratch/c$i/out")" == "answer $i" && ! -s "$scratch/c$i/err" ]]
		fi
	done
	expect_no_temp_files
}

test_a_missing_ssh_is_a_failure_with_its_own_message() {
	fresh
	# A build whose ssh does not exist: bash says so and exits 127, which is
	# not a sleeping laptop either.
	capture "$LAPTOP_NOSSH" true
	[[ $status == 127 ]] || {
		echo "  exit $status"
		return 1
	}
	expect_no_err "offline or asleep"
}

tests=(
	test_runs_the_command_over_ssh
	test_ssh_ignores_every_configuration_file
	test_ssh_never_asks_and_never_uses_an_agent
	test_a_sleeping_laptop_is_given_up_on_in_seconds
	test_the_laptops_host_key_is_pinned
	test_without_a_host_key_the_first_one_is_remembered_in_the_state_directory
	test_the_state_directory_falls_back_to_home
	test_without_a_state_directory_it_says_so_and_does_not_call_ssh
	test_a_state_directory_that_cannot_be_made_is_reported
	test_every_word_reaches_the_remote_shell_as_one_word
	test_the_command_name_is_quoted_too
	test_a_word_that_looks_like_an_option_is_not_one_of_sshs
	test_a_huge_argument_goes_through
	test_a_command_line_beyond_what_exec_takes_is_refused_before_ssh_runs
	test_the_exit_status_of_the_command_is_the_commands
	test_a_command_that_exits_255_is_told_from_an_ssh_that_failed
	test_standard_output_and_error_stay_apart
	test_standard_input_reaches_the_command
	test_a_laptop_that_cannot_be_reached_is_offline_or_asleep
	test_the_message_is_one_line_and_names_the_command
	test_output_before_the_link_died_is_kept
	test_a_noted_host_key_does_not_hide_a_dead_link
	test_a_session_closed_in_the_middle_of_a_command_is_255_and_silent
	test_a_session_reset_in_the_middle_of_a_command_is_75_after_ssh_s_line
	test_a_laptop_that_refuses_is_not_called_asleep
	test_the_carriage_returns_ssh_ends_its_messages_with_are_dropped
	test_an_ssh_failure_it_does_not_know_is_reported_as_such
	test_a_log_of_a_successful_run_is_not_shown
	test_no_arguments_print_the_usage
	test_help_prints_the_usage_on_standard_output
	test_a_lone_double_dash_is_no_command
	test_an_unknown_option_is_refused_not_passed_on
	test_a_command_after_a_double_dash_runs
	test_built_with_nothing_it_says_what_to_set
	test_a_missing_identity_file_is_reported_before_ssh_runs
	test_it_leaves_nothing_in_the_temporary_directory
	test_a_temporary_directory_that_is_not_there_is_this_machines_failure_not_the_commands
	test_runs_at_the_same_time_do_not_mix_up_their_answers
	test_a_missing_ssh_is_a_failure_with_its_own_message
)
run_tests "${tests[@]}"
