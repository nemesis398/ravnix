// What the tests share: a throwaway tree under TMPDIR for each test, with
// claude-roll's state directory in it, and an arena for everything the test
// allocates.
package claude_roll_tests

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"

Fixture :: struct {
	t:     ^testing.T,
	arena: virtual.Arena,
	a:     runtime.Allocator,
	dir:   string,
	state: string,
}

// fixture makes the tree; fixture_destroy removes it and frees the arena.
fixture :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	f.t = t
	if virtual.arena_init_growing(&f.arena) != nil {
		testing.fail_now(t, "no memory for the fixture's arena")
	}
	f.a = virtual.arena_allocator(&f.arena)
	tmp := os.get_env("TMPDIR", f.a)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, err := os.make_directory_temp(tmp, "cr-*", f.a)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	f.dir = dir
	f.state = pj(f.a, dir, "state")
	return f
}

fixture_destroy :: proc(f: ^Fixture) {
	_ = os.remove_all(f.dir)
	virtual.arena_destroy(&f.arena)
	free(f)
}

write_file :: proc(f: ^Fixture, path: string, data: string) {
	if err := os.write_entire_file(path, transmute([]byte)data); err != nil {
		testing.fail_now(f.t, "cannot write a test file")
	}
}

// count_entries counts what is in dir; a missing dir holds nothing.
count_entries :: proc(f: ^Fixture, dir: string) -> int {
	d, err := os.open(dir)
	if err != nil {
		return 0
	}
	defer os.close(d)
	entries, _ := os.read_dir(d, -1, f.a)
	return len(entries)
}

// pj joins a path.
pj :: proc(a: runtime.Allocator, parts: ..string) -> string {
	s, _ := filepath.join(parts, a)
	return s
}
