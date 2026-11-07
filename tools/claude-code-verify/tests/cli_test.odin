// The tests of run, the command line: its arguments and its exit codes.
// Each case runs the whole tool in this process, on the fixtures, and
// reads only the exit code; the messages go to stdout and stderr.
package claude_code_verify_tests

import "core:os"
import "core:strings"
import "core:testing"
import ccv ".."

MANIFEST_PATH :: #directory + "/testdata/manifest.json"

@(test)
a_matching_binary_exits_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.run({"--manifest", MANIFEST_PATH, FIXTURE, "1.2.3"}), 0)
	testing.expect_value(t, ccv.run({"--platform", "linux-x64", "--manifest", MANIFEST_PATH, FIXTURE, "1.2.3"}), 0)
}

@(test)
a_mismatch_exits_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.run({"--manifest", MANIFEST_PATH, "--platform", "darwin-arm64", FIXTURE, "1.2.3"}), 1)
	testing.expect_value(t, ccv.run({"--manifest", MANIFEST_PATH, FIXTURE, "1.2.4"}), 1)
	testing.expect_value(t, ccv.run({"--manifest", MANIFEST_PATH, "--platform", "linux-arm64", FIXTURE, "1.2.3"}), 1)
}

@(test)
bad_usage_exits_2 :: proc(t: ^testing.T) {
	bad := [?][]string{
		{},
		{FIXTURE},
		{FIXTURE, "1.2.3", "extra"},
		{"--manifest"},
		{"--manifest", MANIFEST_PATH},
		{"--platform", "", FIXTURE, "1.2.3"},
		{"--frobnicate", FIXTURE, "1.2.3"},
		{FIXTURE, "../1.2.3"},
		{FIXTURE, ""},
		{"--releases", "file:///etc", FIXTURE, "1.2.3"},
		{"--releases", "https://x", "--manifest", MANIFEST_PATH, FIXTURE, "1.2.3"},
		{"--manifest", "/no/such/manifest.json", FIXTURE, "1.2.3"},
		{"--manifest", MANIFEST_PATH, "/no/such/claude", "1.2.3"},
	}
	for args in bad {
		testing.expectf(t, ccv.run(args) == 2, "%v should be bad usage", args)
	}
}

@(test)
help_exits_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.run({"--help"}), 0)
}

@(test)
an_unreachable_manifest_exits_3 :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.run({"--releases", "http://127.0.0.1:9", FIXTURE, "1.2.3"}), 3)
}

@(test)
an_oversized_answer_exits_1 :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	curl := fake_curl(t, dir, `echo 'curl: (63) Maximum file size exceeded' >&2; exit 63`)
	defer delete(curl)
	testing.expect_value(t, ccv.run({"--releases", "https://releases.example.org", FIXTURE, "1.2.3"}, curl), 1)
}

@(test)
a_missing_curl_exits_2 :: proc(t: ^testing.T) {
	testing.expect_value(t, ccv.run({"--releases", "http://127.0.0.1:9", FIXTURE, "1.2.3"}, "/no/such/curl"), 2)
}

@(test)
fetches_the_manifest_of_the_version_asked :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	// A fake curl that serves the fixture manifest for 1.2.3, and 404 for
	// any other version.
	script := strings.concatenate({
		`case "$*" in *"/1.2.3/manifest.json"*) cat '`, MANIFEST_PATH, `'; printf '\n200' ;; *) printf 'no\n404' ;; esac`,
	})
	defer delete(script)
	curl := fake_curl(t, dir, script)
	defer delete(curl)
	testing.expect_value(t, ccv.run({"--releases", "https://releases.example.org/", FIXTURE, "1.2.3"}, curl), 0)
	testing.expect_value(t, ccv.run({"--releases", "https://releases.example.org", FIXTURE, "1.2.4"}, curl), 1)
}
