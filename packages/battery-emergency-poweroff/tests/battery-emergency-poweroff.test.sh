#!/usr/bin/env bash
# shellcheck disable=SC2016
# Tests for battery-emergency-poweroff (packages/battery-emergency-poweroff),
# run by the check bin-battery-emergency-poweroff.
#
# The script runs as it is, against a battery directory in the scratch
# directory, with stubs on the PATH for the four commands that act: logger,
# wall, sleep and systemctl log their arguments and do nothing else, so no
# case powers anything off. The sleep stub can also change the battery's
# status, as plugging in the charger during the warning does. The last tests
# check the package: the script is the one tested here, and its PATH is the
# store's tools and nothing inherited, since it runs as root.
#
#   SOURCE=  the script, packages/battery-emergency-poweroff/*.sh
#   PACKAGE= the built command
#   TEST_LIB= scripts/tests/lib.sh
#
# (SC2016 above: the stub bodies are written in single quotes on purpose.)

# shellcheck source=scripts/tests/lib.sh
source "${TEST_LIB:?TEST_LIB names scripts/tests/lib.sh}"
: "${SOURCE:?SOURCE names the script}" "${PACKAGE:?PACKAGE names the built command}"

bin="$scratch/bin"
calls="$scratch/calls"
bat="$scratch/BAT0"

write_script "$bin/logger" 'printf "logger %s\n" "$*" >>"$CALLS"; exit "${LOGGER_STATUS:-0}"'
write_script "$bin/wall" 'printf "wall %s\n" "$*" >>"$CALLS"; exit "${WALL_STATUS:-0}"'
write_script "$bin/sleep" \
	'printf "sleep %s\n" "$*" >>"$CALLS"' \
	'[ -z "${ON_SLEEP:-}" ] || printf "%s\n" "$ON_SLEEP" >"$BAT_DIR/status"'
write_script "$bin/systemctl" 'printf "systemctl %s\n" "$*" >>"$CALLS"'

# battery STATUS CAPACITY: a battery directory as sysfs shows it.
battery() {
	rm -rf -- "$bat"
	mkdir -p "$bat"
	printf '%s\n' "$1" >"$bat/status"
	printf '%s\n' "$2" >"$bat/capacity"
}

# Runs the script against $bat, or against the directory given.
run() {
	: >"$calls"
	capture env PATH="$bin:$PATH" CALLS="$calls" BAT_DIR="$bat" bash "$SOURCE" "${1:-$bat}"
}

expect_calls() {
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
expect_no_calls() {
	[[ ! -s "$calls" ]] || {
		echo "  expected no calls, got:"
		sed 's/^/    /' "$calls"
		return 1
	}
}

# The warning and the poweroff, in order, for capacity $1.
poweroff_calls() {
	expect_calls \
		"logger -t battery-emergency-poweroff battery at $1% and discharging, powering off in 10s" \
		"wall Battery at $1%: EMERGENCY POWEROFF in 10 seconds. Plug in AC now to abort." \
		"sleep 10" \
		"systemctl poweroff"
}

# The threshold is 3 %, inclusive, while discharging.

test_powers_off_at_3_percent() {
	battery Discharging 3
	run
	expect_status 0
	poweroff_calls 3
}

test_powers_off_at_1_percent() {
	battery Discharging 1
	run
	poweroff_calls 1
}

test_powers_off_at_0_percent() {
	battery Discharging 0
	run
	poweroff_calls 0
}

test_does_nothing_at_4_percent() {
	battery Discharging 4
	run
	expect_status 0
	expect_no_calls
}

test_does_nothing_at_50_percent() {
	battery Discharging 50
	run
	expect_no_calls
}

# Only a discharging battery counts: on the charger it never acts, at any
# level, and Long_Life's parked cell reads "Not charging".

test_does_nothing_while_charging_at_1_percent() {
	battery Charging 1
	run
	expect_no_calls
}

test_does_nothing_when_parked_at_2_percent() {
	battery "Not charging" 2
	run
	expect_no_calls
}

test_does_nothing_when_full() {
	battery Full 100
	run
	expect_no_calls
}

test_does_nothing_for_an_unknown_status() {
	battery Unknown 2
	run
	expect_no_calls
}

test_status_is_case_sensitive() {
	battery discharging 2
	run
	expect_no_calls
}

# The grace period: plugging in during the 10 seconds aborts.

test_plugging_in_during_the_warning_aborts() {
	battery Discharging 3
	ON_SLEEP=Charging run
	expect_status 0
	expect_calls \
		"logger -t battery-emergency-poweroff battery at 3% and discharging, powering off in 10s" \
		"wall Battery at 3%: EMERGENCY POWEROFF in 10 seconds. Plug in AC now to abort." \
		"sleep 10"
}

test_parking_during_the_warning_aborts() {
	battery Discharging 2
	ON_SLEEP="Not charging" run
	expect_status 0
	[[ "$(cat "$calls")" != *"systemctl"* ]] || {
		echo "  powered off although the battery stopped discharging"
		return 1
	}
}

test_still_discharging_after_the_warning_powers_off() {
	battery Discharging 3
	ON_SLEEP=Discharging run
	poweroff_calls 3
}

# A failing warning never stops the poweroff.

test_powers_off_when_wall_fails() {
	battery Discharging 2
	WALL_STATUS=1 run
	poweroff_calls 2
}

test_powers_off_when_logger_fails() {
	battery Discharging 2
	LOGGER_STATUS=1 run
	poweroff_calls 2
}

# Missing and malformed readings: no battery, no files, or a capacity that
# is no number, and the script exits 0 without acting.

test_no_battery_directory() {
	rm -rf -- "$bat"
	run
	expect_status 0
	expect_no_calls
}

test_no_status_file() {
	battery Discharging 1
	rm -- "$bat/status"
	run
	expect_status 0
	expect_no_calls
}

test_no_capacity_file() {
	battery Discharging 1
	rm -- "$bat/capacity"
	run
	expect_status 0
	expect_no_calls
}

test_unreadable_capacity() {
	# root reads a file of mode 000, so the case means nothing for root.
	((EUID != 0)) || return 0
	battery Discharging 1
	chmod 000 "$bat/capacity"
	run
	chmod 644 "$bat/capacity"
	expect_status 0
	expect_no_calls
}

test_empty_capacity() {
	battery Discharging ""
	run
	expect_status 0
	expect_no_calls
}

test_capacity_that_is_no_number() {
	battery Discharging abc
	run
	expect_status 0
	expect_no_calls
}

test_capacity_with_a_percent_sign() {
	battery Discharging "2%"
	run
	expect_status 0
	expect_no_calls
}

test_huge_capacity() {
	battery Discharging 99999999999999999999999
	run
	expect_status 0
	expect_no_calls
}

# A negative reading is below 3, so it counts as empty (README.md, Findings).
test_negative_capacity_counts_as_empty() {
	battery Discharging -1
	run
	poweroff_calls -1
}

# Two runs at once, as a timer run and a manual one: each acts on its own.
test_two_runs_at_once() {
	battery Discharging 3
	: >"$calls"
	env PATH="$bin:$PATH" CALLS="$calls" BAT_DIR="$bat" bash "$SOURCE" "$bat" &
	env PATH="$bin:$PATH" CALLS="$calls" BAT_DIR="$bat" bash "$SOURCE" "$bat" &
	wait
	[[ "$(grep -c '^systemctl poweroff$' "$calls")" == 2 ]] || {
		echo "  expected two poweroffs, got:"
		cat "$calls"
		return 1
	}
}

# The battery is BAT0 unless an argument names another.
test_default_battery_is_bat0() {
	grep -Fqx 'BAT=${1:-/sys/class/power_supply/BAT0}' "$SOURCE" || {
		echo "  the script does not default to /sys/class/power_supply/BAT0"
		return 1
	}
}

# The package.

# writeShellApplication puts the script after its PATH line, between an
# empty line of its own on either side.
test_package_runs_this_script() {
	diff <(tail -n +2 "$SOURCE") <(awk 'body; /^export PATH=/ { body = 1 }' "$PACKAGE" | sed '1{/^$/d}; ${/^$/d}') || {
		echo "  the package's script is not this one"
		return 1
	}
}

test_package_path_is_the_store_only() {
	local line path
	line="$(grep -m1 '^export PATH=' "$PACKAGE")"
	[[ "$line" != *'$PATH'* ]] || {
		echo "  the package inherits the caller's PATH: $line"
		return 1
	}
	path="${line#export PATH=\"}"
	path="${path%\"}"
	capture env -i PATH="$path" "$BASH" -c 'command -v cat logger wall sleep systemctl'
	expect_status 0
	expect_lines 5
	local cmd
	while IFS= read -r cmd; do
		[[ "$cmd" == /nix/store/* ]] || {
			echo "  $cmd is not from the store"
			return 1
		}
	done <<<"$out"
}

tests=(
	test_powers_off_at_3_percent
	test_powers_off_at_1_percent
	test_powers_off_at_0_percent
	test_does_nothing_at_4_percent
	test_does_nothing_at_50_percent
	test_does_nothing_while_charging_at_1_percent
	test_does_nothing_when_parked_at_2_percent
	test_does_nothing_when_full
	test_does_nothing_for_an_unknown_status
	test_status_is_case_sensitive
	test_plugging_in_during_the_warning_aborts
	test_parking_during_the_warning_aborts
	test_still_discharging_after_the_warning_powers_off
	test_powers_off_when_wall_fails
	test_powers_off_when_logger_fails
	test_no_battery_directory
	test_no_status_file
	test_no_capacity_file
	test_unreadable_capacity
	test_empty_capacity
	test_capacity_that_is_no_number
	test_capacity_with_a_percent_sign
	test_huge_capacity
	test_negative_capacity_counts_as_empty
	test_two_runs_at_once
	test_default_battery_is_bat0
	test_package_runs_this_script
	test_package_path_is_the_store_only
)
run_tests "${tests[@]}"
