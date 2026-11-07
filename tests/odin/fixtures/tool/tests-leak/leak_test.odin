// Passes on its assertion and leaks: the run must fail on the leak alone.
package fixture_leak

import "core:testing"

@(test)
leaks :: proc(t: ^testing.T) {
	p := new(int)
	p^ = 3
	testing.expect_value(t, p^, 3)
}
