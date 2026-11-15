// charge-mode: the battery's charge ceiling on the IdeaPad Pro 5 16AHP9,
// read and set from the desktop without a password (README.md).
//
// WHAT THE HARDWARE ACTUALLY OFFERS. This IdeaPad has NO
// charge_control_end_threshold anywhere under /sys/class/power_supply, so an
// arbitrary cap ("stop at 95%") is NOT EXPRESSIBLE on it. What exists is
// /sys/class/power_supply/BAT0/charge_types with exactly three discrete modes:
// Fast / Standard / Long_Life. Writing it also flips
// /sys/bus/platform/devices/VPC2004:00/conservation_mode, because the two are
// faces of one EC feature. The kernel says so itself (2026-08-23):
//   ideapad_acpi VPC2004:00: conservation_mode attribute has been deprecated,
//   see charge_types.
// so this tool drives charge_types and never the deprecated attribute.
//
// WHAT Long_Life DOES, MEASURED 2026-09-18 starting from 97%: the EC PARKS the
// cell, it does NOT force-discharge to its threshold. status went to
// "Not charging", power_now tapered 2.74 W -> 1.47 -> 0.65 -> 0.19 -> 0 over
// ~50 s as the charge path closed, energy_now froze at 75.55 Wh and held for
// 4 min with ADP0/online=1. power_now=0 on AC with the machine running is the
// proof that the PSU is carrying the whole load and the battery is neither
// taking nor giving anything, which is what "run off the power supply, not
// through the battery" actually means. There was never a knob for that half;
// it is simply what the hardware does once charging stops. (There is no
// charge_behaviour attribute on this machine, i.e. no ThinkPad-style
// inhibit-charge / force-discharge interface to set.)
//
// THE REFILL CEILING IS 80%, measured from upower history (2026-09-28, and
// twice on 2026-10-02): below it Long_Life refills to 80% and stops there;
// above it, it parks where it stands. It could not be measured on AC because
// parking leaves no discharge to observe, so it was read off the first real
// battery runs instead. Long_Life is also the boot default since 2026-10-03.
//
// One package, built three times (default.nix): CHARGE_MODE_ROLE picks the
// program, and each binary holds only the code its main reaches.
//
//   charge-mode          the user's command (user.odin)
//   charge-mode-apply    the one root writer, behind the sudo rule (apply.odin)
//   charge-mode-restore  the saved mode at boot (restore.odin)
//
// This file holds what the three share: the paths, the seams, and reading
// charge_types.
package charge_mode

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"

// The battery's attribute and the saved boot mode.
ATTR :: "/sys/class/power_supply/BAT0/charge_types"
STATE :: "/var/lib/charge-mode"

// The helper the other two run, and the notification program. default.nix
// sets both to their store paths; a bare name is looked up on PATH.
HELPER :: #config(CHARGE_MODE_HELPER, "")
NOTIFY_SEND :: #config(CHARGE_MODE_NOTIFY_SEND, "notify-send")

// The most the root programs read of charge_types or the saved mode. sysfs
// hands out at most a page, and a mode is a word; anything longer is not
// what these files hold.
MAX_ROOT_READ :: 4096
// The user's command reads more before it gives up, as cat did.
MAX_USER_READ :: 65536

// What one run works on: the system's own paths, or a test's.
Config :: struct {
	attr:        string,
	state:       string,
	helper:      string,
	notify_send: string,
	// Where sudo is looked up: the caller's PATH, for the setuid wrapper in
	// /run/wrappers/bin.
	path:        string,
	// The environment the children get.
	env:         []string,
	// Whose Waybar the refresh signals.
	euid:        int,
	// How long the restore waits for charge_types: tries times step.
	wait_tries:  int,
	wait_step:   time.Duration,
}

// The seams: a caller without privilege may point the three programs at
// other paths, for the tests. Under sudo or as the boot unit the process is
// root, so the variables are ignored and the fixed paths hold, whatever the
// environment says; sudo's env_reset would drop them anyway, but the helper
// does not rely on it. A process with any effective capability counts as
// privileged too, and so does one whose real and effective uid or gid
// differ: a setuid or setgid exec to a user other than root would otherwise
// let the caller aim the helper's write at whatever that uid or gid may
// write. The ids are compared rather than the auxiliary vector's AT_SECURE,
// which says the same for setuid and setgid (and file capabilities, which
// capget already sees): a plain comparison is one the tests can feed.
SEAM_ATTR :: "CHARGE_MODE_ATTR"
SEAM_STATE :: "CHARGE_MODE_STATE"
SEAM_HELPER :: "CHARGE_MODE_HELPER"
SEAM_NOTIFY_SEND :: "CHARGE_MODE_NOTIFY_SEND"

// Who the process is, for seams_allowed.
Credentials :: struct {
	uid, euid, gid, egid: int,
	capabilities:         u64,
}

current_credentials :: proc() -> Credentials {
	return {
		uid = int(linux.getuid()),
		euid = int(linux.geteuid()),
		gid = int(linux.getgid()),
		egid = int(linux.getegid()),
		capabilities = effective_capabilities(),
	}
}

seams_allowed :: proc(c: Credentials) -> bool {
	return c.uid != 0 && c.euid != 0 && c.capabilities == 0 && c.uid == c.euid && c.gid == c.egid
}

// effective_capabilities is the process's effective capability set, or
// everything when the kernel does not say.
effective_capabilities :: proc() -> u64 {
	Header :: struct {
		version: u32,
		pid:     i32,
	}
	Data :: struct {
		effective, permitted, inheritable: u32,
	}
	// _LINUX_CAPABILITY_VERSION_3: two words of each set.
	header := Header{version = 0x20080522}
	data: [2]Data
	ret := int(intrinsics.syscall(linux.SYS_capget, uintptr(&header), uintptr(&data[0])))
	if ret != 0 {
		return max(u64)
	}
	return u64(data[0].effective) | u64(data[1].effective) << 32
}

// system_config is the run's paths: the fixed ones, or the seams' where they
// are allowed and set.
system_config :: proc(allocator := context.allocator) -> Config {
	cfg := Config {
		attr       = ATTR,
		state      = STATE,
		helper     = HELPER,
		euid       = int(linux.geteuid()),
		wait_tries = 20,
		wait_step  = 500 * time.Millisecond,
	}
	if seams_allowed(current_credentials()) {
		seam :: proc(name: string, into: ^string, allocator: runtime.Allocator) {
			if v, ok := os.lookup_env(name, allocator); ok && v != "" {
				into^ = v
			}
		}
		seam(SEAM_ATTR, &cfg.attr, allocator)
		seam(SEAM_STATE, &cfg.state, allocator)
		seam(SEAM_HELPER, &cfg.helper, allocator)
	}
	// Only the user's command notifies; the root programs do not even hold
	// the name.
	when ROLE == "user" {
		cfg.notify_send = NOTIFY_SEND
		if seams_allowed(current_credentials()) {
			if v, ok := os.lookup_env(SEAM_NOTIFY_SEND, allocator); ok && v != "" {
				cfg.notify_send = v
			}
		}
	}
	cfg.path = os.get_env("PATH", allocator)
	cfg.env, _ = os.environ(allocator)
	return cfg
}

// How reading a small file went.
Read_Result :: enum {
	Ok,
	Missing,
	// The last component is a symlink, and the caller follows none.
	Symlink,
	// A directory, a device, a FIFO: anything but a regular file.
	Not_File,
	Too_Big,
	// It exists and could not be read; errno says why.
	Failed,
}

// read_small reads the regular file at path, at most limit bytes; a longer
// one is Too_Big. With follow false, a symlink as the last component is
// refused: the components before it are followed, since sysfs reaches
// BAT0 through one. The file is opened without blocking, so a FIFO put in
// its place cannot hang the reader; it is refused as Not_File.
read_small :: proc(path: string, limit: int, follow: bool, allocator := context.allocator) -> (data: []byte, res: Read_Result, errno: linux.Errno) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	flags := linux.Open_Flags{.CLOEXEC, .NONBLOCK, .NOCTTY}
	if !follow {
		flags += {.NOFOLLOW}
	}
	fd, oerr := linux.open(cpath, flags)
	if oerr != .NONE {
		#partial switch oerr {
		case .ENOENT, .ENOTDIR:
			return nil, .Missing, oerr
		case .ELOOP:
			return nil, .Symlink if !follow else .Failed, oerr
		case:
			return nil, .Failed, oerr
		}
	}
	defer linux.close(fd)
	st: linux.Stat
	if serr := linux.fstat(fd, &st); serr != .NONE {
		return nil, .Failed, serr
	}
	if !linux.S_ISREG(st.mode) {
		return nil, .Not_File, .NONE
	}
	buf := make([]byte, limit + 1, allocator)
	n := 0
	for n < len(buf) {
		got, rerr := linux.read(fd, buf[n:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE {
			delete(buf, allocator)
			return nil, .Failed, rerr
		}
		if got == 0 {
			break
		}
		n += got
	}
	if n > limit {
		delete(buf, allocator)
		return nil, .Too_Big, .NONE
	}
	return buf[:n], .Ok, .NONE
}

// current_mode is the bracketed mode of charge_types' text. It is "unknown"
// rather than the whole line when nothing is bracketed, so a caller can
// never mistake the raw attribute text for a mode name.
current_mode :: proc(text: string) -> string {
	open_at := strings.index_byte(text, '[')
	if open_at < 0 {
		return "unknown"
	}
	rest := text[open_at + 1:]
	close_at := strings.index_byte(rest, ']')
	if close_at < 0 {
		return "unknown"
	}
	return rest[:close_at]
}

// offered_modes is what `charge-mode modes` lists: the words of the text,
// split on spaces and line ends, without their brackets. The legal set comes
// from the firmware, not from a list here, so a kernel or firmware change
// cannot leave this tool writing a rejected value.
offered_modes :: proc(text: string, allocator := context.allocator) -> []string {
	modes := make([dynamic]string, allocator)
	rest := text
	for len(rest) > 0 {
		end := strings.index_any(rest, " \n")
		word := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end + 1:]
		stripped := without_brackets(word, allocator)
		if stripped != "" {
			append(&modes, stripped)
		}
	}
	return modes[:]
}

// is_offered tells whether mode is one of the words the kernel lists: the
// text without its brackets, split on spaces, tabs and line ends. This is the
// helper's check, the whole of its trust in its argument: no argument can
// make it write anything the kernel does not offer.
is_offered :: proc(text, mode: string) -> bool {
	if mode == "" {
		return false
	}
	rest := without_brackets(text, context.temp_allocator)
	for len(rest) > 0 {
		end := strings.index_any(rest, " \t\n")
		word := rest if end < 0 else rest[:end]
		rest = "" if end < 0 else rest[end + 1:]
		if word == mode {
			return true
		}
	}
	return false
}

without_brackets :: proc(s: string, allocator := context.allocator) -> string {
	if strings.index_any(s, "[]") < 0 {
		return s
	}
	b := strings.builder_make(0, len(s), allocator)
	for i in 0 ..< len(s) {
		if s[i] != '[' && s[i] != ']' {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// trim_newlines drops the line ends at the end of s, as the shell's $(...)
// did.
trim_newlines :: proc(s: string) -> string {
	return strings.trim_right(s, "\n")
}

// next_mode is the cycle: Long_Life -> Standard -> Fast -> Long_Life, and an
// unknown mode goes to the conservative end.
next_mode :: proc(mode: string) -> string {
	switch mode {
	case "Long_Life":
		return "Standard"
	case "Standard":
		return "Fast"
	}
	return "Long_Life"
}

describe :: proc(mode: string) -> string {
	switch mode {
	case "Long_Life":
		return "Parks the cell; the PSU carries the machine. Refills only to the EC ceiling."
	case "Standard":
		return "Charges to 100% at the normal rate."
	case "Fast":
		return "Charges to 100% rapidly. Hardest of the three on the cell."
	}
	return ""
}

// shown is s as a message may show it: every byte outside printable ASCII
// as \xNN, and cut after 64 bytes with its length, so a refusal stays one
// line of reasonable size whatever the argument held.
shown :: proc(s: string, allocator := context.allocator) -> string {
	MAX_SHOWN :: 64
	b := strings.builder_make(allocator)
	for i in 0 ..< min(len(s), MAX_SHOWN) {
		c := s[i]
		if c < 0x20 || c > 0x7e || c == '\\' {
			fmt.sbprintf(&b, "\\x%02x", c)
		} else {
			strings.write_byte(&b, c)
		}
	}
	if len(s) > MAX_SHOWN {
		fmt.sbprintf(&b, "... (%d bytes)", len(s))
	}
	return strings.to_string(b)
}

// split_path is the directory and the last component of path: "." for a
// path without a slash, "/" for one directly under the root.
split_path :: proc(path: string) -> (dir, base: string) {
	slash := strings.last_index_byte(path, '/')
	if slash < 0 {
		return ".", path
	}
	if slash == 0 {
		return "/", path[1:]
	}
	return path[:slash], path[slash + 1:]
}

// errno_text is a short reason for an errno, for messages.
errno_text :: proc(errno: linux.Errno) -> string {
	#partial switch errno {
	case .ENOENT:
		return "No such file or directory"
	case .EACCES:
		return "Permission denied"
	case .EPERM:
		return "Operation not permitted"
	case .EROFS:
		return "Read-only file system"
	case .EINVAL:
		return "Invalid argument"
	case .EISDIR:
		return "Is a directory"
	case .ENOTDIR:
		return "Not a directory"
	case .ELOOP:
		return "Too many levels of symbolic links"
	case .ENOSPC:
		return "No space left on device"
	case .EIO:
		return "Input/output error"
	case .EBUSY:
		return "Device or resource busy"
	case .ENODEV:
		return "No such device"
	}
	return fmt.tprintf("errno %d", int(errno))
}
