// The tests of the by-id lookup: the path the guard prints is a link in
// /dev/disk/by-id that names the target's serial and points at the disk
// lsblk matched, and every link that names the serial agrees with lsblk.
// Each test lays out its own link directory under TMPDIR; the links point
// at kernel names that need not exist, as udev's do (../../nvme0n1).
package ravnix_disk_guard_tests

import "core:os"
import "core:strings"
import "core:testing"
import guard ".."

Link :: struct {
	name:   string,
	target: string,
}

// The links udev makes for today's layout: by model and serial, the same
// with the namespace appended, by EUI, and one per partition of each.
today_links := [?]Link{
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL", "../../nvme0n1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1", "../../nvme0n1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part1", "../../nvme0n1p1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part2", "../../nvme0n1p2"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part3", "../../nvme0n1p3"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part4", "../../nvme0n1p4"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1-part1", "../../nvme0n1p1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1-part2", "../../nvme0n1p2"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1-part3", "../../nvme0n1p3"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1-part4", "../../nvme0n1p4"},
	{"nvme-eui.0000000000000001", "../../nvme0n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL", "../../nvme1n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL_1", "../../nvme1n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part1", "../../nvme1n1p1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part2", "../../nvme1n1p2"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part3", "../../nvme1n1p3"},
	{"nvme-eui.0000000000000002", "../../nvme1n1"},
	{"dm-name-luks-00000000-0000-4000-8000-000000000000", "../../dm-0"},
	{"dm-uuid-CRYPT-LUKS2-00000000000040008000000000000000-luks-00000000-0000-4000-8000-000000000000", "../../dm-0"},
	{"usb-Generic_MassStorageClass_000000000001-0:0", "../../sda"},
	{"usb-Generic_MassStorageClass_000000000001-0:0-part1", "../../sda1"},
	{"usb-Generic_MassStorageClass_000000000001-0:0-part2", "../../sda2"},
}

// The same links after a boot that swapped the kernel names.
swapped_links := [?]Link{
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL", "../../nvme1n1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1", "../../nvme1n1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part1", "../../nvme1n1p1"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part2", "../../nvme1n1p2"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part3", "../../nvme1n1p3"},
	{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part4", "../../nvme1n1p4"},
	{"nvme-eui.0000000000000001", "../../nvme1n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL", "../../nvme0n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL_1", "../../nvme0n1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part1", "../../nvme0n1p1"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part2", "../../nvme0n1p2"},
	{"nvme-Keep_SSD_1TB_KEEP0SERIAL-part3", "../../nvme0n1p3"},
	{"nvme-eui.0000000000000002", "../../nvme0n1"},
}

TARGET_LINK :: "nvme-Example_SSD_1TB_EXAMPLE0SERIAL"

// A scratch directory under TMPDIR, removed by the caller.
scratch_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "disk-guard-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	return dir
}

// make_links lays out links in dir/by-id and returns that directory.
make_links :: proc(t: ^testing.T, dir: string, links: []Link) -> string {
	by_id := strings.concatenate({dir, "/by-id"})
	testing.expect_value(t, os.make_directory(by_id), nil)
	for l in links {
		path := strings.concatenate({by_id, "/", l.name})
		defer delete(path)
		testing.expect_value(t, os.symlink(l.target, path), nil)
	}
	return by_id
}

// lookup parses data, finds the target and looks it up in by_id.
lookup :: proc(t: ^testing.T, data: []u8, by_id: string, serial := SERIAL) -> (r: guard.By_Id) {
	list := guard.parse_lsblk(data)
	defer guard.device_list_destroy(&list)
	target, err := guard.find_target(list.devices, MODEL, serial)
	testing.expect_value(t, err, guard.Guard_Error.None)
	return guard.find_by_id(by_id, target, serial)
}

expect_path :: proc(t: ^testing.T, r: guard.By_Id, by_id: string, name: string, loc := #caller_location) {
	want := strings.concatenate({by_id, "/", name})
	defer delete(want)
	testing.expect_value(t, r.status, guard.By_Id_Status.Ok, loc = loc)
	testing.expect_value(t, r.path, want, loc = loc)
}

@(test)
prints_the_by_id_path_of_the_target_in_todays_layout :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	// The name without the namespace, the shorter of the two that name the
	// whole disk, and never the EUI or a partition.
	expect_path(t, r, by_id, TARGET_LINK)
}

@(test)
prints_the_same_path_when_the_kernel_names_are_swapped :: proc(t: ^testing.T) {
	// Review Focus 4, end to end: lsblk and udev both swapped.
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, swapped_links[:])
	defer delete(by_id)

	r := lookup(t, SWAPPED, by_id)
	defer guard.by_id_destroy(r)
	expect_path(t, r, by_id, TARGET_LINK)
}

@(test)
refuses_links_that_disagree_with_lsblk :: proc(t: ^testing.T) {
	// lsblk from after the swap, links from before it: the link that names
	// the serial points at nvme0n1, which lsblk says is the disk to keep.
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := lookup(t, SWAPPED, by_id)
	defer guard.by_id_destroy(r)
	testing.expect_value(t, r.status, guard.By_Id_Status.Conflict)
	testing.expect_value(t, r.path, "")
	testing.expect(t, r.link != "")
	testing.expect_value(t, r.points_at, "nvme0n1")
}

@(test)
refuses_a_partition_link_that_points_elsewhere :: proc(t: ^testing.T) {
	links := [?]Link{
		{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL", "../../nvme0n1"},
		{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL-part1", "../../nvme1n1p1"},
	}
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, links[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	testing.expect_value(t, r.status, guard.By_Id_Status.Conflict)
	testing.expect_value(t, r.points_at, "nvme1n1p1")
}

@(test)
takes_the_namespace_link_when_it_is_the_only_one :: proc(t: ^testing.T) {
	links := [?]Link{
		{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1", "../../nvme0n1"},
		{"nvme-eui.0000000000000001", "../../nvme0n1"},
	}
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, links[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	expect_path(t, r, by_id, "nvme-Example_SSD_1TB_EXAMPLE0SERIAL_1")
}

@(test)
accepts_an_absolute_link :: proc(t: ^testing.T) {
	links := [?]Link{{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL", "/dev/nvme0n1"}}
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, links[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	expect_path(t, r, by_id, TARGET_LINK)
}

@(test)
finds_no_link_when_none_names_the_serial :: proc(t: ^testing.T) {
	// The EUI link points at the disk but does not name the serial, and a
	// serial that only starts or ends the same is another serial.
	links := [?]Link{
		{"nvme-eui.0000000000000001", "../../nvme0n1"},
		{"nvme-Example_SSD_1TB_EXAMPLE0SERIAL0", "../../nvme0n1"},
		{"nvme-Example_SSD_1TB_XEXAMPLE0SERIAL", "../../nvme0n1"},
		{"nvme-Example_SSD_1TB-EXAMPLE0SERIAL", "../../nvme0n1"},
	}
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, links[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	testing.expect_value(t, r.status, guard.By_Id_Status.Not_Found)
	testing.expect_value(t, r.path, "")
}

@(test)
ignores_what_is_no_link :: proc(t: ^testing.T) {
	// A file and a directory named like the target are not udev's links.
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, {})
	defer delete(by_id)
	file := strings.concatenate({by_id, "/", TARGET_LINK})
	defer delete(file)
	testing.expect_value(t, os.write_entire_file(file, "../../nvme0n1"), nil)
	sub := strings.concatenate({by_id, "/", TARGET_LINK, "_1"})
	defer delete(sub)
	testing.expect_value(t, os.make_directory(sub), nil)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	testing.expect_value(t, r.status, guard.By_Id_Status.Not_Found)
}

@(test)
refuses_a_missing_or_unreadable_directory :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	missing := strings.concatenate({dir, "/no-such-by-id"})
	defer delete(missing)

	r := lookup(t, TODAY, missing)
	defer guard.by_id_destroy(r)
	testing.expect_value(t, r.status, guard.By_Id_Status.Unreadable)
	testing.expect(t, r.os_error != nil)

	// A file where the directory should be.
	file := strings.concatenate({dir, "/by-id"})
	defer delete(file)
	testing.expect_value(t, os.write_entire_file(file, "not a directory"), nil)
	r2 := lookup(t, TODAY, file)
	defer guard.by_id_destroy(r2)
	testing.expect_value(t, r2.status, guard.By_Id_Status.Unreadable)
}

@(test)
picks_the_same_link_whatever_the_order :: proc(t: ^testing.T) {
	// The directory lists its entries in no fixed order; the links made in
	// reverse must give the same answer.
	reversed: [len(today_links)]Link
	for l, i in today_links {
		reversed[len(today_links) - 1 - i] = l
	}
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, reversed[:])
	defer delete(by_id)

	r := lookup(t, TODAY, by_id)
	defer guard.by_id_destroy(r)
	expect_path(t, r, by_id, TARGET_LINK)
}

@(test)
does_not_double_a_trailing_slash :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	slashed := strings.concatenate({by_id, "/"})
	defer delete(slashed)

	r := lookup(t, TODAY, slashed)
	defer guard.by_id_destroy(r)
	expect_path(t, r, by_id, TARGET_LINK)
}
