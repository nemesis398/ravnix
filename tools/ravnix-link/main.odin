// The command: ravnix-link [OPTION...] COMMAND [ARG...]. README.md has what
// each command does on which host.
package ravnix_link

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

EX_USAGE :: 64
// What a commit from the laptop may take beyond the server's commit: ssh's
// connection, and the server's lock.
FORWARD_EXTRA :: 60_000
// How long receive waits for the delivery service to resolve a commit
// whose files are here, before it answers that the commit is queued.
DEFAULT_RECEIVE_WAIT :: 10_000

USAGE :: `usage: ravnix-link [OPTION...] COMMAND [ARG...]

On the server (muninn), forwarded to the laptop (huginn), queued while it is away:
  open URL|PATH                       open a link or a file on the laptop (xdg-open)
  notify [--topic T] [--urgency U] [--app NAME] SUMMARY [BODY]
                                      show a notification on the laptop; with
                                      --topic, also post it to that Matrix room
  notify-send [OPTION...] SUMMARY [BODY]
                                      notify-send: runs the real one, and notify
  obsidian move path=P to=P           move a note in Obsidian on the laptop
  obsidian rename path=P name=N       rename a note
  obsidian delete path=P              move a note to the trash
  vault-commit MESSAGE [PATH...]      commit PATHs (or what is staged) in the
                                      vault, once the Obsidian operations
                                      queued before it have run and the
                                      vault here shows what they did
  flush                               deliver what waits, now (a commit that
                                      waits for its next attempt included)
  deliver                             deliver whenever the laptop is back (a service)
  status                              list what waits, and the commits that failed
  dismiss                             clear the list of commits that failed
  drop ID                             let go of a request that waits (its id
                                      as status shows it): it fails, and what
                                      waits behind it goes ahead
  receive                             queue the commit on standard input, one
                                      line, which the laptop's vault-commit
                                      sends; answer with how it came out

On the laptop:
  daemon                              carry out what the server sends
  vault-commit MESSAGE PATH...        with --forward: ask the server to commit
                                      PATHs, once its copy of the vault has
                                      them as they are here

Options:
  --socket PATH         the daemon's socket (default $XDG_RUNTIME_DIR/` + SOCKET_NAME + `)
  --state DIR           the queue and the records (default $XDG_STATE_HOME/ravnix-link)
  --vault DIR           the vault: the server's git repository, where
                        vault-commit commits; on the laptop, its copy, which
                        vault-commit reads the paths in
  --git PATH            the git that vault-commit runs
  --ravnix-notify PATH  the ravnix-notify that notify --topic runs
  --xdg-open PATH, --notify-send PATH, --obsidian PATH
                        the programs the daemon runs; --notify-send is also
                        the real notify-send that notify-send runs
  --systemd-run PATH    the daemon starts each program in a scope of its own
                        with it (systemd-run --user --scope), so what the
                        program starts outlives a restart of the daemon
  --forward PATH        the laptop's: vault-commit runs it with the request on
                        its standard input, for the server's receive, and
                        reads the server's answer from its output (ssh)

Exit status: 0 done, or queued for the laptop; 1 failed; 64 bad usage.`

// The environment the command reads, given as values so a test can set it.
Environment :: struct {
	runtime_dir:   string, // XDG_RUNTIME_DIR
	state_home:    string, // XDG_STATE_HOME
	home:          string, // HOME
	cwd:           string, // the working directory
	daemon_marker: string, // RAVNIX_LINK_DAEMON
	stdin:         ^os.File, // what receive reads; nil is the process's own
}

// user_manager is the user manager's own socket, where systemd-run --user
// connects; "" without XDG_RUNTIME_DIR, when nothing is checked.
user_manager :: proc(env: Environment, allocator := context.allocator) -> string {
	return strings.concatenate({env.runtime_dir, "/systemd/private"}, allocator) if env.runtime_dir != "" else ""
}

// config_from is the configuration the environment gives, before options.
config_from :: proc(env: Environment, allocator := context.allocator) -> (cfg: Config, why: string) {
	if env.runtime_dir != "" {
		cfg.socket = strings.concatenate({env.runtime_dir, "/", SOCKET_NAME}, allocator)
	}
	cfg.user_manager = user_manager(env, allocator)
	switch {
	case strings.has_prefix(env.state_home, "/"):
		cfg.state = strings.concatenate({env.state_home, "/ravnix-link"}, allocator)
	case env.home != "":
		cfg.state = strings.concatenate({env.home, "/.local/state/ravnix-link"}, allocator)
	case:
		why = "neither XDG_STATE_HOME nor HOME is set, so there is no place for the queue (give --state)"
	}
	return
}

usage_error :: proc(errf: ^os.File, format: string, args: ..any) -> int {
	fmt.fprintf(errf, "ravnix-link: %s\n", fmt.tprintf(format, ..args))
	fmt.fprintln(errf, "run ravnix-link --help for the usage")
	return EX_USAGE
}

run :: proc(args: []string, env: Environment, stdout, stderr: ^os.File) -> int {
	out := stdout if stdout != nil else os.stdout
	errf := stderr if stderr != nil else os.stderr
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.fprintln(errf, "ravnix-link: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)

	cfg, env_why := config_from(env)
	cfg.stderr = errf
	Option :: struct {
		name:  string,
		field: ^string,
		given: bool,
	}
	options := []Option {
		{"--socket", &cfg.socket, false},
		{"--state", &cfg.state, false},
		{"--vault", &cfg.vault, false},
		{"--git", &cfg.git, false},
		{"--ravnix-notify", &cfg.ravnix_notify, false},
		{"--xdg-open", &cfg.xdg_open, false},
		{"--notify-send", &cfg.notify_send, false},
		{"--obsidian", &cfg.obsidian, false},
		{"--systemd-run", &cfg.systemd_run, false},
		{"--forward", &cfg.forward, false},
	}
	i := 0
	parse: for ; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			fmt.fprintln(out, USAGE)
			return 0
		}
		if !strings.has_prefix(arg, "--") {
			break
		}
		for &o in options {
			if arg == o.name {
				if o.given {
					return usage_error(errf, "%s given twice", arg)
				}
				if i + 1 >= len(args) {
					return usage_error(errf, "%s needs a value", arg)
				}
				i += 1
				if args[i] == "" {
					return usage_error(errf, "%s is empty", arg)
				}
				o.field^, o.given = args[i], true
				continue parse
			}
		}
		return usage_error(errf, "unknown option %s", arg)
	}
	if i >= len(args) {
		return usage_error(errf, "no command")
	}
	command, rest := args[i], args[i + 1:]

	switch command {
	case "open", "notify", "notify-send", "obsidian", "vault-commit", "receive", "flush", "deliver", "status", "dismiss", "drop", "daemon":
	case:
		return usage_error(errf, "unknown command %s", command)
	}
	if env.daemon_marker != "" && command != "daemon" && command != "status" {
		fmt.fprintln(
			errf,
			"ravnix-link: refused: this runs under the laptop's daemon (" + DAEMON_MARKER + " is set), and forwarding from there would loop",
		)
		return 1
	}
	if cfg.state == "" {
		fmt.fprintf(errf, "ravnix-link: %s\n", env_why)
		return 1
	}
	if command != "daemon" && command != "status" && command != "dismiss" && command != "drop" {
		// A commit that failed for good is the server's to tell about,
		// until the user has seen it.
		if failed, _ := read_failed(cfg, context.temp_allocator); len(failed) > 0 {
			report(cfg, "%s failed for good; ravnix-link status shows the list, ravnix-link dismiss clears it", commits(len(failed)))
		}
	}

	switch command {
	case "open":
		return run_open(cfg, env, rest, out, errf)
	case "notify":
		return run_notify(cfg, rest, errf)
	case "notify-send":
		return run_notify_send(cfg, rest, out, errf)
	case "obsidian":
		return run_obsidian(cfg, rest, errf)
	case "vault-commit":
		if cfg.forward != "" {
			return run_laptop_commit(cfg, rest, errf)
		}
		return run_vault_commit(cfg, rest, errf)
	case "receive":
		if len(rest) > 0 {
			return usage_error(errf, "receive takes no argument: the request is on its standard input")
		}
		return run_receive(cfg, env, out, errf)
	case "drop":
		if len(rest) != 1 {
			return usage_error(errf, "drop takes one id, as status shows it")
		}
		if !is_uuid(rest[0]) {
			return usage_error(errf, "%q is no request's id", rest[0])
		}
		r, why := drop(cfg, rest[0])
		if why != "" {
			report(cfg, "%s", why)
			return 1
		}
		fmt.fprintfln(out, "dropped %s", describe(r))
		return 0
	case "flush", "deliver", "status", "dismiss", "daemon":
		if len(rest) > 0 {
			return usage_error(errf, "%s takes no argument", command)
		}
	}
	switch command {
	case "dismiss":
		n, why := dismiss(cfg)
		if why != "" {
			report(cfg, "%s", why)
			return 1
		}
		fmt.fprintfln(out, "%s cleared from the list of failed ones", commits(n))
		return 0
	case "flush":
		cfg.retry_now = true
		result, why := flush(cfg)
		if why != "" {
			report(cfg, "%s", why)
			return 1
		}
		if result.pending > 0 {
			report(cfg, "%d requests wait for the laptop", result.pending)
		}
		return 0
	case "deliver":
		stop := false
		deliver(cfg, &stop, 60_000)
		return 0
	case "status":
		return run_status(cfg, out, errf)
	case "daemon":
		// The daemon runs for days: its memory is the heap's, not the run's.
		d, why := daemon_open(cfg, runtime.heap_allocator())
		if why != "" {
			report(cfg, "%s", why)
			return 1
		}
		report(cfg, "listening on %s", cfg.socket)
		stop := false
		daemon_serve(d, &stop)
		daemon_close(d)
		return 0
	}
	return 0
}

// request_base is a request of kind with a new id and the time.
request_base :: proc(cfg: Config, kind: Kind) -> Request {
	return Request{id = new_id(), kind = kind, created = timestamp(clock(cfg))}
}

// tell says how a submitted request came out and gives the exit status.
tell :: proc(cfg: Config, r: Request, outcome: Outcome, message: string) -> int {
	switch outcome {
	case .Done:
		return 0
	case .Failed:
		report(cfg, "%s failed: %s", describe(r), message)
		return 1
	case .Refused:
		report(cfg, "%s", message)
		return 1
	case .Expired:
		report(cfg, "the notification was not shown: it waited too long for the laptop")
		return 0
	case .Queued:
		switch r.kind {
		case .Notify:
			report(cfg, "the laptop is away: the notification is queued, and dropped if the laptop is not back within %d minutes", int(NOTIFY_TTL / time.Minute))
		case .Vault_Commit:
			report(cfg, "the commit is queued: it runs once the Obsidian operations and commits queued before it are done, and the vault here shows what they did")
		case .Open, .Obsidian:
			report(cfg, "the laptop is away: %s is queued, and runs when it is back", describe(r))
		}
		return 0
	case .Busy:
		report(cfg, "another ravnix-link run is delivering: %s is queued, and that run or the delivery service sends it", describe(r))
		return 0
	case .Retrying:
		report(cfg, "the commit is queued, since it did not go through: %s", message)
		return 0
	case .Delivered:
		report(cfg, "another ravnix-link run resolved %s, and its outcome is no longer recorded", describe(r))
		return 0
	}
	return 1
}

// commits is n vault commits, in words.
commits :: proc(n: int) -> string {
	return "1 vault commit" if n == 1 else fmt.tprintf("%d vault commits", n)
}

submit_and_tell :: proc(cfg: Config, r: Request, errf: ^os.File) -> int {
	if why := check_request(r); why != "" {
		return usage_error(errf, "%s", why)
	}
	if _, why := encode_request(r, context.temp_allocator); why != "" {
		return usage_error(errf, "%s", why)
	}
	outcome, message := submit(cfg, r)
	return tell(cfg, r, outcome, message)
}

run_open :: proc(cfg: Config, env: Environment, args: []string, out, errf: ^os.File) -> int {
	if len(args) == 1 {
		switch args[0] {
		case "--help", "--manual":
			fmt.fprintln(out, "usage: xdg-open { file | URL }: ravnix-link opens it on the laptop")
			return 0
		case "--version":
			fmt.fprintln(out, "xdg-open of ravnix-link")
			return 0
		}
	}
	if len(args) != 1 {
		return usage_error(errf, "open takes one link or path, not %d", len(args))
	}
	target := args[0]
	if target != "" && scheme_of(target) == "" && target[0] != '/' {
		if env.cwd == "" {
			report(cfg, "the working directory is unknown, so %s cannot be made absolute", target)
			return 1
		}
		target, _ = filepath.clean(strings.concatenate({env.cwd, "/", target}))
	} else if target != "" && target[0] == '/' {
		target, _ = filepath.clean(target)
	}
	r := request_base(cfg, .Open)
	r.target = target
	return submit_and_tell(cfg, r, errf)
}

is_topic :: proc(t: string) -> bool {
	if t == "" || !(t[0] >= 'a' && t[0] <= 'z') {
		return false
	}
	for c in transmute([]u8)t {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

run_notify :: proc(cfg: Config, args: []string, errf: ^os.File) -> int {
	r := request_base(cfg, .Notify)
	topic := ""
	positional := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "--":
			append(&positional, ..args[i + 1:])
			i = len(args)
		case "--topic", "--urgency", "--app":
			if i + 1 >= len(args) {
				return usage_error(errf, "%s needs a value", arg)
			}
			i += 1
			switch arg {
			case "--topic":
				topic = args[i]
				if !is_topic(topic) {
					return usage_error(errf, "the topic %q is not a name of lowercase letters, digits and dashes", topic)
				}
			case "--urgency":
				r.urgency = args[i]
			case "--app":
				r.app = args[i]
			}
		case:
			if strings.has_prefix(arg, "--") {
				return usage_error(errf, "notify has no option %s", arg)
			}
			append(&positional, arg)
		}
	}
	if len(positional) < 1 || len(positional) > 2 {
		return usage_error(errf, "notify takes a summary and a body, not %d texts", len(positional))
	}
	r.summary = positional[0]
	if len(positional) == 2 {
		r.body = positional[1]
	}
	if why := check_request(r); why != "" {
		return usage_error(errf, "%s", why)
	}
	room_failed := false
	if topic != "" {
		message := r.summary if r.body == "" else strings.concatenate({r.summary, "\n\n", r.body})
		program := cfg.ravnix_notify if cfg.ravnix_notify != "" else "ravnix-notify"
		ran: Program_Run
		if _, found := find_program(program); !found {
			ran.why = fmt.tprintf("%s is not installed", program)
		} else {
			ran = run_program({program, "--topic", topic, message}, DEFAULT_NOTIFY_TIMEOUT)
		}
		if !ran.success {
			report(cfg, "the message did not reach the Matrix room of %s: %s", topic, program_failure(program, ran))
			room_failed = true
		}
	}
	status := submit_and_tell(cfg, r, errf)
	return 1 if room_failed else status
}

// parse_notify_send reads notify-send's arguments as libnotify's
// notify-send reads them (GOption): short options with their value in the
// next argument or glued on, long ones with = or the next argument, options
// anywhere until --, and then SUMMARY [BODY]. Of the options, the urgency
// and the application's name are forwarded; the others are read and left.
// --help and --version are the real notify-send's: passthrough is set.
parse_notify_send :: proc(args: []string) -> (n: Notify_Send, why: string) {
	Opt :: struct {
		short: u8,
		long:  string,
		value: bool,
	}
	OPTIONS :: [?]Opt {
		{'u', "urgency", true},
		{'t', "expire-time", true},
		{'a', "app-name", true},
		{'i', "icon", true},
		{'c', "category", true},
		{'h', "hint", true},
		{'r', "replace-id", true},
		{'A', "action", true},
		{'e', "transient", false},
		{'p', "print-id", false},
		{'w', "wait", false},
		{'v', "version", false},
		{'?', "help", false},
	}
	positional := make([dynamic]string, context.temp_allocator)
	options_done := false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if options_done || arg == "-" || !strings.has_prefix(arg, "-") {
			append(&positional, arg)
			continue
		}
		if arg == "--" {
			options_done = true
			continue
		}
		opt: Opt
		found := false
		value := ""
		has_value := false
		if strings.has_prefix(arg, "--") {
			name := arg[2:]
			if eq := strings.index_byte(name, '='); eq >= 0 {
				name, value, has_value = name[:eq], name[eq + 1:], true
			}
			for o in OPTIONS {
				if o.long == name {
					opt, found = o, true
				}
			}
			if !found {
				return {}, fmt.tprintf("notify-send has no option --%s", name)
			}
		} else {
			for o in OPTIONS {
				if o.short == arg[1] {
					opt, found = o, true
				}
			}
			if !found {
				return {}, fmt.tprintf("notify-send has no option -%c", arg[1])
			}
			if len(arg) > 2 {
				if !opt.value {
					return {}, fmt.tprintf("notify-send's -%c takes no value", arg[1])
				}
				value, has_value = arg[2:], true
			}
		}
		if opt.value && !has_value {
			if i + 1 >= len(args) {
				return {}, fmt.tprintf("notify-send's --%s needs a value", opt.long)
			}
			i += 1
			value = args[i]
		} else if !opt.value && has_value {
			return {}, fmt.tprintf("notify-send's --%s takes no value", opt.long)
		}
		switch opt.long {
		case "urgency":
			switch value {
			case "low", "normal", "critical":
				n.urgency = value
			case:
				return {}, fmt.tprintf("the urgency %q is not low, normal or critical", value)
			}
		case "app-name":
			n.app = value
		case "version", "help":
			n.passthrough = true
		}
	}
	if n.passthrough {
		return n, ""
	}
	if len(positional) == 0 || positional[0] == "" {
		return {}, "notify-send needs a summary"
	}
	if len(positional) > 2 {
		return {}, "notify-send takes a summary and a body, no more"
	}
	n.summary = positional[0]
	if len(positional) == 2 {
		n.body = positional[1]
	}
	return n, ""
}

Notify_Send :: struct {
	summary, body, urgency, app: string,
	passthrough:                 bool,
}

// run_notify_send is the notify-send of the server: it runs the real one
// with the caller's arguments (on a server without a notification
// service it fails, and that is nobody's business: its output and status
// are dropped), then forwards the notification to the laptop.
run_notify_send :: proc(cfg: Config, args: []string, out, errf: ^os.File) -> int {
	n, why := parse_notify_send(args)
	if why != "" {
		return usage_error(errf, "%s", why)
	}
	real_argv := make([dynamic]string)
	append(&real_argv, cfg.notify_send)
	append(&real_argv, ..args)
	if n.passthrough {
		if cfg.notify_send == "" {
			report(cfg, "no real notify-send is given (--notify-send) to answer %s", args[0])
			return 1
		}
		process, err := os.process_start({command = real_argv[:], stdout = out, stderr = errf})
		if err != nil {
			report(cfg, "cannot run %s: %s", cfg.notify_send, os.error_string(err))
			return 1
		}
		state, _ := os.process_wait(process)
		return state.exit_code
	}
	if cfg.notify_send != "" {
		run_program(real_argv[:], NOTIFY_SEND_TIMEOUT)
	}
	r := request_base(cfg, .Notify)
	r.summary, r.body, r.urgency, r.app = n.summary, n.body, n.urgency, n.app
	return submit_and_tell(cfg, r, errf)
}

run_obsidian :: proc(cfg: Config, args: []string, errf: ^os.File) -> int {
	r := request_base(cfg, .Obsidian)
	if len(args) == 0 {
		return usage_error(errf, "obsidian takes move, rename or delete")
	}
	switch args[0] {
	case "move":
		r.op = .Move
	case "rename":
		r.op = .Rename
	case "delete":
		r.op = .Delete
	case:
		return usage_error(errf, "obsidian takes move, rename or delete, not %q", args[0])
	}
	seen := make(map[string]bool)
	for arg in args[1:] {
		eq := strings.index_byte(arg, '=')
		key := arg[:eq] if eq >= 0 else arg
		value := arg[eq + 1:] if eq >= 0 else ""
		if key == "permanent" {
			return usage_error(errf, "permanent is refused: delete moves a note to the trash, where a slip can be undone")
		}
		if eq < 0 {
			return usage_error(errf, "obsidian takes no positional argument (%q): name the note with path=, or it acts on whatever note is open", arg)
		}
		switch key {
		case "path", "to", "name":
		case "file":
			return usage_error(errf, "name the note with path=, its path in the vault, never with file=")
		case "vault":
			return usage_error(errf, "vault= is not forwarded: Obsidian acts in the vault it had open last")
		case:
			return usage_error(errf, "obsidian %s has no parameter %s= (it takes path=, and to= for move or name= for rename)", args[0], key)
		}
		if seen[key] {
			return usage_error(errf, "%s= given twice", key)
		}
		seen[key] = true
		switch key {
		case "path":
			r.path = value
		case "to":
			r.to = value
		case "name":
			r.name = value
		}
	}
	if !seen["path"] {
		return usage_error(errf, "obsidian %s needs path=, the note's path in the vault", args[0])
	}
	return submit_and_tell(cfg, r, errf)
}

run_vault_commit :: proc(cfg: Config, args: []string, errf: ^os.File) -> int {
	if cfg.vault == "" {
		return usage_error(
			errf,
			"vault-commit runs on the server, where the vault's git repository is, and needs --vault (the server's ravnix-link has it from ravnix.link.vault)",
		)
	}
	if len(args) == 0 {
		return usage_error(errf, "vault-commit needs a message")
	}
	r := request_base(cfg, .Vault_Commit)
	r.vault = cfg.vault
	r.message = args[0]
	r.paths = args[1:]
	return submit_and_tell(cfg, r, errf)
}

// run_laptop_commit is vault-commit on the laptop: the request, with the
// sum of each path as the laptop's copy of the vault has it, goes to the
// server's receive through the program of --forward, and the server's
// answer is the outcome. Nothing is queued here: a laptop that cannot reach
// the server says so, and the caller asks again.
run_laptop_commit :: proc(cfg: Config, args: []string, errf: ^os.File) -> int {
	if cfg.vault == "" {
		return usage_error(errf, "on the laptop, vault-commit needs --vault, the laptop's copy of the vault, to tell the server what the files are")
	}
	if len(args) == 0 {
		return usage_error(errf, "vault-commit needs a message")
	}
	if len(args) == 1 {
		return usage_error(errf, "on the laptop, vault-commit names the files to commit: what is staged is the server's")
	}
	r := request_base(cfg, .Vault_Commit)
	r.vault = cfg.vault
	r.message = args[0]
	r.paths = args[1:]
	// The paths are checked before they are read: none leaves the vault.
	if why := check_request(r); why != "" {
		return usage_error(errf, "%s", why)
	}
	sums := make([]string, len(r.paths))
	for p, i in r.paths {
		sum, why, not_a_file := file_sum(strings.concatenate({cfg.vault, "/", p}, context.temp_allocator))
		if not_a_file {
			return usage_error(errf, "%s: the server waits for each file the sync brings, so name the files", why)
		}
		if why != "" {
			report(cfg, "%s", why)
			return 1
		}
		sums[i] = sum
	}
	r.sums = sums
	line, why := encode_request(r)
	if why != "" {
		return usage_error(errf, "%s", why)
	}
	timeout := or_default(cfg.commit_timeout_ms, DEFAULT_COMMIT_TIMEOUT) + FORWARD_EXTRA
	ran := run_program({cfg.forward}, timeout, input = line, allocator = context.temp_allocator, die_with_parent = true)
	rest := ran.output
	for l in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(l, "{") {
			continue
		}
		rep, rwhy := decode_reply(l, context.temp_allocator)
		if rwhy != "" || rep.id != r.id {
			continue
		}
		switch rep.status {
		case .Done:
			return 0
		case .Retry:
			report(cfg, "the server queued the commit: %s", rep.error)
			return 0
		case .Failed:
			report(cfg, "the commit failed on the server: %s", rep.error)
			return 1
		}
	}
	how := program_failure(cfg.forward, ran) if !ran.success || ran.why != "" else fmt.tprintf("%s ended without an answer: %s", cfg.forward, first_lines(ran.output, 5))
	report(cfg, "the server did not answer (%s). It may or may not have queued the commit; asking again is safe, as a second commit of the same files commits nothing", how)
	return 1
}

// run_receive is the server's end of a commit from the laptop: one request
// line on standard input, answered with one reply line on standard output
// (receive).
run_receive :: proc(cfg: Config, env: Environment, out, errf: ^os.File) -> int {
	input := env.stdin if env.stdin != nil else os.stdin
	buf := make([]u8, MAX_LINE + 1)
	n := 0
	for n < len(buf) {
		k, err := os.read(input, buf[n:])
		if k > 0 {
			n += k
			if strings.index_byte(string(buf[n - k:n]), '\n') >= 0 {
				break
			}
		}
		if err != nil || k <= 0 {
			break
		}
	}
	data := string(buf[:n])
	line := data
	if end := strings.index_byte(data, '\n'); end >= 0 {
		line = data[:end + 1]
	} else if n > MAX_LINE - 1 {
		line = ""
	}
	rep: Reply
	code: int
	if line == "" && n > MAX_LINE - 1 {
		rep, code = Reply{status = .Failed, error = fmt.tprintf("the request is longer than the %d bytes a line may have", MAX_LINE)}, EX_USAGE
	} else {
		rep, code = receive(cfg, line)
	}
	if rep.status == .Failed {
		report(cfg, "%s", rep.error)
	}
	fmt.fprint(out, encode_reply(rep, context.temp_allocator))
	return code
}

// receive takes the line of a commit from the laptop: a vault-commit with
// its paths and their sums. It is queued as the server's own, in the vault
// configured here, and the delivery service (ravnix-link-deliver) commits
// it, in its environment, which has the agent a signed commit needs; the
// queue's change wakes it. receive runs no git: an ssh session may have no
// agent. It answers done or failed when the service has resolved the
// commit within receive_wait_ms, and retry (queued) when the commit waits:
// for the sync to bring the files, at once, or for the service. A request
// sent again with its id gets the outcome it had, and runs nothing twice.
receive :: proc(cfg: Config, line: string) -> (rep: Reply, code: int) {
	refuse :: proc(id, why: string) -> (Reply, int) {
		return Reply{id = id, status = .Failed, error = why}, EX_USAGE
	}
	if strings.trim_space(line) == "" {
		return refuse("", "there is no request on standard input")
	}
	// In temporary memory, as is what it answers: the caller's run ends soon.
	r, why := decode_request(line, context.temp_allocator)
	if why != "" {
		return refuse(id_of(line, context.temp_allocator), why)
	}
	switch {
	case r.kind != .Vault_Commit:
		return refuse(r.id, fmt.tprintf("receive takes a vault-commit from the laptop, not %s", KIND_NAMES[r.kind]))
	case len(r.paths) == 0:
		return refuse(r.id, "a commit from the laptop names its files: what is staged here is not the laptop's")
	case len(r.sums) == 0:
		return refuse(r.id, "a commit from the laptop carries the sum of each file, which the commit waits for")
	case cfg.vault == "":
		return refuse(r.id, "no vault is configured here (--vault, ravnix.link.vault)")
	}
	// The vault is this host's: the laptop's path for it may be another.
	r.vault = cfg.vault
	if why = check_request(r); why != "" {
		return refuse(r.id, why)
	}
	if why = enqueue(cfg, r); why != "" {
		return Reply{id = r.id, status = .Failed, error = why}, 1
	}
	wait := or_default(cfg.receive_wait_ms, DEFAULT_RECEIVE_WAIT)
	start := time.tick_now()
	for {
		outcome, message := outcome_of(cfg, r.id, {})
		#partial switch outcome {
		case .Done, .Delivered:
			return Reply{id = r.id, status = .Done}, 0
		case .Failed:
			return Reply{id = r.id, status = .Failed, error = message}, 1
		case .Retrying:
			return Reply{id = r.id, status = .Retry, error = fmt.tprintf("the server could not commit it yet, and tries again: %s", message)}, 0
		}
		if unsynced_files(cfg.vault, r) > 0 {
			return Reply {
					id = r.id,
					status = .Retry,
					error = fmt.tprintf("it waits until the server's copy of the vault has the files as the laptop wrote them, which the sync brings (at most %d minutes, then it commits what is there)", int(SYNC_WAIT / time.Minute)),
				},
				0
		}
		if int(time.duration_milliseconds(time.tick_since(start))) >= wait {
			return Reply{id = r.id, status = .Retry, error = "it is queued, and the delivery service (ravnix-link-deliver) commits it after what waits before it"}, 0
		}
		time.sleep(100 * time.Millisecond)
	}
}

run_status :: proc(cfg: Config, out, errf: ^os.File) -> int {
	snap, why := read_snapshot(cfg)
	if why != "" {
		report(cfg, "%s", why)
		return 1
	}
	waiting := pending(snap)
	corrupt := 0
	for e in snap.entries {
		if e.why != "" {
			corrupt += 1
		}
	}
	switch len(waiting) {
	case 0:
		fmt.fprintln(out, "nothing waits for the laptop")
	case 1:
		fmt.fprintln(out, "1 request waits for the laptop:")
	case:
		fmt.fprintfln(out, "%d requests wait for the laptop:", len(waiting))
	}
	expects: [dynamic]Expectation
	if cfg.vault != "" {
		expects, _ = read_expectations(cfg, context.temp_allocator)
	}
	for e in waiting {
		r := e.request
		fmt.fprintfln(out, "  %s  %s  %s", r.created, r.id, describe(r))
		if r.kind != .Vault_Commit {
			continue
		}
		for x in expects {
			if !x.dropped && x.created <= r.created && !synced(cfg.vault, x) {
				fmt.fprintfln(out, "      waits until the vault here shows %s (done on the laptop at %s)", x.what, x.done)
			}
		}
		rec, has := snap.records[r.id]
		if cfg.vault != "" && len(r.sums) > 0 && (!has || rec.attempts == 0) {
			created, _ := parse_timestamp(r.created)
			if n := unsynced_files(cfg.vault, r); n > 0 && time.diff(created, clock(cfg)) < SYNC_WAIT {
				until := timestamp(time.time_add(created, SYNC_WAIT), context.temp_allocator)
				if n == 1 {
					fmt.fprintfln(out, "      waits until the vault here has 1 file as the laptop wrote it (the sync brings it), at most until %s", until)
				} else {
					fmt.fprintfln(out, "      waits until the vault here has %d files as the laptop wrote them (the sync brings them), at most until %s", n, until)
				}
			}
		}
		if has && rec.status == .Retry {
			fmt.fprintfln(out, "      attempt %d failed, again at %s: %s", rec.attempts, rec.next, first_lines(rec.error, 1))
		}
	}
	if corrupt > 0 {
		fmt.fprintfln(out, "%d lines of the queue are not requests", corrupt)
	}
	failed, fwhy := read_failed(cfg, context.temp_allocator)
	if fwhy != "" {
		report(cfg, "%s", fwhy)
	}
	if len(failed) > 0 {
		fmt.fprintfln(out, "%s failed for good (ravnix-link dismiss clears this list):", commits(len(failed)))
		for f in failed {
			fmt.fprintfln(out, "  %s  vault-commit \"%s\": %s", f.at, first_lines(f.message, 1), first_lines(f.error, 1))
		}
	}
	return 0
}

main :: proc() {
	env := Environment {
		runtime_dir   = os.get_env("XDG_RUNTIME_DIR", context.allocator),
		state_home    = os.get_env("XDG_STATE_HOME", context.allocator),
		home          = os.get_env("HOME", context.allocator),
		daemon_marker = os.get_env(DAEMON_MARKER, context.allocator),
	}
	env.cwd, _ = os.get_working_directory(context.allocator)
	os.exit(run(os.args[1:], env, os.stdout, os.stderr))
}

