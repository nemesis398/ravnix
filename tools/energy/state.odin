package energy

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"

// The settings that persist, one file each in the state directory
// (~/.local/state/energy): the file holds the value and a newline.
Key :: struct {
	name:    string,
	default: string,
	values:  []string,
}

KEYS := [?]Key {
	{"refresh", "auto", {"auto", "120", "60"}},
	{"idle_suspend", "on", {"on", "off"}},
	{"focus_bar", "off", {"on", "off"}},
}

find_key :: proc(name: string) -> (key: Key, ok: bool) {
	for k in KEYS {
		if k.name == name {
			return k, true
		}
	}
	return
}

valid_value :: proc(key: Key, value: string) -> bool {
	for v in key.values {
		if v == value {
			return true
		}
	}
	return false
}

// The longest state file read. A value is at most four bytes; a file that
// holds more is not one.
STATE_READ_LIMIT :: 64

// state_get is the value of a key: what the file holds, or the default when
// there is no file, it cannot be read, or it holds none of the key's values
// (an empty or torn file, a hand-made mistake). Fedora's script counted such
// a file as an empty value, so an empty refresh meant auto and an empty
// idle_suspend meant off.
state_get :: proc(cfg: ^Config, key: Key) -> string {
	if cfg.state_dir == "" {
		return key.default
	}
	buf: [STATE_READ_LIMIT + 1]u8
	path := strings.concatenate({cfg.state_dir, "/", key.name}, context.temp_allocator)
	// A file that is not a regular one (a FIFO) must not block the reader.
	fd, errno := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return key.default
	}
	defer linux.close(fd)
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE || n > STATE_READ_LIMIT {
		return key.default
	}
	text := strings.trim_space(string(buf[:n]))
	for v in key.values {
		if v == text {
			return v
		}
	}
	return key.default
}

@(private = "file")
temp_counter: u32

// state_set saves a value through a temporary file and a rename, so two
// sets at once leave one whole value, and a get never reads a file halfway
// written. The caller has checked the value. It returns 0, or 1 with the
// reason on the error output.
state_set :: proc(cfg: ^Config, key: Key, value: string) -> int {
	if cfg.state_dir == "" {
		say(cfg, "energy: cannot save %s: neither XDG_STATE_HOME nor HOME is set", key.name)
		return 1
	}
	if err := os.make_directory_all(cfg.state_dir); err != nil && err != .Exist {
		say(cfg, "energy: cannot make %s: %s", cfg.state_dir, os.error_string(err))
		return 1
	}
	final := strings.concatenate({cfg.state_dir, "/", key.name}, context.temp_allocator)
	data := fmt.tprintf("%s\n", value)

	tmp: cstring
	fd: linux.Fd
	errno: linux.Errno
	for _ in 0 ..< 100 {
		serial := sync.atomic_add(&temp_counter, 1)
		name := fmt.tprintf("%s/.%s.%d.%d", cfg.state_dir, key.name, os.get_pid(), serial)
		tmp = strings.clone_to_cstring(name, context.temp_allocator)
		fd, errno = linux.open(tmp, {.WRONLY, .CREAT, .EXCL, .CLOEXEC}, {.IRUSR, .IWUSR})
		if errno != .EEXIST {
			break
		}
	}
	if errno != .NONE {
		say(cfg, "energy: cannot save %s: %v", key.name, errno)
		return 1
	}
	written, werr := linux.write(fd, transmute([]u8)data)
	ferr := linux.fsync(fd)
	_ = linux.close(fd)
	if werr != .NONE || written != len(data) || ferr != .NONE {
		_ = linux.unlink(tmp)
		say(cfg, "energy: cannot save %s: %v", key.name, werr if werr != .NONE else ferr)
		return 1
	}
	if rerr := linux.rename(tmp, strings.clone_to_cstring(final, context.temp_allocator)); rerr != .NONE {
		_ = linux.unlink(tmp)
		say(cfg, "energy: cannot save %s: %v", key.name, rerr)
		return 1
	}
	return 0
}

// read_text is the content of a small file of the runtime directory or
// sysfs without its trailing newlines, as `$(cat FILE)` gives it; ok is
// false when it cannot be read.
read_text :: proc(path: string) -> (text: string, ok: bool) {
	buf: [256]u8
	fd, errno := linux.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .CLOEXEC})
	if errno != .NONE {
		return
	}
	defer linux.close(fd)
	n, rerr := linux.read(fd, buf[:])
	if rerr != .NONE {
		return
	}
	return strings.trim_right(strings.clone(string(buf[:n]), context.temp_allocator), "\n"), true
}
