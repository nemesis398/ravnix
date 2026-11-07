// The template's tests. The check template-tests runs them with a fixed seed
// and fails a test that leaks or frees badly, even when its assertions hold.
// A tool copied from here keeps the habit: each edge case is a test.
package template_tests

import "core:os"
import "core:testing"
import template ".."

@(test)
tells_blank_from_text :: proc(t: ^testing.T) {
	testing.expect(t, template.is_blank(""))
	testing.expect(t, template.is_blank(" \t\n　"))
	testing.expect(t, !template.is_blank(" Huginn "))
}

@(test)
counts_words_and_frees_what_it_takes :: proc(t: ^testing.T) {
	count := template.count_words("Huginn and Muninn,\tthought and memory\n")
	testing.expect_value(t, count, template.Count{words = 6, unique = 5})
}

@(test)
counts_nothing_in_empty_input :: proc(t: ^testing.T) {
	testing.expect_value(t, template.count_words(""), template.Count{})
	testing.expect_value(t, template.count_words(" \n\t "), template.Count{})
}

@(test)
reads_a_file :: proc(t: ^testing.T) {
	data, err := template.read_input(#file)
	defer delete(data)
	testing.expect_value(t, err, nil)
	testing.expect(t, len(data) > 0)
}

@(test)
refuses_a_missing_file :: proc(t: ^testing.T) {
	data, err := template.read_input("/no/such/file")
	testing.expect_value(t, err, os.General_Error.Not_Exist)
	testing.expect_value(t, len(data), 0)
}
