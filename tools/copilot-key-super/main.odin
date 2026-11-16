// copilot-key-super: the IdeaPad's Copilot key as a plain second Super.
// README.md has what the key sends and why this is a grab and not a remap.
package copilot_key_super

import "core:fmt"
import "core:io"
import "core:os"
import "core:sys/linux"

USAGE :: `usage: copilot-key-super [--root DIR] | --filter

Grabs the keyboard named "AT Translated Set 2 keyboard" and re-emits its
events through the virtual keyboard copilot-key-super (vendor 1, product 1),
with the Copilot key's Super+Shift+F23 turned into a plain Super. It runs
until the keyboard goes away or something fails, and then exits 1; the
kernel gives the keyboard back the moment it ends.

  --root DIR  find the keyboard and open /dev under DIR
  --filter    translate input_event records from standard input to
              standard output, and touch no device
  -h, --help  print this

Exit status: 0 the filter's input ended; 1 a failure; 2 bad usage.`

// run is the whole command, for the arguments after the program's name.
run :: proc(args: []string, out, err: io.Writer) -> int {
	root := ""
	filter_mode := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-h", "--help":
			fmt.wprintln(out, USAGE)
			return 0
		case "--filter":
			filter_mode = true
		case "--root":
			if i + 1 >= len(args) {
				fmt.wprintln(err, "copilot-key-super: --root needs a directory")
				return 2
			}
			i += 1
			root = args[i]
			if root == "" {
				fmt.wprintln(err, "copilot-key-super: --root needs a directory")
				return 2
			}
		case:
			fmt.wprintfln(err, "copilot-key-super: unknown argument %q", args[i])
			fmt.wprintln(err, USAGE)
			return 2
		}
	}
	if filter_mode {
		if root != "" {
			fmt.wprintln(err, "copilot-key-super: --filter touches no device, so it takes no --root")
			fmt.wprintln(err, USAGE)
			return 2
		}
		return filter(0, 1, err)
	}
	return daemon(root, err)
}

// filter is --filter: the translation from one descriptor to another, with
// no device. A SYN_DROPPED in the input resyncs to no key held.
filter :: proc(input, output: linux.Fd, err: io.Writer) -> int {
	t: Translator
	result := pump(&t, input, output, read_fd, write_fd, proc(fd: linux.Fd, held: ^Key_Bits) -> linux.Errno {
		held^ = {}
		return .NONE
	})
	if result.stop == .Ended && result.torn == 0 {
		return 0
	}
	switch result.stop {
	case .Ended:
		fmt.wprintfln(err, "copilot-key-super: the input ends %d bytes into an event", result.torn)
	case .Write_Failed:
		fmt.wprintfln(err, "copilot-key-super: cannot write the output: %v", result.errno)
	case .Gone, .Read_Failed, .Resync_Failed:
		fmt.wprintfln(err, "copilot-key-super: cannot read the input: %v", result.errno)
	}
	return 1
}

main :: proc() {
	os.exit(run(os.args[1:], os.to_writer(os.stdout), os.to_writer(os.stderr)))
}
