// The tests of fetch: the release manifest over HTTPS, through curl. Each
// case puts a fake curl in a scratch directory that prints what a real one
// would, so no case needs the network; one case runs the real curl against
// a port where nothing listens.
package claude_code_verify_tests

import "core:os"
import "core:strings"
import "core:testing"
import ccv ".."

FAKE_CURL :: #directory + "/testdata/fake-curl"

// A curl in dir that runs body, a /bin/sh script, with curl's arguments:
// dir/curl links to testdata/fake-curl, which reads dir/case.sh.
fake_curl :: proc(t: ^testing.T, dir: string, body: string) -> string {
	case_path := strings.concatenate({dir, "/case.sh"})
	defer delete(case_path)
	testing.expect_value(t, os.write_entire_file(case_path, body), nil)
	path := strings.concatenate({dir, "/curl"})
	if !os.exists(path) {
		testing.expect_value(t, os.symlink(FAKE_CURL, path), nil)
	}
	return path
}

URL :: "https://releases.example.org/claude-code-releases/1.2.3/manifest.json"

@(test)
an_answer_of_200_is_the_manifest :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	curl := fake_curl(t, dir, `printf '{"version": "1.2.3"}\n200'`)
	defer delete(curl)

	f := ccv.fetch(curl, URL)
	defer ccv.fetched_destroy(f)
	testing.expect_value(t, f.status, ccv.Fetch_Status.Ok)
	testing.expect_value(t, f.http_code, 200)
	testing.expect_value(t, string(f.body), `{"version": "1.2.3"}`)
}

@(test)
curl_is_asked_for_https_redirects_a_time_limit_and_a_size_limit :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	// The fake writes each argument on a line of its own.
	curl := fake_curl(t, dir, `printf '%s\n' "$@" >"${0%/*}/argv"; printf '{}\n200'`)
	defer delete(curl)

	f := ccv.fetch(curl, URL)
	defer ccv.fetched_destroy(f)
	argv_path := strings.concatenate({dir, "/argv"})
	defer delete(argv_path)
	argv, err := os.read_entire_file(argv_path, context.allocator)
	defer delete(argv)
	testing.expect_value(t, err, nil)
	args := string(argv)
	for want in ([]string{
		"--url\n" + URL + "\n",
		"--proto-redir\n=https\n",
		"--max-time\n",
		"--connect-timeout\n",
		"--max-filesize\n",
		"--silent\n",
		"--show-error\n",
	}) {
		testing.expectf(t, strings.contains(args, want), "curl was not given %q:\n%s", want, args)
	}
}

@(test)
an_answer_of_404_or_410_means_no_manifest_for_that_version :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	for code in ([]string{"404", "410"}) {
		script := strings.concatenate({`printf '<html>Not Found</html>\n`, code, `'`})
		defer delete(script)
		curl := fake_curl(t, dir, script)
		defer delete(curl)
		f := ccv.fetch(curl, URL)
		defer ccv.fetched_destroy(f)
		testing.expectf(t, f.status == .Not_Found, "%s: got %v (%v)", code, f.status, f.run_error)
		testing.expect_value(t, ccv.fetch_exit_code(f.status), 1)
	}
}

@(test)
a_server_error_or_a_rate_limit_is_unreachable :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	for code in ([]string{"500", "502", "503", "429", "403"}) {
		script := strings.concatenate({`printf 'busy\n`, code, `'`})
		defer delete(script)
		curl := fake_curl(t, dir, script)
		defer delete(curl)
		f := ccv.fetch(curl, URL)
		defer ccv.fetched_destroy(f)
		testing.expectf(t, f.status == .Unreachable, "%s: got %v (%v)", code, f.status, f.run_error)
		testing.expect_value(t, ccv.fetch_exit_code(f.status), 3)
	}
}

@(test)
a_failed_transfer_is_unreachable_and_keeps_curls_reason :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	cases := [?]struct {
		exit:   string,
		reason: string,
	}{
		{"6", "curl: (6) Could not resolve host: releases.example.org"},
		{"7", "curl: (7) Failed to connect to releases.example.org port 443"},
		{"28", "curl: (28) Operation timed out after 30001 milliseconds"},
		{"35", "curl: (35) TLS connect error"},
		{"60", "curl: (60) SSL certificate problem: unable to get local issuer certificate"},
	}
	for c in cases {
		script := strings.concatenate({`printf '\n000'; echo '`, c.reason, `' >&2; exit `, c.exit})
		defer delete(script)
		curl := fake_curl(t, dir, script)
		defer delete(curl)
		f := ccv.fetch(curl, URL)
		defer ccv.fetched_destroy(f)
		testing.expectf(t, f.status == .Unreachable, "exit %s: got %v (%v)", c.exit, f.status, f.run_error)
		testing.expect_value(t, f.detail, c.reason)
	}
}

@(test)
an_answer_above_the_size_limit_is_a_wrong_answer_not_an_unreachable_one :: proc(t: ^testing.T) {
	// curl exits 63 when the answer is larger than --max-filesize. The
	// server answered, with something no release manifest is: a wrong
	// answer, exit 1, and not "try again later", exit 3.
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	curl := fake_curl(t, dir, `echo 'curl: (63) Maximum file size exceeded' >&2; exit 63`)
	defer delete(curl)
	f := ccv.fetch(curl, URL)
	defer ccv.fetched_destroy(f)
	testing.expect_value(t, f.curl_exit, 63)
	testing.expect_value(t, ccv.fetch_exit_code(f.status), 1)
	testing.expect_value(t, f.detail, "curl: (63) Maximum file size exceeded")
	line := ccv.describe_fetch(f, URL)
	defer delete(line)
	testing.expectf(t, strings.contains(line, "larger than 1 MiB"), "%q", line)
}

@(test)
curl_that_prints_no_status_is_unreachable :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	for script in ([]string{"exit 0", `printf '{"version": "1.2.3"}'`, `printf 'x\nabc'`, `printf 'x\n2000'`}) {
		curl := fake_curl(t, dir, script)
		defer delete(curl)
		f := ccv.fetch(curl, URL)
		defer ccv.fetched_destroy(f)
		testing.expectf(t, f.status == .Unreachable, "%q: got %v (%v)", script, f.status, f.run_error)
	}
}

@(test)
curl_killed_by_a_signal_is_unreachable :: proc(t: ^testing.T) {
	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	curl := fake_curl(t, dir, `printf '{}\n'; kill -9 $$`)
	defer delete(curl)
	f := ccv.fetch(curl, URL)
	defer ccv.fetched_destroy(f)
	testing.expect_value(t, f.status, ccv.Fetch_Status.Unreachable)
}

@(test)
a_missing_or_unrunnable_curl_is_no_fetcher :: proc(t: ^testing.T) {
	f := ccv.fetch("/no/such/curl", URL)
	defer ccv.fetched_destroy(f)
	testing.expect_value(t, f.status, ccv.Fetch_Status.No_Fetcher)
	testing.expect_value(t, ccv.fetch_exit_code(f.status), 2)

	dir := scratch_dir(t)
	defer delete(dir)
	defer os.remove_all(dir)
	path := write_file(t, dir, "curl", transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	defer delete(path)
	g := ccv.fetch(path, URL)
	defer ccv.fetched_destroy(g)
	testing.expect_value(t, g.status, ccv.Fetch_Status.No_Fetcher)
}

@(test)
the_real_curl_finds_nothing_listening :: proc(t: ^testing.T) {
	// Port 9 is discard, which nothing serves in the build sandbox or on a
	// workstation; the connection is refused at once.
	f := ccv.fetch(ccv.CURL, "http://127.0.0.1:9/claude-code-releases/1.2.3/manifest.json")
	defer ccv.fetched_destroy(f)
	testing.expect_value(t, f.status, ccv.Fetch_Status.Unreachable)
	testing.expect(t, f.detail != "")
}

@(test)
builds_the_manifest_url_from_a_base_and_a_version :: proc(t: ^testing.T) {
	cases := [?]struct {
		base, want: string,
	}{
		{"https://downloads.claude.ai/claude-code-releases", "https://downloads.claude.ai/claude-code-releases/2.1.319/manifest.json"},
		{"https://downloads.claude.ai/claude-code-releases/", "https://downloads.claude.ai/claude-code-releases/2.1.319/manifest.json"},
		{"http://127.0.0.1:8080", "http://127.0.0.1:8080/2.1.319/manifest.json"},
	}
	for c in cases {
		url := ccv.manifest_url(c.base, "2.1.319")
		defer delete(url)
		testing.expect_value(t, url, c.want)
	}
}

@(test)
takes_only_a_version_that_cannot_leave_its_directory :: proc(t: ^testing.T) {
	for v in ([]string{"2.1.319", "1.0.0-beta.1", "1.0.0+build.7", "10"}) {
		testing.expectf(t, ccv.valid_version(v), "%q should be a version", v)
	}
	long := strings.repeat("1", 65)
	defer delete(long)
	for v in ([]string{"", "..", "../2.1.319", "2.1/319", "-1", ".1", "2.1.319\n", "2.1.319 ", "2.1.319?x", "2.1.319#", long}) {
		testing.expectf(t, !ccv.valid_version(v), "%q should not be a version", v)
	}
}

@(test)
takes_only_an_http_base_url :: proc(t: ^testing.T) {
	for u in ([]string{"https://downloads.claude.ai/claude-code-releases", "http://127.0.0.1:8080"}) {
		testing.expectf(t, ccv.valid_base_url(u), "%q should be a base URL", u)
	}
	for u in ([]string{"", "downloads.claude.ai", "file:///etc", "-K/etc/passwd", "https://", "https://a b", "https://a\nb", "ftp://x"}) {
		testing.expectf(t, !ccv.valid_base_url(u), "%q should not be a base URL", u)
	}
}
