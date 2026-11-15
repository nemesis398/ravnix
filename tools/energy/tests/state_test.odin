// get and set: three keys with fixed values, kept in the state directory.
package energy_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import energy ".."

@(test)
defaults_without_state :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for want in ([][2]string{{"refresh", "auto"}, {"idle_suspend", "on"}, {"focus_bar", "off"}}) {
		code, out, _ := run(t, &f, "get", want[0])
		testing.expect_value(t, code, 0)
		testing.expect_value(t, out, strings.concatenate({want[1], "\n"}))
	}
}

@(test)
sets_and_gets_every_value :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for kv in ([][2]string{{"refresh", "auto"}, {"refresh", "120"}, {"refresh", "60"}, {"idle_suspend", "on"}, {"idle_suspend", "off"}, {"focus_bar", "on"}, {"focus_bar", "off"}}) {
		code, _, _ := run(t, &f, "set", kv[0], kv[1])
		testing.expect_value(t, code, 0)
		// The file holds the value and a newline, as Fedora's did.
		data, _ := os.read_entire_file(join(f.state, kv[0]), context.allocator)
		testing.expect_value(t, string(data), strings.concatenate({kv[1], "\n"}))
		_, out, _ := run(t, &f, "get", kv[0])
		testing.expect_value(t, out, strings.concatenate({kv[1], "\n"}))
	}
}

@(test)
set_refuses_other_values :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for kv in ([][2]string {
			{"refresh", "90"},
			{"refresh", "Auto"},
			{"refresh", ""},
			{"idle_suspend", "yes"},
			{"focus_bar", "1"},
			{"bogus", "on"},
			{"refresh", "60 "},
			{"refresh", "../x"},
			{"refresh", "60\n"},
			{"refresh", "on"},
		}) {
		code, _, _ := run(t, &f, "set", kv[0], kv[1])
		testing.expectf(t, code != 0, "accepted %v", kv)
	}
	code, _, err := run(t, &f, "set", "refresh", "90")
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(err, "'90' is not a value for 'refresh'"), err)
	testing.expect(t, !exists(f.state), "wrote state for a refused value")
}

@(test)
set_and_get_need_their_arguments :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	code, _, err := run(t, &f, "set", "refresh")
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(err, "value"), err)
	code, _, err = run(t, &f, "set")
	testing.expect_value(t, code, 2)
	code, _, err = run(t, &f, "get")
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(err, "key"), err)
	code, _, _ = run(t, &f, "get", "")
	testing.expect_value(t, code, 2)
}

// The Bash version died with "unbound variable" on a key that is none of
// the three; now the message names the keys.
@(test)
get_refuses_an_unknown_key :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	code, out, err := run(t, &f, "get", "bogus")
	testing.expect_value(t, code, 2)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(err, "'bogus' is not a key (refresh, idle_suspend, focus_bar)"), err)
	// A key is no path.
	code, _, _ = run(t, &f, "get", "../refresh")
	testing.expect_value(t, code, 2)
}

// The Bash version read an empty file as an empty value (an empty refresh
// counted as auto, an empty idle_suspend as off); a file that holds none of
// the key's values now reads as the default.
@(test)
a_state_file_without_a_value_reads_as_the_default :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for bad in ([]string{"", "bogus", "90", "ON", "on off", "\x00", "6", "60x"}) {
		set_state(t, &f, "refresh", bad)
		set_state(t, &f, "idle_suspend", bad)
		set_state(t, &f, "focus_bar", bad)
		for want in ([][2]string{{"refresh", "auto"}, {"idle_suspend", "on"}, {"focus_bar", "off"}}) {
			_, out, _ := run(t, &f, "get", want[0])
			testing.expectf(t, out == strings.concatenate({want[1], "\n"}), "%q for %s read as %q", bad, want[0], out)
		}
	}
	// No newline, and white space around the value, are fine.
	write(t, join(f.state, "refresh"), "  60 \r\n")
	_, out, _ := run(t, &f, "get", "refresh")
	testing.expect_value(t, out, "60\n")
	write(t, join(f.state, "refresh"), "120")
	_, out, _ = run(t, &f, "get", "refresh")
	testing.expect_value(t, out, "120\n")
	// A completely empty file (zero bytes).
	write(t, join(f.state, "refresh"), "")
	_, out, _ = run(t, &f, "get", "refresh")
	testing.expect_value(t, out, "auto\n")
}

@(test)
a_huge_state_file_is_not_read_whole :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	big, _ := strings.repeat("60\n", 1 << 20)
	write(t, join(f.state, "refresh"), big)
	_, out, _ := run(t, &f, "get", "refresh")
	testing.expect_value(t, out, "auto\n")
}

@(test)
a_directory_or_a_fifo_in_place_of_the_state_file_reads_as_the_default :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	make_dirs(t, join(f.state, "refresh"))
	_, out, _ := run(t, &f, "get", "refresh")
	testing.expect_value(t, out, "auto\n")

	// A FIFO nobody writes to must not block the reader.
	fifo := strings.clone_to_cstring(join(f.state, "focus_bar"))
	testing.expect_value(t, linux.mknod(fifo, {.IFIFO, .IRUSR, .IWUSR}, 0), linux.Errno.NONE)
	_, out, _ = run(t, &f, "get", "focus_bar")
	testing.expect_value(t, out, "off\n")
}

@(test)
set_leaves_nothing_else_in_the_state_directory :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	for _ in 0 ..< 20 {
		code, _, _ := run(t, &f, "set", "refresh", "60")
		testing.expect_value(t, code, 0)
	}
	infos, err := os.read_all_directory_by_path(f.state, context.allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(infos), 1)
	// The file is private to the user, as mktemp made it.
	info, _ := os.stat(join(f.state, "refresh"), context.allocator)
	testing.expect_value(t, info.mode, os.Permissions{.Read_User, .Write_User})
}

// Two sets of one key at once leave one whole value. auto and 60 differ in
// length, so a torn write shows: 60 written over auto is "60\no".
Racer :: struct {
	cfg:   energy.Config,
	value: string,
	go:    ^sync.Barrier,
}

race :: proc(th: ^thread.Thread) {
	r := cast(^Racer)th.data
	key, _ := energy.find_key("refresh")
	sync.barrier_wait(r.go)
	for _ in 0 ..< 200 {
		energy.state_set(&r.cfg, key, r.value)
	}
}

@(test)
two_sets_at_once_leave_one_value :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	set_state(t, &f, "refresh", "auto")

	barrier: sync.Barrier
	sync.barrier_init(&barrier, 3)
	a := Racer{f.cfg, "auto", &barrier}
	b := Racer{f.cfg, "60", &barrier}
	ta, tb := thread.create(race), thread.create(race)
	ta.data, tb.data = &a, &b
	ta.init_context, tb.init_context = context, context
	thread.start(ta)
	thread.start(tb)

	// Reads during the sets see the old value or the new one, never an
	// empty or torn file; get falls back to the default for those, so read
	// the raw file.
	sync.barrier_wait(&barrier)
	torn := 0
	for _ in 0 ..< 2000 {
		data, err := os.read_entire_file(join(f.state, "refresh"), context.temp_allocator)
		if err != nil {
			continue
		}
		if s := string(data); s != "auto\n" && s != "60\n" {
			torn += 1
		}
	}
	thread.join(ta)
	thread.join(tb)
	thread.destroy(ta)
	thread.destroy(tb)
	testing.expect_value(t, torn, 0)
	got, _ := os.read_entire_file(join(f.state, "refresh"), context.allocator)
	testing.expectf(t, string(got) == "auto\n" || string(got) == "60\n", "saved %q", string(got))
	infos, _ := os.read_all_directory_by_path(f.state, context.allocator)
	testing.expect_value(t, len(infos), 1)
}

@(test)
set_into_an_unwritable_place_fails :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	if os.get_uid() == 0 {
		return
	}

	make_dirs(t, f.state)
	testing.expect_value(t, os.chmod(f.state, {.Read_User, .Execute_User}), nil)
	code, _, err := run(t, &f, "set", "refresh", "60")
	_ = os.chmod(f.state, {.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "cannot save refresh"), err)
	// A file where the directory should be.
	_ = os.remove_all(f.state)
	write(t, f.state, "in the way")
	code, _, err = run(t, &f, "set", "refresh", "60")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "cannot make"), err)
}

@(test)
without_a_state_directory_get_gives_the_default_and_set_fails :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	f.cfg.state_dir = ""

	_, out, _ := run(t, &f, "get", "idle_suspend")
	testing.expect_value(t, out, "on\n")
	code, _, err := run(t, &f, "set", "idle_suspend", "off")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "neither XDG_STATE_HOME nor HOME"), err)
}

@(test)
the_state_directory_follows_xdg_then_home :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, energy.state_dir_of("/x/state", "/home/u"), "/x/state/energy")
	testing.expect_value(t, energy.state_dir_of("", "/home/u"), "/home/u/.local/state/energy")
	testing.expect_value(t, energy.state_dir_of("", ""), "")
	testing.expect_value(t, energy.join_path("/t/bin", "/usr/bin:/bin"), "/t/bin:/usr/bin:/bin")
	testing.expect_value(t, energy.join_path("", "/usr/bin"), "/usr/bin")
	testing.expect_value(t, energy.join_path("/t/bin", ""), "/t/bin")
}
