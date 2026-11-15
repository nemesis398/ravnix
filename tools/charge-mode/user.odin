// charge-mode: read and cycle the laptop battery's charge ceiling.
//
// WHY A ROOT HELPER AND NOT `sudo tee`. charge_types is root-writable only.
// The hardware module (modules/hardware/ideapad-pro-5-16ahp9/battery.nix)
// gives the user one sudo rule, without a password, for exactly one command:
// charge-mode-apply, from this package, which validates its argument against
// the live charge_types list, so the grant cannot be bent into an arbitrary
// root write. This command never writes sysfs or the saved mode itself.
// sudo is the setuid wrapper on the caller's PATH; when it fails, the
// message says why (run_helper).
package charge_mode

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/linux"

USAGE :: `charge-mode              print the active mode
charge-mode cycle        Long_Life -> Standard -> Fast -> Long_Life
charge-mode set <mode>   set one explicitly, right now
charge-mode default      print the mode re-asserted at boot
charge-mode default <m>  set the boot mode, leaving the live one alone
charge-mode modes        list what the firmware currently offers`

// The most of sudo's and the helper's words that a failure shows.
MAX_SAID :: 65536

// Exit statuses: 0 done (or nothing to do without charge_types), 1 the
// helper did not run or refused, 2 bad usage.
run_user :: proc(args: []string, cfg: Config, out, err: io.Writer) -> int {
	// Inert where the attribute does not exist, rather than failing loudly:
	// same auto-detect-not-hardcode rule as waybar-battery and the
	// waybar-gpu* helpers.
	if linux.access(strings.clone_to_cstring(cfg.attr, context.temp_allocator), linux.R_OK) != .NONE {
		fmt.wprintfln(err, "charge-mode: no %s on this machine; nothing to do", cfg.attr)
		return 0
	}
	command := args[0] if len(args) > 0 else ""
	switch command {
	case "", "show", "status":
		fmt.wprintln(out, current(cfg))
	case "cycle":
		return apply(cfg, next_mode(current(cfg)), false, out, err)
	case "set":
		mode := args[1] if len(args) > 1 else ""
		if mode == "" {
			b := strings.builder_make(context.temp_allocator)
			for m in modes(cfg) {
				fmt.sbprintf(&b, "%s ", m)
			}
			fmt.wprintfln(err, "charge-mode: 'set' needs a mode. Offered now: %s", strings.to_string(b))
			return 2
		}
		return apply(cfg, mode, false, out, err)
	case "default":
		mode := args[1] if len(args) > 1 else ""
		if mode == "" {
			data, res, _ := read_small(cfg.state, MAX_USER_READ, follow = true, allocator = context.temp_allocator)
			if res == .Ok {
				io.write(out, data)
			} else {
				fmt.wprintln(out, "(nothing saved)")
			}
			return 0
		}
		return apply(cfg, mode, true, out, err)
	case "modes":
		for m in modes(cfg) {
			fmt.wprintln(out, m)
		}
	case "-h", "--help", "help":
		fmt.wprintln(out, USAGE)
	case:
		fmt.wprintfln(err, "charge-mode: unknown command '%s' (try --help)", command)
		return 2
	}
	return 0
}

// current is the active mode, the bracketed one; "unknown" when the
// attribute cannot be read or brackets none.
current :: proc(cfg: Config) -> string {
	data, res, _ := read_small(cfg.attr, MAX_USER_READ, follow = true, allocator = context.temp_allocator)
	if res != .Ok {
		return "unknown"
	}
	return current_mode(string(data))
}

modes :: proc(cfg: Config) -> []string {
	data, res, _ := read_small(cfg.attr, MAX_USER_READ, follow = true, allocator = context.temp_allocator)
	if res != .Ok {
		return nil
	}
	return offered_modes(string(data), context.temp_allocator)
}

// apply sets mode through the helper; save_only sets the BOOT DEFAULT and
// leaves the live mode alone. The two are deliberately separable: the cell
// can stay parked now and still come up in a different mode after a reboot.
// The mode goes to the helper as it is, and the helper judges it.
apply :: proc(cfg: Config, mode: string, save_only: bool, out, err: io.Writer) -> int {
	if !is_executable(cfg.helper) {
		fmt.wprintfln(err, "charge-mode: %s is missing.", cfg.helper)
		fmt.wprintln(err, "             It comes with the charge-mode package; rebuild the host.")
		return 1
	}
	if save_only {
		if !run_helper(cfg, {"--save-only", mode}, err) {
			return 1
		}
		notify(cfg, {"-a", "charge-mode", fmt.tprintf("Charge mode at boot: %s", mode), fmt.tprintf("The live mode is unchanged (%s).", current(cfg))})
		fmt.wprintln(out, mode)
		return 0
	}
	if !run_helper(cfg, {mode}, err) {
		return 1
	}
	notify(cfg, {"-a", "charge-mode", fmt.tprintf("Charge mode: %s", mode), describe(mode)})
	refresh_waybar(cfg.euid)
	fmt.wprintln(out, mode)
	return 0
}

// run_helper runs the helper through sudo -n. When that fails, the message
// is the real cause, sudo's own words or the helper's, with a hint only
// where the cause is known: no sudo rule, or a sudo that is not the setuid
// one (a PATH that lost /run/wrappers/bin). The same goes into a
// notification, since a click on Waybar shows no terminal.
run_helper :: proc(cfg: Config, helper_args: []string, err: io.Writer) -> bool {
	context.allocator = context.temp_allocator
	said: string
	sudo, found := find_on_path("sudo", cfg.path)
	if !found {
		said = "charge-mode: no sudo on the PATH; on NixOS the setuid one is /run/wrappers/bin/sudo."
	} else {
		command := make([dynamic]string)
		append(&command, sudo, "-n", cfg.helper)
		append(&command, ..helper_args)
		output, ran, start_error := run_captured(command[:], env_with(cfg.env, "LC_ALL", "C"))
		if ran {
			// A helper that succeeds says nothing, unless it warns.
			if words := trim_newlines(output); words != "" {
				fmt.wprintln(err, words)
			}
			return true
		}
		said = trim_newlines(output)
		if start_error != "" {
			said = fmt.tprintf("charge-mode: cannot run %s: %s", sudo, start_error)
		}
	}
	hint := hint_for(said)
	if said == "" {
		said = "charge-mode: sudo or the helper failed without a message."
	}
	fmt.wprintln(err, said)
	if hint != "" {
		fmt.wprintfln(err, "charge-mode: %s", hint)
	}
	body := said if hint == "" else fmt.tprintf("%s %s", said, hint)
	notify(cfg, {"-a", "charge-mode", "-u", "critical", "Charge mode not changed", body})
	return false
}

// hint_for is the known cause behind sudo's words, or "".
hint_for :: proc(said: string) -> string {
	switch {
	case strings.contains(said, "a password is required"):
		return "no sudo rule lets you run the helper without a password; the hardware module's battery.nix gives it."
	case strings.contains(said, "setuid bit"), strings.contains(said, "effective uid is not 0"):
		return "this sudo is not the setuid one; on NixOS that is /run/wrappers/bin/sudo, which the PATH must name first."
	}
	return ""
}

// notify runs notify-send with args, when there is one; whether it works
// changes nothing.
notify :: proc(cfg: Config, args: []string) {
	context.allocator = context.temp_allocator
	program := cfg.notify_send
	if program == "" {
		return
	}
	if strings.index_byte(program, '/') < 0 {
		found: bool
		if program, found = find_on_path(program, cfg.path); !found {
			return
		}
	} else if !is_executable(program) {
		return
	}
	command := make([dynamic]string)
	append(&command, program)
	append(&command, ..args)
	run_inherited(command[:], cfg.env)
}

// find_on_path finds name as an executable regular file in a directory of
// path, as the shell's `command -v` does; empty and relative entries are
// skipped, so nothing is ever run from the working directory.
find_on_path :: proc(name, path: string) -> (string, bool) {
	rest := path
	for dir in strings.split_iterator(&rest, ":") {
		if !strings.has_prefix(dir, "/") {
			continue
		}
		candidate := strings.concatenate({strings.trim_right(dir, "/"), "/", name}, context.temp_allocator)
		if is_executable(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// is_executable tells whether path is a regular file this process may run.
is_executable :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: linux.Stat
	if linux.stat(cpath, &st) != .NONE || !linux.S_ISREG(st.mode) {
		return false
	}
	return linux.access(cpath, linux.X_OK) == .NONE
}

// env_with is env with key set to value, and no other entry for key.
env_with :: proc(env: []string, key, value: string, allocator := context.allocator) -> []string {
	result := make([dynamic]string, 0, len(env) + 1, allocator)
	prefix := strings.concatenate({key, "="}, allocator)
	for e in env {
		if !strings.has_prefix(e, prefix) {
			append(&result, e)
		}
	}
	append(&result, strings.concatenate({prefix, value}, allocator))
	return result[:]
}

// run_captured runs command and returns its output and error output
// together, as they came, at most MAX_SAID bytes of it; ran is whether it
// started and exited 0.
run_captured :: proc(command, env: []string) -> (output: string, ran: bool, start_error: string) {
	r, w, perr := os.pipe()
	if perr != nil {
		return "", false, os.error_string(perr)
	}
	process, serr := os.process_start({command = command, env = env, stdout = w, stderr = w})
	os.close(w)
	if serr != nil {
		os.close(r)
		return "", false, os.error_string(serr)
	}
	collected := make([dynamic]byte, context.temp_allocator)
	buf: [4096]byte
	for {
		n, rerr := os.read(r, buf[:])
		if n > 0 && len(collected) < MAX_SAID {
			append(&collected, ..buf[:min(n, MAX_SAID - len(collected))])
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	os.close(r)
	state, _ := os.process_wait(process)
	return string(collected[:]), state.exited && state.success && state.exit_code == 0, ""
}

// run_inherited runs command with this process's output and error output,
// and waits for it.
run_inherited :: proc(command, env: []string) {
	process, serr := os.process_start({command = command, env = env, stdout = os.stdout, stderr = os.stderr})
	if serr != nil {
		return
	}
	_, _ = os.process_wait(process)
}
