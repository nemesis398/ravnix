// The command: ravnix-notify --topic TOPIC MESSAGE... README.md has the
// exit codes and the config.
package ravnix_notify

import "core:os"
import "core:sys/linux"

main :: proc() {
	// systemd sets JOURNAL_STREAM to the device and inode of the journal
	// stream when a unit's standard error is connected to it, and passes it
	// on to every child. Only a standard error with those very numbers is
	// the journal: see stderr_is_journal.
	buf: [64]u8
	stream, _ := os.lookup_env(buf[:], "JOURNAL_STREAM")
	os.exit(run(os.args[1:], Env{
		stdin = os.stdin,
		out = os.to_writer(os.stdout),
		err = os.to_writer(os.stderr),
		journal_stream = stderr_is_journal(stream, linux.Fd(2)),
	}))
}
