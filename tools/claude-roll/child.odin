// The child process runner, as ravnix-notify has it (tools/ravnix-notify/
// child.odin): a timeout, a cap on the output, and no SIGPIPE. claude-roll
// runs herdr and ravnix-notify through it.
package claude_roll

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// What a child program did. start_error is "" when it started.
Child_Result :: struct {
	stdout:      []byte,
	stderr:      []byte,
	exit_code:   int,
	start_error: string,
	// It did not finish in time and was killed.
	timed_out:   bool,
	// It printed more than allowed and was killed.
	too_much:    bool,
}

// Starting a process changes what its siblings inherit, and Odin says the
// call is not thread safe; so two runs in one process, as in the tests,
// start their children one at a time.
@(private = "file")
spawn_mutex: sync.Mutex

CHUNK :: 4096

// run_child runs command with input on its standard input, and returns what
// it printed, in dir when it is not "", with env as its whole environment
// when it is not nil. It waits for the child to exit, however long its pipes stay
// open: a daemon it starts (rbw starts its agent) may keep them. It kills the
// child when timeout is over, or when it prints more than max_output bytes.
//
// One poll over the pipes and the child's pidfd drives it all, writing the
// input in pieces that fit the pipe, so a child that never reads cannot stall
// the write, and a child that is gone does not kill this process (SIGPIPE is
// ignored).
run_child :: proc(command: []string, input: []byte, timeout: time.Duration, max_output: int, allocator := context.allocator, dir := "", env: []string = nil) -> (res: Child_Result) {
	_ = posix.sigignore(.SIGPIPE)

	stdin_r, stdin_w, stdout_r, stdout_w, stderr_r, stderr_w: ^os.File
	process: os.Process
	{
		sync.guard(&spawn_mutex)
		err: os.Error
		if stdin_r, stdin_w, err = os.pipe(); err == nil {
			if stdout_r, stdout_w, err = os.pipe(); err == nil {
				stderr_r, stderr_w, err = os.pipe()
			}
		}
		if err == nil {
			process, err = os.process_start({command = command, working_dir = dir, env = env, stdin = stdin_r, stdout = stdout_w, stderr = stderr_w})
		}
		// The child has its ends, or there is no child; the parent keeps none.
		close_files(stdin_r, stdout_w, stderr_w)
		if err != nil {
			close_files(stdin_w, stdout_r, stderr_r)
			res.start_error = strings.clone(os.error_string(err), allocator)
			return
		}
	}

	out := make([dynamic]byte, allocator)
	errb := make([dynamic]byte, allocator)
	if len(input) == 0 {
		close_files(stdin_w)
		stdin_w = nil
	}
	sent := 0
	deadline := time.tick_add(time.tick_now(), timeout)
	pid_fd := linux.Fd(process.handle)
	buf: [CHUNK]byte

	poll: for {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			res.timed_out = true
			break
		}
		fds: [4]linux.Poll_Fd
		n := 0
		fds[n] = {
			fd     = pid_fd,
			events = {.IN},
		}
		n += 1
		if stdin_w != nil {
			fds[n] = {
				fd     = linux.Fd(os.fd(stdin_w)),
				events = {.OUT},
			}
			n += 1
		}
		if stdout_r != nil {
			fds[n] = {
				fd     = linux.Fd(os.fd(stdout_r)),
				events = {.IN},
			}
			n += 1
		}
		if stderr_r != nil {
			fds[n] = {
				fd     = linux.Fd(os.fd(stderr_r)),
				events = {.IN},
			}
			n += 1
		}
		_, errno := linux.poll(fds[:n], i32(min(remaining / time.Millisecond + 1, 60_000)))
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			res.timed_out = true
			break
		}
		exited := false
		for k in 0 ..< n {
			ready := fds[k].revents
			if ready == {} {
				continue
			}
			switch {
			case fds[k].fd == pid_fd:
				exited = true
			case stdin_w != nil && fds[k].fd == linux.Fd(os.fd(stdin_w)):
				if .ERR in ready || .HUP in ready {
					close_files(stdin_w)
					stdin_w = nil
					break
				}
				piece := input[sent:min(sent + CHUNK, len(input))]
				wrote, werr := os.write(stdin_w, piece)
				sent += wrote
				if werr != nil || sent == len(input) {
					close_files(stdin_w)
					stdin_w = nil
				}
			case stdout_r != nil && fds[k].fd == linux.Fd(os.fd(stdout_r)):
				if !read_some(&stdout_r, &out, buf[:]) {
					break
				}
			case stderr_r != nil && fds[k].fd == linux.Fd(os.fd(stderr_r)):
				if !read_some(&stderr_r, &errb, buf[:]) {
					break
				}
			}
		}
		if len(out) + len(errb) > max_output {
			res.too_much = true
			break
		}
		if exited {
			// What it wrote before it exited is in the pipes.
			drain(&stdout_r, &out, buf[:])
			drain(&stderr_r, &errb, buf[:])
			break poll
		}
	}
	close_files(stdin_w, stdout_r, stderr_r)

	if res.timed_out || res.too_much {
		_ = os.process_kill(process)
	}
	state, _ := os.process_wait(process)
	res.exit_code = state.exit_code
	res.stdout = out[:]
	res.stderr = errb[:]
	return
}

close_files :: proc(files: ..^os.File) {
	for f in files {
		if f != nil {
			_ = os.close(f)
		}
	}
}

// read_some reads what is there from a pipe that poll has reported. At its
// end, the pipe is closed and nil, and the result is false.
read_some :: proc(pipe: ^^os.File, into: ^[dynamic]byte, buf: []byte) -> bool {
	n, _ := os.read(pipe^, buf)
	if n > 0 {
		append(into, ..buf[:n])
		return true
	}
	close_files(pipe^)
	pipe^ = nil
	return false
}

// drain reads a pipe until nothing more is there to read at once.
drain :: proc(pipe: ^^os.File, into: ^[dynamic]byte, buf: []byte) {
	for pipe^ != nil {
		fds := [1]linux.Poll_Fd{{fd = linux.Fd(os.fd(pipe^)), events = {.IN}}}
		ready, errno := linux.poll(fds[:], 0)
		if errno != .NONE || ready <= 0 {
			return
		}
		if !read_some(pipe, into, buf) {
			return
		}
	}
}
