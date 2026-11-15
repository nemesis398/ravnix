package check_style

import "core:bytes"
import "core:unicode/utf8"
import "core:sys/linux"

// A file read line by line in blocks, so that a file of any size needs the
// memory of its longest line, and no more.

READ_BLOCK :: 64 * 1024

// A line longer than this is refused instead of read: the check would
// otherwise take all the memory of the machine for one.
LINE_LIMIT :: 256 * 1024 * 1024

Reader :: struct {
	fd:      linux.Fd,
	buf:     [dynamic]u8,
	start:   int,
	end:     int,
	// How much of the pending text has been searched for a line end.
	scanned: int,
	eof:     bool,
	// The longest line the reader takes; 0 is LINE_LIMIT.
	limit:   int,
	// Set until the start of the file has been looked at for a byte order mark.
	fresh:   bool,
}

Read_Error :: enum {
	None,
	Failed,
	Line_Too_Long,
}

reader_open :: proc(path: string, limit := 0) -> (r: Reader, errno: linux.Errno) {
	fd, e := linux.open(clone_c(path), {.CLOEXEC, .NOCTTY})
	if e != .NONE {
		return {}, e
	}
	return Reader{fd = fd, limit = limit if limit > 0 else LINE_LIMIT, fresh = true}, .NONE
}

reader_close :: proc(r: ^Reader) {
	linux.close(r.fd)
	delete(r.buf)
}

// reader_next returns the next line without its line end. The text lives
// until the next call. ok is false at the end of the file; a file that does
// not end in a line end gives its last line all the same.
reader_next :: proc(r: ^Reader) -> (line: string, ok: bool, err: Read_Error, errno: linux.Errno) {
	if r.fresh {
		r.fresh = false
		if err, errno = reader_sniff(r); err != .None {
			return "", false, err, errno
		}
	}
	for {
		pending := r.buf[r.start + r.scanned:r.end]
		if i := bytes.index_byte(pending, '\n'); i >= 0 {
			stop := r.start + r.scanned + i
			line = string(r.buf[r.start:stop])
			r.start = stop + 1
			r.scanned = 0
			if len(line) > r.limit {
				return "", false, .Line_Too_Long, .NONE
			}
			return line, true, .None, .NONE
		}
		r.scanned = r.end - r.start
		if r.eof {
			if r.end > r.start {
				line = string(r.buf[r.start:r.end])
				r.start = r.end
				r.scanned = 0
				if len(line) > r.limit {
					return "", false, .Line_Too_Long, .NONE
				}
				return line, true, .None, .NONE
			}
			return "", false, .None, .NONE
		}
		if err, errno = reader_fill(r, true); err != .None {
			return "", false, err, errno
		}
	}
}

// reader_fill reads one block more into the buffer. With check_limit it
// refuses a pending line that is already longer than the limit.
reader_fill :: proc(r: ^Reader, check_limit: bool) -> (err: Read_Error, errno: linux.Errno) {
	if r.start > 0 {
		copy(r.buf[:], r.buf[r.start:r.end])
		r.end -= r.start
		r.start = 0
	}
	if check_limit && r.end > r.limit {
		return .Line_Too_Long, .NONE
	}
	if len(r.buf) - r.end < READ_BLOCK {
		new_len := max(2 * len(r.buf), r.end + READ_BLOCK)
		non_zero_resize(&r.buf, new_len)
	}
	for {
		n, e := linux.read(r.fd, r.buf[r.end:])
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return .Failed, e
		}
		if n == 0 {
			r.eof = true
		} else {
			r.end += n
		}
		return .None, .NONE
	}
}

// reader_sniff does with the start of a file what ripgrep does, since the
// Bash version read every file through it: a UTF-8 byte order mark is dropped,
// and a file that starts with a UTF-16 one is read as UTF-16 and turned into
// UTF-8 (a UTF-16 file is rare, so it is read whole).
reader_sniff :: proc(r: ^Reader) -> (err: Read_Error, errno: linux.Errno) {
	for r.end - r.start < 3 && !r.eof {
		if err, errno = reader_fill(r, false); err != .None {
			return
		}
	}
	head := r.buf[r.start:r.end]
	if len(head) >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF {
		r.start += 3
		return
	}
	if len(head) >= 2 && ((head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF)) {
		little := head[0] == 0xFF
		for !r.eof {
			if r.end > 4 * r.limit {
				return .Line_Too_Long, .NONE
			}
			if err, errno = reader_fill(r, false); err != .None {
				return
			}
		}
		text := utf16_to_utf8(r.buf[r.start + 2:r.end], little)
		delete(r.buf)
		r.buf = text
		r.start = 0
		r.end = len(text)
	}
	return
}

// utf16_to_utf8 turns UTF-16 text without its byte order mark into UTF-8. A
// unit that belongs to no valid pair, and a byte left over, become U+FFFD, as
// in ripgrep.
utf16_to_utf8 :: proc(data: []u8, little: bool) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, len(data) + len(data) / 2 + 4)
	unit :: proc(data: []u8, i: int, little: bool) -> u16 {
		if little {
			return u16(data[i]) | u16(data[i + 1]) << 8
		}
		return u16(data[i]) << 8 | u16(data[i + 1])
	}
	i := 0
	for i + 1 < len(data) {
		u := unit(data, i, little)
		i += 2
		r: rune
		switch {
		case u >= 0xD800 && u < 0xDC00:
			if i + 1 < len(data) {
				if low := unit(data, i, little); low >= 0xDC00 && low < 0xE000 {
					i += 2
					r = rune(0x10000 + (u32(u) - 0xD800) << 10 + (u32(low) - 0xDC00))
					break
				}
			}
			r = utf8.RUNE_ERROR
		case u >= 0xDC00 && u < 0xE000:
			r = utf8.RUNE_ERROR
		case:
			r = rune(u)
		}
		enc, n := utf8.encode_rune(r)
		append(&out, ..enc[:n])
	}
	if i < len(data) {
		enc, n := utf8.encode_rune(utf8.RUNE_ERROR)
		append(&out, ..enc[:n])
	}
	return out
}

clone_c :: proc(s: string) -> cstring {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	return cstring(raw_data(b))
}

// read_whole_file reads a small file (the shared theme) whole.
read_whole_file :: proc(path: string) -> (data: []u8, ok: bool) {
	r, errno := reader_open(path)
	if errno != .NONE {
		return nil, false
	}
	defer reader_close(&r)
	out: [dynamic]u8
	for {
		line, more, err, _ := reader_next(&r)
		if err != .None {
			delete(out)
			return nil, false
		}
		if !more {
			break
		}
		append(&out, line)
		append(&out, '\n')
	}
	return out[:], true
}
