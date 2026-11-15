// What the Bash version never handled, or only by accident: malformed
// input, bytes that are no text, paths of odd shapes, files that cannot be
// read, a shared theme that is missing or odd, and lines built to make a
// careless scanner take quadratic time.
package check_style_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import cs ".."

// check_with runs the program with a configuration of the test's.
check_with :: proc(f: ^Fixture, cfg: cs.Config, args: ..string) -> (status: int, out, err: string) {
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	o := strings.builder_make()
	e := strings.builder_make()
	status = cs.run(args, cfg, strings.to_writer(&o), strings.to_writer(&e))
	return status, strings.to_string(o), strings.to_string(e)
}

// Paths.

@(test)
an_empty_argument_is_a_missing_path :: proc(t: ^testing.T) {
	f := enter(t)
	status, _, err := check(f, "")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "no such file or directory")
}

@(test)
a_missing_path_after_good_ones_gives_no_hits :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, "a.css", "nowhere")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, out, "")
}

@(test)
a_directory_with_a_trailing_slash_is_walked_as_given :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	status, out, _ := check(f, "modules/")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "modules/y.nix:1:hex-color\n")
	status, out, _ = check(f, "modules///")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "modules/y.nix:1:hex-color\n")
}

@(test)
a_file_with_a_trailing_slash_is_no_file :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; }\n")
	status, _, err := check(f, "a.css/")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "no such file or directory")
}

@(test)
a_link_to_a_directory_is_not_entered_even_with_a_slash :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "real/modules/y.nix", "c = \"#cba6f7\";\n")
	symlink(t, "real", join(f, "tree/alias"))
	// A dangling link is skipped as quietly as a good one.
	symlink(t, "nowhere", join(f, "tree/dangling.css"))
	for arg in ([]string{"alias", "dangling.css"}) {
		status, out, _ := check(f, arg)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, out, "")
	}
	status, out, _ := check(f, "alias/")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "")
	// The real directory is judged, and a link in it is not followed.
	symlink(t, "../real", join(f, "tree/real/modules/loop"))
	status, out, _ = check(f, "real")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "real/modules/y.nix:1:hex-color\n")
}

@(test)
a_fifo_is_neither_a_file_nor_a_directory :: proc(t: ^testing.T) {
	f := enter(t)
	path := join(f, "tree/pipe.css")
	testing.expect_value(t, linux.mknod(strings.clone_to_cstring(path, context.temp_allocator), {.IFIFO, .IRUSR, .IWUSR}, 0), linux.Errno.NONE)
	// The walk does not open it, so it cannot hang the check.
	expect_clean(t, f)
	status, _, err := check(f, "pipe.css")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "neither a file nor a directory")
}

@(test)
a_deep_tree_is_walked :: proc(t: ^testing.T) {
	f := enter(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "modules")
	for _ in 0 ..< 150 {
		strings.write_string(&b, "/d")
	}
	strings.write_string(&b, "/x.css")
	put(t, f, strings.to_string(b), "a { border-radius: 4px; }\n")
	status, out, _ := check(f, ".")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, lines(out), 1)
	expect_contains(t, out, "/x.css:1:radius")
}

@(test)
what_is_not_judged_is_not_opened :: proc(t: ^testing.T) {
	if linux.geteuid() == 0 {
		return
	}
	f := enter(t)
	put(t, f, "tests/locked.css", "a { border-radius: 4px; }\n")
	put(t, f, "readme.txt", "x\n")
	put(t, f, "node_modules/p/locked/a.css", "a\n")
	put(t, f, ".git/objects/locked/a.css", "a\n")
	for p in ([]string{"tests/locked.css", "readme.txt", "node_modules/p/locked", ".git/objects/locked"}) {
		linux.chmod(strings.clone_to_cstring(join(f, strings.concatenate({"tree/", p}, context.temp_allocator)), context.temp_allocator), {})
	}
	expect_clean(t, f)
}

@(test)
two_hits_for_one_line_are_two_lines_and_a_repeat_is_one :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; border-top-left-radius: 2px; opacity: .5; opacity: .4; }\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:1:radius")
	status, _, err := check(f, ".")
	testing.expect_value(t, status, 1)
	expect_contains(t, err, "2 hits")
}

// Bytes that are no text.

@(test)
invalid_utf8_and_nul_bytes_are_bytes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; }\xff\xfe\x00\n\x00\x00\nb { opacity: 0.5 }\xc3\x28\n")
	expect_hits(t, f, "a.css:1:radius", "a.css:3:opacity")
}

@(test)
a_line_end_in_the_middle_of_a_cr_pair_is_not_one :: proc(t: ^testing.T) {
	f := enter(t)
	// A lone CR is no line end: the whole text is line 1.
	put(t, f, "a.css", "a { color: red; }\rb { border-radius: 4px; }\n")
	expect_hits(t, f, "a.css:1:radius")
}

@(test)
a_file_of_many_short_lines_numbers_them_right :: proc(t: ^testing.T) {
	f := enter(t)
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 200_000 {
		strings.write_string(&b, "a { color: red; }\n")
	}
	strings.write_string(&b, "a { border-radius: 4px; }\n")
	put(t, f, "big.css", strings.to_string(b))
	expect_hits(t, f, "big.css:200001:radius")
}

@(test)
a_line_over_the_limit_is_refused_not_read :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", strings.concatenate({"/* ", strings.repeat("x", 3000, context.temp_allocator), " */\na { border-radius: 4px; }\n"}, context.temp_allocator))
	cfg := cs.Config {
		cwd        = f.tree,
		theme      = f.theme,
		line_limit = 1000,
	}
	status, out, err := check_with(f, cfg, ".")
	testing.expect_value(t, status, 2)
	testing.expect_value(t, out, "")
	expect_contains(t, err, "a line is longer than 1000 bytes")
	cfg.line_limit = 4000
	status, out, _ = check_with(f, cfg, ".")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "a.css:2:radius\n")
	// A file whose last line has no line end and is over the limit.
	put(t, f, "a.css", strings.repeat("y", 5000, context.temp_allocator))
	cfg.line_limit = 1000
	status, _, _ = check_with(f, cfg, ".")
	testing.expect_value(t, status, 2)
}

// The shared theme.

@(test)
a_theme_that_is_a_directory_is_bad_usage :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{init: {\"theme\": \"base\"}}%%\n")
	f.theme = f.tree
	status, _, err := check(f, ".")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "cannot read the shared Mermaid theme")
}

@(test)
no_theme_at_all_is_bad_usage_only_when_a_block_needs_it :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "no block\n")
	f.theme = ""
	status, _, _ := check(f, ".")
	testing.expect_value(t, status, 0)
	put(t, f, "docs/a.md", "%%{init: {}}%%\n")
	err: string
	status, _, err = check(f, ".")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "cannot read the shared Mermaid theme")
}

@(test)
an_empty_theme_is_matched_by_an_empty_block_only :: proc(t: ^testing.T) {
	f := enter(t)
	put_file(t, f.theme, "  \n\t\n")
	put(t, f, "docs/a.md", "%%{init:}%%\n%%{init: \n  }%%\n")
	expect_clean(t, f)
	put(t, f, "docs/b.md", "%%{init: x}%%\n")
	expect_hits(t, f, "docs/b.md:1:mermaid-init")
}

@(test)
a_block_with_windows_line_ends_matches :: proc(t: ^testing.T) {
	f := enter(t)
	text, _ := strings.replace_all(SHARED_BLOCK, "\n", "\r\n", context.temp_allocator)
	put(t, f, "docs/a.md", strings.concatenate({"x\r\n", text, "y\r\n"}, context.temp_allocator))
	expect_clean(t, f)
}

@(test)
two_blocks_in_a_file_are_judged_each :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", strings.concatenate({SHARED_BLOCK, "text\n%%{init: {\"theme\": \"dark\"}}%%\n", SHARED_BLOCK}, context.temp_allocator))
	expect_hits(t, f, "docs/a.md:5:mermaid-init")
}

@(test)
a_block_that_is_longer_than_the_theme_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	text, _ := strings.replace(SHARED_BLOCK, "}}}%%", "} }} }, \"extra\": 1}%%", 1, context.temp_allocator)
	put(t, f, "docs/a.md", text)
	expect_hits(t, f, "docs/a.md:1:mermaid-init")
}

@(test)
a_block_that_is_a_prefix_of_the_theme_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{init: {\"theme\": \"base\"}}%%\n")
	expect_hits(t, f, "docs/a.md:1:mermaid-init")
}

@(test)
a_hex_color_inside_an_unclosed_block_is_the_blocks_business :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{init: {\"background\": \"#cba6f7\"\nmore #cba6f7\n")
	expect_hits(t, f, "docs/a.md:1:mermaid-init")
}

@(test)
a_block_in_code_is_a_block_too :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "x = ''\n%%{init: {\"theme\": \"dark\"}}%%\n'';\n")
	expect_hits(t, f, "modules/a.nix:2:mermaid-init")
}

// Lines built to hurt: each must come back in a few seconds.

timed :: proc(t: ^testing.T, f: ^Fixture, name, line: string, copies: int, want: ..string) {
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	start := time.now()
	put(t, f, "p.css", strings.concatenate({strings.repeat(line, copies), "\n"}))
	status, _, _ := check(f, ".")
	spent := time.since(start)
	testing.expectf(t, spent < 10 * time.Second, "%s: %v", name, spent)
	testing.expectf(t, status == 0 || status == 1, "%s: exit %d", name, status)
	_ = want
}

@(test)
pathological_lines_take_linear_time :: proc(t: ^testing.T) {
	f := enter(t)
	cases := [?][2]string {
		{"color: ", "color:"},
		{"color then transparent", "color: x "},
		{"comments", "/* a "},
		{"closed comments", "/* a */ "},
		{"stars", "/*/*/*/ "},
		{"hashes", "#abc "},
		{"hashes colors", "#cba6f7 "},
		{"property hashes", "color: #abc "},
		{"radius", "radius "},
		{"border radius", "border-radius:"},
		{"keys", "a_radius = 1 "},
		{"opacity", "opacity: "},
		{"opacity sway", "opacity "},
		{"rgba", "rgba("},
		{"slash", "rgb(0 / "},
		{"alpha", "alpha "},
		{"transparent", "transparent "},
		{"transparent colon", "color:transparent "},
		{"animation", "animation "},
		{"motion match", "transition: "},
		{"keyframes", "@keyframes "},
		{"round", "round "},
		{"border rounded", "border "},
		{"define", "@define-color "},
		{"equals", "= "},
		{"blanks", " "},
		{"init", "%%{init: "},
	}
	for c in cases {
		timed(t, f, c[0], c[1], 400_000 / len(c[1]) + 1)
	}
}

// Corners of the rules that a mutation of the program survived until a test
// named them.

@(test)
a_hit_for_one_rule_in_the_middle_of_two_others_is_still_one :: proc(t: ^testing.T) {
	f := enter(t)
	// The hex rule says hex-color and opacity, the radius rule radius, and the
	// opacity rule opacity again: each once.
	put(t, f, "a.css", "a { color: #1e1e2ecc; border-radius: 4px; opacity: .5; }\n")
	expect_hits(t, f, "a.css:1:hex-color", "a.css:1:opacity", "a.css:1:radius")
}

@(test)
a_short_color_in_css_needs_no_property :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { margin: #abc; }\nb { foo: x#abc; }\n")
	put(t, f, "modules/b.nix", "x = ''margin: #abc;'';\n")
	expect_hits(t, f, "a.css:1:hex-color")
}

@(test)
a_color_is_not_glued_to_a_shell_expansion :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/shell.nix", "s = ''\n  echo ${#cba6f7} $#cba6f7 x$#cba6f7 &#cba6f7\n'';\n")
	expect_clean(t, f)
}

@(test)
only_a_full_alpha_is_opaque :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { color: #1e1e2eff; }\nb { color: #1e1e2eFF; }\nc { color: #1e1e2ef0; }\nd { color: #1e1e2e0f; }\ne { color: #abcF; }\nf { color: #abc0; }\n")
	expect_hits(t, f, "a.css:1:hex-color", "a.css:2:hex-color", "a.css:3:hex-color", "a.css:3:opacity", "a.css:4:hex-color", "a.css:4:opacity", "a.css:5:hex-color", "a.css:6:hex-color", "a.css:6:opacity")
}

@(test)
an_opacity_key_may_lead_with_a_dash :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { -webkit-opacity: 0.5; }\nb { --opacity: 0.5; }\n")
	expect_hits(t, f, "a.css:1:opacity")
}

@(test)
the_two_mocha_colors_without_a_letter_are_colors :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/x.conf", "background=181825\nborder=313244\nbackground=123456\ntext=ffffff\n")
	expect_hits(t, f, "modules/x.conf:1:hex-color", "modules/x.conf:2:hex-color", "modules/x.conf:4:hex-color")
}

@(test)
a_comment_line_ends_before_the_carriage_return :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "/* border-radius: 4px */\r\n/*\r\n * border-radius: 4px;\r\n */\r\na { color: red; }\r\n")
	expect_clean(t, f)
}

@(test)
a_class_selector_in_css_needs_no_comma_or_brace_at_the_end :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", ".animation-paused:hover\n{\n  color: red;\n}\n")
	put(t, f, "modules/b.nix", "x = ''\n.animation-paused:hover\n{ color: red; }\n'';\n")
	// In Nix the selector must end its line with , or {, or open the rule.
	expect_hits(t, f, "modules/b.nix:2:motion")
}

@(test)
a_block_with_tabs_matches_like_one_with_spaces :: proc(t: ^testing.T) {
	f := enter(t)
	text, _ := strings.replace_all(SHARED_BLOCK, "  ", "\t", context.temp_allocator)
	put(t, f, "docs/a.md", text)
	expect_clean(t, f)
}

@(test)
a_blank_line_in_a_block_changes_nothing :: proc(t: ^testing.T) {
	f := enter(t)
	text, _ := strings.replace(SHARED_BLOCK, "\"primaryColor\"", "\n\n  \"primaryColor\"", 1, context.temp_allocator)
	put(t, f, "docs/a.md", text)
	expect_clean(t, f)
}

@(test)
every_styling_extension_is_judged_and_images_fonts_and_locks_are_not :: proc(t: ^testing.T) {
	f := enter(t)
	for ext in ([]string{"css", "scss", "tcss", "rasi", "CSS"}) {
		put(t, f, strings.concatenate({"s/a.", ext}, context.temp_allocator), "a { border-radius: 4px; }\n")
	}
	for ext in ([]string{"ini", "conf", "toml", "jsonc", "kdl", "colors"}) {
		put(t, f, strings.concatenate({"s/b.", ext}, context.temp_allocator), "radius = 4\n")
	}
	for ext in ([]string{"svg", "png", "jpg", "jpeg", "gif", "ico", "webp", "ttf", "otf", "woff", "woff2", "lock", "SVG"}) {
		put(t, f, strings.concatenate({"modules/x.", ext}, context.temp_allocator), "a { border-radius: 4px; color: #cba6f7; }\n")
	}
	put(t, f, "docs/a.MD", "The accent is #cba6f7 and #1e1e2ecc.\n")
	put(t, f, "docs/b.mermaid", "A --> B; style A fill:#cba6f7\n")
	expect_hits(
		t,
		f,
		"docs/a.MD:1:hex-color",
		"docs/b.mermaid:1:hex-color",
		"s/a.CSS:1:radius",
		"s/a.css:1:radius",
		"s/a.rasi:1:radius",
		"s/a.scss:1:radius",
		"s/a.tcss:1:radius",
		"s/b.colors:1:radius",
		"s/b.conf:1:radius",
		"s/b.ini:1:radius",
		"s/b.jsonc:1:radius",
		"s/b.kdl:1:radius",
		"s/b.toml:1:radius",
	)
}

@(test)
a_file_without_an_extension_below_hosts_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "hosts/laptop/config", "opacity 0.5\nbackground = #cba6f7\n")
	put(t, f, "x/hosts/y/config", "border-radius: 3px\n")
	expect_hits(t, f, "hosts/laptop/config:1:opacity", "hosts/laptop/config:2:hex-color", "x/hosts/y/config:1:radius")
}

@(test)
tool_state_roots_given_as_files_are_not_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, ".worktrees/other/modules/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, ".superpowers/sdd/x.md", "c = #cba6f7\n")
	put(t, f, "scripts/tests/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tools/ravnix-x/tests/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tools/ravnix-x/testz/y.nix", "c = \"#cba6f7\";\n")
	for arg in ([]string{".worktrees/other/modules/x.nix", ".superpowers/sdd/x.md", "scripts/tests/y.nix", "tools/ravnix-x/tests/y.nix"}) {
		status, out, _ := check(f, arg)
		testing.expectf(t, status == 0 && out == "", "%s is judged: %d %q", arg, status, out)
	}
	expect_hits(t, f, "tools/ravnix-x/testz/y.nix:1:hex-color")
}

@(test)
the_current_directory_given_by_name_or_with_dots_is_the_root :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tests/z.css", "a { border-radius: 4px; }\n")
	// The absolute name of the current directory is the same tree as ".".
	status, out, _ := check(f, f.tree)
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, strings.concatenate({f.tree, "/modules/y.nix:1:hex-color\n"}, context.temp_allocator))
	// ".." from a directory of the tree is a root of its own, as any
	// directory outside the current one is: its modules/theme is a theme.
	sub := join(f, "tree/modules")
	status, out, _ = check_in(f, sub, "..")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "../modules/y.nix:1:hex-color\n")
}

@(test)
transparent_ends_in_each_way_a_value_ends :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { background: transparent !important; }\nb { fill: transparent; }\nc { stroke:transparent }\nd { box-shadow: 0 0 transparent, 0 0 red; }\ne { caret-color: transparent; }\nf { outline: 1px solid transparent; }\ng { border-color: transparent}\n")
	put(t, f, "b.css", "a { background: transparently; }\nb { fill: nottransparent x; }\nc { color: transparent-ish; }\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:2:opacity", "a.css:3:opacity", "a.css:4:opacity", "a.css:5:opacity", "a.css:6:opacity", "a.css:7:opacity")
}

@(test)
keyframes_with_a_vendor_prefix_and_not_as_a_prefix_of_a_word :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "@-webkit-keyframes x { }\n@-moz-keyframes y { }\n@keyframes-x { }\n")
	put(t, f, "b.css", "@keyframesfoo { }\n@keyframes_x { }\n@-keyframes z { }\n@--keyframes z { }\n")
	expect_hits(t, f, "a.css:1:motion", "a.css:2:motion", "a.css:3:motion")
}

@(test)
a_property_after_a_semicolon_may_wear_a_vendor_prefix_or_a_corner :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a;-moz-border-radius:4px\nb;outline-top-left-radius:4px\nc;border-radius:0!5\nd;-o-outline-radius: 3px\ne;border-top-left-radius:2px\n")
	expect_hits(t, f, "a.css:1:radius", "a.css:2:radius", "a.css:4:radius", "a.css:5:radius")
}

// $PWD is the current directory when it names it, so a path through a link
// stays as written; else the system's answer.
@(test)
the_current_directory_follows_pwd_when_pwd_names_it :: proc(t: ^testing.T) {
	f := enter(t)
	context.allocator = virtual.arena_allocator(&f.arena)
	context.temp_allocator = context.allocator
	here, herr := os.get_working_directory(context.allocator)
	testing.expect_value(t, herr, nil)
	link := join(f, "link")
	symlink(t, here, link)
	old, had := os.lookup_env("PWD", context.allocator)
	defer {
		if had {
			os.set_env("PWD", old)
		} else {
			os.unset_env("PWD")
		}
	}
	os.set_env("PWD", link)
	got, ok := cs.current_directory()
	testing.expect(t, ok)
	testing.expect_value(t, got, link)
	// A PWD that names another directory is ignored, and so is a relative or
	// a missing one.
	for other in ([]string{f.tree, "relative/path", join(f, "nowhere"), ""}) {
		os.set_env("PWD", other)
		got, ok = cs.current_directory()
		testing.expect(t, ok)
		testing.expect_value(t, got, here)
	}
	os.unset_env("PWD")
	got, ok = cs.current_directory()
	testing.expect(t, ok)
	testing.expect_value(t, got, here)
}

// The memory of a run is that of its file list, its hits and its longest line,
// not of the size of the files: a file of a million lines is read in a few
// kilobytes.
@(test)
the_memory_does_not_grow_with_the_size_of_a_file :: proc(t: ^testing.T) {
	f := enter(t)
	b := strings.builder_make(context.temp_allocator)
	line := "a { color: red; border: 1px solid blue; /* a note */ opacity: 1; transition: none; }\n"
	for _ in 0 ..< 120_000 {
		strings.write_string(&b, line)
	}
	put(t, f, "big.css", strings.to_string(b))
	before := f.arena.total_used
	status, out, _ := check(f, ".")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "")
	used := f.arena.total_used - before
	// The file is 10 MB; a line, the lists and the buffers are far below one.
	testing.expectf(t, used < 1_000_000, "a run over a %d byte file took %d bytes", strings.builder_len(b), used)
}
