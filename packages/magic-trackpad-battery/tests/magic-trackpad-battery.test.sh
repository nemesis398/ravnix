#!/usr/bin/env bash
# Tests for magic-trackpad-battery (packages/magic-trackpad-battery), run by the
# check bin-magic-trackpad-battery. The script has no tests in Fedora; these are
# new. The build sandbox has no Apple device and no /dev/hidraw, so the script's
# functions are loaded as a module and run against a fake sysfs and a fake
# ioctl: which devices it picks (by driver, not by name), how it names them, what
# it does with a report that is out of range or cannot be read, and what it
# prints. The real command is run once for what it must do on a machine with no
# device at all: print nothing and exit 0.
#
# MAGIC_TRACKPAD_BATTERY_UNDER_TEST=<file> tests another copy; by default it is
# the magic-trackpad-battery on the PATH.

set -uo pipefail

SUT=$(readlink -f "${MAGIC_TRACKPAD_BATTERY_UNDER_TEST:-$(type -P magic-trackpad-battery)}")
SB=$(mktemp -d "${TMPDIR:-/tmp}/magic-trackpad-battery-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

echo "magic-trackpad-battery"

# The two cases below need a machine with no Magic device. The build sandbox is
# one; a laptop with a trackpad connected is not, and says so instead of failing.
if compgen -G '/sys/bus/hid/drivers/magicmouse/[0-9]*' >/dev/null; then
    printf '  - %s\n' "this machine has a Magic device: the no-device cases are not run"
else
    no_device() { # no_device [OPTION]: the command prints nothing and exits 0
        local out rc
        out=$(env -i PATH="$PATH" HOME="$SB" "$SUT" "$@" 2>&1 </dev/null)
        rc=$?
        if [[ $rc == 0 && -z $out ]]; then
            printf '  \e[32m✓\e[0m %s\n' "with no HID device it prints nothing and exits 0 (${1:-no option})"
        else
            printf '  \e[31m✗\e[0m %s\n    rc %s, out: %s\n' "with no HID device it prints nothing and exits 0 (${1:-no option})" "$rc" "$out"
            exit 1
        fi
    }
    no_device
    no_device --tsv
fi

# Not exec'd, so that the trap above removes the sandbox when it ends.
env -i PATH="$PATH" HOME="$SB" SB="$SB" SUT="$SUT" python3 -I - <<'PY'
import contextlib
import importlib.machinery
import importlib.util
import io
import os
import sys

sb = os.environ["SB"]
loader = importlib.machinery.SourceFileLoader("mtb", os.environ["SUT"])
spec = importlib.util.spec_from_loader("mtb", loader)
mtb = importlib.util.module_from_spec(spec)
loader.exec_module(mtb)

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        print(f"  \033[32m✓\033[0m {name}")
        passed += 1
    else:
        print(f"  \033[31m✗\033[0m {name}\n    {detail}")
        failed += 1


# ── the ioctl number ───────────────────────────────────────────────────────
# HIDIOCGINPUT(len) is _IOC(READ|WRITE, 'H', 0x0A, len). For a 3 byte report
# that is 0xC003480A, the number linux/hidraw.h gives.
check("HIDIOCGINPUT(3) is the number linux/hidraw.h gives", mtb.hidiocginput(3) == 0xC003480A,
      hex(mtb.hidiocginput(3)))
check("the length goes into the size field", mtb.hidiocginput(64) == 0xC040480A, hex(mtb.hidiocginput(64)))

# ── a fake sysfs ───────────────────────────────────────────────────────────
root = os.path.join(sb, "sys")
drivers = os.path.join(root, "drivers")
os.makedirs(os.path.join(drivers, "magicmouse"))
os.makedirs(os.path.join(drivers, "hid-generic"))


def device(name, driver=None, model=None, uevent=None, hidraw=()):
    d = os.path.join(root, "devices", name)
    os.makedirs(d)
    if driver:
        os.symlink(os.path.join(drivers, driver), os.path.join(d, "driver"))
    if model is not None:
        ps = os.path.join(d, "power_supply", "ps0")
        os.makedirs(ps)
        with open(os.path.join(ps, "model_name"), "w") as fh:
            fh.write(model)
    if uevent is not None:
        with open(os.path.join(d, "uevent"), "w") as fh:
            fh.write(uevent)
    for node in hidraw:
        os.makedirs(os.path.join(d, "hidraw", node))
    os.makedirs(os.path.join(root, "bus"), exist_ok=True)
    link = os.path.join(root, "bus", name)
    os.symlink(d, link)
    return d


device("0005:004C:0324.0001", "magicmouse", model="Magic Trackpad\n", hidraw=("hidraw3",))
device("0003:05AC:0324.0002", "magicmouse", uevent="DRIVER=magicmouse\nHID_NAME=Magic Keyboard\n")
device("0003:046D:C52B.0003", "hid-generic", model="Some Mouse")
device("0003:0000:0000.0004")
device("0005:004C:0324.0005", "magicmouse", model="\n", uevent="HID_NAME=never read\n")

real_glob = mtb.glob.glob
mtb.glob.glob = lambda pat: real_glob(pat.replace("/sys/bus/hid/devices", os.path.join(root, "bus")))
found = list(mtb.magic_devices())
names = [n for _, n in found]
paths = [os.path.basename(p) for p, _ in found]
check("only devices bound to the magicmouse driver are picked, whatever their name",
      paths == ["0003:05AC:0324.0002", "0005:004C:0324.0001", "0005:004C:0324.0005"], str(paths))
check("the label is the power_supply model when there is one", "Magic Trackpad" in names, str(names))
check("without a power_supply the label is the HID_NAME of the uevent", "Magic Keyboard" in names, str(names))
check("an empty model leaves the default label, and the uevent is not read then", names.count("Magic device") == 1, str(names))
check("a device with no driver link, and one with another driver, are left out",
      not any("0004" in p or "0003.0003" in p or "C52B" in p for p in paths), str(paths))

# ── reading the report ─────────────────────────────────────────────────────
real_open, real_ioctl = mtb.open if hasattr(mtb, "open") else open, mtb.fcntl.ioctl


class Fake:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


opened = []
answers = {}


def fake_open(path, mode="r", *a, **k):
    if path.startswith("/dev/"):
        node = path[5:]
        opened.append(node)
        if node not in answers or answers[node] is None:
            raise PermissionError(13, "Permission denied", path)
        return Fake()
    return open(path, mode, *a, **k)


def fake_ioctl(fh, num, buf):
    node = opened[-1]
    assert num == mtb.hidiocginput(3), hex(num)
    buf[:] = bytes(answers[node])
    return 0


mtb.open = fake_open
mtb.fcntl.ioctl = fake_ioctl
trackpad = os.path.join(root, "devices", "0005:004C:0324.0001")

answers["hidraw3"] = [0x90, 0x04, 0x64]
check("a full battery: report 90 04 64 is 100 percent, not charging (the kernel says 4)",
      mtb.read_battery(trackpad) == (100, False), str(mtb.read_battery(trackpad)))
answers["hidraw3"] = [0x90, 0x02, 0x37]
check("bit 1 of the flags byte is charging", mtb.read_battery(trackpad) == (55, True), str(mtb.read_battery(trackpad)))
answers["hidraw3"] = [0x90, 0x00, 0x00]
check("an empty battery is 0 percent", mtb.read_battery(trackpad) == (0, False), str(mtb.read_battery(trackpad)))
answers["hidraw3"] = [0x90, 0x00, 101]
check("a capacity above 100 is no answer", mtb.read_battery(trackpad) is None, str(mtb.read_battery(trackpad)))
answers["hidraw3"] = [0x91, 0x00, 50]
check("a report that is not 0x90 is no answer", mtb.read_battery(trackpad) is None, str(mtb.read_battery(trackpad)))
answers["hidraw3"] = None
check("a node that cannot be opened is no answer, not a crash", mtb.read_battery(trackpad) is None)
check("a device with no hidraw directory is no answer", mtb.read_battery(os.path.join(root, "devices", "0003:05AC:0324.0002")) is None)

# Several hidraw nodes: the first that answers wins.
many = device("0005:004C:0324.0009", "magicmouse", model="Two Nodes", hidraw=("hidraw7", "hidraw8"))
answers.update({"hidraw7": None, "hidraw8": [0x90, 0x00, 42]})
check("with several nodes the first one that answers is used", mtb.read_battery(many) == (42, False))

# ── the output ─────────────────────────────────────────────────────────────
answers.clear()
answers["hidraw3"] = [0x90, 0x04, 0x64]
answers.update({"hidraw7": [0x90, 0x02, 7], "hidraw8": None})


def run(argv):
    buf = io.StringIO()
    old = sys.argv
    sys.argv = ["magic-trackpad-battery", *argv]
    try:
        with contextlib.redirect_stdout(buf):
            rc = mtb.main()
    finally:
        sys.argv = old
    return rc, buf.getvalue()


rc, text = run([])
check("the default output is one line per device with a percentage and the state",
      rc == 0 and text == "Magic Trackpad: 100% (discharging)\nTwo Nodes: 7% (charging)\n", repr(text))
rc, text = run(["--tsv"])
check("--tsv is capacity, status and name, separated by tabs, for a status bar",
      rc == 0 and text == "100\tDischarging\tMagic Trackpad\n7\tCharging\tTwo Nodes\n", repr(text))
answers.clear()
rc, text = run(["--tsv"])
check("devices that cannot be read are left out, and the exit code is still 0", rc == 0 and text == "", repr(text))

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
exit $?
