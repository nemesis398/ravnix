// Just enough JSON to change one value of a file and keep every other byte:
// a scanner that checks a document and finds where a member's value is, and
// the strings of an array of strings. core:encoding/json parses into maps,
// which lose the order of the keys and every byte of the layout, so writing
// Handy's settings back through it would rewrite all of them.
package adapters

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// A value's place in the text: text[start:end] is the value.
Span :: struct {
	start, end: int,
}

// A member of an object: its key, decoded, and the spans of the key and
// of the value.
Member :: struct {
	key:   string,
	key_s: Span,
	value: Span,
}

// MAX_DEPTH is how deep arrays and objects may nest; more is no settings
// file, and would only use up the stack.
MAX_DEPTH :: 256

Scanner :: struct {
	text: string,
	pos:  int,
	why:  string,
}

@(private)
fail :: proc(s: ^Scanner, what: string) -> bool {
	if s.why == "" {
		s.why = fmt.tprintf("%s at byte %d", what, s.pos)
	}
	return false
}

@(private)
skip_space :: proc(s: ^Scanner) {
	for s.pos < len(s.text) {
		switch s.text[s.pos] {
		case ' ', '\t', '\n', '\r':
			s.pos += 1
		case:
			return
		}
	}
}

// skip_value checks the value at the scanner's position and moves past it.
@(private)
skip_value :: proc(s: ^Scanner, depth: int) -> bool {
	skip_space(s)
	if s.pos >= len(s.text) {
		return fail(s, "the text ends where a value should be")
	}
	if depth > MAX_DEPTH {
		return fail(s, "values nest too deep")
	}
	switch c := s.text[s.pos]; c {
	case '{':
		s.pos += 1
		skip_space(s)
		if s.pos < len(s.text) && s.text[s.pos] == '}' {
			s.pos += 1
			return true
		}
		for {
			skip_space(s)
			if !skip_string(s) {
				return fail(s, "an object's key is not a string")
			}
			skip_space(s)
			if s.pos >= len(s.text) || s.text[s.pos] != ':' {
				return fail(s, "a key is not followed by :")
			}
			s.pos += 1
			if !skip_value(s, depth + 1) {
				return false
			}
			skip_space(s)
			if s.pos >= len(s.text) {
				return fail(s, "an object is not closed")
			}
			if s.text[s.pos] == ',' {
				s.pos += 1
				continue
			}
			if s.text[s.pos] == '}' {
				s.pos += 1
				return true
			}
			return fail(s, "an object's members are not separated by ,")
		}
	case '[':
		s.pos += 1
		skip_space(s)
		if s.pos < len(s.text) && s.text[s.pos] == ']' {
			s.pos += 1
			return true
		}
		for {
			if !skip_value(s, depth + 1) {
				return false
			}
			skip_space(s)
			if s.pos >= len(s.text) {
				return fail(s, "an array is not closed")
			}
			if s.text[s.pos] == ',' {
				s.pos += 1
				continue
			}
			if s.text[s.pos] == ']' {
				s.pos += 1
				return true
			}
			return fail(s, "an array's values are not separated by ,")
		}
	case '"':
		return skip_string(s)
	case 't', 'f', 'n':
		for lit in ([]string{"true", "false", "null"}) {
			if strings.has_prefix(s.text[s.pos:], lit) {
				s.pos += len(lit)
				return true
			}
		}
		return fail(s, "an unknown word")
	case '-', '0' ..= '9':
		digits := 0
		for s.pos < len(s.text) {
			switch s.text[s.pos] {
			case '0' ..= '9':
				digits += 1
				s.pos += 1
			case '-', '+', '.', 'e', 'E':
				s.pos += 1
			case:
				return digits > 0 || fail(s, "a number without digits")
			}
		}
		return digits > 0 || fail(s, "a number without digits")
	}
	return fail(s, "no value")
}

// skip_string checks the string at the scanner's position and moves past
// it: no control character inside, and only JSON's escapes.
@(private)
skip_string :: proc(s: ^Scanner) -> bool {
	if s.pos >= len(s.text) || s.text[s.pos] != '"' {
		return false
	}
	s.pos += 1
	for s.pos < len(s.text) {
		c := s.text[s.pos]
		switch {
		case c == '"':
			s.pos += 1
			return true
		case c < 0x20:
			return fail(s, "a string holds a control character")
		case c == '\\':
			if s.pos + 1 >= len(s.text) {
				return fail(s, "a string ends in an escape")
			}
			switch s.text[s.pos + 1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				s.pos += 2
			case 'u':
				if s.pos + 6 > len(s.text) {
					return fail(s, "a string ends in an escape")
				}
				for h in s.text[s.pos + 2:s.pos + 6] {
					if hex(u8(h)) < 0 {
						return fail(s, "a \\u escape is not four hex digits")
					}
				}
				s.pos += 6
			case:
				return fail(s, "a string holds an unknown escape")
			}
		case:
			s.pos += 1
		}
	}
	return fail(s, "a string is not closed")
}

@(private)
hex :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}

// check_document checks that text is one JSON object, UTF-8, with only
// white space after it, and returns its span.
check_document :: proc(text: string) -> (Span, string) {
	if !utf8.valid_string(text) {
		return {}, "it is not UTF-8"
	}
	s := Scanner{text = text}
	skip_space(&s)
	start := s.pos
	if s.pos >= len(text) || text[s.pos] != '{' {
		return {}, "it is not a JSON object"
	}
	if !skip_value(&s, 0) {
		return {}, fmt.tprintf("it is not JSON: %s", s.why)
	}
	end := s.pos
	skip_space(&s)
	if s.pos != len(text) {
		return {}, fmt.tprintf("it is not JSON: something follows the object at byte %d", s.pos)
	}
	return Span{start, end}, ""
}

// members is the members of the object at span, which check_document has
// checked, in the order of the text.
members :: proc(text: string, object: Span) -> []Member {
	out := make([dynamic]Member, context.temp_allocator)
	s := Scanner{text = text, pos = object.start + 1}
	for {
		skip_space(&s)
		if s.text[s.pos] == '}' {
			break
		}
		if s.text[s.pos] == ',' {
			s.pos += 1
			skip_space(&s)
		}
		m: Member
		m.key_s.start = s.pos
		skip_string(&s)
		m.key_s.end = s.pos
		m.key, _ = decode_string(text[m.key_s.start:m.key_s.end])
		skip_space(&s)
		s.pos += 1 // the colon
		skip_space(&s)
		m.value.start = s.pos
		skip_value(&s, 0)
		m.value.end = s.pos
		append(&out, m)
	}
	return out[:]
}

// member is the last member of the object named key, as serde_json takes
// the last of two members with one key; found is false when there is none.
member :: proc(text: string, object: Span, key: string) -> (m: Member, found: bool) {
	for x in members(text, object) {
		if x.key == key {
			m, found = x, true
		}
	}
	return
}

// decode_string decodes a JSON string, quotes included, which skip_string
// has checked. A \u escape that is half of a surrogate pair without its
// other half is refused, as serde_json refuses it.
decode_string :: proc(raw: string) -> (string, bool) {
	inner := raw[1:len(raw) - 1]
	if strings.index_byte(inner, '\\') < 0 {
		return inner, true
	}
	b := strings.builder_make(0, len(inner), context.temp_allocator)
	for i := 0; i < len(inner); {
		c := inner[i]
		if c != '\\' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		e := inner[i + 1]
		i += 2
		switch e {
		case '"':
			strings.write_byte(&b, '"')
		case '\\':
			strings.write_byte(&b, '\\')
		case '/':
			strings.write_byte(&b, '/')
		case 'b':
			strings.write_byte(&b, '\b')
		case 'f':
			strings.write_byte(&b, '\f')
		case 'n':
			strings.write_byte(&b, '\n')
		case 'r':
			strings.write_byte(&b, '\r')
		case 't':
			strings.write_byte(&b, '\t')
		case 'u':
			unit := code_unit(inner[i:i + 4])
			i += 4
			r := rune(unit)
			if unit >= 0xd800 && unit < 0xdc00 {
				if i + 6 > len(inner) || inner[i] != '\\' || inner[i + 1] != 'u' {
					return "", false
				}
				low := code_unit(inner[i + 2:i + 6])
				if low < 0xdc00 || low >= 0xe000 {
					return "", false
				}
				i += 6
				r = rune(0x10000 + (unit - 0xd800) << 10 + (low - 0xdc00))
			} else if unit >= 0xdc00 && unit < 0xe000 {
				return "", false
			}
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b), true
}

@(private)
code_unit :: proc(h: string) -> int {
	n := 0
	for i in 0 ..< 4 {
		n = n * 16 + hex(h[i])
	}
	return n
}

// encode_string writes s as a JSON string as serde_json does: a quote, a
// backslash and a control character escaped, everything else as it is.
encode_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case:
			if c < 0x20 {
				fmt.sbprintf(b, `\u%04x`, c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// string_array is the strings of the array at span; why says what is
// wrong when it is no array of strings.
string_array :: proc(text: string, span: Span) -> (words: []string, why: string) {
	if text[span.start] != '[' {
		return nil, "it is not an array"
	}
	out := make([dynamic]string)
	s := Scanner{text = text, pos = span.start + 1}
	for {
		skip_space(&s)
		if s.text[s.pos] == ']' {
			break
		}
		if s.text[s.pos] == ',' {
			s.pos += 1
			skip_space(&s)
		}
		if s.text[s.pos] != '"' {
			return nil, "it holds a value that is not a string"
		}
		start := s.pos
		skip_string(&s)
		w, ok := decode_string(text[start:s.pos])
		if !ok {
			return nil, "a string holds half of a surrogate pair"
		}
		append(&out, strings.clone(w))
	}
	return out[:], ""
}

// indent_of is the white space at the start of the line that holds pos.
indent_of :: proc(text: string, pos: int) -> string {
	start := strings.last_index_byte(text[:pos], '\n') + 1
	end := start
	for end < pos && (text[end] == ' ' || text[end] == '\t') {
		end += 1
	}
	return text[start:end]
}
