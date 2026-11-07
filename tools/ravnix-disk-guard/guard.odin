// ravnix-disk-guard picks the one disk an installer may write: the disk whose
// model and serial are both the ones the private flake names, with nothing
// on it mounted and no mapping holding it, by its /dev/disk/by-id path. Never
// by a kernel name such as nvme0n1, which can belong to the other disk after
// the next boot (README.md). It writes nothing anywhere. This file holds the
// decision; main.odin is the command and runs lsblk.
package ravnix_disk_guard

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

// lsblk's list for a laptop is a few KiB. The guard refuses more than this,
// which no real list is, so a runaway lsblk cannot fill the memory.
MAX_LSBLK_BYTES :: 4 * 1024 * 1024

// How deep the JSON may nest. Each level of lsblk's tree is two (an array and
// an object), and a real one is a disk, a partition, a crypt device and an
// LVM volume deep at most. The parser recurses once per level, so a list of a
// million brackets would otherwise overflow the stack.
MAX_DEPTH :: 64

// The columns the guard asks lsblk for, and the fields it reads.
LSBLK_COLUMNS :: "NAME,MODEL,SERIAL,MOUNTPOINTS,TYPE"

// One block device as `lsblk -J -o NAME,MODEL,SERIAL,MOUNTPOINTS,TYPE` lists
// it. The strings live in the arena of the Device_List that holds it.
Block_Device :: struct {
	// The kernel's name for it (nvme0n1, nvme0n1p3), or a mapping's name.
	name:        string,
	// As lsblk prints them, without surrounding white space; "" where lsblk
	// gives null, as for a partition or zram.
	model:       string,
	serial:      string,
	// disk, part, crypt, lvm, raid1, loop, rom and so on.
	type:        string,
	// Where it is mounted, "[SWAP]" for swap; empty when it is not.
	mountpoints: []string,
	children:    []Block_Device,
}

// The devices lsblk lists, or why its output is not such a list.
Device_List :: struct {
	// The top of lsblk's tree: the disks, loop devices, zram and so on.
	devices: []Block_Device,
	// Why the output is no device list, for the message; "" when it is one.
	why:     string,
	// Holds devices and why; device_list_destroy frees it.
	arena:   ^virtual.Arena,
}

// parse_lsblk reads lsblk's JSON. Every device must have every field the
// guard asks for: a list without serials could hide a second disk with the
// target's serial, so a missing field refuses the whole list, and so does
// anything else that is not what lsblk prints. The caller destroys the list
// with device_list_destroy, whether or not it parsed.
parse_lsblk :: proc(data: []u8) -> (list: Device_List) {
	list.arena = new(virtual.Arena)
	if list.arena == nil || virtual.arena_init_growing(list.arena) != nil {
		free(list.arena)
		list.arena = nil
		list.why = "there is no memory to read it"
		return
	}
	allocator := virtual.arena_allocator(list.arena)

	devices, why := parse_list(data, allocator)
	if why != "" {
		list.why = why
		return
	}
	list.devices = devices
	return
}

device_list_destroy :: proc(list: ^Device_List) {
	if list.arena != nil {
		virtual.arena_destroy(list.arena)
		free(list.arena)
	}
	list^ = {}
}

// parse_list does the work of parse_lsblk, everything in allocator.
@(private = "file")
parse_list :: proc(data: []u8, allocator: runtime.Allocator) -> (devices: []Block_Device, why: string) {
	context.allocator = allocator
	if len(data) > MAX_LSBLK_BYTES {
		return nil, "lsblk printed more than 4 MiB, which no device list is"
	}
	if slice.contains(data, 0) {
		// The JSON tokenizer would take a NUL for the end of the input and
		// ignore whatever follows it.
		return nil, "lsblk's output holds a NUL byte"
	}
	if len(strings.trim_space(string(data))) == 0 {
		return nil, "lsblk printed nothing"
	}
	if !nesting_within(data, MAX_DEPTH) {
		return nil, "lsblk's output nests deeper than any device tree"
	}

	// Strict JSON: lsblk prints nothing else, and JSON5 would let through
	// what it never prints.
	p := json.make_parser(data, .JSON, false, allocator)
	root, err := json.parse_value(&p)
	if err != .None {
		return nil, fmt.aprintf("lsblk's output is not JSON (%v)", err)
	}
	if p.curr_token.kind != .EOF {
		return nil, "lsblk's output holds more than one JSON value"
	}
	obj, is_object := root.(json.Object)
	if !is_object {
		return nil, "lsblk's output is no JSON object"
	}
	top, has_top := obj["blockdevices"].(json.Array)
	if !has_top {
		return nil, "lsblk's output has no blockdevices list"
	}
	if len(top) == 0 {
		return nil, "lsblk lists no block device"
	}
	devices, why = parse_devices(top)
	if why != "" {
		return nil, why
	}
	// A kernel name is one disk; with two, a link could point at either.
	seen := make(map[string]struct{}, len(devices))
	for d in devices {
		if d.name in seen {
			return nil, fmt.aprintf("lsblk lists %s twice", d.name)
		}
		seen[d.name] = {}
	}
	return
}

@(private = "file")
parse_devices :: proc(values: json.Array) -> (devices: []Block_Device, why: string) {
	devices = make([]Block_Device, len(values))
	for v, i in values {
		devices[i], why = parse_device(v)
		if why != "" {
			return nil, why
		}
	}
	return
}

@(private = "file")
parse_device :: proc(v: json.Value) -> (d: Block_Device, why: string) {
	obj, is_object := v.(json.Object)
	if !is_object {
		return {}, "lsblk lists a device that is no JSON object"
	}
	name, has_name := obj["name"].(json.String)
	if !has_name || name == "" {
		return {}, "lsblk lists a device that has no name"
	}
	d.name = name

	ok: bool
	if d.model, why = nullable_string(obj, name, "model"); why != "" {
		return
	}
	if d.serial, why = nullable_string(obj, name, "serial"); why != "" {
		return
	}
	type_value, has_type := obj["type"]
	if !has_type {
		return {}, missing_field(name, "type")
	}
	d.type, ok = type_value.(json.String)
	if !ok || d.type == "" {
		return {}, fmt.aprintf("%s has a type that is no name", name)
	}

	mounts_value, has_mounts := obj["mountpoints"]
	if !has_mounts {
		return {}, missing_field(name, "mountpoints")
	}
	mounts, is_array := mounts_value.(json.Array)
	if !is_array {
		return {}, fmt.aprintf("%s has mountpoints that are no list", name)
	}
	kept := make([dynamic]string, 0, len(mounts))
	for m in mounts {
		switch mv in m {
		case json.Null:
		// util-linux before 2.39 prints [null] for a device that is not
		// mounted.
		case json.String:
			append(&kept, mv)
		case json.Integer, json.Float, json.Boolean, json.Array, json.Object:
			return {}, fmt.aprintf("%s has a mountpoint that is neither a path nor null", name)
		}
	}
	d.mountpoints = kept[:]

	if children_value, has_children := obj["children"]; has_children {
		children, children_ok := children_value.(json.Array)
		if !children_ok {
			return {}, fmt.aprintf("%s has children that are no list", name)
		}
		if d.children, why = parse_devices(children); why != "" {
			return
		}
	}
	return
}

// nullable_string reads the field key of the device name: a string, trimmed,
// or null, which is "".
@(private = "file")
nullable_string :: proc(obj: json.Object, name, key: string) -> (s: string, why: string) {
	value, present := obj[key]
	if !present {
		return "", missing_field(name, key)
	}
	switch v in value {
	case json.Null:
		return "", ""
	case json.String:
		return strings.trim_space(v), ""
	case json.Integer, json.Float, json.Boolean, json.Array, json.Object:
	}
	return "", fmt.aprintf("%s has a %s that is neither a string nor null", name, key)
}

@(private = "file")
missing_field :: proc(name, key: string) -> string {
	return fmt.aprintf("%s has no %s field: run lsblk -J -o %s", name, key, LSBLK_COLUMNS)
}

// nesting_within reports whether the arrays and objects of the JSON text nest
// at most limit deep, counting brackets outside strings only.
nesting_within :: proc(text: []u8, limit: int) -> bool {
	depth := 0
	in_string, escaped := false, false
	for b in text {
		if in_string {
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				in_string = false
			}
			continue
		}
		switch b {
		case '"':
			in_string = true
		case '[', '{':
			depth += 1
			if depth > limit {
				return false
			}
		case ']', '}':
			depth -= 1
		}
	}
	return true
}

Guard_Error :: enum {
	None,
	// No disk has both the model and the serial.
	No_Match,
	// More than one disk has both, so neither is the one.
	Many_Matches,
	// The one disk that has both is mounted, or something on it is, or a
	// mapping holds it: an open LUKS volume, LVM, RAID, swap.
	In_Use,
}

// find_target finds the one whole disk (type disk) whose model and serial
// are model and serial, exactly, and checks that it is not in use. It returns
// the disk when it is the only match, in use or not. It allocates nothing and
// touches nothing shared.
find_target :: proc(devices: []Block_Device, model: string, serial: string) -> (Block_Device, Guard_Error) {
	target: Block_Device
	matches := 0
	for d in devices {
		if d.type == "disk" && d.model == model && d.serial == serial {
			target = d
			matches += 1
		}
	}
	switch matches {
	case 0:
		return {}, .No_Match
	case 1:
	case:
		return {}, .Many_Matches
	}
	if _, _, busy := in_use(target); busy {
		return target, .In_Use
	}
	return target, .None
}

// in_use reports whether disk is in use: mounted itself, or anything on it
// mounted (swap included), or anything on it that is not a partition, which
// is a mapping the kernel holds. holder is the device found so, and
// mountpoint where it is mounted, "" for a mapping.
in_use :: proc(disk: Block_Device) -> (holder: Block_Device, mountpoint: string, busy: bool) {
	if len(disk.mountpoints) > 0 {
		return disk, disk.mountpoints[0], true
	}
	for child in disk.children {
		if child.type != "part" {
			return child, "", true
		}
		if h, m, b := in_use(child); b {
			return h, m, b
		}
	}
	return {}, "", false
}

By_Id_Status :: enum {
	Ok,
	// The directory cannot be read, or a link in it.
	Unreadable,
	// No link names the serial and points at the disk.
	Not_Found,
	// A link names the serial and points somewhere else than the disk, or
	// than one of its partitions: the links disagree with lsblk.
	Conflict,
}

By_Id :: struct {
	status:    By_Id_Status,
	// dir/name of the link to print, when status is Ok.
	path:      string,
	// The link that conflicts, and the name it points at; or the link that
	// cannot be read.
	link:      string,
	points_at: string,
	os_error:  os.Error,
}

// find_by_id finds the link in dir, /dev/disk/by-id, that names serial and
// points at disk. A link names the serial when the serial stands in its name
// between an underscore and the name's end, an underscore or "-part", as udev
// writes them: nvme-<model>_<serial>, nvme-<model>_<serial>_<namespace>,
// and -partN after either for a partition. Of the links that name the whole
// disk, the first by name is printed, which is the one without the
// namespace when both exist. Any link that names the serial and points
// elsewhere refuses the lot. The strings of the result are allocated in
// allocator; by_id_destroy frees them.
find_by_id :: proc(dir: string, disk: Block_Device, serial: string, allocator := context.allocator) -> (r: By_Id) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		r.status = .Unreadable
		r.os_error = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	defer virtual.arena_destroy(&arena)
	scratch := virtual.arena_allocator(&arena)

	base := strings.trim_right(dir, "/")
	if base == "" {
		base = dir
	}
	entries, err := os.read_all_directory_by_path(dir, scratch)
	if err != nil {
		r.status, r.os_error = .Unreadable, err
		return
	}
	// The directory gives its entries in no fixed order.
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	chosen := ""
	for e in entries {
		if e.type != .Symlink {
			continue
		}
		names, part := names_serial(e.name, serial)
		if !names {
			continue
		}
		link := strings.concatenate({base, "/", e.name}, scratch)
		target, lerr := os.read_link(link, scratch)
		if lerr != nil {
			r.status, r.os_error = .Unreadable, lerr
			r.link = strings.clone(link, allocator)
			return
		}
		points_at := target[strings.last_index_byte(target, '/') + 1:]
		agrees := is_partition_of(disk, points_at) if part else (points_at == disk.name)
		if !agrees {
			r.status = .Conflict
			r.link = strings.clone(link, allocator)
			r.points_at = strings.clone(points_at, allocator)
			return
		}
		if !part && chosen == "" {
			chosen = link
		}
	}
	if chosen == "" {
		r.status = .Not_Found
		return
	}
	r.status, r.path = .Ok, strings.clone(chosen, allocator)
	return
}

by_id_destroy :: proc(r: By_Id, allocator := context.allocator) {
	delete(r.path, allocator)
	delete(r.link, allocator)
	delete(r.points_at, allocator)
}

// names_serial reports whether the link name names serial, and whether it
// is a partition's link (ends in -partN).
names_serial :: proc(name, serial: string) -> (names: bool, part: bool) {
	if serial == "" {
		return false, false
	}
	from := 0
	for from < len(name) {
		i := strings.index(name[from:], serial)
		if i < 0 {
			break
		}
		at := from + i
		after := name[at + len(serial):]
		if at > 0 && name[at - 1] == '_' && (after == "" || after[0] == '_' || strings.has_prefix(after, "-part")) {
			return true, is_partition_link(name)
		}
		from = at + 1
	}
	return false, false
}

// is_partition_link reports whether name ends in -partN, as udev names a
// partition's link.
is_partition_link :: proc(name: string) -> bool {
	i := strings.last_index(name, "-part")
	if i < 0 || i + len("-part") == len(name) {
		return false
	}
	for c in transmute([]u8)name[i + len("-part"):] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// is_partition_of reports whether name is a partition of disk.
is_partition_of :: proc(disk: Block_Device, name: string) -> bool {
	for child in disk.children {
		if child.type == "part" && child.name == name {
			return true
		}
	}
	return false
}

// What the guard decided, for the command.
Outcome :: struct {
	// The exit status: 0 the disk is found and free; 1 no single disk
	// matches, or the list or the links cannot be read or disagree; 2 the
	// disk is in use.
	code:    int,
	// The by-id path of the disk when code is 0, else "".
	path:    string,
	// One line for the operator: what the guard found, or why it refuses.
	// It names the target's serial, never another disk's.
	message: string,
}

// decide is the whole decision on lsblk's JSON and the links in by_id_dir.
// It allocates the outcome in allocator (outcome_destroy frees it) and
// touches nothing shared, so concurrent calls are safe.
decide :: proc(lsblk_json: []u8, model, serial, by_id_dir: string, allocator := context.allocator) -> (o: Outcome) {
	list := parse_lsblk(lsblk_json)
	defer device_list_destroy(&list)
	if list.why != "" {
		o.code = 1
		o.message = fmt.aprintf("cannot use lsblk's device list: %s", list.why, allocator = allocator)
		return
	}

	target, err := find_target(list.devices, model, serial)
	switch err {
	case .None:
	case .No_Match:
		o.code = 1
		o.message = describe_no_match(list.devices, model, serial, allocator)
		return
	case .Many_Matches:
		o.code = 1
		o.message = describe_many(list.devices, model, serial, allocator)
		return
	case .In_Use:
		holder, mountpoint, _ := in_use(target)
		o.code = 2
		if mountpoint != "" {
			o.message = fmt.aprintf(
				"%s (model %q, serial %q) is in use: %s is mounted at %s",
				target.name, model, serial, holder.name, mountpoint, allocator = allocator,
			)
		} else {
			o.message = fmt.aprintf(
				"%s (model %q, serial %q) is in use: %s on it is an active %s mapping",
				target.name, model, serial, holder.name, holder.type, allocator = allocator,
			)
		}
		return
	}

	r := find_by_id(by_id_dir, target, serial)
	defer by_id_destroy(r)
	switch r.status {
	case .Ok:
		o.code = 0
		o.path = strings.clone(r.path, allocator)
		o.message = fmt.aprintf(
			"%s is %s, model %q, serial %q: nothing on it is mounted and no mapping holds it",
			r.path, target.name, model, serial, allocator = allocator,
		)
	case .Unreadable:
		o.code = 1
		what := r.link if r.link != "" else by_id_dir
		o.message = fmt.aprintf("cannot read %s: %s", what, os.error_string(r.os_error), allocator = allocator)
	case .Not_Found:
		o.code = 1
		o.message = fmt.aprintf(
			"%s has model %q and serial %q, but no link in %s names that serial and points at it",
			target.name, model, serial, by_id_dir, allocator = allocator,
		)
	case .Conflict:
		o.code = 1
		o.message = fmt.aprintf(
			"%s names serial %q but points at %s, and lsblk says that serial is %s: the links disagree with lsblk",
			r.link, serial, r.points_at, target.name, allocator = allocator,
		)
	}
	return
}

outcome_destroy :: proc(o: Outcome, allocator := context.allocator) {
	delete(o.path, allocator)
	delete(o.message, allocator)
}

// describe_no_match names each disk lsblk lists with its model, and says
// whether its serial is the one asked for, without printing any other.
@(private = "file")
describe_no_match :: proc(devices: []Block_Device, model, serial: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "no disk has model %q and serial %q; the disks lsblk lists:", model, serial)
	disks := 0
	for d in devices {
		if d.type != "disk" {
			continue
		}
		disks += 1
		fmt.sbprintf(&b, "%s %s (", "," if disks > 1 else "", d.name)
		if d.model != "" {
			fmt.sbprintf(&b, "model %q", d.model)
		} else {
			strings.write_string(&b, "no model")
		}
		switch {
		case d.serial == "":
			strings.write_string(&b, ", no serial)")
		case d.serial == serial:
			strings.write_string(&b, ", the serial asked for)")
		case:
			strings.write_string(&b, ", another serial)")
		}
	}
	if disks == 0 {
		strings.write_string(&b, " none")
	}
	return strings.to_string(b)
}

@(private = "file")
describe_many :: proc(devices: []Block_Device, model, serial: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	names := 0
	for d in devices {
		if d.type == "disk" && d.model == model && d.serial == serial {
			names += 1
		}
	}
	fmt.sbprintf(&b, "%d disks have model %q and serial %q:", names, model, serial)
	i := 0
	for d in devices {
		if d.type == "disk" && d.model == model && d.serial == serial {
			fmt.sbprintf(&b, "%s %s", "," if i > 0 else "", d.name)
			i += 1
		}
	}
	strings.write_string(&b, "; the guard picks none of them")
	return strings.to_string(b)
}
