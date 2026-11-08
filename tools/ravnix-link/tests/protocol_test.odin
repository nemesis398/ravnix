// The tests of the wire format: a request as one JSON line, a reply and a
// record, what each refuses, and the ids.
package ravnix_link_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import link ".."

// A path with spaces, umlauts and an en dash, as German notes have them.
ODD_PATH :: "Notizen/Über Grüße – Entwurf.md"

scratch :: proc(t: ^testing.T) -> (arena: virtual.Arena) {
	if virtual.arena_init_growing(&arena) != nil {
		testing.fail_now(t, "no memory")
	}
	return
}

// The paths of the commit in base_request; a slice of a literal in a
// procedure would point into its frame.
COMMIT_PATHS := [?]string{ODD_PATH, "Notizen/Neu – Grüße.md"}

base_request :: proc(kind: link.Kind) -> link.Request {
	r := link.Request {
		id      = "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d",
		kind    = kind,
		created = "2026-11-08T12:00:00Z",
	}
	switch kind {
	case .Open:
		r.target = "https://example.org/a b?q=1"
	case .Notify:
		r.summary = "Claude fragt"
		r.body = "Darf ich?"
	case .Obsidian:
		r.op = .Rename
		r.path = ODD_PATH
		r.name = "Neu – Grüße"
	case .Vault_Commit:
		r.vault = "/home/alice/vault"
		r.message = "vault: rename a note"
		r.paths = COMMIT_PATHS[:]
	}
	return r
}

round_trip :: proc(t: ^testing.T, r: link.Request, loc := #caller_location) -> link.Request {
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	line, why := link.encode_request(r, a)
	testing.expect_value(t, why, "", loc = loc)
	testing.expect(t, strings.has_suffix(line, "\n"), "a request line ends with a newline", loc = loc)
	testing.expect_value(t, strings.count(line, "\n"), 1, loc = loc)
	back, bwhy := link.decode_request(line, context.temp_allocator)
	testing.expect_value(t, bwhy, "", loc = loc)
	return back
}

expect_same :: proc(t: ^testing.T, a, b: link.Request, loc := #caller_location) {
	testing.expect_value(t, a.id, b.id, loc = loc)
	testing.expect_value(t, a.kind, b.kind, loc = loc)
	testing.expect_value(t, a.created, b.created, loc = loc)
	testing.expect_value(t, a.target, b.target, loc = loc)
	testing.expect_value(t, a.summary, b.summary, loc = loc)
	testing.expect_value(t, a.body, b.body, loc = loc)
	testing.expect_value(t, a.urgency, b.urgency, loc = loc)
	testing.expect_value(t, a.app, b.app, loc = loc)
	testing.expect_value(t, a.op, b.op, loc = loc)
	testing.expect_value(t, a.path, b.path, loc = loc)
	testing.expect_value(t, a.to, b.to, loc = loc)
	testing.expect_value(t, a.name, b.name, loc = loc)
	testing.expect_value(t, a.vault, b.vault, loc = loc)
	testing.expect_value(t, a.message, b.message, loc = loc)
	testing.expect_value(t, len(a.paths), len(b.paths), loc = loc)
	for p, i in a.paths {
		if i < len(b.paths) {
			testing.expect_value(t, p, b.paths[i], loc = loc)
		}
	}
}

@(test)
every_kind_round_trips :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for kind in link.Kind {
		r := base_request(kind)
		expect_same(t, r, round_trip(t, r))
	}
	move := base_request(.Obsidian)
	move.op, move.name, move.to = .Move, "", "Archiv/Über – alt"
	expect_same(t, move, round_trip(t, move))
	del := base_request(.Obsidian)
	del.op, del.name = .Delete, ""
	expect_same(t, del, round_trip(t, del))
	n := base_request(.Notify)
	n.urgency, n.app, n.body = "critical", "Claude Code", ""
	expect_same(t, n, round_trip(t, n))
	c := base_request(.Vault_Commit)
	c.paths = nil
	expect_same(t, c, round_trip(t, c))
}

@(test)
a_path_with_spaces_umlauts_and_an_en_dash_round_trips :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	r := base_request(.Obsidian)
	back := round_trip(t, r)
	testing.expect_value(t, back.path, ODD_PATH)
	testing.expect_value(t, back.name, "Neu – Grüße")
	o := base_request(.Open)
	o.target = "/home/alice/Nextcloud/Über Grüße – Entwurf.pdf"
	testing.expect_value(t, round_trip(t, o).target, o.target)
}

@(test)
control_characters_survive_the_line :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	every := strings.builder_make(context.temp_allocator)
	for c in 1 ..< 0x20 {
		strings.write_byte(&every, u8(c))
	}
	strings.write_string(&every, "\x7f \"quoted\" back\\slash     tab\there\r\n")
	r := base_request(.Notify)
	r.body = strings.to_string(every)
	r.summary = "line one\nline two"
	arena := scratch(t)
	defer virtual.arena_destroy(&arena)
	line, why := link.encode_request(r, virtual.arena_allocator(&arena))
	testing.expect_value(t, why, "")
	// One line on disk, and plain ASCII for every control character.
	testing.expect_value(t, strings.count(line, "\n"), 1)
	for i in 0 ..< len(line) - 1 {
		testing.expect(t, line[i] >= 0x20 && line[i] != 0x7f, "a control character went into the line raw")
	}
	back := round_trip(t, r)
	testing.expect_value(t, back.body, r.body)
	testing.expect_value(t, back.summary, r.summary)
	m := base_request(.Vault_Commit)
	m.message = "subject\n\nbody with\ttab and \x1b[31mescape\x1b[0m"
	testing.expect_value(t, round_trip(t, m).message, m.message)
}

@(test)
invalid_utf8_is_refused_with_an_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := []string{"\xff", "abc\xc3", "\xed\xa0\x80", "\xc0\xaf", "ok \xe2\x80"}
	for bad in cases {
		r := base_request(.Notify)
		r.body = bad
		why := link.check_request(r)
		testing.expectf(t, contains(why, "UTF-8"), "body %q: %q", bad, why)
		line, ewhy := link.encode_request(r, context.temp_allocator)
		testing.expect_value(t, line, "")
		testing.expect(t, contains(ewhy, "UTF-8"))
		p := base_request(.Obsidian)
		p.path = strings.concatenate({"Notizen/", bad, ".md"}, context.temp_allocator)
		testing.expect(t, contains(link.check_request(p), "UTF-8"))
	}
	// The same bytes in a line from elsewhere, raw or as an escaped lone
	// surrogate, are refused on the way in.
	good, _ := link.encode_request(base_request(.Notify), context.temp_allocator)
	raw, _ := strings.replace(good, "Darf ich?", "Darf \xff ich?", 1, context.temp_allocator)
	_, why := link.decode_request(raw, context.temp_allocator)
	testing.expect(t, why != "", "a raw invalid byte decoded")
	lone, _ := strings.replace(good, "Darf ich?", "Darf \\ud800 ich?", 1, context.temp_allocator)
	_, why = link.decode_request(lone, context.temp_allocator)
	testing.expect(t, why != "", "a lone surrogate decoded")
}

@(test)
a_nul_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	r := base_request(.Notify)
	r.body = "a\x00b"
	testing.expect(t, contains(link.check_request(r), "NUL"))
	good, _ := link.encode_request(base_request(.Notify), context.temp_allocator)
	nul, _ := strings.replace(good, "Darf ich?", "Darf \\u0000 ich?", 1, context.temp_allocator)
	_, why := link.decode_request(nul, context.temp_allocator)
	testing.expect(t, contains(why, "NUL"), why)
}

@(test)
a_ten_megabyte_body_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	r := base_request(.Notify)
	r.body = strings.repeat("x", 10 * 1024 * 1024, context.temp_allocator)
	line, why := link.encode_request(r, context.temp_allocator)
	testing.expect_value(t, line, "")
	testing.expectf(t, contains(why, "65536"), "the error names the limit: %q", why)
	// Just inside the limit is fine, one byte more is not.
	r.body = ""
	empty, _ := link.encode_request(r, context.temp_allocator)
	r.body = strings.repeat("y", link.MAX_LINE - len(empty), context.temp_allocator)
	at, at_why := link.encode_request(r, context.temp_allocator)
	testing.expect_value(t, at_why, "")
	testing.expect_value(t, len(at), link.MAX_LINE)
	r.body = strings.repeat("y", link.MAX_LINE - len(empty) + 1, context.temp_allocator)
	over, over_why := link.encode_request(r, context.temp_allocator)
	testing.expect_value(t, over, "")
	testing.expect(t, over_why != "")
	// A line that long from elsewhere is refused on the way in, unread.
	long := strings.concatenate({`{"id":"`, strings.repeat("a", 70_000, context.temp_allocator), `"}`}, context.temp_allocator)
	_, dwhy := link.decode_request(long, context.temp_allocator)
	testing.expect(t, contains(dwhy, "65536"), dwhy)
}

@(test)
decode_refuses_what_is_not_a_request :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	id :: `"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d"`
	at :: `"created":"2026-11-08T12:00:00Z"`
	bad := []string {
		"",
		"   ",
		"not json",
		"[]",
		`"a string"`,
		`{}`,
		`{` + id + `}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"},` + at + `} {}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"},` + at + `,"extra":1}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org","more":"x"},` + at + `}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"},` + at + `,` + id + `}`,
		`{` + id + `,"kind":"run","args":{"target":"https://example.org"},` + at + `}`,
		`{` + id + `,"kind":"open","args":{"target":5},` + at + `}`,
		`{` + id + `,"kind":"open","args":["https://example.org"],` + at + `}`,
		`{` + id + `,"kind":"open","args":{},` + at + `}`,
		`{` + id + `,"kind":"open","args":{"summary":"x","body":"y"},` + at + `}`,
		`{"id":"not-a-uuid","kind":"open","args":{"target":"https://example.org"},` + at + `}`,
		`{"id":"0B9A1C2E-4F5D-4A6B-8C7D-9E0F1A2B3C4D","kind":"open","args":{"target":"https://example.org"},` + at + `}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"},"created":"yesterday"}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"},"created":"2026-11-08T12:00:00Zjunk"}`,
		`{` + id + `,"kind":"open","args":{"target":"https://example.org"}}`,
		`{` + id + `,"kind":"obsidian","args":{"op":"rename","path":"a.md"},` + at + `}`,
		`{` + id + `,"kind":"obsidian","args":{"op":"delete","path":"a.md","permanent":"yes"},` + at + `}`,
		`{` + id + `,"kind":"obsidian","args":{"op":"shred","path":"a.md"},` + at + `}`,
		`{` + id + `,"kind":"vault-commit","args":{"vault":"/v","message":"m","paths":"a.md"},` + at + `}`,
		`{` + id + `,"kind":"vault-commit","args":{"vault":"/v","message":"m","paths":[1]},` + at + `}`,
		strings.concatenate({`{"x":`, strings.repeat("[", 5000, context.temp_allocator), strings.repeat("]", 5000, context.temp_allocator), `}`}, context.temp_allocator),
	}
	for line in bad {
		_, why := link.decode_request(line, context.temp_allocator)
		testing.expectf(t, why != "", "decoded what is not a request: %q", line)
	}
	good := `{` + id + `,"kind":"open","args":{"target":"https://example.org"},` + at + `}`
	_, why := link.decode_request(good, context.temp_allocator)
	testing.expect_value(t, why, "")
	_, why = link.decode_request(strings.concatenate({good, "\n"}, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, why, "")
}

@(test)
ids_are_uuids_and_distinct :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	seen := make(map[string]struct{}, context.temp_allocator)
	for _ in 0 ..< 1000 {
		id := link.new_id(context.temp_allocator)
		testing.expect(t, link.is_uuid(id), id)
		testing.expect_value(t, len(id), 36)
		testing.expect_value(t, id[14], '4')
		testing.expect(t, strings.index_byte("89ab", id[19]) >= 0, id)
		testing.expect(t, !(id in seen), "an id came twice")
		seen[id] = {}
	}
	for bad in ([]string{"", "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4", "0b9a1c2e04f5d-4a6b-8c7d-9e0f1a2b3c4d", "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4g"}) {
		testing.expect(t, !link.is_uuid(bad), bad)
	}
}

@(test)
obsidian_requests_name_a_note_by_its_path_in_the_vault :: proc(t: ^testing.T) {
	r := base_request(.Obsidian)
	testing.expect_value(t, link.check_request(r), "")
	cases := []struct {
		op:       link.Obsidian_Op,
		path, to, name: string,
		refusal:  string,
	} {
		{.Rename, "", "", "Neu", "path"},
		{.Rename, "/home/alice/vault/a.md", "", "Neu", "relative"},
		{.Rename, "../a.md", "", "Neu", ".."},
		{.Rename, "a/./b.md", "", "Neu", "."},
		{.Rename, "a//b.md", "", "Neu", "empty"},
		{.Rename, "a/", "", "Neu", "empty"},
		{.Rename, "a\nb.md", "", "Neu", "control"},
		{.Rename, "a.md", "", "", "name"},
		{.Rename, "a.md", "", "sub/Neu", "/"},
		{.Rename, "a.md", "", "..", "name"},
		{.Rename, "a.md", "b", "Neu", "to="},
		{.Move, "a.md", "", "", "to"},
		{.Move, "a.md", "/abs", "", "relative"},
		{.Move, "a.md", "x/../../y", "", ".."},
		{.Move, "a.md", "b", "Neu", "name="},
		{.Delete, "a.md", "b", "", "to="},
		{.Delete, "a.md", "", "b", "name="},
		{.None, "a.md", "", "", "operation"},
	}
	for c in cases {
		x := r
		x.op, x.path, x.to, x.name = c.op, c.path, c.to, c.name
		why := link.check_request(x)
		testing.expectf(t, contains(why, c.refusal), "%v path=%q to=%q name=%q: %q", c.op, c.path, c.to, c.name, why)
	}
	long := r
	long.path = strings.repeat("a", 5000, context.temp_allocator)
	testing.expect(t, link.check_request(long) != "")
	free_all(context.temp_allocator)
}

// open takes http, https and mailto links, written in lowercase, and
// absolute paths; a note opens by its path. Obsidian's URIs would hand the
// server its actions on the laptop (obsidian://new with &overwrite replaces
// a note), and file: adds nothing to a path.
@(test)
open_takes_web_and_mail_links_and_absolute_paths_and_nothing_else :: proc(t: ^testing.T) {
	ok := []string {
		"https://example.org/path?q=a b",
		"http://localhost:8080/",
		"mailto:alice@example.org",
		"/home/alice/Nextcloud/Über – x.pdf",
		"/home/alice/notes/Notizen/a.md",
		"/x:y",
	}
	for target in ok {
		r := base_request(.Open)
		r.target = target
		testing.expectf(t, link.check_request(r) == "", "%q: %q", target, link.check_request(r))
	}
	refused := []string {
		"",
		"obsidian://new?vault=v&file=Notizen%2Fa&content=x&overwrite",
		"obsidian://open?vault=v&file=Notizen%2Fa",
		"file:///home/alice/Nextcloud/x.pdf",
		"javascript:alert(1)",
		"HTTPS://EXAMPLE.ORG/",
		"Https://example.org/",
		"MailTo:alice@example.org",
		"steam://run/1",
		"vscode://file/x",
		"relative/x.pdf",
		"x.pdf",
		"https://example.org/\n",
	}
	for target in refused {
		r := base_request(.Open)
		r.target = target
		why := link.check_request(r)
		testing.expectf(t, why != "", "%q was taken", target)
	}
	r := base_request(.Open)
	r.target = "obsidian://new?file=a&overwrite"
	testing.expect(t, contains(link.check_request(r), "not obsidian:"), link.check_request(r))
}

@(test)
notify_and_commit_requests_are_checked :: proc(t: ^testing.T) {
	n := base_request(.Notify)
	n.summary = ""
	testing.expect(t, contains(link.check_request(n), "summary"))
	n = base_request(.Notify)
	n.urgency = "urgent"
	testing.expect(t, contains(link.check_request(n), "urgency"))
	for u in ([]string{"", "low", "normal", "critical"}) {
		n.urgency = u
		testing.expect_value(t, link.check_request(n), "")
	}
	c := base_request(.Vault_Commit)
	c.message = ""
	testing.expect(t, contains(link.check_request(c), "message"))
	c = base_request(.Vault_Commit)
	c.vault = "relative/vault"
	testing.expect(t, contains(link.check_request(c), "vault"))
	c = base_request(.Vault_Commit)
	c.paths = {"../outside.md"}
	testing.expect(t, contains(link.check_request(c), ".."))
	c = base_request(.Vault_Commit)
	many := make([]string, link.MAX_PATHS + 1, context.temp_allocator)
	for &p in many {
		p = "a.md"
	}
	c.paths = many
	testing.expect(t, contains(link.check_request(c), "paths"))
	free_all(context.temp_allocator)
}

@(test)
replies_and_records_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	id :: "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d"
	for status in link.Status {
		rep := link.Reply{id = id, status = status}
		if status != .Done {
			rep.error = "Error: Datei \"x\" nicht gefunden\nzweite Zeile"
		}
		line := link.encode_reply(rep, context.temp_allocator)
		testing.expect(t, strings.has_suffix(line, "\n"))
		back, why := link.decode_reply(line, context.temp_allocator)
		testing.expect_value(t, why, "")
		testing.expect_value(t, back, rep)
	}
	for status in link.Record_Status {
		rec := link.Record{id = id, status = status, error = "warum – darum"}
		line := link.encode_record(rec, context.temp_allocator)
		back, why := link.decode_record(line, context.temp_allocator)
		testing.expect_value(t, why, "")
		testing.expect_value(t, back, rec)
	}
	for line in ([]string{"", "{}", `{"id":"x","status":"done"}`, `{"id":"` + id + `","status":"maybe"}`, `{"id":"` + id + `"}`}) {
		_, why := link.decode_reply(line, context.temp_allocator)
		testing.expectf(t, why != "", "a reply from %q", line)
	}
	// A record of a skipped line has no id of a request, but the line's hash.
	skipped := link.Record{id = "corrupt-0123456789abcdef", status = .Skipped}
	back, why := link.decode_record(link.encode_record(skipped, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, why, "")
	testing.expect_value(t, back, skipped)
	// An error message with bad bytes (a program's output) is made valid, not
	// refused: the record must still be written.
	odd := link.Record{id = id, status = .Failed, error = "bad \xff byte"}
	back, why = link.decode_record(link.encode_record(odd, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, why, "")
	testing.expect(t, contains(back.error, "bad "))
}

@(test)
timestamps_are_rfc3339_in_utc :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := link.timestamp(link.clock(link.Config{}), context.temp_allocator)
	testing.expect_value(t, len(s), len("2026-11-08T12:00:00Z"))
	testing.expect(t, strings.has_suffix(s, "Z"), s)
	_, ok := link.parse_timestamp(s)
	testing.expect(t, ok)
	_, ok = link.parse_timestamp("2026-13-40T99:00:00Z")
	testing.expect(t, !ok)
}
