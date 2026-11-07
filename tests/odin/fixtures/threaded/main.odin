// A fixture for tests/odin/harness.nix whose work runs in a worker thread:
// it churns the number of rounds its argument gives, and the main thread
// only starts the worker and waits for it. The bench must count the
// worker's instructions, which never run under main.
package threaded

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:thread"

Work :: struct {
	rounds: int,
	result: u64,
}

// churn runs rounds of a linear congruential generator; the work is all
// arithmetic, so its count grows by the same amount per round.
churn :: proc(rounds: int) -> u64 {
	x: u64 = 12345
	sum: u64 = 0
	for _ in 0 ..< rounds {
		x = x * 6364136223846793005 + 1442695040888963407
		sum ~= x >> 17
	}
	return sum
}

worker :: proc(t: ^thread.Thread) {
	work := cast(^Work)t.data
	work.result = churn(work.rounds)
}

main :: proc() {
	rounds := 0
	if len(os.args) == 2 {
		rounds, _ = strconv.parse_int(os.args[1])
	}
	work := Work{rounds = rounds}
	t := thread.create(worker)
	t.data = &work
	thread.start(t)
	thread.join(t)
	thread.destroy(t)
	fmt.println(work.result)
}
