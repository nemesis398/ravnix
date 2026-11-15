// The fake system of the tests: a sysfs and a /dev under a temporary root, and
// a fake hidraw reader. The build sandbox has no Apple device and no
// /dev/hidraw, so the reader is handed in; the ioctl itself is tested on what
// a sandbox has (battery_test.odin) and was run against a real trackpad.
package magic_trackpad_battery_tests

import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"
import tool ".."

// An Answer is what one hidraw node gives.
Answer_Kind :: enum {
	Missing, // /dev/NODE cannot be opened
	Fails, // it opens, and the ioctl fails
	Report, // the ioctl returns ret bytes, and the buffer holds bytes
}

Answer :: struct {
	kind:  Answer_Kind,
	bytes: tool.Report,
	ret:   int,
}

// Fake is the system behind the fake reader: the answer of each node by name,
// and the nodes that were asked, in order. It reaches the reader through
// context.user_ptr, since a Reader is a bare procedure.
Fake :: struct {
	answers:   map[string]Answer,
	asked:     [dynamic]string,
	allocator: runtime.Allocator, // what asked lives in: the run's own arena is gone when it returns
}

fake_read :: proc(path: string, report: ^tool.Report) -> int {
	fake := cast(^Fake)context.user_ptr
	node := path[strings.last_index_byte(path, '/') + 1:]
	append(&fake.asked, strings.clone(node, fake.allocator))
	answer, found := fake.answers[node]
	if !found || answer.kind == .Missing {
		return -13 // EACCES
	}
	if answer.kind == .Fails {
		return -25 // ENOTTY
	}
	report^ = answer.bytes
	return answer.ret
}

// Tree is a fake system under dir: dir/sys/bus/hid/devices, dir/sys/bus/hid/
// drivers and dir/dev.
Tree :: struct {
	dir: string,
}

// make_tree makes the tree under a new temporary directory, which
// remove_tree removes. Everything it allocates comes from the caller's
// allocator, which in a test is an arena.
make_tree :: proc(t: ^testing.T) -> Tree {
	dir, err := os.make_directory_temp("", "magic-trackpad-battery-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	tree := Tree{dir = dir}
	make_dirs(t, join(tree, "sys/bus/hid/devices"))
	make_dirs(t, join(tree, "sys/bus/hid/drivers"))
	make_dirs(t, join(tree, "dev"))
	return tree
}

remove_tree :: proc(tree: Tree) {
	_ = os.remove_all(tree.dir)
}

join :: proc(tree: Tree, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1)
	append(&all, tree.dir)
	append(&all, ..parts)
	return strings.join(all[:], "/")
}

make_dirs :: proc(t: ^testing.T, path: string) {
	err := os.make_directory_all(path)
	testing.expectf(t, err == nil || err == .Exist, "%s: %v", path, err)
}

write :: proc(t: ^testing.T, path: string, data: string) {
	make_dirs(t, path[:strings.last_index_byte(path, '/')])
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)data), nil)
}

// add_device makes the HID device id with the driver link and the hidraw
// directories, and nothing else: a driver of "" leaves the link out.
add_device :: proc(t: ^testing.T, tree: Tree, id, driver: string, nodes: ..string) -> string {
	dev := join(tree, "sys/bus/hid/devices", id)
	make_dirs(t, dev)
	if driver != "" {
		target := join(tree, "sys/bus/hid/drivers", driver)
		make_dirs(t, target)
		testing.expect_value(t, os.symlink(target, strings.concatenate({dev, "/driver"})), nil)
	}
	for node in nodes {
		make_dirs(t, strings.join({dev, "hidraw", node}, "/"))
	}
	return dev
}

// run_command runs the whole command on the tree, with the fake system behind
// the reader, and returns its exit status and what it wrote.
run_command :: proc(fake: ^Fake, tree: Tree, args: ..string) -> (code: int, out, err: string) {
	all := make([dynamic]string)
	append(&all, ..args)
	append(&all, "--root", tree.dir)
	return run_args(fake, all[:])
}

run_args :: proc(fake: ^Fake, args: []string) -> (code: int, out, err: string) {
	o, e: strings.Builder
	strings.builder_init(&o)
	strings.builder_init(&e)
	context.user_ptr = fake
	fake.allocator = context.allocator
	if fake.asked.allocator.procedure == nil {
		fake.asked = make([dynamic]string, fake.allocator)
	}
	code = tool.run(args, fake_read, strings.to_writer(&o), strings.to_writer(&e))
	return code, strings.to_string(o), strings.to_string(e)
}

// bytes3 is a report of the three bytes.
bytes3 :: proc(id, flags, capacity: u8) -> tool.Report {
	return tool.Report{id, flags, capacity}
}

full :: proc(flags, capacity: u8) -> Answer {
	return Answer{kind = .Report, bytes = bytes3(tool.REPORT_ID, flags, capacity), ret = tool.REPORT_LEN}
}

