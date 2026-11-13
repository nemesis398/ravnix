// Remote Control's restart after an update: only while its unit holds no
// session, read from the unit's control group in a fake /sys/fs/cgroup.
package claude_roll_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import roll ".."

CGROUP :: "/user.slice/user-1000.slice/user@1000.service/app.slice/claude-remote-control.service"

state_text :: proc(f: ^Fixture, active: string, pid: int) -> string {
	return fmt.aprintf("ActiveState=%s\nMainPID=%d\nControlGroup=%s\n", active, pid, CGROUP, allocator = f.a)
}

// group writes the pids into the unit's group, or a group below it.
group :: proc(f: ^Fixture, sub: string, pids: ..int) {
	dir := pj(f.a, f.dir, "sys", CGROUP, sub)
	_ = os.make_directory_all(dir)
	b := strings.builder_make(f.a)
	for p in pids {
		fmt.sbprintf(&b, "%d\n", p)
	}
	write_file(f, pj(f.a, dir, "cgroup.procs"), strings.to_string(b))
}

rc_config :: proc(f: ^Fixture, fu: ^Fake_Update, log: ^strings.Builder) -> roll.RC_Config {
	c := roll.default_rc_config()
	c.sys_root = pj(f.a, f.dir, "sys")
	c.deadline = 10 * time.Minute
	c.hooks = hooks_of(fu)
	c.log = log
	return c
}

@(test)
restarts_remote_control_that_holds_no_session :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.unit_states = {state_text(f, "active", 500)}
	group(f, "", 500)
	log := strings.builder_make(f.a)
	outcome, status := roll.remote_control(rc_config(f, fu, &log))
	testing.expect_value(t, outcome, roll.RC_Outcome.Restarted)
	testing.expect_value(t, status, 0)
	testing.expect(t, called(fu, "systemctl --user restart -- claude-remote-control.service"))
	testing.expect_value(t, len(fu.notified), 0)
}

@(test)
waits_while_a_phone_session_is_open :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.unit_states = {state_text(f, "active", 500)}
	group(f, "", 500, 501, 502)
	log := strings.builder_make(f.a)
	outcome, status := roll.remote_control(rc_config(f, fu, &log))
	testing.expect_value(t, outcome, roll.RC_Outcome.Left)
	testing.expect_value(t, status, 0)
	testing.expect(t, !called(fu, "systemctl --user restart"))
	testing.expect_value(t, len(fu.notified), 1)
	testing.expect(t, strings.contains(note(fu), "2 processes"), note(fu))
	testing.expect(t, called(fu, "ravnix-notify --topic sessions"))
	// It looked every minute for the ten minutes.
	testing.expect_value(t, fu.shows, 1 + 11)
}

@(test)
restarts_once_the_session_ends :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.unit_states = {state_text(f, "active", 500)}
	group(f, "", 500)
	// A process in a group below the unit's counts too.
	group(f, "session", 777)
	log := strings.builder_make(f.a)
	cfg := rc_config(f, fu, &log)
	cfg.deadline = 0
	outcome, _ := roll.remote_control(cfg)
	testing.expect_value(t, outcome, roll.RC_Outcome.Left)
	testing.expect(t, !called(fu, "systemctl --user restart"))

	group(f, "session")
	gu := fake_update(f)
	gu.unit_states = {state_text(f, "active", 500)}
	cfg.hooks = hooks_of(gu)
	outcome, _ = roll.remote_control(cfg)
	testing.expect_value(t, outcome, roll.RC_Outcome.Restarted)
}

@(test)
an_unreadable_group_counts_as_busy :: proc(t: ^testing.T) {
	cases := []string{"missing", "garbage", "no main", "escape"}
	for c in cases {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.unit_states = {state_text(f, "active", 500)}
		switch c {
		case "garbage":
			_ = os.make_directory_all(pj(f.a, f.dir, "sys", CGROUP))
			write_file(f, pj(f.a, f.dir, "sys", CGROUP, "cgroup.procs"), "500\nzzz\n")
		case "no main":
			group(f, "", 9)
		case "escape":
			fu.unit_states = {"ActiveState=active\nMainPID=500\nControlGroup=/../../etc\n"}
		}
		log := strings.builder_make(f.a)
		cfg := rc_config(f, fu, &log)
		cfg.deadline = 0
		outcome, _ := roll.remote_control(cfg)
		testing.expectf(t, outcome == .Left, "%s: %v", c, outcome)
		testing.expect(t, !called(fu, "systemctl --user restart"))
		testing.expect(t, strings.contains(note(fu), "could not be read") || c == "no main", note(fu))
	}
}

@(test)
leaves_a_stopped_or_restarted_unit_alone :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.unit_states = {state_text(f, "inactive", 0)}
	log := strings.builder_make(f.a)
	outcome, _ := roll.remote_control(rc_config(f, fu, &log))
	testing.expect_value(t, outcome, roll.RC_Outcome.Not_Running)

	// Busy at first, then Restart= started it again by itself.
	gu := fake_update(f)
	gu.unit_states = {state_text(f, "active", 500), state_text(f, "active", 500), state_text(f, "active", 900)}
	group(f, "", 500, 501)
	cfg := rc_config(f, gu, &log)
	outcome, _ = roll.remote_control(cfg)
	testing.expect_value(t, outcome, roll.RC_Outcome.Restarted_Itself)
	testing.expect(t, !called(gu, "systemctl --user restart"))

	// The user manager cannot be asked.
	hu := fake_update(f)
	cfg.hooks = hooks_of(hu)
	_, status := roll.remote_control(cfg)
	testing.expect_value(t, status, 1)
}

@(test)
tells_a_failed_restart :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.unit_states = {state_text(f, "active", 500)}
	fu.restart_fails = true
	group(f, "", 500)
	log := strings.builder_make(f.a)
	outcome, status := roll.remote_control(rc_config(f, fu, &log))
	testing.expect_value(t, outcome, roll.RC_Outcome.Failed)
	testing.expect_value(t, status, 1)
	testing.expect_value(t, len(fu.notified), 1)
}

@(test)
reads_the_units_state :: proc(t: ^testing.T) {
	s := roll.parse_unit_state("ActiveState=active\nMainPID=42\nControlGroup=/a.slice/b.service\nother=1\n")
	testing.expect_value(t, s.active, "active")
	testing.expect_value(t, s.main_pid, 42)
	testing.expect_value(t, s.cgroup, "/a.slice/b.service")
	s = roll.parse_unit_state("MainPID=x\n")
	testing.expect_value(t, s.main_pid, -1)
	testing.expect_value(t, s.active, "")
}
