package fixture_panic

import "core:testing"

@(test)
panics :: proc(t: ^testing.T) {
	values := []int{1, 2, 3}
	index := len(values)
	testing.expect_value(t, values[index], 4)
}
