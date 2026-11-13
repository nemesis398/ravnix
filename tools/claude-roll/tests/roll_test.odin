// The roll: which panes claude-roll asks to exit and starts again with
// --resume, which it leaves, and what it tells the user, against the fake
// herdr of fake_herdr.odin.
package claude_roll_tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import roll ".."

@(test)
rolls_an_idle_pane_with_its_flags :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "wK:p1", session = SID_B, statuses = {"idle"}, screens = {S_SUGGESTION}})
	write_record(f, "wK:p1", SID_B, "--add-dir", "/home/user/notes", "--model", "opus", "fix the build")

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, outcome_of(r, "wK:p1"), roll.Outcome.Rolled)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "wK:p1", "/exit"), 1)
	testing.expect(t, p.started)
	want := []string{"agent", "start", "claude-wk-p1", "--kind", "claude", "--pane", "wK:p1", "--timeout", "120000", "--", "--resume", SID_B, "--add-dir", "/home/user/notes", "--model", "opus"}
	testing.expectf(t, equal_strings(p.start_argv, want), "start: %v", p.start_argv)
	// Read twice before the /exit, and nothing typed but the /exit.
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "read", "wK:p1"), 2)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "send-keys"), 0)
	testing.expect_value(t, calls_of(fk, "herdr", "pane", "send-text"), 0)
	testing.expect_value(t, len(notes(fk)), 0)
	// The /exit comes after both reads, the start after the shell was seen.
	order := call_order(fk)
	testing.expectf(t, strings.contains(order, "read read prompt"), "order: %s", order)
	testing.expectf(t, strings.contains(order, "process-info get start"), "order: %s", order)
}

// Review Focus 3: herdr says idle, the screen shows a dialog. Nothing is
// typed there, whatever the dialog, and the user is told.
@(test)
never_types_into_a_dialog_that_herdr_calls_idle :: proc(t: ^testing.T) {
	dialogs := []string {
		S_PERMISSION,
		#load("../testdata/screens/permission-edit.txt", string),
		S_RESUME,
		#load("../testdata/screens/resume-above.txt", string),
		#load("../testdata/screens/resume-replacing.txt", string),
		#load("../testdata/screens/ask-question.txt", string),
		#load("../testdata/screens/model-picker.txt", string),
		#load("../testdata/screens/question-tabs.txt", string),
	}
	for screen, i in dialogs {
		f := fixture(t)
		fk := fake_make(t)
		add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {screen}})
		add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"done"}, screens = {S_EMPTY, screen}})
		write_record(f, "w1:p1", SID_A)
		write_record(f, "w1:p2", SID_B)
		r := roll.roll(config(fk, f.state), f.a)
		testing.expectf(t, calls_of(fk, "herdr", "agent", "prompt") == 0, "dialog %d: a prompt was sent", i)
		testing.expectf(t, calls_of(fk, "herdr", "agent", "send-keys") == 0, "dialog %d: keys were sent", i)
		testing.expectf(t, calls_of(fk, "herdr", "agent", "start") == 0, "dialog %d: an agent was started", i)
		testing.expectf(t, outcome_of(r, "w1:p1") == .Dialog, "dialog %d: %v", i, outcome_of(r, "w1:p1"))
		// The second pane showed the dialog only at the second read.
		testing.expectf(t, outcome_of(r, "w1:p2") == .Dialog, "dialog %d, second read: %v", i, outcome_of(r, "w1:p2"))
		n := notes(fk)
		testing.expectf(t, len(n) == 2, "dialog %d: %d notifications", i, len(n))
		for m in n {
			testing.expect(t, strings.contains(m, "w1:p"))
		}
		testing.expect_value(t, calls_of(fk, "ravnix-notify", "--topic", "sessions", "--"), 2)
		fake_destroy(fk)
		fixture_destroy(f)
	}
}

@(test)
retries_a_working_pane_until_it_is_idle :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"working", "working", "idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	testing.expect(t, p.started)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "list"), 3)
	// Not read while it was working.
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "read"), 2)
	testing.expect(t, fk.slept >= 2 * roll.DEFAULT_POLL)
}

@(test)
leaves_a_working_pane_at_the_deadline :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"working"}, screens = {S_WORKING}})
	write_record(f, "w1:p1", SID_A)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Left)
	testing.expect(t, !sent_anything(fk))
	// It waited three hours and not much longer.
	waited := time.diff(T0, fk.now)
	testing.expectf(t, waited >= 3 * time.Hour && waited <= 3 * time.Hour + roll.DEFAULT_POLL + time.Minute, "waited %v", waited)
}

// The deadline falls in the middle of a sleep: the run ends there.
@(test)
the_deadline_cuts_a_wait_short :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"working"}, screens = {S_WORKING}})
	write_record(f, "w1:p1", SID_A)
	cfg := config(fk, f.state)
	cfg.deadline = 45 * time.Second
	cfg.poll = 30 * time.Second

	r := roll.roll(cfg, f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Left)
	testing.expectf(t, time.diff(T0, fk.now) < 46 * time.Second, "ran %v", time.diff(T0, fk.now))
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "list"), 3)
}

// The deadline passes while a pane is between its /exit and its start: the
// resume is finished all the same, since the session is no longer running.
@(test)
the_deadline_never_strands_a_session_mid_roll :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, shell_after = 8})
	write_record(f, "w1:p1", SID_A)
	cfg := config(fk, f.state)
	cfg.deadline = time.Second

	r := roll.roll(cfg, f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	testing.expect(t, p.started)
	testing.expect(t, time.diff(T0, fk.now) > time.Second)
}

@(test)
skips_a_blocked_pane_and_says_so_once :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"blocked"}, screens = {S_PERMISSION}})
	// A second pane keeps the run going for a while.
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"working", "working", "working", "idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Blocked)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Rolled)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "read", "w1:p1"), 0)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p1"), 0)
	n := notes(fk)
	testing.expect_value(t, len(n), 1)
	testing.expect(t, len(n) == 1 && strings.contains(n[0], "w1:p1"))
	testing.expect_value(t, calls_of(fk, "ravnix-notify", "--topic", "sessions", "--"), 1)
}

// After /clear the pane runs another session, and the hook has written its
// record again: the new id is resumed, with the flags of the process.
@(test)
resumes_the_session_the_pane_runs_now :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "w1:p1", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_C, "--add-dir", "/a")
	// herdr knows no session for this one: the record (rewritten by the hook
	// at /clear) has it.
	q := add_pane(fk, {id = "w1:p2", statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p2", SID_B)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	testing.expect(t, contains_seq(p.start_argv, {"--", "--resume", SID_C, "--add-dir", "/a"}))
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Rolled)
	testing.expect(t, contains_seq(q.start_argv, {"--", "--resume", SID_B}))
}

@(test)
a_failed_resume_names_the_session_to_resume_by_hand :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, start_error = E_START_FAILED})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}, start_error = E_PANE_BUSY})
	add_pane(fk, {id = "w1:p3", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}, start_error = E_START_TIMEOUT})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	write_record(f, "w1:p3", SID_C)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, r.status, 1)
	sids := []string{SID_A, SID_B, SID_C}
	for pane, i in ([]string{"w1:p1", "w1:p2", "w1:p3"}) {
		testing.expectf(t, outcome_of(r, pane) == .Failed, "%s: %v", pane, outcome_of(r, pane))
		found := false
		for m in notes(fk) {
			if strings.contains(m, pane) && strings.contains(m, strings.concatenate({"claude --resume ", sids[i]}, f.a)) {
				found = true
			}
		}
		testing.expectf(t, found, "%s: no notification with claude --resume %s in %v", pane, sids[i], notes(fk))
	}
}

// Claude Code that does not leave on /exit, or a pane where something
// else takes the foreground: no start into it, and the user is told.
@(test)
waits_for_the_shell_and_gives_up_cleanly :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, no_exit = true})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}, command_after = true})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, calls_of(fk, "herdr", "agent", "start"), 0)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Failed)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Failed)
	testing.expect_value(t, len(notes(fk)), 2)
	for m in notes(fk) {
		testing.expect(t, strings.contains(m, "claude --resume"))
	}
	testing.expect_value(t, r.status, 1)
}

// The resumed session stops at a dialog while it starts (the "Resume this
// conversation?" one, say): it runs, and waits for the user.
@(test)
a_resume_that_waits_at_a_dialog_is_reported :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, start_error = E_START_NOT_READY})
	write_record(f, "w1:p1", SID_A)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Stalled)
	n := notes(fk)
	testing.expect(t, len(n) == 1 && strings.contains(n[0], "w1:p1") && strings.contains(n[0], "dialog"))
	// Nothing typed into the new session.
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt"), 1)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "send-keys"), 0)
}

// --dry-run sends nothing at all: no prompt, no key, no start, no
// notification. It reads, and says what it would do.
@(test)
a_dry_run_sends_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"blocked"}, screens = {S_PERMISSION}})
	add_pane(fk, {id = "w1:p3", session = SID_C, statuses = {"working"}, screens = {S_WORKING}})
	add_pane(fk, {id = "w1:p4", session = SID_C, statuses = {"idle"}, screens = {S_RESUME}})
	add_pane(fk, {id = "w1:p5", session = "bad id", statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p6", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, start_error = E_START_FAILED})
	write_record(f, "w1:p1", SID_A, "--add-dir", "/a")
	write_record(f, "w1:p4", SID_C)
	write_record(f, "w1:p6", SID_A)
	cfg := config(fk, f.state)
	cfg.dry_run = true

	r := roll.roll(cfg, f.a)

	for c in fk.calls {
		testing.expectf(t, is_read_only(c), "--dry-run ran %v", c)
	}
	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Would_Roll)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Blocked)
	testing.expect_value(t, outcome_of(r, "w1:p3"), roll.Outcome.Left)
	testing.expect_value(t, outcome_of(r, "w1:p4"), roll.Outcome.Dialog)
	testing.expect_value(t, outcome_of(r, "w1:p5"), roll.Outcome.Cannot)
	// One pass: no waiting for the working pane.
	testing.expect_value(t, fk.slept < time.Minute, true)
	log := strings.to_string(cfg.log^)
	testing.expectf(t, strings.contains(log, "--resume " + SID_A + " --add-dir /a"), "log: %s", log)
	testing.expect(t, strings.contains(log, "would notify"))
	// It takes no lock either: a dry run beside a real one is fine.
	testing.expect_value(t, count_entries(f, f.state) <= 1, true)
}

@(test)
herdr_not_running_or_missing_ends_the_run :: proc(t: ^testing.T) {
	for kind in 0 ..< 2 {
		f := fixture(t)
		fk := fake_make(t)
		if kind == 0 {
			fk.list_error = E_NOT_RUNNING
		} else {
			fk.missing = true
		}
		add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
		write_record(f, "w1:p1", SID_A)
		cfg := config(fk, f.state)
		r := roll.roll(cfg, f.a)
		testing.expect_value(t, r.status, 1)
		testing.expect(t, !sent_anything(fk))
		testing.expect_value(t, len(fk.calls), 1)
		log := strings.to_string(cfg.log^)
		if kind == 0 {
			testing.expectf(t, strings.contains(log, "server_not_running"), "log: %s", log)
		}
		fake_destroy(fk)
		fixture_destroy(f)
	}
}

// herdr goes away in the middle of the run, while a pane is still working.
@(test)
herdr_dying_mid_run_stops_the_run :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	fk.list_error = E_NOT_RUNNING
	fk.list_fails_at = 3
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"working"}, screens = {S_WORKING}})
	write_record(f, "w1:p1", SID_A)
	r := roll.roll(config(fk, f.state), f.a)
	testing.expect_value(t, r.status, 1)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Left)
	testing.expect(t, !sent_anything(fk))
}

@(test)
a_list_that_is_no_list_sends_nothing :: proc(t: ^testing.T) {
	full := J_LIST
	bad := []string {
		"",
		"not json",
		full[:len(full) / 2],
		`{"id":"cli:agent:list","result":{"agents":"x","type":"agent_list"}}`,
		`{"id":"cli:agent:list","result":{"agents":[],"type":"pane_list"}}`,
		`{"id":"cli:agent:list","result":{"agents":[{"agent":"claude","agent_status":"idle"}],"type":"agent_list"}}`,
		`[]`,
		"\x00",
	}
	for raw in bad {
		f := fixture(t)
		fk := fake_make(t)
		fk.use_raw = true
		fk.list_raw = raw
		cfg := config(fk, f.state)
		r := roll.roll(cfg, f.a)
		testing.expectf(t, !sent_anything(fk), "%q: sent something", raw)
		if raw != bad[5] {
			testing.expectf(t, r.status == 1, "%q: status %d", raw, r.status)
		}
		fake_destroy(fk)
		fixture_destroy(f)
	}
}

// The recorded list of a real herdr: three Claude Code panes, one idle.
@(test)
reads_the_recorded_agent_list :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	agents, err := roll.parse_agent_list(J_LIST, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(agents), 3)
	testing.expect_value(t, agents[1].pane_id, "wK:p1")
	testing.expect_value(t, agents[1].agent, "claude")
	testing.expect_value(t, agents[1].agent_status, "idle")
	testing.expect_value(t, agents[1].agent_session.kind, "id")
	testing.expect_value(t, agents[1].agent_session.value, SID_B)
	testing.expect_value(t, agents[0].agent_status, "working")

	at, aerr := roll.at_shell(J_AT_SHELL, J_GET_SHELL)
	testing.expect_value(t, aerr, "")
	testing.expect(t, at)
	for pi in ([]string{J_IN_CLAUDE, J_IN_COMMAND}) {
		at, aerr = roll.at_shell(pi, J_GET_SHELL)
		testing.expect(t, !at && aerr == "")
	}
	at, _ = roll.at_shell(J_AT_SHELL, J_GET_AGENT)
	testing.expect(t, !at)
	_, aerr = roll.at_shell("{", J_GET_SHELL)
	testing.expect(t, aerr != "")

	pids, perr := roll.foreground_pids(J_IN_CLAUDE, f.a)
	testing.expect_value(t, perr, "")
	testing.expect(t, len(pids) == 1 && pids[0] == 3318752)
	pids, perr = roll.foreground_pids(J_AT_SHELL, f.a)
	testing.expect(t, perr == "" && len(pids) == 1 && pids[0] == 5795)
	_, perr = roll.foreground_pids(J_GET_SHELL, f.a)
	testing.expect(t, perr != "")

	code, msg := roll.herdr_error(E_NOT_RUNNING, f.a)
	testing.expect_value(t, code, "server_not_running")
	testing.expect(t, strings.contains(msg, "no herdr server"))
	code, _ = roll.herdr_error("garbage", f.a)
	testing.expect_value(t, code, "")
}

@(test)
a_pane_gone_between_list_and_read_is_let_go :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, gone_at_read = true})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"working"}, screens = {S_EMPTY}, gone_from_list = 2})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	r := roll.roll(config(fk, f.state), f.a)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Gone)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Gone)
	testing.expect(t, !sent_anything(fk))
	testing.expect_value(t, r.status, 0)
	// Gone: no reason to wait for the deadline.
	testing.expect(t, time.diff(T0, fk.now) < 5 * time.Minute)
}

// The screen changes between the two reads before the /exit: a turn
// started, or a dialog came up. Nothing is sent on that round.
@(test)
a_screen_that_changes_before_the_send_is_not_sent_to :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY, S_WORKING, S_EMPTY, S_EMPTY}})
	q := add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_SUGGESTION, S_DRAFT}})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	cfg := config(fk, f.state)
	cfg.deadline = 10 * time.Minute
	r := roll.roll(cfg, f.a)
	// The first one settles and is rolled on the next round.
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	testing.expect_value(t, p.reads, 4)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p1"), 1)
	// The second keeps a draft: never sent to.
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Left)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p2"), 0)
	testing.expect(t, !q.started)
}

@(test)
a_session_id_with_odd_characters_is_not_used :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	odd := []string{"--dangerously-skip-permissions", "x; rm -r ~", "0a1b2c3d-1111-4222-8333-444455556666\nmore", SID_A}
	for sid, i in odd {
		pane := strings.concatenate({"w1:p", string([]u8{u8('1' + i)})}, f.a)
		kind := "path" if i == 3 else ""
		add_pane(fk, {id = pane, session = sid, session_kind = kind, statuses = {"idle"}, screens = {S_EMPTY}})
		write_record(f, pane, "not-a-uuid")
	}
	r := roll.roll(config(fk, f.state), f.a)
	testing.expect(t, !sent_anything_but_notes(fk))
	for p in r.panes {
		testing.expectf(t, p.outcome == .Cannot, "%s: %v", p.pane, p.outcome)
	}
	// The odd id itself is not echoed into the notification.
	for m in notes(fk) {
		testing.expect(t, !strings.contains(m, "rm -r"))
		testing.expect(t, !strings.contains(m, "\n"))
	}
}

@(test)
a_pane_without_usable_launch_flags_is_left_and_named :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p3", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}})
	// w1:p1 has none; w1:p2 a broken one; w1:p3 one with a flag claude-roll
	// cannot carry.
	dir := pj(f.a, f.state, "claude-panes")
	_ = os.make_directory_all(dir)
	write_file(f, pj(f.a, dir, "w1:p2.json"), `{"pane":"w1:p2","session_id":`)
	write_record(f, "w1:p3", SID_C, "--worktree", "feature")

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect(t, !sent_anything_but_notes(fk))
	for pane in ([]string{"w1:p1", "w1:p2", "w1:p3"}) {
		testing.expectf(t, outcome_of(r, pane) == .Cannot, "%s: %v", pane, outcome_of(r, pane))
	}
	n := notes(fk)
	testing.expect_value(t, len(n), 3)
	testing.expect(t, len(n) == 3 && strings.contains(n[2], "--worktree"))
}

// The busy file of the UserPromptSubmit/Stop hooks says a turn runs: the
// second signal wins over herdr's idle.
@(test)
the_busy_hook_holds_a_pane_back :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	busy := pj(f.a, f.state, "claude-busy")
	_ = os.make_directory_all(busy)
	write_file(f, pj(f.a, busy, SID_A), "busy\n")
	write_file(f, pj(f.a, busy, SID_B), "idle\n")
	cfg := config(fk, f.state)
	cfg.deadline = 5 * time.Minute

	r := roll.roll(cfg, f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Left)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p1"), 0)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Rolled)
}

// herdr refuses the /exit: the agent turned blocked, or left, just before.
@(test)
a_refused_exit_starts_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, prompt_error = E_BLOCKED})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}, prompt_error = E_AGENT_NOT_FOUND})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	r := roll.roll(config(fk, f.state), f.a)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "start"), 0)
	// One look at each pane's processes before the /exit, no wait for a
	// shell after it.
	testing.expect_value(t, calls_of(fk, "herdr", "pane", "process-info"), 2)
	testing.expect_value(t, calls_of(fk, "herdr", "pane", "get"), 0)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Blocked)
	testing.expect_value(t, outcome_of(r, "w1:p2"), roll.Outcome.Gone)
	testing.expect_value(t, len(notes(fk)), 1)
}

// The /exit call itself times out: whether it arrived is unknown, so the
// shell is waited for, and the session resumed if it ended.
@(test)
an_exit_of_unknown_fate_is_followed_up :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	p := add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, prompt_hangs = true})
	write_record(f, "w1:p1", SID_A)
	r := roll.roll(config(fk, f.state), f.a)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	testing.expect(t, p.started)
}

@(test)
rolls_each_pane_once_and_only_claude :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, name = "reviewer", statuses = {"idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"working", "working", "idle"}, screens = {S_EMPTY}})
	add_pane(fk, {id = "w1:p3", agent = "codex", statuses = {"idle"}, screens = {S_EMPTY}})
	// A pane that shows up during the run already runs the new version.
	add_pane(fk, {id = "w1:p4", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}, appears_at = 2})
	write_record(f, "w1:p1", SID_A)
	write_record(f, "w1:p2", SID_B)
	write_record(f, "w1:p4", SID_C)

	cfg := config(fk, f.state)
	r := roll.roll(cfg, f.a)

	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p1"), 1)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "start", "reviewer"), 1)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "prompt", "w1:p2"), 1)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "read", "w1:p3"), 0)
	testing.expect_value(t, outcome_of(r, "w1:p3"), roll.Outcome.Pending)
	testing.expect_value(t, outcome_of(r, "w1:p4"), roll.Outcome.Pending)
	testing.expect_value(t, calls_of(fk, "herdr", "agent", "read", "w1:p4"), 0)
	testing.expectf(t, r.status == 0, "log: %s", strings.to_string(cfg.log^))
}

@(test)
a_notification_that_fails_does_not_stop_the_run :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	fk.notify_exit = 75
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"blocked"}, screens = {S_PERMISSION}})
	p := add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p2", SID_B)
	cfg := config(fk, f.state)
	r := roll.roll(cfg, f.a)
	testing.expect(t, p.started)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Blocked)
	testing.expect(t, strings.contains(strings.to_string(cfg.log^), "ravnix-notify"))
}

// Two runs at once: the second finds the lock and leaves without a call.
@(test)
a_second_run_at_once_does_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)

	// The first run holds the lock (a lock of its own file description, as
	// another process would have it).
	_ = os.make_directory_all(f.state)
	lock_path := pj(f.a, f.state, roll.LOCK_NAME)
	held, err := os.open(lock_path, {.Read, .Write, .Create})
	testing.expect(t, err == nil)
	testing.expect_value(t, linux.flock(linux.Fd(os.fd(held)), {.EX, .NB}), linux.Errno.NONE)

	cfg := config(fk, f.state)
	r := roll.roll(cfg, f.a)
	testing.expect_value(t, r.status, roll.EXIT_LOCKED)
	testing.expect_value(t, len(fk.calls), 0)
	testing.expect(t, strings.contains(strings.to_string(cfg.log^), "another"))

	// Once it is let go, a run goes ahead, and leaves the lock free again.
	_ = linux.flock(linux.Fd(os.fd(held)), {.UN})
	r = roll.roll(config(fk, f.state), f.a)
	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Rolled)
	// Another test's child may hold a copy of the file for the moment
	// between its fork and its exec (the files are close-on-exec), so the
	// lock is tried for a while.
	again := linux.Errno.EAGAIN
	for _ in 0 ..< 100 {
		if again = linux.flock(linux.Fd(os.fd(held)), {.EX, .NB}); again != .EAGAIN {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, again, linux.Errno.NONE)
	os.close(held)
}

// A state directory that cannot be made: the run says so and sends nothing.
@(test)
an_unusable_state_directory_stops_the_run :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	file := pj(f.a, f.dir, "a-file")
	write_file(f, file, "x")
	cfg := config(fk, pj(f.a, file, "state"))
	r := roll.roll(cfg, f.a)
	testing.expect_value(t, r.status, 1)
	testing.expect_value(t, len(fk.calls), 0)
}

contains_seq :: proc(hay, needle: []string) -> bool {
	if len(needle) > len(hay) {
		return false
	}
	for i in 0 ..= len(hay) - len(needle) {
		if equal_strings(hay[i:i + len(needle)], needle) {
			return true
		}
	}
	return false
}

sent_anything_but_notes :: proc(fk: ^Fake) -> bool {
	for c in fk.calls {
		if !is_read_only(c) && filepath.base(c[0]) != "ravnix-notify" {
			return true
		}
	}
	return false
}

// call_order is the herdr subcommands in the order they ran.
call_order :: proc(fk: ^Fake) -> string {
	b := strings.builder_make(fk.a)
	for c in fk.calls {
		if len(c) > 2 && filepath.base(c[0]) == "herdr" {
			strings.write_string(&b, c[2])
			strings.write_byte(&b, ' ')
		}
	}
	return strings.to_string(b)
}

// The record is of another session than the one herdr says the pane runs:
// a nested Claude Code wrote it, or a moved pane, or the hook failed and
// left an old one. Its flags are not used, and the user is told.
@(test)
a_record_of_another_session_is_not_used :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A, "--dangerously-skip-permissions")

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Cannot)
	testing.expect(t, !sent_anything_but_notes(fk))
	n := notes(fk)
	testing.expect(t, len(n) == 1 && strings.contains(n[0], "w1:p1") && strings.contains(n[0], "another session"))
}

// The record names a process that is not the Claude Code in the pane's
// foreground now: another pid, a pid reused by a later process, or an old
// record without one. Not used.
@(test)
a_record_of_another_process_is_not_used :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}, fg_pid = 4242})
	write_record(f, "w1:p1", SID_A)
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p2", SID_B)
	// The pid is alive, but another process holds it now.
	pid := pid_of("w1:p2")
	fake_process(f, pj(f.a, f.dir, "proc"), {pid = pid, ppid = 1, pgid = pid, start = start_of(pid) + 7, comm = "claude", argv = {"claude"}})
	add_pane(fk, {id = "w1:p3", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p3", SID_C)
	write_file(f, pj(f.a, f.state, "claude-panes", "w1:p3.json"), `{"pane":"w1:p3","session_id":"` + SID_C + `","argv":[]}`)

	r := roll.roll(config(fk, f.state), f.a)

	testing.expect(t, !sent_anything_but_notes(fk))
	for pane in ([]string{"w1:p1", "w1:p2", "w1:p3"}) {
		testing.expectf(t, outcome_of(r, pane) == .Cannot, "%s: %v", pane, outcome_of(r, pane))
	}
	testing.expect_value(t, len(notes(fk)), 3)
}

// A session whose turn has ended can still run work: a command started in
// the background (a dev server, a long build) is a child of Claude Code,
// in a process group of its own, and /exit would end it. Such a pane waits;
// the MCP servers Claude Code keeps in its own group do not hold it back.
@(test)
a_session_with_a_background_task_is_not_exited :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	root := pj(f.a, f.dir, "proc")
	// A Bash tool command in the background.
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)
	p1 := pid_of("w1:p1")
	fake_process(f, root, {pid = 70001, ppid = p1, pgid = 70001, start = 9, comm = "bash", argv = {"/bin/bash", "-c", "source /home/user/.claude/shell-snapshots/snapshot-bash-1-x.sh 2>/dev/null || true && eval 'npm run dev' < /dev/null && pwd -P >| /tmp/claude-1-cwd"}})
	// A child in a group of its own that is no Bash tool shell: unknown work.
	add_pane(fk, {id = "w1:p2", session = SID_B, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p2", SID_B)
	fake_process(f, root, {pid = 70002, ppid = pid_of("w1:p2"), pgid = 70002, start = 9, comm = "sleep", argv = {"sleep", "600"}})
	// A Bash tool shell in Claude Code's own group still counts.
	add_pane(fk, {id = "w1:p3", session = SID_C, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p3", SID_C)
	p3 := pid_of("w1:p3")
	fake_process(f, root, {pid = 70003, ppid = p3, pgid = p3, start = 9, comm = "bash", argv = {"/bin/bash", "-c", "source /home/user/.claude/shell-snapshots/snapshot-bash-2-y.sh && eval 'make'"}})
	// Only an MCP server, in Claude Code's group: rolled.
	add_pane(fk, {id = "w1:p4", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p4", SID_A)
	p4 := pid_of("w1:p4")
	fake_process(f, root, {pid = 70004, ppid = p4, pgid = p4, start = 9, comm = "node", argv = {"node", "/home/user/mcp/server.js"}})
	cfg := config(fk, f.state)
	cfg.deadline = 5 * time.Minute

	r := roll.roll(cfg, f.a)

	for pane in ([]string{"w1:p1", "w1:p2", "w1:p3"}) {
		testing.expectf(t, outcome_of(r, pane) == .Left, "%s: %v", pane, outcome_of(r, pane))
		testing.expectf(t, calls_of(fk, "herdr", "agent", "prompt", pane) == 0, "%s got /exit", pane)
	}
	testing.expect_value(t, outcome_of(r, "w1:p4"), roll.Outcome.Rolled)
	for p in r.panes {
		if p.pane == "w1:p1" {
			testing.expectf(t, strings.contains(p.reason, "background"), "reason: %s", p.reason)
		}
	}
}

// When the processes cannot be read, nobody can say that no background work
// runs: the pane waits.
@(test)
unreadable_processes_hold_a_pane_back :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fk := fake_make(t)
	defer fake_destroy(fk)
	add_pane(fk, {id = "w1:p1", session = SID_A, statuses = {"idle"}, screens = {S_EMPTY}})
	write_record(f, "w1:p1", SID_A)
	cfg := config(fk, f.state)
	cfg.proc_root = pj(f.a, f.dir, "no-proc")
	cfg.deadline = time.Minute

	r := roll.roll(cfg, f.a)

	testing.expect_value(t, outcome_of(r, "w1:p1"), roll.Outcome.Left)
	testing.expect(t, !sent_anything(fk))
}
