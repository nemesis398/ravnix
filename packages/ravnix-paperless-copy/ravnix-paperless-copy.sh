#!/usr/bin/env bash
# ravnix-paperless-copy --media DIR --targets DIR [--once] [--at HH:MM]
#
# Mirrors each owner's filed Paperless documents into that owner's read-only
# "Archiv" folder, one way, every night. DIR of --media is Paperless' media
# folder (documents/archive/OWNER/..., documents/originals/OWNER/...); DIR of
# --targets holds one folder per owner, each the Archiv folder of that person,
# and the folders there ARE the owner list: the compose override mounts one
# per person and nobody else is ever copied. An owner is a real directory in
# --targets; a symlink there is refused, never followed.
#
# What an owner's folder becomes, exactly: the files of media/documents/archive/
# OWNER (the searchable PDF/A), plus every file of media/documents/originals/
# OWNER that has no archive twin, which is the same relative path with .pdf in
# place of its extension (a JPG, say, that Paperless could not make a PDF/A
# of), plus LIESMICH.txt. Everything else in the owner's folder is deleted, so
# a file deleted there is back after the run, a change is overwritten, and a
# document renamed in Paperless (title, correspondent, year) has its new path
# and no stale old file or empty folder.
#
# How the fallback survives the delete pass: there is one rsync --delete per
# owner, from a staging tree that holds exactly what the folder is to become.
# The staging tree is made of symlinks to the source files (cp -rs of the
# archive tree, then a symlink for each original without a twin), and rsync
# follows them (-L). So the delete pass compares against the merged set, and a
# fallback original is as safe from it as any archive file; no protect rule, no
# second pass, and the folders that only a fallback sits in stay. Symlinks,
# fifos and other non-regular files of the source never get into the staging
# tree, so a link in the media folder cannot show the owner a file outside it.
# The staging tree lives in $TMPDIR and is removed when the run ends.
#
# It refuses (exit 3) to run when the archive tree is missing or empty while a
# target holds files, so an unmounted media folder never empties a copy. With
# the same source and empty targets it exits 0 and says there is nothing to do,
# and pushes nothing.
#
# The push: when the environment variable KUMA_PUSH_URL is set and not empty,
# a run that copied every owner without a failure or refusal calls it, with
# curl reading the URL from its standard input (a push URL is a token, so it
# is on no command line and in no output). A push that fails is said and does
# not change the exit status. The variable is unset before anything else runs.
#
# Without --once it loops, running at --at (HH:MM, default 03:30) every day on
# the clock of $TZ (default Europe/Berlin), and the first run is the first
# 03:30 after the start, not the start. A run that fails or refuses is logged
# and the loop goes on; SIGTERM and SIGINT end it.
#
# Exit status: 0 done (or nothing to do), 1 a copy failed, 3 refused, 2 usage.
set -uo pipefail
export LC_ALL=C
export TZ=${TZ:-Europe/Berlin}

notice=@notice@

# The push URL is a token: keep it from every child but curl's standard input.
push_url=${KUMA_PUSH_URL:-}
unset KUMA_PUSH_URL

say() { printf 'ravnix-paperless-copy: %s\n' "$*" >&2; }

usage() {
	cat <<-'EOF'
		usage: ravnix-paperless-copy --media DIR --targets DIR [--once] [--at HH:MM]
		  --media DIR    Paperless' media folder (documents/archive, documents/originals)
		  --targets DIR  one folder per owner, each that person's Archiv folder
		  --once         copy once and exit; without it, loop and copy daily at --at
		  --at HH:MM     the time of the daily copy, default 03:30, on the clock of $TZ
		                 (default Europe/Berlin)
		The Uptime Kuma push URL is read from the environment variable KUMA_PUSH_URL.
		Exit status: 0 done, 1 a copy failed, 2 usage, 3 refused.
	EOF
}
die_usage() {
	say "$1"
	usage >&2
	exit 2
}

media='' targets='' once=0 at=03:30
while (($#)); do
	case $1 in
	--media | --targets | --at)
		(($# >= 2)) || die_usage "$1 needs a value"
		case $1 in
		--media) media=$2 ;;
		--targets) targets=$2 ;;
		--at) at=$2 ;;
		esac
		shift 2
		;;
	--once)
		once=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die_usage "unknown argument: $1" ;;
	esac
done
[[ -n $media ]] || die_usage "--media is required"
[[ -n $targets ]] || die_usage "--targets is required"
[[ $at =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die_usage "--at needs HH:MM (00:00 to 23:59), not '$at'"
[[ -d $targets ]] || die_usage "--targets is not a directory: $targets"
[[ -f $notice ]] || {
	say "the notice $notice is missing"
	exit 2
}
[[ $media == /* ]] || media=$PWD/$media
[[ $targets == /* ]] || targets=$PWD/$targets
media=${media%/}
targets=${targets%/}
[[ $(cd -- "$targets" && pwd -P) != / ]] || die_usage "--targets must not be /"

archive_root=$media/documents/archive
originals_root=$media/documents/originals

work=''
sleeper=''
cleanup() {
	[[ -z $sleeper ]] || kill "$sleeper" 2>/dev/null
	[[ -z $work ]] || rm -rf -- "$work"
}
trap cleanup EXIT

# Does DIR hold anything other than the notice?
holds_files() {
	[[ -n $(find -P "$1" -mindepth 1 -maxdepth 1 ! -name LIESMICH.txt -print -quit 2>/dev/null) ]]
}

# Fills the staging tree $1 for OWNER: the archive files, the originals with
# no archive twin, and the notice. Returns 1 when it cannot.
build_stage() {
	local stage=$1 owner=$2 src_a="$archive_root/$2" src_o="$originals_root/$2"
	local rel stem base
	mkdir -p -- "$stage" || return 1
	if [[ -d $src_a ]]; then
		cp -rs -- "$src_a/." "$stage/" || return 1
		# A symlink, a fifo or a device in the source is no document: the
		# staging link to it would be followed.
		while IFS= read -r -d '' rel; do
			rm -f -- "${stage:?}/$rel"
		done < <(find -P "$src_a" -mindepth 1 ! -type f ! -type d -printf '%P\0')
	fi
	FALLBACKS=0
	if [[ -d $src_o ]]; then
		while IFS= read -r -d '' rel; do
			base=${rel##*/}
			stem=$rel
			[[ $base != ?*.* ]] || stem=${rel%.*}
			[[ ! -e $stage/$stem.pdf ]] || continue
			[[ ! -e $stage/$rel && ! -L $stage/$rel ]] || continue
			[[ $rel != */* ]] || mkdir -p -- "$stage/${rel%/*}" || return 1
			ln -s -- "$src_o/$rel" "$stage/$rel" || return 1
			FALLBACKS=$((FALLBACKS + 1))
		done < <(find -P "$src_o" -type f -printf '%P\0')
	fi
	ln -sf -- "$notice" "$stage/LIESMICH.txt"
}

# Copies one owner. Returns 0, 1 (failed) or 3 (refused).
copy_owner() {
	local owner=$1 dst="$targets/$1" stage="$work/stage" log="$work/rsync.log" rc copied deleted
	if [[ -L $archive_root/$owner || -L $originals_root/$owner ]]; then
		say "refusing $owner: its folder in the media folder is a symlink"
		return 3
	fi
	rm -rf -- "$stage"
	if ! build_stage "$stage" "$owner"; then
		say "$owner: could not list the documents"
		return 1
	fi
	rsync -rtLO --no-perms --chmod=D755,F644 --delete-delay --itemize-changes \
		-- "$stage/" "$dst/" >"$log"
	rc=$?
	rm -rf -- "$stage"
	# 24: a file went away while it was read, which a night's consume can do.
	if ((rc != 0 && rc != 24)); then
		say "$owner: rsync failed with status $rc"
		return 1
	fi
	copied=$(grep -c '^>f' "$log")
	deleted=$(grep -c '^\*deleting' "$log")
	say "$owner: $copied copied, $deleted deleted, $FALLBACKS originals without an archive version"
}

push() {
	[[ -n $push_url ]] || return 0
	if [[ $push_url == *[\"\\]* || $push_url == *$'\n'* || $push_url == *$'\r'* ]]; then
		say "KUMA_PUSH_URL holds a quote, a backslash or a line break; not pushing"
		return 0
	fi
	# curl reads the URL as a config line from standard input: printf is a
	# builtin, so the token is on no command line.
	if ! printf 'url = "%s"\n' "$push_url" | curl -fsS --max-time 30 --retry 2 --config - -o /dev/null; then
		say "the push to Uptime Kuma failed"
	fi
}

# One run over every owner folder, with a staging directory of its own that
# goes when the run ends. Returns 0, 1 (a copy failed) or 3 (refused).
run_once() {
	local rc
	work=$(mktemp -d -p "${TMPDIR:-/tmp}" paperless-copy.XXXXXX) || {
		say "cannot make a staging directory in ${TMPDIR:-/tmp}"
		return 1
	}
	run_owners
	rc=$?
	rm -rf -- "$work"
	work=''
	return "$rc"
}

run_owners() {
	local owner rc failed=0 refused=0 done_any=0 link
	local -a owners=()
	mapfile -d '' owners < <(find -P "$targets" -mindepth 1 -maxdepth 1 -type d -printf '%f\0' | sort -z)

	if [[ ! -d $archive_root ]] || [[ -z $(find -H "$archive_root" -mindepth 1 -print -quit 2>/dev/null) ]]; then
		for owner in "${owners[@]}"; do
			if holds_files "$targets/$owner"; then
				say "refusing to run: $archive_root is missing or empty, and $owner's folder holds files"
				return 3
			fi
		done
		say "$archive_root is missing or empty, and no folder holds files: nothing to do"
		return 0
	fi

	while IFS= read -r -d '' link; do
		say "refusing $link: it is a symlink, not a folder"
		refused=1
	done < <(find -P "$targets" -mindepth 1 -maxdepth 1 -type l -printf '%f\0')

	for owner in "${owners[@]}"; do
		copy_owner "$owner"
		rc=$?
		case $rc in
		0) done_any=1 ;;
		3) refused=1 ;;
		*) failed=1 ;;
		esac
	done
	((failed == 0)) || return 1
	((refused == 0)) || return 3
	if ((done_any == 0)); then
		say "no owner folders in $targets: nothing to do"
		return 0
	fi
	push
	return 0
}

# Seconds from now to the next HH:MM on the clock of $TZ.
seconds_until() {
	local now next
	now=$(date +%s)
	next=$(date -d "today $1" +%s)
	((next > now)) || next=$(date -d "tomorrow $1" +%s)
	echo $((next - now))
}

if ((once)); then
	run_once
	exit $?
fi

trap 'say "stopping"; exit 0' TERM INT
say "copying daily at $at ($TZ)"
while :; do
	wait_s=$(seconds_until "$at")
	say "next run at $at, in ${wait_s}s"
	sleep "$wait_s" &
	sleeper=$!
	wait "$sleeper"
	sleeper=''
	run_once
	rc=$?
	((rc == 0)) || say "the run ended with status $rc"
done
