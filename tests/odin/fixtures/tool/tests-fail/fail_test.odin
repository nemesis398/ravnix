package fixture_fail

import "core:testing"

@(test)
fails :: proc(t: ^testing.T) {
	testing.expect_value(t, 1 + 1, 3)
}
