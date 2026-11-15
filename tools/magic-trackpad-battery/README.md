# magic-trackpad-battery

The true battery level of Apple Magic devices, read from the HID input report
0x90 that the device itself sends. Over Bluetooth the kernel's value is wrong
(it reads the status byte as the capacity, and shows 4 % on a full battery),
so a status bar that trusts `power_supply` shows a permanent false warning.
`main.odin` has the measurement.

```sh
magic-trackpad-battery [--tsv] [--root DIR]
```

It prints `NAME: N% (charging|discharging)`, or with `--tsv` the
tab-separated `N<TAB>Charging|Discharging<TAB>NAME` that
`waybar-peripherals` splits, one line per device. It prints nothing and exits
0 when there is no device, no permission or no report, so a status bar that
polls it shows nothing instead of breaking. Ported from the Python script
that came over from Fedora's `bin-magic-trackpad-battery` (AGENTS.md, rule 4):
the same cases passed on both (`testdata/cases.txt`).

Installed on the laptop by `modules/desktop/scripts.nix`. The udev rule that
lets it open the hidraw node is the peripherals module's (see below).

## Personal values

None.

## What it does

- **Picks devices by driver.** Every HID device in `/sys/bus/hid/devices`
  whose `driver` link points to `magicmouse`, not by product name or id. It
  holds for Bluetooth (`0005:004C:0324`) and USB (`0003:05AC:0324`) alike and
  survives Apple renaming the product, which they did for the 2024 model.
  The link is read, not followed.
- **Asks the hidraw nodes of a device in name order**, as strings (so
  `hidraw10` comes before `hidraw9`, as it did in Python), with
  `HIDIOCGINPUT(3)` on `/dev/NODE` opened read and write. The first node
  that gives a report of id 0x90 with a capacity of at most 100 decides.
  A node that cannot be opened, whose ioctl fails, or that answers with
  another id or a capacity above 100 is skipped; a device with no answer is
  left out.
- **Labels a device** with the `model_name` of its first power_supply that
  has one (so the label matches what other tools show), else with the last
  `HID_NAME` of its uevent, else `Magic device`.
- **Has no fallback to the sysfs value, on purpose.** A confidently wrong
  percentage is worse than none, because it trains you to ignore the warning
  that matters.
- **Takes `--root DIR`** to read `/sys` and `/dev` under DIR; the tests and the
  bench use it. Other arguments are ignored, as they always were, so a caller
  that passes one still gets its answer. `--help` prints the usage.

## The udev rule

Reading the node needs a `uaccess` tag, which a udev rule sets. It is not in
this package or in the module that installs it
(`modules/desktop/scripts.nix`): the peripherals module
(`modules/desktop/peripherals.nix`) owns `60-magic-trackpad.rules`, with the
three hidraw lines this tool needs (the `magicmouse` driver, and the
Bluetooth and USB ids) and the evdev lines of Fedora's file. Without the rule
the tool exits quietly, as it does for any device it cannot open.

## Changes from the Python

- An ioctl that returns fewer than the three bytes asked for is no answer.
  The Python ignored the count, so a short read left the buffer as it was put
  in (`90 00 00`) and showed 0 %. On a real trackpad over Bluetooth the
  ioctl returns 3.
- A label is made safe to print: bytes that are not UTF-8 become U+FFFD
  (the Python raised `UnicodeDecodeError` and printed a traceback), control
  characters, including a tab or a line break, become spaces (they split a
  `--tsv` field), and a label is cut at 256 bytes. An empty `HID_NAME` leaves
  the default label (the Python printed an empty one).
- `--root DIR` and `--help` are new.
- The files it reads are bounded: 4 KiB for a `model_name`, 64 KiB for a
  uevent, whose last line is dropped when the file went past that.
- A `power_supply` or a `uevent` that is not what it should be (a file where
  a directory belongs, a directory where a file belongs) is skipped as an
  unreadable one, as the Python skipped an `OSError`.

## Tests

`tests/` is the Odin package that `magic-trackpad-battery-tests` runs, and
`testdata/cases.txt` is the table of cases it runs (the format is in its
header): a fake sysfs and `/dev` under a temporary root, the answers the
hidraw nodes give, the arguments and the output. The cases without `new:` also
ran against the Python tool through a harness, and passed on it first. The
fake reader stands in for the ioctl, because the build sandbox has no Apple
device and no `/dev/hidraw`. Beside the cases are the ioctl number, the real
reader on files that are no hidraw node, the name cleaning, huge and
malformed sysfs files, a system that is not there, a thousand devices and
three runs at once on one tree.

`tests/bin/magic-trackpad-battery/cli.test.sh`, the check
`bin-magic-trackpad-battery`, runs the built program for what only it shows:
its exit status and streams, with the real ioctl, on a machine with no device
and on a fake sysfs whose nodes are plain files. It is not run for the
no-device cases of the real system on a machine that has a trackpad
connected. On the real trackpad it printed the same line as the Python.

## Bench

The bench reads the fake system in `bench/root` (five HID devices, three of
them bound to `magicmouse`, with a power_supply model or a uevent name) with
`--tsv`. The nodes in `bench/root/dev` are plain files, so the ioctl fails and
the bench counts the enumeration, the driver check and the ioctl attempts, not
the report parsing, which is a few instructions. A bench cannot fake a hidraw
node.

## Findings not fixed

- A device that does not implement report 0x90 and answers with the id and
  two zero bytes reads as 0 %, not as "no answer". The device's own answer
  cannot be told from a battery at 0 % with nothing charging, so the filter
  only rejects a capacity above 100, as the Python did, although the Python's
  comment said the echo of the id alone was treated as no answer.
- The ioctl count is checked against 3 on the strength of one device, the
  Bluetooth trackpad. A device that returns another count for the same
  report on USB would be skipped.
- The ioctl can wait for the device: over Bluetooth the kernel asks the pad
  and waits for the answer, once per node, and the tool sets no timeout of
  its own. `waybar-peripherals` calls it in line, so a pad that does not
  answer holds the module's poll until the kernel gives up.
