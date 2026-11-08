#!/usr/bin/env bash
# A stand-in for rbw, for the tests of `nord` and `vpn-home`. `get ITEM`
# prints "secret-for-ITEM"; `add NAME` runs the editor on a temporary file as
# the real one does ($VISUAL before $EDITOR), and keeps what the editor wrote.
# FAKE_DIR holds:
#   rbw-locked       makes `get` fail as it does with a locked vault
#   rbw-add-fails    makes `add` fail
#   rbw.log          one line per call
#   rbw.added        the text `add` was given, rbw.added.name the item's name
set -u
d="${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$d/rbw.log"
case "${1:-}" in
get)
	if [ -f "$d/rbw-locked" ]; then
		echo "rbw: vault is locked" >&2
		exit 1
	fi
	printf 'secret-for-%s\n' "$2"
	;;
add)
	[ -f "$d/rbw-add-fails" ] && exit 1
	f="$(mktemp -p "$d" rbw-add.XXXXXX)"
	# As rbw 1.15.0 picks its editor (src/edit.rs): $VISUAL first, and $EDITOR
	# only when VISUAL is unset; an editor with a space or another shell
	# metacharacter in it is run as `/bin/sh -c "EDITOR FILE"`.
	editor="${VISUAL-${EDITOR-}}"
	[ -n "$editor" ] || exit 1
	case "$editor" in
	*[!A-Za-z0-9_./-]*) sh -c "$editor $f" || exit 1 ;;
	*) "$editor" "$f" || exit 1 ;;
	esac
	cp "$f" "$d/rbw.added"
	printf '%s\n' "$2" >"$d/rbw.added.name"
	rm -f "$f"
	;;
*)
	echo "fake rbw: unexpected call: $*" >&2
	exit 2
	;;
esac
