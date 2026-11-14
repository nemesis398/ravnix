// The tests of the command: its arguments, its exit codes, what it prints
// where, and how it reads the file. Each case runs the whole command in this
// process, with its standard output and error in files under TMPDIR, so a
// test reads exactly what the prune job's $(...) would get.
package ravnix_retention_tests

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import retention ".."

Ran :: struct {
	code: int,
	out:  string,
	err:  string,
}

ran_destroy :: proc(r: Ran) {
	delete(r.out)
	delete(r.err)
}

scratch_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "retention-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	return dir
}

// write_file writes text to dir/name and returns the path.
write_file :: proc(t: ^testing.T, dir, name, text: string) -> string {
	path := strings.concatenate({dir, "/", name})
	testing.expect_value(t, os.write_entire_file(path, text), nil)
	return path
}

// run_tool runs the command with args, and default_file standing in for
// RAVNIX_RETENTION_FILE, and returns its exit code and what it printed.
run_tool :: proc(t: ^testing.T, dir: string, args: []string, default_file := "", name := "") -> (r: Ran) {
	out_path := strings.concatenate({dir, "/stdout", name})
	defer delete(out_path)
	err_path := strings.concatenate({dir, "/stderr", name})
	defer delete(err_path)
	out, oerr := os.create(out_path)
	testing.expect_value(t, oerr, nil)
	errf, eerr := os.create(err_path)
	testing.expect_value(t, eerr, nil)
	r.code = retention.run(args, default_file, out, errf)
	os.close(out)
	os.close(errf)
	out_data, _ := os.read_entire_file(out_path, context.allocator)
	err_data, _ := os.read_entire_file(err_path, context.allocator)
	r.out, r.err = string(out_data), string(err_data)
	return
}

// expect_usage_error checks that args are refused as bad usage, saying
// want, with nothing on standard output.
expect_usage_error :: proc(t: ^testing.T, dir: string, args: []string, want: string, default_file := "", loc := #caller_location) {
	r := run_tool(t, dir, args, default_file)
	defer ran_destroy(r)
	testing.expectf(t, r.code == 2, "exit %d for %v, want 2; stderr: %s", r.code, args, r.err, loc = loc)
	testing.expectf(t, r.out == "", "stdout for %v: %q", args, r.out, loc = loc)
	testing.expectf(t, strings.contains(r.err, want), "stderr for %v lacks %q: %s", args, want, r.err, loc = loc)
}

@(test)
prints_the_flags_on_one_line :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)

	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn", "--file", file})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, NAS_HUGINN + "\n")
	testing.expect_value(t, r.err, "")
}

@(test)
takes_the_options_in_any_order :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)

	r := run_tool(t, dir, {"flags", "--file", file, "--host", "huginn", "--target", "internxt"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, INTERNXT_HUGINN + "\n")
}

@(test)
reads_the_file_the_environment_names :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)

	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn"}, default_file = file)
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, NAS_HUGINN + "\n")
}

@(test)
file_wins_over_the_environment :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)

	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn", "--file", file}, default_file = "/no/such/file")
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, NAS_HUGINN + "\n")
}

@(test)
says_where_the_file_must_come_from :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "huginn"}, "RAVNIX_RETENTION_FILE")
}

@(test)
prints_its_usage :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	for args in ([][]string{{"--help"}, {"-h"}, {"flags", "--help"}}) {
		r := run_tool(t, dir, args)
		testing.expect_value(t, r.code, 0)
		testing.expectf(t, strings.has_prefix(r.out, "usage: ravnix-retention flags"), "stdout: %s", r.out)
		testing.expect_value(t, r.err, "")
		ran_destroy(r)
	}
}

@(test)
refuses_bad_usage :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	F :: "/no/file/is/read"
	expect_usage_error(t, dir, {}, "usage")
	expect_usage_error(t, dir, {"prune"}, "unknown command prune")
	expect_usage_error(t, dir, {"flags", "--host", "huginn", "--file", F}, "give --target and --host")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--file", F}, "give --target and --host")
	expect_usage_error(t, dir, {"flags", "--target"}, "--target needs a value")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--target", "nas", "--host", "h", "--file", F}, "--target given twice")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "h", "--host", "h", "--file", F}, "--host given twice")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "h", "--file", F, "--file", F}, "--file given twice")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "h", "--file", ""}, "--file is empty")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "h", "--prune", "--file", F}, "unknown option --prune")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "h", "--file", F, "huginn"}, "unexpected argument")
}

@(test)
refuses_an_unknown_target_naming_the_known :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)
	expect_usage_error(t, dir, {"flags", "--target", "b2", "--host", "huginn", "--file", file}, "unknown target b2; the targets are nas and internxt")
	expect_usage_error(t, dir, {"flags", "--target", "", "--host", "huginn", "--file", file}, "unknown target")
}

@(test)
refuses_a_host_that_is_no_name :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "-v", "--file", file}, "--host")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "a b", "--file", file}, "--host")
	expect_usage_error(t, dir, {"flags", "--target", "nas", "--host", "", "--file", file}, "--host")
}

// expect_file_error checks that the command fails with exit 1 on the file
// at path, saying want, and prints no flags.
expect_file_error :: proc(t: ^testing.T, dir, path, want: string, loc := #caller_location) {
	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn", "--file", path})
	defer ran_destroy(r)
	testing.expectf(t, r.code == 1, "exit %d, want 1; stderr: %s", r.code, r.err, loc = loc)
	testing.expectf(t, r.out == "", "flags printed: %q", r.out, loc = loc)
	testing.expectf(t, strings.contains(r.err, want), "stderr lacks %q: %s", want, r.err, loc = loc)
}

@(test)
refuses_a_file_it_cannot_read :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	expect_file_error(t, dir, "/no/such/backups.toml", "ravnix-retention: cannot read /no/such/backups.toml")
	expect_file_error(t, dir, dir, "cannot read")
}

@(test)
refuses_a_wrong_file_naming_it_and_the_key :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", "[targets.nas]\ndaily = 0\nweekly = 0\nmonthly = 0\nyearly = 0\n[targets.internxt]\ndaily = 1\nweekly = 0\nmonthly = 0\nyearly = 0\n")
	defer delete(file)
	want := strings.concatenate({"ravnix-retention: ", file, ": targets.nas keeps nothing, so a prune would delete every snapshot\n"})
	defer delete(want)
	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn", "--file", file})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 1)
	testing.expect_value(t, r.out, "")
	testing.expect_value(t, r.err, want)
}

@(test)
refuses_a_file_too_large_to_be_one :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	big := strings.repeat("#\n", retention.MAX_FILE_BYTES)
	defer delete(big)
	file := write_file(t, dir, "big.toml", big)
	defer delete(file)
	expect_file_error(t, dir, file, "is larger than")
	// A file that never ends is cut at the limit, not read forever.
	expect_file_error(t, dir, "/dev/zero", "is larger than")
}

@(test)
reads_a_file_just_under_the_limit :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	pad := strings.repeat("#", retention.MAX_FILE_BYTES - len(TEMPLATE) - 1)
	defer delete(pad)
	text := strings.concatenate({pad, "\n", TEMPLATE})
	defer delete(text)
	testing.expect_value(t, len(text), retention.MAX_FILE_BYTES)
	file := write_file(t, dir, "full.toml", text)
	defer delete(file)
	r := run_tool(t, dir, {"flags", "--target", "nas", "--host", "huginn", "--file", file})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, NAS_HUGINN + "\n")
}

@(test)
refuses_an_empty_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "empty.toml", "")
	defer delete(file)
	expect_file_error(t, dir, file, "targets.nas is missing")
}

Concurrent :: struct {
	t:     ^testing.T,
	dir:   string,
	file:  string,
	index: int,
	wrong: int,
	mutex: sync.Mutex,
}

@(test)
gives_the_same_flags_to_runs_at_once :: proc(t: ^testing.T) {
	// The prune jobs of several hosts may ask at the same moment; the
	// command keeps no state, so each gets its own answer.
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	file := write_file(t, dir, "backups.toml", TEMPLATE)
	defer delete(file)

	c := Concurrent{t = t, dir = dir, file = file}
	threads: [8]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(&c, proc(data: rawptr) {
			c := (^Concurrent)(data)
			sync.mutex_lock(&c.mutex)
			c.index += 1
			name := strings.repeat("-", c.index)
			sync.mutex_unlock(&c.mutex)
			defer delete(name)
			for _ in 0 ..< 20 {
				r := run_tool(c.t, c.dir, {"flags", "--target", "nas", "--host", "huginn", "--file", c.file}, name = name)
				if r.code != 0 || r.out != NAS_HUGINN + "\n" {
					sync.mutex_lock(&c.mutex)
					c.wrong += 1
					sync.mutex_unlock(&c.mutex)
				}
				ran_destroy(r)
			}
		}, init_context = context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, c.wrong, 0)
}
