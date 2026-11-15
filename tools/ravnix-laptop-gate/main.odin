// The command: sshd runs it as the forced command of the server's key, with
// what the server asked for in SSH_ORIGINAL_COMMAND (README.md).
package ravnix_laptop_gate

import "core:fmt"
import "core:mem/virtual"
import "core:os"

// The program behind `facts`. default.nix sets it to the store path of
// machine-facts; without it, facts fails with exit 70 (decide).
MACHINE_FACTS :: #config(MACHINE_FACTS, "")

// The PATH machine-facts runs with: the system's programs, and not
// /run/wrappers/bin, where the setuid sudo and pkexec are. run0 and
// systemd-run need no setuid bit and are on this PATH; what keeps facts
// from them is that machine-facts calls neither, and that polkit refuses
// them from an ssh session (README.md).
FACTS_PATH :: "/run/current-system/sw/bin"

USAGE :: `usage: ravnix-laptop-gate [--root DIR] [--command TEXT]

The forced command of the server's key on the laptop. It reads what the
server asked for from SSH_ORIGINAL_COMMAND and answers only these calls,
each by its name alone, with no argument:

  ping          huginn is up
  facts         machine-facts, without sudo and without waking the dGPU
  battery       charge, power, energy and cycles of each battery
  charge-mode   the active charge mode, read and never set
  power         the dGPU's runtime power state, the battery's draw, and the
                CPU package's power counter (needs root on NixOS)

Anything else is refused with exit status 77, the reason on stderr, and one
line in the journal (journalctl -t ravnix-laptop-gate).

  --root DIR      read sysfs and /dev/log under DIR (tests, the bench)
  --command TEXT  answer TEXT in place of SSH_ORIGINAL_COMMAND

Exit status: 0 answered; 77 refused; 70 machine-facts could not be started;
64 bad usage.`

// parse_args reads the gate's own arguments, which come from the key's
// command= and never from the server. stop says to exit with status.
parse_args :: proc(args: []string, cfg: ^Config) -> (status: int, stop: bool) {
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			fmt.println(USAGE)
			return 0, true
		case "--root", "--command":
			if i + 1 >= len(args) {
				fmt.eprintfln("ravnix-laptop-gate: %s needs a value", args[i])
				return USAGE_ERROR, true
			}
			if args[i] == "--root" {
				cfg.root = args[i + 1]
			} else {
				cfg.command = args[i + 1]
			}
			i += 1
		case:
			fmt.eprintln("ravnix-laptop-gate: unknown argument; see --help")
			return USAGE_ERROR, true
		}
	}
	return 0, false
}

run :: proc() -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return EXEC_FAILED
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cfg := Config {
		root    = "",
		command = os.get_env("SSH_ORIGINAL_COMMAND", context.allocator),
		client  = client_of(os.get_env("SSH_CONNECTION", context.allocator), context.allocator),
		home    = os.get_env("HOME", context.allocator),
		user    = os.get_env("USER", context.allocator),
		facts   = MACHINE_FACTS,
		path    = FACTS_PATH,
	}
	if status, stop := parse_args(os.args[1:], &cfg); stop {
		return status
	}

	r := answer(cfg, context.allocator)
	if r.stdout != "" {
		_, _ = os.write_string(os.stdout, r.stdout)
	}
	if r.stderr != "" {
		_, _ = os.write_string(os.stderr, r.stderr)
	}
	if r.exec.path != "" {
		errno := start(r.exec, context.allocator)
		fmt.eprintfln("ravnix-laptop-gate: cannot start %s: %v", r.exec.path, errno)
		return EXEC_FAILED
	}
	return r.status
}

main :: proc() {
	os.exit(run())
}
