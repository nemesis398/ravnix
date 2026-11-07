// Getting the release manifest. Odin's core library has no HTTPS client, so
// the tool runs curl, by the store path the build gives it in CURL, and
// reads the body and the HTTP status from curl's standard output.
package claude_code_verify

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The curl the tool runs. default.nix sets it to curl's store path; a bare
// name is looked up on PATH.
CURL :: #config(CURL, "curl")

// Where Anthropic publishes the releases: <base>/<version>/manifest.json.
DEFAULT_RELEASES :: "https://downloads.claude.ai/claude-code-releases"

// A manifest is about 2 KiB. curl refuses an answer above this, so a server
// that sends something else cannot fill the memory.
MAX_MANIFEST_BYTES :: 1024 * 1024

Fetch_Status :: enum {
	Ok,
	// The server answered 404 or 410: it has no manifest for that version.
	Not_Found,
	// The server answered with more than MAX_MANIFEST_BYTES (curl exit 63):
	// something no release manifest is, so a wrong answer, not a missing one.
	Too_Large,
	// No answer, or one that says to come back later: a failed connection,
	// a timeout, a TLS error, a server error, a rate limit.
	Unreachable,
	// curl itself cannot be started.
	No_Fetcher,
}

Fetched :: struct {
	status:    Fetch_Status,
	// The manifest when status is Ok, a slice of out.
	body:      []u8,
	// The HTTP status, 0 when curl got none.
	http_code: int,
	curl_exit: int,
	// curl's own message, its first line, or what went wrong running it: a
	// slice of err_text or a constant.
	detail:    string,
	// Why curl could not be started, when status is No_Fetcher.
	run_error: os.Error,
	out:       []u8,
	err_text:  []u8,
}

fetched_destroy :: proc(f: Fetched, allocator := context.allocator) {
	delete(f.out, allocator)
	delete(f.err_text, allocator)
}

// fetch_exit_code is the command's exit status when the fetch did not give
// a manifest: 1 for no manifest of that version or an answer too large to be
// one, 3 for no answer, 2 when curl cannot run.
fetch_exit_code :: proc(s: Fetch_Status) -> int {
	switch s {
	case .Ok:
		return 0
	case .Not_Found, .Too_Large:
		return 1
	case .Unreachable:
		return 3
	case .No_Fetcher:
		return 2
	}
	return 3
}

// fetch gets url through the curl at the path curl. curl follows redirects
// to https only, gives up after 10 s without a connection and 30 s in all,
// and refuses an answer larger than MAX_MANIFEST_BYTES. The caller frees
// the result with fetched_destroy.
fetch :: proc(curl, url: string, allocator := context.allocator) -> (f: Fetched) {
	max_bytes_buf: [32]u8
	max_bytes := strconv.write_int(max_bytes_buf[:], MAX_MANIFEST_BYTES, 10)
	command := []string{
		curl,
		"--silent",
		"--show-error",
		"--location",
		"--max-redirs", "5",
		"--proto-redir", "=https",
		"--connect-timeout", "10",
		"--max-time", "30",
		"--max-filesize", max_bytes,
		"--output", "-",
		"--write-out", "\n%{http_code}",
		"--url", url,
	}

	out_r, out_w, perr := os.pipe()
	if perr != nil {
		f.status, f.detail = .No_Fetcher, "cannot make a pipe for curl"
		return
	}
	defer os.close(out_r)
	err_r, err_w, perr2 := os.pipe()
	if perr2 != nil {
		os.close(out_w)
		f.status, f.detail = .No_Fetcher, "cannot make a pipe for curl"
		return
	}
	defer os.close(err_r)

	process, serr := os.process_start({command = command, stdout = out_w, stderr = err_w})
	// The child holds its own copies; closing ours lets the reads below end.
	os.close(out_w)
	os.close(err_w)
	if serr != nil {
		f.status, f.detail, f.run_error = .No_Fetcher, "cannot run curl", serr
		return
	}
	// stdout first and to its end: curl writes little to stderr, far less
	// than a pipe holds, so it never blocks on it meanwhile.
	f.out, _ = os.read_entire_file(out_r, allocator)
	f.err_text, _ = os.read_entire_file(err_r, allocator)
	state, werr := os.process_wait(process)

	f.detail = first_line(string(f.err_text))
	if werr != nil || !state.exited {
		f.status = .Unreachable
		if f.detail == "" {
			f.detail = "curl did not finish"
		}
		return
	}
	f.curl_exit = state.exit_code
	// CURLE_FILESIZE_EXCEEDED: the answer is above --max-filesize.
	if state.exit_code == 63 {
		f.status = .Too_Large
		return
	}
	if !state.success || state.exit_code != 0 {
		f.status = .Unreachable
		if f.detail == "" {
			f.detail = "curl failed without saying why"
		}
		return
	}

	// --write-out puts a newline and the three digits of the status last.
	out := string(f.out)
	nl := strings.last_index_byte(out, '\n')
	code_text := out[nl + 1:] if nl >= 0 else ""
	code, parsed := strconv.parse_int(code_text, 10)
	if nl < 0 || len(code_text) != 3 || !parsed {
		f.status, f.detail = .Unreachable, "curl printed no HTTP status"
		return
	}
	f.http_code = code
	switch code {
	case 200 ..= 299:
		f.status, f.body = .Ok, f.out[:nl]
	case 404, 410:
		f.status = .Not_Found
	case:
		f.status = .Unreachable
	}
	return
}

first_line :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = strings.trim_space(t[:i])
	}
	return t
}

// manifest_url is the manifest's URL for version under the base URL. The
// caller deletes it.
manifest_url :: proc(base, version: string, allocator := context.allocator) -> string {
	return strings.concatenate({strings.trim_right(base, "/"), "/", version, "/manifest.json"}, allocator)
}

// valid_version reports whether version can name a release and nothing
// else: letters, digits, dots, dashes, pluses and underscores, starting with
// a letter or digit, at most MAX_VERSION_LEN long, so it can never step out
// of its directory of the URL or read as an option.
valid_version :: proc(version: string) -> bool {
	if len(version) == 0 || len(version) > MAX_VERSION_LEN {
		return false
	}
	for c, i in transmute([]u8)version {
		switch c {
		case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z':
		case '.', '-', '+', '_':
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return !strings.contains(version, "..")
}

// valid_base_url reports whether url is an http or https URL with a host
// and nothing curl could read as more than one URL.
valid_base_url :: proc(url: string) -> bool {
	rest: string
	switch {
	case strings.has_prefix(url, "https://"):
		rest = url[len("https://"):]
	case strings.has_prefix(url, "http://"):
		rest = url[len("http://"):]
	case:
		return false
	}
	if len(rest) == 0 || rest[0] == '/' {
		return false
	}
	for c in transmute([]u8)url {
		if c <= ' ' || c == 0x7f {
			return false
		}
	}
	return true
}

// describe_fetch is the line the command prints when the fetch gave no
// manifest. The caller deletes it.
describe_fetch :: proc(f: Fetched, url: string, allocator := context.allocator) -> string {
	switch f.status {
	case .Ok:
		return fmt.aprintf("fetched %s", url, allocator = allocator)
	case .Not_Found:
		return fmt.aprintf("there is no release manifest at %s (HTTP %d)", url, f.http_code, allocator = allocator)
	case .Too_Large:
		return fmt.aprintf("the answer at %s is larger than 1 MiB, which no release manifest is (%s)", url, f.detail, allocator = allocator)
	case .Unreachable:
		if f.http_code != 0 {
			return fmt.aprintf("the release manifest at %s is unreachable: HTTP %d", url, f.http_code, allocator = allocator)
		}
		return fmt.aprintf("the release manifest at %s is unreachable: %s", url, f.detail, allocator = allocator)
	case .No_Fetcher:
		if f.run_error != nil {
			return fmt.aprintf("cannot fetch %s: %s: %s", url, f.detail, os.error_string(f.run_error), allocator = allocator)
		}
		return fmt.aprintf("cannot fetch %s: %s", url, f.detail, allocator = allocator)
	}
	return strings.clone("unknown fetch result", allocator)
}
