// The command: claude-code-verify [options] BINARY VERSION. README.md has
// the exit codes and what each one means for the gate and the update timer.
package claude_code_verify

import "core:fmt"
import "core:os"
import "core:strings"

USAGE :: `usage: claude-code-verify [--platform P] [--releases URL | --manifest FILE] BINARY VERSION

Checks that BINARY is Claude Code VERSION as Anthropic released it: its size
and sha256 against the release manifest URL/VERSION/manifest.json.

  --platform P     the manifest's platform entry (default: ` + DEFAULT_PLATFORM + `)
  --releases URL   where the releases are (default: ` + DEFAULT_RELEASES + `)
  --manifest FILE  read the manifest from FILE instead of fetching it

Exit status: 0 verified; 1 not verified (the binary differs, or no manifest
of that version describes it); 2 bad usage or an unreadable file; 3 the
manifest is unreachable.`

// run is the whole command, for the arguments after the program's name. It
// returns the exit status; curl is the curl it fetches with.
run :: proc(args: []string, curl := CURL) -> int {
	platform := DEFAULT_PLATFORM
	releases := DEFAULT_RELEASES
	manifest_file := ""
	has_releases := false
	positional: [dynamic]string
	defer delete(positional)

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "-h", "--help":
			fmt.println(USAGE)
			return 0
		case "--platform", "--releases", "--manifest":
			if i + 1 >= len(args) {
				return usage_error("%s needs a value", arg)
			}
			i += 1
			switch arg {
			case "--platform":
				platform = args[i]
			case "--releases":
				releases, has_releases = args[i], true
			case "--manifest":
				manifest_file = args[i]
			}
		case:
			if strings.has_prefix(arg, "-") {
				return usage_error("unknown option %s", arg)
			}
			append(&positional, arg)
		}
	}
	if len(positional) != 2 {
		return usage_error("give BINARY and VERSION")
	}
	binary, version := positional[0], positional[1]
	if platform == "" {
		return usage_error("no platform: this build knows none, so give --platform")
	}
	if !valid_version(version) {
		return usage_error("%q is not a version", version)
	}
	if has_releases && manifest_file != "" {
		return usage_error("give --releases or --manifest, not both")
	}
	if !valid_base_url(releases) {
		return usage_error("%q is not an http or https URL", releases)
	}

	source: string
	manifest: []u8
	fetched: Fetched
	defer fetched_destroy(fetched)
	file_data: []u8
	defer delete(file_data)
	url: string
	defer delete(url)

	if manifest_file != "" {
		err: os.Error
		file_data, err = os.read_entire_file(manifest_file, context.allocator)
		if err != nil {
			fmt.eprintfln("claude-code-verify: cannot read the manifest %s: %s", manifest_file, os.error_string(err))
			return 2
		}
		source, manifest = manifest_file, file_data
	} else {
		url = manifest_url(releases, version)
		fetched = fetch(curl, url)
		if fetched.status != .Ok {
			line := describe_fetch(fetched, url)
			defer delete(line)
			fmt.eprintfln("claude-code-verify: %s", line)
			return fetch_exit_code(fetched.status)
		}
		source, manifest = url, fetched.body
	}

	result := verify(binary, manifest, platform, version)
	line := message(result, binary, version, platform, source)
	defer delete(line)
	if result.status == .Ok {
		fmt.printfln("claude-code-verify: %s", line)
	} else {
		fmt.eprintfln("claude-code-verify: %s", line)
	}
	return exit_code(result.status)
}

usage_error :: proc(format: string, args: ..any) -> int {
	fmt.eprint("claude-code-verify: ")
	fmt.eprintfln(format, ..args)
	fmt.eprintln("run claude-code-verify --help for the usage")
	return 2
}

main :: proc() {
	os.exit(run(os.args[1:]))
}
