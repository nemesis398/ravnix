// What the tests share: a throwaway tree under TMPDIR for each test, with a
// dictionary path and a state directory, a run of the command line that
// returns what it printed, and fixture adapters whose lists live in the test.
package ravnix_dict_tests

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import dict ".."

Fixture :: struct {
	t:     ^testing.T,
	// The allocator the fixture itself came from; a test may set
	// context.allocator to the arena after making it.
	owner: runtime.Allocator,
	arena: virtual.Arena,
	a:     runtime.Allocator,
	dir:   string,
	file:  string,
	state: string,
}

// fixture makes the tree. Everything it allocates is in its arena, which
// fixture_destroy frees with the tree.
fixture :: proc(t: ^testing.T) -> ^Fixture {
	f := new(Fixture)
	f.t = t
	f.owner = context.allocator
	if virtual.arena_init_growing(&f.arena) != nil {
		testing.fail_now(t, "no memory for the fixture's arena")
	}
	f.a = virtual.arena_allocator(&f.arena)
	tmp := os.get_env("TMPDIR", f.a)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, err := os.make_directory_temp(tmp, "rd-*", f.a)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	f.dir = dir
	f.file = join(f, "dictionary.txt")
	f.state = join(f, "state")
	fixture_allocator = f.a
	stores = {}
	write_log = nil
	return f
}

fixture_destroy :: proc(f: ^Fixture) {
	os.remove_all(f.dir)
	virtual.arena_destroy(&f.arena)
	fixture_allocator = {}
	stores = {}
	write_log = nil
	free(f, f.owner)
}

join :: proc(f: ^Fixture, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1, f.a)
	append(&all, f.dir)
	append(&all, ..parts)
	return strings.join(all[:], "/", f.a)
}

write_file :: proc(f: ^Fixture, path: string, data: string) {
	testing.expect_value(f.t, os.write_entire_file(path, data), nil)
}

read_file :: proc(f: ^Fixture, path: string) -> string {
	data, err := os.read_entire_file(path, f.a)
	if err != nil {
		return ""
	}
	return string(data)
}

Result :: struct {
	code: int,
	out:  string,
	err:  string,
}

env :: proc(f: ^Fixture) -> dict.Environment {
	return dict.Environment{file = f.file, state_home = "", home = "", lock_wait_ms = 10_000}
}

// run runs the command line with --state set to the fixture's, and the
// adapters given; it returns the exit status and what was printed.
run :: proc(f: ^Fixture, adapters: []dict.Adapter, args: ..string) -> Result {
	return run_env(f, env(f), adapters, ..args)
}

run_env :: proc(f: ^Fixture, e: dict.Environment, adapters: []dict.Adapter, args: ..string) -> Result {
	out_path := join(f, "stdout")
	err_path := join(f, "stderr")
	outf, oerr := os.create(out_path)
	errf, eerr := os.create(err_path)
	if oerr != nil || eerr != nil {
		testing.fail_now(f.t, "cannot create the files for the output")
	}
	all := make([dynamic]string, f.a)
	append(&all, "--state", f.state)
	append(&all, ..args)
	code := dict.run(all[:], e, adapters, outf, errf)
	os.close(outf)
	os.close(errf)
	return Result{code = code, out = read_file(f, out_path), err = read_file(f, err_path)}
}

// lines is text split into its lines, without an empty last one.
lines :: proc(f: ^Fixture, text: string) -> []string {
	if text == "" {
		return {}
	}
	return strings.split(strings.trim_suffix(text, "\n"), "\n", f.a)
}

has :: proc(list: []string, word: string) -> bool {
	for w in list {
		if w == word {
			return true
		}
	}
	return false
}

count :: proc(list: []string, word: string) -> int {
	n := 0
	for w in list {
		if w == word {
			n += 1
		}
	}
	return n
}

// The fixture adapters. A test sets the list each one holds and whether it
// fails; the lists live in the fixture's arena. They are thread-local,
// because the runner runs tests in parallel and an adapter's procedures
// take nothing that would tell the tests apart.

Store :: struct {
	words:      []string,
	reads:      int,
	writes:     int,
	fail_read:  bool,
	fail_write: bool,
}

@(thread_local)
fixture_allocator: runtime.Allocator
@(thread_local)
stores: [3]Store
@(thread_local)
write_log: [dynamic]string

store_read :: proc(i: int) -> ([]string, dict.Error) {
	stores[i].reads += 1
	if stores[i].fail_read {
		return nil, "the fixture refuses to be read"
	}
	// The core owns what read returns, in its own allocator.
	out := make([]string, len(stores[i].words))
	for w, j in stores[i].words {
		out[j] = strings.clone(w)
	}
	return out, nil
}

store_write :: proc(i: int, name: string, words: []string) -> dict.Error {
	if stores[i].fail_write {
		return "the fixture refuses to be written"
	}
	stores[i].writes += 1
	kept := make([]string, len(words), fixture_allocator)
	for w, j in words {
		kept[j] = strings.clone(w, fixture_allocator)
	}
	stores[i].words = kept
	if write_log == nil {
		write_log = make([dynamic]string, fixture_allocator)
	}
	append(&write_log, name)
	return nil
}

read_alpha :: proc() -> ([]string, dict.Error) {return store_read(0)}
write_alpha :: proc(words: []string) -> dict.Error {return store_write(0, "alpha", words)}
read_beta :: proc() -> ([]string, dict.Error) {return store_read(1)}
write_beta :: proc(words: []string) -> dict.Error {return store_write(1, "beta", words)}
read_gamma :: proc() -> ([]string, dict.Error) {return store_read(2)}
write_gamma :: proc(words: []string) -> dict.Error {return store_write(2, "gamma", words)}

ALPHA :: 0
BETA :: 1
GAMMA :: 2

// adapters is the three fixture adapters; gamma is one that must be stopped
// to be written, as Handy must.
adapters :: proc() -> []dict.Adapter {
	@(static) list := [3]dict.Adapter {
		{name = "gamma", read = read_gamma, write = write_gamma, must_stop = true},
		{name = "alpha", read = read_alpha, write = write_alpha},
		{name = "beta", read = read_beta, write = write_beta},
	}
	return list[:]
}

set :: proc(i: int, words: ..string) {
	kept := make([]string, len(words), fixture_allocator)
	for w, j in words {
		kept[j] = strings.clone(w, fixture_allocator)
	}
	stores[i].words = kept
}

words_of :: proc(i: int) -> []string {
	return stores[i].words
}

// listed is the words the list command prints.
listed :: proc(f: ^Fixture) -> []string {
	r := run(f, nil, "list")
	testing.expectf(f.t, r.code == 0, "list exits 0, not %d: %s", r.code, r.err)
	return lines(f, r.out)
}
