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
       claude-roll classify FILE...`

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

Exit status: 0 done (sessions left on their version included); 1 herdr could
not be read, or a session did not come back; 64 bad usage; 75 another
claude-roll is running.`

Command :: enum {
	Roll,
	Record,
	Classify,
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
