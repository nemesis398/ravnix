// The prose adapter: the prose skill's dictionary file, read as the skill's
// checker reads it, and written with its comments and layout kept.
package ravnix_dict_tests

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import tools "../adapters"

prose_setup :: proc(f: ^Fixture) -> string {
	file := join(f, "prose", "dictionary.txt")
	tools.prose = {file = file}
	return file
}

@(test)
prose_reads_words_as_the_checker_does :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	file := prose_setup(f)
	testing.expect_value(t, os.make_directory(join(f, "prose")), nil)
	write_file(f, file, "# a comment\n\n  restic  \nKonzept\r\n   # indented comment\nC#\nOpen WebUI\nlast")
	words, err := tools.prose_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.join(words, "|"), "restic|Konzept|C#|Open WebUI|last")
}

@(test)
prose_writes_and_keeps_comments_layout_and_places :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	file := prose_setup(f)
	testing.expect_value(t, os.make_directory(join(f, "prose")), nil)
	write_file(f, file, "# head\nrestic\n\n# German\n  konzept\r\ngone\nlast")
	_, _ = tools.prose_read()
	// restic stays, konzept gets the dictionary's spelling in its place,
	// gone is removed, and two new words come at the end.
	testing.expect_value(t, tools.prose_write({"restic", "Konzept", "last", "Huginn", "Open WebUI"}), nil)
	testing.expect_value(t, read_file(f, file), "# head\nrestic\n\n# German\n  Konzept\r\nlast\nHuginn\nOpen WebUI\n")
	words, _ := tools.prose_read()
	testing.expect_value(t, strings.join(words, "|"), "restic|Konzept|last|Huginn|Open WebUI")
	// A word twice in the file is once in it after a write.
	write_file(f, file, "a\nA\nb\n")
	testing.expect_value(t, tools.prose_write({"a", "b"}), nil)
	testing.expect_value(t, read_file(f, file), "a\nb\n")
}

@(test)
a_missing_prose_dictionary_is_made_with_a_header :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	file := prose_setup(f)
	words, err := tools.prose_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(words), 0)
	testing.expect_value(t, tools.prose_write({"Huginn", "Muninn"}), nil)
	text := read_file(f, file)
	testing.expect(t, strings.has_prefix(text, "# Words the prose skill"))
	testing.expect(t, strings.has_suffix(text, "\nHuginn\nMuninn\n"))
	again, _ := tools.prose_read()
	testing.expect_value(t, strings.join(again, "|"), "Huginn|Muninn")
	// And emptied: the header stays.
	testing.expect_value(t, tools.prose_write({}), nil)
	testing.expect(t, strings.has_prefix(read_file(f, file), "# Words"))
	none, _ := tools.prose_read()
	testing.expect_value(t, len(none), 0)
}

@(test)
a_prose_dictionary_that_is_not_text_is_an_error_and_left_alone :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	file := prose_setup(f)
	testing.expect_value(t, os.make_directory(join(f, "prose")), nil)
	write_file(f, file, "Gr\xfc\xdfe\n")
	_, err := tools.prose_read()
	testing.expect(t, err != nil)
	testing.expect(t, tools.prose_write({"x"}) != nil)
	testing.expect_value(t, read_file(f, file), "Gr\xfc\xdfe\n")
	// A directory where the file should be.
	tools.prose.file = join(f, "prose")
	_, err = tools.prose_read()
	testing.expect(t, err != nil)
}

@(test)
prose_keeps_the_file_s_mode_and_link_and_a_read_only_file :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	file := prose_setup(f)
	testing.expect_value(t, os.make_directory(join(f, "prose")), nil)
	real := join(f, "real.txt")
	write_file(f, real, "a\n")
	testing.expect_value(t, os.chmod(real, {.Read_User, .Write_User}), nil)
	testing.expect_value(t, os.symlink(real, file), nil)
	testing.expect_value(t, tools.prose_write({"a", "b"}), nil)
	target, _ := os.read_link(file, f.a)
	testing.expect_value(t, target, real)
	testing.expect_value(t, read_file(f, real), "a\nb\n")
	st: linux.Stat
	linux.stat(strings.clone_to_cstring(real), &st)
	testing.expect_value(t, transmute(u32)st.mode & 0o777, 0o600)
	// Read-only is the user's no.
	testing.expect_value(t, os.chmod(real, {.Read_User}), nil)
	testing.expect(t, tools.prose_write({"a", "b", "c"}) != nil)
	testing.expect_value(t, read_file(f, real), "a\nb\n")
}
