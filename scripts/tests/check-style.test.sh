#!/usr/bin/env bash
# Tests for scripts/check-style.sh, the style check. Each test builds a
# fixture tree in a temporary directory and runs the check on it. The colors
# in the fixtures are Catppuccin Mocha values or made up; fixtures meant to
# fail live only here, in the temporary directory, never in the tree the
# check judges. Run it with:
#
#   bash scripts/tests/check-style.test.sh
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

# The fixtures' CSS and shell snippets are data, not code for this shell.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/../.." && pwd)"
check="$here/../check-style.sh"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

# Set by new_tree for the test that is running.
tree=""

# The shared Mermaid theme the fixtures compare against, so no test depends on
# the repository's own docs. One test uses the real file.
theme="$scratch/mermaid-theme.json"
cat >"$theme" <<'JSON'
{
  "theme": "base",
  "themeVariables": {
    "background": "#1e1e2e",
    "primaryColor": "#313244",
    "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"
  }
}
JSON
export RAVNIX_MERMAID_THEME="$theme"

new_tree() {
	local dir
	dir="$(mktemp -d -p "$scratch")"
	tree="$dir/tree"
	mkdir -p "$tree"
}

# Writes $2 into $tree/$1, \n and \r read as line ends.
put() {
	local path="$tree/$1"
	mkdir -p "$(dirname "$path")"
	printf '%b' "$2" >"$path"
}

in_tree() {
	cd "$tree" && "$@"
}
run_check() {
	capture in_tree "$check" "$@"
}

# The check ran on the whole tree and found nothing.
expect_clean() {
	run_check .
	expect_status 0
	[[ -z "$out" ]] || {
		echo "  expected no output, got: $out"
		return 1
	}
}

# The check found exactly these hits, in this order.
expect_hits() {
	local want
	want="$(printf '%s\n' "$@")"
	run_check .
	expect_status 1
	[[ "$out" == "$want" ]] || {
		echo "  expected the hits:"
		printf '%s\n' "$want" | sed 's/^/    /'
		echo "  got:"
		printf '%s\n' "$out" | sed 's/^/    /'
		return 1
	}
}

# Usage.

no_path_is_bad_usage() {
	new_tree
	run_check
	expect_status 2
	expect_err "usage"
}

an_option_is_bad_usage() {
	new_tree
	put a.css 'a { color: red; }\n'
	run_check -x
	expect_status 2
	expect_err "usage"
	run_check --help
	expect_status 2
	run_check . -x
	expect_status 2
}

a_file_named_like_an_option_is_reached_with_a_prefix() {
	new_tree
	put ./-odd.css 'a { border-radius: 4px; }\n'
	run_check ./-odd.css
	expect_status 1
	expect_out "./-odd.css:1:radius"
}

a_missing_path_is_bad_usage() {
	new_tree
	run_check nowhere
	expect_status 2
	expect_err "no such file or directory"
}

a_missing_rg_is_bad_usage() {
	new_tree
	local tools="$scratch/tools" tool
	mkdir -p "$tools"
	for tool in bash cat dirname env find sed sort tr awk; do
		ln -sf "$(command -v "$tool")" "$tools/$tool"
	done
	put a.css 'a { color: red; }\n'
	capture in_tree env PATH="$tools" "$check" .
	expect_status 2
	expect_err "rg not found"
}

# Hex colors.

a_hex_color_in_a_module_outside_the_theme_is_a_hit() {
	new_tree
	put modules/desktop/waybar.nix 'let\n  accent = "#cba6f7";\nin accent\n'
	run_check .
	expect_status 1
	expect_out "modules/desktop/waybar.nix:2:hex-color"
	expect_err "1 hit"
}

the_same_hex_color_inside_the_theme_module_passes() {
	new_tree
	put modules/theme/palette.nix '{ mauve = "#cba6f7"; }\n'
	put modules/theme/css/bar.css 'bar { color: #cdd6f4; background: #1e1e2e; }\n'
	expect_clean
}

the_vendor_root_is_exempt_from_the_hex_rule_only() {
	new_tree
	put vendor/catppuccin/mocha.css 'a { color: #cba6f7; }\n'
	put node_modules/x/y.css 'a { color: #cba6f7; }\n'
	put modules/desktop/node_modules/y.css 'a { color: #cba6f7; }\n'
	expect_clean
	put vendor/catppuccin/round.css 'a { border-radius: 6px; transition: all 1s; opacity: 0.5; }\n'
	expect_hits "vendor/catppuccin/round.css:1:motion" "vendor/catppuccin/round.css:1:opacity" \
		"vendor/catppuccin/round.css:1:radius"
}

an_exemption_is_a_place_and_not_a_name() {
	new_tree
	put modules/desktop/themes/g.css 'a { border-radius: 9px; color: #ff0000; }\n'
	put modules/desktop/tests/g2.css 'a { border-radius: 9px; }\n'
	put modules/desktop/vendor/g3.css 'a { color: #ff0000; }\n'
	put modules/desktop/fixtures/y.nix 'c = "#cba6f7";\n'
	put modules/.worktrees/w.nix 'c = "#cba6f7";\n'
	put templates/default/modules/theme/g4.nix 'c = "#ff0000";\n'
	put tools/ravnix-x/src/tests/z.nix 'c = "#cba6f7";\n'
	put other/docs/style.md 'The accent is #cba6f7.\n'
	put themes/mocha.css 'a { color: #cba6f7; }\n'
	put third_party/x.css 'a { color: #cba6f7; }\n'
	expect_hits "modules/.worktrees/w.nix:1:hex-color" "modules/desktop/fixtures/y.nix:1:hex-color" \
		"modules/desktop/tests/g2.css:1:radius" "modules/desktop/themes/g.css:1:hex-color" \
		"modules/desktop/themes/g.css:1:radius" "modules/desktop/vendor/g3.css:1:hex-color" \
		"other/docs/style.md:1:hex-color" "templates/default/modules/theme/g4.nix:1:hex-color" \
		"themes/mocha.css:1:hex-color" "third_party/x.css:1:hex-color" \
		"tools/ravnix-x/src/tests/z.nix:1:hex-color"
}

a_directory_argument_is_anchored_at_the_current_directory() {
	new_tree
	put modules/theme/x.nix 'c = "#cba6f7";\n'
	put modules/y.nix 'c = "#cba6f7";\n'
	put tests/z.css 'a { border-radius: 4px; }\n'
	run_check modules tests
	expect_status 1
	expect_lines 1
	expect_out "modules/y.nix:1:hex-color"
}

the_style_document_itself_may_hold_hex_colors() {
	new_tree
	put docs/style.md '| Base | `#1e1e2e` |\n'
	expect_clean
}

another_document_may_not() {
	new_tree
	put docs/architecture.md 'The accent is #cba6f7.\n'
	expect_hits "docs/architecture.md:1:hex-color"
}

a_hex_color_in_a_comment_is_still_a_hit() {
	new_tree
	put modules/x.nix '# was #cba6f7 on Fedora\n{ }\n'
	expect_hits "modules/x.nix:1:hex-color"
}

a_short_hex_color_in_css_or_quotes_is_a_hit() {
	new_tree
	put bar.css 'a { color: #fff; }\nb { color: #abcf; }\n'
	put modules/x.nix 'y = "#fff";\n'
	put modules/y.nix "z = ''\n  .a { background: #abc; }\n'';\n"
	expect_hits "bar.css:1:hex-color" "bar.css:2:hex-color" \
		"modules/x.nix:1:hex-color" "modules/y.nix:2:hex-color"
}

a_hex_color_with_alpha_is_a_hit_for_two_rules() {
	new_tree
	put bar.css 'a { color: #1e1e2ecc; }\n'
	expect_hits "bar.css:1:hex-color" "bar.css:1:opacity"
}

an_alpha_in_the_theme_module_is_still_a_hit() {
	new_tree
	put modules/theme/x.css 'a { color: #1e1e2ecc; }\n'
	expect_hits "modules/theme/x.css:1:opacity"
}

two_colors_on_one_line_are_one_hit() {
	new_tree
	put a.css 'a { background: #1e1e2e; color: #cdd6f4; }\n'
	expect_hits "a.css:1:hex-color"
}

things_that_look_like_hex_but_are_not_colors_pass() {
	new_tree
	put modules/pin.nix 'rev = "82bca82b2b27e3d044c7cd5c22a471c8c60df72e";\n'
	put modules/hash.nix 'narHash = "sha256-i2+b4Rdp7/yIcVESrp0tzS97FkTuTJxIlqNOTjoswfk=";\n'
	put modules/digest.nix 'sha256 = "sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";\n'
	put modules/version.nix 'version = "20240101";\nshort = "deadbeef";\n'
	put modules/frag.nix 'url = "https://example.org/page#cba6f7";\nref = ".#cba6f7";\n'
	put modules/shell.nix "s = ''\n  echo \$#; n=\${#arr[@]}; echo \${#bad}\n'';\n"
	put docs/guide.md '[a](#section) fixes #123 and see &#12345; and #1234\n'
	put docs/hash.md 'The commit is 82bca82b and the file is #!/bin/sh\n'
	put modules/ids.css '#clock, #custom-battery, window#waybar, #cpu.warning { color: red; }\n'
	expect_clean
}

the_theme_exemption_is_the_directory_not_a_prefix() {
	new_tree
	put modules/theme-extra/x.nix 'c = "#cba6f7";\n'
	put modules/themed/y.nix 'c = "#cba6f7";\n'
	put other/modules/theme/z.nix 'c = "#cba6f7";\n'
	expect_hits "modules/theme-extra/x.nix:1:hex-color" "modules/themed/y.nix:1:hex-color" \
		"other/modules/theme/z.nix:1:hex-color"
}

# Places that are not judged.

tests_fixtures_and_other_languages_are_not_judged() {
	new_tree
	put tests/theme/palette.nix 'base = "#1e1e2e";\n'
	put tests/theme/fixtures/bad.css 'a { color: #fff; border-radius: 4px; opacity: 0.5; transition: all 1s; }\n'
	put scripts/tests/x.sh 'echo "#cba6f7"\n'
	put scripts/tests/z.nix 'c = "#cba6f7";\n'
	put tools/ravnix-x/tests/y.nix 'c = "#cba6f7";\n'
	put tools/ravnix-x/main.odin 'c :: "#cba6f7"\n'
	put tools/ravnix-x/tests/x_test.odin 'c :: "#cba6f7"\n'
	put bench/run.py 'c = "#cba6f7"\n'
	put deploy/compose.yaml 'color: "#cba6f7"\nopacity: 0.5\n'
	put assets/mark.svg '<svg><path fill="#cba6f7" opacity="0.5"/></svg>\n'
	put modules/desktop/assets/mark.svg '<svg><path fill="#cba6f7" opacity="0.5"/></svg>\n'
	put flake.lock '{"narHash": "sha256-abc#123456"}\n'
	put .git/hooks/x.css 'a { color: #fff; }\n'
	put .worktrees/other/modules/x.nix 'c = "#cba6f7";\n'
	put .superpowers/sdd/x.md 'c = #cba6f7\n'
	expect_clean
}

a_nix_file_in_tools_is_judged_like_any_other() {
	new_tree
	put tools/ravnix-x/default.nix 'c = "#cba6f7";\n'
	expect_hits "tools/ravnix-x/default.nix:1:hex-color"
}

a_file_without_an_extension_under_modules_is_judged() {
	new_tree
	put modules/desktop/sway/config 'client.focused #cba6f7 #1e1e2e\n'
	expect_hits "modules/desktop/sway/config:1:hex-color"
}

a_file_without_an_extension_elsewhere_is_not() {
	new_tree
	put bin/tool 'echo "#cba6f7"\n'
	expect_clean
}

a_directory_below_tests_is_judged_by_what_is_below_it() {
	new_tree
	# The ancestors of the argument do not count, only the path below it.
	mkdir -p "$tree/tests/vendor"
	put tests/vendor/modules/x.nix 'c = "#cba6f7";\n'
	capture env -C "$tree/tests/vendor" "$check" .
	expect_status 1
	expect_out "modules/x.nix:1:hex-color"
}

a_path_with_brackets_quotes_or_a_dollar_is_judged() {
	new_tree
	put 'modules/[id]/x.css' 'a { border-radius: 4px; }\n'
	put "modules/a'b/y.css" 'a { border-radius: 4px; }\n'
	put 'modules/$x/z.css' 'a { border-radius: 4px; }\n'
	expect_hits 'modules/$x/z.css:1:radius' 'modules/[id]/x.css:1:radius' "modules/a'b/y.css:1:radius"
}

a_symbolic_link_is_not_followed() {
	new_tree
	put real/x.css 'a { color: #cba6f7; }\n'
	ln -s ../real/x.css "$tree/modules-link.css"
	mkdir -p "$tree/modules"
	ln -s ../real/x.css "$tree/modules/link.css"
	run_check modules
	expect_status 0
	run_check modules-link.css
	expect_status 0
}

# Radii.

a_radius_other_than_zero_is_a_hit() {
	new_tree
	put a.css 'a { border-radius: 4px; }\n'
	put b.css 'a { border-top-left-radius: 2px; }\nb { -gtk-outline-radius: 3px; }\nc { border-radius: 0 0 0 1px; }\n'
	put c.css 'a { -moz-border-radius: .5em; }\nb { border-radius: var(--r); }\nc { border-radius: calc(0px + 1px); }\n'
	expect_hits "a.css:1:radius" "b.css:1:radius" "b.css:2:radius" "b.css:3:radius" \
		"c.css:1:radius" "c.css:2:radius" "c.css:3:radius"
}

a_radius_of_zero_passes() {
	new_tree
	put a.css 'a { border-radius: 0; }\nb { border-radius: 0px !important; }\nc { border-radius: 0 0 0 0 }\n'
	put b.css '* { border-radius: 0; }\n*, *::before { border-radius: 0px; }\n'
	put c.css 'a { border-radius: 0.0; border-top-left-radius: 0%; }\n'
	expect_clean
}

radius_keys_in_configs_are_judged() {
	new_tree
	put modules/a.nix 'radius = 10;\ncorner_radius = 12;\n"border-radius" = "4px";\n'
	put modules/b.ini '[border]\nradius=8\n'
	put modules/c.nix 'radius = 0;\n'
	put modules/d.ini '[border]\nradius=0\n'
	expect_hits "modules/a.nix:1:radius" "modules/a.nix:2:radius" "modules/a.nix:3:radius" \
		"modules/b.ini:2:radius"
}

the_lock_ring_radius_is_a_gauge_not_a_corner() {
	new_tree
	put modules/swaylock.conf 'indicator-radius=110\nindicator-thickness=10\n'
	put modules/swaylock.nix '"indicator-radius" = 110;\nindicator-radius = 110;\n'
	expect_clean
}

a_rounded_border_is_a_hit() {
	new_tree
	put modules/a.nix 'ui = { border = "rounded"; };\nwinborder = "rounded";\n'
	put modules/nvim/init.lua 'vim.o.winborder = "rounded"\nui = { border = "single" }\nvim.o.winborder = "single"\n'
	put modules/b.nix 'border = "single";\nstyle = "rounded";\n'
	expect_hits "modules/a.nix:1:radius" "modules/a.nix:2:radius" "modules/nvim/init.lua:1:radius"
}

rounded_corners_are_a_hit_unless_off() {
	new_tree
	put modules/mangohud.conf 'round_corners=10\n'
	put modules/b.nix 'rounded_corners = true;\nround-corners = 1;\n'
	put modules/c.conf 'round_corners=0\n'
	put modules/d.nix 'rounded_corners = false;\n'
	expect_hits "modules/b.nix:1:radius" "modules/b.nix:2:radius" "modules/mangohud.conf:1:radius"
}

any_radius_key_is_a_hit_except_the_lock_ring_gauge() {
	new_tree
	put modules/dunstrc 'progress_bar_corner_radius = 4\nicon_corner_radius = 4\n'
	put modules/b.nix 'selection_radius = 3;\nfoo-radius: 2px;\n'
	put modules/c.nix 'progress_bar_corner_radius = 0;\nindicator_radius = 110;\n"indicator-radius" = 110;\n'
	expect_hits "modules/b.nix:1:radius" "modules/b.nix:2:radius" "modules/dunstrc:1:radius" \
		"modules/dunstrc:2:radius"
}

a_declaration_after_a_closed_comment_or_a_selector_star_is_judged() {
	new_tree
	put a.css '/* x */ border-radius: 4px;\n* button { border-radius: 4px; }\n'
	expect_hits "a.css:1:radius" "a.css:2:radius"
}

a_lua_comment_is_a_comment() {
	new_tree
	put modules/nvim/init.lua '-- No animations: no smooth scrolling, corner_radius = 4\nvim.g.snacks_animate = false\nvim.o.winborder = "single"\nlocal half = 6 // 2\n'
	expect_clean
	put modules/nvim/b.lua 'animations = true\n-- animations = true\n'
	expect_hits "modules/nvim/b.lua:1:motion"
}

a_radius_in_a_comment_passes() {
	new_tree
	put a.css '/* border-radius: 4px */\n/*\n * border-radius: 4px;\n */\na { border-radius: 0; /* was border-radius: 4px */ }\n'
	put modules/a.nix '# radius = 10;\n  # border-radius: 4px\n'
	put b.css '// border-radius: 4px\n'
	expect_clean
}

# Opacity.

an_opacity_below_one_is_a_hit() {
	new_tree
	put a.css 'a { opacity: 0.9; }\nb { opacity: .5; }\nc { opacity: 0; }\nd { opacity: 90%; }\n'
	expect_hits "a.css:1:opacity" "a.css:2:opacity" "a.css:3:opacity" "a.css:4:opacity"
}

an_opacity_of_one_passes() {
	new_tree
	put a.css 'a { opacity: 1; }\nb { opacity: 1.0; }\nc { opacity: 100%; }\n'
	put modules/b.nix 'opacity = 1;\ncfg.opacity = config.x.opacity;\n'
	expect_clean
}

an_alpha_function_in_css_is_a_hit() {
	new_tree
	put waybar.css '#clock:hover { background: alpha(@accent, 0.18); }\n'
	expect_hits "waybar.css:1:opacity"
}

an_rgba_with_alpha_below_one_is_a_hit() {
	new_tree
	put a.css 'a { background: rgba(0, 0, 0, 0.5); }\nb { background: rgb(0 0 0 / 50%); }\nc { background: hsla(0, 0%, 0%, .3); }\n'
	put b.css 'a { background: rgba(0, 0, 0, 1); }\nb { background: rgb(1, 2, 0); }\nc { background: rgb(0 0 0 / 100%); }\n'
	expect_hits "a.css:1:opacity" "a.css:2:opacity" "a.css:3:opacity"
}

an_alpha_key_in_a_config_is_a_hit() {
	new_tree
	put modules/mangohud.conf 'background_alpha=0.8\n'
	put modules/b.nix 'window_opacity = 0.9;\n"inactive-opacity" = "0.7";\n'
	put modules/c.conf 'background_alpha=1\nopacity=1.0\n'
	expect_hits "modules/b.nix:1:opacity" "modules/b.nix:2:opacity" "modules/mangohud.conf:1:opacity"
}

the_sway_opacity_command_is_a_hit() {
	new_tree
	put modules/sway/config 'for_window [app_id=".*"] opacity 0.9\nfor_window [class=x] opacity set 0.8\nfor_window [class=y] opacity 1\n'
	expect_hits "modules/sway/config:1:opacity" "modules/sway/config:2:opacity"
}

a_translucent_bare_color_in_a_config_is_a_hit() {
	new_tree
	# Below the theme module, where a hex color is allowed, only the alpha counts.
	put modules/theme/fuzzel.ini '[colors]\nbackground=1e1e2edd\ntext=cdd6f4ff\nselection=45475acc\n'
	put modules/theme/b.nix 'border = "cba6f780";\nring-color = "#585b7080";\n'
	put modules/theme/c.ini '[colors]\nbackground=1e1e2eff\nselection=45475aFF\n'
	expect_hits "modules/theme/b.nix:1:opacity" "modules/theme/b.nix:2:opacity" \
		"modules/theme/fuzzel.ini:2:opacity" "modules/theme/fuzzel.ini:4:opacity"
}

a_bare_color_outside_the_theme_is_a_hex_color_hit() {
	new_tree
	put modules/fuzzel.ini '[colors]\nbackground=1e1e2eff\ntext=cdd6f4\nselection=45475aFF\n'
	put modules/swaylock.conf 'inside-color=00000000\nring-color=585b70\n'
	put modules/b.nix '"inside-ver-color" = "#1e1e2ecc";\nborder = "cba6f7";\n'
	put modules/theme/ok.conf 'background=1e1e2eff\ninside-color=00000000\nring-color=585b70\n'
	expect_hits "modules/b.nix:1:hex-color" "modules/b.nix:2:hex-color" \
		"modules/fuzzel.ini:2:hex-color" "modules/fuzzel.ini:3:hex-color" "modules/fuzzel.ini:4:hex-color" \
		"modules/swaylock.conf:1:hex-color" "modules/swaylock.conf:2:hex-color"
}

an_eight_digit_value_that_is_not_a_color_passes() {
	new_tree
	put modules/a.nix 'version = "20240101";\nrev = "deadbeef";\nserial = "12345678";\nshort = "123456";\n'
	put modules/b.nix 'contextId = "1a2b3c4d";\ninputs = "1a2b3c4d";\nframework = "1a2b3c";\nrematched = "1a2b3c4d";\n'
	expect_clean
}

the_inside_of_the_lock_ring_is_the_one_exemption() {
	new_tree
	put modules/theme/swaylock.conf 'inside-color=00000000\ninside-clear-color=1e1e2e00\ninside-ver-color=1e1e2ecc\ninside-wrong-color=1e1e2ecc\ninside-caps-lock-color=1e1e2ecc\n'
	put modules/theme/swaylock.nix '"inside-ver-color" = "1e1e2ecc";\ninside-color = "00000000";\n"inside-wrong-color" = "#1e1e2ecc";\ninside-clear-color = "#1e1e2e00";\n'
	expect_clean
}

no_other_swaylock_color_may_be_translucent() {
	new_tree
	put modules/theme/swaylock.conf 'ring-color=585b7080\nline-color=1e1e2e00\ntext-color=cdd6f4cc\nseparator-color=00000000\nkey-hl-color=cba6f7cc\n'
	put modules/theme/swaylock.nix 'text-color = "#cdd6f4cc";\n'
	expect_hits "modules/theme/swaylock.conf:1:opacity" "modules/theme/swaylock.conf:2:opacity" \
		"modules/theme/swaylock.conf:3:opacity" "modules/theme/swaylock.conf:4:opacity" \
		"modules/theme/swaylock.conf:5:opacity" "modules/theme/swaylock.nix:1:opacity"
}

a_sway_command_in_a_nix_string_is_a_hit() {
	new_tree
	put modules/a.nix 'command = "opacity 0.9";\ncmd2 = "opacity set 0.8";\ncmd3 = "opacity 1";\n'
	expect_hits "modules/a.nix:1:opacity" "modules/a.nix:2:opacity"
}

the_transparent_keyword_is_a_hit() {
	new_tree
	put a.css '#clock { background: transparent; }\nb { border-bottom: 2px solid transparent; }\n@define-color marker transparent;\nc { background: inherit; border-bottom: 2px solid @mantle; }\n'
	put modules/b.nix 'background = "transparent";\ndescription = "A transparent proxy";\n'
	expect_hits "a.css:1:opacity" "a.css:2:opacity" "a.css:3:opacity" "modules/b.nix:1:opacity"
}

an_alpha_that_is_a_smoothing_factor_is_no_opacity() {
	new_tree
	put modules/a.toml 'smoothing_alpha = 0.3\nlearning-alpha = 0.1\n'
	expect_clean
	put modules/b.toml 'alpha = 0.5\nbg_alpha = 0.5\nwindow-alpha: 0.9\ninactive_opacity = 0.9\n'
	expect_hits "modules/b.toml:1:opacity" "modules/b.toml:2:opacity" "modules/b.toml:3:opacity" \
		"modules/b.toml:4:opacity"
}

# Motion.

a_transition_or_animation_key_is_a_hit() {
	new_tree
	put a.css 'a { transition: opacity 80ms ease-out; }\nb { animation: pulse 1s infinite; }\n'
	put b.css 'a { transition-duration: 1s; }\nb { animation-name: x; }\n@keyframes pulse { from { color: red; } }\n'
	put c.css 'a { -webkit-transition: all 1s; }\nb { -gtk-animation: x; }\n'
	put modules/d.nix 'animation = "x";\ntransition = 1;\nanimations = { enabled = true; };\n'
	expect_hits "a.css:1:motion" "a.css:2:motion" "b.css:1:motion" "b.css:2:motion" "b.css:3:motion" \
		"c.css:1:motion" "c.css:2:motion" \
		"modules/d.nix:1:motion" "modules/d.nix:2:motion" "modules/d.nix:3:motion"
}

a_key_that_turns_motion_off_passes() {
	new_tree
	put a.css 'a { transition: none; }\nb { animation: none !important; }\nc { transition-duration: 0s; }\nd { animation-duration: 0ms }\n'
	put modules/b.nix 'animations = false;\n"animation" = "off";\ntransition = 0;\n'
	expect_clean
	put modules/c.nix 'animations = { enabled = false; };\n'
	put c.css '@keyframes x { }\n'
	expect_hits "c.css:1:motion" "modules/c.nix:1:motion"
}

an_issue_number_in_a_trailing_comment_is_no_color() {
	new_tree
	put modules/a.nix 'x = 1; # see issue #290879\n'
	put modules/b.nix 'c = "#333333"; # see #290879\n'
	expect_hits "modules/b.nix:1:hex-color"
}

a_link_anchor_is_no_color() {
	new_tree
	put docs/a.md 'See [the facade](#facade) and [x](#deadbeef), <a href="#facade">y</a>.\n'
	put docs/b.md 'Mauve (#cba6f7) and [x](#cba6f7) here.\n'
	expect_hits "docs/b.md:1:hex-color"
}

an_issue_number_is_no_color() {
	new_tree
	put docs/a.md 'See issue #290879 and PR #216321, [#221181](https://example.org).\n'
	put modules/a.nix '# workaround for #290879\n{ }\n'
	put docs/b.md 'Surface0 is #313244 and Mantle #181825.\n'
	put modules/b.nix 'c = "#333333";\n# was #313244\n'
	expect_hits "docs/b.md:1:hex-color" "modules/b.nix:1:hex-color" "modules/b.nix:2:hex-color"
}

turning_animations_on_is_a_hit() {
	new_tree
	put modules/a.nix '"gtk-enable-animations" = true;\nenable-animations = true;\n"enable-animations" = "true";\n'
	put modules/b.ini 'gtk-enable-animations=1\n'
	put modules/c.ini 'gtk-enable-animations=0\ngtk-enable-animations=false\n'
	expect_hits "modules/a.nix:1:motion" "modules/a.nix:2:motion" "modules/a.nix:3:motion" \
		"modules/b.ini:1:motion"
}

words_that_merely_contain_the_names_pass() {
	new_tree
	put modules/a.nix '"gtk-enable-animations" = false;\nenable-animations = false;\nsystemd.TransitionTime = 1;\n# animation: none is the default\n'
	put modules/b.ini 'gtk-enable-animations=false\n'
	put a.css '/* no transition: ever */\na { color: red; }\n'
	expect_clean
}

# Mermaid.

a_mermaid_init_block_identical_to_the_shared_one_passes() {
	new_tree
	put docs/a.md '```mermaid\n%%{init: {"theme": "base", "themeVariables": {\n  "background": "#1e1e2e", "primaryColor": "#313244",\n  "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace" }}}%%\nflowchart LR\n  A[a] --> B[b]\n```\n'
	expect_clean
}

a_mermaid_init_block_with_a_changed_color_is_a_hit() {
	new_tree
	put docs/a.md 'text\n\n```mermaid\n%%{init: {"theme": "base", "themeVariables": {\n  "background": "#1e1e2f", "primaryColor": "#313244",\n  "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace" }}}%%\nflowchart LR\n```\n'
	expect_hits "docs/a.md:4:mermaid-init"
}

a_one_line_init_block_and_a_different_theme_are_judged_too() {
	new_tree
	put docs/a.md '%%{init: {"theme": "dark"}}%%\n'
	put docs/b.md '%%{init: {"theme": "base", "themeVariables": {"background": "#1e1e2e", "primaryColor": "#313244", "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"}}}%%\n'
	expect_hits "docs/a.md:1:mermaid-init"
}

init_spellings_with_spaces_or_initialize_are_blocks() {
	new_tree
	put docs/a.md '%%{ init: {"theme": "dark"} }%%\n'
	put docs/b.md '%%{initialize: {"theme": "dark"}}%%\n'
	put docs/c.md '%%{initialize: {"theme": "base", "themeVariables": {"background": "#1e1e2e", "primaryColor": "#313244", "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"}}}%%\n'
	put docs/d.md '%%{ init: {"theme": "base", "themeVariables": {"background": "#1e1e2e", "primaryColor": "#313244", "fontFamily": "JetBrainsMono Nerd Font, ui-monospace, monospace"}} }%%\n'
	expect_hits "docs/a.md:1:mermaid-init" "docs/b.md:1:mermaid-init"
}

prose_about_the_init_syntax_is_no_block() {
	new_tree
	put docs/a.md 'The block `%%{init: ...}%%` is shared; write %%{init: x}%% in prose.\n'
	expect_clean
}

an_indented_init_block_is_judged() {
	new_tree
	put docs/a.md '- item\n\n    %%{init: {"theme": "dark"}}%%\n'
	expect_hits "docs/a.md:3:mermaid-init"
}

an_init_block_that_never_closes_is_a_hit() {
	new_tree
	put docs/a.md 'a\n%%{init: {"theme": "base"\nflowchart LR\n'
	expect_hits "docs/a.md:2:mermaid-init"
}

a_hex_color_in_a_mermaid_style_line_is_a_hit() {
	new_tree
	put docs/a.md '```mermaid\nflowchart LR\n  A[a]\n  style A fill:#313244,stroke:#cba6f7\n```\n'
	expect_hits "docs/a.md:4:hex-color"
}

a_missing_shared_theme_is_bad_usage_when_a_block_needs_it() {
	new_tree
	put docs/a.md '%%{init: {"theme": "base"}}%%\n'
	capture in_tree env RAVNIX_MERMAID_THEME="$scratch/nowhere.json" "$check" .
	expect_status 2
	expect_err "cannot read the shared Mermaid theme"
	put docs/a.md 'no block here\n'
	capture in_tree env RAVNIX_MERMAID_THEME="$scratch/nowhere.json" "$check" .
	expect_status 0
}

the_repository_init_block_and_the_shared_theme_agree() {
	[[ -f "$src/docs/style.md" && -f "$src/docs/mermaid-theme.json" ]] || {
		echo "  docs/style.md or docs/mermaid-theme.json is missing from $src"
		return 1
	}
	new_tree
	mkdir -p "$tree/docs"
	cp "$src/docs/style.md" "$tree/docs/"
	# Without RAVNIX_MERMAID_THEME the script reads the docs/mermaid-theme.json
	# beside its own scripts/ directory, which is the repository's.
	capture in_tree env -u RAVNIX_MERMAID_THEME "$check" docs/style.md
	expect_status 0
}

# Robustness.

an_empty_tree_and_an_empty_file_pass() {
	new_tree
	expect_clean
	put modules/empty.nix ''
	put a.css ''
	expect_clean
}

a_directory_without_judged_files_passes() {
	new_tree
	put README.txt 'nothing to see\n'
	expect_clean
}

a_file_without_a_final_newline_is_judged() {
	new_tree
	put a.css 'a { border-radius: 4px }'
	expect_hits "a.css:1:radius"
}

windows_line_ends_are_judged_like_unix_ones() {
	new_tree
	put a.css 'a { border-radius: 0; }\r\nb { border-radius: 0 }\r\nc { opacity: 1 }\r\n'
	put b.css 'a { border-radius: 4px }\r\nb { color: #cba6f7 }\r\n'
	expect_hits "b.css:1:radius" "b.css:2:hex-color"
}

a_path_with_spaces_or_a_colon_is_reported_whole() {
	new_tree
	put 'modules/a b/c d.css' 'a { border-radius: 4px; }\n'
	put 'modules/x:y.css' 'a { border-radius: 4px; }\n'
	expect_hits "modules/a b/c d.css:1:radius" "modules/x:y.css:1:radius"
}

a_binary_file_with_a_style_name_does_not_crash_the_check() {
	new_tree
	printf '\0\1\2#cba6f7\0\3' >"$tree/a.css"
	run_check .
	[[ "$status" == 0 || "$status" == 1 ]] || {
		echo "  expected exit 0 or 1, got $status: $err"
		return 1
	}
}

a_huge_line_is_judged_in_time() {
	new_tree
	local big="$tree/big.css"
	head -c 3000000 /dev/zero | tr '\0' 'x' >"$big"
	printf '\na { border-radius: 4px; }\n' >>"$big"
	run_check .
	expect_status 1
	expect_out "big.css:2:radius"
	# One line of 3 MB with a property in the middle of it.
	{
		head -c 1000000 /dev/zero | tr '\0' ' '
		printf 'a { opacity: 0.5; }'
		head -c 1000000 /dev/zero | tr '\0' ' '
		printf '\n'
	} >"$big"
	run_check .
	expect_status 1
	expect_out "big.css:1:opacity"
}

many_files_are_judged_in_slices() {
	new_tree
	local i
	for i in $(seq 1 1300); do
		printf 'a { color: red; }\n' >"$tree/f$i.css"
	done
	printf 'a { border-radius: 4px; }\n' >"$tree/f1299.css"
	run_check .
	expect_status 1
	expect_out "f1299.css:1:radius"
	expect_lines 1
}

an_unreadable_file_is_bad_usage() {
	(($(id -u) != 0)) || return 0 # root reads it anyway
	new_tree
	put locked.css 'a { border-radius: 4px; }\n'
	chmod 000 "$tree/locked.css"
	run_check .
	expect_status 2
}

a_file_argument_is_judged_by_its_own_path() {
	new_tree
	put modules/theme/x.nix 'c = "#cba6f7";\n'
	put modules/y.nix 'c = "#cba6f7";\n'
	put tests/z.nix 'c = "#cba6f7";\n'
	run_check modules/theme/x.nix
	expect_status 0
	run_check tests/z.nix
	expect_status 0
	run_check modules/y.nix
	expect_status 1
	expect_out "modules/y.nix:1:hex-color"
	run_check modules/theme/x.nix modules/y.nix tests/z.nix
	expect_status 1
	expect_lines 1
}

a_directory_outside_the_current_directory_is_its_own_root() {
	new_tree
	put modules/theme/x.nix 'c = "#cba6f7";\n'
	put modules/y.nix 'c = "#cba6f7";\n'
	put tests/z.css 'a { border-radius: 4px; }\n'
	put themes/t.css 'a { border-radius: 4px; }\n'
	local elsewhere="$scratch/elsewhere"
	mkdir -p "$elsewhere"
	capture env -C "$elsewhere" "$check" "$tree"
	expect_status 1
	expect_out "$tree/modules/y.nix:1:hex-color
$tree/themes/t.css:1:radius"
}

an_absolute_directory_below_the_current_directory_is_anchored_there() {
	new_tree
	put modules/theme/x.nix 'c = "#cba6f7";\n'
	put modules/y.nix 'c = "#cba6f7";\n'
	put tests/z.css 'a { border-radius: 4px; }\n'
	capture env -C "$tree" "$check" "$tree/modules" "$tree/tests"
	expect_status 1
	expect_out "$tree/modules/y.nix:1:hex-color"
	run_check ./modules ./tests
	expect_status 1
	expect_out "./modules/y.nix:1:hex-color"
}

a_file_outside_the_current_directory_gets_no_exemption() {
	new_tree
	put modules/theme/x.nix 'c = "#cba6f7";\n'
	local elsewhere="$scratch/elsewhere"
	mkdir -p "$elsewhere"
	capture env -C "$elsewhere" "$check" "$tree/modules/theme/x.nix"
	expect_status 1
	expect_out "$tree/modules/theme/x.nix:1:hex-color"
}

a_double_slash_comment_hides_an_issue_number_except_in_nix() {
	new_tree
	put modules/a.conf 'x = 1 // see #290879\n'
	put modules/b.nix 'x = a // b; # not #290879\nx = a // b; // see #290879\nx = "#290879"; # a color\n'
	expect_hits "modules/b.nix:2:hex-color" "modules/b.nix:3:hex-color"
}

a_file_given_by_an_absolute_path_is_judged_below_the_current_directory() {
	local dir="$scratch/tests/vendor/proj"
	mkdir -p "$dir/modules" "$dir/tests"
	printf 'c = "#cba6f7";\n' >"$dir/modules/x.nix"
	printf 'c = "#cba6f7";\n' >"$dir/tests/y.nix"
	capture env -C "$dir" "$check" "$dir/modules/x.nix"
	expect_status 1
	expect_out "$dir/modules/x.nix:1:hex-color"
	capture env -C "$dir" "$check" "$dir/tests/y.nix"
	expect_status 0
}

the_same_file_given_twice_is_reported_once() {
	new_tree
	put a.css 'a { border-radius: 4px; }\n'
	run_check a.css a.css .
	expect_status 1
	expect_lines 1
}

two_runs_at_once_agree() {
	new_tree
	put a.css 'a { border-radius: 4px; }\n'
	put modules/b.nix 'c = "#cba6f7";\n'
	local one="$scratch/one" two="$scratch/two"
	(cd "$tree" && { "$check" . >"$one" 2>&1 || echo "exit $?" >>"$one"; }) &
	(cd "$tree" && { "$check" . >"$two" 2>&1 || echo "exit $?" >>"$two"; }) &
	wait
	diff "$one" "$two"
	[[ "$(tail -n1 "$one")" == "exit 1" ]]
}

hits_are_sorted_by_file_and_line() {
	new_tree
	put z.css 'a { border-radius: 4px; }\n'
	put modules/m.nix 'a = 1;\nb = "#cba6f7";\nradius = 3;\n'
	put a.css 'a { opacity: 0.5; }\n\nb { border-radius: 2px; }\n'
	expect_hits "a.css:1:opacity" "a.css:3:radius" "modules/m.nix:2:hex-color" \
		"modules/m.nix:3:radius" "z.css:1:radius"
}

tests=(
	no_path_is_bad_usage
	an_option_is_bad_usage
	a_file_named_like_an_option_is_reached_with_a_prefix
	a_missing_path_is_bad_usage
	a_missing_rg_is_bad_usage
	a_hex_color_in_a_module_outside_the_theme_is_a_hit
	the_same_hex_color_inside_the_theme_module_passes
	the_vendor_root_is_exempt_from_the_hex_rule_only
	an_exemption_is_a_place_and_not_a_name
	a_directory_argument_is_anchored_at_the_current_directory
	the_style_document_itself_may_hold_hex_colors
	the_theme_exemption_is_the_directory_not_a_prefix
	another_document_may_not
	a_hex_color_in_a_comment_is_still_a_hit
	a_short_hex_color_in_css_or_quotes_is_a_hit
	a_hex_color_with_alpha_is_a_hit_for_two_rules
	an_alpha_in_the_theme_module_is_still_a_hit
	two_colors_on_one_line_are_one_hit
	things_that_look_like_hex_but_are_not_colors_pass
	tests_fixtures_and_other_languages_are_not_judged
	a_nix_file_in_tools_is_judged_like_any_other
	a_file_without_an_extension_under_modules_is_judged
	a_file_without_an_extension_elsewhere_is_not
	a_directory_below_tests_is_judged_by_what_is_below_it
	a_path_with_brackets_quotes_or_a_dollar_is_judged
	a_symbolic_link_is_not_followed
	a_radius_other_than_zero_is_a_hit
	a_radius_of_zero_passes
	radius_keys_in_configs_are_judged
	the_lock_ring_radius_is_a_gauge_not_a_corner
	a_rounded_border_is_a_hit
	rounded_corners_are_a_hit_unless_off
	any_radius_key_is_a_hit_except_the_lock_ring_gauge
	a_declaration_after_a_closed_comment_or_a_selector_star_is_judged
	a_lua_comment_is_a_comment
	a_radius_in_a_comment_passes
	an_opacity_below_one_is_a_hit
	an_opacity_of_one_passes
	an_alpha_function_in_css_is_a_hit
	an_rgba_with_alpha_below_one_is_a_hit
	an_alpha_key_in_a_config_is_a_hit
	the_sway_opacity_command_is_a_hit
	a_translucent_bare_color_in_a_config_is_a_hit
	a_bare_color_outside_the_theme_is_a_hex_color_hit
	an_eight_digit_value_that_is_not_a_color_passes
	the_inside_of_the_lock_ring_is_the_one_exemption
	no_other_swaylock_color_may_be_translucent
	a_sway_command_in_a_nix_string_is_a_hit
	the_transparent_keyword_is_a_hit
	an_alpha_that_is_a_smoothing_factor_is_no_opacity
	a_transition_or_animation_key_is_a_hit
	a_key_that_turns_motion_off_passes
	an_issue_number_in_a_trailing_comment_is_no_color
	a_link_anchor_is_no_color
	an_issue_number_is_no_color
	turning_animations_on_is_a_hit
	words_that_merely_contain_the_names_pass
	a_mermaid_init_block_identical_to_the_shared_one_passes
	a_mermaid_init_block_with_a_changed_color_is_a_hit
	a_one_line_init_block_and_a_different_theme_are_judged_too
	init_spellings_with_spaces_or_initialize_are_blocks
	prose_about_the_init_syntax_is_no_block
	an_indented_init_block_is_judged
	an_init_block_that_never_closes_is_a_hit
	a_hex_color_in_a_mermaid_style_line_is_a_hit
	a_missing_shared_theme_is_bad_usage_when_a_block_needs_it
	the_repository_init_block_and_the_shared_theme_agree
	an_empty_tree_and_an_empty_file_pass
	a_directory_without_judged_files_passes
	a_file_without_a_final_newline_is_judged
	windows_line_ends_are_judged_like_unix_ones
	a_path_with_spaces_or_a_colon_is_reported_whole
	a_binary_file_with_a_style_name_does_not_crash_the_check
	a_huge_line_is_judged_in_time
	many_files_are_judged_in_slices
	an_unreadable_file_is_bad_usage
	a_file_argument_is_judged_by_its_own_path
	a_directory_outside_the_current_directory_is_its_own_root
	an_absolute_directory_below_the_current_directory_is_anchored_there
	a_file_outside_the_current_directory_gets_no_exemption
	a_double_slash_comment_hides_an_issue_number_except_in_nix
	a_file_given_by_an_absolute_path_is_judged_below_the_current_directory
	the_same_file_given_twice_is_reported_once
	two_runs_at_once_agree
	hits_are_sorted_by_file_and_line
)

run_tests "${tests[@]}"
