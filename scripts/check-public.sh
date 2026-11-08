#!/usr/bin/env bash
# The public-boundary check: no value from the deny list may appear in this
# repository. It searches the given paths for every entry of the list and
# prints one line per hit:
#
#   file:line:list:N  an entry appears in the file's contents on that line
#   file:name:list:N  an entry appears in the file's path below a directory
#                     argument
#   file:link:list:N  the file is a symbolic link whose target holds an entry
#
# where list is the deny list's file name and N the line of the entry in it.
# A hit never prints the entry itself: the output goes into logs, transcripts
# and reports, and the entries are the values the list keeps out of them. For
# the same reason they are never put on a command line, where any local user
# could read them: they reach rg as files, in a directory of the owner's alone
# that is removed when the check ends, and the summary line names the list by
# its file name, since its path can hold an entry. Two things a hit does
# show: the path of a file that holds an entry in its name (it is the file's
# own, and the hit is about it), so a value that could be a file name is not
# one to list; and the text of nothing else.
#
# Usage: check-public.sh DENY_LIST [PATH...]
#
# PATH defaults to the current directory. A directory is searched whole:
# hidden files, files that .gitignore or .ignore name, and binary files read
# as text. Only three things are left out, the places that hold the authors'
# names by right: LICENSE and AUTHORS directly in a directory argument (or in
# the current directory, when a file argument names one of them), and
# everything named .git, at any depth. Git cannot track a path with a .git
# component, so through the gate that is only git's own directory; a tree
# checked outside git skips a nested repository's .git as well. A symbolic
# link is checked by its target, as git stores it, and is never followed.
#
# The deny list holds one literal per line, matched without regard to case
# (Unicode case folding, in any locale). Blank lines and lines that start with
# '#' are ignored, and so is whitespace around an entry; spaces inside one
# count. The list lives outside this repository, in the user's private flake,
# and its values never belong in this one.
#
# Exit status: 0 when nothing was found, 1 on a hit, 2 on bad usage, a
# missing or unreadable list, a list without entries, or a file the search
# could not read.
#
# Changing this file so it finds less needs the maintainer's explicit
# approval (AGENTS.md, rule 6).

set -euo pipefail
shopt -s inherit_errexit

prog=check-public.sh

usage() {
	printf 'usage: %s DENY_LIST [PATH...]\n' "$prog" >&2
	exit 2
}

die() {
	printf '%s: %s\n' "$prog" "$*" >&2
	exit 2
}

(($# >= 1)) || usage
[[ "$1" != -* ]] || usage
list="$1"
listname="${list##*/}"
shift
paths=("$@")
((${#paths[@]} > 0)) || paths=(.)

[[ -f "$list" && -r "$list" ]] || die "cannot read the deny list $list"
command -v rg >/dev/null 2>&1 || die "rg not found; install ripgrep."

entries=()    # the literals
entry_line=() # the line of each in the list
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
	lineno=$((lineno + 1))
	line="${line%$'\r'}"
	line="${line#"${line%%[![:space:]]*}"}"
	line="${line%"${line##*[![:space:]]}"}"
	[[ -z "$line" || "$line" == '#'* ]] && continue
	entries+=("$line")
	entry_line+=("$lineno")
done <"$list"
((${#entries[@]} > 0)) || die "the deny list $list has no entries"

# The same flags for every search: no user configuration, every file, binary
# files as text, and the entries as literals without regard to case.
rg_flags=(--no-config --fixed-strings --ignore-case --text --hidden --no-ignore
	--color never)

files=() # regular files whose contents are searched, as displayed
links=() # symbolic links whose targets are checked, as displayed
names=() # paths below a directory argument, whose names are checked
named=() # how each of those is displayed

# Whether a file argument is LICENSE or AUTHORS in the current directory.
top_exempt() {
	case "${1##*/}" in
	LICENSE | AUTHORS) ;;
	*) return 1 ;;
	esac
	[[ "$(realpath -s -- "$1")" == "$(realpath -s .)/${1##*/}" ]]
}

walk() {
	local dir="$1" path rel shown
	while [[ "$dir" == */ && "$dir" != / ]]; do
		dir="${dir%/}"
	done
	[[ "$dir" != -* ]] || dir="./$dir"
	# find's status comes last, as a record without a slash, which no path it
	# prints can be.
	while IFS= read -r -d '' path; do
		if [[ "$path" != */* ]]; then
			[[ "$path" == "find-status:0" ]] || die "could not walk $dir"
			continue
		fi
		rel="${path#"$dir"/}"
		[[ "$rel" != LICENSE && "$rel" != AUTHORS ]] || continue
		if [[ "$dir" == . ]]; then shown="$rel"; else shown="$path"; fi
		names+=("$rel")
		named+=("$shown")
		if [[ -L "$path" ]]; then links+=("$shown"); else files+=("$shown"); fi
	done < <(
		find "$dir" -name .git -prune -o \( -type f -o -type l \) -print0
		printf 'find-status:%s\0' "$?"
	)
}

for p in "${paths[@]}"; do
	if [[ -L "$p" ]]; then
		top_exempt "$p" || links+=("$p")
	elif [[ -d "$p" ]]; then
		walk "$p"
	elif [[ -f "$p" ]]; then
		top_exempt "$p" || files+=("$p")
	elif [[ -e "$p" ]]; then
		die "$p is neither a file nor a directory"
	else
		die "$p: no such file or directory"
	fi
done

# The entries as files for rg, in a directory only this user can enter: all of
# them in one, and one at a time in another for the searches that say which
# entry matched. Removed on every way out. Made after the paths have been
# walked, so that a TMPDIR inside a searched tree does not put these files
# among the ones that are searched.
umask 077
work="$(mktemp -d "${TMPDIR:-/tmp}/check-public.XXXXXX")" ||
	die "cannot make a temporary directory"
trap 'rm -rf -- "$work"' EXIT
# A write that fails (a full disk) is an error of the check, exit 2. Left to
# errexit it would end the script with status 1, which is a hit.
printf '%s\n' "${entries[@]}" >"$work/all" || die "cannot write the entries to $work"

hits=()
declare -A seen=()

# hit PATH WHERE ENTRY: WHERE is a line number, name or link, and ENTRY the
# index of the entry that matched, which the report gives as its line in the
# list.
hit() {
	local key="$1:$2:$listname:${entry_line[$3]}"
	[[ -z "${seen[$key]:-}" ]] || return 0
	seen[$key]=1
	hits+=("$key")
}

# The contents. One search with every entry finds the files that hold any of
# them, which is none on a clean tree; only those are searched entry by entry
# for the line numbers. The files go in slices, to stay below the limit on
# the length of a command line.
slice=1000
suspects=()
for ((i = 0; i < ${#files[@]}; i += slice)); do
	status=0
	while IFS= read -r -d '' path; do
		suspects+=("$path")
	done < <(rg "${rg_flags[@]}" --files-with-matches --null \
		--file "$work/all" -- "${files[@]:i:slice}")
	wait $! || status=$?
	((status <= 1)) || die "the search failed (rg exit $status); see above"
done

for i in "${!entries[@]}"; do
	((${#suspects[@]} > 0)) || break
	printf '%s\n' "${entries[i]}" >"$work/one" || die "cannot write the entries to $work"
	status=0
	while IFS= read -r -d '' path; do
		IFS= read -r rest
		hit "$path" "${rest%%:*}" "$i"
	done < <(rg "${rg_flags[@]}" --line-number --with-filename --no-heading --null \
		--only-matching --replace '' --file "$work/one" -- "${suspects[@]}")
	wait $! || status=$?
	((status <= 1)) || die "the search failed (rg exit $status); see above"
done

# A list of strings, one per record: which records hold an entry. $1 is the
# kind of hit, $2 the name of the array that displays each record, and the
# rest are the records.
check_strings() {
	local kind="$1" shown_name="$2" record status
	local -n shown_ref="$shown_name"
	shift 2
	(($# > 0)) || return 0
	status=0
	printf '%s\0' "$@" | rg "${rg_flags[@]}" --null-data --quiet \
		--file "$work/all" || status=$?
	((status != 1)) || return 0
	((status == 0)) || die "the search failed (rg exit $status)"
	for i in "${!entries[@]}"; do
		printf '%s\n' "${entries[i]}" >"$work/one" || die "cannot write the entries to $work"
		while IFS= read -r -d '' record; do
			record="${record%%:*}"
			hit "${shown_ref[record - 1]}" "$kind" "$i"
		done < <(printf '%s\0' "$@" | rg "${rg_flags[@]}" --null-data --line-number \
			--only-matching --replace '' --file "$work/one" || true)
	done
}

check_strings name named "${names[@]}"

targets=()
for l in "${links[@]}"; do
	targets+=("$(readlink -- "$l")")
done
check_strings link links "${targets[@]}"

((${#hits[@]} > 0)) || exit 0
printf '%s\n' "${hits[@]}"
if ((${#hits[@]} == 1)); then
	printf '%s: 1 hit: a value from the deny list %s is in the files above (the last number is its line in the list)\n' \
		"$prog" "$listname" >&2
else
	printf '%s: %d hits: values from the deny list %s are in the files above (the last number is the line in the list)\n' \
		"$prog" "${#hits[@]}" "$listname" >&2
fi
exit 1
