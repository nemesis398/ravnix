// The process that holds the password makes no core dump and cannot be
// read through ptrace or /proc/PID/mem by another process of the user.
package ravnix_keyring_unlock_tests

import "core:sys/linux"
import "core:testing"
import kr ".."

PR_GET_DUMPABLE :: 3

@(test)
forbids_core_dumps_and_ptrace :: proc(t: ^testing.T) {
	why := kr.forbid_core_dumps()
	testing.expect_value(t, why, "")
	dumpable := linux.syscall(linux.SYS_prctl, PR_GET_DUMPABLE, 0, 0, 0, 0)
	testing.expect_value(t, dumpable, 0)
	// A second call changes nothing and still succeeds.
	testing.expect_value(t, kr.forbid_core_dumps(), "")
}
