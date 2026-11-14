#!/usr/bin/env bash
# The session scripts are in single quotes on purpose: the private session
# expands them, with its own environment.
# shellcheck disable=SC2016
# The unlock against the real daemons, in the build sandbox: a private
# dbus-daemon (dbus-run-session) and gnome-keyring-daemon 50, started the
# way pam_gnome_keyring starts it at a login, with a password and without
# one. Sourced by tests/desktop/keyring-autounlock.nix, which sets TOOL and
# puts dbus, gnome-keyring, libsecret and busctl on PATH.
#
# The keyring is a throwaway one, made here with a known password and an
# item labeled "Chromium Safe Storage", as Helium stores its cookie key.
set -euo pipefail

PASSWORD='Pferd Batterie ü 42'
SECRET='cookie-key-0123456789'
fails=0
ok() { echo "ok   $1"; }
bad() {
	echo "FAIL $1" >&2
	fails=$((fails + 1))
}
check() {
	local what=$1
	shift
	if "$@"; then ok "$what"; else bad "$what"; fi
}

root=$TMPDIR/k
mkdir -p "$root/services"
# The Secret Service as D-Bus starts it, from gnome-keyring's own service
# file but with the daemon's store path: the package's file names NixOS's
# capability wrapper, which the sandbox has not.
cat >"$root/services/org.freedesktop.secrets.service" <<EOF
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=$(command -v gnome-keyring-daemon) --start --foreground --components=secrets
EOF
mkdir -p "$root/share/dbus-1"
ln -s "$root/services" "$root/share/dbus-1/services"
session_conf=$(dirname "$(command -v dbus-daemon)")/../share/dbus-1/session.conf

# home NAME makes a home with its own data and runtime directories (the
# control socket's path must fit a Unix socket's 107 bytes, so they are short).
home() {
	local h=$root/$1
	rm -rf "$h"
	mkdir -p "$h/home/.local/share/keyrings" "$h/run"
	chmod 700 "$h/run"
	echo "$h"
}

# in_session HOME SCRIPT runs SCRIPT (bash) in a fresh private session bus,
# with the home's directories and nothing of the build's environment.
in_session() {
	local h=$1
	shift
	env -i PATH="$PATH" HOME="$h/home" XDG_DATA_HOME="$h/home/.local/share" \
		XDG_RUNTIME_DIR="$h/run" XDG_DATA_DIRS="$root/share" XDG_CONFIG_HOME="$h/home/.config" \
		TOOL="$TOOL" PASSWORD="$PASSWORD" SECRET="$SECRET" LANG=C.UTF-8 \
		dbus-run-session --config-file="$session_conf" -- bash -euo pipefail -c "$1"
}

# ── the fixture: a login keyring encrypted with PASSWORD ──────────────────────
fixture=$(home fixture)
in_session "$fixture" '
	printf %s "$PASSWORD" | gnome-keyring-daemon --unlock --foreground --components=secrets >/dev/null 2>&1 &
	daemon=$!
	for _ in $(seq 100); do
		busctl --address="$DBUS_SESSION_BUS_ADDRESS" status org.freedesktop.secrets >/dev/null 2>&1 && break
		sleep 0.1
	done
	printf %s "$SECRET" | secret-tool store --collection=login --label="Chromium Safe Storage" application chromium
	kill $daemon; wait $daemon || true
'
keyring=$fixture/home/.local/share/keyrings/login.keyring
check "fixture: the login keyring is encrypted (binary format)" \
	bash -c "head -c 16 '$keyring' | grep -qa '^GnomeKeyring'"
fixture_hash=$(sha256sum <"$keyring")

# The part of every scenario that runs in its session: the daemon as PAM
# starts it (--daemonize --login, the password on stdin, none for a tap),
# then the tool, then what the bus says. Output lines start with a tag.
probe='
	locked() { busctl --address="$DBUS_SESSION_BUS_ADDRESS" get-property org.freedesktop.secrets \
		/org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked 2>&1 || true; }
	set +e
	"$TOOL" --credential "$CRED" >"$OUT" 2>&1
	echo "rc=$?"
	echo "locked=$(locked)"
	pid=$(busctl --address="$DBUS_SESSION_BUS_ADDRESS" call org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus GetConnectionUnixProcessID s org.freedesktop.secrets 2>/dev/null | cut -d" " -f2)
	echo "owner=$(tr "\0" " " </proc/$pid/cmdline 2>/dev/null)"
	echo "lookup=$(timeout 10 secret-tool lookup application chromium 2>&1 </dev/null)"
	"$TOOL" --credential "$CRED" >"$OUT.2" 2>&1
	echo "rc2=$?"
'
pam_tap='gnome-keyring-daemon --daemonize --login </dev/null >/dev/null'
pam_password='printf %s "$PASSWORD" | gnome-keyring-daemon --daemonize --login >/dev/null'

# scenario NAME DAEMON CREDENTIAL-CONTENT|- [nokeyring]
scenario() {
	local name=$1 daemon=$2 content=$3 nokeyring=${4:-}
	local h
	h=$(home "$name")
	[[ -n $nokeyring ]] || cp "$keyring" "$h/home/.local/share/keyrings/login.keyring"
	if [[ $content == - ]]; then
		cred=$h/absent
	else
		cred=$h/cred
		printf '%s' "$content" >"$cred"
	fi
	in_session "$h" "export CRED=$cred OUT=$h/out; $daemon; $probe" >"$h/probe" 2>"$h/probe.err" || true
	echo "$h"
}
field() { sed -n "s/^$2=//p" "$1/probe"; }
lines() { wc -l <"$1"; }
no_password_in() { ! grep -q 'Pferd' "$@"; }

# ── a tap: PAM had no password, the credential holds the right one ────────────
h=$(scenario tap "$pam_tap" "$PASSWORD"$'\n')
check "tap: the tool exits 0" test "$(field "$h" rc)" = 0
check "tap: it says it unlocked the keyring, in one line" \
	bash -c "grep -q 'unlocked the login keyring' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "tap: the keyring reports unlocked" test "$(field "$h" locked)" = "b false"
check "tap: Helium's cookie key comes back without a prompt" test "$(field "$h" lookup)" = "$SECRET"
check "tap: the Secret Service is the daemon PAM started, not a second one" \
	bash -c "grep -q -- '^owner=.*--login' '$h/probe'"
check "tap: a second run has nothing to do" \
	bash -c "test '$(field "$h" rc2)' = 0 && grep -q 'already unlocked' '$h/out.2' && test \$(wc -l <'$h/out.2') = 1"
check "tap: the keyring file is still the encrypted one" \
	bash -c "test \"\$(sha256sum <'$h/home/.local/share/keyrings/login.keyring')\" = '$fixture_hash'"
check "tap: no password in any output" no_password_in "$h/out" "$h/out.2" "$h/probe" "$h/probe.err"

# ── a password login: PAM unlocked it already ──────────────────────────────────
h=$(scenario password "$pam_password" "$PASSWORD")
check "password: exit 0, already unlocked, one line" \
	bash -c "test '$(field "$h" rc)' = 0 && grep -q 'already unlocked' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "password: unlocked" test "$(field "$h" locked)" = "b false"

# ── a password login, with a keyring password of its own ───────────────────────
# PAM's attempt with the login password fails; the credential opens it.
pam_other='printf %s "the login password" | gnome-keyring-daemon --daemonize --login >/dev/null'
h=$(scenario own "$pam_other" "$PASSWORD")
check "own password: exit 0, unlocked, one line" \
	bash -c "test '$(field "$h" rc)' = 0 && grep -q 'unlocked the login keyring' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "own password: unlocked, and the cookie key is there" \
	bash -c "test '$(field "$h" locked)' = 'b false' && test '$(field "$h" lookup)' = '$SECRET'"
check "own password: the keyring keeps its own password" \
	bash -c "test \"\$(sha256sum <'$h/home/.local/share/keyrings/login.keyring')\" = '$fixture_hash'"

# ── a tap with a wrong password in the credential ──────────────────────────────
h=$(scenario wrong "$pam_tap" "Pferd but not the one")
check "wrong password: exit 0" test "$(field "$h" rc)" = 0
check "wrong password: one warning line" \
	bash -c "grep -q 'does not unlock the login keyring' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "wrong password: the keyring stays locked" test "$(field "$h" locked)" = "b true"
check "wrong password: the keyring file is unchanged" \
	bash -c "test \"\$(sha256sum <'$h/home/.local/share/keyrings/login.keyring')\" = '$fixture_hash'"
check "wrong password: no password in any output" no_password_in "$h/out" "$h/out.2" "$h/probe.err"

# ── a tap without a credential ─────────────────────────────────────────────────
h=$(scenario nocred "$pam_tap" -)
check "no credential: exit 0, one line" \
	bash -c "test '$(field "$h" rc)' = 0 && grep -q 'no credential' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "no credential: the keyring stays locked" test "$(field "$h" locked)" = "b true"

# ── a tap on a home without a login keyring ────────────────────────────────────
h=$(scenario nokeyring "$pam_tap" "$PASSWORD" nokeyring)
check "no login keyring: exit 0, one line" \
	bash -c "test '$(field "$h" rc)' = 0 && grep -q 'no login keyring' '$h/out' && test \$(wc -l <'$h/out') = 1"
check "no login keyring: none is created with the credential's password" \
	test ! -e "$h/home/.local/share/keyrings/login.keyring"

# ── no Secret Service at all ───────────────────────────────────────────────────
h=$(home nobus)
printf %s "$PASSWORD" >"$h/cred"
set +e
"$TOOL" --credential "$h/cred" --bus "unix:path=$h/run/no-bus" >"$h/out" 2>&1
rc=$?
set -e
check "no bus: exit 1, one line" bash -c "test $rc = 1 && test \$(wc -l <'$h/out') = 1"

if ((fails > 0)); then
	echo "keyring daemon tests: $fails failed" >&2
	for f in "$root"/*/probe "$root"/*/probe.err "$root"/*/out; do
		echo "--- $f" >&2
		sed 's/^/  | /' "$f" >&2
	done
	exit 1
fi
echo "keyring daemon tests: all passed"
