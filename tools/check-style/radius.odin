package check_style

import "core:strings"

// The radius rule: a border radius other than 0, in four shapes.
//
//   property  border-radius and its per-corner forms (border-top-left-radius,
//             -moz-border-radius, outline-radius), written as CSS: after a
//             colon
//   key       any key that ends in radius, with = or :
//             (corner_radius = 12; foo-radius: 2px), except the lock ring's
//             gauge: indicator-radius, ring-radius, lock-ring-radius
//   rounded   a border key set to rounded (ui = { border = "rounded"; },
//             winborder)
//   corners   round_corners and rounded_corners, unless 0 or false
//
// Comments are cut out of the line first, and a line that is only a comment
// is not judged.

check_radius :: proc(j: ^Judge) {
	if j.is_comment {
		return
	}
	if !strings.contains(j.lower, "radius") && !strings.contains(j.lower, "round") {
		return
	}
	s := strip_comments(j.lower, &j.strip_buf)
	if radius_property(s) || radius_key(s) || radius_rounded(s) || radius_corners(s) {
		add_hit(j, .Radius)
	}
}

// Whether a radius value is not 0: it has a digit from 1 to 9 up to the end
// of its declaration, or is computed.
radius_value :: proc(v: string) -> bool {
	w := v
	if k := index_any_from(w, 0, ";}"); k >= 0 {
		w = w[:k]
	}
	if k := strings.index_byte(w, '!'); k >= 0 {
		w = w[:k]
	}
	// A trailing comment: white space and a #.
	for k := 0; k + 1 < len(w); k += 1 {
		if is_space(w[k]) && w[k + 1] == '#' {
			w = w[:k]
			break
		}
	}
	for i in 0 ..< len(w) {
		if w[i] >= '1' && w[i] <= '9' {
			return true
		}
	}
	return strings.contains(w, "var(") || strings.contains(w, "calc(") || strings.contains(w, "env(")
}

// Whether the value of round_corners is neither 0 nor false.
corners_value :: proc(v: string) -> bool {
	w := v
	if k := index_any_from(w, 0, ";}"); k >= 0 {
		w = w[:k]
	}
	if k := strings.index_byte(w, '!'); k >= 0 {
		w = w[:k]
	}
	b: [dynamic]u8
	defer delete(b)
	for c in transmute([]u8)w {
		if c != '"' && c != '\'' && c != ' ' && c != ',' {
			append(&b, c)
		}
	}
	w = string(b[:])
	if k := strings.index_byte(w, '#'); k >= 0 {
		w = w[:k]
	}
	switch w {
	case "", "0", "0px", "0.0", "false", "off", "no", "none":
		return false
	}
	return true
}

is_key_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || is_digit(c) || c == '_' || c == '-'
}

// The index of the end of the value that starts at i: the next ; or }
// (stops) or the end of the line.
value_end :: proc(s: string, i: int, stops: string) -> int {
	if k := index_any_from(s, i, stops); k >= 0 {
		return k
	}
	return len(s)
}

// Whether a byte at i, or the start of the unmatched text at floor, lets a
// word that begins after it start there.
boundary_before :: proc(s: string, i, floor: int, class: proc(c: u8) -> bool) -> bool {
	return i == floor || (i > floor && class(s[i - 1]))
}

not_word :: proc(c: u8) -> bool {
	return !is_word(c)
}

// (outline|border)-([a-z]+-[a-z]+-)?radius["']?:value, with an optional
// vendor prefix (-moz-), that does not run on from a word before it.
radius_property :: proc(s: string) -> bool {
	floor := 0
	hit := false
	for r := index_from(s, 0, "radius"); r >= 0; r = index_from(s, max(r + 1, floor), "radius") {
		if r < floor {
			continue
		}
		_, ok := radius_property_word(s, r, floor)
		if !ok {
			continue
		}
		i := skip_quote(s, r + len("radius"))
		i = skip_space(s, i)
		if i >= len(s) || s[i] != ':' {
			continue
		}
		i = skip_space(s, i + 1)
		end := value_end(s, i, ";}")
		if radius_value(s[i:end]) {
			hit = true
		}
		floor = end
	}
	return hit
}

// The start of the property word (outline or border) before the radius at
// r, with its corner and vendor prefix, if the text before r has the shape.
radius_property_word :: proc(s: string, r, floor: int) -> (start: int, ok: bool) {
	if r == 0 || s[r - 1] != '-' {
		return 0, false
	}
	p := r - 1
	// No corner: the word ends at the dash.
	for word in ([?]string{"outline", "border"}) {
		if p >= len(word) && s[p - len(word):p] == word && property_prefix_ok(s, p - len(word), floor) {
			return p - len(word), true
		}
	}
	// A corner: word, a dash, two letter runs each followed by a dash.
	y := p
	for y > 0 && s[y - 1] >= 'a' && s[y - 1] <= 'z' {
		y -= 1
	}
	if y == p || y == 0 || s[y - 1] != '-' {
		return 0, false
	}
	x := y - 1
	x_end := x
	for x > 0 && s[x - 1] >= 'a' && s[x - 1] <= 'z' {
		x -= 1
	}
	if x == x_end || x == 0 || s[x - 1] != '-' {
		return 0, false
	}
	dash := x - 1
	for word in ([?]string{"outline", "border"}) {
		if dash >= len(word) && s[dash - len(word):dash] == word && property_prefix_ok(s, dash - len(word), floor) {
			return dash - len(word), true
		}
	}
	return 0, false
}

// What may stand before the property word: the line start (or the start of
// the unmatched text), a byte that is no part of a word, or a vendor prefix
// -word- that has such a byte before it.
property_prefix_ok :: proc(s: string, w, floor: int) -> bool {
	if boundary_before(s, w, floor, not_word) {
		return true
	}
	if w >= 1 && s[w - 1] == '-' {
		k := w - 1
		for k > 0 && s[k - 1] >= 'a' && s[k - 1] <= 'z' {
			k -= 1
		}
		if k < w - 1 && k >= 1 && s[k - 1] == '-' {
			return boundary_before(s, k - 1, floor, not_word)
		}
	}
	return false
}

// A key that ends in radius: foo_radius = 3, window.focus_ring_radius: 8.
// The key follows the line start or one of white space { . , and a quote.
radius_key :: proc(s: string) -> bool {
	floor := 0
	hit := false
	i := 0
	for i < len(s) {
		if !is_key_byte(s[i]) {
			i += 1
			continue
		}
		a := i
		for i < len(s) && is_key_byte(s[i]) {
			i += 1
		}
		if a < floor || !boundary_before(s, a, floor, radius_key_boundary) || !strings.has_suffix(s[a:i], "radius") {
			continue
		}
		j := skip_quote(s, i)
		j = skip_space(s, j)
		if j >= len(s) || (s[j] != '=' && s[j] != ':') {
			continue
		}
		j = skip_space(s, j + 1)
		end := value_end(s, j, ";")
		if !lock_ring_gauge(s[a:i]) && radius_value(s[j:end]) {
			hit = true
		}
		floor = end
		i = end
	}
	return hit
}

radius_key_boundary :: proc(c: u8) -> bool {
	return is_space(c) || c == '{' || c == '.' || c == ',' || is_quote(c)
}

// The lock ring is a gauge: swaylock's indicator-radius, and a ring or
// lock-ring radius, are geometry. Any other ring (focus_ring_radius) has a
// corner.
lock_ring_gauge :: proc(key: string) -> bool {
	if !strings.has_suffix(key, "radius") || len(key) < 7 {
		return false
	}
	head := key[:len(key) - len("radius") - 1]
	if key[len(key) - len("radius") - 1] != '_' && key[len(key) - len("radius") - 1] != '-' {
		return false
	}
	switch head {
	case "indicator", "ring", "lock_ring", "lock-ring":
		return true
	}
	return false
}

// A border key set to rounded: any run of key bytes that holds "border" and
// is followed by = or : and the word rounded.
radius_rounded :: proc(s: string) -> bool {
	if !strings.contains(s, "rounded") {
		return false
	}
	i := 0
	for i < len(s) {
		if !is_key_byte(s[i]) {
			i += 1
			continue
		}
		a := i
		for i < len(s) && is_key_byte(s[i]) {
			i += 1
		}
		if !strings.contains(s[a:i], "border") {
			continue
		}
		j := skip_quote(s, i)
		j = skip_space(s, j)
		if j >= len(s) || (s[j] != '=' && s[j] != ':') {
			continue
		}
		j = skip_space(s, j + 1)
		j = skip_quote(s, j)
		if has_at(s, j, "rounded") {
			k := j + len("rounded")
			if k >= len(s) || !(is_alnum(s[k]) || s[k] == '_') {
				return true
			}
		}
	}
	return false
}

// round_corners and rounded_corners (with a dash too) set to anything but 0
// or false.
radius_corners :: proc(s: string) -> bool {
	floor := 0
	hit := false
	for p := index_from(s, 0, "round"); p >= 0; p = index_from(s, max(p + 1, floor), "round") {
		if p < floor || !boundary_before(s, p, floor, is_not_alnum) {
			continue
		}
		q := p + len("round")
		if has_at(s, q, "ed") {
			q += 2
		}
		if q >= len(s) || (s[q] != '_' && s[q] != '-') || !has_at(s, q + 1, "corners") {
			continue
		}
		i := skip_quote(s, q + 1 + len("corners"))
		i = skip_space(s, i)
		if i >= len(s) || (s[i] != '=' && s[i] != ':') {
			continue
		}
		i = skip_space(s, i + 1)
		end := value_end(s, i, ";")
		if corners_value(s[i:end]) {
			hit = true
		}
		floor = end
	}
	return hit
}

is_not_alnum :: proc(c: u8) -> bool {
	return !is_alnum(c)
}
