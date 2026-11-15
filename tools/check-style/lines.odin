package check_style

import "core:bytes"
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
	return Reader{fd = fd, limit = limit if limit > 0 else LINE_LIMIT}, .NONE
}

reader_close :: proc(r: ^Reader) {
	linux.close(r.fd)
	delete(r.buf)
}

// reader_next returns the next line without its line end. The text lives
// until the next call. ok is false at the end of the file; a file that does
// not end in a line end gives its last line all the same.
reader_next :: proc(r: ^Reader) -> (line: string, ok: bool, err: Read_Error, errno: linux.Errno) {
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
		if r.start > 0 {
			copy(r.buf[:], r.buf[r.start:r.end])
			r.end -= r.start
			r.start = 0
		}
		if r.end > r.limit {
			return "", false, .Line_Too_Long, .NONE
		}
		if len(r.buf) - r.end < READ_BLOCK {
			new_len := max(2 * len(r.buf), r.end + READ_BLOCK)
			non_zero_resize(&r.buf, new_len)
		}
		n, e := linux.read(r.fd, r.buf[r.end:])
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return "", false, .Failed, e
		}
		if n == 0 {
			r.eof = true
		} else {
			r.end += n
		}
	}
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
