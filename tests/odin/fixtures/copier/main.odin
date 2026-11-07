// A fixture for tests/odin/harness.nix whose count is mostly glibc's memmove
// and memset: the work whose instructions depend on the CPU that glibc sees,
// unless the bench pins glibc's choices.
package copier

import "core:fmt"
import "core:mem"

copy_rounds :: proc(rounds: int) -> int {
	big := make([]byte, 4 * 1024 * 1024)
	defer delete(big)
	other := make([]byte, len(big))
	defer delete(other)
	for i in 0 ..< len(big) {
		big[i] = byte(i * 31)
	}
	sum := 0
	for r in 0 ..< rounds {
		copy(other, big)
		copy(big[1:], other[:len(other) - 1])
		mem.zero_slice(other[:64 * 1024 + r])
		for size := 7; size < 70000; size *= 3 {
			copy(other[r:][:size], big[:size])
			mem.set(raw_data(big[size:]), byte(r), size / 2)
		}
		sum += int(other[r * 7]) + int(big[r * 13])
	}
	return sum
}

main :: proc() {
	fmt.println(copy_rounds(4))
}
