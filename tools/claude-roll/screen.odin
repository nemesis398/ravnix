// The screen check. herdr's idle can be wrong: it takes an unknown dialog
// for an idle prompt, and its idle says nothing about text typed and not
// sent. Before claude-roll types /exit into a pane it reads the pane's
// screen (`herdr agent read PANE --source visible --format ansi`) and
// types only into what it positively knows: the empty input box of Claude
// Code at the bottom of the screen, with no dialog anywhere, no turn
// running, and no unsent text. Everything else waits, and a dialog is
// never typed into.
//
// The box, as Claude Code 2.1.323 draws it:
//
//   ──────────────────────────────── (a rule; a session name may sit in it)
//   ❯ <input>
//     <more input lines>
//   ────────────────────────────────
//     <status line>
//     <mode line: -- INSERT --, auto mode, esc to interrupt>
//
// An empty input may hold a prompt suggestion, which Claude Code draws dim
// (SGR 2): dim text is no input. Typed text is drawn in a color, never dim,
// so the ANSI form tells the two apart. Without it, any text in the input
// counts as typed.
package claude_roll

import "core:strings"
import "core:unicode/utf8"

Verdict :: enum {
	// Not now: a turn runs, text waits in the input, or the screen is not
	// one claude-roll knows. Tried again until the deadline.
	Not_Ready,
	// The empty input box: /exit may be typed.
	Ready,
	// A dialog waits for the user: never typed into.
	Dialog,
}

Screen :: struct {
	verdict: Verdict,
	// Why it is not Ready, for the log; a constant.
	reason:  string,
}

// Words that only a dialog, a form or a menu of Claude Code shows,
// lowercase. One of them anywhere on the screen is a dialog, even in the
// transcript: a pane whose text quotes one is left alone, which costs a
// roll and never a wrong keystroke. Most are the ones herdr's own Claude
// detection uses for blocked (src/detect/manifests/claude.toml in herdr
// 0.9.5); "resume this conversation?" is the dialog herdr calls idle.
DIALOG_WORDS :: [?]string {
	"resume this conversation?",
	"do you want to proceed?",
	"do you want to make this edit",
	"do you want to create",
	"do you want to allow",
	"would you like to proceed?",
	"waiting for permission",
	"tab to amend",
	"ctrl+e to explain",
	"esc to cancel",
	"enter to confirm",
	"enter to select",
	"requests your input",
	"review your answers",
	"run a dynamic workflow?",
}

// Claude Code's spinner glyphs, which start the line of a running turn
// ("✻ Hashing… (1h 8m · ↓ 108.4k tokens)"). A finished turn's line ("✻
// Cooked for 2m 10s") has no ellipsis.
SPINNER :: "*·✢✳✶✻✽"

// How far under the box the screen may go: the status line, the mode line,
// and a little room.
MAX_FOOTER_LINES :: 6
// How many lines above the box are looked at for a running turn.
ABOVE_LINES :: 8
// A screen longer than this is no viewport.
MAX_SCREEN_BYTES :: 1 << 20

Line :: struct {
	// The text, without escapes.
	plain:  string,
	// The text with every dim character made a blank: what was typed.
	typed:  string,
}

classify_screen :: proc(ansi: string) -> Screen {
	if len(ansi) > MAX_SCREEN_BYTES {
		return {.Not_Ready, "the screen is too large to be one"}
	}
	lines := screen_lines(ansi, context.temp_allocator)

	whole := strings.builder_make(context.temp_allocator)
	for l in lines {
		strings.write_string(&whole, l.plain)
		strings.write_byte(&whole, '\n')
	}
	lower := strings.to_lower(strings.to_string(whole), context.temp_allocator)
	for w in DIALOG_WORDS {
		if strings.contains(lower, w) {
			return {.Dialog, "a dialog is on the screen"}
		}
	}
	if strings.contains(lower, "showing detailed transcript") {
		return {.Not_Ready, "the transcript viewer is open"}
	}

	top, bottom, last, found := find_box(lines)
	if !found {
		return {.Not_Ready, "no input box at the bottom of the screen"}
	}

	// The input: ❯ and a blank, then nothing typed, here or below.
	first := strings.trim_left(lines[top + 1].plain, " ")
	if !strings.has_prefix(first, "❯") {
		return {.Not_Ready, "the input box holds no Claude Code prompt"}
	}
	after := first[len("❯"):]
	if after != "" && !strings.has_prefix(after, " ") && !strings.has_prefix(after, "\u00a0") {
		return {.Not_Ready, "the input box holds no Claude Code prompt"}
	}
	// A dim ❯ is a blank here already.
	typed := strings.trim_prefix(strings.trim_left(lines[top + 1].typed, " "), "❯")
	if !is_blank(typed) {
		return {.Not_Ready, "the input holds unsent text"}
	}
	for i in top + 2 ..< bottom {
		if !is_blank(lines[i].typed) {
			return {.Not_Ready, "the input holds unsent text"}
		}
	}

	for i in bottom + 1 ..= last {
		footer := strings.to_lower(lines[i].plain, context.temp_allocator)
		if strings.contains(footer, "esc to interrupt") {
			return {.Not_Ready, "a turn is running"}
		}
		if strings.contains(footer, "-- normal --") {
			return {.Not_Ready, "vim NORMAL mode: typed letters would be commands"}
		}
	}
	seen := 0
	for i := top - 1; i >= 0 && seen < ABOVE_LINES; i -= 1 {
		if is_blank(lines[i].plain) {
			continue
		}
		seen += 1
		if is_spinner_line(lines[i].plain) {
			return {.Not_Ready, "a turn is running"}
		}
		l := strings.to_lower(lines[i].plain, context.temp_allocator)
		if strings.contains(l, "esc to interrupt") || (strings.contains(l, "waiting for") && strings.contains(l, "background agent")) {
			return {.Not_Ready, "a turn is running"}
		}
	}
	return {.Ready, ""}
}

// find_box finds the input box: its top and bottom rule, with no more than
// MAX_FOOTER_LINES under it to the last line with text (last).
find_box :: proc(lines: []Line) -> (top, bottom, last: int, found: bool) {
	last = len(lines) - 1
	for last >= 0 && is_blank(lines[last].plain) {
		last -= 1
	}
	bottom = -1
	for i := last; i >= 0 && i >= last - MAX_FOOTER_LINES; i -= 1 {
		if is_rule(lines[i].plain) {
			bottom = i
			break
		}
	}
	if bottom < 0 {
		return
	}
	top = -1
	for i := bottom - 1; i >= 0; i -= 1 {
		if is_rule(lines[i].plain) {
			top = i
			break
		}
	}
	found = top >= 0 && top + 1 < bottom
	return
}

// input_box returns what was typed in the input box of a Ready screen, its
// rules included, so two reads can be compared without the status line,
// whose clock or counters may move between them. Other screens give "".
input_box :: proc(ansi: string, allocator := context.allocator) -> string {
	if classify_screen(ansi).verdict != .Ready {
		return ""
	}
	lines := screen_lines(ansi, context.temp_allocator)
	top, bottom, _, _ := find_box(lines)
	b := strings.builder_make(allocator)
	for i in top ..= bottom {
		strings.write_string(&b, lines[i].typed)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

is_blank :: proc(s: string) -> bool {
	for r in s {
		if r != ' ' && r != '\u00a0' && r != '\t' {
			return false
		}
	}
	return true
}

// A rule: three or more ─ at its start (after blanks) and at its end.
is_rule :: proc(s: string) -> bool {
	t := strings.trim(s, " ")
	return strings.has_prefix(t, "───") && strings.has_suffix(t, "───")
}

is_spinner_line :: proc(s: string) -> bool {
	t := strings.trim_left(s, " ")
	if t == "" {
		return false
	}
	r, n := utf8.decode_rune_in_string(t)
	if !strings.contains_rune(SPINNER, r) {
		return false
	}
	rest := t[n:]
	if !strings.has_prefix(rest, " ") || is_blank(rest) {
		return false
	}
	return strings.contains(rest, "…")
}

// screen_lines splits a screen into lines without their escapes, and
// notes which characters were dim. It reads CSI sequences (SGR among
// them), OSC strings and two-byte escapes; a sequence cut off at the end
// is dropped. Other control characters become blanks, CR is dropped.
screen_lines :: proc(ansi: string, allocator := context.allocator) -> []Line {
	out := make([dynamic]Line, allocator)
	plain := strings.builder_make(allocator)
	typed := strings.builder_make(allocator)
	dim := false
	i := 0
	flush :: proc(out: ^[dynamic]Line, plain, typed: ^strings.Builder, allocator := context.allocator) {
		append(out, Line{strings.clone(strings.to_string(plain^), allocator), strings.clone(strings.to_string(typed^), allocator)})
		strings.builder_reset(plain)
		strings.builder_reset(typed)
	}
	for i < len(ansi) {
		c := ansi[i]
		switch {
		case c == 0x1b:
			if i + 1 >= len(ansi) {
				i += 1
				continue
			}
			switch ansi[i + 1] {
			case '[':
				j := i + 2
				for j < len(ansi) && !(ansi[j] >= 0x40 && ansi[j] <= 0x7e) {
					j += 1
				}
				if j >= len(ansi) {
					i = j
					continue
				}
				if ansi[j] == 'm' {
					dim = apply_sgr(ansi[i + 2:j], dim)
				}
				i = j + 1
			case ']':
				// OSC: up to BEL or ESC \.
				j := i + 2
				for j < len(ansi) && ansi[j] != 0x07 && !(ansi[j] == 0x1b && j + 1 < len(ansi) && ansi[j + 1] == '\\') {
					j += 1
				}
				if j < len(ansi) && ansi[j] == 0x1b {
					j += 1
				}
				i = j + 1
			case:
				i += 2
			}
		case c == '\n':
			flush(&out, &plain, &typed, allocator)
			i += 1
		case c == '\r':
			i += 1
		case c < 0x20 || c == 0x7f:
			strings.write_byte(&plain, ' ')
			strings.write_byte(&typed, ' ')
			i += 1
		case:
			r, n := utf8.decode_rune_in_string(ansi[i:])
			if r == utf8.RUNE_ERROR {
				r = '?'
			}
			strings.write_rune(&plain, r)
			strings.write_rune(&typed, ' ' if dim else r)
			i += n
		}
	}
	flush(&out, &plain, &typed, allocator)
	return out[:]
}

// apply_sgr returns whether text is dim after the SGR parameters params:
// 0 or none resets, 2 sets dim, 22 ends it. The colors 38, 48 and 58 take
// their own parameters (5;N or 2;R;G;B), which are no attributes: the 2 of
// 38;2;R;G;B is not dim.
apply_sgr :: proc(params: string, dim: bool) -> bool {
	dim := dim
	if params == "" {
		return false
	}
	ps := strings.split(params, ";", context.temp_allocator)
	for k := 0; k < len(ps); k += 1 {
		// A colon form (38:2::R:G:B) is one parameter.
		p := ps[k]
		if colon := strings.index_byte(p, ':'); colon >= 0 {
			p = p[:colon]
			if p == "38" || p == "48" || p == "58" {
				continue
			}
		}
		switch p {
		case "", "0":
			dim = false
		case "2":
			dim = true
		case "22":
			dim = false
		case "38", "48", "58":
			if k + 1 < len(ps) {
				switch ps[k + 1] {
				case "5":
					k += 2
				case "2":
					k += 4
				}
			}
		}
	}
	return dim
}
