// A herdr that lives in the test: claude-roll's runner calls it instead of
// starting a program, and it records every call, so a test can say exactly
// what claude-roll sent. It answers with the JSON herdr 0.9.5 prints
// (testdata/herdr, recorded from a real server where it could be, built from
// herdr's source where it could not), keeps a clock that only sleeps move,
// and plays each pane's states and screens in order.
package claude_roll_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import roll ".."

J_LIST :: #load("../testdata/herdr/agent-list.json", string)
J_PROMPT :: #load("../testdata/herdr/agent-prompt.json", string)
J_START :: #load("../testdata/herdr/agent-start.json", string)
J_AT_SHELL :: #load("../testdata/herdr/process-info-shell.json", string)
J_IN_CLAUDE :: #load("../testdata/herdr/process-info-claude.json", string)
J_IN_COMMAND :: #load("../testdata/herdr/process-info-command.json", string)
J_GET_SHELL :: #load("../testdata/herdr/pane-get-shell.json", string)
J_GET_AGENT :: #load("../testdata/herdr/pane-get-agent.json", string)
E_NOT_RUNNING :: #load("../testdata/herdr/error-server-not-running.json", string)
E_AGENT_NOT_FOUND :: #load("../testdata/herdr/error-agent-not-found.json", string)
E_PANE_NOT_FOUND :: #load("../testdata/herdr/error-pane-not-found.json", string)
E_BLOCKED :: #load("../testdata/herdr/error-agent-blocked.json", string)
E_PANE_BUSY :: #load("../testdata/herdr/error-pane-busy.json", string)
E_START_FAILED :: #load("../testdata/herdr/error-start-failed.json", string)
E_START_NOT_READY :: #load("../testdata/herdr/error-start-not-ready.json", string)
E_START_TIMEOUT :: #load("../testdata/herdr/error-start-timeout.json", string)

S_SUGGESTION :: #load("../testdata/screens/idle-suggestion.txt", string)
S_EMPTY :: #load("../testdata/screens/idle-empty.txt", string)
S_DRAFT :: #load("../testdata/screens/idle-draft.txt", string)
S_WORKING :: #load("../testdata/screens/working-spinner.txt", string)
S_PERMISSION :: #load("../testdata/screens/permission-bash.txt", string)
S_RESUME :: #load("../testdata/screens/resume-below.txt", string)

SID_A :: "0a1b2c3d-1111-4222-8333-444455556666"
SID_B :: "0a1b2c3d-2222-4222-8333-444455556666"
SID_C :: "0a1b2c3d-3333-4222-8333-444455556666"

Fake_Pane :: struct {
	id:              string,
	agent:           string, // "claude" unless set
	name:            string,
	session:         string, // herdr's agent_session value, "" for none
	session_kind:    string, // "id" unless set
	statuses:        []string, // one per list; the last repeats
	screens:         []string, // one per read; the last repeats
	// The pid of the Claude Code that herdr's process-info shows in the
	// pane's foreground (0: pid_of(id), the one write_record records).
	fg_pid:          int,
	// /exit does not end Claude Code.
	no_exit:         bool,
	// The shell shows only after this many process-info calls.
	shell_after:     int,
	// A command other than the shell holds the foreground after the exit.
	command_after:   bool,
	// The pane is gone from the list from this list on (0: never).
	gone_from_list:  int,
	// The pane is in the list only from this list on (0: from the first).
	appears_at:      int,
	// herdr no longer knows the agent when it is read.
	gone_at_read:    bool,
	prompt_error:    string,
	prompt_hangs:    bool,
	start_error:     string,
	// State.
	lists, reads:    int,
	polls:           int,
	exited, started: bool,
	start_argv:      []string,
}

Fake :: struct {
	t:           ^testing.T,
	arena:       virtual.Arena,
	a:           runtime.Allocator,
	panes:       [dynamic]^Fake_Pane,
	calls:       [dynamic][]string,
	now:         time.Time,
	slept:       time.Duration,
	// agent list: its stderr and exit 1 from list number list_fails_at on.
	list_error:  string,
	list_fails_at: int,
	// agent list prints list_raw instead of the panes.
	use_raw:     bool,
	list_raw:    string,
	// herdr cannot be started at all.
	missing:     bool,
	notify_exit: int,
	lists:       int,
}

T0 :: time.Time{_nsec = 1_800_000_000_000_000_000}

// What a started agent shows (a global: a slice literal in fake_run would
// live on its stack).
IDLE_ONLY := []string{"idle"}

fake_make :: proc(t: ^testing.T) -> ^Fake {
	fk := new(Fake)
	fk.t = t
	if virtual.arena_init_growing(&fk.arena) != nil {
		testing.fail_now(t, "no memory for the fake")
	}
	fk.a = virtual.arena_allocator(&fk.arena)
	fk.panes = make([dynamic]^Fake_Pane, fk.a)
	fk.calls = make([dynamic][]string, fk.a)
	fk.now = T0
	return fk
}

fake_destroy :: proc(fk: ^Fake) {
	virtual.arena_destroy(&fk.arena)
	free(fk)
}

add_pane :: proc(fk: ^Fake, p: Fake_Pane) -> ^Fake_Pane {
	np := new(Fake_Pane, fk.a)
	np^ = p
	if np.agent == "" {
		np.agent = "claude"
	}
	if np.session_kind == "" {
		np.session_kind = "id"
	}
	append(&fk.panes, np)
	return np
}

// config gives claude-roll this fake as its herdr, ravnix-notify and clock,
// and state as its state directory.
config :: proc(fk: ^Fake, state: string) -> roll.Config {
	cfg := roll.default_config()
	cfg.state_dir = state
	// write_record's processes are in the /proc beside the state.
	cfg.proc_root = pj(fk.a, filepath.dir(state), "proc")
	cfg.hooks = {
		data  = fk,
		run   = fake_run,
		now   = proc(data: rawptr) -> time.Time {return (^Fake)(data).now},
		sleep = proc(data: rawptr, d: time.Duration) {
			fk := (^Fake)(data)
			fk.now = time.time_add(fk.now, d)
			fk.slept += d
		},
	}
	cfg.log = new(strings.Builder, fk.a)
	strings.builder_init(cfg.log, fk.a)
	return cfg
}

find_pane :: proc(fk: ^Fake, id: string) -> ^Fake_Pane {
	for p in fk.panes {
		if p.id == id {
			return p
		}
	}
	return nil
}

ok :: proc(stdout: string) -> roll.Run_Result {
	return {stdout = transmute([]byte)stdout}
}

fail :: proc(stderr: string) -> roll.Run_Result {
	return {stderr = transmute([]byte)stderr, exit_code = 1}
}

fake_run :: proc(data: rawptr, given: []string, timeout: time.Duration) -> roll.Run_Result {
	fk := (^Fake)(data)
	context.allocator = fk.a
	// claude-roll's strings live in its arena, which is gone after the run.
	argv := deep_clone(given)
	append(&fk.calls, argv)
	// Every call takes a little time.
	fk.now = time.time_add(fk.now, 10 * time.Millisecond)
	if len(argv) == 0 {
		return {start_error = "no program"}
	}
	switch filepath.base(argv[0]) {
	case "ravnix-notify":
		return {exit_code = fk.notify_exit}
	case "herdr":
	case:
		return {start_error = "No such file or directory"}
	}
	if fk.missing {
		return {start_error = "No such file or directory"}
	}
	args := argv[1:]
	if len(args) < 2 {
		return {exit_code = 2}
	}
	cmd := strings.join(args[:2], " ")
	switch cmd {
	case "agent list":
		fk.lists += 1
		if fk.list_error != "" && fk.lists >= max(fk.list_fails_at, 1) {
			return fail(fk.list_error)
		}
		if fk.use_raw {
			return ok(fk.list_raw)
		}
		return ok(fake_list(fk))
	case "agent read":
		p := find_pane(fk, args[2])
		if p == nil || p.gone_at_read || p.exited {
			return fail(E_AGENT_NOT_FOUND)
		}
		s := p.screens[min(p.reads, len(p.screens) - 1)]
		p.reads += 1
		return ok(s)
	case "agent prompt":
		p := find_pane(fk, args[2])
		if p == nil || p.exited {
			return fail(E_AGENT_NOT_FOUND)
		}
		if p.prompt_error != "" {
			return fail(p.prompt_error)
		}
		if !p.no_exit {
			p.exited = true
			p.polls = 0
		}
		if p.prompt_hangs {
			return {timed_out = true, exit_code = -1}
		}
		return ok(J_PROMPT)
	case "pane process-info":
		p := find_pane(fk, args[3])
		if p == nil {
			return fail(E_PANE_NOT_FOUND)
		}
		p.polls += 1
		if !p.exited || p.polls <= p.shell_after {
			return ok(in_claude(fk, p))
		}
		if p.command_after {
			return ok(J_IN_COMMAND)
		}
		return ok(J_AT_SHELL)
	case "pane get":
		p := find_pane(fk, args[2])
		if p == nil {
			return fail(E_PANE_NOT_FOUND)
		}
		if p.exited && p.polls > p.shell_after {
			return ok(J_GET_SHELL)
		}
		return ok(J_GET_AGENT)
	case "agent start":
		p := find_pane(fk, args[6])
		if p == nil {
			return fail(E_PANE_NOT_FOUND)
		}
		p.start_argv = args
		if p.start_error != "" {
			return fail(p.start_error)
		}
		p.exited = false
		p.started = true
		p.statuses = IDLE_ONLY
		return ok(J_START)
	}
	return fail("unknown command")
}

deep_clone :: proc(words: []string) -> []string {
	out := make([]string, len(words))
	for w, i in words {
		out[i] = strings.clone(w)
	}
	return out
}

// in_claude is process-info for a pane whose Claude Code runs, in the shape
// of process-info-claude.json: that process leads the foreground group.
in_claude :: proc(fk: ^Fake, p: ^Fake_Pane) -> string {
	pid := p.fg_pid if p.fg_pid != 0 else pid_of(p.id)
	return fmt.aprintf(`{{"id":"cli:pane:process_info","result":{{"process_info":{{"foreground_process_group_id":%d,"foreground_processes":[{{"argv":["claude"],"cmdline":"claude","cwd":"/home/user/project","name":"claude","pid":%d}}],"pane_id":%q,"shell_pid":6588}},"type":"pane_process_info"}}}}`, pid, pid, p.id, allocator = fk.a)
}

fake_list :: proc(fk: ^Fake) -> string {
	b := strings.builder_make(fk.a)
	strings.write_string(&b, `{"id":"cli:agent:list","result":{"agents":[`)
	first := true
	for p in fk.panes {
		p.lists += 1
		if p.exited || (p.gone_from_list > 0 && fk.lists >= p.gone_from_list) || fk.lists < p.appears_at {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		status := p.statuses[min(p.lists - 1, len(p.statuses) - 1)]
		fmt.sbprintf(&b, `{{"agent":%q,`, p.agent)
		if p.session != "" {
			fmt.sbprintf(&b, `"agent_session":{{"agent":%q,"kind":%q,"source":"herdr:claude","value":%q}},`, p.agent, p.session_kind, p.session)
		}
		fmt.sbprintf(&b, `"agent_status":%q,"cwd":"/home/user/project","focused":false,"foreground_cwd":"/home/user/project",`, status)
		if p.name != "" {
			fmt.sbprintf(&b, `"name":%q,`, p.name)
		}
		fmt.sbprintf(&b, `"pane_id":%q,"revision":1,"state_change_seq":%d,"tab_id":"w1:t1","terminal_id":"term_%s","workspace_id":"w1"}}`, p.id, p.lists, p.id)
	}
	strings.write_string(&b, `],"type":"agent_list"}}`)
	return strings.to_string(b)
}

// What claude-roll ran, by the words that say what a call does.
calls_of :: proc(fk: ^Fake, words: ..string) -> int {
	n := 0
	outer: for c in fk.calls {
		if len(c) < len(words) {
			continue
		}
		for w, i in words {
			if w != "*" && c[i] != w {
				continue outer
			}
		}
		n += 1
	}
	return n
}

// sent_anything says whether claude-roll ran anything but a read: a prompt,
// a key, a start, a notification.
sent_anything :: proc(fk: ^Fake) -> bool {
	for c in fk.calls {
		if !is_read_only(c) {
			return true
		}
	}
	return false
}

is_read_only :: proc(c: []string) -> bool {
	if len(c) < 3 || filepath.base(c[0]) != "herdr" {
		return false
	}
	switch strings.join(c[1:3], " ", context.temp_allocator) {
	case "agent list", "agent read", "agent get", "pane process-info", "pane get":
		return true
	}
	return false
}

// notes returns the messages sent to ravnix-notify.
notes :: proc(fk: ^Fake) -> []string {
	out := make([dynamic]string, fk.a)
	for c in fk.calls {
		if filepath.base(c[0]) == "ravnix-notify" {
			append(&out, c[len(c) - 1])
		}
	}
	return out[:]
}

// write_record writes the record that claude-roll record would have
// written for pane, and the pane's Claude Code into the fake /proc beside
// the state, at pid_of(pane).
write_record :: proc(f: ^Fixture, pane, session: string, argv: ..string) {
	pid := pid_of(pane)
	words := make([dynamic]string, f.a)
	append(&words, "claude")
	append(&words, ..argv)
	fake_process(f, pj(f.a, f.dir, "proc"), {pid = pid, ppid = 1, pgid = pid, start = start_of(pid), comm = "claude", argv = words[:]})
	dir := pj(f.a, f.state, "claude-panes")
	_ = os.make_directory_all(dir)
	b := strings.builder_make(f.a)
	fmt.sbprintf(&b, `{{"pane":%q,"session_id":%q,"pid":%d,"start_time":%d,"cwd":"/home/user/project","source":"startup","argv":[`, pane, session, pid, start_of(pid))
	for a, i in argv {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%q", a)
	}
	strings.write_string(&b, "]}")
	write_file(f, pj(f.a, dir, strings.concatenate({pane, ".json"}, f.a)), strings.to_string(b))
}

outcome_of :: proc(r: roll.Report, pane: string) -> roll.Outcome {
	for p in r.panes {
		if p.pane == pane {
			return p.outcome
		}
	}
	return .Pending
}
