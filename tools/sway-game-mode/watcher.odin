// What the tool decides, and how it acts on Sway: which window has focus,
// which mode Sway is in, and the commands that enter and leave "game".
package sway_game_mode

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:sys/linux"
import "core:time"

// The windows that put Sway into mode "game": an app_id, or the class of an
// XWayland window. To add one, read it with
//   swaymsg -t get_tree | jq -r '.. | select(.focused?) | .app_id // .window_properties.class'
GAMES :: [?]string{"com.mojang.minecraft"}

// The sway config's values (modules/desktop/sway/config, `seat * hide_cursor`).
// "game" switches the hiding off and leaving restores them; keep them in
// step with the config.
HIDE_WHEN_TYPING :: "enable"
HIDE_TIMEOUT_MS :: "8000"

ENTER_COMMANDS := [?]string{"mode game", "seat * hide_cursor when-typing disable", "seat * hide_cursor 0"}
LEAVE_COMMANDS := [?]string {
	"mode default",
	"seat * hide_cursor when-typing " + HIDE_WHEN_TYPING,
	"seat * hide_cursor " + HIDE_TIMEOUT_MS,
}

// The changes of a window or workspace event that can change which window
// has focus, or put Sway back into mode "default". "reload" arrives on the
// workspace channel: `swaymsg reload` resets sway to mode "default" while
// the game keeps focus, and no focus event follows.
EVENT_CHANGES :: [?]string{"focus", "close", "new", "move", "init", "empty", "reload"}

// A tree nested deeper than this is not one of Sway's (a handful of levels
// plus the splits a person makes) and is refused before the JSON parser,
// which recurses, sees it.
MAX_JSON_DEPTH :: 512

// How long the rest of an event frame may take once its first byte is in. Sway
// writes a frame whole; a peer that stops in the middle of one is hung.
FRAME_STALL :: 10 * time.Second

Config :: struct {
	socket:  string,
	// See Conn.stop; -1 for none.
	stop:    linux.Fd,
	// How long Sway may take to answer one request.
	timeout: time.Duration,
	log:     ^os.File,
}

Action :: enum u8 {
	Nothing,
	Enter,
	Leave,
}

is_game :: proc(app: string) -> bool {
	for g in GAMES {
		if app == g {
			return true
		}
	}
	return false
}

// decide is the whole policy. The tool enters "game" only from "default": a
// focus change while you are in "resize" or "passthrough" (a VNC session
// into another compositor) leaves that mode alone, and so it only ever
// leaves "game". A mode the tool does not know is not touched either.
decide :: proc(app, mode: string) -> Action {
	game := is_game(app)
	switch {
	case game && mode == "default":
		return .Enter
	case !game && mode == "game":
		return .Leave
	}
	return .Nothing
}

is_event_change :: proc(change: string) -> bool {
	for c in EVENT_CHANGES {
		if change == c {
			return true
		}
	}
	return false
}

// json_depth_ok is false when the JSON text nests deeper than MAX_JSON_DEPTH
// brackets, strings and their escapes aside.
json_depth_ok :: proc(data: []u8) -> bool {
	depth := 0
	in_string, escaped := false, false
	for b in data {
		switch {
		case in_string:
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				in_string = false
			}
		case b == '"':
			in_string = true
		case b == '[' || b == '{':
			depth += 1
			if depth > MAX_JSON_DEPTH {
				return false
			}
		case b == ']' || b == '}':
			depth -= 1
		}
	}
	return true
}

parse_json :: proc(data: []u8, allocator := context.allocator) -> (v: json.Value, ok: bool) {
	if !json_depth_ok(data) {
		return nil, false
	}
	value, err := json.parse(data, .JSON, false, allocator)
	if err != .None {
		return nil, false
	}
	return value, true
}

string_of :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

// focused_app is the app_id of the window with focus, or its class when it
// is an XWayland window. It is "" for an empty workspace (which holds the
// focus itself, with no app), and when the window has neither. Like the
// Python watcher before it, it takes the first focused node in the order of
// a depth-first walk that visits the floating nodes before the tiled ones.
focused_app :: proc(tree: json.Value, allocator := context.allocator) -> string {
	stack := make([dynamic]json.Value, allocator)
	append(&stack, tree)
	for len(stack) > 0 {
		node, is_obj := pop(&stack).(json.Object)
		if !is_obj {
			continue
		}
		if focused, _ := node["focused"].(json.Boolean); focused {
			if app := string_of(node["app_id"]); app != "" {
				return app
			}
			props, _ := node["window_properties"].(json.Object)
			return string_of(props["class"])
		}
		for key in ([?]string{"nodes", "floating_nodes"}) {
			children, _ := node[key].(json.Array)
			for child in children {
				append(&stack, child)
			}
		}
	}
	return ""
}

// binding_mode is the name of the mode Sway is in, from a get_binding_state
// reply.
binding_mode :: proc(reply: []u8, allocator := context.allocator) -> (mode: string, ok: bool) {
	v, parsed := parse_json(reply, allocator)
	if !parsed {
		return "", false
	}
	obj, is_obj := v.(json.Object)
	if !is_obj {
		return "", false
	}
	name, is_str := obj["name"].(json.String)
	return name, is_str
}

// event_change is the "change" of a window or workspace event.
event_change :: proc(payload: []u8, allocator := context.allocator) -> string {
	v, parsed := parse_json(payload, allocator)
	if !parsed {
		return ""
	}
	obj, _ := v.(json.Object)
	return string_of(obj["change"])
}

// failed_commands names what a run_command reply says went wrong: an array
// of {"success": bool, "error": string}. "" when every command worked, or
// when the reply is none this tool knows how to read (the commands were sent
// all the same).
failed_commands :: proc(reply: []u8, allocator := context.allocator) -> string {
	v, parsed := parse_json(reply, allocator)
	if !parsed {
		return ""
	}
	results, _ := v.(json.Array)
	for r in results {
		obj, _ := r.(json.Object)
		if ok, has := obj["success"].(json.Boolean); has && !ok {
			if text := string_of(obj["error"]); text != "" {
				return text
			}
			return "the command failed"
		}
	}
	return ""
}

Status :: enum u8 {
	Ok,
	Stopped,
	Failed,
}

say :: proc(cfg: Config, format: string, args: ..any) {
	// One write, so that two lines of the journal's never interleave.
	fmt.fprintfln(cfg.log, "sway-game-mode: %s", fmt.tprintf(format, ..args))
}

failure :: proc(e: Net_Error, what: string) -> (Status, string) {
	if e == .Stopped {
		return .Stopped, ""
	}
	return .Failed, fmt.tprintf("%s: %s", what, net_error_text(e))
}

// Watcher is the command connection, and the memory one request's work
// uses, which is emptied after it.
Watcher :: struct {
	cfg:   Config,
	cmd:   Conn,
	arena: virtual.Arena,
	a:     runtime.Allocator,
}

watcher_open :: proc(w: ^Watcher, cfg: Config) -> bool {
	w.cfg = cfg
	w.cmd = Conn {
		fd      = -1,
		stop    = cfg.stop,
		timeout = cfg.timeout,
	}
	if virtual.arena_init_growing(&w.arena) != nil {
		return false
	}
	w.a = virtual.arena_allocator(&w.arena)
	return true
}

watcher_close :: proc(w: ^Watcher) {
	conn_close(&w.cmd)
	virtual.arena_destroy(&w.arena)
}

// run_commands sends the commands one by one, as `swaymsg` did, and says so
// when Sway refuses one; the rest still run.
run_commands :: proc(w: ^Watcher, commands: []string) -> (Status, string) {
	for cmd in commands {
		reply, err := request(&w.cmd, MSG_RUN_COMMAND, cmd)
		if err != .None {
			return failure(err, fmt.tprintf("cannot run %q", cmd))
		}
		if text := failed_commands(reply, w.a); text != "" {
			say(w.cfg, "sway refused %q: %s", cmd, text)
		}
	}
	return .Ok, ""
}

// sync looks at the focus and the mode, and enters or leaves "game".
sync :: proc(w: ^Watcher) -> (Status, string) {
	defer virtual.arena_free_all(&w.arena)
	tree_reply, err := request(&w.cmd, MSG_GET_TREE, "")
	if err != .None {
		return failure(err, "cannot read the tree")
	}
	tree, tree_ok := parse_json(tree_reply, w.a)
	if !tree_ok {
		return .Failed, "sway sent a tree that is not JSON"
	}
	app := focused_app(tree, w.a)
	state_reply: []u8
	state_reply, err = request(&w.cmd, MSG_GET_BINDING_STATE, "")
	if err != .None {
		return failure(err, "cannot read the binding state")
	}
	mode, mode_ok := binding_mode(state_reply, w.a)
	if !mode_ok {
		return .Failed, "sway sent a binding state without a mode name"
	}
	switch decide(app, mode) {
	case .Enter:
		say(w.cfg, "%s has focus, entering mode game", app)
		return run_commands(w, ENTER_COMMANDS[:])
	case .Leave:
		say(w.cfg, "focus is on %q, leaving mode game", app)
		return run_commands(w, LEAVE_COMMANDS[:])
	case .Nothing:
	}
	return .Ok, ""
}

// leave_if_game puts Sway back into "default" when it is in "game", on a
// connection that no stop interrupts. It is what SIGTERM does, and what
// `--leave` is for the unit's ExecStopPost: after a crash the handler never
// ran, and Sway must not stay in a mode that leaves the mouse buttons
// unbound without the watcher. Without a Sway there is nothing to leave.
leave_if_game :: proc(cfg: Config) -> int {
	cfg := cfg
	cfg.stop = -1
	fd, _, why := dial(cfg.socket, -1, cfg.timeout)
	if why != "" {
		say(cfg, "nothing to leave: %s", why)
		return 0
	}
	w: Watcher
	if !watcher_open(&w, cfg) {
		say(cfg, "there is no memory to run")
		close_fd(fd)
		return 1
	}
	defer watcher_close(&w)
	w.cmd.fd = fd
	reply, err := request(&w.cmd, MSG_GET_BINDING_STATE, "")
	if err != .None {
		_, text := failure(err, "cannot read the binding state")
		say(cfg, "%s", text)
		return 1
	}
	mode, ok := binding_mode(reply, w.a)
	if !ok {
		say(cfg, "sway sent a binding state without a mode name")
		return 1
	}
	if mode != "game" {
		return 0
	}
	say(cfg, "leaving mode game")
	if st, text := run_commands(&w, LEAVE_COMMANDS[:]); st != .Ok {
		say(cfg, "%s", text)
		return 1
	}
	return 0
}

close_fd :: proc(fd: linux.Fd) {
	linux.close(fd)
}

// subscribed is whether Sway took the subscription: {"success": true}.
subscribed :: proc(reply: []u8, allocator := context.allocator) -> bool {
	v, ok := parse_json(reply, allocator)
	if !ok {
		return false
	}
	obj, _ := v.(json.Object)
	success, _ := obj["success"].(json.Boolean)
	return success
}

// watch is the watcher: subscribe, look once, then look again at every
// event that can change the answer. It returns the exit status. It returns
// only when stopped (0, after leaving "game") or when Sway goes away or
// breaks the protocol (1); systemd restarts the unit then.
watch :: proc(cfg: Config) -> int {
	w: Watcher
	if !watcher_open(&w, cfg) {
		say(cfg, "there is no memory to run")
		return 1
	}
	defer watcher_close(&w)

	// Subscribe before the first look, so that a change between the two is
	// an event and not a missed one.
	sub_fd, derr, why := dial(cfg.socket, cfg.stop, cfg.timeout)
	if derr == .Stopped {
		return 0
	}
	if why != "" {
		say(cfg, "%s", why)
		return 1
	}
	sub := Conn {
		fd      = sub_fd,
		stop    = cfg.stop,
		timeout = cfg.timeout,
	}
	defer conn_close(&sub)
	reply, err := request(&sub, MSG_SUBSCRIBE, `["window", "workspace"]`)
	if err != .None {
		if err == .Stopped {
			return 0
		}
		say(cfg, "cannot subscribe: %s", net_error_text(err))
		return 1
	}
	if !subscribed(reply, w.a) {
		say(cfg, "sway refused the subscription")
		return 1
	}
	// Events come when they come, but a frame that has begun goes on.
	sub.timeout = 0
	sub.stall = FRAME_STALL

	cmd_fd, derr2, why2 := dial(cfg.socket, cfg.stop, cfg.timeout)
	if derr2 == .Stopped {
		return 0
	}
	if why2 != "" {
		say(cfg, "%s", why2)
		return 1
	}
	w.cmd.fd = cmd_fd

	status, text := sync(&w)
	for status == .Ok {
		free_all(context.temp_allocator)
		type, payload, rerr := read_frame(&sub)
		if rerr != .None {
			status = .Stopped if rerr == .Stopped else .Failed
			text = net_error_text(rerr)
			break
		}
		if type != EVENT_WINDOW && type != EVENT_WORKSPACE {
			continue
		}
		change := event_change(payload, w.a)
		relevant := is_event_change(change)
		virtual.arena_free_all(&w.arena)
		if relevant {
			status, text = sync(&w)
		}
	}
	switch status {
	case .Stopped:
		return leave_if_game(cfg)
	case .Failed:
		say(cfg, "%s", text)
		return 1
	case .Ok:
	}
	return 1
}
