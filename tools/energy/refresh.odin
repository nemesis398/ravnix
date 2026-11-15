package energy

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

// on_battery: the charger's file says 0. A missing or garbled file counts as
// the charger, so nothing suspends on a guess.
on_battery :: proc(cfg: ^Config) -> bool {
	text, ok := read_text(cfg.online_file)
	return ok && text == "0"
}

// tuned-ppd's power-profiles API on the system bus, the same one waybar's
// power-profiles-daemon module uses (powerprofilesctl is not installed here).
PROFILE_ARGS :: [?]string{"--system", "get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles", "ActiveProfile"}

// profile is the active power profile, or balanced when the daemon does not
// answer.
profile :: proc(cfg: ^Config) -> string {
	args := PROFILE_ARGS
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "busctl")
	append(&argv, ..args[:])
	res := run_child(cfg, {argv = argv[:], capture = true}, context.temp_allocator)
	if res.code != 0 {
		return "balanced"
	}
	v := strings.trim_right(string(res.stdout), "\n")
	v = strings.trim_prefix(v, "s \"")
	return strings.trim_suffix(v, "\"")
}

set_profile :: proc(cfg: ^Config, name: string) -> int {
	args := PROFILE_ARGS
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "busctl", args[0], "set-property", args[2], args[3], args[4], args[5], "s", name)
	return run_child(cfg, {argv = argv[:], stdout_to = cfg.stdout, stderr_to = cfg.stderr}, context.temp_allocator).code
}

// target_hz is the rate the panel should have: the fixed one, or in auto
// mode 60 Hz on power-saver and 120 Hz on the other profiles.
target_hz :: proc(cfg: ^Config) -> int {
	key, _ := find_key("refresh")
	switch state_get(cfg, key) {
	case "60":
		return 60
	case "120":
		return 120
	}
	return 60 if profile(cfg) == "power-saver" else 120
}

// The internal panel as sway reports it.
Panel :: struct {
	name:          string,
	width, height: i64,
	hz:            i64,
}

// MAX_JSON_DEPTH is how deep a list of outputs may nest. sway's has three
// levels; the parser recurses, so a stream of brackets must not reach it.
MAX_JSON_DEPTH :: 32

json_depth_ok :: proc(data: []byte) -> bool {
	depth := 0
	in_string, escaped := false, false
	for c in data {
		switch {
		case in_string:
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
		case c == '"':
			in_string = true
		case c == '[' || c == '{':
			depth += 1
			if depth > MAX_JSON_DEPTH {
				return false
			}
		case c == ']' || c == '}':
			depth -= 1
		}
	}
	return true
}

number_of :: proc(v: json.Value) -> (f64, bool) {
	#partial switch n in v {
	case json.Integer:
		return f64(n), true
	case json.Float:
		return f64(n), !math.is_nan(n) && !math.is_inf(n)
	}
	return 0, false
}

// find_panel picks the first active output whose name starts with eDP (the
// internal panel is eDP-1 or eDP-2, depending on the boot) from sway's list
// of outputs. hz is the refresh rate in whole Hz, rounded (59951 mHz is 60).
// ok is false when there is none, when the list is not JSON, and when that
// output has no mode to read, so no mode is set on a guess.
find_panel :: proc(data: []byte) -> (panel: Panel, ok: bool) {
	if !json_depth_ok(data) {
		return
	}
	root, err := json.parse(data, .JSON, true, context.temp_allocator)
	if err != .None {
		return
	}
	outputs, is_list := root.(json.Array)
	if !is_list {
		return
	}
	for item in outputs {
		output, is_object := item.(json.Object)
		if !is_object {
			continue
		}
		active, _ := output["active"].(json.Boolean)
		name, named := output["name"].(json.String)
		if !active || !named || !strings.has_prefix(name, "eDP") {
			continue
		}
		mode, has_mode := output["current_mode"].(json.Object)
		if !has_mode {
			return
		}
		w, w_ok := number_of(mode["width"])
		h, h_ok := number_of(mode["height"])
		r, r_ok := number_of(mode["refresh"])
		if !w_ok || !h_ok || !r_ok || w != math.floor(w) || h != math.floor(h) || w < 1 || h < 1 || w > 1e6 || h > 1e6 || math.abs(r) > 1e12 {
			return
		}
		return Panel{name = name, width = i64(w), height = i64(h), hz = i64(math.floor((r + 500) / 1000))}, true
	}
	return
}

// refresh puts the internal panel at the target rate. Only an active panel
// is touched, and only when its rate differs, so a call costs no modeset.
// kanshi pins 2560x1600@120Hz in all its profiles and re-applies on every
// dock and undock, so each profile ends with `exec energy refresh`, which
// puts the auto choice back.
refresh :: proc(cfg: ^Config) -> int {
	res := run_child(cfg, {argv = {"swaymsg", "-t", "get_outputs"}, capture = true}, context.temp_allocator)
	if res.code != 0 && len(res.stdout) == 0 {
		return 0
	}
	panel, ok := find_panel(res.stdout)
	if !ok {
		return 0
	}
	want := target_hz(cfg)
	if panel.hz == i64(want) {
		return 0
	}
	mode := fmt.tprintf("%dx%d@%dHz", panel.width, panel.height, want)
	return run_child(cfg, {argv = {"swaymsg", "output", panel.name, "mode", mode}, stderr_to = cfg.stderr}, context.temp_allocator).code
}

// idle_suspend is called by swayidle after IDLE_SUSPEND_MIN of idle (normal
// mode only; with keep-awake on, swayidle runs no timeouts at all). It
// suspends on battery with its switch on, and never cuts a backup or a video
// download short: then this idle period passes without a suspend.
idle_suspend :: proc(cfg: ^Config) -> int {
	key, _ := find_key("idle_suspend")
	if state_get(cfg, key) != "on" || !on_battery(cfg) {
		return 0
	}
	if run_child(cfg, {argv = {"systemctl", "is-active", "--quiet", "borg-backup.service"}}, context.temp_allocator).code == 0 ||
	   run_child(cfg, {argv = {"pgrep", "-x", "dl-video"}}, context.temp_allocator).code == 0 ||
	   run_child(cfg, {argv = {"pgrep", "-f", "^restic "}}, context.temp_allocator).code == 0 {
		return 0
	}
	return run_child(cfg, {argv = {"systemctl", "suspend"}, stdout_to = cfg.stdout, stderr_to = cfg.stderr}, context.temp_allocator).code
}
