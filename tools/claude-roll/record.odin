// claude-roll record: the SessionStart hook of Claude Code that writes down,
// for the herdr pane it runs in, the session and the arguments Claude Code
// was started with, so a roll can start it again the same way
// (flags.odin). Claude Code hands the hook its session on standard input;
// the arguments it does not hand over, so the hook finds the Claude Code
// process above itself in the process tree and reads its command line.
//
// It runs again at /clear, /compact and a resume, so the record follows the
// session the pane runs now. It records the process too (pid and start
// time), so the roll can check that the record is of the Claude Code that
// runs in the pane. It writes nothing outside a herdr pane (HERDR_PANE_ID),
// nothing for an id it cannot vouch for, nothing for a Claude Code started
// inside another one (which inherits the pane's HERDR_PANE_ID), and through
// a temporary file and a rename, so a reader never sees half a record.
package claude_roll

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	pid, start, argv, nested, found := find_claude(r.proc_root, r.start_pid, allocator)
	if !found || len(argv) == 0 {
		return "", "no Claude Code process above the hook"
	}
	if nested {
		// claude -p from the Bash tool, a script: the pane's own session
		// keeps its record.
		return "", "a Claude Code started inside another one does not write the pane's record"
	}

	data, merr := json.marshal(
		Pane_Record{pane = r.pane, session_id = hook.session_id, cwd = hook.cwd, source = hook.source, argv = argv[1:], pid = pid, start_time = start},
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

// find_claude walks up from pid to the first Claude Code process and
// returns its pid, its start time and its command line. nested is true when
// that Claude Code was started inside another one: its own environment
// holds CLAUDECODE, which Claude Code sets for what it runs, or another
// Claude Code is above it.
find_claude :: proc(root: string, pid: int, allocator: runtime.Allocator) -> (claude: int, start: u64, argv: []string, nested, found: bool) {
	pid := pid
	for _ in 0 ..< MAX_WALK {
		if pid <= 1 {
			return
		}
		st := read_stat(root, pid) or_return
		if is_claude_process(root, pid) {
			claude, start, found = pid, st.start, true
			argv = read_words(root, pid, "cmdline", allocator) or_return
			env, _ := read_words(root, pid, "environ", context.temp_allocator)
			for e in env {
				if strings.has_prefix(e, "CLAUDECODE=") {
					nested = true
				}
			}
			above := st.ppid
			for _ in 0 ..< MAX_WALK {
				if above <= 1 {
					break
				}
				if is_claude_process(root, above) {
					nested = true
					break
				}
				up, read := read_stat(root, above)
				if !read {
					break
				}
				above = up.ppid
			}
			return
		}
		pid = st.ppid
	}
	return
}
