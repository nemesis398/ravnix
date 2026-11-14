// The adapters of ravnix-dict: Handy, LanguageTool and the prose skill's
// dictionary (../README.md, "Adapters"). Each is a package-level setup that
// main fills from the environment, and three procedures the core calls:
// read, write and unavailable. The setup is thread-local, so the tests,
// which the runner runs in parallel, each set up their own.
//
// This file holds what the three share: running a program with a time
// limit, and replacing a file through a rename.
package adapters

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

Error :: Maybe(string)

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

errno_text :: proc(e: linux.Errno) -> string {
	#partial switch e {
	case .ENOENT:
		return "it does not exist"
	case .EACCES, .EPERM:
		return "permission denied"
	case .EISDIR:
		return "it is a directory"
	case .ENOSPC:
		return "the disk is full"
	case .EROFS:
		return "the file system is read-only"
	case .ENOTDIR:
		return "a part of the path is not a directory"
	case .ELOOP:
		return "it is a loop of links"
	}
	return fmt.tprintf("error %d", int(e))
}

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
	fd, e := linux.open(cstr(path), {.CLOEXEC})
	for e == .EINTR {
		fd, e = linux.open(cstr(path), {.CLOEXEC})
	}
	if e == .ENOENT {
		return "", true, ""
	}
	if e != .NONE {
		return "", false, fmt.tprintf("cannot read %s: %s", path, errno_text(e))
	}
	defer linux.close(fd)
	st: linux.Stat
	if se := linux.fstat(fd, &st); se != .NONE {
		return "", false, fmt.tprintf("cannot read %s: %s", path, errno_text(se))
	}
	if linux.S_ISDIR(st.mode) {
		return "", false, fmt.tprintf("cannot read %s: it is a directory", path)
	}
	buf := make([dynamic]u8, 0, int(st.size) + 1, allocator)
	chunk: [64 * 1024]u8
	for {
		n, re := linux.read(fd, chunk[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			return "", false, fmt.tprintf("cannot read %s: %s", path, errno_text(re))
		}
		if n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
		if len(buf) > limit {
			return "", false, fmt.tprintf("%s is bigger than %d MiB, more than a list of words", path, limit / (1024 * 1024))
		}
	}
	return string(buf[:]), false, ""
}

// replace writes data to path through a new file next to it and a rename,
// so a reader sees the old file or the new one. A link is followed, so it
// stays a link; the file keeps its mode, and a new one gets mode. A file
// the user made read-only is not replaced. The directory is made when it
// is missing.
replace :: proc(path: string, data: string, mode: u32) -> (why: string) {
	target := path
	if resolved := posix.realpath(cstr(path)); resolved != nil {
		target = strings.clone(string(resolved), context.temp_allocator)
		posix.free(rawptr(resolved))
	}
	slash := strings.last_index_byte(target, '/')
	dir := target[:max(slash, 1)] if slash >= 0 else "."
	if !os.exists(dir) {
		if err := os.make_directory_all(dir); err != nil {
			return fmt.tprintf("cannot make the directory %s: %v", dir, err)
		}
	}
	perm := mode
	st: linux.Stat
	if linux.stat(cstr(target), &st) == .NONE {
		perm = transmute(u32)st.mode & 0o7777
		if e := linux.access(cstr(target), linux.W_OK); e != .NONE {
			return fmt.tprintf("%s is not writable: %s", target, errno_text(e))
		}
	}
	tmp := fmt.tprintf("%s/.%s.ravnix-dict-new", dir, target[slash + 1:])
	fd, e := linux.open(cstr(tmp), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC, .NOFOLLOW}, transmute(linux.Mode)u32(0o600))
	if e != .NONE {
		return fmt.tprintf("cannot write next to %s: %s", target, errno_text(e))
	}
	rest := transmute([]u8)data
	we := linux.Errno.NONE
	for len(rest) > 0 {
		n, wr := linux.write(fd, rest)
		if wr == .EINTR {
			continue
		}
		if wr != .NONE {
			we = wr
			break
		}
		rest = rest[n:]
	}
	if we == .NONE {
		we = linux.fchmod(fd, transmute(linux.Mode)perm)
	}
	if we == .NONE {
		we = linux.fsync(fd)
	}
	linux.close(fd)
	if we != .NONE {
		linux.unlink(cstr(tmp))
		return fmt.tprintf("cannot write next to %s: %s", target, errno_text(we))
	}
	if re := linux.rename(cstr(tmp), cstr(target)); re != .NONE {
		linux.unlink(cstr(tmp))
		return fmt.tprintf("cannot replace %s: %s", target, errno_text(re))
	}
	if dfd, de := linux.open(cstr(dir), {.DIRECTORY, .CLOEXEC}); de == .NONE {
		linux.fsync(dfd)
		linux.close(dfd)
	}
	return ""
}

// lower is the key of a word, as the core folds it: rune by rune to lower
// case, so the adapters tell words apart as the dictionary does.
lower :: proc(word: string) -> string {
	return strings.to_lower(word, context.temp_allocator)
}
