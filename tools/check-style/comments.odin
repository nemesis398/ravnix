package check_style

import "core:strings"

// comment_line reports whether the whole line is a comment: # followed by
// white space or the end, ; at the start, a /* that stays open to the end of
// the line or closes exactly there, the closing */ line, a lone * and a
// " * text" line inside a block comment (not a CSS rule that starts with
// * as a selector: * button { ... }). In files where // starts a comment (CSS
// and the other configs, not Nix) a line that starts with // is one, and in
// Lua one that starts with --. Documents have no comment lines.
comment_line :: proc(line: string, kind: Kind) -> bool {
	if kind == .Docs {
		return false
	}
	i := 0
	for i < len(line) && is_blank(line[i]) {
		i += 1
	}
	s := line[i:]
	if len(s) == 0 {
		return false
	}
	switch s[0] {
	case '#':
		if len(s) == 1 || is_blank(s[1]) {
			return true
		}
	case ';':
		return true
	case '/':
		if len(s) >= 2 && s[1] == '*' && comment_stays_open_or_closes_at_end(s[2:]) {
			return true
		}
	case '*':
		if star_comment_line(s) {
			return true
		}
	}
	if (kind == .Css || kind == .Code) && strings.has_prefix(s, "//") {
		return true
	}
	if kind == .Lua && strings.has_prefix(s, "--") {
		return true
	}
	return false
}

// What follows "/*" on a line that starts with it: no */ before the end
// (the comment is still open), or a first */ with nothing but blanks after
// it. A /* x */ border-radius: 4px; line is code.
comment_stays_open_or_closes_at_end :: proc(rest: string) -> bool {
	end := strings.index(rest, "*/")
	return end < 0 || all_blank(rest[end + 2:])
}

// A line that starts with *: stars and a closing /, a lone *, or * and white
// space and text that is no selector (not one that starts with { , : . # [ >
// + ~) and holds no {.
star_comment_line :: proc(s: string) -> bool {
	stars := 0
	for stars < len(s) && s[stars] == '*' {
		stars += 1
	}
	if stars < len(s) && s[stars] == '/' && all_blank(s[stars + 1:]) {
		return true
	}
	if all_blank(s[1:]) {
		return true
	}
	if len(s) > 1 && is_blank(s[1]) {
		k := 1
		for k < len(s) && is_blank(s[k]) {
			k += 1
		}
		if k < len(s) && strings.index_byte("{,:.#[>+~", s[k]) < 0 && strings.index_byte(s[k + 1:], '{') < 0 {
			return true
		}
	}
	return false
}

// strip_comments returns text without its /* ... */ spans, each replaced by
// one space, and without the open comment at its end: from the first /* that
// no */ closes on. text must have its letters in lower case already when the
// caller wants that. The result is text itself when it holds no /*, and
// otherwise lives in out until the next call.
//
// The Bash version cut the rightmost /* that a */ closes, again and again.
// The same result comes from one pass from the right, in time linear in the
// line: a stack of the */ not yet used, from which each /* takes the nearest
// one at least two bytes after its own start (so /*/ is not a whole
// comment). A */ whose / is the first byte of a cut /* is gone with it.
strip_comments :: proc(text: string, out: ^[dynamic]u8) -> string {
	if !strings.contains(text, "/*") {
		return text
	}
	closes: [dynamic]int
	spans: [dynamic][2]int
	defer delete(closes)
	defer delete(spans)
	cut_at := -1
	for i := len(text) - 2; i >= 0; i -= 1 {
		if text[i] == '*' && text[i + 1] == '/' {
			if i + 1 != cut_at {
				append(&closes, i)
			}
		} else if text[i] == '/' && text[i + 1] == '*' {
			n := len(closes)
			if n > 0 && closes[n - 1] >= i + 2 {
				append(&spans, [2]int{i, closes[n - 1] + 2})
				resize(&closes, n - 1)
				cut_at = i
			} else if n >= 2 && closes[n - 1] == i + 1 {
				append(&spans, [2]int{i, closes[n - 2] + 2})
				resize(&closes, n - 2)
				cut_at = i
			}
		}
	}
	clear(out)
	pos := 0
	// The spans were found from the right; the outermost of nested ones
	// comes last.
	for k := len(spans) - 1; k >= 0; k -= 1 {
		span := spans[k]
		if span[0] < pos {
			if span[1] > pos {
				pos = span[1]
			}
			continue
		}
		append(out, text[pos:span[0]])
		append(out, ' ')
		pos = span[1]
	}
	append(out, text[pos:])
	result := string(out[:])
	if open := strings.index(result, "/*"); open >= 0 {
		result = result[:open]
	}
	return result
}
