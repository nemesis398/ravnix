#!/usr/bin/env bash
# A stand-in for rbw, for the tests of `nord` and `vpn-home`. `get ITEM`
# prints "secret-for-ITEM"; `add NAME` runs $EDITOR on a temporary file as
# the real one does, and keeps what the editor wrote. FAKE_DIR holds:
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
	eval "${EDITOR:?} \"$f\"" || exit 1
	cp "$f" "$d/rbw.added"
	printf '%s\n' "$2" >"$d/rbw.added.name"
	rm -f "$f"
	;;
*)
	echo "fake rbw: unexpected call: $*" >&2
	exit 2
	;;
esac
