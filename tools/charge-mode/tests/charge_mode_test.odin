// The tests of charge-mode's three programs: the reading of charge_types,
// the helper's checks and writes, the restore's wait, and the user's command
// as far as it runs no child. Each test runs in an arena, as each program
// does, and in a directory of its own under TMPDIR; none touches the real
// battery or the real saved mode. The shell test (tests/bin/charge-mode)
// runs the built programs with sudo, notify-send and Waybar.
package charge_mode_tests

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import cm ".."

// Each test's world: a directory with a fake charge_types and a state
// directory, and the config that points there.
World :: struct {
	arena: virtual.Arena,
	dir:   string,
	cfg:   cm.Config,
}

FIRMWARE :: "Fast Standard [Long_Life]\n"

@(deferred_out = leave)
enter :: proc(t: ^testing.T, firmware: Maybe(string) = FIRMWARE) -> ^World {
	w := new(World)
	if virtual.arena_init_growing(&w.arena) != nil {
		testing.fail_now(t, "no arena")
	}
	context.allocator = virtual.arena_allocator(&w.arena)
	base, terr := os.temp_directory(context.allocator)
	testing.expect_value(t, terr, nil)
	dir, err := os.make_directory_temp(base, "charge-mode-test-*", context.allocator)
	if err != nil {
		testing.fail_now(t, "no temporary directory")
	}
	w.dir = dir
	must(t, os.make_directory(path(w, "BAT0")))
	make_private_dir(t, path(w, "state"))
	w.cfg = cm.Config {
		attr       = path(w, "BAT0/charge_types"),
		state      = path(w, "state/charge-mode"),
		helper     = path(w, "no-helper"),
		euid       = int(linux.geteuid()),
		wait_tries = 20,
		wait_step  = time.Millisecond,
	}
	if text, ok := firmware.?; ok {
		put(t, w.cfg.attr, text)
	}
	return w
}

leave :: proc(w: ^World) {
	// Undo what a test made unwritable, so the directory can go.
	linux.chmod(strings.clone_to_cstring(w.cfg.attr, virtual.arena_allocator(&w.arena)), {.IRUSR, .IWUSR})
	linux.chmod(strings.clone_to_cstring(path(w, "state"), virtual.arena_allocator(&w.arena)), {.IRUSR, .IWUSR, .IXUSR})
	os.remove_all(w.dir)
	virtual.arena_destroy(&w.arena)
	free(w)
}

path :: proc(w: ^World, rel: string) -> string {
	return strings.concatenate({w.dir, "/", rel}, virtual.arena_allocator(&w.arena))
}

// make_private_dir makes a directory of 0755, whatever the umask: writable
// by its owner alone, as the helper wants the directory of the saved mode.
make_private_dir :: proc(t: ^testing.T, dir: string, loc := #caller_location) {
	must(t, os.make_directory(dir), loc)
	testing.expect_value(t, linux.chmod(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}), linux.Errno.NONE, loc = loc)
}

must :: proc(t: ^testing.T, err: os.Error, loc := #caller_location) {
	testing.expect_value(t, err, nil, loc = loc)
}

put :: proc(t: ^testing.T, file, text: string, loc := #caller_location) {
	must(t, os.write_entire_file(file, transmute([]byte)text), loc)
}

content :: proc(file: string) -> string {
	data, err := os.read_entire_file(file, context.allocator)
	if err != nil {
		return "<no file>"
	}
	return string(data)
}

// apply runs the helper's procedure; it returns the status and what it said.
apply :: proc(w: ^World, args: ..string) -> (int, string) {
	context.allocator = virtual.arena_allocator(&w.arena)
	context.temp_allocator = context.allocator
	b := strings.builder_make()
	status := cm.run_apply(args, w.cfg, strings.to_writer(&b))
	return status, strings.to_string(b)
}

user :: proc(w: ^World, args: ..string) -> (status: int, out, err: string) {
	context.allocator = virtual.arena_allocator(&w.arena)
	context.temp_allocator = context.allocator
	o := strings.builder_make()
	e := strings.builder_make()
	status = cm.run_user(args, w.cfg, strings.to_writer(&o), strings.to_writer(&e))
	return status, strings.to_string(o), strings.to_string(e)
}

restore :: proc(w: ^World) -> (cm.Restore, string) {
	context.allocator = virtual.arena_allocator(&w.arena)
	context.temp_allocator = context.allocator
	b := strings.builder_make()
	plan := cm.plan_restore(w.cfg, strings.to_writer(&b))
	return plan, strings.to_string(b)
}

// Reading charge_types.

@(test)
the_active_mode_is_the_bracketed_one :: proc(t: ^testing.T) {
	testing.expect_value(t, cm.current_mode("Fast Standard [Long_Life]\n"), "Long_Life")
	testing.expect_value(t, cm.current_mode("Fast [Standard] Long_Life\n"), "Standard")
	testing.expect_value(t, cm.current_mode("[Fast] Standard Long_Life"), "Fast")
	testing.expect_value(t, cm.current_mode("Fast Standard Long_Life\n"), "unknown")
	testing.expect_value(t, cm.current_mode(""), "unknown")
	testing.expect_value(t, cm.current_mode("[Fast Standard"), "unknown")
	testing.expect_value(t, cm.current_mode("Fast] [Standard"), "unknown")
	// Between the first [ and the first ] after it, as the shell cut it.
	testing.expect_value(t, cm.current_mode("a]b[c]d[e]"), "c")
	testing.expect_value(t, cm.current_mode("[]"), "")
	testing.expect_value(t, cm.current_mode("[Fa\nst]"), "Fa\nst")
}

@(test)
the_modes_are_the_firmwares_words :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expect_list(t, cm.offered_modes("Fast Standard [Long_Life]\n"), {"Fast", "Standard", "Long_Life"})
	expect_list(t, cm.offered_modes("[Standard] Adaptive\n"), {"Standard", "Adaptive"})
	expect_list(t, cm.offered_modes("  Fast  \n\n[]\n"), {"Fast"})
	expect_list(t, cm.offered_modes(""), {})
	// Only spaces and line ends split, as tr ' ' '\n' did.
	expect_list(t, cm.offered_modes("Fa\tst Standard"), {"Fa\tst", "Standard"})
}

expect_list :: proc(t: ^testing.T, got, want: []string, loc := #caller_location) {
	testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want, loc = loc)
	for i in 0 ..< min(len(got), len(want)) {
		testing.expect_value(t, got[i], want[i], loc = loc)
	}
}

@(test)
only_a_word_the_kernel_lists_is_offered :: proc(t: ^testing.T) {
	for m in ([]string{"Fast", "Standard", "Long_Life"}) {
		testing.expectf(t, cm.is_offered(FIRMWARE, m), "%s is refused", m)
	}
	refused := []string {
		"",
		"Bogus",
		// Part of a word is no word.
		"Fas",
		"ast",
		"Long",
		"_",
		"FastFast",
		"long_life",
		"[Long_Life]",
		"Long_Life]",
		"Long_Life Fast",
		"Long_Life ",
		" Fast",
		"Fast\n",
		"Fast\nStandard",
		"Fa\x00st",
		"Fast\t",
		"*",
		"?ast",
		"F*",
		"-n",
		"Fast;id",
		"../Fast",
		"Fast Standard [Long_Life]",
		"Standard Long_Life",
	}
	for m in refused {
		testing.expectf(t, !cm.is_offered(FIRMWARE, m), "%q is offered", m)
	}
	// Tabs split the kernel's words as the shell's IFS did.
	testing.expect(t, cm.is_offered("Fast\tStandard", "Standard"))
	testing.expect(t, !cm.is_offered("", "Fast"))
	testing.expect(t, !cm.is_offered("[]", ""))
}

@(test)
the_cycle_goes_long_life_standard_fast :: proc(t: ^testing.T) {
	testing.expect_value(t, cm.next_mode("Long_Life"), "Standard")
	testing.expect_value(t, cm.next_mode("Standard"), "Fast")
	testing.expect_value(t, cm.next_mode("Fast"), "Long_Life")
	testing.expect_value(t, cm.next_mode("unknown"), "Long_Life")
	testing.expect_value(t, cm.next_mode(""), "Long_Life")
	testing.expect_value(t, cm.describe("Bogus"), "")
	testing.expect_value(t, cm.describe("Standard"), "Charges to 100% at the normal rate.")
}

@(test)
a_shown_argument_is_one_short_line :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, cm.shown("Fast"), "Fast")
	testing.expect_value(t, cm.shown("Fa\nst\x1b[31m\r\t"), "Fa\\x0ast\\x1b[31m\\x0d\\x09")
	testing.expect_value(t, cm.shown("a\\b"), "a\\x5cb")
	testing.expect_value(t, cm.shown("Fäst"), "F\\xc3\\xa4st")
	huge := strings.repeat("x", 100_000)
	s := cm.shown(huge)
	testing.expect(t, len(s) < 100)
	testing.expect(t, strings.has_suffix(s, "... (100000 bytes)"))
	testing.expect_value(t, cm.shown(strings.repeat("y", 64)), strings.repeat("y", 64))
}

@(test)
reading_refuses_what_is_no_small_file :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	data, res, _ := cm.read_small(w.cfg.attr, cm.MAX_ROOT_READ, false)
	testing.expect_value(t, res, cm.Read_Result.Ok)
	testing.expect_value(t, string(data), FIRMWARE)

	_, res, _ = cm.read_small(path(w, "missing"), 10, false)
	testing.expect_value(t, res, cm.Read_Result.Missing)
	_, res, _ = cm.read_small(path(w, "BAT0/charge_types/below"), 10, false)
	testing.expect_value(t, res, cm.Read_Result.Missing)
	_, res, _ = cm.read_small(path(w, "BAT0"), 10, false)
	testing.expect_value(t, res, cm.Read_Result.Not_File)

	must(t, os.symlink(w.cfg.attr, path(w, "link")))
	_, res, _ = cm.read_small(path(w, "link"), 4096, false)
	testing.expect_value(t, res, cm.Read_Result.Symlink)
	data, res, _ = cm.read_small(path(w, "link"), 4096, true)
	testing.expect_value(t, res, cm.Read_Result.Ok)
	testing.expect_value(t, string(data), FIRMWARE)
	// A dangling link is no file to follow.
	must(t, os.symlink(path(w, "nowhere"), path(w, "dangling")))
	_, res, _ = cm.read_small(path(w, "dangling"), 10, true)
	testing.expect_value(t, res, cm.Read_Result.Missing)

	// A FIFO in the file's place is refused, not waited on.
	fifo := strings.clone_to_cstring(path(w, "fifo"))
	testing.expect_value(t, linux.mknod(fifo, {.IFIFO, .IRUSR, .IWUSR}, 0), linux.Errno.NONE)
	_, res, _ = cm.read_small(path(w, "fifo"), 10, true)
	testing.expect_value(t, res, cm.Read_Result.Not_File)

	put(t, path(w, "exact"), strings.repeat("x", 4096))
	data, res, _ = cm.read_small(path(w, "exact"), 4096, false)
	testing.expect_value(t, res, cm.Read_Result.Ok)
	testing.expect_value(t, len(data), 4096)
	put(t, path(w, "over"), strings.repeat("x", 4097))
	_, res, _ = cm.read_small(path(w, "over"), 4096, false)
	testing.expect_value(t, res, cm.Read_Result.Too_Big)
	put(t, path(w, "empty"), "")
	data, res, _ = cm.read_small(path(w, "empty"), 4096, false)
	testing.expect_value(t, res, cm.Read_Result.Ok)
	testing.expect_value(t, len(data), 0)
}

// The seams.

@(test)
only_a_caller_without_root_moves_the_paths :: proc(t: ^testing.T) {
	user :: cm.Credentials{uid = 1000, euid = 1000, gid = 100, egid = 100}
	testing.expect(t, cm.seams_allowed(user))
	root := user
	root.uid, root.euid = 0, 0
	testing.expect(t, !cm.seams_allowed(root))
	c := user
	c.euid = 0
	testing.expect(t, !cm.seams_allowed(c))
	c = user
	c.uid = 0
	testing.expect(t, !cm.seams_allowed(c))
	// A capability is privilege too, whatever the uid.
	c = user
	c.capabilities = 1 << 1
	testing.expect(t, !cm.seams_allowed(c))
	c.capabilities = max(u64)
	testing.expect(t, !cm.seams_allowed(c))
	// So is a setuid or setgid exec to anyone else: the caller would aim the
	// helper's write at what that uid or gid may write.
	c = user
	c.euid = 1001
	testing.expect(t, !cm.seams_allowed(c))
	c = user
	c.uid = 1001
	testing.expect(t, !cm.seams_allowed(c))
	c = user
	c.egid = 101
	testing.expect(t, !cm.seams_allowed(c))
	c = user
	c.gid = 101
	testing.expect(t, !cm.seams_allowed(c))
	// gid 0 alone is no root, as long as it is the caller's own.
	c = user
	c.gid, c.egid = 0, 0
	testing.expect(t, cm.seams_allowed(c))
	// The process's own credentials: in the check the tests run without
	// privilege; run as root, they must not allow the seams.
	own := cm.current_credentials()
	testing.expect_value(t, cm.seams_allowed(own), own.uid != 0 && own.euid != 0 && own.uid == own.euid && own.gid == own.egid && own.capabilities == 0)
	if linux.getuid() != 0 {
		testing.expect(t, cm.seams_allowed(own))
	}
}

@(test)
the_fixed_paths_are_the_systems :: proc(t: ^testing.T) {
	testing.expect_value(t, cm.ATTR, "/sys/class/power_supply/BAT0/charge_types")
	testing.expect_value(t, cm.STATE, "/var/lib/charge-mode")
	dir, base := cm.split_path(cm.STATE)
	testing.expect_value(t, dir, "/var/lib")
	testing.expect_value(t, base, "charge-mode")
	dir, base = cm.split_path("/x")
	testing.expect_value(t, dir, "/")
	testing.expect_value(t, base, "x")
	dir, base = cm.split_path("x")
	testing.expect_value(t, dir, ".")
	testing.expect_value(t, base, "x")
}

// charge-mode-apply.

@(test)
apply_writes_the_mode_and_saves_it :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	status, said := apply(w, "Fast")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, said, "")
	// The attribute gets the mode without a line end, as sysfs wants it.
	testing.expect_value(t, content(w.cfg.attr), "Fast")
	testing.expect_value(t, content(w.cfg.state), "Fast\n")
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(w.cfg.state), &st)
	testing.expect_value(t, transmute(u32)(st.mode & {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}), 0o644)
	expect_only_the_state(t, w)
}

@(test)
apply_save_only_leaves_the_live_mode :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	// --save-only reads the attribute and never opens it for writing.
	linux.chmod(strings.clone_to_cstring(w.cfg.attr), {.IRUSR})
	status, _ := apply(w, "--save-only", "Standard")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
	testing.expect_value(t, content(w.cfg.state), "Standard\n")
}

// expect_untouched: a refusal leaves the attribute and the saved mode.
expect_untouched :: proc(t: ^testing.T, w: ^World, saved: string, loc := #caller_location) {
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE, loc = loc)
	testing.expect_value(t, content(w.cfg.state), saved, loc = loc)
}

// expect_only_the_state: no temporary file is left beside the saved mode.
expect_only_the_state :: proc(t: ^testing.T, w: ^World, loc := #caller_location) {
	entries, _ := os.read_all_directory_by_path(path(w, "state"), context.allocator)
	names := make([dynamic]string)
	for e in entries {
		append(&names, e.name)
	}
	testing.expectf(t, len(names) <= 1, "beside the saved mode: %v", names, loc = loc)
}

@(test)
apply_refuses_what_the_firmware_does_not_offer :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	for mode in ([]string{"Bogus", "long_life", "[Long_Life]", "Long_Life Fast", "Long_Life ", "*", "?ast", "-n", "Fast;id", "../Fast", "Fast\n", "\x1b[2J"}) {
		for save_only in ([]bool{false, true}) {
			status: int
			said: string
			if save_only {
				status, said = apply(w, "--save-only", mode)
			} else {
				status, said = apply(w, mode)
			}
			testing.expectf(t, status == 2, "%q: exit %d", mode, status)
			testing.expectf(t, strings.contains(said, "is not offered by this firmware"), "%q: %s", mode, said)
			testing.expectf(t, strings.contains(said, "\n  offered: Fast Standard Long_Life\n"), "%q: %s", mode, said)
			testing.expectf(t, strings.count(said, "\n") == 2, "%q: the refusal is not two lines: %q", mode, said)
			expect_untouched(t, w, "Long_Life\n")
		}
	}
	status, said := apply(w, strings.repeat("x", 100_000))
	testing.expect_value(t, status, 2)
	testing.expect(t, len(said) < 300)
	expect_untouched(t, w, "Long_Life\n")
}

@(test)
apply_needs_one_mode :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	for args in ([][]string{{}, {""}, {"--save-only"}, {"--save-only", ""}, {"", "Fast"}}) {
		status, said := apply(w, ..args)
		testing.expectf(t, status == 2, "%v: exit %d", args, status)
		testing.expectf(t, strings.contains(said, "no mode given"), "%v: %s", args, said)
		expect_untouched(t, w, "Long_Life\n")
	}
	for args in ([][]string{{"Fast", "Standard"}, {"Fast", "/tmp/elsewhere"}, {"Fast", "--save-only"}, {"--save-only", "--save-only", "Fast"}, {"--save-only", "Fast", "x"}}) {
		status, said := apply(w, ..args)
		testing.expectf(t, status == 2, "%v: exit %d", args, status)
		testing.expectf(t, strings.contains(said, "takes one mode"), "%v: %s", args, said)
		expect_untouched(t, w, "Long_Life\n")
	}
}

@(test)
apply_refuses_an_attribute_that_is_not_as_it_should_be :: proc(t: ^testing.T) {
	w := enter(t, nil)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	status, said := apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, said, fmt.tprintf("charge-mode-apply: no %s\n", w.cfg.attr))
	// No attribute is checked before the arguments, as the Bash helper did.
	status, _ = apply(w)
	testing.expect_value(t, status, 1)

	put(t, path(w, "elsewhere"), FIRMWARE)
	must(t, os.symlink(path(w, "elsewhere"), w.cfg.attr))
	status, said = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "is a symlink"))
	testing.expect_value(t, content(path(w, "elsewhere")), FIRMWARE)
	must(t, os.remove(w.cfg.attr))

	must(t, os.make_directory(w.cfg.attr))
	status, said = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "is not a file"))
	must(t, os.remove(w.cfg.attr))

	put(t, w.cfg.attr, strings.concatenate({FIRMWARE, strings.repeat("x", 5000)}))
	status, said = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "more than 4096 bytes"))
	testing.expect_value(t, content(w.cfg.state), "Long_Life\n")
}

@(test)
apply_saves_nothing_when_the_write_fails :: proc(t: ^testing.T) {
	if linux.geteuid() == 0 {
		// Root writes a read-only file.
		return
	}
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	linux.chmod(strings.clone_to_cstring(w.cfg.attr), {.IRUSR})
	status, said := apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "cannot write"))
	expect_untouched(t, w, "Long_Life\n")
}

@(test)
apply_refuses_a_state_that_is_not_as_it_should_be :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)

	// The saved mode is a symlink: refused, neither followed nor replaced.
	put(t, path(w, "target"), "keep\n")
	must(t, os.symlink(path(w, "target"), w.cfg.state))
	status, said := apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "is a symlink"))
	testing.expect_value(t, content(path(w, "target")), "keep\n")
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
	must(t, os.remove(w.cfg.state))

	// A directory in its place: the Bash helper's mv moved the mode into it.
	must(t, os.make_directory(w.cfg.state))
	status, said = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "is not a file"))
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
	entries, _ := os.read_all_directory_by_path(w.cfg.state, context.allocator)
	testing.expect_value(t, len(entries), 0)
	must(t, os.remove(w.cfg.state))
}

@(test)
apply_refuses_a_state_directory_that_is_not_as_it_should_be :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	state_dir := path(w, "state")

	// Others may write it: they could swap the temporary file or the rename.
	for bits in ([]linux.Mode{{.IWGRP}, {.IWOTH}, {.IWOTH, .ISVTX}}) {
		linux.chmod(strings.clone_to_cstring(state_dir), {.IRUSR, .IWUSR, .IXUSR} + bits)
		status, said := apply(w, "Fast")
		testing.expect_value(t, status, 1)
		testing.expect(t, strings.contains(said, "writable by others"))
		testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
	}
	linux.chmod(strings.clone_to_cstring(state_dir), {.IRUSR, .IWUSR, .IXUSR})

	// A symlink to a directory.
	must(t, os.remove(state_dir))
	make_private_dir(t, path(w, "real-state"))
	must(t, os.symlink(path(w, "real-state"), state_dir))
	status, said := apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "is a symlink"))
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
	entries, _ := os.read_all_directory_by_path(path(w, "real-state"), context.allocator)
	testing.expect_value(t, len(entries), 0)
	must(t, os.remove(state_dir))

	// None at all: the Bash helper wrote the attribute and then failed.
	status, said = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect(t, strings.contains(said, "no directory"))
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)

	// A file where the directory should be.
	put(t, state_dir, "")
	status, _ = apply(w, "Fast")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
}

@(test)
apply_saves_past_a_temporary_file_left_behind :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	// A crash between the create and the rename leaves one; the next run
	// takes another name.
	put(t, path(w, fmt.tprintf("state/charge-mode.tmp-%d-0", linux.getpid())), "Fa")
	status, _ := apply(w, "--save-only", "Fast")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, content(w.cfg.state), "Fast\n")
}

// Two clicks at once must leave one whole mode saved, never a torn file
// ("Fast" over "Standard" reads "Fast\nard") that the boot restore would
// then refuse. The Bash helper's plain redirect tore it in 43 of 1000 rounds.
@(test)
two_applies_at_once_leave_one_mode :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	Racer :: struct {
		cfg:  cm.Config,
		mode: string,
		go_:  ^sync.Barrier,
		ok:   bool,
	}
	race :: proc(r: ^Racer) {
		arena: virtual.Arena
		_ = virtual.arena_init_growing(&arena)
		defer virtual.arena_destroy(&arena)
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator
		b := strings.builder_make()
		sync.barrier_wait(r.go_)
		r.ok = cm.run_apply({"--save-only", r.mode}, r.cfg, strings.to_writer(&b)) == 0
	}
	for round in 0 ..< 200 {
		barrier: sync.Barrier
		sync.barrier_init(&barrier, 2)
		a := Racer{w.cfg, "Fast", &barrier, false}
		b := Racer{w.cfg, "Standard", &barrier, false}
		ta := thread.create_and_start_with_poly_data(&a, race)
		tb := thread.create_and_start_with_poly_data(&b, race)
		thread.join(ta)
		thread.join(tb)
		thread.destroy(ta)
		thread.destroy(tb)
		got := content(w.cfg.state)
		testing.expectf(t, a.ok && b.ok, "round %d: a write failed", round)
		if !testing.expectf(t, got == "Fast\n" || got == "Standard\n", "round %d saved %q", round, got) {
			return
		}
	}
	expect_only_the_state(t, w)
}

// charge-mode-restore.

@(test)
restore_passes_the_saved_mode_on :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	plan, said := restore(w)
	testing.expect_value(t, plan, cm.Restore{run = true, mode = "Long_Life"})
	testing.expect_value(t, said, "")
	// Unchecked: the helper judges it, as it judges every caller's.
	for saved in ([]string{"Bogus\n", "Fast\n\n\n", "Fast\nard\n", " Fast", "Fast"}) {
		put(t, w.cfg.state, saved)
		plan, _ = restore(w)
		testing.expect(t, plan.run)
		testing.expect_value(t, plan.mode, strings.trim_right(saved, "\n"))
	}
}

@(test)
restore_without_a_saved_mode_does_nothing :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	plan, said := restore(w)
	testing.expect_value(t, plan, cm.Restore{})
	testing.expect_value(t, said, "")
	for saved in ([]string{"", "\n", "\n\n"}) {
		put(t, w.cfg.state, saved)
		plan, said = restore(w)
		testing.expect_value(t, plan, cm.Restore{})
		testing.expect_value(t, said, "")
	}
	if linux.geteuid() != 0 {
		put(t, w.cfg.state, "Fast\n")
		linux.chmod(strings.clone_to_cstring(w.cfg.state), {})
		plan, said = restore(w)
		testing.expect_value(t, plan, cm.Restore{})
		testing.expect_value(t, said, "")
	}
}

@(test)
restore_refuses_a_saved_mode_that_is_not_as_it_should_be :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, path(w, "target"), "Fast\n")
	must(t, os.symlink(path(w, "target"), w.cfg.state))
	plan, said := restore(w)
	testing.expect_value(t, plan, cm.Restore{status = 1})
	testing.expect(t, strings.contains(said, "is a symlink"))
	must(t, os.remove(w.cfg.state))

	must(t, os.make_directory(w.cfg.state))
	plan, said = restore(w)
	testing.expect_value(t, plan, cm.Restore{status = 1})
	testing.expect(t, strings.contains(said, "is not a file"))
	must(t, os.remove(w.cfg.state))

	put(t, w.cfg.state, strings.repeat("x", 100_000))
	plan, said = restore(w)
	testing.expect_value(t, plan, cm.Restore{status = 2})
	testing.expect(t, strings.contains(said, "more than 4096 bytes"))

	// The Bash restore's $(cat) dropped the NUL and passed "Fast" on.
	put(t, w.cfg.state, "Fa\x00st\n")
	plan, said = restore(w)
	testing.expect_value(t, plan, cm.Restore{status = 2})
	testing.expect(t, strings.contains(said, "NUL"))
}

@(test)
restore_waits_for_a_late_attribute :: proc(t: ^testing.T) {
	w := enter(t, nil)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	w.cfg.wait_step = 20 * time.Millisecond
	Late :: struct {
		attr: string,
	}
	appear :: proc(l: ^Late) {
		time.sleep(70 * time.Millisecond)
		_ = os.write_entire_file(l.attr, transmute([]byte)string(FIRMWARE))
	}
	late := Late{w.cfg.attr}
	th := thread.create_and_start_with_poly_data(&late, appear)
	start := time.tick_now()
	plan, said := restore(w)
	took := time.tick_since(start)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, plan, cm.Restore{run = true, mode = "Long_Life"})
	testing.expect_value(t, said, "")
	testing.expectf(t, took >= 60 * time.Millisecond && took < 400 * time.Millisecond, "took %v", took)
}

@(test)
restore_gives_up_after_its_tries :: proc(t: ^testing.T) {
	w := enter(t, nil)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, w.cfg.state, "Long_Life\n")
	w.cfg.wait_step = 5 * time.Millisecond
	start := time.tick_now()
	plan, said := restore(w)
	took := time.tick_since(start)
	// Exit 0: another laptop, or a kernel that renamed it, is no failure.
	testing.expect_value(t, plan, cm.Restore{})
	testing.expect_value(t, said, fmt.tprintf("charge-mode-restore: %s never appeared\n", w.cfg.attr))
	// 20 waits.
	testing.expectf(t, took >= 100 * time.Millisecond, "gave up after %v", took)
	// The system's own is 20 waits of half a second, 10 s at most.
	sys := cm.system_config()
	testing.expect_value(t, sys.wait_tries, 20)
	testing.expect_value(t, sys.wait_step, 500 * time.Millisecond)
}

// charge-mode, the user's command, as far as it runs no child: no sudo on
// the PATH and no notify-send.

@(test)
without_charge_types_every_command_does_nothing :: proc(t: ^testing.T) {
	w := enter(t, nil)
	context.allocator = virtual.arena_allocator(&w.arena)
	for args in ([][]string{{}, {"show"}, {"cycle"}, {"set", "Fast"}, {"default"}, {"default", "Fast"}, {"modes"}, {"help"}, {"bogus"}}) {
		status, out, err := user(w, ..args)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, out, "")
		testing.expect_value(t, err, fmt.tprintf("charge-mode: no %s on this machine; nothing to do\n", w.cfg.attr))
	}
}

@(test)
the_user_reads_the_mode_and_the_offer :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	for args in ([][]string{{}, {""}, {"show"}, {"status"}, {"show", "extra"}}) {
		status, out, _ := user(w, ..args)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, out, "Long_Life\n")
	}
	status, out, _ := user(w, "modes")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "Fast\nStandard\nLong_Life\n")
	put(t, w.cfg.attr, "")
	_, out, _ = user(w)
	testing.expect_value(t, out, "unknown\n")
	_, out, _ = user(w, "modes")
	testing.expect_value(t, out, "")
}

@(test)
the_user_prints_the_saved_mode :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	_, out, _ := user(w, "default")
	testing.expect_value(t, out, "(nothing saved)\n")
	put(t, w.cfg.state, "Long_Life\n")
	_, out, _ = user(w, "default")
	testing.expect_value(t, out, "Long_Life\n")
	_, out, _ = user(w, "default", "")
	testing.expect_value(t, out, "Long_Life\n")
	// As cat printed it: an empty file prints nothing.
	put(t, w.cfg.state, "")
	_, out, _ = user(w, "default")
	testing.expect_value(t, out, "")
}

@(test)
the_user_gets_usage_and_refusals :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	for h in ([]string{"help", "-h", "--help"}) {
		status, out, _ := user(w, h)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, out, fmt.tprintf("%s\n", cm.USAGE))
	}
	status, _, err := user(w, "bogus")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, err, "charge-mode: unknown command 'bogus' (try --help)\n")
	status, _, err = user(w, "set")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, err, "charge-mode: 'set' needs a mode. Offered now: Fast Standard Long_Life \n")
	status, _, err = user(w, "set", "")
	testing.expect_value(t, status, 2)
}

@(test)
the_user_needs_the_helper :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	for args in ([][]string{{"set", "Fast"}, {"cycle"}, {"default", "Fast"}}) {
		status, out, err := user(w, ..args)
		testing.expect_value(t, status, 1)
		testing.expect_value(t, out, "")
		testing.expect(t, strings.has_prefix(err, fmt.tprintf("charge-mode: %s is missing.\n", w.cfg.helper)))
	}
	// A directory or a file it may not run is no helper either.
	w.cfg.helper = path(w, "state")
	status, _, _ := user(w, "set", "Fast")
	testing.expect_value(t, status, 1)
	put(t, path(w, "plain"), "")
	w.cfg.helper = path(w, "plain")
	status, _, _ = user(w, "set", "Fast")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, content(w.cfg.attr), FIRMWARE)
}

@(test)
the_user_without_sudo_is_told_so :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	put(t, path(w, "helper"), "")
	linux.chmod(strings.clone_to_cstring(path(w, "helper")), {.IRUSR, .IXUSR})
	w.cfg.helper = path(w, "helper")
	w.cfg.path = path(w, "BAT0")
	status, out, err := user(w, "set", "Standard")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "")
	testing.expect_value(t, err, "charge-mode: no sudo on the PATH; on NixOS the setuid one is /run/wrappers/bin/sudo.\n")
}

@(test)
sudos_words_name_the_cause :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(cm.hint_for("sudo: a password is required"), "no sudo rule lets you run the helper"))
	testing.expect(t, strings.has_prefix(cm.hint_for("sudo: /run/current-system/sw/bin/sudo must be owned by uid 0 and have the setuid bit set"), "this sudo is not the setuid one"))
	testing.expect(t, strings.has_prefix(cm.hint_for("sudo: effective uid is not 0, is sudo installed setuid root?"), "this sudo is not the setuid one"))
	testing.expect_value(t, cm.hint_for(""), "")
	testing.expect_value(t, cm.hint_for("charge-mode-apply: 'Bogus' is not offered by this firmware"), "")
	// The password comes first, as the shell's case did.
	testing.expect(t, strings.has_prefix(cm.hint_for("a password is required; setuid bit"), "no sudo rule"))
}

@(test)
sudo_is_found_on_the_path_and_never_in_the_working_directory :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	must(t, os.make_directory(path(w, "a")))
	must(t, os.make_directory(path(w, "b")))
	must(t, os.make_directory(path(w, "a/sudo")))
	put(t, path(w, "b/sudo"), "")
	linux.chmod(strings.clone_to_cstring(path(w, "b/sudo")), {.IRUSR})
	put(t, path(w, "c-sudo"), "")
	_, found := cm.find_on_path("sudo", strings.join({path(w, "a"), path(w, "b")}, ":"))
	testing.expect(t, !found)
	linux.chmod(strings.clone_to_cstring(path(w, "b/sudo")), {.IRUSR, .IXUSR})
	got, ok := cm.find_on_path("sudo", strings.join({"", ".", "relative", path(w, "a"), fmt.tprintf("%s/", path(w, "b"))}, ":"))
	testing.expect(t, ok)
	testing.expect_value(t, got, path(w, "b/sudo"))
	_, found = cm.find_on_path("sudo", "")
	testing.expect(t, !found)
}

@(test)
sudo_gets_the_c_locale :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expect_list(t, cm.env_with({"PATH=/bin", "LC_ALL=de_DE.UTF-8", "LC_ALLX=1", "LC_ALL="}, "LC_ALL", "C"), {"PATH=/bin", "LC_ALLX=1", "LC_ALL=C"})
	expect_list(t, cm.env_with({}, "LC_ALL", "C"), {"LC_ALL=C"})
}

// The Waybar refresh.

@(test)
the_refresh_picks_the_users_waybar_by_name :: proc(t: ^testing.T) {
	w := enter(t)
	context.allocator = virtual.arena_allocator(&w.arena)
	proc_ :: proc(t: ^testing.T, w: ^World, pid: int, comm, uid: string) {
		dir := path(w, fmt.tprintf("proc/%d", pid))
		must(t, os.make_directory_all(dir))
		put(t, fmt.tprintf("%s/comm", dir), comm)
		if uid != "" {
			put(t, fmt.tprintf("%s/status", dir), fmt.tprintf("Name:\t%s\nUmask:\t0022\nUid:\t%s\nGid:\t100\t100\t100\t100\n", comm, uid))
		}
	}
	proc_(t, w, 10, "waybar\n", "1000\t1000\t1000\t1000")
	proc_(t, w, 11, ".waybar-wrapped\n", "1000\t1000\t1000\t1000")
	proc_(t, w, 12, "waybar-launch\n", "1000\t1000\t1000\t1000")
	proc_(t, w, 13, "waybar-powerdraw\n", "1000\t1000\t1000\t1000")
	proc_(t, w, 14, "waybar\n", "1001\t1001\t1001\t1001")
	// Real uid the user's, effective another: pkill -u went by the
	// effective one.
	proc_(t, w, 15, "waybar\n", "1000\t0\t0\t0")
	proc_(t, w, 16, "waybar\n", "0\t1000\t1000\t1000")
	proc_(t, w, 17, "waybar\n", "")
	proc_(t, w, 18, "waybar\n", "garbage")
	proc_(t, w, 19, "waybar", "1000\t1000\t1000\t1000")
	proc_(t, w, 20, "Waybar\n", "1000\t1000\t1000\t1000")
	proc_(t, w, 21, "", "1000\t1000\t1000\t1000")
	root := path(w, "proc")
	want := []int{10, 11, 16, 19}
	for pid in 10 ..= 22 {
		testing.expectf(t, cm.is_waybar(root, pid, 1000) == slice.contains(want, pid), "pid %d", pid)
	}
	testing.expect_value(t, cm.WAYBAR_SIGNAL, 44)
}
