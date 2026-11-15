// Robustness and the place of the root: the last cases of the shell test, and
// the edge cases the Bash version never had: malformed input, binary files,
// huge lines and files, paths with spaces or a leading dash, unreadable files
// and directories, a file that changes under the walk.
package check_style_tests

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import cs ".."
import "core:sys/linux"
import "core:testing"
import "core:time"

@(test)
an_empty_tree_and_an_empty_file_pass :: proc(t: ^testing.T) {
	f := enter(t)
	expect_clean(t, f)
	put(t, f, "modules/empty.nix", "")
	put(t, f, "a.css", "")
	expect_clean(t, f)
}

@(test)
a_directory_without_judged_files_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "README.txt", "nothing to see\n")
	expect_clean(t, f)
}

@(test)
a_file_without_a_final_newline_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px }")
	expect_hits(t, f, "a.css:1:radius")
}

@(test)
windows_line_ends_are_judged_like_unix_ones :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 0; }\r\nb { border-radius: 0 }\r\nc { opacity: 1 }\r\n")
	put(t, f, "b.css", "a { border-radius: 4px }\r\nb { color: #cba6f7 }\r\n")
	expect_hits(t, f, "b.css:1:radius", "b.css:2:hex-color")
}

@(test)
a_path_with_spaces_or_a_colon_is_reported_whole :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a b/c d.css", "a { border-radius: 4px; }\n")
	put(t, f, "modules/x:y.css", "a { border-radius: 4px; }\n")
	expect_hits(t, f, "modules/a b/c d.css:1:radius", "modules/x:y.css:1:radius")
}

@(test)
a_binary_file_with_a_style_name_does_not_crash_the_check :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "\x00\x01\x02#cba6f7\x00\x03")
	status, _, _ := check(f, ".")
	testing.expect(t, status == 0 || status == 1)
}

@(test)
a_huge_line_is_judged_in_time :: proc(t: ^testing.T) {
	f := enter(t)
	start := time.now()
	big := strings.repeat("x", 3_000_000, context.temp_allocator)
	put(t, f, "big.css", strings.concatenate({big, "\na { border-radius: 4px; }\n"}, context.temp_allocator))
	expect_hits(t, f, "big.css:2:radius")
	// One line of 3 MB with a property in the middle of it.
	pad := strings.repeat(" ", 1_000_000, context.temp_allocator)
	put(t, f, "big.css", strings.concatenate({pad, "a { opacity: 0.5; }", pad, "\n"}, context.temp_allocator))
	expect_hits(t, f, "big.css:1:opacity")
	testing.expect(t, time.since(start) < 20 * time.Second)
}

@(test)
many_files_are_judged_in_slices :: proc(t: ^testing.T) {
	f := enter(t)
	for i in 1 ..= 1300 {
		put(t, f, strings.concatenate({"f", itoa(i), ".css"}, context.temp_allocator), "a { color: red; }\n")
	}
	put(t, f, "f1299.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, ".")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "f1299.css:1:radius\n")
}

itoa :: proc(i: int) -> string {
	buf: [32]u8
	n := len(buf)
	v := i
	if v == 0 {
		return "0"
	}
	for v > 0 {
		n -= 1
		buf[n] = u8('0' + v % 10)
		v /= 10
	}
	return strings.clone(string(buf[n:]), context.temp_allocator)
}

@(test)
an_unreadable_file_is_bad_usage :: proc(t: ^testing.T) {
	if linux.geteuid() == 0 {
		return // root reads it anyway
	}
	f := enter(t)
	put(t, f, "locked.css", "a { border-radius: 4px; }\n")
	linux.chmod(strings.clone_to_cstring(join(f, "tree/locked.css"), context.temp_allocator), {})
	status, out, err := check(f, ".")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, out, "")
	expect_contains(t, err, "locked.css")
}

@(test)
an_unreadable_directory_is_bad_usage :: proc(t: ^testing.T) {
	if linux.geteuid() == 0 {
		return
	}
	f := enter(t)
	put(t, f, "modules/locked/a.css", "a { border-radius: 4px; }\n")
	put(t, f, "b.css", "a { border-radius: 4px; }\n")
	linux.chmod(strings.clone_to_cstring(join(f, "tree/modules/locked"), context.temp_allocator), {})
	status, out, err := check(f, ".")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, out, "")
	expect_contains(t, err, "could not walk")
}

@(test)
a_file_argument_is_judged_by_its_own_path :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tests/z.nix", "c = \"#cba6f7\";\n")
	status, _, _ := check(f, "modules/theme/x.nix")
	testing.expect_value(t, status, 0)
	status, _, _ = check(f, "tests/z.nix")
	testing.expect_value(t, status, 0)
	out: string
	status, out, _ = check(f, "modules/y.nix")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "modules/y.nix:1:hex-color\n")
	status, out, _ = check(f, "modules/theme/x.nix", "modules/y.nix", "tests/z.nix")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, lines(out), 1)
}

@(test)
a_directory_outside_the_current_directory_is_its_own_root :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tests/z.css", "a { border-radius: 4px; }\n")
	put(t, f, "themes/t.css", "a { border-radius: 4px; }\n")
	elsewhere := join(f, "elsewhere")
	make_dirs(t, elsewhere)
	status, out, _ := check_in(f, elsewhere, f.tree)
	testing.expect_value(t, status, 1)
	want := strings.concatenate({f.tree, "/modules/y.nix:1:hex-color\n", f.tree, "/themes/t.css:1:radius\n"}, context.temp_allocator)
	testing.expect_value(t, out, want)
}

@(test)
an_absolute_directory_below_the_current_directory_is_anchored_there :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tests/z.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, join(f, "tree/modules"), join(f, "tree/tests"))
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, strings.concatenate({f.tree, "/modules/y.nix:1:hex-color\n"}, context.temp_allocator))
	status, out, _ = check(f, "./modules", "./tests")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "./modules/y.nix:1:hex-color\n")
}

@(test)
a_file_outside_the_current_directory_gets_no_exemption :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	elsewhere := join(f, "elsewhere")
	make_dirs(t, elsewhere)
	status, out, _ := check_in(f, elsewhere, join(f, "tree/modules/theme/x.nix"))
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, strings.concatenate({f.tree, "/modules/theme/x.nix:1:hex-color\n"}, context.temp_allocator))
}

@(test)
a_double_slash_comment_hides_an_issue_number_except_in_nix :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.conf", "x = 1 // see #290879\n")
	put(t, f, "modules/b.nix", "x = a // b; # not #290879\nx = a // b; // see #290879\nx = \"#290879\"; # a color\n")
	expect_hits(t, f, "modules/b.nix:2:hex-color", "modules/b.nix:3:hex-color")
}

@(test)
a_file_given_by_an_absolute_path_is_judged_below_the_current_directory :: proc(t: ^testing.T) {
	f := enter(t)
	dir := join(f, "tests/vendor/proj")
	put_file(t, strings.concatenate({dir, "/modules/x.nix"}, context.temp_allocator), "c = \"#cba6f7\";\n")
	put_file(t, strings.concatenate({dir, "/tests/y.nix"}, context.temp_allocator), "c = \"#cba6f7\";\n")
	status, out, _ := check_in(f, dir, strings.concatenate({dir, "/modules/x.nix"}, context.temp_allocator))
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, strings.concatenate({dir, "/modules/x.nix:1:hex-color\n"}, context.temp_allocator))
	status, _, _ = check_in(f, dir, strings.concatenate({dir, "/tests/y.nix"}, context.temp_allocator))
	testing.expect_value(t, status, 0)
}

@(test)
the_same_file_given_twice_is_reported_once :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, "a.css", "a.css", ".")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, lines(out), 1)
}

@(test)
hits_are_sorted_by_file_and_line :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "z.css", "a { border-radius: 4px; }\n")
	put(t, f, "modules/m.nix", "a = 1;\nb = \"#cba6f7\";\nradius = 3;\n")
	put(t, f, "a.css", "a { opacity: 0.5; }\n\nb { border-radius: 2px; }\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:3:radius", "modules/m.nix:2:hex-color", "modules/m.nix:3:radius", "z.css:1:radius")
}

// A directory entry whose type the file system does not give is looked at
// with lstat, and an entry lstat cannot look at fails the walk, as find fails.
@(test)
an_entry_of_unknown_type_is_looked_at_and_a_missing_one_is_an_error :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.conf", "x\n")
	dir := f.tree
	file := strings.concatenate({dir, "/a.conf"}, context.temp_allocator)
	missing := strings.concatenate({dir, "/gone"}, context.temp_allocator)

	kind, errno := cs.entry_kind(dir, .UNKNOWN)
	testing.expect_value(t, kind, linux.Dirent_Type.DIR)
	testing.expect_value(t, errno, linux.Errno.NONE)
	kind, errno = cs.entry_kind(file, .UNKNOWN)
	testing.expect_value(t, kind, linux.Dirent_Type.REG)
	testing.expect_value(t, errno, linux.Errno.NONE)
	_, errno = cs.entry_kind(missing, .UNKNOWN)
	testing.expect_value(t, errno, linux.Errno.ENOENT)
	// A type that the directory gave is taken as it is, without a look.
	kind, errno = cs.entry_kind(missing, .REG)
	testing.expect_value(t, kind, linux.Dirent_Type.REG)
	testing.expect_value(t, errno, linux.Errno.NONE)
}

// A tree of many files is found with one lookup per file, not a scan of the
// files already found: 100 000 paths, none a repeat, go through classify in
// well under a second with a set (about 5 * 10^9 string compares with the
// scan, tens of seconds), and a repeat of a path is still dropped.
@(test)
a_file_set_looks_a_path_up_instead_of_scanning :: proc(t: ^testing.T) {
	f := enter(t)
	context.allocator = virtual.arena_allocator(&f.arena)
	set: cs.File_Set
	started := time.tick_now()
	for i in 0 ..< 100_000 {
		path := fmt.aprintf("modules/d%d/f%d.conf", i % 40, i)
		cs.classify(path, path, &set)
	}
	took := time.duration_seconds(time.tick_since(started))
	testing.expect_value(t, len(set.list), 100_000)
	// Repeats are dropped.
	cs.classify("modules/d0/f0.conf", "modules/d0/f0.conf", &set)
	testing.expect_value(t, len(set.list), 100_000)
	testing.expectf(t, took < 3, "100000 paths took %v seconds", took)
}

// Many files in a real tree, given twice, are judged once and in order.
@(test)
a_tree_of_many_files_given_twice_is_judged_once :: proc(t: ^testing.T) {
	f := enter(t)
	for i in 0 ..< 600 {
		put(t, f, strings.concatenate({"modules/d", itoa(i % 40), "/f", itoa(i), ".conf"}, context.temp_allocator), "x\n")
	}
	put(t, f, "modules/d3/bad.conf", "transition: x\n")
	status, out, _ := check(f, ".", "modules", "modules/d3")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "modules/d3/bad.conf:1:motion\n")
}
