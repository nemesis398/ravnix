// A fixture tool for tests/odin/harness.nix: prints the size of the file its
// first argument names, or of its standard input without one. Each tests*
// directory next to it is one way a test run can end.
package fixture

import "core:fmt"
import "core:os"

size_of_file :: proc(path: string) -> (int, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return 0, false
	}
	defer delete(data)
	return len(data), true
}

size_of_stdin :: proc() -> (int, bool) {
	data, err := os.read_entire_file(os.stdin, context.allocator)
	if err != nil {
		return 0, false
	}
	defer delete(data)
	return len(data), true
}

main :: proc() {
	if len(os.args) > 2 {
		fmt.eprintln("usage: fixture [FILE]")
		os.exit(2)
	}
	size: int
	ok: bool
	if len(os.args) == 2 {
		size, ok = size_of_file(os.args[1])
	} else {
		size, ok = size_of_stdin()
	}
	if !ok {
		fmt.eprintfln("fixture: cannot read %s", os.args[1] if len(os.args) == 2 else "standard input")
		os.exit(1)
	}
	fmt.println(size)
}
