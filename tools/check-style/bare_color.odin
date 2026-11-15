package check_style

import "core:strings"

// A bare RRGGBB or RRGGBBAA value of a color key, as fuzzel and swaylock
// write them (`background=1e1e2eff`, `ring-color = "585b70";`): a hex color
// outside the theme module, and a translucent one. It is the last
// assignment of the line, and its key says it is a color.

check_bare_color :: proc(j: ^Judge) {
	if j.is_comment {
		return
	}
	s := j.lower
	// Back from the end of the line: blanks, one ; or ,, blanks, a quote,
	// the digits, a quote, blanks, = or :, blanks, a quote, the key.
	e := len(s)
	for e > 0 && is_space(s[e - 1]) {
		e -= 1
	}
	if e > 0 && (s[e - 1] == ';' || s[e - 1] == ',') {
		e -= 1
	}
	for e > 0 && is_space(s[e - 1]) {
		e -= 1
	}
	if e > 0 && is_quote(s[e - 1]) {
		e -= 1
	}
	d := e
	for d > 0 && is_hex(s[d - 1]) {
		d -= 1
	}
	value := s[d:e]
	if len(value) != 6 && len(value) != 8 {
		return
	}
	i := d
	if i > 0 && is_quote(s[i - 1]) {
		i -= 1
	}
	for i > 0 && is_space(s[i - 1]) {
		i -= 1
	}
	if i == 0 || (s[i - 1] != '=' && s[i - 1] != ':') {
		return
	}
	i -= 1
	for i > 0 && is_space(s[i - 1]) {
		i -= 1
	}
	if i > 0 && is_quote(s[i - 1]) {
		i -= 1
	}
	k := i
	for k > 0 && is_key_byte(s[k - 1]) {
		k -= 1
	}
	// The key starts with a letter, and no byte of a word is before it.
	if k == i || !is_alpha(s[k]) {
		return
	}
	key := s[k:i]
	if !is_color_key(key) {
		return
	}
	// Six digits and no letter is a number, unless it is one of the two
	// colors of Mocha that have no letter.
	if len(value) == 6 && all_digits(value) && value != "181825" && value != "313244" {
		return
	}
	// Letters and no digit is a word (facade, deadbeef), unless every byte is
	// a doubled digit, as #fed expands to ffeedd.
	if all_letters_a_to_f(value) && !doubled_digits(value) {
		return
	}
	if !hex_allowed(j.file) {
		add_hit(j, .Hex_Color)
	}
	if len(value) != 8 || value[6:] == "ff" {
		return
	}
	// The inside of the lock ring and its separator are the places a color
	// may be see-through.
	if key == "inside-color" || (strings.has_prefix(key, "inside-") && strings.has_suffix(key, "-color")) {
		return
	}
	if key == "separator-color" && value[6:] == "00" {
		return
	}
	add_hit(j, .Opacity)
}

all_letters_a_to_f :: proc(v: string) -> bool {
	for i in 0 ..< len(v) {
		if v[i] < 'a' || v[i] > 'f' {
			return false
		}
	}
	return len(v) > 0
}

// Whether every byte of the hex digits v is one digit twice (ffeedd).
doubled_digits :: proc(v: string) -> bool {
	for i := 0; i + 1 < len(v); i += 2 {
		if v[i] != v[i + 1] {
			return false
		}
	}
	return true
}

// Whether the word key names a color: it holds color, or one of its dash or
// underscore separated parts is the name of a part of a surface. Words that
// merely contain a part, such as context or inputs, are no color keys.
is_color_key :: proc(key: string) -> bool {
	if strings.contains(key, "color") || strings.contains(key, "colour") {
		return true
	}
	rest := key
	for {
		cut := index_any_from(rest, 0, "_-")
		part := rest if cut < 0 else rest[:cut]
		switch part {
		case "background", "foreground", "bg", "fg", "border", "selection", "match", "placeholder", "prompt", "counter", "separator", "frame", "text", "input":
			return true
		}
		if cut < 0 {
			break
		}
		rest = rest[cut + 1:]
	}
	return false
}
