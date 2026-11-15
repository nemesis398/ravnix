package check_style

import "core:strings"

// Hex colors. Four searches find them, as the Bash version had four:
//
//   long      #rrggbb and #rrggbbaa, in every judged file
//   short     #rgb and #rgba, in CSS files
//   quoted    "#rgb" and "#rgba", in code files
//   property  #rgb and #rgba after a color property (color, background,
//             border, outline, fill, stroke, shadow), in code files
//
// A color is a # and 6 or 8 (3 or 4) hex digits, not glued to a word, a path,
// a URL, a shell expansion ($#, ${#a}) or an entity (&#): the byte before the
// # is none of a letter, a digit, _ # & / $ . @ { -, and the byte after the
// digits none of a letter, a digit, _ -. A link target, ](#facade) or
// href="#facade", is no color.

check_hex :: proc(j: ^Judge) {
	s := j.line
	judged_as_code := j.file.kind != .Docs
	for h := strings.index_byte(s, '#'); h >= 0; {
		n := hex_run(s, h + 1)
		after_ok := h + 1 + n >= len(s) || !is_word(s[h + 1 + n])
		if after_ok {
			if (n == 6 || n == 8) && long_prefix_ok(s, h) {
				hex_hit(j, s[h + 1:h + 1 + n])
			}
			if (n == 3 || n == 4) && judged_as_code {
				if j.file.kind == .Css && hash_prefix_ok(s, h) {
					hex_hit(j, s[h + 1:h + 1 + n])
				}
			}
		}
		if (n == 3 || n == 4) && judged_as_code && h > 0 && is_quote(s[h - 1]) && h + 1 + n < len(s) && is_quote(s[h + 1 + n]) {
			hex_hit(j, s[h + 1:h + 1 + n])
		}
		next := strings.index_byte(s[h + 1:], '#')
		if next < 0 {
			break
		}
		h += 1 + next
	}
	if judged_as_code {
		check_hex_property(j)
	}
}

// Whether the byte before the # at h lets a color start there: the start of
// the line, or none of the bytes that glue a # to a word.
hash_prefix_ok :: proc(s: string, h: int) -> bool {
	if h == 0 {
		return true
	}
	return !is_alnum(s[h - 1]) && strings.index_byte("_#&/$.@{-", s[h - 1]) < 0
}

// The prefix of a long color: that of any color, but a link target is none
// (the Bash version matched it and then let it go).
long_prefix_ok :: proc(s: string, h: int) -> bool {
	if h >= 2 && s[h - 2] == ']' && s[h - 1] == '(' {
		return false
	}
	if h >= 6 && is_quote(s[h - 1]) && s[h - 2] == '=' && strings.equal_fold(s[h - 6:h - 2], "href") {
		return false
	}
	return hash_prefix_ok(s, h)
}

// hex_hit judges one color, given by its digits: whether it is an issue
// number, translucent, or outside the places that may hold colors.
hex_hit :: proc(j: ^Judge, digits: string) {
	if j.in_init {
		return
	}
	// #123456 in a document or a comment is an issue number, not a color.
	// The two colors of Mocha that are all digits, Mantle and Surface0, are
	// not.
	if all_digits(digits) && digits != "181825" && digits != "313244" {
		if j.file.kind == .Docs || j.is_comment || in_trailing_comment(j, digits) {
			return
		}
	}
	// Alpha: the last two digits of #rrggbbaa, the last of #rgba. A document
	// only shows a color; what is translucent is code.
	if j.file.kind != .Docs {
		switch len(digits) {
		case 8:
			if !(lower_byte(digits[6]) == 'f' && lower_byte(digits[7]) == 'f') && !lock_ring_inside(j, digits) {
				add_hit(j, .Opacity)
			}
		case 4:
			if lower_byte(digits[3]) != 'f' && !lock_ring_inside(j, digits) {
				add_hit(j, .Opacity)
			}
		}
	}
	if !hex_allowed(j.file) {
		add_hit(j, .Hex_Color)
	}
}

// Whether the first #DIGITS of the line stands in a trailing comment: after
// a # or // (-- in Lua) that has white space or the line start before it.
in_trailing_comment :: proc(j: ^Judge, digits: string) -> bool {
	needle := strings.concatenate({"#", digits}, context.temp_allocator)
	at := strings.index(j.line, needle)
	if at < 0 {
		return false
	}
	before := j.line[:at]
	if comment_marker_before(before, "#", true) {
		return true
	}
	if (j.file.kind == .Css || j.file.kind == .Code) && comment_marker_before(before, "//", false) {
		return true
	}
	if j.file.kind == .Lua && comment_marker_before(before, "--", false) {
		return true
	}
	return false
}

// Whether text holds marker with the line start or white space before it,
// and, when alone is set, white space or the end after it.
comment_marker_before :: proc(text, marker: string, alone: bool) -> bool {
	for k := 0; k + len(marker) <= len(text); k += 1 {
		if text[k:k + len(marker)] != marker {
			continue
		}
		if k > 0 && !is_space(text[k - 1]) {
			continue
		}
		end := k + len(marker)
		if alone && end < len(text) && !is_space(text[end]) {
			continue
		}
		return true
	}
	return false
}

// Whether the color with these digits is the value of one of swaylock's
// inside-color keys, or of its separator-color with alpha 00: the places a
// color may be see-through.
lock_ring_inside :: proc(j: ^Judge, digits: string) -> bool {
	lower := j.lower
	mine := strings.to_lower(digits, context.temp_allocator)
	if key_assigns_hash(lower, mine, true) {
		return true
	}
	// The separator is fully clear (alpha 00) or it is a hit.
	clear_alpha := (len(mine) == 8 && mine[6:] == "00") || (len(mine) == 4 && mine[3] == '0')
	return clear_alpha && key_assigns_hash(lower, mine, false)
}

// Whether lower has `KEY = "#DIGITS`, with KEY inside-NAME-color (inside) or
// separator-color (not inside), a quote after the key and before the value
// optional, : instead of = allowed, and a byte before the key that is no part
// of a word.
key_assigns_hash :: proc(lower, digits: string, inside: bool) -> bool {
	from := 0
	for {
		k := index_from(lower, from, "inside" if inside else "separator-color")
		if k < 0 {
			return false
		}
		from = k + 1
		if k > 0 && is_word(lower[k - 1]) {
			continue
		}
		end: int
		if inside {
			// inside(-[a-z]+)*-color: segments, the last of them "color".
			i := k + len("inside")
			last_start := -1
			for i < len(lower) && lower[i] == '-' {
				j := i + 1
				for j < len(lower) && lower[j] >= 'a' && lower[j] <= 'z' {
					j += 1
				}
				if j == i + 1 {
					break
				}
				last_start = i + 1
				i = j
			}
			if last_start < 0 || lower[last_start:i] != "color" {
				continue
			}
			end = i
		} else {
			end = k + len("separator-color")
		}
		i := skip_quote(lower, end)
		i = skip_space(lower, i)
		if i >= len(lower) || (lower[i] != '=' && lower[i] != ':') {
			continue
		}
		i = skip_space(lower, i + 1)
		i = skip_quote(lower, i)
		if i < len(lower) && lower[i] == '#' && has_at(lower, i + 1, digits) {
			return true
		}
	}
}

// The words that name a part of a surface, after which a short color is
// searched: color, background, border, outline, fill, stroke, shadow.
PROPERTY_WORDS :: [?]string{"color", "background", "border", "outline", "fill", "stroke", "shadow"}

// #rgb or #rgba after a color property, up to the next ; { or }:
// `color: #fff`, `border: 1px solid #abc`. The match runs from the property
// word to the byte after the color; the digits are those of the first #
// that a hex digit follows in it, as the Bash version read them.
check_hex_property :: proc(j: ^Judge) {
	s := j.lower
	if strings.index_byte(s, '#') < 0 {
		return
	}
	// The colors a property could take: the # of a 3 or 4 digit color that
	// no word, digit, _ or - follows, and the ; { } that end the property.
	colors: [dynamic]int
	stops: [dynamic]int
	defer delete(colors)
	defer delete(stops)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '#':
			n := hex_run(s, i + 1)
			if (n == 3 || n == 4) && (i + 1 + n >= len(s) || !is_word(s[i + 1 + n])) {
				append(&colors, i)
			}
		case ';', '{', '}':
			append(&stops, i)
		}
	}
	if len(colors) == 0 {
		return
	}
	from := 0
	for from < len(s) {
		start := -1
		colon := -1
		for p := from; p < len(s) && start < 0; p += 1 {
			for word in PROPERTY_WORDS {
				if !has_at(s, p, word) {
					continue
				}
				i := p + len(word)
				for i < len(s) && is_letter_or_dash(s[i]) {
					i += 1
				}
				run_end := i
				i = skip_unicode_space(s, i)
				if i < len(s) && s[i] == ':' {
					start = p
					colon = i
				} else {
					// Every word of this run fails alike: what follows the
					// run decides.
					p = run_end - 1
				}
				break
			}
		}
		if start < 0 {
			return
		}
		// The last color before the next stop; the stop may follow it.
		limit := len(s)
		if k := first_at_or_after(stops[:], colon + 1); k >= 0 {
			limit = stops[k]
		}
		last := last_before(colors[:], limit)
		if last < 0 || colors[last] <= colon {
			from = start + 1
			continue
		}
		h := colors[last]
		n := hex_run(s, h + 1)
		end := h + 1 + n
		if end < len(s) {
			end += 1 // the byte after the color is part of the match
		}
		// The digits of the first # with hex digits after it.
		for k := start; k < end; k += 1 {
			if s[k] == '#' && hex_run(s, k + 1) > 0 {
				hex_hit(j, j.line[k + 1:k + 1 + hex_run(s, k + 1)])
				break
			}
		}
		from = end
	}
}

// The index in sorted of the first value that is at least x, or -1.
first_at_or_after :: proc(sorted: []int, x: int) -> int {
	lo, hi := 0, len(sorted)
	for lo < hi {
		mid := (lo + hi) / 2
		if sorted[mid] < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo if lo < len(sorted) else -1
}

// The index in sorted of the last value that is below x, or -1.
last_before :: proc(sorted: []int, x: int) -> int {
	lo, hi := 0, len(sorted)
	for lo < hi {
		mid := (lo + hi) / 2
		if sorted[mid] < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}
