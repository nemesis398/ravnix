// The retention file, backups.toml, and the flags of restic forget it gives
// for one target and one host. README.md has the format and why each check
// is there; modules/options/backup.nix checks the same file at build time,
// with the same messages.
package ravnix_retention

import "core:fmt"
import "core:strings"

// The largest retention file read. The template's is under 1 KiB; one with
// an override for each of a few hundred hosts stays under this.
MAX_FILE_BYTES :: 64 * 1024

// The longest host name taken: one DNS label, which is what a NixOS host
// name is and what restic records.
MAX_HOST_LEN :: 63

Kind :: enum u8 {
	Daily,
	Weekly,
	Monthly,
	Yearly,
}

KIND_KEYS := [Kind]string {
	.Daily   = "daily",
	.Weekly  = "weekly",
	.Monthly = "monthly",
	.Yearly  = "yearly",
}

Counts :: [Kind]i64

Target :: enum u8 {
	Nas,
	Internxt,
}

TARGET_NAMES := [Target]string {
	.Nas      = "nas",
	.Internxt = "internxt",
}

// A host's own numbers: the kinds it gives, and their counts.
Override :: struct {
	given:  bit_set[Kind],
	counts: Counts,
}

Policy :: struct {
	counts: Counts,
	hosts:  map[string]Override,
}

Retention :: struct {
	targets: [Target]Policy,
}

target_named :: proc(name: string) -> (Target, bool) {
	for n, target in TARGET_NAMES {
		if n == name {
			return target, true
		}
	}
	return .Nas, false
}

// check_host says what keeps host from being a host name, or "" when
// nothing does. The flags go through a shell's word splitting, and restic
// would read a name with a leading dash as an option.
check_host :: proc(host: string) -> string {
	if host == "" {
		return "is empty"
	}
	if len(host) > MAX_HOST_LEN {
		return "is longer than 63 characters, which no host name is"
	}
	if !is_alnum(host[0]) {
		return "does not start with a letter or a digit"
	}
	for c in transmute([]u8)host {
		if !is_alnum(c) && c != '-' && c != '_' {
			return "holds a character other than letters, digits, - and _"
		}
	}
	return ""
}

// policy_of gives the counts that hold for host at target: the host's own
// where it has them, the target's otherwise.
policy_of :: proc(r: ^Retention, target: Target, host: string) -> Counts {
	p := &r.targets[target]
	counts := p.counts
	if own, ok := p.hosts[host]; ok {
		for kind in own.given {
			counts[kind] = own.counts[kind]
		}
	}
	return counts
}

// flags gives the flags of restic forget for host at target, on one line.
// --host keeps the prune to that host's snapshots, in a repository the whole
// estate shares; --group-by host makes all of them one group, so a change of
// the backup paths does not start a second group whose newest snapshots the
// policy would keep for good. A count of 0 is left out, which is what 0
// means: none of that kind is kept for its own sake.
flags :: proc(r: ^Retention, target: Target, host: string, allocator := context.allocator) -> string {
	counts := policy_of(r, target, host)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "--host ")
	strings.write_string(&b, host)
	strings.write_string(&b, " --group-by host")
	for n, kind in counts {
		if n > 0 {
			strings.write_string(&b, " --keep-")
			strings.write_string(&b, KIND_KEYS[kind])
			strings.write_byte(&b, ' ')
			strings.write_i64(&b, n)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Reading the file
//
// The file is TOML, and this reads the part of TOML a retention file needs:
// comments, [table] headers, key = value lines, bare and quoted keys (a
// quoted one without escapes), dotted keys, and decimal integers. Every
// other value is read as "not a whole number", which the checks refuse,
// naming the key; anything else (an array of tables, an escape in a key, a
// value that runs over several lines) is refused, naming the line. A file
// that Nix reads and this does not fails the prune, which keeps everything:
// the safe way to be wrong.

Bad :: struct {
	inline_table: bool,
}

Value :: union {
	^Table,
	i64,
	Bad,
}

Entry :: struct {
	key:   string,
	value: Value,
	line:  int,
}

Table :: struct {
	entries: [dynamic]Entry,
	// Whether a header or a dotted key made it, so a second header for it is
	// refused; a table made on the way to another is not.
	defined: bool,
}

// read_retention reads text and checks it. why is "" when the file is right,
// and otherwise says what is wrong, naming the key and, where there is one,
// its line. Everything goes into allocator.
read_retention :: proc(text: string, allocator := context.allocator) -> (r: Retention, why: string) {
	context.allocator = allocator
	root: ^Table
	root, why = parse(text)
	if why != "" {
		return
	}
	return check(root)
}

find :: proc(t: ^Table, key: string) -> ^Entry {
	for &e in t.entries {
		if e.key == key {
			return &e
		}
	}
	return nil
}

new_table :: proc(defined: bool) -> ^Table {
	t := new(Table)
	t.entries = make([dynamic]Entry)
	t.defined = defined
	return t
}

parse :: proc(text: string) -> (root: ^Table, why: string) {
	root = new_table(true)
	current := root
	current_path: []string
	rest := strings.trim_prefix(text, "\xef\xbb\xbf")
	line_no := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_no += 1
		line := strings.trim_suffix(raw, "\r")
		for c in transmute([]u8)line {
			if (c < ' ' && c != '\t') || c == 0x7f {
				return nil, fmt.aprintf("line %d: holds a control character", line_no)
			}
		}
		line = strings.trim(strip_comment(line), " \t")
		if line == "" {
			continue
		}

		if strings.has_prefix(line, "[[") {
			return nil, fmt.aprintf("line %d: an array of tables ([[...]]) is not part of a retention file", line_no)
		}
		if line[0] == '[' {
			keys, after, kwhy := parse_keys(line[1:], ']')
			if kwhy != "" {
				return nil, fmt.aprintf("line %d: %s", line_no, kwhy)
			}
			if after != "]" {
				return nil, fmt.aprintf("line %d: something follows the table header [%s]", line_no, strings.join(keys, "."))
			}
			t := root
			for key, i in keys {
				e := find(t, key)
				last := i == len(keys) - 1
				if e == nil {
					append(&t.entries, Entry{key = key, value = new_table(last), line = line_no})
					e = &t.entries[len(t.entries) - 1]
				} else if sub, is_table := e.value.(^Table); !is_table {
					return nil, fmt.aprintf("line %d: %s is given twice", line_no, strings.join(keys[:i + 1], "."))
				} else if last {
					if sub.defined {
						return nil, fmt.aprintf("line %d: [%s] is given twice", line_no, strings.join(keys, "."))
					}
					sub.defined = true
				}
				t = e.value.(^Table)
			}
			current, current_path = t, keys
			continue
		}

		keys, after, kwhy := parse_keys(line, '=')
		if kwhy != "" {
			return nil, fmt.aprintf("line %d: %s", line_no, kwhy)
		}
		path := path_of(current_path, keys)
		t := current
		for key, i in keys[:len(keys) - 1] {
			e := find(t, key)
			if e == nil {
				append(&t.entries, Entry{key = key, value = new_table(true), line = line_no})
				e = &t.entries[len(t.entries) - 1]
			} else if _, is_table := e.value.(^Table); !is_table {
				return nil, fmt.aprintf("line %d: %s is given twice", line_no, path_of(current_path, keys[:i + 1]))
			}
			t = e.value.(^Table)
		}
		key := keys[len(keys) - 1]
		if find(t, key) != nil {
			return nil, fmt.aprintf("line %d: %s is given twice", line_no, path)
		}
		append(&t.entries, Entry{key = key, value = parse_value(strings.trim(after[1:], " \t")), line = line_no})
	}
	return root, ""
}

path_of :: proc(prefix, keys: []string) -> string {
	all := make([dynamic]string)
	append(&all, ..prefix)
	append(&all, ..keys)
	return strings.join(all[:], ".")
}

// strip_comment cuts line at a # that is not inside a quoted string.
strip_comment :: proc(line: string) -> string {
	quote: u8 = 0
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		switch {
		case quote == 0 && c == '#':
			return line[:i]
		case quote == 0 && (c == '"' || c == '\''):
			quote = c
		case quote == '"' && c == '\\':
			i += 1
		case quote != 0 && c == quote:
			quote = 0
		}
	}
	return line
}

is_alnum :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

is_bare :: proc(c: u8) -> bool {
	return is_alnum(c) || c == '-' || c == '_'
}

// parse_keys reads a dotted key from s up to stop, and gives the keys and
// the rest of s from stop on.
parse_keys :: proc(s: string, stop: u8) -> (keys: []string, rest: string, why: string) {
	out := make([dynamic]string)
	i := 0
	skip :: proc(s: string, i: ^int) {
		for i^ < len(s) && (s[i^] == ' ' || s[i^] == '\t') {
			i^ += 1
		}
	}
	for {
		skip(s, &i)
		if i >= len(s) {
			return nil, "", "a key is missing" if stop == '=' else "the table header does not end with ]"
		}
		key: string
		c := s[i]
		switch {
		case c == '"' || c == '\'':
			end := strings.index_byte(s[i + 1:], c)
			if end < 0 {
				return nil, "", "a quoted key does not end"
			}
			key = s[i + 1:i + 1 + end]
			if c == '"' && strings.contains_rune(key, '\\') {
				return nil, "", "a key with an escape is not part of a retention file"
			}
			i += end + 2
		case is_bare(c):
			start := i
			for i < len(s) && is_bare(s[i]) {
				i += 1
			}
			key = s[start:i]
		case:
			return nil, "", "a key is missing" if c == stop || c == '.' else fmt.aprintf("%q cannot start a key", c)
		}
		if key == "" {
			return nil, "", "a key is empty"
		}
		append(&out, key)
		skip(s, &i)
		if i >= len(s) {
			return nil, "", "a key has no value: write KEY = VALUE" if stop == '=' else "the table header does not end with ]"
		}
		switch s[i] {
		case '.':
			i += 1
		case stop:
			return out[:], s[i:], ""
		case:
			return nil, "", fmt.aprintf("the key %s is followed by %q, where a dot or %q belongs", strings.join(out[:], "."), s[i], stop)
		}
	}
}

parse_value :: proc(s: string) -> Value {
	if strings.has_prefix(s, "{") {
		return Bad{inline_table = true}
	}
	if n, ok := parse_integer(s); ok {
		return n
	}
	return Bad{}
}

// parse_integer reads a decimal integer as TOML writes it: an optional sign,
// no leading zero, an underscore only between two digits, and within i64.
parse_integer :: proc(s: string) -> (n: i64, ok: bool) {
	digits := s
	negative := false
	if len(digits) > 0 && (digits[0] == '+' || digits[0] == '-') {
		negative = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 || (digits[0] == '0' && len(digits) > 1) {
		return 0, false
	}
	limit: u64 = 1 << 63 if negative else 1 << 63 - 1
	v: u64 = 0
	after_digit := false
	for c, i in transmute([]u8)digits {
		switch {
		case c >= '0' && c <= '9':
			d := u64(c - '0')
			if v > (limit - d) / 10 {
				return 0, false
			}
			v = v * 10 + d
			after_digit = true
		case c == '_' && after_digit && i < len(digits) - 1:
			after_digit = false
		case:
			return 0, false
		}
	}
	if !after_digit {
		return 0, false
	}
	return -i64(v) if negative else i64(v), true
}

// ---------------------------------------------------------------------------
// Checking what was read, in the order and with the words of
// modules/options/backup.nix; the first problem is the answer.

at :: proc(e: ^Entry, path, what: string) -> string {
	return fmt.aprintf("line %d: %s %s", e.line, path, what)
}

table_of :: proc(e: ^Entry, path: string) -> (^Table, string) {
	switch v in e.value {
	case ^Table:
		return v, ""
	case Bad:
		if v.inline_table {
			return nil, inline(e, path)
		}
	case i64:
	}
	return nil, at(e, path, "is not a table")
}

inline :: proc(e: ^Entry, path: string) -> string {
	return at(e, path, fmt.aprintf("is an inline table ({ ... }), which is not part of a retention file; write a [%s] table", path))
}

count_of :: proc(e: ^Entry, path: string) -> (i64, string) {
	#partial switch v in e.value {
	case i64:
		if v >= 0 {
			return v, ""
		}
	case Bad:
		if v.inline_table {
			return 0, inline(e, path)
		}
	}
	return 0, at(e, path, "is not a whole number of 0 or more")
}

kind_named :: proc(key: string) -> (Kind, bool) {
	for k, kind in KIND_KEYS {
		if k == key {
			return kind, true
		}
	}
	return .Daily, false
}

// read_counts reads the counts of t at where, and says which keys are
// neither counts nor, where allowed, hosts.
read_counts :: proc(t: ^Table, where_: string, required, hosts_allowed: bool) -> (given: bit_set[Kind], counts: Counts, why: string) {
	for key, kind in KIND_KEYS {
		e := find(t, key)
		if e == nil {
			if required {
				return {}, {}, fmt.aprintf("%s has no %s", where_, key)
			}
			continue
		}
		counts[kind], why = count_of(e, fmt.aprintf("%s.%s", where_, key))
		if why != "" {
			return
		}
		given += {kind}
	}
	for &e in t.entries {
		if _, is_kind := kind_named(e.key); !is_kind && !(hosts_allowed && e.key == "hosts") {
			return {}, {}, at(&e, fmt.aprintf("%s.%s", where_, e.key), "is not a key of the file")
		}
	}
	return
}

keeps_nothing :: proc(counts: Counts) -> bool {
	for n in counts {
		if n != 0 {
			return false
		}
	}
	return true
}

check :: proc(root: ^Table) -> (r: Retention, why: string) {
	targets: ^Table
	for &e in root.entries {
		if e.key != "targets" {
			return {}, at(&e, e.key, "is not a key of the file")
		}
		targets, why = table_of(&e, "targets")
		if why != "" {
			return
		}
	}
	if targets == nil {
		return {}, "targets.nas is missing"
	}
	for name in TARGET_NAMES {
		if find(targets, name) == nil {
			return {}, fmt.aprintf("targets.%s is missing", name)
		}
	}
	for &e in targets.entries {
		if _, known := target_named(e.key); !known {
			return {}, at(&e, fmt.aprintf("targets.%s", e.key), "is not a target ravnix backs up to")
		}
	}
	for name, target in TARGET_NAMES {
		where_ := fmt.aprintf("targets.%s", name)
		t: ^Table
		t, why = table_of(find(targets, name), where_)
		if why != "" {
			return
		}
		p := &r.targets[target]
		_, p.counts, why = read_counts(t, where_, true, true)
		if why != "" {
			return
		}
		if keeps_nothing(p.counts) {
			return {}, fmt.aprintf("%s keeps nothing, so a prune would delete every snapshot", where_)
		}
		p.hosts = make(map[string]Override)
		hosts_entry := find(t, "hosts")
		if hosts_entry == nil {
			continue
		}
		hosts: ^Table
		hosts, why = table_of(hosts_entry, fmt.aprintf("%s.hosts", where_))
		if why != "" {
			return
		}
		for &h in hosts.entries {
			host_where := fmt.aprintf("%s.hosts.%s", where_, h.key)
			ht: ^Table
			ht, why = table_of(&h, host_where)
			if why != "" {
				return
			}
			own: Override
			own.given, own.counts, why = read_counts(ht, host_where, false, false)
			if why != "" {
				return
			}
			p.hosts[h.key] = own
			if keeps_nothing(policy_of(&r, target, h.key)) {
				return {}, fmt.aprintf("%s keeps nothing, so a prune would delete every snapshot", host_where)
			}
		}
	}
	return r, ""
}
