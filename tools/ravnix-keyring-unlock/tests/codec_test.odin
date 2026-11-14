// The wire format and the bus address: what the tool writes must be what a
// bus reads, and what a peer sends that the format does not allow must be
// refused, never read past.
package ravnix_keyring_unlock_tests

import "core:testing"
import kr ".."

@(test)
finds_the_socket_of_a_session_bus_address :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"unix:path=/run/user/1000/bus", "/run/user/1000/bus"},
		{"unix:path=/run/user/1000/bus,guid=0123456789abcdef", "/run/user/1000/bus"},
		{"unix:guid=01,path=/tmp/b", "/tmp/b"},
		{"tcp:host=localhost,port=1;unix:path=/tmp/second", "/tmp/second"},
		{"unix:path=/tmp/with%20space%2c", "/tmp/with space,"},
	}
	for c in cases {
		path, why := kr.socket_path(c[0], context.temp_allocator)
		testing.expectf(t, why == "", "%s: %s", c[0], why)
		testing.expect_value(t, path, c[1])
	}
}

@(test)
refuses_an_address_it_cannot_use :: proc(t: ^testing.T) {
	long := "unix:path=/" + "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678"
	cases := []string {
		"",
		"unix:abstract=/tmp/dbus-x",
		"tcp:host=localhost,port=1",
		"unix:path=",
		"unix:path=/tmp/a%2",
		"unix:path=/tmp/a%zz",
		"unix:path",
		"nocolon",
		long,
	}
	for c in cases {
		path, why := kr.socket_path(c, context.temp_allocator)
		testing.expectf(t, why != "" && path == "", "%q was taken as %q", c, path)
	}
}

@(test)
falls_back_to_the_runtime_dir_socket :: proc(t: ^testing.T) {
	testing.expect_value(t, kr.default_address("unix:path=/x", "/run/user/1", context.temp_allocator), "unix:path=/x")
	testing.expect_value(t, kr.default_address("", "/run/user/1", context.temp_allocator), "unix:path=/run/user/1/bus")
	testing.expect_value(t, kr.default_address("", "", context.temp_allocator), "")
}

// A method call as the tool sends it, read back by the decoder, both byte
// orders, with the layout the specification fixes checked byte by byte.
@(test)
encodes_what_it_decodes :: proc(t: ^testing.T) {
	for big in ([]bool{false, true}) {
		body := make([dynamic]u8, context.temp_allocator)
		w := kr.Writer {
			buf = &body,
			big = big,
		}
		kr.put_string(w, "org.freedesktop.Secret.Collection")
		kr.put_string(w, "Locked")
		out := make([dynamic]u8, context.temp_allocator)
		kr.encode(
			kr.Message {
				type = .Method_Call,
				serial = 7,
				destination = "org.freedesktop.secrets",
				path = kr.LOGIN_COLLECTION,
				interface = "org.freedesktop.DBus.Properties",
				member = "Get",
				signature = "ss",
				body = body[:],
				big_endian = big,
			},
			&out,
		)
		testing.expect_value(t, out[0], u8('B' if big else 'l'))
		testing.expect_value(t, out[1], u8(1))
		testing.expect_value(t, out[3], u8(1))
		// The body starts at a multiple of 8 and is the last thing.
		testing.expect_value(t, (len(out) - len(body)) % 8, 0)
		size, swhy := kr.message_size(out[:16])
		testing.expect_value(t, swhy, "")
		testing.expect_value(t, size, len(out))
		m, why := kr.decode(out[:])
		testing.expect_value(t, why, "")
		testing.expect_value(t, m.type, kr.Message_Type.Method_Call)
		testing.expect_value(t, m.serial, u32(7))
		testing.expect_value(t, m.destination, "org.freedesktop.secrets")
		testing.expect_value(t, m.path, kr.LOGIN_COLLECTION)
		testing.expect_value(t, m.interface, "org.freedesktop.DBus.Properties")
		testing.expect_value(t, m.member, "Get")
		testing.expect_value(t, m.signature, "ss")
		testing.expect_value(t, m.big_endian, big)
		r := kr.Reader {
			data = m.body,
			big  = m.big_endian,
		}
		testing.expect_value(t, kr.get_string(&r), "org.freedesktop.Secret.Collection")
		testing.expect_value(t, kr.get_string(&r), "Locked")
		testing.expect(t, !r.bad)
		testing.expect_value(t, r.pos, len(m.body))
	}
}

// The bytes of a Hello call, as the specification lays them out: the fixed
// header, then PATH, MEMBER and DESTINATION, each a struct at a multiple of
// 8, the array's length (77) counting from its first struct to the end of
// the last, and no body.
@(test)
lays_out_a_hello_as_the_specification_does :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	kr.encode(
		kr.Message {
			type = .Method_Call,
			serial = 1,
			destination = "org.freedesktop.DBus",
			path = "/org/freedesktop/DBus",
			member = "Hello",
		},
		&out,
	)
	want := []u8 {
		'l', 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 77, 0, 0, 0,
		// PATH: code, signature "o", the path's length 21, the path, NUL
		1, 1, 'o', 0, 21, 0, 0, 0,
		'/', 'o', 'r', 'g', '/', 'f', 'r', 'e', 'e', 'd', 'e', 's', 'k', 't', 'o', 'p', '/', 'D', 'B', 'u', 's', 0,
		0, 0, // padding to 48
		// MEMBER
		3, 1, 's', 0, 5, 0, 0, 0, 'H', 'e', 'l', 'l', 'o', 0,
		0, 0, // padding to 64
		// DESTINATION
		6, 1, 's', 0, 20, 0, 0, 0,
		'o', 'r', 'g', '.', 'f', 'r', 'e', 'e', 'd', 'e', 's', 'k', 't', 'o', 'p', '.', 'D', 'B', 'u', 's', 0,
		0, 0, 0, // padding to 96: the header ends at a multiple of 8
	}
	testing.expect_value(t, len(out), len(want))
	if len(out) == len(want) {
		for b, i in want {
			testing.expectf(t, out[i] == b, "byte %d is %d, not %d", i, out[i], b)
		}
	}
}

// A reply as a bus sends it: the variant of a property, read back.
@(test)
reads_a_variant_reply :: proc(t: ^testing.T) {
	for big in ([]bool{false, true}) {
		body := make([dynamic]u8, context.temp_allocator)
		w := kr.Writer {
			buf = &body,
			big = big,
		}
		kr.put_signature(w, "b")
		kr.put_u32(w, 1)
		out := make([dynamic]u8, context.temp_allocator)
		kr.encode(
			kr.Message{type = .Method_Return, serial = 9, reply_serial = 3, signature = "v", body = body[:], big_endian = big},
			&out,
		)
		m, why := kr.decode(out[:])
		testing.expect_value(t, why, "")
		testing.expect_value(t, m.reply_serial, u32(3))
		r := kr.Reader {
			data = m.body,
			big  = m.big_endian,
		}
		testing.expect_value(t, kr.get_signature(&r), "b")
		testing.expect_value(t, kr.get_bool(&r), true)
		testing.expect(t, !r.bad)
	}
}

// encode_reply makes a reply's bytes for the malformation tests to change.
encode_reply :: proc() -> [dynamic]u8 {
	body := make([dynamic]u8, context.temp_allocator)
	kr.put_string(kr.Writer{buf = &body}, "hi")
	out := make([dynamic]u8, context.temp_allocator)
	kr.encode(kr.Message{type = .Method_Return, serial = 2, reply_serial = 1, signature = "s", body = body[:]}, &out)
	return out
}

@(test)
refuses_a_malformed_message :: proc(t: ^testing.T) {
	good := encode_reply()
	m, why := kr.decode(good[:])
	testing.expect_value(t, why, "")
	testing.expect_value(t, m.signature, "s")

	Change :: struct {
		name: string,
		at:   int,
		to:   u8,
	}
	changes := []Change {
		{"no byte order", 0, 'x'},
		{"version 2", 3, 2},
		{"type 9", 1, 9},
		{"serial 0", 8, 0},
		{"body longer than the data", 4, 200},
		{"fields longer than the data", 12, 250},
		{"a field's signature not NUL-terminated", 19, 'x'},
		{"a container in a field", 18, '('},
		{"a reply serial typed as a string", 18, 's'},
	}
	for c in changes {
		bad := make([dynamic]u8, context.temp_allocator)
		append(&bad, ..good[:])
		bad[c.at] = c.to
		_, w := kr.decode(bad[:])
		testing.expectf(t, w != "", "%s: decoded", c.name)
	}
	// Truncated anywhere.
	for n in 0 ..< len(good) {
		_, w := kr.decode(good[:n])
		testing.expectf(t, w != "", "truncated to %d bytes: decoded", n)
	}
	// A reply that names no call.
	out := make([dynamic]u8, context.temp_allocator)
	kr.encode(kr.Message{type = .Error, serial = 2, reply_serial = 0, error_name = "x.Y"}, &out)
	_, w := kr.decode(out[:])
	testing.expect(t, w != "")
	// A body without a signature.
	clear(&out)
	kr.encode(kr.Message{type = .Method_Return, serial = 2, reply_serial = 1, body = []u8{1, 2, 3, 4}}, &out)
	_, w = kr.decode(out[:])
	testing.expect(t, w != "")
}

@(test)
refuses_a_message_too_large :: proc(t: ^testing.T) {
	head := []u8{'l', 2, 0, 1, 0, 0, 0x20, 0, 1, 0, 0, 0, 0, 0, 0, 0}
	_, why := kr.message_size(head)
	testing.expect(t, why != "")
	head2 := []u8{'B', 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0xff, 0xff, 0xf0}
	_, why = kr.message_size(head2)
	testing.expect(t, why != "")
}

@(test)
reader_never_reads_past_the_end :: proc(t: ^testing.T) {
	// A string whose length runs past the data.
	r := kr.Reader {
		data = []u8{0xff, 0xff, 0xff, 0x7f, 'a', 0},
	}
	testing.expect_value(t, kr.get_string(&r), "")
	testing.expect(t, r.bad)
	// A string without its NUL.
	r = kr.Reader {
		data = []u8{1, 0, 0, 0, 'a', 'b'},
	}
	kr.get_string(&r)
	testing.expect(t, r.bad)
	// A boolean that is neither 0 nor 1.
	r = kr.Reader {
		data = []u8{2, 0, 0, 0},
	}
	kr.get_bool(&r)
	testing.expect(t, r.bad)
	// An array of bytes longer than the data.
	r = kr.Reader {
		data = []u8{9, 0, 0, 0, 1, 2},
	}
	testing.expect(t, kr.get_bytes(&r) == nil)
	testing.expect(t, r.bad)
	// After the first bad read, every read returns nothing.
	testing.expect_value(t, kr.get_u32(&r), u32(0))
	testing.expect_value(t, kr.get_u8(&r), u8(0))
}

@(test)
keeps_a_peer_s_text_on_one_line :: proc(t: ^testing.T) {
	testing.expect_value(t, kr.printable("a\nb\x1b[31m"), "a?b?[31m")
	long := kr.printable("0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789")
	testing.expect_value(t, len(long), 200)
}

// Two messages in one buffer: the second is aligned from its own start,
// not the buffer's, whatever length the first has.
@(test)
aligns_each_message_from_its_own_start :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	body := []u8{'x', 0, 0, 0, 'y'}
	kr.encode(kr.Message{type = .Method_Return, serial = 1, reply_serial = 1, signature = "ay", body = body}, &out)
	first := len(out)
	testing.expect(t, first % 8 != 0)
	kr.encode(kr.Message{type = .Method_Return, serial = 2, reply_serial = 9, signature = "s", body = body}, &out)
	m, why := kr.decode(out[first:])
	testing.expect_value(t, why, "")
	testing.expect_value(t, m.reply_serial, u32(9))
}
