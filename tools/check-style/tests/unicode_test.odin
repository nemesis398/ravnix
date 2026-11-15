// ripgrep's \s is Unicode white space, and the Bash version took the motion
// and short-color searches from ripgrep. The port must find what the script
// finds, so white space is the Unicode White_Space property at the three
// places where the script used \s: before a motion key, between a motion key
// and its separator, and between a color property and its colon.
package check_style_tests

import "core:strings"
import "core:testing"
import cs ".."

// Every character of the White_Space property, as UTF-8, and a few look-alikes
// that are not white space.
WHITE_SPACE := [?]string {
	" ", "\t", "\n", "\v", "\f", "\r",
	"\u0085", "\xc2\xa0", "\xe1\x9a\x80", "\xe2\x80\x80", "\xe2\x80\x81", "\xe2\x80\x82", "\xe2\x80\x83", "\xe2\x80\x84", "\xe2\x80\x85", "\xe2\x80\x86", "\xe2\x80\x87", "\xe2\x80\x88",
	"\xe2\x80\x89", "\xe2\x80\x8a", "\xe2\x80\xa8", "\xe2\x80\xa9", "\xe2\x80\xaf", "\xe2\x81\x9f", "\xe3\x80\x80",
}
NOT_WHITE_SPACE := [?]string{"\xe2\x80\x8b", "\xe2\x80\x8c", "\xe2\x80\x8d", "\xe2\x81\xa0", "\xef\xbb\xbf", "\xe1\xa0\x8e", "\xc2\xad", "\xe2\x80\x90", "\xe3\x80\x81", "\xe1\x9a\x81", "\xe2\x80\xa7", "\xe2\x80\xae", "\xc2\xa1", "\u0086", "\u0084"}

@(test)
unicode_space_lengths :: proc(t: ^testing.T) {
	for w in WHITE_SPACE {
		testing.expectf(t, cs.unicode_space_at(w, 0) == len(w), "%q is white space of %d bytes", w, len(w))
		// Only at its own start.
		if len(w) > 1 {
			testing.expectf(t, cs.unicode_space_at(w, 1) == 0, "%q is white space inside", w)
		}
	}
	for w in NOT_WHITE_SPACE {
		testing.expectf(t, cs.unicode_space_at(w, 0) == 0, "%q is no white space", w)
	}
	// Broken sequences, a cut at the end, and the ends of the string.
	for bad in ([?]string{"\xc2", "\xe2\x80", "\xe2", "\xe3\x80", "\xa0", "\x80", "\xff", "\xc2\x20", "\xe2\x80\x20", "\xe1\x9a", ""}) {
		testing.expectf(t, cs.unicode_space_at(bad, 0) == 0, "%q is no character", bad)
	}
	testing.expect_value(t, cs.unicode_space_at("a", 5), 0)
	testing.expect_value(t, cs.unicode_space_at("a", -1), 0)
	testing.expect_value(t, cs.skip_unicode_space("\u00a0\u3000 \tx", 0), 7)
	testing.expect_value(t, cs.skip_unicode_space("x", 0), 0)
}

// Each white space character at each of the three places finds what the
// script finds.
@(test)
every_white_space_character_counts_at_the_three_places :: proc(t: ^testing.T) {
	for w in WHITE_SPACE {
		if w == "\n" || w == "\v" || w == "\f" || w == "\r" {
			// A line end is not inside a line; \v \f are white space to both
			// versions already, tested below with the others.
			continue
		}
		f := enter(t)
		put(t, f, "modules/boundary.conf", strings.concatenate({"foo", w, "transition: all 1s\n"}, context.temp_allocator))
		put(t, f, "modules/separator.conf", strings.concatenate({"transition", w, "= 1s\n"}, context.temp_allocator))
		put(t, f, "modules/quote.conf", strings.concatenate({"\"animation\"", w, ": x\n"}, context.temp_allocator))
		put(t, f, "modules/property.conf", strings.concatenate({"color", w, ": #abc;\n"}, context.temp_allocator))
		status, out, _ := check(f, ".")
		testing.expectf(t, status == 1, "%q: exit %d", w, status)
		want := "modules/boundary.conf:1:motion\nmodules/property.conf:1:hex-color\nmodules/quote.conf:1:motion\nmodules/separator.conf:1:motion\n"
		testing.expectf(t, out == want, "%q: %q", w, out)
	}
}

@(test)
vertical_tab_and_form_feed_are_white_space_as_before :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.conf", "foo\vtransition: x\nfoo\ftransition: x\ntransition\v= 1s\ncolor\f: #abc;\n")
	expect_hits(t, f, "modules/a.conf:1:motion", "modules/a.conf:2:motion", "modules/a.conf:3:motion", "modules/a.conf:4:hex-color")
}

@(test)
look_alikes_and_broken_sequences_are_no_white_space :: proc(t: ^testing.T) {
	f := enter(t)
	for w, i in NOT_WHITE_SPACE {
		name := strings.concatenate({"modules/n", itoa(i), ".conf"}, context.temp_allocator)
		put(t, f, name, strings.concatenate({"foo", w, "transition: x\ntransition", w, "= 1s\ncolor", w, ": #abc;\n"}, context.temp_allocator))
	}
	put(t, f, "modules/broken.conf", "foo\xc2transition: x\nfoo\xe2\x80transition: x\nfoo\xa0transition: x\ncolor\xc2: #abc;\ntransition\xe2\x80= 1s\n")
	expect_clean(t, f)
}

@(test)
white_space_inside_the_value_and_after_the_separator_is_not_skipped :: proc(t: ^testing.T) {
	f := enter(t)
	// After = the script skips ASCII white space only: a value of a no-break
	// space and "none" is not "none".
	put(t, f, "modules/a.conf", "transition = \u00a0none\ntransition = none\n")
	expect_hits(t, f, "modules/a.conf:1:motion")
}

@(test)
a_multibyte_boundary_gives_the_match_text_its_whole_character :: proc(t: ^testing.T) {
	f := enter(t)
	// A class selector after a no-break space: the match starts with the dot
	// only when the space is the boundary; the selector rule sees a dot at the
	// start of the text of the match, as for an ASCII space.
	put(t, f, "a.css", "\u00a0.animation-paused:hover { color: red; }\n")
	put(t, f, "b.css", "\u00a0animation: x;\n")
	expect_hits(t, f, "b.css:1:motion")
}

// ripgrep reads a file after its byte order mark: a UTF-8 one is dropped (so
// a rule anchored at the start of the line still sees the start), and a
// UTF-16 file is read as text. The script read every file through ripgrep.

// ascii16 is s as UTF-16 with a byte order mark.
ascii16 :: proc(s: string, little: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\xff\xfe" if little else "\xfe\xff")
	for c in transmute([]u8)s {
		if little {
			strings.write_byte(&b, c)
			strings.write_byte(&b, 0)
		} else {
			strings.write_byte(&b, 0)
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

@(test)
a_utf8_byte_order_mark_at_the_start_of_a_file_is_dropped :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.conf", "\xef\xbb\xbftransition: all 1s\n")
	put(t, f, "modules/b.conf", "\xef\xbb\xbfcolor: #abc;\nanimation: x\n")
	// Only at the start of the file: in the middle it is a character, and the
	// word before the key is not a boundary.
	put(t, f, "modules/c.conf", "x\n\xef\xbb\xbftransition: all 1s\n")
	// A mark alone, a cut one, and an empty file.
	put(t, f, "modules/d.conf", "\xef\xbb\xbf")
	put(t, f, "modules/e.conf", "\xef\xbb")
	put(t, f, "modules/f.conf", "\xef")
	expect_hits(t, f, "modules/a.conf:1:motion", "modules/b.conf:1:hex-color", "modules/b.conf:2:motion")
}

@(test)
a_utf16_file_with_a_byte_order_mark_is_read_as_text :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/le.conf", ascii16("transition: all 1s\nfine\n", true))
	put(t, f, "modules/be.conf", ascii16("fine\ncolor: #abc;\n", false))
	// Not at the start of the file after a clean first line, with CRLF.
	put(t, f, "modules/crlf.conf", ascii16("fine\r\nanimation: x\r\n", true))
	// A surrogate pair, a lone surrogate and a byte left over do not stop it.
	put(t, f, "modules/pairs.conf", "\xff\xfe\x3d\xd8\x00\xde \x00\x3d\xd8 \x00\x00\xdc \x00t\x00r\x00a\x00n\x00s\x00i\x00t\x00i\x00o\x00n\x00:\x00 \x001\x00s\x00\n\x00x")
	// Only a mark, and a mark and one byte.
	put(t, f, "modules/mark.conf", "\xff\xfe")
	put(t, f, "modules/odd.conf", "\xfe\xff\x00")
	expect_hits(
		t,
		f,
		"modules/be.conf:2:hex-color",
		"modules/crlf.conf:2:motion",
		"modules/le.conf:1:motion",
		"modules/pairs.conf:1:motion",
	)
}

// ripgrep's patterns do not cross a byte that is no UTF-8: a keyword right
// after one starts the text a window rule judges, a value ends at one, and a
// comment line that holds one is no comment line to the patterns that read it
// to its end.
@(test)
a_byte_that_is_no_utf8_ends_what_a_rule_reads :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.conf", "\xffradius=3\n")
	put(t, f, "modules/b.conf", "radius=0\xff5\n")
	put(t, f, "modules/c.conf", "\xe9opacity = 0.5\n")
	put(t, f, "modules/d.conf", "opacity = 1\xff0.5\n")
	put(t, f, "modules/e.conf", "/*@keyframes\xa0\n* \x80@keyframes\n")
	// Still comment lines: they stay open or are a line comment, and the
	// byte is not read by their pattern.
	put(t, f, "modules/f.conf", "/* note transition: x\n; \xe9 transition: x\n// \xe9 transition: x\n")
	// And a line of valid text of the same shapes is a comment line.
	put(t, f, "modules/g.conf", "/*@keyframes\n* @keyframes x\n")
	expect_hits(t, f, "modules/a.conf:1:radius", "modules/c.conf:1:opacity", "modules/e.conf:1:motion", "modules/e.conf:2:motion")
}

@(test)
valid_runs_are_found_and_broken_bytes_end_them :: proc(t: ^testing.T) {
	testing.expect_value(t, cs.valid_run(""), 0)
	testing.expect_value(t, cs.valid_run("abc"), 3)
	testing.expect_value(t, cs.valid_run("a\xc3\xa9b"), 4)
	testing.expect_value(t, cs.valid_run("ab\xffcd"), 2)
	testing.expect_value(t, cs.valid_run("\xffab"), 0)
	testing.expect_value(t, cs.valid_run("ab\xe2\x80"), 2)
	testing.expect_value(t, cs.valid_run("ab\xc2"), 2)
	testing.expect_value(t, cs.valid_run("\xef\xbf\xbd"), 3)
	testing.expect_value(t, cs.valid_run("a\x80"), 1)
	// Overlong and surrogate forms are not UTF-8.
	testing.expect_value(t, cs.valid_run("\xc0\xaf"), 0)
	testing.expect_value(t, cs.valid_run("\xed\xa0\x80"), 0)
}
