// The test of the one decision that is not about a message: whether standard
// error is the journal. systemd.exec(5) says a set JOURNAL_STREAM is not
// proof, because a unit passes the variable on to children whose standard
// error is a terminal or a pipe of their own; the device and inode in it have
// to be those of the descriptor.
package ravnix_notify_tests

import "core:fmt"
import "core:sys/linux"
import "core:testing"
import notify ".."

// A pipe stands in for the journal's stream: it has a device and an inode of
// its own, which is all the decision looks at.
@(private = "file")
pipe_make :: proc(t: ^testing.T) -> (fds: [2]linux.Fd, st: linux.Stat) {
	testing.expect_value(t, linux.pipe2(&fds, {.CLOEXEC}), linux.Errno.NONE)
	testing.expect_value(t, linux.fstat(fds[0], &st), linux.Errno.NONE)
	return
}

@(private = "file")
pipe_close :: proc(fds: [2]linux.Fd) {
	linux.close(fds[0])
	linux.close(fds[1])
}

@(test)
standard_error_is_the_journal_when_device_and_inode_match :: proc(t: ^testing.T) {
	fds, st := pipe_make(t)
	defer pipe_close(fds)
	value := fmt.tprintf("%d:%d", u64(st.dev), u64(st.ino))
	testing.expectf(t, notify.stderr_is_journal(value, fds[0]), "%q is the pipe's own device and inode", value)
	// The write end is the same inode.
	testing.expectf(t, notify.stderr_is_journal(value, fds[1]), "%q is the write end's too", value)
}

@(test)
a_set_variable_that_names_another_stream_is_not_the_journal :: proc(t: ^testing.T) {
	fds, st := pipe_make(t)
	defer pipe_close(fds)
	other, ost := pipe_make(t)
	defer pipe_close(other)

	// Another inode on the same device: the unit's journal stream, passed on
	// to a child whose stderr is something else.
	value := fmt.tprintf("%d:%d", u64(st.dev), u64(ost.ino))
	testing.expectf(t, !notify.stderr_is_journal(value, fds[0]), "%q is the other pipe's inode", value)
	// The same inode on another device.
	value = fmt.tprintf("%d:%d", u64(st.dev) + 1, u64(st.ino))
	testing.expectf(t, !notify.stderr_is_journal(value, fds[0]), "%q is another device", value)
	// The value systemd.exec(5) uses as its example.
	testing.expect(t, !notify.stderr_is_journal("8:1", fds[0]))
}

@(test)
a_malformed_variable_is_not_the_journal :: proc(t: ^testing.T) {
	fds, st := pipe_make(t)
	defer pipe_close(fds)
	good := fmt.tprintf("%d:%d", u64(st.dev), u64(st.ino))

	bad := [?]string {
		"", // not set
		":",
		good[:len(good) - 1], // cut inside the inode: a different number
		fmt.tprintf("%d", u64(st.dev)), // no colon
		fmt.tprintf("%d:", u64(st.dev)),
		fmt.tprintf(":%d", u64(st.ino)),
		fmt.tprintf("%d:%d:1", u64(st.dev), u64(st.ino)),
		fmt.tprintf("%d,%d", u64(st.dev), u64(st.ino)),
		fmt.tprintf(" %s", good),
		fmt.tprintf("%s ", good),
		fmt.tprintf("%s\n", good),
		fmt.tprintf("+%d:%d", u64(st.dev), u64(st.ino)),
		fmt.tprintf("-%d:%d", u64(st.dev), u64(st.ino)),
		fmt.tprintf("%d:0x%x", u64(st.dev), u64(st.ino)),
		fmt.tprintf("%d:%d_0", u64(st.dev), u64(st.ino)),
		fmt.tprintf("0%d:%d%s", u64(st.dev), u64(st.ino), "x"),
		"a:b",
		"1.5:2",
		"18446744073709551616:1",
		"99999999999999999999999999:1",
		"1:99999999999999999999999999",
	}
	for v in bad {
		testing.expectf(t, !notify.stderr_is_journal(v, fds[0]), "%q is not the journal", v)
	}
	testing.expect(t, notify.stderr_is_journal(good, fds[0]), "the control value is")
}

@(test)
a_number_that_wraps_around_is_not_the_journal :: proc(t: ^testing.T) {
	fds, st := pipe_make(t)
	defer pipe_close(fds)
	// 2^64 plus the real inode is the same number to a parser that wraps on
	// overflow; it has twenty digits and must not match.
	over := u128(1) << 64
	wrapped_ino := fmt.tprintf("%d:%d", u64(st.dev), over + u128(st.ino))
	testing.expectf(t, !notify.stderr_is_journal(wrapped_ino, fds[0]), "%q", wrapped_ino)
	wrapped_dev := fmt.tprintf("%d:%d", over + u128(st.dev), u64(st.ino))
	testing.expectf(t, !notify.stderr_is_journal(wrapped_dev, fds[0]), "%q", wrapped_dev)
}

@(test)
a_descriptor_that_is_not_open_is_not_the_journal :: proc(t: ^testing.T) {
	fds, st := pipe_make(t)
	value := fmt.tprintf("%d:%d", u64(st.dev), u64(st.ino))
	pipe_close(fds)
	// Closed, the descriptor has no inode to match; nothing is guessed.
	testing.expectf(t, !notify.stderr_is_journal(value, fds[0]), "%q on a closed descriptor", value)
	testing.expect(t, !notify.stderr_is_journal(value, linux.Fd(-1)))
}
