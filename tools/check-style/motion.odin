package check_style

import "core:strings"

// The motion rule: a transition or animation key, or @keyframes, unless the
// key turns motion off (none, false, off, no, 0, 0s, 0ms); also
// enable-animations and gtk-enable-animations set to anything else, also as
// the last part of an attribute path
// (gtk.gtk3.extraConfig.gtk-enable-animations = true). Words that only
// contain the names, such as systemd.TransitionTime, are no keys.
//
// A key is found as a match, as ripgrep found it for the Bash version: after
// the line start or one of white space { ; " ' ( , . the key, an optional
// quote, white space, = or :, and up to 60 characters that are no ; { or }.
// White space here is Unicode's, as ripgrep's \s was.
// The matches do not overlap, so a value that runs on swallows the keys
// inside it. The text of the match is what is judged.

MOTION_VENDORS :: [?]string{"gtk", "moz", "webkit", "ms", "o"}

check_motion :: proc(j: ^Judge) {
	if j.is_comment {
		return
	}
	s := j.lower
	if !strings.contains(s, "transition") && !strings.contains(s, "animation") && !strings.contains(s, "keyframes") {
		return
	}
	from := 0
	for from < len(s) {
		start, end, ok := next_motion_match(s, from)
		if !ok {
			return
		}
		if motion_match_is_hit(j, start, end) {
			add_hit(j, .Motion)
		}
		from = end
	}
}

// The length of the boundary character at p: one of { ; " ' ( , . or white
// space (the Unicode one, as ripgrep's \s was), or 0.
motion_boundary_width :: proc(s: string, p: int) -> int {
	if strings.index_byte("{;\"'(,.", s[p]) >= 0 {
		return 1
	}
	return unicode_space_at(s, p)
}

// The first match from index from on, as the start and the end of its text.
next_motion_match :: proc(s: string, from: int) -> (start, end: int, ok: bool) {
	for p := from; p < len(s); p += 1 {
		if s[p] == '@' {
			if e, found := keyframes_at(s, p); found {
				return p, e, true
			}
		}
		if p == 0 {
			if e, found := motion_key_at(s, 0); found {
				return 0, e, true
			}
		}
		if width := motion_boundary_width(s, p); width > 0 {
			if e, found := motion_key_at(s, p + width); found {
				return p, e, true
			}
		}
	}
	return 0, 0, false
}

// @keyframes and @-webkit-keyframes, at a word end.
keyframes_at :: proc(s: string, p: int) -> (end: int, ok: bool) {
	i := p + 1
	if i < len(s) && s[i] == '-' {
		k := i + 1
		for k < len(s) && s[k] >= 'a' && s[k] <= 'z' {
			k += 1
		}
		if k == i + 1 || k >= len(s) || s[k] != '-' {
			return 0, false
		}
		i = k + 1
	}
	if !has_at(s, i, "keyframes") {
		return 0, false
	}
	i += len("keyframes")
	if i < len(s) && (is_alnum(s[i]) || s[i] == '_') {
		return 0, false
	}
	return i, true
}

// A key at k, its separator and up to 60 characters of its value: the end of
// the match.
motion_key_at :: proc(s: string, k: int) -> (end: int, ok: bool) {
	i := k
	matched := false
	if i < len(s) && s[i] == '-' {
		for vendor in MOTION_VENDORS {
			if has_at(s, i + 1, vendor) && has_at(s, i + 1 + len(vendor), "-") {
				i += 2 + len(vendor)
				break
			}
		}
	}
	if has_at(s, i, "transition") {
		i += len("transition")
		matched = true
	} else if has_at(s, i, "animation") {
		i += len("animation")
		if has_at(s, i, "s") {
			i += 1
		}
		matched = true
	}
	if matched {
		// An optional tail: - or . and letters, dots and dashes up to the last
		// letter (transition-duration, animations.enabled).
		if i < len(s) && (s[i] == '-' || s[i] == '.') {
			last_letter := -1
			for m := i + 1; m < len(s) && (s[m] >= 'a' && s[m] <= 'z' || s[m] == '.' || s[m] == '-'); m += 1 {
				if s[m] >= 'a' && s[m] <= 'z' {
					last_letter = m
				}
			}
			if last_letter >= 0 {
				i = last_letter + 1
			}
		}
	} else {
		i = k
		if has_at(s, i, "gtk-") {
			i += 4
		}
		if !has_at(s, i, "enable-animations") {
			return 0, false
		}
		i += len("enable-animations")
	}
	i = skip_quote(s, i)
	i = skip_unicode_space(s, i)
	if i >= len(s) || (s[i] != '=' && s[i] != ':') {
		return 0, false
	}
	i += 1
	count := 0
	for i < len(s) && s[i] != ';' && s[i] != '{' && s[i] != '}' {
		// A character is a byte that is no continuation of a UTF-8 sequence.
		if s[i] & 0xC0 != 0x80 {
			if count == 60 {
				break
			}
			count += 1
		}
		i += 1
	}
	return i, true
}

// Whether the match at start..end is a hit.
motion_match_is_hit :: proc(j: ^Judge, start, end: int) -> bool {
	text := j.lower[start:end]
	// A class selector with a pseudo-class (.animation-x:hover) is no key.
	if text[0] == '.' {
		first := index_any_from(text, 0, "=:")
		if first >= 0 && text[first] == ':' && is_class_selector(j, j.line[start:end]) {
			return false
		}
	}
	at_sign := strings.index_byte(text, '@')
	keyframes := at_sign >= 0 && strings.contains(text[at_sign:], "keyframes")
	first := index_any_from(text, 0, "=:")
	if first >= 0 && !keyframes {
		value := text[skip_space(text, first + 1):]
		b: [dynamic]u8
		defer delete(b)
		for c in transmute([]u8)value {
			if !is_quote(c) {
				append(&b, c)
			}
		}
		v := string(b[:])
		if k := strings.index_byte(v, '!'); k >= 0 {
			v = v[:k]
		}
		v = strings.trim_right_proc(v, is_space_rune)
		switch v {
		case "none", "false", "off", "no", "0", "0s", "0ms", "0.0s", "0.0ms":
			return false
		}
	}
	return true
}

is_space_rune :: proc(r: rune) -> bool {
	return r < 128 && is_space(u8(r))
}

// Whether a match that starts with a dot and has its colon before any = is a
// CSS class selector with a pseudo-class, not a key written as an attribute
// path. In a CSS file it always is. Elsewhere (a stylesheet in a Nix string)
// the selector ends the line with , or {, or the rule opens right after the
// match.
is_class_selector :: proc(j: ^Judge, matched: string) -> bool {
	if j.file.kind == .Css {
		return true
	}
	at := strings.index(j.line, matched)
	if at >= 0 {
		tail := j.line[at + len(matched):]
		i := skip_space(tail, 0)
		if i < len(tail) && tail[i] == '{' {
			return true
		}
	}
	e := len(j.line)
	for e > 0 && is_space(j.line[e - 1]) {
		e -= 1
	}
	return e > 0 && (j.line[e - 1] == ',' || j.line[e - 1] == '{')
}
