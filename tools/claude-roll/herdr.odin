// What claude-roll reads from herdr 0.9.5, and how. The JSON shapes are the
// ones herdr's CLI prints (src/api/schema in herdr's source; recorded in
// testdata/herdr): a success on standard output with exit 0,
//
//   {"id":"cli:agent:list","result":{"type":"agent_list","agents":[...]}}
//
// and an error on standard error with exit 1,
//
//   {"id":"cli:agent:list","error":{"code":"server_not_running","message":"..."}}
//
// Only the fields claude-roll uses are read; herdr leaves out the ones it
// has no value for, and a JSON null reads as empty.
//
// The calls claude-roll makes:
//
//   herdr agent list
//   herdr agent read PANE --source visible --format ansi
//   herdr agent prompt PANE /exit
//   herdr pane process-info --pane PANE
//   herdr pane get PANE
//   herdr agent start NAME --kind claude --pane PANE --timeout MS -- ARG...
package claude_roll

import "base:runtime"
import "core:encoding/json"
import "core:strings"

Agent_Session :: struct {
	source: string,
	agent:  string,
	// "id" or "path"; claude-roll resumes by id only.
	kind:   string,
	value:  string,
}

Agent :: struct {
	terminal_id:      string,
	// A name given with `agent start` or `agent rename`.
	name:             string,
	// The agent's kind: "claude", "codex", ...
	agent:            string,
	// idle, working, blocked, done or unknown.
	agent_status:     string,
	agent_session:    Agent_Session,
	pane_id:          string,
	state_change_seq: u64,
}

Herdr_Error :: struct {
	code:    string,
	message: string,
}

parse_agent_list :: proc(data: string, allocator: runtime.Allocator) -> (agents: []Agent, err: string) {
	Reply :: struct {
		result: struct {
			type:   string,
			agents: []Agent,
		},
	}
	reply: Reply
	if json.unmarshal_string(data, &reply, allocator = allocator) != nil {
		return nil, "herdr agent list printed no JSON claude-roll can read"
	}
	if reply.result.type != "agent_list" {
		return nil, "herdr agent list printed no agent list"
	}
	return reply.result.agents, ""
}

// herdr_error reads the error herdr printed on standard error; code is ""
// when it printed none it could read.
herdr_error :: proc(stderr: string, allocator: runtime.Allocator) -> (code, message: string) {
	Reply :: struct {
		error: Herdr_Error,
	}
	reply: Reply
	if json.unmarshal_string(strings.trim_space(stderr), &reply, allocator = allocator) != nil {
		return "", ""
	}
	return reply.error.code, reply.error.message
}

// at_shell says whether a pane is back at its shell's prompt: the shell
// holds the terminal's foreground (`pane process-info`), and herdr sees no
// agent in the pane any more (`pane get`). `agent start` needs both.
at_shell :: proc(process_info, pane_get: string) -> (yes: bool, err: string) {
	Info :: struct {
		result: struct {
			process_info: struct {
				shell_pid:                   u64,
				foreground_process_group_id: u64,
			},
		},
	}
	Get :: struct {
		result: struct {
			type: string,
			pane: struct {
				pane_id: string,
				agent:   string,
			},
		},
	}
	info: Info
	get: Get
	if json.unmarshal_string(process_info, &info, allocator = context.temp_allocator) != nil {
		return false, "herdr pane process-info printed no JSON claude-roll can read"
	}
	if json.unmarshal_string(pane_get, &get, allocator = context.temp_allocator) != nil || get.result.type != "pane_info" {
		return false, "herdr pane get printed no pane"
	}
	p := info.result.process_info
	return p.shell_pid != 0 && p.foreground_process_group_id == p.shell_pid && get.result.pane.agent == "", ""
}
