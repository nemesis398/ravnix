// claude-roll record: the SessionStart hook of Claude Code that writes down,
// for the herdr pane it runs in, the session and the arguments Claude Code
// was started with, so a roll can start it again the same way
// (flags.odin). Claude Code hands the hook its session on standard input;
// the arguments it does not hand over, so the hook finds the Claude Code
// process above itself in the process tree and reads its command line.
//
// It runs again at /clear, /compact and a resume, so the record follows the
// session the pane runs now. It writes nothing outside a herdr pane
// (HERDR_PANE_ID), nothing for an id it cannot vouch for, and through a
// temporary file and a rename, so a reader never sees half a record.
package claude_roll

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Record_Input :: struct {
	// HERDR_PANE_ID.
	pane:      string,
	state_dir: string,
	// /proc, and the process to start the walk at (the hook's parent).
	proc_root: string,
	start_pid: int,
	// What Claude Code wrote on the hook's standard input.
	input:     []byte,
}

// How far up the tree Claude Code may be: the hook's wrapper, a shell that
// Claude Code runs hooks with, and room for one more.
MAX_WALK :: 8

// record_pane writes the record and returns its path, or why it wrote none.
record_pane :: proc(r: Record_Input, allocator: runtime.Allocator) -> (path: string, err: string) {
	if r.pane == "" {
		return "", "not in a herdr pane (no HERDR_PANE_ID)"
	}
	if !valid_pane_id(r.pane) {
		return "", "HERDR_PANE_ID is no plain pane id"
	}
	Hook :: struct {
		session_id, cwd, source: string,
	}
	hook: Hook
	if len(r.input) == 0 || json.unmarshal(r.input, &hook, allocator = allocator) != nil {
		return "", "the hook input is no JSON object"
	}
	if !valid_session_id(hook.session_id) {
		return "", "the hook input holds no session id claude-roll accepts"
	}
	argv, found := claude_argv(r.proc_root, r.start_pid, allocator)
	if !found {
		return "", "no Claude Code process above the hook"
	}

	data, merr := json.marshal(
		Pane_Record{pane = r.pane, session_id = hook.session_id, cwd = hook.cwd, source = hook.source, argv = argv[1:]},
		{pretty = false},
		allocator,
	)
	if merr != nil {
		return "", "cannot write the record as JSON"
	}
	dir, _ := filepath.join({r.state_dir, PANES_DIR}, allocator)
	if e := os.make_directory_all(dir); e != nil && e != os.General_Error.Exist {
		return "", fmt.aprintf("cannot make %s", dir, allocator = allocator)
	}
	path = record_path(r.state_dir, r.pane, allocator)
	tmp := fmt.aprintf("%s.%d.tmp", path, os.get_pid(), allocator = allocator)
	if e := os.write_entire_file(tmp, data); e != nil {
		_ = os.remove(tmp)
		return "", fmt.aprintf("cannot write %s", tmp, allocator = allocator)
	}
	if e := os.rename(tmp, path); e != nil {
		_ = os.remove(tmp)
		return "", fmt.aprintf("cannot rename %s", tmp, allocator = allocator)
	}
	return path, ""
}

// claude_argv walks up from pid to the first Claude Code process and
// returns its command line. Claude Code is the process whose argv[0] or
// comm is claude, or .claude-wrapped, the name a Nix wrapper gives the
// program it starts.
claude_argv :: proc(proc_root: string, pid: int, allocator: runtime.Allocator) -> (argv: []string, found: bool) {
	pid := pid
	for _ in 0 ..< MAX_WALK {
		if pid <= 1 {
			return
		}
		dir, _ := filepath.join({proc_root, fmt.tprint(pid)}, context.temp_allocator)
		cmd_path, _ := filepath.join({dir, "cmdline"}, context.temp_allocator)
		cmdline, cerr := os.read_entire_file(cmd_path, context.temp_allocator)
		if cerr != nil {
			return
		}
		words := strings.split(strings.trim_right(string(cmdline), "\x00"), "\x00", context.temp_allocator)
		comm_path, _ := filepath.join({dir, "comm"}, context.temp_allocator)
		comm_data, _ := os.read_entire_file(comm_path, context.temp_allocator)
		comm := strings.trim_right(string(comm_data), "\n")
		if is_claude(filepath.base(words[0])) || is_claude(comm) {
			out := make([]string, len(words), allocator)
			for w, i in words {
				out[i] = strings.clone(w, allocator)
			}
			return out, true
		}
		pid = parent_of(dir) or_return
	}
	return
}

is_claude :: proc(name: string) -> bool {
	return name == "claude" || name == ".claude-wrapped"
}

// parent_of reads the parent's pid from <dir>/stat, whose second field
// (comm, in parentheses) may hold blanks and parentheses itself.
parent_of :: proc(dir: string) -> (ppid: int, ok: bool) {
	stat_path, _ := filepath.join({dir, "stat"}, context.temp_allocator)
	data, err := os.read_entire_file(stat_path, context.temp_allocator)
	if err != nil {
		return
	}
	s := string(data)
	close := strings.last_index_byte(s, ')')
	if close < 0 {
		return
	}
	fields := strings.fields(s[close + 1:], context.temp_allocator)
	if len(fields) < 2 {
		return
	}
	return strconv.parse_int(fields[1], 10)
}
