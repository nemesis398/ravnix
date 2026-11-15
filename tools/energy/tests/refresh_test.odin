// refresh: the panel's rate follows the setting, and in auto the profile;
// idle-suspend: swayidle's 30-minute timeout, on battery only, with its
// switch on, and never during a backup or a download.
package energy_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import energy ".."

@(test)
auto_on_power_saver_is_60 :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")
	outputs(t, &f, "eDP-1:true:120000")

	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f, mode_call("eDP-1", 60))
}

@(test)
auto_on_balanced_and_performance_is_120 :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	outputs(t, &f, "eDP-1:true:60000")

	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 120))
	write(t, join(f.bin, "calls"), "")
	profile_is(t, &f, "performance")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 120))
}

@(test)
no_modeset_when_the_rate_is_right :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	outputs(t, &f, "eDP-1:true:120000")

	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
}

@(test)
a_rate_near_60_counts_as_60 :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	for mhz in ([]string{"59951", "60499", "59500", "60000"}) {
		outputs(t, &f, strings.concatenate({"eDP-1:true:", mhz}))
		run(t, &f, "refresh")
		expect_calls(t, &f)
	}
	// 59499 mHz rounds to 59 Hz and is set.
	outputs(t, &f, "eDP-1:true:59499")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 60))
}

@(test)
fixed_rates_ignore_the_profile :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "refresh", "60")
	profile_is(t, &f, "performance")
	outputs(t, &f, "eDP-1:true:120000")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 60))

	write(t, join(f.bin, "calls"), "")
	set_state(t, &f, "refresh", "120")
	profile_is(t, &f, "power-saver")
	outputs(t, &f, "eDP-1:true:60000")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 120))
}

@(test)
the_active_edp_is_the_one_changed :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	outputs(t, &f, "DP-1:true:144000", "eDP-1:false:120000", "eDP-2:true:120000")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-2", 60))

	// Only the first active one.
	write(t, join(f.bin, "calls"), "")
	outputs(t, &f, "eDP-1:true:120000", "eDP-2:true:120000")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 60))
}

@(test)
no_panel_no_modeset :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	outputs(t, &f, "DP-1:true:120000", "eDP-1:false:120000")
	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
	outputs(t, &f)
	run(t, &f, "refresh")
	expect_calls(t, &f)
}

@(test)
no_sway_no_modeset :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	// The stub fails without a list of outputs, as swaymsg does outside Sway.
	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
	// And no swaymsg at all.
	remove_program(t, &f, "swaymsg")
	code, _, _ = run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
}

@(test)
malformed_outputs_no_modeset :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	for bad in ([]string {
			"not json",
			"",
			"{}",
			"null",
			"[1,2,3]",
			`[{"name":"eDP-1","active":true}]`,
			`[{"name":"eDP-1","active":true,"current_mode":null}]`,
			`[{"name":"eDP-1","active":true,"current_mode":{}}]`,
			`[{"name":"eDP-1","active":true,"current_mode":{"width":"2560","height":1600,"refresh":120000}}]`,
			`[{"name":"eDP-1","active":true,"current_mode":{"width":0,"height":1600,"refresh":120000}}]`,
			`[{"name":"eDP-1","active":true,"current_mode":{"width":2560.5,"height":1600,"refresh":120000}}]`,
			`[{"name":"eDP-1","active":"true","current_mode":{"width":2560,"height":1600,"refresh":120000}}]`,
			`[{"name":5,"active":true,"current_mode":{"width":2560,"height":1600,"refresh":120000}}]`,
			`[{"name":"eDP-1","active":true,"current_mode":{"width":2560,"height":1600,"refresh":120000}}`,
		}) {
		write(t, join(f.bin, "outputs"), bad)
		code, _, _ := run(t, &f, "refresh")
		testing.expectf(t, code == 0, "%q: status %d", bad, code)
		testing.expectf(t, calls(&f) == "", "%q set a mode: %s", bad, calls(&f))
	}
}

@(test)
a_mode_of_eight_outputs_with_odd_fields_still_finds_the_panel :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	// Extra fields, a float refresh, other types in other outputs, a name
	// with escapes.
	write(t, join(f.bin, "outputs"), `[
 "junk", 7, null, {"name":"DP-1","active":true},
 {"name":"eDP-1","active":false,"current_mode":{"width":1,"height":1,"refresh":1}},
 {"name":"eDP-2","active":true,"make":"Xé","modes":[{"width":1}],
  "current_mode":{"width":2560.0,"height":1600,"refresh":119998.5,"picture_aspect_ratio":"none"}}
]`)
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-2", 60))
}

@(test)
an_immense_or_deep_list_of_outputs_is_survived :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")

	// A hundred thousand brackets would overflow a recursive parser.
	deep, _ := strings.repeat("[", 200_000)
	write(t, join(f.bin, "outputs"), deep)
	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)

	// Twenty thousand outputs, the panel last.
	b := strings.builder_make()
	strings.write_string(&b, "[")
	for i in 0 ..< 20_000 {
		strings.write_string(&b, `{"name":"DP-`)
		strings.write_int(&b, i)
		strings.write_string(&b, `","active":true,"current_mode":{"width":1,"height":1,"refresh":1}},`)
	}
	strings.write_string(&b, `{"name":"eDP-1","active":true,"current_mode":{"width":2560,"height":1600,"refresh":120000}}]`)
	write(t, join(f.bin, "outputs"), strings.to_string(b))
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 60))
}

@(test)
a_refresh_rate_that_is_absurd_sets_no_mode :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for refresh in ([]string{"1e300", "-5", "99999999999999999999"}) {
		write(
			t,
			join(f.bin, "outputs"),
			strings.concatenate({`[{"name":"eDP-1","active":true,"current_mode":{"width":2560,"height":1600,"refresh":`, refresh, "}}]"}),
		)
		code, _, _ := run(t, &f, "refresh")
		testing.expectf(t, code == 0, "%s: status %d", refresh, code)
	}
	_ = energy.MAX_JSON_DEPTH
}

@(test)
no_profile_daemon_counts_as_balanced :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	outputs(t, &f, "eDP-1:true:60000")
	flag(t, &f, "busctl.fails")

	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f, mode_call("eDP-1", 120))

	remove_program(t, &f, "busctl")
	write(t, join(f.bin, "calls"), "")
	run(t, &f, "refresh")
	expect_calls(t, &f, mode_call("eDP-1", 120))
}

@(test)
a_failing_modeset_is_the_status :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	outputs(t, &f, "eDP-1:true:60000")
	flag(t, &f, "swaymsg.set-fails")

	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 2)
}

@(test)
a_hung_sway_is_killed_after_the_time_limit :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	f.cfg.timeout = 300 * time.Millisecond
	flag(t, &f, "swaymsg.hangs")

	code, _, _ := run(t, &f, "refresh")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
	// The same for the profile daemon: balanced, as if it were not there.
	res := energy.run_child(&f.cfg, {argv = {"swaymsg", "-t", "get_outputs"}, capture = true})
	testing.expect(t, res.timed_out)
	testing.expect_value(t, res.code, 124)
}

@(test)
a_program_that_prints_too_much_is_killed :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	f.cfg.max_output = 100
	big, _ := strings.repeat("x", 5000)
	write(t, join(f.bin, "outputs"), big)

	res := energy.run_child(&f.cfg, {argv = {"swaymsg", "-t", "get_outputs"}, capture = true})
	testing.expect(t, res.too_much)
	run(t, &f, "refresh")
	expect_calls(t, &f)
}

// idle-suspend

@(test)
idle_suspend_on_battery :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	charger(t, &f, "0")

	code, _, _ := run(t, &f, "idle-suspend")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f, "systemctl suspend")
}

@(test)
idle_suspend_never_on_the_charger :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
}

@(test)
idle_suspend_off_does_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	charger(t, &f, "0")
	set_state(t, &f, "idle_suspend", "off")

	code, _, _ := run(t, &f, "idle-suspend")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
}

@(test)
idle_suspend_waits_for_a_backup_a_download_or_restic :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	charger(t, &f, "0")

	write(t, join(f.bin, "active_units"), "borg-backup.service\n")
	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
	// Another unit does not hold it back (README.md has the finding).
	write(t, join(f.bin, "active_units"), "ravnix-backup.service\n")
	run(t, &f, "idle-suspend")
	expect_calls(t, &f, "systemctl suspend")

	write(t, join(f.bin, "calls"), "")
	write(t, join(f.bin, "active_units"), "")
	write(t, join(f.bin, "running"), "dl-video\n")
	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
	write(t, join(f.bin, "running"), "^restic \n")
	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
}

@(test)
idle_suspend_with_a_missing_or_garbled_charger_file_counts_as_charger :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for text in ([]string{"", "garbage", "00", "0 0", " 0", "-1", "2"}) {
		charger(t, &f, text)
		run(t, &f, "idle-suspend")
		expect_calls(t, &f)
	}
	testing.expect_value(t, os.remove(join(f.bin, "online")), nil)
	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
	// The file of a charger that is a directory.
	make_dirs(t, join(f.bin, "online"))
	run(t, &f, "idle-suspend")
	expect_calls(t, &f)
}

@(test)
idle_suspend_without_systemctl_fails_quietly :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	charger(t, &f, "0")
	remove_program(t, &f, "systemctl")
	remove_program(t, &f, "pgrep")

	code, _, _ := run(t, &f, "idle-suspend")
	testing.expect_value(t, code, 127)
}
