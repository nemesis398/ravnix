// The radius, opacity and transparent rules: the cases of the shell test.
package check_style_tests

import "core:testing"

// Radii.

@(test)
a_radius_other_than_zero_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 4px; }\n")
	put(t, f, "b.css", "a { border-top-left-radius: 2px; }\nb { -gtk-outline-radius: 3px; }\nc { border-radius: 0 0 0 1px; }\n")
	put(t, f, "c.css", "a { -moz-border-radius: .5em; }\nb { border-radius: var(--r); }\nc { border-radius: calc(0px + 1px); }\n")
	expect_hits(t, f, "a.css:1:radius", "b.css:1:radius", "b.css:2:radius", "b.css:3:radius", "c.css:1:radius", "c.css:2:radius", "c.css:3:radius")
}

@(test)
a_radius_of_zero_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { border-radius: 0; }\nb { border-radius: 0px !important; }\nc { border-radius: 0 0 0 0 }\n")
	put(t, f, "b.css", "* { border-radius: 0; }\n*, *::before { border-radius: 0px; }\n")
	put(t, f, "c.css", "a { border-radius: 0.0; border-top-left-radius: 0%; }\n")
	expect_clean(t, f)
}

@(test)
radius_keys_in_configs_are_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "radius = 10;\ncorner_radius = 12;\n\"border-radius\" = \"4px\";\n")
	put(t, f, "modules/b.ini", "[border]\nradius=8\n")
	put(t, f, "modules/c.nix", "radius = 0;\n")
	put(t, f, "modules/d.ini", "[border]\nradius=0\n")
	expect_hits(t, f, "modules/a.nix:1:radius", "modules/a.nix:2:radius", "modules/a.nix:3:radius", "modules/b.ini:2:radius")
}

@(test)
the_lock_ring_radius_is_a_gauge_not_a_corner :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/swaylock.conf", "indicator-radius=110\nindicator-thickness=10\n")
	put(t, f, "modules/swaylock.nix", "\"indicator-radius\" = 110;\nindicator-radius = 110;\n")
	expect_clean(t, f)
}

@(test)
a_rounded_border_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "ui = { border = \"rounded\"; };\nwinborder = \"rounded\";\n")
	put(t, f, "modules/nvim/init.lua", "vim.o.winborder = \"rounded\"\nui = { border = \"single\" }\nvim.o.winborder = \"single\"\n")
	put(t, f, "modules/b.nix", "border = \"single\";\nstyle = \"rounded\";\n")
	expect_hits(t, f, "modules/a.nix:1:radius", "modules/a.nix:2:radius", "modules/nvim/init.lua:1:radius")
}

@(test)
rounded_corners_are_a_hit_unless_off :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/mangohud.conf", "round_corners=10\n")
	put(t, f, "modules/b.nix", "rounded_corners = true;\nround-corners = 1;\n")
	put(t, f, "modules/c.conf", "round_corners=0\n")
	put(t, f, "modules/d.nix", "rounded_corners = false;\n")
	expect_hits(t, f, "modules/b.nix:1:radius", "modules/b.nix:2:radius", "modules/mangohud.conf:1:radius")
}

@(test)
a_radius_of_the_lock_ring_is_geometry_not_a_corner :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.toml", "ring_radius = 110\nlock-ring-radius = 100\nlock_ring_radius = 100\nindicator_radius = 110\nindicator-radius = 110\nRing_Radius = 9\n")
	expect_clean(t, f)
	put(t, f, "modules/b.toml", "spring_radius = 5\nringradius = 5\nring_radius_x = 5\nring_corner_radius = 5\n")
	expect_hits(t, f, "modules/b.toml:1:radius", "modules/b.toml:2:radius", "modules/b.toml:4:radius")
}

@(test)
a_ring_that_is_not_the_lock_ring_has_a_corner :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.toml", "focus_ring_radius = 8\nouter-ring-radius = 8\nunlock_ring_radius = 8\nwindow.focus_ring_radius = 8\n")
	put(t, f, "modules/b.nix", "programs.x.settings.focus_ring_radius = 8;\nprograms.swaylock.settings.indicator-radius = 110;\nsettings.lock-ring-radius = 100;\n")
	expect_hits(t, f, "modules/a.toml:1:radius", "modules/a.toml:2:radius", "modules/a.toml:3:radius", "modules/a.toml:4:radius", "modules/b.nix:1:radius")
}

@(test)
any_radius_key_is_a_hit_except_the_lock_ring_gauge :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/dunstrc", "progress_bar_corner_radius = 4\nicon_corner_radius = 4\n")
	put(t, f, "modules/b.nix", "selection_radius = 3;\nfoo-radius: 2px;\n")
	put(t, f, "modules/c.nix", "progress_bar_corner_radius = 0;\nindicator_radius = 110;\n\"indicator-radius\" = 110;\n")
	expect_hits(t, f, "modules/b.nix:1:radius", "modules/b.nix:2:radius", "modules/dunstrc:1:radius", "modules/dunstrc:2:radius")
}

@(test)
a_declaration_after_a_closed_comment_or_a_selector_star_is_judged :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "/* x */ border-radius: 4px;\n* button { border-radius: 4px; }\n")
	expect_hits(t, f, "a.css:1:radius", "a.css:2:radius")
}

@(test)
a_lua_comment_is_a_comment :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/nvim/init.lua", "-- No animations: no smooth scrolling, corner_radius = 4\nvim.g.snacks_animate = false\nvim.o.winborder = \"single\"\nlocal half = 6 // 2\n")
	expect_clean(t, f)
	put(t, f, "modules/nvim/b.lua", "animations = true\n-- animations = true\n")
	expect_hits(t, f, "modules/nvim/b.lua:1:motion")
}

@(test)
a_radius_in_a_comment_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "/* border-radius: 4px */\n/*\n * border-radius: 4px;\n */\na { border-radius: 0; /* was border-radius: 4px */ }\n")
	put(t, f, "modules/a.nix", "# radius = 10;\n  # border-radius: 4px\n")
	put(t, f, "b.css", "// border-radius: 4px\n")
	expect_clean(t, f)
}

// Opacity.

@(test)
an_opacity_below_one_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { opacity: 0.9; }\nb { opacity: .5; }\nc { opacity: 0; }\nd { opacity: 90%; }\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:2:opacity", "a.css:3:opacity", "a.css:4:opacity")
}

@(test)
an_opacity_of_one_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { opacity: 1; }\nb { opacity: 1.0; }\nc { opacity: 100%; }\n")
	put(t, f, "modules/b.nix", "opacity = 1;\ncfg.opacity = config.x.opacity;\n")
	expect_clean(t, f)
}

@(test)
an_alpha_function_in_css_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "waybar.css", "#clock:hover { background: alpha(@accent, 0.18); }\n")
	expect_hits(t, f, "waybar.css:1:opacity")
}

@(test)
an_rgba_with_alpha_below_one_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "a { background: rgba(0, 0, 0, 0.5); }\nb { background: rgb(0 0 0 / 50%); }\nc { background: hsla(0, 0%, 0%, .3); }\n")
	put(t, f, "b.css", "a { background: rgba(0, 0, 0, 1); }\nb { background: rgb(1, 2, 0); }\nc { background: rgb(0 0 0 / 100%); }\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:2:opacity", "a.css:3:opacity")
}

@(test)
an_alpha_key_in_a_config_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/mangohud.conf", "background_alpha=0.8\n")
	put(t, f, "modules/b.nix", "window_opacity = 0.9;\n\"inactive-opacity\" = \"0.7\";\n")
	put(t, f, "modules/c.conf", "background_alpha=1\nopacity=1.0\n")
	expect_hits(t, f, "modules/b.nix:1:opacity", "modules/b.nix:2:opacity", "modules/mangohud.conf:1:opacity")
}

@(test)
the_sway_opacity_command_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/sway/config", "for_window [app_id=\".*\"] opacity 0.9\nfor_window [class=x] opacity set 0.8\nfor_window [class=y] opacity 1\n")
	expect_hits(t, f, "modules/sway/config:1:opacity", "modules/sway/config:2:opacity")
}

@(test)
a_translucent_bare_color_in_a_config_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	// Below the theme module, where a hex color is allowed, only the alpha counts.
	put(t, f, "modules/theme/fuzzel.ini", "[colors]\nbackground=1e1e2edd\ntext=cdd6f4ff\nselection=45475acc\n")
	put(t, f, "modules/theme/b.nix", "border = \"cba6f780\";\nring-color = \"#585b7080\";\n")
	put(t, f, "modules/theme/c.ini", "[colors]\nbackground=1e1e2eff\nselection=45475aFF\n")
	expect_hits(t, f, "modules/theme/b.nix:1:opacity", "modules/theme/b.nix:2:opacity", "modules/theme/fuzzel.ini:2:opacity", "modules/theme/fuzzel.ini:4:opacity")
}

@(test)
a_bare_color_outside_the_theme_is_a_hex_color_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/fuzzel.ini", "[colors]\nbackground=1e1e2eff\ntext=cdd6f4\nselection=45475aFF\n")
	put(t, f, "modules/swaylock.conf", "inside-color=00000000\nring-color=585b70\n")
	put(t, f, "modules/b.nix", "\"inside-ver-color\" = \"#1e1e2ecc\";\nborder = \"cba6f7\";\n")
	put(t, f, "modules/theme/ok.conf", "background=1e1e2eff\ninside-color=00000000\nring-color=585b70\n")
	expect_hits(
		t,
		f,
		"modules/b.nix:1:hex-color",
		"modules/b.nix:2:hex-color",
		"modules/fuzzel.ini:2:hex-color",
		"modules/fuzzel.ini:3:hex-color",
		"modules/fuzzel.ini:4:hex-color",
		"modules/swaylock.conf:1:hex-color",
		"modules/swaylock.conf:2:hex-color",
	)
}

@(test)
an_eight_digit_value_that_is_not_a_color_passes :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "version = \"20240101\";\nrev = \"deadbeef\";\nserial = \"12345678\";\nshort = \"123456\";\n")
	put(t, f, "modules/b.nix", "contextId = \"1a2b3c4d\";\ninputs = \"1a2b3c4d\";\nframework = \"1a2b3c\";\nrematched = \"1a2b3c4d\";\n")
	expect_clean(t, f)
}

@(test)
the_inside_and_the_separator_of_the_lock_ring_are_the_exemption :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/swaylock.conf", "inside-color=00000000\ninside-clear-color=1e1e2e00\ninside-ver-color=1e1e2ecc\ninside-wrong-color=1e1e2ecc\ninside-caps-lock-color=1e1e2ecc\nseparator-color=1e1e2e00\n")
	put(t, f, "modules/theme/swaylock.nix", "\"inside-ver-color\" = \"1e1e2ecc\";\ninside-color = \"00000000\";\n\"inside-wrong-color\" = \"#1e1e2ecc\";\ninside-clear-color = \"#1e1e2e00\";\nseparator-color = \"#1e1e2e00\";\n")
	expect_clean(t, f)
}

@(test)
a_separator_is_clear_or_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/ok.conf", "separator-color=00000000\nseparator-color=1e1e2e00\n")
	put(t, f, "modules/theme/ok.nix", "separator-color = \"#1e1e2e00\";\n\"separator-color\" = \"1e1e2e00\";\n")
	expect_clean(t, f)
	put(t, f, "modules/theme/bad.conf", "separator-color=1e1e2ecc\nseparator-color=1e1e2e01\n")
	put(t, f, "modules/theme/bad.nix", "separator-color = \"#1e1e2ecc\";\n\"separator-color\" = \"1e1e2e80\";\n")
	expect_hits(t, f, "modules/theme/bad.conf:1:opacity", "modules/theme/bad.conf:2:opacity", "modules/theme/bad.nix:1:opacity", "modules/theme/bad.nix:2:opacity")
}

@(test)
no_other_swaylock_color_may_be_translucent :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/theme/swaylock.conf", "ring-color=585b7080\nline-color=1e1e2e00\ntext-color=cdd6f4cc\nkey-hl-color=cba6f7cc\nseparator-ring-color=00000000\n")
	put(t, f, "modules/theme/swaylock.nix", "text-color = \"#cdd6f4cc\";\n")
	expect_hits(
		t,
		f,
		"modules/theme/swaylock.conf:1:opacity",
		"modules/theme/swaylock.conf:2:opacity",
		"modules/theme/swaylock.conf:3:opacity",
		"modules/theme/swaylock.conf:4:opacity",
		"modules/theme/swaylock.conf:5:opacity",
		"modules/theme/swaylock.nix:1:opacity",
	)
}

@(test)
a_sway_command_in_a_nix_string_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "command = \"opacity 0.9\";\ncmd2 = \"opacity set 0.8\";\ncmd3 = \"opacity 1\";\n")
	expect_hits(t, f, "modules/a.nix:1:opacity", "modules/a.nix:2:opacity")
}

@(test)
prose_that_holds_the_word_transparent_is_no_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.nix", "description = ''\n    Default: transparent\n    Example: a transparent proxy;\n  '';\nx = 1; # Default: transparent\n")
	put(t, f, "modules/b.json5", "{ \"default\": \"transparent\", \"note\": \"transparent\" }\n")
	expect_clean(t, f)
	put(t, f, "modules/c.nix", "description = ''\n    background: transparent;\n  '';\nsettings.\"ui.menu\" = transparent;\nx = 1; # background: transparent\n")
	expect_hits(t, f, "modules/c.nix:2:opacity", "modules/c.nix:4:opacity", "modules/c.nix:5:opacity")
}

@(test)
the_transparent_keyword_is_a_hit :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "a.css", "#clock { background: transparent; }\nb { border-bottom: 2px solid transparent; }\n@define-color marker transparent;\nc { background: inherit; border-bottom: 2px solid @mantle; }\n")
	put(t, f, "modules/b.nix", "background = \"transparent\";\ndescription = \"A transparent proxy\";\n")
	expect_hits(t, f, "a.css:1:opacity", "a.css:2:opacity", "a.css:3:opacity", "modules/b.nix:1:opacity")
}

@(test)
neovim_blend_is_transparency_unless_it_is_zero :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/nvim/a.lua", "vim.o.pumblend = 10\nvim.opt.winblend = 20\nlocal t = { winblend = 5 }\nvim.wo.winblend = \"30\"\n")
	put(t, f, "modules/nvim/b.vim", "set pumblend=10\nset winblend=0\n")
	put(t, f, "modules/nvim/c.lua", "vim.o.pumblend = 0\nvim.opt.winblend = 0\nlocal t = { winblend = vim.o.pumblend }\nlocal u = { blendmode = 10, windowblend = 10 }\n")
	expect_hits(t, f, "modules/nvim/a.lua:1:opacity", "modules/nvim/a.lua:2:opacity", "modules/nvim/a.lua:3:opacity", "modules/nvim/a.lua:4:opacity", "modules/nvim/b.vim:1:opacity")
}

@(test)
an_alpha_that_is_a_smoothing_factor_is_no_opacity :: proc(t: ^testing.T) {
	f := enter(t)
	put(t, f, "modules/a.toml", "smoothing_alpha = 0.3\nlearning-alpha = 0.1\n")
	expect_clean(t, f)
	put(t, f, "modules/b.toml", "alpha = 0.5\nbg_alpha = 0.5\nwindow-alpha: 0.9\ninactive_opacity = 0.9\n")
	expect_hits(t, f, "modules/b.toml:1:opacity", "modules/b.toml:2:opacity", "modules/b.toml:3:opacity", "modules/b.toml:4:opacity")
}
