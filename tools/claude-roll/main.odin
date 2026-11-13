// The command: claude-roll [OPTION...], claude-roll record, claude-roll
// classify FILE... README.md has what each does.
package claude_roll

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

USAGE :: `usage: claude-roll [--dry-run] [--deadline DURATION] [OPTION...]
       claude-roll record
       claude-roll classify FILE...
       claude-roll update --mode bump|follow --flake DIR --host NAME --user NAME
                          --group NAME --running VERSION --candidate FILE [OPTION...]
       claude-roll update-prepare --mode bump|follow --remote URL --host NAME [OPTION...]
       claude-roll update-finish --mode bump|follow --remote URL [OPTION...]
       claude-roll remote-control [--unit UNIT] [--deadline DURATION] [OPTION...]`

HELP :: USAGE + `

Rolls every Claude Code session in a herdr pane onto the Claude Code that is
installed now: a session that is idle gets /exit and is started again in its
pane with herdr agent start ... -- --resume SESSION and the flags it was
started with. A working session is tried again every 30 seconds until the
deadline, then left on its version until the next run. A blocked session,
and one whose screen shows a dialog, is never touched; ravnix-notify tells
the user (topic sessions), as it does for a session that does not come back.

  --dry-run             read herdr and say what would be done; send, type and
                        notify nothing, take no lock, and wait for nothing
  --deadline DURATION   how long to wait for working sessions: 3h, 90m,
                        1h30m, 0s for one pass (default 3h, at most 168h)
  --state DIR           the records, the busy files and the lock (default
                        $XDG_STATE_HOME/ravnix)
  --herdr PATH          the herdr to run (default: herdr, from PATH)
  --ravnix-notify PATH  the ravnix-notify to run (default: from PATH)

claude-roll record is Claude Code's SessionStart hook: it writes the pane's
session and launch flags to DIR/claude-panes/PANE.json, from the hook's
input and the command line of the Claude Code above it. It always exits 0.

claude-roll classify reads screens as herdr agent read --format ansi prints
them and says, for each, what claude-roll would make of it.

claude-roll update, update-prepare and update-finish are the Claude Code
update timer's three steps, root's and the user's; remote-control restarts
Remote Control's unit once it holds no session. README.md has their
options and what each does.

Exit status: 0 done (sessions left on their version included); 1 herdr could
not be read, or a session did not come back, or an update step failed; 64
bad usage; 75 another claude-roll is running, or an update could not reach
what it needs and tries again at the next run.`

Command :: enum {
	Roll,
	Record,
	Classify,
	Update,
	Update_Prepare,
	Update_Finish,
	Remote_Control,
	Help,
}

// The environment the command reads, given as values so a test can set it.
Environment :: struct {
	state_home: string, // XDG_STATE_HOME
	home:       string, // HOME
}

Args :: struct {
	command: Command,
	cfg:     Config,
	files:   []string,
	update:  Update_Config,
	prepare: Prepare_Config,
	finish:  Finish_Config,
	rc:      RC_Config,
}

MAX_DEADLINE :: 168 * time.Hour

parse_args :: proc(args: []string, env: Environment, allocator: runtime.Allocator) -> (a: Args, err: string) {
	a.cfg = default_config()
	if len(args) > 0 {
		switch args[0] {
		case "record":
			if len(args) > 1 {
				return a, "record takes no argument"
			}
			a.command = .Record
		case "classify":
			if len(args) == 1 {
				return a, "classify needs a file"
			}
			a.command = .Classify
			a.files = args[1:]
			return a, ""
		case "update", "update-prepare", "update-finish", "remote-control":
			return parse_update_args(args, env, allocator)
		}
	}
	state := ""
	i := 0
	if a.command == .Record {
		i = 1
	}
	for ; i < len(args); i += 1 {
		arg := args[i]
		name, value, has_value := arg, "", false
		if eq := strings.index_byte(arg, '='); eq >= 0 && strings.has_prefix(arg, "--") {
			name, value, has_value = arg[:eq], arg[eq + 1:], true
		}
		takes_value := name == "--deadline" || name == "--state" || name == "--herdr" || name == "--ravnix-notify"
		if takes_value && !has_value {
			if i + 1 >= len(args) {
				return a, fmt.aprintf("%s needs a value", name, allocator = allocator)
			}
			i += 1
			value = args[i]
		}
		if takes_value && value == "" {
			return a, fmt.aprintf("%s needs a value", name, allocator = allocator)
		}
		switch name {
		case "--help", "-h":
			a.command = .Help
			return a, ""
		case "--dry-run":
			a.cfg.dry_run = true
		case "--deadline":
			d, ok := parse_duration(value)
			if !ok {
				return a, fmt.aprintf("--deadline %q is no duration such as 3h, 90m or 1h30m, up to 168h", value, allocator = allocator)
			}
			a.cfg.deadline = d
		case "--state":
			state = value
		case "--herdr":
			a.cfg.herdr = value
		case "--ravnix-notify":
			a.cfg.notify = value
		case:
			return a, fmt.aprintf("unknown argument %q", arg, allocator = allocator)
		}
	}
	if state == "" {
		switch {
		case env.state_home != "":
			state, _ = filepath.join({env.state_home, "ravnix"}, allocator)
		case env.home != "":
			state, _ = filepath.join({env.home, ".local", "state", "ravnix"}, allocator)
		case:
			return a, "neither XDG_STATE_HOME nor HOME is set; give --state"
		}
	}
	a.cfg.state_dir = state
	return a, ""
}

// parse_duration reads one or more NUMBER UNIT pairs, the units h, m and s
// in that order, each at most once: 3h, 45s, 1h30m, 0s.
parse_duration :: proc(s: string) -> (d: time.Duration, ok: bool) {
	if s == "" {
		return
	}
	units := "hms"
	rest := s
	for rest != "" {
		n := 0
		for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {
			n += 1
		}
		if n == 0 || n > 6 || n == len(rest) {
			return 0, false
		}
		v, _ := strconv.parse_int(rest[:n], 10)
		u := strings.index_byte(units, rest[n])
		if u < 0 {
			return 0, false
		}
		switch units[u] {
		case 'h':
			d += time.Duration(v) * time.Hour
		case 'm':
			d += time.Duration(v) * time.Minute
		case 's':
			d += time.Duration(v) * time.Second
		}
		units = units[u + 1:]
		rest = rest[n + 1:]
	}
	if d > MAX_DEADLINE {
		return 0, false
	}
	return d, true
}

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("claude-roll: out of memory")
		os.exit(1)
	}
	context.allocator = virtual.arena_allocator(&arena)
	env := Environment {
		state_home = os.get_env("XDG_STATE_HOME", context.allocator),
		home       = os.get_env("HOME", context.allocator),
	}
	a, err := parse_args(os.args[1:], env, context.allocator)
	if err != "" {
		fmt.eprintf("claude-roll: %s\n%s\n", err, USAGE)
		// A hook must not fail the session it runs in.
		os.exit(0 if a.command == .Record else EXIT_USAGE)
	}
	status := 0
	switch a.command {
	case .Help:
		fmt.println(HELP)
	case .Record:
		status = run_record(a.cfg.state_dir)
	case .Classify:
		status = run_classify(a.files)
	case .Roll:
		status = roll(a.cfg, context.allocator).status
	case .Update:
		_, status = update(a.update)
	case .Update_Prepare:
		status = prepare(a.prepare)
	case .Update_Finish:
		status = finish(a.finish)
	case .Remote_Control:
		_, status = remote_control(a.rc)
	}
	virtual.arena_destroy(&arena)
	os.exit(status)
}

// run_record is the SessionStart hook. Whatever happens, it exits 0 and
// prints nothing on standard output, which Claude Code would show.
run_record :: proc(state: string) -> int {
	pane := os.get_env("HERDR_PANE_ID", context.allocator)
	if pane == "" {
		return 0
	}
	input, err := os.read_entire_file(os.stdin, context.allocator)
	if err != nil {
		fmt.eprintln("claude-roll record: cannot read the hook input")
		return 0
	}
	_, rerr := record_pane({pane = pane, state_dir = state, proc_root = "/proc", start_pid = os.get_ppid(), input = input}, context.allocator)
	if rerr != "" {
		fmt.eprintf("claude-roll record: %s\n", rerr)
	}
	return 0
}

run_classify :: proc(files: []string) -> int {
	status := 0
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			fmt.eprintf("claude-roll: cannot read %s\n", f)
			status = 1
			continue
		}
		s := classify_screen(string(data))
		switch s.verdict {
		case .Ready:
			fmt.printf("%s: ready\n", f)
		case .Not_Ready:
			fmt.printf("%s: not ready: %s\n", f, s.reason)
		case .Dialog:
			fmt.printf("%s: dialog: %s\n", f, s.reason)
		}
		free_all(context.temp_allocator)
	}
	return status
}

// parse_update_args reads the options of update, update-prepare,
// update-finish and remote-control. Each takes --NAME VALUE or
// --NAME=VALUE; --override and --roll-unit may be given more than once.
parse_update_args :: proc(args: []string, env: Environment, allocator: runtime.Allocator) -> (a: Args, err: string) {
	known: []string
	switch args[0] {
	case "update":
		a.command = .Update
		known = {"--mode", "--flake", "--host", "--user", "--group", "--running", "--candidate", "--input", "--package", "--releases", "--state", "--prepare-unit", "--finish-unit", "--profile", "--override"}
	case "update-prepare":
		a.command = .Update_Prepare
		known = {"--mode", "--remote", "--branch", "--input", "--state", "--repo", "--host", "--ravnix-notify"}
	case "update-finish":
		a.command = .Update_Finish
		known = {"--mode", "--remote", "--branch", "--state", "--repo", "--result", "--ravnix-notify", "--roll-unit"}
	case "remote-control":
		a.command = .Remote_Control
		known = {"--unit", "--deadline", "--ravnix-notify", "--sys-root"}
	}
	values := make(map[string]string, allocator)
	overrides := make([dynamic]Override, allocator)
	units := make([dynamic]string, allocator)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--help" || arg == "-h" {
			a.command = .Help
			return a, ""
		}
		name, value := arg, ""
		has_value := false
		if eq := strings.index_byte(arg, '='); eq >= 0 && strings.has_prefix(arg, "--") {
			name, value, has_value = arg[:eq], arg[eq + 1:], true
		}
		found := false
		for k in known {
			found ||= k == name
		}
		if !found {
			return a, fmt.aprintf("%s: unknown argument %q", args[0], arg, allocator = allocator)
		}
		if !has_value {
			if i + 1 >= len(args) {
				return a, fmt.aprintf("%s needs a value", name, allocator = allocator)
			}
			i += 1
			value = args[i]
		}
		if value == "" || strings.contains_any(value, "\n\x00") {
			return a, fmt.aprintf("%s needs a value on one line", name, allocator = allocator)
		}
		switch name {
		case "--override":
			eq := strings.index_byte(value, '=')
			if eq <= 0 || !valid_attr_name(value[:eq]) || !strings.has_prefix(value[eq + 1:], "/") {
				return a, fmt.aprintf("--override %q is not NAME=/PATH", value, allocator = allocator)
			}
			append(&overrides, Override{value[:eq], value[eq + 1:]})
		case "--roll-unit":
			if !valid_unit(value) {
				return a, fmt.aprintf("--roll-unit %q is no unit name", value, allocator = allocator)
			}
			append(&units, value)
		case:
			if name in values {
				return a, fmt.aprintf("%s is given twice", name, allocator = allocator)
			}
			values[name] = value
		}
	}
	mode := Update_Mode.Bump
	if a.command != .Remote_Control {
		switch values["--mode"] {
		case "bump":
			mode = .Bump
		case "follow":
			mode = .Follow
		case "":
			return a, "--mode is needed: bump or follow"
		case:
			return a, fmt.aprintf("--mode %q is not bump or follow", values["--mode"], allocator = allocator)
		}
	}
	need :: proc(values: map[string]string, names: ..string) -> string {
		for n in names {
			if values[n] == "" {
				return n
			}
		}
		return ""
	}
	or_default :: proc(values: map[string]string, name, fallback: string) -> string {
		v := values[name]
		return v if v != "" else fallback
	}
	user_state := ""
	switch {
	case env.state_home != "":
		user_state, _ = filepath.join({env.state_home, "ravnix", "claude-update"}, allocator)
	case env.home != "":
		user_state, _ = filepath.join({env.home, ".local", "state", "ravnix", "claude-update"}, allocator)
	}

	switch a.command {
	case .Update:
		if missing := need(values, "--flake", "--host", "--user", "--group", "--running", "--candidate"); missing != "" {
			return a, fmt.aprintf("update needs %s", missing, allocator = allocator)
		}
		c := default_update_config()
		c.mode = mode
		c.flake = values["--flake"]
		c.host = values["--host"]
		c.user = values["--user"]
		c.group = values["--group"]
		c.running = values["--running"]
		c.candidate = values["--candidate"]
		c.input = or_default(values, "--input", c.input)
		c.package_attr = or_default(values, "--package", fmt.aprintf("home-manager.users.%s.programs.claude-code.package", c.user, allocator = allocator))
		c.releases = or_default(values, "--releases", c.releases)
		c.state_dir = or_default(values, "--state", c.state_dir)
		c.prepare_unit = or_default(values, "--prepare-unit", c.prepare_unit)
		c.finish_unit = or_default(values, "--finish-unit", c.finish_unit)
		c.profile = or_default(values, "--profile", c.profile)
		c.overrides = overrides[:]
		switch {
		case !valid_attr_name(c.host):
			return a, fmt.aprintf("--host %q is no attribute name", c.host, allocator = allocator)
		case !valid_attr_name(c.user) || !valid_attr_name(c.group):
			return a, "--user and --group take a name"
		case !valid_attr_name(c.input):
			return a, fmt.aprintf("--input %q is no input name", c.input, allocator = allocator)
		case !valid_attr_path(c.package_attr):
			return a, fmt.aprintf("--package %q is no attribute path", c.package_attr, allocator = allocator)
		case !valid_version(c.running):
			return a, fmt.aprintf("--running %q is no version", c.running, allocator = allocator)
		case !strings.has_prefix(c.flake, "/") || !strings.has_prefix(c.candidate, "/") || !strings.has_prefix(c.state_dir, "/") || !strings.has_prefix(c.profile, "/"):
			return a, "--flake, --candidate, --state and --profile take absolute paths"
		case !strings.has_prefix(c.releases, "https://"):
			return a, fmt.aprintf("--releases %q is not an https URL", c.releases, allocator = allocator)
		case !valid_unit(c.prepare_unit) || !valid_unit(c.finish_unit):
			return a, "--prepare-unit and --finish-unit take unit names"
		}
		a.update = c
	case .Update_Prepare, .Update_Finish:
		if missing := need(values, "--remote"); missing != "" {
			return a, fmt.aprintf("%s needs %s", args[0], missing, allocator = allocator)
		}
		remote := values["--remote"]
		if !strings.has_prefix(remote, "https://") || strings.contains_any(remote, " \t") {
			return a, fmt.aprintf("--remote %q is not an https URL", remote, allocator = allocator)
		}
		branch := or_default(values, "--branch", DEFAULT_BRANCH)
		if !valid_branch(branch) {
			return a, fmt.aprintf("--branch %q is no branch name", branch, allocator = allocator)
		}
		state := or_default(values, "--state", user_state)
		if state == "" {
			return a, "neither XDG_STATE_HOME nor HOME is set; give --state"
		}
		repo := or_default(values, "--repo", fmt.aprintf("%s/flake.git", state, allocator = allocator))
		notify := or_default(values, "--ravnix-notify", "ravnix-notify")
		if a.command == .Update_Prepare {
			if missing := need(values, "--host"); missing != "" {
				return a, "update-prepare needs --host"
			}
			input := or_default(values, "--input", DEFAULT_INPUT)
			if !valid_attr_name(input) {
				return a, fmt.aprintf("--input %q is no input name", input, allocator = allocator)
			}
			a.prepare = {
				mode      = mode,
				remote    = remote,
				branch    = branch,
				input     = input,
				state_dir = state,
				repo      = repo,
				host      = values["--host"],
				notify    = notify,
			}
		} else {
			result := or_default(values, "--result", DEFAULT_ROOT_STATE + "/" + RESULT_NAME)
			a.finish = {
				mode       = mode,
				remote     = remote,
				branch     = branch,
				state_dir  = state,
				repo       = repo,
				result     = result,
				notify     = notify,
				roll_units = units[:],
			}
		}
	case .Remote_Control:
		c := default_rc_config()
		c.unit = or_default(values, "--unit", c.unit)
		c.notify = or_default(values, "--ravnix-notify", c.notify)
		c.sys_root = or_default(values, "--sys-root", c.sys_root)
		if !valid_unit(c.unit) {
			return a, fmt.aprintf("--unit %q is no unit name", c.unit, allocator = allocator)
		}
		if d := values["--deadline"]; d != "" {
			dl, ok := parse_duration(d)
			if !ok {
				return a, fmt.aprintf("--deadline %q is no duration such as 3h, 90m or 1h30m, up to 168h", d, allocator = allocator)
			}
			c.deadline = dl
		}
		a.rc = c
	case .Roll, .Record, .Classify, .Help:
	}
	return a, ""
}

// valid_attr_name: a Nix attribute name, an input name, a user or a group
// as the update puts them into an attribute path or a command.
valid_attr_name :: proc(s: string) -> bool {
	if s == "" || len(s) > 64 || s[0] == '-' {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

valid_attr_path :: proc(s: string) -> bool {
	rest := s
	parts := 0
	for part in strings.split_iterator(&rest, ".") {
		if !valid_attr_name(part) {
			return false
		}
		parts += 1
	}
	return parts > 0 && !strings.has_suffix(s, ".")
}

valid_unit :: proc(s: string) -> bool {
	if s == "" || len(s) > 255 || s[0] == '-' {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && !strings.contains_rune("_-.@:\\", rune(c)) {
			return false
		}
	}
	return strings.contains_rune(s, '.')
}

valid_branch :: proc(s: string) -> bool {
	if s == "" || len(s) > 200 || s[0] == '-' || strings.contains(s, "..") || strings.has_suffix(s, "/") || strings.has_prefix(s, "/") {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && !strings.contains_rune("_-./", rune(c)) {
			return false
		}
	}
	return true
}
