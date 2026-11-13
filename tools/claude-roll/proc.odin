// What claude-roll reads from /proc: the Claude Code process of a pane, and
// whether work it started still runs.
//
// A pid alone does not name a process for long: a later process can get
// it. A process is therefore named by its pid and its start time (field 22
// of /proc/PID/stat), as the pane record keeps them.
//
// Background work: Claude Code runs every command of its Bash tool in a
// shell of its own, `/bin/bash -c source ~/.claude/shell-snapshots/
// snapshot-bash-….sh … && eval '<command>'`, started in a process group of
// its own (seen on Claude Code 2.1.323). A command started in the background
// keeps that shell alive after the turn has ended, while herdr says idle, the
// busy hook says idle and no spinner shows; /exit would end it. The MCP
// servers Claude Code keeps run in its own process group. So a child of the
// Claude Code process that is a Bash tool shell, or that leads a group of its
// own, is work that runs, and the pane waits. What cannot be read counts as
// work too.
package claude_roll

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Proc_Stat :: struct {
	ppid:  int,
	pgid:  int,
	// Field 22: when it started, in clock ticks after boot.
	start: u64,
}

SNAPSHOT_MARK :: "/shell-snapshots/snapshot-"

// read_stat reads /proc/PID/stat, whose second field (comm, in parentheses)
// may hold blanks and parentheses itself.
read_stat :: proc(root: string, pid: int) -> (st: Proc_Stat, ok: bool) {
	path, _ := filepath.join({root, fmt.tprint(pid), "stat"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	s := string(data)
	close := strings.last_index_byte(s, ')')
	if close < 0 {
		return
	}
	// After the comm: state (3), ppid (4), pgrp (5), …, starttime (22).
	fields := strings.fields(s[close + 1:], context.temp_allocator)
	if len(fields) < 20 {
		return
	}
	st.ppid = strconv.parse_int(fields[1], 10) or_return
	st.pgid = strconv.parse_int(fields[2], 10) or_return
	st.start = strconv.parse_u64(fields[19], 10) or_return
	return st, true
}

// read_words reads a NUL-separated file of /proc/PID (cmdline, environ).
read_words :: proc(root: string, pid: int, name: string, allocator: runtime.Allocator) -> (words: []string, ok: bool) {
	path, _ := filepath.join({root, fmt.tprint(pid), name}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	parts := strings.split(strings.trim_right(string(data), "\x00"), "\x00", context.temp_allocator)
	out := make([]string, len(parts), allocator)
	for w, i in parts {
		out[i] = strings.clone(w, allocator)
	}
	return out, true
}

// is_claude_process says whether pid runs Claude Code: its argv[0] or its
// comm is claude, or .claude-wrapped, the name a Nix wrapper gives it.
is_claude_process :: proc(root: string, pid: int) -> bool {
	argv, ok := read_words(root, pid, "cmdline", context.temp_allocator)
	if ok && len(argv) > 0 && is_claude(filepath.base(argv[0])) {
		return true
	}
	path, _ := filepath.join({root, fmt.tprint(pid), "comm"}, context.temp_allocator)
	comm, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && is_claude(strings.trim_right(string(comm), "\n"))
}

is_claude :: proc(name: string) -> bool {
	return name == "claude" || name == ".claude-wrapped"
}

// background_work says whether the Claude Code process pid, which leads or
// belongs to the process group pgid, has a child that is work of its own (a
// Bash tool shell, or a process in another group), and why. ok is false
// when that cannot be told.
background_work :: proc(root: string, pid, pgid: int) -> (busy: bool, why: string, ok: bool) {
	dir, err := os.open(root)
	if err != nil {
		return false, "", false
	}
	defer os.close(dir)
	entries, rerr := os.read_dir(dir, -1, context.temp_allocator)
	if rerr != nil {
		return false, "", false
	}
	for e in entries {
		child, is_pid := strconv.parse_int(e.name, 10)
		if !is_pid || child <= 0 || child == pid {
			continue
		}
		st, read := read_stat(root, child)
		if !read || st.ppid != pid {
			// Gone since the listing, or another's child.
			continue
		}
		argv, _ := read_words(root, child, "cmdline", context.temp_allocator)
		for a in argv {
			if strings.contains(a, SNAPSHOT_MARK) {
				return true, "a background command of the session's Bash tool is still running", true
			}
		}
		if st.pgid != pgid {
			return true, "a process the session started in the background is still running", true
		}
	}
	return false, "", true
}
