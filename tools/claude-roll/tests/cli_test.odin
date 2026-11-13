// The command line, and claude-roll against a herdr that is a program:
// the runner, a herdr that is not there, one that answers with an error,
// one that hangs, and --dry-run through real processes.
package claude_roll_tests

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import roll ".."

FAKE_HERDR :: #directory + "/../testdata/fake-herdr"

@(test)
parses_the_command_line :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	env := roll.Environment{state_home = "/s", home = "/h"}

	a, err := roll.parse_args({}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.command, roll.Command.Roll)
	testing.expect_value(t, a.cfg.deadline, 3 * time.Hour)
	testing.expect_value(t, a.cfg.dry_run, false)
	testing.expect_value(t, a.cfg.state_dir, "/s/ravnix")
	testing.expect_value(t, a.cfg.herdr, "herdr")
	testing.expect_value(t, a.cfg.notify, "ravnix-notify")

	a, err = roll.parse_args({"--dry-run", "--deadline", "90m", "--state", "/x", "--herdr", "/bin/h", "--ravnix-notify", "/bin/n"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect(t, a.cfg.dry_run)
	testing.expect_value(t, a.cfg.deadline, 90 * time.Minute)
	testing.expect_value(t, a.cfg.state_dir, "/x")
	testing.expect_value(t, a.cfg.herdr, "/bin/h")
	testing.expect_value(t, a.cfg.notify, "/bin/n")

	a, err = roll.parse_args({"--deadline=1h30m"}, roll.Environment{home = "/h"}, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.cfg.deadline, 90 * time.Minute)
	testing.expect_value(t, a.cfg.state_dir, "/h/.local/state/ravnix")

	a, err = roll.parse_args({"record"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.command, roll.Command.Record)

	a, err = roll.parse_args({"classify", "a.txt", "b.txt"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.command, roll.Command.Classify)
	testing.expect_value(t, len(a.files), 2)

	a, err = roll.parse_args({"--help"}, env, f.a)
	testing.expect_value(t, a.command, roll.Command.Help)

	for bad in ([][]string {
			{"--deadline"},
			{"--deadline", "3"},
			{"--deadline", "h"},
			{"--deadline", "-1h"},
			{"--deadline", "3x"},
			{"--deadline", "99999999999999999999h"},
			{"--deadline", "200h"},
			{"--state"},
			{"--state", ""},
			{"--herdr", ""},
			{"--no-such-option"},
			{"roll"},
			{"classify"},
			{"record", "x"},
		}) {
		_, e := roll.parse_args(bad, env, f.a)
		testing.expectf(t, e != "", "%v parsed", bad)
	}
	// Without a home or a state home there is no default state directory.
	_, err = roll.parse_args({}, roll.Environment{}, f.a)
	testing.expect(t, err != "")
	_, err = roll.parse_args({"--state", "/x"}, roll.Environment{}, f.a)
	testing.expect_value(t, err, "")
}

@(test)
parses_durations :: proc(t: ^testing.T) {
	cases := []struct {
		s: string,
		d: time.Duration,
	}{{"3h", 3 * time.Hour}, {"0s", 0}, {"45s", 45 * time.Second}, {"1h30m", 90 * time.Minute}, {"2m5s", 125 * time.Second}, {"168h", 168 * time.Hour}}
	for c in cases {
		d, ok := roll.parse_duration(c.s)
		testing.expectf(t, ok && d == c.d, "%s: %v %v", c.s, d, ok)
	}
	for bad in ([]string{"", "3", "h", "3h3", "3hh", " 3h", "3 h", "1d", "169h", "-3h", "+3h", "3.5h"}) {
		_, ok := roll.parse_duration(bad)
		testing.expectf(t, !ok, "%q parsed", bad)
	}
}

Proc_Fixture :: struct {
	using f: ^Fixture,
	bin:     string,
}

proc_fixture :: proc(t: ^testing.T) -> Proc_Fixture {
	f := fixture(t)
	bin := pj(f.a, f.dir, "bin")
	if os.make_directory(bin) != nil || os.symlink(FAKE_HERDR, pj(f.a, bin, "herdr")) != nil {
		testing.fail_now(t, "cannot set up the fake herdr")
	}
	return {f, bin}
}

answer :: proc(pf: Proc_Fixture, name: string, data: string) {
	write_file(pf.f, pj(pf.a, pf.bin, name), data)
}

// herdr_log returns the herdr calls the fake recorded, each as its words
// joined by blanks.
herdr_log :: proc(pf: Proc_Fixture) -> []string {
	data, _ := os.read_entire_file(pj(pf.a, pf.bin, "log"), pf.a)
	out := make([dynamic]string, pf.a)
	for run in strings.split(string(data), "\x01", pf.a) {
		if run == "" {
			continue
		}
		words := strings.split(strings.trim_right(run, "\x00"), "\x00", pf.a)
		append(&out, strings.join(words, " ", pf.a))
	}
	return out[:]
}

proc_config :: proc(pf: Proc_Fixture) -> roll.Config {
	cfg := roll.default_config()
	cfg.state_dir = pf.state
	cfg.herdr = pj(pf.a, pf.bin, "herdr")
	cfg.notify = pj(pf.a, pf.bin, "no-ravnix-notify")
	cfg.proc_root = pj(pf.a, pf.dir, "proc")
	cfg.log = new(strings.Builder, pf.a)
	strings.builder_init(cfg.log, pf.a)
	return cfg
}

// --dry-run against a herdr that is a program: it reads the list and the
// screen, and runs nothing else.
@(test)
a_dry_run_through_processes_only_reads :: proc(t: ^testing.T) {
	pf := proc_fixture(t)
	defer fixture_destroy(pf.f)
	answer(pf, "agent-list.out", J_LIST)
	answer(pf, "agent-read.out", S_EMPTY)
	write_record(pf.f, "wK:p1", SID_B, "--add-dir", "/home/user/notes")
	fk := fake_make(t)
	defer fake_destroy(fk)
	answer(pf, "pane-process-info.out", in_claude(fk, add_pane(fk, {id = "wK:p1"})))
	cfg := proc_config(pf)
	cfg.dry_run = true

	r := roll.roll(cfg, pf.a)

	testing.expect_value(t, r.status, 0)
	testing.expect_value(t, outcome_of(r, "wK:p1"), roll.Outcome.Would_Roll)
	log := herdr_log(pf)
	testing.expect_value(t, len(log), 4)
	testing.expect_value(t, log[0], "agent list")
	testing.expect_value(t, log[1], "pane process-info --pane wK:p1")
	for l in log[2:] {
		testing.expectf(t, strings.has_prefix(l, "agent read wK:p1 --source visible --format ansi"), "ran: %s", l)
	}
	out := strings.to_string(cfg.log^)
	testing.expectf(t, strings.contains(out, "herdr agent start claude-wk-p1 --kind claude --pane wK:p1 --timeout 120000 -- --resume " + SID_B + " --add-dir /home/user/notes"), "log: %s", out)
}

@(test)
a_herdr_that_is_not_there :: proc(t: ^testing.T) {
	pf := proc_fixture(t)
	defer fixture_destroy(pf.f)
	cfg := proc_config(pf)
	cfg.herdr = pj(pf.a, pf.bin, "no-herdr")
	r := roll.roll(cfg, pf.a)
	testing.expect_value(t, r.status, 1)
	testing.expectf(t, strings.contains(strings.to_string(cfg.log^), "no-herdr"), "log: %s", strings.to_string(cfg.log^))
}

@(test)
a_herdr_whose_server_is_gone :: proc(t: ^testing.T) {
	pf := proc_fixture(t)
	defer fixture_destroy(pf.f)
	answer(pf, "agent-list.err", E_NOT_RUNNING)
	answer(pf, "agent-list.rc", "1\n")
	cfg := proc_config(pf)
	r := roll.roll(cfg, pf.a)
	testing.expect_value(t, r.status, 1)
	testing.expect_value(t, len(herdr_log(pf)), 1)
	testing.expect(t, strings.contains(strings.to_string(cfg.log^), "server_not_running"))
}

@(test)
a_herdr_that_hangs_is_killed :: proc(t: ^testing.T) {
	pf := proc_fixture(t)
	defer fixture_destroy(pf.f)
	answer(pf, "agent-list.hang", "")
	cfg := proc_config(pf)
	cfg.call_timeout = 300 * time.Millisecond
	start := time.tick_now()
	r := roll.roll(cfg, pf.a)
	testing.expect_value(t, r.status, 1)
	testing.expect(t, time.tick_since(start) < 10 * time.Second)
	testing.expect(t, strings.contains(strings.to_string(cfg.log^), "did not answer"))
}

// A list far larger than any real one is refused, not read without end.
@(test)
a_herdr_that_prints_without_end_is_cut_off :: proc(t: ^testing.T) {
	pf := proc_fixture(t)
	defer fixture_destroy(pf.f)
	answer(pf, "agent-list.out", strings.repeat("x", roll.MAX_OUTPUT + 1, pf.a))
	cfg := proc_config(pf)
	r := roll.roll(cfg, pf.a)
	testing.expect_value(t, r.status, 1)
}
