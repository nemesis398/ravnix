// Running the popup: fuzzel as the user, with its input on standard input and
// its answer on standard output, closed when it takes too long.
package ravnix_tap_ask

import "base:runtime"
import "core:os"
import "core:sync"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

// fuzzel prints an index and a newline. More than this is no answer of
// fuzzel's.
MAX_OUTPUT :: 4096

Popup_Result :: struct {
	stdout:       []byte,
	exit_code:    int,
	// It did not start.
	start_failed: bool,
	// It did not exit in time and was killed.
	timed_out:    bool,
	// It printed more than MAX_OUTPUT and was killed.
	too_much:     bool,
	// From the start to its exit.
	elapsed:      time.Duration,
}

// Starting a process is not thread safe in Odin, and the tests run in
// threads, so children start one at a time.
@(private = "file")
spawn_mutex: sync.Mutex

// run_popup runs command with env as its whole environment and input on its
// standard input, in /, and waits for it at most timeout. Its standard error
// goes nowhere: pam_exec would drop it anyway.
run_popup :: proc(command, env: []string, input: string, timeout: time.Duration, allocator: runtime.Allocator) -> (res: Popup_Result) {
	// A popup that exits before it reads its input must not kill this
	// process with SIGPIPE.
	_ = posix.sigignore(.SIGPIPE)

	stdin_r, stdin_w, stdout_r, stdout_w: ^os.File
	process: os.Process
	start := time.tick_now()
	{
		sync.guard(&spawn_mutex)
		err: os.Error
		if stdin_r, stdin_w, err = os.pipe(); err == nil {
			stdout_r, stdout_w, err = os.pipe()
		}
		if err == nil {
			process, err = os.process_start({command = command, env = env, working_dir = "/", stdin = stdin_r, stdout = stdout_w})
		}
		close_all(stdin_r, stdout_w)
		if err != nil {
			close_all(stdin_w, stdout_r)
			res.start_failed = true
			return
		}
	}
	// The input is a few bytes, far less than a pipe holds, so this does not
	// block; a popup that never reads it still gets to answer.
	_, _ = os.write_string(stdin_w, input)
	close_all(stdin_w)

	out := make([dynamic]byte, 0, 64, allocator)
	deadline := time.tick_add(start, timeout)
	pid_fd := linux.Fd(process.handle)
	buf: [512]byte
	loop: for {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			res.timed_out = true
			break
		}
		fds := [2]linux.Poll_Fd{{fd = pid_fd, events = {.IN}}, {fd = -1}}
		n := 1
		if stdout_r != nil {
			fds[1] = {
				fd     = linux.Fd(os.fd(stdout_r)),
				events = {.IN},
			}
			n = 2
		}
		_, errno := linux.poll(fds[:n], i32(min(remaining / time.Millisecond + 1, 60_000)))
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			res.timed_out = true
			break
		}
		if n == 2 && fds[1].revents != {} {
			read_some(&stdout_r, &out, buf[:])
		}
		if len(out) > MAX_OUTPUT {
			res.too_much = true
			break
		}
		if fds[0].revents != {} {
			// What it wrote before it exited is in the pipe.
			for stdout_r != nil && len(out) <= MAX_OUTPUT {
				ready := [1]linux.Poll_Fd{{fd = linux.Fd(os.fd(stdout_r)), events = {.IN}}}
				got, perr := linux.poll(ready[:], 0)
				if perr != .NONE || got <= 0 {
					break
				}
				read_some(&stdout_r, &out, buf[:])
			}
			break loop
		}
	}
	close_all(stdout_r)
	if res.timed_out || res.too_much {
		_ = os.process_kill(process)
	}
	state, _ := os.process_wait(process)
	res.elapsed = time.tick_since(start)
	res.exit_code = state.exit_code
	res.stdout = out[:]
	return
}

@(private = "file")
close_all :: proc(files: ..^os.File) {
	for f in files {
		if f != nil {
			_ = os.close(f)
		}
	}
}

// read_some reads what poll reported. At the pipe's end it closes it.
@(private = "file")
read_some :: proc(pipe: ^^os.File, into: ^[dynamic]byte, buf: []byte) {
	n, _ := os.read(pipe^, buf)
	if n > 0 {
		append(into, ..buf[:n])
		return
	}
	close_all(pipe^)
	pipe^ = nil
}
