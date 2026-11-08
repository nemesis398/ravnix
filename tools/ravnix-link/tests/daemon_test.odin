// The tests of the daemon on huginn: its socket, what it runs for each
// request and how, and what it does with a line that is not a request.
package ravnix_link_tests

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import link ".."

@(test)
the_socket_is_the_users_alone :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	info, err := os.lstat(f.socket, f.a)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, info.type, os.File_Type.Socket)
	testing.expect_value(t, transmute(u32)info.mode & 0o777, 0o600)
	dinfo, derr := os.stat(f.server.state, f.a)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, transmute(u32)dinfo.mode & 0o777, 0o700)
}

@(test)
a_second_daemon_on_the_same_socket_is_refused :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	d, why := link.daemon_open(f.server)
	testing.expect(t, d == nil)
	testing.expect(t, contains(why, "already"), why)
	// The first one still answers.
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
}

@(test)
a_stale_socket_is_replaced_and_a_file_in_its_place_is_kept :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	// A daemon that died leaves its socket behind.
	crash_daemon(f)
	testing.expect(t, os.exists(f.socket))
	start_daemon(f)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	stop_daemon(f)

	os.remove(f.socket)
	write_file(f, f.socket, "not a socket")
	d, why := link.daemon_open(f.server)
	testing.expect(t, d == nil)
	testing.expect(t, contains(why, "not a socket"), why)
	testing.expect_value(t, read_file(f, f.socket), "not a socket")
}

// A live daemon with another state directory still listens on the socket:
// the probe finds it, and the second daemon refuses to start.
@(test)
a_second_daemon_with_another_state_is_refused_by_the_probe :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	other := f.server
	other.state = join(f, "other-state")
	began := time.tick_now()
	d, why := link.daemon_open(other)
	testing.expect(t, d == nil)
	testing.expect(t, contains(why, "already listens"), why)
	testing.expect(t, time.tick_since(began) >= 400 * time.Millisecond)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
}

// A child forked just before the daemon died holds a copy of its listening
// socket until it runs its program, so for a moment the dead daemon's
// socket still takes connections. In the tests that child is any other
// test's, as the tests run in threads of one process.
@(test)
a_socket_held_a_moment_by_a_forked_child_is_still_stale :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	// Close-on-exec, or the other tests' programs would keep it far longer.
	copy, e := linux.fcntl(f.daemon.listener, linux.F_DUPFD_CLOEXEC, 0)
	testing.expect_value(t, e, linux.Errno.NONE)
	crash_daemon(f)
	closer := thread.create_and_start_with_poly_data(copy, proc(fd: linux.Fd) {
		time.sleep(50 * time.Millisecond)
		linux.close(fd)
	})
	defer thread.destroy(closer)
	defer thread.join(closer)
	start_daemon(f)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
}

@(test)
a_socket_path_too_long_for_unix_is_refused :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	cfg := f.server
	cfg.socket = strings.concatenate({f.dir, "/", strings.repeat("s", 120, f.a)}, f.a)
	d, why := link.daemon_open(cfg)
	testing.expect(t, d == nil)
	testing.expect(t, contains(why, "107"), why)
	_, dwhy := link.dial(cfg.socket)
	testing.expect(t, contains(dwhy, "107"), dwhy)
}

@(test)
obsidian_is_run_by_path_with_nothing_on_its_input :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `if [ "$n" = obsidian ]; then if read -r line; then echo "stdin:$line" >>"$d/stdin"; else echo "stdin:eof" >>"$d/stdin"; fi; fi` + "\n")
	start_daemon(f)
	reqs := []link.Request {
		obsidian_request(f, .Move, ODD_PATH, to = "Archiv/Über – alt"),
		obsidian_request(f, .Rename, ODD_PATH, name = "Neu"),
		obsidian_request(f, .Delete, ODD_PATH),
	}
	for r in reqs {
		outcome, message := link.submit(f.client, r)
		testing.expectf(t, outcome == .Done, "%v: %s", outcome, message)
	}
	got := runs_of(f, "obsidian")
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), "move|path=" + ODD_PATH + "|to=Archiv/Über – alt")
		testing.expect_value(t, strings.join(got[1][1:], "|", f.a), "rename|path=" + ODD_PATH + "|name=Neu")
		testing.expect_value(t, strings.join(got[2][1:], "|", f.a), "delete|path=" + ODD_PATH)
	}
	testing.expect_value(t, read_file(f, join(f, "bin", "stdin")), "stdin:eof\nstdin:eof\nstdin:eof\n")
}

@(test)
an_error_line_from_obsidian_fails_the_request_whatever_its_exit :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = obsidian ] && { echo 'Moving...'; echo 'Error: Destination "Archiv" is a file.'; }` + "\n")
	start_daemon(f)
	outcome, message := link.submit(f.client, obsidian_request(f, .Move, "a.md", to = "Archiv"))
	testing.expect_value(t, outcome, link.Outcome.Failed)
	testing.expect_value(t, message, `Error: Destination "Archiv" is a file.`)
	// An Error: inside a line is no error; a failing exit is.
	set_case(f, `[ "$n" = obsidian ] && echo 'Moved. No Error: here.'` + "\n")
	outcome, message = link.submit(f.client, obsidian_request(f, .Move, "b.md", to = "Archiv"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	set_case(f, `[ "$n" = obsidian ] && { echo 'crashed' >&2; exit 3; }` + "\n")
	outcome, message = link.submit(f.client, obsidian_request(f, .Move, "c.md", to = "Archiv"))
	testing.expect_value(t, outcome, link.Outcome.Failed)
	testing.expect(t, contains(message, "crashed"), message)
	testing.expect(t, contains(message, "3"), message)
}

@(test)
an_obsidian_that_hangs_is_killed_and_the_request_failed :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	f.server.program_timeout_ms = 300
	set_case(f, `[ "$n" = obsidian ] && exec sleep 30` + "\n")
	start_daemon(f)
	began := time.tick_now()
	outcome, message := link.submit(f.client, obsidian_request(f, .Delete, "a.md"))
	testing.expect_value(t, outcome, link.Outcome.Failed)
	testing.expect(t, contains(message, "did not finish"), message)
	testing.expect(t, time.tick_since(began) < 10 * time.Second)
}

// xdg-open hands the link to an application and may wait for it to quit.
// The daemon does not: a run still going after a moment is a link opened.
@(test)
an_open_that_keeps_running_is_opened_and_does_not_block_the_daemon :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = xdg-open ] && exec sleep 4` + "\n")
	start_daemon(f)
	began := time.tick_now()
	for i in 0 ..< 3 {
		outcome, message := link.submit(f.client, open_request(f, "https://example.org/"))
		testing.expectf(t, outcome == .Done, "%d: %v %s", i, outcome, message)
	}
	testing.expect(t, time.tick_since(began) < 10 * time.Second)
	set_case(f, `[ "$n" = xdg-open ] && { echo "xdg-open: file '$1' does not exist" >&2; exit 2; }` + "\n")
	outcome, message := link.submit(f.client, open_request(f, "/home/alice/nirgends.pdf"))
	testing.expect_value(t, outcome, link.Outcome.Failed)
	testing.expect(t, contains(message, "exited with status 2"), message)
	// Its words are in the daemon's standard error, the journal.
	testing.expect(t, contains(stderr_text(f), "does not exist"), stderr_text(f))
}

// With a systemd-run, each program starts in a scope of its own, so a
// restart of the daemon's unit does not take down what the program
// started; the stand-in runs the program as systemd-run --scope does, in
// its own place.
@(test)
the_programs_start_in_a_scope_of_their_own :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	testing.expect_value(t, os.symlink(STUB, join(f, "bin", "systemd-run")), nil)
	set_case(f, `[ "$n" = systemd-run ] && { while [ "$1" != -- ]; do shift; done; shift; exec "$@"; }` + "\n")
	f.server.systemd_run = join(f, "bin", "systemd-run")
	start_daemon(f)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	outcome, _ = link.submit(f.client, obsidian_request(f, .Delete, "Notizen/a.md"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	all := runs(f)
	testing.expect_value(t, len(all), 4)
	if len(all) == 4 {
		scope := []string{"systemd-run", "--user", "--scope", "--collect", "--quiet", "--"}
		testing.expect(t, slice_equal(all[0][:6], scope), strings.join(all[0], " ", f.a))
		testing.expect_value(t, all[0][6], f.server.xdg_open)
		testing.expect_value(t, strings.join(all[1], " ", f.a), "xdg-open https://example.org/")
		testing.expect(t, slice_equal(all[2][:6], scope), strings.join(all[2], " ", f.a))
		testing.expect_value(t, all[2][6], f.server.obsidian)
		testing.expect_value(t, all[3][0], "obsidian")
	}
	// A systemd-run that is not there: the request waits, as for a
	// missing program.
	stop_daemon(f)
	f.server.systemd_run = join(f, "bin", "no-systemd-run")
	start_daemon(f)
	expect_enqueued(f, open_request(f, "https://example.org/2"))
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	testing.expect_value(t, len(runs(f)), 4)
}

slice_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}

// obsidian may start Obsidian, which keeps the CLI's output open for its
// whole life. The daemon reads the CLI's output while it runs and stops
// when the CLI has ended, not when the output closes; its Error: line
// still counts.
@(test)
an_obsidian_that_leaves_a_process_on_its_output_is_answered_when_it_ends :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	// The process left behind writes to the output a second later; with
	// the output closed, that write fails and its next line never runs.
	set_case(f, `[ "$n" = obsidian ] && { sleep 30 & ( sleep 1; echo later && : >"$d/late" ) & echo 'Error: File "Notizen/a.md" not found.'; exit 0; }` + "\n")
	start_daemon(f)
	began := time.tick_now()
	outcome, message := link.submit(f.client, obsidian_request(f, .Delete, "Notizen/a.md"))
	testing.expect(t, time.tick_since(began) < 10 * time.Second)
	testing.expect_value(t, outcome, link.Outcome.Failed)
	testing.expect(t, contains(message, `Error: File "Notizen/a.md" not found.`), message)
	time.sleep(2 * time.Second)
	testing.expect(t, !os.exists(join(f, "bin", "late")), "the process left behind still wrote to the daemon")
}

// A program that times out is stopped with its process group: what it
// started (a hook, ssh-keygen, a helper) goes with it.
@(test)
a_program_that_times_out_is_stopped_with_what_it_started :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	pid_file := join(f, "child.pid")
	ran := link.run_program({"/bin/sh", "-c", strings.concatenate({"sleep 60 & echo $! >'", pid_file, "'; sleep 60"}, f.a)}, 300, allocator = f.a)
	testing.expect(t, contains(ran.why, "did not finish"), ran.why)
	pid, ok := strconv.parse_int(strings.trim_space(read_file(f, pid_file)))
	testing.expect(t, ok, read_file(f, pid_file))
	gone := false
	for _ in 0 ..< 100 {
		if linux.kill(linux.Pid(pid), linux.Signal(0)) == .ESRCH {
			gone = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, gone, "the background child outlived its program")
}

// An xdg-open that went on after its request is collected when it ends,
// and leaves no zombie behind.
@(test)
an_open_that_ended_later_is_collected :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	f.server.open_wait_ms = 100
	set_case(f, `[ "$n" = xdg-open ] && exec sleep 0.3` + "\n")
	start_daemon(f)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	time.sleep(1 * time.Second)
	sync.atomic_store(&f.stop, true)
	thread.join(f.worker)
	thread.destroy(f.worker)
	f.worker = nil
	testing.expect_value(t, len(f.daemon.children), 0)
}

@(test)
notify_send_gets_the_urgency_the_application_and_the_text :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	n := notify_request(f, "-u low", "--zweite Zeile\nund mehr")
	n.urgency = "critical"
	n.app = "Claude Code"
	outcome, _ := link.submit(f.client, n)
	testing.expect_value(t, outcome, link.Outcome.Done)
	got := runs_of(f, "notify-send")
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), "-u|critical|-a|Claude Code|--|-u low|--zweite Zeile\nund mehr")
	}
}

@(test)
what_is_not_a_request_is_answered_and_the_connection_kept :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	fd, why := link.dial(f.socket)
	testing.expect_value(t, why, "")
	defer link.hang_up(fd)
	reply, ewhy := link.exchange(fd, "nonsense\n", 5000, f.a)
	testing.expect_value(t, ewhy, "")
	testing.expect_value(t, reply.status, link.Status.Failed)
	testing.expect_value(t, reply.id, "")
	// A request with an id but a kind the daemon does not know is answered
	// by that id, so the client can let it go.
	bad := `{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","kind":"shell","args":{"command":"rm"},"created":"2026-11-08T12:00:00Z"}` + "\n"
	reply, ewhy = link.exchange(fd, bad, 5000, f.a)
	testing.expect_value(t, ewhy, "")
	testing.expect_value(t, reply.status, link.Status.Failed)
	testing.expect_value(t, reply.id, "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d")
	// vault-commit is the server's; the daemon runs no git.
	c := commit_request(f, "vault: here?")
	line, _ := link.encode_request(c, f.a)
	reply, ewhy = link.exchange(fd, line, 5000, f.a)
	testing.expect_value(t, reply.status, link.Status.Failed)
	testing.expect(t, contains(reply.error, "server"), reply.error)
	// And the connection still serves a good request.
	good, _ := link.encode_request(open_request(f, "https://example.org/"), f.a)
	reply, ewhy = link.exchange(fd, good, 5000, f.a)
	testing.expect_value(t, reply.status, link.Status.Done)
	testing.expect_value(t, len(runs(f)), 1)
}

@(test)
a_line_above_the_limit_is_refused_and_the_connection_closed :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	fd, why := link.dial(f.socket)
	testing.expect_value(t, why, "")
	defer link.hang_up(fd)
	// Above the limit, and within what the socket holds, so the whole line
	// is sent before the daemon answers and closes.
	huge := strings.concatenate({`{"id":"`, strings.repeat("x", 70_000, f.a), "\"}\n"}, f.a)
	reply, ewhy := link.exchange(fd, huge, 5000, f.a)
	testing.expect_value(t, ewhy, "")
	testing.expect_value(t, reply.status, link.Status.Failed)
	testing.expect(t, contains(reply.error, "65536"), reply.error)
	good, _ := link.encode_request(open_request(f, "https://example.org/"), f.a)
	_, after := link.exchange(fd, good, 5000, f.a)
	testing.expect(t, after != "", "the connection served on after a line above the limit")
	// The daemon serves the next connection.
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
}

// A connection that sends nothing is closed after the idle time, and the
// daemon serves the next one meanwhile... after it.
@(test)
a_silent_connection_does_not_hold_the_daemon :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	f.server.idle_ms = 300
	start_daemon(f)
	fd, why := link.dial(f.socket)
	testing.expect_value(t, why, "")
	defer link.hang_up(fd)
	began := time.tick_now()
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	testing.expect(t, time.tick_since(began) < 5 * time.Second)
}

// The programs the daemon starts carry a mark, and a client that has it
// refuses to run: a daemon that ran on muninn by mistake would otherwise
// hand each request to itself through the xdg-open there, forever.
@(test)
the_daemons_programs_are_marked_and_a_marked_client_refuses :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = xdg-open ] && echo "mark:${RAVNIX_LINK_DAEMON-}" >>"$d/mark"` + "\n")
	start_daemon(f)
	outcome, _ := link.submit(f.client, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	testing.expect_value(t, read_file(f, join(f, "bin", "mark")), "mark:1\n")
	env := link.Environment {
		runtime_dir   = f.dir,
		state_home    = f.dir,
		home          = f.dir,
		cwd           = f.dir,
		daemon_marker = "1",
	}
	code := run_cli(f, env, {"open", "https://example.org/"})
	testing.expect_value(t, code.code, 1)
	testing.expect(t, contains(code.err, "loop"), code.err)
}
