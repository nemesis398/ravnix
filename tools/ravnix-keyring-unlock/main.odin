// ravnix-keyring-unlock: unlocks the login keyring of the gnome-keyring
// daemon that is already running, with the password from a systemd
// credential, right after a login that gave PAM no password (a YubiKey
// tap). README.md has the why; modules/desktop/keyring.nix runs it.
//
// It does one thing, in one connection to the session bus:
//
//   1. read the password from $CREDENTIALS_DIRECTORY/ravnix-keyring-login;
//      without it, say so and stop, before touching the bus;
//   2. ask the Secret Service whether the login collection is locked; when
//      it is not (a password login, which PAM unlocked), or there is no
//      login keyring, say so and stop: the password is never sent;
//   3. open a "plain" Secret Service session and call gnome-keyring's
//      UnlockWithMasterPassword on the login collection, the call its own
//      tools use to unlock with a known password, without a prompt;
//   4. ask again, and report unlocked only when the collection says so.
//
// It prints one line, on standard error, with the journal's priority
// prefix when standard error is the journal. It never prompts, and the
// password is never in its arguments, its environment or its output.
package ravnix_keyring_unlock

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The credential's name: the file in $CREDENTIALS_DIRECTORY, the file in
// ~/.config/credstore.encrypted/, and the name the setup encrypts it under.
CREDENTIAL_NAME :: "ravnix-keyring-login"
// The login keyring, as gnome-keyring exports it: login.keyring.
LOGIN_COLLECTION :: "/org/freedesktop/secrets/collection/login"
SECRETS :: "org.freedesktop.secrets"
// The longest password the tool sends: gnome-keyring takes no longer login
// password (gkd-main.c, read_login_password).
MAX_PASSWORD :: 8192
// How long the whole conversation may take. The first call may start the
// Secret Service; gnome-keyring is up in well under a second.
TIMEOUT :: 10 * time.Second

Outcome :: enum u8 {
	Unlocked,
	Already_Unlocked,
	No_Credential,
	No_Keyring,
	Wrong_Password,
	Failed,
}

Result :: struct {
	outcome: Outcome,
	// What went wrong, or where the credential was looked for; in the
	// temporary allocator.
	detail:  string,
}

// exit_code is 0 for everything that leaves the session as it should be or
// as the user left it, 1 for a failure. A wrong password is 0: the keyring
// stays as the login left it, and the warning says what to redo.
exit_code :: proc(o: Outcome) -> int {
	return 1 if o == .Failed else 0
}

// priority is the syslog level of the outcome's line.
priority :: proc(o: Outcome) -> int {
	switch o {
	case .Unlocked, .Already_Unlocked:
		return 6
	case .No_Credential, .No_Keyring:
		return 5
	case .Wrong_Password:
		return 4
	case .Failed:
		return 3
	}
	return 3
}

// line is the one line the run prints.
line :: proc(r: Result) -> string {
	text: string
	switch r.outcome {
	case .Unlocked:
		text = "unlocked the login keyring"
	case .Already_Unlocked:
		text = "the login keyring is already unlocked (a password login), nothing to do"
	case .No_Credential:
		text = fmt.tprintf(
			"no credential %s (%s): the login keyring stays as the login left it; ravnix.desktop.keyring.autoUnlock has the setup command",
			CREDENTIAL_NAME,
			r.detail,
		)
	case .No_Keyring:
		text = "there is no login keyring yet, nothing to unlock (the first password login creates it)"
	case .Wrong_Password:
		text = "the credential's password does not unlock the login keyring, so it stays locked: redo the setup after a change of the keyring's password"
	case .Failed:
		text = fmt.tprintf("cannot unlock the login keyring: %s", r.detail)
	}
	return fmt.tprintf("ravnix-keyring-unlock: %s", text)
}

// ── the credential ───────────────────────────────────────────────────────────

Credential_Status :: enum u8 {
	Ok,
	Missing,
	Failed,
}

// read_credential reads the password from path. "" or a file that is not
// there is Missing. The password is the file's bytes without one trailing
// newline; it must not be empty, hold a NUL or be longer than
// MAX_PASSWORD. The caller wipes and deletes it.
read_credential :: proc(path: string, allocator := context.allocator) -> (password: []u8, status: Credential_Status, why: string) {
	if path == "" {
		return nil, .Missing, ""
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, e := linux.open(cpath, {.CLOEXEC})
	if e == .ENOENT {
		return nil, .Missing, ""
	}
	if e != .NONE {
		return nil, .Failed, fmt.tprintf("cannot open the credential %s: %s", path, errno_text(e))
	}
	defer linux.close(fd)
	buf := make([]u8, MAX_PASSWORD + 2, allocator)
	n := 0
	for n < len(buf) {
		got, re := linux.read(fd, buf[n:])
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			wipe(buf)
			delete(buf, allocator)
			return nil, .Failed, fmt.tprintf("cannot read the credential %s: %s", path, errno_text(re))
		}
		if got == 0 {
			break
		}
		n += got
	}
	data := buf[:n]
	if n > 0 && data[n - 1] == '\n' {
		data = data[:n - 1]
	}
	fail := ""
	switch {
	case n == len(buf) || len(data) > MAX_PASSWORD:
		fail = fmt.tprintf("the credential %s is longer than a login password can be (%d bytes)", path, MAX_PASSWORD)
	case len(data) == 0:
		fail = fmt.tprintf("the credential %s is empty", path)
	case strings.index_byte(string(data), 0) >= 0:
		fail = fmt.tprintf("the credential %s holds a NUL byte, which no login password has", path)
	}
	if fail != "" {
		wipe(buf)
		delete(buf, allocator)
		return nil, .Failed, fail
	}
	password = make([]u8, len(data), allocator)
	copy(password, data)
	wipe(buf)
	delete(buf, allocator)
	return password, .Ok, ""
}

// ── the unlock ───────────────────────────────────────────────────────────────

// is_locked asks the Secret Service whether the login collection is locked.
// no_keyring is set when the daemon has no such collection.
is_locked :: proc(c: ^Conn) -> (locked: bool, no_keyring: bool, why: string) {
	body := make([dynamic]u8, context.temp_allocator)
	w := Writer {
		buf = &body,
	}
	put_string(w, "org.freedesktop.Secret.Collection")
	put_string(w, "Locked")
	reply, cwhy := call(c, SECRETS, LOGIN_COLLECTION, "org.freedesktop.DBus.Properties", "Get", "ss", body[:])
	if cwhy != "" {
		return false, false, cwhy
	}
	if reply.type == .Error {
		switch reply.error_name {
		case "org.freedesktop.DBus.Error.UnknownObject",
		     "org.freedesktop.DBus.Error.UnknownMethod",
		     "org.freedesktop.Secret.Error.NoSuchObject":
			return false, true, ""
		}
		return false, false, fmt.tprintf("asking whether it is locked: %s", error_text(reply))
	}
	r := Reader {
		data = reply.body,
		big  = reply.big_endian,
	}
	sig := ""
	if reply.signature == "v" {
		sig = get_signature(&r)
	}
	if sig != "b" {
		return false, false, fmt.tprintf("the Secret Service answered Locked with %q, not a boolean", printable(reply.signature if sig == "" else sig))
	}
	locked = get_bool(&r)
	if r.bad {
		return false, false, "the Secret Service answered Locked with a malformed boolean"
	}
	return locked, false, ""
}

// open_session opens a Secret Service session with the "plain" algorithm,
// in which a secret travels as it is; the bus is the user's own.
open_session :: proc(c: ^Conn) -> (path: string, why: string) {
	body := make([dynamic]u8, context.temp_allocator)
	w := Writer {
		buf = &body,
	}
	put_string(w, "plain")
	put_signature(w, "s")
	put_string(w, "")
	reply, cwhy := call(c, SECRETS, "/org/freedesktop/secrets", "org.freedesktop.Secret.Service", "OpenSession", "sv", body[:])
	if cwhy != "" {
		return "", cwhy
	}
	if reply.type == .Error {
		return "", fmt.tprintf("opening a session: %s", error_text(reply))
	}
	r := Reader {
		data = reply.body,
		big  = reply.big_endian,
	}
	if reply.signature != "vo" || get_signature(&r) != "s" {
		return "", fmt.tprintf("the Secret Service opened a session with %q, not a plain one", printable(reply.signature))
	}
	get_string(&r)
	path = get_string(&r)
	if r.bad || path == "" || path == "/" {
		return "", "the Secret Service opened no session"
	}
	return strings.clone(path, context.temp_allocator), ""
}

// send_password calls UnlockWithMasterPassword. denied is the daemon's
// answer to a wrong password.
send_password :: proc(c: ^Conn, session: string, password: []u8) -> (denied: bool, why: string) {
	body := make([dynamic]u8, 0, 256 + len(password))
	defer delete(body)
	w := Writer {
		buf = &body,
	}
	put_string(w, LOGIN_COLLECTION)
	// The secret, (oayays): session, parameters (none for plain), value,
	// content type.
	put_align(w, 8)
	put_string(w, session)
	put_bytes(w, nil)
	put_bytes(w, password)
	put_string(w, "text/plain")
	reply, cwhy := call(
		c,
		SECRETS,
		"/org/freedesktop/secrets",
		"org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface",
		"UnlockWithMasterPassword",
		"o(oayays)",
		body[:],
	)
	wipe(body[:])
	if cwhy != "" {
		return false, cwhy
	}
	if reply.type == .Error {
		if reply.error_name == "org.gnome.keyring.Error.Denied" {
			return true, ""
		}
		return false, fmt.tprintf("the unlock: %s", error_text(reply))
	}
	return false, ""
}

// unlock does steps 2 to 4 on a connection that has logged in.
unlock :: proc(c: ^Conn, password: []u8) -> Result {
	hello, hwhy := call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil)
	if hwhy != "" {
		return {.Failed, hwhy}
	}
	if hello.type == .Error {
		return {.Failed, fmt.tprintf("the bus refused Hello: %s", error_text(hello))}
	}
	locked, no_keyring, why := is_locked(c)
	switch {
	case why != "":
		return {.Failed, why}
	case no_keyring:
		return {.No_Keyring, ""}
	case !locked:
		return {.Already_Unlocked, ""}
	}
	session, swhy := open_session(c)
	if swhy != "" {
		return {.Failed, swhy}
	}
	denied, uwhy := send_password(c, session, password)
	switch {
	case uwhy != "":
		return {.Failed, uwhy}
	case denied:
		return {.Wrong_Password, ""}
	}
	locked, no_keyring, why = is_locked(c)
	switch {
	case why != "":
		return {.Failed, why}
	case no_keyring:
		return {.Failed, "the login keyring went away during the unlock"}
	case locked:
		return {.Failed, "the daemon took the password, and the login keyring is still locked"}
	}
	return {.Unlocked, ""}
}

// run is the whole work: the credential at credential, the bus at address
// (a D-Bus address), all within timeout, logging in as uid.
run :: proc(credential, address: string, timeout: time.Duration, uid: u32) -> Result {
	password, status, cwhy := read_credential(credential)
	switch status {
	case .Missing:
		return {.No_Credential, credential if credential != "" else "CREDENTIALS_DIRECTORY is not set"}
	case .Failed:
		return {.Failed, cwhy}
	case .Ok:
	}
	defer {
		wipe(password)
		delete(password)
	}
	path, awhy := socket_path(address, context.temp_allocator)
	if awhy != "" {
		return {.Failed, awhy}
	}
	fd, dwhy := dial(path)
	if dwhy != "" {
		return {.Failed, dwhy}
	}
	c: Conn
	conn_init(&c, fd, timeout)
	defer conn_close(&c)
	if w := authenticate(&c, uid); w != "" {
		return {.Failed, w}
	}
	return unlock(&c, password)
}

// ── the command ──────────────────────────────────────────────────────────────

USAGE :: `usage: ravnix-keyring-unlock [--credential FILE] [--bus ADDRESS]

Unlocks the login keyring of the running gnome-keyring daemon with the
password in a systemd credential, when it is locked. It never prompts.

  --credential FILE  the password (default: $CREDENTIALS_DIRECTORY/` + CREDENTIAL_NAME + `)
  --bus ADDRESS      the session bus (default: $DBUS_SESSION_BUS_ADDRESS, or
                     unix:path=$XDG_RUNTIME_DIR/bus)

Exit status: 0 unlocked, or nothing to do (no credential, already unlocked,
no login keyring, or a wrong password, which it warns about); 1 it could
not unlock; 2 bad usage. It prints one line on standard error.`

// Env is what the command reads from its environment.
Env :: struct {
	credentials_directory: string,
	bus_address:           string,
	runtime_dir:           string,
	journal_stream:        string,
}

// journal_prefix reports whether fd is the journal stream that
// JOURNAL_STREAM ("DEVICE:INODE") names, so that a "<N>" prefix sets the
// line's priority there and nowhere else.
journal_prefix :: proc(stream: string, fd: linux.Fd) -> bool {
	colon := strings.index_byte(stream, ':')
	if colon <= 0 || colon == len(stream) - 1 {
		return false
	}
	dev, dok := strconv.parse_u64(stream[:colon], 10)
	ino, iok := strconv.parse_u64(stream[colon + 1:], 10)
	if !dok || !iok {
		return false
	}
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE {
		return false
	}
	return u64(st.dev) == dev && u64(st.ino) == ino
}

usage_error :: proc(stderr: ^os.File, text: string) -> int {
	fmt.fprintfln(stderr, "ravnix-keyring-unlock: %s\n%s", text, USAGE)
	return 2
}

// cli is the command for the arguments after the program's name; it prints
// to stderr and returns the exit status.
cli :: proc(args: []string, env: Env, stderr: ^os.File) -> int {
	credential, bus := "", ""
	has_credential, has_bus := false, false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			fmt.fprintln(stderr, USAGE)
			return 0
		case "--credential", "--bus":
			if i + 1 >= len(args) {
				return usage_error(stderr, fmt.tprintf("%s needs a value", args[i]))
			}
			seen := &has_credential if args[i] == "--credential" else &has_bus
			if seen^ {
				return usage_error(stderr, fmt.tprintf("%s given twice", args[i]))
			}
			seen^ = true
			if args[i] == "--credential" {
				credential = args[i + 1]
			} else {
				bus = args[i + 1]
			}
			i += 1
		case:
			return usage_error(stderr, fmt.tprintf("unknown argument %q", printable(args[i])))
		}
	}
	if !has_credential && env.credentials_directory != "" {
		credential = fmt.tprintf("%s/%s", env.credentials_directory, CREDENTIAL_NAME)
	}
	if !has_bus {
		bus = default_address(env.bus_address, env.runtime_dir, context.temp_allocator)
	}
	r := run(credential, bus, TIMEOUT, u32(linux.getuid()))
	text := line(r)
	if journal_prefix(env.journal_stream, linux.Fd(os.fd(stderr))) {
		fmt.fprintfln(stderr, "<%d>%s", priority(r.outcome), text)
	} else {
		fmt.fprintln(stderr, text)
	}
	return exit_code(r.outcome)
}

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("ravnix-keyring-unlock: there is no memory to run")
		os.exit(1)
	}
	context.allocator = virtual.arena_allocator(&arena)
	env := Env {
		credentials_directory = os.get_env("CREDENTIALS_DIRECTORY", context.allocator),
		bus_address           = os.get_env("DBUS_SESSION_BUS_ADDRESS", context.allocator),
		runtime_dir           = os.get_env("XDG_RUNTIME_DIR", context.allocator),
		journal_stream        = os.get_env("JOURNAL_STREAM", context.allocator),
	}
	code := cli(os.args[1:], env, os.stderr)
	virtual.arena_destroy(&arena)
	os.exit(code)
}
