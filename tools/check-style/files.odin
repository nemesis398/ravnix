package check_style

import "core:strings"
import "core:sys/linux"

// Which files are judged, and the walk of a directory.
//
// A file is judged by its path from the root of the judged tree, which is the
// current directory: a relative path, or an absolute one below the current
// directory, is placed by its path from there, so scripts/check.sh hands it
// repository-relative paths and the rules mean the same wherever the
// repository is checked out. A directory that is not below the current
// directory is the root of its own tree; a file that is not below it is
// placed by its path as given, so no exemption applies to it.

has_suffix_fold :: proc(name, suffix: string) -> bool {
	return len(name) >= len(suffix) && strings.equal_fold(name[len(name) - len(suffix):], suffix)
}

// Whether a directory component of rel is one of the names.
has_component :: proc(rel: string, a, b: string) -> bool {
	slash := strings.last_index_byte(rel, '/')
	if slash < 0 {
		return false
	}
	rest := rel[:slash]
	for part in strings.split_iterator(&rest, "/") {
		if part == a || part == b {
			return true
		}
	}
	return false
}

// The files to judge, in the order they were found, and the paths shown for
// them, so that a file found twice is judged once without a scan of the list.
File_Set :: struct {
	list: [dynamic]File,
	seen: map[string]struct{},
}

// classify judges the file whose path from the root of the judged tree is
// rel and which is displayed as shown, and files it under its kind. The
// exemptions name places, not directory names: a themes/ or tests/ directory
// further down is judged like any other.
classify :: proc(rel_in, shown: string, files: ^File_Set) {
	rel := rel_in
	for strings.has_prefix(rel, "./") {
		rel = rel[2:]
	}
	name := rel[strings.last_index_byte(rel, '/') + 1:]
	if has_component(rel, ".git", "node_modules") {
		return
	}
	if strings.has_prefix(rel, ".worktrees/") || strings.has_prefix(rel, ".superpowers/") || strings.has_prefix(rel, "tests/") || strings.has_prefix(rel, "scripts/tests/") {
		return
	}
	if is_tool_tests_path(rel) {
		return
	}
	for ext in ([?]string{".svg", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".webp", ".ttf", ".otf", ".woff", ".woff2", ".lock"}) {
		if has_suffix_fold(name, ext) {
			return
		}
	}
	kind: Kind
	switch {
	case has_suffix_fold(name, ".md") || has_suffix_fold(name, ".markdown") || has_suffix_fold(name, ".mmd") || has_suffix_fold(name, ".mermaid"):
		kind = .Docs
	case has_suffix_fold(name, ".css") || has_suffix_fold(name, ".scss") || has_suffix_fold(name, ".tcss") || has_suffix_fold(name, ".rasi"):
		kind = .Css
	case has_suffix_fold(name, ".nix"):
		kind = .Nix
	case has_suffix_fold(name, ".ini") || has_suffix_fold(name, ".conf") || has_suffix_fold(name, ".toml") || has_suffix_fold(name, ".jsonc") || has_suffix_fold(name, ".kdl") || has_suffix_fold(name, ".colors"):
		kind = .Code
	case:
		// Sway's config has no extension: every other file below a modules/ or
		// hosts/ directory is judged.
		if !(strings.has_prefix(rel, "modules/") || strings.has_prefix(rel, "hosts/") || strings.contains(rel, "/modules/") || strings.contains(rel, "/hosts/")) {
			return
		}
		kind = .Code
	}
	if kind == .Code && has_suffix_fold(name, ".lua") {
		kind = .Lua
	}
	if shown in files.seen {
		return
	}
	files.seen[shown] = {}
	append(&files.list, File{shown = shown, rel = strings.clone(rel), kind = kind})
}

// tools/NAME/tests/..., where fixtures fail on purpose.
is_tool_tests_path :: proc(rel: string) -> bool {
	if !strings.has_prefix(rel, "tools/") {
		return false
	}
	rest := rel[len("tools/"):]
	slash := strings.index_byte(rest, '/')
	return slash > 0 && strings.has_prefix(rest[slash + 1:], "tests/")
}

// An absolute path of a path as the user gave it, for the file system.
absolute :: proc(cwd, path: string) -> string {
	if strings.has_prefix(path, "/") {
		return path
	}
	if path == "." {
		return cwd
	}
	return strings.concatenate({cwd, "/", path})
}

// lstat of path: the mode, and whether it exists.
lstat_mode :: proc(path: string) -> (mode: linux.Mode, errno: linux.Errno) {
	st: linux.Stat
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	errno = linux.lstat(cpath, &st)
	return st.mode, errno
}

stat_mode :: proc(path: string) -> (mode: linux.Mode, errno: linux.Errno) {
	st: linux.Stat
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	errno = linux.stat(cpath, &st)
	return st.mode, errno
}

// The state of a walk.
Walk :: struct {
	cwd:    string,
	files:  ^File_Set,
	// The directory as the user gave it (trailing slashes cut), what a hit
	// shows in front of the path below it, and the part of the root of the
	// judged tree that comes before it.
	dir:    string,
	prefix: string,
	// Whether the tree root's own tool state (.worktrees, .superpowers) is
	// pruned: only where the directory is the root of the judged tree.
	prune_state: bool,
	error:  string,
}

// walk_dir classifies the files below dir. Symbolic links are never
// followed, a directory named .git or node_modules is not entered, and a
// directory that cannot be read ends the walk with an error.
walk_dir :: proc(cwd: string, dir_in: string, files: ^File_Set) -> (error: string) {
	dir := dir_in
	for strings.has_suffix(dir, "/") && dir != "/" {
		dir = dir[:len(dir) - 1]
	}
	prefix := ""
	switch {
	case dir == "." || dir == cwd:
	case strings.has_prefix(dir, "/") || dir == ".." || strings.has_prefix(dir, "../"):
		if strings.has_prefix(dir, strings.concatenate({cwd, "/"}, context.temp_allocator)) {
			prefix = strings.concatenate({dir[len(cwd) + 1:], "/"})
		}
	case:
		trimmed := dir[2:] if strings.has_prefix(dir, "./") else dir
		prefix = strings.concatenate({trimmed, "/"})
	}
	base := dir[strings.last_index_byte(dir, '/') + 1:]
	if base == ".git" || base == "node_modules" {
		return ""
	}
	abs_dir := absolute(cwd, dir)
	mode, lerr := lstat_mode(abs_dir)
	if lerr != .NONE {
		return strings.concatenate({"could not walk ", dir})
	}
	if linux.S_ISLNK(mode) {
		return ""
	}
	w := Walk {
		cwd         = cwd,
		files       = files,
		dir         = dir,
		prefix      = prefix,
		prune_state = prefix == "",
	}
	walk_level(&w, abs_dir, "")
	return w.error
}

// entry_kind is the kind of the directory entry at path: what the directory
// said, or, where a file system does not say (DT_UNKNOWN), what lstat finds.
// An entry that lstat cannot look at is an error.
entry_kind :: proc(path: string, said: linux.Dirent_Type) -> (kind: linux.Dirent_Type, errno: linux.Errno) {
	if said != .UNKNOWN {
		return said, .NONE
	}
	mode: linux.Mode
	mode, errno = lstat_mode(path)
	if errno != .NONE {
		return .UNKNOWN, errno
	}
	switch {
	case linux.S_ISDIR(mode):
		return .DIR, .NONE
	case linux.S_ISREG(mode):
		return .REG, .NONE
	}
	return .UNKNOWN, .NONE
}

walk_level :: proc(w: ^Walk, abs_dir, below: string) {
	fd, errno := linux.open(strings.clone_to_cstring(abs_dir, context.temp_allocator), {.DIRECTORY, .CLOEXEC, .NOFOLLOW})
	if errno != .NONE {
		w.error = strings.concatenate({"could not walk ", w.dir})
		return
	}
	defer linux.close(fd)
	buf := make([]u8, 32768)
	defer delete(buf)
	names: [dynamic]string
	kinds: [dynamic]linux.Dirent_Type
	defer delete(names)
	defer delete(kinds)
	for {
		n, derr := linux.getdents(fd, buf)
		if derr != .NONE {
			w.error = strings.concatenate({"could not walk ", w.dir})
			return
		}
		if n == 0 {
			break
		}
		offset := 0
		for d in linux.dirent_iterate_buf(buf[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {
				continue
			}
			append(&names, strings.clone(name))
			append(&kinds, d.type)
		}
	}
	for name, i in names {
		if name == ".git" || name == "node_modules" {
			continue
		}
		below_name := name if below == "" else strings.concatenate({below, "/", name})
		if w.prune_state && below == "" && (name == ".worktrees" || name == ".superpowers") {
			continue
		}
		path := strings.concatenate({abs_dir, "/", name}, context.temp_allocator)
		kind, kerr := entry_kind(path, kinds[i])
		if kerr != .NONE {
			// find fails the run on an entry it cannot look at.
			w.error = strings.concatenate({"could not walk ", w.dir})
			return
		}
		#partial switch kind {
		case .DIR:
			walk_level(w, path, below_name)
			if w.error != "" {
				return
			}
		case .REG:
			shown: string
			switch {
			case w.dir == ".":
				shown = below_name
			case:
				shown = strings.concatenate({w.dir, "/", below_name})
			}
			classify(strings.concatenate({w.prefix, below_name}, context.temp_allocator), shown, w.files)
		}
	}
}
