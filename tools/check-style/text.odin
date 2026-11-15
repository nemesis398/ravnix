package check_style

import "core:strings"

// The byte classes of the rules. The Bash version ran in the C locale, so
// every class is ASCII: a byte of 0x80 or more is no letter, no digit and
// no white space.

is_alpha :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// [[:alnum:]]
is_alnum :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c)
}

// [[:alnum:]_-], the bytes of a word, a key or a number that runs on.
is_word :: proc(c: u8) -> bool {
	return is_alnum(c) || c == '_' || c == '-'
}

// [[:space:]]
is_space :: proc(c: u8) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r')
}

// [ \t]
is_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

is_hex :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

is_quote :: proc(c: u8) -> bool {
	return c == '"' || c == '\''
}

// Whether the byte i of s exists and is in the class.
is_at :: proc(s: string, i: int, class: proc(c: u8) -> bool) -> bool {
	return i >= 0 && i < len(s) && class(s[i])
}

// The index after the white space that starts at i.
skip_space :: proc(s: string, i: int) -> int {
	i := i
	for i < len(s) && is_space(s[i]) {
		i += 1
	}
	return i
}

// The index after one optional quote at i.
skip_quote :: proc(s: string, i: int) -> int {
	if i < len(s) && is_quote(s[i]) {
		return i + 1
	}
	return i
}

// The length of the run of hex digits that starts at i.
hex_run :: proc(s: string, i: int) -> int {
	n := 0
	for i + n < len(s) && is_hex(s[i + n]) {
		n += 1
	}
	return n
}

all_digits :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if !is_digit(s[i]) {
			return false
		}
	}
	return true
}

all_blank :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if !is_blank(s[i]) {
			return false
		}
	}
	return true
}

lower_byte :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

// lower_into puts s in ASCII lower case into buf, which it clears first, and
// returns it as a string of the same length. The string lives until the next
// call that clears buf.
lower_into :: proc(buf: ^[dynamic]u8, s: string) -> string {
	clear(buf)
	resize(buf, len(s))
	for i in 0 ..< len(s) {
		buf[i] = lower_byte(s[i])
	}
	return string(buf[:])
}

// Whether s has word at index i.
has_at :: proc(s: string, i: int, word: string) -> bool {
	return i >= 0 && i + len(word) <= len(s) && s[i:i + len(word)] == word
}

// The index of the first byte of s from i on that is in the set, or -1.
index_any_from :: proc(s: string, i: int, set: string) -> int {
	for k := i; k < len(s); k += 1 {
		if strings.index_byte(set, s[k]) >= 0 {
			return k
		}
	}
	return -1
}

// The index of the first occurrence of word in s from i on, or -1.
index_from :: proc(s: string, i: int, word: string) -> int {
	if i > len(s) {
		return -1
	}
	k := strings.index(s[i:], word)
	if k < 0 {
		return -1
	}
	return i + k
}

// Whether the digit string v is below the full value: below 1, or below
// 100 % when it ends in %. The shapes are those of a CSS or config number,
// 0.9 .5 1. 90%, and nothing else is a number.
below_one :: proc(v: string) -> bool {
	body := v
	percent := false
	if strings.has_suffix(v, "%") {
		percent = true
		body = v[:len(v) - 1]
	}
	dot := strings.index_byte(body, '.')
	whole, fraction := body, ""
	if dot >= 0 {
		whole, fraction = body[:dot], body[dot + 1:]
	}
	if !all_digits(whole) || !all_digits(fraction) {
		return false
	}
	// [0-9]*\.?[0-9]+ or [0-9]+\.
	valid := (dot < 0 && len(whole) > 0) || (dot >= 0 && (len(fraction) > 0 || len(whole) > 0))
	if !valid {
		return false
	}
	// The whole part decides: 0 is below 1, up to 99 is below 100.
	significant := strings.trim_left(whole, "0")
	return len(significant) <= (2 if percent else 0)
}

// [a-z-]
is_letter_or_dash :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || c == '-'
}

// unicode_space_at is the length in bytes of the white space character that
// starts at s[i], or 0. White space is the Unicode White_Space property, what
// ripgrep's \s matches: the ASCII white space, U+0085, U+00A0, U+1680,
// U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F and U+3000, read from
// UTF-8. A byte that starts no complete valid sequence of these is none.
//
// The Bash version took three searches from ripgrep (the key of a motion
// rule, the separator after it, and a color property's colon), so they see
// this white space and not only the ASCII one of [[:space:]].
unicode_space_at :: proc(s: string, i: int) -> int {
	if i < 0 || i >= len(s) {
		return 0
	}
	c := s[i]
	if c < 0x80 {
		return 1 if is_space(c) else 0
	}
	rest := len(s) - i
	switch c {
	case 0xC2:
		// U+0085, U+00A0
		if rest >= 2 && (s[i + 1] == 0x85 || s[i + 1] == 0xA0) {
			return 2
		}
	case 0xE1:
		// U+1680
		if rest >= 3 && s[i + 1] == 0x9A && s[i + 2] == 0x80 {
			return 3
		}
	case 0xE2:
		if rest >= 3 {
			b, d := s[i + 1], s[i + 2]
			// U+2000 to U+200A, U+2028, U+2029, U+202F
			if b == 0x80 && ((d >= 0x80 && d <= 0x8A) || d == 0xA8 || d == 0xA9 || d == 0xAF) {
				return 3
			}
			// U+205F
			if b == 0x81 && d == 0x9F {
				return 3
			}
		}
	case 0xE3:
		// U+3000
		if rest >= 3 && s[i + 1] == 0x80 && s[i + 2] == 0x80 {
			return 3
		}
	}
	return 0
}

// The index after the white space (Unicode, see unicode_space_at) that
// starts at i.
skip_unicode_space :: proc(s: string, i: int) -> int {
	i := i
	for {
		n := unicode_space_at(s, i)
		if n == 0 {
			return i
		}
		i += n
	}
}
