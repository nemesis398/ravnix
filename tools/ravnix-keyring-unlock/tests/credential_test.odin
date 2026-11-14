// The credential: the password as systemd hands it to the service, in a
// file of $CREDENTIALS_DIRECTORY. Missing is a normal state (no setup yet);
// anything else that is not a password is refused.
package ravnix_keyring_unlock_tests

import "core:os"
import "core:strings"
import "core:testing"
import kr ".."

@(test)
reads_the_password :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	cases := [][2]string {
		{"correct horse", "correct horse"},
		// systemd-ask-password -n writes no newline; echo does, and one is
		// taken off, because no login password ends in one.
		{"correct horse\n", "correct horse"},
		{"two\n\n", "two\n"},
		{"Schlüssel ü =;#", "Schlüssel ü =;#"},
		{" leading and trailing ", " leading and trailing "},
	}
	for c, i in cases {
		path := write_file(t, d, "c", c[0])
		pw, status, why := kr.read_credential(path, context.allocator)
		testing.expectf(t, status == .Ok, "case %d: %v %s", i, status, why)
		testing.expect_value(t, string(pw), c[1])
		kr.wipe(pw)
		delete(pw)
	}
}

@(test)
takes_a_missing_credential_as_not_set_up :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	for path in ([]string{"", strings.concatenate({d, "/no-such-credential"}, context.temp_allocator)}) {
		pw, status, _ := kr.read_credential(path, context.allocator)
		testing.expect_value(t, status, kr.Credential_Status.Missing)
		testing.expect(t, pw == nil)
	}
}

@(test)
refuses_what_is_not_a_password :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	huge := strings.repeat("x", kr.MAX_PASSWORD + 1, context.temp_allocator)
	cases := []string{"", "\n", "Pferd\x00Pferd", huge}
	for c, i in cases {
		path := write_file(t, d, "bad", c)
		pw, status, why := kr.read_credential(path, context.allocator)
		testing.expectf(t, status == .Failed && why != "", "case %d: %v", i, status)
		testing.expect(t, pw == nil)
		// The message never holds what the file holds.
		testing.expect(t, !strings.contains(why, "Pferd"))
		testing.expect(t, !strings.contains(why, "xxxx"))
	}
	// The longest password there is still passes.
	path := write_file(t, d, "max", strings.repeat("y", kr.MAX_PASSWORD, context.temp_allocator))
	pw, status, _ := kr.read_credential(path, context.allocator)
	testing.expect_value(t, status, kr.Credential_Status.Ok)
	testing.expect_value(t, len(pw), kr.MAX_PASSWORD)
	delete(pw)
	// A directory where the file should be.
	dir := strings.concatenate({d, "/dir"}, context.temp_allocator)
	testing.expect(t, os.make_directory(dir) == nil)
	pw, status, _ = kr.read_credential(dir, context.allocator)
	testing.expect_value(t, status, kr.Credential_Status.Failed)
	testing.expect(t, pw == nil)
}

@(test)
refuses_an_unreadable_credential :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	path := write_file(t, d, "locked", "secret")
	testing.expect(t, os.chmod(path, {}) == nil)
	defer os.chmod(path, {.Read_User, .Write_User})
	// Root reads it anyway; the case is only for a user.
	if os.get_uid() == 0 {
		return
	}
	pw, status, why := kr.read_credential(path, context.allocator)
	testing.expect_value(t, status, kr.Credential_Status.Failed)
	testing.expect(t, strings.contains(why, "permission denied"))
	testing.expect(t, pw == nil)
}
