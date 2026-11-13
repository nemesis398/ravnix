// The roll: every Claude Code pane that herdr knows is asked to exit and
// started again on the version now installed, with the session it had and
// the flags it was started with. README.md has the whole story; in short:
//
//   idle or done   the screen is read twice; if both show the empty input
//                  box and nothing else (screen.odin), /exit is typed, the
//                  pane's shell is waited for, and `herdr agent start ...
//                  -- --resume SESSION FLAGS` starts it again
//   working        tried again every poll until the deadline (3 h), then
//                  left on its version until the next run
//   blocked        never touched; the user is told
//   a dialog       on a pane herdr calls idle: never touched; the user is
//                  told
//
// A pane that is not ready (text waits in its input, the busy hook says a
// turn runs, the screen is one claude-roll does not know) waits like a
// working one. A pane without a session id or launch flags claude-roll can
// trust is left, and the user is told. Once /exit is sent, the deadline no
// longer counts: the session is not running, so it is started again
// whatever the time, and when that fails the user is told the session id
// to resume by hand.
package claude_roll

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:time"

DEFAULT_DEADLINE :: 3 * time.Hour
DEFAULT_POLL :: 30 * time.Second
// Between the two reads of a screen before /exit.
DEFAULT_SETTLE :: 500 * time.Millisecond
// How long Claude Code may take to leave after /exit.
DEFAULT_SHELL_WAIT :: 60 * time.Second
DEFAULT_SHELL_POLL :: 500 * time.Millisecond
// What `herdr agent start --timeout` gets: Claude Code with its MCP
// servers can take a while to be ready. herdr allows up to 300000.
DEFAULT_START_TIMEOUT_MS :: 120_000
// What one herdr call may take, the start apart.
DEFAULT_CALL_TIMEOUT :: 30 * time.Second
// What ravnix-notify may take (its own retries end after about 250 s).
NOTIFY_TIMEOUT :: 300 * time.Second
// The most a herdr call may print.
MAX_OUTPUT :: 4 << 20

LOCK_NAME :: "claude-roll.lock"
BUSY_DIR :: "claude-busy"
NOTIFY_TOPIC :: "sessions"

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 64
EXIT_LOCKED :: 75

// What a run of a program gave.
Run_Result :: Child_Result

// The seams of the tests: the programs run, the clock and the sleep. Left
// nil, they are the real ones.
Hooks :: struct {
	data:  rawptr,
	run:   proc(data: rawptr, argv: []string, timeout: time.Duration) -> Run_Result,
	now:   proc(data: rawptr) -> time.Time,
	sleep: proc(data: rawptr, d: time.Duration),
}

Config :: struct {
	dry_run:          bool,
	deadline:         time.Duration,
	// $XDG_STATE_HOME/ravnix: the records, the busy files and the lock.
	state_dir:        string,
	herdr:            string,
	notify:           string,
	// Where the processes are read: /proc.
	proc_root:        string,
	poll:             time.Duration,
	settle:           time.Duration,
	shell_wait:       time.Duration,
	shell_poll:       time.Duration,
	start_timeout_ms: int,
	call_timeout:     time.Duration,
	hooks:            Hooks,
	// Where the log goes; nil is standard error.
	log:              ^strings.Builder,
}

default_config :: proc() -> Config {
	return {
		deadline = DEFAULT_DEADLINE,
		herdr = "herdr",
		notify = "ravnix-notify",
		proc_root = "/proc",
		poll = DEFAULT_POLL,
		settle = DEFAULT_SETTLE,
		shell_wait = DEFAULT_SHELL_WAIT,
		shell_poll = DEFAULT_SHELL_POLL,
		start_timeout_ms = DEFAULT_START_TIMEOUT_MS,
		call_timeout = DEFAULT_CALL_TIMEOUT,
	}
}

Outcome :: enum {
	// Not decided (yet): a pane claude-roll does not handle stays so.
	Pending,
	Rolled,
	// --dry-run: would have been rolled.
	Would_Roll,
	// Not ready by the deadline; it stays on its version.
	Left,
	// herdr says blocked; the user was told.
	Blocked,
	// The screen shows a dialog; the user was told.
	Dialog,
	// No session id or launch flags claude-roll can trust; the user was told.
	Cannot,
	// The pane or its agent went away by itself.
	Gone,
	// /exit was sent and the session did not come back; the user was told
	// the session id.
	Failed,
	// Started again, and waiting at a dialog; the user was told.
	Stalled,
}

Pane_Result :: struct {
	pane:    string,
	session: string,
	outcome: Outcome,
	reason:  string,
}

Report :: struct {
	panes:  []Pane_Result,
	status: int,
}

@(private = "file")
Run :: struct {
	cfg:      Config,
	// Everything of the run; the report is copied out of it.
	a:        runtime.Allocator,
	deadline: time.Time,
	panes:    [dynamic]Pane_Result,
	// The terminal each pane had in the first list: a pane whose terminal
	// changed is another one.
	terminal: map[string]string,
	failed:   bool,
}

// roll runs one roll and returns what came of each Claude Code pane.
roll :: proc(cfg: Config, allocator: runtime.Allocator) -> Report {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return {status = EXIT_FAILED}
	}
	defer virtual.arena_destroy(&arena)
	// The scratch of one round, freed after it: a run may last hours.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return {status = EXIT_FAILED}
	}
	defer virtual.arena_destroy(&scratch)
	r := Run {
		cfg = cfg,
		a   = virtual.arena_allocator(&arena),
	}
	context.allocator = r.a
	context.temp_allocator = virtual.arena_allocator(&scratch)
	r.panes = make([dynamic]Pane_Result)
	r.terminal = make(map[string]string)

	status := run_roll(&r)

	out := make([]Pane_Result, len(r.panes), allocator)
	for p, i in r.panes {
		out[i] = {strings.clone(p.pane, allocator), strings.clone(p.session, allocator), p.outcome, strings.clone(p.reason, allocator)}
	}
	return {out, status}
}

@(private = "file")
run_roll :: proc(r: ^Run) -> int {
	cfg := &r.cfg
	// A dry run takes no lock: it sends nothing, and may run beside a roll.
	lock: ^os.File
	// Closing the file lets the lock go.
	defer if lock != nil {
		os.close(lock)
	}
	if !cfg.dry_run {
		if e := os.make_directory_all(cfg.state_dir); e != nil && e != os.General_Error.Exist {
			logf(r, "cannot make the state directory %s", cfg.state_dir)
			return EXIT_FAILED
		}
		path, _ := filepath.join({cfg.state_dir, LOCK_NAME})
		held: bool
		lock, held = take_lock(path)
		if !held {
			if lock == nil {
				logf(r, "cannot open the lock %s", path)
				return EXIT_FAILED
			}
			logf(r, "another claude-roll is running (it holds %s); nothing done", path)
			return EXIT_LOCKED
		}
	}
	r.deadline = time.time_add(now(r), cfg.deadline)

	for round := 0;; round += 1 {
		agents, ok := list_agents(r)
		if !ok {
			leave_pending(r, "herdr could not be read")
			return EXIT_FAILED
		}
		if round == 0 {
			for a in agents {
				if a.agent != "claude" {
					continue
				}
				if !valid_pane_id(a.pane_id) {
					logf(r, "an agent with no usable pane id is left alone")
					continue
				}
				append(&r.panes, Pane_Result{pane = a.pane_id})
				r.terminal[a.pane_id] = a.terminal_id
			}
			if len(r.panes) == 0 {
				logf(r, "no Claude Code pane in herdr")
			}
		}
		for &p in r.panes {
			if p.outcome != .Pending {
				continue
			}
			a, here := find_agent(agents, p.pane)
			if !here || a.agent != "claude" || a.terminal_id != r.terminal[p.pane] {
				settle(r, &p, .Gone, "the pane or its Claude Code went away")
				continue
			}
			switch a.agent_status {
			case "blocked":
				settle(r, &p, .Blocked, "herdr says it waits for an answer")
				tell(r, fmt.tprintf("Claude Code in pane %s waits for an answer; claude-roll left it on its version.", p.pane))
			case "idle", "done":
				try_roll(r, &p, a)
			case:
				p.reason = "a turn is running"
			}
		}
		free_all(context.temp_allocator)

		pending := 0
		for p in r.panes {
			if p.outcome == .Pending {
				pending += 1
			}
		}
		if pending == 0 {
			break
		}
		if cfg.dry_run {
			leave_pending(r, "")
			break
		}
		left := time.diff(now(r), r.deadline)
		if left <= 0 {
			leave_pending(r, "")
			break
		}
		sleep(r, min(cfg.poll, left))
	}
	return EXIT_FAILED if r.failed else EXIT_OK
}

@(private = "file")
try_roll :: proc(r: ^Run, p: ^Pane_Result, a: Agent) {
	cfg := &r.cfg
	session := ""
	if a.agent_session.kind == "id" {
		session = a.agent_session.value
		if !valid_session_id(session) {
			settle(r, p, .Cannot, "herdr reports a session id that is no UUID")
			tell(r, fmt.tprintf("claude-roll left Claude Code in pane %s on its version: herdr reports a session id it does not accept.", p.pane))
			return
		}
	}
	rec, rerr := read_pane_record(cfg.state_dir, p.pane, r.a)
	if session == "" {
		// herdr has none: the record's, which the hook rewrites at /clear;
		// the process check below makes sure it is this pane's.
		if rerr == "" && valid_session_id(rec.session_id) {
			session = rec.session_id
		} else {
			settle(r, p, .Cannot, "no session id")
			tell(r, fmt.tprintf("claude-roll left Claude Code in pane %s on its version: neither herdr nor the pane's record has a session id it accepts.", p.pane))
			return
		}
	}
	p.session = session
	if rerr != "" {
		cannot(r, p, rerr)
		return
	}
	// The record must be of this session and of the Claude Code process that
	// runs in the pane now. One of another (a Claude Code started inside
	// this one, a pane moved here, a hook that failed and left an older
	// record) would resume the session with someone else's flags.
	if rec.session_id != session {
		cannot(r, p, "the pane's record is of another session")
		return
	}
	if rec.pid <= 0 {
		cannot(r, p, "the pane's record names no process (it is older than claude-roll's process check)")
		return
	}
	info := run(r, {cfg.herdr, "pane", "process-info", "--pane", p.pane}, cfg.call_timeout)
	if !succeeded(info) {
		code, msg := herdr_error(string(info.stderr), r.a)
		p.reason = fmt.aprintf("its processes could not be read (%s)", failure(info, code, msg))
		return
	}
	pids, perr := foreground_pids(string(info.stdout), context.temp_allocator)
	if perr != "" {
		p.reason = strings.clone(perr, r.a)
		return
	}
	in_front := false
	for pid in pids {
		in_front ||= pid == rec.pid
	}
	if !in_front {
		cannot(r, p, "the pane's record is of another process than the Claude Code in the pane")
		return
	}
	st, read := read_stat(cfg.proc_root, rec.pid)
	if !read || !is_claude_process(cfg.proc_root, rec.pid) {
		// herdr sees it and /proc does not: nothing can be told.
		p.reason = "the pane's Claude Code process cannot be read"
		return
	}
	if st.start != rec.start_time {
		cannot(r, p, "the pane's record is of an earlier process with the same pid")
		return
	}
	if running, why, known := background_work(cfg.proc_root, rec.pid, st.pgid); !known {
		p.reason = "whether the session runs background work cannot be told"
		return
	} else if running {
		p.reason = why
		return
	}
	flags, ferr := resume_args(rec.argv, r.a)
	if ferr != "" {
		cannot(r, p, ferr)
		return
	}
	if busy(cfg.state_dir, session) {
		p.reason = "the busy hook says a turn is running"
		return
	}

	first, failed := read_screen(r, p)
	if failed {
		return
	}
	v := classify_screen(first)
	if v.verdict == .Dialog {
		dialog(r, p)
		return
	}
	if v.verdict != .Ready {
		p.reason = v.reason
		return
	}
	sleep(r, cfg.settle)
	second: string
	second, failed = read_screen(r, p)
	if failed {
		return
	}
	v = classify_screen(second)
	if v.verdict == .Dialog {
		dialog(r, p)
		return
	}
	if v.verdict != .Ready || input_box(first, context.temp_allocator) != input_box(second, context.temp_allocator) {
		p.reason = "the screen changed between two reads"
		return
	}

	name := agent_name(a.name, p.pane, r.a)
	start := make([dynamic]string)
	append(&start, cfg.herdr, "agent", "start", name, "--kind", "claude", "--pane", p.pane, "--timeout", fmt.aprint(cfg.start_timeout_ms), "--", "--resume", session)
	append(&start, ..flags)
	if cfg.dry_run {
		settle(r, p, .Would_Roll, "")
		logf(r, "pane %s: would type /exit, then run: %s", p.pane, strings.join(start[:], " "))
		return
	}

	// /exit. herdr refuses it, before anything is typed, when the agent is
	// blocked, gone or not ready; any other failure leaves it unknown
	// whether it arrived, so the shell is waited for all the same.
	res := run(r, {cfg.herdr, "agent", "prompt", p.pane, "/exit"}, cfg.call_timeout)
	if !succeeded(res) {
		code, msg := herdr_error(string(res.stderr), r.a)
		switch code {
		case "agent_blocked":
			settle(r, p, .Blocked, "herdr refused the /exit: blocked")
			tell(r, fmt.tprintf("Claude Code in pane %s waits for an answer; claude-roll left it on its version.", p.pane))
			return
		case "agent_not_found":
			settle(r, p, .Gone, "the agent went away before the /exit")
			return
		case "agent_not_ready":
			p.reason = "herdr says it is not ready for input"
			return
		}
		logf(r, "pane %s: the /exit may not have arrived (%s); waiting for the shell", p.pane, failure(res, code, msg))
	}
	logf(r, "pane %s: sent /exit to session %s", p.pane, session)

	if !wait_for_shell(r, p) {
		settle(r, p, .Failed, "Claude Code did not return to the shell")
		tell(r, fmt.tprintf("claude-roll sent /exit to pane %s, but the pane did not return to its shell within %v. If Claude Code is gone, resume session %s by hand: `claude --resume %s`", p.pane, cfg.shell_wait, session, session))
		r.failed = true
		return
	}

	res = run(r, start[:], time.Duration(cfg.start_timeout_ms) * time.Millisecond + cfg.call_timeout)
	if succeeded(res) {
		settle(r, p, .Rolled, "")
		logf(r, "pane %s: resumed session %s", p.pane, session)
		return
	}
	code, msg := herdr_error(string(res.stderr), r.a)
	if code == "agent_not_ready" {
		settle(r, p, .Stalled, "the resumed session waits at a dialog")
		tell(r, fmt.tprintf("claude-roll resumed session %s in pane %s, and it waits at a dialog; answer it there.", session, p.pane))
		return
	}
	settle(r, p, .Failed, failure(res, code, msg))
	tell(r, fmt.tprintf("claude-roll could not resume session %s in pane %s (%s). Resume it by hand: `claude --resume %s`", session, p.pane, failure(res, code, msg), session))
	r.failed = true
}

// cannot leaves a pane on its version for a reason that will not pass by
// itself, and tells the user.
@(private = "file")
cannot :: proc(r: ^Run, p: ^Pane_Result, why: string) {
	settle(r, p, .Cannot, why)
	tell(r, fmt.tprintf("claude-roll left Claude Code in pane %s (session %s) on its version: %s.", p.pane, p.session, why))
}

@(private = "file")
dialog :: proc(r: ^Run, p: ^Pane_Result) {
	settle(r, p, .Dialog, "a dialog is on the screen")
	tell(r, fmt.tprintf("Claude Code in pane %s shows a dialog that herdr takes for idle; claude-roll left it on its version.", p.pane))
}

// read_screen reads a pane's screen. failed is true when there is none:
// the agent is gone (and the pane settled as Gone), or herdr did not answer
// (and the pane waits for the next round).
@(private = "file")
read_screen :: proc(r: ^Run, p: ^Pane_Result) -> (screen: string, failed: bool) {
	res := run(r, {r.cfg.herdr, "agent", "read", p.pane, "--source", "visible", "--format", "ansi"}, r.cfg.call_timeout)
	if succeeded(res) {
		return string(res.stdout), false
	}
	code, msg := herdr_error(string(res.stderr), r.a)
	if code == "agent_not_found" {
		settle(r, p, .Gone, "the agent went away before its screen was read")
		return "", true
	}
	p.reason = fmt.aprintf("its screen could not be read (%s)", failure(res, code, msg))
	return "", true
}

@(private = "file")
wait_for_shell :: proc(r: ^Run, p: ^Pane_Result) -> bool {
	until := time.time_add(now(r), r.cfg.shell_wait)
	for {
		info := run(r, {r.cfg.herdr, "pane", "process-info", "--pane", p.pane}, r.cfg.call_timeout)
		if succeeded(info) {
			get := run(r, {r.cfg.herdr, "pane", "get", p.pane}, r.cfg.call_timeout)
			if succeeded(get) {
				if yes, _ := at_shell(string(info.stdout), string(get.stdout)); yes {
					return true
				}
			}
		}
		if time.diff(now(r), until) <= 0 {
			return false
		}
		sleep(r, r.cfg.shell_poll)
	}
}

@(private = "file")
list_agents :: proc(r: ^Run) -> (agents: []Agent, ok: bool) {
	res := run(r, {r.cfg.herdr, "agent", "list"}, r.cfg.call_timeout)
	if !succeeded(res) {
		code, msg := herdr_error(string(res.stderr), r.a)
		logf(r, "herdr agent list failed: %s", failure(res, code, msg))
		return nil, false
	}
	list, err := parse_agent_list(string(res.stdout), r.a)
	if err != "" {
		logf(r, "%s", err)
		return nil, false
	}
	return list, true
}

@(private = "file")
find_agent :: proc(agents: []Agent, pane: string) -> (Agent, bool) {
	for a in agents {
		if a.pane_id == pane {
			return a, true
		}
	}
	return {}, false
}

// busy says whether the busy hook (claude/hooks/busy-state.sh) last wrote
// busy for the session.
busy :: proc(state, session: string) -> bool {
	path, _ := filepath.join({state, BUSY_DIR, session}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	return strings.trim_space(string(data[:min(len(data), 64)])) == "busy"
}

@(private = "file")
settle :: proc(r: ^Run, p: ^Pane_Result, outcome: Outcome, reason: string) {
	p.outcome = outcome
	p.reason = strings.clone(reason, r.a)
	if outcome != .Rolled && outcome != .Would_Roll {
		logf(r, "pane %s: %v: %s", p.pane, outcome, reason)
	}
}

@(private = "file")
leave_pending :: proc(r: ^Run, why: string) {
	for &p in r.panes {
		if p.outcome == .Pending {
			settle(r, &p, .Left, why if why != "" else p.reason)
		}
	}
}

// tell sends the user a message through ravnix-notify, in the sessions
// topic; --dry-run only logs it. A failure is logged, and the run goes on.
@(private = "file")
tell :: proc(r: ^Run, message: string) {
	if r.cfg.dry_run {
		logf(r, "would notify: %s", message)
		return
	}
	res := run(r, {r.cfg.notify, "--topic", NOTIFY_TOPIC, "--", message}, NOTIFY_TIMEOUT)
	if !succeeded(res) {
		logf(r, "ravnix-notify failed (%s): %s", failure(res, "", ""), message)
	}
}

@(private = "file")
succeeded :: proc(res: Run_Result) -> bool {
	return res.start_error == "" && !res.timed_out && !res.too_much && res.exit_code == 0
}

@(private = "file")
failure :: proc(res: Run_Result, code, message: string) -> string {
	switch {
	case res.start_error != "":
		return fmt.tprintf("could not start it: %s", res.start_error)
	case res.timed_out:
		return "it did not answer in time"
	case res.too_much:
		return "it printed more than any answer holds"
	case code != "":
		return fmt.tprintf("%s: %s", code, message)
	}
	return fmt.tprintf("exit %d: %s", res.exit_code, strings.trim_space(string(res.stderr)))
}

@(private = "file")
run :: proc(r: ^Run, argv: []string, timeout: time.Duration) -> Run_Result {
	if r.cfg.hooks.run != nil {
		return r.cfg.hooks.run(r.cfg.hooks.data, argv, timeout)
	}
	res := run_child(argv, nil, timeout, MAX_OUTPUT, r.a)
	if res.start_error != "" {
		res.start_error = fmt.aprintf("%s: %s", argv[0], res.start_error)
	}
	return res
}

@(private = "file")
now :: proc(r: ^Run) -> time.Time {
	if r.cfg.hooks.now != nil {
		return r.cfg.hooks.now(r.cfg.hooks.data)
	}
	return time.now()
}

@(private = "file")
sleep :: proc(r: ^Run, d: time.Duration) {
	if r.cfg.hooks.sleep != nil {
		r.cfg.hooks.sleep(r.cfg.hooks.data, d)
		return
	}
	time.sleep(d)
}

@(private = "file")
logf :: proc(r: ^Run, format: string, args: ..any) {
	if r.cfg.log != nil {
		fmt.sbprintf(r.cfg.log, "claude-roll: ")
		fmt.sbprintf(r.cfg.log, format, ..args)
		strings.write_byte(r.cfg.log, '\n')
		return
	}
	fmt.eprint("claude-roll: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}

// take_lock opens path and takes an exclusive lock on it without waiting.
// It returns the file (nil when it cannot be opened) and whether the lock
// is held; the lock lasts until the file is closed.
take_lock :: proc(path: string) -> (f: ^os.File, held: bool) {
	file, err := os.open(path, {.Read, .Write, .Create})
	if err != nil {
		return nil, false
	}
	for {
		e := linux.flock(linux.Fd(os.fd(file)), {.EX, .NB})
		if e == .EINTR {
			continue
		}
		return file, e == .NONE
	}
}
