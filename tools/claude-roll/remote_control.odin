// claude-roll remote-control: after an update, restart Claude Code's Remote
// Control unit onto the new version, but only while it holds no session.
//
// Remote Control is a user unit, not a herdr pane, so the roll does not see
// it, and a restart ends every session the phone has open in it. Each such
// session is a process of the unit beside its main one (`claude
// remote-control --spawn worktree` starts one per session), so the unit is
// restarted only when its control group holds the main process alone. While
// it holds more, the check is repeated every minute until the deadline;
// then the unit stays on the old version, and the user is told how to
// restart it. A control group that cannot be read counts as busy.
package claude_roll

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

DEFAULT_RC_UNIT :: "claude-remote-control.service"
DEFAULT_SYS_ROOT :: "/sys/fs/cgroup"
DEFAULT_RC_POLL :: 60 * time.Second

RC_Config :: struct {
	unit:     string,
	// Where the control groups are: /sys/fs/cgroup.
	sys_root: string,
	notify:   string,
	deadline: time.Duration,
	poll:     time.Duration,
	hooks:    Update_Hooks,
	log:      ^strings.Builder,
}

RC_Outcome :: enum {
	Failed,
	// The unit is not running: nothing to restart.
	Not_Running,
	Restarted,
	// It restarted by itself meanwhile, onto the installed version.
	Restarted_Itself,
	// A session stayed open until the deadline; the user was told.
	Left,
}

default_rc_config :: proc() -> RC_Config {
	return {unit = DEFAULT_RC_UNIT, sys_root = DEFAULT_SYS_ROOT, notify = "ravnix-notify", deadline = DEFAULT_DEADLINE, poll = DEFAULT_RC_POLL}
}

Unit_State :: struct {
	active:   string,
	main_pid: int,
	cgroup:   string,
}

remote_control :: proc(cfg: RC_Config) -> (outcome: RC_Outcome, status: int) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return .Failed, EXIT_FAILED
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	u := Updater{hooks = cfg.hooks, log = cfg.log, notify = cfg.notify, name = "claude-roll remote-control"}

	first, ok := unit_state(&u, cfg.unit)
	if !ok {
		return .Failed, EXIT_FAILED
	}
	if first.active != "active" || first.main_pid <= 0 {
		ulog(&u, "%s is not running (%s); nothing to restart", cfg.unit, first.active)
		return .Not_Running, EXIT_OK
	}
	deadline := time.time_add(unow(&u), cfg.deadline)
	for {
		state, read := unit_state(&u, cfg.unit)
		if !read {
			return .Failed, EXIT_FAILED
		}
		if state.active != "active" || state.main_pid <= 0 {
			ulog(&u, "%s stopped meanwhile (%s); nothing to restart", cfg.unit, state.active)
			return .Not_Running, EXIT_OK
		}
		if state.main_pid != first.main_pid {
			ulog(&u, "%s restarted by itself meanwhile, onto the installed Claude Code", cfg.unit)
			return .Restarted_Itself, EXIT_OK
		}
		others, counted := other_processes(cfg.sys_root, state)
		if counted && others == 0 {
			res := urun(&u, {argv = {"systemctl", "--user", "restart", "--", cfg.unit}, timeout = UNIT_TIMEOUT})
			if !succeeded_update(res) {
				rc_tell(&u, fmt.tprintf("Remote Control (%s) did not restart onto the new Claude Code: %s. Restart it with `systemctl --user restart %s`.", cfg.unit, tail(describe(res)), cfg.unit))
				return .Failed, EXIT_FAILED
			}
			ulog(&u, "restarted %s onto the installed Claude Code", cfg.unit)
			return .Restarted, EXIT_OK
		}
		if time.diff(unow(&u), deadline) <= 0 {
			why := fmt.tprintf("it holds %d processes besides its own, a session from the phone", others) if counted else "its processes could not be read"
			rc_tell(&u, fmt.tprintf("Remote Control (%s) stays on the Claude Code it started with: %s. Restart it with `systemctl --user restart %s` when no session is open; the restart ends every session in it.", cfg.unit, why, cfg.unit))
			return .Left, EXIT_OK
		}
		usleep(&u, cfg.poll)
	}
}

@(private = "file")
rc_tell :: proc(u: ^Updater, message: string) {
	ulog(u, "%s", message)
	res := urun(u, {argv = {u.notify, "--topic", NOTIFY_TOPIC, "--", message}, timeout = NOTIFY_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "ravnix-notify failed (%s)", describe(res))
	}
}

unit_state :: proc(u: ^Updater, unit: string) -> (s: Unit_State, ok: bool) {
	res := urun(u, {argv = {"systemctl", "--user", "show", "--property=ActiveState", "--property=MainPID", "--property=ControlGroup", "--", unit}, timeout = UNIT_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "cannot read the state of %s: %s", unit, describe(res))
		return s, false
	}
	return parse_unit_state(string(res.stdout)), true
}

parse_unit_state :: proc(text: string) -> (s: Unit_State) {
	s.main_pid = -1
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key, value := line[:eq], line[eq + 1:]
		switch key {
		case "ActiveState":
			s.active = value
		case "MainPID":
			n, ok := strconv.parse_int(value, 10)
			s.main_pid = n if ok else -1
		case "ControlGroup":
			s.cgroup = value
		}
	}
	return
}

// other_processes counts the processes in the unit's control group and the
// groups below it, other than its main one. counted is false when the group
// cannot be read, or the main process is not in it.
other_processes :: proc(sys_root: string, s: Unit_State) -> (others: int, counted: bool) {
	if !strings.has_prefix(s.cgroup, "/") || strings.contains(s.cgroup, "/../") || strings.has_suffix(s.cgroup, "/..") {
		return 0, false
	}
	dir, _ := filepath.join({sys_root, s.cgroup})
	main_seen := false
	if !count_group(dir, s.main_pid, &others, &main_seen, 0) {
		return others, false
	}
	return others, main_seen
}

@(private = "file")
count_group :: proc(dir: string, main_pid: int, others: ^int, main_seen: ^bool, depth: int) -> bool {
	if depth > 16 {
		return false
	}
	procs, _ := filepath.join({dir, "cgroup.procs"})
	data, err := os.read_entire_file(procs, context.allocator)
	if err != nil {
		return false
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		word := strings.trim_space(line)
		if word == "" {
			continue
		}
		pid, ok := strconv.parse_int(word, 10)
		if !ok {
			return false
		}
		if pid == main_pid {
			main_seen^ = true
		} else {
			others^ += 1
		}
	}
	d, oerr := os.open(dir)
	if oerr != nil {
		return false
	}
	defer os.close(d)
	entries, rerr := os.read_dir(d, -1, context.allocator)
	if rerr != nil {
		return false
	}
	for e in entries {
		if e.type == .Directory {
			sub, _ := filepath.join({dir, e.name})
			if !count_group(sub, main_pid, others, main_seen, depth + 1) {
				return false
			}
		}
	}
	return true
}
