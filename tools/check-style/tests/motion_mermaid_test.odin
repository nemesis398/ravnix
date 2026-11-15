// The motion rule, the issue-number and link exemptions of the hex rule, and
// the Mermaid init blocks: the cases of the shell test.
package check_style_tests

import "core:os"
import "core:strings"
import "core:testing"
import cs ".."

// Motion.

@(test)
a_transition_or_animation_key_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { transition: opacity 80ms ease-out; }\nb { animation: pulse 1s infinite; }\n")
	put(t, f, "b.css", "a { transition-duration: 1s; }\nb { animation-name: x; }\n@keyframes pulse { from { color: red; } }\n")
	put(t, f, "c.css", "a { -webkit-transition: all 1s; }\nb { -gtk-animation: x; }\n")
	put(t, f, "modules/d.nix", "animation = \"x\";\ntransition = 1;\nanimations = { enabled = true; };\n")
	expect_hits(
		t,
		f,
		"a.css:1:motion",
		"a.css:2:motion",
		"b.css:1:motion",
		"b.css:2:motion",
		"b.css:3:motion",
		"c.css:1:motion",
		"c.css:2:motion",
		"modules/d.nix:1:motion",
		"modules/d.nix:2:motion",
		"modules/d.nix:3:motion",
	)
}

@(test)
a_key_that_turns_motion_off_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { transition: none; }\nb { animation: none !important; }\nc { transition-duration: 0s; }\nd { animation-duration: 0ms }\n")
	put(t, f, "modules/b.nix", "animations = false;\n\"animation\" = \"off\";\ntransition = 0;\n")
	expect_clean(t, f)
	put(t, f, "modules/c.nix", "animations = { enabled = false; };\n")
	put(t, f, "c.css", "@keyframes x { }\n")
	expect_hits(t, f, "c.css:1:motion", "modules/c.nix:1:motion")
}

@(test)
an_issue_number_in_a_trailing_comment_is_no_color :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "x = 1; # see issue #290879\n")
	put(t, f, "modules/b.nix", "c = \"#333333\"; # see #290879\n")
	expect_hits(t, f, "modules/b.nix:1:hex-color")
}

@(test)
an_issue_number_in_a_lua_comment_is_no_color :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/nvim/a.lua", "-- see #290879\nlocal x = 1 -- see #290879\nlocal y = \"#290879\" -- a color\n")
	expect_hits(t, f, "modules/nvim/a.lua:3:hex-color")
}

@(test)
a_word_of_hex_letters_on_a_color_key_is_no_color :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "text = \"facade\";\ninput = \"decade\";\nborder = \"deadbeef\";\nbackground = \"accede\";\nmatch = \"efface\";\n")
	expect_clean(t, f)
	// Letters only is a color when every byte is a doubled digit, as #fed is.
	put(t, f, "modules/b.nix", "text = \"ffeedd\";\nborder = \"cccccc\";\nforeground = \"ffffffff\";\nbackground = \"abcdef12\";\n")
	expect_hits(t, f, "modules/b.nix:1:hex-color", "modules/b.nix:2:hex-color", "modules/b.nix:3:hex-color", "modules/b.nix:4:hex-color", "modules/b.nix:4:opacity")
}

@(test)
a_link_anchor_is_no_color :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "See [the facade](#facade) and [x](#deadbeef), <a href=\"#facade\">y</a>.\n")
	put(t, f, "docs/b.md", "Mauve (#cba6f7) and [x](#cba6f7) here.\n")
	expect_hits(t, f, "docs/b.md:1:hex-color")
}

@(test)
an_issue_number_is_no_color :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "See issue #290879 and PR #216321, [#221181](https://example.org).\n")
	put(t, f, "modules/a.nix", "# workaround for #290879\n{ }\n")
	put(t, f, "docs/b.md", "Surface0 is #313244 and Mantle #181825.\n")
	put(t, f, "modules/b.nix", "c = \"#333333\";\n# was #313244\n")
	expect_hits(t, f, "docs/b.md:1:hex-color", "modules/b.nix:1:hex-color", "modules/b.nix:2:hex-color")
}

@(test)
turning_animations_on_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "\"gtk-enable-animations\" = true;\nenable-animations = true;\n\"enable-animations\" = \"true\";\n")
	put(t, f, "modules/b.ini", "gtk-enable-animations=1\n")
	put(t, f, "modules/c.ini", "gtk-enable-animations=0\ngtk-enable-animations=false\n")
	expect_hits(t, f, "modules/a.nix:1:motion", "modules/a.nix:2:motion", "modules/a.nix:3:motion", "modules/b.ini:1:motion")
}

@(test)
a_motion_key_in_an_attribute_path_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "gtk.gtk3.extraConfig.gtk-enable-animations = true;\ndconf.settings.\"org/gnome/desktop/interface\".enable-animations = true;\nprograms.x.settings.animation = \"slide\";\nfoo.transition = 1;\nprograms.y.animations.enabled = true;\n")
	put(t, f, "modules/b.nix", "gtk.gtk3.extraConfig.gtk-enable-animations = false;\ndconf.settings.\"org/gnome/desktop/interface\".enable-animations = false;\nfoo.transition = 0;\nprograms.y.animations.enabled = false;\nsystemd.TransitionTime = 1;\nlib.animationsFoo = 1;\nprograms.z.gtk-enable-animations = \"off\";\n")
	expect_hits(t, f, "modules/a.nix:1:motion", "modules/a.nix:2:motion", "modules/a.nix:3:motion", "modules/a.nix:4:motion", "modules/a.nix:5:motion")
}

@(test)
a_css_class_selector_is_no_motion_key :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", ".animation-paused:hover { color: red; }\nwindow .transition-x:focus { color: red; }\n.animation-x:hover,\n.b:active {\n  color: red;\n}\n")
	put(t, f, "modules/b.nix", "programs.waybar.style = ''\n  .animation-x:hover { color: red; }\n  window .transition-y:focus > b { color: red; }\n  .animation-z:active,\n  .b {\n    color: red;\n  }\n'';\n")
	expect_clean(t, f)
	// A property is still a key, in a rule and in a string, and an attribute
	// path still is one.
	put(t, f, "c.css", ".a { animation: spin 1s linear; }\n.b:hover { transition: all 1s; }\n")
	put(t, f, "modules/d.nix", "programs.waybar.style = ''\n  .a { animation: spin 1s; }\n'';\nfoo.animation = 1;\n")
	expect_hits(t, f, "c.css:1:motion", "c.css:2:motion", "modules/d.nix:2:motion", "modules/d.nix:4:motion")
}

@(test)
words_that_merely_contain_the_names_pass :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "\"gtk-enable-animations\" = false;\nenable-animations = false;\nsystemd.TransitionTime = 1;\n# animation: none is the default\n")
	put(t, f, "modules/b.ini", "gtk-enable-animations=false\n")
	put(t, f, "a.css", "/* no transition: ever */\na { color: red; }\n")
	expect_clean(t, f)
}

// Mermaid.

@(test)
a_mermaid_init_block_identical_to_the_shared_one_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", strings.concatenate({"```mermaid\n", SHARED_BLOCK, "flowchart LR\n  A[a] --> B[b]\n```\n"}, context.temp_allocator))
	expect_clean(t, f)
}

@(test)
a_mermaid_init_block_with_a_changed_color_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "text\n\n```mermaid\n%%{init: {\"theme\": \"base\", \"themeVariables\": {\n  \"background\": \"#1e1e2f\", \"primaryColor\": \"#313244\",\n  \"fontFamily\": \"JetBrainsMono Nerd Font, ui-monospace, monospace\" }}}%%\nflowchart LR\n```\n")
	expect_hits(t, f, "docs/a.md:4:mermaid-init")
}

ONE_LINE :: `{"theme": "base", "themeVariables": {"background": "#1e1e2e", "primaryColor": "#313244", "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"}}`

@(test)
a_one_line_init_block_and_a_different_theme_are_judged_too :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{init: {\"theme\": \"dark\"}}%%\n")
	put(t, f, "docs/b.md", "%%{init: " + ONE_LINE + "}%%\n")
	expect_hits(t, f, "docs/a.md:1:mermaid-init")
}

@(test)
init_spellings_with_spaces_or_initialize_are_blocks :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{ init: {\"theme\": \"dark\"} }%%\n")
	put(t, f, "docs/b.md", "%%{initialize: {\"theme\": \"dark\"}}%%\n")
	put(t, f, "docs/c.md", "%%{initialize: " + ONE_LINE + "}%%\n")
	put(t, f, "docs/d.md", "%%{ init: " + ONE_LINE + " }%%\n")
	expect_hits(t, f, "docs/a.md:1:mermaid-init", "docs/b.md:1:mermaid-init")
}

@(test)
prose_about_the_init_syntax_is_no_block :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "The block `%%{init: ...}%%` is shared; write %%{init: x}%% in prose.\n")
	expect_clean(t, f)
}

@(test)
an_indented_init_block_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "- item\n\n    %%{init: {\"theme\": \"dark\"}}%%\n")
	expect_hits(t, f, "docs/a.md:3:mermaid-init")
}

@(test)
an_init_block_that_never_closes_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "a\n%%{init: {\"theme\": \"base\"\nflowchart LR\n")
	expect_hits(t, f, "docs/a.md:2:mermaid-init")
}

@(test)
a_hex_color_in_a_mermaid_style_line_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "```mermaid\nflowchart LR\n  A[a]\n  style A fill:#313244,stroke:#cba6f7\n```\n")
	expect_hits(t, f, "docs/a.md:4:hex-color")
}

@(test)
a_missing_shared_theme_is_bad_usage_when_a_block_needs_it :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/a.md", "%%{init: {\"theme\": \"base\"}}%%\n")
	f.theme = join(f, "nowhere.json")
	status, _, err := check(f, ".")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "cannot read the shared Mermaid theme")
	put(t, f, "docs/a.md", "no block here\n")
	status, _, _ = check(f, ".")
	testing.expect_value(t, status, 0)
}

// The style document and the shared theme of the repository. Built by Nix
// they are named by -define:STYLE_DOC and MERMAID_THEME (default.nix); run by
// hand they are found from this file.
STYLE_DOC :: #config(STYLE_DOC, "")

@(test)
the_repository_init_block_and_the_shared_theme_agree :: proc(t: ^testing.T) {
	f := enter(t)
	root := strings.concatenate({#directory, "../../../"}, context.temp_allocator)
	style_path := STYLE_DOC if STYLE_DOC != "" else strings.concatenate({root, "docs/style.md"}, context.temp_allocator)
	f.theme = cs.DEFAULT_THEME if cs.DEFAULT_THEME != "" else strings.concatenate({root, "docs/mermaid-theme.json"}, context.temp_allocator)
	style, serr := os.read_entire_file(style_path, context.temp_allocator)
	testing.expect_value(t, serr, nil)
	put(t, f, "docs/style.md", string(style))
	status, out, _ := check(f, "docs/style.md")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "")
}
