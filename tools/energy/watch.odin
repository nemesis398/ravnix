package energy

import "core:os"
import "core:strings"
import "core:sys/linux"

// unplugged: the charger went away. Keep-awake is switched off, so it can't
// be forgotten on battery again (as it was for 8 days in late September),
// and with Focus bar on, waybar switches to its focus layout. Without
// keep-awake or waybar-launch the journal and a notification say so.
unplugged :: proc(cfg: ^Config) {
	if text, _ := read_text(run_path(cfg, "keep-awake")); text == "1" &&
	   need(cfg, "keep-awake", "keep-awake stays on after the unplug") &&
	   keep_awake(cfg, "off", "on") == 0 {
		notify(cfg, "Keep-awake off", "Switched off on unplug.")
	}
	key, _ := find_key("focus_bar")
	if state_get(cfg, key) != "on" {
		return
	}
	// No waybar-mode file counts as the full layout.
	mode, ok := read_text(run_path(cfg, "waybar-mode"))
	if !ok {
		mode = "full"
	}
	if mode == "full" && need(cfg, "waybar-launch", "the bar stays as it is") {
		write_file(cfg, run_path(cfg, "waybar-mode"), "focus\n")
		write_file(cfg, run_path(cfg, "energy-focus-auto"), "")
		launch_waybar(cfg)
	}
}

// plugged_in switches the bar back, but only if the watcher was the one
// that switched it (its marker file is there) and nobody has changed the
// mode since. Without waybar-launch the marker stays, so a later replug
// switches back.
plugged_in :: proc(cfg: ^Config) {
	marker := run_path(cfg, "energy-focus-auto")
	if !file_exists(marker) {
		return
	}
	if mode, _ := read_text(run_path(cfg, "waybar-mode")); mode == "focus" {
		if !need(cfg, "waybar-launch", "the bar stays as it is") {
			return
		}
		write_file(cfg, run_path(cfg, "waybar-mode"), "full\n")
		launch_waybar(cfg)
	}
	_ = os.remove(marker)
}

// launch_waybar starts waybar-launch detached from this process, so a
// restart of the watcher does not take the bar with it. setsid -f returns
// at once, so a waybar-launch that is there but fails is not seen here; its
// own log has it.
launch_waybar :: proc(cfg: ^Config) {
	_ = run_child(cfg, {argv = {"setsid", "-f", "waybar-launch"}}, context.temp_allocator)
}

run_path :: proc(cfg: ^Config, name: string) -> string {
	return strings.concatenate({cfg.run_dir, "/", name}, context.temp_allocator)
}

file_exists :: proc(path: string) -> bool {
	stat: linux.Statx
	return linux.statx(linux.AT_FDCWD, strings.clone_to_cstring(path, context.temp_allocator), {.SYMLINK_NOFOLLOW}, {.TYPE}, &stat) == .NONE
}

// write_file saves text to a file of the runtime directory. A failure is said
// and goes on: the bar and the marker are best effort, as in Fedora's script.
write_file :: proc(cfg: ^Config, path, text: string) {
	if err := os.write_entire_file(path, text); err != nil {
		say(cfg, "energy: cannot write %s: %s", path, os.error_string(err))
	}
}

// The gdbus monitors of the system bus: UPower's OnBattery and tuned-ppd's
// ActiveProfile. gdbus blocks on the bus socket, so an idle watcher costs no
// wakeups.
Monitor :: struct {
	process: os.Process,
	pipe:    ^os.File,
	// A line in progress, up to LINE_LIMIT bytes.
	line:    [dynamic]u8,
}

LINE_LIMIT :: 1 << 20

MONITORS :: [2][]string {
	{"gdbus", "monitor", "--system", "--dest", "org.freedesktop.UPower", "--object-path", "/org/freedesktop/UPower"},
	{"gdbus", "monitor", "--system", "--dest", "net.hadess.PowerProfiles", "--object-path", "/net/hadess/PowerProfiles"},
}

// watch listens on the system bus and acts on changes: the refresh rate
// follows the profile in auto mode, and an unplug turns keep-awake off and,
// if Focus bar is on, switches waybar to focus (plugging in switches it
// back, but only if the watcher was the one that switched). It runs until
// both monitors have ended, then returns 1: systemd restarts the watcher.
watch :: proc(cfg: ^Config) -> int {
	refresh(cfg)
	last := on_battery(cfg)

	commands := MONITORS
	monitors: [len(commands)]Monitor
	for i in 0 ..< len(commands) {
		monitors[i] = start_monitor(cfg, commands[i])
	}

	buf: [4096]u8
	for {
		fds: [len(commands)]linux.Poll_Fd
		index: [len(commands)]int
		n := 0
		for m, i in monitors {
			if m.pipe != nil {
				fds[n] = {
					fd     = linux.Fd(os.fd(m.pipe)),
					events = {.IN},
				}
				index[n] = i
				n += 1
			}
		}
		if n == 0 {
			break
		}
		_, errno := linux.poll(fds[:n], -1)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			break
		}
		for k in 0 ..< n {
			if fds[k].revents == {} {
				continue
			}
			m := &monitors[index[k]]
			got, rerr := linux.read(fds[k].fd, buf[:])
			if rerr == .EINTR || rerr == .EAGAIN {
				continue
			}
			if rerr != .NONE || got == 0 {
				// A line without its newline is not an event, as `read` in
				// the shell loop did not count it.
				_ = os.close(m.pipe)
				m.pipe = nil
				continue
			}
			for c in buf[:got] {
				if c == '\n' {
					handle_line(cfg, string(m.line[:]), &last)
					clear(&m.line)
				} else {
					append(&m.line, c)
					if len(m.line) >= LINE_LIMIT {
						handle_line(cfg, string(m.line[:]), &last)
						clear(&m.line)
					}
				}
			}
		}
	}
	for &m in monitors {
		if m.pipe != nil {
			_ = os.close(m.pipe)
		}
		if m.process.pid != 0 {
			_ = linux.kill(linux.Pid(m.process.pid), .SIGTERM)
			_ = wait_child(m.process)
		}
		delete(m.line)
	}
	// The monitors died; systemd restarts the watcher.
	return 1
}

start_monitor :: proc(cfg: ^Config, command: []string) -> (m: Monitor) {
	exe, found := find_program(cfg.path, command[0], context.temp_allocator)
	if !found {
		say(cfg, "energy: %s is not on the PATH, so there is no monitor of the system bus", command[0])
		return
	}
	argv := make([]string, len(command), context.temp_allocator)
	copy(argv, command)
	argv[0] = exe
	r, w, perr := os.pipe()
	if perr != nil {
		say(cfg, "energy: cannot make a pipe: %s", os.error_string(perr))
		return
	}
	process, err := start_child(cfg, argv, nil, w, nil)
	_ = os.close(w)
	if err != nil {
		_ = os.close(r)
		say(cfg, "energy: cannot start %s: %s", command[0], os.error_string(err))
		return
	}
	m.process = process
	m.pipe = r
	m.line = make([dynamic]u8)
	return
}

// handle_line reacts to one line of a monitor: only OnBattery and
// ActiveProfile count, anything else on the bus is noise. A change of the
// charger runs unplugged or plugged_in; every event refreshes the rate.
handle_line :: proc(cfg: ^Config, line: string, last: ^bool) {
	if !strings.contains(line, "OnBattery") && !strings.contains(line, "ActiveProfile") {
		return
	}
	now := on_battery(cfg)
	if now != last^ {
		if now {
			unplugged(cfg)
		} else {
			plugged_in(cfg)
		}
		last^ = now
	}
	refresh(cfg)
}
