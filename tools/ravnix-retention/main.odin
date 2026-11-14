// The command: ravnix-retention flags --target TARGET --host HOST [--file FILE].
// README.md has the exit codes and how the prune jobs use it.
package ravnix_retention

import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// The variable that names the retention file when --file is not given.
FILE_VARIABLE :: "RAVNIX_RETENTION_FILE"

USAGE :: `usage: ravnix-retention flags --target TARGET --host HOST [--file FILE]

Reads the retention file (backups.toml) and prints, on one line, the flags of
restic forget that keep what the file says HOST keeps at TARGET:

  restic forget --prune $(ravnix-retention flags --target nas --host huginn)

The flags always name the host (--host HOST --group-by host), so a prune
never reaches another host's snapshots. A count of 0 is left out. A file
with any mistake in it, anywhere, gives no flags at all.

  --target TARGET  nas or internxt
  --host HOST      the host name the snapshots carry
  --file FILE      the retention file (default: $` + FILE_VARIABLE + `)

Exit status: 0 the flags are printed; 1 the file cannot be read or is
wrong; 2 bad usage. Only exit 0 prints anything on standard output.`

// run is the whole command, for the arguments after the program's name.
// default_file is the file to read without --file ($RAVNIX_RETENTION_FILE,
// or "" when it is not set). It prints to stdout and stderr (the process's
// own when nil) and returns the exit status.
run :: proc(args: []string, default_file: string, stdout: ^os.File = nil, stderr: ^os.File = nil) -> int {
	out := stdout if stdout != nil else os.stdout
	errf := stderr if stderr != nil else os.stderr

	// Everything the run allocates goes into one arena, freed at its end.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.fprintln(errf, "ravnix-retention: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	if len(args) == 0 {
		return usage_error(errf, "give a command: flags")
	}
	switch args[0] {
	case "-h", "--help":
		fmt.fprintln(out, USAGE)
		return 0
	case "flags":
	case:
		return usage_error(errf, "unknown command %s", args[0])
	}

	target, host, file := "", "", ""
	has_target, has_host, has_file := false, false, false
	rest := args[1:]
	for i := 0; i < len(rest); i += 1 {
		arg := rest[i]
		switch arg {
		case "-h", "--help":
			fmt.fprintln(out, USAGE)
			return 0
		case "--target", "--host", "--file":
			if i + 1 >= len(rest) {
				return usage_error(errf, "%s needs a value", arg)
			}
			i += 1
			seen: ^bool
			switch arg {
			case "--target":
				target, seen = rest[i], &has_target
			case "--host":
				host, seen = rest[i], &has_host
			case "--file":
				file, seen = rest[i], &has_file
			}
			if seen^ {
				return usage_error(errf, "%s given twice", arg)
			}
			seen^ = true
		case:
			if strings.has_prefix(arg, "-") {
				return usage_error(errf, "unknown option %s", arg)
			}
			return usage_error(errf, "unexpected argument %q", arg)
		}
	}
	if !has_target || !has_host {
		return usage_error(errf, "give --target and --host")
	}
	which, known := target_named(target)
	if !known {
		return usage_error(errf, "unknown target %s; the targets are nas and internxt", target if target != "" else `""`)
	}
	if why := check_host(host); why != "" {
		return usage_error(errf, "--host %q %s", host, why)
	}
	if has_file && file == "" {
		return usage_error(errf, "--file is empty")
	}
	if !has_file {
		file = default_file
	}
	if file == "" {
		return usage_error(errf, "no retention file: give --file FILE, or set %s", FILE_VARIABLE)
	}

	data, why := read_bounded(file)
	if why != "" {
		fmt.fprintfln(errf, "ravnix-retention: %s", why)
		return 1
	}
	r, rwhy := read_retention(string(data))
	if rwhy != "" {
		fmt.fprintfln(errf, "ravnix-retention: %s: %s", file, rwhy)
		return 1
	}
	fmt.fprintln(out, flags(&r, which, host))
	return 0
}

// read_bounded reads the file at path, up to MAX_FILE_BYTES: a larger one,
// or one that never ends (a device), is refused once the limit is passed.
read_bounded :: proc(path: string) -> (data: []u8, why: string) {
	f, err := os.open(path)
	if err != nil {
		return nil, fmt.aprintf("cannot read %s: %s", path, os.error_string(err))
	}
	defer os.close(f)
	buf := make([]u8, MAX_FILE_BYTES + 1)
	n := 0
	for n < len(buf) {
		got, rerr := os.read(f, buf[n:])
		n += got
		if rerr == io.Error.EOF || (rerr == nil && got == 0) {
			break
		}
		if rerr != nil {
			return nil, fmt.aprintf("cannot read %s: %s", path, os.error_string(rerr))
		}
	}
	if n > MAX_FILE_BYTES {
		return nil, fmt.aprintf("%s is larger than %d KiB, which no retention file is", path, MAX_FILE_BYTES / 1024)
	}
	return buf[:n], ""
}

usage_error :: proc(errf: ^os.File, format: string, args: ..any) -> int {
	fmt.fprint(errf, "ravnix-retention: ")
	fmt.fprintfln(errf, format, ..args)
	fmt.fprintln(errf, "run ravnix-retention --help for the usage")
	return 2
}

main :: proc() {
	os.exit(run(os.args[1:], os.get_env(FILE_VARIABLE, context.allocator)))
}
