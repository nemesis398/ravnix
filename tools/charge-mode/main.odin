// The entry point of each of the three programs. CHARGE_MODE_ROLE, which
// default.nix sets for each build, picks one; the others' code is not in the
// binary, since Odin builds only what main reaches. So the root helper holds
// no sudo, no notification and no Waybar refresh, only its own checks and
// its two writes.
package charge_mode

import "core:mem/virtual"
import "core:os"

ROLE :: #config(CHARGE_MODE_ROLE, "user")
#assert(ROLE == "user" || ROLE == "apply" || ROLE == "restore", "CHARGE_MODE_ROLE is user, apply or restore")

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		os.exit(1)
	}
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	cfg := system_config()
	status: int
	when ROLE == "apply" {
		status = run_apply(os.args[1:], cfg, os.to_writer(os.stderr))
	} else when ROLE == "restore" {
		status = run_restore(cfg, os.to_writer(os.stderr), context.allocator)
	} else {
		status = run_user(os.args[1:], cfg, os.to_writer(os.stdout), os.to_writer(os.stderr))
	}
	virtual.arena_destroy(&arena)
	os.exit(status)
}
