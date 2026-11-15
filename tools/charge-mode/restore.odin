// charge-mode-restore: re-assert the saved charge mode at boot, through
// charge-mode-apply, which validates it. charge-mode-restore.service runs it
// (modules/hardware/ideapad-pro-5-16ahp9/battery.nix).
//
// Waits briefly for the attribute: ideapad_laptop is a module, and if it has
// not bound yet this would otherwise skip in silence and leave the mode
// unrestored. Bounded so a machine that will never have it does not hang the
// boot.
package charge_mode

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:strings"
import "core:sys/linux"
import "core:time"

// What the restore decided: run the helper with mode, or exit with status.
Restore :: struct {
	run:    bool,
	mode:   string,
	status: int,
}

// plan_restore reads the saved mode and waits for charge_types. Without a
// readable saved mode, or with an empty one, there is nothing to do. The mode
// is passed on unchecked: the helper judges it, as it judges every caller's.
plan_restore :: proc(cfg: Config, err: io.Writer, allocator := context.allocator) -> Restore {
	data, res, _ := read_small(cfg.state, MAX_ROOT_READ, follow = false, allocator = allocator)
	switch res {
	case .Ok:
	case .Missing, .Failed:
		return {}
	case .Symlink:
		fmt.wprintfln(err, "charge-mode-restore: %s is a symlink; not restored", cfg.state)
		return {status = 1}
	case .Not_File:
		fmt.wprintfln(err, "charge-mode-restore: %s is not a file; not restored", cfg.state)
		return {status = 1}
	case .Too_Big:
		fmt.wprintfln(err, "charge-mode-restore: %s holds more than %d bytes, which no mode does; not restored", cfg.state, MAX_ROOT_READ)
		return {status = 2}
	}
	mode := trim_newlines(string(data))
	if mode == "" {
		return {}
	}
	// An argument ends at a NUL, so the helper would see another mode than
	// the file holds.
	if strings.index_byte(mode, 0) >= 0 {
		fmt.wprintfln(err, "charge-mode-restore: %s holds a NUL byte; not restored", cfg.state)
		return {status = 2}
	}

	path := strings.clone_to_cstring(cfg.attr, context.temp_allocator)
	for i := 0; linux.access(path, linux.F_OK) != .NONE; i += 1 {
		if i >= cfg.wait_tries {
			fmt.wprintfln(err, "charge-mode-restore: %s never appeared", cfg.attr)
			return {}
		}
		time.sleep(cfg.wait_step)
	}
	return {run = true, mode = mode}
}

// exec_helper replaces this process with the helper, which keeps the
// environment. It returns only when that fails, with the shell's status for
// it: 127 when there is no such file, 126 otherwise.
exec_helper :: proc(cfg: Config, mode: string, err: io.Writer) -> int {
	context.allocator = context.temp_allocator
	argv := []cstring{strings.clone_to_cstring(cfg.helper), strings.clone_to_cstring(mode), nil}
	envp := make([]cstring, len(cfg.env) + 1)
	for e, i in cfg.env {
		envp[i] = strings.clone_to_cstring(e)
	}
	errno := linux.execve(argv[0], raw_data(argv), raw_data(envp))
	fmt.wprintfln(err, "charge-mode-restore: cannot run %s: %s", cfg.helper, errno_text(errno))
	return 127 if errno == .ENOENT else 126
}

run_restore :: proc(cfg: Config, err: io.Writer, allocator: runtime.Allocator) -> int {
	plan := plan_restore(cfg, err, allocator)
	if !plan.run {
		return plan.status
	}
	return exec_helper(cfg, plan.mode, err)
}
