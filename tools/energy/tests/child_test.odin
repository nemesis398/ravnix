// The programs energy starts: finding them on the PATH, their status, their
// environment, and the panel parser on its own.
package energy_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import energy ".."

@(test)
finds_a_program_like_command_v :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	path := f.cfg.path

	full, ok := energy.find_program(path, "busctl")
	testing.expect(t, ok)
	testing.expect_value(t, full, join(f.bin, "busctl"))

	_, ok = energy.find_program(path, "no-such-tool")
	testing.expect(t, !ok)
	_, ok = energy.find_program(path, "")
	testing.expect(t, !ok)
	_, ok = energy.find_program("", "busctl")
	testing.expect(t, !ok)
	// Empty entries are skipped, not the current directory.
	_, ok = energy.find_program(strings.concatenate({":", f.bin, "::"}), "busctl")
	testing.expect(t, ok)
	// A directory of the name, and a file that is not executable, are no
	// program.
	make_dirs(t, join(f.bin, "adir"))
	_, ok = energy.find_program(path, "adir")
	testing.expect(t, !ok)
	write(t, join(f.bin, "plain"), "x")
	_, ok = energy.find_program(path, "plain")
	testing.expect(t, !ok)
	// A name with a slash is taken as it is.
	_, ok = energy.find_program("", join(f.bin, "busctl"))
	testing.expect(t, ok)
	_, ok = energy.find_program(path, "bin/busctl")
	testing.expect(t, !ok)
	// A dangling link.
	testing.expect_value(t, os.symlink("/no/such/file", join(f.bin, "dangling")), nil)
	_, ok = energy.find_program(path, "dangling")
	testing.expect(t, !ok)
	// A path that is too long for the buffer is no program, not a crash.
	long, _ := strings.repeat("a", 5000)
	_, ok = energy.find_program(path, long)
	testing.expect(t, !ok)
}

@(test)
a_missing_program_is_status_127_and_not_started :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	remove_program(t, &f, "systemctl")

	res := energy.run_child(&f.cfg, {argv = {"systemctl", "suspend"}})
	testing.expect(t, !res.started)
	testing.expect_value(t, res.code, 127)
}

@(test)
a_program_that_is_not_runnable_is_not_started :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	// Executable, but with no interpreter: exec fails after the lookup.
	write(t, join(f.bin, "broken"), "#!/no/such/interpreter\n")
	testing.expect_value(t, os.chmod(join(f.bin, "broken"), {.Read_User, .Write_User, .Execute_User}), nil)
	res := energy.run_child(&f.cfg, {argv = {"broken"}})
	testing.expect(t, !res.started)
	testing.expect_value(t, res.code, 127)
}

@(test)
the_status_of_a_program_and_of_a_signal :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	write(t, join(f.bin, "keep-awake.status"), "7\n")
	res := energy.run_child(&f.cfg, {argv = {"keep-awake", "set", "on"}})
	testing.expect(t, res.started)
	testing.expect_value(t, res.code, 7)

	write(t, join(f.bin, "keep-awake.case"), "kill -9 $$\n")
	res = energy.run_child(&f.cfg, {argv = {"keep-awake", "set", "on"}})
	testing.expect_value(t, res.code, 128 + 9)
}

@(test)
a_child_gets_the_path_of_the_config_and_the_rest_of_the_environment :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "keep-awake.case"), "printf '%s\\n' \"$PATH\" >\"$dir/path\"; printf '%s\\n' \"${HOME:-unset}\" >\"$dir/home\"\n")

	energy.run_child(&f.cfg, {argv = {"keep-awake"}})
	expect_file(t, join(f.bin, "path"), f.cfg.path)
	home, _ := read_text(join(f.bin, "home"))
	testing.expect_value(t, home, os.get_env("HOME", context.allocator) if os.get_env("HOME", context.allocator) != "" else "unset")
}

@(test)
a_program_that_closes_its_output_but_runs_is_still_waited_for :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "keep-awake.case"), "printf 'hello'; exec 1>&-; sleep 0.3; exit 5\n")

	res := energy.run_child(&f.cfg, {argv = {"keep-awake"}, capture = true})
	testing.expect_value(t, string(res.stdout), "hello")
	testing.expect_value(t, res.code, 5)
}

@(test)
a_program_that_exits_leaving_a_daemon_on_its_pipe_does_not_hang :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "keep-awake.case"), "printf 'x'; sleep 3 &\nexit 0\n")

	res := energy.run_child(&f.cfg, {argv = {"keep-awake"}, capture = true})
	testing.expect_value(t, res.code, 0)
	testing.expect_value(t, string(res.stdout), "x")
}

@(test)
rows_reach_the_programs_input :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, join(f.bin, "keep-awake.case"), "while IFS= read -r l; do printf '<%s>' \"$l\"; done\n")

	big, _ := strings.repeat("row\n", 100_000)
	res := energy.run_child(&f.cfg, {argv = {"keep-awake"}, input = big, capture = true})
	testing.expect_value(t, res.code, 0)
	testing.expect_value(t, len(res.stdout), 100_000 * 5)

	// A program that never reads its input and ends does not raise SIGPIPE
	// here.
	write(t, join(f.bin, "keep-awake.case"), "exit 3\n")
	res = energy.run_child(&f.cfg, {argv = {"keep-awake"}, input = big})
	testing.expect_value(t, res.code, 3)
}

// The panel parser

@(test)
finds_the_panel_in_sways_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	list := `[{"name":"DP-1","active":true,"current_mode":{"width":3840,"height":2160,"refresh":60000}},
	  {"name":"eDP-1","active":true,"current_mode":{"width":2560,"height":1600,"refresh":119998}}]`
	panel, ok := energy.find_panel(transmute([]byte)list)
	testing.expect(t, ok)
	testing.expect_value(t, panel, energy.Panel{name = "eDP-1", width = 2560, height = 1600, hz = 120})
}

@(test)
the_depth_check_counts_brackets_outside_strings :: proc(t: ^testing.T) {
	testing.expect(t, energy.json_depth_ok(transmute([]byte)string(`[{"a":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["}]`)))
	testing.expect(t, energy.json_depth_ok(transmute([]byte)string(`["\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["]`)))
	deep, _ := strings.repeat("[", energy.MAX_JSON_DEPTH + 1)
	defer delete(deep)
	testing.expect(t, !energy.json_depth_ok(transmute([]byte)deep))
	ok_depth, _ := strings.repeat("[", energy.MAX_JSON_DEPTH)
	defer delete(ok_depth)
	testing.expect(t, energy.json_depth_ok(transmute([]byte)ok_depth))
	testing.expect(t, energy.json_depth_ok(nil))
}
