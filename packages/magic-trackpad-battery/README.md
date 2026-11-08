# magic-trackpad-battery

The true battery level of Apple Magic devices, read from the HID input report
0x90 that the device itself sends. Over Bluetooth the kernel's value is wrong
(it reads the status byte as the capacity, and shows 4 % on a full battery),
so a status bar that trusts `power_supply` shows a permanent false warning.
The script prints `NAME: N% (charging|discharging)`, or with `--tsv` the
tab-separated `N<TAB>Status<TAB>NAME`, and prints nothing and exits 0 when
there is no device, no permission or no report. Python, standard library
only, carried over from Fedora's `bin-magic-trackpad-battery` (AGENTS.md, rule
4). The docstring has the measurements.

Installed on the laptop by `modules/desktop/scripts.nix`. The udev rule that
lets it open the hidraw node is the peripherals module's (see below).

## Personal values

None.

## The udev rule

Reading the node needs a `uaccess` tag, which a udev rule sets. It is not in
this package or in the module that installs it
(`modules/desktop/scripts.nix`): the peripherals module
(`modules/desktop/peripherals.nix`) owns `60-magic-trackpad.rules`, with the
three hidraw lines this script needs (the `magicmouse` driver, and the
Bluetooth and USB ids) and the evdev lines of Fedora's file. This task's own
copy had the same three hidraw lines and nothing else, so it was dropped.
Without the rule the script exits quietly, as it does for any device it cannot
open.

## Changes from the original

- the shebang is gone (the package adds one), and the comment that named
  Fedora's script that installed the ACL names the module instead;
- flake8 ignores E501 (21 lines), E302 and E305 (one blank line where PEP 8
  wants two, 7 places) and E401 (two imports on one line): the original fails
  them and is left as it was.

## Left out

Nothing.

## Tests

`tests/magic-trackpad-battery.test.sh`, the check `bin-magic-trackpad-battery`.
The sandbox has no Apple device and no `/dev/hidraw`, so the functions are
loaded as a module against a fake sysfs and a fake `ioctl`: the ioctl number,
that devices are picked by driver and not by name, how they are labelled,
what a report of 100 %, a charging flag, 0 %, a capacity above 100, another
report id or an unopenable node gives, the first of several nodes that
answers, and the two output formats. The real command is run once for the
no-device case (not on a machine that has a trackpad connected).

## Findings not fixed

- A device that does not implement report 0x90 and answers with the id and
  two zero bytes reads as 0 %, not as "no answer": the filter in the script
  only rejects a capacity above 100, although its comment says the echo of
  the id alone is treated as no answer.
