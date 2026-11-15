// charge-mode-apply: the ONLY privileged writer of BAT0/charge_types.
//
// This is the security boundary for the one-command sudo rule without a
// password that the hardware module gives the user
// (modules/hardware/ideapad-pro-5-16ahp9/battery.nix): the mode is checked
// against the list the KERNEL currently offers, so no argument can make this
// write anything else, and the two paths it touches are fixed. It runs
// nothing and reads no PATH. Writing charge_types also flips
// VPC2004:00/conservation_mode, which is the same EC feature under its
// deprecated name (kernel, 2026-08-23). Do not write that attribute.
//
// Everything is checked before anything is written: the argument, the
// attribute, the directory of the saved mode and the saved mode itself. A
// refusal leaves both files as they were.
package charge_mode

import "core:fmt"
import "core:io"
import "core:strings"
import "core:sys/linux"

// Exit statuses: 0 written, 1 the system is not as it should be (no
// attribute, a symlink, a failed write), 2 the arguments are refused.
run_apply :: proc(args: []string, cfg: Config, err: io.Writer) -> int {
	text, res, errno := read_small(cfg.attr, MAX_ROOT_READ, follow = false, allocator = context.temp_allocator)
	switch res {
	case .Ok:
	case .Missing:
		fmt.wprintfln(err, "charge-mode-apply: no %s", cfg.attr)
		return 1
	case .Symlink:
		fmt.wprintfln(err, "charge-mode-apply: %s is a symlink; refused", cfg.attr)
		return 1
	case .Not_File:
		fmt.wprintfln(err, "charge-mode-apply: %s is not a file; refused", cfg.attr)
		return 1
	case .Too_Big:
		fmt.wprintfln(err, "charge-mode-apply: %s holds more than %d bytes, which no charge_types does; refused", cfg.attr, MAX_ROOT_READ)
		return 1
	case .Failed:
		fmt.wprintfln(err, "charge-mode-apply: cannot read %s: %s", cfg.attr, errno_text(errno))
		return 1
	}

	// --save-only changes the BOOT DEFAULT without touching the live mode,
	// for the "parked at 97% now, something else after a reboot" case. It
	// runs through the same validation, so the state file can never be
	// seeded with a value that the restore would then refuse.
	rest := args
	save_only := false
	if len(rest) > 0 && rest[0] == "--save-only" {
		save_only = true
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] == "" {
		fmt.wprintln(err, "charge-mode-apply: no mode given")
		return 2
	}
	if len(rest) > 1 {
		fmt.wprintfln(err, "charge-mode-apply: takes one mode, after --save-only or alone; got %d arguments", len(args))
		return 2
	}
	mode := rest[0]
	if !is_offered(string(text), mode) {
		fmt.wprintfln(err, "charge-mode-apply: '%s' is not offered by this firmware", shown(mode, context.temp_allocator))
		fmt.wprintfln(err, "  offered: %s", trim_newlines(without_brackets(string(text), context.temp_allocator)))
		return 2
	}

	dir, ok := open_state_dir(cfg.state, err)
	if !ok {
		return 1
	}
	defer linux.close(dir)
	_, base := split_path(cfg.state)
	if !state_target_ok(dir, cfg.state, base, err) {
		return 1
	}

	if !save_only && !write_attr(cfg.attr, mode, err) {
		return 1
	}
	if !save_state(dir, cfg.state, base, mode, err) {
		return 1
	}
	return 0
}

// open_state_dir opens the directory of the saved mode. It must be a real
// directory, not a symlink, owned by root or by this process's user, and
// writable by nobody else: the temporary file and the rename below happen in
// it, and another writer there could swap either.
open_state_dir :: proc(state: string, err: io.Writer) -> (linux.Fd, bool) {
	dir, _ := split_path(state)
	fd, errno := linux.open(strings.clone_to_cstring(dir, context.temp_allocator), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if errno != .NONE {
		// O_NOFOLLOW with O_DIRECTORY answers a symlink with ENOTDIR (or
		// ELOOP), so the path itself tells which it is.
		st: linux.Stat
		if (errno == .ENOTDIR || errno == .ELOOP) && linux.fstatat(linux.AT_FDCWD, strings.clone_to_cstring(dir, context.temp_allocator), &st, {.SYMLINK_NOFOLLOW}) == .NONE && linux.S_ISLNK(st.mode) {
			errno = .ELOOP
		}
		#partial switch errno {
		case .ELOOP:
			fmt.wprintfln(err, "charge-mode-apply: %s, the directory of the saved mode, is a symlink; refused", dir)
		case .ENOENT:
			fmt.wprintfln(err, "charge-mode-apply: no directory %s for the saved mode", dir)
		case:
			fmt.wprintfln(err, "charge-mode-apply: cannot open %s: %s", dir, errno_text(errno))
		}
		return -1, false
	}
	st: linux.Stat
	if serr := linux.fstat(fd, &st); serr != .NONE {
		fmt.wprintfln(err, "charge-mode-apply: cannot stat %s: %s", dir, errno_text(serr))
		linux.close(fd)
		return -1, false
	}
	if st.uid != 0 && st.uid != linux.geteuid() {
		fmt.wprintfln(err, "charge-mode-apply: %s belongs to uid %d, neither root nor this user; refused", dir, st.uid)
		linux.close(fd)
		return -1, false
	}
	if .IWGRP in st.mode || .IWOTH in st.mode {
		fmt.wprintfln(err, "charge-mode-apply: %s is writable by others than its owner; refused", dir)
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

// state_target_ok tells whether the saved mode may be replaced: it is not
// there yet, or it is a regular file. A symlink or a directory in its place
// is refused, not followed or filled.
state_target_ok :: proc(dir: linux.Fd, state, base: string, err: io.Writer) -> bool {
	st: linux.Stat
	errno := linux.fstatat(dir, strings.clone_to_cstring(base, context.temp_allocator), &st, {.SYMLINK_NOFOLLOW})
	if errno == .ENOENT {
		return true
	}
	if errno != .NONE {
		fmt.wprintfln(err, "charge-mode-apply: cannot stat %s: %s", state, errno_text(errno))
		return false
	}
	if linux.S_ISLNK(st.mode) {
		fmt.wprintfln(err, "charge-mode-apply: %s is a symlink; refused", state)
		return false
	}
	if !linux.S_ISREG(st.mode) {
		fmt.wprintfln(err, "charge-mode-apply: %s is not a file; refused", state)
		return false
	}
	return true
}

// write_attr writes mode to charge_types in one write and without a line
// end, as sysfs wants it. It never creates the file and never follows a
// symlink in its place.
write_attr :: proc(attr, mode: string, err: io.Writer) -> bool {
	fd, errno := linux.open(strings.clone_to_cstring(attr, context.temp_allocator), {.WRONLY, .TRUNC, .NOFOLLOW, .CLOEXEC, .NOCTTY, .NONBLOCK})
	if errno != .NONE {
		fmt.wprintfln(err, "charge-mode-apply: cannot write %s: %s", attr, errno_text(errno))
		return false
	}
	defer linux.close(fd)
	st: linux.Stat
	if serr := linux.fstat(fd, &st); serr != .NONE || !linux.S_ISREG(st.mode) {
		fmt.wprintfln(err, "charge-mode-apply: %s is not a file; refused", attr)
		return false
	}
	for {
		n, werr := linux.write(fd, transmute([]byte)mode)
		if werr == .EINTR {
			continue
		}
		if werr != .NONE {
			fmt.wprintfln(err, "charge-mode-apply: cannot write %s: %s", attr, errno_text(werr))
			return false
		}
		if n != len(mode) {
			fmt.wprintfln(err, "charge-mode-apply: wrote %d of %d bytes to %s", n, len(mode), attr)
			return false
		}
		return true
	}
}

// save_state saves mode for the boot, through a temporary file beside it
// and a rename, so two writes at once leave one whole mode and never a torn
// file that the restore would refuse. The file is 0644 whatever the umask:
// the user's `charge-mode default` reads it.
save_state :: proc(dir: linux.Fd, state, base, mode: string, err: io.Writer) -> bool {
	fd: linux.Fd
	tmp: cstring
	errno: linux.Errno = .EEXIST
	pid := int(linux.getpid())
	for attempt := 0; attempt < 100 && errno == .EEXIST; attempt += 1 {
		tmp = fmt.ctprintf("%s.tmp-%d-%d", base, pid, attempt)
		fd, errno = linux.openat(dir, tmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	}
	if errno != .NONE {
		fmt.wprintfln(err, "charge-mode-apply: cannot save the mode beside %s: %s", state, errno_text(errno))
		return false
	}
	line := fmt.tprintf("%s\n", mode)
	failed := linux.fchmod(fd, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if failed == .NONE {
		n, werr := linux.write(fd, transmute([]byte)line)
		failed = werr
		if werr == .NONE && n != len(line) {
			failed = .EIO
		}
	}
	if failed == .NONE {
		failed = linux.fsync(fd)
	}
	if cerr := linux.close(fd); failed == .NONE {
		failed = cerr
	}
	if failed == .NONE {
		failed = linux.renameat(dir, tmp, dir, strings.clone_to_cstring(base, context.temp_allocator))
	}
	if failed != .NONE {
		linux.unlinkat(dir, tmp, {})
		fmt.wprintfln(err, "charge-mode-apply: cannot save the mode in %s: %s", state, errno_text(failed))
		return false
	}
	// The rename is durable only once the directory is synced: without it a
	// power cut right after a `set` could bring the old saved mode back. By
	// now the mode is set and saved, so a failure here is a warning and the
	// run still succeeds: an exit 1 would make charge-mode say "not changed"
	// about a mode that did change. The warning goes to standard error, which
	// the boot unit's journal and charge-mode both show.
	if serr := linux.fsync(dir); serr != .NONE {
		dir_name, _ := split_path(state)
		fmt.wprintfln(err, "charge-mode-apply: warning: saved the mode, but cannot sync %s (%s); it may not survive a power cut", dir_name, errno_text(serr))
	}
	return true
}
