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
