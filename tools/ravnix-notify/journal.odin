package ravnix_notify

import "core:fmt"
import "core:strings"
import "core:sys/linux"

// Where the journal listens for entries that do not come over a stream.
JOURNAL_SOCKET :: "/run/systemd/journal/socket"

// The longest text of one diagnostic line. What the homeserver or a program
// says is cut to this, so a hostile answer cannot fill the journal.
MAX_LINE :: 400

Level :: enum {
	Error   = 3,
	Warning = 4,
}

// one_line is text on one line and cut short: a control character, which
// could start an escape sequence on a terminal or a line of its own in the
// journal, becomes a blank.
one_line :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, min(len(text), MAX_LINE) + 3, allocator)
	for i := 0; i < len(text); i += 1 {
		if i == MAX_LINE {
			strings.write_string(&b, "...")
			break
		}
		c := text[i]
		strings.write_byte(&b, ' ' if c < 0x20 || c == 0x7f else c)
	}
	return strings.to_string(b)
}

// log_line writes one diagnostic line, and makes sure it is in the journal.
// text is a sentence without the program's name.
//
// Run by a unit, stderr is the journal's stream (env.journal_stream, which
// main sets from stderr_is_journal): "<N>" in front of the line gives it its
// priority, and the line goes nowhere else, so it is there once. Run by hand,
// from a hook, from a terminal, or by a unit's child that has a stderr of its
// own, stderr is not the journal, and the line goes to stderr in plain words
// and to the journal's socket as an entry of its own, which is what
// systemd-cat does without a program to start. A journal that is not there
// loses the entry and nothing else.
log_line :: proc(env: Env, level: Level, text: string) {
	line := one_line(text)
	defer delete(line)
	if env.journal_stream {
		fmt.wprintf(env.err, "<%d>ravnix-notify: %s\n", int(level), line)
		return
	}
	fmt.wprintf(env.err, "ravnix-notify: %s\n", line)
	send_to_journal(env.journal_socket if env.journal_socket != "" else JOURNAL_SOCKET, level, line)
}

send_to_journal :: proc(path: string, level: Level, line: string) {
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		return
	}
	copy(addr.sun_path[:], path)
	fd, errno := linux.socket(.UNIX, .DGRAM, {.CLOEXEC}, {})
	if errno != .NONE {
		return
	}
	defer linux.close(fd)
	entry := fmt.aprintf("MESSAGE=%s\nPRIORITY=%d\nSYSLOG_IDENTIFIER=ravnix-notify\n", line, int(level))
	defer delete(entry)
	// Without waiting: a journal that does not take it is not worth a stall.
	_, _ = linux.sendto(fd, transmute([]byte)entry, {.DONTWAIT, .NOSIGNAL}, &addr)
}

// stderr_is_journal says whether the descriptor fd is the journal's stream,
// the way systemd.exec(5) says to decide it: value, the JOURNAL_STREAM
// variable, is the device and the inode of the stream in decimal, "DEV:INO",
// and the descriptor is that stream when fstat(2) gives the same two numbers.
// A set variable alone is no proof, because a unit hands the variable on to
// the children it starts, whose standard error can be a terminal, a pipe or a
// file of their own. A value that is not two plain decimal numbers around one
// colon, an unset variable (""), and a descriptor that fstat refuses are all
// "no".
stderr_is_journal :: proc(value: string, fd: linux.Fd) -> bool {
	dev, ino, ok := parse_stream_id(value)
	if !ok {
		return false
	}
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE {
		return false
	}
	return u64(st.dev) == dev && u64(st.ino) == ino
}

// parse_stream_id reads "DEV:INO": two numbers of decimal digits, nothing
// else, each of them in 64 bits.
parse_stream_id :: proc(value: string) -> (dev, ino: u64, ok: bool) {
	colon := strings.index_byte(value, ':')
	if colon < 0 {
		return
	}
	dev, ok = parse_decimal(value[:colon])
	if !ok {
		return
	}
	ino, ok = parse_decimal(value[colon + 1:])
	return
}

// parse_decimal is the digits 0 to 9 and nothing else (no sign, no blank, no
// underscore, no prefix) in a u64 that does not wrap.
parse_decimal :: proc(digits: string) -> (n: u64, ok: bool) {
	if len(digits) == 0 {
		return
	}
	for i := 0; i < len(digits); i += 1 {
		c := digits[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := u64(c - '0')
		if n > (max(u64) - d) / 10 {
			return 0, false
		}
		n = n * 10 + d
	}
	return n, true
}
