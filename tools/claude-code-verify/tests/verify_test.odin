// The tests of verify: a binary against a release manifest. The check
// claude-code-verify-tests runs them with a fixed seed and fails a test that
// leaks or frees badly, even when its assertions hold.
package claude_code_verify_tests

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import ccv ".."

// The fixture binary and its manifest, whose linux-x64 entry describes it.
FIXTURE :: #directory + "/testdata/claude.bin"
MANIFEST :: #load("testdata/manifest.json")
NO_LINUX_X64 :: #load("testdata/no-linux-x64.json")
FIXTURE_SHA256 :: "4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d"
FIXTURE_SIZE :: 192

// A manifest with one linux-x64 entry, the given checksum and size text.
manifest_with :: proc(checksum: string, size: string, allocator := context.allocator) -> []u8 {
	size_part := "" if size == "" else strings.concatenate({`, "size": `, size}, context.temp_allocator)
	return transmute([]u8)strings.concatenate(
		{`{"version": "1.2.3", "platforms": {"linux-x64": {"checksum": "`, checksum, `"`, size_part, `}}}`},
		allocator,
	)
}

// A scratch directory under TMPDIR, removed by the caller.
scratch_dir :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "ccv-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	return dir
}

// Writes data to name in dir and returns the path.
write_file :: proc(t: ^testing.T, dir, name: string, data: []u8) -> string {
	path := strings.concatenate({dir, "/", name})
	testing.expect_value(t, os.write_entire_file(path, data), nil)
	return path
}

@(test)
accepts_a_binary_that_matches_its_manifest :: proc(t: ^testing.T) {
	r := ccv.verify(FIXTURE, MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Ok)
	hex := ccv.hex_digest(r.actual)
	testing.expect_value(t, string(hex[:]), FIXTURE_SHA256)
	testing.expect_value(t, r.actual_size, FIXTURE_SIZE)
	testing.expect_value(t, ccv.entry_version(&r.entry), "1.2.3")
}

@(test)
refuses_a_binary_with_one_flipped_byte :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	data, err := os.read_entire_file(FIXTURE, context.allocator)
	testing.expect_value(t, err, nil)
	defer delete(data)
	data[len(data) / 2] ~= 0x01
	path := write_file(t, dir, "claude", data)
	defer delete(path)

	r := ccv.verify(path, MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Checksum_Mismatch)
	// The same size, so the hash and not the size found it.
	testing.expect_value(t, r.actual_size, FIXTURE_SIZE)
	hex := ccv.hex_digest(r.actual)
	testing.expect(t, string(hex[:]) != FIXTURE_SHA256)
}

@(test)
names_the_platform_a_manifest_lacks :: proc(t: ^testing.T) {
	// The manifest has linux-x64-musl with the fixture's own checksum: a
	// platform is matched by its whole name, never by a prefix.
	r := ccv.verify(FIXTURE, NO_LINUX_X64, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.No_Platform)
	msg := ccv.message(r, FIXTURE, "1.2.3", "linux-x64", "no-linux-x64.json")
	defer delete(msg)
	testing.expectf(t, strings.contains(msg, `no entry for the platform "linux-x64"`), "message: %s", msg)
	testing.expect_value(t, ccv.exit_code(r.status), 1)
}

@(test)
refuses_malformed_json_without_crashing :: proc(t: ^testing.T) {
	bad := [?]string{
		"",
		" ",
		"{",
		`{"version": "1.2.3", "platforms": {`,
		"[]",
		"null",
		`"linux-x64"`,
		"42",
		`{}`,
		`{"version": "1.2.3"}`,
		`{"version": "1.2.3", "platforms": []}`,
		`{"version": "1.2.3", "platforms": {"linux-x64": "4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d"}}`,
		`{"version": "1.2.3", "platforms": {"linux-x64": {}}}`,
		`{"version": "1.2.3", "platforms": {"linux-x64": {"checksum": 42}}}`,
		`{"version": 123, "platforms": {"linux-x64": {"checksum": "4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d"}}}`,
		`{"version": "", "platforms": {"linux-x64": {"checksum": "4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d"}}}`,
		// Two values, a value with trailing junk, and a NUL byte that the
		// JSON tokenizer would take for the end of the input.
		`{"version": "1.2.3", "platforms": {}} {}`,
		`{"version": "1.2.3", "platforms": {"linux-x64": {"checksum": "4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d"}}} junk`,
		"{\"version\": \"1.2.3\", \"platforms\": {\"linux-x64\": {\"checksum\": \"4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d\"}}}\x00junk",
		// A captive portal's answer instead of the manifest.
		"<html><body>Please log in to the hotel Wi-Fi</body></html>",
		// The same key twice.
		`{"version": "1.2.3", "version": "1.2.4", "platforms": {}}`,
	}
	for text in bad {
		r := ccv.verify(FIXTURE, transmute([]u8)text, "linux-x64")
		testing.expectf(t, r.status == .Bad_Manifest, "%q: got %v", text, r.status)
		testing.expect(t, r.why != "")
		testing.expect_value(t, ccv.exit_code(r.status), 1)
	}
}

@(test)
refuses_a_checksum_that_is_not_64_hex_digits :: proc(t: ^testing.T) {
	bad := [?]string{
		"",
		"4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835",
		"4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835d0",
		"4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b76835g",
		"4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b7683 d",
		"sha256:4ec27b819de66adab132df0592c1a116833dcf15182a5455d7fd1c157b",
	}
	for checksum in bad {
		m := manifest_with(checksum, "192")
		defer delete(m)
		r := ccv.verify(FIXTURE, m, "linux-x64")
		testing.expectf(t, r.status == .Bad_Manifest, "%q: got %v", checksum, r.status)
	}
}

@(test)
accepts_an_uppercase_checksum :: proc(t: ^testing.T) {
	upper := strings.to_upper(FIXTURE_SHA256)
	defer delete(upper)
	m := manifest_with(upper, "192")
	defer delete(m)
	testing.expect_value(t, ccv.verify(FIXTURE, m, "linux-x64").status, ccv.Verify_Status.Ok)
}

@(test)
refuses_a_size_that_is_not_a_positive_whole_number :: proc(t: ^testing.T) {
	bad := [?]string{`"192"`, "-192", "0", "0.5", "192.5", "true", "null", "[192]", "99999999999999999999999", "9007199254740993", "1e400"}
	for size in bad {
		m := manifest_with(FIXTURE_SHA256, size)
		defer delete(m)
		r := ccv.verify(FIXTURE, m, "linux-x64")
		testing.expectf(t, r.status == .Bad_Manifest, "size %s: got %v", size, r.status)
	}
}

@(test)
a_size_in_exponent_form_is_still_its_number :: proc(t: ^testing.T) {
	m := manifest_with(FIXTURE_SHA256, "1.92e2")
	defer delete(m)
	testing.expect_value(t, ccv.verify(FIXTURE, m, "linux-x64").status, ccv.Verify_Status.Ok)
	n := manifest_with(FIXTURE_SHA256, "1e3")
	defer delete(n)
	r := ccv.verify(FIXTURE, n, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Size_Mismatch)
	testing.expect_value(t, r.entry.size, 1000)
}

@(test)
a_manifest_without_a_size_is_checked_by_its_checksum_alone :: proc(t: ^testing.T) {
	m := manifest_with(FIXTURE_SHA256, "")
	defer delete(m)
	testing.expect_value(t, ccv.verify(FIXTURE, m, "linux-x64").status, ccv.Verify_Status.Ok)
}

@(test)
a_deeply_nested_manifest_is_refused_without_overflowing_the_stack :: proc(t: ^testing.T) {
	deep := strings.repeat("[", 200_000)
	defer delete(deep)
	r := ccv.verify(FIXTURE, transmute([]u8)deep, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Bad_Manifest)
	// Brackets inside a string are text, not nesting.
	m := manifest_with(FIXTURE_SHA256, "192")
	defer delete(m)
	quoted := strings.concatenate({`{"note": "`, deep, `", `, string(m[1:])})
	defer delete(quoted)
	testing.expect_value(t, ccv.verify(FIXTURE, transmute([]u8)quoted, "linux-x64").status, ccv.Verify_Status.Ok)
}

@(test)
an_empty_binary_is_a_mismatch :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	path := write_file(t, dir, "empty", nil)
	defer delete(path)

	r := ccv.verify(path, MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Size_Mismatch)
	testing.expect_value(t, r.actual_size, 0)
	testing.expect_value(t, ccv.exit_code(r.status), 1)

	// Without a size in the manifest, the hash finds it.
	m := manifest_with(FIXTURE_SHA256, "")
	defer delete(m)
	testing.expect_value(t, ccv.verify(path, m, "linux-x64").status, ccv.Verify_Status.Checksum_Mismatch)
}

@(test)
a_longer_binary_is_a_size_mismatch :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	data, _ := os.read_entire_file(FIXTURE, context.allocator)
	defer delete(data)
	longer := make([]u8, len(data) + 1)
	defer delete(longer)
	copy(longer, data)
	path := write_file(t, dir, "claude", longer)
	defer delete(path)

	r := ccv.verify(path, MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Size_Mismatch)
	testing.expect_value(t, r.actual_size, FIXTURE_SIZE + 1)
	msg := ccv.message(r, path, "1.2.3", "linux-x64", "manifest.json")
	defer delete(msg)
	testing.expectf(t, strings.contains(msg, "193 bytes") && strings.contains(msg, "192"), "message: %s", msg)
}

@(test)
a_missing_binary_is_unreadable :: proc(t: ^testing.T) {
	r := ccv.verify("/no/such/claude", MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Unreadable_Binary)
	testing.expect_value(t, r.os_error, os.General_Error.Not_Exist)
	testing.expect_value(t, ccv.exit_code(r.status), 2)
}

@(test)
a_directory_is_no_binary :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	r := ccv.verify(dir, MANIFEST, "linux-x64")
	testing.expect_value(t, r.status, ccv.Verify_Status.Unreadable_Binary)
	msg := ccv.message(r, dir, "1.2.3", "linux-x64", "manifest.json")
	defer delete(msg)
	testing.expectf(t, strings.contains(msg, "not a regular file"), "message: %s", msg)
}

@(test)
the_manifest_must_be_for_the_version_asked :: proc(t: ^testing.T) {
	r := ccv.verify(FIXTURE, MANIFEST, "linux-x64", "1.2.4")
	testing.expect_value(t, r.status, ccv.Verify_Status.Wrong_Version)
	msg := ccv.message(r, FIXTURE, "1.2.4", "linux-x64", "manifest.json")
	defer delete(msg)
	testing.expectf(t, strings.contains(msg, "1.2.3") && strings.contains(msg, "1.2.4"), "message: %s", msg)
	testing.expect_value(t, ccv.exit_code(r.status), 1)
	// The version is checked only when one is given.
	testing.expect_value(t, ccv.verify(FIXTURE, MANIFEST, "linux-x64", "1.2.3").status, ccv.Verify_Status.Ok)
	testing.expect_value(t, ccv.verify(FIXTURE, MANIFEST, "linux-x64", "").status, ccv.Verify_Status.Ok)
}

@(test)
the_platform_must_match_exactly :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.verify(FIXTURE, MANIFEST, "linux").status, ccv.Verify_Status.No_Platform)
	testing.expect_value(t, ccv.verify(FIXTURE, MANIFEST, "LINUX-X64").status, ccv.Verify_Status.No_Platform)
	testing.expect_value(t, ccv.verify(FIXTURE, MANIFEST, "darwin-arm64").status, ccv.Verify_Status.Checksum_Mismatch)
}

@(test)
this_build_verifies_linux_x64 :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
		testing.expect_value(t, ccv.DEFAULT_PLATFORM, "linux-x64")
	}
}

Shared :: struct {
	failures: int,
	mutex:    sync.Mutex,
}

@(test)
concurrent_verifications_agree :: proc(t: ^testing.T) {
	shared: Shared
	worker :: proc(data: rawptr) {
		s := (^Shared)(data)
		for _ in 0 ..< 20 {
			if ccv.verify(FIXTURE, MANIFEST, "linux-x64").status != .Ok {
				sync.mutex_lock(&s.mutex)
				s.failures += 1
				sync.mutex_unlock(&s.mutex)
			}
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
maps_every_status_to_its_exit_code :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.exit_code(.Ok), 0)
	testing.expect_value(t, ccv.exit_code(.Checksum_Mismatch), 1)
	testing.expect_value(t, ccv.exit_code(.Size_Mismatch), 1)
	testing.expect_value(t, ccv.exit_code(.Wrong_Version), 1)
	testing.expect_value(t, ccv.exit_code(.No_Platform), 1)
	testing.expect_value(t, ccv.exit_code(.Bad_Manifest), 1)
	testing.expect_value(t, ccv.exit_code(.Unreadable_Binary), 2)
}
