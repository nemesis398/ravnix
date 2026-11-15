// The verbs the gate answers itself, from sysfs: battery, charge-mode and
// power. Each reads a few attributes, never writes one, and prints a line
// per reading, "WHAT FIELD VALUE", where VALUE is the reading or what kept
// it from being one: absent, needs root, unreadable.
package ravnix_laptop_gate

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"

// The most a sysfs reading takes. An attribute is a page at most, and the
// ones read here are a number or a word; more than this is no reading.
MAX_VALUE :: 64

Reading :: struct {
	value: string,
	// What went wrong, when value is "".
	trouble: string,
}

// read_value reads one attribute, without its newline. It is a reading when
// it is printable ASCII of 1 to MAX_VALUE bytes.
read_value :: proc(path: string, allocator: runtime.Allocator) -> Reading {
	f, err := os.open(path)
	if err != nil {
		return {trouble = trouble_of(err)}
	}
	defer os.close(f)
	buf: [MAX_VALUE + 2]byte
	n := 0
	for n < len(buf) {
		got, rerr := os.read(f, buf[n:])
		if rerr != nil && rerr != io.Error.EOF {
			return {trouble = trouble_of(rerr)}
		}
		if got <= 0 {
			break
		}
		n += got
	}
	text := string(buf[:n])
	text = strings.trim_suffix(text, "\n")
	if len(text) == 0 || len(text) > MAX_VALUE {
		return {trouble = "unreadable"}
	}
	for c in transmute([]byte)text {
		if c < 0x20 || c >= 0x7f {
			return {trouble = "unreadable"}
		}
	}
	return {value = strings.clone(text, allocator)}
}

// trouble_of names what kept a file from being read.
trouble_of :: proc(err: os.Error) -> string {
	switch {
	case err == os.General_Error.Not_Exist:
		return "absent"
	case err == io.Error.Permission_Denied:
		return "needs root"
	}
	return "unreadable"
}

// is_number: an optional minus and at least one digit.
is_number :: proc(s: string) -> bool {
	digits := strings.trim_prefix(s, "-")
	if len(digits) == 0 {
		return false
	}
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// entries lists a directory's names, sorted, so the answer does not depend
// on the order the kernel lists them in. A directory that is not there has
// none.
entries :: proc(dir: string, allocator: runtime.Allocator) -> []string {
	infos, err := os.read_all_directory_by_path(dir, allocator)
	if err != nil {
		return nil
	}
	names := make([]string, len(infos), allocator)
	for info, i in infos {
		names[i] = info.name
	}
	slice.sort(names)
	return names
}

join :: proc(allocator: runtime.Allocator, parts: ..string) -> string {
	return strings.join(parts, "/", allocator)
}

// batteries are the laptop's own: the supplies of type Battery, but not the
// battery of a device (scope Device: a mouse's, a headset's), whose name
// can carry its Bluetooth address and is nothing the server needs.
batteries :: proc(root: string, allocator: runtime.Allocator) -> (dir: string, names: []string) {
	dir = join(allocator, root, "sys/class/power_supply")
	list := make([dynamic]string, allocator)
	for name in entries(dir, allocator) {
		if read_value(join(allocator, dir, name, "type"), allocator).value != "Battery" {
			continue
		}
		if read_value(join(allocator, dir, name, "scope"), allocator).value == "Device" {
			continue
		}
		append(&list, name)
	}
	return dir, list[:]
}

Field :: struct {
	name:    string,
	unit:    string,
	numeric: bool,
}

BATTERY_FIELDS :: [?]Field {
	{"status", "", false},
	{"capacity", "%", true},
	{"power_now", "uW", true},
	{"energy_now", "uWh", true},
	{"energy_full", "uWh", true},
	{"energy_full_design", "uWh", true},
	{"cycle_count", "", true},
}

write_reading :: proc(b: ^strings.Builder, what, field: string, r: Reading, unit := "", numeric := false) {
	r := r
	if r.value != "" && numeric && !is_number(r.value) {
		r = {trouble = "unreadable"}
	}
	fmt.sbprintf(b, "%s %s ", what, field)
	if r.value == "" {
		strings.write_string(b, r.trouble)
	} else {
		strings.write_string(b, r.value)
		if unit != "" {
			strings.write_byte(b, ' ')
			strings.write_string(b, unit)
		}
	}
	strings.write_byte(b, '\n')
}

// battery: the charge, the power and energy, and the cycles of each battery.
battery :: proc(root: string, allocator: runtime.Allocator) -> string {
	dir, names := batteries(root, allocator)
	if len(names) == 0 {
		return "no battery\n"
	}
	b := strings.builder_make(allocator)
	fields := BATTERY_FIELDS
	for name in names {
		what := escape(name, allocator)
		for field in fields {
			write_reading(&b, what, field.name, read_value(join(allocator, dir, name, field.name), allocator), field.unit, field.numeric)
		}
	}
	return strings.to_string(b)
}

// charge_mode: the active one of charge_types, the one in brackets, as
// charge-mode prints it, and nothing that would change it.
charge_mode :: proc(root: string, allocator: runtime.Allocator) -> string {
	dir, names := batteries(root, allocator)
	b := strings.builder_make(allocator)
	for name in names {
		path := join(allocator, dir, name, "charge_types")
		if !os.exists(path) {
			continue
		}
		mode := "unknown"
		r := read_value(path, allocator)
		open := strings.index_byte(r.value, '[')
		if open >= 0 {
			close := strings.index_byte(r.value[open:], ']')
			if close > 1 {
				candidate := r.value[open + 1:][:close - 1]
				ok := true
				for c in transmute([]byte)candidate {
					if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_') {
						ok = false
					}
				}
				if ok {
					mode = candidate
				}
			}
		}
		fmt.sbprintf(&b, "%s charge_types %s\n", escape(name, allocator), mode)
	}
	if strings.builder_len(b) == 0 {
		return "no battery with charge_types\n"
	}
	return strings.to_string(b)
}

NVIDIA :: "0x10de"

// power: the NVIDIA GPU's runtime power state, read from sysfs and never
// from its configuration space, which would wake it; the draw of each of
// the laptop's batteries (power_now); and the energy counter of the CPU
// package (each RAPL package zone), which the kernel gives to root alone:
// for the user it says `needs root`, and nothing here asks for more
// rights.
power :: proc(root: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	pci := join(allocator, root, "sys/bus/pci/devices")
	found := false
	for device in entries(pci, allocator) {
		if read_value(join(allocator, pci, device, "vendor"), allocator).value != NVIDIA {
			continue
		}
		class := read_value(join(allocator, pci, device, "class"), allocator).value
		// A VGA (0x0300) or 3D (0x0302) controller, not the card's audio.
		if !strings.has_prefix(class, "0x0300") && !strings.has_prefix(class, "0x0302") {
			continue
		}
		found = true
		what := strings.concatenate({"dGPU ", escape(device, allocator)}, allocator)
		write_reading(&b, what, "runtime_status", read_value(join(allocator, pci, device, "power/runtime_status"), allocator))
		write_reading(&b, what, "power_state", read_value(join(allocator, pci, device, "power_state"), allocator))
	}
	if !found {
		strings.write_string(&b, "dGPU none\n")
	}

	dir, names := batteries(root, allocator)
	for name in names {
		write_reading(&b, escape(name, allocator), "power_now", read_value(join(allocator, dir, name, "power_now"), allocator), "uW", true)
	}
	if len(names) == 0 {
		strings.write_string(&b, "battery none\n")
	}

	powercap := join(allocator, root, "sys/class/powercap")
	zones := 0
	for zone in entries(powercap, allocator) {
		// A zone is intel-rapl:0 (AMD's are named so as well); intel-rapl
		// alone is the control type, and intel-rapl:0:0 a subzone (core,
		// uncore) of the package, which the gate does not report.
		if !strings.contains_rune(zone, ':') {
			continue
		}
		name := read_value(join(allocator, powercap, zone, "name"), allocator)
		if !strings.has_prefix(name.value, "package-") {
			continue
		}
		zones += 1
		what := strings.concatenate({"RAPL ", escape(zone, allocator), " ", name.value}, allocator)
		write_reading(&b, what, "energy_uj", read_value(join(allocator, powercap, zone, "energy_uj"), allocator), numeric = true)
	}
	if zones == 0 {
		strings.write_string(&b, "RAPL none\n")
	}
	return strings.to_string(b)
}
