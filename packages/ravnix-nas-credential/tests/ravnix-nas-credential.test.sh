#!/usr/bin/env bash
# Tests for ravnix-nas-credential (packages/ravnix-nas-credential), run by the
# check bin-ravnix-nas-credential. The script under test is a copy of the
# package's whose PATH starts with $STUB_PATH (tests/bin/helpers/
# stub-first.nix), so that setpriv, rbw, timeout and mv are stand-ins:
# setpriv records how it was asked to drop to the user and then runs the
# rest with an environment as bare as --reset-env leaves it, rbw answers from
# files in $fake and logs every call without its secret, timeout logs the
# limit it was given and is the real one with one second, and mv is the real
# one, slowed when a test needs a run caught mid-write. The build user stands
# in for the login. tests/desktop/nas-rbw-vm.nix runs the real setpriv and
# rbw against a real agent.
#
# The cases that matter most are the negative ones: a locked vault, a vault
# that is not there, an empty, a multi-line, an overlong or a slow secret, and
# a login that does not exist leave the file of an earlier run as it was, and
# none is made; a secret reaches the file byte for byte, whatever it holds,
# and reaches no command line, no environment and no output on the way.
#
# NAS_CREDENTIAL_UNDER_TEST names the copy, TEST_LIB scripts/tests/lib.sh, and
# RBW_TIMEOUT the limit the package gives each rbw call.

# The stubs' bodies are written in single quotes on purpose.
# shellcheck disable=SC2016

# shellcheck source=scripts/tests/lib.sh
. "${TEST_LIB:?}"

SUT=${NAS_CREDENTIAL_UNDER_TEST:?}
limit=${RBW_TIMEOUT:?}
login=$(id -un)
uid=$(id -u)
gid=$(id -g)

bin="$scratch/bin"
fake="$scratch/fake"
real_timeout=$(type -P timeout)
real_mv=$(type -P mv)
# The tools of the rbw stand-in, which setpriv's stand-in starts with no PATH.
tools=$(dirname "$(type -P tr)")
mkdir -p "$bin" "$fake"
export STUB_PATH="$bin"

# setpriv: logs its options, checks that they are the ones that drop to the
# login with nothing of root's kept, and runs the command after `--` with
# the environment --reset-env leaves (and nothing of the test's).
write_script "$bin/setpriv" \
	'printf "%s\n" "$*" >>'"'$fake/setpriv.log'" \
	'want="--reuid='"$uid"' --regid='"$gid"' --init-groups --no-new-privs --reset-env --"' \
	'[[ "${*:1:6}" == "$want" ]] || { echo "fake setpriv: unexpected options: $*" >&2; exit 97; }' \
	'shift 6' \
	'exec env -i HOME='"'$fake/home'"' USER='"'$login'"' PATH=/nonexistent "$@"'

# rbw: `unlocked` and `get` as the real one answers them. $fake holds:
#   locked     the vault is locked: `unlocked` fails
#   no-vault   rbw has no configuration and no agent: every call fails
#   slow       `get` takes five seconds
#   slow-unlocked
#              `unlocked` takes 0.3 seconds
#   flood      `get` prints 2 MiB, then makes flood-done, unless the
#              reader stopped it before the end; then it fails, as rbw
#              does on EPIPE
#   fail-after `get` prints the password and then fails, as an rbw that is
#              cut off or errs after a partial line
#   item.NAME  the password of the item NAME (non-alphanumerics as _),
#              printed with a newline after it, as rbw does
#   rbw.log    one line per call, the arguments only
#   rbw.env    the environment of the last call
#   rbw.stdin  where the last call's standard input pointed
write_script "$bin/rbw" \
	'PATH='"'$tools'" \
	'd='"'$fake'" \
	'printf "%s\n" "$*" >>"$d/rbw.log"' \
	'env | sort >"$d/rbw.env"' \
	'readlink /proc/$$/fd/0 >"$d/rbw.stdin"' \
	'if [[ -e $d/no-vault ]]; then echo "rbw: failed to load config" >&2; exit 1; fi' \
	'case "$1" in' \
	'unlocked) [[ ! -e $d/slow-unlocked ]] || sleep 0.3; [[ ! -e $d/locked ]] ;;' \
	'get)' \
	'  [[ -e $d/locked ]] && { echo "rbw: agent is locked" >&2; exit 1; }' \
	'  [[ -e $d/slow ]] && sleep 5' \
	'  [[ $2 == -- ]] || { echo "fake rbw: get without --" >&2; exit 98; }' \
	'  if [[ -e $d/flood ]]; then head -c 2097152 /dev/zero | tr "\\0" f || exit 1; touch "$d/flood-done"; exit 0; fi' \
	'  f="$d/item.$(printf %s "$3" | tr -c "A-Za-z0-9" _)"' \
	'  [[ -e $f ]] || { echo "rbw: no entry found" >&2; exit 1; }' \
	'  cat "$f"; echo; [[ ! -e $d/fail-after ]] || exit 1 ;;' \
	'*) echo "fake rbw: unexpected call: $*" >&2; exit 99 ;;' \
	'esac'

# timeout: logs the limit, then is the real one with one second in its place.
write_script "$bin/timeout" \
	'printf "%s\n" "$1" >>'"'$fake/timeout.log'" \
	'shift; exec '"'$real_timeout'"' 1 "$@"'
# mv: the real one, five seconds late while $fake/slow-mv exists.
write_script "$bin/mv" \
	'[[ ! -e '"'$fake/slow-mv'"' ]] || sleep 5' \
	'exec '"'$real_mv'"' "$@"'

dir="$scratch/run/nas"
file="$dir/share.cred"

# item NAME SECRET: stores SECRET, exactly, as the password of NAME.
item() { printf '%s' "$2" >"$fake/item.$(printf %s "$1" | tr -c 'A-Za-z0-9' _)"; }
# What the script is started with on its standard input: a file, not
# /dev/null, so that rbw's own /dev/null is the script's doing.
stdin="$scratch/stdin"
printf 'a terminal would be here\n' >"$stdin"
# run [ITEM_USER]: the script for the item "NAS - share", as the user u-1.
run() {
	capture "$SUT" "$login" "$file" u-1 "NAS - share" "$@" <"$stdin"
}
# No part of a secret of the tests, six bytes or more, in the output, the
# logs or the setpriv options: every six-byte window of the secret's first
# 600 bytes is looked for.
clean() {
	local f i w
	local -A seen=()
	for ((i = 0; i + 6 <= ${#1} && i < 600; i++)); do
		w=${1:i:6}
		[[ -z ${seen[$w]-} ]] || continue
		seen[$w]=1
		for f in "$fake/rbw.log" "$fake/setpriv.log" "$fake/rbw.env"; do
			[[ ! -e $f ]] || ! command grep -qF -e "$w" "$f" || {
				echo "  '$w' of the secret is in $f"
				return 1
			}
		done
		[[ "$out$err" != *"$w"* ]] || {
			echo "  '$w' of the secret is in the output: $out $err"
			return 1
		}
	done
}
# Nothing but the file itself in its directory: no temporary file is left.
alone() {
	local left
	left=$(cd "$dir" && ls -A)
	[[ "$left" == "${1-share.cred}" ]] || {
		echo "  the directory holds: $left"
		return 1
	}
}
fresh() {
	rm -rf -- "$dir" "$fake"/item.* "$fake"/locked "$fake"/no-vault "$fake"/slow "$fake"/slow-* \
		"$fake"/flood "$fake"/flood-done "$fake"/fail-after "$fake"/*.log "$fake"/rbw.*
}
expect_file() {
	local want
	want=$(printf 'username=u-1\npassword=%s\n.' "$1")
	[[ "$(cat "$file"; echo .)" == "$want" ]] || {
		echo "  the file holds: $(cat "$file")"
		return 1
	}
}
expect_mode() {
	local got
	got=$(stat -c %a -- "$2")
	[[ "$got" == "$1" ]] || {
		echo "  $2 has mode $got, not $1"
		return 1
	}
}
# An earlier run's file, which a failed read must leave as it was.
earlier() {
	mkdir -p "$dir"
	chmod 700 "$dir"
	printf 'username=u-1\npassword=before\n' >"$file"
	chmod 600 "$file"
}
expect_earlier() {
	expect_file before
}

test_writes_the_file_root_only() {
	fresh
	item "NAS - share" "Qz7plain-secret-1"
	run
	expect_status 0
	expect_file Qz7plain-secret-1
	expect_mode 600 "$file"
	expect_mode 700 "$dir"
	alone
	clean Qz7plain-secret-1
}

test_reads_the_item_as_the_login_through_rbw_alone() {
	fresh
	item "NAS - share" "plain-secret-2"
	run
	expect_status 0
	# The vault is asked whether it is unlocked, then for the item, by name.
	[[ "$(cat "$fake/rbw.log")" == $'unlocked\nget -- NAS - share' ]] || {
		echo "  rbw was asked: $(cat "$fake/rbw.log")"
		return 1
	}
	# setpriv dropped to the login twice, once per call, and the limit runs
	# after the drop, as the login: timeout signals rbw as its own user, and
	# root keeps no capability to signal another.
	[[ "$(wc -l <"$fake/setpriv.log")" == 2 ]]
	command grep -q -- "--reset-env -- $bin/timeout $limit " "$fake/setpriv.log" || {
		echo "  setpriv ran: $(cat "$fake/setpriv.log")"
		return 1
	}
	# rbw never starts an agent of its own here: RBW_AGENT is a program that
	# fails, and its runtime directory is the login's.
	command grep -qx "RBW_AGENT=$(type -P false)" "$fake/rbw.env" || {
		echo "  RBW_AGENT: $(command grep RBW_AGENT "$fake/rbw.env")"
		return 1
	}
	command grep -qx "XDG_RUNTIME_DIR=/run/user/$uid" "$fake/rbw.env"
	# And it reads no terminal: its standard input is /dev/null.
	[[ "$(cat "$fake/rbw.stdin")" == /dev/null ]] || {
		echo "  rbw's standard input: $(cat "$fake/rbw.stdin")"
		return 1
	}
}

test_passes_the_item_user_when_given() {
	fresh
	item "NAS - share" "plain-secret-3"
	run "u-1 at nas"
	expect_status 0
	command grep -qx -- "get -- NAS - share u-1 at nas" "$fake/rbw.log" || {
		echo "  rbw was asked: $(cat "$fake/rbw.log")"
		return 1
	}
}

test_keeps_spaces_hashes_commas_and_equals() {
	fresh
	local s='  lead # not a comment, a=b ; $HOME `id` "q" '"'"'x'"'"' \z  '
	item "NAS - share" "$s"
	run
	expect_status 0
	expect_file "$s"
	clean "not a comment"
}

test_refuses_a_secret_of_two_lines() {
	fresh
	item "NAS - share" $'line-one\npassword=line-two'
	run
	expect_status 1
	expect_err "more than one line"
	[[ ! -e "$file" ]]
	clean line-one
	clean line-two
	# An earlier file stays as it was, and the run says so.
	earlier
	run
	expect_status 0
	expect_err "keep"
	expect_earlier
	alone
}

test_refuses_an_empty_secret() {
	fresh
	item "NAS - share" ""
	run
	expect_status 1
	expect_err "empty"
	[[ ! -e "$file" ]]
	earlier
	run
	expect_status 0
	expect_earlier
}

test_refuses_a_secret_longer_than_mount_cifs_takes() {
	fresh
	# 512 bytes is the most mount.cifs takes, after it doubles each comma.
	local max over commas
	max=$(printf 'x%.0s' {1..512})
	item "NAS - share" "$max"
	run
	expect_status 0
	expect_file "$max"
	fresh
	over="Qz7${max}y"
	item "NAS - share" "$over"
	run
	expect_status 1
	expect_err "512"
	clean "$over"
	[[ ! -e "$file" ]]
	fresh
	commas="Qz7$(printf ',%.0s' {1..257})"
	item "NAS - share" "$commas"
	run
	expect_status 1
	expect_err "512"
	clean "$commas"
	# A huge one, a mebibyte, the same.
	fresh
	item "NAS - share" "$(head -c 1048576 /dev/zero | tr '\0' x)"
	run
	expect_status 1
	expect_err "512"
	[[ ! -e "$file" ]]
}

# A flood from rbw is read no further than the 512-byte limit needs: rbw
# never gets to the end of its output.
test_reads_no_more_of_rbw_than_it_needs() {
	fresh
	touch "$fake/flood"
	run
	expect_status 1
	expect_err "512"
	[[ ! -e "$fake/flood-done" ]] || {
		echo "  the script read all 2 MiB that rbw wrote"
		return 1
	}
	[[ ! -e "$file" ]]
}

# Each rbw call gets the package's limit, and the two together fit the
# unit's start timeout (tests/desktop/nas.nix holds the unit to it): a slow
# answer to both still ends in the fallback, which keeps the earlier file.
test_each_rbw_call_has_the_limit_and_both_leave_time_to_keep() {
	fresh
	earlier
	touch "$fake/slow-unlocked" "$fake/slow"
	item "NAS - share" "slow-secret"
	local start=$SECONDS
	run
	expect_status 0
	expect_earlier
	alone
	((SECONDS - start < 4)) || {
		echo "  two slow calls took $((SECONDS - start)) s"
		return 1
	}
	[[ "$(cat "$fake/timeout.log")" == "$limit"$'\n'"$limit" ]] || {
		echo "  the limits given: $(cat "$fake/timeout.log"), not $limit twice"
		return 1
	}
}

# Killed while it writes, as systemd's stop or start timeout does (SIGTERM
# to the unit's processes), it leaves no temporary file and the earlier
# file as it was.
test_a_kill_mid_write_leaves_no_temporary_file() {
	fresh
	earlier
	item "NAS - share" "killed-secret"
	touch "$fake/slow-mv"
	setsid "$SUT" "$login" "$file" u-1 "NAS - share" </dev/null 2>/dev/null &
	local pid=$! i
	for ((i = 0; i < 50; i++)); do
		compgen -G "$file.??????" >/dev/null && break
		sleep 0.1
	done
	compgen -G "$file.??????" >/dev/null || {
		echo "  the run never made its temporary file"
		return 1
	}
	kill -TERM -- "-$pid"
	wait "$pid" || true
	expect_earlier
	alone
}

# A temporary file that a SIGKILL left behind is removed by the next run once
# it is old; a new one, which may be another run's, is left alone.
test_removes_old_temporary_files_only() {
	fresh
	earlier
	item "NAS - share" "plain-secret-4"
	printf 'username=u-1\npassword=left\n' >"$file.Old123"
	touch -d '10 minutes ago' "$file.Old123"
	printf 'username=u-1\npassword=busy\n' >"$file.New123"
	run
	expect_status 0
	expect_file plain-secret-4
	[[ ! -e "$file.Old123" && -e "$file.New123" ]] || {
		echo "  the directory holds: $(ls -A "$dir")"
		return 1
	}
}

test_locked_vault_keeps_the_earlier_file_and_makes_none() {
	fresh
	touch "$fake/locked"
	item "NAS - share" "never-read"
	run
	expect_status 1
	expect_err "locked"
	expect_err "ai-unlock"
	[[ ! -e "$file" ]]
	# A locked vault is never asked for the item.
	if command grep -q '^get' "$fake/rbw.log"; then
		echo "  a locked vault was asked: $(cat "$fake/rbw.log")"
		return 1
	fi
	earlier
	run
	expect_status 0
	expect_err "keep"
	expect_earlier
	alone
}

test_no_vault_at_all_is_a_locked_one() {
	fresh
	touch "$fake/no-vault"
	run
	expect_status 1
	expect_err "locked"
	[[ ! -e "$file" ]]
	earlier
	run
	expect_status 0
	expect_earlier
}

# What an rbw that fails printed is never written, however it looks: a
# whole password, or one longer than the limit. The run says rbw failed.
test_what_a_failed_rbw_printed_is_not_written() {
	fresh
	touch "$fake/fail-after"
	item "NAS - share" "Qz7looks-whole"
	run
	expect_status 1
	expect_err "cannot read"
	[[ ! -e "$file" ]]
	clean Qz7looks-whole
	fresh
	touch "$fake/fail-after"
	item "NAS - share" "Qz7$(printf 'y%.0s' {1..600})"
	run
	expect_status 1
	expect_err "cannot read"
	expect_no_err "512"
	[[ ! -e "$file" ]]
	earlier
	run
	expect_status 0
	expect_err "cannot read"
	expect_earlier
}

test_an_item_rbw_cannot_read() {
	fresh
	run
	expect_status 1
	expect_err "NAS - share"
	[[ ! -e "$file" ]]
	earlier
	run
	expect_status 0
	expect_earlier
}

test_a_slow_rbw_is_given_up() {
	fresh
	touch "$fake/slow"
	item "NAS - share" "slow-secret"
	local start=$SECONDS
	run
	expect_status 1
	((SECONDS - start < 4)) || {
		echo "  it waited $((SECONDS - start)) s for rbw"
		return 1
	}
	[[ ! -e "$file" ]]
}

test_a_login_that_does_not_exist() {
	fresh
	item "NAS - share" "never-read"
	capture "$SUT" no-such-login-x "$file" u-1 "NAS - share"
	expect_status 1
	expect_err "no-such-login-x"
	[[ ! -e "$fake/rbw.log" && ! -e "$fake/setpriv.log" && ! -e "$file" ]]
}

test_refuses_bad_arguments() {
	fresh
	capture "$SUT" "$login" "$file"
	expect_status 2
	expect_err "usage"
	capture "$SUT" "$login" relative.cred u-1 "NAS - share"
	expect_status 2
	capture "$SUT" "$login" "$file" $'u-1\npassword=x' "NAS - share"
	expect_status 2
	[[ ! -e "$fake/rbw.log" && ! -e "$file" ]]
}

# The secret reaches no command line and no environment: every program the
# script starts is traced, with its arguments and its environment.
test_the_secret_is_on_no_command_line() {
	fresh
	item "NAS - share" "traced-secret-value"
	capture strace -f -qq -v -s 100000 -e trace=execve -o "$scratch/trace" "$SUT" "$login" "$file" u-1 "NAS - share"
	expect_status 0
	expect_file traced-secret-value
	command grep -q execve "$scratch/trace"
	! command grep -qF traced-secret-value "$scratch/trace" || {
		echo "  the secret is in an execve:"
		command grep -F traced-secret-value "$scratch/trace"
		return 1
	}
}

# Runs at the same time leave one whole file of one of them, and nothing
# else, whichever ends last.
test_concurrent_runs() {
	fresh
	local i pids=()
	for i in 1 2 3 4 5 6 7 8; do
		item "NAS - $i" "secret-of-run-$i"
	done
	for i in 1 2 3 4 5 6 7 8; do
		"$SUT" "$login" "$file" u-1 "NAS - $i" 2>/dev/null &
		pids+=($!)
	done
	for i in "${pids[@]}"; do wait "$i"; done
	alone
	expect_mode 600 "$file"
	local got
	got=$(cat "$file")
	local want='^username=u-1
password=secret-of-run-[1-8]$'
	[[ "$got" =~ $want ]] || {
		echo "  the file holds: $got"
		return 1
	}
}

tests=(
	test_writes_the_file_root_only
	test_reads_the_item_as_the_login_through_rbw_alone
	test_passes_the_item_user_when_given
	test_keeps_spaces_hashes_commas_and_equals
	test_refuses_a_secret_of_two_lines
	test_refuses_an_empty_secret
	test_refuses_a_secret_longer_than_mount_cifs_takes
	test_reads_no_more_of_rbw_than_it_needs
	test_what_a_failed_rbw_printed_is_not_written
	test_each_rbw_call_has_the_limit_and_both_leave_time_to_keep
	test_a_kill_mid_write_leaves_no_temporary_file
	test_removes_old_temporary_files_only
	test_locked_vault_keeps_the_earlier_file_and_makes_none
	test_no_vault_at_all_is_a_locked_one
	test_an_item_rbw_cannot_read
	test_a_slow_rbw_is_given_up
	test_a_login_that_does_not_exist
	test_refuses_bad_arguments
	test_the_secret_is_on_no_command_line
	test_concurrent_runs
)
run_tests "${tests[@]}"
