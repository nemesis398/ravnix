// The dictionary file: what it reads, what it refuses, and that what it
// writes back is the file as it was, byte for byte, but for the lines a
// command changed.
package ravnix_dict_tests

import "core:strings"
import "core:testing"
import "core:time"
import dict ".."

FORMAT :: #load("testdata/format.txt", string)

round_trips :: proc(t: ^testing.T, text: string, loc := #caller_location) {
	d, why := dict.parse(text, context.temp_allocator)
	testing.expectf(t, why == "", "%q parses: %s", text, why, loc = loc)
	back := dict.serialize(d, context.temp_allocator)
	testing.expectf(t, back == text, "%q comes back as %q", text, back, loc = loc)
}

@(test)
round_trips_byte_for_byte :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	round_trips(t, FORMAT)
	round_trips(t, "")
	round_trips(t, "\n")
	round_trips(t, "\n\n\n")
	round_trips(t, "word")
	round_trips(t, "word\n")
	round_trips(t, "one\ntwo")
	round_trips(t, "one\r\ntwo\r\n")
	round_trips(t, "one\r\ntwo\nthree")
	round_trips(t, "a lone\rcarriage return\n")
	round_trips(t, "\xef\xbb\xbfword\n")
	round_trips(t, "\xef\xbb\xbf")
	round_trips(t, "   \t \n")
	round_trips(t, "  # an indented comment\n")
	round_trips(t, "|\n")
	round_trips(t, " | \n")
	round_trips(t, "| lang=de\n")
	round_trips(t, "word |\n")
	round_trips(t, "word | lang\n")
	round_trips(t, "word | lang=de | lang=en\n")
	round_trips(t, "word|lang=de|heard=x\n")
	round_trips(t, "word | colour=blue\n")
	round_trips(t, "a\n\n\nb")
}

@(test)
reads_words_and_fields :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d, why := dict.parse(FORMAT, context.temp_allocator)
	testing.expect_value(t, why, "")
	words := dict.words(d, context.temp_allocator)
	want := []string {
		"Huginn",
		"Muninn",
		"CLAUDE.md",
		"Open WebUI",
		"Übergrößenträger",
		"Straße",
		"C#",
		"self-hosted",
		"indented",
		"Zettelkasten",
		"Nix",
		"nixpkgs",
	}
	testing.expect_value(t, len(words), len(want))
	for w, i in want {
		if i < len(words) {
			testing.expect_value(t, words[i], w)
		}
	}
	langs := dict.langs_of(d, "indented", context.temp_allocator)
	testing.expect(t, !langs.all)
	testing.expect_value(t, strings.join(langs.codes, ",", context.temp_allocator), "de,en")
	// A word without lang= is known in every language.
	langs = dict.langs_of(d, "Muninn", context.temp_allocator)
	testing.expect(t, langs.all)
	testing.expect_value(t, len(langs.codes), 0)
	heard := dict.heard_of(d, "Huginn", context.temp_allocator)
	testing.expect_value(t, strings.join(heard, ";", context.temp_allocator), "Hugin;who gin")
	heard = dict.heard_of(d, "indented", context.temp_allocator)
	testing.expect_value(t, strings.join(heard, ";", context.temp_allocator), "in dented")
}

@(test)
words_that_differ_in_case_are_one_entry_and_keep_their_first_spelling :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d, why := dict.parse("GitHub | lang=de\ngithub | lang=en\nÄrger\närger\n", context.temp_allocator)
	testing.expect_value(t, why, "")
	words := dict.words(d, context.temp_allocator)
	testing.expect_value(t, strings.join(words, "/", context.temp_allocator), "GitHub/Ärger")
	langs := dict.langs_of(d, "GITHUB", context.temp_allocator)
	testing.expect(t, !langs.all)
	testing.expect_value(t, strings.join(langs.codes, ",", context.temp_allocator), "de,en")
}

@(test)
a_word_with_one_line_without_lang_is_in_every_language :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for text in ([]string{"Foo\nfoo | lang=en\n", "foo | lang=en\nFOO\n", "foo | lang=\n", "foo | heard=fu\n"}) {
		d, _ := dict.parse(text, context.temp_allocator)
		langs := dict.langs_of(d, "foo", context.temp_allocator)
		testing.expectf(t, langs.all, "%q is in every language: %v", text, langs)
	}
	// A word that is not there is in no language.
	d, _ := dict.parse("bar\n", context.temp_allocator)
	langs := dict.langs_of(d, "foo", context.temp_allocator)
	testing.expect(t, !langs.all)
	testing.expect_value(t, len(langs.codes), 0)
}

@(test)
warns_about_fields_it_cannot_read_and_keeps_the_word :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "one | colour=blue\ntwo | lang=de | lang=en\nthree | lang\nfour |\nfive | heard=\n"
	d, why := dict.parse(text, context.temp_allocator)
	testing.expect_value(t, why, "")
	words := dict.words(d, context.temp_allocator)
	testing.expect_value(t, strings.join(words, " ", context.temp_allocator), "one two three four five")
	all := strings.join(d.warnings[:], "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(all, "line 1") && strings.contains(all, "colour"), "an unknown field is named: %s", all)
	testing.expectf(t, strings.contains(all, "line 2") && strings.contains(all, "twice"), "a field given twice is named: %s", all)
	testing.expectf(t, strings.contains(all, "line 3"), "a field without = is named: %s", all)
	testing.expectf(t, strings.contains(all, "line 4"), "an empty field is named: %s", all)
	// Both values of a field given twice count.
	langs := dict.langs_of(d, "two", context.temp_allocator)
	testing.expect_value(t, strings.join(langs.codes, ",", context.temp_allocator), "de,en")
}

@(test)
a_line_with_no_word_is_no_entry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d, why := dict.parse("|\n | \n| lang=de\nreal\n", context.temp_allocator)
	testing.expect_value(t, why, "")
	words := dict.words(d, context.temp_allocator)
	testing.expect_value(t, strings.join(words, " ", context.temp_allocator), "real")
	testing.expect_value(t, len(d.warnings), 3)
}

@(test)
refuses_a_file_it_cannot_trust :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	refuse :: proc(t: ^testing.T, text: string, says: string, loc := #caller_location) {
		_, why := dict.parse(text, context.temp_allocator)
		testing.expectf(t, strings.contains(why, says), "%q is refused with %q, not %q", text, says, why, loc = loc)
	}
	// Latin-1, as an editor in the wrong encoding writes an umlaut.
	refuse(t, "ok\nM\xfcller\n", "line 2")
	refuse(t, "ok\nM\xfcller\n", "UTF-8")
	refuse(t, "ok\x00\n", "NUL")
	// An unresolved merge in the private repository.
	refuse(t, "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n", "merge")
	refuse(t, "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n", "line 2")
}

@(test)
tells_which_words_the_file_can_hold :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, word: string, loc := #caller_location) {
		testing.expectf(t, dict.word_problem(word) == "", "%q is a word: %s", word, dict.word_problem(word), loc = loc)
	}
	bad :: proc(t: ^testing.T, word: string, loc := #caller_location) {
		testing.expectf(t, dict.word_problem(word) != "", "%q is refused", word, loc = loc)
	}
	ok(t, "Müller")
	ok(t, "CLAUDE.md")
	ok(t, "Open WebUI")
	ok(t, "C#")
	ok(t, "a=b")
	ok(t, strings.repeat("x", dict.MAX_WORD, context.temp_allocator))
	bad(t, "")
	bad(t, "   ")
	bad(t, " padded")
	bad(t, "a|b")
	bad(t, "#hashtag")
	bad(t, "two\nlines")
	bad(t, "carriage\rreturn")
	bad(t, "tab\there")
	bad(t, "M\xfcller")
	bad(t, "<<<<<<< HEAD")
	bad(t, strings.repeat("x", dict.MAX_WORD + 1, context.temp_allocator))
	free_all(context.temp_allocator)
}

@(test)
adds_a_line_in_the_file_s_own_style :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	added :: proc(t: ^testing.T, text: string, want: string, loc := #caller_location) {
		d, why := dict.parse(text, context.temp_allocator)
		testing.expect_value(t, why, "", loc = loc)
		testing.expect(t, dict.add_word(&d, "Neu", nil, nil, context.temp_allocator), loc = loc)
		got := dict.serialize(d, context.temp_allocator)
		testing.expectf(t, got == want, "%q plus a word is %q, not %q", text, want, got, loc = loc)
	}
	added(t, "", "Neu\n")
	added(t, "a\n", "a\nNeu\n")
	added(t, "a", "a\nNeu\n")
	added(t, "a\r\nb\r\n", "a\r\nb\r\nNeu\r\n")
	added(t, "a\r\nb", "a\r\nb\r\nNeu\r\n")
	added(t, "\xef\xbb\xbfa\n", "\xef\xbb\xbfa\nNeu\n")
	added(t, "\xef\xbb\xbf", "\xef\xbb\xbfNeu\n")
	added(t, "# only a comment", "# only a comment\nNeu\n")

	d, _ := dict.parse("", context.temp_allocator)
	dict.add_word(&d, "Huginn", {"de", "en"}, {"Hugin", "who gin"}, context.temp_allocator)
	testing.expect_value(t, dict.serialize(d, context.temp_allocator), "Huginn | lang=de,en | heard=Hugin;who gin\n")
}

@(test)
adding_a_word_that_is_there_merges_its_fields_or_changes_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "# head\nHuginn | lang=de | heard=Hugin | note=kept\nMuninn\n"
	d, _ := dict.parse(text, context.temp_allocator)
	testing.expect(t, !dict.add_word(&d, "huginn", nil, nil, context.temp_allocator))
	testing.expect(t, !dict.add_word(&d, "HUGINN", {"de"}, {"Hugin"}, context.temp_allocator))
	testing.expect_value(t, dict.serialize(d, context.temp_allocator), text)
	testing.expect(t, dict.add_word(&d, "huginn", {"en", "de"}, {"who gin"}, context.temp_allocator))
	testing.expect_value(
		t,
		dict.serialize(d, context.temp_allocator),
		"# head\nHuginn | lang=de,en | heard=Hugin;who gin | note=kept\nMuninn\n",
	)
	// A word without lang= is in every language: --lang never narrows it.
	before := dict.serialize(d, context.temp_allocator)
	testing.expect(t, !dict.add_word(&d, "Muninn", {"en"}, nil, context.temp_allocator))
	testing.expect_value(t, dict.serialize(d, context.temp_allocator), before)
	// A mishearing still reaches it; the languages stay as they are.
	testing.expect(t, dict.add_word(&d, "Muninn", {"en"}, {"moon in"}, context.temp_allocator))
	testing.expect_value(
		t,
		dict.serialize(d, context.temp_allocator),
		"# head\nHuginn | lang=de,en | heard=Hugin;who gin | note=kept\nMuninn | heard=moon in\n",
	)
	testing.expect(t, dict.langs_of(d, "muninn", context.temp_allocator).all)
}

@(test)
removing_a_word_leaves_every_other_byte :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d, _ := dict.parse(FORMAT, context.temp_allocator)
	testing.expect_value(t, dict.remove_word(&d, "open webui"), 1)
	want, _ := strings.replace(FORMAT, "Open WebUI | lang=en\n", "", 1, context.temp_allocator)
	testing.expect_value(t, dict.serialize(d, context.temp_allocator), want)
	testing.expect_value(t, dict.remove_word(&d, "Open WebUI"), 0)

	// Every line of the word goes, whatever its case.
	d2, _ := dict.parse("a\r\nGitHub\r\nb\r\ngithub | lang=en\r\nc", context.temp_allocator)
	testing.expect_value(t, dict.remove_word(&d2, "GITHUB"), 2)
	testing.expect_value(t, dict.serialize(d2, context.temp_allocator), "a\r\nb\r\nc")

	// The last line without a line break, removed: the file ends where the
	// line before it did.
	d3, _ := dict.parse("a\nb", context.temp_allocator)
	testing.expect_value(t, dict.remove_word(&d3, "b"), 1)
	testing.expect_value(t, dict.serialize(d3, context.temp_allocator), "a\n")
}

@(test)
reads_a_huge_file_in_linear_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	N :: 200_000
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# a huge dictionary\n")
	for i in 0 ..< N {
		strings.write_string(&b, "wort")
		strings.write_int(&b, i)
		if i % 3 == 0 {
			strings.write_string(&b, " | lang=de | heard=vort")
		}
		strings.write_byte(&b, '\n')
	}
	text := strings.to_string(b)
	start := time.tick_now()
	d, why := dict.parse(text, context.temp_allocator)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(dict.words(d, context.temp_allocator)), N)
	testing.expect(t, dict.add_word(&d, "neu", nil, nil, context.temp_allocator))
	testing.expect(t, !dict.add_word(&d, "WORT199999", nil, nil, context.temp_allocator))
	back := dict.serialize(d, context.temp_allocator)
	testing.expect_value(t, back[:len(text)], text)
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expectf(t, elapsed < 10, "200 000 lines took %.1f s", elapsed)
}

@(test)
a_key_is_the_lower_case_of_any_word :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cases := [][2]string {
		{"", ""},
		{"github", "github"},
		{"GitHub", "github"},
		{"CLAUDE.md", "claude.md"},
		{"Open WebUI", "open webui"},
		{"ÜBERGRÖSSE", "übergrösse"},
		{"Ärger", "ärger"},
		{"Straße", "straße"},
		{"[@Z]", "[@z]"},
		{"\u1e9e", "ß"},
	}
	for c in cases {
		testing.expect_value(t, dict.key(c[0], context.temp_allocator), c[1])
	}
}
