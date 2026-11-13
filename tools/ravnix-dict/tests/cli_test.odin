// The command line: add, remove and list against a file on the disk, and
// what they do with a file that is missing, too big, not writable, a link,
// or written by two runs at once.
package ravnix_dict_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import dict ".."

@(test)
adds_lists_and_removes_words_with_umlauts_dots_and_spaces :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "# words\n")
	for w in ([]string{"Übergrößenträger", "CLAUDE.md", "Open WebUI", "C#", "Straße"}) {
		r := run(f, nil, "add", w)
		testing.expectf(t, r.code == 0, "add %q exits 0, not %d: %s", w, r.code, r.err)
	}
	testing.expect_value(t, read_file(f, f.file), "# words\nÜbergrößenträger\nCLAUDE.md\nOpen WebUI\nC#\nStraße\n")
	testing.expect_value(
		t,
		strings.join(listed(f), "/", f.a),
		"Übergrößenträger/CLAUDE.md/Open WebUI/C#/Straße",
	)
	r := run(f, nil, "remove", "open webui")
	testing.expectf(t, r.code == 0, "remove exits 0: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "# words\nÜbergrößenträger\nCLAUDE.md\nC#\nStraße\n")
}

@(test)
add_takes_languages_and_mishearings :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "")
	r := run(f, nil, "add", "Huginn", "--lang", "de,EN", "--heard", "Hugin; who gin ;")
	testing.expectf(t, r.code == 0, "add exits 0: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "Huginn | lang=de,en | heard=Hugin;who gin\n")
	r = run(f, nil, "add", "--lang", "en", "huginn")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, read_file(f, f.file), "Huginn | lang=de,en | heard=Hugin;who gin\n")
	testing.expectf(t, strings.contains(r.out, "already"), "says it was there: %q", r.out)
}

@(test)
refuses_a_word_the_file_cannot_hold :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	for w in ([]string{"a|b", "#tag", "", "two\nlines"}) {
		r := run(f, nil, "add", w)
		testing.expectf(t, r.code == dict.EX_USAGE, "add %q exits %d, not %d", w, dict.EX_USAGE, r.code)
	}
	for l in ([]string{"deu", "d", "d1", "de;en"}) {
		r := run(f, nil, "add", "word", "--lang", l)
		testing.expectf(t, r.code == dict.EX_USAGE, "--lang %q exits %d, not %d", l, dict.EX_USAGE, r.code)
	}
	r := run(f, nil, "add", "word", "--heard", "x|y")
	testing.expect_value(t, r.code, dict.EX_USAGE)
	testing.expect_value(t, read_file(f, f.file), "a\n")
}

@(test)
bad_usage_exits_64 :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	cases := [][]string {
		{},
		{"frobnicate"},
		{"add"},
		{"add", "a", "b"},
		{"add", "a", "--lang"},
		{"add", "a", "--lang", "de", "--lang", "en"},
		{"add", "a", "--colour", "blue"},
		{"remove"},
		{"remove", "a", "b"},
		{"list", "x"},
		{"sync", "--adapter"},
		{"sync", "--adapter", "nosuch"},
		{"sync", "extra"},
	}
	for c in cases {
		r := run(f, nil, ..c)
		testing.expectf(t, r.code == dict.EX_USAGE, "%v exits %d, not %d: %s", c, dict.EX_USAGE, r.code, r.err)
	}
	r := run(f, nil, "--help")
	testing.expect_value(t, r.code, 0)
	testing.expect(t, strings.contains(r.out, "usage"))
}

@(test)
removing_a_word_that_is_not_there_fails :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	r := run(f, nil, "remove", "b")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, strings.contains(r.err, "not in the dictionary"))
	testing.expect_value(t, read_file(f, f.file), "a\n")
}

@(test)
a_missing_dictionary_is_an_error_and_is_not_created :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set(ALPHA, "kept")
	for c in ([][]string{{"list"}, {"add", "word"}, {"remove", "word"}, {"sync"}}) {
		r := run(f, adapters(), ..c)
		testing.expectf(t, r.code == 1, "%v exits 1, not %d", c, r.code)
		testing.expectf(t, strings.contains(r.err, f.file), "%v names the file: %s", c, r.err)
	}
	testing.expect(t, !os.exists(f.file))
	testing.expect_value(t, strings.join(words_of(ALPHA), ",", f.a), "kept")
	testing.expect_value(t, stores[ALPHA].writes, 0)
}

@(test)
no_file_given_is_an_error :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	e := env(f)
	e.file = ""
	r := run_env(f, e, nil, "list")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, strings.contains(r.err, "RAVNIX_DICT_FILE"))
	// --file wins over the environment.
	write_file(f, join(f, "other.txt"), "other\n")
	r = run_env(f, e, nil, "--file", join(f, "other.txt"), "list")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "other\n")
}

@(test)
a_dictionary_that_is_too_big_is_refused :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	big := strings.repeat("x\n", dict.MAX_FILE_SIZE / 2 + 1, f.a)
	write_file(f, f.file, big)
	r := run(f, nil, "list")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "MiB"), "says how big it may be: %s", r.err)
}

@(test)
a_dictionary_that_is_a_directory_is_refused :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	testing.expect_value(t, os.make_directory(f.file), nil)
	r := run(f, nil, "list")
	testing.expect_value(t, r.code, 1)
	r = run(f, nil, "add", "x")
	testing.expect_value(t, r.code, 1)
}

@(test)
a_dictionary_that_is_not_writable_is_left_alone :: proc(t: ^testing.T) {
	if linux.getuid() == 0 {
		// root writes a file of mode 444 all the same; nothing to show.
		return
	}
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	testing.expect_value(t, os.chmod(f.file, {.Read_User}), nil)
	r := run(f, nil, "add", "b")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "not writable"), "says why: %s", r.err)
	r = run(f, nil, "remove", "a")
	testing.expect_value(t, r.code, 1)
	testing.expect_value(t, read_file(f, f.file), "a\n")
	// It can still be read.
	testing.expect_value(t, strings.join(listed(f), ",", f.a), "a")
	os.chmod(f.file, {.Read_User, .Write_User})
}

@(test)
writes_through_a_link_and_keeps_the_link_and_the_mode :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	target := join(f, "real.txt")
	write_file(f, target, "a\n")
	testing.expect_value(t, os.chmod(target, {.Read_User, .Write_User, .Read_Group}), nil)
	testing.expect_value(t, os.symlink("real.txt", f.file), nil)
	r := run(f, nil, "add", "b")
	testing.expectf(t, r.code == 0, "add exits 0: %s", r.err)
	testing.expect_value(t, read_file(f, target), "a\nb\n")
	link, lerr := os.read_link(f.file, f.a)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, link, "real.txt")
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(target, f.a), &st)
	testing.expect_value(t, u32(transmute(u32)st.mode) & 0o777, u32(0o640))
	// No temporary file is left behind.
	entries, _ := os.read_all_directory_by_path(f.dir, f.a)
	for e in entries {
		testing.expectf(t, !strings.contains(e.name, "tmp"), "%s is left behind", e.name)
	}
}

@(test)
waits_for_the_lock_and_gives_up_with_a_reason :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	testing.expect_value(t, os.make_directory(f.state), nil)
	fd, e := linux.open(strings.clone_to_cstring(join(f, "state", "lock"), f.a), {.RDWR, .CREAT, .CLOEXEC}, transmute(linux.Mode)u32(0o600))
	testing.expect_value(t, e, linux.Errno.NONE)
	testing.expect_value(t, linux.flock(fd, {.EX}), linux.Errno.NONE)
	en := env(f)
	en.lock_wait_ms = 200
	r := run_env(f, en, nil, "add", "b")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "another ravnix-dict"), "says why: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "a\n")
	linux.close(fd)
	r = run_env(f, en, nil, "add", "b")
	testing.expect_value(t, r.code, 0)
}

Writer :: struct {
	f:     ^Fixture,
	from:  int,
	codes: [25]int,
}

writer_worker :: proc(w: ^Writer) {
	null, _ := os.open("/dev/null", {.Write})
	defer os.close(null)
	for i in 0 ..< len(w.codes) {
		word := fmt.tprintf("w%03d", w.from + i)
		args := []string{"--state", w.f.state, "add", word}
		w.codes[i] = dict.run(args, env(w.f), nil, null, null)
	}
	free_all(context.temp_allocator)
}

@(test)
two_runs_at_once_lose_no_word :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "# start\n")
	writers: [4]Writer
	threads: [4]^thread.Thread
	for &w, i in writers {
		w.f = f
		w.from = i * 100
	}
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data(&writers[i], writer_worker, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for w in writers {
		for c in w.codes {
			testing.expect_value(t, c, 0)
		}
	}
	words := listed(f)
	testing.expect_value(t, len(words), 100)
	for i in 0 ..< 4 {
		for j in 0 ..< 25 {
			word := fmt.tprintf("w%03d", i * 100 + j)
			testing.expectf(t, count(words, word) == 1, "%s is there once", word)
		}
	}
	free_all(context.temp_allocator)
}

@(test)
list_warns_about_lines_it_cannot_read_but_lists_the_rest :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "\xef\xbb\xbfone\r\n|\r\ntwo | colour=blue\r\nthree")
	r := run(f, nil, "list")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "one\ntwo\nthree\n")
	testing.expect(t, strings.contains(r.err, "line 2"))
	testing.expect(t, strings.contains(r.err, "line 3"))
	// An empty dictionary lists nothing, and is no error.
	write_file(f, f.file, "")
	r = run(f, nil, "list")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "")
}

@(test)
a_file_with_many_bad_lines_gets_a_count_not_a_flood :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, strings.concatenate({"good\n", strings.repeat("|\n", 500, f.a)}, f.a))
	r := run(f, nil, "list")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "good\n")
	testing.expect_value(t, len(lines(f, r.err)), dict.MAX_WARNINGS + 1)
	testing.expectf(t, strings.contains(r.err, "480 more"), "counts the rest: %s", r.err)
}
