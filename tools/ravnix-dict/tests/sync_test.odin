// sync: two-way and add only. A word new in a tool comes into the file, a
// word missing from a tool is written to it, and nothing is taken from the
// file by a tool. A word leaves a tool only when it has left the file, by
// remove or by hand, and the record of that survives a crash, a failed
// adapter and a tool that resets its list.
package ravnix_dict_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import dict ".."
import tools "../adapters"

sync_ok :: proc(f: ^Fixture, args: ..string, loc := #caller_location) -> Result {
	all := make([dynamic]string, f.a)
	append(&all, "sync")
	append(&all, ..args)
	r := run(f, adapters(), ..all[:])
	testing.expectf(f.t, r.code == 0, "sync exits 0, not %d: %s", r.code, r.err, loc = loc)
	return r
}

joined :: proc(f: ^Fixture, i: int) -> string {
	return strings.join(words_of(i), ",", f.a)
}

@(test)
sync_is_two_way :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "# words\nHuginn | lang=en\nMuninn\n")
	set(ALPHA, "Muninn", "Zettelkasten")
	set(BETA)
	set(GAMMA, "Open WebUI", "huginn")
	sync_ok(f)
	// New in a tool: into the file, in the order of the adapters, with the
	// spelling the tool has, in the file's own style.
	testing.expect_value(t, read_file(f, f.file), "# words\nHuginn | lang=en\nMuninn\nOpen WebUI\nZettelkasten\n")
	// Missing from a tool: written to it, after what it had; a word it has
	// in another case gets the file's spelling.
	testing.expect_value(t, joined(f, ALPHA), "Muninn,Zettelkasten,Huginn,Open WebUI")
	testing.expect_value(t, joined(f, BETA), "Huginn,Muninn,Open WebUI,Zettelkasten")
	testing.expect_value(t, joined(f, GAMMA), "Open WebUI,Huginn,Muninn,Zettelkasten")
}

@(test)
a_sync_in_step_writes_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\nb\n")
	set(ALPHA, "b", "a")
	set(BETA, "a", "b")
	set(GAMMA, "A", "b")
	sync_ok(f)
	testing.expect_value(t, stores[ALPHA].writes, 0)
	testing.expect_value(t, stores[BETA].writes, 0)
	// GAMMA had "A": the file's spelling is written to it once.
	testing.expect_value(t, stores[GAMMA].writes, 1)
	sync_ok(f)
	testing.expect_value(t, stores[GAMMA].writes, 1)
	testing.expect_value(t, read_file(f, f.file), "a\nb\n")
}

@(test)
a_tool_that_resets_its_list_gets_every_word_back_and_takes_none :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\nb\nc\n")
	set(ALPHA, "a", "b", "c")
	set(BETA, "a", "b", "c")
	set(GAMMA, "a", "b", "c")
	sync_ok(f)
	set(GAMMA)
	set(ALPHA, "b")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "a\nb\nc\n")
	testing.expect_value(t, joined(f, GAMMA), "a,b,c")
	testing.expect_value(t, joined(f, ALPHA), "b,a,c")
}

@(test)
remove_takes_the_word_from_every_tool_at_the_next_sync :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\nGone | lang=de\n")
	set(ALPHA, "keep", "Gone")
	set(BETA, "gone", "keep")
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, joined(f, GAMMA), "keep,Gone")
	r := run(f, adapters(), "remove", "gone")
	testing.expectf(t, r.code == 0, "remove exits 0: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	// remove itself writes no tool.
	testing.expect_value(t, joined(f, ALPHA), "keep,Gone")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	testing.expect_value(t, joined(f, ALPHA), "keep")
	testing.expect_value(t, joined(f, BETA), "keep")
	testing.expect_value(t, joined(f, GAMMA), "keep")
}

@(test)
a_line_deleted_by_hand_is_a_removal :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "# words\nkeep\ngone\nalso\n")
	set(ALPHA, "keep", "gone", "also")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, joined(f, BETA), "keep,gone,also")
	// The user deletes the line in an editor, and the editor writes the file
	// with a new line ending; nothing else knows of it.
	write_file(f, f.file, "# words\r\nkeep\r\nalso\r\n")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "# words\r\nkeep\r\nalso\r\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,also")
	testing.expect_value(t, joined(f, BETA), "keep,also")
	testing.expect_value(t, joined(f, GAMMA), "keep,also")
}

@(test)
a_word_whose_case_was_changed_by_hand_is_not_removed :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "Github\n")
	set(ALPHA, "Github")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	write_file(f, f.file, "GitHub\n")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "GitHub\n")
	testing.expect_value(t, joined(f, ALPHA), "GitHub")
	testing.expect_value(t, joined(f, BETA), "GitHub")
}

@(test)
a_removal_survives_a_crash_and_a_failed_adapter :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\ngone\n")
	set(ALPHA, "keep", "gone")
	set(BETA, "keep", "gone")
	set(GAMMA, "keep", "gone")
	sync_ok(f)
	// remove, then the process ends: everything it knows is on the disk.
	testing.expect_value(t, run(f, nil, "remove", "gone").code, 0)
	// The next sync reaches only alpha; beta cannot be read, gamma cannot
	// be written.
	stores[BETA].fail_read = true
	stores[GAMMA].fail_write = true
	r := run(f, adapters(), "sync")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "beta") && strings.contains(r.err, "gamma"), "names both: %s", r.err)
	testing.expect_value(t, joined(f, ALPHA), "keep")
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	// A sync after that one has no fresh removal to see in the file, and
	// still takes the word from the tools that missed it.
	stores[BETA].fail_read = false
	stores[GAMMA].fail_write = false
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	testing.expect_value(t, joined(f, BETA), "keep")
	testing.expect_value(t, joined(f, GAMMA), "keep")
}

@(test)
a_tool_restored_from_an_old_list_brings_no_removed_word_back :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\ngone\n")
	set(ALPHA, "keep", "gone")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	write_file(f, f.file, "keep\n")
	sync_ok(f)
	testing.expect_value(t, joined(f, ALPHA), "keep")
	// Many syncs later, alpha's settings are restored from a backup, or the
	// tool resets to a list that still has the word.
	sync_ok(f)
	sync_ok(f)
	set(ALPHA, "GONE", "keep", "fresh")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\nfresh\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,fresh")
	testing.expect_value(t, joined(f, BETA), "keep,fresh")
}

@(test)
a_removed_word_comes_back_through_the_file_only :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\ngone\n")
	set(ALPHA, "keep", "gone")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, run(f, nil, "remove", "gone").code, 0)
	sync_ok(f)
	testing.expect_value(t, run(f, nil, "add", "Gone").code, 0)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\nGone\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,Gone")
	testing.expect_value(t, joined(f, BETA), "keep,Gone")
	// And once back, a tool's copy of it is a word like any other.
	set(BETA, "keep")
	sync_ok(f)
	testing.expect_value(t, joined(f, BETA), "keep,Gone")
	// The same by hand.
	write_file(f, f.file, "keep\n")
	sync_ok(f)
	testing.expect_value(t, joined(f, ALPHA), "keep")
	write_file(f, f.file, "keep\ngone\n")
	sync_ok(f)
	testing.expect_value(t, joined(f, ALPHA), "keep,gone")
}

@(test)
a_line_deleted_before_the_first_sync_on_a_host_comes_back :: proc(t: ^testing.T) {
	// The known limit: without a sync before the deletion, nothing on this
	// host knew the word was in the file, so a tool's copy is a new word.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\n")
	set(ALPHA, "keep", "gone")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\ngone\n")
}

@(test)
remove_records_the_removal_without_an_earlier_sync :: proc(t: ^testing.T) {
	// remove itself writes the record, so on a host that never synced it
	// is a removal all the same; a line deleted by hand there is not.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\ngone\n")
	set(ALPHA, "keep", "gone")
	set(BETA)
	set(GAMMA)
	testing.expect_value(t, run(f, nil, "remove", "gone").code, 0)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	testing.expect_value(t, joined(f, ALPHA), "keep")
}

@(test)
an_adapter_that_fails_leaves_the_others_synced_and_exits_1 :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "from-alpha")
	set(BETA, "from-beta")
	set(GAMMA, "from-gamma")
	stores[ALPHA].fail_read = true
	r := run(f, adapters(), "sync")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "alpha") && strings.contains(r.err, "refuses to be read"), "says which and why: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "a\nfrom-gamma\nfrom-beta\n")
	testing.expect_value(t, joined(f, BETA), "from-beta,a,from-gamma")
	testing.expect_value(t, joined(f, GAMMA), "from-gamma,a,from-beta")
	testing.expect_value(t, stores[ALPHA].writes, 0)

	stores[ALPHA].fail_read = false
	stores[BETA].fail_write = true
	r = run(f, adapters(), "sync")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, strings.contains(r.err, "beta"))
	testing.expect_value(t, read_file(f, f.file), "a\nfrom-gamma\nfrom-beta\nfrom-alpha\n")
	testing.expect_value(t, joined(f, ALPHA), "from-alpha,a,from-gamma,from-beta")
	testing.expect_value(t, joined(f, GAMMA), "from-gamma,a,from-beta,from-alpha")
}

@(test)
an_adapter_s_duplicates_and_empty_words_are_cleaned :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "", "  ", " Foo ", "foo", "FOO", "a", "A", "\t", "Bar")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "a\nFoo\nBar\n")
	testing.expect_value(t, joined(f, ALPHA), "Foo,a,Bar")
}

@(test)
a_word_from_a_tool_that_the_file_cannot_hold_stays_in_the_tool :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "a|b", "#tag", "fine")
	set(BETA)
	set(GAMMA)
	r := sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "a\nfine\n")
	testing.expect_value(t, joined(f, ALPHA), "a|b,#tag,fine,a")
	testing.expect_value(t, joined(f, BETA), "a,fine")
	testing.expectf(t, strings.contains(r.err, "a|b") && strings.contains(r.err, "#tag"), "warns: %s", r.err)
}

@(test)
sync_with_one_adapter_reaches_only_that_one :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "x")
	set(BETA, "y")
	set(GAMMA, "z")
	sync_ok(f, "--adapter", "beta")
	testing.expect_value(t, read_file(f, f.file), "a\ny\n")
	testing.expect_value(t, stores[ALPHA].reads, 0)
	testing.expect_value(t, stores[GAMMA].reads, 0)
	testing.expect_value(t, joined(f, BETA), "y,a")
	// A removal seen in a sync of one adapter reaches the others in theirs.
	set(ALPHA, "a", "y")
	sync_ok(f, "--adapter", "alpha")
	testing.expect_value(t, run(f, nil, "remove", "y").code, 0)
	sync_ok(f, "--adapter", "beta")
	testing.expect_value(t, joined(f, BETA), "a")
	sync_ok(f, "--adapter", "alpha")
	testing.expect_value(t, joined(f, ALPHA), "a")
}

@(test)
an_adapter_that_must_be_stopped_is_written_last :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA)
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, strings.join(write_log[:], ",", f.a), "alpha,beta,gamma")
}

@(test)
an_emptied_dictionary_is_refused_until_asked_for :: proc(t: ^testing.T) {
	// An editor that truncates the file before it writes it, a checkout
	// gone wrong: a file with no word left would take every word from
	// every tool. sync refuses that unless --allow-empty says it is meant.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\nb\n")
	set(ALPHA, "a", "b")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	for text in ([]string{"", "# only comments now\n\n"}) {
		write_file(f, f.file, text)
		r := run(f, adapters(), "sync")
		testing.expect_value(t, r.code, 1)
		testing.expectf(t, strings.contains(r.err, "--allow-empty"), "says how: %s", r.err)
		testing.expectf(t, strings.contains(r.err, "the 2 words of the last sync"), "says which words would go: %s", r.err)
		testing.expect_value(t, joined(f, ALPHA), "a,b")
		testing.expect_value(t, read_file(f, f.file), text)
	}
	// Put back, nothing was lost.
	write_file(f, f.file, "a\nb\n")
	sync_ok(f)
	testing.expect_value(t, joined(f, ALPHA), "a,b")
	write_file(f, f.file, "")
	sync_ok(f, "--allow-empty")
	testing.expect_value(t, joined(f, ALPHA), "")
	testing.expect_value(t, read_file(f, f.file), "")
	// A first sync of an empty file is no such case.
	g := fixture(t)
	defer fixture_destroy(g)
	write_file(g, g.file, "")
	set(ALPHA, "x")
	set(BETA)
	set(GAMMA)
	sync_ok(g)
	testing.expect_value(t, read_file(g, g.file), "x\n")
}

@(test)
a_dictionary_with_a_merge_conflict_is_not_synced :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\nb\n")
	set(ALPHA, "a", "b")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	text := "a\n<<<<<<< HEAD\n=======\nb\n>>>>>>> theirs\n"
	write_file(f, f.file, text)
	r := run(f, adapters(), "sync")
	testing.expect_value(t, r.code, 1)
	testing.expect_value(t, read_file(f, f.file), text)
	testing.expect_value(t, joined(f, ALPHA), "a,b")
}

@(test)
the_state_is_plain_text_and_a_lost_state_loses_no_word :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "Keep\nGone\n")
	set(ALPHA, "Keep", "Gone")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, run(f, nil, "remove", "gone").code, 0)
	removed := read_file(f, join(f, "state", "removed"))
	testing.expectf(t, strings.contains(removed, "\ngone\n"), "the record names the word: %q", removed)
	sync_ok(f)
	known := read_file(f, join(f, "state", "known"))
	testing.expectf(t, strings.contains(known, "\nkeep\n") && !strings.contains(known, "\ngone\n"), "known: %q", known)
	// A state that is deleted only forgets removals; the next sync is a
	// first one, and every word in the file and the tools stays.
	os.remove_all(f.state)
	set(ALPHA, "Keep", "Other")
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "Keep\nOther\n")
}

@(test)
a_corrupt_state_is_an_error_not_a_guess :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "a")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	write_file(f, join(f, "state", "removed"), "# ravnix-dict\nok\n\xff\xfe\n")
	r := run(f, adapters(), "sync")
	testing.expect_value(t, r.code, 1)
	testing.expectf(t, strings.contains(r.err, "removed"), "names the file: %s", r.err)
	testing.expect_value(t, joined(f, ALPHA), "a")
}

@(test)
syncs_a_huge_dictionary :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	N :: 50_000
	b := strings.builder_make(f.a)
	tool := make([]string, N, f.a)
	for i in 0 ..< N {
		fmt.sbprintf(&b, "file%d\n", i)
		tool[i] = fmt.aprintf("tool%d", i, allocator = f.a)
	}
	write_file(f, f.file, strings.to_string(b))
	set(ALPHA, ..tool)
	set(BETA)
	set(GAMMA)
	start := time.tick_now()
	sync_ok(f)
	elapsed := time.duration_seconds(time.tick_since(start))
	testing.expectf(t, elapsed < 20, "50 000 words each way took %.1f s", elapsed)
	testing.expect_value(t, len(words_of(ALPHA)), 2 * N)
	testing.expect_value(t, len(words_of(BETA)), 2 * N)
	testing.expect_value(t, len(listed(f)), 2 * N)
}

@(test)
a_file_changed_while_sync_reads_the_tools_is_not_overwritten :: proc(t: ^testing.T) {
	// The file is replaced only when it still holds what sync read: a word
	// that an editor saved in the meantime is not lost to the rename.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	sneak_path = f.file
	sneaked = false
	defer sneak_path = ""
	list := [1]dict.Adapter{{name = "sneaky", read = read_sneaky, write = write_sneaky}}
	r := run(f, list[:], "sync")
	testing.expectf(t, r.code == 0, "sync exits 0 after a second try: %s", r.err)
	testing.expect_value(t, read_file(f, f.file), "a\nby-hand\nfrom-tool\n")
}

@(thread_local)
sneak_path: string
@(thread_local)
sneaked: bool

read_sneaky :: proc() -> ([]string, dict.Error) {
	if !sneaked {
		sneaked = true
		// The user saves the file in an editor while sync runs.
		_ = os.write_entire_file(sneak_path, "a\nby-hand\n")
	}
	out := make([]string, 1)
	out[0] = "from-tool"
	return out, nil
}

write_sneaky :: proc(words: []string) -> dict.Error {
	return nil
}

@(test)
a_removed_word_that_turns_up_in_a_tool_is_stripped_until_it_is_added :: proc(t: ^testing.T) {
	// The maintainer's rule (2026-11-14): strip it, add it back on purpose.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\nword\n")
	set(ALPHA, "keep", "word")
	set(BETA)
	set(GAMMA)
	sync_ok(f)
	testing.expect_value(t, run(f, nil, "remove", "word").code, 0)
	sync_ok(f)
	testing.expect_value(t, joined(f, GAMMA), "keep")
	// Handy, quitting, writes its list from memory, and the word with it.
	set(GAMMA, "keep", "Word")
	sync_ok(f)
	testing.expect_value(t, joined(f, GAMMA), "keep")
	testing.expect_value(t, read_file(f, f.file), "keep\n")
	// And again, in another tool, many syncs later.
	sync_ok(f)
	set(BETA, "word", "keep")
	sync_ok(f)
	testing.expect_value(t, joined(f, BETA), "keep")
	// add clears the record: the word is back in the file and every tool.
	testing.expect_value(t, run(f, nil, "add", "word").code, 0)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\nword\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,word")
	testing.expect_value(t, joined(f, BETA), "keep,word")
	testing.expect_value(t, joined(f, GAMMA), "keep,word")
	testing.expect(t, !has(lines(f, read_file(f, join(f, "state", "removed"))), "word"))
	// Once back, a tool that loses it gets it again, like any word.
	set(GAMMA, "keep")
	sync_ok(f)
	testing.expect_value(t, joined(f, GAMMA), "keep,word")
}

@(test)
add_right_after_remove_brings_the_word_back :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\nword\n")
	set(ALPHA, "keep", "word")
	set(BETA, "keep", "word")
	set(GAMMA, "keep", "word")
	sync_ok(f)
	// Changed one's mind before any sync carried the removal.
	testing.expect_value(t, run(f, nil, "remove", "word").code, 0)
	testing.expect_value(t, run(f, nil, "add", "Word").code, 0)
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\nWord\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,Word")
	testing.expect_value(t, joined(f, GAMMA), "keep,Word")
}

@(thread_local)
gone_reason: string

@(test)
an_unavailable_adapter_is_skipped_and_is_no_failure :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	set(ALPHA, "b")
	set(BETA, "c")
	gone_reason = "the vault is locked"
	defer gone_reason = ""
	list := [2]dict.Adapter {
		{name = "alpha", read = read_alpha, write = write_alpha},
		{name = "beta", read = read_beta, write = write_beta, unavailable = proc() -> string {return gone_reason}},
	}
	r := run(f, list[:], "sync")
	testing.expectf(t, r.code == 0, "sync exits 0: %s", r.err)
	testing.expectf(t, strings.contains(r.out, "beta: skipped: the vault is locked"), "%s", r.out)
	testing.expect_value(t, stores[BETA].reads, 0)
	testing.expect_value(t, stores[BETA].writes, 0)
	testing.expect_value(t, read_file(f, f.file), "a\nb\n")
	testing.expect_value(t, joined(f, ALPHA), "b,a")
	// Once it is there again, it is synced.
	gone_reason = ""
	r = run(f, list[:], "sync")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, joined(f, BETA), "c,a,b")
	testing.expect_value(t, read_file(f, f.file), "a\nb\nc\n")
}

@(test)
sync_tells_the_adapters_where_the_state_is :: proc(t: ^testing.T) {
	// Handy's adapter keeps the marker of a stopped Handy there.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "a\n")
	tools.state_dir = ""
	sync_ok(f)
	testing.expect_value(t, tools.state_dir, f.state)
}

@(test)
a_word_struck_before_the_first_sync_never_comes_in :: proc(t: ^testing.T) {
	// The first merge (README.md, "The first sync"): add and remove a word
	// a tool has, and the first sync takes it out instead of taking it in.
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, f.file, "keep\n")
	set(ALPHA, "keep", "junk", "new")
	set(BETA, "Junk")
	set(GAMMA)
	testing.expect_value(t, run(f, nil, "add", "junk").code, 0)
	testing.expect_value(t, run(f, nil, "remove", "junk").code, 0)
	testing.expect(t, !os.exists(join(f, "state", "known")))
	sync_ok(f)
	testing.expect_value(t, read_file(f, f.file), "keep\nnew\n")
	testing.expect_value(t, joined(f, ALPHA), "keep,new")
	testing.expect_value(t, joined(f, BETA), "keep,new")
	testing.expect_value(t, joined(f, GAMMA), "keep,new")
	// And the sync by hand leaves what the watcher waits for.
	testing.expect(t, os.exists(join(f, "state", "known")))
}
