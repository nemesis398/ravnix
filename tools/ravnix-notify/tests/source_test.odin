// The tool writes no file: the token comes from rbw into memory and goes to
// curl on a pipe, and nothing else it holds needs a disk. A test of a run can
// look only in the directory it is given; a file in $TMPDIR, or anywhere, would
// escape it. So this one reads the sources, and fails on a call that creates,
// opens for writing, renames or removes a file or a directory. It guards a
// design decision, and it is meant to be argued with: a tool that needs a file
// later changes this list in the same commit and says why.
package ravnix_notify_tests

import "core:os"
import "core:strings"
import "core:testing"

SOURCE_DIR :: #directory + ".."

// The names of the calls that make a file or change one.
FILE_WRITERS := [?]string {
	"write_entire_file",
	"os.create",
	"os.open",
	"os.write_file",
	"os.make_directory",
	"os.remove",
	"os.rename",
	"os.link",
	"os.symlink",
	"os.truncate",
	"os.copy_file",
	"os.chmod",
	"create_temp",
	"make_directory_temp",
	"linux.open",
	"linux.creat",
	"linux.mkdir",
	"linux.unlink",
	"linux.rename",
	"linux.truncate",
	"posix.open",
	"posix.creat",
	"posix.mkdir",
	"posix.unlink",
	"posix.rename",
}

@(test)
the_tool_creates_no_file :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path(SOURCE_DIR, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expect_value(t, err, nil)

	seen := 0
	for e in entries {
		if e.type != .Regular || !strings.has_suffix(e.name, ".odin") {
			continue
		}
		seen += 1
		path := strings.concatenate({SOURCE_DIR, "/", e.name})
		defer delete(path)
		data, rerr := os.read_entire_file(path, context.allocator)
		defer delete(data)
		testing.expect_value(t, rerr, nil)
		for name in FILE_WRITERS {
			testing.expectf(t, !strings.contains(string(data), name), "%s calls %s", e.name, name)
		}
	}
	// A wrong directory would pass for nothing.
	testing.expectf(t, seen >= 8, "only %d source files were found in %s", seen, SOURCE_DIR)
}
