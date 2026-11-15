#!/usr/bin/env bash
# The command magic-trackpad-battery as a program, run by the check
# bin-magic-trackpad-battery. The Odin tests (tools/magic-trackpad-battery/
# tests) hold the logic against a fake reader; this holds what only the built
# program shows: its exit status and streams, with the real ioctl, on a machine
# with no device and on a fake sysfs whose nodes are no hidraw nodes. The build
# sandbox has no Apple device and no /dev/hidraw.
#
# MAGIC_TRACKPAD_BATTERY_UNDER_TEST=<file> tests another copy; by default it is
# the magic-trackpad-battery on the PATH.

set -uo pipefail

SUT=$(readlink -f "${MAGIC_TRACKPAD_BATTERY_UNDER_TEST:-$(type -P magic-trackpad-battery)}")
SB=$(mktemp -d "${TMPDIR:-/tmp}/magic-trackpad-battery-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

echo "magic-trackpad-battery"

failed=0
ok() { printf '  \e[32m✓\e[0m %s\n' "$1"; }
bad() {
    printf '  \e[31m✗\e[0m %s\n    %s\n' "$1" "$2"
    failed=1
}

# expect NAME WANT_RC WANT_OUT -- ARG...: stdout and stderr together.
expect() {
    local name=$1 want_rc=$2 want_out=$3 out rc
    shift 4
    out=$(env -i PATH="$PATH" HOME="$SB" "$SUT" "$@" 2>&1 </dev/null)
    rc=$?
    if [[ $rc == "$want_rc" && $out == "$want_out" ]]; then
        ok "$name"
    else
        bad "$name" "rc $rc, out: $out"
    fi
}

# On a machine with a Magic device connected the real command prints a line,
# which is right, so the no-device cases there use an empty root.
mkdir -p "$SB/empty"
expect "an empty system prints nothing and exits 0" 0 "" -- --root "$SB/empty"
expect "an empty system prints nothing with --tsv" 0 "" -- --tsv --root "$SB/empty"
expect "a root that is not there prints nothing and exits 0" 0 "" -- --tsv --root "$SB/missing"
if ! compgen -G '/sys/bus/hid/drivers/magicmouse/[0-9]*' >/dev/null; then
    expect "with no HID device it prints nothing and exits 0" 0 "" --
    expect "with no HID device it prints nothing and exits 0 (--tsv)" 0 "" -- --tsv
else
    printf '  - %s\n' "this machine has a Magic device: the no-device cases of the real system are not run"
fi

# A device bound to the driver whose hidraw node is a plain file: the ioctl
# fails there, which is no answer and no error.
mkdir -p "$SB/fake/sys/bus/hid/devices/0005:004C:0324.0001/hidraw/hidraw3" "$SB/fake/sys/bus/hid/drivers/magicmouse" "$SB/fake/dev"
ln -s "$SB/fake/sys/bus/hid/drivers/magicmouse" "$SB/fake/sys/bus/hid/devices/0005:004C:0324.0001/driver"
printf '\x90\x00\x32' >"$SB/fake/dev/hidraw3"
expect "a node that is no hidraw node is no answer" 0 "" -- --tsv --root "$SB/fake"
# Root opens the node whatever its mode, and the case would then pass for the
# other reason (the ioctl fails), so it runs only for a user who is refused.
# The Odin test the_real_reader_gets_no_answer_where_there_is_no_hidraw holds
# the open failure for every user.
chmod 000 "$SB/fake/dev/hidraw3"
if [[ $EUID == 0 ]]; then
    printf '  - %s\n' "running as root: the case of a node that cannot be opened is not run"
else
    expect "a node that cannot be opened is no answer" 0 "" -- --root "$SB/fake"
fi

expect "an argument it does not know is ignored" 0 "" -- --bogus --root "$SB/empty"
expect "--root without a value is a usage error" 2 "magic-trackpad-battery: --root needs a value
run magic-trackpad-battery --help for the usage" -- --root

out=$(env -i PATH="$PATH" HOME="$SB" "$SUT" --help 2>&1 </dev/null)
rc=$?
if [[ $rc == 0 && $out == "usage: magic-trackpad-battery"* && $out == *"no fallback to the kernel's value"* ]]; then
    ok "--help prints the usage and exits 0"
else
    bad "--help prints the usage and exits 0" "rc $rc, out: $out"
fi

exit $failed
