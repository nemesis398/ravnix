// The tests of the small parts: the command line, the config file, the
// encodings that put a message and a room id into a request, and the event
// that carries the message. None of them starts a process or opens a socket.
package ravnix_notify_tests

import "core:encoding/json"
import "core:strings"
import "core:testing"
import notify ".."

// ---------------------------------------------------------------------------
// The command line

@(test)
reads_a_topic_and_a_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, err := notify.parse_args({"--topic", "builds", "build", "failed"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.topic, "builds")
	testing.expect_value(t, a.message, "build failed")
	testing.expect(t, !a.from_stdin && !a.dry_run && !a.help)
	testing.expect_value(t, a.config_path, notify.DEFAULT_CONFIG)

	a, err = notify.parse_args({"--topic=updates", "one"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.topic, "updates")
	testing.expect_value(t, a.message, "one")

	a, err = notify.parse_args({"one", "--topic", "updates"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.topic, "updates")
	testing.expect_value(t, a.message, "one")
}

@(test)
reads_the_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, err := notify.parse_args({"--config", "/x/c.json", "--dry-run", "--topic", "sessions", "m"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.config_path, "/x/c.json")
	testing.expect(t, a.dry_run)

	a, err = notify.parse_args({"--config=/y.json", "--topic", "sessions", "m"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.config_path, "/y.json")

	a, err = notify.parse_args({"--help"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, a.help)
	a, err = notify.parse_args({"-h"}, context.temp_allocator)
	testing.expect(t, a.help)
}

@(test)
takes_everything_after_two_dashes_as_the_message :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, err := notify.parse_args({"--topic", "builds", "--", "--dry-run", "-", "--topic"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.message, "--dry-run - --topic")
	testing.expect(t, !a.dry_run && !a.from_stdin)
}

@(test)
reads_the_message_from_standard_input_on_a_dash :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, err := notify.parse_args({"--topic", "builds", "-"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, a.from_stdin)
	testing.expect_value(t, a.message, "")

	// A dash among words is a word.
	a, err = notify.parse_args({"--topic", "builds", "a", "-", "b"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, !a.from_stdin)
	testing.expect_value(t, a.message, "a - b")
}

@(test)
refuses_a_bad_command_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bad := [?][]string{
		{},
		{"msg"},
		{"--topic"},
		{"--topic", "builds"},
		{"--topic", "", "msg"},
		{"--topic=", "msg"},
		{"--topic", "builds", "--topic", "updates", "msg"},
		{"--topic", "builds", "--bogus", "msg"},
		{"--topic", "builds", "--config"},
		{"--topic", "builds", "--config", "", "msg"},
		{"--topic", "builds", "--config", "a", "--config", "b", "msg"},
		{"--topic", "builds", "--"},
		{"--topic", "builds", "", ""},
		{"--topic", "builds", "   \n\t "},
	}
	for args in bad {
		_, err := notify.parse_args(args, context.temp_allocator)
		testing.expectf(t, err != "", "parse_args(%q) was accepted", args)
	}
}

// ---------------------------------------------------------------------------
// The config file

VALID_CONFIG :: `{
  "homeserver": "https://matrix.example.org/",
  "rbw": "/bin/rbw",
  "rooms": {
    "sessions": { "roomId": "!abc:example.org", "tokenItem": "Matrix - access token (ravnix-sessions)" },
    "builds":   { "roomId": null, "tokenItem": "Matrix - access token (ravnix-builds)" }
  }
}`

@(test)
reads_a_config :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg, err := notify.parse_config(transmute([]byte)string(VALID_CONFIG), context.temp_allocator)
	testing.expect_value(t, err, "")
	// The slash at the end goes: paths are joined to it.
	testing.expect_value(t, cfg.homeserver, "https://matrix.example.org")
	testing.expect_value(t, cfg.rbw, "/bin/rbw")
	testing.expect_value(t, cfg.curl, notify.CURL)
	testing.expect_value(t, len(cfg.rooms), 2)
	testing.expect_value(t, cfg.rooms["sessions"].room_id, "!abc:example.org")
	testing.expect_value(t, cfg.rooms["sessions"].token_item, "Matrix - access token (ravnix-sessions)")
	// A room that does not exist yet has no id.
	testing.expect_value(t, cfg.rooms["builds"].room_id, "")
	testing.expect_value(t, cfg.retry_base_ms, notify.DEFAULT_RETRY_BASE_MS)
	testing.expect_value(t, cfg.timeout_secs, notify.DEFAULT_TIMEOUT_SECS)
	testing.expect_value(t, cfg.rbw_timeout_ms, notify.DEFAULT_RBW_TIMEOUT_MS)
}

@(test)
reads_the_tuning_of_a_config :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `{"homeserver":"http://127.0.0.1:8008","rbw":"r","curl":"/c","retryBaseMs":5,"timeoutSecs":0.5,"rbwTimeoutMs":100,"rooms":{}}`
	cfg, err := notify.parse_config(transmute([]byte)text, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, cfg.curl, "/c")
	testing.expect_value(t, cfg.retry_base_ms, 5)
	testing.expect_value(t, cfg.timeout_secs, 0.5)
	testing.expect_value(t, cfg.rbw_timeout_ms, 100)
	testing.expect_value(t, len(cfg.rooms), 0)
}

@(test)
refuses_a_bad_config :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	R :: `"rooms":{"a":{"roomId":"!a:x","tokenItem":"t"}}`
	bad := [?]struct {
		name, text, names: string,
	}{
		{"empty", ``, ""},
		{"not JSON", `homeserver = x`, ""},
		{"truncated", `{"homeserver":"http://h"`, ""},
		{"an array", `[]`, "object"},
		{"a string", `"x"`, "object"},
		{"no homeserver", `{"rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver is a number", `{"homeserver":1,"rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver without a scheme", `{"homeserver":"matrix.example.org","rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver is ftp", `{"homeserver":"ftp://h","rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver with a space", `{"homeserver":"http://h x","rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver with a newline", `{"homeserver":"http://h\nurl = x","rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver with a quote", `{"homeserver":"http://h\"","rbw":"r",` + R + `}`, "homeserver"},
		{"homeserver with only a scheme", `{"homeserver":"https://","rbw":"r",` + R + `}`, "homeserver"},
		{"no rbw", `{"homeserver":"http://h",` + R + `}`, "rbw"},
		{"empty rbw", `{"homeserver":"http://h","rbw":"",` + R + `}`, "rbw"},
		{"curl is a list", `{"homeserver":"http://h","rbw":"r","curl":[],` + R + `}`, "curl"},
		{"no rooms", `{"homeserver":"http://h","rbw":"r"}`, "rooms"},
		{"rooms is a list", `{"homeserver":"http://h","rbw":"r","rooms":[]}`, "rooms"},
		{"a room is a string", `{"homeserver":"http://h","rbw":"r","rooms":{"a":"x"}}`, "rooms.a"},
		{"a room without a token item", `{"homeserver":"http://h","rbw":"r","rooms":{"a":{"roomId":"!a:x"}}}`, "rooms.a.tokenItem"},
		{"an empty token item", `{"homeserver":"http://h","rbw":"r","rooms":{"a":{"roomId":"!a:x","tokenItem":""}}}`, "rooms.a.tokenItem"},
		{"a room id without !", `{"homeserver":"http://h","rbw":"r","rooms":{"a":{"roomId":"a:x","tokenItem":"t"}}}`, "rooms.a.roomId"},
		{"a room id with a space", `{"homeserver":"http://h","rbw":"r","rooms":{"a":{"roomId":"!a b:x","tokenItem":"t"}}}`, "rooms.a.roomId"},
		{"a room id that is a number", `{"homeserver":"http://h","rbw":"r","rooms":{"a":{"roomId":7,"tokenItem":"t"}}}`, "rooms.a.roomId"},
		{"a negative backoff", `{"homeserver":"http://h","rbw":"r","retryBaseMs":-1,` + R + `}`, "retryBaseMs"},
		{"a backoff that is text", `{"homeserver":"http://h","rbw":"r","retryBaseMs":"1",` + R + `}`, "retryBaseMs"},
		{"a backoff over a minute", `{"homeserver":"http://h","rbw":"r","retryBaseMs":60001,` + R + `}`, "retryBaseMs"},
		{"a timeout of zero", `{"homeserver":"http://h","rbw":"r","timeoutSecs":0,` + R + `}`, "timeoutSecs"},
		{"a negative timeout", `{"homeserver":"http://h","rbw":"r","timeoutSecs":-3,` + R + `}`, "timeoutSecs"},
		{"a timeout over ten minutes", `{"homeserver":"http://h","rbw":"r","timeoutSecs":601,` + R + `}`, "timeoutSecs"},
		{"an rbw timeout of zero", `{"homeserver":"http://h","rbw":"r","rbwTimeoutMs":0,` + R + `}`, "rbwTimeoutMs"},
	}
	for c in bad {
		_, err := notify.parse_config(transmute([]byte)c.text, context.temp_allocator)
		testing.expectf(t, err != "", "%s: the config was accepted", c.name)
		testing.expectf(t, strings.contains(err, c.names), "%s: the message %q does not name %q", c.name, err, c.names)
	}
}

// ---------------------------------------------------------------------------
// The encodings

@(test)
percent_encodes_a_room_id :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{"!AbC123:example.org", "%21AbC123%3Aexample.org"},
		{"!room_version_12-id", "%21room_version_12-id"},
		{"a/b?c#d e%f", "a%2Fb%3Fc%23d%20e%25f"},
		{"-._~", "-._~"},
		{"ü日🎉", "%C3%BC%E6%97%A5%F0%9F%8E%89"},
		{"\x00\r\n\"\\", "%00%0D%0A%22%5C"},
		{"", ""},
	}
	for c in cases {
		got := notify.percent_encode(c[0])
		defer delete(got)
		testing.expectf(t, got == c[1], "percent_encode(%q) = %q, want %q", c[0], got, c[1])
	}
}

@(test)
quotes_for_a_curl_config :: proc(t: ^testing.T) {
	cases := [?][2]string{
		{`plain`, `plain`},
		{`a"b`, `a\"b`},
		{`a\b`, `a\\b`},
		{`{"k":"v\n"}`, `{\"k\":\"v\\n\"}`},
		{`ü日🎉`, `ü日🎉`},
		{``, ``},
	}
	for c in cases {
		got, ok := notify.curl_quote(c[0])
		defer delete(got)
		testing.expect(t, ok)
		testing.expectf(t, got == c[1], "curl_quote(%q) = %q, want %q", c[0], got, c[1])
	}
	// A line break would end the value and start another line: an option
	// of the sender's choosing. None is quoted.
	for bad in ([?]string{"a\nb", "a\rb", "a\x00b", "a\x0bb", "a\x1bb", "\x7f"}) {
		got, ok := notify.curl_quote(bad)
		testing.expectf(t, !ok, "curl_quote(%q) = %q", bad, got)
		delete(got)
	}
}

// ---------------------------------------------------------------------------
// The event

Event_Fields :: struct {
	msgtype, body, format, formatted_body: string,
}

// parse_event reads the event's JSON back, with the allocator, and says
// whether it is a JSON object of four strings.
parse_event :: proc(t: ^testing.T, text: string) -> (e: Event_Fields, ok: bool) {
	value, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
	if !testing.expectf(t, err == .None, "not JSON (%v): %s", err, text) {
		return
	}
	obj, is_obj := value.(json.Object)
	if !testing.expect(t, is_obj) {
		return
	}
	get :: proc(t: ^testing.T, obj: json.Object, key: string) -> string {
		s, is_str := obj[key].(json.String)
		testing.expectf(t, is_str, "%s is no string", key)
		return string(s)
	}
	e = {get(t, obj, "msgtype"), get(t, obj, "body"), get(t, obj, "format"), get(t, obj, "formatted_body")}
	testing.expect_value(t, len(obj), 4)
	return e, true
}

@(test)
builds_an_event_with_markdown_as_formatted_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text, err := notify.build_event("**build** failed on `huginn`")
	defer delete(text)
	testing.expect_value(t, err, notify.Event_Error.None)
	e, ok := parse_event(t, text)
	if !ok {
		return
	}
	// m.text, not m.notice: the default push rules keep m.notice from
	// notifying a phone.
	testing.expect_value(t, e.msgtype, "m.text")
	testing.expect_value(t, e.body, "**build** failed on `huginn`")
	testing.expect_value(t, e.format, "org.matrix.custom.html")
	testing.expect_value(t, e.formatted_body, "<p><strong>build</strong> failed on <code>huginn</code></p>")
}

@(test)
encodes_what_json_must_escape :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	messages := [?]string{
		"quote \" backslash \\ slash /",
		"tab\there\nnewline\r\nand\x01\x02\x1f control",
		"nul\x00in the middle",
		"del\x7f",
		"日本語 ü 🎉    ",
		"{\"msgtype\":\"m.notice\"}",
		"</script><!-- -->",
	}
	for m in messages {
		text, err := notify.build_event(m)
		defer delete(text)
		testing.expect_value(t, err, notify.Event_Error.None)
		// No raw control byte may be left: the JSON goes through a line
		// based config.
		for c in transmute([]byte)text {
			testing.expectf(t, c >= 0x20 && c != 0x7f, "a raw control byte %x in %q", c, text)
		}
		e, ok := parse_event(t, text)
		if ok {
			testing.expect_value(t, e.body, m)
		}
	}
}

@(test)
replaces_bytes_that_are_not_utf8 :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// A log excerpt can end in the middle of a character.
	text, err := notify.build_event("ok \xff\xfe broken \xe6\x97")
	defer delete(text)
	testing.expect_value(t, err, notify.Event_Error.None)
	e, ok := parse_event(t, text)
	if ok {
		testing.expect(t, strings.contains(e.body, "ok �"))
		testing.expect(t, strings.contains(e.body, "broken �"))
		testing.expect(t, !strings.contains(e.body, "\xff"))
	}
}

@(test)
refuses_an_event_that_is_too_large :: proc(t: ^testing.T) {
	// Synapse refuses an event over 65536 bytes; the tool refuses before it
	// asks, instead of cutting the message.
	big := strings.repeat("x", notify.MAX_EVENT_BYTES)
	defer delete(big)
	text, err := notify.build_event(big)
	defer delete(text)
	testing.expect_value(t, err, notify.Event_Error.Too_Large)
	testing.expect_value(t, text, "")

	// The HTML can be much longer than the text: every < becomes &lt;.
	angle := strings.repeat("<", notify.MAX_EVENT_BYTES / 2)
	defer delete(angle)
	text2, err2 := notify.build_event(angle)
	defer delete(text2)
	testing.expect_value(t, err2, notify.Event_Error.Too_Large)

	fits := strings.repeat("x", 20000)
	defer delete(fits)
	text3, err3 := notify.build_event(fits)
	defer delete(text3)
	testing.expect_value(t, err3, notify.Event_Error.None)
	testing.expect(t, len(text3) < notify.MAX_EVENT_BYTES)
}
