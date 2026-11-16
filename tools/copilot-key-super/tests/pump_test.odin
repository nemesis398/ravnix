// The loop and the command. The loop runs on real file descriptors (files
// and pipes) where the sandbox has them, and on a fake reader for what it
// has not: a keyboard that goes away (ENODEV), a read that fails or is
// interrupted, and input that comes a byte at a time. The command runs on a
// fake root, for every way it must fail before it grabs anything.
package copilot_key_super_tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import tool ".."

// The macro and a typed letter, as the keyboard sends them.
sample :: proc() -> []tool.Event {
	p := macro_press(0)
	r := macro_release(500)
	return keys(p[0], p[1], p[2], r[0], r[1], r[2], key(700, KEY_A, 1), key(780, KEY_A, 0))
}

// sample_out is what the virtual device gets for sample.
sample_out :: proc() -> []Out {
	out := make([]Out, 12, context.temp_allocator)
	copy(out, []Out{k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN, k(KEY_A, 1), SYN, k(KEY_A, 0), SYN})
	return out
}

as_bytes :: proc(events: []tool.Event) -> []u8 {
	return mem.slice_to_bytes(events)
}

decode :: proc(t: ^testing.T, data: []u8) -> []Out {
	testing.expectf(t, len(data) % size_of(tool.Event) == 0, "the output is %d bytes, no whole number of events", len(data))
	events := mem.slice_data_cast([]tool.Event, data[:len(data) - len(data) % size_of(tool.Event)])
	got := make([dynamic]Out, context.temp_allocator)
	for e in events {
		append(&got, Out{e.type, e.code, e.value})
	}
	return got[:]
}

open_fd :: proc(t: ^testing.T, path: string, flags: linux.Open_Flags) -> linux.Fd {
	fd, err := linux.open(strings.clone_to_cstring(path, context.temp_allocator), flags, {.IRUSR, .IWUSR})
	testing.expectf(t, err == .NONE, "open %s: %v", path, err)
	return fd
}

no_keys :: proc(fd: linux.Fd, held: ^tool.Key_Bits) -> linux.Errno {
	held^ = {}
	return .NONE
}

// Script is what the fake reader hands out, call by call: a chunk of bytes,
// or an error. When it runs out it returns end.
Step :: struct {
	data:  []u8,
	errno: linux.Errno,
}
Script :: struct {
	steps: []Step,
	next:  int,
	end:   linux.Errno, // .NONE: read returns 0
	calls: int,
}

fake_read :: proc(fd: linux.Fd, buf: []u8) -> (int, linux.Errno) {
	s := cast(^Script)context.user_ptr
	s.calls += 1
	if s.next >= len(s.steps) {
		return 0, s.end
	}
	step := &s.steps[s.next]
	if step.errno != .NONE {
		s.next += 1
		return 0, step.errno
	}
	n := copy(buf, step.data)
	step.data = step.data[n:]
	if len(step.data) == 0 {
		s.next += 1
	}
	return n, .NONE
}

pump_file :: proc(t: ^testing.T, events: []tool.Event) -> (result: tool.Pump_Result, got: []Out) {
	dir := scratch(t)
	in_path := strings.concatenate({dir, "/in"}, context.temp_allocator)
	out_path := strings.concatenate({dir, "/out"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(in_path, as_bytes(events)), nil)
	input := open_fd(t, in_path, {})
	output := open_fd(t, out_path, {.WRONLY, .CREAT, .TRUNC})
	tr: tool.Translator
	result = tool.pump(&tr, input, output, tool.read_fd, tool.write_fd, no_keys)
	linux.close(input)
	linux.close(output)
	data, err := os.read_entire_file(out_path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	os.remove_all(dir)
	return result, decode(t, data)
}

@(test)
pumps_a_recording_from_a_file :: proc(t: ^testing.T) {
	result, got := pump_file(t, sample())
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	testing.expect_value(t, result.torn, 0)
	expect_out(t, got, sample_out())
}

@(test)
pumps_more_than_one_read_holds :: proc(t: ^testing.T) {
	// Ten reads' worth: the buffer turns over many times.
	all := make([dynamic]tool.Event, context.temp_allocator)
	want := make([dynamic]Out, context.temp_allocator)
	ms: i64 = 0
	for _ in 0 ..< 10 * tool.READ_EVENTS {
		append(&all, ..keys(key(ms, KEY_A, 1), key(ms + 30, KEY_A, 0)))
		append(&want, k(KEY_A, 1), SYN, k(KEY_A, 0), SYN)
		ms += 100
	}
	result, got := pump_file(t, all[:])
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	expect_out(t, got, want[:])
}

@(test)
an_empty_input_ends_at_once :: proc(t: ^testing.T) {
	result, got := pump_file(t, {})
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	testing.expect_value(t, len(got), 0)
}

@(test)
input_a_byte_at_a_time_gives_the_same :: proc(t: ^testing.T) {
	// A pipe can hand out part of an event; the rest comes with the next read.
	data := as_bytes(sample())
	steps := make([]Step, len(data), context.temp_allocator)
	for i in 0 ..< len(data) {
		steps[i] = {data = data[i:i + 1]}
	}
	script := Script{steps = steps}
	context.user_ptr = &script
	dir := scratch(t)
	defer os.remove_all(dir)
	out_path := strings.concatenate({dir, "/out"}, context.temp_allocator)
	output := open_fd(t, out_path, {.WRONLY, .CREAT, .TRUNC})
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, no_keys)
	linux.close(output)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	testing.expect_value(t, result.torn, 0)
	out, _ := os.read_entire_file(out_path, context.temp_allocator)
	expect_out(t, decode(t, out), sample_out())
}

@(test)
a_torn_last_event_is_reported :: proc(t: ^testing.T) {
	events := sample()
	data := as_bytes(events)
	script := Script{steps = {{data = data[:len(data) - 5]}}}
	context.user_ptr = &script
	dir := scratch(t)
	defer os.remove_all(dir)
	output := open_fd(t, strings.concatenate({dir, "/out"}, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC})
	defer linux.close(output)
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	testing.expect_value(t, result.torn, size_of(tool.Event) - 5)
}

@(test)
a_keyboard_that_goes_away_stops_the_loop :: proc(t: ^testing.T) {
	// The macro, then ENODEV, as evdev answers once the device is unbound.
	// The loop must stop with Gone, after writing what it had, and not read
	// again.
	script := Script{steps = {{data = as_bytes(sample())}, {errno = .ENODEV}}, end = .ENODEV}
	context.user_ptr = &script
	dir := scratch(t)
	defer os.remove_all(dir)
	out_path := strings.concatenate({dir, "/out"}, context.temp_allocator)
	output := open_fd(t, out_path, {.WRONLY, .CREAT, .TRUNC})
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, no_keys)
	linux.close(output)
	testing.expect_value(t, result.stop, tool.Stop.Gone)
	testing.expect_value(t, result.errno, linux.Errno.ENODEV)
	testing.expect_value(t, script.calls, 2)
	out, _ := os.read_entire_file(out_path, context.temp_allocator)
	expect_out(t, decode(t, out), sample_out())
}

@(test)
a_failed_read_stops_and_an_interrupted_one_does_not :: proc(t: ^testing.T) {
	data := as_bytes(sample())
	script := Script{steps = {{errno = .EINTR}, {data = data}, {errno = .EINTR}, {errno = .EIO}}}
	context.user_ptr = &script
	dir := scratch(t)
	defer os.remove_all(dir)
	output := open_fd(t, strings.concatenate({dir, "/out"}, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC})
	defer linux.close(output)
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Read_Failed)
	testing.expect_value(t, result.errno, linux.Errno.EIO)
}

@(test)
a_failed_write_stops_the_loop :: proc(t: ^testing.T) {
	script := Script{steps = {{data = as_bytes(sample())}}}
	context.user_ptr = &script
	// A descriptor opened read-only cannot be written: EBADF.
	dir := scratch(t)
	defer os.remove_all(dir)
	path := strings.concatenate({dir, "/ro"}, context.temp_allocator)
	put(t, path, "")
	output := open_fd(t, path, {})
	defer linux.close(output)
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Write_Failed)
	testing.expect_value(t, result.errno, linux.Errno.EBADF)
	testing.expect_value(t, script.calls, 1)
}

// Sink is where the fake writer puts what it takes: at most chunk bytes a
// call, after an EINTR on every interrupt-th call, and nothing at all (a
// return of 0) once stall calls have passed, when stall is set.
Sink :: struct {
	data:      [dynamic]u8,
	chunk:     int,
	interrupt: int,
	stall:     int,
	calls:     int,
}

fake_write :: proc(fd: linux.Fd, data: []u8) -> (int, linux.Errno) {
	s := cast(^Sink)context.user_ptr
	s.calls += 1
	if s.interrupt > 0 && s.calls % s.interrupt == 0 {
		return 0, .EINTR
	}
	if s.stall > 0 && s.calls > s.stall {
		return 0, .NONE
	}
	n := min(len(data), s.chunk)
	append(&s.data, ..data[:n])
	return n, .NONE
}

@(test)
short_and_interrupted_writes_are_finished :: proc(t: ^testing.T) {
	// Writes that take 1, 2 or 7 bytes, with an EINTR every third call: all
	// of the data arrives, in order.
	data := as_bytes(sample())
	for chunk in ([]int{1, 2, 7}) {
		sink := Sink{data = make([dynamic]u8, context.temp_allocator), chunk = chunk, interrupt = 3}
		context.user_ptr = &sink
		testing.expect_value(t, tool.write_all(1, data, fake_write), linux.Errno.NONE)
		testing.expectf(t, string(sink.data[:]) == string(data), "chunk %d: %d bytes arrived of %d", chunk, len(sink.data), len(data))
	}
	// A write that takes nothing and reports no error would loop forever:
	// it is an EIO.
	sink := Sink{data = make([dynamic]u8, context.temp_allocator), chunk = 5, stall = 2}
	context.user_ptr = &sink
	testing.expect_value(t, tool.write_all(1, data, fake_write), linux.Errno.EIO)
	testing.expect_value(t, len(sink.data), 10)
}

@(test)
the_loop_writes_through_short_writes :: proc(t: ^testing.T) {
	// The loop with a reader and a writer that both hand over a few bytes at
	// a time.
	script := Script{steps = {{data = as_bytes(sample())}}}
	sink := Sink{data = make([dynamic]u8, context.temp_allocator), chunk = 5, interrupt = 4}
	Both :: struct {
		script: ^Script,
		sink:   ^Sink,
	}
	both := Both{&script, &sink}
	context.user_ptr = &both
	read :: proc(fd: linux.Fd, buf: []u8) -> (int, linux.Errno) {
		b := cast(^Both)context.user_ptr
		context.user_ptr = b.script
		return fake_read(fd, buf[:min(len(buf), 11)])
	}
	write :: proc(fd: linux.Fd, data: []u8) -> (int, linux.Errno) {
		b := cast(^Both)context.user_ptr
		context.user_ptr = b.sink
		return fake_write(fd, data)
	}
	tr: tool.Translator
	result := tool.pump(&tr, 0, 1, read, write, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	expect_out(t, decode(t, sink.data[:]), sample_out())
}

@(test)
a_full_pipe_reader_gone_fails_the_write :: proc(t: ^testing.T) {
	// The virtual device's end closed: writing to a pipe with no reader is
	// EPIPE (SIGPIPE is ignored for the test, as the runner does not set it).
	fds: [2]linux.Fd
	testing.expect_value(t, linux.pipe2(&fds, {.CLOEXEC}), linux.Errno.NONE)
	linux.close(fds[0])
	defer linux.close(fds[1])
	old: linux.Sig_Action
	ign := linux.Sig_Action {
		special = .SIG_IGN,
	}
	linux.rt_sigaction(.SIGPIPE, &ign, &old)
	defer linux.rt_sigaction(.SIGPIPE, &old, nil)
	script := Script{steps = {{data = as_bytes(sample())}}}
	context.user_ptr = &script
	tr: tool.Translator
	result := tool.pump(&tr, 0, fds[1], fake_read, tool.write_fd, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Write_Failed)
	testing.expect_value(t, result.errno, linux.Errno.EPIPE)
}

// The keyboard after the reads below, as EVIOCGKEY reports it. A fake
// snapshot may only be a state the kernel can return: the keys as they are
// after every event the reads handed out, and after whatever came since
// (EVIOCGKEY also throws away the key events still queued for the reader).
held_b_and_c :: proc(fd: linux.Fd, held: ^tool.Key_Bits) -> linux.Errno {
	held^ = {}
	tool.set_bit(held, KEY_B, true)
	tool.set_bit(held, KEY_C, true)
	return .NONE
}

failing_held :: proc(fd: linux.Fd, held: ^tool.Key_Bits) -> linux.Errno {
	return .ENODEV
}

KEY_C :: 46

// pump_events runs the loop over events in one read, with held as the
// snapshot, and returns what came out.
pump_events :: proc(t: ^testing.T, events: []tool.Event, held: tool.Held_Reader) -> (tool.Pump_Result, []Out) {
	script := Script{steps = {{data = as_bytes(events)}}}
	context.user_ptr = &script
	dir := scratch(t)
	defer os.remove_all(dir)
	out_path := strings.concatenate({dir, "/out"}, context.temp_allocator)
	output := open_fd(t, out_path, {.WRONLY, .CREAT, .TRUNC})
	tr: tool.Translator
	result := tool.pump(&tr, 0, output, fake_read, tool.write_fd, held)
	linux.close(output)
	out, _ := os.read_entire_file(out_path, context.temp_allocator)
	return result, decode(t, out)
}

@(test)
a_syn_dropped_resyncs_from_the_keyboard :: proc(t: ^testing.T) {
	// A is held; the drop loses A's release and B's press; C comes after
	// it. The snapshot, taken after the read, has B and C down: A is
	// released and B pressed, in code order, after everything of the read.
	events := []tool.Event {
		at(0, tool.EV_KEY, KEY_A, 1),
		at(0, tool.EV_SYN, tool.SYN_REPORT, 0),
		at(1, tool.EV_SYN, tool.SYN_DROPPED, 0),
		at(2, tool.EV_SYN, tool.SYN_REPORT, 0),
		at(3, tool.EV_KEY, KEY_C, 1),
		at(3, tool.EV_SYN, tool.SYN_REPORT, 0),
	}
	result, got := pump_events(t, events, held_b_and_c)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	expect_out(t, got, {k(KEY_A, 1), SYN, k(KEY_C, 1), SYN, k(KEY_A, 0), k(KEY_B, 1), SYN})

	// When the keys cannot be read, the loop stops.
	result, _ = pump_events(t, events, failing_held)
	testing.expect_value(t, result.stop, tool.Stop.Resync_Failed)
	testing.expect_value(t, result.errno, linux.Errno.ENODEV)
}

@(test)
a_key_pressed_after_the_drop_and_let_go_before_the_snapshot_is_up :: proc(t: ^testing.T) {
	// One read: the drop, its report, then A pressed. A is let go before the
	// snapshot, which says A is up and throws the queued release away. The
	// snapshot is the newest word, so A must end up.
	events := []tool.Event {
		at(0, tool.EV_SYN, tool.SYN_DROPPED, 0),
		at(0, tool.EV_SYN, tool.SYN_REPORT, 0),
		at(1, tool.EV_KEY, KEY_A, 1),
		at(1, tool.EV_SYN, tool.SYN_REPORT, 0),
	}
	result, got := pump_events(t, events, no_keys)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	expect_out(t, got, {k(KEY_A, 1), SYN, k(KEY_A, 0), SYN})
}

held_macro :: proc(fd: linux.Fd, held: ^tool.Key_Bits) -> linux.Errno {
	held^ = {}
	tool.set_bit(held, META, true)
	tool.set_bit(held, SHIFT, true)
	tool.set_bit(held, F23, true)
	return .NONE
}

@(test)
a_lost_macro_whose_f23_follows_the_drop_is_still_super :: proc(t: ^testing.T) {
	// The drop loses the macro's Meta and Shift presses; its F23 press comes
	// after the drop's report, in the same read, and cancels nothing (Meta
	// is not down as far as the events go). The snapshot at the end of the
	// read has all three down: that is the macro, so Meta goes down and
	// Shift does not, and a key typed in the hold is Super+key.
	events := []tool.Event {
		at(0, tool.EV_SYN, tool.SYN_DROPPED, 0),
		at(0, tool.EV_SYN, tool.SYN_REPORT, 0),
		at(2, tool.EV_KEY, F23, 1),
		at(2, tool.EV_SYN, tool.SYN_REPORT, 0),
	}
	result, got := pump_events(t, events, held_macro)
	testing.expect_value(t, result.stop, tool.Stop.Ended)
	expect_out(t, got, {k(META, 1), SYN})
}

@(test)
the_bench_stream_holds_the_macro :: proc(t: ^testing.T) {
	// bench/typing.events is make_stream's output, written by this test with
	// COPILOT_KEY_SUPER_WRITE_BENCH=PATH (README.md). The tests cannot read
	// bench/ (lib/odin.nix leaves it out of their source), so nothing checks
	// that the file is still this; README.md lists that.
	stream := make_stream(context.temp_allocator)
	if path := os.get_env("COPILOT_KEY_SUPER_WRITE_BENCH", context.temp_allocator); path != "" {
		testing.expect_value(t, os.write_entire_file(path, as_bytes(stream)), nil)
	}
	testing.expect_value(t, len(stream), 4096)
	tr: tool.Translator
	f23_in, f23_out, cancels := 0, 0, 0
	for ev in stream {
		if ev.type == tool.EV_KEY && ev.code == F23 && ev.value == 1 {
			f23_in += 1
		}
		was := tr.shift_cancelled
		if out, ok := tool.translate(&tr, ev); ok && out.type == tool.EV_KEY && out.code == F23 {
			f23_out += 1
		}
		if !was && tr.shift_cancelled {
			cancels += 1
		}
	}
	// Every Copilot press in it is read as the macro, none comes through.
	testing.expect(t, f23_in > 10)
	testing.expect_value(t, cancels, f23_in)
	testing.expect_value(t, f23_out, 0)
	testing.expect(t, !tool.any_down(&tr.down))
}

// make_stream is the bench's recording: 4096 events of typing at 80 ms a
// key, with MSC_SCAN as atkbd sends it, Shift every 16th key, and a Copilot
// press every 32nd, held for 600 ms with the keyboard repeating F23.
make_stream :: proc(allocator := context.allocator) -> []tool.Event {
	events := make([dynamic]tool.Event, 0, 4096, allocator)
	ms: i64 = 1_000_000
	frame :: proc(events: ^[dynamic]tool.Event, ms: i64, scan: i32, code: u16, value: i32) {
		append(events, at(ms, tool.EV_MSC, 4, scan), at(ms, tool.EV_KEY, code, value), at(ms, tool.EV_SYN, tool.SYN_REPORT, 0))
	}
	letters := [?]u16{30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25}
	for i := 0; len(events) + 30 <= 4096; i += 1 {
		if i % 32 == 31 {
			frame(&events, ms, 0xdb, META, 1)
			frame(&events, ms + 1, 0x2a, SHIFT, 1)
			frame(&events, ms + 2, 0x6e, F23, 1)
			for r in 0 ..< 5 {
				frame(&events, ms + 252 + i64(r) * 33, 0x6e, F23, 2)
			}
			frame(&events, ms + 600, 0x6e, F23, 0)
			frame(&events, ms + 601, 0x2a, SHIFT, 0)
			frame(&events, ms + 602, 0xdb, META, 0)
			ms += 700
			continue
		}
		code := letters[i % len(letters)]
		if i % 16 == 7 {
			frame(&events, ms, 0x2a, SHIFT, 1)
			frame(&events, ms + 40, i32(code), code, 1)
			frame(&events, ms + 90, i32(code), code, 0)
			frame(&events, ms + 120, 0x2a, SHIFT, 0)
		} else {
			frame(&events, ms, i32(code), code, 1)
			frame(&events, ms + 60, i32(code), code, 0)
		}
		ms += 80
	}
	for len(events) < 4096 {
		append(&events, at(ms, tool.EV_SYN, tool.SYN_REPORT, 0))
	}
	return events[:]
}

@(test)
the_command_refuses_bad_usage :: proc(t: ^testing.T) {
	code, out, err := run_command("--frobnicate")
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(err, "usage"), err)
	testing.expect_value(t, out, "")
	code, out, err = run_command("--root")
	testing.expect_value(t, code, 2)
	testing.expect(t, strings.contains(err, "--root needs a directory"), err)
	code, out, err = run_command("--filter", "--root", "/")
	testing.expect_value(t, code, 2)
	code, out, err = run_command("--help")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(out, "usage: copilot-key-super"), out)
}

@(test)
the_command_fails_without_the_keyboard :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	code, _, err := run_command("--root", root)
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "cannot list"), err)
	device(t, root, "event0", "Power Button\n")
	code, _, err = run_command("--root", root)
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, `no input device named "AT Translated Set 2 keyboard"`), err)
}

@(test)
the_command_fails_when_the_node_is_missing_or_no_device :: proc(t: ^testing.T) {
	root := scratch(t)
	defer os.remove_all(root)
	device(t, root, "event3", "AT Translated Set 2 keyboard\n")
	// sysfs has it, /dev has no node.
	code, _, err := run_command("--root", root)
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "/dev/input/event3"), err)
	// A plain file at the node: it opens, and is no input device (ENOTTY).
	put(t, strings.concatenate({root, "/dev/input/event3"}, context.temp_allocator), "")
	code, _, err = run_command("--root", root)
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(err, "not an input device"), err)
}

run_command :: proc(args: ..string) -> (code: int, out, err: string) {
	o, e: strings.Builder
	strings.builder_init(&o, context.temp_allocator)
	strings.builder_init(&e, context.temp_allocator)
	code = tool.run(args, strings.to_writer(&o), strings.to_writer(&e))
	return code, strings.to_string(o), strings.to_string(e)
}
