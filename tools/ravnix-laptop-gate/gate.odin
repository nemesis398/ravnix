// What the gate lets through, and how it refuses the rest. sshd runs it in
// place of whatever the server asked for and puts that in
// SSH_ORIGINAL_COMMAND; nothing of it reaches a shell. A call is one of
// the verbs below, byte for byte, with no argument: no verb needs one.
package ravnix_laptop_gate

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

Verb :: enum {
	None,
	Ping,
	Facts,
	Battery,
	Charge_Mode,
	Power,
}

// The names the server calls the verbs by, in the order the refusal lists
// them.
VERB_NAMES := [Verb]string {
	.None        = "",
	.Ping        = "ping",
	.Facts       = "facts",
	.Battery     = "battery",
	.Charge_Mode = "charge-mode",
	.Power       = "power",
}

ALLOWED :: "ping, facts, battery, charge-mode, power"

Refusal :: enum {
	None,
	// No command: a shell, a subsystem, or an empty one.
	Empty,
	// Longer than MAX_COMMAND.
	Too_Long,
	// A byte below 0x20 (NUL, a newline, a tab, an escape) or DEL.
	Control,
	// A character that means something to a shell.
	Metacharacter,
	// A verb, followed by anything.
	Arguments,
	// Anything else.
	Unknown,
}

// The longest command the gate reads. The longest verb, charge-mode, has
// 11 bytes, so nothing allowed is near it; and a refused command of up to
// this many bytes, each escaped to at most four, still fits one log line.
MAX_COMMAND :: 64

// The exit statuses: sysexits' EX_NOPERM for a refusal, EX_SOFTWARE for a
// program that could not be started, EX_USAGE for arguments the gate's own
// command line does not take. ravnix-laptop passes each on.
REFUSED :: 77
EXEC_FAILED :: 70
USAGE_ERROR :: 64

// The shell's metacharacters, and the backslash and quotes that ravnix-
// laptop quotes a word with. A space separates words and is not one.
METACHARACTERS :: "|&;<>()$`\\\"'*?[]#~!{}"

parse :: proc(command: string) -> (verb: Verb, refusal: Refusal) {
	if len(command) == 0 {
		return .None, .Empty
	}
	if len(command) > MAX_COMMAND {
		return .None, .Too_Long
	}
	for c in transmute([]byte)command {
		if c < 0x20 || c == 0x7f {
			return .None, .Control
		}
	}
	if strings.contains_any(command, METACHARACTERS) {
		return .None, .Metacharacter
	}
	word := command
	if space := strings.index_byte(command, ' '); space >= 0 {
		word = command[:space]
	}
	for name, v in VERB_NAMES {
		if v != .None && name == word {
			if word != command {
				return .None, .Arguments
			}
			return v, .None
		}
	}
	return .None, .Unknown
}

// escape writes s for a log line: printable ASCII as it is, a backslash and
// a quote with a backslash, and every other byte as \xHH.
escape :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(0, len(s) + 8, allocator)
	for c in transmute([]byte)s {
		switch {
		case c == '\\' || c == '"':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, c)
		case c >= 0x20 && c < 0x7f:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "\\x%02x", c)
		}
	}
	return strings.to_string(b)
}

// reason is why, in words, for the caller and for the log.
reason :: proc(command: string, refusal: Refusal, allocator: runtime.Allocator) -> string {
	switch refusal {
	case .None:
		return ""
	case .Empty:
		return "no command (a shell, a subsystem or an empty command)"
	case .Too_Long:
		return fmt.aprintf("longer than %d bytes", MAX_COMMAND, allocator = allocator)
	case .Control:
		return "a control character"
	case .Metacharacter:
		return "a shell metacharacter"
	case .Arguments:
		word := command[:strings.index_byte(command, ' ')]
		return fmt.aprintf("%s takes no arguments", word, allocator = allocator)
	case .Unknown:
		return "not an allowed call"
	}
	return ""
}

// refusal_line is the one line the journal gets. A command is quoted and
// escaped, or, when it is empty or too long, named by its size alone.
refusal_line :: proc(command: string, refusal: Refusal, client: string, allocator: runtime.Allocator) -> string {
	what: string
	#partial switch refusal {
	case .Empty:
		what = "an empty command"
	case .Too_Long:
		what = fmt.aprintf("a command of %d bytes", len(command), allocator = allocator)
	case:
		what = fmt.aprintf("\"%s\"", escape(command, allocator), allocator = allocator)
	}
	from := client if client != "" else "an unknown address"
	return fmt.aprintf("refused %s from %s: %s", what, from, reason(command, refusal, allocator), allocator = allocator)
}

// client_of takes the client's address from SSH_CONNECTION ("ADDRESS PORT
// ADDRESS PORT"), when it looks like one: digits, hex letters, dots and
// colons, and a zone (%wt0) after them.
client_of :: proc(ssh_connection: string, allocator: runtime.Allocator) -> string {
	space := strings.index_byte(ssh_connection, ' ')
	address := ssh_connection if space < 0 else ssh_connection[:space]
	if len(address) == 0 || len(address) > 64 {
		return ""
	}
	for c in transmute([]byte)address {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == ':' || c == '%' || c == '_' || c == '-'
		if !ok {
			return ""
		}
	}
	return strings.clone(address, allocator)
}

Config :: struct {
	// Where sysfs and /dev/log are: "/" on the laptop, a fixture in a test.
	root:    string,
	// What the server asked for, SSH_ORIGINAL_COMMAND.
	command: string,
	// The server's address, for the log.
	client:  string,
	// HOME and USER, for machine-facts.
	home:    string,
	user:    string,
	// machine-facts, by its store path.
	facts:   string,
	// The PATH machine-facts gets.
	path:    string,
}

// A program to run in the gate's place.
Exec :: struct {
	path: string,
	argv: []string,
	env:  []string,
}

Result :: struct {
	status: int,
	stdout: string,
	stderr: string,
	// The journal's line, for a refusal; nothing for an answer.
	log:    string,
	// For facts: what to run in the gate's place.
	exec:   Exec,
}

// decide answers the command, or says how to refuse it.
decide :: proc(cfg: Config, allocator: runtime.Allocator) -> (r: Result) {
	verb, refusal := parse(cfg.command)
	switch verb {
	case .None:
		r.status = REFUSED
		r.stderr = fmt.aprintf("ravnix-laptop-gate: refused: %s. huginn answers only: %s\n", reason(cfg.command, refusal, allocator), ALLOWED, allocator = allocator)
		r.log = refusal_line(cfg.command, refusal, cfg.client, allocator)
	case .Ping:
		r.stdout = "huginn is up\n"
	case .Battery:
		r.stdout = battery(cfg.root, allocator)
	case .Charge_Mode:
		r.stdout = charge_mode(cfg.root, allocator)
	case .Power:
		r.stdout = power(cfg.root, allocator)
	case .Facts:
		// Only by an absolute path: a bare name is looked up in the working
		// directory, the user's home under sshd. A build without the
		// define fails closed.
		if !strings.has_prefix(cfg.facts, "/") {
			r.status = EXEC_FAILED
			r.stderr = "ravnix-laptop-gate: facts is not available: built without the store path of machine-facts\n"
			return
		}
		env := make([dynamic]string, 0, 6, allocator)
		append(&env, strings.concatenate({"PATH=", cfg.path}, allocator))
		if cfg.home != "" {
			append(&env, strings.concatenate({"HOME=", cfg.home}, allocator))
		}
		if cfg.user != "" {
			append(&env, strings.concatenate({"USER=", cfg.user}, allocator))
			append(&env, strings.concatenate({"LOGNAME=", cfg.user}, allocator))
		}
		append(&env, "MACHINE_FACTS_NO_SUDO=1")
		// The server may ask often, and a dGPU woken from runtime suspend
		// costs battery: machine-facts leaves out what may wake it.
		append(&env, "MACHINE_FACTS_NO_DGPU_WAKE=1")
		argv := make([]string, 1, allocator)
		argv[0] = cfg.facts
		r.exec = Exec {
			path = cfg.facts,
			argv = argv,
			env  = env[:],
		}
	}
	return
}

// answer decides, and sends a refusal's one line to the journal.
answer :: proc(cfg: Config, allocator: runtime.Allocator) -> (r: Result) {
	r = decide(cfg, allocator)
	if r.log != "" {
		send_log(cfg.root, r.log, allocator)
	}
	return
}

// authpriv (10) times 8, plus warning (4).
SYSLOG_AUTHPRIV_WARNING :: 10 * 8 + 4

// send_log sends one message to journald's syslog socket, the way syslog(3)
// does, under the gate's name: journalctl -t ravnix-laptop-gate shows it.
// It never waits for room in the socket's queue.
// Not stderr: sshd hands a forced command's stderr to the client, so the
// server would read it and the laptop's journal would not. It never fails
// the refusal: without the socket there is no line, and the gate refuses
// all the same.
send_log :: proc(root, text: string, allocator := context.allocator) {
	path := strings.concatenate({root, "/dev/log"}, allocator)
	fd, errno := linux.socket(.UNIX, .DGRAM, {.CLOEXEC}, .HOPOPT)
	if errno != .NONE {
		return
	}
	defer linux.close(fd)
	addr := linux.Sock_Addr_Un {
		sun_family = .UNIX,
	}
	if len(path) >= len(addr.sun_path) {
		return
	}
	copy(addr.sun_path[:], path)
	message := fmt.aprintf("<%d>ravnix-laptop-gate: %s", SYSLOG_AUTHPRIV_WARNING, text, allocator = allocator)
	// Without waiting: a journald that stalls fills the socket's queue,
	// and a refusal that waited for room would hang the server's session.
	// The line is lost then (EAGAIN), and the refusal stands.
	_, _ = linux.sendto(fd, transmute([]u8)message, {.DONTWAIT}, &addr)
}

// start runs e in the gate's place, by its path and with its environment
// alone; no shell reads any of it. It returns only when that failed.
start :: proc(e: Exec, allocator: runtime.Allocator) -> (errno: linux.Errno) {
	path := strings.clone_to_cstring(e.path, allocator)
	argv := make([]cstring, len(e.argv) + 1, allocator)
	for a, i in e.argv {
		argv[i] = strings.clone_to_cstring(a, allocator)
	}
	envp := make([]cstring, len(e.env) + 1, allocator)
	for kv, i in e.env {
		envp[i] = strings.clone_to_cstring(kv, allocator)
	}
	return linux.execve(path, raw_data(argv), raw_data(envp))
}
