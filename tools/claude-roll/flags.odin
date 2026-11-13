// The launch flags of a pane, and the ids claude-roll puts into a file name
// or onto a command line.
//
// Claude Code keeps a session's conversation, not the flags it was started
// with: --add-dir, --settings, --mcp-config and the rest are gone after a
// plain `claude --resume ID`. The SessionStart hook (`claude-roll record`,
// record.odin) writes down per herdr pane what its Claude Code was started
// with, and resume_args picks from that what a resume passes again.
//
// It keeps only flags it knows, with the number of values each takes, and
// drops the old session's (--resume, --continue, --session-id,
// --fork-session) and a first prompt, which must not be sent twice. A flag
// it does not know stops it: with an unknown flag it cannot tell a value
// from a prompt, and a wrong guess would start the session differently or
// send a prompt. So does a flag a resume must not repeat (--worktree makes
// a new worktree each time; --print, --bg and the like are no interactive
// session). That pane is left on its version, and the user is told.
package claude_roll

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Arity :: enum {
	None,
	// One value.
	One,
	// One value if the next word is no flag.
	Optional,
	// Every word up to the next flag (commander's variadic options).
	Many,
}

Flag :: struct {
	arity: Arity,
	// Passed again on a resume; else dropped.
	keep:  bool,
}

// The flags of Claude Code 2.1.323 (`claude --help`): how many values each
// takes, and whether a resume passes it again.
flag_of :: proc(name: string) -> (f: Flag, known: bool) {
	switch name {
	case "--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools",
	     "--disallowed-tools", "--mcp-config", "--tools":
		return {.Many, true}, true
	case "--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file",
	     "--autocompact", "--debug-file", "--effort", "--fallback-model", "--model", "-n",
	     "--name", "--permission-mode", "--plugin-dir",
	     "--remote-control-session-name-prefix", "--setting-sources", "--settings",
	     "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot":
		return {.One, true}, true
	case "--allow-dangerously-skip-permissions", "--ax-screen-reader", "--bare", "--brief",
	     "--chrome", "--dangerously-skip-permissions", "--disable-slash-commands",
	     "--exclude-dynamic-system-prompt-sections", "--ide", "--no-chrome", "--restricted",
	     "--safe-mode", "--strict-mcp-config", "--verbose":
		return {.None, true}, true
	case "-d", "--debug", "--prompt-suggestions", "--remote-control":
		return {.Optional, true}, true
	// The old session: dropped.
	case "-r", "--resume":
		return {.Optional, false}, true
	case "-c", "--continue", "--fork-session":
		return {.None, false}, true
	case "--session-id":
		return {.One, false}, true
	}
	return {}, false
}

// resume_args returns the flags of argv (Claude Code's arguments after its
// name) that a resume passes again, or why there are none it can trust.
resume_args :: proc(argv: []string, allocator: runtime.Allocator) -> (flags: []string, err: string) {
	out := make([dynamic]string, allocator)
	for a in argv {
		for c in a {
			if c < 0x20 || c == 0x7f {
				return nil, "a launch flag holds a control character, which no shell line can carry"
			}
		}
	}
	i := 0
	for i < len(argv) {
		a := argv[i]
		if a == "--" {
			// What follows is the first prompt.
			break
		}
		if !strings.has_prefix(a, "-") || a == "-" {
			// A word that no flag takes: the first prompt.
			i += 1
			continue
		}
		name, value, has_value := a, "", false
		if eq := strings.index_byte(a, '='); eq >= 0 && strings.has_prefix(a, "--") {
			name, value, has_value = a[:eq], a[eq + 1:], true
		}
		f, known := flag_of(name)
		if !known {
			return nil, fmt.aprintf("launch flag %s is not one claude-roll can carry into a resume", name, allocator = allocator)
		}
		words := 1
		switch f.arity {
		case .None:
			if has_value {
				return nil, fmt.aprintf("launch flag %s takes no value", name, allocator = allocator)
			}
		case .One:
			if has_value {
				if value == "" {
					return nil, fmt.aprintf("launch flag %s has no value", name, allocator = allocator)
				}
			} else {
				if i + 1 >= len(argv) || is_flag(argv[i + 1]) {
					return nil, fmt.aprintf("launch flag %s has no value", name, allocator = allocator)
				}
				words = 2
			}
		case .Optional:
			if !has_value && i + 1 < len(argv) && !is_flag(argv[i + 1]) {
				words = 2
			}
		case .Many:
			if !has_value {
				for i + words < len(argv) && !is_flag(argv[i + words]) {
					words += 1
				}
				if words == 1 {
					return nil, fmt.aprintf("launch flag %s has no value", name, allocator = allocator)
				}
			}
		}
		if f.keep {
			for w in argv[i:i + words] {
				append(&out, strings.clone(w, allocator))
			}
		}
		i += words
	}
	return out[:], ""
}

is_flag :: proc(s: string) -> bool {
	return strings.has_prefix(s, "-") && s != "-"
}

// valid_session_id: a UUID, which is what Claude Code names a session by
// and what herdr reports. Anything else is not put onto a command line.
valid_session_id :: proc(s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for c, i in transmute([]byte)s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		case:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
	}
	return true
}

// valid_pane_id: herdr's pane ids (w1:p1, wK:p1N) and nothing that could
// leave a directory or start like a flag.
valid_pane_id :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 || s[0] == '-' || s[0] == '.' {
		return false
	}
	for c in transmute([]byte)s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == ':' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// agent_name is the name `herdr agent start` gives the resumed agent: the
// one it had when herdr accepts it ([a-z][a-z0-9_-]{0,31}), else one made
// of the pane id.
agent_name :: proc(name, pane: string, allocator: runtime.Allocator) -> string {
	if valid_agent_name(name) {
		return strings.clone(name, allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "claude-")
	for c in transmute([]byte)pane {
		if strings.builder_len(b) >= 32 {
			break
		}
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&b, c + ('a' - 'A'))
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_', c == '-':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '-')
		}
	}
	return strings.to_string(b)
}

valid_agent_name :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 32 || !(s[0] >= 'a' && s[0] <= 'z') {
		return false
	}
	for c in transmute([]byte)s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// What the SessionStart hook writes for a pane, in
// $XDG_STATE_HOME/ravnix/claude-panes/<pane>.json.
Pane_Record :: struct {
	pane:       string,
	session_id: string,
	cwd:        string,
	// SessionStart's source: startup, resume, clear or compact.
	source:     string,
	// Claude Code's arguments after its name, as it was started.
	argv:       []string,
}

PANES_DIR :: "claude-panes"
MAX_RECORD_BYTES :: 1 << 20

parse_pane_record :: proc(data: []byte, allocator: runtime.Allocator) -> (rec: Pane_Record, err: string) {
	// argv must be there, as a list: a record without it is not one of a
	// pane started without flags.
	Raw :: struct {
		pane, session_id, cwd, source: string,
		argv:                          json.Value,
	}
	raw: Raw
	if e := json.unmarshal(data, &raw, allocator = allocator); e != nil {
		return {}, "the record is no JSON object of a pane"
	}
	list, is_list := raw.argv.(json.Array)
	if !is_list {
		return {}, "the record has no argv list"
	}
	argv := make([]string, len(list), allocator)
	for v, i in list {
		s, is_string := v.(json.String)
		if !is_string {
			return {}, "the record's argv holds something other than strings"
		}
		argv[i] = s
	}
	return {raw.pane, raw.session_id, raw.cwd, raw.source, argv}, ""
}

// read_pane_record reads the record of pane under state.
read_pane_record :: proc(state, pane: string, allocator: runtime.Allocator) -> (rec: Pane_Record, err: string) {
	if !valid_pane_id(pane) {
		return {}, "the pane id is no plain id"
	}
	path := record_path(state, pane, allocator)
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		return {}, fmt.aprintf("no launch flags recorded (%s)", path, allocator = allocator)
	}
	if info.size > MAX_RECORD_BYTES {
		return {}, fmt.aprintf("%s is too large to be a record", path, allocator = allocator)
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return {}, fmt.aprintf("cannot read %s", path, allocator = allocator)
	}
	rec, err = parse_pane_record(data, allocator)
	if err != "" {
		return {}, fmt.aprintf("%s: %s", path, err, allocator = allocator)
	}
	if rec.pane != pane {
		return {}, fmt.aprintf("%s is the record of pane %s", path, rec.pane, allocator = allocator)
	}
	return rec, ""
}

record_path :: proc(state, pane: string, allocator: runtime.Allocator) -> string {
	name := strings.concatenate({pane, ".json"}, context.temp_allocator)
	p, _ := filepath.join({state, PANES_DIR, name}, allocator)
	return p
}
