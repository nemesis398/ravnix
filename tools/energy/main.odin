// energy: the laptop's energy settings in one place, and the watcher that
// applies them. Built 2026-10-03 from the battery round's decisions on the
// Fedora laptop, in Bash; ported to Odin with the same commands and state
// files (README.md has what changed).
//
// THE MENU (`energy menu`, middle click on waybar's power draw) is a
// fuzzel dropdown in the style of waybar-netmenu. Each row is one setting with
// its current value; picking a row opens that setting's choices:
//   Power profile    power-saver / balanced / performance (tuned-ppd)
//   Refresh rate     auto / 120 Hz / 60 Hz. Auto = 60 Hz on power-saver and
//                    120 Hz on the other two profiles.
//   Keep-awake       on / off (the waybar cup; it also switches itself off on
//                    every unplug, so it can't be forgotten on battery again,
//                    as it was for 8 days in late September)
//   Idle suspend     on / off: suspend after 30 min idle, on battery only
//   Charge mode      Long_Life / Standard / Fast (charge-mode)
//   Focus bar        on / off: on battery, switch waybar to its focus layout
//
// THE WATCHER (`energy watch`, energy-watch.service) listens on the system bus
// for UPower's OnBattery and tuned-ppd's ActiveProfile and acts on changes:
// the refresh rate follows the profile in auto mode, and an unplug turns
// keep-awake off and, if Focus bar is on, switches waybar to focus (plugging
// in switches it back, but only if the watcher was the one that switched).
// gdbus blocks on the bus socket, so an idle watcher costs no wakeups.
//
// WHY KANSHI CALLS `energy refresh`. kanshi pins 2560x1600@120Hz in all its
// profiles and re-applies on every dock and undock, so each profile ends with
// `exec energy refresh`, which puts the auto choice back.
//
// The tools of the session come from its PATH: fuzzel (with the session's
// theme), swaymsg, keep-awake and waybar-launch. The rest comes with the
// package, charge-mode by the store path the hardware module gives it. A missing keep-awake or
// waybar-launch is said in the journal and a notification, never skipped
// without a word.
//
// Settings persist in ~/.local/state/energy (machine-local, survives reboots).
package energy

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"

// charge-mode, looked up on the PATH by name. The hardware module wraps the
// program with ENERGY_CHARGE_MODE set to the store path of the charge-mode
// that its sudo rule names, so the two cannot be told apart from outside.
CHARGE_MODE :: "charge-mode"
// The directories of the programs the package brings (busctl, systemctl,
// gdbus, notify-send, pgrep, setsid), in front of the session's PATH:
// default.nix sets them.
TOOLS_PATH :: #config(TOOLS_PATH, "")

// The charger of the IdeaPad. UPower's OnBattery wakes the watcher; this
// file says which way it changed (README.md has the finding).
ONLINE_FILE :: "/sys/class/power_supply/ADP0/online"

// The seams of the tests. Each replaces what the build or the system names;
// the variable ENERGY_TOOLS_PATH may be empty, for no directory of the
// package in front of the PATH.
ONLINE_FILE_VARIABLE :: "ENERGY_ONLINE_FILE"
CHARGE_MODE_VARIABLE :: "ENERGY_CHARGE_MODE"
TOOLS_PATH_VARIABLE :: "ENERGY_TOOLS_PATH"

// How long a program that only answers (sway, the bus, systemctl) may take
// before it is killed: a hung one must not stall the watcher or kanshi.
TIMEOUT :: 30 * time.Second

USAGE :: "usage: energy [menu|watch|refresh|idle-suspend|get KEY|set KEY VALUE]"

Config :: struct {
	// $XDG_STATE_HOME/energy, else ~/.local/state/energy; "" when neither
	// variable is set.
	state_dir:   string,
	// $XDG_RUNTIME_DIR, else /tmp: keep-awake, waybar-mode and the marker.
	run_dir:     string,
	online_file: string,
	charge_mode: string,
	// The PATH to look programs up on, which the programs started get too.
	path:        string,
	stdout:      ^os.File,
	stderr:      ^os.File,
	timeout:     time.Duration,
	// What a program may print before it is killed; 0 is MAX_OUTPUT.
	max_output:  int,
}

// config_from_env reads the environment once. Everything is allocated with
// context.allocator.
config_from_env :: proc() -> Config {
	cfg := Config {
		online_file = env_or(ONLINE_FILE_VARIABLE, ONLINE_FILE),
		charge_mode = env_or(CHARGE_MODE_VARIABLE, CHARGE_MODE),
		run_dir     = env_or("XDG_RUNTIME_DIR", "/tmp"),
		stdout      = os.stdout,
		stderr      = os.stderr,
		timeout     = TIMEOUT,
	}
	cfg.state_dir = state_dir_of(env_or("XDG_STATE_HOME", ""), env_or("HOME", ""))
	tools := TOOLS_PATH
	if v, set := os.lookup_env(TOOLS_PATH_VARIABLE, context.allocator); set {
		tools = v
	}
	cfg.path = join_path(tools, os.get_env("PATH", context.allocator))
	return cfg
}

// state_dir_of is $XDG_STATE_HOME/energy, else ~/.local/state/energy, and ""
// when neither is set. A variable that is set but empty counts as unset, as
// ${VAR:-...} does.
state_dir_of :: proc(state_home, home: string, allocator := context.allocator) -> string {
	switch {
	case state_home != "":
		return strings.concatenate({state_home, "/energy"}, allocator)
	case home != "":
		return strings.concatenate({home, "/.local/state/energy"}, allocator)
	}
	return ""
}

env_or :: proc(name, fallback: string) -> string {
	if v := os.get_env(name, context.allocator); v != "" {
		return v
	}
	return fallback
}

// join_path puts the package's directories in front of the session's PATH.
join_path :: proc(tools, session: string) -> string {
	switch {
	case tools == "":
		return session
	case session == "":
		return tools
	}
	return strings.concatenate({tools, ":", session})
}

// run is the whole command, for the arguments after the program's name. It
// returns the exit status. The first argument is the subcommand, menu when
// there is none.
run :: proc(args: []string, cfg: ^Config) -> int {
	// Everything the run allocates goes into one arena, freed at its end.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		say(cfg, "energy: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)

	command := "menu"
	if len(args) > 0 && args[0] != "" {
		command = args[0]
	}
	switch command {
	case "menu":
		return menu(cfg)
	case "watch":
		return watch(cfg)
	case "refresh":
		return refresh(cfg)
	case "idle-suspend":
		return idle_suspend(cfg)
	case "get":
		if len(args) < 2 || args[1] == "" {
			say(cfg, "energy: get needs a key")
			return 2
		}
		key, known := find_key(args[1])
		if !known {
			say(cfg, "energy: '%s' is not a key (%s)", args[1], key_names())
			return 2
		}
		fmt.fprintln(cfg.stdout, state_get(cfg, key))
		return 0
	case "set":
		if len(args) < 3 || args[1] == "" || args[2] == "" {
			say(cfg, "energy: set needs a key and a value")
			return 2
		}
		key, known := find_key(args[1])
		if !known || !valid_value(key, args[2]) {
			say(cfg, "energy: '%s' is not a value for '%s'", args[2], args[1])
			return 2
		}
		return state_set(cfg, key, args[2])
	}
	fmt.fprintln(cfg.stderr, USAGE)
	return 2
}

key_names :: proc() -> string {
	names := make([dynamic]string, context.temp_allocator)
	for k in KEYS {
		append(&names, k.name)
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

main :: proc() {
	cfg := config_from_env()
	os.exit(run(os.args[1:], &cfg))
}
