// The fixtures of the gate's tests: a system under a temporary root, with the
// sysfs files each verb reads and, where a test wants it, journald's
// /dev/log as a real Unix socket.
package ravnix_laptop_gate_tests

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"

Fixture :: struct {
	arena: virtual.Arena,
	root:  string,
}

// fixture makes an empty root in TMPDIR, and points the context's
// allocator at the fixture's arena; done frees both.
fixture :: proc(t: ^testing.T, f: ^Fixture) {
	testing.expect_value(t, virtual.arena_init_growing(&f.arena), nil)
	context.allocator = virtual.arena_allocator(&f.arena)
	dir, err := os.make_directory_temp("", "laptop-gate-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	f.root = dir
}

done :: proc(f: ^Fixture) {
	_ = os.remove_all(f.root)
	virtual.arena_destroy(&f.arena)
}

join :: proc(f: ^Fixture, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1, virtual.arena_allocator(&f.arena))
	append(&all, f.root)
	append(&all, ..parts)
	return strings.join(all[:], "/", virtual.arena_allocator(&f.arena))
}

make_dirs :: proc(t: ^testing.T, path: string) {
	err := os.make_directory_all(path)
	testing.expectf(t, err == nil || err == .Exist, "%s: %v", path, err)
}

// write writes a file under the root, making its directories.
write :: proc(t: ^testing.T, f: ^Fixture, path, data: string) {
	full := join(f, path)
	make_dirs(t, full[:strings.last_index_byte(full, '/')])
	testing.expect_value(t, os.write_entire_file(full, transmute([]byte)data), nil)
}

// unreadable takes every permission from a file, as the kernel gives
// RAPL's energy_uj to root alone. Root reads it anyway: a test that relies
// on it asks can_deny first.
unreadable :: proc(t: ^testing.T, f: ^Fixture, path: string) {
	testing.expect_value(t, os.change_mode(join(f, path), {}), nil)
}

can_deny :: proc() -> bool {
	return linux.geteuid() != 0
}

// The laptop of the tests: an IdeaPad's battery and AC, an NVIDIA dGPU
// beside an AMD iGPU, and two RAPL zones, one of them root's alone.
laptop :: proc(t: ^testing.T, f: ^Fixture) {
	ps :: "sys/class/power_supply/"
	write(t, f, ps + "AC/type", "Mains\n")
	write(t, f, ps + "AC/online", "1\n")
	write(t, f, ps + "BAT0/type", "Battery\n")
	write(t, f, ps + "BAT0/status", "Discharging\n")
	write(t, f, ps + "BAT0/capacity", "80\n")
	write(t, f, ps + "BAT0/power_now", "9512000\n")
	write(t, f, ps + "BAT0/energy_now", "60000000\n")
	write(t, f, ps + "BAT0/energy_full", "70000000\n")
	write(t, f, ps + "BAT0/energy_full_design", "75000000\n")
	write(t, f, ps + "BAT0/cycle_count", "42\n")
	write(t, f, ps + "BAT0/charge_types", "Fast [Standard] Long_Life\n")

	pci :: "sys/bus/pci/devices/"
	write(t, f, pci + "0000:01:00.0/vendor", "0x10de\n")
	write(t, f, pci + "0000:01:00.0/class", "0x030000\n")
	write(t, f, pci + "0000:01:00.0/power/runtime_status", "suspended\n")
	write(t, f, pci + "0000:01:00.0/power_state", "D3cold\n")
	// The dGPU's audio function: NVIDIA's, and no display.
	write(t, f, pci + "0000:01:00.1/vendor", "0x10de\n")
	write(t, f, pci + "0000:01:00.1/class", "0x040300\n")
	write(t, f, pci + "0000:01:00.1/power/runtime_status", "suspended\n")
	// The iGPU, AMD's.
	write(t, f, pci + "0000:05:00.0/vendor", "0x1002\n")
	write(t, f, pci + "0000:05:00.0/class", "0x030000\n")
	write(t, f, pci + "0000:05:00.0/power/runtime_status", "active\n")

	pc :: "sys/class/powercap/"
	// The control type, which is no zone.
	write(t, f, pc + "intel-rapl/enabled", "1\n")
	write(t, f, pc + "intel-rapl:0/name", "package-0\n")
	write(t, f, pc + "intel-rapl:0/energy_uj", "123456789\n")
	write(t, f, pc + "intel-rapl:0:0/name", "core\n")
	write(t, f, pc + "intel-rapl:0:0/energy_uj", "4242\n")
	unreadable(t, f, pc + "intel-rapl:0:0/energy_uj")
}

// listen_log binds the root's dev/log, as journald does.
listen_log :: proc(t: ^testing.T, f: ^Fixture) -> linux.Fd {
	path := join(f, "dev/log")
	make_dirs(t, path[:strings.last_index_byte(path, '/')])
	fd, errno := linux.socket(.UNIX, .DGRAM, {}, .HOPOPT)
	testing.expect_value(t, errno, linux.Errno.NONE)
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	copy(addr.sun_path[:len(addr.sun_path) - 1], path)
	testing.expect_value(t, linux.bind(fd, &addr), linux.Errno.NONE)
	return fd
}

// logged is every message waiting on the log socket.
logged :: proc(fd: linux.Fd, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for {
		buf := make([]u8, 4096, allocator)
		from: linux.Sock_Addr_Un
		n, errno := linux.recvfrom(fd, buf, {.DONTWAIT}, &from)
		if errno != .NONE || n <= 0 {
			break
		}
		append(&out, string(buf[:n]))
	}
	return out[:]
}
