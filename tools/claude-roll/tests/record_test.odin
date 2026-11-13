// claude-roll record: the SessionStart hook that writes down, per herdr
// pane, the session and the arguments its Claude Code was started with, read
// from the process tree. The tests give it a /proc of their own.
package claude_roll_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import roll ".."

HOOK_INPUT :: `{"session_id":"0a1b2c3d-2222-4222-8333-444455556666","transcript_path":"/home/user/.claude/projects/x/0a1b2c3d-2222-4222-8333-444455556666.jsonl","cwd":"/home/user/project","hook_event_name":"SessionStart","source":"startup"}`

// fake_proc writes one process into the /proc under root.
fake_proc :: proc(f: ^Fixture, root: string, pid, ppid: int, comm: string, argv: ..string) {
	dir := pj(f.a, root, fmt.tprint(pid))
	if os.make_directory_all(dir) != nil {
		testing.fail_now(f.t, "cannot make the fake /proc")
	}
	write_file(f, pj(f.a, dir, "stat"), fmt.tprintf("%d (%s) S %d 1 1 0 -1 4194304", pid, comm, ppid))
	write_file(f, pj(f.a, dir, "comm"), strings.concatenate({comm, "\n"}, f.a))
	b := strings.builder_make(f.a)
	for a in argv {
		strings.write_string(&b, a)
		strings.write_byte(&b, 0)
	}
	write_file(f, pj(f.a, dir, "cmdline"), strings.to_string(b))
}

record_input :: proc(f: ^Fixture, pane: string, start: int, input := HOOK_INPUT) -> roll.Record_Input {
	return roll.Record_Input{pane = pane, state_dir = f.state, proc_root = pj(f.a, f.dir, "proc"), start_pid = start, input = transmute([]byte)input}
}

@(test)
records_the_flags_of_the_claude_above_the_hook :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	root := pj(f.a, f.dir, "proc")
	// hook (bash) <- sh -c <- claude <- the pane's shell
	fake_proc(f, root, 40, 30, "bash", "bash", "/hooks/claude-pane")
	fake_proc(f, root, 30, 20, "sh", "/bin/sh", "-c", "/hooks/claude-pane")
	fake_proc(f, root, 20, 10, "claude", "claude", "--add-dir", "/home/user/notes", "--append-system-prompt", "two\nlines and \"quotes\"")
	fake_proc(f, root, 10, 1, "bash", "-bash")

	path, err := roll.record_pane(record_input(f, "wK:p1", 40), f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, path, pj(f.a, f.state, "claude-panes", "wK:p1.json"))

	data, rerr := os.read_entire_file(path, f.a)
	testing.expect(t, rerr == nil)
	rec, perr := roll.parse_pane_record(data, f.a)
	testing.expect_value(t, perr, "")
	testing.expect_value(t, rec.pane, "wK:p1")
	testing.expect_value(t, rec.session_id, "0a1b2c3d-2222-4222-8333-444455556666")
	testing.expect_value(t, rec.cwd, "/home/user/project")
	testing.expect_value(t, rec.source, "startup")
	testing.expect(t, equal_strings(rec.argv, {"--add-dir", "/home/user/notes", "--append-system-prompt", "two\nlines and \"quotes\""}))
	// Nothing else in the directory: the write went through a temporary
	// file that is gone.
	testing.expect_value(t, count_entries(f, pj(f.a, f.state, "claude-panes")), 1)
}

@(test)
knows_claude_by_its_wrapper_and_its_store_path :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	root := pj(f.a, f.dir, "proc")
	fake_proc(f, root, 50, 51, "bash", "bash", "hook")
	fake_proc(f, root, 51, 2, ".claude-wrapped", "/nix/store/abc-claude-code-2.1.400/bin/claude", "--model", "opus")
	_, err := roll.record_pane(record_input(f, "w1:p1", 50), f.a)
	testing.expect_value(t, err, "")
	rec, _ := roll.read_pane_record(f.state, "w1:p1", f.a)
	testing.expect(t, equal_strings(rec.argv, {"--model", "opus"}))

	fake_proc(f, root, 60, 61, "bash", "bash", "hook")
	fake_proc(f, root, 61, 2, ".claude-wrapped", "/nix/store/abc-claude-code/bin/.claude-wrapped")
	_, err = roll.record_pane(record_input(f, "w1:p2", 60), f.a)
	testing.expect_value(t, err, "")
	rec, _ = roll.read_pane_record(f.state, "w1:p2", f.a)
	testing.expect_value(t, len(rec.argv), 0)
}

// After /clear, SessionStart runs again with a new id: the record follows.
@(test)
a_new_session_in_the_pane_replaces_the_record :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	root := pj(f.a, f.dir, "proc")
	fake_proc(f, root, 40, 20, "bash", "bash", "hook")
	fake_proc(f, root, 20, 1, "claude", "claude", "--add-dir", "/a")
	_, err := roll.record_pane(record_input(f, "wK:p1", 40), f.a)
	testing.expect_value(t, err, "")
	cleared := `{"session_id":"0a1b2c3d-9999-4222-8333-444455556666","cwd":"/home/user/project","hook_event_name":"SessionStart","source":"clear"}`
	_, err = roll.record_pane(record_input(f, "wK:p1", 40, cleared), f.a)
	testing.expect_value(t, err, "")
	rec, rerr := roll.read_pane_record(f.state, "wK:p1", f.a)
	testing.expect_value(t, rerr, "")
	testing.expect_value(t, rec.session_id, "0a1b2c3d-9999-4222-8333-444455556666")
	testing.expect_value(t, rec.source, "clear")
	testing.expect_value(t, count_entries(f, pj(f.a, f.state, "claude-panes")), 1)
}

@(test)
writes_nothing_it_cannot_vouch_for :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	root := pj(f.a, f.dir, "proc")
	fake_proc(f, root, 40, 20, "bash", "bash", "hook")
	fake_proc(f, root, 20, 1, "claude", "claude")
	// No Claude Code above the hook within reach.
	fake_proc(f, root, 70, 71, "bash", "bash", "hook")
	fake_proc(f, root, 71, 72, "sh", "sh")
	fake_proc(f, root, 72, 1, "init", "/sbin/init")
	// A loop in the tree (a /proc that changed under the walk).
	fake_proc(f, root, 80, 81, "bash", "bash")
	fake_proc(f, root, 81, 80, "sh", "sh")
	// A stat whose comm holds blanks and parentheses.
	fake_proc(f, root, 90, 91, "a) b (c", "bash")
	fake_proc(f, root, 91, 1, "claude", "claude", "--verbose")

	cases := []struct {
		name, pane, input: string,
		start:             int,
		err:               string,
	} {
		{"outside herdr", "", HOOK_INPUT, 40, "HERDR_PANE_ID"},
		{"a pane id that is a path", "../../x", HOOK_INPUT, 40, "pane"},
		{"a session id with odd characters", "w1:p1", `{"session_id":"x; rm -r ~","source":"startup"}`, 40, "session"},
		{"no session id", "w1:p1", `{"source":"startup"}`, 40, "session"},
		{"input that is no JSON", "w1:p1", `{"session_id":`, 40, "input"},
		{"empty input", "w1:p1", ``, 40, "input"},
		{"no Claude Code above the hook", "w1:p1", HOOK_INPUT, 70, "Claude Code"},
		{"a loop in the process tree", "w1:p1", HOOK_INPUT, 80, "Claude Code"},
		{"a process that is gone", "w1:p1", HOOK_INPUT, 12345, "Claude Code"},
	}
	for c in cases {
		_, err := roll.record_pane(record_input(f, c.pane, c.start, c.input), f.a)
		testing.expectf(t, strings.contains(err, c.err), "%s: error %q does not say %q", c.name, err, c.err)
	}
	testing.expect_value(t, count_entries(f, pj(f.a, f.state, "claude-panes")), 0)

	_, err := roll.record_pane(record_input(f, "w1:p9", 90), f.a)
	testing.expect_value(t, err, "")
	rec, _ := roll.read_pane_record(f.state, "w1:p9", f.a)
	testing.expect(t, equal_strings(rec.argv, {"--verbose"}))
}

// The record of a pane that has none, or a broken one.
@(test)
reads_a_missing_or_broken_record_as_an_error :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	_, err := roll.read_pane_record(f.state, "w1:p1", f.a)
	testing.expect(t, err != "")
	dir := pj(f.a, f.state, "claude-panes")
	_ = os.make_directory_all(dir)
	write_file(f, pj(f.a, dir, "w1:p1.json"), `{"pane":"w1:p1","session_id":"0a1b`)
	_, err = roll.read_pane_record(f.state, "w1:p1", f.a)
	testing.expect(t, err != "")
	// A record of another pane under this pane's name.
	write_file(f, pj(f.a, dir, "w1:p2.json"), `{"pane":"w1:p3","session_id":"0a1b2c3d-2222-4222-8333-444455556666","argv":[]}`)
	_, err = roll.read_pane_record(f.state, "w1:p2", f.a)
	testing.expect(t, strings.contains(err, "w1:p3"))
	// A pane id that would leave the directory is not read at all.
	_, err = roll.read_pane_record(f.state, "../x", f.a)
	testing.expect(t, err != "")
	// A huge file is refused, not read whole.
	write_file(f, pj(f.a, dir, "w1:p4.json"), strings.repeat(" ", 2 << 20, f.a))
	_, err = roll.read_pane_record(f.state, "w1:p4", f.a)
	testing.expect(t, err != "")
}
