#!/usr/bin/env bash
# shellcheck disable=SC2016
# Tests for energy (packages/energy), run by the check bin-energy.
#
# energy runs as a copy whose two fixed strings point into the scratch
# directory: the charger's sysfs file (ADP0/online) and the charge-mode it
# calls. A test fails when the copy still names either. Everything it talks
# to is a stub on the PATH that logs its calls: busctl answers for the power
# profile from a file, swaymsg for the outputs, fuzzel picks rows by the
# patterns a test lists (ESC stands for Escape), and gdbus plays a list of
# bus events for the watcher, waiting after each one until the watcher has
# acted on it, so the order of what follows is fixed. keep-awake,
# waybar-launch, setsid, systemctl, pgrep and notify-send log and do nothing
# else. The last tests check the package: the command is this script with
# the package's charge-mode, and its PATH has the tools the script calls.
#
#   SOURCE=   packages/energy/energy.sh
#   PACKAGE=  the built package
#   TEST_LIB= scripts/tests/lib.sh
#
# (SC2016 above: the stub bodies are written in single quotes on purpose.)

# shellcheck source=scripts/tests/lib.sh
source "${TEST_LIB:?TEST_LIB names scripts/tests/lib.sh}"
: "${SOURCE:?SOURCE names energy.sh}" "${PACKAGE:?PACKAGE names the built package}"

bin="$scratch/bin"
calls="$scratch/calls"
fake="$scratch/fake-sysfs"
online="$fake/ADP0/online"
energy="$scratch/energy"
export STATE_HOME="$scratch/state" RUNTIME="$scratch/run"

# busctl: get-property prints the profile in $PROFILE_FILE, set-property
# stores one; BUSCTL_FAILS makes both fail, as with no tuned-ppd.
write_script "$bin/busctl" \
	'[ -z "${BUSCTL_FAILS:-}" ] || exit 1' \
	'case "$2" in' \
	'get-property) printf "s \"%s\"\n" "$(cat "$PROFILE_FILE")" ;;' \
	'set-property) printf "busctl %s\n" "$*" >>"$CALLS"; printf "%s\n" "${8}" >"$PROFILE_FILE" ;;' \
	'esac'
# swaymsg: get_outputs prints $OUTPUTS (and counts, for the watcher's sync),
# anything else is logged.
write_script "$bin/swaymsg" \
	'if [ "$1 $2" = "-t get_outputs" ]; then' \
	'  echo $(($(cat "$REFRESHES" 2>/dev/null || echo 0) + 1)) >"$REFRESHES"' \
	'  [ -f "$OUTPUTS" ] || exit 1; cat "$OUTPUTS"; exit 0' \
	'fi' \
	'printf "swaymsg %s\n" "$*" >>"$CALLS"'
# fuzzel --dmenu: logs its prompt and rows, then prints the first row that
# holds the next pattern of $PICKS; ESC, or none left, is Escape.
write_script "$bin/fuzzel" \
	'prompt=""; while [ $# -gt 0 ]; do [ "$1" = --prompt ] && prompt=$2; shift; done' \
	'rows=$(cat); { printf "fuzzel [%s]\n" "$prompt"; printf "%s\n" "$rows" | sed "s/^/  | /"; } >>"$FUZZEL_LOG"' \
	'pat=$(head -n 1 "$PICKS" 2>/dev/null); sed -i 1d "$PICKS" 2>/dev/null' \
	'[ -n "$pat" ] && [ "$pat" != ESC ] || exit 1' \
	'printf "%s\n" "$rows" | grep -F -m 1 -- "$pat"'
# gdbus monitor: the UPower monitor plays $EVENTS, the profile monitor ends at
# once. "online V" sets the charger, "say TEXT" prints a line the watcher acts
# on and waits until it refreshed, "noise TEXT" prints one it ignores.
write_script "$bin/gdbus" \
	'case "$*" in *org.freedesktop.UPower*) ;; *) exit 0 ;; esac' \
	'n=$(cat "$REFRESHES" 2>/dev/null || echo 0)' \
	'while read -r what text; do' \
	'  case "$what" in' \
	'  online) printf "%s\n" "$text" >"$ONLINE" ;;' \
	'  noise) printf "%s\n" "$text" ;;' \
	'  say) printf "%s\n" "$text"; n=$((n + 1)); i=0' \
	'    while [ "$(cat "$REFRESHES" 2>/dev/null || echo 0)" -lt "$n" ] && [ "$i" -lt 200 ]; do sleep 0.02; i=$((i + 1)); done ;;' \
	'  esac' \
	'done <"$EVENTS"'
for c in keep-awake waybar-launch setsid notify-send; do
	write_script "$bin/$c" "printf '$c %s\n' \"\$*\" >>\"\$CALLS\""
done
# keep-awake fails with KEEP_AWAKE_STATUS, as a broken one would.
write_script "$bin/keep-awake" \
	'printf "keep-awake %s\n" "$*" >>"$CALLS"' \
	'exit "${KEEP_AWAKE_STATUS:-0}"'
# systemctl: is-active answers from $ACTIVE_UNITS, anything else is logged.
write_script "$bin/systemctl" \
	'if [ "$1" = is-active ]; then for u in ${ACTIVE_UNITS:-}; do [ "$u" = "${3:-}" ] && exit 0; done; exit 3; fi' \
	'printf "systemctl %s\n" "$*" >>"$CALLS"'
# pgrep: finds what $RUNNING lists, one pattern a line, by the pattern it
# was given.
write_script "$bin/pgrep" \
	'printf "%s\n" "${RUNNING:-}" | grep -Fxq -- "${!#}"'
# charge-mode: prints $CHARGE_MODE_NOW, or fails without it; set is logged.
write_script "$scratch/charge-mode" \
	'if [ "${1:-}" = set ]; then printf "charge-mode %s\n" "$*" >>"$CALLS"; exit 0; fi' \
	'[ -n "${CHARGE_MODE_NOW:-}" ] || exit 1; printf "%s\n" "$CHARGE_MODE_NOW"'

# Outside the sandbox the cases must never reach the desktop they run on.
# Behind the stubs comes the caller's PATH without any directory that holds
# keep-awake or waybar-launch: a case that takes a stub away would else run
# the real one, and keep-awake restarts the session's swayidle. The cases
# also get no Wayland, Sway or session bus to talk to.
host_path=""
IFS=: read -ra host_dirs <<<"$PATH"
for dir in "${host_dirs[@]}"; do
	[[ -e "$dir/keep-awake" || -e "$dir/waybar-launch" ]] || host_path+="${host_path:+:}$dir"
done
off_desktop=(-u WAYLAND_DISPLAY -u SWAYSOCK -u DISPLAY DBUS_SESSION_BUS_ADDRESS="unix:path=$scratch/no-bus")

# The copy of energy.sh under test; the sandbox has no /usr/bin/env.
sed -e "1s|^#!.*|#!$BASH|" \
	-e "s|/sys/class/power_supply/ADP0|$fake/ADP0|g" \
	-e "s|@chargeMode@|$scratch/charge-mode|g" "$SOURCE" >"$energy"
if grep -Ev '^[[:space:]]*#' "$energy" | grep -Eq '/sys/|@chargeMode@'; then
	echo "the copy of energy.sh still names a real path or the placeholder" >&2
	exit 1
fi

# A fresh world for each test: on the charger, profile balanced, no state.
fresh() {
	rm -rf -- "$fake" "$STATE_HOME" "$RUNTIME" "$scratch/profile" "$scratch/outputs" \
		"$scratch/picks" "$scratch/events" "$scratch/refreshes" "$scratch/fuzzel.log"
	mkdir -p "$fake/ADP0" "$RUNTIME"
	echo 1 >"$online"
	echo balanced >"$scratch/profile"
	: >"$calls"
	: >"$scratch/fuzzel.log"
}
fresh

charger() { printf '%s\n' "$1" >"$online"; }
profile_is() { printf '%s\n' "$1" >"$scratch/profile"; }
# outputs NAME:ACTIVE:HZ...: the outputs swaymsg reports, each 2560x1600.
outputs() {
	local o name active hz first=1
	{
		printf '['
		for o in "$@"; do
			IFS=: read -r name active hz <<<"$o"
			((first)) || printf ','
			first=0
			printf '{"name":"%s","active":%s,"current_mode":{"width":2560,"height":1600,"refresh":%s}}' \
				"$name" "$active" "$hz"
		done
		printf ']\n'
	} >"$scratch/outputs"
}
picks() { printf '%s\n' "$@" >"$scratch/picks"; }
events() { printf '%s\n' "$@" >"$scratch/events"; }
set_state() {
	mkdir -p "$STATE_HOME/energy"
	printf '%s\n' "$2" >"$STATE_HOME/energy/$1"
}

run() {
	capture env "${off_desktop[@]}" PATH="$bin:$host_path" CALLS="$calls" PROFILE_FILE="$scratch/profile" \
		OUTPUTS="$scratch/outputs" PICKS="$scratch/picks" FUZZEL_LOG="$scratch/fuzzel.log" \
		EVENTS="$scratch/events" REFRESHES="$scratch/refreshes" ONLINE="$online" \
		XDG_STATE_HOME="$STATE_HOME" XDG_RUNTIME_DIR="$RUNTIME" \
		"$BASH" "$energy" "$@"
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
fuzzel_showed() {
	grep -Fq -- "$1" "$scratch/fuzzel.log" || {
		echo "  fuzzel never showed '$1':"
		cat "$scratch/fuzzel.log"
		return 1
	}
}

# get and set: three keys with fixed values, kept in XDG_STATE_HOME.

test_defaults() {
	fresh
	run get refresh
	[[ "$out" == auto ]] || { echo "  refresh: $out"; return 1; }
	run get idle_suspend
	[[ "$out" == on ]] || { echo "  idle_suspend: $out"; return 1; }
	run get focus_bar
	[[ "$out" == off ]] || { echo "  focus_bar: $out"; return 1; }
}

test_set_and_get_every_value() {
	fresh
	local kv
	for kv in refresh:auto refresh:120 refresh:60 idle_suspend:on idle_suspend:off focus_bar:on focus_bar:off; do
		run set "${kv%%:*}" "${kv#*:}"
		expect_status 0
		content_is "$STATE_HOME/energy/${kv%%:*}" "${kv#*:}"
		run get "${kv%%:*}"
		[[ "$out" == "${kv#*:}" ]] || { echo "  $kv read back as $out"; return 1; }
	done
}

test_set_refuses_other_values() {
	fresh
	local kv
	for kv in refresh:90 refresh:Auto refresh: idle_suspend:yes focus_bar:1 bogus:on "refresh:60 " "refresh:../x"; do
		run set "${kv%%:*}" "${kv#*:}"
		[[ "$status" != 0 ]] || { echo "  accepted $kv"; return 1; }
	done
	run set refresh 90
	expect_status 2
	expect_err "'90' is not a value for 'refresh'"
	[[ ! -e "$STATE_HOME/energy" ]] || { echo "  wrote state for a refused value"; ls -R "$STATE_HOME"; return 1; }
}

test_set_without_a_value_fails() {
	fresh
	run set refresh
	[[ "$status" != 0 ]]
	expect_err "value"
	run get
	[[ "$status" != 0 ]]
	expect_err "key"
}

# Findings, kept as Fedora has them (README.md).
test_get_of_an_unknown_key_dies_unbound() {
	fresh
	run get bogus
	[[ "$status" != 0 ]] || { echo "  exit 0"; return 1; }
	expect_err "unbound variable"
}

test_an_empty_state_file_reads_as_empty() {
	fresh
	set_state refresh ""
	run get refresh
	expect_status 0
	[[ "$out" == "" ]] || { echo "  got '$out'"; return 1; }
}

# Two sets of one key at once leave one whole value, and nothing else in
# the state directory. auto and 60 differ in length, so a torn write
# shows: 60 written over auto is "60\no".
test_two_sets_at_once_leave_one_value() {
	fresh
	local round got
	for ((round = 1; round <= 200; round++)); do
		env XDG_STATE_HOME="$STATE_HOME" "$BASH" "$energy" set refresh auto &
		env XDG_STATE_HOME="$STATE_HOME" "$BASH" "$energy" set refresh 60 &
		wait
		got="$(
			cat "$STATE_HOME/energy/refresh"
			echo x
		)"
		got="${got%x}"
		[[ "$got" == $'auto\n' || "$got" == $'60\n' ]] || {
			echo "  round $round saved '$got'"
			return 1
		}
	done
	got="$(find "$STATE_HOME/energy" -mindepth 1 ! -name refresh)"
	[[ -z "$got" ]] || {
		echo "  left in the state directory: $got"
		return 1
	}
}

# A get while a set of the same key runs reads the old value or the new
# one, never an empty file, as the watcher's and swayidle's reads do.
test_a_get_during_sets_never_reads_empty() {
	fresh
	set_state refresh auto
	local stop="$scratch/stop-writer" round got bad=""
	rm -f -- "$stop"
	(
		while [[ ! -e "$stop" ]]; do
			env XDG_STATE_HOME="$STATE_HOME" "$BASH" "$energy" set refresh 60
			env XDG_STATE_HOME="$STATE_HOME" "$BASH" "$energy" set refresh auto
		done
	) &
	local writer=$!
	for ((round = 1; round <= 600; round++)); do
		got="$(env XDG_STATE_HOME="$STATE_HOME" "$BASH" "$energy" get refresh)"
		if [[ "$got" != auto && "$got" != 60 ]]; then
			bad="read $round got '$got'"
			break
		fi
	done
	: >"$stop"
	wait "$writer" || true
	[[ -z "$bad" ]] || {
		echo "  $bad"
		return 1
	}
}

test_set_into_an_unwritable_state_fails() {
	((EUID != 0)) || return 0
	fresh
	mkdir -p "$STATE_HOME"
	chmod 555 "$STATE_HOME"
	run set refresh 60
	chmod 755 "$STATE_HOME"
	[[ "$status" != 0 ]] || { echo "  exit 0"; return 1; }
}

test_state_falls_back_to_home() {
	fresh
	local home="$scratch/home"
	rm -rf -- "$home"
	capture env -u XDG_STATE_HOME "${off_desktop[@]}" HOME="$home" PATH="$bin:$host_path" "$BASH" "$energy" set focus_bar on
	expect_status 0
	content_is "$home/.local/state/energy/focus_bar" on
}

# refresh: the panel's rate follows the setting, and in auto the profile.

test_auto_on_power_saver_is_60() {
	fresh
	profile_is power-saver
	outputs eDP-1:true:120000
	run refresh
	expect_status 0
	calls_are "swaymsg output eDP-1 mode 2560x1600@60Hz"
}

test_auto_on_balanced_and_performance_is_120() {
	fresh
	outputs eDP-1:true:60000
	run refresh
	calls_are "swaymsg output eDP-1 mode 2560x1600@120Hz"
	: >"$calls"
	profile_is performance
	run refresh
	calls_are "swaymsg output eDP-1 mode 2560x1600@120Hz"
}

test_no_modeset_when_the_rate_is_right() {
	fresh
	outputs eDP-1:true:120000
	run refresh
	expect_status 0
	no_calls
}

test_a_rate_near_60_counts_as_60() {
	fresh
	profile_is power-saver
	outputs eDP-1:true:59951
	run refresh
	no_calls
	outputs eDP-1:true:60499
	run refresh
	no_calls
}

test_fixed_rates_ignore_the_profile() {
	fresh
	set_state refresh 60
	profile_is performance
	outputs eDP-1:true:120000
	run refresh
	calls_are "swaymsg output eDP-1 mode 2560x1600@60Hz"
	: >"$calls"
	set_state refresh 120
	profile_is power-saver
	outputs eDP-1:true:60000
	run refresh
	calls_are "swaymsg output eDP-1 mode 2560x1600@120Hz"
}

test_the_active_edp_is_the_one_changed() {
	fresh
	profile_is power-saver
	outputs DP-1:true:144000 eDP-1:false:120000 eDP-2:true:120000
	run refresh
	calls_are "swaymsg output eDP-2 mode 2560x1600@60Hz"
}

test_only_the_first_active_edp_is_changed() {
	fresh
	profile_is power-saver
	outputs eDP-1:true:120000 eDP-2:true:120000
	run refresh
	calls_are "swaymsg output eDP-1 mode 2560x1600@60Hz"
}

test_no_panel_no_modeset() {
	fresh
	profile_is power-saver
	outputs DP-1:true:120000 eDP-1:false:120000
	run refresh
	expect_status 0
	no_calls
	outputs
	run refresh
	no_calls
}

test_no_sway_no_modeset() {
	fresh
	profile_is power-saver
	run refresh
	expect_status 0
	no_calls
}

test_malformed_outputs_no_modeset() {
	fresh
	profile_is power-saver
	printf 'not json\n' >"$scratch/outputs"
	run refresh
	expect_status 0
	no_calls
}

test_no_profile_daemon_counts_as_balanced() {
	fresh
	outputs eDP-1:true:60000
	BUSCTL_FAILS=1 run refresh
	expect_status 0
	calls_are "swaymsg output eDP-1 mode 2560x1600@120Hz"
}

# idle-suspend: swayidle's 30-minute timeout; on battery only, with its switch
# on, and never during a backup or a download.

test_idle_suspend_on_battery() {
	fresh
	charger 0
	run idle-suspend
	expect_status 0
	calls_are "systemctl suspend"
}

test_idle_suspend_never_on_the_charger() {
	fresh
	run idle-suspend
	no_calls
}

test_idle_suspend_off_does_nothing() {
	fresh
	charger 0
	set_state idle_suspend off
	run idle-suspend
	expect_status 0
	no_calls
}

test_idle_suspend_waits_for_a_backup() {
	fresh
	charger 0
	ACTIVE_UNITS=borg-backup.service run idle-suspend
	no_calls
}

test_idle_suspend_waits_for_a_download_or_restic() {
	fresh
	charger 0
	RUNNING=dl-video run idle-suspend
	no_calls
	RUNNING='^restic ' run idle-suspend
	no_calls
}

test_idle_suspend_without_a_charger_file_counts_as_charger() {
	fresh
	rm -- "$online"
	run idle-suspend
	no_calls
}

test_idle_suspend_with_a_garbled_charger_file() {
	fresh
	charger ""
	run idle-suspend
	no_calls
}

# watch: the watcher's reaction to the charger and the profile.

test_unplug_turns_keep_awake_off() {
	fresh
	echo 1 >"$RUNTIME/keep-awake"
	events "online 0" "say OnBattery true"
	run watch
	expect_status 1
	calls_are "keep-awake set off" "notify-send -a Energy Keep-awake off Switched off on unplug."
}

# A dead dependency: keep-awake or waybar-launch missing from the PATH, or
# keep-awake failing. The watcher says which, in the journal and as a
# notification, claims no change it did not make, and goes on watching
# (the profile event after the unplug still refreshes).

test_unplug_without_keep_awake_says_so() {
	fresh
	echo 1 >"$RUNTIME/keep-awake"
	events "online 0" "say OnBattery true" "say ActiveProfile power-saver"
	mv "$bin/keep-awake" "$scratch/keep-awake.away"
	run watch
	mv "$scratch/keep-awake.away" "$bin/keep-awake"
	expect_status 1
	expect_err "energy: keep-awake is not on the PATH, so keep-awake stays on after the unplug"
	calls_are "notify-send -a Energy -u critical keep-awake not found keep-awake stays on after the unplug."
	content_is "$scratch/refreshes" 3
}

test_unplug_with_a_failing_keep_awake_says_so() {
	fresh
	echo 1 >"$RUNTIME/keep-awake"
	events "online 0" "say OnBattery true" "say ActiveProfile power-saver"
	KEEP_AWAKE_STATUS=3 run watch
	expect_status 1
	expect_err "energy: keep-awake set off failed (exit 3), so keep-awake may still be on"
	calls_are "keep-awake set off" \
		"notify-send -a Energy -u critical keep-awake failed keep-awake set off failed (exit 3), so keep-awake may still be on."
	content_is "$scratch/refreshes" 3
}

test_unplug_without_waybar_launch_says_so() {
	fresh
	set_state focus_bar on
	echo full >"$RUNTIME/waybar-mode"
	events "online 0" "say OnBattery true" "say ActiveProfile power-saver"
	mv "$bin/waybar-launch" "$scratch/waybar-launch.away"
	run watch
	mv "$scratch/waybar-launch.away" "$bin/waybar-launch"
	expect_status 1
	expect_err "energy: waybar-launch is not on the PATH, so the bar stays as it is"
	calls_are "notify-send -a Energy -u critical waybar-launch not found the bar stays as it is."
	content_is "$RUNTIME/waybar-mode" full
	[[ ! -e "$RUNTIME/energy-focus-auto" ]] || { echo "  the marker says the watcher switched"; return 1; }
	content_is "$scratch/refreshes" 3
}

test_replug_without_waybar_launch_says_so() {
	fresh
	echo focus >"$RUNTIME/waybar-mode"
	: >"$RUNTIME/energy-focus-auto"
	charger 0
	events "online 1" "say OnBattery false" "say ActiveProfile power-saver"
	mv "$bin/waybar-launch" "$scratch/waybar-launch.away"
	run watch
	mv "$scratch/waybar-launch.away" "$bin/waybar-launch"
	expect_status 1
	expect_err "energy: waybar-launch is not on the PATH, so the bar stays as it is"
	calls_are "notify-send -a Energy -u critical waybar-launch not found the bar stays as it is."
	content_is "$RUNTIME/waybar-mode" focus
	[[ -e "$RUNTIME/energy-focus-auto" ]] || { echo "  the marker went, so a later replug cannot switch back"; return 1; }
	content_is "$scratch/refreshes" 3
}

test_menu_keep_awake_without_keep_awake_says_so() {
	fresh
	picks "Keep-awake" "on   ("
	mv "$bin/keep-awake" "$scratch/keep-awake.away"
	run menu
	mv "$scratch/keep-awake.away" "$bin/keep-awake"
	expect_status 1
	expect_err "energy: keep-awake is not on the PATH, so keep-awake is unchanged"
	calls_are "notify-send -a Energy -u critical keep-awake not found keep-awake is unchanged."
}

test_unplug_with_keep_awake_off_leaves_it() {
	fresh
	echo 0 >"$RUNTIME/keep-awake"
	events "online 0" "say OnBattery true"
	run watch
	no_calls
}

test_unplug_switches_to_the_focus_bar() {
	fresh
	set_state focus_bar on
	echo full >"$RUNTIME/waybar-mode"
	events "online 0" "say OnBattery true"
	run watch
	calls_are "setsid -f waybar-launch"
	content_is "$RUNTIME/waybar-mode" focus
	[[ -e "$RUNTIME/energy-focus-auto" ]] || { echo "  no marker"; return 1; }
}

test_unplug_without_a_waybar_mode_counts_as_full() {
	fresh
	set_state focus_bar on
	events "online 0" "say OnBattery true"
	run watch
	content_is "$RUNTIME/waybar-mode" focus
}

test_unplug_leaves_a_focus_bar_set_by_hand() {
	fresh
	set_state focus_bar on
	echo focus >"$RUNTIME/waybar-mode"
	events "online 0" "say OnBattery true"
	run watch
	no_calls
	[[ ! -e "$RUNTIME/energy-focus-auto" ]]
}

test_unplug_with_the_focus_bar_off_leaves_the_bar() {
	fresh
	echo full >"$RUNTIME/waybar-mode"
	events "online 0" "say OnBattery true"
	run watch
	no_calls
	content_is "$RUNTIME/waybar-mode" full
}

test_replug_undoes_only_its_own_switch() {
	fresh
	set_state focus_bar on
	echo full >"$RUNTIME/waybar-mode"
	events "online 0" "say OnBattery true" "online 1" "say OnBattery false"
	run watch
	calls_are "setsid -f waybar-launch" "setsid -f waybar-launch"
	content_is "$RUNTIME/waybar-mode" full
	[[ ! -e "$RUNTIME/energy-focus-auto" ]]
}

test_replug_leaves_a_hand_set_focus_bar() {
	fresh
	echo focus >"$RUNTIME/waybar-mode"
	charger 0
	events "online 1" "say OnBattery false"
	run watch
	no_calls
	content_is "$RUNTIME/waybar-mode" focus
}

test_replug_after_a_hand_change_to_full_leaves_it() {
	fresh
	echo full >"$RUNTIME/waybar-mode"
	: >"$RUNTIME/energy-focus-auto"
	charger 0
	events "online 1" "say OnBattery false"
	run watch
	no_calls
	[[ ! -e "$RUNTIME/energy-focus-auto" ]] || { echo "  the marker stayed"; return 1; }
}

test_each_event_refreshes_and_noise_does_not() {
	fresh
	profile_is power-saver
	outputs eDP-1:true:120000
	events "noise PropertiesChanged Percentage 50" "say ActiveProfile power-saver" "noise nothing"
	run watch
	# One refresh at the start and one for the event; the first sets 60 Hz,
	# and the stub's rate stays 120, so the second asks again.
	content_is "$scratch/refreshes" 2
	calls_are "swaymsg output eDP-1 mode 2560x1600@60Hz" "swaymsg output eDP-1 mode 2560x1600@60Hz"
}

test_a_profile_change_alone_touches_no_setting() {
	fresh
	echo 1 >"$RUNTIME/keep-awake"
	events "say ActiveProfile performance"
	run watch
	no_calls
}

test_a_second_unplug_event_acts_once() {
	fresh
	echo 1 >"$RUNTIME/keep-awake"
	events "online 0" "say OnBattery true" "say OnBattery true"
	run watch
	calls_are "keep-awake set off" "notify-send -a Energy Keep-awake off Switched off on unplug."
}

test_starting_on_battery_is_no_unplug() {
	fresh
	charger 0
	echo 1 >"$RUNTIME/keep-awake"
	events "say OnBattery true"
	run watch
	no_calls
}

test_watch_exits_1_when_the_monitors_end() {
	fresh
	events
	run watch
	expect_status 1
}

# menu: one fuzzel row per setting, and one choice list per row.

test_menu_escape_does_nothing() {
	fresh
	picks ESC
	run menu
	expect_status 0
	no_calls
}

test_no_argument_is_the_menu() {
	fresh
	picks ESC
	run
	expect_status 0
	fuzzel_showed "fuzzel [  Energy   ]"
}

test_menu_rows_show_the_values() {
	fresh
	profile_is power-saver
	echo 1 >"$RUNTIME/keep-awake"
	set_state focus_bar on
	picks ESC
	CHARGE_MODE_NOW=Long_Life run menu
	fuzzel_showed "󰾅  Power profile: power-saver"
	fuzzel_showed "󰍹  Refresh rate: auto (60 Hz now)"
	fuzzel_showed "󰅶  Keep-awake: on"
	fuzzel_showed "󰒲  Idle suspend on battery: on"
	fuzzel_showed "󰂄  Charge mode: Long_Life"
	fuzzel_showed "󰕮  Focus bar on battery: on"
}

test_menu_without_charge_mode_says_unknown() {
	fresh
	picks ESC
	run menu
	fuzzel_showed "󰂄  Charge mode: unknown"
}

test_menu_sets_each_profile() {
	fresh
	local p
	for p in power-saver performance balanced; do
		: >"$calls"
		picks "Power profile" "$p"
		run menu
		expect_status 0
		calls_are "busctl --system set-property net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile s $p"
	done
}

test_menu_marks_the_active_profile() {
	fresh
	profile_is performance
	picks "Power profile" ESC
	run menu
	fuzzel_showed "fuzzel [  Power profile   ]"
	fuzzel_showed "| 󰄬 performance"
	fuzzel_showed "|    balanced"
	no_calls
}

test_menu_refresh_rate() {
	fresh
	outputs eDP-1:true:120000
	picks "Refresh rate" "60 Hz always"
	run menu
	content_is "$STATE_HOME/energy/refresh" 60
	calls_are "swaymsg output eDP-1 mode 2560x1600@60Hz"
	picks "Refresh rate" "auto"
	run menu
	content_is "$STATE_HOME/energy/refresh" auto
	picks "Refresh rate" "120 Hz always"
	run menu
	content_is "$STATE_HOME/energy/refresh" 120
}

test_menu_keep_awake() {
	fresh
	picks "Keep-awake" "on   ("
	run menu
	calls_are "keep-awake set on"
	: >"$calls"
	picks "Keep-awake" "off  ("
	run menu
	calls_are "keep-awake set off"
}

test_menu_idle_suspend_and_focus_bar() {
	fresh
	picks "Idle suspend" "off"
	run menu
	content_is "$STATE_HOME/energy/idle_suspend" off
	picks "Focus bar" "on   ("
	run menu
	content_is "$STATE_HOME/energy/focus_bar" on
	picks "Focus bar" "off"
	run menu
	content_is "$STATE_HOME/energy/focus_bar" off
}

test_menu_charge_mode() {
	fresh
	local m
	for m in Standard Fast Long_Life; do
		: >"$calls"
		picks "Charge mode" "$m"
		CHARGE_MODE_NOW=Long_Life run menu
		calls_are "charge-mode set $m"
	done
}

test_menu_escape_in_a_choice_list_does_nothing() {
	fresh
	local row
	for row in "Power profile" "Refresh rate" "Keep-awake" "Idle suspend" "Charge mode" "Focus bar"; do
		picks "$row" ESC
		run menu
		expect_status 0
	done
	no_calls
	[[ ! -e "$STATE_HOME/energy" ]]
}

test_menu_without_fuzzel_exits_quietly() {
	fresh
	mv "$bin/fuzzel" "$scratch/fuzzel.away"
	run menu
	mv "$scratch/fuzzel.away" "$bin/fuzzel"
	expect_status 0
	no_calls
}

test_unknown_command() {
	fresh
	run bogus
	expect_status 2
	expect_err "usage: energy [menu|watch|refresh|idle-suspend|get KEY|set KEY VALUE]"
}

# The package.

test_package_is_this_script_with_its_charge_mode() {
	local line cm
	cm="$(grep -o '/nix/store/[^"]*-charge-mode[^/"]*/bin/charge-mode' "$PACKAGE/bin/energy" | head -n 1)"
	[[ -x "$cm" ]] || { echo "  energy names no charge-mode from the store: '$cm'"; return 1; }
	diff <(tail -n +2 "$SOURCE" | sed "s|@chargeMode@|$cm|g") \
		<(awk 'body; /^export PATH=/ { body = 1 }' "$PACKAGE/bin/energy" | sed '1{/^$/d}; ${/^$/d}') || {
		echo "  the package's energy is not this script"
		return 1
	}
	line="$(grep -m1 '^export PATH=' "$PACKAGE/bin/energy")"
	# fuzzel, swaymsg, keep-awake and waybar-launch come from the session.
	[[ "$line" == *':$PATH"' ]] || { echo "  $line"; return 1; }
}

test_package_path_holds_the_tools() {
	local line path
	line="$(grep -m1 '^export PATH=' "$PACKAGE/bin/energy")"
	path="${line#export PATH=\"}"
	path="${path%:\$PATH\"}"
	capture env -i PATH="$path" "$BASH" -c 'command -v awk busctl cat gdbus jq mkdir mktemp mv notify-send pgrep rm setsid systemctl'
	expect_status 0
	expect_lines 13
}

tests=(
	test_defaults
	test_set_and_get_every_value
	test_set_refuses_other_values
	test_set_without_a_value_fails
	test_get_of_an_unknown_key_dies_unbound
	test_an_empty_state_file_reads_as_empty
	test_two_sets_at_once_leave_one_value
	test_a_get_during_sets_never_reads_empty
	test_set_into_an_unwritable_state_fails
	test_state_falls_back_to_home
	test_auto_on_power_saver_is_60
	test_auto_on_balanced_and_performance_is_120
	test_no_modeset_when_the_rate_is_right
	test_a_rate_near_60_counts_as_60
	test_fixed_rates_ignore_the_profile
	test_the_active_edp_is_the_one_changed
	test_only_the_first_active_edp_is_changed
	test_no_panel_no_modeset
	test_no_sway_no_modeset
	test_malformed_outputs_no_modeset
	test_no_profile_daemon_counts_as_balanced
	test_idle_suspend_on_battery
	test_idle_suspend_never_on_the_charger
	test_idle_suspend_off_does_nothing
	test_idle_suspend_waits_for_a_backup
	test_idle_suspend_waits_for_a_download_or_restic
	test_idle_suspend_without_a_charger_file_counts_as_charger
	test_idle_suspend_with_a_garbled_charger_file
	test_unplug_turns_keep_awake_off
	test_unplug_without_keep_awake_says_so
	test_unplug_with_a_failing_keep_awake_says_so
	test_unplug_without_waybar_launch_says_so
	test_replug_without_waybar_launch_says_so
	test_menu_keep_awake_without_keep_awake_says_so
	test_unplug_with_keep_awake_off_leaves_it
	test_unplug_switches_to_the_focus_bar
	test_unplug_without_a_waybar_mode_counts_as_full
	test_unplug_leaves_a_focus_bar_set_by_hand
	test_unplug_with_the_focus_bar_off_leaves_the_bar
	test_replug_undoes_only_its_own_switch
	test_replug_leaves_a_hand_set_focus_bar
	test_replug_after_a_hand_change_to_full_leaves_it
	test_each_event_refreshes_and_noise_does_not
	test_a_profile_change_alone_touches_no_setting
	test_a_second_unplug_event_acts_once
	test_starting_on_battery_is_no_unplug
	test_watch_exits_1_when_the_monitors_end
	test_menu_escape_does_nothing
	test_no_argument_is_the_menu
	test_menu_rows_show_the_values
	test_menu_without_charge_mode_says_unknown
	test_menu_sets_each_profile
	test_menu_marks_the_active_profile
	test_menu_refresh_rate
	test_menu_keep_awake
	test_menu_idle_suspend_and_focus_bar
	test_menu_charge_mode
	test_menu_escape_in_a_choice_list_does_nothing
	test_menu_without_fuzzel_exits_quietly
	test_unknown_command
	test_package_is_this_script_with_its_charge_mode
	test_package_path_holds_the_tools
)
run_tests "${tests[@]}"
