# Shared by scripts/check.sh and the git hooks in .githooks/, which source
# it: where the deny list is, and how to lay out what git will commit or push
# as plain files, so scripts/check-public.sh and shellcheck can read exactly
# that and not the work tree. Each object is copied from git's object store
# as it is, with no clean or smudge filter, line-end conversion or export
# attribute in between; a symbolic link becomes a link to the same target.
# Submodules are left out.
# shellcheck shell=bash

# Prints the deny list that git config ravnix.denyList names, as an absolute
# path (a relative one is taken from the top of the work tree), or nothing
# when it is not set. Fails when git cannot read its configuration.
ravnix_deny_list() {
	local value status=0
	value="$(git config --path --get ravnix.denyList)" || status=$?
	if ((status == 1)); then
		return 0
	elif ((status != 0)); then
		echo "could not read git config ravnix.denyList (git exit $status)" >&2
		return 2
	fi
	[[ -n "$value" ]] || return 0
	[[ "$value" == /* ]] || value="$(git rev-parse --show-toplevel)/$value"
	printf '%s\n' "$value"
}

# $1 names the program for the note.
ravnix_skip_note() {
	printf '%s: the public-boundary check was SKIPPED: git config ravnix.denyList is not set.\n' "$1"
	printf '%s: set it to your deny list, for example: git config ravnix.denyList ~/private-flake/deny-list.txt\n' "$1"
}

# Writes the object $2 with mode $1 to the path $3.
ravnix_write_object() {
	local mode="$1" sha="$2" dest="$3"
	case "$mode" in
	100644 | 100755 | 120000) ;;
	*) return 0 ;;
	esac
	mkdir -p -- "${dest%/*}"
	if [[ "$mode" == 120000 ]]; then
		ln -s -- "$(git cat-file blob "$sha")" "$dest"
	else
		git cat-file blob "$sha" >"$dest"
	fi
}

# Lays out the index, which is what the next commit holds, under the
# directory $1, and prints the regular files it wrote, NUL-terminated and
# relative to $1. Paths with merge conflicts have no single staged version
# and are left out; their work-tree copies are what a check reads.
ravnix_snapshot_index() {
	local dir="$1" record meta path mode sha stage status=0
	mkdir -p -- "$dir"
	# mode sha stage<TAB>path
	while IFS= read -r -d '' record; do
		meta="${record%%$'\t'*}"
		path="${record#*$'\t'}"
		mode="${meta%% *}"
		sha="${meta#* }"
		stage="${sha#* }"
		sha="${sha%% *}"
		[[ "$stage" == 0 ]] || continue
		ravnix_write_object "$mode" "$sha" "$dir/$path"
		case "$mode" in
		100644 | 100755) printf '%s\0' "$path" ;;
		esac
	done < <(git ls-files --stage -z)
	wait $! || status=$?
	((status == 0)) || {
		echo "git ls-files failed (exit $status)" >&2
		return 1
	}
}

# Lays out what the commit $1 adds or changes, against each of its parents
# (all of it for a root commit), under the directory $2.
ravnix_snapshot_commit() {
	local commit="$1" dir="$2" meta path mode sha status=0
	mkdir -p -- "$dir"
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		# :old-mode new-mode old-sha new-sha status
		read -r _ mode _ sha _ <<<"$meta"
		ravnix_write_object "$mode" "$sha" "$dir/$path"
	done < <(git diff-tree -r -z -m --root --no-commit-id --no-renames \
		--diff-filter=AMT "$commit")
	wait $! || status=$?
	((status == 0)) || {
		echo "git diff-tree failed on $commit (exit $status)" >&2
		return 1
	}
}
