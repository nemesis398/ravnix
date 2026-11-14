#!/usr/bin/env bash
# The config parity diff of the style acceptance (plan Task 3.7, Step 3a): it
# compares generated configs with the stow sources they were ported from and
# prints what still differs after the differences a config file allows.
#
# Usage: style-parity.sh --stow DIR --built NAME=DIR [--built NAME=DIR]...
#                        --config FILE [--show-allowed]
#                        [--path-dir DIR]...
#
#   --stow DIR      the stow tree: DIR/PACKAGE/PATH, as in a dotfiles repository
#   --built NAME=DIR  a tree of generated files, called NAME in the config
#                   (for example home-manager's home-files and the system's sw)
#   --config FILE   what to compare and what to allow (below)
#   --show-allowed  also list every difference that was allowed, with its reason
#
# The config is a text file of tab separated lines; blank lines and lines that
# start with # are skipped.
#
#   compare FORMAT STOWPATH NAME:BUILTPATH[+NAME:BUILTPATH]...
#       Compare DIR/STOWPATH with the file BUILTPATH below the tree NAME. With
#       several built files (a program that reads a theme file and a config
#       file) their normalised lines are joined and sorted; a file name with
#       a "+" in it cannot be named.
#   allow GLOB TEXT [REASON]
#       Allow one difference in every compared file whose STOWPATH matches the
#       glob. TEXT is one line of the diff as printed: "-line" for a line only
#       the stow source has, "+line" for one only the built file has,
#       "!missing" for a built file that does not exist, or
#       "!not-on-path NAME" (see binsub). Every occurrence of the line in that
#       file is allowed, not one. For "!builtonly" (see builtonly) the glob
#       matches NAME:PATH of the built file instead.
#   sub GLOB FROM TO
#       Replace FROM by TO in a copy of the stow source before it is
#       normalised and sorted, so that a rewritten line finds its place. Use
#       it for what is the same thing in another spelling (the stow source
#       says what Fedora had, the built file what the options say).
#   binsub GLOB FROM TO
#       A sub for FROM a directory that held commands (Fedora's ~/.local/bin/)
#       and TO the empty string: the word after each FROM is a command name,
#       and every such name must exist in one of the --path-dir directories
#       (the built system's PATH); names in comment lines (shebangs
#       included) are not checked. A name that does not is the diff line
#       "!not-on-path NAME". This closes the hole a bare sub leaves open: a
#       command that nothing installs would compare equal to itself.
#   builtonly NAME:DIR
#       List every file below DIR of the tree NAME that no compare line names
#       (a file the port generates that Fedora never had) as "BUILT ONLY
#       NAME:PATH", and count it as a remaining difference unless an allow
#       entry with the TEXT "!builtonly" matches it.
#
# Another option: --path-dir DIR (repeatable) names a directory of the built
# system's PATH, for binsub.
#
# The allow list is exact. An allow, sub or binsub entry that never matched
# anything is reported as STALE and fails the run, so a row cannot outlive its
# difference. The config holds the personal values (a stow tree is the
# author's, and so are the templated values), which is why it lives in the
# private flake and not in this repository.
#
# Both sides are normalised first, so only the content is compared, never
# layout, comment text, quoting, key order or the case of a hex color:
#
#   kv        key=value files, with [sections] (ini, toml, ghostty, fuzzel,
#             dunst, swaylock, btop); sorted
#   yaml      nested keys by indentation (lazygit, eza); sorted
#   css       one line per declaration with its selector path (GTK CSS), in
#             order, because the cascade is; the @define-color lines first and
#             sorted, because a definition's place does not matter
#   jsonc     JSON with comments and trailing commas: one line per leaf with
#             its path; sorted by path (arrays keep their index)
#   lines     the code lines, in order (Lua, anything else)
#   sway      the same, with the "set" lines first and sorted (Sway's config)
#   script    a shell script: no shebang, comments, blank lines, leading white
#             space or the "export PATH=/nix/store/..." line that
#             writeShellApplication prepends
#   pyscript  the same for a Python script, with its indentation
#
# Output: one line per compared file ("ok", "DIFF" with its differing lines
# indented below, or "MISSING"), the STALE entries, and a summary. Exit 0 when
# nothing remains, 1 when a difference or a stale entry does, 2 when the
# arguments, the config, a stow source or a file's syntax are wrong.
#
# Why Bash and not an Odin tool (AGENTS.md rule 4): this is not a tool of the
# system but an acceptance harness that runs a few times, once per surface
# port. It is the format normalisers (awk), `diff` and a table of allowed
# lines, the same shape as check-style.sh, and it carries no state or user
# data. Its tests are scripts/tests/style-parity.test.sh. Known limits:
# normalisation is line and token based, not a parser: a CSS string holding a
# brace or a semicolon, a TOML key in quotes, a YAML flow mapping or a JSON
# comment marker inside a TOML string are not understood. In kv the sections
# "Desktop Entry" and "Desktop Action ..." (.desktop files) drop the localised
# keys (Name[de]=) and a list's trailing ";". In kv the boolean
# words true, yes and on equal 1 and false, no and off equal 0, for any key. An
# array of tables ([[items]]) is flattened into one bag of key=value lines, so
# a label paired with the wrong command in the other table compares clean.

set -uo pipefail

die() {
	echo "style-parity: $*" >&2
	exit 2
}

usage() {
	cat <<'EOF'
usage: style-parity.sh --stow DIR --built NAME=DIR [--built NAME=DIR]... --config FILE [--path-dir DIR]... [--show-allowed]
EOF
}

stow=""
config=""
show_allowed=0
declare -A roots=()
have_built=0
path_dirs=()

while (($# > 0)); do
	case "$1" in
	--stow)
		(($# >= 2)) || die "--stow needs a directory"
		stow="$2"
		shift 2
		;;
	--config)
		(($# >= 2)) || die "--config needs a file"
		config="$2"
		shift 2
		;;
	--built)
		(($# >= 2)) || die "--built needs NAME=DIR"
		[[ "$2" == ?*=?* ]] || die "--built needs NAME=DIR, got '$2'"
		roots["${2%%=*}"]="${2#*=}"
		have_built=1
		shift 2
		;;
	--path-dir)
		(($# >= 2)) || die "--path-dir needs a directory"
		path_dirs+=("$2")
		shift 2
		;;
	--show-allowed)
		show_allowed=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown argument '$1'"
		;;
	esac
done

if [[ -z "$stow" || -z "$config" || "$have_built" == 0 ]]; then
	usage >&2
	die "--stow, --built and --config are required"
fi
[[ -d "$stow" ]] || die "the stow directory '$stow' does not exist"
[[ -f "$config" ]] || die "the config '$config' is not a file"
for name in "${!roots[@]}"; do
	[[ -d "${roots[$name]}" ]] || die "the built tree '$name' ('${roots[$name]}') is not a directory"
done
for tool in awk cp diff find jq mktemp mv rm sort; do
	command -v "$tool" >/dev/null 2>&1 || die "needs '$tool' on the PATH"
done

work="$(mktemp -d)" || die "cannot make a scratch directory"
trap 'rm -rf -- "$work"' EXIT

# ── normalisers ─────────────────────────────────────────────────────────────

# Shared awk functions: trim, and lower-casing of #rrggbb and #rrggbbaa.
awk_lib='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function lowhex(s,   out) {
	out = ""
	while (match(s, /#[0-9A-Fa-f]+/)) {
		if (RLENGTH == 7 || RLENGTH == 9)
			out = out substr(s, 1, RSTART - 1) tolower(substr(s, RSTART, RLENGTH))
		else
			out = out substr(s, 1, RSTART + RLENGTH - 1)
		s = substr(s, RSTART + RLENGTH)
	}
	return out s
}
function unquote(v) {
	if (length(v) >= 2 && ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") || (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")))
		return substr(v, 2, length(v) - 2)
	return v
}
function clean(s) { sub(/\r$/, "", s); gsub(/\t/, " ", s); return s }
'

norm_kv() {
	awk "$awk_lib"'
	function pending(v,   t, n) {
		t = v
		n = gsub(/"""/, "", t)
		return (v ~ /\\$/) || (n % 2 == 1)
	}
	function barehex(v,   n, parts, i) {
		n = split(v, parts, ",")
		for (i = 1; i <= n; i++)
			if (parts[i] !~ /^[0-9A-Fa-f]+$/ || (length(parts[i]) != 6 && length(parts[i]) != 8)) return 0
		return 1
	}
	function flush(   v) {
		if (!have) return
		v = val
		gsub(/"""/, "", v)
		v = unquote(trim(v))
		if (barehex(v)) v = tolower(v)
		if (v == "false" || v == "no" || v == "off") v = "0"
		else if (v == "true" || v == "yes" || v == "on") v = "1"
		if (sect ~ /^Desktop /) {
			if (key ~ /\[[^]]*\]$/) { have = 0; return }
			sub(/;$/, "", v)
		}
		print lowhex((sect == "" ? "" : sect ".") key "=" v)
		have = 0
	}
	{
		line = trim(clean($0))
		if (line == "" || line ~ /^[#;]/) next
		sub(/ +#( .*)?$/, "", line)
		line = trim(line)
		if (line == "") next
		if (line ~ /^\[.*\]$/) { flush(); sect = substr(line, 2, length(line) - 2); next }
		if (have && pending(val)) {
			if (val ~ /\\$/) { sub(/\\$/, "", val); val = val line }
			else val = val " " line
			next
		}
		eq = index(line, "=")
		k = (eq > 0) ? trim(substr(line, 1, eq - 1)) : ""
		flush()
		if (eq > 0 && k ~ /^[A-Za-z0-9_.-]+(\[[^]]*\])?$/) {
			key = k; val = trim(substr(line, eq + 1))
		} else {
			key = line; val = ""
		}
		have = 1
	}
	END { flush() }' "$1" | LC_ALL=C sort
}

norm_yaml() {
	awk "$awk_lib"'
	{
		raw = clean($0)
		if (raw ~ /^ *(#.*)?$/ || raw ~ /^(%|---|\.\.\.)/) next
		match(raw, /^ */); ind0 = RLENGTH
		line = substr(raw, ind0 + 1)
		sub(/ +#( .*)?$/, "", line)
		ind = ind0; dash = 0
		if (line ~ /^- /) { dash = 1; line = trim(substr(line, 3)); ind = ind0 + 2 }
		else if (line == "-") next
		if (dash) { while (depth > 0 && ind0 < sind[depth]) depth-- }
		else { while (depth > 0 && ind <= sind[depth]) depth-- }
		path = ""
		for (i = 1; i <= depth; i++) path = path (i > 1 ? "." : "") skey[i]
		if (dash) path = path (path == "" ? "" : ".") "-"
		if (match(line, /^[^: ][^:]*:( |$)/)) {
			k = trim(substr(line, 1, index(line, ":") - 1))
			v = trim(substr(line, index(line, ":") + 1))
			if (v == "") { depth++; sind[depth] = ind; skey[depth] = k }
			else print lowhex(path (path == "" ? "" : ".") k "=" unquote(v))
		} else {
			print lowhex(path "=" unquote(line))
		}
	}' "$1" | LC_ALL=C sort
}

norm_css() {
	awk "$awk_lib"'
	function norm(s) { gsub(/[ \t\r\n]+/, " ", s); return trim(s) }
	function emit(b,   c, p, v) {
		b = norm(b)
		if (b == "") return
		if (b !~ /^@/ && (c = index(b, ":")) > 0) {
			p = trim(substr(b, 1, c - 1)); v = trim(substr(b, c + 1))
			b = p ": " v
		}
		if (d > 0) {
			path = stack[1]
			for (i = 2; i <= d; i++) path = path " > " stack[i]
			b = path " :: " b
		}
		b = lowhex(b)
		if (d == 0 && b ~ /^@define-color /) dc[++ndc] = b
		else other[++nother] = b
	}
	{ t = t $0 "\n" }
	END {
		while ((s = index(t, "/*")) > 0) {
			e = index(substr(t, s + 2), "*/")
			if (e == 0) { t = substr(t, 1, s - 1); break }
			t = substr(t, 1, s - 1) " " substr(t, s + e + 3)
		}
		n = length(t); buf = ""; d = 0
		for (j = 1; j <= n; j++) {
			c = substr(t, j, 1)
			if (c == "{") { s = norm(buf); gsub(/ *, */, ", ", s); stack[++d] = s; buf = "" }
			else if (c == ";") { emit(buf); buf = "" }
			else if (c == "}") { emit(buf); buf = ""; if (d > 0) d-- }
			else buf = buf c
		}
		emit(buf)
		for (i = 2; i <= ndc; i++) {
			v = dc[i]
			for (j = i - 1; j >= 1 && dc[j] > v; j--) dc[j + 1] = dc[j]
			dc[j + 1] = v
		}
		for (i = 1; i <= ndc; i++) print dc[i]
		for (i = 1; i <= nother; i++) print other[i]
	}' "$1"
}

norm_jsonc() {
	awk '
	{ t = t $0 "\n" }
	END {
		n = length(t); out = ""; instr = 0
		for (i = 1; i <= n; i++) {
			c = substr(t, i, 1)
			if (instr) {
				out = out c
				if (c == "\\") { out = out substr(t, i + 1, 1); i++ }
				else if (c == "\"") instr = 0
			} else if (c == "\"") { instr = 1; out = out c }
			else if (c == "/" && substr(t, i + 1, 1) == "/") {
				while (i < n && substr(t, i + 1, 1) != "\n") i++
			} else if (c == "/" && substr(t, i + 1, 1) == "*") {
				i += 2
				while (i < n && !(substr(t, i, 1) == "*" && substr(t, i + 1, 1) == "/")) i++
				i++
				out = out " "
			} else out = out c
		}
		t = out; n = length(t); out = ""; instr = 0
		for (i = 1; i <= n; i++) {
			c = substr(t, i, 1)
			if (instr) {
				out = out c
				if (c == "\\") { out = out substr(t, i + 1, 1); i++ }
				else if (c == "\"") instr = 0
			} else if (c == "\"") { instr = 1; out = out c }
			else if (c == ",") {
				j = i + 1
				while (j <= n && substr(t, j, 1) ~ /[ \t\r\n]/) j++
				if (substr(t, j, 1) != "}" && substr(t, j, 1) != "]") out = out c
			} else out = out c
		}
		printf "%s", out
	}' "$1" |
		jq -r '. as $d | paths as $p | ($d | getpath($p)) as $v
			| select((($v | type) != "array" and ($v | type) != "object") or ($v | length) == 0)
			| ($p | map(tostring) | join(".")) + " = " + ($v | tojson)' |
		awk "$awk_lib"'{ print lowhex($0) }' | LC_ALL=C sort -V
}

norm_lines() {
	awk "$awk_lib"'
	{
		line = trim(clean($0))
		if (line == "" || line ~ /^(#|--|\/\/)/) next
		gsub(/ +/, " ", line)
		print lowhex(line)
	}' "$1"
}

# Sway's config: the code lines in order, except that the "set" lines come
# first and sorted, because a variable's place does not matter and the palette
# is the one block a port reorders.
norm_sway() {
	norm_lines "$1" | awk '
		/^set / { sets[++n] = $0; next }
		{ rest[++m] = $0 }
		END {
			for (i = 2; i <= n; i++) {
				v = sets[i]
				for (j = i - 1; j >= 1 && sets[j] > v; j--) sets[j + 1] = sets[j]
				sets[j + 1] = v
			}
			for (i = 1; i <= n; i++) print sets[i]
			for (i = 1; i <= m; i++) print rest[i]
		}'
}

# $1 is "keep" to keep the indentation (Python) or "strip".
norm_script() {
	awk -v indent="$2" "$awk_lib"'
	{
		raw = clean($0)
		if (NR == 1 && raw ~ /^#!/) next
		line = trim(raw)
		if (line == "" || line ~ /^#/) next
		if (line ~ /^export PATH="\/nix\/store\// && NR <= 8) next
		if (indent == "keep") { sub(/[ ]+$/, "", raw); print lowhex(raw) }
		else print lowhex(line)
	}' "$1"
}

# normalize FORMAT FILE: the normalised lines on stdout; non-zero when the
# file cannot be read as that format.
normalize() {
	case "$1" in
	kv) norm_kv "$2" ;;
	yaml) norm_yaml "$2" ;;
	css) norm_css "$2" ;;
	jsonc) norm_jsonc "$2" ;;
	lines) norm_lines "$2" ;;
	sway) norm_sway "$2" ;;
	script) norm_script "$2" strip ;;
	pyscript) norm_script "$2" keep ;;
	*) return 2 ;;
	esac
}

valid_format() {
	case "$1" in
	kv | yaml | css | jsonc | lines | sway | script | pyscript) return 0 ;;
	*) return 1 ;;
	esac
}

# ── the config ──────────────────────────────────────────────────────────────

fields=()
# Splits $1 at "+" into plus.
plus=()
split_plus() {
	local s="$1"
	plus=()
	while :; do
		plus+=("${s%%+*}")
		[[ "$s" == *+* ]] || break
		s="${s#*+}"
	done
}

# Splits $1 at tabs into fields, keeping empty ones.
split_tabs() {
	local s="$1"
	fields=()
	while :; do
		fields+=("${s%%$'\t'*}")
		[[ "$s" == *$'\t'* ]] || break
		s="${s#*$'\t'}"
	done
}

c_fmt=() c_stow=() c_built=()
a_glob=() a_text=() a_reason=()
s_glob=() s_from=() s_to=() s_bin=()
b_spec=()

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
	lineno=$((lineno + 1))
	line="${line%$'\r'}"
	[[ -z "$line" || "$line" == "#"* ]] && continue
	split_tabs "$line"
	case "${fields[0]}" in
	compare)
		((${#fields[@]} == 4)) || die "$config line $lineno: compare needs FORMAT, STOWPATH and NAME:BUILTPATH"
		valid_format "${fields[1]}" || die "$config line $lineno: unknown format '${fields[1]}'"
		split_plus "${fields[3]}"
		for part in "${plus[@]}"; do
			[[ "$part" == ?*:?* ]] || die "$config line $lineno: the built side must be NAME:BUILTPATH[+NAME:BUILTPATH]..."
			[[ -v roots["${part%%:*}"] ]] || die "$config line $lineno: no --built tree called '${part%%:*}'"
		done
		c_fmt+=("${fields[1]}")
		c_stow+=("${fields[2]}")
		c_built+=("${fields[3]}")
		;;
	builtonly)
		((${#fields[@]} == 2)) || die "$config line $lineno: builtonly needs NAME:DIR"
		[[ "${fields[1]}" == ?*:?* && -v roots["${fields[1]%%:*}"] ]] ||
			die "$config line $lineno: builtonly needs NAME:DIR with a --built tree called NAME"
		b_spec+=("${fields[1]}")
		;;
	allow)
		((${#fields[@]} >= 3 && ${#fields[@]} <= 4)) || die "$config line $lineno: allow needs GLOB, TEXT and an optional REASON"
		[[ "${fields[2]}" == "-"* || "${fields[2]}" == "+"* || "${fields[2]}" == "!missing" ||
			"${fields[2]}" == "!builtonly" || "${fields[2]}" == "!not-on-path "?* ]] ||
			die "$config line $lineno: allow TEXT starts with - or +, or is !missing, !builtonly or !not-on-path NAME"
		a_glob+=("${fields[1]}")
		a_text+=("${fields[2]}")
		a_reason+=("${fields[3]:-}")
		;;
	sub | binsub)
		((${#fields[@]} == 4)) || die "$config line $lineno: ${fields[0]} needs GLOB, FROM and TO"
		[[ -n "${fields[2]}" ]] || die "$config line $lineno: ${fields[0]} FROM is empty"
		s_glob+=("${fields[1]}")
		s_from+=("${fields[2]}")
		s_to+=("${fields[3]}")
		if [[ "${fields[0]}" == binsub ]]; then
			s_bin+=(1)
			((${#path_dirs[@]} > 0)) || die "$config line $lineno: binsub needs at least one --path-dir"
		else
			s_bin+=(0)
		fi
		;;
	*) die "$config line $lineno: unknown directive '${fields[0]}'" ;;
	esac
done <"$config"

((${#c_fmt[@]} > 0)) || die "$config has no compare line"

# Every stow source must exist before anything is printed.
bad=0
for i in "${!c_fmt[@]}"; do
	if [[ ! -f "$stow/${c_stow[$i]}" ]]; then
		echo "style-parity: the stow source '${c_stow[$i]}' is not a file in $stow" >&2
		bad=1
	fi
done
((bad == 0)) || exit 2

# ── the run ─────────────────────────────────────────────────────────────────

declare -A a_used=() s_used=() compared=()
n_files=0 n_ok=0 n_diff=0 n_remaining=0 n_allowed=0
: >"$work/used"

for i in "${!c_fmt[@]}"; do
	fmt="${c_fmt[$i]}"
	spath="${c_stow[$i]}"
	where="${c_built[$i]}"
	n_files=$((n_files + 1))
	split_plus "$where"
	parts=("${plus[@]}")
	for part in "${parts[@]}"; do compared["$part"]=1; done

	# Allow entries that apply to this file, as "index<TAB>text" lines.
	: >"$work/sel"
	missing_allowed=""
	for j in "${!a_glob[@]}"; do
		# shellcheck disable=SC2053 # the glob is the point
		[[ "$spath" == ${a_glob[$j]} ]] || continue
		[[ "${a_text[$j]}" == "!builtonly" ]] && continue
		a_used[$j]="${a_used[$j]:-0}"
		if [[ "${a_text[$j]}" == "!missing" ]]; then
			missing_allowed="$j"
		else
			printf '%s\t%s\n' "$j" "${a_text[$j]}" >>"$work/sel"
		fi
	done

	absent=0
	for part in "${parts[@]}"; do
		[[ -f "${roots[${part%%:*}]}/${part#*:}" ]] || absent=1
	done
	if ((absent == 1)); then
		if [[ -n "$missing_allowed" ]]; then
			a_used[$missing_allowed]=$((a_used[$missing_allowed] + 1))
			n_allowed=$((n_allowed + 1))
			echo "allowed missing $spath  ($where) ${a_reason[$missing_allowed]:+- ${a_reason[$missing_allowed]}}"
		else
			n_diff=$((n_diff + 1))
			n_remaining=$((n_remaining + 1))
			echo "MISSING $spath  ($where)"
		fi
		continue
	fi

	# The subs rewrite a copy of the raw stow file, before the normaliser
	# sorts it: a rewritten line must find its place in the sort order.
	cp -- "$stow/$spath" "$work/raw"
	: >"$work/names"
	for k in "${!s_glob[@]}"; do
		# shellcheck disable=SC2053 # the glob is the point
		[[ "$spath" == ${s_glob[$k]} ]] || continue
		s_used[$k]="${s_used[$k]:-0}"
		PF="${s_from[$k]}" PT="${s_to[$k]}" awk -v cf="$work/subcount" -v nf="$work/names" -v bin="${s_bin[$k]}" '
			BEGIN { f = ENVIRON["PF"]; t = ENVIRON["PT"]; n = 0 }
			{
				out = ""; s = $0
				skip = ($0 ~ /^[ \t]*#/)
				while ((p = index(s, f)) > 0) {
					out = out substr(s, 1, p - 1) t; s = substr(s, p + length(f)); n++
					if (bin == 1 && !skip && match(s, /^[A-Za-z0-9._+@-]+/)) print substr(s, 1, RLENGTH) >> nf
				}
				print out s
			}
			END { print n > cf }' "$work/raw" >"$work/raw2" || die "cannot apply the sub entry for '${s_glob[$k]}'"
		mv -- "$work/raw2" "$work/raw"
		s_used[$k]=$((s_used[$k] + $(<"$work/subcount")))
	done

	normalize "$fmt" "$work/raw" >"$work/a" 2>"$work/err" ||
		die "cannot read the stow source '$spath' as $fmt"
	: >"$work/b"
	for part in "${parts[@]}"; do
		normalize "$fmt" "${roots[${part%%:*}]}/${part#*:}" >>"$work/b" 2>"$work/err" ||
			die "cannot read the built file '$part' as $fmt"
	done
	((${#parts[@]} > 1)) && LC_ALL=C sort -o "$work/b" "$work/b"

	diff --unchanged-line-format= --old-line-format='-%L' --new-line-format='+%L' "$work/a" "$work/b" >"$work/d"
	rc=$?
	((rc <= 1)) || die "diff failed on '$spath'"

	# Every command name a binsub made bare must be on the PATH of the built
	# system; the names that are not become lines of the diff.
	if [[ -s "$work/names" ]]; then
		declare -A seen_name=()
		while IFS= read -r name; do
			[[ -n "${seen_name[$name]:-}" ]] && continue
			seen_name[$name]=1
			found=0
			for dir in "${path_dirs[@]}"; do
				[[ -e "$dir/$name" ]] && found=1
			done
			((found == 1)) || printf '!not-on-path %s\n' "$name" >>"$work/d"
		done <"$work/names"
		unset seen_name
	fi

	: >"$work/rem"
	: >"$work/alw"
	awk -v rem="$work/rem" -v alw="$work/alw" -v used="$work/used" -v sel="$work/sel" '
		FILENAME == sel {
			t = index($0, "\t")
			txt = substr($0, t + 1)
			ids[txt] = ids[txt] (ids[txt] == "" ? "" : " ") substr($0, 1, t - 1)
			next
		}
		{
			if ($0 in ids) {
				print ids[$0] "\t" $0 > alw
				n = split(ids[$0], parts, " ")
				for (q = 1; q <= n; q++) print parts[q] >> used
			} else print $0 > rem
		}' "$work/sel" "$work/d"
	[[ -e "$work/rem" ]] || : >"$work/rem"

	mapfile -t rem_lines <"$work/rem"
	mapfile -t alw_lines <"$work/alw"
	nr=${#rem_lines[@]}
	na=${#alw_lines[@]}
	n_allowed=$((n_allowed + na))
	n_remaining=$((n_remaining + nr))
	suffix=""
	((na > 0)) && suffix=" ($na allowed)"
	if ((nr == 0)); then
		n_ok=$((n_ok + 1))
		echo "ok    $spath$suffix"
	else
		n_diff=$((n_diff + 1))
		echo "DIFF  $spath ($nr remaining, $na allowed)"
		printf '  %s\n' "${rem_lines[@]}"
	fi
	if ((show_allowed == 1 && na > 0)); then
		for al in "${alw_lines[@]}"; do
			id="${al%%$'\t'*}"
			id="${id%% *}"
			echo "  allowed ${al#*$'\t'}${a_reason[$id]:+  (${a_reason[$id]})}"
		done
	fi
done

# Files that exist only on the built side: nothing above compares them.
n_builtonly=0
for spec in "${b_spec[@]}"; do
	base="${roots[${spec%%:*}]}/${spec#*:}"
	[[ -d "$base" ]] || die "the builtonly directory '$spec' is not a directory"
	while IFS= read -r -d '' f; do
		key="${spec%%:*}:${f#"${roots[${spec%%:*}]}"/}"
		[[ -n "${compared[$key]:-}" ]] && continue
		allowed_by=""
		for j in "${!a_glob[@]}"; do
			[[ "${a_text[$j]}" == "!builtonly" ]] || continue
			# shellcheck disable=SC2053 # the glob is the point
			[[ "$key" == ${a_glob[$j]} ]] && { allowed_by="$j"; break; }
		done
		if [[ -n "$allowed_by" ]]; then
			a_used[$allowed_by]=$((${a_used[$allowed_by]:-0} + 1))
			n_allowed=$((n_allowed + 1))
			((show_allowed == 1)) && echo "allowed built only $key  (${a_reason[$allowed_by]})"
		else
			n_builtonly=$((n_builtonly + 1))
			n_remaining=$((n_remaining + 1))
			echo "BUILT ONLY $key"
		fi
	done < <(find -L "$base" -type f -print0 | LC_ALL=C sort -z)
done

# Which allow entries were used.
while IFS= read -r id; do
	[[ -n "$id" ]] && a_used[$id]=$((${a_used[$id]:-0} + 1))
done <"$work/used"

stale=0
for j in "${!a_glob[@]}"; do
	if (("${a_used[$j]:-0}" == 0)); then
		stale=$((stale + 1))
		echo "STALE allow ${a_glob[$j]}  ${a_text[$j]}"
	fi
done
for k in "${!s_glob[@]}"; do
	if (("${s_used[$k]:-0}" == 0)); then
		stale=$((stale + 1))
		echo "STALE sub ${s_glob[$k]}  ${s_from[$k]}"
	fi
done

echo "style-parity: $n_files compared, $n_ok identical, $n_diff with remaining differences, $n_builtonly built only, $n_remaining remaining lines in all, $n_allowed allowed, $stale stale"
if ((n_remaining == 0 && stale == 0)); then
	echo "style-parity: no remaining differences"
	exit 0
fi
exit 1
