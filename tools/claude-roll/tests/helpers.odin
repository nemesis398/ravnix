// What the tests share: a throwaway tree under TMPDIR for each test, with
// claude-roll's state directory in it, and an arena for everything the test
// allocates.
package claude_roll_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
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

// A process of a fake /proc.
Fake_Proc :: struct {
	pid, ppid, pgid: int,
	// Field 22 of stat: when it started, in clock ticks after boot.
	start:           u64,
	comm:            string,
	// Its environment, NAME=VALUE entries.
	env:             []string,
	argv:            []string,
}

// fake_process writes p into the /proc under root: stat, comm, cmdline and
// environ, as Linux has them.
fake_process :: proc(f: ^Fixture, root: string, p: Fake_Proc) {
	dir := pj(f.a, root, fmt.tprint(p.pid))
	if e := os.make_directory_all(dir); e != nil && e != os.General_Error.Exist {
		testing.fail_now(f.t, "cannot make the fake /proc")
	}
	// pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt
	// majflt cmajflt utime stime cutime cstime priority nice threads
	// itrealvalue starttime ...
	write_file(f, pj(f.a, dir, "stat"), fmt.aprintf("%d (%s) S %d %d %d 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 %d 0 0 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0", p.pid, p.comm, p.ppid, p.pgid, p.pgid, p.start, allocator = f.a))
	write_file(f, pj(f.a, dir, "comm"), strings.concatenate({p.comm, "\n"}, f.a))
	write_file(f, pj(f.a, dir, "cmdline"), nul_joined(f, p.argv))
	write_file(f, pj(f.a, dir, "environ"), nul_joined(f, p.env))
}

// fake_proc writes a process that leads its own process group.
fake_proc :: proc(f: ^Fixture, root: string, pid, ppid: int, comm: string, argv: ..string) {
	fake_process(f, root, {pid = pid, ppid = ppid, pgid = pid, start = start_of(pid), comm = comm, argv = argv})
}

start_of :: proc(pid: int) -> u64 {
	return u64(100_000 + pid)
}

nul_joined :: proc(f: ^Fixture, words: []string) -> string {
	b := strings.builder_make(f.a)
	for w in words {
		strings.write_string(&b, w)
		strings.write_byte(&b, 0)
	}
	return strings.to_string(b)
}

// pid_of is the pid the tests give the Claude Code of a pane: the same in
// the fake /proc, the record, and the fake herdr's process-info.
pid_of :: proc(pane: string) -> int {
	h: u32 = 2166136261
	for c in transmute([]byte)pane {
		h = (h ~ u32(c)) * 16777619
	}
	return 10_000 + int(h % 50_000)
}
