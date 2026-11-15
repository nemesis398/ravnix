// watch: the watcher's reaction to the charger and the profile. The gdbus
// of the world plays a list of bus events and waits after each one until the
// watcher has refreshed, so the order of what follows is fixed.
package energy_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"

NOTIFY_OFF :: "notify-send -a Energy Keep-awake off Switched off on unplug."

@(test)
unplug_turns_keep_awake_off :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "say OnBattery true")

	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	expect_calls(t, &f, "keep-awake set off", NOTIFY_OFF)
}

@(test)
unplug_without_keep_awake_says_so :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "say OnBattery true", "say ActiveProfile power-saver")
	remove_program(t, &f, "keep-awake")

	code, _, err := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: keep-awake is not on the PATH, so keep-awake stays on after the unplug"), err)
	expect_calls(t, &f, "notify-send -a Energy -u critical keep-awake not found keep-awake stays on after the unplug.")
	// It goes on watching: the profile event after the unplug refreshes.
	testing.expect_value(t, refreshes(&f), "3")
}

@(test)
unplug_with_a_failing_keep_awake_says_so :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	write(t, join(f.bin, "keep-awake.status"), "3\n")
	events(t, &f, "online 0", "say OnBattery true", "say ActiveProfile power-saver")

	code, _, err := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: keep-awake set off failed (exit 3), so keep-awake may still be on"), err)
	expect_calls(
		t,
		&f,
		"keep-awake set off",
		"notify-send -a Energy -u critical keep-awake failed keep-awake set off failed (exit 3), so keep-awake may still be on.",
	)
	testing.expect_value(t, refreshes(&f), "3")
}

@(test)
unplug_without_waybar_launch_says_so :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "focus_bar", "on")
	set_run(t, &f, "waybar-mode", "full")
	events(t, &f, "online 0", "say OnBattery true", "say ActiveProfile power-saver")
	remove_program(t, &f, "waybar-launch")

	code, _, err := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: waybar-launch is not on the PATH, so the bar stays as it is"), err)
	expect_calls(t, &f, "notify-send -a Energy -u critical waybar-launch not found the bar stays as it is.")
	expect_file(t, join(f.run, "waybar-mode"), "full")
	testing.expect(t, !exists(join(f.run, "energy-focus-auto")), "the marker says the watcher switched")
	testing.expect_value(t, refreshes(&f), "3")
}

@(test)
replug_without_waybar_launch_says_so :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "waybar-mode", "focus")
	write(t, join(f.run, "energy-focus-auto"), "")
	charger(t, &f, "0")
	events(t, &f, "online 1", "say OnBattery false", "say ActiveProfile power-saver")
	remove_program(t, &f, "waybar-launch")

	code, _, err := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: waybar-launch is not on the PATH, so the bar stays as it is"), err)
	expect_calls(t, &f, "notify-send -a Energy -u critical waybar-launch not found the bar stays as it is.")
	expect_file(t, join(f.run, "waybar-mode"), "focus")
	// The marker stays, so a later replug switches back.
	testing.expect(t, exists(join(f.run, "energy-focus-auto")), "the marker went")
	testing.expect_value(t, refreshes(&f), "3")
}

@(test)
no_notify_send_is_no_failure :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "say OnBattery true")
	remove_program(t, &f, "notify-send")

	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	expect_calls(t, &f, "keep-awake set off")
}

@(test)
unplug_with_keep_awake_off_leaves_it :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	for state in ([]string{"0", "", "2", "11"}) {
		set_run(t, &f, "keep-awake", state)
		charger(t, &f, "1")
		events(t, &f, "online 0", "say OnBattery true")
		run(t, &f, "watch")
		expect_calls(t, &f)
	}
	// No file at all.
	_ = remove_file(join(f.run, "keep-awake"))
	charger(t, &f, "1")
	run(t, &f, "watch")
	expect_calls(t, &f)
}

@(test)
unplug_switches_to_the_focus_bar :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "focus_bar", "on")
	set_run(t, &f, "waybar-mode", "full")
	events(t, &f, "online 0", "say OnBattery true")

	run(t, &f, "watch")
	expect_calls(t, &f, "setsid -f waybar-launch")
	expect_file(t, join(f.run, "waybar-mode"), "focus")
	testing.expect(t, exists(join(f.run, "energy-focus-auto")), "no marker")
}

@(test)
unplug_without_a_waybar_mode_counts_as_full :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "focus_bar", "on")
	events(t, &f, "online 0", "say OnBattery true")

	run(t, &f, "watch")
	expect_file(t, join(f.run, "waybar-mode"), "focus")
}

@(test)
unplug_leaves_a_focus_bar_set_by_hand :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "focus_bar", "on")
	set_run(t, &f, "waybar-mode", "focus")
	events(t, &f, "online 0", "say OnBattery true")

	run(t, &f, "watch")
	expect_calls(t, &f)
	testing.expect(t, !exists(join(f.run, "energy-focus-auto")))
}

@(test)
unplug_with_the_focus_bar_off_leaves_the_bar :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "waybar-mode", "full")
	events(t, &f, "online 0", "say OnBattery true")

	run(t, &f, "watch")
	expect_calls(t, &f)
	expect_file(t, join(f.run, "waybar-mode"), "full")
}

@(test)
replug_undoes_only_its_own_switch :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "focus_bar", "on")
	set_run(t, &f, "waybar-mode", "full")
	events(t, &f, "online 0", "say OnBattery true", "online 1", "say OnBattery false")

	run(t, &f, "watch")
	expect_calls(t, &f, "setsid -f waybar-launch", "setsid -f waybar-launch")
	expect_file(t, join(f.run, "waybar-mode"), "full")
	testing.expect(t, !exists(join(f.run, "energy-focus-auto")))
}

@(test)
replug_leaves_a_hand_set_focus_bar :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "waybar-mode", "focus")
	charger(t, &f, "0")
	events(t, &f, "online 1", "say OnBattery false")

	run(t, &f, "watch")
	expect_calls(t, &f)
	expect_file(t, join(f.run, "waybar-mode"), "focus")
}

@(test)
replug_after_a_hand_change_to_full_drops_the_marker :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "waybar-mode", "full")
	write(t, join(f.run, "energy-focus-auto"), "")
	charger(t, &f, "0")
	events(t, &f, "online 1", "say OnBattery false")

	run(t, &f, "watch")
	expect_calls(t, &f)
	testing.expect(t, !exists(join(f.run, "energy-focus-auto")), "the marker stayed")
}

@(test)
each_event_refreshes_and_noise_does_not :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")
	outputs(t, &f, "eDP-1:true:120000")
	events(t, &f, "noise PropertiesChanged Percentage 50", "say ActiveProfile power-saver", "noise nothing")

	run(t, &f, "watch")
	// One refresh at the start and one for the event; the first sets 60 Hz,
	// and the stub's rate stays 120, so the second asks again.
	testing.expect_value(t, refreshes(&f), "2")
	expect_calls(t, &f, mode_call("eDP-1", 60), mode_call("eDP-1", 60))
}

@(test)
a_profile_change_alone_touches_no_setting :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "say ActiveProfile performance")

	run(t, &f, "watch")
	expect_calls(t, &f)
}

@(test)
a_second_unplug_event_acts_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "say OnBattery true", "say OnBattery true")

	run(t, &f, "watch")
	expect_calls(t, &f, "keep-awake set off", NOTIFY_OFF)
}

@(test)
starting_on_battery_is_no_unplug :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	charger(t, &f, "0")
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "say OnBattery true")

	run(t, &f, "watch")
	expect_calls(t, &f)
}

@(test)
watch_exits_1_when_the_monitors_end :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	events(t, &f)

	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	// Only the initial refresh.
	testing.expect_value(t, refreshes(&f), "1")
}

@(test)
watch_without_gdbus_says_so_and_exits_1 :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	remove_program(t, &f, "gdbus")

	code, _, err := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: gdbus is not on the PATH"), err)
}

@(test)
a_line_without_its_newline_is_no_event :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "partial OnBattery true")

	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	expect_calls(t, &f)
	testing.expect_value(t, refreshes(&f), "1")
}

@(test)
a_line_longer_than_the_limit_is_still_read :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// Two megabytes of noise, then an event.
	big, _ := strings.repeat("x", 2 << 20)
	events(t, &f, strings.concatenate({"noise ", big}), "say ActiveProfile power-saver")

	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
	testing.expect_value(t, refreshes(&f), "2")
}

@(test)
a_dead_dependency_does_not_stop_the_watcher_from_refreshing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// No swaymsg, no busctl, no systemctl: the events still go through.
	remove_program(t, &f, "swaymsg")
	remove_program(t, &f, "busctl")
	set_run(t, &f, "keep-awake", "1")
	events(t, &f, "online 0", "noise x", "partial y")
	code, _, _ := run(t, &f, "watch")
	testing.expect_value(t, code, 1)
}
