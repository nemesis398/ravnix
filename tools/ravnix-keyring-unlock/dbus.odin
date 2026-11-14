// The part of D-Bus this tool speaks, on its own: the session bus's Unix
// socket, the EXTERNAL login, and the messages of the wire format (method
// calls out; method returns, errors and signals in). The tool sends five
// calls and reads their replies, so this is the whole client: no
// introspection, no match rules, no file descriptors, no containers but
// the variant and the struct of the Secret Service's secret.
//
// The D-Bus specification, "Message Protocol", is what this follows: a
// 16-byte fixed header, the header fields as an array of (byte, variant),
// padding to 8, and the body; every value aligned to its own size from the
// start of the message, which is also the start of the body's alignment,
// because the body begins at a multiple of 8.
package ravnix_keyring_unlock

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// A Unix socket path has 108 bytes, its terminating NUL included.
MAX_SOCKET_PATH :: 107
// The largest message the tool takes. Its replies are a few hundred bytes;
// the bus allows 128 MiB, and a peer that announces more than this is not
// answering the calls this tool makes.
MAX_MESSAGE :: 1 << 20
// The longest line of the login exchange.
MAX_AUTH_LINE :: 512

Message_Type :: enum u8 {
	Invalid       = 0,
	Method_Call   = 1,
	Method_Return = 2,
	Error         = 3,
	Signal        = 4,
}

// Header flags.
FLAG_NO_REPLY_EXPECTED :: 0x1
FLAG_NO_AUTO_START :: 0x2

// The codes of the header fields.
FIELD_PATH :: 1
FIELD_INTERFACE :: 2
FIELD_MEMBER :: 3
FIELD_ERROR_NAME :: 4
FIELD_REPLY_SERIAL :: 5
FIELD_DESTINATION :: 6
FIELD_SENDER :: 7
FIELD_SIGNATURE :: 8
FIELD_UNIX_FDS :: 9

// Message is one message, either way. The strings and the body point into
// the buffer the message was decoded from, or into the caller's for one to
// encode.
Message :: struct {
	type:         Message_Type,
	flags:        u8,
	serial:       u32,
	reply_serial: u32,
	path:         string,
	interface:    string,
	member:       string,
	error_name:   string,
	destination:  string,
	sender:       string,
	signature:    string,
	body:         []u8,
	big_endian:   bool,
}

// ── writing ──────────────────────────────────────────────────────────────────

// Writer appends values to buf, aligned from base, where the message (or
// the body) starts in buf. big writes big-endian, which only the tests'
// stand-in for a bus does.
Writer :: struct {
	buf:  ^[dynamic]u8,
	big:  bool,
	base: int,
}

put_align :: proc(w: Writer, n: int) {
	for (len(w.buf) - w.base) % n != 0 {
		append(w.buf, 0)
	}
}

put_u8 :: proc(w: Writer, v: u8) {
	append(w.buf, v)
}

put_u32 :: proc(w: Writer, v: u32) {
	put_align(w, 4)
	b := transmute([4]u8)v
	if w.big {
		append(w.buf, b[3], b[2], b[1], b[0])
	} else {
		append(w.buf, b[0], b[1], b[2], b[3])
	}
}

// put_string writes a string or an object path: its length, its bytes and
// a NUL.
put_string :: proc(w: Writer, s: string) {
	put_u32(w, u32(len(s)))
	append(w.buf, s)
	append(w.buf, 0)
}

put_signature :: proc(w: Writer, s: string) {
	put_u8(w, u8(len(s)))
	append(w.buf, s)
	append(w.buf, 0)
}

// put_bytes writes an array of bytes (ay): its length and the bytes, which
// need no alignment of their own.
put_bytes :: proc(w: Writer, b: []u8) {
	put_u32(w, u32(len(b)))
	append(w.buf, ..b)
}

put_field :: proc(w: Writer, code: u8, sig: string, value: string) {
	put_align(w, 8)
	put_u8(w, code)
	put_signature(w, sig)
	if sig == "g" {
		put_signature(w, value)
	} else {
		put_string(w, value)
	}
}

put_field_u32 :: proc(w: Writer, code: u8, value: u32) {
	put_align(w, 8)
	put_u8(w, code)
	put_signature(w, "u")
	put_u32(w, value)
}

// encode appends m to out, the header and the body, in m's byte order.
encode :: proc(m: Message, out: ^[dynamic]u8) {
	start := len(out)
	w := Writer {
		buf  = out,
		big  = m.big_endian,
		base = start,
	}
	put_u8(w, 'B' if m.big_endian else 'l')
	put_u8(w, u8(m.type))
	put_u8(w, m.flags)
	put_u8(w, 1)
	put_u32(w, u32(len(m.body)))
	put_u32(w, m.serial)
	fields_at := len(out)
	put_u32(w, 0)
	// The array of header fields holds structs, which start at 8.
	put_align(w, 8)
	first := len(out)
	if m.path != "" {
		put_field(w, FIELD_PATH, "o", m.path)
	}
	if m.interface != "" {
		put_field(w, FIELD_INTERFACE, "s", m.interface)
	}
	if m.member != "" {
		put_field(w, FIELD_MEMBER, "s", m.member)
	}
	if m.error_name != "" {
		put_field(w, FIELD_ERROR_NAME, "s", m.error_name)
	}
	if m.type == .Method_Return || m.type == .Error {
		put_field_u32(w, FIELD_REPLY_SERIAL, m.reply_serial)
	}
	if m.destination != "" {
		put_field(w, FIELD_DESTINATION, "s", m.destination)
	}
	if m.sender != "" {
		put_field(w, FIELD_SENDER, "s", m.sender)
	}
	if m.signature != "" {
		put_field(w, FIELD_SIGNATURE, "g", m.signature)
	}
	n := u32(len(out) - first)
	b := transmute([4]u8)n
	if m.big_endian {
		b = {b[3], b[2], b[1], b[0]}
	}
	copy(out[fields_at:fields_at + 4], b[:])
	// The header ends at a multiple of 8, counted from the message's start.
	for (len(out) - start) % 8 != 0 {
		append(out, 0)
	}
	append(out, ..m.body)
}

// ── reading ──────────────────────────────────────────────────────────────────

// Reader reads values from data, aligned from the start of data. bad is set
// by the first read that runs past the end or finds a value the format
// does not allow, and every read after it returns nothing.
Reader :: struct {
	data: []u8,
	pos:  int,
	big:  bool,
	bad:  bool,
}

get_align :: proc(r: ^Reader, n: int) {
	if r.bad {
		return
	}
	next := (r.pos + n - 1) / n * n
	if next > len(r.data) {
		r.bad = true
		return
	}
	r.pos = next
}

get_u8 :: proc(r: ^Reader) -> u8 {
	if r.bad || r.pos + 1 > len(r.data) {
		r.bad = true
		return 0
	}
	r.pos += 1
	return r.data[r.pos - 1]
}

get_u16 :: proc(r: ^Reader) -> u16 {
	get_align(r, 2)
	if r.bad || r.pos + 2 > len(r.data) {
		r.bad = true
		return 0
	}
	d := r.data[r.pos:r.pos + 2]
	r.pos += 2
	return u16(d[0]) << 8 | u16(d[1]) if r.big else u16(d[1]) << 8 | u16(d[0])
}

get_u32 :: proc(r: ^Reader) -> u32 {
	get_align(r, 4)
	if r.bad || r.pos + 4 > len(r.data) {
		r.bad = true
		return 0
	}
	d := r.data[r.pos:r.pos + 4]
	r.pos += 4
	if r.big {
		return u32(d[0]) << 24 | u32(d[1]) << 16 | u32(d[2]) << 8 | u32(d[3])
	}
	return u32(d[3]) << 24 | u32(d[2]) << 16 | u32(d[1]) << 8 | u32(d[0])
}

get_bool :: proc(r: ^Reader) -> bool {
	v := get_u32(r)
	if v > 1 {
		r.bad = true
		return false
	}
	return v == 1
}

// get_string reads a string or an object path. It points into the data.
get_string :: proc(r: ^Reader) -> string {
	n := int(get_u32(r))
	if r.bad || n > len(r.data) - r.pos - 1 || r.data[r.pos + n] != 0 {
		r.bad = true
		return ""
	}
	s := string(r.data[r.pos:r.pos + n])
	r.pos += n + 1
	return s
}

get_signature :: proc(r: ^Reader) -> string {
	n := int(get_u8(r))
	if r.bad || n > len(r.data) - r.pos - 1 || r.data[r.pos + n] != 0 {
		r.bad = true
		return ""
	}
	s := string(r.data[r.pos:r.pos + n])
	r.pos += n + 1
	return s
}

get_bytes :: proc(r: ^Reader) -> []u8 {
	n := int(get_u32(r))
	if r.bad || n > len(r.data) - r.pos {
		r.bad = true
		return nil
	}
	b := r.data[r.pos:r.pos + n]
	r.pos += n
	return b
}

// skip_basic steps over one value of a basic type, the only kind a header
// field holds. Anything else is malformed here.
skip_basic :: proc(r: ^Reader, sig: string) {
	if len(sig) != 1 {
		r.bad = true
		return
	}
	switch sig[0] {
	case 'y':
		get_u8(r)
	case 'n', 'q':
		get_u16(r)
	case 'b':
		get_bool(r)
	case 'i', 'u', 'h':
		get_u32(r)
	case 'x', 't', 'd':
		get_align(r, 8)
		get_u32(r)
		get_u32(r)
	case 's', 'o':
		get_string(r)
	case 'g':
		get_signature(r)
	case:
		r.bad = true
	}
}

// message_size is the size of the whole message whose first 16 bytes are
// head, or why those bytes cannot start one.
message_size :: proc(head: []u8) -> (size: int, why: string) {
	if len(head) < 16 {
		return 0, "a message shorter than its header"
	}
	r := Reader {
		data = head[:16],
	}
	switch head[0] {
	case 'l':
	case 'B':
		r.big = true
	case:
		return 0, fmt.tprintf("a message in no byte order (0x%02x)", head[0])
	}
	if head[3] != 1 {
		return 0, fmt.tprintf("a message of protocol version %d, not 1", head[3])
	}
	r.pos = 4
	body := int(get_u32(&r))
	get_u32(&r)
	fields := int(get_u32(&r))
	if body > MAX_MESSAGE || fields > MAX_MESSAGE {
		return 0, fmt.tprintf("a message larger than %d bytes", MAX_MESSAGE)
	}
	size = (16 + fields + 7) / 8 * 8 + body
	if size > MAX_MESSAGE {
		return 0, fmt.tprintf("a message larger than %d bytes", MAX_MESSAGE)
	}
	return size, ""
}

// decode reads the message that data holds, all of it. The message points
// into data.
decode :: proc(data: []u8) -> (m: Message, why: string) {
	size, mwhy := message_size(data)
	if mwhy != "" {
		return {}, mwhy
	}
	if size != len(data) {
		return {}, "a message whose length does not match its header"
	}
	r := Reader {
		data = data,
		big  = data[0] == 'B',
	}
	m.big_endian = r.big
	r.pos = 1
	m.type = Message_Type(get_u8(&r))
	m.flags = get_u8(&r)
	get_u8(&r)
	body := int(get_u32(&r))
	m.serial = get_u32(&r)
	fields := int(get_u32(&r))
	if m.serial == 0 {
		return {}, "a message with serial 0"
	}
	// The fields are read from a reader that ends with them, so a field
	// that runs past them is malformed, not the start of the body.
	fr := Reader {
		data = data[:16 + fields],
		pos  = 16,
		big  = r.big,
	}
	for !fr.bad && fr.pos < len(fr.data) {
		get_align(&fr, 8)
		if fr.bad || fr.pos >= len(fr.data) {
			break
		}
		code := get_u8(&fr)
		sig := get_signature(&fr)
		switch {
		case code == FIELD_REPLY_SERIAL && sig == "u":
			m.reply_serial = get_u32(&fr)
		case code == FIELD_ERROR_NAME && sig == "s":
			m.error_name = get_string(&fr)
		case code == FIELD_PATH && sig == "o":
			m.path = get_string(&fr)
		case code == FIELD_INTERFACE && sig == "s":
			m.interface = get_string(&fr)
		case code == FIELD_MEMBER && sig == "s":
			m.member = get_string(&fr)
		case code == FIELD_DESTINATION && sig == "s":
			m.destination = get_string(&fr)
		case code == FIELD_SENDER && sig == "s":
			m.sender = get_string(&fr)
		case code == FIELD_SIGNATURE && sig == "g":
			m.signature = get_signature(&fr)
		case code >= FIELD_PATH && code <= FIELD_UNIX_FDS && code != FIELD_UNIX_FDS:
			// A known field with the wrong type.
			fr.bad = true
		case:
			skip_basic(&fr, sig)
		}
	}
	if fr.bad {
		return {}, "a message with malformed header fields"
	}
	m.body = data[len(data) - body:]
	#partial switch m.type {
	case .Method_Return:
		if m.reply_serial == 0 {
			return {}, "a reply without the serial of its call"
		}
	case .Error:
		if m.reply_serial == 0 || m.error_name == "" {
			return {}, "an error without the serial of its call or its name"
		}
	case .Method_Call, .Signal:
	case:
		return {}, fmt.tprintf("a message of unknown type %d", u8(m.type))
	}
	if len(m.body) > 0 && m.signature == "" {
		return {}, "a message with a body and no signature"
	}
	return m, ""
}

// error_text is the error's name and, when its body starts with one, its
// message, for a log line.
error_text :: proc(m: Message) -> string {
	if len(m.signature) > 0 && m.signature[0] == 's' {
		r := Reader {
			data = m.body,
			big  = m.big_endian,
		}
		text := get_string(&r)
		if !r.bad && text != "" {
			return fmt.tprintf("%s: %s", m.error_name, printable(text))
		}
	}
	return m.error_name
}

// printable keeps a peer's text on one line of the journal.
printable :: proc(s: string) -> string {
	if len(s) > 200 {
		return printable(s[:200])
	}
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if c < 0x20 || c == 0x7f {
			strings.write_byte(&b, '?')
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// ── the address ──────────────────────────────────────────────────────────────

// socket_path is the path of the first unix:path= entry of a D-Bus server
// address, which is how a user manager names the session bus
// (unix:path=/run/user/UID/bus), or why there is none.
socket_path :: proc(address: string, allocator := context.allocator) -> (path: string, why: string) {
	if address == "" {
		return "", "no session bus: DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR are not set"
	}
	other := ""
	rest := address
	for entry in strings.split_iterator(&rest, ";") {
		colon := strings.index_byte(entry, ':')
		if colon < 0 {
			return "", fmt.tprintf("the bus address %q has an entry without a transport", printable(address))
		}
		if entry[:colon] != "unix" {
			other = entry[:colon]
			continue
		}
		keys := entry[colon + 1:]
		for pair in strings.split_iterator(&keys, ",") {
			eq := strings.index_byte(pair, '=')
			if eq < 0 {
				return "", fmt.tprintf("the bus address %q has a key without a value", printable(address))
			}
			key, value := pair[:eq], pair[eq + 1:]
			switch key {
			case "path":
				p, ok := unescape(value, allocator)
				if !ok {
					return "", fmt.tprintf("the bus address %q has a bad %%-escape", printable(address))
				}
				if p == "" {
					return "", fmt.tprintf("the bus address %q has an empty path", printable(address))
				}
				if len(p) > MAX_SOCKET_PATH {
					return "", fmt.tprintf("the bus socket %s is longer than a Unix socket path can be (%d bytes)", printable(p), MAX_SOCKET_PATH)
				}
				return p, ""
			case "abstract":
				other = "unix:abstract"
			}
		}
	}
	if other != "" {
		return "", fmt.tprintf("the bus address %q names no unix:path= socket (%s is not supported)", printable(address), other)
	}
	return "", fmt.tprintf("the bus address %q names no unix:path= socket", printable(address))
}

// unescape undoes the %XX escapes of an address value.
unescape :: proc(s: string, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] != '%' {
			strings.write_byte(&b, s[i])
			continue
		}
		if i + 2 >= len(s) {
			strings.builder_destroy(&b)
			return "", false
		}
		v, ok := strconv.parse_uint(s[i + 1:i + 3], 16)
		if !ok {
			strings.builder_destroy(&b)
			return "", false
		}
		strings.write_byte(&b, u8(v))
		i += 2
	}
	return strings.to_string(b), true
}

// default_address is the session bus's address: the environment's, or the
// user manager's socket in the runtime directory, as sd-bus and GDBus find
// it when the variable is not set.
default_address :: proc(env_address, runtime_dir: string, allocator := context.allocator) -> string {
	if env_address != "" {
		return env_address
	}
	if runtime_dir == "" {
		return ""
	}
	return fmt.aprintf("unix:path=%s/bus", runtime_dir, allocator = allocator)
}

// ── the connection ───────────────────────────────────────────────────────────

// Conn is a connection to the bus. Everything it reads waits until deadline
// at the latest.
Conn :: struct {
	fd:       linux.Fd,
	serial:   u32,
	deadline: time.Tick,
	timeout:  time.Duration,
	// What came in and is not read yet.
	pending:  [dynamic]u8,
	// The message the last read_message returned; its strings point here.
	current:  [dynamic]u8,
}

conn_init :: proc(c: ^Conn, fd: linux.Fd, timeout: time.Duration) {
	c.fd = fd
	c.timeout = timeout
	c.deadline = time.tick_add(time.tick_now(), timeout)
}

conn_close :: proc(c: ^Conn) {
	if c.fd >= 0 {
		linux.close(c.fd)
	}
	c.fd = -1
	wipe(c.pending[:])
	wipe(c.current[:])
	delete(c.pending)
	delete(c.current)
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
	case .EISDIR:
		return "is a directory"
	}
	return fmt.tprintf("errno %d", int(e))
}

// dial connects to the Unix socket at path.
dial :: proc(path: string) -> (fd: linux.Fd, why: string) {
	if len(path) > MAX_SOCKET_PATH {
		return -1, fmt.tprintf("the bus socket %s is longer than a Unix socket path can be", printable(path))
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
		return -1, fmt.tprintf("cannot connect to the session bus at %s: %s", printable(path), errno_text(e))
	}
	return s, ""
}

left_ms :: proc(c: ^Conn) -> i32 {
	d := time.tick_diff(time.tick_now(), c.deadline)
	if d <= 0 {
		return 0
	}
	ms := time.duration_milliseconds(d)
	return i32(ms) + 1
}

timed_out :: proc(c: ^Conn) -> string {
	return fmt.tprintf("the bus did not answer within %v", c.timeout)
}

// send_all writes data, before the deadline.
send_all :: proc(c: ^Conn, data: []u8) -> string {
	rest := data
	for len(rest) > 0 {
		fds := []linux.Poll_Fd{{fd = c.fd, events = {.OUT}}}
		n, e := linux.poll(fds, left_ms(c))
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return fmt.tprintf("cannot wait for the bus: %s", errno_text(e))
		}
		if n == 0 {
			return timed_out(c)
		}
		sent, se := linux.send(c.fd, rest, {.NOSIGNAL, .DONTWAIT})
		#partial switch se {
		case .NONE:
			rest = rest[sent:]
		case .EINTR, .EAGAIN:
		case:
			return fmt.tprintf("the bus connection broke (%s)", errno_text(se))
		}
	}
	return ""
}

// fill reads what the socket has into pending, waiting until the deadline.
fill :: proc(c: ^Conn) -> string {
	for {
		fds := []linux.Poll_Fd{{fd = c.fd, events = {.IN}}}
		n, e := linux.poll(fds, left_ms(c))
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return fmt.tprintf("cannot wait for the bus: %s", errno_text(e))
		}
		if n == 0 {
			return timed_out(c)
		}
		buf: [4096]u8
		got, re := linux.recv(c.fd, buf[:], {.DONTWAIT})
		#partial switch re {
		case .NONE:
			if got == 0 {
				return "the bus closed the connection"
			}
			append(&c.pending, ..buf[:got])
			wipe(buf[:got])
			return ""
		case .EINTR, .EAGAIN:
		case:
			return fmt.tprintf("the bus connection broke (%s)", errno_text(re))
		}
	}
}

// take moves the first n pending bytes into current.
take :: proc(c: ^Conn, n: int) {
	wipe(c.current[:])
	clear(&c.current)
	append(&c.current, ..c.pending[:n])
	copy(c.pending[:], c.pending[n:])
	wipe(c.pending[len(c.pending) - n:])
	resize(&c.pending, len(c.pending) - n)
}

// read_line reads one line of the login exchange, without its CR LF. It
// points into the connection and is valid until the next read.
read_line :: proc(c: ^Conn) -> (line: string, why: string) {
	for {
		for i in 1 ..< len(c.pending) {
			if c.pending[i - 1] == '\r' && c.pending[i] == '\n' {
				take(c, i + 1)
				return string(c.current[:i - 1]), ""
			}
		}
		if len(c.pending) > MAX_AUTH_LINE {
			return "", "the bus sent a login line that does not end"
		}
		if w := fill(c); w != "" {
			return "", w
		}
	}
}

// read_message reads the next message. It points into the connection and is
// valid until the next read.
read_message :: proc(c: ^Conn) -> (m: Message, why: string) {
	for len(c.pending) < 16 {
		if w := fill(c); w != "" {
			return {}, w
		}
	}
	size, swhy := message_size(c.pending[:16])
	if swhy != "" {
		return {}, fmt.tprintf("the bus sent %s", swhy)
	}
	for len(c.pending) < size {
		if w := fill(c); w != "" {
			return {}, w
		}
	}
	take(c, size)
	msg, dwhy := decode(c.current[:])
	if dwhy != "" {
		return {}, fmt.tprintf("the bus sent %s", dwhy)
	}
	return msg, ""
}

// authenticate logs in with EXTERNAL as uid, the way every client on a
// local bus does: the bus checks the uid against the socket's peer.
authenticate :: proc(c: ^Conn, uid: u32) -> string {
	hex := strings.builder_make(context.temp_allocator)
	for d in fmt.tprintf("%d", uid) {
		fmt.sbprintf(&hex, "%02x", u8(d))
	}
	hello := fmt.tprintf("\x00AUTH EXTERNAL %s\r\n", strings.to_string(hex))
	if w := send_all(c, transmute([]u8)hello); w != "" {
		return w
	}
	line, why := read_line(c)
	if why != "" {
		return why
	}
	if !strings.has_prefix(line, "OK ") {
		return fmt.tprintf("the bus refused the login: %s", printable(line))
	}
	return send_all(c, transmute([]u8)string("BEGIN\r\n"))
}

// call sends a method call and returns its reply, a method return or an
// error, skipping every other message that comes in before it. The body is
// wiped from the buffer it was sent from.
call :: proc(c: ^Conn, destination, path, interface, member, signature: string, body: []u8) -> (reply: Message, why: string) {
	c.serial += 1
	out := make([dynamic]u8, 0, 256 + len(body))
	defer delete(out)
	encode(
		Message {
			type = .Method_Call,
			serial = c.serial,
			destination = destination,
			path = path,
			interface = interface,
			member = member,
			signature = signature,
			body = body,
		},
		&out,
	)
	sent := send_all(c, out[:])
	wipe(out[:])
	if sent != "" {
		return {}, sent
	}
	for {
		m, w := read_message(c)
		if w != "" {
			return {}, w
		}
		if (m.type == .Method_Return || m.type == .Error) && m.reply_serial == c.serial {
			return m, ""
		}
	}
}

// wipe overwrites b with zeros, in a way the compiler keeps.
wipe :: proc(b: []u8) {
	if len(b) > 0 {
		mem.zero_explicit(raw_data(b), len(b))
	}
}
