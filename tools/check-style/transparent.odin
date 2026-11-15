package check_style

import "core:strings"

// The keyword transparent as a value, which is an opacity hit: `background:
// transparent`, a border of `2px solid transparent`, `@define-color marker
// transparent`, or any key set to it with =. A child that shows its parent
// uses the role color or inherit. After a colon only a color property
// counts, so prose such as "Default: transparent" is no hit.

check_transparent :: proc(j: ^Judge) {
	if j.is_comment || !strings.contains(j.lower, "transparent") {
		return
	}
	s := strip_comments(j.lower, &j.strip_buf)
	if strings.contains(s, "transparent") && (transparent_after_equals(s) || transparent_define(s) || transparent_after_colon(s)) {
		add_hit(j, .Opacity)
	}
}

// What follows the word at q: a quote, white space, and then ; , } ! or the
// end of the line.
transparent_ends :: proc(s: string, q: int) -> bool {
	i := skip_quote(s, q + len("transparent"))
	i = skip_space(s, i)
	return i >= len(s) || strings.index_byte(";,}!", s[i]) >= 0
}

// `= transparent` with an optional quote.
transparent_after_equals :: proc(s: string) -> bool {
	for q := index_from(s, 0, "transparent"); q >= 0; q = index_from(s, q + 1, "transparent") {
		i := q
		if i > 0 && is_quote(s[i - 1]) {
			i -= 1
		}
		for i > 0 && is_space(s[i - 1]) {
			i -= 1
		}
		if i > 0 && s[i - 1] == '=' && transparent_ends(s, q) {
			return true
		}
	}
	return false
}

// @define-color NAME transparent
transparent_define :: proc(s: string) -> bool {
	for p := index_from(s, 0, "@define-color"); p >= 0; p = index_from(s, p + 1, "@define-color") {
		i := p + len("@define-color")
		if !is_at(s, i, is_space) {
			continue
		}
		i = skip_space(s, i)
		name := i
		for i < len(s) && is_key_byte(s[i]) {
			i += 1
		}
		if i == name || !is_at(s, i, is_space) {
			continue
		}
		i = skip_space(s, i)
		if has_at(s, i, "transparent") {
			return true
		}
	}
	return false
}

COLOR_PROPERTY_WORDS :: [?]string{"color", "background", "border", "outline", "fill", "stroke", "shadow", "caret"}

// Whether the colon at c ends the name of a color property: a run of
// letters and dashes that holds one of the words, after a byte that is no
// part of a word, then an optional quote and white space.
color_property_colon :: proc(s: string, c: int) -> bool {
	i := c
	for i > 0 && is_space(s[i - 1]) {
		i -= 1
	}
	if i > 0 && is_quote(s[i - 1]) {
		i -= 1
	}
	end := i
	for i > 0 && is_letter_or_dash(s[i - 1]) {
		i -= 1
	}
	if i == end || (i > 0 && is_word(s[i - 1])) {
		return false
	}
	name := s[i:end]
	for word in COLOR_PROPERTY_WORDS {
		if strings.contains(name, word) {
			return true
		}
	}
	return false
}

// `background: transparent`, `border: 2px solid transparent`: a color
// property, a colon, and after it, within the same declaration (up to the next
// ; { or }), the word, led by white space or the colon, with a quote around it
// optional, and followed by ; , } ! or the end.
transparent_after_colon :: proc(s: string) -> bool {
	last_stop := -1
	last_colon := -1
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case ';', '{', '}':
			last_stop = i
		case ':':
			if color_property_colon(s, i) {
				last_colon = i
			}
		case 't':
			if !has_at(s, i, "transparent") || !transparent_ends(s, i) {
				continue
			}
			q := i - 1 if i > 0 && is_quote(s[i - 1]) else i
			if last_colon < 0 || last_colon < last_stop || last_colon >= q {
				continue
			}
			if last_colon == q - 1 || (q > 0 && is_space(s[q - 1])) {
				return true
			}
		}
	}
	return false
}
