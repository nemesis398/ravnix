// The tests of ravnix-tap-ask. Each one builds a system under a temporary
// root: /etc/passwd, the user's mapping, /sys/class/hidraw, the processes in
// /proc and the user's runtime directory with a real Unix socket for Wayland.
// The popup is a fake fuzzel behind a fake setpriv (testdata/), which record
// what they were given and answer as the fixture says.
package ravnix_tap_ask_tests

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import tap ".."

FAKE_SETPRIV :: #directory + "/testdata/fake-setpriv"
FAKE_FUZZEL :: #directory + "/testdata/fake-fuzzel"

UID :: 1000
GID :: 100
SUDO :: 4242
SHELL :: 4200

// A FIDO key's report descriptor starts with its usage page; a keyboard's
// with the generic desktop page (0x05 0x01).
FIDO_DESCRIPTOR :: "\x06\xd0\xf1\x09\x01\xa1\x01"
KEYBOARD_DESCRIPTOR :: "\x05\x01\x09\x06\xa1\x01"

Fixture :: struct {
	arena: virtual.Arena,
	dir:   string,
	root:  string,
	cfg:   tap.Config,
}

join :: proc(f: ^Fixture, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1)
	append(&all, f.dir)
	append(&all, ..parts)
	return strings.join(all[:], "/")
}

// make_dirs makes a directory and its parents, which may be there already.
make_dirs :: proc(t: ^testing.T, path: string) {
	err := os.make_directory_all(path)
	testing.expectf(t, err == nil || err == .Exist, "%s: %v", path, err)
}

write :: proc(t: ^testing.T, path, data: string) {
	make_dirs(t, path[:strings.last_index_byte(path, '/')])
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)data), nil)
}

// make_proc writes the /proc entries of a process the tool reads, in place of
// those of an earlier process with its pid.
make_proc :: proc(t: ^testing.T, f: ^Fixture, pid, ppid: int, comm: string, uid: int, exe := "", cmdline := "", environ := "") {
	base := join(f, "root/proc", fmt.aprint(pid))
	_ = os.remove_all(base)
	write(t, strings.join({base, "stat"}, "/"), fmt.aprintf("%d (%s) S %d %d %d 0 -1\n", pid, comm, ppid, pid, pid))
	write(t, strings.join({base, "comm"}, "/"), fmt.aprintf("%s\n", comm))
	write(t, strings.join({base, "status"}, "/"), fmt.aprintf("Name:\t%s\nUid:\t%d\t%d\t%d\t%d\n", comm, uid, uid, uid, uid))
	write(t, strings.join({base, "cmdline"}, "/"), cmdline)
	write(t, strings.join({base, "environ"}, "/"), environ)
	if exe != "" {
		testing.expect_value(t, os.symlink(exe, strings.join({base, "exe"}, "/")), nil)
	}
}

// make_socket binds a Unix socket at path, as a compositor does.
make_socket :: proc(t: ^testing.T, path: string) {
	make_dirs(t, path[:strings.last_index_byte(path, '/')])
	fd, errno := linux.socket(.UNIX, .STREAM, {}, .HOPOPT)
	testing.expect_value(t, errno, linux.Errno.NONE)
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	copy(addr.sun_path[:len(addr.sun_path) - 1], path)
	testing.expect_value(t, linux.bind(fd, &addr), linux.Errno.NONE)
	_ = linux.close(fd)
}

// set_case writes what the fake fuzzel does once it has recorded its input.
set_case :: proc(t: ^testing.T, f: ^Fixture, script: string) {
	write(t, join(f, "bin/fuzzel-case.sh"), script)
}

// fixture is a system where everything is in place: the user alice with a
// mapping, a FIDO key, no lock screen, a Wayland socket, and sudo run from a
// shell on a terminal. A test takes away what it is about.
fixture :: proc(t: ^testing.T, f: ^Fixture) {
	testing.expect_value(t, virtual.arena_init_growing(&f.arena), nil)
	context.allocator = virtual.arena_allocator(&f.arena)
	dir, err := os.make_directory_temp("", "tap-ask-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	f.dir = dir
	f.root = join(f, "root")

	write(t, join(f, "root/etc/passwd"), "root:x:0:0:System administrator:/root:/bin/sh\nmalformed line\nalice:x:1000:100:Alice:/home/alice:/bin/sh\n")
	write(t, join(f, "root/home/alice/.config/Yubico/u2f_keys"), "alice:kh,pk,es256,+presence")
	write(t, join(f, "root/sys/class/hidraw/hidraw0/device/report_descriptor"), KEYBOARD_DESCRIPTOR)
	write(t, join(f, "root/sys/class/hidraw/hidraw1/device/report_descriptor"), FIDO_DESCRIPTOR)
	make_proc(t, f, 1, 0, "systemd", 0, "/nix/store/x-systemd/lib/systemd/systemd")
	make_proc(t, f, 900, 1, "sway", UID, "/nix/store/x-sway/bin/sway")
	make_proc(t, f, 950, 900, "ghostty", UID, "/nix/store/x-ghostty/bin/ghostty")
	make_proc(t, f, SHELL, 950, "bash", UID, "/nix/store/x-bash/bin/bash")
	make_proc(t, f, SUDO, SHELL, "sudo", UID, "/run/wrappers/wrappers.x/sudo", "sudo\x00systemctl\x00restart\x00nix-daemon\x00", "HOME=/home/alice\x00")
	make_socket(t, join(f, "root/run/user/1000/wayland-1"))
	write(t, join(f, "root/run/user/1000/wayland-1.lock"), "")

	make_dirs(t, join(f, "bin"))
	testing.expect_value(t, os.symlink(FAKE_SETPRIV, join(f, "bin/setpriv")), nil)
	testing.expect_value(t, os.symlink(FAKE_FUZZEL, join(f, "bin/fuzzel")), nil)
	set_case(t, f, "sleep 0.3; echo 1\n")

	f.cfg = tap.Config {
		root       = f.root,
		parent     = SUDO,
		user       = "alice",
		tty        = "/dev/pts/3",
		pam_type   = "auth",
		fuzzel     = join(f, "bin/fuzzel"),
		setpriv    = join(f, "bin/setpriv"),
		popup_path = os.get_env("PATH", context.allocator),
		timeout    = 3 * time.Second,
		min_read   = 100 * time.Millisecond,
	}
}

destroy :: proc(f: ^Fixture) {
	_ = os.remove_all(f.dir)
	virtual.arena_destroy(&f.arena)
}

read :: proc(f: ^Fixture, name: string) -> (string, bool) {
	data, err := os.read_entire_file(join(f, "bin", name), context.allocator)
	return string(data), err == nil
}

@(test)
prepares_a_popup_when_everything_is_there :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	req := tap.prepare(f.cfg, context.allocator)
	testing.expect_value(t, req.skip, tap.Skip.None)
	testing.expect_value(t, req.uid, UID)
	testing.expect_value(t, req.gid, GID)
	testing.expect_value(t, req.home, "/home/alice")
	testing.expect_value(t, req.wayland, "wayland-1")
	testing.expect_value(t, req.runtime_dir, join(&f, "root/run/user/1000"))
	testing.expect_value(t, req.command, "sudo systemctl restart nix-daemon")
	testing.expect_value(t, req.origin.kind, tap.Origin_Kind.Terminal)
	testing.expect_value(t, req.origin.tty, "/dev/pts/3")
}

@(test)
skips_what_is_not_auth :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	for kind in ([]string{"account", "session", "password", ""}) {
		f.cfg.pam_type = kind
		testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.Not_Auth)
	}
}

@(test)
skips_an_unknown_or_odd_user :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	for user in ([]string{"bob", "", "alice:x", "ali", "malformed line"}) {
		f.cfg.user = user
		testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_User)
	}
	// No passwd at all.
	f.cfg.user = "alice"
	testing.expect_value(t, os.remove(join(&f, "root/etc/passwd")), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_User)
}

@(test)
skips_without_a_mapping :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	keys := join(&f, "root/home/alice/.config/Yubico/u2f_keys")

	write(t, keys, "")
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Mapping)
	testing.expect_value(t, os.remove(keys), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Mapping)
	// A directory in its place.
	testing.expect_value(t, os.make_directory(keys), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Mapping)
}

@(test)
skips_without_a_fido_key :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	// The keyboard alone is no key.
	testing.expect_value(t, os.remove_all(join(&f, "root/sys/class/hidraw/hidraw1")), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Key)
	// No hidraw device at all.
	testing.expect_value(t, os.remove_all(join(&f, "root/sys/class/hidraw")), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Key)
}

@(test)
skips_while_the_screen_is_locked :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)

	// Another user's swaylock does not lock this user's screen.
	make_proc(t, &f, 5000, 900, "swaylock", 1001)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.None)

	make_proc(t, &f, 5001, 900, ".swaylock-wrapp", UID)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.Locked)
	testing.expect_value(t, os.remove_all(join(&f, "root/proc/5001")), nil)
	make_proc(t, &f, 5002, 900, "swaylock", UID)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.Locked)
}

@(test)
skips_without_a_graphical_session :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	run_dir := join(&f, "root/run/user/1000")

	// A file of the socket's name, left behind, is no session; nor is the
	// lock file alone.
	testing.expect_value(t, os.remove(strings.join({run_dir, "wayland-1"}, "/")), nil)
	write(t, strings.join({run_dir, "wayland-1"}, "/"), "")
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Session)
	testing.expect_value(t, os.remove(strings.join({run_dir, "wayland-1"}, "/")), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Session)
	// A socket of another name.
	make_socket(t, strings.join({run_dir, "wayland-x"}, "/"))
	make_socket(t, strings.join({run_dir, "wayland-01"}, "/"))
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Session)
	// No runtime directory.
	testing.expect_value(t, os.remove_all(run_dir), nil)
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).skip, tap.Skip.No_Session)
}

@(test)
takes_the_lowest_wayland_socket :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	make_socket(t, join(&f, "root/run/user/1000/wayland-12"))
	make_socket(t, join(&f, "root/run/user/1000/wayland-0"))
	testing.expect_value(t, tap.prepare(f.cfg, context.allocator).wayland, "wayland-0")
}

@(test)
names_a_terminal :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	o := tap.origin_of(f.cfg, context.allocator)
	testing.expect_value(t, o.kind, tap.Origin_Kind.Terminal)
	testing.expect_value(t, o.tty, "/dev/pts/3")
	testing.expect(t, strings.contains(tap.origin_text(o, context.allocator), "a terminal on this laptop, /dev/pts/3"))
}

@(test)
names_an_ssh_ancestor_even_with_a_terminal :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// sshd, its per-connection sshd-session, a shell, `script` for a
	// terminal, a shell, sudo.
	make_proc(t, &f, 700, 1, "sshd", 0, "/nix/store/x-openssh/bin/sshd")
	make_proc(t, &f, 710, 700, "sshd-session", 0, "/nix/store/x-openssh/libexec/sshd-session")
	make_proc(t, &f, 720, 710, "bash", UID, "/nix/store/x-bash/bin/bash")
	make_proc(t, &f, 730, 720, "script", UID, "/nix/store/x-util-linux/bin/script")
	make_proc(t, &f, SHELL, 730, "bash", UID, "/nix/store/x-bash/bin/bash")
	o := tap.origin_of(f.cfg, context.allocator)
	testing.expect_value(t, o.kind, tap.Origin_Kind.Ssh)
	testing.expect_value(t, tap.origin_text(o, context.allocator), "ssh (the server's laptop-access link)")
}

@(test)
names_ssh_by_the_program_not_the_name_it_gives_itself :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// sshd-session titles itself "sshd: alice@notty", its comm is its own.
	make_proc(t, &f, 710, 1, "sshd: alice@no", 0, "/nix/store/x-openssh/libexec/sshd-session")
	make_proc(t, &f, SHELL, 710, "bash", UID, "/nix/store/x-bash/bin/bash")
	f.cfg.tty = ""
	testing.expect_value(t, tap.origin_of(f.cfg, context.allocator).kind, tap.Origin_Kind.Ssh)
}

@(test)
names_ssh_by_its_environment :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	testing.expect_value(t, os.remove_all(join(&f, "root/proc", fmt.aprint(SUDO))), nil)
	make_proc(t, &f, SUDO, SHELL, "sudo", UID, "/run/wrappers/wrappers.x/sudo", "sudo\x00true\x00", "HOME=/home/alice\x00SSH_CONNECTION=100.64.0.2 52044 100.64.0.1 22\x00")
	f.cfg.tty = ""
	o := tap.origin_of(f.cfg, context.allocator)
	testing.expect_value(t, o.kind, tap.Origin_Kind.Ssh)
	testing.expect_value(t, o.client, "100.64.0.2")
	testing.expect_value(t, tap.origin_text(o, context.allocator), "ssh from 100.64.0.2 (the server's laptop-access link)")
}

@(test)
names_a_program_without_a_terminal :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	testing.expect_value(t, os.remove_all(join(&f, "root/proc", fmt.aprint(SHELL))), nil)
	make_proc(t, &f, SHELL, 900, "some\nthing", UID, "/nix/store/x/bin/thing")
	f.cfg.tty = ""
	o := tap.origin_of(f.cfg, context.allocator)
	testing.expect_value(t, o.kind, tap.Origin_Kind.No_Terminal)
	testing.expect_value(t, tap.origin_text(o, context.allocator), "a program without a terminal, some?thing")
}

@(test)
stops_at_a_loop_in_the_process_tree :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	testing.expect_value(t, os.remove_all(join(&f, "root/proc", fmt.aprint(SHELL))), nil)
	make_proc(t, &f, SHELL, 4300, "bash", UID)
	make_proc(t, &f, 4300, SHELL, "bash", UID)
	testing.expect_value(t, tap.origin_of(f.cfg, context.allocator).kind, tap.Origin_Kind.Terminal)
	// A sudo whose parent is gone.
	testing.expect_value(t, os.remove_all(join(&f, "root/proc")), nil)
	f.cfg.tty = ""
	o := tap.origin_of(f.cfg, context.allocator)
	testing.expect_value(t, o.kind, tap.Origin_Kind.No_Terminal)
	testing.expect_value(t, o.process, "")
}

@(test)
shows_the_command_safely :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	cmdline := join(&f, "root/proc", fmt.aprint(SUDO), "cmdline")

	// A newline or an escape in an argument cannot start a line of its own.
	write(t, cmdline, "sudo\x00sh\x00-c\x00echo hi\nfrom     a terminal\x1b[2J\x00")
	testing.expect_value(t, tap.command_of(f.cfg, context.allocator), "sudo sh -c echo hi?from     a terminal?[2J")
	// A long one is cut, at a character.
	write(t, cmdline, strings.concatenate({"sudo\x00", strings.repeat("ä", 300)}))
	command := tap.command_of(f.cfg, context.allocator)
	testing.expect(t, len(command) <= tap.MAX_COMMAND + len("…"))
	testing.expect(t, strings.has_suffix(command, "ä…"))
	// None at all.
	write(t, cmdline, "")
	testing.expect_value(t, tap.command_of(f.cfg, context.allocator), "(unknown)")
	// Invalid UTF-8.
	write(t, cmdline, "sudo\x00\xff\xfe\x00")
	testing.expect_value(t, tap.command_of(f.cfg, context.allocator), "sudo ��")
}

@(test)
the_popup_says_what_who_and_from_where :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	req := tap.prepare(f.cfg, context.allocator)
	m := tap.message(req, context.allocator)
	testing.expect(t, strings.contains(m, "command  sudo systemctl restart nix-daemon\n"), m)
	testing.expect(t, strings.contains(m, "user     alice\n"), m)
	testing.expect(t, strings.contains(m, "from     a terminal on this laptop, /dev/pts/3\n"), m)
	testing.expect(t, !strings.contains(m, "PIN"), m)
}

@(test)
runs_fuzzel_as_the_user_with_the_session_alone :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	req := tap.prepare(f.cfg, context.allocator)
	command := tap.popup_command(f.cfg, req, context.allocator)
	testing.expect_value(t, command[0], f.cfg.setpriv)
	testing.expect_value(t, strings.join(command[1:7], " "), strings.join({"--reuid=1000 --regid=100 --clear-groups --no-new-privs --", f.cfg.fuzzel}, " "))
	for flag in ([]string{"--dmenu", "--index", "--only-match", "--layer=overlay"}) {
		found := false
		for arg in command {
			found ||= arg == flag
		}
		testing.expect(t, found, flag)
	}
	env := tap.popup_env(f.cfg, req, context.allocator)
	testing.expect_value(t, len(env), 7)
	testing.expect_value(t, env[0], "WAYLAND_DISPLAY=wayland-1")
	testing.expect_value(t, env[1], strings.concatenate({"XDG_RUNTIME_DIR=", join(&f, "root/run/user/1000")}))
	testing.expect_value(t, env[2], "HOME=/home/alice")
}

// popup runs the whole decision with the fake popup doing what script says.
popup :: proc(t: ^testing.T, f: ^Fixture, script: string) -> tap.Decision {
	set_case(t, f, script)
	return tap.decide(f.cfg, context.allocator)
}

@(test)
allow_lets_pam_u2f_run :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	d := popup(t, &f, "sleep 0.3; echo 1\n")
	testing.expect_value(t, d, tap.Decision{skip = .None, answer = .Allow})
	testing.expect(t, tap.allowed(d))

	// The popup got the two entries, Deny first, and the user's session
	// and nothing else of this process's environment.
	stdin, _ := read(&f, "fuzzel-stdin")
	testing.expect_value(t, stdin, "Deny\nAllow\n")
	env, _ := read(&f, "fuzzel-env")
	testing.expect(t, strings.contains(env, "WAYLAND_DISPLAY=wayland-1\n"), env)
	testing.expect(t, strings.contains(env, "HOME=/home/alice\n"), env)
	testing.expect(t, !strings.contains(env, "PAM_"), env)
	testing.expect(t, !strings.contains(env, "TMPDIR"), env)
	args, _ := read(&f, "setpriv-args")
	testing.expect(t, strings.has_prefix(args, "--reuid=1000\n--regid=100\n--clear-groups\n--no-new-privs\n--\n"), args)
}

@(test)
deny_and_its_kin_skip_pam_u2f :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	cases := []struct {
		script: string,
		answer: tap.Answer,
	} {
		{"sleep 0.3; echo 0\n", .Deny},
		// Esc, or focus lost: fuzzel exits 1 with nothing.
		{"exit 1\n", .Deny},
		// Allow before the popup can be read.
		{"echo 1\n", .Too_Soon},
		// fuzzel never prints these.
		{"sleep 0.3; echo '1 1'\n", .Failed},
		{"sleep 0.3; echo 2\n", .Failed},
		{"sleep 0.3; echo 1; exit 3\n", .Failed},
		{"sleep 0.3; echo Allow\n", .Failed},
		{"sleep 0.3; head -c 10000 /dev/zero\n", .Failed},
		{"kill -9 $$\n", .Failed},
	}
	for c in cases {
		d := popup(t, &f, c.script)
		testing.expectf(t, d.answer == c.answer, "%q: %v, not %v", c.script, d.answer, c.answer)
		testing.expect(t, !tap.allowed(d), c.script)
	}
}

@(test)
no_answer_in_time_skips_pam_u2f_and_closes_the_popup :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	f.cfg.timeout = 500 * time.Millisecond
	start := time.tick_now()
	d := popup(t, &f, "exec sleep 30\n")
	elapsed := time.tick_since(start)
	testing.expect_value(t, d.answer, tap.Answer.Timeout)
	testing.expect(t, !tap.allowed(d))
	testing.expectf(t, elapsed < 5 * time.Second, "it took %v", elapsed)
}

@(test)
a_popup_that_does_not_start_skips_pam_u2f :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	f.cfg.setpriv = join(&f, "bin/no-such-setpriv")
	d := tap.decide(f.cfg, context.allocator)
	testing.expect(t, !tap.allowed(d))
}

@(test)
no_popup_where_there_is_nothing_to_ask :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// A popup that would allow, never started: no session, then a locked
	// screen.
	set_case(t, &f, "sleep 0.3; echo 1\n")
	testing.expect_value(t, os.remove(join(&f, "root/run/user/1000/wayland-1")), nil)
	d := tap.decide(f.cfg, context.allocator)
	testing.expect_value(t, d.skip, tap.Skip.No_Session)
	testing.expect(t, !tap.allowed(d))
	make_socket(t, join(&f, "root/run/user/1000/wayland-1"))
	make_proc(t, &f, 5002, 900, "swaylock", UID)
	d = tap.decide(f.cfg, context.allocator)
	testing.expect_value(t, d.skip, tap.Skip.Locked)
	testing.expect(t, !tap.allowed(d))
	_, started := read(&f, "fuzzel-stdin")
	testing.expect(t, !started, "the popup ran")
}

@(test)
ssh_without_a_terminal_reaches_the_key_only_through_allow :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer destroy(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// The server's link: sshd-session, a shell without a terminal, sudo.
	make_proc(t, &f, 710, 1, "sshd-session", 0, "/nix/store/x-openssh/libexec/sshd-session")
	make_proc(t, &f, SHELL, 710, "bash", UID, "/nix/store/x-bash/bin/bash")
	f.cfg.tty = ""
	f.cfg.timeout = 500 * time.Millisecond
	testing.expect(t, !tap.allowed(popup(t, &f, "exec sleep 30\n")))
	testing.expect(t, !tap.allowed(popup(t, &f, "sleep 0.3; echo 0\n")))
	testing.expect(t, !tap.allowed(popup(t, &f, "echo 1\n")))
	f.cfg.timeout = 3 * time.Second
	testing.expect(t, tap.allowed(popup(t, &f, "sleep 0.3; echo 1\n")))
	args, _ := read(&f, "fuzzel-args")
	testing.expect(t, strings.contains(args, "from     ssh (the server's laptop-access link)\n"), args)
}
