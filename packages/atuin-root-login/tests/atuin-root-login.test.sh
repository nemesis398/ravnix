#!/usr/bin/env bash
# Tests for atuin-root-login (packages/atuin-root-login), run by the check
# bin-atuin-root-login. rbw, sudo and id are stand-ins made here, and atuin is
# a stand-in built into the package (atuin-stub.bash), so no vault, no root and
# no server are involved. What matters most is what the helper keeps out of
# reach: the username, the password and the recovery key are on no command
# line (not rbw's, sudo's or atuin's), in no file, in no output and in no
# trace, apart from the user name, which is the account's name, and a failure of any step still prints none of them. One test runs
# the real atuin, to show that it takes the password from its standard input
# and the key from its environment, which the helper relies on.
#
# ATUIN_ROOT_LOGIN_UNDER_TEST is the helper built with the stand-in atuin, and
# ATUIN_REAL the real atuin.

# The stubs are written in single quotes on purpose; the checks read variables
# that they set.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

SUT="${ATUIN_ROOT_LOGIN_UNDER_TEST:?set ATUIN_ROOT_LOGIN_UNDER_TEST to the helper}"
real_atuin="${ATUIN_REAL:?set ATUIN_REAL to the real atuin}"

bin="$scratch/bin"
nobin="$scratch/nobin"
rec="$scratch/rec"
vault="$scratch/vault"
tools="$scratch/tools"
mkdir -p "$bin" "$nobin" "$rec" "$vault" "$tools"
# The tools the helper and the stand-ins use, found once: a run's PATH is the
# stand-ins and these, so a test can leave rbw out.
for t in env cat sort readlink head wc find timeout sleep seq python3 unshare cp stat; do
	p="$(type -P "$t" || true)"
	[[ -z "$p" ]] || ln -s "$p" "$tools/$t"
done

item="Test Atuin Item"
# Values that need care: a space, quotes, a dollar and a backtick; none of
# them may be taken for shell syntax or leak.
user_v='sync-user'
key_v='alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima'
pass_v='pw $HOME `id` "q" '"'"'s'"'"' \z -n --'

# rbw: logs its arguments, answers `unlocked` from RBW_LOCKED, and `get` from
# the files username, notes and password in $VAULT for the item named
# $RBW_ITEM (files, so that the values are in no process's environment but
# the one that reads them); RBW_FAIL=<field> makes it fail after writing the
# value to stderr, as a failing rbw might.
write_script "$bin/rbw" \
	'printf "[%s]" "$@" >>"$REC/rbw.calls"; echo >>"$REC/rbw.calls"' \
	'case $1 in' \
	'  unlocked) [[ ${RBW_LOCKED:-0} == 0 ]] ;;' \
	'  get)' \
	'    [[ $2 == --field && $4 == -- && $5 == "$RBW_ITEM" ]] || exit 1' \
	'    v=$(cat "$VAULT/$3")' \
	'    if [[ ${RBW_FAIL:-} == "$3" ]]; then printf "%s\n" "$v" >&2; exit 1; fi' \
	'    printf "%s\n" "$v" ;;' \
	'  *) exit 1 ;;' \
	'esac'
# sudo: records its arguments and its environment, fails with SUDO_RC, and
# otherwise runs the command as root in a user namespace (unshare -Ur), where
# $EUID is 0 and nothing outside the sandbox is root's.
write_script "$bin/sudo" \
	'printf "[%s]" "$@" >>"$REC/sudo.calls"; echo >>"$REC/sudo.calls"' \
	'env | sort >"$REC/sudo.env"' \
	'[[ -z ${SUDO_RC:-} ]] || exit "$SUDO_RC"' \
	'[[ $1 == -- ]] && shift' \
	'exec unshare -Ur -- "$@"'
# An id that would say root and leaves a mark when it runs: the helper reads
# $EUID and must not ask it.
write_script "$bin/id" \
	'echo ran >>"$REC/id.ran"; echo 0'

# Runs the helper with the stand-ins on the PATH, in an environment of its own
# that holds no secret. The variables below pass through when the test sets
# them; the arguments are the command to run.
run() {
	local extra=() v
	for v in RBW_LOCKED RBW_FAIL SUDO_RC ATUIN_LOGIN_RC ATUIN_SYNC_RC; do
		[[ -z ${!v+x} ]] || extra+=("$v=${!v}")
	done
	printf '%s\n' "$user_v" >"$vault/username"
	printf '%s\n' "$key_v" >"$vault/notes"
	printf '%s\n' "$pass_v" >"$vault/password"
	: >"$rec/rbw.calls"
	: >"$rec/sudo.calls"
	: >"$rec/atuin.calls"
	rm -f "$rec"/id.ran "$rec"/atuin.stdin "$rec"/atuin.key "$rec"/atuin.home "$rec"/atuin.env "$rec"/sudo.env
	capture env -i \
		PATH="$bin:$tools" HOME="$scratch/home" TMPDIR="$scratch/tmp" REC="$rec" \
		VAULT="$vault" RBW_ITEM="$item" "${extra[@]}" \
		"$@"
}
mkdir -p "$scratch/home" "$scratch/tmp"
helper() { run "$SUT" "$@"; }

# Runs the helper with one field of the item set to a value: with_field FIELD
# VALUE COMMAND... (the field is username, notes or password).
with_field() {
	local field="$1" value="$2" saved_user="$user_v" saved_key="$key_v" saved_pass="$pass_v"
	shift 2
	case "$field" in
		username) user_v="$value" ;;
		notes) key_v="$value" ;;
		password) pass_v="$value" ;;
	esac
	run "$@"
	user_v="$saved_user" key_v="$saved_key" pass_v="$saved_pass"
}

# No stand-in's record and no output holds a secret: the password or the
# recovery key. The user name is the account's name, not a secret, and atuin
# gets it as an argument. $1 is what must be clean, for the message.
no_secret_in() {
	local what="$1" text="$2" s
	for s in "$key_v" "$pass_v"; do
		[[ "$text" != *"$s"* ]] || {
			echo "  $what holds a secret: $s"
			return 1
		}
	done
}

it_logs_in_with_the_password_on_stdin_and_the_key_in_the_environment() {
	helper "$item"
	expect_status 0
	# atuin's arguments: the program, the flags and `-p -`, no value.
	[[ "$(cat "$rec/atuin.calls")" == $'[login][--username=sync-user][-p][-]\n[sync]' ]] || {
		echo "  atuin was called as: $(cat "$rec/atuin.calls")"
		return 1
	}
	[[ "$(cat "$rec/atuin.stdin")" == "$pass_v" ]] || {
		echo "  atuin's standard input is not the password: $(cat "$rec/atuin.stdin")"
		return 1
	}
	[[ "$(cat "$rec/atuin.key")" == "$key_v" ]] || {
		echo "  atuin's ATUIN_ENCRYPTION_KEY is not the key: $(cat "$rec/atuin.key")"
		return 1
	}
	[[ "$(cat "$rec/atuin.home")" == /root ]] || {
		echo "  atuin runs with HOME=$(cat "$rec/atuin.home"), not root's"
		return 1
	}
}

it_reads_the_three_fields_of_the_item_through_rbw() {
	helper "$item"
	expect_status 0
	local want=$'[unlocked]\n[get][--field][username][--][Test Atuin Item]\n[get][--field][notes][--][Test Atuin Item]\n[get][--field][password][--][Test Atuin Item]'
	[[ "$(cat "$rec/rbw.calls")" == "$want" ]] || {
		echo "  rbw was called as: $(cat "$rec/rbw.calls")"
		return 1
	}
}

it_starts_the_root_half_through_sudo_by_its_own_path() {
	helper "$item"
	expect_status 0
	local line
	line="$(cat "$rec/sudo.calls")"
	[[ "$line" == "[--]["*"][--as-root]" ]] || {
		echo "  sudo was called as: $line"
		return 1
	}
	local path="${line#\[--\]\[}"
	path="${path%\]\[--as-root\]}"
	[[ "$path" == "$(readlink -f "$SUT")" ]] || {
		echo "  sudo ran $path, not the helper ($SUT)"
		return 1
	}
}

it_puts_no_secret_on_a_command_line() {
	helper "$item"
	expect_status 0
	no_secret_in "rbw's arguments" "$(cat "$rec/rbw.calls")"
	no_secret_in "sudo's arguments" "$(cat "$rec/sudo.calls")"
	no_secret_in "atuin's arguments" "$(cat "$rec/atuin.calls")"
}

it_keeps_the_secrets_out_of_sudos_environment() {
	helper "$item"
	expect_status 0
	no_secret_in "sudo's environment" "$(cat "$rec/sudo.env")"
	# atuin's environment holds the key and nothing else.
	local env
	env="$(grep -v '^ATUIN_ENCRYPTION_KEY=' "$rec/atuin.env" || true)"
	no_secret_in "atuin's environment but the key" "$env"
	grep -q '^ATUIN_ENCRYPTION_KEY=' "$rec/atuin.env" || {
		echo "  atuin's environment has no ATUIN_ENCRYPTION_KEY"
		return 1
	}
}

it_writes_no_file() {
	helper "$item"
	expect_status 0
	# Everything the helper could have written is under the scratch directory
	# but the stand-ins' records and the stand-in vault.
	local f hits=""
	while IFS= read -r -d '' f; do
		case "$f" in "$rec"/* | "$vault"/*) continue ;; esac
		if command grep -q -F -e "$key_v" -e "$pass_v" -- "$f" 2>/dev/null; then
			hits="$hits $f"
		fi
	done < <(find "$scratch" -type f -print0)
	[[ -z "$hits" ]] || {
		echo "  a file holds a secret:$hits"
		return 1
	}
}

it_prints_no_secret_even_when_traced() {
	# bash -x, SHELLOPTS and PS4 are set to trace the script; it turns tracing
	# off first.
	run env SHELLOPTS=xtrace PS4='+ ${BASH_COMMAND} # ' "$SUT" "$item"
	expect_status 0
	no_secret_in "stdout" "$out"
	no_secret_in "stderr" "$err"
	run "$BASH" -x "$SUT" "$item"
	no_secret_in "stdout of bash -x" "$out"
	no_secret_in "stderr of bash -x" "$err"
}

it_hands_over_values_that_look_like_options_or_shell_syntax() {
	local v
	for v in '-n' '--' '-e' '-' '$(id)' '`id`' 'a b' '--username=x -p y' "it's" 'back\slash'; do
		pass_v="$v" key_v="$v" run "$SUT" "$item"
		expect_status 0
		[[ "$(cat "$rec/atuin.stdin")" == "$v" ]] || {
			echo "  the password $v reached atuin as: $(cat "$rec/atuin.stdin")"
			return 1
		}
		[[ "$(cat "$rec/atuin.key")" == "$v" ]] || {
			echo "  the key $v reached atuin as: $(cat "$rec/atuin.key")"
			return 1
		}
	done
	# A user name that starts with a dash is not an option of atuin.
	user_v='-x' run "$SUT" "$item"
	expect_status 0
	[[ "$(head -n1 "$rec/atuin.calls")" == '[login][--username=-x][-p][-]' ]] || {
		echo "  atuin was called as: $(head -n1 "$rec/atuin.calls")"
		return 1
	}
}

it_trims_the_notes_but_keeps_the_key_inside() {
	local padded
	padded=$'\n  one two three  \n\n'
	key_v="$padded" run "$SUT" "$item"
	expect_status 0
	[[ "$(cat "$rec/atuin.key")" == "one two three" ]] || {
		echo "  the key reached atuin as: [$(cat "$rec/atuin.key")]"
		return 1
	}
}

it_keeps_the_spaces_at_the_ends_of_the_password_and_the_user_name() {
	pass_v='  spaced pw  ' user_v='name ' run "$SUT" "$item"
	expect_status 0
	[[ "$(cat "$rec/atuin.stdin")" == '  spaced pw  ' ]] || {
		echo "  the password reached atuin as: [$(cat "$rec/atuin.stdin")]"
		return 1
	}
	[[ "$(head -n1 "$rec/atuin.calls")" == '[login][--username=name ][-p][-]' ]] || {
		echo "  atuin was called as: $(head -n1 "$rec/atuin.calls")"
		return 1
	}
}

it_refuses_a_locked_vault_without_asking_for_anything() {
	RBW_LOCKED=1 run "$SUT" "$item"
	expect_status 1
	expect_err 'locked'
	expect_err 'ai-unlock'
	[[ "$(cat "$rec/rbw.calls")" == '[unlocked]' ]] || {
		echo "  rbw was asked more than whether it is unlocked: $(cat "$rec/rbw.calls")"
		return 1
	}
	[[ ! -s "$rec/sudo.calls" ]] || {
		echo "  sudo ran with a locked vault"
		return 1
	}
}

it_says_so_when_rbw_is_missing() {
	capture env -i PATH="$nobin:$tools" HOME="$scratch/home" "$SUT" "$item"
	expect_status 1
	expect_err 'rbw is not installed'
}

it_stops_at_a_field_rbw_cannot_read_and_names_it() {
	local f
	for f in username notes password; do
		# The failing rbw writes the value to stderr; the helper throws that
		# away.
		RBW_FAIL="$f" run "$SUT" "$item"
		expect_status 1
		expect_err "cannot read the $f of"
		no_secret_in "stderr" "$err"
		no_secret_in "stdout" "$out"
		[[ ! -s "$rec/sudo.calls" ]] || {
			echo "  sudo ran although rbw failed on the $f"
			return 1
		}
	done
}

it_refuses_an_empty_field() {
	local f
	for f in username notes password; do
		with_field "$f" '' "$SUT" "$item"
		expect_status 1
		expect_err "the $f of"
		expect_err 'is empty'
		[[ ! -s "$rec/sudo.calls" ]] || {
			echo "  sudo ran with an empty $f"
			return 1
		}
	done
}

it_refuses_a_field_of_more_than_one_line_without_printing_it() {
	local f
	for f in username notes password; do
		with_field "$f" $'first-secret-line\nsecond-secret-line' "$SUT" "$item"
		expect_status 1
		expect_err "the $f of"
		expect_err 'more than one line'
		[[ "$out$err" != *secret-line* ]] || {
			echo "  the refusal printed a line of the field: $out $err"
			return 1
		}
		[[ ! -s "$rec/sudo.calls" ]] || {
			echo "  sudo ran with a $f of two lines"
			return 1
		}
	done
}

it_passes_on_a_failed_sudo() {
	SUDO_RC=1 run "$SUT" "$item"
	expect_status 1
	[[ ! -s "$rec/atuin.calls" ]] || {
		echo "  atuin ran although sudo failed"
		return 1
	}
	no_secret_in "stderr" "$err"
	no_secret_in "stdout" "$out"
}

it_passes_on_a_failed_login_without_syncing_or_leaking() {
	ATUIN_LOGIN_RC=3 run "$SUT" "$item"
	expect_status 3
	[[ "$(cat "$rec/atuin.calls")" == '[login][--username=sync-user][-p][-]' ]] || {
		echo "  atuin was called as: $(cat "$rec/atuin.calls")"
		return 1
	}
	no_secret_in "stderr" "$err"
	no_secret_in "stdout" "$out"
}

it_reports_a_failed_first_sync() {
	ATUIN_SYNC_RC=4 run "$SUT" "$item"
	expect_status 4
}

it_refuses_usage_mistakes_before_it_reads_anything() {
	local args
	for args in "" "--bogus" "-x" "a b" "--as-root-not"; do
		# shellcheck disable=SC2086 # the words are the point
		if [[ -z "$args" ]]; then helper; else helper $args; fi
		expect_status 2
		expect_err 'usage:'
	done
	[[ ! -s "$rec/rbw.calls" ]] || {
		echo "  rbw was asked after a usage mistake"
		return 1
	}
	helper --help
	expect_status 0
	expect_out 'usage:'
}

it_does_not_run_the_root_half_as_a_normal_user() {
	# The shell of the build is no root, and the id on the PATH says it is: the
	# helper goes by $EUID. Nothing is read from the input or run.
	rm -f "$rec/id.ran"
	capture env -i PATH="$bin:$tools" HOME="$scratch/home" REC="$rec" \
		"$BASH" -c 'printf "u\nk\np\n" | "$1" --as-root' _ "$SUT"
	expect_status 1
	expect_err 'for sudo to start'
	[[ ! -s "$rec/atuin.calls" ]] || {
		echo "  atuin ran as a normal user"
		return 1
	}
}

it_goes_by_euid_and_never_asks_id() {
	# The id on the PATH says 0 and leaves a mark. The user half and the root
	# half must neither run it nor believe it.
	helper "$item"
	expect_status 0
	[[ ! -e "$rec/id.ran" ]] || {
		echo "  the helper ran id from the PATH"
		return 1
	}
	rm -f "$rec/id.ran"
	capture env -i PATH="$bin:$tools" HOME="$scratch/home" REC="$rec" \
		"$BASH" -c 'printf "u\nk\np\n" | "$1" --as-root' _ "$SUT"
	expect_status 1
	[[ ! -e "$rec/id.ran" ]] || {
		echo "  the root half ran id from the PATH"
		return 1
	}
}

it_runs_sudo_on_its_own_store_path_whoever_started_it() {
	# A copy of the helper, in a directory the caller can write to, started by
	# its path and through bash, is what a caller could make sudo run as root
	# if the helper took its name from $0. It names its own store path.
	local want copy="$scratch/copy/atuin-root-login"
	want="$(readlink -f "$SUT")"
	mkdir -p "$scratch/copy"
	cp -- "$want" "$copy"
	chmod +x "$copy"
	run "$copy" "$item"
	expect_status 0
	[[ "$(cat "$rec/sudo.calls")" == "[--][$want][--as-root]" ]] || {
		echo "  sudo was called as: $(cat "$rec/sudo.calls")"
		return 1
	}
	run "$BASH" "$copy" "$item"
	expect_status 0
	[[ "$(cat "$rec/sudo.calls")" == "[--][$want][--as-root]" ]] || {
		echo "  through bash, sudo was called as: $(cat "$rec/sudo.calls")"
		return 1
	}
	case "$want" in /nix/store/*) ;; *)
		echo "  the helper under test is not a store path: $want"
		return 1 ;;
	esac
}

it_stops_the_root_half_on_a_short_input() {
	local input
	for input in "" "only-a-user\n"; do
		: >"$rec/atuin.calls"
		capture env -i PATH="$bin:$tools" HOME="$scratch/home" REC="$rec" \
			unshare -Ur -- "$BASH" -c 'printf "$2" | "$1" --as-root' _ "$SUT" "$input"
		expect_status 1
		[[ ! -s "$rec/atuin.calls" ]] || {
			echo "  atuin ran on the input [$input]"
			return 1
		}
	done
}

it_makes_what_atuin_creates_private_to_root() {
	# The caller's umask is open; the root half closes it before atuin runs,
	# so atuin's key file and database are not made readable by others.
	umask 022
	helper "$item"
	expect_status 0
	[[ "$(stat -c %a "$rec/atuin.created")" == 600 ]] || {
		echo "  a file made by atuin has the mode $(stat -c %a "$rec/atuin.created"), not 600"
		return 1
	}
}

it_leaves_what_sudo_kept_out_of_atuin() {
	# sudo may keep the caller's variables; atuin must look at root's home.
	run env XDG_CONFIG_HOME=/home/other/.config XDG_DATA_HOME=/home/other/.local/share \
		ATUIN_CONFIG_DIR=/home/other/atuin ATUIN_PASSWORD=from-the-environment \
		ATUIN_SESSION=session HOME=/home/other "$SUT" "$item"
	expect_status 0
	local env
	env="$(cat "$rec/atuin.env")"
	for v in XDG_CONFIG_HOME XDG_DATA_HOME ATUIN_CONFIG_DIR ATUIN_PASSWORD ATUIN_SESSION; do
		[[ "$env" != *"$v="* ]] || {
			echo "  atuin got $v from the caller"
			return 1
		}
	done
	[[ "$(cat "$rec/atuin.home")" == /root ]] || {
		echo "  atuin's HOME is $(cat "$rec/atuin.home")"
		return 1
	}
}

# The contract with the real atuin: `-p -` reads the password from the
# standard input, ATUIN_ENCRYPTION_KEY is the key, and ATUIN_SYNC_ADDRESS the
# server. The server is a one-shot listener in the sandbox that records the
# login request, so the test sees the password that arrives, with the spaces at
# its ends, and not only that no prompt opened. $real_login is the command
# under test: the same flags as the helper's, with the password argument
# `-p -`; the test shows below what a literal one would do.
real_login() { # real_login HOME PASSWORD_ARGUMENT KEY: password on stdin
	local h="$1" arg="$2" key="$3"
	printf '%s\n' "$stdin_password" |
		env -i PATH="$tools" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
			ATUIN_SYNC_ADDRESS="http://127.0.0.1:$port" ATUIN_ENCRYPTION_KEY="$key" \
			timeout 60 "$real_atuin" login --username=someone -p "$arg" >/dev/null 2>&1 || true
}
real_key() { # a 24-word key from a fresh atuin home
	local h="$scratch/real-key-home"
	mkdir -p "$h/.config/atuin"
	printf 'auto_sync = false\nupdate_check = false\n' >"$h/.config/atuin/config.toml"
	local session
	session="$(env -i PATH="$tools" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" "$real_atuin" uuid)"
	env -i PATH="$tools" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" ATUIN_SESSION="$session" \
		"$real_atuin" history list >/dev/null 2>&1 || true
	env -i PATH="$tools" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" "$real_atuin" key
}
# Starts the listener and waits for it; the request log is $scratch/requests.
listen() {
	rm -f "$scratch/requests" "$scratch/listening"
	python3 -I "$here/listener.py" "$port" "$scratch/requests" "$scratch/listening" &
	listener=$!
	local n
	for n in $(seq 1 100); do
		[[ -e "$scratch/listening" ]] && return 0
		sleep 0.1
	done
	echo "  the listener did not start"
	return 1
}
port=18765
stdin_password='  a password with  spaces  '

it_works_against_the_real_atuin() {
	local key h="$scratch/real-login-home"
	key="$(real_key)"
	[[ "$(printf '%s' "$key" | wc -w)" == 24 ]] || {
		echo "  the real atuin made no 24-word key: $key"
		return 1
	}
	mkdir -p "$h/.config/atuin"
	# No sync_address in the file: the environment names the server.
	printf 'auto_sync = false\nupdate_check = false\n' >"$h/.config/atuin/config.toml"
	listen
	real_login "$h" - "$key"
	wait "$listener" || true
	[[ -s "$scratch/requests" ]] || {
		echo "  the login never reached the listener"
		return 1
	}
	local want
	want="$(printf '{"method": "POST", "path": "/login", "body": "{\\"username\\":\\"someone\\",\\"password\\":\\"%s\\"}"}' "$stdin_password")"
	[[ "$(head -n1 "$scratch/requests")" == "$want" ]] || {
		echo "  the login request is not the user name and the password from the standard input"
		echo "  got:  $(head -n1 "$scratch/requests")"
		echo "  want: $want"
		return 1
	}
	# The key reached atuin through the environment.
	local stored
	stored="$(env -i PATH="$tools" HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" "$real_atuin" key)"
	[[ "$stored" == "$key" ]] || {
		echo "  the stored key is not the one from ATUIN_ENCRYPTION_KEY"
		return 1
	}
}

# The test above would pass for a literal password that equals the one on the
# standard input; this one shows that it can fail: a literal `-p` argument
# makes the request carry that word and not the standard input.
it_sees_a_password_that_does_not_come_from_stdin() {
	local key h="$scratch/real-literal-home"
	key="$(real_key)"
	mkdir -p "$h/.config/atuin"
	printf 'auto_sync = false\nupdate_check = false\n' >"$h/.config/atuin/config.toml"
	listen
	real_login "$h" literal-not-stdin "$key"
	wait "$listener" || true
	[[ "$(head -n1 "$scratch/requests")" == *literal-not-stdin* ]] || {
		echo "  a literal password did not reach the listener as it is: $(head -n1 "$scratch/requests")"
		return 1
	}
	[[ "$(head -n1 "$scratch/requests")" != *"$stdin_password"* ]] || {
		echo "  the standard input reached the listener beside a literal password"
		return 1
	}
}

tests=(
	it_logs_in_with_the_password_on_stdin_and_the_key_in_the_environment
	it_reads_the_three_fields_of_the_item_through_rbw
	it_starts_the_root_half_through_sudo_by_its_own_path
	it_puts_no_secret_on_a_command_line
	it_keeps_the_secrets_out_of_sudos_environment
	it_writes_no_file
	it_prints_no_secret_even_when_traced
	it_hands_over_values_that_look_like_options_or_shell_syntax
	it_trims_the_notes_but_keeps_the_key_inside
	it_keeps_the_spaces_at_the_ends_of_the_password_and_the_user_name
	it_refuses_a_locked_vault_without_asking_for_anything
	it_says_so_when_rbw_is_missing
	it_stops_at_a_field_rbw_cannot_read_and_names_it
	it_refuses_an_empty_field
	it_refuses_a_field_of_more_than_one_line_without_printing_it
	it_passes_on_a_failed_sudo
	it_passes_on_a_failed_login_without_syncing_or_leaking
	it_reports_a_failed_first_sync
	it_refuses_usage_mistakes_before_it_reads_anything
	it_does_not_run_the_root_half_as_a_normal_user
	it_goes_by_euid_and_never_asks_id
	it_runs_sudo_on_its_own_store_path_whoever_started_it
	it_stops_the_root_half_on_a_short_input
	it_makes_what_atuin_creates_private_to_root
	it_leaves_what_sudo_kept_out_of_atuin
	it_works_against_the_real_atuin
	it_sees_a_password_that_does_not_come_from_stdin
)
run_tests "${tests[@]}"
