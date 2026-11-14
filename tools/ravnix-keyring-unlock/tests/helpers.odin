// What the tests share: a throwaway directory under TMPDIR, and a stand-in
// for the session bus with gnome-keyring behind it, which serves one
// connection in a thread of the test. It speaks the same wire format as the
// tool (it uses the tool's encoder and decoder, so a mistake both make
// alike is caught by the check that runs the real dbus-daemon and
// gnome-keyring-daemon, tests/desktop/keyring-autounlock.nix), records
// every call, and answers as its Behavior says.
package ravnix_keyring_unlock_tests

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import kr ".."

scratch :: proc(t: ^testing.T) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {
		tmp = "/tmp"
	}
	dir, err := os.make_directory_temp(tmp, "kru-*", context.temp_allocator)
	if err != nil {
		testing.fail_now(t, "cannot make the test's directory under TMPDIR")
	}
	return dir
}

write_file :: proc(t: ^testing.T, dir, name, content: string) -> string {
	path := strings.concatenate({dir, "/", name}, context.temp_allocator)
	if os.write_entire_file_from_string(path, content, {.Read_User, .Write_User}) != nil {
		testing.fail_now(t, "cannot write the test's file")
	}
	return path
}

Behavior :: struct {
	// What the bus answers the login with; "" is a plain OK.
	auth_reply:   string,
	// The login keyring's state before the unlock.
	locked:       bool,
	// After an unlock the daemon accepted, the keyring is still locked.
	stays_locked: bool,
	// There is no login keyring: Get answers UnknownObject.
	no_keyring:   bool,
	// Nobody owns org.freedesktop.secrets and nothing can be started.
	no_service:   bool,
	// The keyring's password; another one is Denied.
	password:     string,
	// An error the unlock answers with, whatever the password.
	unlock_error: string,
	// The replies are big-endian.
	big_endian:   bool,
	// A signal and a reply to another call come before every reply.
	noise:        bool,
	// The call that gets no answer, and the call at which the bus hangs up.
	hang_on:      string,
	close_on:     string,
	// The type of the variant Get answers with; "" is "b".
	locked_type:  string,
	// Get is answered with a header that announces 64 MiB.
	huge:         bool,
}

Fake :: struct {
	behavior:    Behavior,
	arena:       virtual.Arena,
	a:           runtime.Allocator,
	dir:         string,
	socket:      string,
	address:     string,
	listen_fd:   linux.Fd,
	stop:        bool,
	worker:      ^thread.Thread,
	// What came in, for the test to check after fake_stop.
	connections: int,
	auth:        string,
	calls:       [dynamic]string,
	no_auto:     bool,
	destination: [dynamic]string,
	algorithm:   string,
	collection:  string,
	session:     string,
	content:     string,
	passwords:   [dynamic]string,
}

SESSION_PATH :: "/org/freedesktop/secrets/session/s7"

fake_start :: proc(t: ^testing.T, b: Behavior) -> ^Fake {
	f := new(Fake)
	if virtual.arena_init_growing(&f.arena) != nil {
		testing.fail_now(t, "no memory for the fake bus")
	}
	f.a = virtual.arena_allocator(&f.arena)
	f.behavior = b
	f.calls = make([dynamic]string, f.a)
	f.destination = make([dynamic]string, f.a)
	f.passwords = make([dynamic]string, f.a)
	f.dir = strings.clone(scratch(t), f.a)
	f.socket = strings.concatenate({f.dir, "/bus"}, f.a)
	f.address = strings.concatenate({"unix:path=", f.socket, ",guid=00112233445566778899aabbccddeeff"}, f.a)
	if len(f.socket) > kr.MAX_SOCKET_PATH {
		os.remove_all(f.dir)
		testing.fail_now(t, "TMPDIR is too long for the test's socket path; set a shorter one")
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], f.socket)
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE || linux.bind(fd, &addr) != .NONE || linux.listen(fd, 4) != .NONE {
		os.remove_all(f.dir)
		testing.fail_now(t, "cannot listen on the fake bus's socket")
	}
	f.listen_fd = fd
	f.worker = thread.create_and_start_with_poly_data(f, fake_serve, context)
	return f
}

// fake_stop waits for the bus to finish its connection (or gives up on one
// that never comes) and frees it, after the test has read what it recorded.
fake_stop :: proc(f: ^Fake) {
	sync.atomic_store(&f.stop, true)
	thread.join(f.worker)
	thread.destroy(f.worker)
	linux.close(f.listen_fd)
	os.remove_all(f.dir)
}

fake_free :: proc(f: ^Fake) {
	virtual.arena_destroy(&f.arena)
	free(f)
}

fake_serve :: proc(f: ^Fake) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	conn_fd: linux.Fd = -1
	for !sync.atomic_load(&f.stop) {
		fds := []linux.Poll_Fd{{fd = f.listen_fd, events = {.IN}}}
		n, _ := linux.poll(fds, 20)
		if n > 0 {
			addr: linux.Sock_Addr_Un
			c, e := linux.accept(f.listen_fd, &addr, {.CLOEXEC})
			if e == .NONE {
				conn_fd = c
				break
			}
		}
	}
	if conn_fd < 0 {
		return
	}
	f.connections += 1
	c: kr.Conn
	kr.conn_init(&c, conn_fd, 5 * time.Second)
	defer kr.conn_close(&c)
	serve_connection(f, &c)
}

reply_to :: proc(f: ^Fake, c: ^kr.Conn, call: kr.Message, m: kr.Message) {
	out := make([dynamic]u8, f.a)
	if f.behavior.noise {
		sig := make([dynamic]u8, f.a)
		kr.put_string(kr.Writer{buf = &sig, big = f.behavior.big_endian}, ":1.99")
		kr.encode(
			kr.Message {
				type = .Signal,
				serial = 900,
				path = "/org/freedesktop/DBus",
				interface = "org.freedesktop.DBus",
				member = "NameAcquired",
				signature = "s",
				body = sig[:],
				big_endian = f.behavior.big_endian,
			},
			&out,
		)
		kr.encode(
			kr.Message{type = .Method_Return, serial = 901, reply_serial = call.serial + 1000, big_endian = f.behavior.big_endian},
			&out,
		)
	}
	r := m
	r.serial = 1000 + call.serial
	r.reply_serial = call.serial
	r.big_endian = f.behavior.big_endian
	kr.encode(r, &out)
	kr.send_all(c, out[:])
}

error_reply :: proc(f: ^Fake, c: ^kr.Conn, call: kr.Message, name, text: string) {
	body := make([dynamic]u8, f.a)
	kr.put_string(kr.Writer{buf = &body, big = f.behavior.big_endian}, text)
	reply_to(f, c, call, kr.Message{type = .Error, error_name = name, signature = "s", body = body[:]})
}

serve_connection :: proc(f: ^Fake, c: ^kr.Conn) {
	b := &f.behavior
	line, why := kr.read_line(c)
	if why != "" {
		return
	}
	f.auth = strings.clone(line, f.a)
	auth := b.auth_reply if b.auth_reply != "" else "OK 00112233445566778899aabbccddeeff"
	kr.send_all(c, transmute([]u8)strings.concatenate({auth, "\r\n"}, f.a))
	if !strings.has_prefix(auth, "OK") {
		return
	}
	if begin, w := kr.read_line(c); w != "" || begin != "BEGIN" {
		return
	}
	locked := b.locked
	for {
		m, w := kr.read_message(c)
		if w != "" {
			return
		}
		append(&f.calls, strings.clone(m.member, f.a))
		append(&f.destination, strings.clone(m.destination, f.a))
		if m.flags & kr.FLAG_NO_AUTO_START != 0 {
			f.no_auto = true
		}
		if m.member == b.close_on {
			return
		}
		if m.member == b.hang_on {
			continue
		}
		if b.no_service && m.destination == "org.freedesktop.secrets" {
			error_reply(f, c, m, "org.freedesktop.DBus.Error.ServiceUnknown", "The name is not activatable")
			continue
		}
		r := kr.Reader {
			data = m.body,
			big  = m.big_endian,
		}
		body := make([dynamic]u8, f.a)
		w2 := kr.Writer {
			buf = &body,
			big = b.big_endian,
		}
		switch m.member {
		case "Hello":
			kr.put_string(w2, ":1.42")
			reply_to(f, c, m, kr.Message{type = .Method_Return, signature = "s", body = body[:]})
		case "Get":
			if b.huge {
				head := []u8{'l', 2, 0, 1, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 0}
				kr.send_all(c, head)
				continue
			}
			if b.no_keyring || m.path != kr.LOGIN_COLLECTION {
				error_reply(f, c, m, "org.freedesktop.DBus.Error.UnknownObject", "No such object path")
				continue
			}
			iface, prop := kr.get_string(&r), kr.get_string(&r)
			if iface != "org.freedesktop.Secret.Collection" || prop != "Locked" {
				error_reply(f, c, m, "org.freedesktop.DBus.Error.InvalidArgs", "No such property")
				continue
			}
			if b.locked_type == "s" {
				kr.put_signature(w2, "s")
				kr.put_string(w2, "yes")
			} else {
				kr.put_signature(w2, "b")
				kr.put_u32(w2, 1 if locked else 0)
			}
			reply_to(f, c, m, kr.Message{type = .Method_Return, signature = "v", body = body[:]})
		case "OpenSession":
			f.algorithm = strings.clone(kr.get_string(&r), f.a)
			if kr.get_signature(&r) != "s" || r.bad {
				error_reply(f, c, m, "org.freedesktop.DBus.Error.InvalidArgs", "bad input")
				continue
			}
			kr.put_signature(w2, "s")
			kr.put_string(w2, "")
			kr.put_string(w2, SESSION_PATH)
			reply_to(f, c, m, kr.Message{type = .Method_Return, signature = "vo", body = body[:]})
		case "UnlockWithMasterPassword":
			if m.signature != "o(oayays)" {
				error_reply(f, c, m, "org.freedesktop.DBus.Error.InvalidArgs", "bad signature")
				continue
			}
			f.collection = strings.clone(kr.get_string(&r), f.a)
			kr.get_align(&r, 8)
			f.session = strings.clone(kr.get_string(&r), f.a)
			kr.get_bytes(&r)
			pw := kr.get_bytes(&r)
			f.content = strings.clone(kr.get_string(&r), f.a)
			if r.bad {
				error_reply(f, c, m, "org.freedesktop.DBus.Error.InvalidArgs", "bad secret")
				continue
			}
			append(&f.passwords, strings.clone(string(pw), f.a))
			switch {
			case b.unlock_error != "":
				error_reply(f, c, m, b.unlock_error, "it went wrong")
			case string(pw) != b.password || f.session != SESSION_PATH:
				error_reply(f, c, m, "org.gnome.keyring.Error.Denied", "The password was incorrect.")
			case:
				locked = b.stays_locked
				reply_to(f, c, m, kr.Message{type = .Method_Return})
			}
		case:
			error_reply(f, c, m, "org.freedesktop.DBus.Error.UnknownMethod", "No such method")
		}
	}
}
