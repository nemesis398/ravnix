// Finding the keyboard in a fake sysfs, and the ioctl numbers and structs
// against the kernel's headers. The expected numbers were printed by a C
// program built against linux/input.h and linux/uinput.h of the flake's
// nixpkgs (README.md), so a slip in ioc() or a size shows here, not on the
// laptop.
package copilot_key_super_tests

import "core:os"
import "core:strings"
import "core:testing"
import tool ".."

scratch :: proc(t: ^testing.T) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, err := os.make_directory_temp(tmp, "copilot-key-super-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	return dir
}

put :: proc(t: ^testing.T, path: string, data: string) {
	dir := path[:strings.last_index_byte(path, '/')]
	derr := os.make_directory_all(dir)
	testing.expectf(t, derr == nil || derr == .Exist, "%s: %v", dir, derr)
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)data), nil)
}

// device puts an input device with the name file's content under root, as
// sys/class/input/ENTRY/device/name.
device :: proc(t: ^testing.T, root, entry, name: string) {
	put(t, strings.concatenate({root, "/sys/class/input/", entry, "/device/name"}, context.temp_allocator), name)
}

@(test)
finds_the_keyboard_by_name :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	device(t, root, "event0", "Power Button\n")
	device(t, root, "event3", "AT Translated Set 2 keyboard\n")
	device(t, root, "event5", "copilot-key-super\n")
	// Not event nodes: the input device itself and a mouse node, both with
	// the keyboard's name, as sysfs has them.
	device(t, root, "input3", "AT Translated Set 2 keyboard\n")
	device(t, root, "mouse0", "AT Translated Set 2 keyboard\n")
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.None)
	testing.expect_value(t, n, 3)
}

@(test)
near_names_are_not_the_keyboard :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	device(t, root, "event1", "AT Translated Set 2 keyboard \n")
	device(t, root, "event2", "AT Translated Set 2 keyboard2\n")
	device(t, root, "event3", "at translated set 2 keyboard\n")
	device(t, root, "event4", "AT Translated Set 2 keyboard\n\n")
	device(t, root, "event5", "AT Translated Set 2\n")
	device(t, root, "event6", "")
	device(t, root, "event7", "AT Translated Set 2 keyboard\r\n")
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.Not_Found)
	testing.expect_value(t, n, -1)
}

@(test)
a_name_without_its_newline_still_matches :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	device(t, root, "event2", "AT Translated Set 2 keyboard")
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.None)
	testing.expect_value(t, n, 2)
}

@(test)
the_lowest_number_wins_by_value :: proc(t: ^testing.T) {
	// event10 sorts before event9 as a string; as a number it is higher.
	root := scratch(t)
	defer os.remove_all(root)
	device(t, root, "event10", "AT Translated Set 2 keyboard\n")
	device(t, root, "event9", "AT Translated Set 2 keyboard\n")
	device(t, root, "event11", "AT Translated Set 2 keyboard\n")
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.None)
	testing.expect_value(t, n, 9)
}

@(test)
odd_entries_are_skipped :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	// No number, a sign, letters after the digits, a number past an int, an
	// event without a name file, and a file where a directory belongs.
	device(t, root, "event", "AT Translated Set 2 keyboard\n")
	device(t, root, "event-1", "AT Translated Set 2 keyboard\n")
	device(t, root, "event1x", "AT Translated Set 2 keyboard\n")
	device(t, root, "event99999999999999999999999", "AT Translated Set 2 keyboard\n")
	put(t, strings.concatenate({root, "/sys/class/input/event4/uevent"}, context.temp_allocator), "MAJOR=13\n")
	put(t, strings.concatenate({root, "/sys/class/input/event6"}, context.temp_allocator), "not a directory\n")
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.Not_Found)
	testing.expect_value(t, n, -1)
	device(t, root, "event7", "AT Translated Set 2 keyboard\n")
	n, err = tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.None)
	testing.expect_value(t, n, 7)
}

@(test)
a_huge_name_file_is_no_match :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	// The keyboard's name, then a megabyte: read only as far as a name goes.
	big := strings.concatenate({tool.KEYBOARD_NAME, strings.repeat("x", 1 << 20, context.temp_allocator)}, context.temp_allocator)
	device(t, root, "event1", big)
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.Not_Found)
	testing.expect_value(t, n, -1)
}

@(test)
no_keyboard_and_no_sysfs :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	n, err := tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.No_Input_Class)
	testing.expect_value(t, n, -1)
	testing.expect_value(t, os.make_directory_all(strings.concatenate({root, "/sys/class/input"}, context.temp_allocator)), nil)
	n, err = tool.find_keyboard(root, tool.KEYBOARD_NAME)
	testing.expect_value(t, err, tool.Find_Error.Not_Found)
	testing.expect_value(t, n, -1)
}

@(test)
ioctl_numbers_are_the_kernels :: proc(t: ^testing.T) {
	testing.expect_value(t, tool.eviocgrab(), 0x40044590)
	testing.expect_value(t, tool.eviocgname(256), 0x81004506)
	testing.expect_value(t, tool.eviocgid(), 0x80084502)
	testing.expect_value(t, tool.eviocgbit(tool.EV_KEY, 96), 0x80604521)
	testing.expect_value(t, tool.eviocgbit(tool.EV_MSC, 1), 0x80014524)
	testing.expect_value(t, tool.eviocgbit(0, 4), 0x80044520)
	testing.expect_value(t, tool.eviocgkey(96), 0x80604518)
	testing.expect_value(t, tool.eviocsclockid(), 0x400445a0)
	testing.expect_value(t, tool.ui_set_evbit(), 0x40045564)
	testing.expect_value(t, tool.ui_set_keybit(), 0x40045565)
	testing.expect_value(t, tool.ui_set_mscbit(), 0x40045568)
	testing.expect_value(t, tool.ui_set_ledbit(), 0x40045569)
	testing.expect_value(t, tool.ui_set_phys(), 0x4008556c)
	testing.expect_value(t, tool.ui_dev_setup(), 0x405c5503)
	testing.expect_value(t, tool.ui_dev_create(), 0x5501)
}

@(test)
the_virtual_device_is_what_sway_names :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(tool.Uinput_Setup), 92)
	testing.expect_value(t, offset_of(tool.Uinput_Setup, name), 8)
	testing.expect_value(t, offset_of(tool.Uinput_Setup, ff_effects_max), 88)
	s := tool.virtual_setup(0x11)
	// Sway's `input "1:1:copilot-key-super"`: vendor 1, product 1, the name.
	testing.expect_value(t, s.id, tool.Input_Id{bustype = 0x11, vendor = 1, product = 1, version = 1})
	name := string(cstring(&s.name[0]))
	testing.expect_value(t, name, "copilot-key-super")
	for b in s.name[len(name):] {
		testing.expect_value(t, b, 0)
	}
	testing.expect_value(t, s.ff_effects_max, 0)
}
