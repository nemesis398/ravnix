// The tests of the guard's decision: which disk, if any, an installer may
// write. The check ravnix-disk-guard-tests runs them with a fixed seed and
// fails a test that leaks or frees badly, even when its assertions hold.
//
// Every model and serial here is made up. The fixtures copy the shape of
// the laptop's lsblk: two NVMe disks, one to install on (Example SSD 1TB)
// and one that holds the running system and must never be touched (Keep SSD
// 1TB), a USB stick, and zram.
package ravnix_disk_guard_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import guard ".."

TODAY :: #load("testdata/today.json")
SWAPPED :: #load("testdata/swapped.json")
SAME_MODEL :: #load("testdata/same-model.json")
TARGET_MOUNTED :: #load("testdata/target-mounted.json")
TARGET_LUKS_OPEN :: #load("testdata/target-luks-open.json")
NO_SERIAL_FIELD :: #load("testdata/no-serial-field.json")
OLD_LSBLK :: #load("testdata/old-lsblk.json")

MODEL :: "Example SSD 1TB"
SERIAL :: "EXAMPLE0SERIAL"
KEEP_MODEL :: "Keep SSD 1TB"
KEEP_SERIAL :: "KEEP0SERIAL"

// find parses data and looks for the disk with model and serial in it.
find :: proc(t: ^testing.T, data: []u8, model := MODEL, serial := SERIAL) -> (name: string, err: guard.Guard_Error) {
	list := guard.parse_lsblk(data)
	defer guard.device_list_destroy(&list)
	testing.expectf(t, list.why == "", "the fixture does not parse: %s", list.why)
	target: guard.Block_Device
	target, err = guard.find_target(list.devices, model, serial)
	// The name lives in the list's arena; a constant for the comparison.
	switch target.name {
	case "":
		name = ""
	case "nvme0n1":
		name = "nvme0n1"
	case "nvme1n1":
		name = "nvme1n1"
	case:
		name = "another device"
	}
	return
}

// why_refused parses data, which must not parse, and returns whether the
// reason holds want.
why_refused :: proc(t: ^testing.T, data: string, want: string) {
	list := guard.parse_lsblk(transmute([]u8)data)
	defer guard.device_list_destroy(&list)
	testing.expectf(t, list.why != "", "%q parsed, and must not", data)
	testing.expectf(t, len(list.devices) == 0, "%q: a refused list holds no device", data)
	testing.expectf(t, strings.contains(list.why, want), "%q: the reason %q does not say %q", data, list.why, want)
}

@(test)
finds_the_target_in_todays_layout :: proc(t: ^testing.T) {
	name, err := find(t, TODAY)
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme0n1")
}

@(test)
finds_the_target_when_the_kernel_names_are_swapped :: proc(t: ^testing.T) {
	// Review Focus 4: after this boot nvme0n1 is the disk to keep, and the
	// target is nvme1n1. The model and the serial still pick the target.
	name, err := find(t, SWAPPED)
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme1n1")
	// The disk to keep is found as itself, and refused, since it is in use.
	keep, keep_err := find(t, SWAPPED, KEEP_MODEL, KEEP_SERIAL)
	testing.expect_value(t, keep_err, guard.Guard_Error.In_Use)
	testing.expect_value(t, keep, "nvme0n1")
}

@(test)
refuses_two_disks_with_the_model_and_the_serial :: proc(t: ^testing.T) {
	name, err := find(t, SAME_MODEL)
	testing.expect_value(t, err, guard.Guard_Error.Many_Matches)
	testing.expect_value(t, name, "")
}

@(test)
the_serial_decides_between_disks_of_one_model :: proc(t: ^testing.T) {
	// Two disks of the target's model; only one has its serial.
	data := strings.join({
		`{"blockdevices": [`,
		`{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": "EXAMPLE1SERIAL", "mountpoints": [], "type": "disk"},`,
		`{"name": "nvme1n1", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "disk"}`,
		`]}`,
	}, "\n")
	defer delete(data)
	name, err := find(t, transmute([]u8)data)
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme1n1")
}

@(test)
refuses_the_model_of_one_disk_with_the_serial_of_another :: proc(t: ^testing.T) {
	_, err := find(t, TODAY, MODEL, KEEP_SERIAL)
	testing.expect_value(t, err, guard.Guard_Error.No_Match)
	_, err = find(t, TODAY, KEEP_MODEL, SERIAL)
	testing.expect_value(t, err, guard.Guard_Error.No_Match)
}

@(test)
matches_the_model_and_the_serial_exactly :: proc(t: ^testing.T) {
	near := [?][2]string{
		{"Example SSD", SERIAL},
		{"Example SSD 1TB ", SERIAL},
		{"example ssd 1tb", SERIAL},
		{"Example SSD 1TB2", SERIAL},
		{MODEL, "EXAMPLE0SERIA"},
		{MODEL, "EXAMPLE0SERIAL0"},
		{MODEL, "example0serial"},
		{MODEL, "XEXAMPLE0SERIAL"},
	}
	for pair in near {
		_, err := find(t, TODAY, pair[0], pair[1])
		testing.expectf(t, err == .No_Match, "%q, %q: got %v", pair[0], pair[1], err)
	}
}

@(test)
trims_the_white_space_lsblk_pads_with :: proc(t: ^testing.T) {
	// sysfs pads an NVMe model to 40 characters; an lsblk that passes the
	// padding on must still match.
	data := `{"blockdevices": [{"name": "nvme0n1", "model": "Example SSD 1TB                         ", "serial": "  EXAMPLE0SERIAL ", "mountpoints": [], "type": "disk"}]}`
	name, err := find(t, transmute([]u8)data)
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme0n1")
}

@(test)
refuses_a_target_with_a_mounted_partition :: proc(t: ^testing.T) {
	name, err := find(t, TARGET_MOUNTED)
	testing.expect_value(t, err, guard.Guard_Error.In_Use)
	testing.expect_value(t, name, "nvme0n1")

	list := guard.parse_lsblk(TARGET_MOUNTED)
	defer guard.device_list_destroy(&list)
	target, _ := guard.find_target(list.devices, MODEL, SERIAL)
	holder, mountpoint, busy := guard.in_use(target)
	testing.expect(t, busy)
	testing.expect_value(t, holder.name, "nvme0n1p3")
	testing.expect_value(t, mountpoint, "/run/media/alice/Data")
}

@(test)
refuses_a_target_with_an_open_luks_mapping :: proc(t: ^testing.T) {
	// Nothing is mounted, but cryptroot is open on the second partition.
	name, err := find(t, TARGET_LUKS_OPEN)
	testing.expect_value(t, err, guard.Guard_Error.In_Use)
	testing.expect_value(t, name, "nvme0n1")

	list := guard.parse_lsblk(TARGET_LUKS_OPEN)
	defer guard.device_list_destroy(&list)
	target, _ := guard.find_target(list.devices, MODEL, SERIAL)
	holder, mountpoint, busy := guard.in_use(target)
	testing.expect(t, busy)
	testing.expect_value(t, holder.name, "cryptroot")
	testing.expect_value(t, holder.type, "crypt")
	testing.expect_value(t, mountpoint, "")
}

@(test)
refuses_a_target_that_anything_holds_or_mounts :: proc(t: ^testing.T) {
	cases := [?]string{
		// Swap on a partition.
		`{"name": "nvme0n1p1", "model": null, "serial": null, "mountpoints": ["[SWAP]"], "type": "part"}`,
		// LVM, RAID and a device mapper target straight on a partition.
		`{"name": "nvme0n1p1", "model": null, "serial": null, "mountpoints": [], "type": "part", "children": [{"name": "vg-root", "model": null, "serial": null, "mountpoints": [], "type": "lvm"}]}`,
		`{"name": "nvme0n1p1", "model": null, "serial": null, "mountpoints": [], "type": "part", "children": [{"name": "md127", "model": null, "serial": null, "mountpoints": [], "type": "raid1"}]}`,
		// A mapping straight on the disk, without a partition.
		`{"name": "cryptroot", "model": null, "serial": null, "mountpoints": [], "type": "crypt"}`,
		// A mapping two levels down, mounted.
		`{"name": "nvme0n1p2", "model": null, "serial": null, "mountpoints": [], "type": "part", "children": [{"name": "cryptroot", "model": null, "serial": null, "mountpoints": [], "type": "crypt", "children": [{"name": "vg-home", "model": null, "serial": null, "mountpoints": ["/home"], "type": "lvm"}]}]}`,
	}
	for child in cases {
		data := fmt.aprintf(
			`{{"blockdevices": [{{"name": "nvme0n1", "model": "%s", "serial": "%s", "mountpoints": [], "type": "disk", "children": [%s]}}]}}`,
			MODEL, SERIAL, child,
		)
		defer delete(data)
		_, err := find(t, transmute([]u8)data)
		testing.expectf(t, err == .In_Use, "%s: got %v", child, err)
	}
	// The whole disk mounted, with no partition table.
	whole := `{"blockdevices": [{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": ["/mnt"], "type": "disk"}]}`
	_, err := find(t, transmute([]u8)whole)
	testing.expect_value(t, err, guard.Guard_Error.In_Use)
}

@(test)
takes_null_mountpoints_for_not_mounted :: proc(t: ^testing.T) {
	// util-linux before 2.39 prints [null] where newer ones print [].
	name, err := find(t, OLD_LSBLK)
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme0n1")
	_, keep_err := find(t, OLD_LSBLK, KEEP_MODEL, KEEP_SERIAL)
	testing.expect_value(t, keep_err, guard.Guard_Error.In_Use)
}

@(test)
looks_only_at_whole_disks :: proc(t: ^testing.T) {
	// A loop device, an optical drive and a partition that report the
	// target's model and serial are none of them the target.
	data := `{"blockdevices": [
		{"name": "loop0", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "loop"},
		{"name": "sr0", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "rom"},
		{"name": "sdb", "model": "Card Reader", "serial": "000000000002", "mountpoints": [], "type": "disk", "children": [
			{"name": "sdb1", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "part"}
		]}
	]}`
	_, err := find(t, transmute([]u8)data)
	testing.expect_value(t, err, guard.Guard_Error.No_Match)
}

@(test)
refuses_a_disk_without_a_serial :: proc(t: ^testing.T) {
	// A disk whose serial lsblk gives as null cannot be the target.
	data := `{"blockdevices": [{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": null, "mountpoints": [], "type": "disk"}]}`
	_, err := find(t, transmute([]u8)data)
	testing.expect_value(t, err, guard.Guard_Error.No_Match)
}

@(test)
refuses_lsblk_output_without_the_serial_field :: proc(t: ^testing.T) {
	// lsblk run without SERIAL in its columns: the guard cannot tell the
	// disks apart, so it refuses all of them and says why.
	list := guard.parse_lsblk(NO_SERIAL_FIELD)
	defer guard.device_list_destroy(&list)
	testing.expect(t, list.why != "")
	testing.expect_value(t, len(list.devices), 0)
	testing.expectf(t, strings.contains(list.why, "sda has no serial field"), "the reason: %s", list.why)
	testing.expectf(t, strings.contains(list.why, guard.LSBLK_COLUMNS), "the reason names the columns: %s", list.why)
}

@(test)
refuses_lsblk_output_without_any_other_field :: proc(t: ^testing.T) {
	why_refused(t, `{"blockdevices": [{"model": "M", "serial": "S", "mountpoints": [], "type": "disk"}]}`, "a device that has no name")
	why_refused(t, `{"blockdevices": [{"name": "sda", "serial": "S", "mountpoints": [], "type": "disk"}]}`, "sda has no model field")
	why_refused(t, `{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "type": "disk"}]}`, "sda has no mountpoints field")
	why_refused(t, `{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": []}]}`, "sda has no type field")
	// The singular column of util-linux before 2.37 is not the one asked for.
	why_refused(t, `{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoint": null, "type": "disk"}]}`, "sda has no mountpoints field")
	// A partition is checked as closely as a disk.
	why_refused(t, `{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": "disk", "children": [{"name": "sda1", "model": null, "mountpoints": [], "type": "part"}]}]}`, "sda1 has no serial field")
}

@(test)
refuses_empty_output :: proc(t: ^testing.T) {
	why_refused(t, "", "lsblk printed nothing")
	why_refused(t, " \n\t", "lsblk printed nothing")
	why_refused(t, "{}", "no blockdevices")
	why_refused(t, `{"blockdevices": []}`, "lists no block device")
	why_refused(t, `{"blockdevices": null}`, "no blockdevices")
}

@(test)
refuses_malformed_output_without_crashing :: proc(t: ^testing.T) {
	bad := [?]string{
		"{",
		"[]",
		"null",
		"42",
		`"nvme0n1"`,
		`{"blockdevices": {}}`,
		`{"blockdevices": [`,
		`{"blockdevices": [42]}`,
		`{"blockdevices": ["nvme0n1"]}`,
		`{"blockdevices": [{"name": 7, "model": "M", "serial": "S", "mountpoints": [], "type": "disk"}]}`,
		`{"blockdevices": [{"name": "", "model": "M", "serial": "S", "mountpoints": [], "type": "disk"}]}`,
		`{"blockdevices": [{"name": "sda", "model": 7, "serial": "S", "mountpoints": [], "type": "disk"}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": ["S"], "mountpoints": [], "type": "disk"}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": "/", "type": "disk"}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [7], "type": "disk"}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": null}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": ""}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": "disk", "children": {}}]}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": "disk", "children": [null]}]}`,
		// Two values, trailing bytes, and a NUL that the tokenizer would
		// take for the end of the input.
		`{"blockdevices": []} {}`,
		`{"blockdevices": [{"name": "sda", "model": "M", "serial": "S", "mountpoints": [], "type": "disk"}]} junk`,
		"{\"blockdevices\": [{\"name\": \"sda\", \"model\": \"M\", \"serial\": \"S\", \"mountpoints\": [], \"type\": \"disk\"}]}\x00junk",
		// A key twice: which serial would count?
		`{"blockdevices": [{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": "KEEP0SERIAL", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "disk"}]}`,
		// JSON5 is not what lsblk prints.
		`{blockdevices: []}`,
		"{\"blockdevices\": [],}",
		// An error message instead of the list.
		"lsblk: unknown column: MOUNTPOINTS",
	}
	for text in bad {
		list := guard.parse_lsblk(transmute([]u8)text)
		testing.expectf(t, list.why != "", "%q parsed, and must not", text)
		testing.expectf(t, len(list.devices) == 0, "%q: a refused list holds no device", text)
		guard.device_list_destroy(&list)
	}
}

@(test)
refuses_two_devices_of_one_name :: proc(t: ^testing.T) {
	// One kernel name, two disks: the by-id link could point at either.
	why_refused(
		t,
		`{"blockdevices": [{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "disk"}, {"name": "nvme0n1", "model": "Keep SSD 1TB", "serial": "KEEP0SERIAL", "mountpoints": ["/"], "type": "disk"}]}`,
		"nvme0n1 twice",
	)
}

@(test)
refuses_output_nested_deeper_than_any_device_tree :: proc(t: ^testing.T) {
	// The JSON parser recurses once per level; this would overflow the stack.
	deep := strings.concatenate({`{"blockdevices": `, strings.repeat("[", 200_000, context.temp_allocator), "]"})
	defer delete(deep)
	why_refused(t, deep, "nests deeper")
}

@(test)
refuses_output_larger_than_any_device_list :: proc(t: ^testing.T) {
	big := make([]u8, guard.MAX_LSBLK_BYTES + 1)
	defer delete(big)
	for &b in big {
		b = ' '
	}
	list := guard.parse_lsblk(big)
	defer guard.device_list_destroy(&list)
	testing.expectf(t, strings.contains(list.why, "more than"), "the reason: %s", list.why)
}

@(test)
finds_the_target_among_thousands_of_devices :: proc(t: ^testing.T) {
	// A host with 5000 loop devices and 2000 more disks, the target last.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"blockdevices": [`)
	for i in 0 ..< 5000 {
		fmt.sbprintf(&b, `{{"name": "loop%d", "model": null, "serial": null, "mountpoints": ["/var/lib/snapd/snap/%d"], "type": "loop"}},`, i, i)
	}
	for i in 0 ..< 2000 {
		fmt.sbprintf(&b, `{{"name": "sd%d", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL%d", "mountpoints": [], "type": "disk"}},`, i, i)
	}
	strings.write_string(&b, `{"name": "nvme0n1", "model": "Example SSD 1TB", "serial": "EXAMPLE0SERIAL", "mountpoints": [], "type": "disk"}]}`)
	name, err := find(t, b.buf[:])
	testing.expect_value(t, err, guard.Guard_Error.None)
	testing.expect_value(t, name, "nvme0n1")
}

@(test)
keeps_a_huge_value_without_trouble :: proc(t: ^testing.T) {
	// A model of 1 MiB parses, and matches nothing short.
	huge := strings.repeat("M", 1024 * 1024)
	defer delete(huge)
	data := fmt.aprintf(`{{"blockdevices": [{{"name": "sda", "model": "%s", "serial": "S", "mountpoints": [], "type": "disk"}}]}}`, huge)
	defer delete(data)
	_, err := find(t, transmute([]u8)data)
	testing.expect_value(t, err, guard.Guard_Error.No_Match)
}
