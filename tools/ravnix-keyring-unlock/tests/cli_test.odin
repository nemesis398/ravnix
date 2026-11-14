// The command: its arguments, where it finds the credential and the bus,
// and the journal's priority prefix, which it writes only when its
// standard error is the journal.
package ravnix_keyring_unlock_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import kr ".."

cli :: proc(t: ^testing.T, args: []string, env: kr.Env) -> (code: int, out: string) {
	d := scratch(t)
	defer os.remove_all(d)
	path := strings.concatenate({d, "/stderr"}, context.temp_allocator)
	f, err := os.create(path)
	if err != nil {
		testing.fail_now(t, "cannot create the stderr file")
	}
	code = kr.cli(args, env, f)
	os.close(f)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return code, string(data)
}

@(test)
refuses_bad_usage :: proc(t: ^testing.T) {
	cases := [][]string{{"--credential"}, {"--bus"}, {"--frobnicate"}, {"extra"}, {"--credential", "a", "--credential", "b"}}
	for args in cases {
		code, out := cli(t, args, {})
		testing.expectf(t, code == 2, "%v: exit %d", args, code)
		testing.expectf(t, strings.contains(out, "usage"), "%v: %q", args, out)
	}
	code, out := cli(t, {"--help"}, {})
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "usage"))
}

@(test)
finds_the_credential_in_the_credentials_directory :: proc(t: ^testing.T) {
	f := fake_start(t, Behavior{locked = true, password = PASSWORD})
	write_file(t, f.dir, kr.CREDENTIAL_NAME, PASSWORD)
	code, out := cli(t, {}, kr.Env{credentials_directory = f.dir, bus_address = f.address})
	fake_stop(f)
	defer fake_free(f)
	testing.expect_value(t, code, 0)
	testing.expectf(t, strings.contains(out, "unlocked the login keyring"), "%q", out)
	// One line, and no prefix: this stderr is a file, not the journal.
	testing.expect_value(t, strings.count(out, "\n"), 1)
	testing.expect(t, !strings.has_prefix(out, "<"))
	testing.expect(t, !strings.contains(out, "Pferd"))
}

@(test)
says_so_without_a_credentials_directory :: proc(t: ^testing.T) {
	code, out := cli(t, {}, kr.Env{bus_address = "unix:path=/nonexistent/bus"})
	testing.expect_value(t, code, 0)
	testing.expectf(t, strings.contains(out, "no credential"), "%q", out)
	testing.expect_value(t, strings.count(out, "\n"), 1)
}

@(test)
an_explicit_credential_wins :: proc(t: ^testing.T) {
	f := fake_start(t, Behavior{locked = false})
	path := write_file(t, f.dir, "other", PASSWORD)
	code, out := cli(t, {"--credential", path, "--bus", f.address}, kr.Env{credentials_directory = "/nonexistent"})
	fake_stop(f)
	defer fake_free(f)
	testing.expect_value(t, code, 0)
	testing.expectf(t, strings.contains(out, "already unlocked"), "%q", out)
}

@(test)
prefixes_the_priority_only_for_the_journal :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	path := write_file(t, d, "stream", "")
	f, err := os.open(path)
	testing.expect(t, err == nil)
	defer os.close(f)
	fd := linux.Fd(os.fd(f))
	st: linux.Stat
	testing.expect(t, linux.fstat(fd, &st) == .NONE)
	same := fmt.tprintf("%d:%d", u64(st.dev), u64(st.ino))
	testing.expect(t, kr.journal_prefix(same, fd))
	testing.expect(t, !kr.journal_prefix("", fd))
	testing.expect(t, !kr.journal_prefix(fmt.tprintf("%d:%d", u64(st.dev), u64(st.ino) + 1), fd))
	testing.expect(t, !kr.journal_prefix("garbage", fd))
	testing.expect(t, !kr.journal_prefix("1:", fd))
}

@(test)
refuses_bad_usage_of_setup :: proc(t: ^testing.T) {
	cases := [][]string {
		{"setup", "--item"},
		{"setup", "--bus"},
		{"setup", "--item", "a", "--item", "b"},
		{"setup", "--credential", "x"},
		{"setup", "extra"},
		// setup is a command, not an argument anywhere else.
		{"--bus", "x", "setup"},
	}
	for args in cases {
		code, out := cli(t, args, {})
		testing.expectf(t, code == 2, "%v: exit %d", args, code)
		testing.expectf(t, strings.contains(out, "usage"), "%v: %q", args, out)
	}
	code, out := cli(t, {"setup", "--help"}, {})
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "setup [--item NAME]"))
}

// No program is on these paths, so a run that got further than it should
// fails instead of reaching the real rbw.
NO_PROGRAMS :: kr.Programs {
	rbw          = "/nonexistent/rbw",
	ask_password = "/nonexistent/systemd-ask-password",
	creds        = "/nonexistent/systemd-creds",
	chkpwd       = "/nonexistent/unix_chkpwd",
}

@(test)
setup_needs_an_item_and_a_home :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	code, out := cli(t, {"setup"}, kr.Env{home = d, programs = NO_PROGRAMS})
	testing.expect_value(t, code, 1)
	testing.expectf(t, strings.contains(out, "ravnix.desktop.keyring.autoUnlock.rbwItem"), "%q", out)
	testing.expect_value(t, strings.count(out, "\n"), 1)
	for home in ([]string{"", "relative"}) {
		code, out = cli(t, {"setup"}, kr.Env{home = home, rbw_item = ITEM, programs = NO_PROGRAMS})
		testing.expect_value(t, code, 1)
		testing.expectf(t, strings.contains(out, "HOME"), "%q", out)
	}
	// rbw that is not there: said, and nothing else runs.
	code, out = cli(t, {"setup"}, kr.Env{home = d, rbw_item = ITEM, programs = NO_PROGRAMS})
	testing.expect_value(t, code, 1)
	testing.expectf(t, strings.contains(out, "rbw is not installed"), "%q", out)
	testing.expect(t, !os.exists(strings.concatenate({d, "/.config"}, context.temp_allocator)))
}

@(test)
setup_takes_the_item_from_the_environment_or_the_argument :: proc(t: ^testing.T) {
	for args in ([][]string{{"setup"}, {"setup", "--item", "Another item"}}) {
		r := rig_start(t, Behavior{locked = true, password = NEW}, typed = ABSENT)
		home := join(r.dir, "home")
		env := kr.Env {
			home = home,
			bus_address = r.fake.address,
			rbw_item = ITEM,
			programs = {rbw = r.s.rbw, ask_password = r.s.ask_password, creds = r.s.creds, chkpwd = r.s.chkpwd},
			user = USER,
		}
		code, out := cli(t, args, env)
		fake_stop(r.fake)
		want := ITEM if len(args) == 1 else "Another item"
		testing.expectf(t, code == 0, "%v: exit %d: %s", args, code, out)
		testing.expectf(t, strings.contains(read(join(r.dir, "log")), fmt.tprintf("rbw [get] [--] [%s]", want)), "%v: %v", args, ran(&r))
		testing.expectf(t, strings.has_suffix(out, "\n") && strings.contains(out, "ravnix-keyring-unlock setup: "), "%q", out)
		testing.expect(t, !strings.contains(out, "Pferd"))
		testing.expect_value(t, read(kr.setup_credential_path(home)), stored(NEW))
		rig_free(&r)
	}
}
