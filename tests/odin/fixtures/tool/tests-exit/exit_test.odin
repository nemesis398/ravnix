// A test that ends the process with status 0 before the runner reports:
// plain odin test exits 0 here, and the run must not pass.
package fixture_exit

import "core:os"
import "core:testing"

@(test)
exits :: proc(t: ^testing.T) {
	testing.expect(t, true)
	os.exit(0)
}
