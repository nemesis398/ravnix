#!/usr/bin/env bash
# A stand-in for rbw, for the tests of `nord` and `vpn-home`. `get ITEM`
# prints the password of an item that `add` stored, and "secret-for-ITEM" for
# any other. `add NAME` takes the item from standard input, as rbw 1.15.0 does
# whenever its standard input is not a terminal (src/edit.rs: no editor
# starts, and $VISUAL and $EDITOR are not read): the first line is the
# password, as parse_editor makes it. In a terminal the real one opens an
# editor, which a test must not depend on, so this one refuses.
# FAKE_DIR holds:
#   rbw-locked       makes `get` fail as it does with a locked vault
#   rbw-add-fails    makes `add` fail
#   rbw-add-corrupts makes `add` exit 0 and store the password without its
#                    last character
#   rbw-get-fails-after-add
#                    makes `get` fail once `add` has run, as it does when
#                    the name now exists twice
#   rbw.log          one line per call
#   rbw.added        the text `add` was given, rbw.added.name the item's name
#   rbw.item.NAME    the password stored under NAME (non-alphanumerics as _)
set -u
d="${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$d/rbw.log"
item() { printf '%s/rbw.item.%s' "$d" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
case "${1:-}" in
get)
	if [ -f "$d/rbw-locked" ]; then
		echo "rbw: vault is locked" >&2
		exit 1
	fi
	if [ -f "$d/rbw-get-fails-after-add" ] && [ -f "$d/rbw.added" ]; then
		echo "rbw: multiple entries found: $2, $2" >&2
		exit 1
	fi
	if [ -f "$(item "$2")" ]; then
		cat "$(item "$2")"
	else
		printf 'secret-for-%s\n' "$2"
	fi
	;;
add)
	[ -f "$d/rbw-add-fails" ] && exit 1
	if [ -t 0 ]; then
		echo "fake rbw: standard input is a terminal, where the real one opens an editor" >&2
		exit 1
	fi
	cat >"$d/rbw.added"
	printf '%s\n' "$2" >"$d/rbw.added.name"
	if [ -f "$d/rbw-add-corrupts" ]; then
		head -n 1 "$d/rbw.added" | sed 's/.$//' >"$(item "$2")"
	else
		head -n 1 "$d/rbw.added" >"$(item "$2")"
	fi
	;;
*)
	echo "fake rbw: unexpected call: $*" >&2
	exit 2
	;;
esac
