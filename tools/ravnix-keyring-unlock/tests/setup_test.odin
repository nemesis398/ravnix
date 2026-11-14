// The setup command, against the stand-in bus and stand-ins for rbw,
// systemd-ask-password and systemd-creds (testdata/fake): what it sends and
// runs, in which order; every refusal, which changes nothing; a run that
// died between the keyring and the credential, and the run that repairs it;
// and the credential file it writes. No password ever reaches an argument,
// an environment, the file in the clear or a line it prints.
package ravnix_keyring_unlock_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import kr ".."

STUB :: #directory + "/testdata/fake"
// The Bitwarden item's password, which the keyring has after the setup. The
// keyring's password before it is PASSWORD (unlock_test.odin). Both hold
// "Pferd", which no output may.
NEW :: "Neues Pferd ü 7 Batterie"
ITEM :: "GNOME Keyring - login (test)"
// A stand-in's file the test does not write: rbw get or the prompt fails.
ABSENT :: "\x01absent"
// The user's login password, which unix_chkpwd knows, and the user's name.
LOGIN :: "das Login-Pferd"
USER :: "alice"

Rig :: struct {
	fake:       ^Fake,
	// The stand-ins and their files.
	dir:        string,
	credential: string,
	messages:   string,
	s:          kr.Setup,
}

join :: proc(parts: ..string) -> string {
	return strings.join(parts, "/", context.temp_allocator)
}

read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return "" if err != nil else string(data)
}

rot13 :: proc(s: string) -> string {
	b := transmute([]u8)strings.clone(s, context.temp_allocator)
	for &c in b {
		switch c {
		case 'a' ..= 'z':
			c = 'a' + (c - 'a' + 13) % 26
		case 'A' ..= 'Z':
			c = 'A' + (c - 'A' + 13) % 26
		}
	}
	return string(b)
}

// stored is what the stand-in for systemd-creds makes of a password.
stored :: proc(password: string) -> string {
	return strings.concatenate({"fake:", rot13(password)}, context.temp_allocator)
}

// rig_start makes the bus with b, the stand-ins, and a setup that writes its
// credential in a home of its own. item is what rbw get prints, typed what
// the prompt gives.
rig_start :: proc(t: ^testing.T, b: Behavior, item: string = NEW + "\n", typed: string = PASSWORD, login: string = LOGIN) -> Rig {
	behavior := b
	if behavior.password == "" {
		behavior.password = PASSWORD
	}
	r: Rig
	r.dir = strings.clone(scratch(t))
	r.fake = fake_start(t, behavior)
	for name in ([]string{"rbw", "systemd-ask-password", "systemd-creds", "unix_chkpwd"}) {
		if os.symlink(STUB, join(r.dir, name)) != nil {
			testing.fail_now(t, "cannot link a stand-in")
		}
	}
	if item != ABSENT {
		write_file(t, r.dir, "item", item)
	}
	if typed != ABSENT {
		write_file(t, r.dir, "typed", typed)
	}
	if login != ABSENT {
		write_file(t, r.dir, "login", login)
	}
	r.credential = strings.clone(join(r.dir, "home/.config/credstore.encrypted", kr.CREDENTIAL_NAME))
	r.messages = strings.clone(join(r.dir, "messages"))
	r.s = kr.Setup {
		item         = ITEM,
		bus          = r.fake.address,
		credential   = r.credential,
		rbw          = strings.clone(join(r.dir, "rbw")),
		ask_password = strings.clone(join(r.dir, "systemd-ask-password")),
		creds        = strings.clone(join(r.dir, "systemd-creds")),
		chkpwd       = strings.clone(join(r.dir, "unix_chkpwd")),
		user         = USER,
		timeout      = 2 * time.Second,
		uid          = u32(linux.getuid()),
	}
	return r
}

rig_free :: proc(r: ^Rig) {
	fake_free(r.fake)
	os.remove_all(r.dir)
	delete(r.dir)
	delete(r.credential)
	delete(r.messages)
	delete(r.s.rbw)
	delete(r.s.ask_password)
	delete(r.s.creds)
	delete(r.s.chkpwd)
}

// rig_run runs the setup and stops the bus, then checks that no password
// went where it must not.
rig_run :: proc(t: ^testing.T, r: ^Rig, loc := #caller_location) -> kr.Setup_Result {
	f, err := os.create(r.messages)
	if err != nil {
		testing.fail_now(t, "cannot create the messages file")
	}
	r.s.messages = f
	res := kr.setup(r.s)
	os.close(f)
	r.s.messages = nil
	fake_stop(r.fake)
	texts := [][2]string {
		{"the line", kr.setup_line(res)},
		{"what it printed", read(r.messages)},
		{"the arguments", read(join(r.dir, "log"))},
		{"rbw's environment", read(join(r.dir, "env.rbw"))},
		{"the prompt's environment", read(join(r.dir, "env.systemd-ask-password"))},
		{"systemd-creds' environment", read(join(r.dir, "env.systemd-creds"))},
		{"the credential", read(r.credential)},
	}
	for x in texts {
		testing.expectf(t, !strings.contains(x[1], "Pferd"), "%s holds a password: %q", x[0], x[1], loc = loc)
		testing.expectf(t, !strings.contains(x[1], "xxxxxxxx"), "%s holds the item: %q", x[0], x[1], loc = loc)
	}
	testing.expectf(t, !strings.contains(kr.setup_line(res), "\n"), "the line is not one line: %q", kr.setup_line(res), loc = loc)
	return res
}

ran :: proc(r: ^Rig) -> []string {
	return strings.split_lines(strings.trim_right(read(join(r.dir, "log")), "\n"), context.temp_allocator)
}

asked :: proc(r: ^Rig) -> int {
	n := 0
	for l in ran(r) {
		if strings.has_prefix(l, "systemd-ask-password ") {
			n += 1
		}
	}
	return n
}

ran_creds :: proc(r: ^Rig) -> bool {
	return strings.contains(read(join(r.dir, "log")), "systemd-creds")
}

expect_changes :: proc(t: ^testing.T, f: ^Fake, want: [][2]string, loc := #caller_location) {
	testing.expectf(t, len(f.changes) == len(want), "changes %v, not %v", f.changes[:], want, loc = loc)
	if len(f.changes) == len(want) {
		for w, i in want {
			testing.expectf(t, f.changes[i] == w, "change %d is %v, not %v", i, f.changes[i], w, loc = loc)
		}
	}
}

mode_of :: proc(path: string) -> u32 {
	st: linux.Stat
	if linux.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return 0xffffffff
	}
	return transmute(u32)st.mode & 0o7777
}

// The files in the credential's directory, so that no temporary file stays.
files_in :: proc(dir: string) -> []string {
	f, err := os.open(dir)
	if err != nil {
		return nil
	}
	defer os.close(f)
	infos, _ := os.read_dir(f, -1, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for i in infos {
		append(&names, i.name)
	}
	return names[:]
}

@(test)
sets_up_a_locked_keyring :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true})
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expectf(t, res.outcome == .Changed, "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, kr.setup_exit_code(res.outcome), 0)
	testing.expect_value(t, r.fake.current, NEW)
	// First the check whether the keyring has the item's password already,
	// then the change from the typed one, then the check with the password
	// the credential decrypts to. ChangeWithMasterPassword is the check: an
	// unlocked collection would take any password for an unlock.
	expect_changes(t, r.fake, {{NEW, NEW}, {PASSWORD, NEW}, {NEW, NEW}})
	expect_calls(
		t,
		r.fake,
		{
			"Hello",
			"Get",
			"OpenSession",
			"ChangeWithMasterPassword",
			"ChangeWithMasterPassword",
			"ChangeWithMasterPassword",
			"Get",
			"UnlockWithMasterPassword",
			"Get",
		},
	)
	// It leaves the keyring open for this session, with the new password.
	testing.expect(t, !r.fake.was_locked)
	testing.expect_value(t, len(r.fake.passwords), 1)
	if len(r.fake.passwords) == 1 {
		testing.expect(t, r.fake.passwords[0] == NEW)
	}
	// The programs, with these arguments and no password among them.
	log := ran(&r)
	testing.expectf(t, len(log) == 6, "it ran %v", log)
	if len(log) == 6 {
		testing.expect_value(t, log[0], "rbw [unlocked]")
		testing.expect_value(t, log[1], "rbw [get] [--] [" + ITEM + "]")
		testing.expect_value(t, log[2], "unix_chkpwd [" + USER + "] [nonull]")
		testing.expectf(t, strings.has_prefix(log[3], "systemd-ask-password [-n] "), "%s", log[3])
		testing.expect_value(t, log[4], "systemd-creds [--user] [encrypt] [--name=ravnix-keyring-login] [-] [-]")
		want := fmt.tprintf("systemd-creds [--user] [decrypt] [--name=ravnix-keyring-login] [%s] [-]", r.credential)
		testing.expect_value(t, log[5], want)
	}
	// unix_chkpwd got the item's password and a NUL, as pam_unix sends it.
	testing.expect_value(t, read(join(r.dir, "chkpwd.in")), NEW + "\x00")
	// systemd-creds got the password on its input, without rbw's newline.
	testing.expect_value(t, read(join(r.dir, "encrypt.in")), NEW)
	testing.expect_value(t, read(r.credential), stored(NEW))
	dir := join(r.dir, "home/.config/credstore.encrypted")
	testing.expect_value(t, mode_of(r.credential), 0o600)
	testing.expect_value(t, mode_of(dir), 0o700)
	testing.expect_value(t, mode_of(join(r.dir, "home/.config")), 0o700)
	names := files_in(dir)
	testing.expectf(t, len(names) == 1 && names[0] == kr.CREDENTIAL_NAME, "the directory holds %v", names)
	testing.expectf(t, strings.contains(res.detail, ITEM), "%s", res.detail)
	// It said what it asks for before it asked.
	testing.expectf(t, strings.contains(read(r.messages), "current password"), "%q", read(r.messages))
}

@(test)
sets_up_an_unlocked_keyring :: proc(t: ^testing.T) {
	// A password login unlocked it: an unlock would take any password now,
	// so only the change tells whether the item's password is the keyring's.
	r := rig_start(t, Behavior{locked = false})
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expectf(t, res.outcome == .Changed, "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, r.fake.current, NEW)
	testing.expect_value(t, asked(&r), 1)
	expect_changes(t, r.fake, {{NEW, NEW}, {PASSWORD, NEW}, {NEW, NEW}})
	expect_calls(
		t,
		r.fake,
		{"Hello", "Get", "OpenSession", "ChangeWithMasterPassword", "ChangeWithMasterPassword", "ChangeWithMasterPassword", "Get"},
	)
	testing.expect(t, !r.fake.was_locked)
	testing.expect_value(t, read(r.credential), stored(NEW))
}

@(test)
stores_again_when_the_keyring_has_the_password_already :: proc(t: ^testing.T) {
	// A run that changed the keyring and died before the credential: the
	// next one asks for nothing and only writes the credential, over the
	// one an earlier setup left.
	for locked in ([]bool{true, false}) {
		r := rig_start(t, Behavior{locked = locked, password = NEW}, typed = ABSENT)
		testing.expect(t, os.make_directory_all(join(r.dir, "home/.config/credstore.encrypted"), {.Read_User, .Write_User, .Execute_User}) == nil)
		write_file(t, join(r.dir, "home/.config/credstore.encrypted"), kr.CREDENTIAL_NAME, "stale")
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Stored, "locked %v: %v: %s", locked, res.outcome, res.detail)
		testing.expect_value(t, kr.setup_exit_code(res.outcome), 0)
		testing.expect_value(t, asked(&r), 0)
		testing.expect_value(t, r.fake.current, NEW)
		expect_changes(t, r.fake, {{NEW, NEW}, {NEW, NEW}})
		testing.expect_value(t, read(r.credential), stored(NEW))
		testing.expect_value(t, mode_of(r.credential), 0o600)
		testing.expect(t, !r.fake.was_locked)
		rig_free(&r)
	}
}

@(test)
a_run_that_died_after_the_change_is_repaired_by_the_next :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true})
	write_file(t, r.dir, "encrypt-fails", "")
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expect_value(t, kr.setup_exit_code(res.outcome), 1)
	// The keyring has the new password, and the line says what to do.
	testing.expect_value(t, r.fake.current, NEW)
	testing.expectf(t, strings.contains(res.detail, "run the setup again"), "%s", res.detail)
	testing.expectf(t, !os.exists(r.credential), "a credential was written")
	names := files_in(join(r.dir, "home/.config/credstore.encrypted"))
	testing.expectf(t, len(names) == 0, "the directory holds %v", names)
	rig_free(&r)

	// The next run, on the keyring as the first one left it.
	r = rig_start(t, Behavior{locked = true, password = NEW}, typed = ABSENT)
	defer rig_free(&r)
	res = rig_run(t, &r)
	testing.expectf(t, res.outcome == .Stored, "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, asked(&r), 0)
	testing.expect_value(t, read(r.credential), stored(NEW))
}

@(test)
refuses_a_wrong_current_password :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true}, typed = "falsches Pferd")
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "does not open"), "%s", res.detail)
	testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%s", res.detail)
	testing.expect_value(t, r.fake.current, PASSWORD)
	expect_changes(t, r.fake, {{NEW, NEW}, {"falsches Pferd", NEW}})
	testing.expect(t, !ran_creds(&r))
	testing.expect(t, !os.exists(r.credential))
	testing.expect(t, r.fake.was_locked)
}

@(test)
refuses_the_same_password :: proc(t: ^testing.T) {
	// The keyring does not open with the item's password, and the one typed
	// as the current one is the item's: nothing is sent.
	r := rig_start(t, Behavior{locked = true}, typed = NEW)
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "same"), "%s", res.detail)
	expect_changes(t, r.fake, {{NEW, NEW}})
	testing.expect_value(t, r.fake.current, PASSWORD)
	testing.expect(t, !ran_creds(&r))
}

@(test)
refuses_when_nobody_types :: proc(t: ^testing.T) {
	for typed in ([]string{ABSENT, ""}) {
		r := rig_start(t, Behavior{locked = true}, typed = typed)
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%q: %v", typed, res.outcome)
		testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%s", res.detail)
		expect_changes(t, r.fake, {{NEW, NEW}})
		testing.expect_value(t, r.fake.current, PASSWORD)
		testing.expect(t, !ran_creds(&r))
		rig_free(&r)
	}
}

@(test)
refuses_when_the_vault_is_locked :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true})
	defer rig_free(&r)
	write_file(t, r.dir, "rbw-locked", "")
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "rbw unlock") && strings.contains(res.detail, "ai-unlock"), "%s", res.detail)
	// It asked rbw whether the vault is open, and nothing else: no get,
	// which would make the agent prompt for the master password.
	log := ran(&r)
	testing.expectf(t, len(log) == 1 && log[0] == "rbw [unlocked]", "it ran %v", log)
	testing.expect_value(t, r.fake.connections, 0)
}

@(test)
refuses_without_rbw :: proc(t: ^testing.T) {
	for program in ([]string{"", "no-rbw-here"}) {
		r := rig_start(t, Behavior{locked = true})
		delete(r.s.rbw)
		r.s.rbw = strings.clone(join(r.dir, program) if program != "" else "")
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%q: %v", program, res.outcome)
		testing.expectf(t, strings.contains(res.detail, "rbw is not installed"), "%s", res.detail)
		testing.expect_value(t, r.fake.connections, 0)
		rig_free(&r)
	}
}

@(test)
refuses_an_item_that_is_no_password :: proc(t: ^testing.T) {
	huge := strings.concatenate({strings.repeat("x", kr.MAX_PASSWORD + 1, context.temp_allocator), "\n"}, context.temp_allocator)
	flood := strings.repeat("x", 200 * 1024, context.temp_allocator)
	cases := [][2]string {
		{ABSENT, "rbw cannot read"},
		{"", "empty"},
		{"\n", "empty"},
		{"Pferd\x00Pferd\n", "NUL"},
		// The unlock takes one line break off the credential, so a password
		// that ends in one would never match.
		{"Pferd\n\n", "line break"},
		{huge, "longer"},
		{flood, "longer"},
	}
	for c in cases {
		r := rig_start(t, Behavior{locked = true}, item = c[0])
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%q: %v", c[1], res.outcome)
		testing.expectf(t, strings.contains(res.detail, c[1]), "%q: %s", c[1], res.detail)
		testing.expectf(t, strings.contains(res.detail, ITEM), "%q: %s", c[1], res.detail)
		testing.expect_value(t, r.fake.connections, 0)
		testing.expect_value(t, asked(&r), 0)
		rig_free(&r)
	}
	// The longest password there is still passes, and one without rbw's
	// newline too.
	longest := strings.repeat("y", kr.MAX_PASSWORD, context.temp_allocator)
	for item in ([]string{strings.concatenate({longest, "\n"}, context.temp_allocator), "no newline"}) {
		r := rig_start(t, Behavior{locked = true}, item = item)
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Changed, "%d bytes: %v: %s", len(item), res.outcome, res.detail)
		testing.expect_value(t, r.fake.current, strings.trim_right(item, "\n"))
		rig_free(&r)
	}
}

@(test)
refuses_a_symlinked_or_odd_credential_path :: proc(t: ^testing.T) {
	Case :: enum {
		File_Is_Link,
		Dir_Is_Link,
		File_Is_Dir,
		Dir_Is_File,
	}
	for c in Case {
		r := rig_start(t, Behavior{locked = true})
		target := join(r.dir, "elsewhere")
		write_file(t, r.dir, "elsewhere", "keep")
		dir := join(r.dir, "home/.config/credstore.encrypted")
		parent := join(r.dir, "home/.config")
		testing.expect(t, os.make_directory_all(parent, {.Read_User, .Write_User, .Execute_User}) == nil)
		switch c {
		case .File_Is_Link:
			testing.expect(t, os.make_directory(dir, {.Read_User, .Write_User, .Execute_User}) == nil)
			testing.expect(t, os.symlink(target, r.credential) == nil)
		case .Dir_Is_Link:
			other := join(r.dir, "other-dir")
			testing.expect(t, os.make_directory(other, {.Read_User, .Write_User, .Execute_User}) == nil)
			testing.expect(t, os.symlink(other, dir) == nil)
		case .File_Is_Dir:
			testing.expect(t, os.make_directory_all(r.credential, {.Read_User, .Write_User, .Execute_User}) == nil)
		case .Dir_Is_File:
			write_file(t, parent, "credstore.encrypted", "not a directory")
		}
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%v: %v", c, res.outcome)
		testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%v: %s", c, res.detail)
		// Refused before anything ran.
		testing.expectf(t, read(join(r.dir, "log")) == "", "%v: it ran %v", c, ran(&r))
		testing.expect_value(t, r.fake.connections, 0)
		testing.expect_value(t, read(target), "keep")
		rig_free(&r)
	}
}

@(test)
fails_when_systemd_creds_fails :: proc(t: ^testing.T) {
	for what in ([]string{"decrypt-fails", "decrypt-other"}) {
		r := rig_start(t, Behavior{locked = true})
		write_file(t, r.dir, what, "")
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%s: %v", what, res.outcome)
		testing.expectf(t, strings.contains(res.detail, "run the setup again"), "%s: %s", what, res.detail)
		// The keyring has the item's password; the check with what the
		// credential holds never reached it.
		testing.expect_value(t, r.fake.current, NEW)
		expect_changes(t, r.fake, {{NEW, NEW}, {PASSWORD, NEW}})
		rig_free(&r)
	}
}

@(test)
refuses_when_there_is_no_login_keyring :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{no_keyring = true})
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "no login keyring"), "%s", res.detail)
	testing.expect_value(t, asked(&r), 0)
	expect_changes(t, r.fake, {})
	expect_calls(t, r.fake, {"Hello", "Get"})
	testing.expect(t, !ran_creds(&r))
}

@(test)
fails_on_another_answer_of_the_daemon :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true, change_error = "org.freedesktop.DBus.Error.UnknownMethod"})
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "UnknownMethod"), "%s", res.detail)
	testing.expect_value(t, asked(&r), 0)
	testing.expect(t, !ran_creds(&r))
	rig_free(&r)

	r = rig_start(t, Behavior{locked = true, close_on = "ChangeWithMasterPassword"})
	res = rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "closed"), "%s", res.detail)
	testing.expect_value(t, asked(&r), 0)
	rig_free(&r)

	r = rig_start(t, Behavior{no_service = true})
	res = rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "ServiceUnknown"), "%s", res.detail)
	rig_free(&r)
}

@(test)
makes_the_directory_private :: proc(t: ^testing.T) {
	r := rig_start(t, Behavior{locked = true})
	defer rig_free(&r)
	dir := join(r.dir, "home/.config/credstore.encrypted")
	testing.expect(t, os.make_directory_all(dir) == nil)
	testing.expect(t, os.chmod(dir, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) == nil)
	res := rig_run(t, &r)
	testing.expectf(t, res.outcome == .Changed, "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, mode_of(dir), 0o700)
	testing.expect_value(t, mode_of(r.credential), 0o600)
}

Writer_Job :: struct {
	path:    string,
	content: string,
	uid:     u32,
	failed:  int,
}

@(test)
writes_the_credential_atomically :: proc(t: ^testing.T) {
	// Runs that write at once each replace the file with a whole one of
	// theirs, and leave no temporary file behind.
	d := scratch(t)
	defer os.remove_all(d)
	path := join(d, "store", kr.CREDENTIAL_NAME)
	jobs: [4]Writer_Job
	threads: [4]^thread.Thread
	for i in 0 ..< len(jobs) {
		jobs[i] = Writer_Job {
			path    = path,
			content = fmt.tprintf("content of writer %d %s", i, strings.repeat("z", 3000 * (i + 1), context.temp_allocator)),
			uid     = u32(linux.getuid()),
		}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], proc(j: ^Writer_Job) {
			for _ in 0 ..< 25 {
				if why := kr.write_credential(j.path, transmute([]u8)j.content, j.uid); why != "" {
					j.failed += 1
				}
			}
		}, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	got := read(path)
	whole := false
	for j in jobs {
		testing.expect_value(t, j.failed, 0)
		whole ||= got == j.content
	}
	testing.expectf(t, whole, "the file is no writer's whole content (%d bytes)", len(got))
	names := files_in(join(d, "store"))
	testing.expectf(t, len(names) == 1, "the directory holds %v", names)
	testing.expect_value(t, mode_of(path), 0o600)
}

@(test)
finds_programs_on_the_path_only :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	bin := join(d, "bin")
	testing.expect(t, os.make_directory(bin) == nil)
	testing.expect(t, os.symlink(STUB, join(bin, "rbw")) == nil)
	write_file(t, bin, "not-executable", "x")
	testing.expect(t, os.make_directory(join(bin, "a-directory")) == nil)
	path := strings.concatenate({"/nonexistent:", bin, ":"}, context.temp_allocator)
	got, ok := kr.find_program("rbw", path)
	testing.expect(t, ok)
	testing.expect_value(t, got, join(bin, "rbw"))
	for name in ([]string{"not-executable", "a-directory", "absent"}) {
		_, found := kr.find_program(name, path)
		testing.expectf(t, !found, "%s was found", name)
	}
	// An empty or relative entry is the working directory, which the
	// setup never runs a program from.
	for p in ([]string{"", ".", "bin", ":", "::"}) {
		_, found := kr.find_program("rbw", p)
		testing.expectf(t, !found, "rbw found on %q", p)
	}
}

@(test)
refuses_an_item_that_holds_the_login_password :: proc(t: ^testing.T) {
	// The keyring has the login password, as PAM made it, and the item
	// holds it too: the check that the keyring has the item's password
	// would pass and ask for nothing. And a keyring with a password of its
	// own, which the setup would change to the login password. Both are
	// refused before the bus is touched.
	for password in ([]string{LOGIN, PASSWORD}) {
		r := rig_start(t, Behavior{locked = true, password = password}, item = LOGIN + "\n")
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%v: %s", res.outcome, res.detail)
		testing.expectf(t, strings.contains(res.detail, "your login password"), "%s", res.detail)
		testing.expectf(t, strings.contains(res.detail, "a password of its own"), "%s", res.detail)
		testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%s", res.detail)
		testing.expect_value(t, r.fake.connections, 0)
		testing.expect_value(t, asked(&r), 0)
		testing.expect(t, !ran_creds(&r))
		testing.expect(t, !os.exists(r.credential))
		testing.expect_value(t, r.fake.current, password)
		rig_free(&r)
	}
}

@(test)
refuses_when_the_login_password_cannot_be_checked :: proc(t: ^testing.T) {
	// No helper, no such user (9), and a helper that cannot be run: the
	// setup does not go on without knowing.
	Case :: enum {
		No_Helper,
		Unknown_User,
		Missing_Helper,
	}
	for c in Case {
		r := rig_start(t, Behavior{locked = true}, login = ABSENT if c == .Unknown_User else LOGIN)
		switch c {
		case .No_Helper:
			delete(r.s.chkpwd)
			r.s.chkpwd = strings.clone("")
		case .Missing_Helper:
			delete(r.s.chkpwd)
			r.s.chkpwd = strings.clone(join(r.dir, "no-chkpwd"))
		case .Unknown_User:
		}
		res := rig_run(t, &r)
		testing.expectf(t, res.outcome == .Failed, "%v: %v", c, res.outcome)
		testing.expectf(t, strings.contains(res.detail, "cannot check"), "%v: %s", c, res.detail)
		testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%v: %s", c, res.detail)
		testing.expect_value(t, r.fake.connections, 0)
		rig_free(&r)
	}
	// Without a user name there is nothing to check against either.
	r := rig_start(t, Behavior{locked = true})
	r.s.user = ""
	res := rig_run(t, &r)
	testing.expectf(t, res.outcome == .Failed && strings.contains(res.detail, "cannot check"), "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, r.fake.connections, 0)
	rig_free(&r)
}

@(test)
does_not_claim_nothing_changed_when_the_change_got_no_answer :: proc(t: ^testing.T) {
	// The bus hangs up during the change from the typed password (the
	// check before it was answered): the daemon may have changed it.
	r := rig_start(t, Behavior{locked = true, close_on = "ChangeWithMasterPassword", close_skip = 1})
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, !strings.contains(res.detail, "nothing changed"), "%s", res.detail)
	testing.expectf(t, strings.contains(res.detail, "not known whether"), "%s", res.detail)
	testing.expectf(t, strings.contains(res.detail, "run the setup again"), "%s", res.detail)
	testing.expect_value(t, asked(&r), 1)
}

@(test)
says_so_when_the_prompt_has_no_terminal :: proc(t: ^testing.T) {
	// The tests give the prompt no terminal (/dev/null); when it fails, the
	// line says to run the setup in one.
	r := rig_start(t, Behavior{locked = true}, typed = ABSENT)
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expect_value(t, res.outcome, kr.Setup_Outcome.Failed)
	testing.expectf(t, strings.contains(res.detail, "not a terminal"), "%s", res.detail)
	testing.expectf(t, strings.contains(res.detail, "nothing changed"), "%s", res.detail)
}

@(test)
finds_the_user_name_in_the_passwd_file :: proc(t: ^testing.T) {
	passwd := "root:x:0:0:System administrator:/root:/bin/sh\n# a comment\nbroken line\nalice:x:1000:100::/home/alice:/bin/sh\nbob:x:10000:100::/home/bob:/bin/sh\n"
	name, ok := kr.user_name(1000, passwd)
	testing.expect(t, ok)
	testing.expect_value(t, name, "alice")
	name, ok = kr.user_name(0, passwd)
	testing.expect_value(t, name, "root")
	for uid in ([]u32{100, 1, 10, 100000}) {
		_, found := kr.user_name(uid, passwd)
		testing.expectf(t, !found, "uid %d found", uid)
	}
	_, ok = kr.user_name(1000, "")
	testing.expect(t, !ok)
	_, ok = kr.user_name(1000, ":x:1000:100::/:/bin/sh\n")
	testing.expect(t, !ok)
}

@(test)
takes_only_a_setuid_root_helper :: proc(t: ^testing.T) {
	// The real helper reads the shadow file only as root; a copy without
	// the setuid bit answers 9, user unknown, which the setup refuses too.
	// The command takes the one under /run/wrappers only when it is setuid
	// and root's, which says so more clearly.
	d := scratch(t)
	defer os.remove_all(d)
	path := write_file(t, d, "unix_chkpwd", "#!/bin/sh\n")
	testing.expect(t, os.chmod(path, {.Read_User, .Write_User, .Execute_User}) == nil)
	testing.expect(t, !kr.setuid_root(path))
	testing.expect(t, !kr.setuid_root(strings.concatenate({d, "/absent"}, context.temp_allocator)))
	testing.expect(t, !kr.setuid_root(d))
}

@(test)
checks_a_long_item_as_pam_unix_checks_a_long_login_password :: proc(t: ^testing.T) {
	// pam_unix hands unix_chkpwd the first 512 bytes of a longer password,
	// at a login and when it sets one; the setup does the same, so a long
	// item that is the login password is refused.
	login := strings.repeat("L", 600, context.temp_allocator)
	r := rig_start(t, Behavior{locked = true, password = login}, item = strings.concatenate({login, "\n"}, context.temp_allocator), login = login[:512])
	defer rig_free(&r)
	res := rig_run(t, &r)
	testing.expectf(t, res.outcome == .Failed && strings.contains(res.detail, "your login password"), "%v: %s", res.outcome, res.detail)
	testing.expect_value(t, len(read(join(r.dir, "chkpwd.in"))), 513)
	testing.expect_value(t, r.fake.connections, 0)
}
