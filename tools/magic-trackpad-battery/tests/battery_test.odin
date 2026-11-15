// The pieces under the cases: the ioctl number, the real reader on what a
// sandbox has, the name cleaning, and the hunting tests: huge and malformed
// sysfs files, a system that is not there, many devices, two runs at once.
#+feature dynamic-literals
package magic_trackpad_battery_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import tool ".."

@(test)
ioctl_number_is_the_one_linux_hidraw_gives :: proc(t: ^testing.T) {
	// HIDIOCGINPUT(len) is _IOC(READ|WRITE, 'H', 0x0A, len); for a 3 byte
	// report that is 0xC003480A, the number linux/hidraw.h gives.
	testing.expect_value(t, tool.hidiocginput(3), 0xC003480A)
	// The length goes into the size field.
	testing.expect_value(t, tool.hidiocginput(64), 0xC040480A)
}

@(test)
the_real_reader_gets_no_answer_where_there_is_no_hidraw :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)

	report := tool.Report{tool.REPORT_ID, 0, 0}
	// Nothing there: ENOENT.
	testing.expect(t, tool.read_hidraw(join(tree, "dev/hidraw0"), &report) < tool.REPORT_LEN)
	// A directory cannot be opened for writing.
	testing.expect(t, tool.read_hidraw(join(tree, "dev"), &report) < tool.REPORT_LEN)
	// A regular file opens, and the ioctl is not one it knows.
	write(t, join(tree, "dev/hidraw1"), "\x90\x00\x32")
	testing.expect(t, tool.read_hidraw(join(tree, "dev/hidraw1"), &report) < tool.REPORT_LEN)
	// So does a device that is no hidraw node.
	testing.expect(t, tool.read_hidraw("/dev/null", &report) < tool.REPORT_LEN)
	testing.expect(t, tool.read_hidraw("", &report) < tool.REPORT_LEN)
	// The buffer is not read as an answer in any of these cases.
	testing.expect_value(t, report, tool.Report{tool.REPORT_ID, 0, 0})
}

@(test)
the_command_with_the_real_reader_prints_nothing_where_the_nodes_are_files :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	add_device(t, tree, "0005:004C:0324.0001", "magicmouse", "hidraw3")
	write(t, join(tree, "dev/hidraw3"), "\x90\x00\x32")

	o, e: strings.Builder
	strings.builder_init(&o)
	strings.builder_init(&e)
	code := tool.run({"--tsv", "--root", tree.dir}, tool.read_hidraw, strings.to_writer(&o), strings.to_writer(&e))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, strings.to_string(o), "")
	testing.expect_value(t, strings.to_string(e), "")
}

@(test)
cleans_names :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	testing.expect_value(t, tool.clean_name("Magic Trackpad"), "Magic Trackpad")
	testing.expect_value(t, tool.clean_name("Magic Trackpad 2 – Müller's"), "Magic Trackpad 2 – Müller's")
	testing.expect_value(t, tool.clean_name(""), tool.DEFAULT_NAME)
	testing.expect_value(t, tool.clean_name(" \t\n "), tool.DEFAULT_NAME)
	// An escape sequence, a tab and a line break stay out of a status bar.
	testing.expect_value(t, tool.clean_name("a\tb\nc\x1b[0m\x7f"), "a b c [0m")
	// The C1 controls too, which a terminal reads as escapes.
	testing.expect_value(t, tool.clean_name("a\u009bb"), "a b")
	// A NUL stops nothing.
	testing.expect_value(t, tool.clean_name("a\x00b"), "a b")
	// Bytes that are no UTF-8, and a truncated character.
	testing.expect_value(t, tool.clean_name("a\xffb\xc3"), "a�b�")
}

@(test)
cuts_a_huge_name_at_a_character :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	ascii := tool.clean_name(strings.repeat("x", 10_000))
	testing.expect_value(t, len(ascii), tool.MAX_NAME_BYTES)
	// 255 bytes of ASCII and a two byte character that does not fit whole.
	wide := tool.clean_name(strings.concatenate({strings.repeat("x", 255), "ö", "tail"}))
	testing.expect_value(t, wide, strings.repeat("x", 255))
	// A name of nothing but control characters is the default, not a long blank.
	testing.expect_value(t, tool.clean_name(strings.repeat("\x01", 10_000)), tool.DEFAULT_NAME)
}

@(test)
labels_a_device_from_what_sysfs_holds :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)

	// A model_name of a megabyte is read as far as a page and cut to a label.
	dev := add_device(t, tree, "0005:004C:0324.0001", "magicmouse", "hidraw3")
	write(t, strings.concatenate({dev, "/power_supply/ps0/model_name"}), strings.repeat("m", 1 << 20))
	name := tool.device_name(dev)
	testing.expect_value(t, len(name), tool.MAX_NAME_BYTES)

	// A uevent past the limit: the HID_NAME in it counts, the line cut in the
	// middle by the limit does not.
	dev2 := add_device(t, tree, "0003:05AC:0324.0002", "magicmouse", "hidraw4")
	filler := strings.repeat("PAD=0123456789abcdef\n", tool.MAX_UEVENT_BYTES / 21 - 4)
	text := strings.concatenate({"HID_NAME=Early\n", filler, "HID_NAME=Late\nHID_NAME=Cut"})
	text = strings.concatenate({text, strings.repeat("x", 200)})
	write(t, strings.concatenate({dev2, "/uevent"}), text)
	testing.expect_value(t, tool.device_name(dev2), "Late")

	// A uevent that is a directory, and a power_supply that is a file.
	dev3 := add_device(t, tree, "0003:05AC:0324.0003", "magicmouse", "hidraw5")
	make_dirs(t, strings.concatenate({dev3, "/uevent"}))
	testing.expect_value(t, tool.device_name(dev3), tool.DEFAULT_NAME)
	dev4 := add_device(t, tree, "0003:05AC:0324.0004", "magicmouse", "hidraw6")
	write(t, strings.concatenate({dev4, "/power_supply"}), "not a directory\n")
	write(t, strings.concatenate({dev4, "/uevent"}), "HID_NAME=From Uevent\n")
	testing.expect_value(t, tool.device_name(dev4), "From Uevent")
}

@(test)
reads_the_driver_from_the_link_without_following_it :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)

	dev := join(tree, "sys/bus/hid/devices/x")
	make_dirs(t, dev)
	link := strings.concatenate({dev, "/driver"})
	// What the kernel makes: relative, and the driver need not exist here.
	testing.expect_value(t, os.symlink("../../../../../bus/hid/drivers/magicmouse", link), nil)
	testing.expect_value(t, tool.driver_of(dev), "magicmouse")
	_ = os.remove(link)
	// A trailing slash, a bare name, and a link that ends in two dots.
	testing.expect_value(t, os.symlink("drivers/magicmouse/", link), nil)
	testing.expect_value(t, tool.driver_of(dev), "magicmouse")
	_ = os.remove(link)
	testing.expect_value(t, os.symlink("magicmouse", link), nil)
	testing.expect_value(t, tool.driver_of(dev), "magicmouse")
	_ = os.remove(link)
	testing.expect_value(t, os.symlink("..", link), nil)
	testing.expect_value(t, tool.driver_of(dev), "")
	_ = os.remove(link)
	// A target of 4090 bytes, near the longest a link can have (4095), fits the buffer.
	testing.expect_value(t, os.symlink(strings.concatenate({strings.repeat("a/", 2040), "magicmouse"}), link), nil)
	testing.expect_value(t, tool.driver_of(dev), "magicmouse")
	_ = os.remove(link)
	// Not a link: a directory called driver, and no driver at all.
	make_dirs(t, link)
	testing.expect_value(t, tool.driver_of(dev), "")
	testing.expect_value(t, tool.driver_of(join(tree, "sys/bus/hid/devices/missing")), "")
}

@(test)
lists_directories_in_byte_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)

	for n in ([]string{"hidraw9", "hidraw10", "hidraw2", ".hidden", "Zed"}) {
		write(t, join(tree, "dev", n), "")
	}
	names, ok := tool.list_dir(join(tree, "dev"))
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(names, " "), ".hidden Zed hidraw10 hidraw2 hidraw9")

	_, ok = tool.list_dir(join(tree, "nothing"))
	testing.expect(t, !ok)
	_, ok = tool.list_dir(join(tree, "dev/hidraw2"))
	testing.expect(t, !ok)
}

@(test)
prints_nothing_when_the_system_is_not_there :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	fake: Fake

	for root in ([]string{join(tree, "nothing"), join(tree, "sys/bus/hid/devices"), ""}) {
		code, out, err := run_args(&fake, {"--tsv", "--root", root} if root != "" else {"--root", join(tree, "dev")})
		testing.expect_value(t, code, 0)
		testing.expect_value(t, out, "")
		testing.expect_value(t, err, "")
	}
	// /sys/bus/hid/devices is a file.
	_ = os.remove_all(join(tree, "sys"))
	write(t, join(tree, "sys"), "x")
	code, out, _ := run_command(&fake, tree, "--tsv")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, "")
}

@(test)
asks_no_node_of_a_device_the_driver_does_not_own :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	add_device(t, tree, "0003:046D:C52B.0003", "hid-generic", "hidraw1")
	add_device(t, tree, "0003:0000:0000.0004", "", "hidraw2")
	add_device(t, tree, "0005:004C:0324.0001", "magicmouse", "hidraw3")
	fake := Fake {
		answers = {"hidraw1" = full(0, 50), "hidraw2" = full(0, 60), "hidraw3" = full(0, 70)},
	}
	_, out, _ := run_command(&fake, tree, "--tsv")
	testing.expect_value(t, out, "70\tDischarging\tMagic device\n")
	testing.expect_value(t, strings.join(fake.asked[:], " "), "hidraw3")
}

@(test)
handles_a_thousand_devices :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	fake: Fake
	want := strings.builder_make()
	for i in 0 ..< 1000 {
		id := strings.builder_make()
		strings.write_string(&id, "0005:004C:0324.")
		strings.write_string(&id, strings.right_justify(itoa(i), 4, "0"))
		node := strings.concatenate({"hidraw", itoa(i)})
		add_device(t, tree, strings.to_string(id), "magicmouse", node)
		fake.answers[node] = full(0, u8(i % 101))
		strings.write_string(&want, itoa(i % 101))
		strings.write_string(&want, "\tDischarging\tMagic device\n")
	}
	code, out, _ := run_command(&fake, tree, "--tsv")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, strings.to_string(want))
}

itoa :: proc(i: int) -> string {
	b := strings.builder_make()
	strings.write_int(&b, i)
	return strings.to_string(b)
}

// Two runs of the command at once on one tree, as two pollers of a status bar
// would: they share nothing, and each prints the whole answer.
Racer :: struct {
	tree:   Tree,
	out:    string,
	code:   int,
	go:     ^sync.Barrier,
	arena:  virtual.Arena,
	failed: bool,
}

race :: proc(r: ^Racer) {
	context.allocator = virtual.arena_allocator(&r.arena)
	fake := Fake {
		answers = {"hidraw3" = full(2, 55), "hidraw4" = full(0, 12)},
	}
	sync.barrier_wait(r.go)
	for _ in 0 ..< 50 {
		code, out, _ := run_command(&fake, r.tree, "--tsv")
		if code != 0 || out != "55\tCharging\tOne\n12\tDischarging\tTwo\n" {
			r.failed = true
			r.out = out
			r.code = code
		}
	}
}

@(test)
two_runs_at_once_do_not_disturb_each_other :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	for spec in ([][3]string{{"0005:004C:0324.0001", "hidraw3", "One"}, {"0005:004C:0324.0002", "hidraw4", "Two"}}) {
		dev := add_device(t, tree, spec[0], "magicmouse", spec[1])
		write(t, strings.concatenate({dev, "/power_supply/ps0/model_name"}), spec[2])
	}

	barrier: sync.Barrier
	sync.barrier_init(&barrier, 3)
	racers: [3]Racer
	threads: [3]^thread.Thread
	for &r, i in racers {
		_ = virtual.arena_init_growing(&r.arena)
		r.tree, r.go = tree, &barrier
		threads[i] = thread.create_and_start_with_poly_data(&r, race)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for &r in racers {
		testing.expectf(t, !r.failed, "a run printed %q with exit %d", r.out, r.code)
		virtual.arena_destroy(&r.arena)
	}
}
