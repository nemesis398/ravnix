// The screen check: what claude-roll reads from a pane before it types
// /exit there. Only an empty input box of Claude Code, with no dialog, no
// running turn and nothing typed in it, is Ready; a dialog is never typed
// into (Review Focus 3). The screens are in testdata/screens, in the form
// `herdr agent read PANE --source visible --format ansi` prints them;
// tools/claude-roll/README.md says which were recorded and which rebuilt.
package claude_roll_tests

import "core:strings"
import "core:testing"
import roll ".."

Screen_Case :: struct {
	name:    string,
	screen:  string,
	verdict: roll.Verdict,
	// A word of the reason, so the reason says the right thing.
	why:     string,
}

SCREENS := [?]Screen_Case {
	{"idle with a prompt suggestion", #load("../testdata/screens/idle-suggestion.txt", string), .Ready, ""},
	{"idle with an empty input", #load("../testdata/screens/idle-empty.txt", string), .Ready, ""},
	{"idle, named session", #load("../testdata/screens/idle-named.txt", string), .Ready, ""},
	{"unsent text in the input", #load("../testdata/screens/idle-draft.txt", string), .Not_Ready, "unsent"},
	{"unsent text on the input's second line", #load("../testdata/screens/idle-draft-second-line.txt", string), .Not_Ready, "unsent"},
	{"a turn still running (spinner)", #load("../testdata/screens/working-spinner.txt", string), .Not_Ready, "turn"},
	{"a turn still running (esc to interrupt)", #load("../testdata/screens/working-interrupt.txt", string), .Not_Ready, "turn"},
	{"background agents still running", #load("../testdata/screens/background-agents.txt", string), .Not_Ready, "turn"},
	{"Bash permission prompt", #load("../testdata/screens/permission-bash.txt", string), .Dialog, "dialog"},
	{"edit permission prompt", #load("../testdata/screens/permission-edit.txt", string), .Dialog, "dialog"},
	{"Resume this conversation? under the input", #load("../testdata/screens/resume-below.txt", string), .Dialog, "dialog"},
	{"Resume this conversation? above the input", #load("../testdata/screens/resume-above.txt", string), .Dialog, "dialog"},
	{"Resume this conversation? in place of the input", #load("../testdata/screens/resume-replacing.txt", string), .Dialog, "dialog"},
	{"model picker", #load("../testdata/screens/model-picker.txt", string), .Dialog, "dialog"},
	{"a question form", #load("../testdata/screens/ask-question.txt", string), .Dialog, "dialog"},
	{"a question form with tabs", #load("../testdata/screens/question-tabs.txt", string), .Dialog, "dialog"},
	{"a question form without its footer", #load("../testdata/screens/question-tabs-no-footer.txt", string), .Not_Ready, "prompt"},
	{"vim NORMAL mode", #load("../testdata/screens/vim-normal.txt", string), .Not_Ready, "NORMAL"},
	{"bash mode", #load("../testdata/screens/bash-mode.txt", string), .Not_Ready, "prompt"},
	{"the shell, Claude Code gone", #load("../testdata/screens/shell.txt", string), .Not_Ready, "box"},
	{"the transcript viewer", #load("../testdata/screens/transcript-viewer.txt", string), .Not_Ready, ""},
	{"scrolled up, no box on the screen", #load("../testdata/screens/scrolled.txt", string), .Not_Ready, "box"},
	{"an empty read", #load("../testdata/screens/empty.txt", string), .Not_Ready, "box"},
}

@(test)
classifies_every_recorded_screen :: proc(t: ^testing.T) {
	for c in SCREENS {
		got := roll.classify_screen(c.screen)
		testing.expectf(t, got.verdict == c.verdict, "%s: got %v (%s), want %v", c.name, got.verdict, got.reason, c.verdict)
		if c.why != "" {
			testing.expectf(t, strings.contains(got.reason, c.why), "%s: reason %q does not say %q", c.name, got.reason, c.why)
		}
		if got.verdict != .Ready {
			testing.expectf(t, got.reason != "", "%s: a screen that is not ready says why", c.name)
		}
	}
}

// The screens without their ANSI codes, as `--format text` prints them,
// lose the dim that tells a suggestion from a draft: then any text in the
// input is a draft, and nothing is typed.
@(test)
without_colors_a_suggestion_counts_as_unsent_text :: proc(t: ^testing.T) {
	plain := strip_esc(#load("../testdata/screens/idle-suggestion.txt", string))
	defer delete(plain)
	got := roll.classify_screen(plain)
	testing.expect_value(t, got.verdict, roll.Verdict.Not_Ready)
	// And the dialogs stay dialogs.
	dialog := strip_esc(#load("../testdata/screens/resume-below.txt", string))
	defer delete(dialog)
	testing.expect_value(t, roll.classify_screen(dialog).verdict, roll.Verdict.Dialog)
}

// A color whose parameters hold a 2 (38;2;R;G;B) is a color, not dim: text
// in gray is typed text.
@(test)
a_true_color_is_not_dim :: proc(t: ^testing.T) {
	screen := box_screen("❯\xc2\xa0\x1b[0m\x1b[38;2;2;2;2mrm -r build\x1b[0m")
	defer delete(screen)
	got := roll.classify_screen(screen)
	testing.expect_value(t, got.verdict, roll.Verdict.Not_Ready)
	testing.expect(t, strings.contains(got.reason, "unsent"))

	dim := box_screen("❯\xc2\xa0\x1b[0;2mrun the tests\x1b[22m")
	defer delete(dim)
	testing.expect_value(t, roll.classify_screen(dim).verdict, roll.Verdict.Ready)

	// 22 ends dim: what follows is typed.
	half := box_screen("❯\xc2\xa0\x1b[2mrun\x1b[22m the tests")
	defer delete(half)
	testing.expect_value(t, roll.classify_screen(half).verdict, roll.Verdict.Not_Ready)

	// A dim prompt glyph and a short draft: the draft still counts.
	glyph := box_screen("\x1b[2m❯\x1b[0m abc")
	defer delete(glyph)
	testing.expect_value(t, roll.classify_screen(glyph).verdict, roll.Verdict.Not_Ready)

	// A 256-color 38;5;2 is no dim either.
	c256 := box_screen("❯\xc2\xa0\x1b[38;5;2mls\x1b[0m")
	defer delete(c256)
	testing.expect_value(t, roll.classify_screen(c256).verdict, roll.Verdict.Not_Ready)
}

// A prompt line that is not exactly ❯ and a blank: a menu row in the box,
// the bash mode's !, a ❯ glued to text.
@(test)
only_claudes_own_prompt_counts :: proc(t: ^testing.T) {
	for line in ([]string{"❯ 1. Yes", "! ", "❯x", "> ", "❯\xc2\xa0\x1b[0m\x1b[7mx\x1b[0m"}) {
		screen := box_screen(line)
		got := roll.classify_screen(screen)
		testing.expectf(t, got.verdict != .Ready, "%q: %v", line, got.verdict)
		delete(screen)
	}
	for line in ([]string{"❯", "❯ ", "❯\xc2\xa0", "  ❯\xc2\xa0  ", "❯\xc2\xa0\x1b[0m\x1b[7m \x1b[0m"}) {
		screen := box_screen(line)
		got := roll.classify_screen(screen)
		testing.expectf(t, got.verdict == .Ready, "%q: %v (%s)", line, got.verdict, got.reason)
		delete(screen)
	}
}

// Input that is no screen at all must not crash the check or pass it:
// broken escapes, a lone ESC at the end, NUL bytes, invalid UTF-8, a huge
// line, an OSC title without its end.
@(test)
survives_malformed_input :: proc(t: ^testing.T) {
	bad := []string {
		"\x1b",
		"\x1b[",
		"\x1b[38;2;",
		"\x1b]0;title",
		"\x1b]0;title\x07",
		"\x00\x00\x00",
		"\xff\xfe❯\xc3",
		"────\r\n❯\xc2\xa0\x1b[",
		"────\n❯ \n────\x1b[2",
	}
	for s in bad {
		got := roll.classify_screen(s)
		testing.expectf(t, got.verdict != .Ready || s == "────\n❯ \n────\x1b[2", "%q passed as ready", s)
	}
	huge := strings.repeat("x", 1 << 20)
	defer delete(huge)
	testing.expect(t, roll.classify_screen(huge).verdict == .Not_Ready)
	many := strings.repeat("────\n", 20_000)
	defer delete(many)
	testing.expect(t, roll.classify_screen(many).verdict == .Not_Ready)
}

// A dialog word in the footer under an otherwise good box.
@(test)
a_dialog_anywhere_on_the_screen_wins :: proc(t: ^testing.T) {
	base := box_screen("❯\xc2\xa0")
	defer delete(base)
	screen := strings.concatenate({base, "\r\n  Enter to confirm · Esc to cancel"})
	defer delete(screen)
	testing.expect_value(t, roll.classify_screen(screen).verdict, roll.Verdict.Dialog)
}

// A box with more under it than a status line and a mode line is not the
// input box at the bottom of the screen.
@(test)
the_box_is_at_the_bottom :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	base := box_screen("❯\xc2\xa0")
	defer delete(base)
	strings.write_string(&b, base)
	for _ in 0 ..< 12 {
		strings.write_string(&b, "\r\nsome output")
	}
	testing.expect_value(t, roll.classify_screen(strings.to_string(b)).verdict, roll.Verdict.Not_Ready)
}

RULE :: "────────────────────────────────────────"

// box_screen returns a screen whose input line is prompt. The caller
// deletes it.
box_screen :: proc(prompt: string) -> string {
	return strings.concatenate({"⏺ Done.\r\n\r\n", RULE, "\r\n", prompt, "\r\n", RULE, "\r\n  status line"})
}

// strip_esc drops every ESC [ ... final sequence, as --format text does.
strip_esc :: proc(s: string) -> string {
	b := strings.builder_make()
	i := 0
	for i < len(s) {
		if s[i] == 0x1b && i + 1 < len(s) && s[i + 1] == '[' {
			j := i + 2
			for j < len(s) && !(s[j] >= 0x40 && s[j] <= 0x7e) {
				j += 1
			}
			i = j + 1
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}
