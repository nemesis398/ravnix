// A test package with no @(test) procedure: the run must not pass.
package fixture_none

import "core:testing"

helper :: proc(t: ^testing.T) {
	testing.expect(t, true)
}
