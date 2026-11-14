// The programs the setup runs: rbw, systemd-ask-password and systemd-creds.
// A password goes to a program on its standard input and comes back on its
// standard output, through pipes, never in its arguments or its environment;
// every buffer that held one is wiped.
package ravnix_keyring_unlock

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The most a pipe takes before its reader runs (the kernel's default pipe
// buffer is 64 KiB). The setup's input is a password, at most MAX_PASSWORD.
MAX_INPUT :: 64 * 1024

// find_program is the first file named name in a directory of path (a PATH
// value) that is a regular file and executable. Only absolute directories
// count: an empty or relative entry means the working directory, and the
// setup never runs a program from wherever it was started. (Odin's
// process_start also tries ./NAME when PATH has no NAME; with an absolute
// path it does not.)
find_program :: proc(name, path: string) -> (found: string, ok: bool) {
	rest := path
	for dir in strings.split_iterator(&rest, ":") {
		if !strings.has_prefix(dir, "/") {
			continue
		}
		full := fmt.tprintf("%s/%s", strings.trim_right(dir, "/"), name)
		st: linux.Stat
		if linux.stat(strings.clone_to_cstring(full, context.temp_allocator), &st) != .NONE {
			continue
		}
		if linux.S_ISREG(st.mode) && linux.access(strings.clone_to_cstring(full, context.temp_allocator), linux.X_OK) == .NONE {
			return full, true
		}
	}
	return "", false
}

Ran :: struct {
	// The exit status, or the number of the signal that ended it.
	status:   int,
	// What it printed on its standard output, at most max_output bytes, in
	// the caller's allocator; the caller wipes and frees it.
	output:   []u8,
	// It printed more than max_output bytes; output is nil then.
	too_long: bool,
	// The buffer output is the start of.
	buffer:   []u8,
}

// run_program runs argv (argv[0] a path) and returns its standard output.
// Its standard input is input when it is not nil, else stdin (nil is
// /dev/null); its standard error is stderr (nil is /dev/null). It is
// stopped after timeout. missing is set when argv[0] cannot be run.
run_program :: proc(
	argv: []string,
	input: []u8,
	stdin: ^os.File,
	stderr: ^os.File,
	timeout: time.Duration,
	max_output: int,
	allocator := context.allocator,
) -> (
	ran: Ran,
	missing: bool,
	why: string,
) {
	if len(argv) == 0 || argv[0] == "" {
		return ran, true, "no program"
	}
	if len(input) > MAX_INPUT {
		return ran, false, fmt.tprintf("cannot give %s more than %d bytes", argv[0], MAX_INPUT)
	}
	out_r, out_w, perr := os.pipe()
	if perr != nil {
		return ran, false, fmt.tprintf("cannot run %s: no pipe", argv[0])
	}
	defer os.close(out_r)
	child_in := stdin
	in_r: ^os.File
	if input != nil {
		in_w: ^os.File
		in_r, in_w, perr = os.pipe()
		if perr != nil {
			os.close(out_w)
			return ran, false, fmt.tprintf("cannot run %s: no pipe", argv[0])
		}
		// The whole input goes into the pipe before the program starts: it
		// fits, and with the read end still open here no write can fail
		// with a broken pipe (and kill this process with SIGPIPE) when the
		// program ends without reading it.
		rest := input
		for len(rest) > 0 {
			n, we := linux.write(linux.Fd(os.fd(in_w)), rest)
			if we == .EINTR {
				continue
			}
			if we != .NONE {
				os.close(in_w)
				os.close(in_r)
				os.close(out_w)
				return ran, false, fmt.tprintf("cannot give %s its input: %s", argv[0], errno_text(we))
			}
			rest = rest[n:]
		}
		os.close(in_w)
		child_in = in_r
	}
	p, serr := os.process_start({command = argv, stdin = child_in, stdout = out_w, stderr = stderr})
	os.close(out_w)
	if in_r != nil {
		os.close(in_r)
	}
	if serr != nil {
		if serr == .Not_Exist {
			return ran, true, fmt.tprintf("cannot run %s: it is not there", argv[0])
		}
		return ran, false, fmt.tprintf("cannot run %s: %v", argv[0], serr)
	}

	buf := make([]u8, max_output, allocator)
	n := 0
	start := time.tick_now()
	fd := linux.Fd(os.fd(out_r))
	timed_out := false
	chunk: [4096]u8
	for {
		left := timeout - time.tick_since(start)
		if left <= 0 {
			timed_out = true
			break
		}
		fds := []linux.Poll_Fd{{fd = fd, events = {.IN}}}
		ready, pe := linux.poll(fds, i32(max(left / time.Millisecond, 1)))
		if pe == .EINTR {
			continue
		}
		if pe != .NONE {
			break
		}
		if ready == 0 {
			continue
		}
		got, re := linux.read(fd, chunk[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE || got == 0 {
			break
		}
		if n + got <= max_output {
			copy(buf[n:], chunk[:got])
			n += got
		} else {
			// Too long: read on to the end, so the program is not stuck on
			// a full pipe, and keep none of it.
			ran.too_long = true
		}
		wipe(chunk[:got])
	}
	if timed_out {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		wipe(buf)
		delete(buf, allocator)
		return {}, false, fmt.tprintf("%s did not finish within %v and was stopped", argv[0], timeout)
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		wipe(buf)
		delete(buf, allocator)
		return {}, false, fmt.tprintf("cannot wait for %s: %v", argv[0], werr)
	}
	ran.status = state.exit_code
	if !state.success && ran.status == 0 {
		ran.status = 1
	}
	if ran.too_long {
		wipe(buf)
		delete(buf, allocator)
		return ran, false, ""
	}
	ran.buffer = buf
	ran.output = buf[:n]
	return ran, false, ""
}

// free_output wipes and frees what run_program returned.
free_output :: proc(r: ^Ran, allocator := context.allocator) {
	if r.buffer != nil {
		wipe(r.buffer)
		delete(r.buffer, allocator)
	}
	r.buffer, r.output = nil, nil
}
