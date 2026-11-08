#!/usr/bin/env bash
# shellcheck disable=SC2016
# Tests for charge-mode (packages/charge-mode), run by the check
# bin-charge-mode: the user's command charge-mode, its root helper
# charge-mode-apply, which the one-command sudo rule lets the user run, and
# charge-mode-restore, which the boot unit runs.
#
# Each script runs as a copy whose fixed paths point into the scratch
# directory: the battery's charge_types, the saved mode in /var/lib, and the
# helper the other two call. The copy is the script with only those strings
# replaced, and a test fails when one of them is still in it, so no case
# touches the real battery or the real state file. sudo, notify-send, pkill
# and sleep are stubs that log their calls; the sudo stub runs the helper as
# the test's own user. The last tests check the package: each command is its
# script, the two root scripts see only the store's tools, and the helper
# both others call is the package's own.
#
#   SOURCES=  packages/charge-mode, where the three scripts are
#   PACKAGE=  the built package
#   TEST_LIB= scripts/tests/lib.sh

# (SC2016 above: the stub bodies are written in single quotes on purpose.)
# shellcheck source=scripts/tests/lib.sh
source "${TEST_LIB:?TEST_LIB names scripts/tests/lib.sh}"
: "${SOURCES:?SOURCES names packages/charge-mode}" "${PACKAGE:?PACKAGE names the built package}"

bin="$scratch/bin"
calls="$scratch/calls"
# The runner's output, for a case that skips to say so.
exec 3>&1
sys="$scratch/fake-sysfs"
attr="$sys/BAT0/charge_types"
state="$scratch/state/charge-mode"
cm="$scratch/charge-mode"
apply="$scratch/charge-mode-apply"
restore="$scratch/charge-mode-restore"

# sudo: SUDO_SAYS is sudo's own refusal, printed before it fails, as sudo
# does for a missing rule or when it is not setuid; SUDO_FAILS fails mute.
write_script "$bin/sudo" \
	'printf "sudo %s\n" "$*" >>"$CALLS"' \
	'[ -z "${SUDO_SAYS:-}" ] || { printf "%s\n" "$SUDO_SAYS" >&2; exit 1; }' \
	'[ -z "${SUDO_FAILS:-}" ] || exit 1' \
	'[ "$1" = -n ] && shift' \
	'exec "$@"'
write_script "$bin/notify-send" 'printf "notify-send %s\n" "$*" >>"$CALLS"'
write_script "$bin/pkill" 'printf "pkill %s\n" "$*" >>"$CALLS"'
# sleep makes charge_types appear at its APPEAR_AT-th call, as ideapad_laptop
# binding late at boot would.
write_script "$bin/sleep" \
	'n=$(($(cat "$SLEEPS" 2>/dev/null || echo 0) + 1)); echo "$n" >"$SLEEPS"' \
	'if [ "$n" = "${APPEAR_AT:-}" ]; then mkdir -p "$(dirname "$ATTR")"; echo "Fast Standard [Long_Life]" >"$ATTR"; fi'
# The call that makes Waybar redraw its battery module: by the process name,
# the plain one or the one NixOS's wrapper gives it, of the user's own.
refresh_bar="pkill -RTMIN+10 -u $EUID -x waybar|\\.waybar-wrapped"
# A helper that only logs, for the cases about who calls it with what.
write_script "$scratch/stub-apply" 'printf "apply %s\n" "$*" >>"$CALLS"'

# copy SCRIPT DEST HELPER: SCRIPT with its fixed paths in the scratch
# directory and HELPER where it names charge-mode-apply. The scratch paths
# hold neither "/sys/" nor "/var/lib", so a path left real shows.
copy() {
	# The sandbox has no /usr/bin/env, so the copy starts with the bash that
	# runs the tests.
	sed -e "1s|^#!.*|#!$BASH|" \
		-e "s|/sys/class/power_supply/BAT0|$sys/BAT0|g" \
		-e "s|/var/lib/charge-mode|$state|g" \
		-e "s|@apply@|$3|g" "$SOURCES/$1" >"$2"
	chmod +x "$2"
	# Comments may name the real paths; code must not.
	if grep -Ev '^[[:space:]]*#' "$2" | grep -Eq '/sys/|/var/lib|@apply@'; then
		echo "  the copy of $1 still names a real path or the placeholder:"
		grep -Ev '^[[:space:]]*#' "$2" | grep -E '/sys/|/var/lib|@apply@'
		return 1
	fi
}

# firmware [TEXT]: charge_types as the kernel shows it; no argument, none.
firmware() {
	rm -rf -- "$sys"
	if (($# > 0)); then
		mkdir -p "$(dirname "$attr")"
		printf '%s\n' "$1" >"$attr"
	fi
}

# saved [MODE]: the saved boot mode; no argument, none.
saved() {
	rm -rf -- "$(dirname "$state")"
	mkdir -p "$(dirname "$state")"
	(($# == 0)) || printf '%s\n' "$1" >"$state"
}

run() {
	local script="$1"
	shift
	: >"$calls"
	rm -f -- "$scratch/sleeps"
	capture env PATH="$bin:$PATH" CALLS="$calls" SLEEPS="$scratch/sleeps" ATTR="$attr" \
		"$BASH" "$script" "$@"
}

calls_are() {
	local want got
	want="$(printf '%s\n' "$@")"
	got="$(cat "$calls")"
	[[ "$got" == "$want" ]] || {
		echo "  expected the calls:"
		printf '    %s\n' "$@"
		echo "  got:"
		sed 's/^/    /' "$calls"
		return 1
	}
}
no_calls() {
	[[ ! -s "$calls" ]] || {
		echo "  expected no calls, got:"
		sed 's/^/    /' "$calls"
		return 1
	}
}
content_is() {
	local got
	got="$(cat "$1" 2>/dev/null || echo "<no file>")"
	[[ "$got" == "$2" ]] || {
		echo "  expected $1 to hold '$2', got '$got'"
		return 1
	}
}

user_stub() { copy charge-mode.sh "$cm" "$scratch/stub-apply"; }
user_real() {
	copy charge-mode-apply.sh "$apply" unused
	copy charge-mode.sh "$cm" "$apply"
}

# charge-mode: reading.

test_show_prints_the_bracketed_mode() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm"
	expect_status 0
	[[ "$out" == Long_Life ]] || { echo "  got '$out'"; return 1; }
	run "$cm" show
	[[ "$out" == Long_Life ]]
	run "$cm" status
	[[ "$out" == Long_Life ]]
}

test_show_finds_the_mode_anywhere_in_the_list() {
	user_stub
	firmware "Fast [Standard] Long_Life"
	run "$cm"
	[[ "$out" == Standard ]] || { echo "  got '$out'"; return 1; }
	firmware "[Fast] Standard Long_Life"
	run "$cm"
	[[ "$out" == Fast ]]
}

test_show_says_unknown_without_brackets() {
	user_stub
	firmware "Fast Standard Long_Life"
	run "$cm"
	expect_status 0
	[[ "$out" == unknown ]] || { echo "  got '$out'"; return 1; }
}

test_show_says_unknown_for_an_empty_attribute() {
	user_stub
	firmware ""
	run "$cm"
	[[ "$out" == unknown ]] || { echo "  got '$out'"; return 1; }
}

test_modes_lists_what_the_firmware_offers() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm" modes
	expect_status 0
	[[ "$out" == $'Fast\nStandard\nLong_Life' ]] || { echo "  got '$out'"; return 1; }
}

test_modes_follows_the_firmware_not_a_list() {
	user_stub
	firmware "[Standard] Adaptive"
	run "$cm" modes
	[[ "$out" == $'Standard\nAdaptive' ]] || { echo "  got '$out'"; return 1; }
}

test_without_charge_types_every_command_does_nothing() {
	user_stub
	firmware
	local args
	for args in "" show cycle "set Fast" default "default Fast" modes help bogus; do
		# shellcheck disable=SC2086
		run "$cm" $args
		expect_status 0
		expect_err "nothing to do"
		no_calls
	done
}

# charge-mode: writing goes through the helper, with sudo -n.

test_cycle_goes_long_life_standard_fast() {
	user_stub
	local from to
	for from in "Fast Standard [Long_Life]:Standard" "Fast [Standard] Long_Life:Fast" "[Fast] Standard Long_Life:Long_Life" "Fast Standard Long_Life:Long_Life"; do
		to="${from##*:}"
		firmware "${from%:*}"
		run "$cm" cycle
		expect_status 0
		calls_are "sudo -n $scratch/stub-apply $to" "apply $to" \
			"notify-send -a charge-mode Charge mode: $to $(describe "$to")" \
			"$refresh_bar"
		[[ "$out" == "$to" ]] || { echo "  printed '$out', not $to"; return 1; }
	done
}

describe() {
	case "$1" in
	Long_Life) echo "Parks the cell; the PSU carries the machine. Refills only to the EC ceiling." ;;
	Standard) echo "Charges to 100% at the normal rate." ;;
	Fast) echo "Charges to 100% rapidly. Hardest of the three on the cell." ;;
	esac
}

test_set_calls_the_helper_with_the_mode() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm" set Fast
	expect_status 0
	calls_are "sudo -n $scratch/stub-apply Fast" "apply Fast" \
		"notify-send -a charge-mode Charge mode: Fast $(describe Fast)" \
		"$refresh_bar"
}

test_set_without_a_mode_lists_the_offer() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm" set
	expect_status 2
	expect_err "Offered now: Fast Standard Long_Life"
	no_calls
}

test_set_leaves_validation_to_the_helper() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm" set Bogus
	calls_are "sudo -n $scratch/stub-apply Bogus" "apply Bogus" \
		"notify-send -a charge-mode Charge mode: Bogus " \
		"$refresh_bar"
}

# A failing sudo: the message is the real cause, sudo's own words or the
# helper's, with a hint only where the cause is known, and the same in a
# critical notification, since a Waybar click shows no terminal.

test_a_missing_sudo_rule_is_named() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	SUDO_SAYS="sudo: a password is required" run "$cm" set Standard
	expect_status 1
	expect_err "sudo: a password is required"
	expect_err "charge-mode: no sudo rule lets you run the helper without a password; the hardware module's battery.nix gives it."
	calls_are "sudo -n $scratch/stub-apply Standard" \
		"notify-send -a charge-mode -u critical Charge mode not changed sudo: a password is required no sudo rule lets you run the helper without a password; the hardware module's battery.nix gives it."
}

test_a_sudo_without_setuid_is_named() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	SUDO_SAYS="sudo: /run/current-system/sw/bin/sudo must be owned by uid 0 and have the setuid bit set" \
		run "$cm" set Standard
	expect_status 1
	expect_err "sudo: /run/current-system/sw/bin/sudo must be owned by uid 0 and have the setuid bit set"
	expect_err "charge-mode: this sudo is not the setuid one; on NixOS that is /run/wrappers/bin/sudo, which the PATH must name first."
	expect_no_err "sudo rule"
	SUDO_SAYS="sudo: effective uid is not 0, is sudo installed setuid root?" run "$cm" set Standard
	expect_status 1
	expect_err "this sudo is not the setuid one"
}

test_no_sudo_on_the_path_is_named() {
	# Outside the sandbox the system's sudo is on the PATH, so the case
	# means something only in the check, which has none. A skip says so on
	# the runner's own output (fd 3), which the test's log does not swallow.
	if command -v sudo >/dev/null 2>&1; then
		echo "SKIP test_no_sudo_on_the_path_is_named: $(command -v sudo) is on the PATH; only the sandbox has none" >&3
		return 0
	fi
	user_stub
	firmware "Fast Standard [Long_Life]"
	mv "$bin/sudo" "$scratch/sudo.away"
	run "$cm" set Standard
	mv "$scratch/sudo.away" "$bin/sudo"
	expect_status 1
	expect_err "charge-mode: no sudo on the PATH; on NixOS the setuid one is /run/wrappers/bin/sudo."
	[[ "$(cat "$calls")" != *"apply"* ]] || { echo "  the helper ran"; return 1; }
}

test_a_mute_sudo_failure_says_so() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	SUDO_FAILS=1 run "$cm" set Standard
	expect_status 1
	expect_err "charge-mode: sudo or the helper failed without a message."
	expect_no_err "sudo rule"
	calls_are "sudo -n $scratch/stub-apply Standard" \
		"notify-send -a charge-mode -u critical Charge mode not changed charge-mode: sudo or the helper failed without a message."
}

test_a_missing_helper_fails_before_sudo() {
	copy charge-mode.sh "$cm" "$scratch/no-such-helper"
	firmware "Fast Standard [Long_Life]"
	run "$cm" set Standard
	expect_status 1
	expect_err "$scratch/no-such-helper is missing"
	no_calls
}

test_default_prints_the_saved_mode() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$cm" default
	expect_status 0
	[[ "$out" == Long_Life ]] || { echo "  got '$out'"; return 1; }
	saved
	run "$cm" default
	[[ "$out" == "(nothing saved)" ]] || { echo "  got '$out'"; return 1; }
}

test_default_with_a_mode_saves_only() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	run "$cm" default Standard
	expect_status 0
	calls_are "sudo -n $scratch/stub-apply --save-only Standard" "apply --save-only Standard" \
		"notify-send -a charge-mode Charge mode at boot: Standard The live mode is unchanged (Long_Life)."
	[[ "$out" == Standard ]]
}

test_default_with_a_refused_sudo_fails() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	SUDO_SAYS="sudo: a password is required" run "$cm" default Standard
	expect_status 1
	expect_err "sudo: a password is required"
	expect_err "no sudo rule lets you run the helper"
	[[ "$out" != Standard ]] || { echo "  printed the mode as if saved"; return 1; }
}

test_help_and_unknown_commands() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	local h
	for h in help -h --help; do
		run "$cm" "$h"
		expect_status 0
		expect_out "charge-mode default <m>  set the boot mode, leaving the live one alone"
	done
	run "$cm" bogus
	expect_status 2
	expect_err "unknown command 'bogus'"
	no_calls
}

test_no_notification_without_notify_send() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	mv "$bin/notify-send" "$scratch/notify-send.away"
	run "$cm" set Fast
	mv "$scratch/notify-send.away" "$bin/notify-send"
	expect_status 0
	calls_are "sudo -n $scratch/stub-apply Fast" "apply Fast" "$refresh_bar"
}

# charge-mode and the real helper together, as the sudo rule runs them.

test_set_writes_the_attribute_and_the_saved_mode() {
	user_real
	firmware "Fast Standard [Long_Life]"
	saved
	run "$cm" set Standard
	expect_status 0
	content_is "$attr" Standard
	content_is "$state" Standard
}

test_default_writes_only_the_saved_mode() {
	user_real
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$cm" default Fast
	expect_status 0
	content_is "$attr" "Fast Standard [Long_Life]"
	content_is "$state" Fast
}

test_set_with_a_refused_mode_writes_nothing() {
	user_real
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$cm" set Bogus
	expect_status 1
	expect_err "'Bogus' is not offered by this firmware"
	expect_err "offered: Fast Standard Long_Life"
	# The helper's own refusal is the cause; no hint about sudo.
	expect_no_err "sudo"
	content_is "$attr" "Fast Standard [Long_Life]"
	content_is "$state" Long_Life
}

# running PID: the process is there and no zombie. kill -0 passes a zombie
# too, so it reads the state in /proc/PID/stat, after the name in brackets.
running() {
	local stat
	stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
	stat="${stat##*) }"
	[[ -n "$stat" && "${stat%% *}" != Z ]]
}

# The Waybar refresh, against real processes and the real pkill: it reaches
# Waybar under the name NixOS's wrapper gives the process (.waybar-wrapped)
# and under the plain one, and nothing else: not waybar-launch, not a
# helper whose name starts with waybar, not a program that only calls
# itself waybar in its argv.
test_the_refresh_reaches_a_wrapped_waybar_and_nothing_else() {
	user_stub
	firmware "Fast Standard [Long_Life]"
	local d="$scratch/procs" name st i want
	local -A pid=()
	rm -rf -- "$d"
	mkdir -p "$d"
	mkfifo "$d/fifo"
	# Each reads the FIFO for up to 60 s; a signal it does not handle ends it.
	for name in .waybar-wrapped waybar waybar-launch waybar-powerdraw not-waybar; do
		cp -- "$BASH" "$d/$name"
	done
	for name in .waybar-wrapped waybar waybar-launch waybar-powerdraw; do
		"$d/$name" -c 'read -r -t 60 _ <>"$0"' "$d/fifo" &
		pid[$name]=$!
	done
	(exec -a waybar "$d/not-waybar" -c 'read -r -t 60 _ <>"$0"' "$d/fifo") &
	pid[not-waybar]=$!
	for name in "${!pid[@]}"; do
		for ((i = 0; i < 200; i++)); do
			[[ "$(cat "/proc/${pid[$name]}/comm" 2>/dev/null)" == "${name:0:15}" ]] && break
			sleep 0.01
		done
	done
	mv "$bin/pkill" "$scratch/pkill.away"
	run "$cm" set Fast
	mv "$scratch/pkill.away" "$bin/pkill"
	expect_status 0
	want=$((128 + $(kill -l RTMIN+10)))
	for name in .waybar-wrapped waybar; do
		st=0
		wait "${pid[$name]}" || st=$?
		[[ "$st" == "$want" ]] || {
			echo "  $name ended with $st, not by SIGRTMIN+10 ($want)"
			kill "${pid[@]}" 2>/dev/null || true
			return 1
		}
	done
	for name in waybar-launch waybar-powerdraw not-waybar; do
		running "${pid[$name]}" || {
			echo "  the refresh signalled $name"
			kill "${pid[@]}" 2>/dev/null || true
			return 1
		}
		kill "${pid[$name]}"
		wait "${pid[$name]}" || true
	done
}

# charge-mode-apply: the security boundary of the sudo rule. It writes only
# a mode the kernel offers, to its two fixed paths.

helper() { copy charge-mode-apply.sh "$apply" unused; }

test_apply_writes_the_mode_and_saves_it() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved
	run "$apply" Fast
	expect_status 0
	# charge_types gets the mode without a newline, as a sysfs write wants.
	[[ "$(od -An -c "$attr" | tr -d ' ')" == Fast ]] || { echo "  wrote '$(od -An -c "$attr")'"; return 1; }
	content_is "$state" Fast
}

test_apply_save_only_leaves_the_live_mode() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$apply" --save-only Standard
	expect_status 0
	content_is "$attr" "Fast Standard [Long_Life]"
	content_is "$state" Standard
}

test_apply_refuses_what_the_firmware_does_not_offer() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	local mode
	for mode in Bogus long_life "[Long_Life]" "Long_Life Fast" "Long_Life " "*" "?ast" "-n" "Fast;id" "../Fast"; do
		run "$apply" "$mode"
		expect_status 2
		expect_err "is not offered by this firmware"
		expect_err "offered: Fast Standard Long_Life"
		content_is "$attr" "Fast Standard [Long_Life]"
		content_is "$state" Long_Life
		run "$apply" --save-only "$mode"
		expect_status 2
		content_is "$state" Long_Life
	done
}

test_apply_needs_a_mode() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$apply"
	expect_status 2
	expect_err "no mode given"
	run "$apply" ""
	expect_status 2
	run "$apply" --save-only
	expect_status 2
	expect_err "no mode given"
	content_is "$state" Long_Life
}

test_apply_without_charge_types_fails() {
	helper
	firmware
	saved Long_Life
	run "$apply" Fast
	expect_status 1
	expect_err "no $attr"
	content_is "$state" Long_Life
}

test_apply_saves_nothing_when_the_write_fails() {
	# root writes a read-only file, so the case means nothing for root.
	((EUID != 0)) || return 0
	helper
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	chmod 444 "$attr"
	run "$apply" Fast
	chmod 644 "$attr"
	[[ "$status" != 0 ]] || { echo "  exit 0 although the write failed"; return 1; }
	content_is "$state" Long_Life
}

test_apply_takes_only_its_first_argument() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved
	run "$apply" Fast /tmp/elsewhere
	expect_status 0
	content_is "$state" Fast
	[[ ! -e /tmp/elsewhere ]]
}

test_apply_huge_mode_is_refused() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	run "$apply" "$(head -c 100000 /dev/zero | tr '\0' x)"
	expect_status 2
	content_is "$state" Long_Life
}

# Two clicks at once must leave one whole mode saved, never a torn file
# ("Fast" over "Standard" reads "Fast\nard") that the boot restore would then
# refuse. --save-only, since the fake charge_types is a plain file that the
# first live write would replace; the saved mode is written the same way
# either way. A tear needs one write to land inside the other: it came in
# about 4 of 100 rounds with a plain redirect, so 200 rounds find it.
test_two_applies_at_once_leave_one_mode() {
	helper
	firmware "Fast Standard [Long_Life]"
	saved
	local got round
	for round in $(seq 200); do
		env PATH="$bin:$PATH" "$BASH" "$apply" --save-only Fast &
		env PATH="$bin:$PATH" "$BASH" "$apply" --save-only Standard &
		wait
		got="$(cat "$state")"
		[[ "$got" == Fast || "$got" == Standard ]] || {
			echo "  round $round saved '$got'"
			return 1
		}
	done
	# No temporary file is left beside the saved mode.
	[[ "$(find "$(dirname "$state")" -mindepth 1 | wc -l)" == 1 ]] || {
		echo "  left beside the saved mode:"
		ls -a "$(dirname "$state")"
		return 1
	}
}

# charge-mode-restore: at boot, the saved mode through the helper.

restorer() { copy charge-mode-restore.sh "$restore" "$scratch/stub-apply"; }

test_restore_applies_the_saved_mode() {
	restorer
	firmware "Fast [Standard] Long_Life"
	saved Long_Life
	run "$restore"
	expect_status 0
	calls_are "apply Long_Life"
}

test_restore_without_a_saved_mode_does_nothing() {
	restorer
	firmware "Fast Standard [Long_Life]"
	saved
	run "$restore"
	expect_status 0
	no_calls
}

test_restore_with_an_empty_saved_mode_does_nothing() {
	restorer
	firmware "Fast Standard [Long_Life]"
	saved
	: >"$state"
	run "$restore"
	expect_status 0
	no_calls
}

test_restore_with_an_unreadable_saved_mode_does_nothing() {
	((EUID != 0)) || return 0
	restorer
	firmware "Fast Standard [Long_Life]"
	saved Long_Life
	chmod 000 "$state"
	run "$restore"
	chmod 644 "$state"
	expect_status 0
	no_calls
}

test_restore_waits_for_a_late_attribute() {
	restorer
	firmware
	saved Long_Life
	APPEAR_AT=3 run "$restore"
	expect_status 0
	calls_are "apply Long_Life"
	content_is "$scratch/sleeps" 3
}

test_restore_gives_up_after_ten_seconds() {
	restorer
	firmware
	saved Long_Life
	run "$restore"
	expect_status 0
	expect_err "never appeared"
	no_calls
	# 20 waits of half a second.
	content_is "$scratch/sleeps" 20
}

test_restore_passes_the_mode_on_unchecked() {
	restorer
	firmware "Fast Standard [Long_Life]"
	saved "Bogus"
	run "$restore"
	calls_are "apply Bogus"
}

# The package: the three commands are these scripts, the helper both others
# call is the package's own, and the two that run as root see the store's
# tools only.

# The body of a writeShellApplication script: what follows its PATH line,
# between an empty line of its own on either side.
body() { awk 'body; /^export PATH=/ { body = 1 }' "$1" | sed '1{/^$/d}; ${/^$/d}'; }

test_package_commands_are_these_scripts() {
	local name helper_path
	helper_path="$(readlink -f "$PACKAGE/bin/charge-mode-apply")"
	for name in charge-mode charge-mode-apply charge-mode-restore; do
		[[ -x "$PACKAGE/bin/$name" ]] || { echo "  no $name in the package"; return 1; }
		diff <(tail -n +2 "$SOURCES/$name.sh" | sed "s|@apply@|$helper_path|g") <(body "$PACKAGE/bin/$name") || {
			echo "  $name is not its script with the package's helper"
			return 1
		}
	done
}

test_package_root_scripts_see_only_the_store() {
	local name line
	for name in charge-mode-apply charge-mode-restore; do
		line="$(grep -m1 '^export PATH=' "$PACKAGE/bin/$name")"
		[[ "$line" != *'$PATH'* ]] || {
			echo "  $name inherits the caller's PATH: $line"
			return 1
		}
	done
}

test_package_user_command_keeps_the_callers_path() {
	# sudo is the setuid wrapper on the caller's PATH, never a store copy.
	local line
	line="$(grep -m1 '^export PATH=' "$PACKAGE/bin/charge-mode")"
	[[ "$line" == *':$PATH"' ]] || { echo "  $line"; return 1; }
	! grep -q '/nix/store/[^/]*sudo' "$PACKAGE/bin/charge-mode"
}

test_package_paths_hold_the_tools() {
	local name line path tools
	for name in charge-mode:"cat tr sed pkill notify-send" charge-mode-apply:"cat tr" charge-mode-restore:"cat sleep"; do
		tools="${name#*:}"
		line="$(grep -m1 '^export PATH=' "$PACKAGE/bin/${name%%:*}")"
		path="${line#export PATH=\"}"
		path="${path%\"}"
		path="${path%:\$PATH}"
		# shellcheck disable=SC2086
		capture env -i PATH="$path" "$BASH" -c "command -v $tools"
		expect_status 0
	done
}

tests=(
	test_show_prints_the_bracketed_mode
	test_show_finds_the_mode_anywhere_in_the_list
	test_show_says_unknown_without_brackets
	test_show_says_unknown_for_an_empty_attribute
	test_modes_lists_what_the_firmware_offers
	test_modes_follows_the_firmware_not_a_list
	test_without_charge_types_every_command_does_nothing
	test_cycle_goes_long_life_standard_fast
	test_set_calls_the_helper_with_the_mode
	test_set_without_a_mode_lists_the_offer
	test_set_leaves_validation_to_the_helper
	test_a_missing_sudo_rule_is_named
	test_a_sudo_without_setuid_is_named
	test_no_sudo_on_the_path_is_named
	test_a_mute_sudo_failure_says_so
	test_a_missing_helper_fails_before_sudo
	test_default_prints_the_saved_mode
	test_default_with_a_mode_saves_only
	test_default_with_a_refused_sudo_fails
	test_help_and_unknown_commands
	test_no_notification_without_notify_send
	test_set_writes_the_attribute_and_the_saved_mode
	test_default_writes_only_the_saved_mode
	test_set_with_a_refused_mode_writes_nothing
	test_the_refresh_reaches_a_wrapped_waybar_and_nothing_else
	test_apply_writes_the_mode_and_saves_it
	test_apply_save_only_leaves_the_live_mode
	test_apply_refuses_what_the_firmware_does_not_offer
	test_apply_needs_a_mode
	test_apply_without_charge_types_fails
	test_apply_saves_nothing_when_the_write_fails
	test_apply_takes_only_its_first_argument
	test_apply_huge_mode_is_refused
	test_two_applies_at_once_leave_one_mode
	test_restore_applies_the_saved_mode
	test_restore_without_a_saved_mode_does_nothing
	test_restore_with_an_empty_saved_mode_does_nothing
	test_restore_with_an_unreadable_saved_mode_does_nothing
	test_restore_waits_for_a_late_attribute
	test_restore_gives_up_after_ten_seconds
	test_restore_passes_the_mode_on_unchecked
	test_package_commands_are_these_scripts
	test_package_root_scripts_see_only_the_store
	test_package_user_command_keeps_the_callers_path
	test_package_paths_hold_the_tools
)
run_tests "${tests[@]}"
