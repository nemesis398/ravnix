#!/usr/bin/env bash
# The style check: what docs/style.md forbids and a program can see. It
# searches the given paths and prints one line per hit:
#
#   file:line:rule
#
# The rules:
#
#   hex-color     a hex color (#rrggbb or #rrggbbaa; #rgb and #rgba in CSS
#                 files, in quotes and after a color property) outside
#                 modules/theme/. Colors come from the theme module's roles,
#                 so the user's accent reaches them. A hex color in a comment
#                 counts.
#   radius        a border radius other than 0: border-radius and its
#                 per-corner forms, and the keys radius and corner_radius.
#                 indicator-radius is not one of these; the lock ring is a
#                 gauge.
#   opacity       anything below fully opaque: opacity or *_alpha below 1,
#                 alpha(), rgba() and hsla() with alpha below 1, sway's
#                 opacity command, a hex color or a bare RRGGBBAA value of a
#                 color key whose alpha is not full. The one exemption is the
#                 inside of the lock ring: swaylock's inside-*color keys.
#   motion        a transition or animation key, or @keyframes, unless the
#                 key turns motion off (none, false, off, 0s). Words that
#                 only contain the names, such as gtk-enable-animations, are
#                 no keys.
#   mermaid-init  a Mermaid init block (%%{init: ...}%% at the start of a line)
#                 that differs from the shared one in docs/mermaid-theme.json,
#                 compared without white space, or that never closes. The
#                 shared block may hold hex colors. Prose that mentions the
#                 syntax in the middle of a line is no block.
#
# Usage: check-style.sh PATH...
#
# At least one path is required. A directory is searched whole, a file by
# itself, and a symbolic link is never followed. The check judges styling
# sources and leaves the rest alone, so it cannot fire on a hash, a revision,
# a test fixture meant to fail or a program's own color table:
#
#   judged        *.nix, *.css, *.scss, *.tcss, *.rasi, *.ini, *.conf,
#                 *.toml, *.jsonc, *.kdl, *.colors, and every other file
#                 below modules/ or hosts/ (Sway's config has no extension),
#                 for all four rules; Markdown and Mermaid files (*.md,
#                 *.markdown, *.mmd, *.mermaid) for hex colors and Mermaid
#                 blocks. Images, fonts and lock files are never judged.
#   not judged    paths with a component named .git, .worktrees,
#                 .superpowers, node_modules, vendor, vendored, third_party,
#                 third-party, themes (vendored files), tests, fixtures,
#                 fixture or testdata (fixtures that fail on purpose).
#   hex allowed   below modules/theme/ and in docs/style.md. Those two may
#                 not be translucent, round or animated either.
#
# For a directory the components below it count, for a file argument the
# path as given, or below the current directory when it is below it, so
# scripts/check.sh hands it repository-relative paths and an absolute path
# in a checkout under a directory named tests is judged all the same.
# A line that is only a comment is not searched for radius, opacity and
# motion; the body lines of a block comment are, unless they start with a *.
# In a document or on a comment line, an all-digit #123456 is an issue number
# and no color.
#
# The shared Mermaid theme is docs/mermaid-theme.json, beside the scripts/
# directory this script is in, or the file that RAVNIX_MERMAID_THEME names.
#
# Exit status: 0 when nothing was found, 1 on a hit, 2 on bad usage, a path
# that does not exist, a missing rg or shared theme, or a file the search
# could not read.
#
# Changing this file so it finds less needs the maintainer's explicit
# approval (AGENTS.md, rule 6).

# The callbacks of search are called by their names.
# shellcheck disable=SC2329

set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

prog=check-style.sh

usage() {
	printf 'usage: %s PATH...\n' "$prog" >&2
	exit 2
}

die() {
	printf '%s: %s\n' "$prog" "$*" >&2
	exit 2
}

(($# >= 1)) || usage
for arg in "$@"; do
	[[ "$arg" != -* ]] || usage
done
command -v rg >/dev/null 2>&1 || die "rg not found; install ripgrep."

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mermaid_theme="${RAVNIX_MERMAID_THEME:-$here/../docs/mermaid-theme.json}"

# The same flags for every search: no user configuration, every file, binary
# files as text, only the matches, and the file and line on each, the file
# name ending in a NUL byte so no path can be mistaken for the line number.
rg_flags=(--no-config --no-ignore --hidden --text --color never --no-heading
	--with-filename --line-number --null --only-matching)

# --- Which files are judged --------------------------------------------

code=()    # judged files, all four rules
docs=()    # Markdown and Mermaid files: hex colors and Mermaid blocks
css=()     # code files whose short hex colors are searched too
nonnix=()  # code files where // starts a comment
declare -A relative=() # displayed path -> path below its directory argument

# Whether the directory part of $1 has a component named in the arguments
# after it.
has_component() {
	local path="$1" part
	shift
	[[ "$path" == */* ]] || return 1
	local -a parts
	IFS=/ read -r -a parts <<<"${path%/*}"
	for part in "${parts[@]}"; do
		[[ -n "$part" ]] || continue
		case " $* " in
		*" $part "*) return 0 ;;
		esac
	done
	return 1
}

# classify REL SHOWN: judges the file whose path below its argument is REL and
# which is displayed as SHOWN, and files it under the kinds above.
classify() {
	local rel="$1" shown="$2" name="${1##*/}" kind
	if has_component "$rel" .git .worktrees .superpowers node_modules vendor \
		vendored third_party third-party themes tests fixtures fixture testdata; then
		return 0
	fi
	name="${name,,}"
	case "$name" in
	*.svg | *.png | *.jpg | *.jpeg | *.gif | *.ico | *.webp | *.ttf | *.otf | *.woff | *.woff2 | *.lock)
		return 0
		;;
	*.md | *.markdown | *.mmd | *.mermaid) kind=docs ;;
	*.css | *.scss | *.tcss | *.rasi) kind=css ;;
	*.nix) kind=nix ;;
	*.ini | *.conf | *.toml | *.jsonc | *.kdl | *.colors) kind=code ;;
	*)
		case "/$rel" in
		*/modules/* | */hosts/*) kind=code ;;
		*) return 0 ;;
		esac
		;;
	esac
	relative["$shown"]="$rel"
	case "$kind" in
	docs) docs+=("$shown") ;;
	css)
		code+=("$shown")
		css+=("$shown")
		nonnix+=("$shown")
		;;
	nix) code+=("$shown") ;;
	code)
		code+=("$shown")
		nonnix+=("$shown")
		;;
	esac
}

walk() {
	local dir="$1" path rel
	while [[ "$dir" == */ && "$dir" != / ]]; do
		dir="${dir%/}"
	done
	# find's status comes last, as a record without a slash, which no path it
	# prints can be.
	while IFS= read -r -d '' path; do
		if [[ "$path" != */* ]]; then
			[[ "$path" == "find-status:0" ]] || die "could not walk $dir"
			continue
		fi
		rel="${path#"$dir"/}"
		if [[ "$dir" == . ]]; then
			classify "$rel" "$rel"
		else
			classify "$rel" "$path"
		fi
	done < <(
		find "$dir" \( -name .git -o -name .worktrees -o -name .superpowers -o -name node_modules \) -prune -o -type f -print0
		printf 'find-status:%s\0' "$?"
	)
}

for p in "$@"; do
	if [[ -L "$p" ]]; then
		continue
	elif [[ -d "$p" ]]; then
		if [[ "$p" == -* ]]; then walk "./$p"; else walk "$p"; fi
	elif [[ -f "$p" ]]; then
		# Judged by its place below the current directory, when it is below it.
		rel="$p"
		[[ "$p" != "$PWD"/* ]] || rel="${p#"$PWD"/}"
		classify "$rel" "$p"
	elif [[ -e "$p" ]]; then
		die "$p is neither a file nor a directory"
	else
		die "$p: no such file or directory"
	fi
done

all=("${docs[@]}" "${code[@]}")
((${#all[@]} > 0)) || exit 0

# --- Hits ---------------------------------------------------------------

declare -A seen=()
hits=()

hit() {
	local key="$1"$'\t'"$2"$'\t'"$3"
	[[ -z "${seen[$key]:-}" ]] || return 0
	seen[$key]=1
	hits+=("$key")
}

slice=500

# search CALLBACK ARRAY REGEX: calls CALLBACK with the path, the line number
# and the text of each match of REGEX in the files of ARRAY. The files go in
# slices, to stay below the limit on the length of a command line.
search() {
	local callback="$1" array="$2" regex="$3" i status path rest
	local -n files_ref="$array"
	((${#files_ref[@]} > 0)) || return 0
	for ((i = 0; i < ${#files_ref[@]}; i += slice)); do
		status=0
		while IFS= read -r -d '' path && IFS= read -r rest; do
			rest="${rest%$'\r'}"
			"$callback" "$path" "${rest%%:*}" "${rest#*:}" || true
		done < <(rg "${rg_flags[@]}" --regexp "$regex" -- "${files_ref[@]:i:slice}")
		wait $! || status=$?
		((status <= 1)) || die "the search failed (rg exit $status); see above"
	done
}

# Lines that are only a comment, found before the rules that skip them. A *
# that opens a CSS selector (* { ... }) is code.
declare -A comment=()
note_comment() {
	comment["$1"$'\t'"$2"]=1
}
comment_lines='^[ \t]*(?:#(?:[ \t]|$)|;|/\*|\*/|\*(?:[ \t]+[^ \t{,:.#\[>+~]|[ \t]*$))'
search note_comment code "$comment_lines"
search note_comment nonnix '^[ \t]*//'

is_comment() {
	[[ -n "${comment["$1"$'\t'"$2"]:-}" ]]
}

# Whether the number $1 is below the full value: below 1, or below 100%.
below_one() {
	local v="$1"
	[[ "$v" =~ ^[0-9]*\.?[0-9]+%?$ || "$v" =~ ^[0-9]+\.%?$ ]] || return 1
	if [[ "$v" == *% ]]; then
		awk -v v="${v%\%}" 'BEGIN { exit !(v + 0 < 100) }'
	else
		awk -v v="$v" 'BEGIN { exit !(v + 0 < 1) }'
	fi
}

# --- Mermaid init blocks --------------------------------------------------

# Per file, the line ranges of its init blocks as "first-last" words.
declare -A init_ranges=()

in_init_block() {
	local range
	for range in ${init_ranges["$1"]:-}; do
		(($2 >= ${range%-*} && $2 <= ${range#*-})) && return 0
	done
	return 1
}

# The init blocks of a file as "first-last:state" records, state being ok (the
# shared block), bad (another one) or open (never closed).
init_blocks() {
	REF="$2" awk '
		function finish(state,   text) {
			text = block
			gsub(/[ \t\r\n]+/, "", text)
			if (state == "closed") state = (text == ENVIRON["REF"]) ? "ok" : "bad"
			print start "-" NR ":" state
		}
		{
			line = $0
			if (!inside) {
				if (!match(line, /^[ \t]*%%\{init:/)) next
				inside = 1; start = NR; block = ""
				line = substr(line, RSTART + RLENGTH)
			}
			j = index(line, "}%%")
			if (j > 0) {
				block = block substr(line, 1, j - 1)
				finish("closed")
				inside = 0
			} else {
				block = block line "\n"
			}
		}
		END { if (inside) finish("open") }
	' "$1"
}

with_init=()
# The files that have a block, so awk runs only on those.
search_files_with_init() {
	local i status path
	for ((i = 0; i < ${#all[@]}; i += slice)); do
		status=0
		while IFS= read -r -d '' path; do
			with_init+=("$path")
		done < <(rg --no-config --no-ignore --hidden --text \
			--files-with-matches --null -- '^[ \t]*%%\{init:' "${all[@]:i:slice}")
		wait $! || status=$?
		((status <= 1)) || die "the search failed (rg exit $status); see above"
	done
}
search_files_with_init

if ((${#with_init[@]} > 0)); then
	[[ -r "$mermaid_theme" ]] || die "cannot read the shared Mermaid theme $mermaid_theme"
	command -v awk >/dev/null 2>&1 || die "awk not found."
	reference="$(tr -d '[:space:]' <"$mermaid_theme")"
	for path in "${with_init[@]}"; do
		ranges=""
		while IFS= read -r record; do
			[[ -n "$record" ]] || continue
			range="${record%%:*}"
			ranges+="$range "
			[[ "${record#*:}" == ok ]] || hit "$path" "${range%-*}" mermaid-init
		done < <(init_blocks "$path" "$reference")
		init_ranges["$path"]="$ranges"
	done
fi

# --- Hex colors -----------------------------------------------------------

# A color is # and 6 or 8 hex digits, not glued to a word, a path, a URL, a
# shell expansion ($#, ${#a}) or an entity (&#). The match includes the
# characters around it; hex_hit reads the digits.
hex_long='(?:^|[^[:alnum:]_#&/$.@{-])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6})(?:[^[:alnum:]_-]|$)'
# #rgb and #rgba are too common as anchors and issue numbers to search
# everywhere: in CSS files they are searched, elsewhere only in quotes and
# after a color property.
hex_short_css='(?:^|[^[:alnum:]_#&/$.@{-])#(?:[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?:[^[:alnum:]_-]|$)'
hex_short_quoted='["'"'"']#(?:[0-9a-fA-F]{4}|[0-9a-fA-F]{3})["'"'"']'
hex_short_property='(?i)(?:color|background|border|outline|fill|stroke|shadow)[a-z-]*\s*:[^;{}]*#(?:[0-9a-f]{4}|[0-9a-f]{3})(?:[^[:alnum:]_-]|$)'

# Whether the file may hold hex colors: the theme module and the style
# document.
hex_allowed() {
	local path
	path="/${relative["$1"]}"
	[[ "$path" == */modules/theme/* || "$path" == */docs/style.md ]]
}

is_doc() {
	[[ "${relative["$1"]}" == *.md || "${relative["$1"]}" == *.markdown ||
		"${relative["$1"]}" == *.mmd || "${relative["$1"]}" == *.mermaid ]]
}

hex_hit() {
	local path="$1" line="$2" text="$3" digits=""
	in_init_block "$path" "$line" && return 0
	if [[ "$text" =~ \#([0-9a-fA-F]+) ]]; then
		digits="${BASH_REMATCH[1]}"
	fi
	# #123456 in a document or a comment is an issue number, not a color. The
	# two colors of Mocha that are all digits, Mantle and Surface0, are not.
	if [[ "$digits" =~ ^[0-9]+$ && "$digits" != 181825 && "$digits" != 313244 ]]; then
		if is_doc "$path" || is_comment "$path" "$line"; then return 0; fi
	fi
	# Alpha: the last two digits of #rrggbbaa, the last of #rgba. A document
	# only shows a color; what is translucent is code.
	if ! is_doc "$path"; then
		case "${#digits}" in
		8) [[ "${digits:6:2}" == [fF][fF] ]] || hit "$path" "$line" opacity ;;
		4) [[ "${digits:3:1}" == [fF] ]] || hit "$path" "$line" opacity ;;
		esac
	fi
	hex_allowed "$path" || hit "$path" "$line" hex-color
}

search hex_hit all "$hex_long"
search hex_hit css "$hex_short_css"
search hex_hit code "$hex_short_quoted"
search hex_hit code "$hex_short_property"

# --- Radius, opacity and motion ---------------------------------------------

# Whether a radius value is not 0: it has a digit from 1 to 9 up to the end of
# its declaration, or is computed.
radius_value() {
	local whole="${1%%[;\}]*}"
	whole="${whole%%!*}"
	whole="${whole%%[[:space:]]#*}"
	[[ "$whole" =~ [1-9] || "$whole" == *var\(* || "$whole" == *calc\(* || "$whole" == *env\(* ]]
}

radius_hit() {
	local path="$1" line="$2" text="$3" rest match value
	is_comment "$path" "$line" && return 0
	text="${text%%/\**}"
	text="${text,,}"
	local property='(^|[^[:alnum:]_-])(-[a-z]+-)?(outline|border)-([a-z]+-[a-z]+-)?radius["'"'"']?[[:space:]]*:[[:space:]]*([^;}]*)'
	local key='(^|[[:space:]{.,"'"'"'])(radius|corner[_-]?radius|border[_-]radius)["'"'"']?[[:space:]]*[=:][[:space:]]*([^;]*)'
	rest="$text"
	while [[ "$rest" =~ $property ]]; do
		match="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[5]}"
		if radius_value "$value"; then hit "$path" "$line" radius; fi
		rest="${rest#*"$match"}"
	done
	rest="$text"
	while [[ "$rest" =~ $key ]]; do
		match="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[3]}"
		if radius_value "$value"; then hit "$path" "$line" radius; fi
		rest="${rest#*"$match"}"
	done
}

opacity_hit() {
	local path="$1" line="$2" text="$3" rest match value
	is_comment "$path" "$line" && return 0
	text="${text%%/\**}"
	text="${text,,}"
	# opacity and *_alpha keys.
	local key='(^|[^[:alnum:]])(([a-z]+[_-])*)(opacity|alpha)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?([^;,}"'"'"'[:space:]]*)'
	rest="$text"
	while [[ "$rest" =~ $key ]]; do
		match="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[5]}"
		if below_one "$value"; then hit "$path" "$line" opacity; fi
		rest="${rest#*"$match"}"
	done
	# sway: opacity 0.9, opacity set 0.9
	local sway='(^|[][:space:]])opacity[[:space:]]+(set[[:space:]]+)?([0-9]*\.?[0-9]+)([[:space:]]|$)'
	if [[ "$text" =~ $sway ]]; then
		value="${BASH_REMATCH[3]}"
		if below_one "$value"; then hit "$path" "$line" opacity; fi
	fi
	# alpha(@color, 0.5)
	if [[ "$text" =~ (^|[^[:alnum:]_-])alpha[[:space:]]*\( ]]; then
		hit "$path" "$line" opacity
	fi
	# rgba(0, 0, 0, 0.5), hsla(...), rgb(0 0 0 / 50%)
	local comma='(rgba|hsla)\([^)]*,[[:space:]]*([0-9.]+%?)[[:space:]]*\)'
	local slash='(rgb|hsl)\([^)]*/[[:space:]]*([0-9.]+%?)[[:space:]]*\)'
	rest="$text"
	while [[ "$rest" =~ $comma ]]; do
		match="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[2]}"
		if below_one "$value"; then hit "$path" "$line" opacity; fi
		rest="${rest#*"$match"}"
	done
	rest="$text"
	while [[ "$rest" =~ $slash ]]; do
		match="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[2]}"
		if below_one "$value"; then hit "$path" "$line" opacity; fi
		rest="${rest#*"$match"}"
	done
}

# A bare RRGGBBAA value of a color key, as fuzzel and swaylock write them.
bare_color_hit() {
	local path="$1" line="$2" text="$3" key value
	is_comment "$path" "$line" && return 0
	text="${text,,}"
	local re='(^|[^[:alnum:]_-])([a-z][a-z0-9_-]*)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?([0-9a-f]{8})["'"'"']?[[:space:]]*[;,]?[[:space:]]*$'
	[[ "$text" =~ $re ]] || return 0
	key="${BASH_REMATCH[2]}"
	value="${BASH_REMATCH[3]}"
	case "$key" in
	*color* | *colour* | *background* | *foreground* | *border* | *selection* | *match* | \
		*placeholder* | *prompt* | *counter* | *separator* | *frame* | *text* | *input*) ;;
	*) return 0 ;;
	esac
	# The inside of the lock ring is the one place a color may be see-through.
	case "$key" in
	inside-color | inside-*-color) return 0 ;;
	esac
	[[ "${value:6:2}" == ff ]] || hit "$path" "$line" opacity
}

# A transition or animation key is a hit unless its value turns motion off:
# none, false, off, no or a zero duration. @keyframes is always a hit.
motion_hit() {
	local text="${3,,}" value
	is_comment "$1" "$2" && return 0
	if [[ "$text" =~ [=:][[:space:]]*(.*)$ && "$text" != *@*keyframes* ]]; then
		value="${BASH_REMATCH[1]}"
		value="${value//[\"\']/}"
		value="${value%%!*}"
		value="${value%"${value##*[![:space:]]}"}"
		case "$value" in
		none | false | off | no | 0 | 0s | 0ms | 0.0s | 0.0ms) return 0 ;;
		esac
	fi
	hit "$1" "$2" motion
}

search radius_hit code '(?i).{0,160}radius["'"'"']?\s*[=:].{0,160}'
search opacity_hit code '(?i).{0,160}(?:opacity|alpha|rgba|hsla|rgb\(|hsl\().{0,160}'
search bare_color_hit code '(?i)(?:^|[^[:alnum:]_-])[a-z][a-z0-9_-]*["'"'"']?\s*[=:]\s*["'"'"']?[0-9a-f]{8}["'"'"']?\s*[;,]?\s*$'
search motion_hit code '(?i)(?:^|[\s{;"'"'"'(,])(?:-(?:gtk|moz|webkit|ms|o)-)?(?:transition|animations?)(?:-[a-z-]+)?["'"'"']?\s*[=:][^;{}]{0,60}|@(?:-[a-z]+-)?keyframes\b'

# --- Report -------------------------------------------------------------------

((${#hits[@]} > 0)) || exit 0
while IFS=$'\t' read -r path line rule; do
	printf '%s:%s:%s\n' "$path" "$line" "$rule"
done < <(printf '%s\n' "${hits[@]}" | sort -t $'\t' -k1,1 -k2,2n -k3,3)
if ((${#hits[@]} == 1)); then
	printf '%s: 1 hit: docs/style.md names the rule on the line above\n' "$prog" >&2
else
	printf '%s: %d hits: docs/style.md names the rules above\n' "$prog" "${#hits[@]}" >&2
fi
exit 1
