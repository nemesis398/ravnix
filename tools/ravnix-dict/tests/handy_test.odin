// The Handy adapter: settings.custom_words of a settings store, every other
// byte kept, and a running Handy stopped before the write and started after
// it, so that its save from memory as it quits cannot undo the write
// (Review Focus 2).
package ravnix_dict_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:time"
import tools "../adapters"

// Handy's own layout (serde_json's to_vec_pretty), with what a scanner can
// get wrong: escapes and a surrogate pair in a word, a string that looks
// like the member, nested objects, an API key, and a custom_words outside
// the settings.
HANDY_STORE :: `{
  "settings": {
    "airpods_mode": false,
    "app_language": "en-US",
    "bindings": {
      "transcribe": {
        "current_binding": "ctrl+space",
        "id": "transcribe"
      }
    },
    "custom_words": [
      "NixOS",
      "Grüße \"quoted\" \\ back",
      "Ärger",
      "emoji 😀"
    ],
    "note": "custom_words: [\"not\", \"this\"]",
    "post_process_api_keys": {
      "openai": "sk-test-not-a-secret"
    },
    "word_correction_threshold": 0.18
  },
  "custom_words": [
    "top-level"
  ]
}`

HANDY_WORDS :: []string{"NixOS", `Grüße "quoted" \ back`, "Ärger", "emoji 😀"}

// The store around settings.custom_words's value, which a write must keep.
store_around :: proc(text: string) -> (before, after: string) {
	start := strings.index(text, "\"custom_words\": [")
	if start < 0 {
		return text, ""
	}
	start += len("\"custom_words\": ")
	end := strings.index(text[start:], "\n    ]")
	if end < 0 {
		end = strings.index_byte(text[start:], ']') - len("\n    ")
	}
	return text[:start], text[start + end + len("\n    ]"):]
}

@(thread_local)
handy_fixture: ^Fixture
@(thread_local)
handy_link: string
@(thread_local)
handy_mode: string
@(thread_local)
handy_children: [dynamic]os.Process
@(thread_local)
handy_starts: int
// Whether the stopped-for-a-write marker was there at the last start.
@(thread_local)
marked_at_start: bool

handy_counter: int

// handy_setup points the adapter at the fixture's store and at a stand-in
// Handy whose name only this test uses.
handy_setup :: proc(f: ^Fixture) -> string {
	handy_fixture = f
	handy_mode = ""
	handy_starts = 0
	handy_children = make([dynamic]os.Process, f.a)
	n := sync.atomic_add(&handy_counter, 1)
	name := fmt.aprintf("fh-%d-%d", os.get_pid() % 1000, n, allocator = f.a)
	handy_link = link(f, f.dir, name)
	settings := join(f, "settings_store.json")
	names := make([]string, 1, f.a)
	names[0] = name
	sysdir := join(f, "systemd")
	_ = os.make_directory(sysdir)
	write_file(f, join(f, "systemd", "systemctl-fake"), "")
	_ = os.make_directory(f.state)
	tools.state_dir = f.state
	tools.handy = {
		settings     = settings,
		names        = names,
		stop_timeout = 2 * time.Second,
		start        = start_fake_handy,
		systemctl    = link(f, sysdir, "systemctl"),
		// Outside the unit, unless a test says otherwise.
		unit_of      = proc(pid: int) -> string {return ""},
	}
	return settings
}

systemctl_log :: proc(f: ^Fixture) -> string {
	return read_file(f, join(f, "systemd", "systemctl-log"))
}

stopped_marker :: proc(f: ^Fixture) -> string {
	return join(f, "state", "handy-stopped")
}

// start_fake_handy starts the stand-in and waits until it has read the
// store: it is the adapter's start, and the test's own.
start_fake_handy :: proc() -> tools.Error {
	f := handy_fixture
	handy_starts += 1
	marked_at_start = os.exists(stopped_marker(f))
	ready := join(f, fmt.aprintf("ready-%d", handy_starts, allocator = f.a))
	command := make([dynamic]string, f.a)
	append(&command, handy_link, tools.handy.settings, ready)
	if handy_mode != "" {
		append(&command, handy_mode)
	}
	p, err := os.process_start({command = command[:]})
	if err != nil {
		return fmt.tprintf("cannot start the stand-in: %v", err)
	}
	append(&handy_children, p)
	for _ in 0 ..< 500 {
		if os.exists(ready) {
			return nil
		}
		time.sleep(10 * time.Millisecond)
	}
	return "the stand-in did not get ready"
}

// handy_quit is Handy quitting by itself: it saves its memory, then ends.
handy_quit :: proc(t: ^testing.T) {
	for pid in tools.handy_processes() {
		linux.kill(linux.Pid(pid), .SIGTERM)
	}
	handy_reap()
}

// handy_reap waits for every stand-in the test started, killing what is
// left after five seconds.
handy_reap :: proc() {
	for p in handy_children {
		if _, err := os.process_wait(p, 5 * time.Second); err != nil {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
		}
	}
	clear(&handy_children)
}

custom_words_of :: proc(f: ^Fixture, path: string) -> []string {
	words, why := tools.handy_words(read_file(f, path))
	testing.expectf(f.t, why == "", "the store reads: %s", why)
	return words
}

@(test)
handy_reads_custom_words_from_the_settings_only :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	words, err := tools.handy_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.join(words, "|", f.a), strings.join(HANDY_WORDS, "|", f.a))
}

@(test)
handy_writes_custom_words_and_keeps_every_other_byte :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	_, _ = tools.handy_read()
	words := []string{"NixOS", "Ärger", "tab\there", "new \"one\""}
	testing.expect_value(t, tools.handy_write(words), nil)
	got := read_file(f, settings)
	before, after := store_around(HANDY_STORE)
	now_before, now_after := store_around(got)
	testing.expect_value(t, now_before, before)
	testing.expect_value(t, now_after, after)
	// In Handy's own layout, as serde_json writes it, read back the same.
	testing.expect(t, strings.contains(got, "\"custom_words\": [\n      \"NixOS\",\n      \"Ärger\",\n      \"tab\\there\",\n      \"new \\\"one\\\"\"\n    ],"))
	testing.expect_value(t, strings.join(custom_words_of(f, settings), "|", f.a), strings.join(words, "|", f.a))
	// Handy is not running: nothing is started.
	testing.expect_value(t, handy_starts, 0)
}

@(test)
handy_is_stopped_written_and_started_and_a_word_survives_its_quit :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	testing.expect_value(t, len(tools.handy_processes()), 1)

	words, err := tools.handy_read()
	testing.expect_value(t, err, nil)
	target := make([dynamic]string, f.a)
	append(&target, ..words)
	append(&target, "Ravnixtest")
	testing.expect_value(t, tools.handy_write(target[:]), nil)
	// Stopped (its save from memory came first, with the old list), written,
	// and started again: a second stand-in, which read the new list.
	testing.expect_value(t, handy_starts, 2)
	testing.expect_value(t, len(tools.handy_processes()), 1)

	// Outside its unit, it was signalled: systemctl was not asked, and the
	// marker of the stop was there until the start, and is gone after it.
	testing.expect_value(t, systemctl_log(f), "")
	testing.expect(t, marked_at_start)
	testing.expect(t, !os.exists(stopped_marker(f)))

	// Handy quits and writes its memory back: the word is in it.
	handy_quit(t)
	testing.expect_value(t, len(tools.handy_processes()), 0)
	testing.expect(t, has(custom_words_of(f, settings), "Ravnixtest"))
	before, after := store_around(HANDY_STORE)
	now_before, now_after := store_around(read_file(f, settings))
	testing.expect_value(t, now_before, before)
	testing.expect_value(t, now_after, after)
}

@(test)
the_stand_in_undoes_a_write_made_while_it_runs :: proc(t: ^testing.T) {
	// Why the adapter stops Handy: a list written into the store while it
	// runs is gone after its next save. The stand-in does what Handy does.
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	data, why := tools.handy_splice(HANDY_STORE, {"Ravnixtest"})
	testing.expect_value(t, why, "")
	write_file(f, settings, data)
	handy_quit(t)
	testing.expect(t, !has(custom_words_of(f, settings), "Ravnixtest"))
}

@(test)
a_handy_that_ignores_sigterm_is_killed_and_written :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	tools.handy.stop_timeout = 300 * time.Millisecond
	handy_mode = "stubborn"
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	handy_mode = ""
	_, _ = tools.handy_read()
	testing.expect_value(t, tools.handy_write({"Ravnixtest"}), nil)
	testing.expect_value(t, handy_starts, 2)
	handy_quit(t)
	testing.expect_value(t, strings.join(custom_words_of(f, settings), "|", f.a), "Ravnixtest")
}

@(test)
a_handy_that_cannot_be_started_again_is_an_error :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	_, _ = tools.handy_read()
	tools.handy.start = proc() -> tools.Error {return "no session"}
	err := tools.handy_write({"Ravnixtest"})
	message, failed := err.?
	testing.expect(t, failed && strings.contains(message, "could not be started again") && strings.contains(message, "no session"))
	// The words are written all the same.
	testing.expect(t, has(custom_words_of(f, settings), "Ravnixtest"))
}

@(test)
a_word_handy_got_between_read_and_write_is_kept :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	words, _ := tools.handy_read()
	// Typed into Handy's window and saved, while sync read the other tools.
	later, _ := tools.handy_splice(HANDY_STORE, {"NixOS", "typed-in-handy"})
	write_file(f, settings, later)
	// The core drops "Ärger" (a removed word) and gives "Muninn".
	target := []string{words[0], words[1], words[3], "Muninn"}
	testing.expect_value(t, tools.handy_write(target), nil)
	testing.expect_value(t, strings.join(custom_words_of(f, settings), "|", f.a), strings.join([]string{words[0], words[1], words[3], "Muninn", "typed-in-handy"}, "|", f.a))
}

@(test)
a_store_without_custom_words_or_settings_gets_them :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	check :: proc(f: ^Fixture, before, want: string, loc := #caller_location) {
		words, why := tools.handy_words(before)
		testing.expectf(f.t, why == "" && len(words) == 0, "%q reads as no words: %s", before, why, loc = loc)
		got, swhy := tools.handy_splice(before, {"a", "b"})
		testing.expectf(f.t, swhy == "", "%q: %s", before, swhy, loc = loc)
		testing.expectf(f.t, got == want, "%q gives\n%s\nnot\n%s", before, got, want, loc = loc)
	}
	check(f, "{\n  \"settings\": {\n    \"debug_mode\": false\n  }\n}", "{\n  \"settings\": {\n    \"debug_mode\": false,\n    \"custom_words\": [\n      \"a\",\n      \"b\"\n    ]\n  }\n}")
	check(f, "{\n  \"settings\": {}\n}", "{\n  \"settings\": {\n    \"custom_words\": [\n      \"a\",\n      \"b\"\n    ]\n  }\n}")
	check(f, "{\n  \"other\": 1\n}", "{\n  \"other\": 1,\n  \"settings\": {\n    \"custom_words\": [\n      \"a\",\n      \"b\"\n    ]\n  }\n}")
	check(f, `{"settings":{"x":[1,2]}}`, `{"settings":{"x":[1,2],"custom_words":["a","b"]}}`)
	check(f, "{}", "{\"settings\":{\"custom_words\":[\"a\",\"b\"]}}")
	// An empty list stays an empty array.
	got, _ := tools.handy_splice(HANDY_STORE, {})
	testing.expect(t, strings.contains(got, "\"custom_words\": [],\n    \"note\""))
}

@(test)
a_missing_store_is_no_words_and_is_made_with_them :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	tools.handy.settings = join(f, "com.pais.handy", "settings_store.json")
	words, err := tools.handy_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(words), 0)
	testing.expect_value(t, tools.handy_write({"Huginn"}), nil)
	testing.expect_value(t, read_file(f, tools.handy.settings), "{\n  \"settings\": {\n    \"custom_words\": [\n      \"Huginn\"\n    ]\n  }\n}")
	_ = settings
}

@(test)
a_store_that_is_not_handy_s_is_an_error_and_left_alone :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	bad := []string {
		"",
		"{",
		"[1]",
		`{"settings": []}`,
		`{"settings": {"custom_words": "NixOS"}}`,
		`{"settings": {"custom_words": ["a", 1]}}`,
		`{"settings": {"custom_words": ["\ud83d"]}}`,
		`{"settings": {"custom_words": ["a"]}} trailing`,
		`{"settings": {"custom_words": ["a\x01"]}}`,
		"{\"a\": \"\xff\"}",
		strings.concatenate({strings.repeat("[", 1000, f.a), strings.repeat("]", 1000, f.a)}, f.a),
	}
	for text, i in bad {
		if text == "" {
			continue
		}
		write_file(f, settings, text)
		_, err := tools.handy_read()
		testing.expectf(t, err != nil, "case %d reads: %q", i, text)
		testing.expectf(t, tools.handy_write({"x"}) != nil, "case %d is written", i)
		testing.expectf(t, read_file(f, settings) == text, "case %d is changed", i)
		// No message holds what the store holds.
		if message, failed := err.?; failed {
			testing.expect(t, !strings.contains(message, "sk-test"))
		}
	}
}

@(test)
handy_keeps_the_store_s_mode_and_link :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	real := join(f, "real.json")
	write_file(f, real, HANDY_STORE)
	testing.expect_value(t, os.chmod(real, {.Read_User, .Write_User}), nil)
	testing.expect_value(t, os.symlink(real, settings), nil)
	_, _ = tools.handy_read()
	testing.expect_value(t, tools.handy_write({"a"}), nil)
	target, _ := os.read_link(settings, f.a)
	testing.expect_value(t, target, real)
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(real, f.a), &st)
	testing.expect_value(t, transmute(u32)st.mode & 0o777, 0o600)
	testing.expect_value(t, strings.join(custom_words_of(f, real), "|", f.a), "a")
}

@(test)
handy_round_trips_ten_thousand_words :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	words := make([]string, 10_000, f.a)
	for i in 0 ..< len(words) {
		words[i] = fmt.aprintf("wörd-%d \"%d\"", i, i, allocator = f.a)
	}
	_, _ = tools.handy_read()
	testing.expect_value(t, tools.handy_write(words), nil)
	back := custom_words_of(f, settings)
	testing.expect_value(t, len(back), len(words))
	testing.expect_value(t, back[9_999], words[9_999])
}

@(test)
a_handy_in_its_unit_is_stopped_by_systemd :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	tools.handy.unit_of = proc(pid: int) -> string {return tools.HANDY_UNIT}
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	pids := tools.handy_processes()
	testing.expect_value(t, len(pids), 1)
	write_file(f, join(f, "systemd", "systemctl-pids"), fmt.aprintf("%d\n", pids[0]))
	_, _ = tools.handy_read()
	testing.expect_value(t, tools.handy_write({"Ravnixtest"}), nil)
	// systemd stopped it, so the unit is inactive when it is started again.
	testing.expect_value(t, systemctl_log(f), "--user stop app-handy@autostart.service\n")
	testing.expect_value(t, handy_starts, 2)
	testing.expect(t, marked_at_start)
	handy_quit(t)
	testing.expect_value(t, strings.join(custom_words_of(f, settings), "|"), "Ravnixtest")
}

@(test)
a_handy_left_stopped_is_started_at_the_next_sync :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	testing.expect_value(t, start_fake_handy(), nil)
	_, _ = tools.handy_read()
	// The start after the write fails: Handy is down, and the marker says so.
	tools.handy.start = proc() -> tools.Error {return "no session"}
	testing.expect(t, tools.handy_write({"Ravnixtest"}) != nil)
	testing.expect_value(t, len(tools.handy_processes()), 0)
	testing.expect(t, os.exists(stopped_marker(f)))
	// A read whose start fails as well says so, and keeps the marker.
	_, err := tools.handy_read()
	message, failed := err.?
	testing.expectf(t, failed && strings.contains(message, "no session"), "%v", err)
	testing.expect(t, os.exists(stopped_marker(f)))
	// The next sync's read starts it, and the marker goes.
	tools.handy.start = start_fake_handy
	words, rerr := tools.handy_read()
	testing.expect_value(t, rerr, nil)
	testing.expect(t, has(words, "Ravnixtest"))
	testing.expect_value(t, len(tools.handy_processes()), 1)
	testing.expect(t, !os.exists(stopped_marker(f)))
}

@(test)
a_marker_left_by_a_killed_sync_starts_handy_once :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	defer handy_reap()
	settings := handy_setup(f)
	write_file(f, settings, HANDY_STORE)
	// A sync killed between the stop and the start (a timeout, a stop of
	// the service) leaves the marker and no Handy.
	write_file(f, stopped_marker(f), "stopped\n")
	_, err := tools.handy_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, handy_starts, 1)
	testing.expect(t, !os.exists(stopped_marker(f)))
	// No marker: a Handy the user quit is left alone.
	handy_quit(t)
	_, err = tools.handy_read()
	testing.expect_value(t, handy_starts, 1)
	// A marker while Handy runs (started by hand meanwhile): only cleared.
	testing.expect_value(t, start_fake_handy(), nil)
	write_file(f, stopped_marker(f), "stopped\n")
	_, err = tools.handy_read()
	testing.expect_value(t, handy_starts, 2)
	testing.expect(t, !os.exists(stopped_marker(f)))
}

@(test)
the_unit_of_a_process_comes_from_its_cgroup :: proc(t: ^testing.T) {
	testing.expect_value(t, tools.unit_of_cgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-handy@autostart.service\n"), "app-handy@autostart.service")
	// Started from the launcher: a scope, no service of its own.
	testing.expect_value(t, tools.unit_of_cgroup("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-sway-fuzzel-123.scope\n"), "")
	// cgroup v1 lists one line per hierarchy; the unified one counts.
	testing.expect_value(t, tools.unit_of_cgroup("12:pids:/user.slice\n1:name=systemd:/user.slice/user@1000.service/app.slice/app-handy@autostart.service\n0::/user.slice/user@1000.service/app.slice/app-handy@autostart.service\n"), "app-handy@autostart.service")
	testing.expect_value(t, tools.unit_of_cgroup(""), "")
	testing.expect_value(t, tools.unit_of_cgroup("0::/\n"), "")
}
