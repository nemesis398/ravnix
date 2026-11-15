// The helpers of the tests: a fixture tree in a directory of its own under
// TMPDIR, the check run on it in process, and the expectations. Every test
// builds its tree, so none depends on the repository's own files. The colors
// in the fixtures are Catppuccin Mocha values or made up; fixtures meant to
// fail live only here, never in the tree the check judges.
package check_style_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import cs ".."

THEME_JSON :: `{
  "theme": "base",
  "themeVariables": {
    "background": "#1e1e2e",
    "primaryColor": "#313244",
    "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"
  }
}
`

// The init block that equals THEME_JSON without white space.
SHARED_BLOCK :: `%%{init: {"theme": "base", "themeVariables": {
  "background": "#1e1e2e", "primaryColor": "#313244",
  "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace" }}}%%
`

Fixture :: struct {
	arena: virtual.Arena,
	// The directory of the test: the tree is dir/tree, scratch files dir/.
	dir:   string,
	tree:  string,
	theme: string,
}

@(deferred_out = leave)
enter :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	if virtual.arena_init_growing(&f.arena) != nil {
		testing.fail_now(t, "no arena")
	}
	context.allocator = virtual.arena_allocator(&f.arena)
	base, terr := os.temp_directory(context.allocator)
	testing.expect_value(t, terr, nil)
	dir, err := os.make_directory_temp(base, "check-style-test-*", context.allocator)
	if err != nil {
		testing.fail_now(t, "no temporary directory")
	}
	f.dir = dir
	f.tree = join(f, "tree")
	f.theme = join(f, "mermaid-theme.json")
	must(t, os.make_directory(f.tree))
	put_file(t, f.theme, THEME_JSON)
	return f
}

leave :: proc(f: ^Fixture) {
	{
		// Undo what a test made unreadable, so the directory can go.
		context.allocator = virtual.arena_allocator(&f.arena)
		context.temp_allocator = context.allocator
		chmod_tree(f.dir)
		os.remove_all(f.dir)
	}
	virtual.arena_destroy(&f.arena)
	free(f)
}

chmod_tree :: proc(dir: string) {
	linux.chmod(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	infos, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		return
	}
	for info in infos {
		// A link is left alone: chmod would follow it to a file of the
		// repository or of the machine.
		if info.type == .Symlink {
			continue
		}
		if info.type == .Directory {
			chmod_tree(info.fullpath)
		} else {
			linux.chmod(strings.clone_to_cstring(info.fullpath, context.temp_allocator), {.IRUSR, .IWUSR})
		}
	}
}

join :: proc(f: ^Fixture, rel: string) -> string {
	return strings.concatenate({f.dir, "/", rel}, virtual.arena_allocator(&f.arena))
}

must :: proc(t: ^testing.T, err: os.Error, loc := #caller_location) {
	testing.expect_value(t, err, nil, loc = loc)
}

// put_file writes text to an absolute path, making the directories above it.
put_file :: proc(t: ^testing.T, path, text: string, loc := #caller_location) {
	if slash := strings.last_index_byte(path, '/'); slash > 0 {
		make_dirs(t, path[:slash], loc)
	}
	must(t, os.write_entire_file(path, transmute([]byte)text), loc)
}

// put writes text to rel in the tree.
put :: proc(t: ^testing.T, f: ^Fixture, rel, text: string, loc := #caller_location) {
	put_file(t, strings.concatenate({f.tree, "/", rel}, virtual.arena_allocator(&f.arena)), text, loc)
}

// check runs the program in the tree, as the shell tests do from inside it.
check :: proc(f: ^Fixture, args: ..string) -> (status: int, out, err: string) {
	return check_in(f, f.tree, ..args)
}

check_in :: proc(f: ^Fixture, cwd: string, args: ..string) -> (status: int, out, err: string) {
	return check_stats(f, cwd, nil, ..args)
}

// check_stats is check_in that also fills stats, when it is not nil.
check_stats :: proc(f: ^Fixture, cwd: string, stats: ^cs.Stats, args: ..string) -> (status: int, out, err: string) {
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	o := strings.builder_make()
	e := strings.builder_make()
	status = cs.run(args, cs.Config{cwd = cwd, theme = f.theme, stats = stats}, strings.to_writer(&o), strings.to_writer(&e))
	return status, strings.to_string(o), strings.to_string(e)
}

// The check ran on the whole tree and found nothing.
expect_clean :: proc(t: ^testing.T, f: ^Fixture, loc := #caller_location) {
	status, out, err := check(f, ".")
	testing.expect_value(t, status, 0, loc = loc)
	testing.expect_value(t, out, "", loc = loc)
	testing.expect_value(t, err, "", loc = loc)
}

// The check found exactly these hits, in this order.
expect_hits :: proc(t: ^testing.T, f: ^Fixture, want: ..string, loc := #caller_location) {
	context.allocator = virtual.arena_allocator(&f.arena)
	status, out, _ := check(f, ".")
	testing.expect_value(t, status, 1, loc = loc)
	testing.expect_value(t, out, strings.concatenate({strings.join(want, "\n"), "\n"}), loc = loc)
}

// Hits of a run with arguments.
expect_hits_of :: proc(t: ^testing.T, f: ^Fixture, args: []string, want: ..string, loc := #caller_location) {
	context.allocator = virtual.arena_allocator(&f.arena)
	status, out, _ := check(f, ..args)
	testing.expect_value(t, status, 1, loc = loc)
	testing.expect_value(t, out, strings.concatenate({strings.join(want, "\n"), "\n"}), loc = loc)
}

expect_contains :: proc(t: ^testing.T, text, part: string, loc := #caller_location) {
	if !strings.contains(text, part) {
		testing.expectf(t, false, "expected %q to contain %q", text, part, loc = loc)
	}
}

lines :: proc(text: string) -> int {
	if text == "" {
		return 0
	}
	return strings.count(text, "\n")
}

symlink :: proc(t: ^testing.T, target, link: string) {
	must(t, os.symlink(target, link))
}


// make_dirs makes a directory and those above it; one that exists is fine.
make_dirs :: proc(t: ^testing.T, path: string, loc := #caller_location) {
	if err := os.make_directory_all(path); err != nil && err != .Exist {
		testing.expect_value(t, err, nil, loc = loc)
	}
}
