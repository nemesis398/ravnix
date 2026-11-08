"""Read the TRUE battery level of Apple Magic devices, straight from the hardware.

WHY THIS EXISTS
---------------
The kernel's hid_magicmouse driver implements battery reporting only over USB. Over
Bluetooth the value in /sys/class/power_supply is wrong, and wrong in a specific,
reproducible way. Measured on this machine 2026-09-04, pad connected over Bluetooth:

    HID report 0x90 : 90 04 64      byte 1 = 0x04 flags, byte 2 = 0x64 = 100%
    kernel reports  : 4%

The kernel reports 4 while the flags byte is 0x04 and the real capacity is 0x64. It
is reading the STATUS byte as the capacity, one byte short of the right offset. So the
sysfs value is not merely stale or coarse, it is a different field entirely, and it
reads alarmingly low on a full battery. Anything trusting power_supply (waybar,
upower, GNOME) therefore shows a permanent false low-battery warning.

The device itself reports the truth as HID input report 0x90:
    byte 0   report id, 0x90
    byte 1   status flags, bit 1 (0x02) = charging
    byte 2   capacity, 0..100

Reading it needs access to the hidraw node, granted by the uaccess udev rule that
modules/desktop/scripts.nix installs. Without that rule this exits quietly rather
than printing a number it could not verify.

DELIBERATELY NO FALLBACK to the sysfs value: a confidently wrong percentage is worse
than no percentage, because it trains you to ignore the warning that matters.
"""
import fcntl, glob, os, sys

_NR, _TYPE, _SIZE, _DIR = 0, 8, 16, 30
_READ, _WRITE = 2, 1

def _ioc(direction, letter, nr, size):
    return (direction << _DIR) | (ord(letter) << _TYPE) | (nr << _NR) | (size << _SIZE)

def hidiocginput(length):
    """HIDIOCGINPUT(len) — fetch an input report by id, without waiting for traffic."""
    return _ioc(_READ | _WRITE, 'H', 0x0A, length)

REPORT_ID = 0x90
CHARGING_BIT = 0x02

def magic_devices():
    """Yield (hid_sysfs_path, name) for every HID device bound to the magicmouse driver.

    Matching on the DRIVER, not on a product name or id: it is stable across the two
    buses (Bluetooth 0005:004C:0324 and USB 0003:05AC:0324 both bind magicmouse) and
    across Apple renaming the product string, which they did for the 2024 model.
    """
    for dev in sorted(glob.glob('/sys/bus/hid/devices/*')):
        driver = os.path.join(dev, 'driver')
        if not os.path.islink(driver) or os.path.basename(os.path.realpath(driver)) != 'magicmouse':
            continue
        name = 'Magic device'
        # Prefer the power_supply model, so the label matches what other tools show.
        psdir = os.path.join(dev, 'power_supply')
        if os.path.isdir(psdir):
            for ps in sorted(os.listdir(psdir)):
                try:
                    with open(os.path.join(psdir, ps, 'model_name')) as fh:
                        name = fh.read().strip() or name
                    break
                except OSError:
                    pass
        else:
            try:
                with open(os.path.join(dev, 'uevent')) as fh:
                    for line in fh:
                        if line.startswith('HID_NAME='):
                            name = line.split('=', 1)[1].strip()
            except OSError:
                pass
        yield dev, name

def read_battery(hid_path):
    """Return (capacity, charging) or None if the report cannot be read."""
    hidraw_dir = os.path.join(hid_path, 'hidraw')
    if not os.path.isdir(hidraw_dir):
        return None
    for node in sorted(os.listdir(hidraw_dir)):
        buf = bytearray(3)
        buf[0] = REPORT_ID
        try:
            with open('/dev/' + node, 'rb+') as fh:
                fcntl.ioctl(fh, hidiocginput(len(buf)), buf)
        except (OSError, PermissionError):
            continue
        # A device that does not implement 0x90 echoes the id back with nothing after
        # it. Treat an out-of-range capacity as "no answer" rather than reporting it.
        if buf[0] != REPORT_ID or not 0 <= buf[2] <= 100:
            continue
        return buf[2], bool(buf[1] & CHARGING_BIT)
    return None

def main():
    tsv = '--tsv' in sys.argv[1:]
    rows = []
    for hid_path, name in magic_devices():
        result = read_battery(hid_path)
        if result is None:
            continue
        capacity, charging = result
        rows.append((capacity, 'Charging' if charging else 'Discharging', name))

    for capacity, status, name in rows:
        if tsv:
            print(f'{capacity}\t{status}\t{name}')
        else:
            print(f'{name}: {capacity}% ({status.lower()})')
    # No device, no permission, no 0x90 support: all exit 0 with no output, so a
    # status bar polling this simply shows nothing instead of breaking.
    return 0

if __name__ == '__main__':
    sys.exit(main())
