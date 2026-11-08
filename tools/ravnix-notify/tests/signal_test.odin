// A child that exits without reading its input must not kill this process:
// a write to its closed pipe raises SIGPIPE, whose default is to end the
// program. run_child ignores the signal, and this test reads the disposition
// itself, because the write that would trigger it is too narrow a window to
// hit on purpose.
package ravnix_notify_tests

import "core:sys/posix"
import "core:testing"
import "core:time"
import notify ".."

// disposition_of is where SIGPIPE stands now: the handler address, with 1
// for SIG_IGN.
@(private = "file")
disposition_of :: proc(t: ^testing.T) -> uintptr {
	old: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(.SIGPIPE, nil, &old), posix.result.OK)
	return transmute(uintptr)old.sa_handler
}

// noop is what stands in for the default while the test waits: a SIGPIPE
// that another test thread raises in that moment runs this and goes no
// further, where the default would end the whole test binary.
@(private = "file")
noop :: proc "c" (sig: posix.Signal) {}

@(test)
a_run_ignores_sigpipe :: proc(t: ^testing.T) {
	// Put a handler of our own in first, so that "ignored" afterwards is this
	// run's doing and not an earlier test's. The handler is a no-op and not
	// SIG_DFL, because the tests run on one thread per core and the
	// signal's disposition is the process's: with the default in place for
	// the moment before run_child's first line, a write to a closed pipe on
	// another thread would kill the binary. No precondition on what a
	// concurrent run_child may already have set back: the result of the
	// call proves ours was accepted, and the check below holds either way.
	handler: posix.sigaction_t
	handler.sa_handler = noop
	testing.expect_value(t, posix.sigaction(.SIGPIPE, &handler, nil), posix.result.OK)

	res := notify.run_child({"/bin/sh", "-c", "exit 0"}, nil, 5 * time.Second, 1024)
	defer delete(res.stdout)
	defer delete(res.stderr)
	testing.expect_value(t, res.start_error, "")
	testing.expect_value(t, res.exit_code, 0)
	testing.expect_value(t, disposition_of(t), uintptr(1))
}
