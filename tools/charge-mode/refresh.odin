// The Waybar refresh: its battery module redraws on SIGRTMIN+10 ("signal": 10
// on custom/battery in modules.jsonc), which the Bash tool sent with
// `pkill -RTMIN+10 -u "$EUID" -x 'waybar|\.waybar-wrapped'`. This does the
// same through /proc and pidfd_send_signal, and runs no pkill.
package charge_mode

import "base:intrinsics"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

// Waybar is C++ on glibc, and its SIGRTMIN is glibc's, 34: glibc keeps the
// kernel's first two real-time signals (32 and 33) for its threads.
// linux.SIGRTMIN is the kernel's 32, so it is not the base here.
WAYBAR_SIGNAL :: 34 + 10

// The names Waybar runs under, matched whole: the kernel takes a process's
// name from its executable's file name, so it is waybar, or .waybar-wrapped
// where NixOS wraps it (the wrapper execs the real binary under that name,
// and a second wrap adds `_`, which the 15-byte name cuts off). Never the
// whole command line, which would also hit unrelated processes that merely
// mention waybar, waybar-launch among them.
WAYBARS :: [?]string{"waybar", ".waybar-wrapped"}

// is_waybar tells whether the process pid under the proc directory root is
// a Waybar of the user euid: one of WAYBARS by name, euid its effective uid,
// as pkill -u matches.
is_waybar :: proc(root: string, pid, euid: int) -> bool {
	context.allocator = context.temp_allocator
	comm, cres, _ := read_small(strings.concatenate({root, "/", int_text(pid), "/comm"}), 64, follow = true)
	if cres != .Ok {
		return false
	}
	name := trim_newlines(string(comm))
	named := false
	for w in WAYBARS {
		named ||= name == w
	}
	if !named {
		return false
	}
	status, sres, _ := read_small(strings.concatenate({root, "/", int_text(pid), "/status"}), MAX_USER_READ, follow = true)
	if sres != .Ok {
		return false
	}
	rest := string(status)
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "Uid:") {
			continue
		}
		fields := strings.fields(line[len("Uid:"):])
		if len(fields) < 2 {
			return false
		}
		effective, ok := strconv.parse_int(fields[1], 10)
		return ok && effective == euid
	}
	return false
}

// refresh_waybar signals every Waybar of the user euid. Each process is
// pinned by a pidfd before it is looked at, so a pid that is reused between
// the look and the signal gets no signal: the pidfd still names the process
// that was looked at, and signalling it after it is gone fails.
refresh_waybar :: proc(euid: int) {
	context.allocator = context.temp_allocator
	entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
	if err != nil {
		return
	}
	self := int(linux.getpid())
	for e in entries {
		pid, ok := strconv.parse_int(e.name, 10)
		if !ok || pid <= 0 || pid == self {
			continue
		}
		pidfd, perr := linux.pidfd_open(linux.Pid(pid), {})
		if perr != .NONE {
			continue
		}
		if is_waybar("/proc", pid, euid) {
			intrinsics.syscall(linux.SYS_pidfd_send_signal, uintptr(pidfd), uintptr(WAYBAR_SIGNAL), 0, 0)
		}
		linux.close(linux.Fd(pidfd))
	}
}

int_text :: proc(n: int) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], i64(n), 10))
}
