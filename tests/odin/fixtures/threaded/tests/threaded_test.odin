package threaded_tests

import "core:testing"
import threaded ".."

@(test)
churns_the_same_twice :: proc(t: ^testing.T) {
	testing.expect_value(t, threaded.churn(1000), threaded.churn(1000))
	testing.expect_value(t, threaded.churn(0), 0)
}
