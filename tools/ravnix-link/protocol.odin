// The wire format. A request is one JSON line,
//
//   {"id":"<uuid>","kind":"open|notify|obsidian|vault-commit","args":{...},"created":"<RFC 3339>"}
//
// the same in the queue on muninn and on the socket to huginn. The daemon
// answers each request with one reply line, {"id","status","error"}, and
// the client records each outcome in its acked file as one record line of
// the same shape. README.md has the arguments of each kind.
package ravnix_link

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

// The longest line, request or reply, its newline included. A request
// carries a URL, a path, a notification or a commit message, none of which
// comes near it; a body of 10 MB is refused, not truncated.
MAX_LINE :: 64 * 1024
// The most paths one vault-commit names, and the longest path.
MAX_PATHS :: 256
MAX_PATH_BYTES :: 4096
// The largest queue that takes another request: 16 MiB of requests waiting
// means the laptop has been away for a very long time, or something loops.
MAX_QUEUE_BYTES :: 16 * 1024 * 1024
// The socket, under $XDG_RUNTIME_DIR on both hosts (modules/glue/link.nix).
SOCKET_NAME :: "ravnix-link.sock"
// A notification older than this is dropped instead of shown: it says
// something that was true when the laptop was away.
NOTIFY_TTL :: 10 * time.Minute

// The schemes open forwards, in lowercase as written. Anything else is
// refused: obsidian: would hand the server Obsidian's URI actions on the
// laptop (obsidian://new with &overwrite, every plugin's handler, and with
// them code in the vault), file: adds nothing to an absolute path, and the
// others (javascript:, steam://, an editor's handler) are not links to
// open. A note opens by its absolute path, with the laptop's default for
// its type.
ALLOWED_SCHEMES :: [?]string{"http", "https", "mailto"}

Kind :: enum u8 {
	Open,
	Notify,
	Obsidian,
	Vault_Commit,
}

KIND_NAMES := [Kind]string {
	.Open         = "open",
	.Notify       = "notify",
	.Obsidian     = "obsidian",
	.Vault_Commit = "vault-commit",
}

Obsidian_Op :: enum u8 {
	None,
	Move,
	Rename,
	Delete,
}

OP_NAMES := [Obsidian_Op]string {
	.None   = "",
	.Move   = "move",
	.Rename = "rename",
	.Delete = "delete",
}

// One request. Which fields mean something depends on the kind:
//   open:         target (a URL or an absolute path)
//   notify:       summary, body, urgency ("" or low|normal|critical), app
//   obsidian:     op, path, to (move), name (rename)
//   vault-commit: vault (the repository), message, paths, and from the
//                 laptop sums: per path, the SHA-256 of its bytes in the
//                 laptop's copy of the vault, or NO_FILE where it has none
Request :: struct {
	id:      string,
	kind:    Kind,
	created: string,
	target:  string,
	summary: string,
	body:    string,
	urgency: string,
	app:     string,
	op:      Obsidian_Op,
	path:    string,
	to:      string,
	name:    string,
	vault:   string,
	message: string,
	paths:   []string,
	sums:    []string,
}

// The sum of a path the laptop's copy of the vault does not have: the
// commit takes its removal.
NO_FILE :: "-"

// is_sum says whether s is a SHA-256 as the laptop writes it: 64
// lowercase hex digits.
is_sum :: proc(s: string) -> bool {
	if len(s) != 64 {
		return false
	}
	for c in transmute([]u8)s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// How the daemon answers: done and failed are final, so the client records
// them and never sends the request again; retry means the laptop could not
// run it now (a program is missing), so it stays queued.
Status :: enum u8 {
	Done,
	Failed,
	Retry,
}

STATUS_NAMES := [Status]string {
	.Done   = "done",
	.Failed = "failed",
	.Retry  = "retry",
}

Reply :: struct {
	id:     string,
	status: Status,
	error:  string,
}

// What a client or the daemon writes down about a request: started before
// it runs anything that it must not run twice, then how it ended. Expired
// is a notification that came too late; skipped is a line of the queue
// that is not a request, by the hash of the line. Retry is a commit that
// failed and runs again at next.
Record_Status :: enum u8 {
	Started,
	Done,
	Failed,
	Expired,
	Skipped,
	Retry,
}

RECORD_NAMES := [Record_Status]string {
	.Started = "started",
	.Done    = "done",
	.Failed  = "failed",
	.Expired = "expired",
	.Skipped = "skipped",
	.Retry   = "retry",
}

// A commit's started and retry records also carry the vault's HEAD before
// the attempt ("" for a repository without a commit), how many attempts
// there were, when the first one was, and when the next one is due.
Record :: struct {
	id:       string,
	status:   Record_Status,
	error:    string,
	head:     string,
	attempts: int,
	since:    string,
	next:     string,
}

// new_id is a random UUID, version 4, in lowercase.
new_id :: proc(allocator := context.allocator) -> string {
	b: [16]u8
	for got := 0; got < len(b); {
		n, err := linux.getrandom(b[got:], {})
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			// The kernel's random source is always there on Linux 3.17
			// and later; without it there is no id that could not repeat.
			panic("ravnix-link: getrandom failed")
		}
		got += n
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	HEX := "0123456789abcdef"
	out := make([]u8, 36, allocator)
	j := 0
	for i in 0 ..< 16 {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-'
			j += 1
		}
		out[j] = HEX[b[i] >> 4]
		out[j + 1] = HEX[b[i] & 0x0f]
		j += 2
	}
	return string(out)
}

// is_uuid reports whether s is a UUID as new_id writes one: 8-4-4-4-12
// lowercase hexadecimal digits.
is_uuid :: proc(s: string) -> bool {
	if len(s) != 36 {
		return false
	}
	for c, i in transmute([]u8)s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// timestamp writes t as RFC 3339 in UTC, to the second: 2026-11-08T12:00:00Z.
timestamp :: proc(t: time.Time, allocator := context.allocator) -> string {
	s, ok := time.time_to_rfc3339(t, 0, false, allocator)
	if !ok {
		return ""
	}
	return s
}

parse_timestamp :: proc(s: string) -> (time.Time, bool) {
	if len(s) == 0 {
		return {}, false
	}
	t, consumed := time.rfc3339_to_time_utc(s)
	if consumed != len(s) {
		return {}, false
	}
	return t, true
}

// check_text says what is wrong with a free text (a summary, a body, a
// commit message), "" when nothing is: it must be valid UTF-8 without a
// NUL, which no program's argument can hold.
check_text :: proc(what, s: string) -> string {
	if !utf8.valid_string(s) {
		return fmt.tprintf("%s is not valid UTF-8", what)
	}
	if strings.index_byte(s, 0) >= 0 {
		return fmt.tprintf("%s holds a NUL", what)
	}
	return ""
}

// check_name says what is wrong with a text that names something (a path,
// a URL, an application): free text, and no control character either.
check_name :: proc(what, s: string) -> string {
	if why := check_text(what, s); why != "" {
		return why
	}
	for c in transmute([]u8)s {
		if c < ' ' || c == 0x7f {
			return fmt.tprintf("%s holds a control character", what)
		}
	}
	return ""
}

// check_vault_path says what is wrong with p as a path in the vault, as
// Obsidian's path= takes it: relative to the vault's root, without an
// empty, a . or a .. component.
check_vault_path :: proc(what, p: string) -> string {
	if p == "" {
		return fmt.tprintf("%s is empty", what)
	}
	if len(p) > MAX_PATH_BYTES {
		return fmt.tprintf("%s is longer than %d bytes", what, MAX_PATH_BYTES)
	}
	if why := check_name(what, p); why != "" {
		return why
	}
	if p[0] == '/' {
		return fmt.tprintf("%s %q starts with /: a path in the vault is relative to its root", what, p)
	}
	if p[len(p) - 1] == '/' {
		return fmt.tprintf("%s %q has an empty component (a / at its end)", what, p)
	}
	rest := p
	for part in strings.split_iterator(&rest, "/") {
		switch part {
		case "":
			return fmt.tprintf("%s %q has an empty component (// or a / at its end)", what, p)
		case ".", "..":
			return fmt.tprintf("%s %q has a %s component", what, p, part)
		}
	}
	return ""
}

// scheme_of is the scheme of a URL as written, or "" when target has none.
scheme_of :: proc(target: string) -> string {
	colon := strings.index_byte(target, ':')
	if colon <= 0 {
		return ""
	}
	for c, i in transmute([]u8)target[:colon] {
		letter := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
		if !(letter || i > 0 && (c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.')) {
			return ""
		}
	}
	return target[:colon]
}

// check_request says what is wrong with r, "" when nothing is.
check_request :: proc(r: Request) -> string {
	if !is_uuid(r.id) {
		return fmt.tprintf("the id %q is not a UUID", r.id)
	}
	if _, ok := parse_timestamp(r.created); !ok {
		return fmt.tprintf("the time %q is not RFC 3339", r.created)
	}
	is_open := r.kind == .Open
	is_notify := r.kind == .Notify
	is_obsidian := r.kind == .Obsidian
	is_commit := r.kind == .Vault_Commit
	stray := []struct {
		set:   bool,
		field: string,
	} {
		{!is_open && r.target != "", "target"},
		{!is_notify && (r.summary != "" || r.body != "" || r.urgency != "" || r.app != ""), "a notification's text"},
		{!is_obsidian && (r.op != .None || r.path != "" || r.to != "" || r.name != ""), "an Obsidian operation"},
		{!is_commit && (r.vault != "" || r.message != "" || len(r.paths) > 0 || len(r.sums) > 0), "a commit"},
	}
	for s in stray {
		if s.set {
			return fmt.tprintf("a request of kind %s carries %s", KIND_NAMES[r.kind], s.field)
		}
	}
	switch r.kind {
	case .Open:
		if r.target == "" {
			return "open has no target"
		}
		if len(r.target) > MAX_PATH_BYTES * 2 {
			return "the target is longer than 8192 bytes"
		}
		if why := check_name("the target", r.target); why != "" {
			return why
		}
		scheme := scheme_of(r.target)
		if scheme == "" {
			if r.target[0] != '/' {
				return fmt.tprintf("the target %q is neither a URL nor an absolute path", r.target)
			}
			return ""
		}
		for allowed in ALLOWED_SCHEMES {
			if scheme == allowed {
				return ""
			}
		}
		return fmt.tprintf("open forwards http, https and mailto links, in lowercase, and absolute paths, not %s:", scheme)
	case .Notify:
		if r.summary == "" {
			return "the notification has no summary"
		}
		if why := check_text("the summary", r.summary); why != "" {
			return why
		}
		if why := check_text("the body", r.body); why != "" {
			return why
		}
		switch r.urgency {
		case "", "low", "normal", "critical":
		case:
			return fmt.tprintf("the urgency %q is not low, normal or critical", r.urgency)
		}
		return check_name("the application", r.app)
	case .Obsidian:
		if r.op == .None {
			return "an Obsidian request names no operation (move, rename or delete)"
		}
		if why := check_vault_path("path=", r.path); why != "" {
			return why
		}
		switch r.op {
		case .None:
		case .Move:
			if r.name != "" {
				return "move takes to=, not name="
			}
			if r.to == "" {
				return "move needs to=, the folder or path to move the note to"
			}
			return check_vault_path("to=", r.to)
		case .Rename:
			if r.to != "" {
				return "rename takes name=, not to= (move moves and renames)"
			}
			if r.name == "" {
				return "rename needs name=, the note's new name"
			}
			if why := check_name("name=", r.name); why != "" {
				return why
			}
			if strings.index_byte(r.name, '/') >= 0 {
				return "name= is a file name, without a /: move moves a note"
			}
			if r.name == "." || r.name == ".." {
				return "name= is . or .., which names no note"
			}
		case .Delete:
			if r.to != "" || r.name != "" {
				return "delete takes path= alone, not to= or name="
			}
		}
		return ""
	case .Vault_Commit:
		if r.vault == "" || r.vault[0] != '/' {
			return fmt.tprintf("the vault %q is not an absolute path", r.vault)
		}
		if why := check_name("the vault", r.vault); why != "" {
			return why
		}
		if r.message == "" {
			return "the commit has no message"
		}
		if why := check_text("the commit message", r.message); why != "" {
			return why
		}
		if len(r.paths) > MAX_PATHS {
			return fmt.tprintf("the commit names %d paths, more than %d", len(r.paths), MAX_PATHS)
		}
		for p in r.paths {
			if why := check_vault_path("a path of the commit", p); why != "" {
				return why
			}
		}
		if len(r.sums) > 0 && len(r.sums) != len(r.paths) {
			return fmt.tprintf("the commit names %d paths and %d sums, one per path", len(r.paths), len(r.sums))
		}
		for sum in r.sums {
			if sum != NO_FILE && !is_sum(sum) {
				return fmt.tprintf("the sum %q is neither a SHA-256 in lowercase hex nor %s", sum, NO_FILE)
			}
		}
	}
	return ""
}

// write_json_string writes s as a JSON string. Every control character is
// escaped, and so are U+2028 and U+2029, so the line is plain printable
// text whatever s holds; s is valid UTF-8 (check_text), or its bad bytes
// are replaced when replace is set.
write_json_string :: proc(b: ^strings.Builder, s: string, replace := false) {
	HEX := "0123456789abcdef"
	strings.write_byte(b, '"')
	for i := 0; i < len(s); {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case 0 ..< 0x20, 0x7f:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, HEX[c >> 4])
			strings.write_byte(b, HEX[c & 0x0f])
		case 0x20 ..< 0x7f:
			strings.write_byte(b, c)
		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width <= 1 {
				if replace {
					strings.write_string(b, `�`)
				}
				i += 1
				continue
			}
			if r == 0x2028 || r == 0x2029 {
				strings.write_string(b, `\u202`)
				strings.write_byte(b, '8' if r == 0x2028 else '9')
			} else {
				strings.write_string(b, s[i:i + width])
			}
			i += width
			continue
		}
		i += 1
	}
	strings.write_byte(b, '"')
}

write_field :: proc(b: ^strings.Builder, first: ^bool, key, value: string) {
	if !first^ {
		strings.write_byte(b, ',')
	}
	first^ = false
	write_json_string(b, key)
	strings.write_byte(b, ':')
	write_json_string(b, value)
}

// encode_request writes r as one line, its newline included, or says why
// it cannot: r is checked first, and a line above MAX_LINE is refused.
encode_request :: proc(r: Request, allocator := context.allocator) -> (line: string, why: string) {
	if why = check_request(r); why != "" {
		return "", why
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"id":`)
	write_json_string(&b, r.id)
	strings.write_string(&b, `,"kind":`)
	write_json_string(&b, KIND_NAMES[r.kind])
	strings.write_string(&b, `,"args":{`)
	first := true
	switch r.kind {
	case .Open:
		write_field(&b, &first, "target", r.target)
	case .Notify:
		write_field(&b, &first, "summary", r.summary)
		write_field(&b, &first, "body", r.body)
		if r.urgency != "" {
			write_field(&b, &first, "urgency", r.urgency)
		}
		if r.app != "" {
			write_field(&b, &first, "app", r.app)
		}
	case .Obsidian:
		write_field(&b, &first, "op", OP_NAMES[r.op])
		write_field(&b, &first, "path", r.path)
		if r.to != "" {
			write_field(&b, &first, "to", r.to)
		}
		if r.name != "" {
			write_field(&b, &first, "name", r.name)
		}
	case .Vault_Commit:
		write_field(&b, &first, "vault", r.vault)
		write_field(&b, &first, "message", r.message)
		strings.write_string(&b, `,"paths":[`)
		for p, i in r.paths {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			write_json_string(&b, p)
		}
		strings.write_byte(&b, ']')
		if len(r.sums) > 0 {
			strings.write_string(&b, `,"sums":[`)
			for sum, i in r.sums {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				write_json_string(&b, sum)
			}
			strings.write_byte(&b, ']')
		}
	}
	strings.write_string(&b, `},"created":`)
	write_json_string(&b, r.created)
	strings.write_string(&b, "}\n")
	if strings.builder_len(b) > MAX_LINE {
		size := strings.builder_len(b)
		strings.builder_destroy(&b)
		return "", fmt.tprintf("the request is %d bytes long as a line, more than the %d a request may have", size, MAX_LINE)
	}
	return strings.to_string(b), ""
}

// nesting_within reports whether the arrays and objects of a JSON text nest
// at most depth deep, counted outside strings. The parser recurses once per
// level, so a line of brackets alone must not reach it.
nesting_within :: proc(data: string, depth: int) -> bool {
	level := 0
	in_string, escaped := false, false
	for c in transmute([]u8)data {
		if in_string {
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				in_string = false
			}
			continue
		}
		switch c {
		case '"':
			in_string = true
		case '[', '{':
			level += 1
			if level > depth {
				return false
			}
		case ']', '}':
			level -= 1
		}
	}
	return true
}

// has_surrogate_escape reports whether a string of the JSON text escapes a
// UTF-16 surrogate. The parser turns a lone one into U+FFFD instead of
// refusing it, and the encoder writes every character as itself, so a
// request never holds one, paired or not.
has_surrogate_escape :: proc(data: string) -> bool {
	in_string := false
	for i := 0; i < len(data); i += 1 {
		c := data[i]
		if !in_string {
			in_string = c == '"'
			continue
		}
		switch c {
		case '"':
			in_string = false
		case '\\':
			if i + 5 < len(data) && data[i + 1] == 'u' && (data[i + 2] == 'd' || data[i + 2] == 'D') {
				switch data[i + 3] {
				case '8', '9', 'a', 'b', 'c', 'd', 'e', 'f', 'A', 'B', 'C', 'D', 'E', 'F':
					return true
				}
			}
			i += 1
		}
	}
	return false
}

// parse_object parses line, which must be one JSON object and nothing
// else, into a parser arena that the caller destroys.
parse_object :: proc(line: string, arena: ^virtual.Arena) -> (obj: json.Object, why: string) {
	text := strings.trim_suffix(line, "\n")
	if len(text) + 1 > MAX_LINE {
		return nil, fmt.tprintf("the line is longer than %d bytes", MAX_LINE)
	}
	if strings.trim_space(text) == "" {
		return nil, "the line is empty"
	}
	if strings.index_byte(text, 0) >= 0 {
		return nil, "the line holds a NUL byte"
	}
	if strings.index_byte(text, '\n') >= 0 {
		return nil, "the line holds a newline"
	}
	if !nesting_within(text, 4) {
		return nil, "the line nests deeper than a request does"
	}
	if !utf8.valid_string(text) {
		return nil, "the line is not valid UTF-8"
	}
	if has_surrogate_escape(text) {
		return nil, "the line escapes a UTF-16 surrogate (\\ud800 to \\udfff), which a request never does"
	}
	if virtual.arena_init_growing(arena) != nil {
		return nil, "there is no memory to read the line"
	}
	// The parser frees what it read of a value it refuses with the context's
	// allocator, so that must be the arena too.
	context.allocator = virtual.arena_allocator(arena)
	p := json.make_parser(text, .JSON, false, context.allocator)
	value, err := json.parse_value(&p)
	if err != .None {
		return nil, fmt.tprintf("the line is not JSON (%v)", err)
	}
	if p.curr_token.kind != .EOF {
		return nil, "the line holds more than one JSON value"
	}
	o, is_object := value.(json.Object)
	if !is_object {
		return nil, "the line is no JSON object"
	}
	return o, ""
}

// only_keys says which key of obj is not one of keys, "" when none is.
only_keys :: proc(obj: json.Object, keys: ..string) -> string {
	outer: for k in obj {
		for want in keys {
			if k == want {
				continue outer
			}
		}
		return k
	}
	return ""
}

// string_field is obj[key] as a string, cloned; required fields must be
// there. A string is valid UTF-8 without a NUL, whatever its escapes said.
string_field :: proc(obj: json.Object, key: string, required: bool, allocator: runtime.Allocator) -> (s: string, why: string) {
	v, present := obj[key]
	if !present {
		if required {
			return "", fmt.tprintf("%s is missing", key)
		}
		return "", ""
	}
	str, is_string := v.(json.String)
	if !is_string {
		return "", fmt.tprintf("%s is not a string", key)
	}
	if why = check_text(key, str); why != "" {
		return "", why
	}
	return strings.clone(str, allocator), ""
}

// decode_request reads a request from line (with or without its newline)
// and checks it, as check_request does. The strings are in allocator.
decode_request :: proc(line: string, allocator := context.allocator) -> (r: Request, why: string) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	obj: json.Object
	if obj, why = parse_object(line, &arena); why != "" {
		return {}, why
	}
	if extra := only_keys(obj, "id", "kind", "args", "created"); extra != "" {
		return {}, fmt.tprintf("a request has no field %q", extra)
	}
	if r.id, why = string_field(obj, "id", true, allocator); why != "" {
		return {}, why
	}
	if !is_uuid(r.id) {
		return {}, fmt.tprintf("the id %q is not a UUID", r.id)
	}
	kind: string
	if kind, why = string_field(obj, "kind", true, context.temp_allocator); why != "" {
		return r, why
	}
	found := false
	for name, k in KIND_NAMES {
		if name == kind {
			r.kind, found = k, true
		}
	}
	if !found {
		return r, fmt.tprintf("the kind %q is none of open, notify, obsidian and vault-commit", kind)
	}
	if r.created, why = string_field(obj, "created", true, allocator); why != "" {
		return r, why
	}
	args_value, has_args := obj["args"]
	if !has_args {
		return r, "args is missing"
	}
	args, args_ok := args_value.(json.Object)
	if !args_ok {
		return r, "args is not an object"
	}
	switch r.kind {
	case .Open:
		if extra := only_keys(args, "target"); extra != "" {
			return r, fmt.tprintf("open has no argument %q", extra)
		}
		if r.target, why = string_field(args, "target", true, allocator); why != "" {
			return r, why
		}
	case .Notify:
		if extra := only_keys(args, "summary", "body", "urgency", "app"); extra != "" {
			return r, fmt.tprintf("notify has no argument %q", extra)
		}
		if r.summary, why = string_field(args, "summary", true, allocator); why != "" {
			return r, why
		}
		if r.body, why = string_field(args, "body", true, allocator); why != "" {
			return r, why
		}
		if r.urgency, why = string_field(args, "urgency", false, allocator); why != "" {
			return r, why
		}
		if r.app, why = string_field(args, "app", false, allocator); why != "" {
			return r, why
		}
	case .Obsidian:
		if extra := only_keys(args, "op", "path", "to", "name"); extra != "" {
			return r, fmt.tprintf("obsidian has no argument %q", extra)
		}
		op: string
		if op, why = string_field(args, "op", true, context.temp_allocator); why != "" {
			return r, why
		}
		for name, o in OP_NAMES {
			if name == op && o != .None {
				r.op = o
			}
		}
		if r.op == .None {
			return r, fmt.tprintf("the operation %q is none of move, rename and delete", op)
		}
		if r.path, why = string_field(args, "path", true, allocator); why != "" {
			return r, why
		}
		if r.to, why = string_field(args, "to", false, allocator); why != "" {
			return r, why
		}
		if r.name, why = string_field(args, "name", false, allocator); why != "" {
			return r, why
		}
	case .Vault_Commit:
		if extra := only_keys(args, "vault", "message", "paths", "sums"); extra != "" {
			return r, fmt.tprintf("vault-commit has no argument %q", extra)
		}
		if r.vault, why = string_field(args, "vault", true, allocator); why != "" {
			return r, why
		}
		if r.message, why = string_field(args, "message", true, allocator); why != "" {
			return r, why
		}
		paths_value, has_paths := args["paths"]
		if !has_paths {
			return r, "paths is missing"
		}
		list, is_list := paths_value.(json.Array)
		if !is_list {
			return r, "paths is not a list"
		}
		if len(list) > MAX_PATHS {
			return r, fmt.tprintf("the commit names %d paths, more than %d", len(list), MAX_PATHS)
		}
		r.paths = make([]string, len(list), allocator)
		for v, i in list {
			s, is_string := v.(json.String)
			if !is_string {
				return r, "a path of the commit is not a string"
			}
			if why = check_text("a path of the commit", s); why != "" {
				return r, why
			}
			r.paths[i] = strings.clone(s, allocator)
		}
		if sums_value, has_sums := args["sums"]; has_sums {
			sums, sums_list := sums_value.(json.Array)
			if !sums_list {
				return r, "sums is not a list"
			}
			if len(sums) > MAX_PATHS {
				return r, fmt.tprintf("the commit names %d sums, more than %d", len(sums), MAX_PATHS)
			}
			r.sums = make([]string, len(sums), allocator)
			for v, i in sums {
				s, is_string := v.(json.String)
				if !is_string {
					return r, "a sum of the commit is not a string"
				}
				r.sums[i] = strings.clone(s, allocator)
			}
		}
	}
	return r, check_request(r)
}

// A reply and a record are flat objects of strings: id, status, error.
encode_flat :: proc(id, status, error: string, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"id":`)
	write_json_string(&b, id, true)
	strings.write_string(&b, `,"status":`)
	write_json_string(&b, status)
	if error != "" {
		strings.write_string(&b, `,"error":`)
		// An error is a program's output, whatever its bytes: bad ones are
		// replaced, so the line is still written. It is cut to stay within
		// a line.
		write_json_string(&b, error[:min(len(error), MAX_LINE / 8)], true)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

decode_flat :: proc(line: string, allocator: runtime.Allocator) -> (id, status, error: string, why: string) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	obj: json.Object
	if obj, why = parse_object(line, &arena); why != "" {
		return
	}
	if extra := only_keys(obj, "id", "status", "error"); extra != "" {
		why = fmt.tprintf("no field %q", extra)
		return
	}
	if id, why = string_field(obj, "id", true, allocator); why != "" {
		return
	}
	if status, why = string_field(obj, "status", true, allocator); why != "" {
		return
	}
	error, why = string_field(obj, "error", false, allocator)
	return
}

encode_reply :: proc(r: Reply, allocator := context.allocator) -> string {
	return encode_flat(r.id, STATUS_NAMES[r.status], r.error, allocator)
}

// decode_reply reads a reply. Its id is a request's, or "" when the daemon
// could not read the request's id.
decode_reply :: proc(line: string, allocator := context.allocator) -> (Reply, string) {
	id, status, error, why := decode_flat(line, allocator)
	if why != "" {
		return {}, why
	}
	if id != "" && !is_uuid(id) {
		return {}, fmt.tprintf("the reply's id %q is not a UUID", id)
	}
	for name, s in STATUS_NAMES {
		if name == status {
			return Reply{id = id, status = s, error = error}, ""
		}
	}
	return {}, fmt.tprintf("the reply's status %q is none of done, failed and retry", status)
}

encode_record :: proc(r: Record, allocator := context.allocator) -> string {
	line := encode_flat(r.id, RECORD_NAMES[r.status], r.error, allocator)
	if r.head == "" && r.attempts == 0 && r.since == "" && r.next == "" {
		return line
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, line[:len(line) - 2])
	if r.head != "" {
		strings.write_string(&b, `,"head":`)
		write_json_string(&b, r.head, true)
	}
	if r.attempts > 0 {
		strings.write_string(&b, `,"attempts":`)
		write_json_string(&b, fmt.tprintf("%d", r.attempts))
	}
	if r.since != "" {
		strings.write_string(&b, `,"since":`)
		write_json_string(&b, r.since, true)
	}
	if r.next != "" {
		strings.write_string(&b, `,"next":`)
		write_json_string(&b, r.next, true)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

decode_record :: proc(line: string, allocator := context.allocator) -> (Record, string) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	obj, pwhy := parse_object(line, &arena)
	if pwhy != "" {
		return {}, pwhy
	}
	if extra := only_keys(obj, "id", "status", "error", "head", "attempts", "since", "next"); extra != "" {
		return {}, fmt.tprintf("no field %q", extra)
	}
	r: Record
	why: string
	status, attempts: string
	if r.id, why = string_field(obj, "id", true, allocator); why != "" {
		return {}, why
	}
	if status, why = string_field(obj, "status", true, allocator); why != "" {
		return {}, why
	}
	if r.error, why = string_field(obj, "error", false, allocator); why != "" {
		return {}, why
	}
	if r.head, why = string_field(obj, "head", false, allocator); why != "" {
		return {}, why
	}
	if attempts, why = string_field(obj, "attempts", false, allocator); why != "" {
		return {}, why
	}
	if r.since, why = string_field(obj, "since", false, allocator); why != "" {
		return {}, why
	}
	if r.next, why = string_field(obj, "next", false, allocator); why != "" {
		return {}, why
	}
	if !is_uuid(r.id) && !(strings.has_prefix(r.id, "corrupt-") && len(r.id) == len("corrupt-") + 16) {
		return {}, fmt.tprintf("the record's id %q is neither a UUID nor a line's hash", r.id)
	}
	if attempts != "" {
		n, ok := strconv.parse_int(attempts, 10)
		if !ok || n < 1 {
			return {}, fmt.tprintf("the record's attempts %q is no count", attempts)
		}
		r.attempts = n
	}
	for name, st in RECORD_NAMES {
		if name == status {
			r.status = st
			return r, ""
		}
	}
	return {}, fmt.tprintf("the record's status %q is unknown", status)
}
