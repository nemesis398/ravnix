// The verbs that the gate answers from sysfs itself: battery, charge-mode and
// power, against a fixture of the files the kernel has.
package ravnix_laptop_gate_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import gate ".."

LAPTOP_BATTERY :: `BAT0 status Discharging
BAT0 capacity 80 %
BAT0 power_now 9512000 uW
BAT0 energy_now 60000000 uWh
BAT0 energy_full 70000000 uWh
BAT0 energy_full_design 75000000 uWh
BAT0 cycle_count 42
`

@(test)
battery_reads_each_reading_of_each_battery :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	testing.expect_value(t, gate.battery(f.root, context.allocator), LAPTOP_BATTERY)
	// A second battery comes after the first, whatever order the directory
	// lists them in. A supply that is no battery (AC, USB) is left out, and
	// so is the battery of a device (scope Device: a mouse's, a headset's),
	// whose name can carry the device's Bluetooth address.
	write(t, &f, "sys/class/power_supply/BAT1/type", "Battery\n")
	write(t, &f, "sys/class/power_supply/BAT1/capacity", "100\n")
	write(t, &f, "sys/class/power_supply/BAT1/scope", "System\n")
	write(t, &f, "sys/class/power_supply/hid-00:11:22:33:44:55-battery-1/type", "Battery\n")
	write(t, &f, "sys/class/power_supply/hid-00:11:22:33:44:55-battery-1/scope", "Device\n")
	write(t, &f, "sys/class/power_supply/hid-00:11:22:33:44:55-battery-1/capacity", "88\n")
	write(t, &f, "sys/class/power_supply/ucsi-source-psy-1/type", "USB\n")
	out := gate.battery(f.root, context.allocator)
	testing.expectf(t, strings.has_prefix(out, LAPTOP_BATTERY), "%s", out)
	testing.expectf(t, strings.has_suffix(out, "BAT1 capacity 100 %\nBAT1 power_now absent\nBAT1 energy_now absent\nBAT1 energy_full absent\nBAT1 energy_full_design absent\nBAT1 cycle_count absent\n"), "%s", out)
	testing.expectf(t, !strings.contains(out, "AC ") && !strings.contains(out, "ucsi") && !strings.contains(out, "hid-"), "%s", out)
}

@(test)
battery_says_what_it_cannot_read :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	ps :: "sys/class/power_supply/BAT0/"
	write(t, &f, ps + "type", "Battery\n")
	// A number that is none, a reading with an escape sequence, one far too
	// long for a reading, one empty, and some that are not there.
	write(t, &f, ps + "capacity", "8a0\n")
	write(t, &f, ps + "status", "Dis\x1b[2Jcharging\n")
	write(t, &f, ps + "power_now", strings.repeat("9", 1 << 20))
	write(t, &f, ps + "energy_now", "")
	// Some drivers say -1 for a count they do not know, and a negative power
	// for a battery that discharges.
	write(t, &f, ps + "cycle_count", "-1\n")
	write(t, &f, ps + "energy_full_design", "-")
	write(t, &f, ps + "energy_full", "70000000\n")
	if can_deny() {
		unreadable(t, &f, ps + "energy_full")
	}
	out := gate.battery(f.root, context.allocator)
	want := strings.join({
		"BAT0 status unreadable",
		"BAT0 capacity unreadable",
		"BAT0 power_now unreadable",
		"BAT0 energy_now unreadable",
		"BAT0 energy_full needs root" if can_deny() else "BAT0 energy_full 70000000 uWh",
		"BAT0 energy_full_design unreadable",
		"BAT0 cycle_count -1",
		"",
	}, "\n")
	testing.expect_value(t, out, want)
}

@(test)
battery_says_when_there_is_none :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	// No power_supply class at all (a VM), and one with AC alone.
	testing.expect_value(t, gate.battery(f.root, context.allocator), "no battery\n")
	write(t, &f, "sys/class/power_supply/AC/type", "Mains\n")
	testing.expect_value(t, gate.battery(f.root, context.allocator), "no battery\n")
	// A supply without a type is no battery either.
	write(t, &f, "sys/class/power_supply/odd/capacity", "50\n")
	testing.expect_value(t, gate.battery(f.root, context.allocator), "no battery\n")
}

@(test)
battery_never_prints_a_strange_name_raw :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	write(t, &f, "sys/class/power_supply/BAT\x1b[2J/type", "Battery\n")
	out := gate.battery(f.root, context.allocator)
	testing.expectf(t, !strings.contains(out, "\x1b") && strings.has_prefix(out, `BAT\x1b[2J status absent`), "%q", out)
}

@(test)
charge_mode_reads_the_active_mode_only :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	testing.expect_value(t, gate.charge_mode(f.root, context.allocator), "BAT0 charge_types Standard\n")
	path := "sys/class/power_supply/BAT0/charge_types"
	for c in ([][2]string{
		{"[Fast] Standard Long_Life\n", "Fast"},
		{"Fast Standard [Long_Life]\n", "Long_Life"},
		// Nothing bracketed, a bracket that is never closed, an empty one,
		// and one with what no mode has: no mode.
		{"Fast Standard Long_Life\n", "unknown"},
		{"Fast [Standard Long_Life\n", "unknown"},
		{"Fast [] Long_Life\n", "unknown"},
		{"[Fa;st] Standard\n", "unknown"},
		{"[Fa\x1bst] Standard\n", "unknown"},
		{"", "unknown"},
	}) {
		write(t, &f, path, c[0])
		testing.expect_value(t, gate.charge_mode(f.root, context.allocator), strings.concatenate({"BAT0 charge_types ", c[1], "\n"}))
	}
	// What it read is what is there: it writes nothing.
	write(t, &f, path, "Fast [Standard] Long_Life\n")
	_ = gate.charge_mode(f.root, context.allocator)
	testing.expect_value(t, gate.battery(f.root, context.allocator), LAPTOP_BATTERY)
}

@(test)
charge_mode_says_when_no_battery_has_one :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	testing.expect_value(t, gate.charge_mode(f.root, context.allocator), "no battery with charge_types\n")
	write(t, &f, "sys/class/power_supply/BAT0/type", "Battery\n")
	testing.expect_value(t, gate.charge_mode(f.root, context.allocator), "no battery with charge_types\n")
}

LAPTOP_POWER :: `dGPU 0000:01:00.0 runtime_status suspended
dGPU 0000:01:00.0 power_state D3cold
BAT0 power_now 9512000 uW
`

@(test)
power_reads_the_dgpu_the_battery_s_draw_and_says_the_cpu_package_needs_root :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	laptop(t, &f)
	out := gate.power(f.root, context.allocator)
	// The CPU package's counter is root's alone: said to be, never read
	// with more rights. Its subzone (core) is no reading of the gate's.
	want := strings.concatenate({LAPTOP_POWER, "RAPL intel-rapl:0 package-0 energy_uj needs root\n" if can_deny() else "RAPL intel-rapl:0 package-0 energy_uj 123456789\n"})
	testing.expect_value(t, out, want)
	// Where the kernel lets the user read it, it is the reading.
	write(t, &f, "sys/class/powercap/intel-rapl:1/name", "package-1\n")
	write(t, &f, "sys/class/powercap/intel-rapl:1/energy_uj", "777\n")
	out = gate.power(f.root, context.allocator)
	testing.expectf(t, strings.has_suffix(out, "RAPL intel-rapl:1 package-1 energy_uj 777\n"), "%s", out)
	testing.expectf(t, !strings.contains(out, "core"), "%s", out)
	// And power runs nothing: no helper, no sudo, nothing in the gate's place.
	cfg := laptop_config(&f, "power")
	r := gate.decide(cfg, context.allocator)
	testing.expect_value(t, r.exec.path, "")
	testing.expect_value(t, r.status, 0)
}

@(test)
power_says_when_there_is_no_dgpu_and_no_rapl :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	testing.expect_value(t, gate.power(f.root, context.allocator), "dGPU none\nbattery none\nRAPL none\n")
	// An AMD GPU alone, the control type of powercap and a zone that is no
	// package, and a mouse's battery.
	write(t, &f, "sys/bus/pci/devices/0000:05:00.0/vendor", "0x1002\n")
	write(t, &f, "sys/bus/pci/devices/0000:05:00.0/class", "0x030000\n")
	write(t, &f, "sys/class/powercap/intel-rapl/enabled", "1\n")
	write(t, &f, "sys/class/powercap/intel-rapl:0:0/name", "core\n")
	write(t, &f, "sys/class/powercap/intel-rapl:0:0/energy_uj", "4242\n")
	write(t, &f, "sys/class/power_supply/hidpp_battery_0/type", "Battery\n")
	write(t, &f, "sys/class/power_supply/hidpp_battery_0/scope", "Device\n")
	testing.expect_value(t, gate.power(f.root, context.allocator), "dGPU none\nbattery none\nRAPL none\n")
}

@(test)
power_says_what_it_cannot_read :: proc(t: ^testing.T) {
	f: Fixture
	fixture(t, &f)
	defer done(&f)
	context.allocator = virtual.arena_allocator(&f.arena)
	pci :: "sys/bus/pci/devices/0000:01:00.0/"
	// A 3D controller (0x0302) is a GPU too; without runtime PM it has no
	// power directory.
	write(t, &f, pci + "vendor", "0x10de\n")
	write(t, &f, pci + "class", "0x030200\n")
	write(t, &f, "sys/class/powercap/intel-rapl:0/name", "package-0\n")
	write(t, &f, "sys/class/powercap/intel-rapl:0/energy_uj", "12x\n")
	// A battery without power_now, and one whose reading is no number.
	write(t, &f, "sys/class/power_supply/BAT0/type", "Battery\n")
	write(t, &f, "sys/class/power_supply/BAT1/type", "Battery\n")
	write(t, &f, "sys/class/power_supply/BAT1/power_now", "fast\n")
	out := gate.power(f.root, context.allocator)
	testing.expect_value(t, out, "dGPU 0000:01:00.0 runtime_status absent\ndGPU 0000:01:00.0 power_state absent\nBAT0 power_now absent\nBAT1 power_now unreadable\nRAPL intel-rapl:0 package-0 energy_uj unreadable\n")
}
