// The disk primitives that the core and the adapters share: opening and
// reading with EINTR handled, the messages for an errno, and replacing a
// file through a rename (store.odin, adapters/common.odin). A leaf
// package: the core imports the adapters, so neither can hold this for the
// other.
package disk

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

errno_text :: proc(e: linux.Errno) -> string {
	#partial switch e {
	case .ENOENT:
		return "it does not exist"
	case .EACCES, .EPERM:
		return "permission denied"
	case .EISDIR:
		return "it is a directory"
	case .ENOSPC:
		return "the disk is full"
	case .EROFS:
		return "the file system is read-only"
	case .ENOTDIR:
		return "a part of the path is not a directory"
	case .ELOOP:
		return "it is a loop of links"
	}
	return fmt.tprintf("error %d", int(e))
}

open_retry :: proc(path: string, flags: linux.Open_Flags, mode: u32 = 0) -> (linux.Fd, linux.Errno) {
	for {
		fd, e := linux.open(cstr(path), flags, transmute(linux.Mode)mode)
		if e != .EINTR {
			return fd, e
		}
	}
}

// read_fd reads all of fd, refusing more than limit bytes.
read_fd :: proc(fd: linux.Fd, limit: int, allocator: runtime.Allocator) -> (data: []u8, too_big: bool, e: linux.Errno) {
	st: linux.Stat
	if e = linux.fstat(fd, &st); e != .NONE {
		return
	}
	if linux.S_ISDIR(st.mode) {
		return nil, false, .EISDIR
	}
	if int(st.size) > limit {
		return nil, true, .NONE
	}
	buf := make([dynamic]u8, 0, int(st.size) + 1, allocator)
	chunk: [64 * 1024]u8
	for {
		n, re := linux.read(fd, chunk[:])
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			return nil, false, re
		}
		if n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
		if len(buf) > limit {
			return nil, true, .NONE
		}
	}
	return buf[:], false, .NONE
}

// read_path reads all of the file at path, refusing more than limit
// bytes.
read_path :: proc(path: string, limit: int, allocator: runtime.Allocator) -> (data: string, too_big: bool, e: linux.Errno) {
	fd: linux.Fd
	fd, e = open_retry(path, {.CLOEXEC})
	if e != .NONE {
		return
	}
	defer linux.close(fd)
	bytes: []u8
	bytes, too_big, e = read_fd(fd, limit, allocator)
	return string(bytes), too_big, e
}

// real_path is path with every link resolved.
real_path :: proc(path: string, allocator: runtime.Allocator) -> (string, bool) {
	resolved := posix.realpath(cstr(path))
	if resolved == nil {
		return "", false
	}
	defer posix.free(rawptr(resolved))
	return strings.clone(string(resolved), allocator), true
}

dir_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	if i < 0 {
		return "."
	}
	return path[:max(i, 1)]
}

sync_dir :: proc(dir: string) {
	fd, e := open_retry(dir, {.DIRECTORY, .CLOEXEC})
	if e != .NONE {
		return
	}
	linux.fsync(fd)
	linux.close(fd)
}

write_all :: proc(fd: linux.Fd, data: []u8) -> linux.Errno {
	rest := data
	for len(rest) > 0 {
		n, e := linux.write(fd, rest)
		if e == .EINTR {
			continue
		}
		if e != .NONE {
			return e
		}
		rest = rest[n:]
	}
	return .NONE
}

Replace :: enum {
	Done,
	Failed,
	// The file no longer holds what was read: read it again.
	Changed,
}

// replace_file writes data to path through a file next to it and a rename,
// so a reader sees the old file or the new one. A link is followed, so the
// link stays a link; the file keeps its mode, and a file the user made
// read-only is not replaced. When expect is not nil, the rename happens
// only if path still holds expect. mode is the new file's mode when path
// does not exist; make_dir makes its directory when that is missing.
replace_file :: proc(path: string, data: string, expect: Maybe(string), mode: u32 = 0o600, make_dir := false) -> (result: Replace, why: string) {
	target := path
	if resolved, ok := real_path(path, context.temp_allocator); ok {
		target = resolved
	}
	if make_dir {
		if mwhy := make_dirs(dir_of(target), 0o755); mwhy != "" {
			return .Failed, mwhy
		}
	}
	perm := mode
	st: linux.Stat
	if linux.stat(cstr(target), &st) == .NONE {
		perm = transmute(u32)st.mode & 0o7777
		// The directory may allow a rename over a file the user made
		// read-only; that is the user's no, and it is kept.
		if e := linux.access(cstr(target), linux.W_OK); e != .NONE {
			return .Failed, fmt.tprintf("%s is not writable: %s", target, errno_text(e))
		}
	}
	slash := strings.last_index_byte(target, '/')
	tmp := fmt.tprintf("%s/.%s.ravnix-dict-new", dir_of(target), target[slash + 1:])
	fd, e := open_retry(tmp, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC, .NOFOLLOW}, 0o600)
	if e != .NONE {
		return .Failed, fmt.tprintf("cannot write next to %s: %s", target, errno_text(e))
	}
	we := write_all(fd, transmute([]u8)data)
	if we == .NONE {
		we = linux.fchmod(fd, transmute(linux.Mode)perm)
	}
	if we == .NONE {
		we = linux.fsync(fd)
	}
	linux.close(fd)
	if we != .NONE {
		linux.unlink(cstr(tmp))
		return .Failed, fmt.tprintf("cannot write next to %s: %s", target, errno_text(we))
	}
	if want, check := expect.?; check {
		now, too_big, re := read_path(target, max(len(want), 1) * 2 + 4096, context.temp_allocator)
		if re != .NONE || too_big || now != want {
			linux.unlink(cstr(tmp))
			return .Changed, ""
		}
	}
	if re := linux.rename(cstr(tmp), cstr(target)); re != .NONE {
		linux.unlink(cstr(tmp))
		return .Failed, fmt.tprintf("cannot replace %s: %s", target, errno_text(re))
	}
	sync_dir(dir_of(target))
	return .Done, ""
}

// make_dirs makes dir and its parents with mode, as mkdir -p does.
make_dirs :: proc(dir: string, mode: u32) -> string {
	for i := 1; i <= len(dir); i += 1 {
		if i < len(dir) && dir[i] != '/' {
			continue
		}
		e := linux.mkdir(cstr(dir[:i]), transmute(linux.Mode)mode)
		if e != .NONE && e != .EEXIST {
			return fmt.tprintf("cannot make the directory %s: %s", dir[:i], errno_text(e))
		}
	}
	return ""
}
