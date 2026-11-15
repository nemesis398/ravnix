// The gate's tests: which commands it lets through, what it says and logs
// about every other one, and what it runs.
package ravnix_laptop_gate_tests

import "core:mem/virtual"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import gate ".."

Case :: struct {
	command: string,
	verb:    gate.Verb,
	refusal: gate.Refusal,
}

@(test)
lets_through_each_verb_and_nothing_else :: proc(t: ^testing.T) {
	cases := []Case {
		{"ping", .Ping, .None},
		{"facts", .Facts, .None},
		{"battery", .Battery, .None},
		{"charge-mode", .Charge_Mode, .None},
		{"power", .Power, .None},
		// What the server must not reach: a shell, sudo, a rebuild.
		{"sh -c id", .None, .Unknown},
		{"sudo -n true", .None, .Unknown},
		{"pkexec id", .None, .Unknown},
		{"run0 id", .None, .Unknown},
		{"nixos-rebuild switch", .None, .Unknown},
		{"bash", .None, .Unknown},
		{"id", .None, .Unknown},
		// A subsystem request runs the forced command with its name.
		{"internal-sftp", .None, .Unknown},
		{"sftp", .None, .Unknown},
		// A verb is its exact name.
		{"PING", .None, .Unknown},
		{"Ping", .None, .Unknown},
		{"pin", .None, .Unknown},
		{"pingg", .None, .Unknown},
		{"charge_mode", .None, .Unknown},
		{"/bin/ping", .None, .Unknown},
		{"pïng", .None, .Unknown},
		// No verb takes an argument, not even one that looks harmless.
		{"ping extra", .None, .Arguments},
		{"ping ", .None, .Arguments},
		{"facts --write", .None, .Arguments},
		{"charge-mode set Fast", .None, .Arguments},
		{"charge-mode cycle", .None, .Arguments},
		{" ping", .None, .Unknown},
		{"  ", .None, .Unknown},
	}
	for c in cases {
		verb, refusal := gate.parse(c.command)
		testing.expectf(t, verb == c.verb && refusal == c.refusal, "%q: got %v %v, want %v %v", c.command, verb, refusal, c.verb, c.refusal)
	}
}

@(test)
refuses_shell_metacharacters :: proc(t: ^testing.T) {
	// Each of them, after a verb and alone. ravnix-laptop quotes a word with
	// a backslash, so `ravnix-laptop 'a b'` arrives as `a\ b`.
	for meta in ([]string{";", "&", "|", "<", ">", "(", ")", "$", "`", "\\", "\"", "'", "*", "?", "[", "]", "#", "~", "!", "{", "}"}) {
		for command in ([]string{meta, strings.concatenate({"ping", meta}, context.temp_allocator), strings.concatenate({meta, "ping"}, context.temp_allocator)}) {
			verb, refusal := gate.parse(command)
			testing.expectf(t, verb == .None && refusal == .Metacharacter, "%q: got %v %v", command, verb, refusal)
		}
	}
	for command in ([]string{"ping;id", "ping && id", "ping || id", "$(id)", "`id`", "ping|id", "ping>/tmp/x", "a\\ b", "ping\\;id", "{ping,id}", "ping #"}) {
		verb, refusal := gate.parse(command)
		testing.expectf(t, verb == .None && refusal == .Metacharacter, "%q: got %v %v", command, verb, refusal)
	}
	free_all(context.temp_allocator)
}

@(test)
refuses_control_characters :: proc(t: ^testing.T) {
	for command in ([]string{"ping\n", "ping\nid", "\nping", "ping\x00", "\x00", "ping\r", "ping\t", "\tping", "ping\x1b[2J", "ping\x7f", "\x01"}) {
		verb, refusal := gate.parse(command)
		testing.expectf(t, verb == .None && refusal == .Control, "%q: got %v %v", command, verb, refusal)
	}
}

@(test)
refuses_an_empty_command :: proc(t: ^testing.T) {
	verb, refusal := gate.parse("")
	testing.expect_value(t, verb, gate.Verb.None)
	testing.expect_value(t, refusal, gate.Refusal.Empty)
}

@(test)
refuses_an_over_long_command_at_the_bound :: proc(t: ^testing.T) {
	at := strings.repeat("x", gate.MAX_COMMAND, context.temp_allocator)
	over := strings.repeat("x", gate.MAX_COMMAND + 1, context.temp_allocator)
	verb, refusal := gate.parse(at)
	testing.expect_value(t, refusal, gate.Refusal.Unknown)
	verb, refusal = gate.parse(over)
	testing.expect_value(t, verb, gate.Verb.None)
	testing.expect_value(t, refusal, gate.Refusal.Too_Long)
	// Length wins over what is in it: a long line of control characters or
	// metacharacters, and a verb padded out, are too long.
	for fill in ([]string{"\n", ";", " ", "\x00"}) {
		_, refusal = gate.parse(strings.repeat(fill, gate.MAX_COMMAND + 1, context.temp_allocator))
		testing.expectf(t, refusal == .Too_Long, "%q: %v", fill, refusal)
	}
	_, refusal = gate.parse(strings.concatenate({"ping", strings.repeat(" ", gate.MAX_COMMAND, context.temp_allocator)}, context.temp_allocator))
	testing.expect_value(t, refusal, gate.Refusal.Too_Long)
	// As large as sshd passes on.
	_, refusal = gate.parse(strings.repeat("y", 128 * 1024, context.temp_allocator))
	testing.expect_value(t, refusal, gate.Refusal.Too_Long)
	free_all(context.temp_allocator)
}

@(test)
escapes_what_it_logs :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	testing.expect_value(t, gate.escape("sh -c id", a), "sh -c id")
	testing.expect_value(t, gate.escape(`a"b\c`, a), `a\"b\\c`)
	testing.expect_value(t, gate.escape("x\ny\x00z\x1b\x7f", a), `x\x0ay\x00z\x1b\x7f`)
	testing.expect_value(t, gate.escape("ä", a), `\xc3\xa4`)
	testing.expect_value(t, gate.escape("", a), "")
}

@(test)
says_in_one_line_why_it_refused :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	C :: "192.0.2.20"
	testing.expect_value(t, gate.refusal_line("sh -c id", .Unknown, C, a), `refused "sh -c id" from 192.0.2.20: not an allowed call`)
	testing.expect_value(t, gate.refusal_line("sudo -n true", .Unknown, C, a), `refused "sudo -n true" from 192.0.2.20: not an allowed call`)
	testing.expect_value(t, gate.refusal_line("ping extra", .Arguments, C, a), `refused "ping extra" from 192.0.2.20: ping takes no arguments`)
	testing.expect_value(t, gate.refusal_line("ping;id", .Metacharacter, C, a), `refused "ping;id" from 192.0.2.20: a shell metacharacter`)
	testing.expect_value(t, gate.refusal_line("ping\nid", .Control, C, a), `refused "ping\x0aid" from 192.0.2.20: a control character`)
	testing.expect_value(t, gate.refusal_line("", .Empty, C, a), "refused an empty command from 192.0.2.20: no command (a shell, a subsystem or an empty command)")
	testing.expect_value(t, gate.refusal_line(strings.repeat("x", 100, a), .Too_Long, "", a), "refused a command of 100 bytes from an unknown address: longer than 64 bytes")
}

@(test)
never_logs_an_over_long_or_control_character_command_raw :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	long := strings.concatenate({"rm -rf /", strings.repeat("\n\x1b", 60000, a)}, a)
	commands := []string{long, strings.repeat("z", 100000, a), "ping\nFAKE: second line", "\x1b]0;title\x07", strings.repeat("\x00", 10, a), strings.repeat("ä", 32, a)}
	for command in commands {
		_, refusal := gate.parse(command)
		line := gate.refusal_line(command, refusal, "192.0.2.20", a)
		testing.expectf(t, refusal != .None, "%q is let through", command[:min(len(command), 40)])
		testing.expectf(t, len(line) <= 400, "a line of %d bytes", len(line))
		testing.expectf(t, !strings.contains(line, "rm -rf") && !strings.contains(line, "zzzz"), "the over-long command is in the line: %q", line[:min(len(line), 80)])
		for c in transmute([]byte)line {
			testing.expectf(t, c >= 0x20 && c < 0x7f, "a raw byte 0x%02x in %q", c, line)
		}
	}
}

@(test)
names_the_client_from_ssh_connection :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	testing.expect_value(t, gate.client_of("192.0.2.20 51234 192.0.2.10 22", a), "192.0.2.20")
	testing.expect_value(t, gate.client_of("fd00::2 51234 fd00::1 22", a), "fd00::2")
	testing.expect_value(t, gate.client_of("fe80::1%wt0 51234 fe80::2%wt0 22", a), "fe80::1%wt0")
	// Nothing to go by, or something that is no address: no client.
	testing.expect_value(t, gate.client_of("", a), "")
	testing.expect_value(t, gate.client_of("   ", a), "")
	testing.expect_value(t, gate.client_of("evil\"name 1 2 3", a), "")
	testing.expect_value(t, gate.client_of("a\nb 1 2 3", a), "")
	testing.expect_value(t, gate.client_of(strings.repeat("1", 65, a), a), "")
}

laptop_config :: proc(f: ^Fixture, command: string) -> gate.Config {
	return gate.Config {
		root = f.root,
		command = command,
		client = "192.0.2.20",
		home = "/home/alice",
		user = "alice",
		facts = "/nix/store/x-machine-facts/bin/machine-facts",
		path = "/run/current-system/sw/bin",
	}
}

@(test)
answers_ping :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	r := gate.decide(laptop_config(&f, "ping"), context.allocator)
	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, r.stdout, "huginn is up\n")
	testing.expect_value(t, r.stderr, "")
	testing.expect_value(t, r.log, "")
	testing.expect_value(t, r.exec.path, "")
}

@(test)
answers_the_sysfs_verbs_itself :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	for verb in ([]string{"battery", "charge-mode", "power"}) {
		r := gate.decide(laptop_config(&f, verb), context.allocator)
		want: string
		switch verb {
		case "battery":
			want = gate.battery(f.root, context.allocator)
		case "charge-mode":
			want = gate.charge_mode(f.root, context.allocator)
		case "power":
			want = gate.power(f.root, context.allocator)
		}
		testing.expectf(t, r.status == 0 && r.stdout == want && want != "" && r.stderr == "" && r.log == "" && r.exec.path == "", "%s: %v", verb, r)
	}
}

@(test)
runs_machine_facts_by_its_path_without_sudo_and_with_nothing_of_the_session :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	cfg := laptop_config(&f, "facts")
	r := gate.decide(cfg, context.allocator)
	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, r.stdout, "")
	testing.expect_value(t, r.log, "")
	testing.expect_value(t, r.exec.path, cfg.facts)
	testing.expect_value(t, len(r.exec.argv), 1)
	if len(r.exec.argv) == 1 {
		testing.expect_value(t, r.exec.argv[0], cfg.facts)
	}
	// No sudo, and nothing that may wake the dGPU: the server may ask often.
	want := []string{"PATH=/run/current-system/sw/bin", "HOME=/home/alice", "USER=alice", "LOGNAME=alice", "MACHINE_FACTS_NO_SUDO=1", "MACHINE_FACTS_NO_DGPU_WAKE=1"}
	testing.expectf(t, len(r.exec.env) == len(want), "env %v", r.exec.env)
	for kv, i in want {
		if i < len(r.exec.env) {
			testing.expect_value(t, r.exec.env[i], kv)
		}
	}
	for kv in r.exec.env {
		// Not the setuid wrappers, where sudo and pkexec are. (run0 needs
		// none; machine-facts not calling it is what keeps it out.)
		testing.expectf(t, !strings.contains(kv, "/run/wrappers"), "%s", kv)
		testing.expectf(t, !strings.has_prefix(kv, "SSH_"), "%s", kv)
	}
	// Without a home or a user it leaves them out, rather than set them empty.
	cfg.home, cfg.user = "", ""
	r = gate.decide(cfg, context.allocator)
	testing.expect_value(t, len(r.exec.env), 3)
}

@(test)
refuses_with_exit_77_a_message_and_one_log_line :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	for command in ([]string{"sh -c id", "sudo -n true", "", "ping extra", "ping;id", "ping\nid", strings.repeat("x", 1000)}) {
		r := gate.decide(laptop_config(&f, command), context.allocator)
		_, refusal := gate.parse(command)
		testing.expectf(t, r.status == gate.REFUSED, "%q: %d", command, r.status)
		testing.expect_value(t, r.stdout, "")
		testing.expect_value(t, r.exec.path, "")
		testing.expect_value(t, r.log, gate.refusal_line(command, refusal, "192.0.2.20", context.allocator))
		testing.expectf(t, strings.has_prefix(r.stderr, "ravnix-laptop-gate: refused: ") && strings.has_suffix(r.stderr, "huginn answers only: ping, facts, battery, charge-mode, power\n"), "%q", r.stderr)
		testing.expect_value(t, strings.count(r.stderr, "\n"), 1)
	}
}

@(test)
sends_exactly_one_line_to_the_journal_for_a_refusal_and_none_for_an_answer :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	fd := listen_log(t, &f)
	defer linux.close(fd)
	for command in ([]string{"sh -c id", "sudo -n true", "", strings.repeat("q", 5000)}) {
		r := gate.answer(laptop_config(&f, command), context.allocator)
		got := logged(fd)
		testing.expectf(t, r.status == gate.REFUSED && len(got) == 1, "%q: %d, %v", command[:min(len(command), 20)], r.status, got)
		if len(got) == 1 {
			// authpriv.warning, under the gate's own name, as syslog(3) sends it.
			testing.expect_value(t, got[0], strings.concatenate({"<84>ravnix-laptop-gate: ", r.log}))
		}
	}
	for command in ([]string{"ping", "battery", "charge-mode", "power", "facts"}) {
		r := gate.answer(laptop_config(&f, command), context.allocator)
		got := logged(fd)
		testing.expectf(t, r.status == 0 && len(got) == 0, "%s: %d, %v", command, r.status, got)
	}
}

@(test)
refuses_without_a_journal_to_log_to :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// No dev/log at all, and one that nobody listens on.
	r := gate.answer(laptop_config(&f, "sudo -n true"), context.allocator)
	testing.expect_value(t, r.status, gate.REFUSED)
	write(t, &f, "dev/log", "")
	r = gate.answer(laptop_config(&f, "sudo -n true"), context.allocator)
	testing.expect_value(t, r.status, gate.REFUSED)
	testing.expect(t, strings.has_prefix(r.stderr, "ravnix-laptop-gate: refused: "))
}

@(test)
a_program_that_is_not_there_is_not_started :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	// Only ever a path that is not there: a start that works replaces the
	// test runner.
	errno := gate.start({path = "/no/such/dir/machine-facts", argv = {"/no/such/dir/machine-facts"}, env = {"PATH=/nowhere"}}, a)
	testing.expect_value(t, errno, linux.Errno.ENOENT)
}

@(test)
reads_its_arguments :: proc(t: ^testing.T) {
	cfg: gate.Config
	status, stop := gate.parse_args({}, &cfg)
	testing.expect(t, status == 0 && !stop)
	status, stop = gate.parse_args({"--command", "battery", "--root", "/tmp/r"}, &cfg)
	testing.expect(t, status == 0 && !stop && cfg.command == "battery" && cfg.root == "/tmp/r")
	status, stop = gate.parse_args({"--root"}, &cfg)
	testing.expect(t, status == gate.USAGE_ERROR && stop)
	status, stop = gate.parse_args({"--command"}, &cfg)
	testing.expect(t, status == gate.USAGE_ERROR && stop)
	status, stop = gate.parse_args({"ping"}, &cfg)
	testing.expect(t, status == gate.USAGE_ERROR && stop)
	status, stop = gate.parse_args({"--help"}, &cfg)
	testing.expect(t, status == 0 && stop)
}

Concurrent :: struct {
	root: string,
	out:  [8]string,
	arenas: [8]virtual.Arena,
}

@(test)
answers_the_same_from_eight_threads_at_once :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	c := Concurrent{root = f.root}
	threads: [8]^thread.Thread
	for i in 0 ..< 8 {
		threads[i] = thread.create_and_start_with_poly_data2(&c, i, proc(c: ^Concurrent, i: int) {
			_ = virtual.arena_init_growing(&c.arenas[i])
			a := virtual.arena_allocator(&c.arenas[i])
			c.out[i] = strings.concatenate({gate.battery(c.root, a), gate.power(c.root, a), gate.charge_mode(c.root, a)}, a)
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	want := strings.concatenate({gate.battery(f.root, context.allocator), gate.power(f.root, context.allocator), gate.charge_mode(f.root, context.allocator)})
	for i in 0 ..< 8 {
		testing.expectf(t, c.out[i] == want && want != "", "thread %d: %q", i, c.out[i])
		virtual.arena_destroy(&c.arenas[i])
	}
}

@(test)
a_journal_that_is_full_does_not_hold_up_a_refusal :: proc(t: ^testing.T) {
	// A refusal that waits on the log would hang the server's session, and
	// ravnix-laptop has no overall timeout.
	testing.set_fail_timeout(t, 10 * time.Second)
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	fd := listen_log(t, &f)
	defer linux.close(fd)
	// journald stalls: nobody reads, and the socket's queue fills up.
	sender, errno := linux.socket(.UNIX, .DGRAM, {}, .HOPOPT)
	testing.expect_value(t, errno, linux.Errno.NONE)
	defer linux.close(sender)
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	copy(addr.sun_path[:len(addr.sun_path) - 1], join(&f, "dev/log"))
	filler := strings.repeat("f", 1024)
	sent := 0
	for sent < 100_000 {
		_, errno = linux.sendto(sender, transmute([]u8)filler, {.DONTWAIT}, &addr)
		if errno != .NONE {
			break
		}
		sent += 1
	}
	testing.expectf(t, errno == .EAGAIN, "the queue did not fill: %v after %d", errno, sent)
	start := time.tick_now()
	r := gate.answer(laptop_config(&f, "sudo -n true"), context.allocator)
	testing.expect_value(t, r.status, gate.REFUSED)
	testing.expectf(t, time.tick_since(start) < 2 * time.Second, "the refusal took %v", time.tick_since(start))
}

@(test)
facts_fails_closed_without_an_absolute_machine_facts :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// A build without the define, and one with a bare name: execve would
	// look for it in the working directory, which is $HOME under sshd.
	for facts in ([]string{"", "machine-facts", "./machine-facts", "bin/machine-facts"}) {
		cfg := laptop_config(&f, "facts")
		cfg.facts = facts
		r := gate.decide(cfg, context.allocator)
		testing.expectf(t, r.status == gate.EXEC_FAILED && r.exec.path == "" && r.stdout == "" && r.log == "", "%q: %v", facts, r)
		testing.expectf(t, r.stderr == "ravnix-laptop-gate: facts is not available: built without the store path of machine-facts\n", "%q: %q", facts, r.stderr)
	}
}
