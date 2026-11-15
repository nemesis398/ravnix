package check_style

import "core:strings"

// The opacity rule: anything below fully opaque.
//
//   key          an opacity key (opacity, window_opacity, inactive-opacity) or
//                an alpha key that makes a surface see-through (alpha,
//                background_alpha, window-alpha) with a value below 1 or
//                100%. A smoothing_alpha is a factor, not a transparency.
//   sway         sway's opacity command, also in a quoted string:
//                opacity 0.9, opacity set 0.9
//   blend        Neovim's winblend and pumblend above 0
//   alpha()      any alpha( function (GTK's alpha(@accent, 0.18))
//   rgba         rgba() and hsla() with an alpha below 1, rgb() and hsl()
//                with / alpha below 1
//
// Comments are cut out first, and a comment line is not judged. The hex
// colors with alpha are the hex rule's (hex.odin), the keyword transparent
// is transparent.odin's.

SURFACES :: [?]string {
	"background",
	"bg",
	"foreground",
	"fg",
	"window",
	"inactive",
	"active",
	"bar",
	"border",
	"cursor",
	"selection",
	"text",
	"panel",
	"menu",
	"popup",
	"overlay",
	"fill",
	"inner",
	"outer",
	"tab",
	"title",
	"titlebar",
	"frame",
	"focus",
	"focused",
	"unfocused",
	"dim",
	"shadow",
	"notification",
}

check_opacity :: proc(j: ^Judge) {
	if j.is_comment {
		return
	}
	l := j.lower
	if !(strings.contains(l, "opacity") || strings.contains(l, "alpha") || strings.contains(l, "blend") ||
		   strings.contains(l, "rgba") || strings.contains(l, "hsla") || strings.contains(l, "rgb(") || strings.contains(l, "hsl(")) {
		return
	}
	s := strip_comments(l, &j.strip_buf)
	if opacity_keys(s) || sway_opacity(s) || blend_keys(s) || alpha_function(s) || functions_with_alpha(s) {
		add_hit(j, .Opacity)
	}
}

// opacity, or words and separators before it (window_opacity, a-b_opacity);
// alpha, or a surface and a separator before it (bg_alpha).
opacity_key :: proc(k: string) -> bool {
	if strings.has_suffix(k, "opacity") {
		p := k[:len(k) - len("opacity")]
		if p == "" {
			return true
		}
		// ([a-z0-9]+[_-])+: words, each ended by one separator.
		if !is_alnum(p[0]) || (p[len(p) - 1] != '_' && p[len(p) - 1] != '-') {
			return false
		}
		for i in 1 ..< len(p) {
			sep := p[i] == '_' || p[i] == '-'
			if !is_alnum(p[i]) && !sep {
				return false
			}
			if sep && (p[i - 1] == '_' || p[i - 1] == '-') {
				return false
			}
		}
		return true
	}
	if k == "alpha" {
		return true
	}
	if strings.has_suffix(k, "alpha") && len(k) > len("alpha") {
		sep := k[len(k) - len("alpha") - 1]
		if sep == '_' || sep == '-' {
			surface := k[:len(k) - len("alpha") - 1]
			for name in SURFACES {
				if surface == name {
					return true
				}
			}
		}
	}
	return false
}

// A key and its value, the key after a byte that is no part of a word (and
// an optional leading dash), then a quote, white space, = or :, white space
// and a quote; the value runs to ; , } a quote or white space.
opacity_keys :: proc(s: string) -> bool {
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
		key := s[a:i]
		if key[0] == '-' {
			key = key[1:]
		}
		if !opacity_key(key) {
			continue
		}
		j := skip_quote(s, i)
		j = skip_space(s, j)
		if j >= len(s) || (s[j] != '=' && s[j] != ':') {
			continue
		}
		j = skip_space(s, j + 1)
		j = skip_quote(s, j)
		end := j
		for end < len(s) && strings.index_byte(";,}\"'", s[end]) < 0 && !is_space(s[end]) {
			end += 1
		}
		if below_one(s[j:end]) {
			hit = true
		}
		i = end
	}
	return hit
}

// [0-9]*\.?[0-9]+ at i: the end of the number, or -1.
number_end :: proc(s: string, i: int) -> int {
	whole := 0
	for i + whole < len(s) && is_digit(s[i + whole]) {
		whole += 1
	}
	k := i + whole
	if k < len(s) && s[k] == '.' {
		fraction := 0
		for k + 1 + fraction < len(s) && is_digit(s[k + 1 + fraction]) {
			fraction += 1
		}
		if fraction > 0 {
			return k + 1 + fraction
		}
	}
	if whole > 0 {
		return k
	}
	return -1
}

// opacity 0.9 and opacity set 0.9, after a line start, white space, a quote or
// ]. Only the first such command of the line counts, as in the Bash version.
sway_opacity :: proc(s: string) -> bool {
	for p := index_from(s, 0, "opacity"); p >= 0; p = index_from(s, p + 1, "opacity") {
		if p > 0 && !(is_space(s[p - 1]) || is_quote(s[p - 1]) || s[p - 1] == ']') {
			continue
		}
		i := p + len("opacity")
		if !is_at(s, i, is_space) {
			continue
		}
		i = skip_space(s, i)
		if has_at(s, i, "set") && is_at(s, i + 3, is_space) {
			i = skip_space(s, i + 3)
		}
		end := number_end(s, i)
		if end < 0 {
			continue
		}
		if end < len(s) && !(is_space(s[end]) || is_quote(s[end]) || s[end] == ';') {
			continue
		}
		return below_one(s[i:end])
	}
	return false
}

// winblend and pumblend, as a key, above 0.
blend_keys :: proc(s: string) -> bool {
	for word in ([?]string{"winblend", "pumblend"}) {
		for p := index_from(s, 0, word); p >= 0; p = index_from(s, p + 1, word) {
			if p > 0 && is_word(s[p - 1]) {
				continue
			}
			i := skip_quote(s, p + len(word))
			i = skip_space(s, i)
			if i >= len(s) || (s[i] != '=' && s[i] != ':') {
				continue
			}
			i = skip_space(s, i + 1)
			i = skip_quote(s, i)
			n := 0
			for i + n < len(s) && is_digit(s[i + n]) {
				if s[i + n] != '0' {
					return true
				}
				n += 1
			}
		}
	}
	return false
}

// alpha( with nothing but white space before the parenthesis, after a byte
// that is no part of a word.
alpha_function :: proc(s: string) -> bool {
	for p := index_from(s, 0, "alpha"); p >= 0; p = index_from(s, p + 1, "alpha") {
		if p > 0 && is_word(s[p - 1]) {
			continue
		}
		i := skip_space(s, p + len("alpha"))
		if i < len(s) && s[i] == '(' {
			return true
		}
	}
	return false
}

// rgba(r, g, b, A), hsla(..., A), rgb(r g b / A), hsl(... / A): the last
// argument, a number, below 1 or 100%.
functions_with_alpha :: proc(s: string) -> bool {
	hit := false
	for name in ([?]string{"rgba(", "hsla("}) {
		if alpha_argument_below_one(s, name, ',') {
			hit = true
		}
	}
	for name in ([?]string{"rgb(", "hsl("}) {
		if alpha_argument_below_one(s, name, '/') {
			hit = true
		}
	}
	return hit
}

alpha_argument_below_one :: proc(s, name: string, separator: u8) -> bool {
	hit := false
	floor := 0
	for p := index_from(s, 0, name); p >= 0; p = index_from(s, max(p + 1, floor), name) {
		if p < floor {
			continue
		}
		open := p + len(name)
		close := strings.index_byte(s[open:], ')')
		if close < 0 {
			return hit
		}
		close += open
		// The arguments end in separator, white space, a number, white space.
		e := close
		for e > open && is_space(s[e - 1]) {
			e -= 1
		}
		n_end := e
		if e > open && s[e - 1] == '%' {
			e -= 1
		}
		for e > open && (is_digit(s[e - 1]) || s[e - 1] == '.') {
			e -= 1
		}
		if e == n_end || (e < n_end && s[e] == '%') {
			continue
		}
		number := s[e:n_end]
		for e > open && is_space(s[e - 1]) {
			e -= 1
		}
		if e == open || s[e - 1] != separator {
			continue
		}
		if below_one(number) {
			hit = true
		}
		floor = close + 1
	}
	return hit
}
