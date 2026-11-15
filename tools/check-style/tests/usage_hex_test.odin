// The usage of the program, the hex rule, and the places that are not
// judged: the cases of scripts/tests/check-style.test.sh, which the Bash
// version passed, and which the Odin version must pass too.
package check_style_tests

import "core:testing"

// Usage.

@(test)
no_path_is_bad_usage :: proc(t: ^testing.T) {
	f := enter(t)
	status, _, err := check(f)
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "usage")
}

@(test)
an_option_is_bad_usage :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { color: red; }\n")
	status, _, err := check(f, "-x")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "usage")
	status, _, _ = check(f, "--help")
	testing.expect_value(t, status, 2)
	status, _, _ = check(f, ".", "-x")
	testing.expect_value(t, status, 2)
}

@(test)
a_file_named_like_an_option_is_reached_with_a_prefix :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "-odd.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, "./-odd.css")
	testing.expect_value(t, status, 1)
	expect_contains(t, out, "./-odd.css:1:radius")
}

@(test)
a_missing_path_is_bad_usage :: proc(t: ^testing.T) {
	f := enter(t)
	status, _, err := check(f, "nowhere")
	testing.expect_value(t, status, 2)
	expect_contains(t, err, "no such file or directory")
}

// Hex colors.

@(test)
a_hex_color_in_a_module_outside_the_theme_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/desktop/waybar.nix", "let\n  accent = \"#cba6f7\";\nin accent\n")
	status, out, err := check(f, ".")
	testing.expect_value(t, status, 1)
	expect_contains(t, out, "modules/desktop/waybar.nix:2:hex-color")
	expect_contains(t, err, "1 hit")
}

@(test)
the_same_hex_color_inside_the_theme_module_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/palette.nix", "{ mauve = \"#cba6f7\"; }\n")
	put(t, f, "modules/theme/css/bar.css", "bar { color: #cdd6f4; background: #1e1e2e; }\n")
	expect_clean(t, f)
}

@(test)
the_vendor_root_is_exempt_from_the_hex_rule_only :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "vendor/catppuccin/mocha.css", "a { color: #cba6f7; }\n")
	put(t, f, "node_modules/x/y.css", "a { color: #cba6f7; }\n")
	put(t, f, "modules/desktop/node_modules/y.css", "a { color: #cba6f7; }\n")
	expect_clean(t, f)
	put(t, f, "vendor/catppuccin/round.css", "a { border-radius: 6px; transition: all 1s; opacity: 0.5; }\n")
	expect_hits(t, f, "vendor/catppuccin/round.css:1:motion", "vendor/catppuccin/round.css:1:opacity", "vendor/catppuccin/round.css:1:radius")
}

@(test)
an_exemption_is_a_place_and_not_a_name :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/desktop/themes/g.css", "a { border-radius: 9px; color: #ff0000; }\n")
	put(t, f, "modules/desktop/tests/g2.css", "a { border-radius: 9px; }\n")
	put(t, f, "modules/desktop/vendor/g3.css", "a { color: #ff0000; }\n")
	put(t, f, "modules/desktop/fixtures/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/.worktrees/w.nix", "c = \"#cba6f7\";\n")
	put(t, f, "templates/default/modules/theme/g4.nix", "c = \"#ff0000\";\n")
	put(t, f, "tools/ravnix-x/src/tests/z.nix", "c = \"#cba6f7\";\n")
	put(t, f, "other/docs/style.md", "The accent is #cba6f7.\n")
	put(t, f, "themes/mocha.css", "a { color: #cba6f7; }\n")
	put(t, f, "third_party/x.css", "a { color: #cba6f7; }\n")
	expect_hits(
		t,
		f,
		"modules/.worktrees/w.nix:1:hex-color",
		"modules/desktop/fixtures/y.nix:1:hex-color",
		"modules/desktop/tests/g2.css:1:radius",
		"modules/desktop/themes/g.css:1:hex-color",
		"modules/desktop/themes/g.css:1:radius",
		"modules/desktop/vendor/g3.css:1:hex-color",
		"other/docs/style.md:1:hex-color",
		"templates/default/modules/theme/g4.nix:1:hex-color",
		"themes/mocha.css:1:hex-color",
		"third_party/x.css:1:hex-color",
		"tools/ravnix-x/src/tests/z.nix:1:hex-color",
	)
}

@(test)
a_directory_argument_is_anchored_at_the_current_directory :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tests/z.css", "a { border-radius: 4px; }\n")
	status, out, _ := check(f, "modules", "tests")
	testing.expect_value(t, status, 1)
	testing.expect_value(t, out, "modules/y.nix:1:hex-color\n")
}

@(test)
the_style_document_itself_may_hold_hex_colors :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/style.md", "| Base | `#1e1e2e` |\n")
	expect_clean(t, f)
}

@(test)
the_theme_exemption_is_the_directory_not_a_prefix :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme-extra/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, "modules/themed/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "other/modules/theme/z.nix", "c = \"#cba6f7\";\n")
	expect_hits(t, f, "modules/theme-extra/x.nix:1:hex-color", "modules/themed/y.nix:1:hex-color", "other/modules/theme/z.nix:1:hex-color")
}

@(test)
another_document_may_not :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "docs/architecture.md", "The accent is #cba6f7.\n")
	expect_hits(t, f, "docs/architecture.md:1:hex-color")
}

@(test)
a_hex_color_in_a_comment_is_still_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/x.nix", "# was #cba6f7 on Fedora\n{ }\n")
	expect_hits(t, f, "modules/x.nix:1:hex-color")
}

@(test)
a_short_hex_color_in_css_or_quotes_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "bar.css", "a { color: #fff; }\nb { color: #abcf; }\n")
	put(t, f, "modules/x.nix", "y = \"#fff\";\n")
	put(t, f, "modules/y.nix", "z = ''\n  .a { background: #abc; }\n'';\n")
	expect_hits(t, f, "bar.css:1:hex-color", "bar.css:2:hex-color", "modules/x.nix:1:hex-color", "modules/y.nix:2:hex-color")
}

@(test)
a_hex_color_with_alpha_is_a_hit_for_two_rules :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "bar.css", "a { color: #1e1e2ecc; }\n")
	expect_hits(t, f, "bar.css:1:hex-color", "bar.css:1:opacity")
}

@(test)
an_alpha_in_the_theme_module_is_still_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/x.css", "a { color: #1e1e2ecc; }\n")
	expect_hits(t, f, "modules/theme/x.css:1:opacity")
}

@(test)
two_colors_on_one_line_are_one_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { background: #1e1e2e; color: #cdd6f4; }\n")
	expect_hits(t, f, "a.css:1:hex-color")
}

@(test)
things_that_look_like_hex_but_are_not_colors_pass :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/pin.nix", "rev = \"82bca82b2b27e3d044c7cd5c22a471c8c60df72e\";\n")
	put(t, f, "modules/hash.nix", "narHash = \"sha256-i2+b4Rdp7/yIcVESrp0tzS97FkTuTJxIlqNOTjoswfk=\";\n")
	put(t, f, "modules/digest.nix", "sha256 = \"sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0\";\n")
	put(t, f, "modules/version.nix", "version = \"20240101\";\nshort = \"deadbeef\";\n")
	put(t, f, "modules/frag.nix", "url = \"https://example.org/page#cba6f7\";\nref = \".#cba6f7\";\n")
	put(t, f, "modules/shell.nix", "s = ''\n  echo $#; n=${#arr[@]}; echo ${#bad}\n'';\n")
	put(t, f, "docs/guide.md", "[a](#section) fixes #123 and see &#12345; and #1234\n")
	put(t, f, "docs/hash.md", "The commit is 82bca82b and the file is #!/bin/sh\n")
	put(t, f, "modules/ids.css", "#clock, #custom-battery, window#waybar, #cpu.warning { color: red; }\n")
	expect_clean(t, f)
}

// Places that are not judged.

@(test)
tests_fixtures_and_other_languages_are_not_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "tests/theme/palette.nix", "base = \"#1e1e2e\";\n")
	put(t, f, "tests/theme/fixtures/bad.css", "a { color: #fff; border-radius: 4px; opacity: 0.5; transition: all 1s; }\n")
	put(t, f, "scripts/tests/x.sh", "echo \"#cba6f7\"\n")
	put(t, f, "scripts/tests/z.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tools/ravnix-x/tests/y.nix", "c = \"#cba6f7\";\n")
	put(t, f, "tools/ravnix-x/main.odin", "c :: \"#cba6f7\"\n")
	put(t, f, "tools/ravnix-x/tests/x_test.odin", "c :: \"#cba6f7\"\n")
	put(t, f, "bench/run.py", "c = \"#cba6f7\"\n")
	put(t, f, "deploy/compose.yaml", "color: \"#cba6f7\"\nopacity: 0.5\n")
	put(t, f, "assets/mark.svg", "<svg><path fill=\"#cba6f7\" opacity=\"0.5\"/></svg>\n")
	put(t, f, "modules/desktop/assets/mark.svg", "<svg><path fill=\"#cba6f7\" opacity=\"0.5\"/></svg>\n")
	put(t, f, "flake.lock", "{\"narHash\": \"sha256-abc#123456\"}\n")
	put(t, f, ".git/hooks/x.css", "a { color: #fff; }\n")
	put(t, f, ".worktrees/other/modules/x.nix", "c = \"#cba6f7\";\n")
	put(t, f, ".superpowers/sdd/x.md", "c = #cba6f7\n")
	expect_clean(t, f)
}

@(test)
a_nix_file_in_tools_is_judged_like_any_other :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "tools/ravnix-x/default.nix", "c = \"#cba6f7\";\n")
	expect_hits(t, f, "tools/ravnix-x/default.nix:1:hex-color")
}

@(test)
a_file_without_an_extension_under_modules_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/desktop/sway/config", "client.focused #cba6f7 #1e1e2e\n")
	expect_hits(t, f, "modules/desktop/sway/config:1:hex-color")
}

@(test)
a_file_without_an_extension_elsewhere_is_not :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "bin/tool", "echo \"#cba6f7\"\n")
	expect_clean(t, f)
}

@(test)
a_directory_below_tests_is_judged_by_what_is_below_it :: proc(t: ^testing.T) {
	f := enter(t)
	// The ancestors of the argument do not count, only the path below it.
	put(t, f, "tests/vendor/modules/x.nix", "c = \"#cba6f7\";\n")
	status, out, _ := check_in(f, join(f, "tree/tests/vendor"), ".")
	testing.expect_value(t, status, 1)
	expect_contains(t, out, "modules/x.nix:1:hex-color")
}

@(test)
a_path_with_brackets_quotes_or_a_dollar_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/[id]/x.css", "a { border-radius: 4px; }\n")
	put(t, f, "modules/a'b/y.css", "a { border-radius: 4px; }\n")
	put(t, f, "modules/$x/z.css", "a { border-radius: 4px; }\n")
	expect_hits(t, f, "modules/$x/z.css:1:radius", "modules/[id]/x.css:1:radius", "modules/a'b/y.css:1:radius")
}

@(test)
a_symbolic_link_is_not_followed :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "real/x.css", "a { color: #cba6f7; }\n")
	symlink(t, "../real/x.css", join(f, "tree/modules-link.css"))
	make_dirs(t, join(f, "tree/modules"))
	symlink(t, "../real/x.css", join(f, "tree/modules/link.css"))
	status, out, _ := check(f, "modules")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "")
	status, out, _ = check(f, "modules-link.css")
	testing.expect_value(t, status, 0)
	testing.expect_value(t, out, "")
}
