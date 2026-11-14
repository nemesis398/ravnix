// ravnix-keyring-unlock setup: the one-time setup of the auto-unlock, in one
// command. It gives the login keyring the password of a Bitwarden item and
// stores that password as the systemd credential the unlock reads:
//
//   1. check the credential's path: no symbolic link, nothing odd;
//   2. read the new password from the Bitwarden item through rbw, while the
//      vault is unlocked (a locked one would prompt for its master password),
//      and refuse it when it is the user's login password, which the
//      keyring must not get (pam_unix's own helper, unix_chkpwd, says);
//   3. ask the daemon whether the keyring already has that password, with
//      ChangeWithMasterPassword from it to itself. UnlockWithMasterPassword
//      is no such check: an unlocked collection takes any password for it;
//   4. when it does not, ask for the current password once, in the
//      terminal (systemd-ask-password), and change it with
//      ChangeWithMasterPassword, which refuses a wrong one and then changes
//      nothing;
//   5. encrypt the new password with systemd-creds and write the credential
//      file in place of the old one, in one rename;
//   6. decrypt the credential again, check that the keyring takes what it
//      holds, and unlock the keyring with it when it is locked.
//
// The keyring comes first and the credential second, and step 3 makes the
// order repairable: a run that died between 4 and 5 left the keyring with
// the item's password, so the next run asks for nothing and only writes the
// credential. Every refusal before 4 changes nothing. README.md has the why.
package ravnix_keyring_unlock

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// How long rbw and systemd-creds may take (a TPM2 can take seconds), and
// each exchange with the bus.
SETUP_TIMEOUT :: 60 * time.Second
// How long the prompt waits for the current password: systemd-ask-password
// gives up after ASK_SECONDS itself, and is stopped a minute later.
ASK_SECONDS :: 300
ASK_TIMEOUT :: (ASK_SECONDS + 60) * time.Second
ASK_PROMPT :: "Current password of the login keyring:"
// An encrypted credential of a password is a few kilobytes of Base64.
MAX_CIPHERTEXT :: 256 * 1024
GUILT_RIDDEN :: "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"
// NixOS's setuid wrapper of pam_unix's helper, which checks the caller's own
// password against the shadow file.
UNIX_CHKPWD :: "/run/wrappers/bin/unix_chkpwd"

Setup :: struct {
	// The Bitwarden item that holds the new password.
	item:         string,
	// The session bus, a D-Bus address.
	bus:          string,
	// The encrypted credential to write:
	// ~/.config/credstore.encrypted/ravnix-keyring-login.
	credential:   string,
	// The programs, as paths; "" is one that is not installed.
	rbw:          string,
	ask_password: string,
	creds:        string,
	// unix_chkpwd, and the user's name, which it checks the password of.
	chkpwd:       string,
	user:         string,
	// The terminal the prompt reads, and where the programs' messages and
	// the setup's own go (nil is /dev/null).
	tty:          ^os.File,
	messages:     ^os.File,
	timeout:      time.Duration,
	uid:          u32,
}

Setup_Outcome :: enum u8 {
	// The keyring got the item's password, and the credential holds it.
	Changed,
	// The keyring had it already; the credential holds it now.
	Stored,
	Failed,
}

Setup_Result :: struct {
	outcome: Setup_Outcome,
	// The line to print, without the prefix; in the temporary allocator.
	detail:  string,
}

setup_exit_code :: proc(o: Setup_Outcome) -> int {
	return 1 if o == .Failed else 0
}

setup_line :: proc(r: Setup_Result) -> string {
	return fmt.tprintf("ravnix-keyring-unlock setup: %s", r.detail)
}

// setup_credential_path is where the user manager finds the credential by
// name (LoadCredentialEncrypted=, modules/desktop/keyring.nix).
setup_credential_path :: proc(home: string) -> string {
	return fmt.tprintf("%s/.config/credstore.encrypted/%s", strings.trim_right(home, "/"), CREDENTIAL_NAME)
}

say :: proc(s: Setup, text: string) {
	if s.messages != nil {
		fmt.fprintfln(s.messages, "ravnix-keyring-unlock setup: %s", text)
	}
}

// ── the credential's file ────────────────────────────────────────────────────

split_path :: proc(path: string) -> (dir, name: string) {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return ".", path
	}
	if slash == 0 {
		return "/", path[1:]
	}
	return path[:slash], path[slash + 1:]
}

lstat_of :: proc(path: string) -> (st: linux.Stat, e: linux.Errno) {
	e = linux.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	return
}

// check_credential_path says what keeps the setup from writing path, before
// anything else runs: a symbolic link where the directory or the file
// should be, something else than a directory or a file there, or a
// directory of another user. A path that is not there yet is fine.
check_credential_path :: proc(path: string, uid: u32) -> string {
	dir, name := split_path(path)
	if name == "" {
		return fmt.tprintf("the credential's path %s names no file", path)
	}
	st, e := lstat_of(dir)
	#partial switch e {
	case .ENOENT:
		return ""
	case .NONE:
	case:
		return fmt.tprintf("cannot look at %s: %s", dir, errno_text(e))
	}
	switch {
	case linux.S_ISLNK(st.mode):
		return fmt.tprintf("%s is a symbolic link, and the setup writes the credential through none", dir)
	case !linux.S_ISDIR(st.mode):
		return fmt.tprintf("%s is not a directory", dir)
	case u32(st.uid) != uid:
		return fmt.tprintf("%s belongs to another user", dir)
	}
	st, e = lstat_of(path)
	#partial switch e {
	case .ENOENT:
		return ""
	case .NONE:
	case:
		return fmt.tprintf("cannot look at %s: %s", path, errno_text(e))
	}
	switch {
	case linux.S_ISLNK(st.mode):
		return fmt.tprintf("%s is a symbolic link, and the setup writes the credential through none", path)
	case !linux.S_ISREG(st.mode):
		return fmt.tprintf("%s is not a file", path)
	}
	return ""
}

// make_directories makes every missing directory of path, private (0700),
// as `mkdir -p -m 0700` does for the last one.
make_directories :: proc(path: string) -> linux.Errno {
	for i := 1; i <= len(path); i += 1 {
		if i < len(path) && path[i] != '/' {
			continue
		}
		e := linux.mkdir(strings.clone_to_cstring(path[:i], context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
		if e != .NONE && e != .EEXIST {
			return e
		}
	}
	return .NONE
}

// open_private_directory opens dir, which it makes when it is missing, and
// makes it 0700. It refuses a symbolic link, something that is not a
// directory, and a directory of another user.
open_private_directory :: proc(dir: string, uid: u32) -> (fd: linux.Fd, why: string) {
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	flags := linux.Open_Flags{.DIRECTORY, .NOFOLLOW, .CLOEXEC}
	e: linux.Errno
	fd, e = linux.open(cdir, flags)
	if e == .ENOENT {
		if me := make_directories(dir); me != .NONE {
			return -1, fmt.tprintf("cannot make %s: %s", dir, errno_text(me))
		}
		fd, e = linux.open(cdir, flags)
	}
	#partial switch e {
	case .NONE:
	case .ELOOP, .ENOTDIR:
		if st, le := lstat_of(dir); le == .NONE && linux.S_ISLNK(st.mode) {
			return -1, fmt.tprintf("%s is a symbolic link, and the setup writes the credential through none", dir)
		}
		return -1, fmt.tprintf("%s is not a directory", dir)
	case:
		return -1, fmt.tprintf("cannot open %s: %s", dir, errno_text(e))
	}
	st: linux.Stat
	if fe := linux.fstat(fd, &st); fe != .NONE {
		linux.close(fd)
		return -1, fmt.tprintf("cannot look at %s: %s", dir, errno_text(fe))
	}
	if u32(st.uid) != uid {
		linux.close(fd)
		return -1, fmt.tprintf("%s belongs to another user", dir)
	}
	private := linux.Mode{.IRUSR, .IWUSR, .IXUSR}
	if transmute(u32)st.mode & 0o7777 != transmute(u32)private {
		if ce := linux.fchmod(fd, private); ce != .NONE {
			linux.close(fd)
			return -1, fmt.tprintf("cannot make %s private: %s", dir, errno_text(ce))
		}
	}
	return fd, ""
}

// write_credential puts data at path, 0600, in a private directory: it
// writes a temporary file beside it, syncs it, and renames it over path, so
// the unlock finds the old file or the new one, never a part. It refuses a
// symbolic link at path or its directory.
write_credential :: proc(path: string, data: []u8, uid: u32) -> string {
	dir, name := split_path(path)
	dfd, dwhy := open_private_directory(dir, uid)
	if dwhy != "" {
		return dwhy
	}
	defer linux.close(dfd)
	// Its own name per thread, so that two runs at once each rename a whole
	// file of theirs. A name a dead run left is taken over.
	tmp := fmt.tprintf(".%s.%d.%d.tmp", name, linux.getpid(), linux.gettid())
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	mode := linux.Mode{.IRUSR, .IWUSR}
	flags := linux.Open_Flags{.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}
	fd, e := linux.openat(dfd, ctmp, flags, mode)
	if e == .EEXIST {
		linux.unlinkat(dfd, ctmp, {})
		fd, e = linux.openat(dfd, ctmp, flags, mode)
	}
	if e != .NONE {
		return fmt.tprintf("cannot write in %s: %s", dir, errno_text(e))
	}
	fail := ""
	if ce := linux.fchmod(fd, mode); ce != .NONE {
		fail = fmt.tprintf("cannot make the credential private: %s", errno_text(ce))
	}
	rest := data
	for fail == "" && len(rest) > 0 {
		n, we := linux.write(fd, rest)
		if we == .EINTR {
			continue
		}
		if we != .NONE {
			fail = fmt.tprintf("cannot write the credential in %s: %s", dir, errno_text(we))
			break
		}
		rest = rest[n:]
	}
	if fail == "" {
		if se := linux.fsync(fd); se != .NONE {
			fail = fmt.tprintf("cannot write the credential in %s: %s", dir, errno_text(se))
		}
	}
	linux.close(fd)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if fail == "" {
		st: linux.Stat
		se := linux.fstatat(dfd, cname, &st, {.SYMLINK_NOFOLLOW})
		switch {
		case se == .NONE && linux.S_ISLNK(st.mode):
			fail = fmt.tprintf("%s is a symbolic link, and the setup writes the credential through none", path)
		case se == .NONE && !linux.S_ISREG(st.mode):
			fail = fmt.tprintf("%s is not a file", path)
		case se != .NONE && se != .ENOENT:
			fail = fmt.tprintf("cannot look at %s: %s", path, errno_text(se))
		}
	}
	if fail == "" {
		if re := linux.renameat(dfd, ctmp, dfd, cname); re != .NONE {
			fail = fmt.tprintf("cannot put the credential in place at %s: %s", path, errno_text(re))
		}
	}
	if fail != "" {
		linux.unlinkat(dfd, ctmp, {})
		return fail
	}
	// The rename itself on the disk, before the setup says it is done.
	linux.fsync(dfd)
	return ""
}

// ── the passwords ────────────────────────────────────────────────────────────

// is_terminal reports whether f is a terminal (TCGETS works on it).
is_terminal :: proc(f: ^os.File) -> bool {
	if f == nil {
		return false
	}
	TCGETS :: 0x5401
	termios: [64]u8
	return linux.syscall(linux.SYS_ioctl, uintptr(os.fd(f)), TCGETS, uintptr(&termios[0])) == 0
}

// user_name is the name of uid in passwd, the text of /etc/passwd.
user_name :: proc(uid: u32, passwd: string) -> (name: string, ok: bool) {
	rest := passwd
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split_n(line, ":", 4, context.temp_allocator)
		if len(fields) < 4 || fields[0] == "" {
			continue
		}
		id, idok := strconv.parse_u64(fields[2], 10)
		if idok && id == u64(uid) {
			return fields[0], true
		}
	}
	return "", false
}

// setuid_root reports whether path is an executable file of root's with the
// setuid bit, as NixOS's wrapper of unix_chkpwd is. A copy without it could
// not read the shadow file and would answer every password with 7, "not
// the login password".
setuid_root :: proc(path: string) -> bool {
	st: linux.Stat
	if linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return false
	}
	return linux.S_ISREG(st.mode) && st.uid == 0 && .ISUID in st.mode && .IXUSR in st.mode
}

// check_not_login refuses a new password that is the user's login password,
// with pam_unix's helper: the user's name and "nonull" as its arguments, the
// password and a NUL on its standard input (a pipe: it refuses a terminal),
// 0 when it is the login password, 7 when not. A run with another password
// is a failed password check in the journal ("password check failed for
// user"); the helper neither waits after it nor counts it.
check_not_login :: proc(s: Setup, password: []u8) -> string {
	cannot :: "cannot check the item's password against your login password"
	if s.user == "" {
		return fmt.tprintf("%s: your user name is not in /etc/passwd; nothing changed", cannot)
	}
	if s.chkpwd == "" {
		return fmt.tprintf("%s: %s, the setuid helper of pam_unix, is not there or not setuid root; nothing changed", cannot, UNIX_CHKPWD)
	}
	input := make([]u8, len(password) + 1)
	defer free_password(input)
	copy(input, password)
	r, missing, why := run_program({s.chkpwd, s.user, "nonull"}, input, nil, s.messages, s.timeout, 4096)
	free_output(&r)
	switch {
	case missing || why != "":
		return fmt.tprintf("%s (%s); nothing changed", cannot, why)
	case r.status == 0:
		return fmt.tprintf(
			"the Bitwarden item %q holds your login password, and the keyring needs a password of its own: give the item another one (Bitwarden's generator); nothing changed",
			printable(s.item),
		)
	case r.status == 7:
		return ""
	}
	return fmt.tprintf("%s (unix_chkpwd ended with %d); nothing changed", cannot, r.status)
}

// take_password copies a program's output into a buffer of its own, which
// the caller wipes and frees, and wipes the output.
take_password :: proc(r: ^Ran, data: []u8) -> []u8 {
	pw := make([]u8, len(data))
	copy(pw, data)
	free_output(r)
	return pw
}

free_password :: proc(pw: []u8) {
	wipe(pw)
	delete(pw)
}

// read_item reads the new password from the Bitwarden item, while the vault
// is unlocked: `rbw get` on a locked vault would make the agent ask for the
// master password, which this is not the place for.
read_item :: proc(s: Setup) -> (password: []u8, why: string) {
	if s.rbw == "" {
		return nil, "rbw is not installed (it is not on PATH), and the item's password comes from it; nothing changed"
	}
	r, missing, rwhy := run_program({s.rbw, "unlocked"}, nil, nil, s.messages, s.timeout, 4096)
	free_output(&r)
	switch {
	case missing:
		return nil, fmt.tprintf("rbw is not installed (%s); nothing changed", rwhy)
	case rwhy != "":
		return nil, fmt.tprintf("%s; nothing changed", rwhy)
	case r.status != 0:
		return nil, "the vault is locked: run `rbw unlock` (or ai-unlock), then the setup again; nothing changed"
	}
	r, missing, rwhy = run_program({s.rbw, "get", "--", s.item}, nil, nil, s.messages, s.timeout, MAX_PASSWORD + 2)
	switch {
	case missing:
		return nil, fmt.tprintf("rbw is not installed (%s); nothing changed", rwhy)
	case rwhy != "":
		return nil, fmt.tprintf("%s; nothing changed", rwhy)
	case r.status != 0:
		free_output(&r)
		return nil, fmt.tprintf(
			"rbw cannot read the item %q (its message is above): name the item in ravnix.desktop.keyring.autoUnlock.rbwItem or with --item; nothing changed",
			printable(s.item),
		)
	case r.too_long:
		return nil, fmt.tprintf("the password of the item %q is longer than a login password can be (%d bytes); nothing changed", printable(s.item), MAX_PASSWORD)
	}
	// rbw ends the password with a newline.
	data := r.output
	if len(data) > 0 && data[len(data) - 1] == '\n' {
		data = data[:len(data) - 1]
	}
	problem := password_problem(data)
	if problem == "" && len(data) > 0 && data[len(data) - 1] == '\n' {
		// The unlock takes one line break off what the credential holds.
		problem = "ends in a line break, which the unlock would take off"
	}
	if problem != "" {
		free_output(&r)
		return nil, fmt.tprintf("the password of the item %q %s; nothing changed", printable(s.item), problem)
	}
	return take_password(&r, data), ""
}

// ask_current asks for the keyring's current password in the terminal,
// masked.
ask_current :: proc(s: Setup) -> (password: []u8, why: string) {
	if s.ask_password == "" {
		return nil, "systemd-ask-password is not installed (it is not on PATH); nothing changed"
	}
	r, missing, rwhy := run_program(
		{s.ask_password, "-n", fmt.tprintf("--timeout=%d", ASK_SECONDS), ASK_PROMPT},
		nil,
		s.tty,
		s.messages,
		ASK_TIMEOUT,
		MAX_PASSWORD + 1,
	)
	switch {
	case missing:
		return nil, fmt.tprintf("systemd-ask-password is not installed (%s); nothing changed", rwhy)
	case rwhy != "":
		return nil, fmt.tprintf("%s; nothing changed", rwhy)
	case r.status != 0 && !is_terminal(s.tty):
		free_output(&r)
		return nil, "no password was typed: the prompt needs a terminal, and the standard input is not a terminal; run the setup in a terminal of the session; nothing changed"
	case r.status != 0:
		free_output(&r)
		return nil, fmt.tprintf("no password was typed (systemd-ask-password ended with %d); nothing changed", r.status)
	case r.too_long:
		return nil, fmt.tprintf("the password typed is longer than a login password can be (%d bytes); nothing changed", MAX_PASSWORD)
	}
	if len(r.output) == 0 {
		free_output(&r)
		return nil, "no password was typed; nothing changed"
	}
	if problem := password_problem(r.output); problem != "" {
		free_output(&r)
		return nil, fmt.tprintf("the password typed %s; nothing changed", problem)
	}
	return take_password(&r, r.output), ""
}

// change_password calls ChangeWithMasterPassword on the login collection:
// from original to master, both in the plain session. denied is the
// daemon's answer when original is not the keyring's password, and then
// nothing changed. unanswered goes with a why that the daemon did not give
// (a timeout, a bus that hung up): the change may have happened.
change_password :: proc(c: ^Conn, session: string, original, master: []u8) -> (denied: bool, why: string, unanswered: bool) {
	// Room for all of it at once, so that no copy of a password is left
	// behind in a buffer that grew.
	body := make([dynamic]u8, 0, 512 + len(original) + len(master))
	defer delete(body)
	w := Writer {
		buf = &body,
	}
	put_string(w, LOGIN_COLLECTION)
	for secret in ([][]u8{original, master}) {
		// A secret, (oayays): session, parameters (none for plain), value,
		// content type.
		put_align(w, 8)
		put_string(w, session)
		put_bytes(w, nil)
		put_bytes(w, secret)
		put_string(w, "text/plain")
	}
	reply, cwhy := call(c, SECRETS, "/org/freedesktop/secrets", GUILT_RIDDEN, "ChangeWithMasterPassword", "o(oayays)(oayays)", body[:])
	wipe(body[:])
	if cwhy != "" {
		return false, cwhy, true
	}
	if reply.type == .Error {
		if reply.error_name == "org.gnome.keyring.Error.Denied" {
			return true, "", false
		}
		return false, fmt.tprintf("the change of the password: %s", error_text(reply)), false
	}
	return false, "", false
}

// ── the setup ────────────────────────────────────────────────────────────────

setup :: proc(s: Setup) -> Setup_Result {
	if s.item == "" {
		return {
			.Failed,
			"name the Bitwarden item whose password the keyring gets: set ravnix.desktop.keyring.autoUnlock.rbwItem, or pass --item NAME; nothing changed",
		}
	}
	if s.creds == "" {
		return {.Failed, "systemd-creds is not installed (it is not on PATH), and the credential comes from it; nothing changed"}
	}
	if why := check_credential_path(s.credential, s.uid); why != "" {
		return {.Failed, fmt.tprintf("%s; nothing changed", why)}
	}
	new_password, iwhy := read_item(s)
	if iwhy != "" {
		return {.Failed, iwhy}
	}
	defer free_password(new_password)
	if why := check_not_login(s, new_password); why != "" {
		return {.Failed, why}
	}

	c: Conn
	if why := connect(&c, s.bus, s.timeout, s.uid); why != "" {
		return {.Failed, fmt.tprintf("%s; nothing changed", why)}
	}
	defer conn_close(&c)
	if why := hello(&c); why != "" {
		return {.Failed, fmt.tprintf("%s; nothing changed", why)}
	}
	_, no_keyring, lwhy := is_locked(&c)
	switch {
	case lwhy != "":
		return {.Failed, fmt.tprintf("%s; nothing changed", lwhy)}
	case no_keyring:
		return {
			.Failed,
			"there is no login keyring yet: log in once with your password, which makes it (the setup never makes one); nothing changed",
		}
	}
	session, swhy := open_session(&c)
	if swhy != "" {
		return {.Failed, fmt.tprintf("%s; nothing changed", swhy)}
	}

	// Whether the keyring has the item's password already: a run that died
	// after the change and before the credential.
	// A change to the same password: if no answer comes, nothing changed.
	denied, pwhy, _ := change_password(&c, session, new_password, new_password)
	if pwhy != "" {
		return {.Failed, fmt.tprintf("%s; nothing changed", pwhy)}
	}
	changed := denied
	if denied {
		say(
			s,
			fmt.tprintf(
				"the login keyring does not open with the password of %q yet. Type its current password: your login password, unless you gave the keyring one of its own.",
				printable(s.item),
			),
		)
		old, awhy := ask_current(s)
		if awhy != "" {
			return {.Failed, awhy}
		}
		defer free_password(old)
		if string(old) == string(new_password) {
			return {
				.Failed,
				fmt.tprintf(
					"the password typed is the same as the one of %q, and the keyring does not open with that, so it is not the current one; nothing changed",
					printable(s.item),
				),
			}
		}
		conn_rearm(&c)
		unanswered: bool
		denied, pwhy, unanswered = change_password(&c, session, old, new_password)
		switch {
		case unanswered:
			return {
				.Failed,
				fmt.tprintf("%s: it is not known whether the keyring changed, so run the setup again, which finds out", pwhy),
			}
		case pwhy != "":
			return {.Failed, fmt.tprintf("%s; nothing changed", pwhy)}
		case denied:
			return {.Failed, "the password typed does not open the login keyring; nothing changed"}
		}
	}

	// From here on the keyring has the item's password, so a failure says
	// to run the setup again, which then only does this part.
	again :: "; the keyring already has the item's password, so run the setup again once that is fixed"
	enc, missing, ewhy := run_program(
		{s.creds, "--user", "encrypt", "--name=" + CREDENTIAL_NAME, "-", "-"},
		new_password,
		nil,
		s.messages,
		s.timeout,
		MAX_CIPHERTEXT,
	)
	switch {
	case missing:
		return {.Failed, fmt.tprintf("systemd-creds is not installed%s", again)}
	case ewhy != "":
		return {.Failed, fmt.tprintf("%s%s", ewhy, again)}
	case enc.status != 0:
		free_output(&enc)
		return {.Failed, fmt.tprintf("systemd-creds could not encrypt the password (its message is above)%s", again)}
	case enc.too_long || len(enc.output) == 0:
		free_output(&enc)
		return {.Failed, fmt.tprintf("systemd-creds gave no credential or a far too long one%s", again)}
	}
	wwhy := write_credential(s.credential, enc.output, s.uid)
	free_output(&enc)
	if wwhy != "" {
		return {.Failed, fmt.tprintf("%s%s", wwhy, again)}
	}

	// The check: what the credential decrypts to opens the keyring.
	dec, _, dwhy := run_program(
		{s.creds, "--user", "decrypt", "--name=" + CREDENTIAL_NAME, s.credential, "-"},
		nil,
		nil,
		s.messages,
		s.timeout,
		MAX_PASSWORD + 1,
	)
	defer free_output(&dec)
	switch {
	case dwhy != "":
		return {.Failed, fmt.tprintf("%s%s", dwhy, again)}
	case dec.status != 0:
		return {.Failed, fmt.tprintf("systemd-creds cannot decrypt the credential it wrote (its message is above)%s", again)}
	case dec.too_long || string(dec.output) != string(new_password):
		return {.Failed, fmt.tprintf("the credential does not decrypt to the item's password%s", again)}
	}
	conn_rearm(&c)
	denied, pwhy, _ = change_password(&c, session, dec.output, dec.output)
	switch {
	case pwhy != "":
		return {.Failed, fmt.tprintf("checking the stored password: %s%s", pwhy, again)}
	case denied:
		return {.Failed, fmt.tprintf("the login keyring does not take the stored password%s", again)}
	}
	// Open it for this session too, as the next login will.
	locked, _, l2why := is_locked(&c)
	if l2why == "" && locked {
		udenied, uwhy := send_password(&c, session, dec.output)
		if uwhy == "" && !udenied {
			locked, _, l2why = is_locked(&c)
		}
	}
	opened := "it is unlocked now" if l2why == "" && !locked else "it is still locked in this session; the next login unlocks it"
	if changed {
		return {
			.Changed,
			fmt.tprintf(
				"the login keyring's password is now the one of %q, and %s holds it for the unlock after every login; %s",
				printable(s.item),
				s.credential,
				opened,
			),
		}
	}
	return {
		.Stored,
		fmt.tprintf(
			"the login keyring already has the password of %q; stored it again in %s for the unlock after every login; %s",
			printable(s.item),
			s.credential,
			opened,
		),
	}
}
