#!/usr/bin/env bash
# A stand-in for nmcli, for the tests of `nord`. FAKE_DIR holds its state:
#   profile          the name of the connection, when there is one
#   up               exists while the connection is activated
#   peers            what `wireguard.peers` shows
#   props            the other properties `connection modify` set
#   imported.conf    the file `connection import` was given
#   nmcli.log        one line per call, in order
#   up-fails, import-fails, modify-fails   make that call fail
set -u
d="${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$d/nmcli.log"
case "$*" in
"-t -f NAME connection show")
	[ -f "$d/profile" ] && cat "$d/profile"
	exit 0
	;;
"-g GENERAL.STATE connection show "*)
	[ -f "$d/profile" ] && [ -f "$d/up" ] && echo activated
	exit 0
	;;
"-g wireguard.peers connection show "*)
	[ -f "$d/peers" ] && cat "$d/peers"
	exit 0
	;;
"--wait 20 connection up "*)
	if [ -f "$d/up-fails" ]; then
		echo "Error: Connection activation failed: fake" >&2
		exit 4
	fi
	touch "$d/up"
	exit 0
	;;
"connection down "*)
	rm -f "$d/up"
	exit 0
	;;
"connection import type wireguard file "*)
	if [ -f "$d/import-fails" ]; then
		echo "Error: fake import refused" >&2
		exit 1
	fi
	cp "${@: -1}" "$d/imported.conf"
	echo wg-nord >"$d/profile"
	# The real import activates the profile at once.
	touch "$d/up"
	exit 0
	;;
"connection modify "*)
	[ -f "$d/modify-fails" ] && exit 1
	name="$3"
	[ -f "$d/profile" ] && [ "$(cat "$d/profile")" = "$name" ] || {
		echo "Error: unknown connection '$name'." >&2
		exit 10
	}
	shift 3
	while (($# >= 2)); do
		case "$1" in
		connection.id) echo "$2" >"$d/profile" ;;
		wireguard.peers) printf '%s\n' "$2" >"$d/peers" ;;
		*) printf '%s=%s\n' "$1" "$2" >>"$d/props" ;;
		esac
		shift 2
	done
	exit 0
	;;
esac
echo "fake nmcli: unexpected call: $*" >&2
exit 2
