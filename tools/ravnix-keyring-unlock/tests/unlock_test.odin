// The unlock, against the stand-in bus: what the tool sends, in which
// order, and what it makes of every answer. The password reaches the
// daemon only when the keyring is locked, and nothing the tool prints ever
// holds it.
package ravnix_keyring_unlock_tests

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import kr ".."

PASSWORD :: "Pferd Batterie ü 42"

// unlock runs the tool's work against a fake bus with b, with the password
// in a credential file (or none when credential is false).
unlock :: proc(
	t: ^testing.T,
	b: Behavior,
	content: string = PASSWORD + "\n",
	credential := true,
	timeout := 2 * time.Second,
) -> (
	kr.Result,
	^Fake,
) {
	behavior := b
	if behavior.password == "" {
		behavior.password = PASSWORD
	}
	f := fake_start(t, behavior)
	path := ""
	if credential {
		path = write_file(t, f.dir, "ravnix-keyring-login", content)
	} else {
		path = strings.concatenate({f.dir, "/absent"}, context.temp_allocator)
	}
	r := kr.run(path, f.address, timeout, 1000)
	fake_stop(f)
	// The line for the journal never holds the password.
	testing.expectf(t, !strings.contains(kr.line(r), "Pferd"), "the line holds the password: %s", kr.line(r))
	testing.expectf(t, !strings.contains(r.detail, "Pferd"), "the detail holds the password: %s", r.detail)
	return r, f
}

expect_calls :: proc(t: ^testing.T, f: ^Fake, want: []string, loc := #caller_location) {
	testing.expectf(t, len(f.calls) == len(want), "calls %v, not %v", f.calls[:], want, loc = loc)
	if len(f.calls) == len(want) {
		for w, i in want {
			testing.expectf(t, f.calls[i] == w, "call %d is %s, not %s", i, f.calls[i], w, loc = loc)
		}
	}
}

@(test)
unlocks_a_locked_keyring :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true})
	defer fake_free(f)
	testing.expectf(t, r.outcome == .Unlocked, "%v: %s", r.outcome, r.detail)
	expect_calls(t, f, {"Hello", "Get", "OpenSession", "UnlockWithMasterPassword", "Get"})
	// The password as the file holds it, without the newline, in a plain
	// session, to the login collection.
	testing.expect_value(t, len(f.passwords), 1)
	if len(f.passwords) == 1 {
		testing.expect(t, f.passwords[0] == PASSWORD)
	}
	testing.expect_value(t, f.algorithm, "plain")
	testing.expect_value(t, f.collection, kr.LOGIN_COLLECTION)
	testing.expect_value(t, f.session, SESSION_PATH)
	testing.expect_value(t, f.content, "text/plain")
	// The login as uid 1000, hex of its digits.
	testing.expect_value(t, f.auth, "\x00AUTH EXTERNAL 31303030")
	// Every call but Hello goes to the Secret Service, and the bus may start
	// it: the daemon PAM started waits for that start (--login) to come up.
	testing.expect(t, !f.no_auto)
	for d, i in f.destination {
		want := "org.freedesktop.DBus" if i == 0 else "org.freedesktop.secrets"
		testing.expect_value(t, d, want)
	}
	testing.expect_value(t, kr.exit_code(r.outcome), 0)
}

@(test)
leaves_an_unlocked_keyring_alone :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = false})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Already_Unlocked)
	expect_calls(t, f, {"Hello", "Get"})
	testing.expect_value(t, len(f.passwords), 0)
	testing.expect_value(t, kr.exit_code(r.outcome), 0)
}

@(test)
reports_a_wrong_password_and_leaves_the_keyring_locked :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, password = "another one"})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Wrong_Password)
	expect_calls(t, f, {"Hello", "Get", "OpenSession", "UnlockWithMasterPassword"})
	testing.expect_value(t, kr.exit_code(r.outcome), 0)
	testing.expect_value(t, kr.priority(r.outcome), 4)
}

@(test)
does_nothing_without_a_credential :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true}, credential = false)
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.No_Credential)
	// It does not even connect: nothing to send, and no daemon started.
	testing.expect_value(t, f.connections, 0)
	testing.expect_value(t, kr.exit_code(r.outcome), 0)
}

@(test)
does_nothing_when_there_is_no_login_keyring :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{no_keyring = true})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.No_Keyring)
	expect_calls(t, f, {"Hello", "Get"})
	testing.expect_value(t, len(f.passwords), 0)
	testing.expect_value(t, kr.exit_code(r.outcome), 0)
}

@(test)
fails_on_a_broken_credential_before_connecting :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true}, content = "")
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expect_value(t, f.connections, 0)
	testing.expect_value(t, kr.exit_code(r.outcome), 1)
}

@(test)
fails_when_no_secret_service_can_start :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{no_service = true, locked = true})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expectf(t, strings.contains(r.detail, "ServiceUnknown"), "%s", r.detail)
	testing.expect_value(t, len(f.passwords), 0)
}

@(test)
fails_when_the_bus_refuses_the_login :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{auth_reply = "REJECTED EXTERNAL"})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expectf(t, strings.contains(r.detail, "REJECTED"), "%s", r.detail)
	expect_calls(t, f, {})
}

@(test)
fails_when_the_keyring_stays_locked :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, stays_locked = true})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	expect_calls(t, f, {"Hello", "Get", "OpenSession", "UnlockWithMasterPassword", "Get"})
}

@(test)
fails_on_another_unlock_error :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, unlock_error = "org.freedesktop.DBus.Error.UnknownMethod"})
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expectf(t, strings.contains(r.detail, "UnknownMethod"), "%s", r.detail)
}

@(test)
skips_signals_and_other_replies :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, noise = true})
	defer fake_free(f)
	testing.expectf(t, r.outcome == .Unlocked, "%v: %s", r.outcome, r.detail)
}

@(test)
reads_big_endian_replies :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, big_endian = true, noise = true})
	defer fake_free(f)
	testing.expectf(t, r.outcome == .Unlocked, "%v: %s", r.outcome, r.detail)
}

@(test)
gives_up_on_a_bus_that_does_not_answer :: proc(t: ^testing.T) {
	start := time.tick_now()
	r, f := unlock(t, Behavior{locked = true, hang_on = "OpenSession"}, timeout = 300 * time.Millisecond)
	defer fake_free(f)
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expectf(t, strings.contains(r.detail, "did not answer"), "%s", r.detail)
	testing.expect(t, time.tick_since(start) < 3 * time.Second)
	testing.expect_value(t, len(f.passwords), 0)
}

@(test)
fails_when_the_bus_hangs_up :: proc(t: ^testing.T) {
	for member in ([]string{"Hello", "Get", "UnlockWithMasterPassword"}) {
		r, f := unlock(t, Behavior{locked = true, close_on = member})
		testing.expectf(t, r.outcome == .Failed, "%s: %v", member, r.outcome)
		testing.expectf(t, strings.contains(r.detail, "closed"), "%s: %s", member, r.detail)
		fake_free(f)
	}
}

@(test)
refuses_a_reply_of_the_wrong_type_or_size :: proc(t: ^testing.T) {
	r, f := unlock(t, Behavior{locked = true, locked_type = "s"})
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expect_value(t, len(f.passwords), 0)
	fake_free(f)
	r, f = unlock(t, Behavior{locked = true, huge = true})
	testing.expect_value(t, r.outcome, kr.Outcome.Failed)
	testing.expectf(t, strings.contains(r.detail, "larger"), "%s", r.detail)
	fake_free(f)
}

@(test)
fails_without_a_bus :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	path := write_file(t, d, "c", PASSWORD)
	for address in ([]string{"", strings.concatenate({"unix:path=", d, "/no-bus"}, context.temp_allocator), "unix:abstract=/x"}) {
		r := kr.run(path, address, time.Second, 1000)
		testing.expectf(t, r.outcome == .Failed && r.detail != "", "%q: %v", address, r.outcome)
	}
}

@(test)
says_one_line_for_every_outcome :: proc(t: ^testing.T) {
	for o in kr.Outcome {
		l := kr.line(kr.Result{outcome = o, detail = "the detail"})
		testing.expectf(t, l != "" && !strings.contains(l, "\n"), "%v: %q", o, l)
		testing.expectf(t, strings.has_prefix(l, "ravnix-keyring-unlock: "), "%v: %q", o, l)
		p := kr.priority(o)
		testing.expect(t, p >= 3 && p <= 6)
	}
	testing.expect_value(t, kr.exit_code(.Failed), 1)
	testing.expect_value(t, kr.priority(.Failed), 3)
}
