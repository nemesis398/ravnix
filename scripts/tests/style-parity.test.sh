#!/usr/bin/env bash
# Tests for scripts/style-parity.sh, the config parity diff: it normalises a
# generated config and its stow source, diffs them and removes the differences
# a config file allows. Every test builds its own small stow tree, built tree
# and config in the scratch directory; no test reads a real config, and the
# fixtures hold only invented values. Run it with:
#
#   bash scripts/tests/style-parity.test.sh
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

# Fixture files are written in single quotes on purpose, and lib.sh sets out.
# shellcheck disable=SC2016,SC2154
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../style-parity.sh"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

tab=$'\t'
stow="$scratch/stow"
home="$scratch/home"
sysroot="$scratch/sys"
conf="$scratch/parity.conf"

setup() {
	rm -rf "$stow" "$home" "$sysroot" "$conf"
	mkdir -p "$stow" "$home" "$sysroot"
	: >"$conf"
}

# put DIR RELPATH CONTENT: writes a file below DIR, making its directories.
put() {
	mkdir -p "$(dirname "$1/$2")"
	printf '%s' "$3" >"$1/$2"
}
# cfg WORDS...: appends one tab separated line to the config.
cfg() {
	local IFS="$tab"
	printf '%s\n' "$*" >>"$conf"
}
parity() {
	capture bash "$script" --stow "$stow" --built home="$home" --built sys="$sysroot" --config "$conf" "$@"
}
expect_remaining() {
	expect_out "$1"
}

# ── the formats ─────────────────────────────────────────────────────────────

test_equal_up_to_comments_order_quotes_and_hex_case_is_clean() {
	setup
	put "$stow" a.ini '# a comment
[main]
font = Mono 9
width=50

[colors]
frame_color = "#CBA6F7"
background=1E1E2EDD
'
	put "$home" a.ini '[colors]
background=1e1e2edd
frame_color="#cba6f7"
[main]
width = 50
font="Mono 9"
'
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 0
	expect_out "no remaining differences"
	expect_out "ok    a.ini"
}

test_kv_difference_shows_both_sides_with_the_section() {
	setup
	put "$stow" a.ini '[colors]
selection=585b70ff
'
	put "$home" a.ini '[colors]
selection=45475aff
'
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 1
	expect_remaining "-colors.selection=585b70ff"
	expect_remaining "+colors.selection=45475aff"
	expect_out "DIFF  a.ini"
}

test_kv_toml_multiline_format_joins_continuations() {
	setup
	put "$stow" s.toml 'format = """\
$directory\
$character"""
[character]
error_symbol = "[x](bold mauve)"
'
	put "$home" s.toml 'format = "$directory$character"
[character]
error_symbol = "[x](bold mauve)"
'
	cfg compare kv s.toml home:s.toml
	parity
	expect_status 0
}

test_kv_repeated_keys_count_as_a_set() {
	setup
	put "$stow" g 'palette = 0=#45475a
palette = 1=#f38ba8
'
	put "$home" g 'palette = 1=#F38BA8
palette = 0=#45475a
'
	cfg compare kv g home:g
	parity
	expect_status 0
}

test_yaml_nests_by_indent_and_ignores_order_and_comments() {
	setup
	put "$stow" l.yml 'gui:
  # comment
  theme:
    activeBorderColor:
      - "#cba6f7"
      - bold
    other: x
  border: single
'
	put "$home" l.yml 'gui:
  border: single
  theme:
    other: x
    activeBorderColor:
      - bold
      - "#CBA6F7"
'
	cfg compare yaml l.yml home:l.yml
	parity
	expect_status 0
	put "$home" l.yml 'gui:
  border: rounded
  theme:
    other: x
    activeBorderColor:
      - bold
      - "#CBA6F7"
'
	parity
	expect_status 1
	expect_remaining "-gui.border=single"
	expect_remaining "+gui.border=rounded"
}

test_css_compares_declarations_per_selector_and_ignores_layout_and_comments() {
	setup
	put "$stow" s.css '@define-color accent #CBA6F7;
/* a comment
   over two lines */
#custom-battery, #cpu {
  min-width: 64px;   /* floor */
  color: @accent;
}
window#waybar { background: @base }
'
	put "$home" s.css '@define-color accent #cba6f7;
#custom-battery, #cpu { min-width: 64px; color: @accent; }
window#waybar {
background: @base;
}
'
	cfg compare css s.css home:s.css
	parity
	expect_status 0
	put "$home" s.css '@define-color accent #cba6f7;
#custom-battery, #cpu { min-width: 72px; color: @accent; }
window#waybar { background: @base; }
'
	parity
	expect_status 1
	expect_remaining "-#custom-battery, #cpu :: min-width: 64px"
	expect_remaining "+#custom-battery, #cpu :: min-width: 72px"
}

test_css_nested_blocks_keep_their_outer_selector() {
	setup
	put "$stow" s.css '@media (x) { a { color: red; } }
'
	put "$home" s.css '@media (x) { a { color: blue; } }
'
	cfg compare css s.css home:s.css
	parity
	expect_status 1
	expect_remaining "-@media (x) > a :: color: red"
	expect_remaining "+@media (x) > a :: color: blue"
}

test_jsonc_ignores_comments_commas_and_layout_but_not_array_order() {
	setup
	put "$stow" c.jsonc '// top comment
{
  /* block */
  "url": "http://example.invalid/x", // trailing
  "modules": ["a", "b",],
  "nested": { "k": 1, },
}
'
	put "$home" c.jsonc '{"nested":{"k":1},"modules":["a","b"],"url":"http://example.invalid/x"}
'
	cfg compare jsonc c.jsonc home:c.jsonc
	parity
	expect_status 0
	put "$home" c.jsonc '{"nested":{"k":1},"modules":["b","a"],"url":"http://example.invalid/x"}
'
	parity
	expect_status 1
	expect_remaining '-modules.0 = "a"'
	expect_remaining '+modules.0 = "b"'
}

test_jsonc_that_does_not_parse_is_an_error_naming_the_file() {
	setup
	put "$stow" c.jsonc '{ "a": '
	put "$home" c.jsonc '{ "a": 1 }'
	cfg compare jsonc c.jsonc home:c.jsonc
	parity
	expect_status 2
	expect_said "c.jsonc"
	expect_said "cannot read"
}

test_lines_format_keeps_order_and_drops_comments_and_blank_lines() {
	setup
	put "$stow" sway '# comment
set $mod   Mod4

bindsym $mod+Return exec ghostty
'
	put "$home" sway 'set $mod Mod4
bindsym $mod+Return exec ghostty
'
	cfg compare lines sway home:sway
	parity
	expect_status 0
	put "$home" sway 'bindsym $mod+Return exec ghostty
set $mod Mod4
'
	parity
	expect_status 1
}

test_script_format_ignores_the_wrapper_header_of_the_build() {
	setup
	put "$stow" tool '#!/usr/bin/env bash
# comment
set -uo pipefail
echo   "hi"
'
	put "$sysroot" tool '#!/nix/store/aaa-bash/bin/bash


export PATH="/nix/store/bbb-coreutils/bin:$PATH"

# comment
set -uo pipefail
echo "hi"
'
	cfg compare script tool sys:tool
	parity
	expect_status 1
	# Inner spacing inside a command is a difference for scripts: the
	# format collapses only the lines' edges.
	put "$stow" tool '#!/usr/bin/env bash
set -uo pipefail
  echo "hi"
'
	parity
	expect_status 0
}

test_pyscript_format_keeps_indentation() {
	setup
	put "$stow" tool '#!/usr/bin/env python3
if x:
    print(1)
'
	put "$sysroot" tool '#! /nix/store/aaa-python3/bin/python3
if x:
    print(1)
'
	cfg compare pyscript tool sys:tool
	parity
	expect_status 0
	put "$sysroot" tool '#! /nix/store/aaa-python3/bin/python3
if x:
print(1)
'
	parity
	expect_status 1
}

# ── the allow list ──────────────────────────────────────────────────────────

test_allowed_lines_are_removed_and_counted() {
	setup
	put "$stow" a.ini '[colors]
selection=585b70ff
'
	put "$home" a.ini '[colors]
selection=45475aff
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'a.ini' '-colors.selection=585b70ff' 'row one'
	cfg allow 'a.ini' '+colors.selection=45475aff' 'row one'
	parity
	expect_status 0
	expect_out "ok    a.ini (2 allowed)"
	expect_out "no remaining differences"
	expect_no_out "selection="
}

test_only_the_listed_side_is_allowed() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=2
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'a.ini' '-k=1'
	parity
	expect_status 1
	expect_remaining "+k=2"
	expect_no_out "-k=1"
}

test_an_allow_entry_matches_by_glob_on_the_stow_path() {
	setup
	put "$stow" d/a.ini 'k=1
'
	put "$home" d/a.ini 'k=2
'
	put "$stow" d/b.ini 'k=1
'
	put "$home" d/b.ini 'k=2
'
	cfg compare kv d/a.ini home:d/a.ini
	cfg compare kv d/b.ini home:d/b.ini
	cfg allow 'd/*.ini' '-k=1'
	cfg allow 'd/*.ini' '+k=2'
	parity
	expect_status 0
}

test_a_stale_allow_entry_fails_and_is_named() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'a.ini' '-k=9'
	parity
	expect_status 1
	expect_out "STALE"
	expect_out "-k=9"
}

test_an_allow_entry_for_a_file_nobody_compares_is_stale() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'zzz.ini' '-k=9'
	parity
	expect_status 1
	expect_out "STALE"
	expect_out "zzz.ini"
}

test_sub_rewrites_the_stow_side_before_the_diff() {
	setup
	put "$stow" a.ini 'accent=aabbcc
frame=aabbcc
'
	put "$home" a.ini 'accent=112233
frame=112233
'
	cfg compare kv a.ini home:a.ini
	cfg sub 'a.ini' 'aabbcc' '112233'
	parity
	expect_status 0
}

test_a_sub_that_changes_nothing_is_stale() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	cfg sub 'a.ini' 'nothere' 'x'
	parity
	expect_status 1
	expect_out "STALE"
	expect_out "nothere"
}

test_show_allowed_lists_the_removed_lines() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=2
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'a.ini' '-k=1' 'why'
	cfg allow 'a.ini' '+k=2' 'why'
	parity --show-allowed
	expect_status 0
	expect_out "allowed -k=1"
	expect_out "allowed +k=2"
}

# ── missing files and bad input ─────────────────────────────────────────────

test_a_missing_built_file_is_a_remaining_difference() {
	setup
	put "$stow" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 1
	expect_out "MISSING a.ini"
}

test_a_missing_built_file_can_be_allowed() {
	setup
	put "$stow" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	cfg allow 'a.ini' '!missing' 'not ported'
	parity
	expect_status 0
	expect_out "allowed missing a.ini"
}

test_a_missing_stow_source_is_an_error() {
	setup
	put "$home" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 2
	expect_said "a.ini"
	expect_said "stow"
}

test_an_unknown_built_root_is_an_error() {
	setup
	put "$stow" a.ini 'k=1
'
	cfg compare kv a.ini nowhere:a.ini
	parity
	expect_status 2
	expect_said "nowhere"
}

test_an_unknown_format_or_directive_is_an_error() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=1
'
	cfg compare toml a.ini home:a.ini
	parity
	expect_status 2
	expect_said "toml"
	setup
	cfg frobnicate x
	parity
	expect_status 2
	expect_said "frobnicate"
}

test_a_config_without_comparisons_is_an_error() {
	setup
	cfg allow 'a.ini' '-k=1'
	parity
	expect_status 2
	expect_said "no compare"
}

test_usage_errors() {
	setup
	capture bash "$script"
	expect_status 2
	expect_said "usage"
	capture bash "$script" --stow "$stow" --built home="$home"
	expect_status 2
	capture bash "$script" --stow "$stow" --config "$conf" --built nonsense
	expect_status 2
	expect_said "NAME=DIR"
	capture bash "$script" --bogus
	expect_status 2
	capture bash "$script" --stow "$scratch/none" --built home="$home" --config "$conf"
	expect_status 2
	capture bash "$script" --stow "$stow" --built home="$home" --config "$scratch/none"
	expect_status 2
	capture bash "$script" --help
	expect_status 0
	expect_out "usage"
}

test_empty_files_equal_each_other() {
	setup
	: >"$stow/a.ini"
	: >"$home/a.ini"
	cfg compare kv a.ini home:a.ini
	cfg compare css a.css home:a.css
	: >"$stow/a.css"
	: >"$home/a.css"
	cfg compare lines a.txt home:a.txt
	: >"$stow/a.txt"
	: >"$home/a.txt"
	parity
	expect_status 0
}

test_crlf_and_names_with_spaces_and_a_dash() {
	setup
	printf 'k = 1\r\n' >"$stow/-a b.ini"
	printf 'k=1\n' >"$home/-a b.ini"
	cfg compare kv '-a b.ini' 'home:-a b.ini'
	parity
	expect_status 0
}

test_a_huge_value_and_many_lines() {
	setup
	local big
	big="$(head -c 200000 /dev/zero | tr '\0' x)"
	{
		printf 'big=%s\n' "$big"
		for i in $(seq 1 3000); do printf 'k%s=%s\n' "$i" "$i"; done
	} >"$stow/a.ini"
	{
		for i in $(seq 3000 -1 1); do printf 'k%s=%s\n' "$i" "$i"; done
		printf 'big=%s\n' "${big}y"
	} >"$home/a.ini"
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 1
	[[ "$(printf '%s\n' "$out" | awk 'length > 190000' | wc -l)" == 2 ]]
}

test_a_symbolic_link_is_followed_like_a_store_file() {
	setup
	put "$scratch" real.ini 'k=1
'
	ln -s "$scratch/real.ini" "$home/a.ini"
	put "$stow" a.ini 'k=1
'
	cfg compare kv a.ini home:a.ini
	parity
	expect_status 0
}

test_two_runs_at_once_do_not_share_scratch_files() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=2
'
	cfg compare kv a.ini home:a.ini
	local i pids=() codes=0
	for i in 1 2 3 4; do
		bash "$script" --stow "$stow" --built home="$home" --config "$conf" >"$scratch/par.$i" 2>&1 &
		pids+=($!)
	done
	for i in "${pids[@]}"; do wait "$i" || codes=$((codes + 1)); done
	[[ "$codes" == 4 ]]
	for i in 1 2 3 4; do
		cmp -s "$scratch/par.1" "$scratch/par.$i"
	done
}

test_it_leaves_no_scratch_files_behind() {
	setup
	put "$stow" a.ini 'k=1
'
	put "$home" a.ini 'k=2
'
	cfg compare kv a.ini home:a.ini
	mkdir -p "$scratch/tmpd"
	capture env TMPDIR="$scratch/tmpd" bash "$script" --stow "$stow" --built home="$home" --config "$conf"
	[[ -z "$(ls -A "$scratch/tmpd")" ]]
}

test_a_missing_tool_is_named_before_any_work() {
	setup
	put "$stow" a.jsonc '{}'
	put "$home" a.jsonc '{}'
	cfg compare jsonc a.jsonc home:a.jsonc
	local d="$scratch/nojq" t
	mkdir -p "$d"
	for t in bash awk sed sort diff mktemp rm cat dirname tr head wc; do
		ln -s "$(command -v "$t")" "$d/$t"
	done
	capture env PATH="$d" "$BASH" "$script" --stow "$stow" --built home="$home" --config "$conf"
	expect_status 2
	expect_said "jq"
}

test_kv_bare_flags_are_keys_of_their_own() {
	setup
	put "$stow" lock 'font=Mono
show-failed-attempts
indicator-caps-lock
'
	put "$home" lock 'indicator-caps-lock
show-failed-attempts
font=Mono
'
	cfg compare kv lock home:lock
	parity
	expect_status 0
	put "$home" lock 'indicator-caps-lock
font=Mono
'
	parity
	expect_status 1
	expect_remaining "-show-failed-attempts="
}

test_yaml_document_markers_are_ignored() {
	setup
	put "$stow" l.yml 'a: 1
'
	put "$home" l.yml '%YAML 1.1
---
a: 1
'
	cfg compare yaml l.yml home:l.yml
	parity
	expect_status 0
}

test_sway_format_ignores_the_place_of_set_lines_only() {
	setup
	put "$stow" sway 'set $b 2
set $a 1
bindsym x exec y
'
	put "$home" sway 'bindsym x exec y
set $a 1
set $b 2
'
	cfg compare sway sway home:sway
	parity
	expect_status 0
	put "$home" sway 'set $a 1
set $b 2
bindsym x exec z
'
	parity
	expect_status 1
	expect_remaining "-bindsym x exec y"
	expect_remaining "+bindsym x exec z"
}

tests=(
	test_equal_up_to_comments_order_quotes_and_hex_case_is_clean
	test_kv_difference_shows_both_sides_with_the_section
	test_kv_toml_multiline_format_joins_continuations
	test_kv_repeated_keys_count_as_a_set
	test_kv_bare_flags_are_keys_of_their_own
	test_yaml_document_markers_are_ignored
	test_sway_format_ignores_the_place_of_set_lines_only
	test_yaml_nests_by_indent_and_ignores_order_and_comments
	test_css_compares_declarations_per_selector_and_ignores_layout_and_comments
	test_css_nested_blocks_keep_their_outer_selector
	test_jsonc_ignores_comments_commas_and_layout_but_not_array_order
	test_jsonc_that_does_not_parse_is_an_error_naming_the_file
	test_lines_format_keeps_order_and_drops_comments_and_blank_lines
	test_script_format_ignores_the_wrapper_header_of_the_build
	test_pyscript_format_keeps_indentation
	test_allowed_lines_are_removed_and_counted
	test_only_the_listed_side_is_allowed
	test_an_allow_entry_matches_by_glob_on_the_stow_path
	test_a_stale_allow_entry_fails_and_is_named
	test_an_allow_entry_for_a_file_nobody_compares_is_stale
	test_sub_rewrites_the_stow_side_before_the_diff
	test_a_sub_that_changes_nothing_is_stale
	test_show_allowed_lists_the_removed_lines
	test_a_missing_built_file_is_a_remaining_difference
	test_a_missing_built_file_can_be_allowed
	test_a_missing_stow_source_is_an_error
	test_an_unknown_built_root_is_an_error
	test_an_unknown_format_or_directive_is_an_error
	test_a_config_without_comparisons_is_an_error
	test_usage_errors
	test_empty_files_equal_each_other
	test_crlf_and_names_with_spaces_and_a_dash
	test_a_huge_value_and_many_lines
	test_a_symbolic_link_is_followed_like_a_store_file
	test_two_runs_at_once_do_not_share_scratch_files
	test_it_leaves_no_scratch_files_behind
	test_a_missing_tool_is_named_before_any_work
)
run_tests "${tests[@]}"
