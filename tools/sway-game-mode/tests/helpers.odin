// What the tests share: a throwaway directory under TMPDIR, and a stand-in
// for Sway that serves its IPC socket. It keeps a focus and a mode, answers
// get_tree, get_binding_state, subscribe and run_command as Sway does (a
// "mode X" command changes the mode, as the real one does), records every
// request, and pushes events to the subscribers on request. Its Behavior
// makes it hang, hang up, or send garbage. It is written without the
// tool's frame code, so a mistake the tool makes in the frames is not
// repeated here; tests/desktop/sway-game-mode.nix runs the tool against a
// real headless Sway.
package sway_game_mode_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import sg ".."

WAIT :: 5 * time.Second

scratch :: proc(t: ^testing.T) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, err := os.make_directory_temp(tmp, "sgm-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	return dir
}

Behavior :: struct {
	// The mode before the first request; "" is "default".
	mode:          string,
	// The app_id (or XWayland class) of the window with focus; "" is an
	// empty workspace, which holds the focus itself.
	focused:       string,
	// The focused window is XWayland: app_id null, a class.
	xwayland:      bool,
	// The focused window floats.
	floating:      bool,
	// Windows without focus, to make the tree big.
	filler:        int,
	// The tree reply, instead of the one built from the above.
	tree:          string,
	// The binding state reply, instead of {"name": mode}.
	binding_state: string,
	// What to send as the subscribe reply, instead of {"success": true}.
	subscribe_reply: string,
	// Commands that are answered with a failure.
	refuse_commands: bool,
	// The request type that gets no answer, and the one at which Sway
	// hangs up (after close_skip such requests were answered).
	hang_on:       Maybe(u32),
	// Requests of that type answered before the hang, and whether only one
	// request hangs (the next ones are answered).
	hang_skip:     int,
	hang_once:     bool,
	close_on:      Maybe(u32),
	close_skip:    int,
	// The request type that is answered with these bytes instead of a frame.
	garbage_on:    Maybe(u32),
	garbage:       []u8,
	// The request type that is answered with a frame of another type.
	wrong_type_on: Maybe(u32),
	// Replies go out one byte at a time.
	dribble:       bool,
}

Fake :: struct {
	behavior:   Behavior,
	arena:      virtual.Arena,
	a:          runtime.Allocator,
	dir:        string,
	socket:     string,
	listen_fd:  linux.Fd,
	stop:       bool,
	acceptor:   ^thread.Thread,
	mu:         sync.Mutex,
	handlers:   [dynamic]^thread.Thread,
	// What the fake records, under mu.
	connections: int,
	commands:   [dynamic]string,
	requests:   [dynamic]u32,
	subscribers: [dynamic]linux.Fd,
	subscriptions: [dynamic]string,
	mode:       string,
	focused:    string,
}

fake_start :: proc(t: ^testing.T, b: Behavior) -> ^Fake {
	f := new(Fake)
	if virtual.arena_init_growing(&f.arena) != nil {
		testing.fail_now(t, "no memory for the fake sway")
	}
	f.a = virtual.arena_allocator(&f.arena)
	f.behavior = b
	f.mode = strings.clone(b.mode if b.mode != "" else "default", f.a)
	f.focused = strings.clone(b.focused, f.a)
	f.handlers = make([dynamic]^thread.Thread, f.a)
	f.commands = make([dynamic]string, f.a)
	f.requests = make([dynamic]u32, f.a)
	f.subscribers = make([dynamic]linux.Fd, f.a)
	f.subscriptions = make([dynamic]string, f.a)
	f.dir = strings.clone(scratch(t), f.a)
	f.socket = strings.concatenate({f.dir, "/sway-ipc.sock"}, f.a)
	if len(f.socket) > sg.MAX_SOCKET_PATH {
		os.remove_all(f.dir)
		testing.fail_now(t, "TMPDIR is too long for the test's socket path; set a shorter one")
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], f.socket)
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE || linux.bind(fd, &addr) != .NONE || linux.listen(fd, 8) != .NONE {
		os.remove_all(f.dir)
		testing.fail_now(t, "cannot listen on the fake sway's socket")
	}
	f.listen_fd = fd
	f.acceptor = thread.create_and_start_with_poly_data(f, fake_accept, context)
	return f
}

// fake_stop ends every connection and frees the threads; the test reads
// what the fake recorded after it, with fake_free at the end.
fake_stop :: proc(f: ^Fake) {
	sync.atomic_store(&f.stop, true)
	thread.join(f.acceptor)
	thread.destroy(f.acceptor)
	for h in f.handlers {
		thread.join(h)
		thread.destroy(h)
	}
	linux.close(f.listen_fd)
	os.remove_all(f.dir)
}

fake_free :: proc(f: ^Fake) {
	virtual.arena_destroy(&f.arena)
	free(f)
}

fake_accept :: proc(f: ^Fake) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	for !sync.atomic_load(&f.stop) {
		fds := []linux.Poll_Fd{{fd = f.listen_fd, events = {.IN}}}
		n, _ := linux.poll(fds, 20)
		if n > 0 {
			addr: linux.Sock_Addr_Un
			c, e := linux.accept(f.listen_fd, &addr, {.CLOEXEC})
			if e == .NONE {
				sync.guard(&f.mu)
				f.connections += 1
				append(&f.handlers, thread.create_and_start_with_poly_data2(f, c, fake_connection, context))
			}
		}
	}
}

// read_exact reads n bytes, or fails when the peer hangs up or the fake is
// stopped.
read_exact :: proc(f: ^Fake, fd: linux.Fd, buf: []u8) -> bool {
	got := 0
	for got < len(buf) {
		if sync.atomic_load(&f.stop) {
			return false
		}
		fds := []linux.Poll_Fd{{fd = fd, events = {.IN}}}
		n, _ := linux.poll(fds, 20)
		if n <= 0 {
			continue
		}
		r, e := linux.recv(fd, buf[got:], {.DONTWAIT})
		if e == .EAGAIN || e == .EINTR {
			continue
		}
		if e != .NONE || r == 0 {
			return false
		}
		got += r
	}
	return true
}

put_u32 :: proc(out: ^[dynamic]u8, v: u32) {
	// Little-endian, as sway on every host this runs on writes it.
	append(out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

frame_bytes :: proc(a: runtime.Allocator, type: u32, payload: string) -> []u8 {
	out := make([dynamic]u8, a)
	append(&out, "i3-ipc")
	put_u32(&out, u32(len(payload)))
	put_u32(&out, type)
	append(&out, payload)
	return out[:]
}

write_bytes :: proc(f: ^Fake, fd: linux.Fd, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		chunk := rest
		if f.behavior.dribble {
			chunk = rest[:1]
			time.sleep(20 * time.Microsecond)
		}
		n, e := linux.send(fd, chunk, {.NOSIGNAL})
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return false
		}
		rest = rest[n:]
	}
	return true
}

tree_json :: proc(f: ^Fake) -> string {
	b := &f.behavior
	game := f.focused
	node := proc(f: ^Fake, id: int, app: string, focused: bool, xwayland: bool) -> string {
		if xwayland {
			return fmt.aprintf(
				`{{"id":%d,"type":"con","focused":%v,"app_id":null,"window_properties":{{"class":%q}},"nodes":[],"floating_nodes":[]}}`,
				id,
				focused,
				app,
				allocator = f.a,
			)
		}
		return fmt.aprintf(
			`{{"id":%d,"type":"con","focused":%v,"app_id":%q,"nodes":[],"floating_nodes":[]}}`,
			id,
			focused,
			app,
			allocator = f.a,
		)
	}
	tiled := make([dynamic]string, f.a)
	floating := make([dynamic]string, f.a)
	for i in 0 ..< b.filler {
		append(&tiled, node(f, 100 + i, "filler", false, false))
	}
	if game != "" {
		if b.floating {
			append(&floating, node(f, 7, game, true, b.xwayland))
		} else {
			append(&tiled, node(f, 7, game, true, b.xwayland))
		}
	}
	return fmt.aprintf(
		`{{"id":1,"type":"root","focused":false,"floating_nodes":[],"nodes":[{{"id":2,"type":"output","focused":false,"floating_nodes":[],"nodes":[{{"id":3,"type":"workspace","name":"1","focused":%v,"nodes":[%s],"floating_nodes":[%s]}}]}}]}}`,
		game == "",
		strings.join(tiled[:], ",", f.a),
		strings.join(floating[:], ",", f.a),
		allocator = f.a,
	)
}

fake_connection :: proc(f: ^Fake, fd: linux.Fd) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	defer linux.close(fd)
	b := &f.behavior
	for {
		head: [14]u8
		if !read_exact(f, fd, head[:]) {
			return
		}
		length := int(head[6]) | int(head[7]) << 8 | int(head[8]) << 16 | int(head[9]) << 24
		type := u32(head[10]) | u32(head[11]) << 8 | u32(head[12]) << 16 | u32(head[13]) << 24
		body := make([]u8, length, f.a)
		if string(head[:6]) != "i3-ipc" || !read_exact(f, fd, body) {
			return
		}
		payload := string(body)

		sync.lock(&f.mu)
		append(&f.requests, type)
		if type == sg.MSG_RUN_COMMAND {
			append(&f.commands, payload)
			if strings.has_prefix(payload, "mode ") && !b.refuse_commands {
				f.mode = strings.clone(payload[5:], f.a)
			}
		}
		if type == sg.MSG_SUBSCRIBE {
			append(&f.subscribers, fd)
			append(&f.subscriptions, payload)
		}
		mode := f.mode
		if c, ok := b.close_on.?; ok && c == type {
			if b.close_skip > 0 {
				b.close_skip -= 1
			} else {
				sync.unlock(&f.mu)
				return
			}
		}
		hung := false
		if hang, ok := b.hang_on.?; ok && hang == type {
			if b.hang_skip > 0 {
				b.hang_skip -= 1
			} else {
				hung = true
				if b.hang_once {
					b.hang_on = nil
				}
			}
		}
		garbage_on, has_garbage := b.garbage_on.?
		wrong_on, has_wrong := b.wrong_type_on.?
		reply: string
		switch type {
		case sg.MSG_RUN_COMMAND:
			reply = `[{"success":false,"error":"nope"}]` if b.refuse_commands else `[{"success":true}]`
		case sg.MSG_SUBSCRIBE:
			reply = b.subscribe_reply if b.subscribe_reply != "" else `{"success":true}`
		case sg.MSG_GET_TREE:
			reply = b.tree if b.tree != "" else tree_json(f)
		case sg.MSG_GET_BINDING_STATE:
			reply = b.binding_state if b.binding_state != "" else fmt.aprintf(`{{"name":%q}}`, mode, allocator = f.a)
		case:
			reply = "{}"
		}
		out := frame_bytes(f.a, wrong_on + 1 if has_wrong && wrong_on == type else type, reply)
		if has_garbage && garbage_on == type {
			out = b.garbage
		}
		sync.unlock(&f.mu)

		if hung {
			continue
		}
		if !write_bytes(f, fd, out) {
			return
		}
	}
}

// ── what a test does to the fake, and asks it ────────────────────────────────

// fake_event pushes one event frame to every subscriber.
fake_event :: proc(f: ^Fake, type: u32, payload: string) {
	sync.guard(&f.mu)
	data := frame_bytes(f.a, type, payload)
	for fd in f.subscribers {
		write_bytes(f, fd, data)
	}
}

// fake_raw pushes bytes as they are to every subscriber.
fake_raw :: proc(f: ^Fake, data: []u8) {
	sync.guard(&f.mu)
	for fd in f.subscribers {
		write_bytes(f, fd, data)
	}
}

// fake_hang_up closes the subscribers' connections from the fake's side.
fake_hang_up :: proc(f: ^Fake) {
	sync.guard(&f.mu)
	for fd in f.subscribers {
		linux.shutdown(fd, .RDWR)
	}
}

// fake_focus moves the focus, as the user does, and says so with an event.
fake_focus :: proc(f: ^Fake, app: string) {
	sync.lock(&f.mu)
	f.focused = strings.clone(app, f.a)
	sync.unlock(&f.mu)
	fake_event(f, sg.EVENT_WINDOW, `{"change":"focus","container":{"id":7}}`)
}

fake_set_mode :: proc(f: ^Fake, mode: string) {
	sync.guard(&f.mu)
	f.mode = strings.clone(mode, f.a)
}

fake_mode :: proc(f: ^Fake) -> string {
	sync.guard(&f.mu)
	return strings.clone(f.mode, context.temp_allocator)
}

fake_commands :: proc(f: ^Fake) -> []string {
	sync.guard(&f.mu)
	out := make([]string, len(f.commands), context.temp_allocator)
	copy(out, f.commands[:])
	return out
}

fake_count :: proc(f: ^Fake, type: u32) -> int {
	sync.guard(&f.mu)
	n := 0
	for r in f.requests {
		if r == type {
			n += 1
		}
	}
	return n
}

fake_requests :: proc(f: ^Fake) -> int {
	sync.guard(&f.mu)
	return len(f.requests)
}

fake_subscribed :: proc(f: ^Fake) -> int {
	sync.guard(&f.mu)
	return len(f.subscribers)
}

// eventually polls cond until it holds or WAIT has passed.
eventually :: proc(f: ^Fake, cond: proc(f: ^Fake, n: int) -> bool, n: int) -> bool {
	deadline := time.tick_add(time.tick_now(), WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if cond(f, n) {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return cond(f, n)
}

has_commands :: proc(f: ^Fake, n: int) -> bool {
	sync.guard(&f.mu)
	return len(f.commands) >= n
}

has_subscriber :: proc(f: ^Fake, n: int) -> bool {
	sync.guard(&f.mu)
	return len(f.subscribers) >= n
}

has_tree_requests :: proc(f: ^Fake, n: int) -> bool {
	sync.guard(&f.mu)
	c := 0
	for r in f.requests {
		if r == sg.MSG_GET_TREE {
			c += 1
		}
	}
	return c >= n
}

has_state_requests :: proc(f: ^Fake, n: int) -> bool {
	sync.guard(&f.mu)
	c := 0
	for r in f.requests {
		if r == sg.MSG_GET_BINDING_STATE {
			c += 1
		}
	}
	return c >= n
}

// ── a watcher in a thread of the test ────────────────────────────────────────

Run :: struct {
	cfg:     sg.Config,
	code:    int,
	done:    bool,
	worker:  ^thread.Thread,
	stopfd:  linux.Fd,
	log:     ^os.File,
}

run_main :: proc(r: ^Run) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	r.code = sg.watch(r.cfg)
	sync.atomic_store(&r.done, true)
}

// run_start starts the watcher on the fake's socket and returns when it has
// subscribed and looked once.
run_start :: proc(t: ^testing.T, f: ^Fake, timeout := WAIT) -> ^Run {
	r := new(Run)
	fd, e := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if e != .NONE {
		testing.fail_now(t, "no eventfd")
	}
	r.stopfd = fd
	r.log, _ = os.open("/dev/null", os.O_WRONLY)
	r.cfg = sg.Config {
		socket  = f.socket,
		stop    = fd,
		timeout = timeout,
		log     = r.log,
	}
	r.worker = thread.create_and_start_with_poly_data(r, run_main, context)
	return r
}

// run_signal stands in for SIGTERM.
run_signal :: proc(r: ^Run) {
	one := u64(1)
	linux.write(r.stopfd, (cast(^[8]u8)&one)[:])
}

run_done :: proc(r: ^Run) -> bool {
	deadline := time.tick_add(time.tick_now(), WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if sync.atomic_load(&r.done) {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return sync.atomic_load(&r.done)
}

// run_end stops the watcher if it still runs, joins it, and returns its
// exit status (-1 when it did not end).
run_end :: proc(r: ^Run) -> int {
	if !sync.atomic_load(&r.done) {
		run_signal(r)
	}
	ended := run_done(r)
	if ended {
		thread.join(r.worker)
	}
	thread.destroy(r.worker)
	linux.close(r.stopfd)
	os.close(r.log)
	code := r.code if ended else -1
	free(r)
	return code
}

same_strings :: proc(got, want: []string) -> bool {
	if len(got) != len(want) {
		return false
	}
	for w, i in want {
		if got[i] != w {
			return false
		}
	}
	return true
}
