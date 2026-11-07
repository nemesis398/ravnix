// The template for a ravnix tool (tools/README.md): it counts the words of
// a text and how many of them are unique. Copy the directory, rename the
// package, and replace the counting with the tool's work; keep the shape:
// the work in procedures the tests can call, and main as thin as it can be.
package template

import "core:fmt"
import "core:os"
import "core:strings"

Count :: struct {
	words:  int,
	unique: int,
}

// count_words counts the words of text, split on Unicode white space, and
// how many of them are unique.
count_words :: proc(text: string) -> Count {
	seen := make(map[string]struct{})
	defer delete(seen)
	words := 0
	rest := text
	for word in strings.fields_iterator(&rest) {
		seen[word] = {}
		words += 1
	}
	return Count{words = words, unique = len(seen)}
}

// is_blank reports whether text holds no word at all.
is_blank :: proc(text: string) -> bool {
	return len(strings.trim_space(text)) == 0
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.eprintln("usage: template [FILE]")
		os.exit(2)
	}
	data: []byte
	err: os.Error
	if len(os.args) == 2 {
		data, err = os.read_entire_file(os.args[1], context.allocator)
	} else {
		data, err = os.read_entire_file(os.stdin, context.allocator)
	}
	if err != nil {
		fmt.eprintfln("template: cannot read %s: %s", os.args[1] if len(os.args) == 2 else "standard input", os.error_string(err))
		os.exit(1)
	}
	defer delete(data)
	count := count_words(string(data))
	fmt.printfln("%d words, %d unique", count.words, count.unique)
}
