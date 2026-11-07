// A test that hangs: the run must end at the time limit, not with the build.
package fixture_sleep

import "core:testing"
import "core:time"

@(test)
hangs :: proc(t: ^testing.T) {
	time.sleep(time.Hour)
	testing.expect(t, true)
}
