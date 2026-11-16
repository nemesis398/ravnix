// The translation, driven with event sequences. Times are in milliseconds
// of the events' own clock. A sequence is what the keyboard sends; what the
// test expects is what the virtual device gets, without the times.
package copilot_key_super_tests

import "core:testing"
import tool ".."

SHIFT :: tool.KEY_LEFTSHIFT
META :: tool.KEY_LEFTMETA
F23 :: tool.KEY_F23
RSHIFT :: 54
KEY_A :: 30
KEY_B :: 48

Out :: struct {
	type:  u16,
	code:  u16,
	value: i32,
}

at :: proc(ms: i64, type, code: u16, value: i32) -> tool.Event {
	us := ms * 1000
	return tool.Event{sec = us / 1_000_000, usec = us % 1_000_000, type = type, code = code, value = value}
}

// key is one key event and its report, as atkbd sends each key.
key :: proc(ms: i64, code: u16, value: i32) -> [2]tool.Event {
	return {at(ms, tool.EV_KEY, code, value), at(ms, tool.EV_SYN, tool.SYN_REPORT, 0)}
}

k :: proc(code: u16, value: i32) -> Out {
	return {tool.EV_KEY, code, value}
}

SYN :: Out{tool.EV_SYN, tool.SYN_REPORT, 0}

// feed translates events and collects what comes out.
feed :: proc(t: ^tool.Translator, events: []tool.Event, got: ^[dynamic]Out) {
	for ev in events {
		if out, ok := tool.translate(t, ev); ok {
			append(got, Out{out.type, out.code, out.value})
		}
	}
}

// keys flattens key frames into one sequence.
keys :: proc(frames: ..[2]tool.Event) -> []tool.Event {
	all := make([dynamic]tool.Event, 0, 2 * len(frames), context.temp_allocator)
	for f in frames {
		append(&all, f[0], f[1])
	}
	return all[:]
}

expect_out :: proc(t: ^testing.T, got: []Out, want: []Out, loc := #caller_location) {
	testing.expectf(t, len(got) == len(want), "got %d events %v, want %d %v", len(got), got, len(want), want, loc = loc)
	for i in 0 ..< min(len(got), len(want)) {
		testing.expectf(t, got[i] == want[i], "event %d: got %v, want %v (all: %v)", i, got[i], want[i], got, loc = loc)
	}
}

run_keys :: proc(tr: ^tool.Translator, frames: ..[2]tool.Event) -> []Out {
	got := make([dynamic]Out, context.temp_allocator)
	feed(tr, keys(..frames), &got)
	return got[:]
}

// The macro as measured on the laptop: Meta, Shift, F23 about 1 ms apart, and
// on release F23, Shift, Meta.
macro_press :: proc(ms: i64) -> [3][2]tool.Event {
	return {key(ms, META, 1), key(ms + 1, SHIFT, 1), key(ms + 2, F23, 1)}
}
macro_release :: proc(ms: i64) -> [3][2]tool.Event {
	return {key(ms, F23, 0), key(ms + 1, SHIFT, 0), key(ms + 2, META, 0)}
}

@(test)
input_event_is_the_kernels_layout :: proc(t: ^testing.T) {
	// struct input_event on x86_64: a 16-byte timeval, then u16, u16, s32.
	testing.expect_value(t, size_of(tool.Event), 24)
	testing.expect_value(t, offset_of(tool.Event, type), 16)
	testing.expect_value(t, offset_of(tool.Event, code), 18)
	testing.expect_value(t, offset_of(tool.Event, value), 20)
	testing.expect_value(t, size_of(tool.Key_Bits), 96)
}

@(test)
key_bits_follow_the_kernels_bitmap :: proc(t: ^testing.T) {
	bits: tool.Key_Bits
	testing.expect(t, !tool.any_down(&bits))
	tool.set_bit(&bits, SHIFT, true)
	testing.expect_value(t, bits[5], 1 << 2) // 42 is bit 2 of byte 5
	testing.expect(t, tool.bit(&bits, SHIFT))
	testing.expect(t, tool.any_down(&bits))
	tool.set_bit(&bits, tool.KEY_CNT - 1, true)
	testing.expect_value(t, bits[95], 0x80)
	tool.set_bit(&bits, SHIFT, false)
	tool.set_bit(&bits, tool.KEY_CNT - 1, false)
	testing.expect(t, !tool.any_down(&bits))
	// A code past the bitmap is no key: it neither sets nor reads a bit.
	tool.set_bit(&bits, 0xffff, true)
	tool.set_bit(&bits, tool.KEY_CNT, true)
	testing.expect(t, !tool.bit(&bits, 0xffff))
	testing.expect(t, !tool.any_down(&bits))
}

@(test)
plain_keys_pass_through :: proc(t: ^testing.T) {
	tr: tool.Translator
	got := run_keys(&tr, key(0, KEY_A, 1), key(80, KEY_A, 0), key(200, SHIFT, 1), key(250, KEY_B, 1), key(300, KEY_B, 0), key(350, SHIFT, 0))
	expect_out(t, got, {k(KEY_A, 1), SYN, k(KEY_A, 0), SYN, k(SHIFT, 1), SYN, k(KEY_B, 1), SYN, k(KEY_B, 0), SYN, k(SHIFT, 0), SYN})
}

@(test)
the_macro_becomes_a_plain_super :: proc(t: ^testing.T) {
	tr: tool.Translator
	p := macro_press(1000)
	r := macro_release(1400)
	got := run_keys(&tr, p[0], p[1], p[2], r[0], r[1], r[2])
	// Shift is down for the 1 ms until F23, then released; F23 never shows,
	// and the keyboard's own Shift release is swallowed. The frames that are
	// left empty get no report.
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN})
	testing.expect(t, !tr.shift_cancelled)
	testing.expect(t, !tool.any_down(&tr.down))
}

@(test)
the_macro_keeps_its_scancodes :: proc(t: ^testing.T) {
	// atkbd sends MSC_SCAN before each key, in the same frame.
	tr: tool.Translator
	scan :: proc(ms: i64, sc: i32, code: u16, value: i32) -> [3]tool.Event {
		return {at(ms, tool.EV_MSC, 4, sc), at(ms, tool.EV_KEY, code, value), at(ms, tool.EV_SYN, 0, 0)}
	}
	got := make([dynamic]Out, context.temp_allocator)
	for f in ([][3]tool.Event{scan(0, 0xdb, META, 1), scan(1, 0x2a, SHIFT, 1), scan(2, 0x6e, F23, 1), scan(900, 0x6e, F23, 0), scan(901, 0x2a, SHIFT, 0), scan(902, 0xdb, META, 0)}) {
		f := f
		feed(&tr, f[:], &got)
	}
	m :: proc(sc: i32) -> Out {return {tool.EV_MSC, 4, sc}}
	expect_out(
		t,
		got[:],
		{m(0xdb), k(META, 1), SYN, m(0x2a), k(SHIFT, 1), SYN, m(0x6e), k(SHIFT, 0), SYN, m(0x6e), SYN, m(0x2a), SYN, m(0xdb), k(META, 0), SYN},
	)
}

@(test)
a_held_macro_repeats_nothing_but_super :: proc(t: ^testing.T) {
	tr: tool.Translator
	p := macro_press(0)
	r := macro_release(2000)
	// The keyboard repeats the last key, F23, and the test also repeats Shift
	// and Meta: neither F23 nor the cancelled Shift may come through.
	got := run_keys(&tr, p[0], p[1], p[2], key(250, F23, 2), key(283, SHIFT, 2), key(316, F23, 2), key(349, META, 2), r[0], r[1], r[2])
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 2), SYN, k(META, 0), SYN})
}

@(test)
a_real_shift_held_before_the_key_is_kept :: proc(t: ^testing.T) {
	tr: tool.Translator
	// The user holds Shift; the macro's Shift is then a key already down,
	// which atkbd reports as a repeat. Copilot+Shift stays Super+Shift.
	got := run_keys(&tr, key(0, SHIFT, 1), key(1000, META, 1), key(1001, SHIFT, 2), key(1002, F23, 1), key(1500, F23, 0), key(1501, SHIFT, 0), key(1502, META, 0))
	expect_out(t, got, {k(SHIFT, 1), SYN, k(META, 1), SYN, k(SHIFT, 2), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN})
}

@(test)
a_real_shift_pressed_just_before_the_key_is_kept :: proc(t: ^testing.T) {
	tr: tool.Translator
	// Shift, then Copilot 20 ms later: inside the window, but the Shift press
	// came before the macro's Meta, so it is the user's. The Python cancelled
	// this one.
	// An A typed while the key is held shows the Shift is still down: a
	// cancel at the F23 would put the Shift release before it.
	got := run_keys(&tr, key(0, SHIFT, 1), key(20, META, 1), key(21, SHIFT, 2), key(22, F23, 1), key(200, KEY_A, 1), key(250, KEY_A, 0), key(400, F23, 0), key(401, SHIFT, 0), key(402, META, 0))
	expect_out(t, got, {k(SHIFT, 1), SYN, k(META, 1), SYN, k(SHIFT, 2), SYN, k(KEY_A, 1), SYN, k(KEY_A, 0), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN})
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
the_order_of_shift_and_meta_decides_to_the_microsecond :: proc(t: ^testing.T) {
	// The same microsecond for Meta and Shift is the macro (its keys can
	// share a timestamp); a Shift one microsecond before the Meta is not.
	feed_at :: proc(tr: ^tool.Translator, meta_us, shift_us, f23_us: i64) {
		got := make([dynamic]Out, context.temp_allocator)
		feed(tr, {tool.Event{usec = meta_us, type = tool.EV_KEY, code = META, value = 1}}, &got)
		feed(tr, {tool.Event{usec = shift_us, type = tool.EV_KEY, code = SHIFT, value = 1}}, &got)
		feed(tr, {tool.Event{usec = f23_us, type = tool.EV_KEY, code = F23, value = 1}}, &got)
	}
	{
		tr: tool.Translator
		feed_at(&tr, 1000, 1000, 1001)
		testing.expect(t, tr.shift_cancelled)
		testing.expect(t, !tool.bit(&tr.down, SHIFT))
	}
	{
		tr: tool.Translator
		feed_at(&tr, 1001, 1000, 1002)
		testing.expect(t, !tr.shift_cancelled)
		testing.expect(t, tool.bit(&tr.down, SHIFT))
	}
}

@(test)
a_real_super_held_before_the_key_still_loses_the_shift :: proc(t: ^testing.T) {
	tr: tool.Translator
	// The macro's Meta comes as a repeat of the held one; its Shift is new.
	got := run_keys(&tr, key(0, META, 1), key(1000, META, 2), key(1001, SHIFT, 1), key(1002, F23, 1), key(1300, F23, 0), key(1301, SHIFT, 0))
	expect_out(t, got, {k(META, 1), SYN, k(META, 2), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN})
	testing.expect(t, tr.meta_down)
}

@(test)
a_right_shift_held_is_left_alone :: proc(t: ^testing.T) {
	tr: tool.Translator
	p := macro_press(1000)
	r := macro_release(1400)
	got := run_keys(&tr, key(0, RSHIFT, 1), p[0], p[1], p[2], r[0], r[1], r[2], key(1600, RSHIFT, 0))
	expect_out(t, got, {k(RSHIFT, 1), SYN, k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN, k(RSHIFT, 0), SYN})
}

@(test)
f23_without_meta_cancels_nothing :: proc(t: ^testing.T) {
	tr: tool.Translator
	// Shift and F23 inside the window, no Meta: a Shift+A typed while F23
	// is held stays Shift+A.
	got := run_keys(&tr, key(0, SHIFT, 1), key(1, F23, 1), key(100, KEY_A, 1), key(150, KEY_A, 0), key(200, F23, 0), key(300, SHIFT, 0))
	expect_out(t, got, {k(SHIFT, 1), SYN, k(KEY_A, 1), SYN, k(KEY_A, 0), SYN, k(SHIFT, 0), SYN})
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
an_f23_repeat_alone_cancels_nothing :: proc(t: ^testing.T) {
	// A repeat of F23 is no press: with Meta and Shift just pressed it opens
	// nothing (a stray repeat after a lost press, say).
	tr: tool.Translator
	got := run_keys(&tr, key(0, META, 1), key(1, SHIFT, 1), key(2, F23, 2), key(100, KEY_A, 1))
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN, k(KEY_A, 1), SYN})
	testing.expect(t, !tr.shift_cancelled)
	testing.expect(t, tool.bit(&tr.down, SHIFT))
}

@(test)
a_repeat_leaves_the_key_bitmap_alone :: proc(t: ^testing.T) {
	// The input core passes a 2 without changing the key's state: a repeat
	// of a key that is up does not make it down, and one of a key that is
	// down keeps it down.
	tr: tool.Translator
	got := run_keys(&tr, key(0, KEY_A, 2))
	expect_out(t, got, {k(KEY_A, 2), SYN})
	testing.expect(t, !tool.bit(&tr.down, KEY_A))
	_ = run_keys(&tr, key(10, KEY_B, 1), key(260, KEY_B, 2), key(293, KEY_B, 2))
	testing.expect(t, tool.bit(&tr.down, KEY_B))
}

@(test)
f23_with_meta_and_no_shift_ever_cancels_nothing :: proc(t: ^testing.T) {
	// The first events after the start, at the clock's zero: no Shift has
	// been pressed, so nothing is in the window.
	tr: tool.Translator
	got := run_keys(&tr, key(0, META, 1), key(0, F23, 1), key(1, F23, 0), key(2, META, 0))
	expect_out(t, got, {k(META, 1), SYN, k(META, 0), SYN})
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
the_window_is_fifty_milliseconds_and_open_at_its_end :: proc(t: ^testing.T) {
	{
		tr: tool.Translator
		got := make([dynamic]Out, context.temp_allocator)
		feed(&tr, keys(key(0, META, 1), key(0, SHIFT, 1)), &got)
		// 49.999 ms: inside.
		feed(&tr, {tool.Event{sec = 0, usec = 49_999, type = tool.EV_KEY, code = F23, value = 1}}, &got)
		testing.expect(t, tr.shift_cancelled)
	}
	{
		tr: tool.Translator
		got := make([dynamic]Out, context.temp_allocator)
		feed(&tr, keys(key(0, META, 1), key(0, SHIFT, 1)), &got)
		// 50 ms exactly: outside, as in the Python (a strict <).
		feed(&tr, {tool.Event{sec = 0, usec = 50_000, type = tool.EV_KEY, code = F23, value = 1}}, &got)
		testing.expect(t, !tr.shift_cancelled)
	}
	{
		// Across a second boundary: 999.990 s to 1000.010 s is 20 ms.
		tr: tool.Translator
		got := make([dynamic]Out, context.temp_allocator)
		feed(&tr, {tool.Event{sec = 999, usec = 990_000, type = tool.EV_KEY, code = META, value = 1}}, &got)
		feed(&tr, {tool.Event{sec = 999, usec = 990_000, type = tool.EV_KEY, code = SHIFT, value = 1}}, &got)
		feed(&tr, {tool.Event{sec = 1000, usec = 10_000, type = tool.EV_KEY, code = F23, value = 1}}, &got)
		testing.expect(t, tr.shift_cancelled)
	}
}

@(test)
a_clock_that_goes_back_cancels_nothing :: proc(t: ^testing.T) {
	// A realtime clock stepped back between Shift and F23 (EVIOCSCLOCKID
	// failed): F23 then seems to come before the Shift, which no macro does.
	tr: tool.Translator
	got := run_keys(&tr, key(5000, META, 1), key(5000, SHIFT, 1), key(4000, F23, 1))
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN})
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
releases_without_a_press :: proc(t: ^testing.T) {
	tr: tool.Translator
	// F23 is never forwarded; a lone Shift or Meta release passes, and the
	// kernel drops it on the virtual device, where the key is up.
	got := run_keys(&tr, key(0, F23, 0), key(1, SHIFT, 0), key(2, META, 0), key(3, F23, 2))
	expect_out(t, got, {k(SHIFT, 0), SYN, k(META, 0), SYN})
	testing.expect(t, !tr.meta_down)
	testing.expect(t, !tool.any_down(&tr.down))
}

@(test)
a_real_shift_press_during_a_cancel_passes_with_its_release :: proc(t: ^testing.T) {
	tr: tool.Translator
	p := macro_press(0)
	// A Shift press (value 1) while the macro's Shift is cancelled: a real
	// one, so it and its release go through (the Python's case).
	got := run_keys(&tr, p[0], p[1], p[2], key(300, SHIFT, 1), key(400, KEY_B, 1), key(450, KEY_B, 0), key(500, SHIFT, 0))
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(SHIFT, 1), SYN, k(KEY_B, 1), SYN, k(KEY_B, 0), SYN, k(SHIFT, 0), SYN})
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
the_macro_twice_and_then_shift_works_as_ever :: proc(t: ^testing.T) {
	tr: tool.Translator
	a := macro_press(0)
	b := macro_release(100)
	c := macro_press(300)
	d := macro_release(400)
	got := run_keys(&tr, a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], d[0], d[1], d[2], key(2000, SHIFT, 1), key(2100, KEY_A, 1), key(2150, KEY_A, 0), key(2200, SHIFT, 0))
	super := []Out{k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN}
	want := make([dynamic]Out, context.temp_allocator)
	append(&want, ..super)
	append(&want, ..super)
	append(&want, k(SHIFT, 1), SYN, k(KEY_A, 1), SYN, k(KEY_A, 0), SYN, k(SHIFT, 0), SYN)
	expect_out(t, got, want[:])
}

@(test)
shift_released_before_f23_is_still_swallowed :: proc(t: ^testing.T) {
	// The release order turned around: Shift first, then F23. The Shift is
	// already up on the virtual device, so its release is swallowed.
	tr: tool.Translator
	p := macro_press(0)
	got := run_keys(&tr, p[0], p[1], p[2], key(300, SHIFT, 0), key(301, F23, 0), key(302, META, 0))
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 1), SYN, k(SHIFT, 0), SYN, k(META, 0), SYN})
}

@(test)
frames_keep_their_bounds :: proc(t: ^testing.T) {
	tr: tool.Translator
	got := make([dynamic]Out, context.temp_allocator)
	// Two keys in one frame stay one frame; a report with nothing before it
	// is not repeated; SYN_CONFIG and SYN_MT_REPORT, which a keyboard never
	// sends, are dropped; other event types pass as they are.
	feed(
		&tr,
		{
			at(0, tool.EV_SYN, tool.SYN_REPORT, 0),
			at(1, tool.EV_KEY, KEY_A, 1),
			at(1, tool.EV_KEY, KEY_B, 1),
			at(1, tool.EV_SYN, tool.SYN_REPORT, 0),
			at(2, tool.EV_SYN, tool.SYN_REPORT, 0),
			at(3, tool.EV_SYN, tool.SYN_CONFIG, 0),
			at(3, tool.EV_SYN, tool.SYN_MT_REPORT, 0),
			at(4, tool.EV_LED, 0, 1),
			at(4, tool.EV_SYN, tool.SYN_REPORT, 0),
			at(5, tool.EV_KEY, F23, 1),
			at(5, tool.EV_SYN, tool.SYN_REPORT, 0),
		},
		&got,
	)
	expect_out(t, got[:], {k(KEY_A, 1), k(KEY_B, 1), SYN, Out{tool.EV_LED, 0, 1}, SYN})
}

@(test)
odd_values_count_as_the_kernel_counts_them :: proc(t: ^testing.T) {
	// The input core takes any value but 0 and 2 as a press. Such a Shift is
	// forwarded, but it does not open the window: only a 1 is a macro's.
	tr: tool.Translator
	got := run_keys(&tr, key(0, META, 1), key(1, SHIFT, 5), key(2, F23, 1))
	expect_out(t, got, {k(META, 1), SYN, k(SHIFT, 5), SYN})
	testing.expect(t, tool.bit(&tr.down, SHIFT))
	testing.expect(t, !tr.shift_cancelled)
	// A negative value is a press too, and a code past the keys passes
	// without touching the bitmap.
	got = run_keys(&tr, key(10, KEY_A, -1), key(11, 0xffff, 1))
	expect_out(t, got, {k(KEY_A, -1), SYN, k(0xffff, 1), SYN})
	testing.expect(t, tool.bit(&tr.down, KEY_A))
}

@(test)
a_syn_dropped_throws_away_the_frame_and_asks_for_a_resync :: proc(t: ^testing.T) {
	tr: tool.Translator
	got := make([dynamic]Out, context.temp_allocator)
	feed(&tr, keys(key(0, KEY_A, 1)), &got)
	feed(&tr, {at(1, tool.EV_KEY, KEY_B, 1), at(1, tool.EV_SYN, tool.SYN_DROPPED, 0), at(2, tool.EV_KEY, KEY_A, 0), at(2, tool.EV_SYN, tool.SYN_DROPPED, 0)}, &got)
	testing.expect(t, tr.dropping)
	testing.expect(t, !tr.resync_wanted)
	feed(&tr, {at(3, tool.EV_SYN, tool.SYN_REPORT, 0)}, &got)
	testing.expect(t, !tr.dropping)
	testing.expect(t, tr.resync_wanted)
	// B went out before the drop, A's release was lost in it.
	expect_out(t, got[:], {k(KEY_A, 1), SYN, k(KEY_B, 1)})

	// Now the keyboard holds B and Shift: A is released, Shift pressed, B
	// stays, and the open frame is closed with a report.
	held: tool.Key_Bits
	tool.set_bit(&held, KEY_B, true)
	tool.set_bit(&held, SHIFT, true)
	out: [tool.RESYNC_MAX]tool.Event
	n := tool.resync(&tr, &held, 0, 4000, out[:])
	fixed := make([dynamic]Out, context.temp_allocator)
	for e in out[:n] {
		append(&fixed, Out{e.type, e.code, e.value})
	}
	// In code order: A (30) before Shift (42).
	expect_out(t, fixed[:], {k(KEY_A, 0), k(SHIFT, 1), SYN})
	testing.expect(t, !tr.resync_wanted)
	testing.expect_value(t, tr.pending, 0)
	testing.expect(t, tool.bit(&tr.down, KEY_B))
	testing.expect(t, !tool.bit(&tr.down, KEY_A))
}

@(test)
a_resync_with_nothing_to_fix_writes_nothing :: proc(t: ^testing.T) {
	tr: tool.Translator
	held: tool.Key_Bits
	out: [tool.RESYNC_MAX]tool.Event
	tr.resync_wanted = true
	testing.expect_value(t, tool.resync(&tr, &held, 0, 0, out[:]), 0)
	testing.expect(t, !tr.resync_wanted)
	// Every key held at once: one press each but F23, then the report. F23,
	// Meta and Shift held, none of them seen before, is a lost macro press,
	// so Shift is not pressed either.
	all: tool.Key_Bits
	for &b in all {
		b = 0xff
	}
	n := tool.resync(&tr, &all, 0, 0, out[:])
	testing.expect_value(t, n, tool.KEY_CNT - 1)
	testing.expect(t, tr.shift_cancelled)
	testing.expect(t, !tool.bit(&tr.down, SHIFT))
	testing.expect_value(t, out[n - 1].type, tool.EV_SYN)
	testing.expect(t, !tool.bit(&tr.down, F23))
	testing.expect(t, tr.meta_down)
}

@(test)
a_resync_inside_a_held_macro_keeps_the_shift_cancelled :: proc(t: ^testing.T) {
	tr: tool.Translator
	p := macro_press(0)
	_ = run_keys(&tr, p[0], p[1], p[2])
	testing.expect(t, tr.shift_cancelled)
	held: tool.Key_Bits
	tool.set_bit(&held, META, true)
	tool.set_bit(&held, SHIFT, true)
	tool.set_bit(&held, F23, true)
	out: [tool.RESYNC_MAX]tool.Event
	// The macro is still held: nothing changes, Shift stays released.
	testing.expect_value(t, tool.resync(&tr, &held, 0, 0, out[:]), 0)
	testing.expect(t, tr.shift_cancelled)
	// The key was let go during a drop: the cancel ends, Meta goes up.
	tool.set_bit(&held, META, false)
	tool.set_bit(&held, SHIFT, false)
	tool.set_bit(&held, F23, false)
	n := tool.resync(&tr, &held, 0, 0, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0].code, u16(META))
	testing.expect_value(t, out[0].value, 0)
	testing.expect(t, !tr.shift_cancelled)
	testing.expect(t, !tr.meta_down)
}

@(test)
a_resync_over_a_lost_macro_press_cancels_its_shift :: proc(t: ^testing.T) {
	// The drop swallowed the whole press: the keyboard now holds Meta, Shift
	// and F23, none of which the virtual device has. That is the macro, so
	// Meta goes down and Shift does not; the rest of the hold is Super.
	tr: tool.Translator
	held: tool.Key_Bits
	tool.set_bit(&held, META, true)
	tool.set_bit(&held, SHIFT, true)
	tool.set_bit(&held, F23, true)
	out: [tool.RESYNC_MAX]tool.Event
	n := tool.resync(&tr, &held, 0, 0, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0].code, u16(META))
	testing.expect_value(t, out[0].value, 1)
	testing.expect(t, tr.shift_cancelled)
	r := macro_release(500)
	got := run_keys(&tr, key(300, KEY_A, 1), key(350, KEY_A, 0), r[0], r[1], r[2])
	expect_out(t, got, {k(KEY_A, 1), SYN, k(KEY_A, 0), SYN, k(META, 0), SYN})
	testing.expect(t, !tool.any_down(&tr.down))
}

@(test)
a_resync_keeps_a_real_shift_held_from_before_the_drop :: proc(t: ^testing.T) {
	// The user's Shift was down before the drop, and the Copilot press was
	// lost in it: the Shift is the user's, and stays.
	tr: tool.Translator
	_ = run_keys(&tr, key(0, SHIFT, 1))
	held: tool.Key_Bits
	tool.set_bit(&held, META, true)
	tool.set_bit(&held, SHIFT, true)
	tool.set_bit(&held, F23, true)
	out: [tool.RESYNC_MAX]tool.Event
	n := tool.resync(&tr, &held, 0, 0, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0].code, u16(META))
	testing.expect(t, !tr.shift_cancelled)
	testing.expect(t, tool.bit(&tr.down, SHIFT))
	// And when F23 was already down before the drop, the resync leaves the
	// cancel as it was: here none, since the macro's press was seen whole
	// with the user's Shift held.
	tr2: tool.Translator
	_ = run_keys(&tr2, key(0, SHIFT, 1), key(1000, META, 1), key(1001, SHIFT, 2), key(1002, F23, 1))
	testing.expect_value(t, tool.resync(&tr2, &held, 0, 0, out[:]), 0)
	testing.expect(t, !tr2.shift_cancelled)
}

@(test)
a_resync_without_meta_keeps_the_shift :: proc(t: ^testing.T) {
	// F23 and Shift held, Meta up: no macro, which lets go of F23 before
	// Meta. The Shift is the user's and is pressed.
	tr: tool.Translator
	held: tool.Key_Bits
	tool.set_bit(&held, SHIFT, true)
	tool.set_bit(&held, F23, true)
	out: [tool.RESYNC_MAX]tool.Event
	n := tool.resync(&tr, &held, 0, 0, out[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, out[0].code, u16(SHIFT))
	testing.expect_value(t, out[0].value, 1)
	testing.expect(t, !tr.shift_cancelled)
}

@(test)
a_huge_burst_keeps_its_shape :: proc(t: ^testing.T) {
	// A million frames: a typed letter every 5th, a Copilot press and release
	// every 100th. The output must be exactly what each pattern gives, with
	// nothing held at the end.
	tr: tool.Translator
	ms: i64 = 0
	forwarded := 0
	reports := 0
	f23s := 0
	for i in 0 ..< 200_000 {
		frames: [6][2]tool.Event
		count := 0
		if i % 20 == 0 {
			p := macro_press(ms)
			r := macro_release(ms + 100)
			frames = {p[0], p[1], p[2], r[0], r[1], r[2]}
			count = 6
		} else {
			frames[0] = key(ms, KEY_A, 1)
			frames[1] = key(ms + 30, KEY_A, 0)
			count = 2
		}
		for f in frames[:count] {
			for ev in f {
				out, ok := tool.translate(&tr, ev)
				if !ok {
					continue
				}
				if out.type == tool.EV_SYN {
					reports += 1
				} else {
					forwarded += 1
				}
				if out.code == F23 {
					f23s += 1
				}
			}
		}
		ms += 200
	}
	macros := 200_000 / 20
	letters := 200_000 - macros
	testing.expect_value(t, f23s, 0)
	testing.expect_value(t, forwarded, 2 * letters + 4 * macros)
	testing.expect_value(t, reports, 2 * letters + 4 * macros)
	testing.expect(t, !tool.any_down(&tr.down))
	testing.expect(t, !tr.shift_cancelled)
	testing.expect_value(t, tr.pending, 0)
}
