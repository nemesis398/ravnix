// The disk: the dictionary file, the lock, and the state of the last sync.
//
// The dictionary is replaced, never written in place: a new file next to
// it, synced to the disk, then renamed over it, so a reader sees the old
// file or the new one. It is replaced only when it still holds what was
// read, so a word an editor saved in the meantime is not overwritten. A
// link is followed, so the link stays a link, and the file keeps its mode.
//
// The state directory holds, for this host:
//   lock     what one ravnix-dict at a time holds (flock)
//   known    the keys of the dictionary at the end of the last sync
//   removed  the keys of the words removed from the dictionary, kept
//            until the word is in the dictionary again
// Both lists are plain text, one key per line under a comment.
package ravnix_dict

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

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

// read_dictionary reads the dictionary at path. A missing file is an
// error: the path comes from the configuration, and a dictionary that is
// not where it should be is not an empty one.
read_dictionary :: proc(path: string, allocator: runtime.Allocator) -> (data: string, why: string) {
	fd, e := open_retry(path, {.CLOEXEC})
	if e != .NONE {
		if e == .ENOENT {
			return "", fmt.tprintf("there is no dictionary at %s (ravnix.dictionary.file); create it, an empty file will do", path)
		}
		return "", fmt.tprintf("cannot read the dictionary %s: %s", path, errno_text(e))
	}
	defer linux.close(fd)
	bytes, too_big, re := read_fd(fd, MAX_FILE_SIZE, allocator)
	if too_big {
		return "", fmt.tprintf("the dictionary %s is bigger than %d MiB, more than a list of words", path, MAX_FILE_SIZE / (1024 * 1024))
	}
	if re != .NONE {
		return "", fmt.tprintf("cannot read the dictionary %s: %s", path, errno_text(re))
	}
	return string(bytes), ""
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

// replace_file writes data to path through a file next to it and a rename.
// When expect is not nil, the rename happens only if path still holds
// expect. mode is the new file's mode when path does not exist.
replace_file :: proc(path: string, data: string, expect: Maybe(string), mode: u32 = 0o600) -> (result: Replace, why: string) {
	target := path
	if resolved, ok := real_path(path, context.temp_allocator); ok {
		target = resolved
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
		now, rwhy := read_dictionary(target, context.temp_allocator)
		if rwhy != "" || now != want {
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

// make_state makes the state directory, and its parents, private to the user.
make_state :: proc(dir: string) -> string {
	if dir == "" {
		return "there is no state directory"
	}
	for i := 1; i <= len(dir); i += 1 {
		if i < len(dir) && dir[i] != '/' {
			continue
		}
		e := linux.mkdir(cstr(dir[:i]), transmute(linux.Mode)u32(0o700))
		if e != .NONE && e != .EEXIST {
			return fmt.tprintf("cannot make the state directory %s: %s", dir[:i], errno_text(e))
		}
	}
	return ""
}

// lock takes the lock of the state directory, waiting up to wait_ms. The
// lock ends with the process, or with unlock.
lock :: proc(dir: string, wait_ms: int) -> (fd: linux.Fd, why: string) {
	if why = make_state(dir); why != "" {
		return -1, why
	}
	path := fmt.tprintf("%s/lock", dir)
	e: linux.Errno
	fd, e = open_retry(path, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}, 0o600)
	if e != .NONE {
		return -1, fmt.tprintf("cannot open the lock %s: %s", path, errno_text(e))
	}
	start: time.Tick
	for waited := false; ; waited = true {
		fe := linux.flock(fd, {.EX, .NB})
		#partial switch fe {
		case .NONE:
			return fd, ""
		case .EWOULDBLOCK, .EINTR:
		case:
			linux.close(fd)
			return -1, fmt.tprintf("cannot lock %s: %s", path, errno_text(fe))
		}
		if !waited {
			// The clock is read only by a run that has to wait.
			start = time.tick_now()
		} else if time.duration_milliseconds(time.tick_since(start)) >= f64(wait_ms) {
			linux.close(fd)
			return -1, fmt.tprintf("another ravnix-dict has held %s for %d s; try again when it is done", path, wait_ms / 1000)
		}
		time.sleep(10 * time.Millisecond)
	}
}

unlock :: proc(fd: linux.Fd) {
	if fd >= 0 {
		linux.flock(fd, {.UN})
		linux.close(fd)
	}
}

Keys :: map[string]struct{}

// read_keys reads a list of the state. A missing list is empty, and found
// is false; a list that is not one, because it is not UTF-8 or a line
// cannot be a key, is an error rather than a guess.
read_keys :: proc(dir, name: string, allocator: runtime.Allocator) -> (keys: Keys, found: bool, why: string) {
	keys = make(Keys, allocator)
	path := fmt.tprintf("%s/%s", dir, name)
	fd, e := open_retry(path, {.CLOEXEC, .NOFOLLOW})
	if e == .ENOENT {
		return keys, false, ""
	}
	if e != .NONE {
		return keys, false, fmt.tprintf("cannot read %s: %s", path, errno_text(e))
	}
	defer linux.close(fd)
	bytes, too_big, re := read_fd(fd, MAX_FILE_SIZE, allocator)
	if too_big || re != .NONE {
		return keys, false, fmt.tprintf("cannot read %s: %s", path, "it is too big" if too_big else errno_text(re))
	}
	text := string(bytes)
	if !utf8.valid_string(text) {
		return keys, false, fmt.tprintf("%s is not UTF-8; delete it, and the next sync starts afresh", path)
	}
	n := 0
	for line in strings.split_lines_iterator(&text) {
		n += 1
		if line == "" || line[0] == '#' {
			continue
		}
		if strings.contains_rune(line, '|') || len(line) > 4 * MAX_WORD {
			return keys, false, fmt.tprintf("line %d of %s is no word; delete the file, and the next sync starts afresh", n, path)
		}
		keys[line] = {}
	}
	return keys, true, ""
}

// write_keys replaces a list of the state, sorted, so it diffs cleanly.
write_keys :: proc(dir, name: string, keys: Keys, comment: string) -> string {
	sorted := make([]string, len(keys), context.temp_allocator)
	i := 0
	for k in keys {
		sorted[i] = k
		i += 1
	}
	slice.sort(sorted)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# %s\n", comment)
	for k in sorted {
		strings.write_string(&b, k)
		strings.write_byte(&b, '\n')
	}
	_, why := replace_file(fmt.tprintf("%s/%s", dir, name), strings.to_string(b), nil)
	return why
}

KNOWN :: "known"
REMOVED :: "removed"
KNOWN_COMMENT :: "ravnix-dict: the words of the dictionary at the end of the last sync on this host, in lower case"
REMOVED_COMMENT :: "ravnix-dict: the words removed from the dictionary, in lower case; sync takes them from every tool, until the word is in the dictionary again"

same_keys :: proc(a, b: Keys) -> bool {
	if len(a) != len(b) {
		return false
	}
	for k in a {
		if k not_in b {
			return false
		}
	}
	return true
}
