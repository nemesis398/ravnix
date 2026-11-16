// Finding the keyboard in a fake sysfs, and the ioctl numbers and structs
// against the kernel's headers. The expected numbers were printed by a C
// program built against linux/input.h and linux/uinput.h of the flake's
// nixpkgs (README.md), so a slip in ioc() or a size shows here, not on the
// laptop.
package copilot_key_super_tests

import "core:os"
import "core:strings"
import "core:sys/linux"
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

// Ioctls is what a fake uinput was asked, call by call: the request, and
// the argument, or what it points to for UI_SET_PHYS and UI_DEV_SETUP.
Ioctl_Call :: struct {
	request: u32,
	arg:     uintptr,
	phys:    string,
	setup:   tool.Uinput_Setup,
}
Ioctls :: struct {
	calls:   [dynamic]Ioctl_Call,
	fail_on: u32, // the request that fails, with EINVAL
}

fake_ioctl :: proc(fd: linux.Fd, request: u32, arg: uintptr) -> linux.Errno {
	f := cast(^Ioctls)context.user_ptr
	c := Ioctl_Call{request = request, arg = arg}
	if request == tool.ui_set_phys() {
		c.phys = strings.clone(string(cstring(rawptr(arg))), context.temp_allocator)
	}
	if request == tool.ui_dev_setup() {
		c.setup = (^tool.Uinput_Setup)(arg)^
	}
	append(&f.calls, c)
	return .EINVAL if request == f.fail_on else .NONE
}

args_of :: proc(f: ^Ioctls, request: u32) -> []uintptr {
	out := make([dynamic]uintptr, context.temp_allocator)
	for c in f.calls {
		if c.request == request {
			append(&out, c.arg)
		}
	}
	return out[:]
}

@(test)
the_virtual_keyboard_gets_what_the_keyboard_has :: proc(t: ^testing.T) {
	// A keyboard with A, B and the left Shift, scancodes and two LEDs, and
	// no Meta: the virtual one gets those, the left Meta the filter writes,
	// no EV_REP, the phys and the setup, and is created last.
	caps: tool.Caps
	caps.id = {bustype = 0x11, vendor = 1, product = 1, version = 0xab41}
	caps.types = 1 << tool.EV_SYN | 1 << tool.EV_KEY | 1 << tool.EV_MSC | 1 << tool.EV_LED | 1 << 0x14
	tool.set_bit(&caps.keys, KEY_A, true)
	tool.set_bit(&caps.keys, KEY_B, true)
	tool.set_bit(&caps.keys, SHIFT, true)
	caps.mscs = 1 << 4
	caps.leds = 1 << 0 | 1 << 1
	f := Ioctls{calls = make([dynamic]Ioctl_Call, context.temp_allocator)}
	context.user_ptr = &f
	testing.expect_value(t, tool.create_virtual(3, &caps, fake_ioctl), linux.Errno.NONE)

	evs := args_of(&f, tool.ui_set_evbit())
	testing.expect_value(t, len(evs), 3)
	testing.expect(t, len(evs) == 3 && evs[0] == tool.EV_KEY && evs[1] == tool.EV_MSC && evs[2] == tool.EV_LED, "event types")
	keys := args_of(&f, tool.ui_set_keybit())
	testing.expectf(t, len(keys) == 4 && keys[0] == KEY_A && keys[1] == SHIFT && keys[2] == KEY_B && keys[3] == META, "keys %v", keys)
	mscs := args_of(&f, tool.ui_set_mscbit())
	testing.expectf(t, len(mscs) == 1 && mscs[0] == 4, "scancodes %v", mscs)
	leds := args_of(&f, tool.ui_set_ledbit())
	testing.expectf(t, len(leds) == 2 && leds[0] == 0 && leds[1] == 1, "leds %v", leds)
	last := f.calls[len(f.calls) - 1]
	testing.expect_value(t, last.request, tool.ui_dev_create())
	found_phys, found_setup := false, false
	for c in f.calls {
		if c.request == tool.ui_set_phys() {
			found_phys = true
			testing.expect_value(t, c.phys, "copilot-key-super")
		}
		if c.request == tool.ui_dev_setup() {
			found_setup = true
			testing.expect_value(t, c.setup.id, tool.Input_Id{bustype = 0x11, vendor = 1, product = 1, version = 1})
		}
	}
	testing.expect(t, found_phys && found_setup, "no UI_SET_PHYS or UI_DEV_SETUP")
}

@(test)
a_keyboard_without_scancodes_or_leds_gets_none :: proc(t: ^testing.T) {
	caps: tool.Caps
	caps.types = 1 << tool.EV_KEY
	caps.mscs = 0xff // not reported, so not used
	f := Ioctls{calls = make([dynamic]Ioctl_Call, context.temp_allocator)}
	context.user_ptr = &f
	testing.expect_value(t, tool.create_virtual(3, &caps, fake_ioctl), linux.Errno.NONE)
	evs := args_of(&f, tool.ui_set_evbit())
	testing.expectf(t, len(evs) == 1 && evs[0] == tool.EV_KEY, "event types %v", evs)
	testing.expect_value(t, len(args_of(&f, tool.ui_set_mscbit())), 0)
	keys := args_of(&f, tool.ui_set_keybit())
	testing.expectf(t, len(keys) == 2 && keys[0] == SHIFT && keys[1] == META, "keys %v", keys)
}

@(test)
a_failed_uinput_call_stops_the_setup :: proc(t: ^testing.T) {
	for request in ([]u32{tool.ui_set_evbit(), tool.ui_set_keybit(), tool.ui_set_phys(), tool.ui_dev_setup(), tool.ui_dev_create()}) {
		caps: tool.Caps
		caps.types = 1 << tool.EV_KEY
		f := Ioctls{calls = make([dynamic]Ioctl_Call, context.temp_allocator), fail_on = request}
		context.user_ptr = &f
		testing.expect_value(t, tool.create_virtual(3, &caps, fake_ioctl), linux.Errno.EINVAL)
		last := f.calls[len(f.calls) - 1]
		testing.expectf(t, last.request == request, "went on after %x failed", request)
	}
}

// Keys_Script is the fake keyboard of wait_keys_up: down for the first down
// polls, then up; or failing from the fail-th poll on.
Keys_Script :: struct {
	down:   int,
	fail:   int,
	polls:  int,
	sleeps: int,
}

script_held :: proc(fd: linux.Fd, held: ^tool.Key_Bits) -> linux.Errno {
	s := cast(^Keys_Script)context.user_ptr
	s.polls += 1
	if s.fail > 0 && s.polls >= s.fail {
		return .ENODEV
	}
	held^ = {}
	if s.polls <= s.down {
		tool.set_bit(held, KEY_A, true)
	}
	return .NONE
}

script_sleep :: proc(ns: i64) {
	s := cast(^Keys_Script)context.user_ptr
	s.sleeps += 1
}

wait :: proc(s: ^Keys_Script) -> (linux.Errno, string) {
	e: strings.Builder
	strings.builder_init(&e, context.temp_allocator)
	context.user_ptr = s
	errno := tool.wait_keys_up(3, script_held, script_sleep, strings.to_writer(&e))
	return errno, strings.to_string(e)
}

@(test)
the_grab_waits_for_every_key_to_be_up :: proc(t: ^testing.T) {
	{
		s := Keys_Script{}
		errno, log := wait(&s)
		testing.expect_value(t, errno, linux.Errno.NONE)
		testing.expect_value(t, s.sleeps, 0)
		testing.expect_value(t, log, "")
	}
	{
		s := Keys_Script{down = 5}
		errno, log := wait(&s)
		testing.expect_value(t, errno, linux.Errno.NONE)
		testing.expect_value(t, s.sleeps, 5)
		testing.expect_value(t, log, "")
	}
	{
		// Held far past the first second: it keeps waiting, and says so once.
		s := Keys_Script{down = 20 * tool.WAIT_STEPS}
		errno, log := wait(&s)
		testing.expect_value(t, errno, linux.Errno.NONE)
		testing.expect_value(t, s.sleeps, 20 * tool.WAIT_STEPS)
		testing.expect_value(t, strings.count(log, "\n"), 1)
		testing.expect(t, strings.contains(log, "still down"), log)
	}
}

@(test)
the_wait_stops_when_the_keys_cannot_be_read :: proc(t: ^testing.T) {
	s := Keys_Script{down = 1000, fail = 3}
	errno, _ := wait(&s)
	testing.expect_value(t, errno, linux.Errno.ENODEV)
	testing.expect_value(t, s.polls, 3)
}
