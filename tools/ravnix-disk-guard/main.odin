// The command: ravnix-disk-guard --model M --serial S [--print-device].
// README.md has the exit codes and how the install uses them.
package ravnix_disk_guard

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// The lsblk the guard runs. default.nix sets it to util-linux's store path;
// a bare name is looked up on PATH.
LSBLK :: #config(LSBLK, "lsblk")

// Where udev keeps the links by model and serial.
DEFAULT_BY_ID :: "/dev/disk/by-id"

// The longest model or serial the guard takes. NVMe gives 40 bytes for a
// model and 20 for a serial.
MAX_ARG_LEN :: 256

USAGE :: `usage: ravnix-disk-guard --model MODEL --serial SERIAL [--print-device]
                         [--lsblk-json FILE] [--by-id DIR]

Finds the one whole disk whose model and serial are MODEL and SERIAL, exactly
as lsblk prints them, and checks that nothing on it is mounted and no mapping
holds it (an open LUKS volume, LVM, RAID, swap). On success it prints the
disk's /dev/disk/by-id path, which names the disk by model and serial, never
a kernel name such as nvme0n1. It writes nothing, anywhere.

  --print-device     print only the path on standard output, for
                     dev=$(ravnix-disk-guard ...); the verdict goes to
                     standard error
  --lsblk-json FILE  read the output of lsblk -J -o ` + LSBLK_COLUMNS + `
                     from FILE instead of running lsblk
  --by-id DIR        where the links are (default: ` + DEFAULT_BY_ID + `)

The last two are for tests: each says on standard error that it is used.

Exit status: 0 the disk is found and free, and its path printed; 1 no single
disk matches, or the device list or the links cannot be read or disagree;
2 the disk is mounted or held; 3 bad usage. Only exit 0 prints a path.`

// run is the whole command, for the arguments after the program's name, with
// lsblk the lsblk it runs. It prints to stdout and stderr (the process's own
// when nil) and returns the exit status.
run :: proc(args: []string, lsblk := LSBLK, stdout: ^os.File = nil, stderr: ^os.File = nil) -> int {
	out := stdout if stdout != nil else os.stdout
	errf := stderr if stderr != nil else os.stderr

	// Everything the run allocates goes into one arena, freed at its end.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.fprintln(errf, "ravnix-disk-guard: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	model, serial, lsblk_json, by_id := "", "", "", DEFAULT_BY_ID
	has_model, has_serial, has_json, has_by_id, print_device := false, false, false, false, false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			fmt.fprintln(out, USAGE)
			return 0
		case "--print-device":
			if print_device {
				return usage_error(errf, "--print-device given twice")
			}
			print_device = true
		case "--model", "--serial", "--lsblk-json", "--by-id":
			if i + 1 >= len(args) {
				return usage_error(errf, "%s needs a value", arg)
			}
			i += 1
			value := args[i]
			seen: ^bool
			switch arg {
			case "--model":
				model, seen = value, &has_model
			case "--serial":
				serial, seen = value, &has_serial
			case "--lsblk-json":
				lsblk_json, seen = value, &has_json
			case "--by-id":
				by_id, seen = value, &has_by_id
			}
			if seen^ {
				return usage_error(errf, "%s given twice", arg)
			}
			seen^ = true
			if value == "" {
				return usage_error(errf, "%s is empty", arg)
			}
		case:
			if strings.has_prefix(arg, "-") {
				return usage_error(errf, "unknown option %s", arg)
			}
			return usage_error(errf, "unexpected argument %q: the guard picks a disk by --model and --serial, never by a name", arg)
		}
	}
	if !has_model || !has_serial {
		return usage_error(errf, "give --model and --serial")
	}
	if why := check_value(model); why != "" {
		return usage_error(errf, "--model %s", why)
	}
	if why := check_value(serial); why != "" {
		return usage_error(errf, "--serial %s", why)
	}

	// A test seam decides on what a file says instead of on the live system,
	// so it says so first, one line each, before anything is read: whoever
	// passes one by mistake sees it at the top. The name is quoted, so the
	// line stays one line. --by-id naming /dev/disk/by-id itself reads the
	// live links, and says nothing.
	if has_json {
		fmt.fprintfln(errf, "ravnix-disk-guard: --lsblk-json: the disks are read from %q, not from lsblk on the live system", lsblk_json)
	}
	if has_by_id && strings.trim_right(by_id, "/") != DEFAULT_BY_ID {
		fmt.fprintfln(errf, "ravnix-disk-guard: --by-id: the links are read from %q, not from /dev/disk/by-id on the live system", by_id)
	}

	data: []u8
	if has_json {
		err: os.Error
		data, err = os.read_entire_file(lsblk_json, context.allocator)
		if err != nil {
			fmt.fprintfln(errf, "ravnix-disk-guard: cannot read %s: %s", lsblk_json, os.error_string(err))
			return 1
		}
	} else {
		why: string
		data, why = run_lsblk(lsblk)
		if why != "" {
			fmt.fprintfln(errf, "ravnix-disk-guard: %s", why)
			return 1
		}
	}

	o := decide(data, model, serial, by_id)
	switch {
	case o.code != 0:
		fmt.fprintfln(errf, "ravnix-disk-guard: %s", o.message)
	case print_device:
		fmt.fprintln(out, o.path)
		fmt.fprintfln(errf, "ravnix-disk-guard: %s", o.message)
	case:
		fmt.fprintfln(out, "ravnix-disk-guard: %s", o.message)
	}
	return o.code
}

// check_value says what is wrong with a model or serial, or "" when nothing
// is. lsblk prints them without surrounding white space and control
// characters, so a value with either matches no disk and is a typo.
check_value :: proc(value: string) -> string {
	if len(value) > MAX_ARG_LEN {
		return "is longer than 256 bytes, which no disk's is"
	}
	if strings.trim_space(value) != value {
		return "starts or ends with white space, which lsblk never prints"
	}
	for c in transmute([]u8)value {
		if c < ' ' || c == 0x7f {
			return "holds a control character"
		}
	}
	return ""
}

usage_error :: proc(errf: ^os.File, format: string, args: ..any) -> int {
	fmt.fprint(errf, "ravnix-disk-guard: ")
	fmt.fprintfln(errf, format, ..args)
	fmt.fprintln(errf, "run ravnix-disk-guard --help for the usage")
	return 3
}

// run_lsblk runs lsblk -J -o LSBLK_COLUMNS with nothing in its environment
// but LC_ALL=C, so no variable of the caller's (LIBMOUNT_MTAB, say) can
// change what it reports, and returns what it printed. why says what went
// wrong, "" when nothing did.
run_lsblk :: proc(lsblk: string) -> (data: []u8, why: string) {
	state, out, errout, err := os.process_exec(
		{command = {lsblk, "-J", "-o", LSBLK_COLUMNS}, env = {"LC_ALL=C"}},
		context.allocator,
	)
	if err != nil {
		return nil, fmt.aprintf("cannot run %s: %s", lsblk, os.error_string(err))
	}
	if !state.exited || !state.success || state.exit_code != 0 {
		detail := first_line(string(errout))
		if detail == "" {
			detail = "it said nothing"
		}
		return nil, fmt.aprintf("lsblk failed (exit %d): %s", state.exit_code, detail)
	}
	return out, ""
}

first_line :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = strings.trim_space(t[:i])
	}
	return t
}

main :: proc() {
	os.exit(run(os.args[1:]))
}
