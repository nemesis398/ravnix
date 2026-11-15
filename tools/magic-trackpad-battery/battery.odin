package magic_trackpad_battery

import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"

// The report the device itself sends, HID input report 0x90:
//
//   byte 0   report id, 0x90
//   byte 1   status flags, bit 1 (0x02) = charging
//   byte 2   capacity, 0..100
REPORT_ID :: 0x90
CHARGING_BIT :: 0x02
REPORT_LEN :: 3

// The driver the devices are matched by. Matching on the DRIVER, not on a
// product name or id: it is stable across the two buses (Bluetooth
// 0005:004C:0324 and USB 0003:05AC:0324 both bind magicmouse) and across
// Apple renaming the product string, which they did for the 2024 model.
DRIVER :: "magicmouse"

// The label of a device that has neither a power_supply model nor a HID_NAME.
DEFAULT_NAME :: "Magic device"

// A label longer than this is cut. The kernel's names are far shorter; the cut
// keeps a hostile or broken sysfs from filling a status bar.
MAX_NAME_BYTES :: 256

// sysfs attributes are one page at most; a uevent can hold more lines than a
// model_name, but 64 KiB is far past any HID device's.
MAX_MODEL_BYTES :: 4096
MAX_UEVENT_BYTES :: 64 * 1024

Report :: [REPORT_LEN]u8

// A Reader asks the hidraw node at path for report 0x90 and fills report,
// whose first byte holds the id. It returns what the ioctl returned: the
// number of bytes of the report, or a negative number when the node cannot be
// opened or the ioctl fails. The command's reader is read_hidraw; the tests
// hand in a fake, because the build sandbox has no Apple device and no
// /dev/hidraw.
Reader :: proc(path: string, report: ^Report) -> int

Row :: struct {
	capacity: int,
	charging: bool,
	name:     string,
}

// ioc is the kernel's _IOC(dir, type, nr, size): the request number of an
// ioctl, from linux/ioctl.h's layout (nr in bits 0-7, type in 8-15, size in
// 16-29, direction in 30-31).
ioc :: proc(direction: u32, letter: u8, nr: u32, size: u32) -> u32 {
	return direction << 30 | size << 16 | u32(letter) << 8 | nr
}

// hidiocginput is HIDIOCGINPUT(len) of linux/hidraw.h: fetch an input report
// by id, without waiting for traffic. The direction is read and write: the
// first byte of the buffer carries the id in, the report comes out.
hidiocginput :: proc(length: u32) -> u32 {
	READ :: 2
	WRITE :: 1
	return ioc(READ | WRITE, 'H', 0x0A, length)
}

// read_hidraw is the Reader of the command: it opens the node and asks the
// kernel for report 0x90.
read_hidraw :: proc(path: string, report: ^Report) -> int {
	fd, oerr := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.RDWR, .CLOEXEC})
	if oerr != .NONE {
		return -int(oerr)
	}
	defer linux.close(fd)
	for {
		// A failed ioctl returns -errno, which as a uintptr is huge: int()
		// brings the sign back.
		ret := int(linux.ioctl(fd, hidiocginput(REPORT_LEN), uintptr(raw_data(report[:]))))
		if ret != -int(linux.Errno.EINTR) {
			return ret
		}
	}
}

// read_file reads up to limit bytes of the file at path. A file that is not
// there, cannot be read, or is a directory is no data. truncated says the file
// went past the limit.
read_file :: proc(path: string, limit: int) -> (data: []u8, ok: bool, truncated: bool) {
	fd, oerr := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC})
	if oerr != .NONE {
		return nil, false, false
	}
	defer linux.close(fd)
	buf := make([]u8, limit + 1)
	n := 0
	for n < len(buf) {
		got, rerr := linux.read(fd, buf[n:])
		if rerr == .EINTR {
			continue
		}
		if rerr != .NONE {
			return nil, false, false
		}
		if got == 0 {
			break
		}
		n += got
	}
	return buf[:min(n, limit)], true, n > limit
}

// list_dir is the names in the directory at path, sorted by bytes as Python's
// sorted() sorted them. A directory that is not there or cannot be read has
// none. The names come straight from getdents: os.read_all_directory_by_path
// also looks at each entry, and fails as a whole when one goes away while it
// reads, as the entries of /sys do.
list_dir :: proc(path: string) -> (names: []string, ok: bool) {
	fd, oerr := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.DIRECTORY, .CLOEXEC})
	if oerr != .NONE {
		return nil, false
	}
	defer linux.close(fd)
	out := make([dynamic]string)
	buf: [16 * 1024]u8
	for {
		n, gerr := linux.getdents(fd, buf[:])
		if gerr == .EINTR {
			continue
		}
		if gerr != .NONE {
			return nil, false
		}
		if n <= 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name != "." && name != ".." {
				append(&out, strings.clone(name))
			}
		}
	}
	slice.sort(out[:])
	return out[:], true
}

// driver_of is the name of the driver bound to the device at dev: the last
// part of where its "driver" link points. A device with no such link, which is
// no driver at all, has "". The link's target is not followed, so a driver
// that has gone from sysfs still names itself. The name is allocated.
driver_of :: proc(dev: string) -> string {
	buf: [4096]u8
	link := strings.concatenate({dev, "/driver"}, context.temp_allocator)
	n, err := linux.readlink(strings.clone_to_cstring(link, context.temp_allocator), buf[:])
	// A target that fills the buffer was cut and names nothing.
	if err != .NONE || n >= len(buf) {
		return ""
	}
	target := strings.trim_right(string(buf[:n]), "/")
	name := target[strings.last_index_byte(target, '/') + 1:]
	if name == "." || name == ".." {
		return ""
	}
	// The name points into buf, which goes with this procedure.
	return strings.clone(name)
}

// clean_name makes a device's label safe to print on one line and between
// tabs: bytes that are not UTF-8 become U+FFFD, control characters (C0, DEL
// and C1) become spaces, the label is trimmed and cut to MAX_NAME_BYTES at a
// character boundary. A label with nothing left is the default.
clean_name :: proc(name: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	for r in name {
		c := r
		if r < 0x20 || (r >= 0x7F && r < 0xA0) {
			c = ' '
		}
		if strings.builder_len(b) + utf8.rune_size(c) > MAX_NAME_BYTES {
			break
		}
		strings.write_rune(&b, c)
	}
	cleaned := strings.trim_space(strings.to_string(b))
	return cleaned if cleaned != "" else DEFAULT_NAME
}

// device_name is the label of the device at dev.
//
// The power_supply model is preferred, so the label matches what other tools
// show: the first power_supply directory, in name order, that has a model_name
// file decides, even when the model is empty (the default then stays). Only a
// device with no power_supply directory at all is labelled from the HID_NAME
// of its uevent, the last one if there are several.
device_name :: proc(dev: string) -> string {
	name := DEFAULT_NAME
	psdir := strings.concatenate({dev, "/power_supply"}, context.temp_allocator)
	if supplies, ok := list_dir(psdir); ok {
		for supply in supplies {
			path := strings.concatenate({psdir, "/", supply, "/model_name"}, context.temp_allocator)
			data, rok, _ := read_file(path, MAX_MODEL_BYTES)
			if !rok {
				continue
			}
			model := strings.trim_space(string(data))
			if model != "" {
				name = model
			}
			break
		}
		return clean_name(name)
	}
	uevent := strings.concatenate({dev, "/uevent"}, context.temp_allocator)
	data, ok, truncated := read_file(uevent, MAX_UEVENT_BYTES)
	if !ok {
		return name
	}
	text := string(data)
	if truncated {
		// The last line was cut in the middle; it says nothing.
		text = text[:strings.last_index_byte(text, '\n') + 1]
	}
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "HID_NAME=") {
			// An empty HID_NAME names nothing, and leaves what was there.
			if value := strings.trim_space(line[len("HID_NAME="):]); value != "" {
				name = value
			}
		}
	}
	return clean_name(name)
}

// read_battery asks the hidraw nodes of the device at dev, in name order, for
// the report, and returns the first answer that is one. A device with no
// hidraw node, or none that answers, has no battery to show.
read_battery :: proc(dev, dev_root: string, read: Reader) -> (capacity: int, charging: bool, ok: bool) {
	nodes, listed := list_dir(strings.concatenate({dev, "/hidraw"}, context.temp_allocator))
	if !listed {
		return 0, false, false
	}
	for node in nodes {
		report: Report
		report[0] = REPORT_ID
		path := strings.concatenate({dev_root, "/", node}, context.temp_allocator)
		// An error, or fewer than the three bytes asked for, is no answer: the
		// buffer then holds only what we put in, and reading it would report a
		// battery of 0 %.
		if read(path, &report) < REPORT_LEN {
			continue
		}
		// A device that does not implement 0x90 echoes the id back with nothing
		// after it. An out-of-range capacity is "no answer", not a number to show.
		if report[0] != REPORT_ID || report[2] > 100 {
			continue
		}
		return int(report[2]), report[1] & CHARGING_BIT != 0, true
	}
	return 0, false, false
}

// collect is every Magic device of the system under root ("" for the real
// one) that gave a battery level, in the order of the devices' names. A device
// without one is left out: no device, no permission and no report all give an
// empty list.
collect :: proc(root: string, read: Reader) -> []Row {
	devices := strings.concatenate({root, "/sys/bus/hid/devices"})
	dev_root := strings.concatenate({root, "/dev"})
	rows := make([dynamic]Row)
	names, _ := list_dir(devices)
	for entry in names {
		if strings.has_prefix(entry, ".") {
			continue
		}
		dev := strings.concatenate({devices, "/", entry}, context.temp_allocator)
		if driver_of(dev) != DRIVER {
			continue
		}
		capacity, charging, ok := read_battery(dev, dev_root, read)
		if !ok {
			continue
		}
		append(&rows, Row{capacity = capacity, charging = charging, name = device_name(dev)})
	}
	return rows[:]
}

// render is the rows as the command prints them: one line each, either
// "NAME: N% (charging|discharging)", or with tsv the tab-separated
// "N<TAB>Charging|Discharging<TAB>NAME" that a status bar splits.
render :: proc(rows: []Row, tsv: bool) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	for row in rows {
		status := "Charging" if row.charging else "Discharging"
		if tsv {
			strings.write_int(&b, row.capacity)
			strings.write_byte(&b, '\t')
			strings.write_string(&b, status)
			strings.write_byte(&b, '\t')
			strings.write_string(&b, row.name)
		} else {
			strings.write_string(&b, row.name)
			strings.write_string(&b, ": ")
			strings.write_int(&b, row.capacity)
			strings.write_string(&b, "% (")
			strings.write_string(&b, strings.to_lower(status, context.temp_allocator))
			strings.write_byte(&b, ')')
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
