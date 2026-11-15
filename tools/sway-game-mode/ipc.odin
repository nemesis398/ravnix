// The part of Sway's IPC protocol this tool speaks, on its own: the Unix
// socket, and the frames of a request and its reply or of an event. This is
// sway-ipc(7) (i3's protocol): the magic "i3-ipc", the payload's length and
// the message type as two 32-bit integers in the host's byte order, and the
// payload, which is JSON. A reply has the type of its request; an event has
// the high bit of its type set.
package sway_game_mode

import "core:fmt"
import "core:sys/linux"
import "core:time"

MAGIC :: "i3-ipc"
HEADER_SIZE :: 14

// The requests the tool sends.
MSG_RUN_COMMAND :: u32(0)
MSG_SUBSCRIBE :: u32(2)
MSG_GET_TREE :: u32(4)
MSG_GET_BINDING_STATE :: u32(12)

// The events it subscribes to.
EVENT_WORKSPACE :: u32(0x80000000)
EVENT_WINDOW :: u32(0x80000003)

// The longest payload the tool takes. A tree of a thousand windows is a
// couple of megabytes; a peer that announces more is not Sway. The length is
// checked before anything is read, so a bogus one costs no memory.
MAX_PAYLOAD :: 16 << 20
// A Unix socket path has 108 bytes, its terminating NUL included.
MAX_SOCKET_PATH :: 107

Net_Error :: enum u8 {
	None,
	// The stop descriptor became readable: SIGTERM or SIGINT.
	Stopped,
	// The peer hung up, in a frame or between two.
	Closed,
	Timeout,
	Bad_Magic,
	Too_Big,
	// A reply of another type than its request.
	Unexpected,
	Failed,
}

net_error_text :: proc(e: Net_Error) -> string {
	switch e {
	case .None:
		return "no error"
	case .Stopped:
		return "stopped"
	case .Closed:
		return "sway closed the connection"
	case .Timeout:
		return "sway did not answer in time"
	case .Bad_Magic:
		return "sway sent something that is not an IPC frame"
	case .Too_Big:
		return "sway announced a frame larger than the tool takes"
	case .Unexpected:
		return "sway answered with another message than the request"
	case .Failed:
		return "the connection to sway broke"
	}
	return "unknown error"
}

// Conn is one connection to Sway, with what came in and is not used yet.
Conn :: struct {
	fd:      linux.Fd,
	// Becomes readable when the process is asked to stop; -1 for none. A
	// read returns .Stopped then, before it reads anything more.
	stop:    linux.Fd,
	// How long one frame may take to arrive or be written; 0 waits for ever
	// for the first byte of a frame (the event stream) and then gives the
	// rest of it stall.
	timeout: time.Duration,
	stall:   time.Duration,
	pending: [dynamic]u8,
	// The bytes of the frame the last read returned; dropped by the next.
	used:    int,
}

conn_close :: proc(c: ^Conn) {
	if c.fd >= 0 {
		linux.close(c.fd)
	}
	c.fd = -1
	delete(c.pending)
}

errno_text :: proc(e: linux.Errno) -> string {
	#partial switch e {
	case .ENOENT:
		return "no such file or directory"
	case .EACCES:
		return "permission denied"
	case .ECONNREFUSED:
		return "connection refused"
	case .ECONNRESET:
		return "connection reset"
	case .EPIPE:
		return "broken pipe"
	case .ENOTSOCK:
		return "not a socket"
	}
	return fmt.tprintf("errno %d", int(e))
}

// dial connects to the Unix socket at path.
dial :: proc(path: string) -> (fd: linux.Fd, why: string) {
	if len(path) > MAX_SOCKET_PATH {
		return -1, "the socket path is longer than a Unix socket path can be"
	}
	addr: linux.Sock_Addr_Un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	s, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return -1, fmt.tprintf("cannot make a socket: %s", errno_text(e))
	}
	for {
		e = linux.connect(s, &addr)
		if e != .EINTR {
			break
		}
	}
	if e != .NONE {
		linux.close(s)
		return -1, fmt.tprintf("cannot connect to %s: %s", path, errno_text(e))
	}
	return s, ""
}

deadline_of :: proc(c: ^Conn, d: time.Duration) -> (deadline: time.Tick, limited: bool) {
	if d <= 0 {
		return {}, false
	}
	return time.tick_add(time.tick_now(), d), true
}

// wait_ms is the poll timeout for the time left: -1 for none, and at least
// 1 while there is any, so a deadline never spins.
wait_ms :: proc(deadline: time.Tick, limited: bool) -> i32 {
	if !limited {
		return -1
	}
	d := time.tick_diff(time.tick_now(), deadline)
	if d <= 0 {
		return 0
	}
	return i32(time.duration_milliseconds(d)) + 1
}

// fill_to reads until pending holds want bytes.
fill_to :: proc(c: ^Conn, want: int, deadline: time.Tick, limited: bool) -> Net_Error {
	for len(c.pending) < want {
		fds := [2]linux.Poll_Fd{{fd = c.fd, events = {.IN}}, {fd = c.stop, events = {.IN}}}
		n, e := linux.poll(fds[:], wait_ms(deadline, limited))
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return .Failed
		}
		if .IN in fds[1].revents {
			return .Stopped
		}
		if n == 0 {
			return .Timeout
		}
		buf: [32768]u8
		got, re := linux.recv(c.fd, buf[:], {.DONTWAIT})
		#partial switch re {
		case .NONE:
			if got == 0 {
				return .Closed
			}
			append(&c.pending, ..buf[:got])
		case .EINTR, .EAGAIN:
		case:
			return .Failed
		}
	}
	return .None
}

// read_frame reads the next frame. The payload points into the connection
// and is valid until the next read.
read_frame :: proc(c: ^Conn) -> (type: u32, payload: []u8, err: Net_Error) {
	if c.used > 0 {
		remaining := len(c.pending) - c.used
		copy(c.pending[:remaining], c.pending[c.used:])
		resize(&c.pending, remaining)
		c.used = 0
	}
	deadline, limited := deadline_of(c, c.timeout)
	if !limited {
		// Between two events there is nothing to wait for but the next
		// one; a frame that has begun, even one that came in with the
		// previous frame, must go on.
		if len(c.pending) == 0 {
			if err = fill_to(c, 1, deadline, false); err != .None {
				return
			}
		}
		deadline, limited = deadline_of(c, c.stall)
	}
	if err = fill_to(c, HEADER_SIZE, deadline, limited); err != .None {
		return
	}
	if string(c.pending[:len(MAGIC)]) != MAGIC {
		return 0, nil, .Bad_Magic
	}
	length := u32_at(c.pending[:], 6)
	type = u32_at(c.pending[:], 10)
	if length > MAX_PAYLOAD {
		return 0, nil, .Too_Big
	}
	if err = fill_to(c, HEADER_SIZE + int(length), deadline, limited); err != .None {
		return 0, nil, err
	}
	c.used = HEADER_SIZE + int(length)
	return type, c.pending[HEADER_SIZE:c.used], .None
}

u32_at :: proc(b: []u8, at: int) -> u32 {
	return transmute(u32)([4]u8{b[at], b[at + 1], b[at + 2], b[at + 3]})
}

// encode_frame appends a frame to out.
encode_frame :: proc(out: ^[dynamic]u8, type: u32, payload: string) {
	length, t := u32(len(payload)), type
	append(out, MAGIC)
	append(out, ..(cast(^[4]u8)&length)[:])
	append(out, ..(cast(^[4]u8)&t)[:])
	append(out, payload)
}

// send_all writes data, before the connection's timeout.
send_all :: proc(c: ^Conn, data: []u8) -> Net_Error {
	deadline, limited := deadline_of(c, c.timeout)
	rest := data
	for len(rest) > 0 {
		fds := []linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
		n, e := linux.poll(fds, wait_ms(deadline, limited))
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return .Failed
		}
		if n == 0 {
			return .Timeout
		}
		sent, se := linux.send(c.fd, rest, {.NOSIGNAL, .DONTWAIT})
		#partial switch se {
		case .NONE:
			rest = rest[sent:]
		case .EINTR, .EAGAIN:
		case .EPIPE, .ECONNRESET:
			return .Closed
		case:
			return .Failed
		}
	}
	return .None
}

// request sends one message and reads its reply, which has the same type.
// The payload points into the connection, valid until the next read.
request :: proc(c: ^Conn, type: u32, payload: string) -> (reply: []u8, err: Net_Error) {
	out := make([dynamic]u8, 0, HEADER_SIZE + len(payload), context.temp_allocator)
	encode_frame(&out, type, payload)
	if err = send_all(c, out[:]); err != .None {
		return nil, err
	}
	reply_type: u32
	reply_type, reply, err = read_frame(c)
	if err != .None {
		return nil, err
	}
	if reply_type != type {
		return nil, .Unexpected
	}
	return reply, .None
}
