// The tests of the command: its arguments, its exit codes, what it prints
// where, and how it runs lsblk. Each case runs the whole tool in this
// process, with its standard output and error in files under TMPDIR, so a
// test reads exactly what a shell's $(...) would get.
package ravnix_disk_guard_tests

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import guard ".."

TODAY_PATH :: #directory + "/testdata/today.json"
SWAPPED_PATH :: #directory + "/testdata/swapped.json"
SAME_MODEL_PATH :: #directory + "/testdata/same-model.json"
TARGET_MOUNTED_PATH :: #directory + "/testdata/target-mounted.json"
TARGET_LUKS_OPEN_PATH :: #directory + "/testdata/target-luks-open.json"
NO_SERIAL_FIELD_PATH :: #directory + "/testdata/no-serial-field.json"
FAKE_LSBLK :: #directory + "/testdata/fake-lsblk"

Ran :: struct {
	code: int,
	out:  string,
	err:  string,
}

ran_destroy :: proc(r: Ran) {
	delete(r.out)
	delete(r.err)
}

// run_guard runs the command with args and lsblk in this process and
// returns its exit code and everything it printed.
run_guard :: proc(t: ^testing.T, dir: string, args: []string, lsblk := "/no/lsblk/in/this/test") -> (r: Ran) {
	out_path := strings.concatenate({dir, "/stdout"})
	defer delete(out_path)
	err_path := strings.concatenate({dir, "/stderr"})
	defer delete(err_path)
	out, oerr := os.create(out_path)
	testing.expect_value(t, oerr, nil)
	errf, eerr := os.create(err_path)
	testing.expect_value(t, eerr, nil)
	r.code = guard.run(args, lsblk, out, errf)
	os.close(out)
	os.close(errf)
	out_data, _ := os.read_entire_file(out_path, context.allocator)
	err_data, _ := os.read_entire_file(err_path, context.allocator)
	r.out, r.err = string(out_data), string(err_data)
	return
}

// fake_lsblk makes an lsblk in dir that runs body as its case.sh.
fake_lsblk :: proc(t: ^testing.T, dir: string, body: string) -> string {
	case_path := strings.concatenate({dir, "/case.sh"})
	defer delete(case_path)
	testing.expect_value(t, os.write_entire_file(case_path, body), nil)
	path := strings.concatenate({dir, "/lsblk"})
	if !os.exists(path) {
		testing.expect_value(t, os.symlink(FAKE_LSBLK, path), nil)
	}
	return path
}

// The case.sh of an lsblk that prints the fixture at path, and fails unless
// the guard asked for the right columns with a clean environment.
lsblk_printing :: proc(path: string) -> string {
	return strings.concatenate({
		`[ "$*" = "-J -o NAME,MODEL,SERIAL,MOUNTPOINTS,TYPE" ] || { echo "lsblk: unexpected arguments: $*" >&2; exit 64; }` + "\n",
		`[ "${LC_ALL-}" = C ] || { echo "lsblk: LC_ALL is not C" >&2; exit 65; }` + "\n",
		`[ -z "${TMPDIR+x}" ] || { echo "lsblk: the environment was passed on" >&2; exit 66; }` + "\n",
		`while IFS= read -r line; do printf '%s\n' "$line"; done < '`, path, `'` + "\n",
	})
}

// The line --lsblk-json prints on standard error, for the file at path,
// which holds nothing to escape.
lsblk_json_line :: proc(path: string) -> string {
	return strings.concatenate({"ravnix-disk-guard: --lsblk-json: the disks are read from \"", path, "\", not from lsblk on the live system\n"})
}

// The line --by-id prints on standard error, for the directory dir, which
// holds nothing to escape.
by_id_line :: proc(dir: string) -> string {
	return strings.concatenate({"ravnix-disk-guard: --by-id: the links are read from \"", dir, "\", not from /dev/disk/by-id on the live system\n"})
}

JSON_SAYS :: "ravnix-disk-guard: --lsblk-json:"
BY_ID_SAYS :: "ravnix-disk-guard: --by-id:"

@(test)
print_device_prints_only_the_path :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TODAY_PATH, "--by-id", by_id})
	defer ran_destroy(r)
	want := strings.concatenate({by_id, "/", TARGET_LINK, "\n"})
	defer delete(want)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, want)
	// The verdict goes to standard error, naming the kernel name of the
	// moment, so the operator sees which device the path is now.
	testing.expectf(t, strings.contains(r.err, "nvme0n1"), "stderr: %s", r.err)
}

@(test)
without_print_device_it_says_what_it_found :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--lsblk-json", TODAY_PATH, "--by-id", by_id})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expectf(t, strings.contains(r.out, TARGET_LINK) && strings.contains(r.out, "nvme0n1"), "stdout: %s", r.out)
	// Standard error holds the two seams' lines and nothing else.
	json_says := lsblk_json_line(TODAY_PATH)
	defer delete(json_says)
	by_id_says := by_id_line(by_id)
	defer delete(by_id_says)
	want := strings.concatenate({json_says, by_id_says})
	defer delete(want)
	testing.expect_value(t, r.err, want)
}

@(test)
swapped_names_print_the_same_path :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, swapped_links[:])
	defer delete(by_id)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", SWAPPED_PATH, "--by-id", by_id})
	defer ran_destroy(r)
	want := strings.concatenate({by_id, "/", TARGET_LINK, "\n"})
	defer delete(want)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, want)
	testing.expectf(t, strings.contains(r.err, "nvme1n1"), "stderr: %s", r.err)
}

// A test seam decides on a file instead of the live system, so it says so,
// once, before anything else, whenever it is used: an operator who passes
// one by mistake sees it in the guard's first line.
@(test)
each_test_seam_says_it_is_used :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	json_says := lsblk_json_line(TODAY_PATH)
	defer delete(json_says)
	by_id_says := by_id_line(by_id)
	defer delete(by_id_says)
	both := strings.concatenate({json_says, by_id_says})
	defer delete(both)
	body := lsblk_printing(TODAY_PATH)
	defer delete(body)
	lsblk := fake_lsblk(t, dir, body)
	defer delete(lsblk)

	// Both, in either order: the file's line, then the directory's, then the
	// verdict, and no seam line twice.
	orders := [][]string{
		{"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TODAY_PATH, "--by-id", by_id},
		{"--by-id", by_id, "--lsblk-json", TODAY_PATH, "--print-device", "--serial", SERIAL, "--model", MODEL},
	}
	for args in orders {
		r := run_guard(t, dir, args)
		testing.expectf(t, r.code == 0, "%v: exit %d: %s", args, r.code, r.err)
		testing.expectf(t, strings.has_prefix(r.err, both), "%v: stderr: %s", args, r.err)
		testing.expectf(t, strings.count(r.err, "live system") == 2, "%v: stderr: %s", args, r.err)
		ran_destroy(r)
	}

	// --by-id alone, with lsblk run: its line only.
	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--by-id", by_id}, lsblk)
	testing.expectf(t, r.code == 0, "exit %d: %s", r.code, r.err)
	testing.expectf(t, strings.has_prefix(r.err, by_id_says), "stderr: %s", r.err)
	testing.expectf(t, !strings.contains(r.err, JSON_SAYS), "stderr: %s", r.err)
	ran_destroy(r)

	// --lsblk-json alone: its line only. The links are then read from
	// /dev/disk/by-id, which has none of the fixture's made-up disk, or is
	// not there at all in the build sandbox, so the guard refuses.
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TODAY_PATH})
	expect_refusal(t, r, 1, "")
	testing.expectf(t, strings.has_prefix(r.err, json_says), "stderr: %s", r.err)
	testing.expectf(t, !strings.contains(r.err, BY_ID_SAYS), "stderr: %s", r.err)
	ran_destroy(r)

	// --by-id naming /dev/disk/by-id itself reads the live links: no line.
	for live in ([]string{"/dev/disk/by-id", "/dev/disk/by-id/", "/dev/disk/by-id//"}) {
		r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--lsblk-json", TODAY_PATH, "--by-id", live})
		testing.expectf(t, r.code == 1, "%s: exit %d", live, r.code)
		testing.expectf(t, strings.has_prefix(r.err, json_says), "%s: stderr: %s", live, r.err)
		testing.expectf(t, !strings.contains(r.err, BY_ID_SAYS), "%s: stderr: %s", live, r.err)
		ran_destroy(r)
	}

	// The line comes first even when the file cannot be read.
	missing := strings.concatenate({dir, "/no-such.json"})
	defer delete(missing)
	missing_says := lsblk_json_line(missing)
	defer delete(missing_says)
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", missing, "--by-id", by_id})
	expect_refusal(t, r, 1, "cannot read")
	testing.expectf(t, strings.has_prefix(r.err, missing_says), "stderr: %s", r.err)
	ran_destroy(r)

	// A name with a newline is quoted: the line stays one line.
	newline := strings.concatenate({dir, "/a\nb.json"})
	defer delete(newline)
	newline_says := strings.concatenate({`ravnix-disk-guard: --lsblk-json: the disks are read from "`, dir, `/a\nb.json", not from lsblk on the live system` + "\n"})
	defer delete(newline_says)
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", newline, "--by-id", by_id})
	expect_refusal(t, r, 1, "cannot read")
	testing.expectf(t, strings.has_prefix(r.err, newline_says), "stderr: %s", r.err)
	ran_destroy(r)

	// Neither: lsblk and /dev/disk/by-id, and no seam line.
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device"}, lsblk)
	expect_refusal(t, r, 1, "")
	testing.expectf(t, !strings.contains(r.err, "live system"), "stderr: %s", r.err)
	ran_destroy(r)

	// Bad usage is refused before any seam is used: the usage error alone.
	r = run_guard(t, dir, {"--model", MODEL, "--lsblk-json", TODAY_PATH, "--by-id", by_id})
	expect_refusal(t, r, 3, "give --model and --serial")
	testing.expectf(t, !strings.contains(r.err, "live system"), "stderr: %s", r.err)
	ran_destroy(r)
}

// expect_refusal checks that a run exited code, printed nothing on standard
// output (so dev=$(...) stays empty), and said why on standard error.
expect_refusal :: proc(t: ^testing.T, r: Ran, code: int, says: string, loc := #caller_location) {
	testing.expect_value(t, r.code, code, loc = loc)
	testing.expect_value(t, r.out, "", loc = loc)
	testing.expectf(t, strings.contains(r.err, says), "stderr does not say %q: %s", says, r.err, loc = loc)
}

@(test)
refusals_exit_1_and_print_no_path :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	empty := strings.concatenate({dir, "/empty.json"})
	defer delete(empty)
	testing.expect_value(t, os.write_entire_file(empty, ""), nil)

	Case :: struct {
		json, model, serial, says: string,
	}
	cases := [?]Case{
		{TODAY_PATH, MODEL, "NOSUCHSERIAL", "no disk has model"},
		{TODAY_PATH, "No Such SSD", SERIAL, "no disk has model"},
		{SAME_MODEL_PATH, MODEL, SERIAL, "2 disks have model"},
		{NO_SERIAL_FIELD_PATH, MODEL, SERIAL, "no serial field"},
		{empty, MODEL, SERIAL, "lsblk printed nothing"},
		{"/no/such/lsblk.json", MODEL, SERIAL, "cannot read"},
		// lsblk after the swap, links from before it.
		{SWAPPED_PATH, MODEL, SERIAL, "points at nvme0n1"},
	}
	for c in cases {
		r := run_guard(t, dir, {"--model", c.model, "--serial", c.serial, "--print-device", "--lsblk-json", c.json, "--by-id", by_id})
		expect_refusal(t, r, 1, c.says)
		ran_destroy(r)
	}
	// No link for the target, and no link directory.
	other := strings.concatenate({dir, "/other"})
	defer delete(other)
	testing.expect_value(t, os.make_directory(other), nil)
	no_links := make_links(t, other, {})
	defer delete(no_links)
	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TODAY_PATH, "--by-id", no_links})
	expect_refusal(t, r, 1, "no link")
	ran_destroy(r)
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TODAY_PATH, "--by-id", "/no/such/by-id"})
	expect_refusal(t, r, 1, "cannot read /no/such/by-id")
	ran_destroy(r)
}

@(test)
names_the_disks_but_never_another_disks_serial :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", "NOSUCHSERIAL", "--print-device", "--lsblk-json", TODAY_PATH, "--by-id", by_id})
	defer ran_destroy(r)
	expect_refusal(t, r, 1, "nvme0n1")
	testing.expectf(t, strings.contains(r.err, KEEP_MODEL), "stderr names the other disk's model: %s", r.err)
	testing.expectf(t, !strings.contains(r.err, KEEP_SERIAL), "stderr shows another disk's serial: %s", r.err)
	testing.expectf(t, !strings.contains(r.err, SERIAL), "stderr shows a serial nobody asked for: %s", r.err)
}

@(test)
a_disk_in_use_exits_2 :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TARGET_MOUNTED_PATH, "--by-id", by_id})
	expect_refusal(t, r, 2, "nvme0n1p3 is mounted at /run/media/alice/Data")
	ran_destroy(r)
	r = run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--lsblk-json", TARGET_LUKS_OPEN_PATH, "--by-id", by_id})
	expect_refusal(t, r, 2, "cryptroot")
	ran_destroy(r)
	// The disk that holds the running system, asked for by its own model
	// and serial, is refused as in use even without --print-device.
	r = run_guard(t, dir, {"--model", KEEP_MODEL, "--serial", KEEP_SERIAL, "--lsblk-json", TODAY_PATH, "--by-id", by_id})
	expect_refusal(t, r, 2, "in use")
	ran_destroy(r)
}

@(test)
bad_usage_exits_3 :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	long := strings.repeat("x", 257)
	defer delete(long)

	bad := [?][]string{
		{},
		{"--model", MODEL},
		{"--serial", SERIAL},
		{"--model", MODEL, "--serial"},
		{"--model", "", "--serial", SERIAL},
		{"--model", MODEL, "--serial", ""},
		{"--model", " Example SSD 1TB", "--serial", SERIAL},
		{"--model", MODEL, "--serial", "EXAMPLE0SERIAL\n"},
		{"--model", MODEL, "--serial", "EXAMPLE0\tSERIAL"},
		{"--model", long, "--serial", SERIAL},
		{"--model", MODEL, "--model", MODEL, "--serial", SERIAL},
		{"--model", MODEL, "--serial", SERIAL, "--serial", SERIAL},
		{"--model", MODEL, "--serial", SERIAL, "--by-id", ""},
		{"--model", MODEL, "--serial", SERIAL, "--lsblk-json", ""},
		{"--model", MODEL, "--serial", SERIAL, "nvme0n1"},
		{"--model", MODEL, "--serial", SERIAL, "--device", "/dev/nvme0n1"},
		{"--model=" + MODEL, "--serial", SERIAL},
	}
	for args in bad {
		r := run_guard(t, dir, args)
		testing.expectf(t, r.code == 3, "%v: exit %d, not 3", args, r.code)
		testing.expectf(t, r.out == "", "%v printed %q on stdout", args, r.out)
		testing.expectf(t, r.err != "", "%v said nothing on stderr", args)
		ran_destroy(r)
	}
}

@(test)
help_exits_0 :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	r := run_guard(t, dir, {"--help"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect(t, strings.contains(r.out, "--print-device"))
}

@(test)
runs_lsblk_with_the_columns_it_reads :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	body := lsblk_printing(TODAY_PATH)
	defer delete(body)
	lsblk := fake_lsblk(t, dir, body)
	defer delete(lsblk)

	r := run_guard(t, dir, {"--model", MODEL, "--serial", SERIAL, "--print-device", "--by-id", by_id}, lsblk)
	defer ran_destroy(r)
	want := strings.concatenate({by_id, "/", TARGET_LINK, "\n"})
	defer delete(want)
	testing.expectf(t, r.code == 0, "exit %d: %s", r.code, r.err)
	testing.expect_value(t, r.out, want)
}

@(test)
refuses_when_lsblk_fails :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	args := []string{"--model", MODEL, "--serial", SERIAL, "--print-device", "--by-id", by_id}

	Case :: struct {
		body, says: string,
	}
	cases := [?]Case{
		{`echo 'lsblk: failed to access sysfs directory: /sys/dev/block: No such file or directory' >&2; exit 32`, "failed to access sysfs"},
		{`exit 1`, "lsblk failed"},
		{`kill -9 $$`, "lsblk"},
		{`printf ''`, "lsblk printed nothing"},
		{`printf 'not json at all\n'`, "not JSON"},
		{`printf '{"blockdevices": []}'`, "lists no block device"},
		// More than the guard reads: 70 000 lines of 65 bytes.
		{`i=0; while [ $i -lt 70000 ]; do printf '%064d\n' 0; i=$((i + 1)); done`, "more than"},
	}
	for c in cases {
		lsblk := fake_lsblk(t, dir, c.body)
		r := run_guard(t, dir, args, lsblk)
		expect_refusal(t, r, 1, c.says)
		ran_destroy(r)
		delete(lsblk)
	}
}

@(test)
refuses_when_lsblk_is_missing_or_not_executable :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	args := []string{"--model", MODEL, "--serial", SERIAL, "--print-device", "--by-id", by_id}

	r := run_guard(t, dir, args, "/no/such/lsblk")
	expect_refusal(t, r, 1, "cannot run /no/such/lsblk")
	ran_destroy(r)

	plain := strings.concatenate({dir, "/plain-lsblk"})
	defer delete(plain)
	testing.expect_value(t, os.write_entire_file(plain, "#!/bin/sh\nexit 0\n"), nil)
	r = run_guard(t, dir, args, plain)
	expect_refusal(t, r, 1, "cannot run")
	ran_destroy(r)
}

@(test)
decides_the_same_in_every_thread :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)
	want := strings.concatenate({by_id, "/", TARGET_LINK})
	defer delete(want)

	Shared :: struct {
		by_id:    string,
		want:     string,
		failures: int,
		mutex:    sync.Mutex,
	}
	shared := Shared{by_id = by_id, want = want}
	worker :: proc(data: rawptr) {
		s := (^Shared)(data)
		for _ in 0 ..< 20 {
			o := guard.decide(TODAY, MODEL, SERIAL, s.by_id)
			busy := guard.decide(TARGET_MOUNTED, MODEL, SERIAL, s.by_id)
			if o.code != 0 || o.path != s.want || busy.code != 2 || busy.path != "" {
				sync.mutex_lock(&s.mutex)
				s.failures += 1
				sync.mutex_unlock(&s.mutex)
			}
			guard.outcome_destroy(o)
			guard.outcome_destroy(busy)
		}
	}
	threads: [8]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(&shared, worker)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.failures, 0)
}

@(test)
decide_gives_the_exit_codes_of_the_command :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	by_id := make_links(t, dir, today_links[:])
	defer delete(by_id)

	Case :: struct {
		data: []u8,
		code: int,
	}
	cases := [?]Case{
		{TODAY, 0},
		{SAME_MODEL, 1},
		{NO_SERIAL_FIELD, 1},
		{TARGET_MOUNTED, 2},
		{TARGET_LUKS_OPEN, 2},
	}
	for c, i in cases {
		o := guard.decide(c.data, MODEL, SERIAL, by_id)
		testing.expectf(t, o.code == c.code, "case %d: exit %d, not %d: %s", i, o.code, c.code, o.message)
		testing.expectf(t, (o.path != "") == (c.code == 0), "case %d: path %q with exit %d", i, o.path, o.code)
		testing.expectf(t, o.message != "", "case %d: no message", i)
		guard.outcome_destroy(o)
	}
}
