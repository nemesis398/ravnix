// ravnix-tap-ask asks on the laptop's own screen before sudo waits for a tap
// on the security key (README.md). pam_exec runs it as root, right before
// pam_u2f in sudo's auth stack; exit 0 lets pam_u2f run, anything else skips
// it, and the password asks as before. This file holds the decision; main.odin
// is the command, and popup.odin runs the popup.
package ravnix_tap_ask

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// How long the popup waits for an answer, and how soon an answer counts as
// typed before the popup could be read: a key held down, or typing that went
// on in the window the popup took the keyboard from.
TIMEOUT :: 30 * time.Second
MIN_READ :: 1 * time.Second

// The longest command line the popup shows, in bytes, and how far up the
// process tree the origin is looked for.
MAX_COMMAND :: 200
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
	// The user has no Wayland socket: there is no screen to ask on.
	No_Session,
}

Origin_Kind :: enum {
	// A terminal on the laptop (PAM_TTY).
	Terminal,
	// An ssh login: the server's laptop-access link.
	Ssh,
	// A program without a terminal.
	No_Terminal,
}

Origin :: struct {
	kind:    Origin_Kind,
	tty:     string,
	// The ssh client's address, from SSH_CONNECTION; "" when unknown.
	client:  string,
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
	append(&all, cfg.root if cfg.root != "" else "/")
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
	if !has_mapping(cfg, req.home) {
		req.skip = .No_Mapping
		return
	}
	if !has_fido_key(cfg) {
		req.skip = .No_Key
		return
	}
	req.origin = origin_of(cfg, allocator)
	req.command = command_of(cfg, allocator)
	if is_locked(cfg, req.uid) {
		req.skip = .Locked
		return
	}
	req.runtime_dir = system_path(cfg, allocator, "run", "user", fmt.aprint(req.uid))
	req.wayland, ok = wayland_socket(req.runtime_dir)
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

// wayland_socket finds the user's Wayland socket, wayland-N, the lowest N
// when there are several. It must be a socket: a file of that name left
// behind is no session.
wayland_socket :: proc(runtime_dir: string) -> (name: string, ok: bool) {
	entries, err := os.read_all_directory_by_path(runtime_dir, context.allocator)
	if err != nil {
		return
	}
	best := -1
	for e in entries {
		digits := strings.trim_prefix(e.name, "wayland-")
		if digits == e.name || digits == "" || e.type != .Socket {
			continue
		}
		n, is_number := strconv.parse_int(digits, 10)
		if !is_number || n < 0 || fmt.aprint(n) != digits {
			continue
		}
		if best < 0 || n < best {
			best, name = n, e.name
		}
	}
	return name, best >= 0
}

// origin_of tells where the sudo came from. An ssh login is the server's
// laptop-access link, the only key huginn's sshd takes: sshd (or sshd-session,
// its per-connection program since OpenSSH 9.8) among sudo's ancestors, or
// SSH_CONNECTION in sudo's environment. That comes first, since a terminal
// can be made inside such a login. Then PAM_TTY. The signal is best effort:
// a program that runs as the user can start sudo from elsewhere (README.md).
origin_of :: proc(cfg: Config, allocator: runtime.Allocator) -> (o: Origin) {
	context.allocator = allocator
	o.tty = sanitize(cfg.tty, MAX_COMMAND)
	client, from_env := ssh_client(cfg, cfg.parent)
	if from_env || has_sshd_ancestor(cfg, cfg.parent) {
		o.kind = .Ssh
		o.client = client
		return
	}
	if cfg.tty != "" {
		o.kind = .Terminal
		return
	}
	o.kind = .No_Terminal
	if ppid, ok := parent_of(cfg, cfg.parent); ok {
		o.process = sanitize(read_comm(cfg, ppid), 32)
	}
	return
}

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
		program := read_comm(cfg, current)
		if target, err := os.read_link(system_path(cfg, context.allocator, "proc", fmt.aprint(current), "exe"), context.allocator); err == nil {
			program = target[strings.last_index_byte(target, '/') + 1:]
		}
		for n in names {
			if program == n {
				return true
			}
		}
	}
	return false
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
	return sanitize(strings.join(args, " "), MAX_COMMAND)
}

// sanitize makes text safe to show: a control character, which could start a
// new line in the popup and fake one of its own, is a "?", invalid UTF-8 is
// U+FFFD, and text longer than max bytes is cut at a character and ends in
// "…".
sanitize :: proc(text: string, max: int, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text), allocator)
	for r in text {
		if strings.builder_len(b) + utf8.rune_size(r) > max {
			strings.write_string(&b, "…")
			break
		}
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			strings.write_byte(&b, '?')
		} else {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

origin_text :: proc(o: Origin, allocator: runtime.Allocator) -> string {
	switch o.kind {
	case .Ssh:
		if o.client != "" {
			return fmt.aprintf("ssh from %s (the server's laptop-access link)", o.client, allocator = allocator)
		}
		return "ssh (the server's laptop-access link)"
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
	if d.skip != .None {
		d.answer = .Deny
		return
	}
	res := run_popup(popup_command(cfg, req, allocator), popup_env(cfg, req, allocator), ENTRIES, cfg.timeout, allocator)
	d.answer = answer_of(res, cfg.min_read)
	return
}
