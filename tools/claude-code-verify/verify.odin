// claude-code-verify proves that a Claude Code binary is the one Anthropic
// released: its sha256 and its size against the release manifest that
// downloads.claude.ai publishes beside every version (README.md). This file
// holds the check itself, which reads nothing but the binary and the
// manifest's bytes; fetch.odin gets the manifest, main.odin is the command.
package claude_code_verify

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

// The manifest's name for the platform this build runs on, and the one it
// verifies unless --platform names another.
when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	DEFAULT_PLATFORM :: "linux-x64"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	DEFAULT_PLATFORM :: "linux-arm64"
} else {
	DEFAULT_PLATFORM :: ""
}

// The longest version a manifest may name. Real ones are like 2.1.319.
MAX_VERSION_LEN :: 64

// How deep a manifest may nest its arrays and objects. A real one nests
// three deep; the JSON parser recurses once per level, so a manifest of a
// million brackets would otherwise overflow the stack.
MAX_DEPTH :: 16

Verify_Status :: enum {
	Ok,
	// The binary hashes to another sha256 than the manifest gives.
	Checksum_Mismatch,
	// The binary has another size than the manifest gives. An empty file is
	// one of these.
	Size_Mismatch,
	// The manifest is for another version than the one asked for.
	Wrong_Version,
	// The manifest has no entry for the platform.
	No_Platform,
	// The manifest is not JSON, or not of the shape of one; why says how.
	Bad_Manifest,
	// The binary cannot be opened or read, or is no regular file.
	Unreadable_Binary,
}

// What the manifest says about one platform, held in fixed arrays so that
// a result needs no allocation and outlives the manifest's bytes.
Manifest_Entry :: struct {
	version:     [MAX_VERSION_LEN]u8,
	version_len: int,
	checksum:    [32]u8,
	// -1 when the manifest gives no size.
	size:        i64,
}

Verify_Result :: struct {
	status:      Verify_Status,
	// Why the manifest is bad, or why the binary is unreadable when no
	// os_error says it: a constant string, never allocated.
	why:         string,
	entry:       Manifest_Entry,
	actual:      [32]u8,
	actual_size: i64,
	os_error:    os.Error,
}

// verify checks the binary at binary_path against the entry for platform in
// manifest, and, when version is not empty, that the manifest is for that
// version. The size is compared before the hash, so a binary of the wrong
// size is not read. It allocates nothing from context.allocator and touches
// nothing shared, so concurrent calls are safe.
verify :: proc(binary_path: string, manifest: []u8, platform: string, version := "") -> (r: Verify_Result) {
	r.status, r.why = parse_manifest(manifest, platform, &r.entry)
	if r.status != .Ok {
		return
	}
	if version != "" && entry_version(&r.entry) != version {
		r.status = .Wrong_Version
		return
	}

	f, err := os.open(binary_path)
	if err != nil {
		r.status, r.os_error = .Unreadable_Binary, err
		return
	}
	defer os.close(f)
	{
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		info, serr := os.fstat(f, context.temp_allocator)
		if serr != nil {
			r.status, r.os_error = .Unreadable_Binary, serr
			return
		}
		if info.type != .Regular {
			r.status, r.why = .Unreadable_Binary, "it is not a regular file"
			return
		}
		r.actual_size = info.size
	}
	if r.entry.size >= 0 && r.actual_size != r.entry.size {
		r.status = .Size_Mismatch
		return
	}

	hashed: i64
	r.actual, hashed, err = hash_file(f)
	if err != nil {
		r.status, r.os_error = .Unreadable_Binary, err
		return
	}
	// The file changed between the stat and the read.
	if hashed != r.actual_size {
		r.actual_size = hashed
		if r.entry.size >= 0 && hashed != r.entry.size {
			r.status = .Size_Mismatch
			return
		}
	}
	if r.actual != r.entry.checksum {
		r.status = .Checksum_Mismatch
	}
	return
}

// hash_file reads f from where it stands to its end and returns its sha256
// and how many bytes it read.
hash_file :: proc(f: ^os.File) -> (digest: [32]u8, n: i64, err: os.Error) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf: [64 * 1024]u8 = ---
	for {
		got, rerr := os.read(f, buf[:])
		if got > 0 {
			sha2.update(&ctx, buf[:got])
			n += i64(got)
		}
		if rerr == .EOF || (rerr == nil && got == 0) {
			break
		}
		if rerr != nil {
			return {}, n, rerr
		}
	}
	sha2.final(&ctx, digest[:])
	return
}

// parse_manifest reads the entry for platform from manifest into entry. Its
// status is Ok, No_Platform or Bad_Manifest, and why says what is wrong
// with a bad one. Everything the parser allocates goes into an arena of its
// own, freed before it returns.
parse_manifest :: proc(manifest: []u8, platform: string, entry: ^Manifest_Entry) -> (status: Verify_Status, why: string) {
	entry^ = {size = -1}
	if !nesting_within(manifest, MAX_DEPTH) {
		return .Bad_Manifest, "it nests deeper than any manifest"
	}
	for b in manifest {
		if b == 0 {
			// The JSON tokenizer would take a NUL for the end of the input
			// and ignore whatever follows it.
			return .Bad_Manifest, "it holds a NUL byte"
		}
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return .Bad_Manifest, "there is no memory to parse it"
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Numbers are read as f64: with parse_integers, core:encoding/json
	// turns an integer beyond i64 into another integer without an error.
	p := json.make_parser(manifest, .JSON, false, context.allocator)
	root, err := json.parse_value(&p)
	if err != .None {
		return .Bad_Manifest, "it is not JSON"
	}
	if p.curr_token.kind != .EOF {
		return .Bad_Manifest, "it holds more than one JSON value"
	}
	obj, is_object := root.(json.Object)
	if !is_object {
		return .Bad_Manifest, "it is no JSON object"
	}
	version, has_version := obj["version"].(json.String)
	if !has_version {
		return .Bad_Manifest, "it has no version string"
	}
	if len(version) == 0 || len(version) > MAX_VERSION_LEN {
		return .Bad_Manifest, "its version is empty or longer than 64 bytes"
	}
	copy(entry.version[:], version)
	entry.version_len = len(version)

	platforms, has_platforms := obj["platforms"].(json.Object)
	if !has_platforms {
		return .Bad_Manifest, "it has no platforms object"
	}
	value, listed := platforms[platform]
	if !listed {
		return .No_Platform, ""
	}
	plat, plat_is_object := value.(json.Object)
	if !plat_is_object {
		return .Bad_Manifest, "its entry for the platform is no object"
	}
	checksum, has_checksum := plat["checksum"].(json.String)
	if !has_checksum || !decode_hex(checksum, &entry.checksum) {
		return .Bad_Manifest, "its checksum for the platform is not 64 hex digits"
	}
	if size_value, has_size := plat["size"]; has_size {
		// A whole number below 2^53: up to there f64 holds every one exactly,
		// and a larger one may have been rounded to its neighbor.
		size, is_number := size_value.(json.Float)
		if !is_number || size < 1 || size >= 1 << 53 || size != f64(i64(size)) {
			return .Bad_Manifest, "its size for the platform is not a positive whole number"
		}
		entry.size = i64(size)
	}
	return .Ok, ""
}

// nesting_within reports whether the arrays and objects of the JSON text
// nest at most limit deep, counting brackets outside strings only.
nesting_within :: proc(text: []u8, limit: int) -> bool {
	depth := 0
	in_string, escaped := false, false
	for b in text {
		if in_string {
			switch {
			case escaped:
				escaped = false
			case b == '\\':
				escaped = true
			case b == '"':
				in_string = false
			}
			continue
		}
		switch b {
		case '"':
			in_string = true
		case '[', '{':
			depth += 1
			if depth > limit {
				return false
			}
		case ']', '}':
			depth -= 1
		}
	}
	return true
}

// decode_hex reads 64 hex digits, in either case, into out.
decode_hex :: proc(text: string, out: ^[32]u8) -> bool {
	if len(text) != 64 {
		return false
	}
	nibble :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9':
			return c - '0', true
		case 'a' ..= 'f':
			return c - 'a' + 10, true
		case 'A' ..= 'F':
			return c - 'A' + 10, true
		}
		return 0, false
	}
	for i in 0 ..< 32 {
		hi, ok_hi := nibble(text[2 * i])
		lo, ok_lo := nibble(text[2 * i + 1])
		if !ok_hi || !ok_lo {
			return false
		}
		out[i] = hi << 4 | lo
	}
	return true
}

// hex_digest writes a digest as 64 lowercase hex digits.
hex_digest :: proc(digest: [32]u8) -> (hex: [64]u8) {
	digits := "0123456789abcdef"
	for b, i in digest {
		hex[2 * i] = digits[b >> 4]
		hex[2 * i + 1] = digits[b & 0xf]
	}
	return
}

// entry_version is the version the manifest names, as a string into entry.
entry_version :: proc(entry: ^Manifest_Entry) -> string {
	return string(entry.version[:entry.version_len])
}

// exit_code is the command's exit status for a result: 0 when verified, 1
// when the binary is not the release the manifest describes or the manifest
// does not describe one, 2 when the binary cannot be read.
exit_code :: proc(s: Verify_Status) -> int {
	switch s {
	case .Ok:
		return 0
	case .Checksum_Mismatch, .Size_Mismatch, .Wrong_Version, .No_Platform, .Bad_Manifest:
		return 1
	case .Unreadable_Binary:
		return 2
	}
	return 1
}

// message is the one line the command prints for a result. source names
// where the manifest came from (its URL or file). The caller deletes it.
message :: proc(result: Verify_Result, binary, version, platform, source: string, allocator := context.allocator) -> string {
	r := result
	switch r.status {
	case .Ok:
		hex := hex_digest(r.actual)
		return fmt.aprintf(
			"%s is Claude Code %s for %s: its sha256 %s matches the release manifest",
			binary, version, platform, string(hex[:]), allocator = allocator,
		)
	case .Checksum_Mismatch:
		got, want := hex_digest(r.actual), hex_digest(r.entry.checksum)
		return fmt.aprintf(
			"%s is not Claude Code %s for %s: its sha256 is %s, the release manifest (%s) says %s",
			binary, version, platform, string(got[:]), source, string(want[:]), allocator = allocator,
		)
	case .Size_Mismatch:
		return fmt.aprintf(
			"%s is not Claude Code %s for %s: it is %d bytes, the release manifest (%s) says %d",
			binary, version, platform, r.actual_size, source, r.entry.size, allocator = allocator,
		)
	case .Wrong_Version:
		return fmt.aprintf(
			"the release manifest (%s) is for version %s, not %s",
			source, entry_version(&r.entry), version, allocator = allocator,
		)
	case .No_Platform:
		return fmt.aprintf(
			"the release manifest of %s (%s) has no entry for the platform %q",
			version, source, platform, allocator = allocator,
		)
	case .Bad_Manifest:
		return fmt.aprintf("%s is not a release manifest: %s", source, r.why, allocator = allocator)
	case .Unreadable_Binary:
		why := r.why if r.os_error == nil else os.error_string(r.os_error)
		return fmt.aprintf("cannot read %s: %s", binary, why, allocator = allocator)
	}
	return strings.clone("unknown result", allocator)
}
