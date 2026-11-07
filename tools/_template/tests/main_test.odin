// The template's tests. The check template-tests runs them with a fixed seed
// and fails a test that leaks or frees badly, even when its assertions hold.
package template_tests

import "core:testing"
import template ".."

@(test)
tells_blank_from_text :: proc(t: ^testing.T) {
	testing.expect(t, template.is_blank(""))
	testing.expect(t, template.is_blank(" \t\n\u3000"))
	testing.expect(t, !template.is_blank(" Huginn "))
}

@(test)
counts_words_and_frees_what_it_takes :: proc(t: ^testing.T) {
	count := template.count_words("Huginn and Muninn,\tthought and memory\n")
	testing.expect_value(t, count, template.Count{words = 6, unique = 5})
}
