// ravnix-tap-ask asks on the laptop's own screen before sudo waits for a tap
// on the security key (README.md). pam_exec runs it as root, right before
// pam_u2f in sudo's auth stack; exit 0 lets pam_u2f run, anything else skips
// it, and the password asks as before. A sudo over ssh gets no popup at all. This file holds the decision; main.odin
// is the command, and popup.odin runs the popup.
package ravnix_tap_ask

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

// How long the popup waits for an answer, and how soon an answer counts as
// typed before the popup could be read: a key held down, or typing that went
// on in the window the popup took the keyboard from.
TIMEOUT :: 30 * time.Second
MIN_READ :: 1 * time.Second

// The longest command line the popup shows, in bytes: a longer one gets no
// popup, since a cut would hide its tail, which is where a padded command
// puts what it runs. And how far up the process tree sshd is looked for.
MAX_COMMAND :: 400
MAX_ANCESTORS :: 64

// What one run reads. The process's own values, or a test's: root is "" for
// the real system and a directory that stands in for / otherwise.
Config :: struct {
	root:       string,
	// sudo's process: pam_exec's child has sudo for its parent.
	parent:     int,
	// PAM_USER, PAM_TTY and PAM_TYPE, as pam_exec sets them.
	user:       string,
	tty:        string,
	pam_type:   string,
	fuzzel:     string,
	setpriv:    string,
	// The PATH of the popup.
	popup_path: string,
	timeout:    time.Duration,
	min_read:   time.Duration,
}

// Why there is no popup. Each one skips pam_u2f.
Skip :: enum {
	None,
	// PAM_TYPE is not auth.
	Not_Auth,
	// The user is not in /etc/passwd.
	No_User,
	// The user has no ~/.config/Yubico/u2f_keys: pam_u2f would fail anyway.
	No_Mapping,
	// No FIDO key is plugged in: there would be nothing to touch.
	No_Key,
	// swaylock runs: the screen is locked and would hide the popup.
	Locked,
	// No Sway of the user's greetd session listens on a Wayland socket:
	// there is no screen to ask on.
	No_Session,
	// The sudo came over ssh, the server's laptop-access link: refused, with
	// no popup, and logged.
	Remote,
	// The command line is longer than MAX_COMMAND.
	Too_Long,
}

// Whether a sudo came over ssh, how that was told, and the client's address
// where it is known.
Remote :: struct {
	remote: bool,
	how:    string,
	client: string,
}

Origin_Kind :: enum {
	// A terminal on the laptop (PAM_TTY).
	Terminal,
	// A program without a terminal.
	No_Terminal,
}

Origin :: struct {
	kind:    Origin_Kind,
	tty:     string,
	// The program that ran sudo, for No_Terminal.
	process: string,
}

// What the popup is about, and where it goes.
Request :: struct {
	skip:        Skip,
	user:        string,
	uid:         int,
	gid:         int,
	home:        string,
	command:     string,
	origin:      Origin,
	// Whether it came over ssh, and how that was told.
	remote:      Remote,
	// The Wayland socket's name in runtime_dir, such as wayland-1.
	wayland:     string,
	runtime_dir: string,
}

default_config :: proc() -> Config {
	return Config {
		fuzzel = FUZZEL,
		setpriv = SETPRIV,
		popup_path = "/run/current-system/sw/bin",
		timeout = TIMEOUT,
		min_read = MIN_READ,
	}
}

// system_path is a path of the system, under cfg.root.
system_path :: proc(cfg: Config, allocator: runtime.Allocator, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1, allocator)
	// "" for the real system, so that a path is "/proc/..." and compares
	// equal to what the kernel prints.
	append(&all, cfg.root)
	append(&all, ..parts)
	joined, _ := strings.join(all[:], "/", allocator)
	return joined
}

// prepare reads what the popup needs, or why there is none. Everything it
// returns is in allocator.
prepare :: proc(cfg: Config, allocator: runtime.Allocator) -> (req: Request) {
	context.allocator = allocator
	if cfg.pam_type != "auth" {
		req.skip = .Not_Auth
		return
	}
	ok: bool
	req.user = cfg.user
	req.uid, req.gid, req.home, ok = lookup_user(cfg, cfg.user)
	if !ok {
		req.skip = .No_User
		return
	}
	req.command = command_of(cfg, allocator)
	req.remote = remote_of(cfg, allocator)
	if req.remote.remote {
		req.skip = .Remote
		return
	}
	if !has_mapping(cfg, req.home) {
		req.skip = .No_Mapping
		return
	}
	if !has_fido_key(cfg) {
		req.skip = .No_Key
		return
	}
	if len(req.command) > MAX_COMMAND {
		req.skip = .Too_Long
		return
	}
	req.origin = origin_of(cfg, allocator)
	if is_locked(cfg, req.uid) {
		req.skip = .Locked
		return
	}
	req.runtime_dir = system_path(cfg, allocator, "run", "user", fmt.aprint(req.uid))
	req.wayland, ok = wayland_of(cfg, req.uid, req.runtime_dir)
	if !ok {
		req.skip = .No_Session
		return
	}
	return
}

// lookup_user finds name in /etc/passwd: its uid, gid and home.
lookup_user :: proc(cfg: Config, name: string) -> (uid, gid: int, home: string, ok: bool) {
	if name == "" || strings.contains_any(name, ":\n") {
		return
	}
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "etc", "passwd"), context.allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, ":")
		if len(fields) != 7 || fields[0] != name {
			continue
		}
		u, u_ok := strconv.parse_int(fields[2], 10)
		g, g_ok := strconv.parse_int(fields[3], 10)
		if !u_ok || !g_ok || u < 0 || g < 0 || !strings.has_prefix(fields[5], "/") {
			return
		}
		return u, g, fields[5], true
	}
	return
}

// has_mapping tells whether pam_u2f has a mapping to read: the user's own
// ~/.config/Yubico/u2f_keys (pam_u2f ignores XDG_CONFIG_HOME under sudo,
// which is setuid), a regular file that is not empty.
has_mapping :: proc(cfg: Config, home: string) -> bool {
	info, err := os.stat(system_path(cfg, context.allocator, home, ".config/Yubico/u2f_keys"), context.allocator)
	return err == nil && info.type == .Regular && info.size > 0
}

// FIDO's HID usage page, 0xF1D0, as a report descriptor declares it: the
// two-byte Usage Page item (0x06) with the page in little-endian order. It is
// what libfido2 looks for to tell a security key from a keyboard.
FIDO_USAGE_PAGE :: "\x06\xd0\xf1"

// has_fido_key tells whether a FIDO key is plugged in.
has_fido_key :: proc(cfg: Config) -> bool {
	dir := system_path(cfg, context.allocator, "sys/class/hidraw")
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return false
	}
	for e in entries {
		data, rerr := os.read_entire_file(strings.join({dir, e.name, "device/report_descriptor"}, "/"), context.allocator)
		if rerr == nil && strings.contains(string(data), FIDO_USAGE_PAGE) {
			return true
		}
	}
	return false
}

// The names swaylock runs under: its own, and that of NixOS's wrapper
// (a comm is cut at 15 bytes).
LOCKERS :: [?]string{"swaylock", ".swaylock-wrapp"}

// is_locked tells whether a swaylock of the user runs.
is_locked :: proc(cfg: Config, uid: int) -> bool {
	dir := system_path(cfg, context.allocator, "proc")
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return false
	}
	lockers := LOCKERS
	for e in entries {
		pid, is_pid := strconv.parse_int(e.name, 10)
		if !is_pid || pid <= 0 {
			continue
		}
		comm := read_comm(cfg, pid)
		named := false
		for l in lockers {
			named ||= comm == l
		}
		if named && real_uid(cfg, pid) == uid {
			return true
		}
	}
	return false
}

// The names Sway runs under: its own, and that of a wrapped Sway.
SWAYS :: [?]string{"sway", ".sway-wrapped"}

// wayland_of finds the Wayland socket of the user's session: the socket that
// the user's Sway listens on, where that Sway is the one greetd started for
// the session, not a Sway that something else started (a headless one under
// the user's systemd, or one inside the session's Sway). Any process of the
// user may bind a wayland-N of its own, the lowest number included, so the
// socket's name alone says nothing. The inode of each socket Sway holds open
// is matched against the paths in /proc/net/unix. The socket must be a
// wayland-N in runtime_dir and still a socket there.
wayland_of :: proc(cfg: Config, uid: int, runtime_dir: string) -> (name: string, ok: bool) {
	sway, found := session_sway(cfg, uid)
	if !found {
		return
	}
	inodes := socket_inodes(cfg, sway)
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", "net", "unix"), context.allocator)
	if err != nil {
		return
	}
	best := -1
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line)
		if len(fields) < 8 {
			continue
		}
		inode, is_inode := strconv.parse_int(fields[6], 10)
		if !is_inode || !(inode in inodes) {
			continue
		}
		path := strings.join(fields[7:], " ")
		slash := strings.last_index_byte(path, '/')
		if slash < 0 || path[:slash] != runtime_dir {
			continue
		}
		base := path[slash + 1:]
		digits := strings.trim_prefix(base, "wayland-")
		n, is_number := strconv.parse_int(digits, 10)
		if digits == base || !is_number || n < 0 || fmt.aprint(n) != digits {
			continue
		}
		info, serr := os.lstat(path, context.allocator)
		if serr != nil || info.type != .Socket {
			continue
		}
		if best < 0 || n < best {
			best, name = n, base
		}
	}
	return name, best >= 0
}

// session_sway finds the user's Sway that greetd started: a process named
// Sway with the user's real uid, whose nearest ancestor that is greetd or a
// Sway is greetd.
session_sway :: proc(cfg: Config, uid: int) -> (pid: int, ok: bool) {
	entries, err := os.read_all_directory_by_path(system_path(cfg, context.allocator, "proc"), context.allocator)
	if err != nil {
		return
	}
	for e in entries {
		candidate, is_pid := strconv.parse_int(e.name, 10)
		if !is_pid || candidate <= 0 || !is_sway(read_comm(cfg, candidate)) || real_uid(cfg, candidate) != uid {
			continue
		}
		current := candidate
		for _ in 0 ..< MAX_ANCESTORS {
			next, has_parent := parent_of(cfg, current)
			if !has_parent || next <= 1 || next == current {
				break
			}
			current = next
			if program_of(cfg, current) == "greetd" {
				return candidate, true
			}
			if is_sway(read_comm(cfg, current)) {
				break
			}
		}
	}
	return
}

is_sway :: proc(comm: string) -> bool {
	sways := SWAYS
	for n in sways {
		if comm == n {
			return true
		}
	}
	return false
}

// socket_inodes are the inodes of the sockets that process pid holds open.
socket_inodes :: proc(cfg: Config, pid: int) -> map[int]struct{} {
	inodes := make(map[int]struct{})
	dir := system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "fd")
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return inodes
	}
	for e in entries {
		target, lerr := os.read_link(strings.join({dir, e.name}, "/"), context.allocator)
		if lerr != nil || !strings.has_prefix(target, "socket:[") || !strings.has_suffix(target, "]") {
			continue
		}
		if inode, ok := strconv.parse_int(target[len("socket:["):len(target) - 1], 10); ok {
			inodes[inode] = {}
		}
	}
	return inodes
}

// origin_of tells where a local sudo came from, for the popup: a terminal on
// the laptop (PAM_TTY), or the program that ran it.
origin_of :: proc(cfg: Config, allocator: runtime.Allocator) -> (o: Origin) {
	context.allocator = allocator
	if cfg.tty != "" {
		o.kind = .Terminal
		o.tty = sanitize(cfg.tty, 64)
		return
	}
	o.kind = .No_Terminal
	if ppid, ok := parent_of(cfg, cfg.parent); ok {
		o.process = sanitize(read_comm(cfg, ppid), 32)
	}
	return
}

// remote_of tells whether the sudo came over ssh, which on huginn is the
// server's laptop-access link, the one key its sshd takes. The caller over
// the link controls sudo's environment, its terminal and, by a double fork,
// its parent; it does not control the login session the kernel and logind
// put it in. So the session decides first:
//
//   - sudo's audit session (/proc/PID/sessionid, which only a process with
//     CAP_AUDIT_CONTROL can change, and logind's session id when audit is on)
//     and the session-N.scope of its cgroup, each looked up in logind's state
//     file /run/systemd/sessions/N, as sd_session_is_remote does: REMOTE=1,
//     or SERVICE=sshd;
//   - then an sshd or sshd-session among sudo's ancestors;
//   - then SSH_CONNECTION in sudo's environment, which can only add.
//
// Leaving the ssh session is possible: a process of the user can have its
// own systemd or Sway start sudo (systemd-run --user, swaymsg exec), and
// that sudo is a local one. Only a forced command on the link's key closes
// that (README.md).
remote_of :: proc(cfg: Config, allocator: runtime.Allocator) -> (r: Remote) {
	context.allocator = allocator
	client, from_env := ssh_client(cfg, cfg.parent)
	r.client = client
	if id, ok := audit_session(cfg, cfg.parent); ok && session_is_remote(cfg, id) {
		r.remote, r.how = true, fmt.aprintf("its login session %s is remote", id)
	} else if id, ok = cgroup_session(cfg, cfg.parent); ok && session_is_remote(cfg, id) {
		r.remote, r.how = true, fmt.aprintf("its session scope %s is remote", id)
	} else if has_sshd_ancestor(cfg, cfg.parent) {
		r.remote, r.how = true, "sshd is among its ancestors"
	} else if from_env {
		r.remote, r.how = true, "its environment has SSH_CONNECTION"
	}
	return
}

// The audit session of a process that has none.
NO_AUDIT_SESSION :: "4294967295"

audit_session :: proc(cfg: Config, pid: int) -> (id: string, ok: bool) {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "sessionid"), context.allocator)
	if err != nil {
		return
	}
	id = strings.trim_space(string(data))
	return id, id != NO_AUDIT_SESSION && is_session_id(id)
}

// cgroup_session reads the session of a session-N.scope in the process's
// unified cgroup path.
cgroup_session :: proc(cfg: Config, pid: int) -> (id: string, ok: bool) {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "cgroup"), context.allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "0::") {
			continue
		}
		for part in strings.split(line[len("0::"):], "/") {
			if strings.has_prefix(part, "session-") && strings.has_suffix(part, ".scope") {
				id = part[len("session-"):len(part) - len(".scope")]
				if is_session_id(id) {
					return id, true
				}
			}
		}
	}
	return
}

// is_session_id refuses anything that would leave /run/systemd/sessions.
is_session_id :: proc(id: string) -> bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for c in transmute([]u8)id {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
			return false
		}
	}
	return true
}

// session_is_remote reads logind's state file of session id.
session_is_remote :: proc(cfg: Config, id: string) -> bool {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "run", "systemd", "sessions", id), context.allocator)
	if err != nil {
		return false
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if line == "REMOTE=1" || line == "SERVICE=sshd" {
			return true
		}
	}
	return false
}

// SYSLOG is where log_line writes, under cfg.root: journald's socket for
// syslog messages.
SYSLOG :: "dev/log"

// log_line sends one message to the journal, as authpriv.warning, the way
// syslog(3) would. It never fails the run: without the socket there is no
// log line, and the decision stands.
log_line :: proc(cfg: Config, text: string) {
	path := system_path(cfg, context.allocator, SYSLOG)
	fd, errno := linux.socket(.UNIX, .DGRAM, {.CLOEXEC}, .HOPOPT)
	if errno != .NONE {
		return
	}
	defer { _ = linux.close(fd) }
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if len(path) >= len(addr.sun_path) {
		return
	}
	copy(addr.sun_path[:], path)
	message := fmt.aprintf("<%d>ravnix-tap-ask: %s", SYSLOG_AUTHPRIV_WARNING, text)
	_, _ = linux.sendto(fd, transmute([]u8)message, {}, &addr)
}

// authpriv (10) times 8, plus warning (4).
SYSLOG_AUTHPRIV_WARNING :: 10 * 8 + 4

// ssh_client reads SSH_CONNECTION from the environment of process pid: the
// client's address is its first field.
ssh_client :: proc(cfg: Config, pid: int) -> (client: string, found: bool) {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "environ"), context.allocator)
	if err != nil {
		return
	}
	for kv in strings.split(string(data), "\x00") {
		if !strings.has_prefix(kv, "SSH_CONNECTION=") {
			continue
		}
		fields := strings.fields(kv[len("SSH_CONNECTION="):])
		if len(fields) > 0 {
			client = sanitize(fields[0], 64)
		}
		return client, true
	}
	return
}

SSHD_NAMES :: [?]string{"sshd", "sshd-session"}

// has_sshd_ancestor walks up from pid's parent, by the program each process
// runs (its exe link, or its comm where that cannot be read).
has_sshd_ancestor :: proc(cfg: Config, pid: int) -> bool {
	names := SSHD_NAMES
	current := pid
	for _ in 0 ..< MAX_ANCESTORS {
		next, ok := parent_of(cfg, current)
		if !ok || next <= 1 || next == current {
			return false
		}
		current = next
		program := program_of(cfg, current)
		for n in names {
			if program == n {
				return true
			}
		}
	}
	return false
}

// program_of is the name of the program a process runs: the base name of its
// exe link, which the process cannot change, or its comm where the link
// cannot be read.
program_of :: proc(cfg: Config, pid: int) -> string {
	if target, err := os.read_link(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "exe"), context.allocator); err == nil {
		return target[strings.last_index_byte(target, '/') + 1:]
	}
	return read_comm(cfg, pid)
}

// parent_of reads the parent of pid from /proc/PID/stat. The comm in
// parentheses may hold spaces and parentheses itself, so the fields after it
// are counted from the last ')'.
parent_of :: proc(cfg: Config, pid: int) -> (ppid: int, ok: bool) {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "stat"), context.allocator)
	if err != nil {
		return
	}
	text := string(data)
	close := strings.last_index_byte(text, ')')
	if close < 0 {
		return
	}
	fields := strings.fields(text[close + 1:])
	if len(fields) < 2 {
		return
	}
	return strconv.parse_int(fields[1], 10)
}

read_comm :: proc(cfg: Config, pid: int) -> string {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "comm"), context.allocator)
	if err != nil {
		return ""
	}
	return strings.trim_right(string(data), "\n")
}

// real_uid reads the real uid of pid from /proc/PID/status, or -1.
real_uid :: proc(cfg: Config, pid: int) -> int {
	data, err := os.read_entire_file(system_path(cfg, context.allocator, "proc", fmt.aprint(pid), "status"), context.allocator)
	if err != nil {
		return -1
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "Uid:") {
			continue
		}
		fields := strings.fields(line[len("Uid:"):])
		if len(fields) == 0 {
			return -1
		}
		uid, ok := strconv.parse_int(fields[0], 10)
		return uid if ok else -1
	}
	return -1
}

// command_of is sudo's own command line, as the popup shows it.
command_of :: proc(cfg: Config, allocator: runtime.Allocator) -> string {
	context.allocator = allocator
	data, err := os.read_entire_file(system_path(cfg, allocator, "proc", fmt.aprint(cfg.parent), "cmdline"), allocator)
	if err != nil || len(data) == 0 {
		return "(unknown)"
	}
	args := strings.split(strings.trim_right(string(data), "\x00"), "\x00")
	// Whole: prepare refuses one longer than MAX_COMMAND.
	return sanitize(strings.join(args, " "), -1)
}

// sanitize makes text safe to show. A control character, which could start a
// new line in the popup and fake one of its own, is a "?", and so is a
// format character (Unicode's Cf: bidi controls, zero-width characters, the
// soft hyphen, tags) and a line or paragraph separator, which could reorder
// or hide a part of the text. Invalid UTF-8 is U+FFFD. With max >= 0, text
// longer than max bytes is cut at a character and ends in "…".
sanitize :: proc(text: string, max: int, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text), allocator)
	for r in text {
		if max >= 0 && strings.builder_len(b) + utf8.rune_size(r) > max {
			strings.write_string(&b, "…")
			break
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || is_format(r) {
			strings.write_byte(&b, '?')
		} else {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// The format characters of Unicode 16 (general category Cf), and the line
// and paragraph separators U+2028 and U+2029.
FORMAT_RANGES :: [?][2]rune {
	{0x00AD, 0x00AD},
	{0x0600, 0x0605},
	{0x061C, 0x061C},
	{0x06DD, 0x06DD},
	{0x070F, 0x070F},
	{0x0890, 0x0891},
	{0x08E2, 0x08E2},
	{0x180E, 0x180E},
	{0x200B, 0x200F},
	{0x2028, 0x202E},
	{0x2060, 0x2064},
	{0x2066, 0x206F},
	{0xFEFF, 0xFEFF},
	{0xFFF9, 0xFFFB},
	{0x110BD, 0x110BD},
	{0x110CD, 0x110CD},
	{0x13430, 0x1343F},
	{0x1BCA0, 0x1BCA3},
	{0x1D173, 0x1D17A},
	{0xE0001, 0xE0001},
	{0xE0020, 0xE007F},
}

is_format :: proc(r: rune) -> bool {
	ranges := FORMAT_RANGES
	for range in ranges {
		if r >= range[0] && r <= range[1] {
			return true
		}
	}
	return false
}

origin_text :: proc(o: Origin, allocator: runtime.Allocator) -> string {
	switch o.kind {
	case .Terminal:
		return fmt.aprintf("a terminal on this laptop, %s", o.tty, allocator = allocator)
	case .No_Terminal:
		if o.process != "" {
			return fmt.aprintf("a program without a terminal, %s", o.process, allocator = allocator)
		}
		return "a program without a terminal"
	}
	return ""
}

// message is the popup's text, above its two entries.
message :: proc(req: Request, allocator: runtime.Allocator) -> string {
	return fmt.aprintf(
		"sudo wants a tap on the security key\n\ncommand  %s\nuser     %s\nfrom     %s\n\nAllow, then touch the key. Deny, Esc or %d s: no tap.",
		req.command,
		sanitize(req.user, 64, allocator),
		origin_text(req.origin, allocator),
		int(TIMEOUT / time.Second),
		allocator = allocator,
	)
}

// The popup's entries, in this order: Deny is the first and the one selected,
// so an Enter by habit denies.
ENTRIES :: "Deny\nAllow\n"
ALLOW_INDEX :: "1"

// popup_command runs fuzzel as the user, never as root on the user's display:
// setpriv drops to the user's uid and gid, with no other group and no way to
// gain privileges again. fuzzel takes its look from the user's own config,
// which the theme module writes: Base, a 1 px accent frame, square corners.
popup_command :: proc(cfg: Config, req: Request, allocator: runtime.Allocator) -> []string {
	return slice_of(
		allocator,
		cfg.setpriv,
		fmt.aprintf("--reuid=%d", req.uid, allocator = allocator),
		fmt.aprintf("--regid=%d", req.gid, allocator = allocator),
		"--clear-groups",
		"--no-new-privs",
		"--",
		cfg.fuzzel,
		"--dmenu",
		"--index",
		"--only-match",
		"--no-sort",
		"--layer=overlay",
		"--lines=2",
		"--minimal-lines",
		"--namespace=ravnix-tap-ask",
		"--placeholder=Allow or Deny",
		fmt.aprintf("--mesg=%s", message(req, allocator), allocator = allocator),
	)
}

// popup_env is the whole environment of the popup: the user's session and
// nothing of sudo's or of this process.
popup_env :: proc(cfg: Config, req: Request, allocator: runtime.Allocator) -> []string {
	return slice_of(
		allocator,
		fmt.aprintf("WAYLAND_DISPLAY=%s", req.wayland, allocator = allocator),
		fmt.aprintf("XDG_RUNTIME_DIR=%s", req.runtime_dir, allocator = allocator),
		fmt.aprintf("HOME=%s", req.home, allocator = allocator),
		fmt.aprintf("USER=%s", req.user, allocator = allocator),
		fmt.aprintf("LOGNAME=%s", req.user, allocator = allocator),
		fmt.aprintf("PATH=%s", cfg.popup_path, allocator = allocator),
		"LANG=C.UTF-8",
	)
}

slice_of :: proc(allocator: runtime.Allocator, items: ..string) -> []string {
	out := make([]string, len(items), allocator)
	copy(out, items)
	return out
}

Answer :: enum {
	// Allow was chosen: pam_u2f runs.
	Allow,
	// Deny, Esc, a click elsewhere: fuzzel gives no Allow.
	Deny,
	// Allow came sooner than the popup can be read.
	Too_Soon,
	// No answer in time; the popup was closed.
	Timeout,
	// The popup did not start, failed, or printed what fuzzel never prints.
	Failed,
}

// answer_of reads what the popup did.
answer_of :: proc(res: Popup_Result, min_read: time.Duration) -> Answer {
	switch {
	case res.start_failed, res.too_much:
		return .Failed
	case res.timed_out:
		return .Timeout
	case res.exit_code != 0:
		// fuzzel exits 1 when it is closed without a choice; anything else
		// failed. Either way there is no Allow.
		return .Deny if res.exit_code == 1 && len(res.stdout) == 0 else .Failed
	}
	switch strings.trim_right(string(res.stdout), "\n") {
	case ALLOW_INDEX:
		return .Allow if res.elapsed >= min_read else .Too_Soon
	case "0":
		return .Deny
	}
	return .Failed
}

// Decision is what one run decided, for the exit status and the dry run.
Decision :: struct {
	skip:   Skip,
	answer: Answer,
}

allowed :: proc(d: Decision) -> bool {
	return d.skip == .None && d.answer == .Allow
}

// decide is the whole run: prepare, then the popup unless there is a reason
// to skip it.
decide :: proc(cfg: Config, allocator: runtime.Allocator) -> (d: Decision) {
	req := prepare(cfg, allocator)
	d.skip = req.skip
	if d.skip == .Remote {
		log_line(
			cfg,
			fmt.aprintf(
				"refused a sudo over ssh by %s%s%s (%s; no popup, no tap): %s",
				sanitize(cfg.user, 64, allocator),
				" from " if req.remote.client != "" else "",
				req.remote.client,
				req.remote.how,
				sanitize(req.command, MAX_COMMAND, allocator),
				allocator = allocator,
			),
		)
	}
	if d.skip != .None {
		d.answer = .Deny
		return
	}
	res := run_popup(popup_command(cfg, req, allocator), popup_env(cfg, req, allocator), ENTRIES, cfg.timeout, allocator)
	d.answer = answer_of(res, cfg.min_read)
	return
}
