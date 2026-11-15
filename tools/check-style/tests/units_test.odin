// The small procedures on their own: what the rules are made of. The
// fixtures in the other files reach them through the whole program; these
// pin down the corners that a fixture would need many lines to reach.
package check_style_tests

import "core:testing"
import cs ".."

@(test)
below_one_reads_the_numbers_of_a_config :: proc(t: ^testing.T) {
	yes := [?]string{"0", "0.9", ".5", "0.", "00.5", "90%", "99.99%", "0%", ".5%", "000", "0.99999999999999999999"}
	no := [?]string{"1", "1.0", "1.", "10", "100%", "100.0%", "250%", "", ".", "%", "x", "0.5.5", "-0.5", "1e-1", "0,5", " 0.5", "0.5 ", "1%%"}
	for v in yes {
		testing.expectf(t, cs.below_one(v), "%q is below one", v)
	}
	for v in no {
		testing.expectf(t, !cs.below_one(v), "%q is not below one", v)
	}
}

@(test)
below_one_takes_numbers_of_any_length :: proc(t: ^testing.T) {
	// No overflow: the digits are read as text.
	testing.expect(t, !cs.below_one("99999999999999999999999999999999999999"))
	testing.expect(t, cs.below_one("0000000000000000000000000000000000.5"))
	testing.expect(t, !cs.below_one("100000000000000000000000000000000000%"))
}

@(test)
strip_comments_cuts_closed_spans_and_the_open_end :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	Case :: struct {
		in_, want: string,
	}
	cases := [?]Case {
		{"a", "a"},
		{"a /* x */ b", "a   b"},
		{"a /* x */ b /* y */ c", "a   b   c"},
		{"a /* x", "a "},
		{"/* x */ border-radius: 4px;", "  border-radius: 4px;"},
		{"x /* a /* b */ c */ y", "x   y"},
		{"/*/ x */ y", "  y"},
		{"/*/", ""},
		{"/* x */* y */", ""},
		{"a */ b /* c */ d", "a */ b   d"},
		{"/**/ a", "  a"},
		{"/***/ a", "  a"},
		{"/* x */ /* open", "  "},
		{"", ""},
	}
	for c in cases {
		testing.expectf(t, cs.strip_comments(c.in_, &buf) == c.want, "strip_comments(%q) = %q, want %q", c.in_, cs.strip_comments(c.in_, &buf), c.want)
	}
}

@(test)
comment_lines_by_kind :: proc(t: ^testing.T) {
	Case :: struct {
		line: string,
		kind: cs.Kind,
		want: bool,
	}
	cases := [?]Case {
		{"# a", .Nix, true},
		{"#", .Nix, true},
		{"#a", .Nix, false},
		{"  ; x", .Code, true},
		{"/* open", .Css, true},
		{"/* closed */", .Css, true},
		{"/* closed */  ", .Css, true},
		{"/* closed */ a { }", .Css, false},
		{"/*/", .Css, true},
		{"*/", .Css, true},
		{" **/ ", .Css, true},
		{"*", .Css, true},
		{" * text", .Css, true},
		{" * { border-radius: 4px; }", .Css, false},
		{"* button { }", .Css, false},
		{"*, *::before { }", .Css, false},
		{"* .a", .Css, false},
		{"* > a", .Css, false},
		{"// c", .Css, true},
		{"// c", .Code, true},
		{"// c", .Nix, false},
		{"// c", .Lua, false},
		{"-- c", .Lua, true},
		{"-- c", .Code, false},
		{"# a", .Docs, false},
		{"", .Css, false},
		{"   ", .Css, false},
	}
	for c in cases {
		testing.expectf(t, cs.comment_line(c.line, c.kind) == c.want, "comment_line(%q, %v) want %v", c.line, c.kind, c.want)
	}
}

@(test)
radius_and_corner_values :: proc(t: ^testing.T) {
	for v in ([?]string{" 4px", "0 0 0 1px", "var(--r)", "calc(0px + 1px)", "env(x)", ".5em", "0 4px", "9"}) {
		testing.expectf(t, cs.radius_value(v), "%q is a radius", v)
	}
	for v in ([?]string{" 0", "0px !important", "0 0 0 0 }", "0 # 5px", "0;5", "", "0.0", "none"}) {
		testing.expectf(t, !cs.radius_value(v), "%q is no radius", v)
	}
	for v in ([?]string{"true", "10", "1", "\"yes\""}) {
		testing.expectf(t, cs.corners_value(v), "%q rounds corners", v)
	}
	for v in ([?]string{"", "0", "false", "off", "no", "none", "\"0\"", " 0 ", "0px", "0.0", "false # x", "0, "}) {
		testing.expectf(t, !cs.corners_value(v), "%q does not round corners", v)
	}
}

@(test)
the_lock_ring_gauge_is_three_keys :: proc(t: ^testing.T) {
	for k in ([?]string{"indicator-radius", "indicator_radius", "ring-radius", "ring_radius", "lock-ring-radius", "lock_ring_radius", "lock-ring_radius"}) {
		testing.expectf(t, cs.lock_ring_gauge(k), "%q is the gauge", k)
	}
	for k in ([?]string{"radius", "spring_radius", "ringradius", "focus_ring_radius", "indicator", "indicator radius", "indicator-radius-x", "", "-radius", "_radius"}) {
		testing.expectf(t, !cs.lock_ring_gauge(k), "%q is no gauge", k)
	}
}

@(test)
opacity_keys_are_words_and_separators :: proc(t: ^testing.T) {
	for k in ([?]string{"opacity", "window_opacity", "a-b_opacity", "x1-opacity", "alpha", "bg_alpha", "window-alpha", "notification_alpha"}) {
		testing.expectf(t, cs.opacity_key(k), "%q is an opacity key", k)
	}
	for k in ([?]string{"", "xopacity", "_opacity", "-opacity", "a__opacity", "a_-opacity", "smoothing_alpha", "learning-alpha", "bg__alpha", "a_b_alpha", "opacity_", "alphas"}) {
		testing.expectf(t, !cs.opacity_key(k), "%q is no opacity key", k)
	}
}

@(test)
color_keys_name_a_part_of_a_surface :: proc(t: ^testing.T) {
	for k in ([?]string{"color", "ring-color", "backgroundcolour", "background", "bg", "key_bg_x", "text", "border", "prompt-text", "separator-ring-color"}) {
		testing.expectf(t, cs.is_color_key(k), "%q is a color key", k)
	}
	for k in ([?]string{"", "inputs", "context", "framework", "matched", "textual", "bgx", "rev", "x-y-z"}) {
		testing.expectf(t, !cs.is_color_key(k), "%q is no color key", k)
	}
}

@(test)
doubled_digits_are_pairs_of_one_digit :: proc(t: ^testing.T) {
	testing.expect(t, cs.doubled_digits("ffeedd"))
	testing.expect(t, cs.doubled_digits("aabbccdd"))
	testing.expect(t, !cs.doubled_digits("facade"))
	testing.expect(t, !cs.doubled_digits("deadbeef"))
}

@(test)
init_starts_are_found_only_at_the_start_of_a_line :: proc(t: ^testing.T) {
	rest, ok := cs.init_start("  %%{ init : {x}}%%")
	testing.expect(t, ok)
	testing.expect_value(t, rest, " {x}}%%")
	rest, ok = cs.init_start("%%{initialize:y")
	testing.expect(t, ok)
	testing.expect_value(t, rest, "y")
	for line in ([?]string{"", "%%{init", "%%{ini: x", "%%{initx: x", "x %%{init: x", "%{init: x", "%%{init x", "%%[init: x"}) {
		_, found := cs.init_start(line)
		testing.expectf(t, !found, "%q starts no block", line)
	}
}

@(test)
hits_sort_as_sort_in_the_c_locale_does :: proc(t: ^testing.T) {
	a := cs.Hit{"a", 2, .Radius}
	b := cs.Hit{"a", 10, .Hex_Color}
	c := cs.Hit{"a", 10, .Radius}
	d := cs.Hit{"B", 1, .Hex_Color}
	e := cs.Hit{"a/b", 1, .Hex_Color}
	f := cs.Hit{"a.css", 1, .Hex_Color}
	testing.expect(t, cs.hit_less(a, b))
	testing.expect(t, cs.hit_less(b, c))
	testing.expect(t, cs.hit_less(d, a))
	// "a" < "a.css" < "a/b": shorter first, then by byte.
	testing.expect(t, cs.hit_less(a, f))
	testing.expect(t, cs.hit_less(f, e))
}
