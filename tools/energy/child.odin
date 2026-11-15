package energy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// What a child program did. started is false when the program is not on the
// PATH (or could not be run), and then code is 127, as a shell says.
Child :: struct {
	started:   bool,
	// The exit status; 128 and the signal number when a signal ended it.
	code:      int,
	stdout:    []byte,
	// It did not finish in time and was killed (code is 124).
	timed_out: bool,
	// It printed more than MAX_OUTPUT and was killed.
	too_much:  bool,
}

Child_Spec :: struct {
	// argv[0] is a program name, looked up on Config.path.
	argv:         []string,
	// Rows for the program's standard input; "" gives it /dev/null.
	input:        string,
	// Keep what it prints on standard output; else that goes to stdout_to.
	capture:      bool,
	// Where its output and error output go; nil is /dev/null.
	stdout_to:    ^os.File,
	stderr_to:    ^os.File,
	// No limit of time: a person answers (fuzzel).
	wait_forever: bool,
}

// What a program may print before it is killed. sway's list of outputs is a
// few kilobytes.
MAX_OUTPUT :: 16 << 20

// Starting a process changes what its siblings inherit, and Odin says the
// call is not thread safe; so the tests, which run on several threads,
// start their children one at a time.
@(private = "file")
spawn_mutex: sync.Mutex

// find_program is what `command -v NAME` finds on the PATH string path: the
// first regular file that can be executed. A name with a slash is taken as
// it is.
find_program :: proc(path, name: string, allocator := context.allocator) -> (full: string, ok: bool) {
	if name == "" {
		return
	}
	if strings.contains_rune(name, '/') {
		return strings.clone(name, allocator), is_executable(name)
	}
	rest := path
	for dir in strings.split_iterator(&rest, ":") {
		if dir == "" {
			continue
		}
		candidate := strings.concatenate({dir, "/", name}, allocator)
		if is_executable(candidate) {
			return candidate, true
		}
		delete(candidate, allocator)
	}
	return
}

is_executable :: proc(path: string) -> bool {
	buf: [4096]u8
	if len(path) >= len(buf) {
		return false
	}
	copy(buf[:], path)
	cpath := cstring(raw_data(buf[:]))
	stat: linux.Statx
	if linux.statx(linux.AT_FDCWD, cpath, {}, {.TYPE}, &stat) != .NONE {
		return false
	}
	return .IFREG in stat.mode && linux.access(cpath, linux.X_OK) == .NONE
}

// child_env is the environment of a child: this process's, with the PATH
// that Config.path names, so that a program energy starts finds the tools
// that energy does.
child_env :: proc(cfg: ^Config, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	environ, _ := os.environ(allocator)
	for entry in environ {
		if !strings.has_prefix(entry, "PATH=") {
			append(&out, entry)
		}
	}
	append(&out, strings.concatenate({"PATH=", cfg.path}, allocator))
	return out[:]
}

// start_child starts argv (argv[0] is a full path) with the given files.
start_child :: proc(cfg: ^Config, argv: []string, stdin, stdout, stderr: ^os.File) -> (process: os.Process, err: os.Error) {
	sync.guard(&spawn_mutex)
	return os.process_start({command = argv, env = child_env(cfg, context.temp_allocator), stdin = stdin, stdout = stdout, stderr = stderr})
}

// wait_child waits for the child, frees its handle and says how it ended.
wait_child :: proc(process: os.Process) -> int {
	info: linux.Sig_Info
	errno := linux.Errno.EINTR
	for errno == .EINTR {
		errno = linux.waitid(.PID, linux.Id(process.pid), &info, {.WEXITED}, nil)
	}
	_ = linux.close(linux.Fd(process.handle))
	if errno != .NONE {
		return 127
	}
	#partial switch linux.Sig_Child_Code(info.code) {
	case .EXITED:
		return int(info.status)
	case:
		return 128 + int(info.status)
	}
}

// run_child runs a program and waits for it. The time limit (Config.timeout)
// and the output limit end a program that hangs or floods; its status is
// then 124 and the flags say why.
//
// One poll over the child's pidfd and its output pipe drives it, so a child
// that is gone while a daemon of its own holds the pipe does not keep this
// call waiting.
run_child :: proc(cfg: ^Config, spec: Child_Spec, allocator := context.allocator) -> (res: Child) {
	res.code = 127
	assert(len(spec.argv) > 0)
	exe, found := find_program(cfg.path, spec.argv[0], context.temp_allocator)
	if !found {
		return
	}
	argv := make([]string, len(spec.argv), context.temp_allocator)
	copy(argv, spec.argv)
	argv[0] = exe

	// The rows go in through a file in memory, not a pipe: a program that
	// ends before it reads them cannot raise SIGPIPE here.
	stdin: ^os.File
	if spec.input != "" {
		fd, errno := linux.memfd_create("energy-input", {.CLOEXEC})
		if errno != .NONE {
			return
		}
		stdin = os.new_file(uintptr(fd), "input")
		_, werr := os.write_string(stdin, spec.input)
		_, serr := linux.lseek(fd, 0, .SET)
		if werr != nil || serr != .NONE {
			_ = os.close(stdin)
			return
		}
	}
	defer if stdin != nil {
		_ = os.close(stdin)
	}

	stdout_r, stdout_w: ^os.File
	stdout_file := spec.stdout_to
	if spec.capture {
		err: os.Error
		if stdout_r, stdout_w, err = os.pipe(); err != nil {
			return
		}
		stdout_file = stdout_w
	}
	process, err := start_child(cfg, argv, stdin, stdout_file, spec.stderr_to)
	if stdout_w != nil {
		_ = os.close(stdout_w)
	}
	if err != nil {
		if stdout_r != nil {
			_ = os.close(stdout_r)
		}
		return
	}
	res.started = true

	out := make([dynamic]byte, allocator)
	limit: time.Duration = cfg.timeout
	deadline := time.tick_add(time.tick_now(), limit)
	pid_fd := linux.Fd(process.handle)
	buf: [4096]byte
	killed := false
	max_output := cfg.max_output if cfg.max_output > 0 else MAX_OUTPUT

	for {
		fds: [2]linux.Poll_Fd
		n := 0
		fds[n] = {
			fd     = pid_fd,
			events = {.IN},
		}
		n += 1
		if stdout_r != nil {
			fds[n] = {
				fd     = linux.Fd(os.fd(stdout_r)),
				events = {.IN},
			}
			n += 1
		}
		wait_ms: i32 = -1
		if !spec.wait_forever {
			remaining := time.tick_diff(time.tick_now(), deadline)
			if remaining <= 0 {
				res.timed_out = true
				break
			}
			wait_ms = i32(min(remaining / time.Millisecond + 1, 60_000))
		}
		_, errno := linux.poll(fds[:n], wait_ms)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			res.timed_out = true
			break
		}
		exited := fds[0].revents != {}
		if n == 2 && fds[1].revents != {} {
			if !read_some(&stdout_r, &out, buf[:]) && !exited {
				// The program closed its output but still runs: wait for
				// the pidfd alone.
				continue
			}
		}
		if len(out) > max_output {
			res.too_much = true
			break
		}
		if exited {
			// What it wrote before it exited is in the pipe.
			for stdout_r != nil && ready_now(stdout_r) {
				if !read_some(&stdout_r, &out, buf[:]) {
					break
				}
			}
			break
		}
	}
	if stdout_r != nil {
		_ = os.close(stdout_r)
	}
	if res.timed_out || res.too_much {
		_ = linux.kill(linux.Pid(process.pid), .SIGKILL)
		killed = true
	}
	res.code = wait_child(process)
	if killed {
		res.code = 124
	}
	res.stdout = out[:]
	return
}

// read_some reads what is there from a pipe that poll has reported. At its
// end the pipe is closed and nil, and the result is false.
read_some :: proc(pipe: ^^os.File, into: ^[dynamic]byte, buf: []byte) -> bool {
	n, _ := os.read(pipe^, buf)
	if n > 0 {
		append(into, ..buf[:n])
		return true
	}
	_ = os.close(pipe^)
	pipe^ = nil
	return false
}

ready_now :: proc(pipe: ^os.File) -> bool {
	fds := [1]linux.Poll_Fd{{fd = linux.Fd(os.fd(pipe)), events = {.IN}}}
	ready, errno := linux.poll(fds[:], 0)
	return errno == .NONE && ready > 0
}

// say writes one line to the error output (the journal, under systemd).
say :: proc(cfg: ^Config, format: string, args: ..any) {
	fmt.fprintfln(cfg.stderr, format, ..args)
}

// notify posts a notification titled Energy, when notify-send is there.
notify :: proc(cfg: ^Config, args: ..string) {
	if _, ok := find_program(cfg.path, "notify-send", context.temp_allocator); !ok {
		return
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "notify-send", "-a", "Energy")
	append(&argv, ..args)
	_ = run_child(cfg, {argv = argv[:], stdout_to = cfg.stdout, stderr_to = cfg.stderr}, context.temp_allocator)
}

// need checks that a program of the desktop session is on the PATH. When it
// is not, the journal and a notification say so, naming the tool and what
// stays as it is, so nothing claims a change that did not happen.
need :: proc(cfg: ^Config, tool, consequence: string) -> bool {
	if _, ok := find_program(cfg.path, tool, context.temp_allocator); ok {
		return true
	}
	say(cfg, "energy: %s is not on the PATH, so %s", tool, consequence)
	notify(cfg, "-u", "critical", fmt.tprintf("%s not found", tool), fmt.tprintf("%s.", consequence))
	return false
}

// keep_awake runs `keep-awake set STATE`, and when it fails says so the same
// way. may_still_be is the state it may have been left in.
keep_awake :: proc(cfg: ^Config, state, may_still_be: string) -> int {
	res := run_child(cfg, {argv = {"keep-awake", "set", state}, stdout_to = cfg.stdout, stderr_to = cfg.stderr}, context.temp_allocator)
	if res.code == 0 {
		return 0
	}
	message := fmt.tprintf("keep-awake set %s failed (exit %d), so keep-awake may still be %s", state, res.code, may_still_be)
	say(cfg, "energy: %s", message)
	notify(cfg, "-u", "critical", "keep-awake failed", fmt.tprintf("%s.", message))
	return res.code
}
