package fixture_tests

import "core:testing"
import fixture ".."

@(test)
reads_a_file :: proc(t: ^testing.T) {
	size, ok := fixture.size_of_file(#file)
	testing.expect(t, ok)
	testing.expect(t, size > 0)
}

@(test)
refuses_a_missing_file :: proc(t: ^testing.T) {
	_, ok := fixture.size_of_file("/no/such/file")
	testing.expect(t, !ok)
}
