// The loop: read the keyboard's events, translate them, write them to the
// virtual device. It stops on the first thing that goes wrong, so the process
// ends and the kernel gives the keyboard back. Its only blocking call is the
// read of the keyboard, which is the job; nothing else can make it hang
// while it holds the grab.
package copilot_key_super

import "core:mem"
import "core:sys/linux"

// How many events one read takes at most.
READ_EVENTS :: 64

// A Reader is read_fd, or a stand-in in the tests.
Reader :: #type proc(fd: linux.Fd, buf: []u8) -> (int, linux.Errno)

// read_fd is the Reader of the command.
read_fd :: proc(fd: linux.Fd, buf: []u8) -> (int, linux.Errno) {
	return linux.read(fd, buf)
}

// A Writer is write_fd, or a stand-in in the tests.
Writer :: #type proc(fd: linux.Fd, data: []u8) -> (int, linux.Errno)

// write_fd is the Writer of the command.
write_fd :: proc(fd: linux.Fd, data: []u8) -> (int, linux.Errno) {
	return linux.write(fd, data)
}

// A Held_Reader fills held with the keys the keyboard holds down now
// (EVIOCGKEY), for the resync after a SYN_DROPPED.
Held_Reader :: #type proc(fd: linux.Fd, held: ^Key_Bits) -> linux.Errno

Stop :: enum {
	Ended, // the input ended (read returned 0)
	Gone, // the device went away (ENODEV)
	Read_Failed,
	Write_Failed,
	Resync_Failed, // EVIOCGKEY failed after a SYN_DROPPED
}

Pump_Result :: struct {
	stop:  Stop,
	errno: linux.Errno,
	torn:  int, // bytes of an incomplete event left when the input ended
}

// pump runs the loop until the input ends or fails. An event read in parts
// (a pipe can do that, evdev does not) is put together first.
pump :: proc(t: ^Translator, input, output: linux.Fd, read: Reader, write: Writer, held: Held_Reader) -> Pump_Result {
	events: [READ_EVENTS]Event
	bytes := mem.slice_to_bytes(events[:])
	out: [max(READ_EVENTS, RESYNC_MAX)]Event
	have := 0
	for {
		n, rerr := read(input, bytes[have:])
		#partial switch rerr {
		case .NONE:
		case .EINTR:
			continue
		case .ENODEV:
			return {stop = .Gone, errno = rerr}
		case:
			return {stop = .Read_Failed, errno = rerr}
		}
		if n == 0 {
			return {stop = .Ended, torn = have}
		}
		have += n
		whole := have / size_of(Event)
		o := 0
		for ev in events[:whole] {
			if e, ok := translate(t, ev); ok {
				out[o] = e
				o += 1
			}
		}
		// The resync after a SYN_DROPPED comes after every event of the read,
		// never between them: the snapshot is newer than all of them, and
		// EVIOCGKEY also throws away the key events still queued for this
		// reader, so an event of the read put after it would undo it (a key
		// pressed in the read and let go before the snapshot would stick).
		if t.resync_wanted {
			if werr := write_all(output, mem.slice_to_bytes(out[:o]), write); werr != .NONE {
				return {stop = .Write_Failed, errno = werr}
			}
			keys: Key_Bits
			if herr := held(input, &keys); herr != .NONE {
				return {stop = .Resync_Failed, errno = herr}
			}
			last := events[whole - 1]
			o = resync(t, &keys, last.sec, last.usec, out[:])
		}
		if werr := write_all(output, mem.slice_to_bytes(out[:o]), write); werr != .NONE {
			return {stop = .Write_Failed, errno = werr}
		}
		used := whole * size_of(Event)
		copy(bytes[:have - used], bytes[used:have])
		have -= used
	}
}

// write_all writes all of data, through short writes and EINTR. A write
// that takes nothing and reports nothing would loop forever, so it is EIO.
write_all :: proc(fd: linux.Fd, data: []u8, write: Writer) -> linux.Errno {
	rest := data
	for len(rest) > 0 {
		n, err := write(fd, rest)
		switch {
		case err == .EINTR:
			continue
		case err != .NONE:
			return err
		case n <= 0:
			return .EIO
		}
		rest = rest[n:]
	}
	return .NONE
}
