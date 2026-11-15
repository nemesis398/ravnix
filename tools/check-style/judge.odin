package check_style

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

// The rules, in the order their names sort, which is the order of hits on
// one line.
Rule :: enum {
	Hex_Color,
	Mermaid_Init,
	Motion,
	Opacity,
	Radius,
}

rule_name :: proc(r: Rule) -> string {
	switch r {
	case .Hex_Color:
		return "hex-color"
	case .Mermaid_Init:
		return "mermaid-init"
	case .Motion:
		return "motion"
	case .Opacity:
		return "opacity"
	case .Radius:
		return "radius"
	}
	return ""
}

Hit :: struct {
	path: string,
	line: int,
	rule: Rule,
}

// What a file is, which decides the rules it is judged by:
//
//   Docs  Markdown and Mermaid: hex colors and Mermaid blocks
//   Css   *.css *.scss *.tcss *.rasi: all rules, short hex colors too,
//         // starts a comment
//   Nix   *.nix: all rules
//   Code  *.ini *.conf *.toml *.jsonc *.kdl *.colors and every other file
//         below modules/ or hosts/: all rules, // starts a comment
//   Lua   a Code file named *.lua: all rules, -- starts a comment
Kind :: enum {
	Docs,
	Css,
	Nix,
	Code,
	Lua,
}

File :: struct {
	// The path as the hits show it: as the caller gave it, or the directory
	// argument with the path below it.
	shown: string,
	// The path from the root of the judged tree, which the exemptions read.
	rel:   string,
	kind:  Kind,
}

// The state of the judgement of one file, line by line.
Judge :: struct {
	file:       File,
	hits:       ^[dynamic]Hit,
	theme:      ^Theme,
	line_no:    int,
	// The line without its line end, and in lower case.
	line:       string,
	lower:      string,
	// The whole line is a comment.
	is_comment: bool,
	// The line is inside a Mermaid init block, or starts or ends one.
	in_init:    bool,
	mermaid:    Mermaid,
	// Scratch buffers, reused from line to line. They and everything that
	// outlives a line (the theme, the hits) are made with persist; the rest
	// of a line's work is made in an arena that is emptied after the line.
	lower_buf:  [dynamic]u8,
	strip_buf:  [dynamic]u8,
	persist:    runtime.Allocator,
}

judge_destroy :: proc(j: ^Judge) {
	delete(j.lower_buf)
	delete(j.strip_buf)
}

add_hit :: proc(j: ^Judge, rule: Rule) {
	add_hit_at(j, j.line_no, rule)
}

add_hit_at :: proc(j: ^Judge, line: int, rule: Rule) {
	// A line that gives the same hit twice gives it once; the final pass
	// removes the other repeats.
	if n := len(j.hits^); n > 0 {
		last := j.hits[n - 1]
		if last.path == j.file.shown && last.line == line && last.rule == rule {
			return
		}
	}
	append(j.hits, Hit{path = j.file.shown, line = line, rule = rule})
}

// Whether the file may hold hex colors: the theme module and the style
// document, and the one root for vendored files, all at the root of the
// tree.
hex_allowed :: proc(f: File) -> bool {
	return strings.has_prefix(f.rel, "modules/theme/") || f.rel == "docs/style.md" || strings.has_prefix(f.rel, "vendor/")
}

// judge_line applies every rule to one line.
judge_line :: proc(j: ^Judge, raw: string) -> (fatal: string) {
	j.line_no += 1
	line := raw
	if n := len(line); n > 0 && line[n - 1] == '\r' {
		line = line[:n - 1]
	}
	j.line = line
	j.in_init = false
	fatal = mermaid_step(j)
	if fatal != "" {
		return
	}
	judged_as_code := j.file.kind != .Docs
	if judged_as_code {
		j.is_comment = comment_line(line, j.file.kind)
	} else {
		j.is_comment = false
	}
	if judged_as_code {
		j.lower = lower_into(&j.lower_buf, line)
	}
	check_hex(j)
	if !judged_as_code {
		return
	}
	// ripgrep's windows (.{0,160} around a keyword) cannot cross a byte that is
	// no UTF-8, and the text of a window was judged on its own, so for the
	// three rules that judged windows each run of valid UTF-8 is judged on
	// its own. The other rules look at the whole line: where ripgrep stopped
	// at such a byte, they find at least what it found.
	whole := j.lower
	rest, at := line, 0
	for len(rest) > 0 {
		n := valid_run(rest)
		if n == 0 {
			rest, at = rest[1:], at + 1
			continue
		}
		j.line, j.lower = rest[:n], whole[at:at + n]
		check_radius(j)
		check_opacity(j)
		check_transparent(j)
		rest, at = rest[n:], at + n
	}
	j.line, j.lower = line, whole
	check_bare_color(j)
	check_motion(j)
	return
}

// The length of the run of valid UTF-8 at the start of s; 0 when s starts
// with a byte that is no UTF-8.
valid_run :: proc(s: string) -> int {
	i := 0
	for i < len(s) {
		if s[i] < 0x80 {
			i += 1
			continue
		}
		r, w := utf8.decode_rune_in_string(s[i:])
		if r == utf8.RUNE_ERROR && w <= 1 {
			break
		}
		i += w
	}
	return i
}
