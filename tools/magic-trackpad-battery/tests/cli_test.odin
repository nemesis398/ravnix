// The command line: the options, the help, and what a bad one does.
#+feature dynamic-literals
package magic_trackpad_battery_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"

@(test)
prints_the_usage_for_help :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	fake: Fake

	for flag in ([]string{"-h", "--help"}) {
		code, out, err := run_args(&fake, {flag})
		testing.expect_value(t, code, 0)
		testing.expect(t, strings.has_prefix(out, "usage: magic-trackpad-battery"))
		testing.expect_value(t, err, "")
		testing.expect_value(t, len(fake.asked), 0)
	}
	// Help wins over what comes after it, and a broken --root before it.
	code, out, _ := run_args(&fake, {"--tsv", "--help", "--root"})
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(out, "usage:"))
}

@(test)
refuses_a_root_without_a_value :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	fake: Fake

	code, out, err := run_args(&fake, {"--tsv", "--root"})
	testing.expect_value(t, code, 2)
	testing.expect_value(t, out, "")
	testing.expect(t, strings.contains(err, "--root needs a value"))
}

@(test)
ignores_what_it_does_not_know :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	add_device(t, tree, "0005:004C:0324.0001", "magicmouse", "hidraw3")
	fake := Fake {
		answers = {"hidraw3" = full(0, 50)},
	}
	// Empty arguments, a lone dash, a second --tsv and an option of no tool
	// that polls this one: the Python tool read only --tsv.
	code, out, err := run_command(&fake, tree, "", "-", "--tsv", "--tsv", "--json", "-x")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, "50\tDischarging\tMagic device\n")
	testing.expect_value(t, err, "")
	// The value of --root is not an option, even when it looks like one.
	code, out, _ = run_args(&fake, {"--root", "--tsv"})
	testing.expect_value(t, code, 0)
	testing.expect_value(t, out, "")
}

@(test)
an_unanswering_node_is_asked_once_and_the_next_is_tried :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	tree := make_tree(t)
	defer remove_tree(tree)
	add_device(t, tree, "0005:004C:0324.0001", "magicmouse", "hidraw3", "hidraw4", "hidraw5")
	fake := Fake {
		answers = {"hidraw3" = {kind = .Fails}, "hidraw4" = full(0, 33), "hidraw5" = full(0, 44)},
	}
	_, out, _ := run_command(&fake, tree, "--tsv")
	testing.expect_value(t, out, "33\tDischarging\tMagic device\n")
	testing.expect_value(t, strings.join(fake.asked[:], " "), "hidraw3 hidraw4")
}
