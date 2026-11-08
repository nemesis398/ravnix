// The daemon on huginn. It listens on the socket that the main connection
// forwards to muninn, takes one connection at a time, and answers each
// request line with one reply line, after it ran the request: xdg-open for
// open, notify-send for notify, and obsidian for an Obsidian operation,
// with nothing on its standard input. It never runs git: vault-commit is
// the server's.
//
// With systemd_run set, each program starts in a transient scope of its
// own (systemd-run --user --scope), so what it starts (a browser, Obsidian)
// is not in the daemon's unit and outlives a restart of it. The output of
// xdg-open and notify-send goes to the daemon's standard error (the
// journal), and they are judged by their exit; obsidian's goes to a pipe
// that the daemon reads, for its Error: line, until the CLI ends.
//
// Every id it is given goes into its seen file, as started before the
// request runs and as done or failed after: a request whose id it has seen
// is answered from there and not run again, whether the client sent it
// twice, crashed before it wrote down the answer, or the daemon itself
// stopped while it ran (then the request is failed, not run again).
package ravnix_link

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// The defaults of the daemon's limits, in milliseconds.
DEFAULT_OPEN_WAIT :: 5_000 // an xdg-open still running then has opened its link
DEFAULT_IDLE :: 30_000 // a connection that sends nothing for this long is closed
DEFAULT_PROGRAM_TIMEOUT :: 60_000 // obsidian may first have to start Obsidian
NOTIFY_SEND_TIMEOUT :: 10_000
// The ids kept in the seen file: the newest of them, when it is rewritten
// at start with more than twice as many records.
SEEN_KEEP :: 10_000
// The environment variable that marks the daemon's programs.
DAEMON_MARKER :: "RAVNIX_LINK_DAEMON"
// How often a socket left behind is tried before it counts as another
// daemon's, and the pause between the tries: half a second in all.
PROBE_TRIES :: 10
PROBE_PAUSE :: 50 * time.Millisecond

Daemon :: struct {
	cfg:        Config,
	allocator:  runtime.Allocator,
	listener:   linux.Fd,
	lock:       linux.Fd,
	seen:       map[string]Record,
	seen_order: [dynamic]string,
	env:        []string,
	children:   [dynamic]Child,
	// The read ends of obsidian's output, after the CLI ended: what it
	// started (Obsidian) may write on, into the journal.
	drains:     [dynamic]linux.Fd,
	reader_buf: []u8,
}

// daemon_open makes the socket and reads what the daemon has seen. It
// refuses a second daemon, on the socket or the state directory, and a
// socket path where something other than a socket is.
daemon_open :: proc(cfg: Config, allocator := context.allocator) -> (^Daemon, string) {
	addr, why := socket_address(cfg.socket)
	if why != "" {
		return nil, why
	}
	if why = ensure_dir(cfg.state); why != "" {
		return nil, why
	}
	lock_fd, lwhy := open_state(state_path(cfg, "daemon.lock"), true)
	if lwhy != "" {
		return nil, lwhy
	}
	if lock(lock_fd, {.EX, .NB}) != .NONE {
		linux.close(lock_fd)
		return nil, fmt.tprintf("a daemon already runs with the state directory %s", cfg.state)
	}
	fail :: proc(fds: ..linux.Fd) {
		for fd in fds {
			linux.close(fd)
		}
	}

	st: linux.Stat
	if linux.lstat(cstr(cfg.socket), &st) == .NONE {
		if !linux.S_ISSOCK(st.mode) {
			fail(lock_fd)
			return nil, fmt.tprintf("%s is not a socket, and the daemon leaves it alone", cfg.socket)
		}
		if listens(cfg.socket) {
			fail(lock_fd)
			return nil, fmt.tprintf("a daemon already listens on %s", cfg.socket)
		}
		// A socket nobody listens on is a daemon's that died.
		linux.unlink(cstr(cfg.socket))
	}
	listener, se := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if se != .NONE {
		fail(lock_fd)
		return nil, fmt.tprintf("cannot make a socket: %s", errno_text(se))
	}
	if e := linux.bind(listener, &addr); e != .NONE {
		fail(listener, lock_fd)
		if e == .EADDRINUSE {
			return nil, fmt.tprintf("a daemon already listens on %s", cfg.socket)
		}
		return nil, fmt.tprintf("cannot listen on %s: %s", cfg.socket, errno_text(e))
	}
	// The directory is the user's alone ($XDG_RUNTIME_DIR), so nobody else
	// could connect before this; the socket is the user's alone after it.
	if e := linux.chmod(cstr(cfg.socket), transmute(linux.Mode)u32(0o600)); e != .NONE {
		fail(listener, lock_fd)
		linux.unlink(cstr(cfg.socket))
		return nil, fmt.tprintf("cannot make %s the user's alone: %s", cfg.socket, errno_text(e))
	}
	if e := linux.listen(listener, 16); e != .NONE {
		fail(listener, lock_fd)
		linux.unlink(cstr(cfg.socket))
		return nil, fmt.tprintf("cannot listen on %s: %s", cfg.socket, errno_text(e))
	}

	d := new(Daemon, allocator)
	d.allocator = allocator
	d.cfg = cfg
	d.listener = listener
	d.lock = lock_fd
	d.seen = make(map[string]Record, allocator)
	d.seen_order = make([dynamic]string, allocator)
	d.children = make([dynamic]Child, allocator)
	d.drains = make([dynamic]linux.Fd, allocator)
	d.reader_buf = make([]u8, MAX_LINE, allocator)
	load_seen(d)

	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 1, allocator)
	for kv in environ {
		if !strings.has_prefix(kv, DAEMON_MARKER + "=") {
			append(&env, strings.clone(kv, allocator))
		}
	}
	append(&env, strings.clone(DAEMON_MARKER + "=1", allocator))
	d.env = env[:]
	return d, ""
}

// listens says whether a daemon listens on the socket at path. A child that
// a daemon forked just before it died holds a copy of the listening socket
// until it runs its program, and the socket takes connections until then:
// so a socket counts as listened on only when it takes every one of
// PROBE_TRIES connections, over half a second.
listens :: proc(path: string) -> bool {
	for i in 0 ..< PROBE_TRIES {
		fd, why := dial(path)
		if why != "" {
			return false
		}
		hang_up(fd)
		if i + 1 < PROBE_TRIES {
			time.sleep(PROBE_PAUSE)
		}
	}
	return true
}

load_seen :: proc(d: ^Daemon) {
	path := state_path(d.cfg, "seen")
	text, why := read_state(path, context.temp_allocator)
	if why != "" {
		report(d.cfg, "%s; the requests seen before are forgotten", why)
		return
	}
	lines := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		lines += 1
		rec, rwhy := decode_record(line, context.temp_allocator)
		if rwhy != "" {
			continue
		}
		remember(d, rec)
	}
	if lines > 2 * SEEN_KEEP {
		for len(d.seen_order) > SEEN_KEEP {
			id := d.seen_order[0]
			ordered_remove(&d.seen_order, 0)
			old := d.seen[id]
			delete_key(&d.seen, id)
			delete(old.id, d.allocator)
			delete(old.error, d.allocator)
		}
		b := strings.builder_make(context.temp_allocator)
		for id in d.seen_order {
			strings.write_string(&b, encode_record(d.seen[id], context.temp_allocator))
		}
		if rwhy := replace_file(path, strings.to_string(b)); rwhy != "" {
			report(d.cfg, "%s", rwhy)
		}
	}
}

// remember keeps rec as what the daemon knows of its id: a final record
// wins over started.
remember :: proc(d: ^Daemon, rec: Record) {
	if old, ok := d.seen[rec.id]; ok {
		if is_final(old.status) && !is_final(rec.status) {
			return
		}
		delete(old.error, d.allocator)
		d.seen[old.id] = Record{id = old.id, status = rec.status, error = strings.clone(rec.error, d.allocator)}
		return
	}
	id := strings.clone(rec.id, d.allocator)
	d.seen[id] = Record{id = id, status = rec.status, error = strings.clone(rec.error, d.allocator)}
	append(&d.seen_order, id)
}

// note writes rec to the seen file before the daemon goes on, and keeps it.
note :: proc(d: ^Daemon, rec: Record) -> string {
	why := append_line(state_path(d.cfg, "seen"), encode_record(rec, context.temp_allocator))
	remember(d, rec)
	return why
}

daemon_serve :: proc(d: ^Daemon, stop: ^bool, poll_ms := 1000) {
	for !sync.atomic_load(stop) {
		reap(d)
		fds := make([dynamic]linux.Poll_Fd, 0, len(d.drains) + 1, context.temp_allocator)
		append(&fds, linux.Poll_Fd{fd = d.listener, events = {.IN}})
		for p in d.drains {
			append(&fds, linux.Poll_Fd{fd = p, events = {.IN}})
		}
		n, pe := linux.poll(fds[:], i32(poll_ms))
		if pe != .NONE || n <= 0 {
			free_all(context.temp_allocator)
			continue
		}
		drain(d)
		if fds[0].revents & {.IN} == {} {
			free_all(context.temp_allocator)
			continue
		}
		addr: linux.Sock_Addr_Un
		fd, e := linux.accept(d.listener, &addr, {.CLOEXEC})
		if e != .NONE {
			continue
		}
		serve_connection(d, fd)
		linux.close(fd)
		free_all(context.temp_allocator)
	}
}

// drain copies what waits in each kept output to the daemon's standard
// error, the journal, and closes one at its end.
drain :: proc(d: ^Daemon) {
	errf := d.cfg.stderr if d.cfg.stderr != nil else os.stderr
	buf: [4096]u8
	for i := len(d.drains) - 1; i >= 0; i -= 1 {
		for {
			k, e := linux.read(d.drains[i], buf[:])
			if k > 0 {
				write_all_fd(linux.Fd(os.fd(errf)), buf[:k])
				continue
			}
			if e == .EAGAIN || e == .EINTR {
				break
			}
			// The end: everything that held the output has let it go.
			linux.close(d.drains[i])
			unordered_remove(&d.drains, i)
			break
		}
	}
}

// reap collects the xdg-open runs that went on after their request.
reap :: proc(d: ^Daemon) {
	for i := len(d.children) - 1; i >= 0; i -= 1 {
		if _, _, ended := wait_child(&d.children[i], 0); ended {
			unordered_remove(&d.children, i)
		}
	}
}

serve_connection :: proc(d: ^Daemon, fd: linux.Fd) {
	reader := Line_Reader {
		fd  = fd,
		buf = d.reader_buf,
	}
	idle := or_default(d.cfg.idle_ms, DEFAULT_IDLE)
	for {
		line, status := read_line(&reader, idle)
		switch status {
		case .Line:
		case .Too_Long:
			reply := Reply {
				status = .Failed,
				error  = fmt.tprintf("the line is longer than the %d bytes a request may have", MAX_LINE),
			}
			send_all(fd, transmute([]u8)encode_reply(reply, context.temp_allocator), idle)
			return
		case .Closed, .Timeout, .Broken:
			return
		}
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {
			return
		}
		reply := handle(d, line, virtual.arena_allocator(&arena))
		drain(d)
		why := send_all(fd, transmute([]u8)encode_reply(reply, virtual.arena_allocator(&arena)), idle)
		virtual.arena_destroy(&arena)
		if why != "" {
			return
		}
	}
}

// id_of is the id a line that is no request gives, if it gives a UUID.
id_of :: proc(line: string, allocator: runtime.Allocator) -> string {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	obj, why := parse_object(line, &arena)
	if why != "" {
		return ""
	}
	id, _ := string_field(obj, "id", true, allocator)
	return id if is_uuid(id) else ""
}

// handle answers one line.
handle :: proc(d: ^Daemon, line: string, allocator: runtime.Allocator) -> Reply {
	r, why := decode_request(line, allocator)
	if why != "" {
		return Reply{id = id_of(line, allocator), status = .Failed, error = fmt.aprintf("not a request: %s", why, allocator = allocator)}
	}
	if r.kind == .Vault_Commit {
		return Reply{id = r.id, status = .Failed, error = "vault-commit is the server's: the daemon on the laptop runs no git"}
	}
	if rec, seen := d.seen[r.id]; seen {
		switch rec.status {
		case .Started:
			return Reply {
				id     = r.id,
				status = .Failed,
				error  = "the daemon stopped while this request ran, and it is not run again, since it may have happened",
			}
		case .Done, .Expired, .Skipped:
			return Reply{id = r.id, status = .Done}
		case .Retry:
		// The daemon writes no retry record; one in the seen file is a
		// request that never ran, so it runs now.
		case .Failed:
			return Reply{id = r.id, status = .Failed, error = strings.clone(rec.error, allocator)}
		}
	}

	argv := make([dynamic]string, allocator)
	timeout := or_default(d.cfg.program_timeout_ms, DEFAULT_PROGRAM_TIMEOUT)
	detach := false
	output := Output.Pass
	switch r.kind {
	case .Open:
		append(&argv, d.cfg.xdg_open if d.cfg.xdg_open != "" else "xdg-open", r.target)
		timeout = or_default(d.cfg.open_wait_ms, DEFAULT_OPEN_WAIT)
		detach = true
	case .Notify:
		append(&argv, d.cfg.notify_send if d.cfg.notify_send != "" else "notify-send")
		if r.urgency != "" {
			append(&argv, "-u", r.urgency)
		}
		if r.app != "" {
			append(&argv, "-a", r.app)
		}
		append(&argv, "--", r.summary)
		if r.body != "" {
			append(&argv, r.body)
		}
		timeout = min(timeout, NOTIFY_SEND_TIMEOUT)
	case .Obsidian:
		output = .Pipe
		append(&argv, d.cfg.obsidian if d.cfg.obsidian != "" else "obsidian", OP_NAMES[r.op])
		append(&argv, strings.concatenate({"path=", r.path}, allocator))
		switch r.op {
		case .Move:
			append(&argv, strings.concatenate({"to=", r.to}, allocator))
		case .Rename:
			append(&argv, strings.concatenate({"name=", r.name}, allocator))
		case .Delete, .None:
		}
	case .Vault_Commit:
	}
	// A program that is not there has run nothing: the request waits for
	// it, and is not recorded.
	if _, found := find_program(argv[0]); !found {
		return Reply {
			id     = r.id,
			status = .Retry,
			error  = fmt.aprintf("%s is not installed on the laptop, or not on the daemon's PATH", argv[0], allocator = allocator),
		}
	}
	if d.cfg.systemd_run != "" {
		if _, found := find_program(d.cfg.systemd_run); !found {
			return Reply {
				id     = r.id,
				status = .Retry,
				error  = fmt.aprintf("%s is not installed on the laptop, so no program can get a scope of its own", d.cfg.systemd_run, allocator = allocator),
			}
		}
		// systemd-run --user needs the user manager's socket; without it, it
		// would fail and the request be lost, so the request waits.
		if sock := d.cfg.user_manager; sock != "" {
			st: linux.Stat
			if linux.lstat(cstr(sock), &st) != .NONE || !linux.S_ISSOCK(st.mode) {
				return Reply {
					id     = r.id,
					status = .Retry,
					error  = fmt.aprintf("the user manager's socket (%s) is not there, so systemd-run cannot give a program a scope", sock, allocator = allocator),
				}
			}
		}
		scoped := make([dynamic]string, allocator)
		append(&scoped, d.cfg.systemd_run, "--user", "--scope", "--collect", "--quiet", "--")
		append(&scoped, ..argv[:])
		argv = scoped
	}
	if nwhy := note(d, Record{id = r.id, status = .Started}); nwhy != "" {
		// Without the record the daemon cannot promise to run it once.
		return Reply{id = r.id, status = .Retry, error = fmt.aprintf("cannot record the request: %s", nwhy, allocator = allocator)}
	}
	program := argv[6] if d.cfg.systemd_run != "" else argv[0]
	errf := d.cfg.stderr if d.cfg.stderr != nil else os.stderr
	ran := run_program(argv[:], timeout, d.env, detach, allocator, output, linux.Fd(os.fd(errf)))
	if ran.running {
		append(&d.children, ran.child)
	}
	if ran.pipe >= 0 {
		append(&d.drains, ran.pipe)
		drain(d)
	}
	reply := Reply {
		id     = r.id,
		status = .Done,
	}
	if failure := judge(r, ran, program); failure != "" {
		reply.status = .Failed
		reply.error = strings.clone(failure, allocator)
	}
	if nwhy := note(d, Record{id = r.id, status = .Done if reply.status == .Done else .Failed, error = reply.error}); nwhy != "" {
		// It ran; a redelivery finds it started and is answered failed,
		// not run again.
		report(d.cfg, "cannot record how %s ended: %s", describe(r), nwhy)
	}
	return reply
}

// judge says why a run failed, "" when it did not. Obsidian's CLI exits 0
// on a failure and prints a line that starts with Error:, so that line is
// the failure, whatever the exit; the other programs fail by their exit.
judge :: proc(r: Request, ran: Program_Run, program: string) -> string {
	if r.kind == .Obsidian {
		rest := ran.output
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(strings.trim_space(line), "Error:") {
				return strings.trim_space(line)
			}
		}
	}
	if ran.running {
		return ""
	}
	if ran.why != "" || !ran.success {
		failure := program_failure(program, ran)
		if r.kind != .Obsidian && ran.why == "" {
			return fmt.tprintf("%s; its output is in the laptop's journal (journalctl --user -u ravnix-link-daemon)", failure)
		}
		return failure
	}
	return ""
}

daemon_close :: proc(d: ^Daemon) {
	if d == nil {
		return
	}
	linux.unlink(cstr(d.cfg.socket))
	daemon_close_keeping_socket(d)
}

// daemon_close_keeping_socket closes the daemon as a crash would: its
// socket file stays behind.
daemon_close_keeping_socket :: proc(d: ^Daemon) {
	if d == nil {
		return
	}
	linux.close(d.listener)
	lock(d.lock, {.UN})
	linux.close(d.lock)
	for c in d.children {
		// They are the user's applications now; only the handle goes.
		if c.pidfd >= 0 {
			linux.close(c.pidfd)
		}
	}
	for p in d.drains {
		linux.close(p)
	}
	for id, rec in d.seen {
		delete(rec.error, d.allocator)
		delete(id, d.allocator)
	}
	delete(d.seen)
	delete(d.seen_order)
	delete(d.children)
	delete(d.drains)
	for kv in d.env {
		delete(kv, d.allocator)
	}
	delete(d.env, d.allocator)
	delete(d.reader_buf, d.allocator)
	free(d, d.allocator)
}
