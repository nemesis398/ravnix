// The tests of the command, whole: each case runs ravnix-notify in this
// process against a homeserver on a loopback port, with a vault client and a
// curl that are scripts (fake_test.odin), and reads its exit status, what it
// said, what the homeserver was asked and what reached the journal. curl is
// the real one, so the request that arrives is the request that would.
package ravnix_notify_tests

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import notify ".."

ROOM_PATH :: "/_matrix/client/v3/rooms/"

// path_for is the path a message to the topic is sent to, up to the
// transaction id.
path_for :: proc(topic: string) -> string {
	room := room_of(topic)
	defer delete(room)
	encoded := notify.percent_encode(room)
	defer delete(encoded)
	return strings.concatenate({ROOM_PATH, encoded, "/send/m.room.message/"})
}

// txn_of is the transaction id of a request: the last part of its path.
txn_of :: proc(r: Request) -> string {
	i := strings.last_index_byte(r.target, '/')
	return r.target[i + 1:]
}

// expect_post checks that r is a send to the topic's room, with the topic's
// token and a JSON body, and returns its body parsed.
expect_post :: proc(t: ^testing.T, r: Request, topic: string, loc := #caller_location) -> (body: json.Object, ok: bool) {
	want_path := path_for(topic)
	defer delete(want_path)
	token := token_of(topic)
	defer delete(token)
	want_auth := strings.concatenate({"Bearer ", token})
	defer delete(want_auth)
	testing.expect_value(t, r.method, "PUT", loc = loc)
	testing.expectf(t, strings.has_prefix(r.target, want_path), "target %s does not start with %s", r.target, want_path, loc = loc)
	testing.expect(t, len(txn_of(r)) > 0, loc = loc)
	testing.expect_value(t, r.authorization, want_auth, loc = loc)
	testing.expect_value(t, r.content_type, "application/json", loc = loc)
	value, err := json.parse(transmute([]byte)r.body, allocator = context.temp_allocator)
	if !testing.expectf(t, err == .None, "the body is not JSON (%v): %s", err, r.body, loc = loc) {
		return
	}
	obj, is_obj := value.(json.Object)
	if !testing.expect(t, is_obj, loc = loc) {
		return
	}
	return obj, true
}

body_string :: proc(obj: json.Object, key: string) -> string {
	s, _ := obj[key].(json.String)
	return string(s)
}

// ---------------------------------------------------------------------------
// The message lands in the topic's room

@(test)
posts_to_the_room_of_the_topic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "sessions", "the build is green"})
	defer ran_destroy(r)

	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.err, "")
	testing.expect_value(t, r.out, "")
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), 1) {
		return
	}
	body, ok := expect_post(t, reqs[0], "sessions")
	if ok {
		testing.expect_value(t, body_string(body, "msgtype"), "m.text")
		testing.expect_value(t, body_string(body, "body"), "the build is green")
		testing.expect_value(t, body_string(body, "formatted_body"), "<p>the build is green</p>")
	}
	calls := file_in(&f, "rbw-calls")
	defer delete(calls)
	testing.expect_value(t, calls, "unlocked\nget -- Matrix - access token (ravnix-sessions)\n")
}

@(test)
every_topic_has_its_own_room_and_token :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	for topic in TOPICS {
		r := run_notify(t, &f, {"--topic", topic, topic})
		defer ran_destroy(r)
		testing.expectf(t, r.code == 0, "%s: exit %d: %s", topic, r.code, r.err)
	}
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), len(TOPICS)) {
		return
	}
	for topic, i in TOPICS {
		body, ok := expect_post(t, reqs[i], topic)
		if ok {
			testing.expect_value(t, body_string(body, "body"), topic)
		}
	}
}

@(test)
sends_markdown_as_formatted_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	text := "**backup failed** on `muninn`: [log](https://example.org/l?a=1&b=2)\n- one\n- two"
	r := run_notify(t, &f, {"--topic", "backups", text})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), 1) {
		return
	}
	body, ok := expect_post(t, reqs[0], "backups")
	if ok {
		testing.expect_value(t, len(body), 4)
		testing.expect_value(t, body_string(body, "body"), text)
		testing.expect_value(t, body_string(body, "format"), "org.matrix.custom.html")
		testing.expect_value(
			t,
			body_string(body, "formatted_body"),
			`<p><strong>backup failed</strong> on <code>muninn</code>: <a href="https://example.org/l?a=1&amp;b=2">log</a></p><ul><li>one</li><li>two</li></ul>`,
		)
	}
}

@(test)
joins_words_and_trims_the_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "updates", "  three", "words\n"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if testing.expect_value(t, len(reqs), 1) {
		body, ok := expect_post(t, reqs[0], "updates")
		if ok {
			testing.expect_value(t, body_string(body, "body"), "three words")
		}
	}
}

@(test)
reads_the_message_from_standard_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "services", "-"}, {stdin = "line one\nline two\n\n"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if testing.expect_value(t, len(reqs), 1) {
		body, ok := expect_post(t, reqs[0], "services")
		if ok {
			testing.expect_value(t, body_string(body, "body"), "line one\nline two")
		}
	}

	// Nothing on standard input is no message.
	r2 := run_notify(t, &f, {"--topic", "services", "-"}, {stdin = "\n"})
	defer ran_destroy(r2)
	testing.expect_value(t, r2.code, notify.EX_USAGE)
	testing.expect_value(t, len(fake_requests(server)), 1)
}

@(test)
sends_text_that_json_and_the_shell_would_choke_on :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	text := "quote \" backslash \\ $(echo x) `id` ; 'single' \x01\x1b[31m 日本語 🎉\nurl = \"file:///etc/passwd\"\n-K /etc/passwd"
	r := run_notify(t, &f, {"--topic", "builds", text})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if testing.expect_value(t, len(reqs), 1) {
		body, ok := expect_post(t, reqs[0], "builds")
		if ok {
			testing.expect_value(t, body_string(body, "body"), text)
		}
	}
	// The one request is the only one made: the lines in the message did
	// not become options of curl.
	calls := file_in(&f, "curl-calls")
	defer delete(calls)
	testing.expect_value(t, strings.count(calls, "\n"), 1)
}

// ---------------------------------------------------------------------------
// What is refused before anything is asked

@(test)
unknown_topic_exits_64_and_asks_nobody :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	for topic in ([?]string{"nonsense", "Sessions", "sessions ", "../sessions", "sessions/../x", "builds,updates", " "}) {
		r := run_notify(t, &f, {"--topic", topic, "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == 64, "topic %q: exit %d, want 64", topic, r.code)
		testing.expectf(t, strings.contains(r.err, "unknown topic"), "topic %q: %s", topic, r.err)
		// The message names the topics there are.
		testing.expectf(t, strings.contains(r.err, "known topics: backups, builds, services, sessions, updates"), "topic %q: %s", topic, r.err)
	}
	testing.expect_value(t, len(fake_requests(server)), 0)
	calls := file_in(&f, "rbw-calls")
	defer delete(calls)
	testing.expect_value(t, calls, "")
}

@(test)
a_bad_command_line_exits_64 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	for args in ([?][]string{{}, {"hello"}, {"--topic", "builds"}, {"--topic", "builds", "--bogus", "x"}, {"--topic", "builds", "  "}}) {
		r := run_notify(t, &f, args)
		defer ran_destroy(r)
		testing.expectf(t, r.code == 64, "%q: exit %d, want 64", args, r.code)
		testing.expectf(t, strings.contains(r.err, "usage"), "%q: %s", args, r.err)
	}
	r := run_notify(t, &f, {"--help"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect(t, strings.contains(r.out, "usage: ravnix-notify"))
	testing.expect_value(t, r.err, "")
}

@(test)
a_topic_without_a_room_exits_78 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	f.rooms = {"sessions"}
	fixture_write(t, &f)

	// A room that is null is the configuration's gap, which the glue module
	// warns about: 78, and neither the vault client nor curl is started,
	// whether the message is on the command line, on standard input, or a
	// dry run.
	runs := [?]struct {
		args:  []string,
		stdin: string,
	}{
		{{"--topic", "builds", "hello"}, ""},
		{{"--topic", "builds", "-"}, "from stdin\n"},
		{{"--topic", "builds", "--dry-run", "hello"}, ""},
	}
	for run in runs {
		r := run_notify(t, &f, run.args, {stdin = run.stdin})
		defer ran_destroy(r)
		testing.expect_value(t, r.code, notify.EX_CONFIG)
		testing.expect(t, strings.contains(r.err, "builds"), r.err)
		testing.expect(t, strings.contains(r.err, "no room"), r.err)
		testing.expect(t, strings.contains(r.err, "ravnix.matrix.rooms.builds.roomId"), r.err)
		testing.expect_value(t, r.out, "")
	}
	testing.expect_value(t, len(fake_requests(server)), 0)
	for name in ([?]string{"rbw-calls", "curl-calls"}) {
		calls := file_in(&f, name)
		defer delete(calls)
		testing.expectf(t, calls == "", "%s ran for a topic without a room: %q", name, calls)
	}
}

@(test)
a_failed_read_of_standard_input_is_not_the_end_of_the_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	// A read that fails (an inherited pipe that is non-blocking, a broken
	// device) is not the end of the message: what was read so far would go
	// out as if it were all of it.
	r := run_notify(t, &f, {"--topic", "builds", "-"}, {stdin_unreadable = true})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_IOERR)
	testing.expect(t, strings.contains(r.err, "standard input"), r.err)
	testing.expect(t, strings.contains(r.err, "could not be read"), r.err)
	testing.expect_value(t, len(fake_requests(server)), 0)
	calls := file_in(&f, "rbw-calls")
	defer delete(calls)
	testing.expect_value(t, calls, "")
}

@(test)
a_missing_or_broken_config_exits_78 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	os.remove(f.config_path)
	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_CONFIG)
	testing.expect(t, strings.contains(r.err, f.config_path), r.err)

	testing.expect_value(t, os.write_entire_file(f.config_path, "{ not json"), nil)
	r2 := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r2)
	testing.expect_value(t, r2.code, notify.EX_CONFIG)
	testing.expect(t, strings.contains(r2.err, f.config_path), r2.err)

	// A directory where the file should be.
	os.remove(f.config_path)
	testing.expect_value(t, os.make_directory(f.config_path), nil)
	r3 := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r3)
	testing.expect_value(t, r3.code, notify.EX_CONFIG)
}

@(test)
a_message_too_large_for_an_event_exits_65 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	big := strings.repeat("x", 100_000)
	defer delete(big)
	r := run_notify(t, &f, {"--topic", "builds", big})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_DATAERR)
	testing.expect(t, strings.contains(r.err, "too large"), r.err)
	testing.expect_value(t, len(fake_requests(server)), 0)
	// Nobody was asked for a token for a message that cannot be sent.
	calls := file_in(&f, "rbw-calls")
	defer delete(calls)
	testing.expect_value(t, calls, "")
}

// ---------------------------------------------------------------------------
// The token

@(test)
a_locked_vault_exits_75_without_asking_for_a_password :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	f.locked = true
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect(t, strings.contains(r.err, "locked"), r.err)
	testing.expect_value(t, len(fake_requests(server)), 0)
	calls := file_in(&f, "rbw-calls")
	defer delete(calls)
	// `get` would have started a pinentry on a terminal nobody sits at.
	testing.expect_value(t, calls, "unlocked\n")
}

@(test)
a_token_the_vault_cannot_give_exits_69 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	cases := [?]struct {
		name, get: string,
	}{
		{"the item is missing", `echo "rbw: no entry found" >&2; exit 1`},
		{"an empty token", `printf '\n'`},
		{"no output at all", `exit 0`},
		{"a token with a line break inside", `printf 'tok\nurl = "file:///etc/passwd"\n'`},
		{"a token with a space", `printf 'tok en\n'`},
		{"a token with a control character", `printf 'tok\033en\n'`},
		{"a token with a NUL", `printf 'tok\000en\n'`},
		{"a token in two lines", `printf 'a\nb\n'`},
		{"a token that is only blanks", `printf '   \n'`},
	}
	for c in cases {
		f.rbw_get = c.get
		fixture_write(t, &f)
		r := run_notify(t, &f, {"--topic", "builds", "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == notify.EX_UNAVAILABLE, "%s: exit %d: %s", c.name, r.code, r.err)
		testing.expectf(t, strings.contains(r.err, "token"), "%s: %s", c.name, r.err)
		// What rbw printed is never repeated.
		testing.expectf(t, !strings.contains(r.err, "passwd"), "%s: %s", c.name, r.err)
	}
	testing.expect_value(t, len(fake_requests(server)), 0)
}

@(test)
passes_an_odd_but_printable_token_through_intact :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	f.rbw_get = `printf '%s\n' 'a"b\c$d'`
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if testing.expect_value(t, len(reqs), 1) {
		testing.expect_value(t, reqs[0].authorization, "Bearer a\"b\\c$d")
	}
}

@(test)
a_missing_vault_client_exits_69 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	os.remove(f.rbw_path)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_UNAVAILABLE)
	testing.expect(t, strings.contains(r.err, "rbw"), r.err)
}

@(test)
a_vault_client_that_hangs_is_given_up_on :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	f.rbw_timeout_ms = 300
	f.rbw_get = `exec sleep 20`
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_UNAVAILABLE)
	testing.expect(t, strings.contains(r.err, "did not answer"), r.err)
	testing.expectf(t, r.elapsed < 5 * time.Second, "took %v", r.elapsed)
}

@(test)
a_token_is_never_on_a_command_line_or_in_a_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The paths that say the most: success, a refusal, a server that is
	// down, one that fails, and one that answers with the token in it.
	Case :: struct {
		name:   string,
		script: []Reply,
		down:   bool,
		stream: bool,
	}
	cases := [?]Case {
		{"success", {OK_REPLY}, false, false},
		{"refused", {{status = 401, body = `{"errcode":"M_UNKNOWN_TOKEN","error":"Invalid access token tok-builds"}`}}, false, false},
		{"unavailable", {{status = 503, body = `{"error":"tok-builds"}`}}, false, true},
		{"down", {OK_REPLY}, true, false},
	}
	for c in cases {
		server := fake_start(t, c.script)
		defer fake_stop(server)
		f := fixture_make(t, free_port(t) if c.down else server.port)
		defer fixture_destroy(&f)

		r := run_notify(t, &f, {"--topic", "builds", "hello"}, {journal_stream = c.stream})
		defer ran_destroy(r)

		argv := file_in(&f, "curl-calls")
		defer delete(argv)
		testing.expectf(t, strings.contains(argv, "-K"), "%s: curl was not given its options on standard input: %s", c.name, argv)
		testing.expectf(t, !strings.contains(argv, "tok-builds"), "%s: the token is on curl's command line: %s", c.name, argv)
		testing.expectf(t, !strings.contains(argv, "Authorization"), "%s: the header is on curl's command line: %s", c.name, argv)
		testing.expectf(t, !strings.contains(r.err, "tok-builds"), "%s: the token is in what the tool said: %s", c.name, r.err)
		testing.expectf(t, !strings.contains(r.out, "tok-builds"), "%s: the token is in what the tool printed: %s", c.name, r.out)
		lines := journal_lines(f.journal)
		defer journal_lines_destroy(lines)
		for l in lines {
			testing.expectf(t, !strings.contains(l, "tok-builds"), "%s: the token is in the journal: %s", c.name, l)
		}
		// Nor in any file the run left in the scratch directory, except the
		// vault client's own script, which is where the stand-in keeps it.
		// (The tool opens no file for writing anywhere, which
		// the_tool_creates_no_file in source_test.odin checks.)
		entries, _ := os.read_all_directory_by_path(f.dir, context.allocator)
		defer os.file_info_slice_delete(entries, context.allocator)
		for e in entries {
			if e.name == "rbw-case.sh" || e.type != .Regular {
				continue
			}
			text := file_in(&f, e.name)
			defer delete(text)
			testing.expectf(t, !strings.contains(text, "tok-builds"), "%s: the token is in %s", c.name, e.name)
		}
	}
}

@(test)
a_curlrc_is_not_read :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY, OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	// A .curlrc in curl's home adds a header to every request of a curl that
	// does not start with -q: a stray option of the user's, or a proxy or a
	// header the config of ravnix-notify never asked for.
	rc := strings.concatenate({f.dir, "/.curlrc"})
	defer delete(rc)
	testing.expect_value(t, os.write_entire_file(rc, "header = \"X-Curlrc: read\"\n"), nil)
	curl_case := strings.concatenate({f.dir, "/curl-case.sh"})
	defer delete(curl_case)
	body := fmt.aprintf("export CURL_HOME='%s'\nexec '%s' \"$@\"\n", f.dir, notify.CURL)
	defer delete(body)
	testing.expect_value(t, os.write_entire_file(curl_case, body), nil)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	testing.expect_value(t, len(reqs), 1)
	if len(reqs) == 1 {
		testing.expectf(t, reqs[0].x_curlrc == "", "the .curlrc was read: %q", reqs[0].x_curlrc)
	}

	// The control: the same curl and the same file, without -q, does send it.
	url := fmt.aprintf("http://127.0.0.1:%d/control", server.port)
	defer delete(url)
	script := fmt.aprintf("CURL_HOME='%s' exec '%s' -s -o /dev/null %s", f.dir, notify.CURL, url)
	defer delete(script)
	res := notify.run_child({"/bin/sh", "-c", script}, nil, 10 * time.Second, 4096)
	defer delete(res.stdout)
	defer delete(res.stderr)
	testing.expect_value(t, res.exit_code, 0)
	reqs = fake_requests(server)
	testing.expect_value(t, len(reqs), 2)
	if len(reqs) == 2 {
		testing.expect_value(t, reqs[1].x_curlrc, "read")
	}
}

// ---------------------------------------------------------------------------
// Retries

@(test)
a_homeserver_that_is_down_is_tried_four_times_then_exit_75 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	f.retry_base_ms = 40
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)

	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	// The first try and three retries, backing off 40, 80 and 160 ms.
	calls := file_in(&f, "curl-calls")
	defer delete(calls)
	testing.expect_value(t, strings.count(calls, "\n"), 4)
	testing.expectf(t, r.elapsed >= 280 * time.Millisecond, "the retries took only %v", r.elapsed)
	for want in ([?]string{"retry 1 of 3 in 40 ms", "retry 2 of 3 in 80 ms", "retry 3 of 3 in 160 ms"}) {
		testing.expectf(t, strings.contains(r.err, want), "no %q in: %s", want, r.err)
	}
	testing.expect(t, !strings.contains(r.err, "retry 4"))
	testing.expect(t, strings.contains(r.err, "giving up after 4 tries"), r.err)
	// The tokens were asked for once, not once per try.
	rbw := file_in(&f, "rbw-calls")
	defer delete(rbw)
	testing.expect_value(t, strings.count(rbw, "get "), 1)
}

@(test)
the_give_up_line_reaches_the_journal :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	// Run by hand or by a hook, stderr is not the journal: the line goes to
	// the journal's socket, and to stderr in plain words.
	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect(t, !strings.contains(r.err, "<3>") && !strings.contains(r.err, "<4>"), r.err)
	testing.expect(t, strings.contains(r.err, "ravnix-notify: builds: giving up"), r.err)
	lines := journal_lines(f.journal)
	defer journal_lines_destroy(lines)
	gave_up, retried := 0, 0
	for l in lines {
		if strings.contains(l, "SYSLOG_IDENTIFIER=ravnix-notify\n") {
			if strings.contains(l, "PRIORITY=3\n") && strings.contains(l, "MESSAGE=builds: giving up after 4 tries") {
				gave_up += 1
			}
			if strings.contains(l, "PRIORITY=4\n") && strings.contains(l, "MESSAGE=builds: retry ") {
				retried += 1
			}
		}
	}
	testing.expectf(t, gave_up == 1, "%d give-up lines in the journal: %q", gave_up, lines)
	testing.expectf(t, retried == 3, "%d retry lines in the journal: %q", retried, lines)
}

@(test)
under_systemd_the_line_goes_to_stderr_with_its_priority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	// With stderr the stream that JOURNAL_STREAM names, a prefix gives the
	// line its priority, and a line sent to the socket as well would be a
	// second copy.
	r := run_notify(t, &f, {"--topic", "builds", "hello"}, {journal_stream = true})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect(t, strings.contains(r.err, "<4>ravnix-notify: builds: retry 1 of 3"), r.err)
	testing.expect(t, strings.contains(r.err, "<3>ravnix-notify: builds: giving up after 4 tries"), r.err)
	for l in strings.split_lines(r.err, context.temp_allocator) {
		testing.expectf(t, l == "" || strings.has_prefix(l, "<"), "a line without a priority: %q", l)
	}
	lines := journal_lines(f.journal)
	defer journal_lines_destroy(lines)
	testing.expect_value(t, len(lines), 0)
}

@(test)
a_missing_journal_does_not_hide_the_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"}, {no_journal = true})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect(t, strings.contains(r.err, "giving up"), r.err)
}

@(test)
retries_a_server_error_and_sends_the_same_transaction_each_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {
		{status = 503, body = `{"errcode":"M_UNKNOWN","error":"down for maintenance"}`},
		{status = 502, body = `<html>bad gateway</html>`},
		{status = 408, body = ``},
		OK_REPLY,
	})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	f.retry_base_ms = 30
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "updates", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), 4) {
		return
	}
	// One transaction id for the message, so a retry after a reply that was
	// lost does not post it twice.
	for req in reqs[1:] {
		testing.expect_value(t, txn_of(req), txn_of(reqs[0]))
	}
	for i in 1 ..< len(reqs) {
		want := time.Duration(30 << uint(i - 1)) * time.Millisecond
		got := time.tick_diff(reqs[i - 1].at, reqs[i].at)
		testing.expectf(t, got >= want, "request %d came after %v, backoff is %v", i + 1, got, want)
	}
	testing.expect(t, strings.contains(r.err, "retry 3 of 3"), r.err)
	testing.expect(t, !strings.contains(r.err, "giving up"), r.err)
}

@(test)
different_messages_get_different_transactions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	for _ in 0 ..< 5 {
		r := run_notify(t, &f, {"--topic", "updates", "same words"})
		ran_destroy(r)
	}
	seen := make(map[string]bool, context.temp_allocator)
	for req in fake_requests(server) {
		seen[txn_of(req)] = true
	}
	testing.expect_value(t, len(seen), 5)
}

@(test)
a_429_waits_as_long_as_the_homeserver_says :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {
		{status = 429, body = `{"errcode":"M_LIMIT_EXCEEDED","error":"Too many requests","retry_after_ms":400}`},
		OK_REPLY,
	})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	// A backoff far below the wait, so only the homeserver's word explains it.
	f.retry_base_ms = 5
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "sessions", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), 2) {
		return
	}
	gap := time.tick_diff(reqs[0].at, reqs[1].at)
	testing.expectf(t, gap >= 400 * time.Millisecond, "the retry came after %v, the homeserver said 400 ms", gap)
	testing.expectf(t, gap < 3 * time.Second, "the retry came after %v, long after the 400 ms", gap)
	testing.expect_value(t, txn_of(reqs[1]), txn_of(reqs[0]))
	testing.expect(t, strings.contains(r.err, "retry 1 of 3 in 400 ms"), r.err)
}

@(test)
a_429_without_a_usable_wait_uses_the_backoff :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bodies := [?]string{
		`{}`,
		``,
		`<html>`,
		`{"retry_after_ms":"400"}`,
		`{"retry_after_ms":-5}`,
		`{"retry_after_ms":0}`,
		`{"retry_after_ms":null}`,
		`{"retry_after_ms":1e400}`,
		`{"retry_after_ms":99999999999999999999999}`,
		`[400]`,
	}
	for body in bodies {
		server := fake_start(t, {{status = 429, body = body}, OK_REPLY})
		defer fake_stop(server)
		f := fixture_make(t, server.port)
		defer fixture_destroy(&f)
		f.retry_base_ms = 30
		fixture_write(t, &f)

		r := run_notify(t, &f, {"--topic", "sessions", "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == 0, "%q: exit %d: %s", body, r.code, r.err)
		reqs := fake_requests(server)
		if testing.expectf(t, len(reqs) == 2, "%q: %d requests", body, len(reqs)) {
			gap := time.tick_diff(reqs[0].at, reqs[1].at)
			testing.expectf(t, gap >= 30 * time.Millisecond && gap < 2 * time.Second, "%q: the retry came after %v", body, gap)
		}
	}
}

@(test)
a_429_that_asks_for_hours_is_not_waited_for :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {{status = 429, body = `{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":3600000}`}, OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "sessions", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect_value(t, len(fake_requests(server)), 1)
	testing.expectf(t, r.elapsed < 2 * time.Second, "took %v", r.elapsed)
	testing.expect(t, strings.contains(r.err, "3600000 ms"), r.err)
}

@(test)
a_429_uses_up_the_retries_like_any_other_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {{status = 429, body = `{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":20}`}})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "sessions", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect_value(t, len(fake_requests(server)), 4)
}

@(test)
a_homeserver_that_never_answers_times_out_and_is_retried :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {{hang = true}})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	f.timeout_secs = 0.3
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "sessions", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect_value(t, len(fake_requests(server)), 4)
	testing.expectf(t, r.elapsed < 10 * time.Second, "took %v", r.elapsed)
}

@(test)
a_connection_closed_without_an_answer_is_retried :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {{close_early = true}, OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "sessions", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, len(fake_requests(server)), 2)
}

// ---------------------------------------------------------------------------
// Answers that retrying does not change

@(test)
a_refused_token_exits_77_without_retrying :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for status in ([?]int{401, 403}) {
		server := fake_start(t, {{status = status, body = `{"errcode":"M_FORBIDDEN","error":"You are not in the room"}`}})
		defer fake_stop(server)
		f := fixture_make(t, server.port)
		defer fixture_destroy(&f)

		r := run_notify(t, &f, {"--topic", "builds", "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == notify.EX_NOPERM, "%d: exit %d", status, r.code)
		testing.expectf(t, strings.contains(r.err, "M_FORBIDDEN"), "%d: %s", status, r.err)
		testing.expectf(t, strings.contains(r.err, "You are not in the room"), "%d: %s", status, r.err)
		testing.expectf(t, len(fake_requests(server)) == 1, "%d: %d requests", status, len(fake_requests(server)))
	}
}

@(test)
other_refusals_exit_76_without_retrying :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [?]struct {
		status: int,
		body:   string,
		says:   string,
	}{
		{404, `{"errcode":"M_NOT_FOUND","error":"Unknown room"}`, "M_NOT_FOUND"},
		{400, `{"errcode":"M_BAD_JSON","error":"x"}`, "M_BAD_JSON"},
		{413, `{"errcode":"M_TOO_LARGE"}`, "M_TOO_LARGE"},
		{404, `<html>not found</html>`, "404"},
		{418, ``, "418"},
		// curl does not follow a redirect, so the token never leaves for
		// another host.
		{302, `moved`, "302"},
		{301, ``, "301"},
	}
	for c in cases {
		server := fake_start(t, {{status = c.status, body = c.body}})
		defer fake_stop(server)
		f := fixture_make(t, server.port)
		defer fixture_destroy(&f)

		r := run_notify(t, &f, {"--topic", "builds", "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == notify.EX_PROTOCOL, "%d %q: exit %d", c.status, c.body, r.code)
		testing.expectf(t, strings.contains(r.err, c.says), "%d: %s", c.status, r.err)
		testing.expectf(t, len(fake_requests(server)) == 1, "%d: %d requests", c.status, len(fake_requests(server)))
	}
}

@(test)
a_success_without_an_event_id_is_no_success :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// A captive portal answers 200 to anything.
	bodies := [?]string{`<html>log in to the Wi-Fi</html>`, `{}`, `[]`, ``, `{"event_id":7}`, `{"event_id":""}`, `null`}
	for body in bodies {
		server := fake_start(t, {{status = 200, body = body}})
		defer fake_stop(server)
		f := fixture_make(t, server.port)
		defer fixture_destroy(&f)

		r := run_notify(t, &f, {"--topic", "builds", "hello"})
		defer ran_destroy(r)
		testing.expectf(t, r.code == notify.EX_PROTOCOL, "%q: exit %d", body, r.code)
		testing.expectf(t, len(fake_requests(server)) == 1, "%q: %d requests", body, len(fake_requests(server)))
	}
}

@(test)
a_huge_answer_is_cut_off :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	huge := strings.repeat("x", 6 * 1024 * 1024)
	defer delete(huge)
	server := fake_start(t, {{status = 200, body = huge}})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_PROTOCOL)
	testing.expectf(t, len(r.err) < 4096, "the tool said %d bytes", len(r.err))
}

@(test)
a_curl_that_cannot_be_run_exits_69 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	os.remove(f.curl_path)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_UNAVAILABLE)
	testing.expect(t, strings.contains(r.err, "curl"), r.err)
	// No retry: another try finds the same missing file.
	testing.expect(t, !strings.contains(r.err, "retry"), r.err)
}

@(test)
a_homeserver_address_curl_refuses_exits_78 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	// Passes the config check, which wants only a scheme and no blanks;
	// curl will not take it.
	delete(f.homeserver)
	f.homeserver = strings.clone("http://[bad")
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_CONFIG)
	testing.expect(t, !strings.contains(r.err, "retry"), r.err)
}

// ---------------------------------------------------------------------------
// Large requests, and children that misbehave

@(test)
sends_a_request_larger_than_a_pipe :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	// Each of these is quoted for curl's config, which doubles what JSON
	// has already escaped: the request is over the 64 KiB a pipe holds, and
	// is written while curl reads.
	messages := [?]string{
		strings.repeat("\"", 7000, context.temp_allocator),
		strings.repeat("\\\\", 3000, context.temp_allocator),
		strings.repeat("a\nb ", 3500, context.temp_allocator),
	}
	for message in messages {
		r := run_notify(t, &f, {"--topic", "builds", message})
		defer ran_destroy(r)
		testing.expectf(t, r.code == 0, "exit %d: %s", r.code, r.err[:min(len(r.err), 300)])
	}
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), len(messages)) {
		return
	}
	for message, i in messages {
		testing.expect(t, len(reqs[i].body) > 15000)
		value, err := json.parse(transmute([]byte)reqs[i].body, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		obj, _ := value.(json.Object)
		testing.expect_value(t, body_string(obj, "body"), strings.trim_space(message))
	}
}

@(test)
a_curl_that_exits_without_reading_is_a_failed_try :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	curl_case := strings.concatenate({f.dir, "/curl-case.sh"})
	defer delete(curl_case)
	testing.expect_value(t, os.write_entire_file(curl_case, "exit 7\n"), nil)

	// The pipe's reader is gone while most of the request is still to be
	// written. The write is not tried on a pipe that poll reports broken.
	// (The window between that report and a write that gets SIGPIPE is too
	// narrow to hit on purpose; run_child ignores the signal as well.)
	big := strings.repeat("\"", 7000, context.temp_allocator)
	r := run_notify(t, &f, {"--topic", "builds", big})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_TEMPFAIL)
	testing.expect(t, strings.contains(r.err, "curl exit 7"), r.err[:min(len(r.err), 300)])
}

@(test)
a_vault_client_that_leaves_a_daemon_behind_is_not_waited_for :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)
	// rbw starts its agent on the first call, and the agent may keep the
	// pipes it was started with. The token is complete when rbw exits.
	f.rbw_get = `(exec sleep 3 &) ; printf '%s\n' tok-builds`
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expectf(t, r.elapsed < 2 * time.Second, "took %v", r.elapsed)
}

@(test)
a_vault_client_that_prints_without_end_is_stopped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)
	f.rbw_get = `exec yes tok`
	fixture_write(t, &f)

	r := run_notify(t, &f, {"--topic", "builds", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_UNAVAILABLE)
	testing.expect(t, strings.contains(r.err, "far more than an access token"), r.err[:min(len(r.err), 300)])
	testing.expectf(t, r.elapsed < 3 * time.Second, "took %v", r.elapsed)
}

@(test)
a_message_on_standard_input_over_the_limit_exits_65 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	huge := strings.repeat("x", 3_000_000, context.temp_allocator)
	r := run_notify(t, &f, {"--topic", "builds", "-"}, {stdin = huge})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_DATAERR)
	testing.expect(t, strings.contains(r.err, "too large"), r.err[:min(len(r.err), 300)])
}

@(test)
a_topic_with_control_characters_is_not_echoed_raw :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--topic", "\x1b]0;owned\x07\nPRIORITY=0", "hello"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_USAGE)
	testing.expect(t, !strings.contains(r.err, "\x1b") && !strings.contains(r.err, "\x07"), r.err)
	testing.expect(t, strings.contains(r.err, "unknown topic"), r.err)
}

// ---------------------------------------------------------------------------
// --dry-run

@(test)
dry_run_prints_the_request_and_touches_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--dry-run", "--topic", "services", "**down**"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.err, "")
	room := room_of("services")
	defer delete(room)
	encoded := notify.percent_encode(room)
	defer delete(encoded)
	want_url := strings.concatenate({"PUT ", f.homeserver, ROOM_PATH, encoded, "/send/m.room.message/<transaction id>\n"})
	defer delete(want_url)
	testing.expectf(t, strings.has_prefix(r.out, want_url), "the output starts: %s", r.out)
	testing.expect(t, strings.contains(r.out, `"formatted_body":"<p><strong>down</strong></p>"`), r.out)
	testing.expect_value(t, len(fake_requests(server)), 0)
	rbw := file_in(&f, "rbw-calls")
	defer delete(rbw)
	curl := file_in(&f, "curl-calls")
	defer delete(curl)
	testing.expect_value(t, rbw, "")
	testing.expect_value(t, curl, "")

	// The same output twice: the bench counts it.
	r2 := run_notify(t, &f, {"--dry-run", "--topic", "services", "**down**"})
	defer ran_destroy(r2)
	testing.expect_value(t, r2.out, r.out)
}

@(test)
dry_run_still_refuses_what_a_real_run_refuses :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f := fixture_make(t, free_port(t))
	defer fixture_destroy(&f)

	r := run_notify(t, &f, {"--dry-run", "--topic", "nonsense", "x"})
	defer ran_destroy(r)
	testing.expect_value(t, r.code, notify.EX_USAGE)
	big := strings.repeat("x", 100_000)
	defer delete(big)
	r2 := run_notify(t, &f, {"--dry-run", "--topic", "builds", big})
	defer ran_destroy(r2)
	testing.expect_value(t, r2.code, notify.EX_DATAERR)
}

// ---------------------------------------------------------------------------
// Runs at the same time

Worker :: struct {
	f:        ^Fixture,
	topic:    string,
	message:  string,
	code:     int,
	err:      string,
	finished: bool,
}

@(private = "file")
work :: proc(data: rawptr) {
	w := cast(^Worker)data
	context.allocator = runtime.heap_allocator()
	err_b := strings.builder_make()
	defer strings.builder_destroy(&err_b)
	stdin, _ := os.open("/dev/null")
	defer os.close(stdin)
	env := notify.Env {
		stdin          = stdin,
		out            = strings.to_writer(&err_b),
		err            = strings.to_writer(&err_b),
		journal_socket = w.f.journal_path,
	}
	args := []string{"--config", w.f.config_path, "--topic", w.topic, w.message}
	w.code = notify.run(args, env)
	w.err = strings.clone(strings.to_string(err_b))
	sync.atomic_store(&w.finished, true)
}

@(test)
runs_at_the_same_time_all_land :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	server := fake_start(t, {OK_REPLY})
	defer fake_stop(server)
	f := fixture_make(t, server.port)
	defer fixture_destroy(&f)

	N :: 8
	workers: [N]Worker
	threads: [N]^thread.Thread
	messages: [N]string
	for i in 0 ..< N {
		messages[i] = fmt.tprintf("message number %d", i)
		workers[i] = Worker{f = &f, topic = TOPICS[i % len(TOPICS)], message = messages[i]}
	}
	for i in 0 ..< N {
		threads[i] = thread.create_and_start_with_data(&workers[i], work)
	}
	for i in 0 ..< N {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	for w in workers {
		testing.expectf(t, w.code == 0, "exit %d: %s", w.code, w.err)
		delete(w.err, runtime.heap_allocator())
	}
	reqs := fake_requests(server)
	if !testing.expect_value(t, len(reqs), N) {
		return
	}
	txns := make(map[string]bool, context.temp_allocator)
	bodies := make(map[string]bool, context.temp_allocator)
	for req in reqs {
		txns[txn_of(req)] = true
		value, err := json.parse(transmute([]byte)req.body, allocator = context.temp_allocator)
		if err == .None {
			obj, _ := value.(json.Object)
			bodies[body_string(obj, "body")] = true
		}
	}
	testing.expect_value(t, len(txns), N)
	for m in messages {
		testing.expectf(t, bodies[m], "%q never arrived", m)
	}
}
