// The command: magic-trackpad-battery [--tsv] [--root DIR]. README.md has why
// it exists and what it does not do.
//
// WHY THIS EXISTS
//
// The kernel's hid_magicmouse driver implements battery reporting only over
// USB. Over Bluetooth the value in /sys/class/power_supply is wrong, and wrong
// in a specific, reproducible way. Measured 2026-09-04, pad connected over
// Bluetooth:
//
//     HID report 0x90 : 90 04 64      byte 1 = 0x04 flags, byte 2 = 0x64 = 100%
//     kernel reports  : 4%
//
// The kernel reports 4 while the flags byte is 0x04 and the real capacity is
// 0x64. It is reading the STATUS byte as the capacity, one byte short of the
// right offset. So the sysfs value is not merely stale or coarse, it is a
// different field entirely, and it reads alarmingly low on a full battery.
// Anything trusting power_supply (waybar, upower, GNOME) therefore shows a
// permanent false low-battery warning.
//
// The device itself reports the truth as HID input report 0x90 (battery.odin).
// Reading it needs access to the hidraw node, granted by the uaccess udev rule
// that modules/desktop/peripherals.nix installs. Without that rule this exits
// quietly rather than printing a number it could not verify.
//
// DELIBERATELY NO FALLBACK to the sysfs value: a confidently wrong percentage
// is worse than no percentage, because it trains you to ignore the warning
// that matters.
package magic_trackpad_battery

import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"

USAGE :: `usage: magic-trackpad-battery [--tsv] [--root DIR]

Prints the true battery level of the Apple Magic devices (the ones the
magicmouse driver binds), read from the HID input report 0x90 that the device
itself sends. One line each:

  Magic Trackpad: 100% (discharging)

  --tsv       print N<TAB>Charging|Discharging<TAB>NAME instead, for a status bar
  --root DIR  read /sys and /dev under DIR
  -h, --help  print this

Nothing is printed, and the exit status is 0, when there is no device, no
permission to open its hidraw node or no report: a status bar that polls this
shows nothing and does not break. There is no fallback to the kernel's value,
which over Bluetooth is wrong. Other arguments are ignored. Exit status: 0;
1 no memory; 2 bad usage.`

// run is the whole command, for the arguments after the program's name. read
// asks a hidraw node for the report (read_hidraw is the real one). It writes to
// out and err and returns the exit status.
run :: proc(args: []string, read: Reader, out, err: io.Writer) -> int {
	// Everything the run allocates goes into one arena, freed at its end.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.wprintln(err, "magic-trackpad-battery: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	tsv := false
	root := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			fmt.wprintln(out, USAGE)
			return 0
		case "--tsv":
			tsv = true
		case "--root":
			if i + 1 >= len(args) {
				fmt.wprintln(err, "magic-trackpad-battery: --root needs a value")
				fmt.wprintln(err, "run magic-trackpad-battery --help for the usage")
				return 2
			}
			i += 1
			root = args[i]
		}
	}
	// No device, no permission, no 0x90 support: all print nothing and exit 0.
	io.write_string(out, render(collect(root, read), tsv))
	return 0
}

main :: proc() {
	os.exit(run(os.args[1:], read_hidraw, os.to_writer(os.stdout), os.to_writer(os.stderr)))
}
