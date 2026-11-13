// What both sides need from Linux: the state files, appended to under a
// lock and read whole; the socket, as a client and as a server; and the
// programs, run with a time limit and their output captured.
package ravnix_link

import "base:runtime"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The longest socket path: sun_path holds 108 bytes, the NUL included.
MAX_SOCKET_PATH :: 107
// The most output of a program that is kept, for its error.
MAX_OUTPUT :: 16 * 1024

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

errno_text :: proc(e: linux.Errno) -> string {
	#partial switch e {
	case .ENOENT:
		return "no such file or directory"
	case .EACCES:
		return "permission denied"
	case .ECONNREFUSED:
		return "connection refused"
	case .ENOSPC:
		return "no space left on the device"
	case .EROFS:
		return "read-only file system"
	case .ENOTDIR:
		return "not a directory"
	case .ELOOP:
		return "a symlink where none may be"
	}
	return fmt.tprintf("%v", e)
}

// ensure_dir makes dir, and its parents, and gives it to the user alone.
ensure_dir :: proc(dir: string) -> string {
	if dir == "" {
		return "no state directory"
	}
	if err := os.make_directory_all(dir, os.perm_number(0o700)); err != nil && err != .Exist {
		return fmt.tprintf("cannot make %s: %s", dir, os.error_string(err))
	}
	if !os.is_directory(dir) {
		return fmt.tprintf("%s is not a directory", dir)
	}
	if e := linux.chmod(cstr(dir), transmute(linux.Mode)u32(0o700)); e != .NONE {
		return fmt.tprintf("cannot make %s the user's alone: %s", dir, errno_text(e))
	}
	return ""
}

// open_state opens a state file: for appending, created for the user
// alone, or for reading. A missing file read is -1 and no error.
open_state :: proc(path: string, write: bool) -> (fd: linux.Fd, why: string) {
	flags: linux.Open_Flags = {.CLOEXEC, .NOFOLLOW}
	if write {
		flags += {.RDWR, .CREAT, .APPEND}
	}
	for {
		e: linux.Errno
		fd, e = linux.open(cstr(path), flags, transmute(linux.Mode)u32(0o600))
		#partial switch e {
		case .NONE:
			return fd, ""
		case .EINTR:
			continue
		case .ENOENT:
			if !write {
				return -1, ""
			}
		}
		return -1, fmt.tprintf("cannot open %s: %s", path, errno_text(e))
	}
}

lock :: proc(fd: linux.Fd, op: linux.FLock_Op) -> linux.Errno {
	for {
		e := linux.flock(fd, op)
		if e != .EINTR {
			return e
		}
	}
}

// lock_within takes an exclusive lock on fd, waiting up to timeout_ms.
lock_within :: proc(fd: linux.Fd, timeout_ms: int) -> bool {
	start := time.tick_now()
	for {
		#partial switch lock(fd, {.EX, .NB}) {
		case .NONE:
			return true
		case .EWOULDBLOCK:
		case:
			return false
		}
		if time.duration_milliseconds(time.tick_since(start)) >= f64(timeout_ms) {
			return false
		}
		time.sleep(20 * time.Millisecond)
	}
}

file_size :: proc(fd: linux.Fd) -> (i64, linux.Errno) {
	st: linux.Stat
	if e := linux.fstat(fd, &st); e != .NONE {
		return 0, e
	}
	return i64(st.size), .NONE
}

// read_fd reads all of fd from its start.
read_fd :: proc(fd: linux.Fd, allocator: runtime.Allocator) -> (data: []u8, why: string) {
	size, e := file_size(fd)
	if e != .NONE {
		return nil, errno_text(e)
	}
	buf := make([dynamic]u8, 0, int(size) + 1, allocator)
	chunk: [64 * 1024]u8
	offset: i64 = 0
	for {
		n, re := linux.pread(fd, chunk[:], offset)
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			return nil, errno_text(re)
		}
		if n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
		offset += i64(n)
	}
	return buf[:], ""
}

// read_state reads a state file whole, under a shared lock, so a writer's
// line is in it whole or not at all. A missing file is empty.
read_state :: proc(path: string, allocator: runtime.Allocator) -> (text: string, why: string) {
	fd, owhy := open_state(path, false)
	if owhy != "" {
		return "", owhy
	}
	if fd < 0 {
		return "", ""
	}
	defer linux.close(fd)
	lock(fd, {.SH})
	defer lock(fd, {.UN})
	data, rwhy := read_fd(fd, allocator)
	if rwhy != "" {
		return "", fmt.tprintf("cannot read %s: %s", path, rwhy)
	}
	return string(data), ""
}

write_all_fd :: proc(fd: linux.Fd, data: []u8) -> linux.Errno {
	rest := data
	for len(rest) > 0 {
		n, e := linux.write(fd, rest)
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return e
		}
		rest = rest[n:]
	}
	return .NONE
}

// file_sum is the SHA-256 of the bytes of the file at path, in lowercase
// hex, or NO_FILE when nothing is there (or a folder on its way is not one).
// A folder, a symlink or anything else that is no regular file is refused:
// the sync carries files, and a commit from the laptop names them.
file_sum :: proc(path: string, allocator := context.allocator) -> (sum: string, why: string, not_a_file: bool) {
	st: linux.Stat
	if e := linux.lstat(cstr(path), &st); e != .NONE {
		if e == .ENOENT || e == .ENOTDIR {
			return NO_FILE, "", false
		}
		return "", fmt.tprintf("cannot look at %s: %s", path, errno_text(e)), false
	}
	if !linux.S_ISREG(st.mode) {
		kind := "a folder" if linux.S_ISDIR(st.mode) else "a symlink" if linux.S_ISLNK(st.mode) else "no file"
		return "", fmt.tprintf("%s is %s, not a file", path, kind), true
	}
	fd, oe := linux.open(cstr(path), {.CLOEXEC, .NOFOLLOW})
	if oe != .NONE {
		return "", fmt.tprintf("cannot read %s: %s", path, errno_text(oe)), false
	}
	defer linux.close(fd)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf: [64 * 1024]u8 = ---
	for {
		n, re := linux.read(fd, buf[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			sha2.reset(&ctx)
			return "", fmt.tprintf("cannot read %s: %s", path, errno_text(re)), false
		}
		if n == 0 {
			break
		}
		sha2.update(&ctx, buf[:n])
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&ctx, digest[:])
	hex := "0123456789abcdef"
	out := make([]u8, 2 * len(digest), allocator)
	for b, i in digest {
		out[2 * i] = hex[b >> 4]
		out[2 * i + 1] = hex[b & 15]
	}
	return string(out), "", false
}

sync_dir :: proc(dir: string) {
	fd, e := linux.open(cstr(dir), {.DIRECTORY, .CLOEXEC})
	if e != .NONE {
		return
	}
	linux.fsync(fd)
	linux.close(fd)
}

// append_line appends line (its newline included) to the file at path as
// one write, under an exclusive lock, and syncs it to the disk before it
// returns. A file whose last line a crash cut short gets a newline first,
// so the new line is a line of its own. limit, when not 0, is the largest
// size the file may grow to.
append_line :: proc(path: string, line: string, limit: i64 = 0) -> string {
	fd, why := open_state(path, true)
	if why != "" {
		return why
	}
	defer linux.close(fd)
	if e := lock(fd, {.EX}); e != .NONE {
		return fmt.tprintf("cannot lock %s: %s", path, errno_text(e))
	}
	defer lock(fd, {.UN})
	size, se := file_size(fd)
	if se != .NONE {
		return fmt.tprintf("cannot read %s: %s", path, errno_text(se))
	}
	if limit > 0 && size + i64(len(line)) > limit {
		return fmt.tprintf(
			"%s holds %d MiB already, and takes at most %d MiB: the laptop has been away long, or something sends without end",
			path,
			size / (1024 * 1024),
			limit / (1024 * 1024),
		)
	}
	data := transmute([]u8)line
	if size > 0 {
		last: [1]u8
		n, _ := linux.pread(fd, last[:], size - 1)
		if n == 1 && last[0] != '\n' {
			fixed := make([]u8, len(line) + 1, context.temp_allocator)
			fixed[0] = '\n'
			copy(fixed[1:], line)
			data = fixed
		}
	}
	if e := write_all_fd(fd, data); e != .NONE {
		return fmt.tprintf("cannot write %s: %s", path, errno_text(e))
	}
	if e := linux.fsync(fd); e != .NONE {
		return fmt.tprintf("cannot sync %s: %s", path, errno_text(e))
	}
	if size == 0 {
		dir := path[:max(strings.last_index_byte(path, '/'), 1)]
		sync_dir(dir)
	}
	return ""
}

// replace_file writes data to path through a temporary file and a rename,
// so a reader sees the old file or the new one, never half of it.
replace_file :: proc(path: string, data: string) -> string {
	tmp := fmt.tprintf("%s.new", path)
	fd, e := linux.open(cstr(tmp), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC, .NOFOLLOW}, transmute(linux.Mode)u32(0o600))
	if e != .NONE {
		return fmt.tprintf("cannot write %s: %s", tmp, errno_text(e))
	}
	we := write_all_fd(fd, transmute([]u8)data)
	if we == .NONE {
		we = linux.fsync(fd)
	}
	linux.close(fd)
	if we != .NONE {
		linux.unlink(cstr(tmp))
		return fmt.tprintf("cannot write %s: %s", tmp, errno_text(we))
	}
	if re := linux.rename(cstr(tmp), cstr(path)); re != .NONE {
		linux.unlink(cstr(tmp))
		return fmt.tprintf("cannot replace %s: %s", path, errno_text(re))
	}
	sync_dir(path[:max(strings.last_index_byte(path, '/'), 1)])
	return ""
}

// socket_address is path as a Unix socket address, or why it cannot be one.
socket_address :: proc(path: string) -> (addr: linux.Sock_Addr_Un, why: string) {
	if path == "" {
		return {}, "there is no socket: XDG_RUNTIME_DIR is not set"
	}
	if len(path) > MAX_SOCKET_PATH {
		return {}, fmt.tprintf("the socket path %s is %d bytes long, and a Unix socket path has at most %d", path, len(path), MAX_SOCKET_PATH)
	}
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	return addr, ""
}

// dial connects to the daemon's socket.
dial :: proc(socket: string) -> (linux.Fd, string) {
	addr, why := socket_address(socket)
	if why != "" {
		return -1, why
	}
	fd, e := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if e != .NONE {
		return -1, fmt.tprintf("cannot make a socket: %s", errno_text(e))
	}
	for {
		e = linux.connect(fd, &addr)
		if e != .EINTR {
			break
		}
	}
	if e != .NONE {
		linux.close(fd)
		#partial switch e {
		case .ENOENT:
			return -1, fmt.tprintf("there is no socket at %s: the laptop is away", socket)
		case .ECONNREFUSED:
			return -1, fmt.tprintf("nothing listens on %s: the laptop is away", socket)
		}
		return -1, fmt.tprintf("cannot connect to %s: %s", socket, errno_text(e))
	}
	return fd, ""
}

hang_up :: proc(fd: linux.Fd) {
	if fd >= 0 {
		linux.close(fd)
	}
}

// wait_for waits until fd is ready for events, up to timeout_ms.
wait_for :: proc(fd: linux.Fd, events: linux.Fd_Poll_Events, timeout_ms: int) -> bool {
	start := time.tick_now()
	for {
		left := timeout_ms - int(time.duration_milliseconds(time.tick_since(start)))
		if left < 0 {
			left = 0
		}
		fds := []linux.Poll_Fd{{fd = fd, events = events}}
		n, e := linux.poll(fds, i32(left))
		if e == .EINTR {
			continue
		}
		return e == .NONE && n > 0
	}
}

// send_all writes data to the socket fd, within timeout_ms.
send_all :: proc(fd: linux.Fd, data: []u8, timeout_ms: int) -> string {
	rest := data
	for len(rest) > 0 {
		if !wait_for(fd, {.OUT}, timeout_ms) {
			return "the other end takes nothing"
		}
		n, e := linux.send(fd, rest, {.NOSIGNAL, .DONTWAIT})
		#partial switch e {
		case .NONE:
			rest = rest[n:]
		case .EINTR, .EAGAIN:
		case:
			return fmt.tprintf("the connection broke (%s)", errno_text(e))
		}
	}
	return ""
}

Read_Status :: enum u8 {
	Line,
	Closed,
	Timeout,
	Too_Long,
	Broken,
}

// A reader of lines from a socket, into a buffer of MAX_LINE.
Line_Reader :: struct {
	fd:         linux.Fd,
	buf:        []u8,
	start, end: int,
}

// read_line reads the next line, without its newline, waiting up to
// timeout_ms for each part of it. The line is in the reader's buffer and
// good until the next read.
read_line :: proc(r: ^Line_Reader, timeout_ms: int) -> (line: string, status: Read_Status) {
	for {
		if i := index_newline(r.buf[r.start:r.end]); i >= 0 {
			line = string(r.buf[r.start:r.start + i])
			r.start += i + 1
			return line, .Line
		}
		if r.start > 0 {
			copy(r.buf, r.buf[r.start:r.end])
			r.end -= r.start
			r.start = 0
		}
		if r.end == len(r.buf) {
			return "", .Too_Long
		}
		if !wait_for(r.fd, {.IN}, timeout_ms) {
			return "", .Timeout
		}
		n, e := linux.recv(r.fd, r.buf[r.end:], {.DONTWAIT})
		#partial switch e {
		case .NONE:
			if n == 0 {
				return "", .Closed
			}
			r.end += n
		case .EINTR, .EAGAIN:
		case:
			return "", .Broken
		}
	}
}

index_newline :: proc(b: []u8) -> int {
	for c, i in b {
		if c == '\n' {
			return i
		}
	}
	return -1
}

// exchange sends one request line on fd and reads the daemon's reply.
exchange :: proc(fd: linux.Fd, line: string, timeout_ms: int, allocator := context.allocator) -> (Reply, string) {
	buf := make([]u8, MAX_LINE, allocator)
	defer delete(buf, allocator)
	reader := Line_Reader{fd = fd, buf = buf}
	return exchange_with(&reader, line, timeout_ms, allocator)
}

exchange_with :: proc(reader: ^Line_Reader, line: string, timeout_ms: int, allocator: runtime.Allocator) -> (Reply, string) {
	if why := send_all(reader.fd, transmute([]u8)line, timeout_ms); why != "" {
		return {}, why
	}
	text, status := read_line(reader, timeout_ms)
	switch status {
	case .Line:
	case .Closed:
		return {}, "the connection closed before the laptop answered"
	case .Timeout:
		return {}, fmt.tprintf("the laptop did not answer within %d s", timeout_ms / 1000)
	case .Too_Long:
		return {}, "the laptop's answer is longer than a line may be"
	case .Broken:
		return {}, "the connection broke"
	}
	reply, why := decode_reply(text, allocator)
	if why != "" {
		return {}, fmt.tprintf("the laptop's answer is not a reply: %s", why)
	}
	return reply, ""
}

// find_program is the program that name runs: name itself when it holds a
// /, otherwise the first executable file of that name on PATH.
find_program :: proc(name: string) -> (path: string, ok: bool) {
	if name == "" {
		return "", false
	}
	executable :: proc(p: string) -> bool {
		st: linux.Stat
		if linux.stat(cstr(p), &st) != .NONE || !linux.S_ISREG(st.mode) {
			return false
		}
		return linux.access(cstr(p), linux.X_OK) == .NONE
	}
	if strings.index_byte(name, '/') >= 0 {
		return name, executable(name)
	}
	path_list := os.get_env("PATH", context.temp_allocator)
	rest := path_list
	for dir in strings.split_iterator(&rest, ":") {
		if dir == "" {
			continue
		}
		candidate := fmt.tprintf("%s/%s", dir, name)
		if executable(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// A program the tools started: its process, the leader of a process group
// of its own, and a pidfd to wait on.
Child :: struct {
	pid:   linux.Pid,
	pidfd: linux.Fd,
}

// spawn starts argv[0] (a path, or a name on PATH) with argv, in env (the
// process's own when nil), with stdin from in_fd (/dev/null when it is -1)
// and stdout and stderr
// on the given descriptors, as the leader of a new process group: a
// timeout then stops the program with everything it started (a hook,
// ssh-keygen, a helper). Between fork and exec the child makes system
// calls only, since the process may have other threads.
//
// With die_with_parent, the program gets SIGTERM when the thread that
// started it ends (PR_SET_PDEATHSIG): a run killed by Ctrl-C or a caller's
// timeout does not leave its git holding index.lock. git removes its locks
// on SIGTERM. Not for what should outlive the daemon, such as a browser.
spawn :: proc(argv: []string, env: []string, out_fd, err_fd: linux.Fd, die_with_parent := false, in_fd: linux.Fd = -1) -> (c: Child, why: string) {
	path, found := find_program(argv[0])
	if !found {
		return {}, fmt.tprintf("%s is not installed, or not on the PATH", argv[0])
	}
	cargs := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		cargs[i] = cstr(a)
	}
	environment := env
	if environment == nil {
		environment, _ = os.environ(context.temp_allocator)
	}
	cenv := make([]cstring, len(environment) + 1, context.temp_allocator)
	for kv, i in environment {
		cenv[i] = cstr(kv)
	}
	cpath := cstr(path)
	null, ne := linux.open("/dev/null", {.CLOEXEC})
	if ne != .NONE {
		return {}, fmt.tprintf("cannot open /dev/null: %s", errno_text(ne))
	}
	defer linux.close(null)
	// The child writes its errno here when exec fails; exec closes it.
	report: [2]linux.Fd
	if e := linux.pipe2(&report, {.CLOEXEC}); e != .NONE {
		return {}, fmt.tprintf("cannot make a pipe: %s", errno_text(e))
	}
	parent := linux.getpid()
	pid, fe := linux.fork()
	if fe != .NONE {
		linux.close(report[0])
		linux.close(report[1])
		return {}, fmt.tprintf("cannot start %s: %s", argv[0], errno_text(fe))
	}
	if pid == 0 {
		child_fail :: proc "contextless" (fd: linux.Fd, e: linux.Errno) -> ! {
			b := [1]u8{u8(e)}
			linux.write(fd, b[:])
			linux.exit_group(127)
		}
		linux.close(report[0])
		linux.setpgid(0, 0)
		if die_with_parent {
			PR_SET_PDEATHSIG :: 1
			linux.syscall(linux.SYS_prctl, uintptr(PR_SET_PDEATHSIG), uintptr(linux.Signal.SIGTERM))
			// The run may have ended before the call: then it is too late
			// for the signal, and the program does not start.
			if linux.getppid() != parent {
				linux.exit_group(127)
			}
		}
		if _, e := linux.dup2(in_fd if in_fd >= 0 else null, 0); e != .NONE {
			child_fail(report[1], e)
		}
		if _, e := linux.dup2(out_fd, 1); e != .NONE {
			child_fail(report[1], e)
		}
		if _, e := linux.dup2(err_fd, 2); e != .NONE {
			child_fail(report[1], e)
		}
		child_fail(report[1], linux.execve(cpath, raw_data(cargs), raw_data(cenv)))
	}
	linux.close(report[1])
	// From this side too, so the group is there before a kill can name it.
	linux.setpgid(pid, pid)
	b: [1]u8
	n: int
	re := linux.Errno.EINTR
	for re == .EINTR {
		n, re = linux.read(report[0], b[:])
	}
	linux.close(report[0])
	if n == 1 {
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil) == .EINTR {}
		return {}, fmt.tprintf("cannot run %s: %s", argv[0], errno_text(linux.Errno(b[0])))
	}
	pidfd, pe := linux.pidfd_open(pid, {})
	if pe != .NONE {
		linux.kill(-pid, .SIGKILL)
		info: linux.Sig_Info
		for linux.waitid(.PID, linux.Id(pid), &info, {.WEXITED}, nil) == .EINTR {}
		return {}, fmt.tprintf("cannot watch %s: %s", argv[0], errno_text(pe))
	}
	return Child{pid = pid, pidfd = linux.Fd(pidfd)}, ""
}

// wait_child waits up to timeout_ms for c to end. One that ended is reaped
// and its pidfd closed; ended is false while it runs.
wait_child :: proc(c: ^Child, timeout_ms: int) -> (code: int, signaled: bool, ended: bool) {
	if c.pidfd < 0 || !wait_for(c.pidfd, {.IN}, timeout_ms) {
		return
	}
	info: linux.Sig_Info
	for linux.waitid(.PIDFD, linux.Id(c.pidfd), &info, {.WEXITED}, nil) == .EINTR {}
	linux.close(c.pidfd)
	c.pidfd = -1
	return int(info.status), linux.Sig_Child_Code(info.code) != .EXITED, true
}

// stop_child kills c's process group, everything it started included, and
// reaps it.
stop_child :: proc(c: ^Child) {
	linux.kill(-c.pid, .SIGKILL)
	wait_child(c, 60_000)
}

// Where a program's standard output and error go.
Output :: enum u8 {
	Capture, // a memory file, read when it has ended (the server's programs)
	Pipe, // a pipe, read while it runs; when it has ended, its read end is
	// the caller's (Program_Run.pipe), to drain what the program started
	// and left running writes later
	Pass, // the descriptor given, such as the daemon's journal
}

// What a program did.
Program_Run :: struct {
	started:  bool,
	exited:   bool, // it ended within the time; running is still going on
	running:  bool,
	success:  bool,
	code:     int,
	signaled: bool,
	output:   string, // its standard output and error, the first MAX_OUTPUT bytes
	why:      string, // why it could not run, or was stopped
	child:    Child, // while it is running
	pipe:     linux.Fd, // Pipe: the read end, open, for the caller to drain and close; -1 otherwise
}

// run_program runs argv with input on its stdin (/dev/null when it is ""), in env (the process's
// own when nil), its output as output says (pass is the descriptor of
// Pass). It waits up to timeout_ms; then the program and its process group
// are killed, unless detach is set, which leaves it running and returns it
// in child for the caller to reap.
run_program :: proc(
	argv: []string,
	timeout_ms: int,
	env: []string = nil,
	detach := false,
	allocator := context.allocator,
	output := Output.Capture,
	pass: linux.Fd = 2,
	die_with_parent := false,
	input := "",
) -> (
	r: Program_Run,
) {
	r.pipe = -1
	in_fd := linux.Fd(-1)
	if input != "" {
		memfd, me := linux.memfd_create("ravnix-link-input", {.CLOEXEC})
		if me != .NONE {
			r.why = fmt.aprintf("cannot give %s its input: %s", argv[0], errno_text(me), allocator = allocator)
			return
		}
		in_fd = memfd
		if we := write_all_fd(memfd, transmute([]u8)input); we != .NONE {
			linux.close(memfd)
			r.why = fmt.aprintf("cannot give %s its input: %s", argv[0], errno_text(we), allocator = allocator)
			return
		}
		linux.lseek(memfd, 0, .SET)
	}
	defer if in_fd >= 0 {
		linux.close(in_fd)
	}
	out_fd, read_fd_ := pass, linux.Fd(-1)
	switch output {
	case .Capture:
		memfd, me := linux.memfd_create("ravnix-link-output", {.CLOEXEC})
		if me != .NONE {
			r.why = fmt.aprintf("cannot capture the output of %s: %s", argv[0], errno_text(me), allocator = allocator)
			return
		}
		out_fd = memfd
	case .Pipe:
		p: [2]linux.Fd
		if e := linux.pipe2(&p, {.CLOEXEC}); e != .NONE {
			r.why = fmt.aprintf("cannot capture the output of %s: %s", argv[0], errno_text(e), allocator = allocator)
			return
		}
		// Only this end does not block: the program's output is a pipe as
		// any program's is.
		if e := linux.fcntl_setfl(p[0], linux.F_SETFL, {.NONBLOCK}); e != .NONE {
			linux.close(p[0])
			linux.close(p[1])
			r.why = fmt.aprintf("cannot capture the output of %s: %s", argv[0], errno_text(e), allocator = allocator)
			return
		}
		read_fd_, out_fd = p[0], p[1]
	case .Pass:
	}
	child, why := spawn(argv, env, out_fd, out_fd, die_with_parent, in_fd)
	if output == .Pipe {
		// The child holds the write end now; with this one closed, the read
		// end sees the end of the file once the child and what it started
		// are done with it.
		linux.close(out_fd)
	}
	defer if output == .Capture {
		linux.close(out_fd)
	}
	// A started program's read end goes to the caller.
	defer if read_fd_ >= 0 && r.pipe < 0 {
		linux.close(read_fd_)
	}
	if why != "" {
		r.why = strings.clone(why, allocator)
		return
	}
	r.started = true
	buf := make([]u8, MAX_OUTPUT, allocator)
	n := 0
	ended := false
	if output == .Pipe {
		// Read while it runs, so a program that writes more than a pipe
		// holds is not stopped by it; keep the first MAX_OUTPUT bytes.
		start := time.tick_now()
		scratch: [4096]u8
		pipe_open := true
		for !ended {
			left := max(0, timeout_ms - int(time.duration_milliseconds(time.tick_since(start))))
			fds := []linux.Poll_Fd {
				{fd = child.pidfd, events = {.IN}},
				{fd = read_fd_ if pipe_open else -1, events = {.IN}},
			}
			got, pe := linux.poll(fds, i32(left))
			if pe == .EINTR {
				continue
			}
			if pe != .NONE || got == 0 {
				break
			}
			if fds[1].revents != {} {
				k, re := linux.read(read_fd_, scratch[:])
				if k > 0 {
					take := min(k, len(buf) - n)
					copy(buf[n:], scratch[:take])
					n += take
				} else if re != .EAGAIN && re != .EINTR {
					// The end of the file, or an error: stop reading it.
					pipe_open = false
				}
			}
			if fds[0].revents != {} {
				ended = true
			}
		}
		// What it wrote before it ended, still in the pipe.
		for ended {
			k, _ := linux.read(read_fd_, scratch[:])
			if k <= 0 {
				break
			}
			take := min(k, len(buf) - n)
			copy(buf[n:], scratch[:take])
			n += take
		}
	}
	// A pipe's loop has waited already, until the end or the time limit.
	code, signaled, done := wait_child(&child, 0 if output == .Pipe else timeout_ms)
	if !done {
		if detach {
			r.running = true
			r.child = child
		} else {
			stop_child(&child)
			r.why = fmt.aprintf("%s did not finish within %.1f s and was stopped", argv[0], f64(timeout_ms) / 1000, allocator = allocator)
		}
	} else {
		r.exited = true
		r.code = code
		r.signaled = signaled
		r.success = !signaled && code == 0
	}
	if output == .Capture {
		for n < len(buf) {
			got, e := linux.pread(out_fd, buf[n:], i64(n))
			if e == .EINTR {
				continue
			}
			if e != .NONE || got == 0 {
				break
			}
			n += got
		}
	}
	if output == .Pipe {
		r.pipe = read_fd_
	}
	r.output = string(buf[:n])
	return
}

// first_lines is text trimmed, at most n lines of it.
first_lines :: proc(text: string, n: int) -> string {
	t := strings.trim_space(text)
	count := 0
	for c, i in transmute([]u8)t {
		if c == '\n' {
			count += 1
			if count == n {
				return strings.trim_space(t[:i])
			}
		}
	}
	return t
}
