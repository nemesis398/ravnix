package copier_tests

import "core:testing"
import copier ".."

@(test)
copies :: proc(t: ^testing.T) {
	testing.expect_value(t, copier.copy_rounds(1), copier.copy_rounds(1))
}
