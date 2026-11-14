// The adapters of ravnix-dict: Handy, LanguageTool and the prose skill's
// dictionary (../README.md, "Adapters"). Each is a package-level setup that
// main fills from the environment, and three procedures the core calls:
// read, write and unavailable. The setup is thread-local, so the tests,
// which the runner runs in parallel, each set up their own.
//
// This file holds what the three share: running a program with a time
// limit; reading and replacing a file is ../disk, which the core shares.
package adapters

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "../disk"

Error :: Maybe(string)

cstr :: disk.cstr
errno_text :: disk.errno_text

// Ran is what a program did: its exit status, and what it printed,
// standard output and standard error in one stream.
Ran :: struct {
	status: int,
	output: string,
}

// MAX_OUTPUT is the most a program may print; a word list is far less.
MAX_OUTPUT :: 64 * 1024 * 1024

// run_program runs command with input on its standard input and returns
// what it printed. A program that has not finished after timeout is killed;
// why then says so, as it does when the program cannot be started. The
// input goes through a pipe, never a file or the command line, so a
// secret in it is in no file and in no process list.
run_program :: proc(command: []string, input: string, timeout: time.Duration, allocator: runtime.Allocator) -> (ran: Ran, why: string) {
	out_r, out_w, perr := os.pipe()
	if perr != nil {
		return ran, fmt.tprintf("cannot run %s: no pipe", command[0])
	}
	defer os.close(out_r)
	in_r, in_w: ^os.File
	if input != "" {
		in_r, in_w, perr = os.pipe()
		if perr != nil {
			os.close(out_w)
			return ran, fmt.tprintf("cannot run %s: no pipe", command[0])
		}
	}
	p, serr := os.process_start({command = command, stdin = in_r, stdout = out_w, stderr = out_w})
	os.close(out_w)
	if in_r != nil {
		os.close(in_r)
	}
	if serr != nil {
		if in_w != nil {
			os.close(in_w)
		}
		if serr == .Not_Exist {
			return ran, fmt.tprintf("cannot run %s: it is not installed", command[0])
		}
		return ran, fmt.tprintf("cannot run %s: %v", command[0], serr)
	}
	if in_w != nil {
		// The input is small (a curl configuration), far less than a pipe
		// holds, so writing it all before reading cannot block.
		_, _ = os.write(in_w, transmute([]u8)input)
		os.close(in_w)
	}

	deadline := time.tick_now()
	buf := make([dynamic]u8, 0, 4096, allocator)
	chunk: [16 * 1024]u8
	fd := linux.Fd(os.fd(out_r))
	timed_out := false
	for {
		left := timeout - time.tick_since(deadline)
		if left <= 0 {
			timed_out = true
			break
		}
		fds := []linux.Poll_Fd{{fd = fd, events = {.IN, .HUP}}}
		n, pe := linux.poll(fds, i32(max(left / time.Millisecond, 1)))
		if pe == .EINTR {
			continue
		}
		if pe != .NONE {
			break
		}
		if n == 0 {
			continue
		}
		got, re := linux.read(fd, chunk[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE || got == 0 {
			break
		}
		if len(buf) + got <= MAX_OUTPUT {
			append(&buf, ..chunk[:got])
		}
	}
	if timed_out {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return ran, fmt.tprintf("%s did not answer within %v and was stopped", command[0], timeout)
	}
	state, werr := os.process_wait(p)
	if werr != nil {
		return ran, fmt.tprintf("cannot wait for %s: %v", command[0], werr)
	}
	// A program ended by a signal gets the number of the signal (Odin's
	// process_wait does not tell the two apart); either is a failure.
	ran.status = state.exit_code
	ran.output = string(buf[:])
	return ran, ""
}

// read_text reads a whole file of at most limit bytes. missing reports a
// file that does not exist, which is no error to the caller that asks.
read_text :: proc(path: string, limit: int, allocator: runtime.Allocator) -> (text: string, missing: bool, why: string) {
	data, too_big, e := disk.read_path(path, limit, allocator)
	switch {
	case e == .ENOENT:
		return "", true, ""
	case e != .NONE:
		return "", false, fmt.tprintf("cannot read %s: %s", path, errno_text(e))
	case too_big:
		return "", false, fmt.tprintf("%s is bigger than %d MiB, more than a list of words", path, limit / (1024 * 1024))
	}
	return data, false, ""
}

// replace writes data to path through a new file next to it and a rename
// (disk.replace_file), making its directory when it is missing.
replace :: proc(path: string, data: string, mode: u32) -> (why: string) {
	_, why = disk.replace_file(path, data, nil, mode, make_dir = true)
	return
}

// lower is the key of a word, as the core folds it: rune by rune to lower
// case, so the adapters tell words apart as the dictionary does.
lower :: proc(word: string) -> string {
	return strings.to_lower(word, context.temp_allocator)
}
