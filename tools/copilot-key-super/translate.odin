// The translation: one input event in, at most one event out. It holds no
// I/O, so the tests drive it with event sequences (README.md has the cases).
package copilot_key_super

// The event types and codes of linux/input-event-codes.h that this needs.
EV_SYN :: 0x00
EV_KEY :: 0x01
EV_MSC :: 0x04
EV_LED :: 0x11
EV_CNT :: 0x20

SYN_REPORT :: 0
SYN_CONFIG :: 1
SYN_MT_REPORT :: 2
SYN_DROPPED :: 3

KEY_LEFTSHIFT :: 42
KEY_LEFTMETA :: 125
KEY_F23 :: 193
KEY_CNT :: 0x300

MSC_CNT :: 0x08
LED_CNT :: 0x10

// How recently the Shift press must have come for an F23 press to be read as
// the Copilot macro's. The macro's keys arrive about 1 ms apart; a person
// holding Shift and then reaching for the Copilot key is far slower.
SHIFT_WINDOW_US :: 50_000

// Event is struct input_event of linux/input.h on x86_64: a struct timeval
// (two longs), then type, code and value. 24 bytes, as the kernel reads and
// writes them.
Event :: struct {
	sec:   i64,
	usec:  i64,
	type:  u16,
	code:  u16,
	value: i32,
}
#assert(size_of(Event) == 24)
#assert(offset_of(Event, type) == 16)
#assert(offset_of(Event, code) == 18)
#assert(offset_of(Event, value) == 20)

// Key_Bits is a key bitmap as EVIOCGKEY and EVIOCGBIT(EV_KEY) fill it: bit
// n%8 of byte n/8 is key n (the kernel's longs, little-endian).
Key_Bits :: [KEY_CNT / 8]u8

// RESYNC_MAX is the most events resync writes: one per key and a report.
RESYNC_MAX :: KEY_CNT + 1

Translator :: struct {
	// The left Meta is down, as the keyboard reports it.
	meta_down:       bool,
	// When the left Meta and the left Shift were last pressed (value 1), in
	// microseconds of the events' own clock; shift_seen once there was one.
	meta_time:       i64,
	shift_time:      i64,
	shift_seen:      bool,
	// The macro's Shift has been released on the virtual device, so the
	// keyboard's own release of it (and its repeats) are swallowed.
	shift_cancelled: bool,
	// Events are thrown away after a SYN_DROPPED, up to the next report.
	dropping:        bool,
	// That report has come: the caller reads the keyboard's keys and calls
	// resync before the next event.
	resync_wanted:   bool,
	// Events written since the last SYN_REPORT: a frame with none gets no
	// report of its own.
	pending:         int,
	// The keys the virtual device holds down, by what was written to it.
	down:            Key_Bits,
}

bit :: proc "contextless" (bits: ^Key_Bits, code: u16) -> bool {
	if int(code) >= KEY_CNT {
		return false
	}
	return bits[code / 8] & (1 << (code % 8)) != 0
}

set_bit :: proc "contextless" (bits: ^Key_Bits, code: u16, on: bool) {
	if int(code) >= KEY_CNT {
		return
	}
	if on {
		bits[code / 8] |= 1 << (code % 8)
	} else {
		bits[code / 8] &~= 1 << (code % 8)
	}
}

any_down :: proc "contextless" (bits: ^Key_Bits) -> bool {
	for b in bits {
		if b != 0 {
			return true
		}
	}
	return false
}

micros :: proc "contextless" (ev: Event) -> i64 {
	return ev.sec * 1_000_000 + ev.usec
}

// emit counts ev into the open frame and the virtual device's keys, as the
// input core counts it: a 2 is a repeat and changes nothing, a 0 releases,
// anything else presses.
emit :: proc "contextless" (t: ^Translator, ev: Event) -> (Event, bool) {
	t.pending += 1
	if ev.type == EV_KEY && ev.value != 2 {
		set_bit(&t.down, ev.code, ev.value != 0)
	}
	return ev, true
}

// translate takes the keyboard's next event and returns what goes to the
// virtual device, if anything. It is the Python daemon's filter, with the
// changes README.md lists:
//
//   * F23 is never forwarded; nothing but the Copilot key sends it.
//   * An F23 press with the left Meta down, and a left Shift press (value 1)
//     that came after the last Meta press and less than SHIFT_WINDOW_US
//     before the F23, is the macro: the Shift is released on the virtual
//     device, and the keyboard's own release and repeats of it are
//     swallowed. A Shift the user already held arrives as a repeat (atkbd
//     reports a press of a key that is down as 2), so it opens no window.
//   * A new Shift press ends the cancel: it and its release go through.
//   * Frames keep the keyboard's bounds; a frame left empty gets no report.
translate :: proc "contextless" (t: ^Translator, ev: Event) -> (out: Event, ok: bool) {
	if t.dropping {
		if ev.type == EV_SYN && ev.code == SYN_REPORT {
			t.dropping = false
			t.resync_wanted = true
		}
		return {}, false
	}
	switch ev.type {
	case EV_SYN:
		switch ev.code {
		case SYN_REPORT:
			if t.pending == 0 {
				return {}, false
			}
			t.pending = 0
			return ev, true
		case SYN_DROPPED:
			// The kernel lost events: everything up to the next report is
			// stale (Documentation/input/event-codes.rst).
			t.dropping = true
		}
		// SYN_CONFIG and SYN_MT_REPORT: no keyboard sends them.
		return {}, false
	case EV_KEY:
		switch ev.code {
		case KEY_F23:
			if ev.value == 1 && t.meta_down && t.shift_seen && t.shift_time >= t.meta_time {
				since := micros(ev) - t.shift_time
				if since >= 0 && since < SHIFT_WINDOW_US {
					t.shift_cancelled = true
					return emit(t, Event{sec = ev.sec, usec = ev.usec, type = EV_KEY, code = KEY_LEFTSHIFT, value = 0})
				}
			}
			return {}, false
		case KEY_LEFTSHIFT:
			switch ev.value {
			case 1:
				t.shift_time = micros(ev)
				t.shift_seen = true
				t.shift_cancelled = false
			case 0:
				if t.shift_cancelled {
					t.shift_cancelled = false
					return {}, false
				}
			case 2:
				if t.shift_cancelled {
					return {}, false
				}
			}
		case KEY_LEFTMETA:
			if ev.value == 1 {
				t.meta_time = micros(ev)
			}
			t.meta_down = ev.value != 0
		}
	}
	return emit(t, ev)
}

// resync is the end of a SYN_DROPPED: held is the keyboard's keys as
// EVIOCGKEY reads them now. It writes into out (at least RESYNC_MAX long) the
// presses and releases that bring the virtual device to that state, and a
// report, and returns how many. F23 stays hidden, and a cancelled Shift stays
// released while F23 is still down, since that is the macro still held.
resync :: proc "contextless" (t: ^Translator, held: ^Key_Bits, sec, usec: i64, out: []Event) -> int {
	t.resync_wanted = false
	if !bit(held, KEY_F23) {
		t.shift_cancelled = false
	}
	t.meta_down = bit(held, KEY_LEFTMETA)
	n := 0
	for code in u16(0) ..< KEY_CNT {
		if code == KEY_F23 {
			continue
		}
		want := bit(held, code) && !(code == KEY_LEFTSHIFT && t.shift_cancelled)
		if want != bit(&t.down, code) {
			out[n], _ = emit(t, Event{sec = sec, usec = usec, type = EV_KEY, code = code, value = 1 if want else 0})
			n += 1
		}
	}
	if t.pending > 0 {
		t.pending = 0
		out[n] = Event{sec = sec, usec = usec, type = EV_SYN, code = SYN_REPORT}
		n += 1
	}
	return n
}
