// The command: pam_exec runs it as root, with PAM_USER, PAM_TTY and PAM_TYPE in
// its environment and sudo as its parent; README.md has the PAM line.
package ravnix_tap_ask

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"

// The programs it runs. default.nix sets both to their store paths; a bare
// name is looked up on PATH.
FUZZEL :: #config(FUZZEL, "fuzzel")
SETPRIV :: #config(SETPRIV, "setpriv")

USAGE :: `usage: ravnix-tap-ask [--dry-run] [--root DIR] [--parent PID] [--user NAME] [--tty TTY]

Asks on the user's own screen, in a fuzzel popup, whether a sudo may wait for
a tap on the security key. pam_exec runs it right before pam_u2f in sudo's auth
stack; it reads PAM_USER, PAM_TTY and PAM_TYPE, and sudo is its parent.

It asks only when the user has ~/.config/Yubico/u2f_keys, a FIDO key is
plugged in, the screen is not locked and the user has a Wayland session.

  --dry-run      decide without the popup: print the decision and what the
                 popup would show, and exit 0
  --root DIR     read /proc, /sys, /run and /etc/passwd under DIR
  --parent PID   the sudo process (default: the parent)
  --user NAME    the user (default: PAM_USER)
  --tty TTY      the terminal (default: PAM_TTY)

Exit status: 0 Allow was chosen, so pam_u2f runs; 1 no popup, Deny, no
answer in 30 s, or the popup failed, so pam_u2f is skipped; 2 bad usage.`

// run is the whole command, for the arguments after the program's name and
// the PAM values of the environment, and returns the exit status.
run :: proc(args: []string, user, tty, pam_type: string) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	cfg := default_config()
	cfg.parent = os.get_ppid()
	cfg.user, cfg.tty, cfg.pam_type = user, tty, pam_type
	dry_run := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			fmt.println(USAGE)
			return 0
		case "--dry-run":
			dry_run = true
		case "--root", "--parent", "--user", "--tty":
			if i + 1 >= len(args) {
				fmt.eprintfln("ravnix-tap-ask: %s needs a value", args[i])
				return 2
			}
			value := args[i + 1]
			switch args[i] {
			case "--root":
				cfg.root = value
			case "--user":
				cfg.user = value
			case "--tty":
				cfg.tty = value
			case "--parent":
				pid, ok := strconv.parse_int(value, 10)
				if !ok || pid <= 0 {
					fmt.eprintfln("ravnix-tap-ask: --parent %s is no process id", value)
					return 2
				}
				cfg.parent = pid
			}
			i += 1
		case:
			fmt.eprintfln("ravnix-tap-ask: unknown argument %s", args[i])
			return 2
		}
	}

	if dry_run {
		if cfg.pam_type == "" {
			cfg.pam_type = "auth"
		}
		req := prepare(cfg, context.allocator)
		if req.skip != .None {
			fmt.printfln("skip: %v", req.skip)
			return 0
		}
		fmt.println("ask:")
		for arg in popup_command(cfg, req, context.allocator) {
			fmt.println(" ", arg)
		}
		return 0
	}
	return 0 if allowed(decide(cfg, context.allocator)) else 1
}

main :: proc() {
	os.exit(run(os.args[1:], os.get_env("PAM_USER", context.allocator), os.get_env("PAM_TTY", context.allocator), os.get_env("PAM_TYPE", context.allocator)))
}
