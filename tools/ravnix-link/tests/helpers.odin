// What the tests share: a throwaway tree under TMPDIR for each test, with
// the client's and the daemon's state directories, a vault, a socket path
// and a bin directory of stand-ins for the programs the tool runs
// (testdata/stub), and a daemon that serves in a thread of the test.
package ravnix_link_tests

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import link ".."

STUB :: #directory + "/testdata/stub"

Fixture :: struct {
	t:      ^testing.T,
	arena:  virtual.Arena,
	a:      runtime.Allocator,
	dir:    string,
	bin:    string,
	vault:  string,
	socket: string,
	// The client's configuration (muninn's side) and the daemon's (huginn's).
	client: link.Config,
	server: link.Config,
	stderr: ^os.File,
	daemon: ^link.Daemon,
	stop:   bool,
	worker: ^thread.Thread,
}

// fixture makes the tree. Everything it allocates is in its arena, which
// fixture_destroy frees with the tree.
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
	dir, err := os.make_directory_temp(tmp, "rl-*", f.a)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	f.dir = dir
	f.bin = join(f, "bin")
	f.vault = join(f, "vault")
	f.socket = join(f, "s")
	// A test that fails now leaves its directory behind, so the one reason
	// a whole run would fail on its own machine is caught before the rest.
	if len(f.socket) > link.MAX_SOCKET_PATH {
		os.remove_all(dir)
		testing.fail_now(t, "TMPDIR is too long for the test's socket path; set a shorter one")
	}
	for sub in ([]string{f.bin, f.vault}) {
		if os.make_directory(sub) != nil {
			testing.fail_now(t, "cannot make the test's directories")
		}
	}
	for name in ([]string{"xdg-open", "notify-send", "obsidian", "git", "ravnix-notify", "forward"}) {
		if os.symlink(STUB, join(f, "bin", name)) != nil {
			testing.fail_now(t, "cannot link the stub")
		}
	}
	errf, eerr := os.create(join(f, "stderr"))
	if eerr != nil {
		testing.fail_now(t, "cannot create the test's stderr file")
	}
	f.stderr = errf

	f.client = link.Config {
		socket           = f.socket,
		state            = join(f, "state"),
		vault            = f.vault,
		git              = join(f, "bin", "git"),
		ravnix_notify    = join(f, "bin", "ravnix-notify"),
		notify_send      = join(f, "bin", "notify-send"),
		stderr           = f.stderr,
		reply_timeout_ms = 10_000,
		lock_wait_ms     = 10_000,
	}
	f.server = link.Config {
		socket       = f.socket,
		state        = join(f, "daemon-state"),
		xdg_open     = join(f, "bin", "xdg-open"),
		notify_send  = join(f, "bin", "notify-send"),
		obsidian     = join(f, "bin", "obsidian"),
		stderr       = f.stderr,
		open_wait_ms = 1500,
		idle_ms      = 5_000,
	}
	return f
}

fixture_destroy :: proc(f: ^Fixture) {
	stop_daemon(f)
	os.close(f.stderr)
	os.remove_all(f.dir)
	virtual.arena_destroy(&f.arena)
	free(f)
}

join :: proc(f: ^Fixture, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1, f.a)
	append(&all, f.dir)
	append(&all, ..parts)
	return strings.join(all[:], "/", f.a)
}

// set_case writes what the stand-ins do in this test (see testdata/stub).
set_case :: proc(f: ^Fixture, body: string) {
	testing.expect_value(f.t, os.write_entire_file(join(f, "bin", "case.sh"), body), nil)
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

// runs reads the stand-ins' log: one entry per run, its name first.
runs :: proc(f: ^Fixture) -> [][]string {
	text := read_file(f, join(f, "bin", "log"))
	out := make([dynamic][]string, f.a)
	for record in strings.split(text, "\x01", f.a) {
		if record == "" {
			continue
		}
		fields := strings.split(strings.trim_suffix(record, "\x00"), "\x00", f.a)
		append(&out, fields)
	}
	return out[:]
}

// runs_of is runs, only those of the program named name.
runs_of :: proc(f: ^Fixture, name: string) -> [][]string {
	out := make([dynamic][]string, f.a)
	for r in runs(f) {
		if r[0] == name {
			append(&out, r)
		}
	}
	return out[:]
}

// git_sub is the subcommand of a run of the git stand-in: the word after
// -C VAULT and --literal-pathspecs.
git_sub :: proc(r: []string) -> string {
	for i := 1; i < len(r); i += 1 {
		switch r[i] {
		case "--literal-pathspecs":
			continue
		case "-C":
			i += 1
			continue
		}
		return r[i]
	}
	return ""
}

// git_runs is the runs of git with the subcommand sub.
git_runs :: proc(f: ^Fixture, sub: string) -> [][]string {
	out := make([dynamic][]string, f.a)
	for r in runs_of(f, "git") {
		if git_sub(r) == sub {
			append(&out, r)
		}
	}
	return out[:]
}

// run_order is the runs by program, a run of git by its subcommand, without
// the reads of HEAD and the log.
run_order :: proc(f: ^Fixture) -> string {
	names := make([dynamic]string, f.a)
	for r in runs(f) {
		if r[0] != "git" {
			append(&names, r[0])
		} else if sub := git_sub(r); sub != "rev-parse" && sub != "log" {
			append(&names, sub)
		}
	}
	return strings.join(names[:], " ", f.a)
}

// OBSIDIAN_DOES_IT is a case for the stand-in obsidian that does the
// operation in the fixture's vault, as Obsidian and the sync would; $v is
// the vault.
OBSIDIAN_DOES_IT :: `[ "$n" = obsidian ] && {
  p=${2#path=}
  case $p in */*) dir=${p%/*}/ ;; *) dir= ;; esac
  case $1 in
  rename) mv "$v/$p" "$v/$dir${3#name=}.md" ;;
  move) mkdir -p "$v/${3#to=}" && mv "$v/$p" "$v/${3#to=}/" ;;
  delete) rm -f "$v/$p" ;;
  esac
}
`

// set_case_in_vault is set_case with $v the vault, and obsidian doing its
// operations there, before body.
set_case_in_vault :: proc(f: ^Fixture, body := "") {
	set_case(f, strings.concatenate({"v='", f.vault, "'\n", OBSIDIAN_DOES_IT, body}, f.a))
}

// note writes a note into the vault, its folders included.
note :: proc(f: ^Fixture, path: string, text := "text\n") {
	full := strings.concatenate({f.vault, "/", path}, f.a)
	if slash := strings.last_index_byte(full, '/'); slash > 0 {
		os.make_directory_all(full[:slash])
	}
	write_file(f, full, text)
}

stderr_text :: proc(f: ^Fixture) -> string {
	return read_file(f, join(f, "stderr"))
}

daemon_worker :: proc(f: ^Fixture) {
	// A thread given a context keeps its temporary memory unless it frees it.
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	link.daemon_serve(f.daemon, &f.stop, 20)
}

// start_daemon opens the daemon on the fixture's socket and serves it in a
// thread until stop_daemon.
start_daemon :: proc(f: ^Fixture) {
	d, why := link.daemon_open(f.server)
	if why != "" {
		os.remove_all(f.dir)
		testing.fail_now(f.t, why)
	}
	f.daemon = d
	sync.atomic_store(&f.stop, false)
	f.worker = thread.create_and_start_with_poly_data(f, daemon_worker, context)
}

// crash_daemon stops the daemon as a crash would: its socket stays.
crash_daemon :: proc(f: ^Fixture) {
	if f.worker != nil {
		sync.atomic_store(&f.stop, true)
		thread.join(f.worker)
		thread.destroy(f.worker)
		f.worker = nil
	}
	link.daemon_close_keeping_socket(f.daemon)
	f.daemon = nil
}

stop_daemon :: proc(f: ^Fixture) {
	if f.worker != nil {
		sync.atomic_store(&f.stop, true)
		thread.join(f.worker)
		thread.destroy(f.worker)
		f.worker = nil
	}
	if f.daemon != nil {
		link.daemon_close(f.daemon)
		f.daemon = nil
	}
}

// The requests of the tests. Each has a fresh id and the fixture's clock.
open_request :: proc(f: ^Fixture, target: string) -> link.Request {
	return link.Request{id = link.new_id(f.a), kind = .Open, created = now(f), target = target}
}

notify_request :: proc(f: ^Fixture, summary, body: string) -> link.Request {
	return link.Request{id = link.new_id(f.a), kind = .Notify, created = now(f), summary = summary, body = body}
}

obsidian_request :: proc(f: ^Fixture, op: link.Obsidian_Op, path: string, to := "", name := "") -> link.Request {
	return link.Request{id = link.new_id(f.a), kind = .Obsidian, created = now(f), op = op, path = path, to = to, name = name}
}

commit_request :: proc(f: ^Fixture, message: string, paths: ..string) -> link.Request {
	p := make([]string, len(paths), f.a)
	copy(p, paths)
	return link.Request{id = link.new_id(f.a), kind = .Vault_Commit, created = now(f), vault = f.vault, message = message, paths = p}
}

now :: proc(f: ^Fixture) -> string {
	return link.timestamp(link.clock(f.client), f.a)
}

// queue_lines is the client's queue file, line by line.
queue_lines :: proc(f: ^Fixture) -> []string {
	text := read_file(f, join(f, "state", "queue"))
	lines := strings.split_lines(strings.trim_suffix(text, "\n"), f.a)
	if text == "" {
		return {}
	}
	return lines
}

expect_enqueued :: proc(f: ^Fixture, r: link.Request, loc := #caller_location) {
	why := link.enqueue(f.client, r)
	testing.expect_value(f.t, why, "", loc = loc)
}

// record_of is what the client recorded for id, "" when it has nothing.
record_of :: proc(f: ^Fixture, id: string) -> (link.Record, bool) {
	snap, why := link.read_snapshot(f.client, f.a)
	testing.expect_value(f.t, why, "")
	rec, ok := snap.records[id]
	return rec, ok
}

contains :: strings.contains
