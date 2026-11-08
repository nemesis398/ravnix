package ravnix_notify

import "core:encoding/json"
import "core:strings"

// An event may not be larger than 65536 bytes of canonical JSON, with the
// fields the homeserver adds around it. The tool refuses a message whose
// event is over this, and does not cut it: a notification that loses its end
// says something other than what the sender wrote.
MAX_EVENT_BYTES :: 60000

Event_Error :: enum {
	None,
	Too_Large,
	Encode,
}

// The message event the tool sends. m.text and not m.notice: the default
// push rules of Matrix suppress notifications for m.notice, and a
// notification that does not reach the phone is no notification.
@(private = "file")
Event :: struct {
	msgtype:        string,
	body:           string,
	format:         string,
	formatted_body: string,
}

// Read-only: a constant cannot be indexed by a variable, and a plain global
// could be written.
@(rodata)
HEX := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'}

// percent_encode is s as one segment of a URL path: everything but the
// unreserved characters of RFC 3986 becomes %XX, byte by byte, so a room id
// (!abc:server) cannot end the segment or start a query.
percent_encode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(s), allocator)
	for c in transmute([]byte)s {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.', '_', '~':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX[c >> 4])
			strings.write_byte(&b, HEX[c & 15])
		}
	}
	return strings.to_string(b)
}

// curl_quote is s as the inside of a quoted value in curl's config file: a
// backslash and a double quote are escaped. A control character is refused
// (ok is false), because a line break would end the value and start a line
// of the sender's choosing, an option of curl. The caller adds the quotes.
curl_quote :: proc(s: string, allocator := context.allocator) -> (quoted: string, ok: bool) {
	for c in transmute([]byte)s {
		if c < 0x20 || c == 0x7f {
			return "", false
		}
	}
	b := strings.builder_make(0, len(s) + 8, allocator)
	for c in transmute([]byte)s {
		if c == '"' || c == '\\' {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b), true
}

// build_event is the JSON of the m.room.message event for message: the
// message itself as body, and its Markdown rendered as formatted_body. Bytes
// that are not UTF-8 become U+FFFD, since JSON has no such bytes and a log
// excerpt can end in the middle of a character.
build_event :: proc(message: string, allocator := context.allocator) -> (text: string, err: Event_Error) {
	clean, aerr := strings.to_valid_utf8(message, "�", allocator)
	if aerr != nil {
		return "", .Encode
	}
	defer delete(clean, allocator)
	html := render_markdown(clean, allocator)
	defer delete(html, allocator)
	data, merr := json.marshal(Event{"m.text", clean, "org.matrix.custom.html", html}, {}, allocator)
	if merr != nil {
		return "", .Encode
	}
	if len(data) > MAX_EVENT_BYTES {
		delete(data, allocator)
		return "", .Too_Large
	}
	return string(data), .None
}
