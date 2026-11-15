// menu: one fuzzel row per setting, and one choice list per row.
package energy_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"

fuzzel_log :: proc(f: ^Fixture) -> string {
	text, _ := read_text(join(f.bin, "fuzzel.log"))
	return text
}

expect_shown :: proc(t: ^testing.T, f: ^Fixture, want: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(fuzzel_log(f), want), "fuzzel never showed %q:\n%s", want, fuzzel_log(f), loc = loc)
}

@(test)
menu_escape_does_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	picks(t, &f, "ESC")

	code, _, _ := run(t, &f, "menu")
	testing.expect_value(t, code, 0)
	expect_calls(t, &f)
}

@(test)
no_argument_and_an_empty_one_are_the_menu :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	picks(t, &f, "ESC", "ESC")

	code, _, _ := run(t, &f)
	testing.expect_value(t, code, 0)
	expect_shown(t, &f, "fuzzel [  Energy   ]")
	code, _, _ = run(t, &f, "")
	testing.expect_value(t, code, 0)
}

@(test)
menu_rows_show_the_values :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "power-saver")
	set_run(t, &f, "keep-awake", "1")
	set_state(t, &f, "focus_bar", "on")
	write(t, join(f.bin, "charge_now"), "Long_Life\n")
	picks(t, &f, "ESC")

	run(t, &f, "menu")
	expect_shown(t, &f, "\U000F0F85  Power profile: power-saver")
	expect_shown(t, &f, "\U000F0379  Refresh rate: auto (60 Hz now)")
	expect_shown(t, &f, "\U000F0176  Keep-awake: on")
	expect_shown(t, &f, "\U000F04B2  Idle suspend on battery: on")
	expect_shown(t, &f, "\U000F0084  Charge mode: Long_Life")
	expect_shown(t, &f, "\U000F056E  Focus bar on battery: on")
}

@(test)
menu_without_charge_mode_says_unknown :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	picks(t, &f, "ESC")

	run(t, &f, "menu")
	expect_shown(t, &f, "\U000F0084  Charge mode: unknown")
	// A charge-mode that is gone altogether is the same.
	remove_program(t, &f, "charge-mode")
	picks(t, &f, "ESC")
	write(t, join(f.bin, "fuzzel.n"), "0\n")
	run(t, &f, "menu")
	testing.expect_value(t, strings.count(fuzzel_log(&f), "Charge mode: unknown"), 2)
}

@(test)
menu_sets_each_profile :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for p in ([]string{"power-saver", "performance", "balanced"}) {
		write(t, join(f.bin, "calls"), "")
		write(t, join(f.bin, "fuzzel.n"), "0\n")
		picks(t, &f, "Power profile", p)
		code, _, _ := run(t, &f, "menu")
		testing.expect_value(t, code, 0)
		expect_calls(
			t,
			&f,
			strings.concatenate({"busctl --system set-property net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile s ", p}),
		)
	}
}

@(test)
menu_marks_the_active_profile :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	profile_is(t, &f, "performance")
	picks(t, &f, "Power profile", "ESC")

	run(t, &f, "menu")
	expect_shown(t, &f, "fuzzel [  Power profile   ]")
	expect_shown(t, &f, "| \U000F012C performance")
	expect_shown(t, &f, "|    balanced")
	expect_calls(t, &f)
}

@(test)
a_refused_profile_is_the_menus_status :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	flag(t, &f, "busctl.set-fails")
	picks(t, &f, "Power profile", "performance")

	code, _, err := run(t, &f, "menu")
	// tuned-ppd refuses the switch outside an active session.
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "Unauthorized"), err)
}

@(test)
menu_refresh_rate :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	outputs(t, &f, "eDP-1:true:120000")

	picks(t, &f, "Refresh rate", "60 Hz always")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "refresh"), "60")
	expect_calls(t, &f, mode_call("eDP-1", 60))

	write(t, join(f.bin, "fuzzel.n"), "0\n")
	picks(t, &f, "Refresh rate", "auto")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "refresh"), "auto")
	write(t, join(f.bin, "fuzzel.n"), "0\n")
	picks(t, &f, "Refresh rate", "120 Hz always")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "refresh"), "120")
}

@(test)
menu_keep_awake :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	picks(t, &f, "Keep-awake", "on   (")
	run(t, &f, "menu")
	expect_calls(t, &f, "keep-awake set on")
	write(t, join(f.bin, "calls"), "")
	write(t, join(f.bin, "fuzzel.n"), "0\n")
	picks(t, &f, "Keep-awake", "off  (")
	run(t, &f, "menu")
	expect_calls(t, &f, "keep-awake set off")
}

@(test)
menu_keep_awake_without_keep_awake_says_so :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	picks(t, &f, "Keep-awake", "on   (")
	remove_program(t, &f, "keep-awake")

	code, _, err := run(t, &f, "menu")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "energy: keep-awake is not on the PATH, so keep-awake is unchanged"), err)
	expect_calls(t, &f, "notify-send -a Energy -u critical keep-awake not found keep-awake is unchanged.")
}

@(test)
menu_keep_awake_that_fails_is_the_status :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "keep-awake.status"), "4\n")
	picks(t, &f, "Keep-awake", "on   (")

	code, _, err := run(t, &f, "menu")
	testing.expect_value(t, code, 4)
	testing.expect(t, strings.contains(err, "keep-awake set on failed (exit 4), so keep-awake may still be off"), err)
}

@(test)
menu_idle_suspend_and_focus_bar :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	picks(t, &f, "Idle suspend", "off")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "idle_suspend"), "off")
	write(t, join(f.bin, "fuzzel.n"), "0\n")
	picks(t, &f, "Focus bar", "on   (")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "focus_bar"), "on")
	write(t, join(f.bin, "fuzzel.n"), "0\n")
	picks(t, &f, "Focus bar", "off")
	run(t, &f, "menu")
	expect_file(t, join(f.state, "focus_bar"), "off")
	expect_shown(t, &f, "(suspend after 30 min idle, on battery)")
}

@(test)
menu_charge_mode :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "charge_now"), "Long_Life\n")

	for m in ([]string{"Standard", "Fast", "Long_Life"}) {
		write(t, join(f.bin, "calls"), "")
		write(t, join(f.bin, "fuzzel.n"), "0\n")
		picks(t, &f, "Charge mode", m)
		run(t, &f, "menu")
		expect_calls(t, &f, strings.concatenate({"charge-mode set ", m}))
	}
}

@(test)
menu_escape_in_a_choice_list_does_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for row in ([]string{"Power profile", "Refresh rate", "Keep-awake", "Idle suspend", "Charge mode", "Focus bar"}) {
		write(t, join(f.bin, "fuzzel.n"), "0\n")
		picks(t, &f, row, "ESC")
		code, _, _ := run(t, &f, "menu")
		testing.expect_value(t, code, 0)
	}
	expect_calls(t, &f)
	testing.expect(t, !exists(f.state))
}

@(test)
menu_without_fuzzel_exits_quietly :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	remove_program(t, &f, "fuzzel")

	code, _, err := run(t, &f, "menu")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(err, "fuzzel is not on the PATH"), err)
	expect_calls(t, &f)
}

@(test)
menu_with_a_fuzzel_that_answers_with_something_else_does_nothing :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for answer in ([]string{"", "nonsense", "\U000F0F85  Power profile: power-saver ", "  "}) {
		write(t, join(f.bin, "fuzzel.says"), strings.concatenate({answer, "\n"}))
		code, _, _ := run(t, &f, "menu")
		testing.expectf(t, code == 0, "%q: status %d", answer, code)
	}
	expect_calls(t, &f)
	testing.expect(t, !exists(f.state))
}

@(test)
an_unknown_command_prints_the_usage :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for cmd in ([]string{"bogus", "Menu", "--help", "-h", "get-all"}) {
		code, out, err := run(t, &f, cmd)
		testing.expectf(t, code == 2, "%s: status %d", cmd, code)
		testing.expect_value(t, out, "")
		testing.expect_value(t, err, "usage: energy [menu|watch|refresh|idle-suspend|get KEY|set KEY VALUE]\n")
	}
}
