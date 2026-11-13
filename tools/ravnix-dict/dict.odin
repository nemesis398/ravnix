// The dictionary file: one entry per line, `word` or
// `word | lang=de,en | heard=Hugin;def VM`, `#` comments, UTF-8 (README.md).
//
// A Dictionary keeps every line as it was written, with its own line break,
// and a byte order mark when the file had one, so serialize gives back the
// file byte for byte; add and remove change only the lines they touch. A
// word is one entry whatever its case: the key of a word is its lower case,
// and the first line of a key gives its spelling.
package ravnix_dict

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// MAX_FILE_SIZE is the largest dictionary read; a bigger one is not a list
// of words someone keeps by hand.
MAX_FILE_SIZE :: 16 * 1024 * 1024
// MAX_WORD is the longest word, in bytes.
MAX_WORD :: 256

BOM :: "\xef\xbb\xbf"

Kind :: enum u8 {
	Blank,
	Comment,
	Entry,
	// A line that is neither: no word before the first bar, or a word the
	// file cannot hold. It stays as it is, and a warning names it.
	Malformed,
}

Field :: struct {
	key:   string, // "" for a field without "="
	value: string,
	text:  string, // the field as written, trimmed
}

Line :: struct {
	text:   string, // without the line break
	end:    string, // "\n", "\r\n", or "" for a last line without one
	kind:   Kind,
	word:   string, // of an entry, trimmed
	key:    string, // of an entry: the word in lower case
	fields: []Field,
}

Dictionary :: struct {
	bom:      bool,
	lines:    [dynamic]Line,
	// The keys of the entries, each with how many lines hold it.
	keys:     map[string]int,
	warnings: [dynamic]string,
}

// key is how a word is told apart: its lower case, rune by rune, so
// "GitHub", "github" and "GITHUB" are one word and "Ärger" is "ärger".
key :: proc(word: string, allocator: runtime.Allocator) -> string {
	upper := false
	for i in 0 ..< len(word) {
		c := word[i]
		if c >= 0x80 {
			return strings.to_lower(word, allocator)
		}
		upper ||= c >= 'A' && c <= 'Z'
	}
	// ASCII, the most of the words: a lower-case word is its own key, and
	// another is lowered byte by byte.
	if !upper {
		return word
	}
	out := make([]u8, len(word), allocator)
	for i in 0 ..< len(word) {
		c := word[i]
		out[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	return string(out)
}

// is_conflict reports a line that git writes into a file it could not
// merge: a dictionary with one is half of two files, and no list of words.
is_conflict :: proc(text: string) -> bool {
	for marker in ([]string{"<<<<<<<", "=======", ">>>>>>>", "|||||||"}) {
		if strings.has_prefix(text, marker) {
			rest := text[len(marker):]
			if rest == "" || rest[0] == ' ' || (marker == "=======" && strings.trim_space(rest) == "") {
				return true
			}
		}
	}
	return false
}

// word_problem says why word cannot be an entry of the file, or "" when it
// can. A bar would end the word and start a field, a line break would end
// the line, a leading "#" would make it a comment, and surrounding space
// would be lost when the line is read back. There is no escape: no tool
// that keeps a word list needs such a word, and an escape would make the
// file harder to read and to edit by hand.
word_problem :: proc(word: string) -> string {
	switch {
	case word == "":
		return "a word cannot be empty"
	case len(word) > MAX_WORD:
		return fmt.tprintf("a word has at most %d bytes, and this one has %d", MAX_WORD, len(word))
	case !utf8.valid_string(word):
		return "a word must be UTF-8"
	case strings.trim_space(word) != word:
		return "a word cannot start or end with a space"
	case word[0] == '#':
		return "a word cannot start with #, which starts a comment"
	case strings.contains_rune(word, '|'):
		return "a word cannot hold |, which starts a field"
	case is_conflict(word):
		return "a word cannot look like a git merge conflict marker"
	}
	for r in word {
		if r < 0x20 || r == 0x7f {
			return "a word cannot hold a line break, a tab or another control character"
		}
	}
	return ""
}

// value_problem says why a value of lang or heard cannot be written, or "".
value_problem :: proc(value: string, separator: rune) -> string {
	switch {
	case value == "":
		return "a value cannot be empty"
	case !utf8.valid_string(value):
		return "a value must be UTF-8"
	case strings.contains_rune(value, '|'):
		return "a value cannot hold |, which starts a field"
	case strings.contains_rune(value, separator):
		return fmt.tprintf("a value cannot hold %c, which separates the values", separator)
	}
	for r in value {
		if r < 0x20 || r == 0x7f {
			return "a value cannot hold a line break, a tab or another control character"
		}
	}
	return ""
}

// parse reads a dictionary. It refuses only what it cannot trust: bytes
// that are not UTF-8, a NUL, and a git merge conflict; everything else it
// keeps, with a warning for a line or a field it cannot read.
parse :: proc(data: string, allocator: runtime.Allocator) -> (d: Dictionary, why: string) {
	context.allocator = allocator
	d.lines = make([dynamic]Line, 0, strings.count(data, "\n") + 1)
	d.keys = make(map[string]int)
	d.warnings = make([dynamic]string)
	rest := data
	if strings.has_prefix(rest, BOM) {
		d.bom = true
		rest = rest[len(BOM):]
	}
	for n := 1; rest != ""; n += 1 {
		line: Line
		i := strings.index_byte(rest, '\n')
		if i < 0 {
			line.text, rest = rest, ""
		} else {
			line.text, line.end, rest = rest[:i], "\n", rest[i + 1:]
			if strings.has_suffix(line.text, "\r") {
				line.text, line.end = line.text[:len(line.text) - 1], "\r\n"
			}
		}
		if !utf8.valid_string(line.text) {
			return d, fmt.aprintf("line %d is not UTF-8; save the file as UTF-8", n)
		}
		if strings.contains_rune(line.text, 0) {
			return d, fmt.aprintf("line %d holds a NUL byte; this is no text file", n)
		}
		if is_conflict(line.text) {
			return d, fmt.aprintf("line %d is a git merge conflict marker; resolve the merge first", n)
		}
		read_line(&d, &line, n)
		append(&d.lines, line)
	}
	return d, ""
}

@(private)
read_line :: proc(d: ^Dictionary, line: ^Line, n: int) {
	trimmed := strings.trim_space(line.text)
	switch {
	case trimmed == "":
		line.kind = .Blank
		return
	case trimmed[0] == '#':
		line.kind = .Comment
		return
	}
	parts := strings.split(line.text, "|")
	word := strings.trim_space(parts[0])
	if word == "" {
		line.kind = .Malformed
		append(&d.warnings, fmt.aprintf("line %d has no word before its first |, and is skipped", n))
		return
	}
	if problem := word_problem(word); problem != "" {
		line.kind = .Malformed
		append(&d.warnings, fmt.aprintf("line %d is skipped: %s", n, problem))
		return
	}
	line.kind = .Entry
	line.word = word
	line.key = key(word, context.allocator)
	fields := make([dynamic]Field, 0, len(parts) - 1)
	seen: [2]bool
	for part in parts[1:] {
		text := strings.trim_space(part)
		if text == "" {
			append(&d.warnings, fmt.aprintf("line %d has an empty field", n))
			continue
		}
		f := Field{text = text}
		eq := strings.index_byte(text, '=')
		if eq < 0 {
			append(&d.warnings, fmt.aprintf("line %d has a field without =: %s", n, text))
		} else {
			f.key = strings.trim_space(text[:eq])
			f.value = strings.trim_space(text[eq + 1:])
			switch f.key {
			case "lang", "heard":
				i := 0 if f.key == "lang" else 1
				if seen[i] {
					append(&d.warnings, fmt.aprintf("line %d has %s= twice; both count", n, f.key))
				}
				seen[i] = true
			case:
				append(&d.warnings, fmt.aprintf("line %d has a field ravnix-dict does not know, kept as it is: %s", n, f.key))
			}
		}
		append(&fields, f)
	}
	line.fields = fields[:]
	d.keys[line.key] += 1
}

// serialize is the file: every line as it was read or as a command wrote it.
serialize :: proc(d: Dictionary, allocator: runtime.Allocator) -> string {
	size := len(BOM) if d.bom else 0
	for l in d.lines {
		size += len(l.text) + len(l.end)
	}
	b := strings.builder_make(0, size, allocator)
	if d.bom {
		strings.write_string(&b, BOM)
	}
	for l in d.lines {
		strings.write_string(&b, l.text)
		strings.write_string(&b, l.end)
	}
	return strings.to_string(b)
}

// words is the words of the dictionary, each once, in the order of the
// file and with the spelling of its first line.
words :: proc(d: Dictionary, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, 0, len(d.keys), allocator)
	seen := make(map[string]struct{}, len(d.keys), context.temp_allocator)
	for l in d.lines {
		if l.kind == .Entry && l.key not_in seen {
			seen[l.key] = {}
			append(&out, l.word)
		}
	}
	delete(seen)
	return out[:]
}

// has_word reports whether the dictionary holds word, in any case.
has_word :: proc(d: Dictionary, word: string) -> bool {
	k := key(word, context.temp_allocator)
	return d.keys[k] > 0
}

// values is the values of the field name over every line of word, each
// once, in the order they are written.
@(private)
values :: proc(d: Dictionary, word, name: string, separator: string, allocator: runtime.Allocator) -> []string {
	k := key(word, context.temp_allocator)
	out := make([dynamic]string, allocator)
	for l in d.lines {
		if l.kind != .Entry || l.key != k {
			continue
		}
		for f in l.fields {
			if f.key != name {
				continue
			}
			for v in strings.split(f.value, separator, context.temp_allocator) {
				value := strings.trim_space(v)
				if name == "lang" {
					value = strings.to_lower(value, allocator)
				}
				if value != "" && !contains(out[:], value) {
					append(&out, value)
				}
			}
		}
	}
	return out[:]
}

// Langs is the languages a word belongs to: every one, or those in codes.
Langs :: struct {
	// No line of the word restricts it: a line without lang=, or with an
	// empty one, puts the word in every language, as the editor's
	// LanguageTool code reads the file. codes is then empty.
	all:   bool,
	codes: []string,
}

// langs_of is the languages of word: every language when any line of it
// has no lang=, else the union of its lines' lang=. A word that is not in
// the dictionary is in none.
langs_of :: proc(d: Dictionary, word: string, allocator: runtime.Allocator) -> Langs {
	k := key(word, context.temp_allocator)
	for l in d.lines {
		if l.kind != .Entry || l.key != k {
			continue
		}
		restricted := false
		for f in l.fields {
			if f.key == "lang" && strings.trim(f.value, " ,") != "" {
				restricted = true
			}
		}
		if !restricted {
			return Langs{all = true}
		}
	}
	return Langs{codes = values(d, word, "lang", ",", allocator)}
}

// spelling_of is how the dictionary spells word: as its first line does,
// or "" when it is not there.
spelling_of :: proc(d: Dictionary, word: string) -> string {
	k := key(word, context.temp_allocator)
	for l in d.lines {
		if l.kind == .Entry && l.key == k {
			return l.word
		}
	}
	return ""
}

// heard_of is what speech recognition wrote for word: the union of its
// heard= fields.
heard_of :: proc(d: Dictionary, word: string, allocator: runtime.Allocator) -> []string {
	return values(d, word, "heard", ";", allocator)
}

contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}

// newline is the file's line break: that of its first line that has one.
newline :: proc(d: Dictionary) -> string {
	for l in d.lines {
		if l.end != "" {
			return l.end
		}
	}
	return "\n"
}

// render is an entry's line: the word, then each field after " | ".
@(private)
render :: proc(word: string, fields: []Field, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, word)
	for f in fields {
		strings.write_string(&b, " | ")
		strings.write_string(&b, f.text)
	}
	return strings.to_string(b)
}

// merge_field adds the values of add that field name of fields lacks, to
// its first occurrence or to a new field at the end. It reports a change.
@(private)
merge_field :: proc(fields: ^[dynamic]Field, name, separator: string, add: []string, have: []string, allocator: runtime.Allocator) -> bool {
	missing := make([dynamic]string, context.temp_allocator)
	for v in add {
		if !contains(have, v) && !contains(missing[:], v) {
			append(&missing, v)
		}
	}
	if len(missing) == 0 {
		return false
	}
	for &f in fields {
		if f.key == name {
			old := strings.trim_space(f.value)
			joined := strings.join(missing[:], separator, allocator)
			f.value = joined if old == "" else strings.concatenate({old, separator, joined}, allocator)
			f.text = strings.concatenate({name, "=", f.value}, allocator)
			return true
		}
	}
	value := strings.join(missing[:], separator, allocator)
	append(fields, Field{key = name, value = value, text = strings.concatenate({name, "=", value}, allocator)})
	return true
}

// add_word adds word with its languages and mishearings, as a new line at
// the end in the file's own line break, or, when the word is there in any
// case, adds what its first line lacks of them. A word that is there in
// every language stays so: langs never narrows it, which only an edit of
// the file does. It reports a change; a
// word that is there with all of them changes nothing. word must pass
// word_problem, and each value value_problem.
add_word :: proc(d: ^Dictionary, word: string, langs, heard: []string, allocator: runtime.Allocator) -> bool {
	context.allocator = allocator
	k := key(word, allocator)
	if d.keys[k] > 0 {
		for &l in d.lines {
			if l.kind != .Entry || l.key != k {
				continue
			}
			fields := make([dynamic]Field, 0, len(l.fields) + 2)
			append(&fields, ..l.fields)
			changed := false
			if have := langs_of(d^, word, context.temp_allocator); !have.all {
				changed = merge_field(&fields, "lang", ",", langs, have.codes, allocator)
			}
			changed |= merge_field(&fields, "heard", ";", heard, heard_of(d^, word, context.temp_allocator), allocator)
			if !changed {
				return false
			}
			l.fields = fields[:]
			l.text = render(l.word, l.fields, allocator)
			return true
		}
	}
	fields := make([dynamic]Field, 0, 2)
	merge_field(&fields, "lang", ",", langs, nil, allocator)
	merge_field(&fields, "heard", ";", heard, nil, allocator)
	nl := newline(d^)
	if n := len(d.lines); n > 0 && d.lines[n - 1].end == "" {
		d.lines[n - 1].end = nl
	}
	append(&d.lines, Line{text = render(word, fields[:], allocator), end = nl, kind = .Entry, word = word, key = k, fields = fields[:]})
	d.keys[k] += 1
	return true
}

// remove_word removes every line of word, in any case, and returns how
// many there were. Every other line stays as it is.
remove_word :: proc(d: ^Dictionary, word: string) -> int {
	k := key(word, context.temp_allocator)
	if d.keys[k] == 0 {
		return 0
	}
	removed := 0
	kept := 0
	for l in d.lines {
		if l.kind == .Entry && l.key == k {
			removed += 1
			continue
		}
		d.lines[kept] = l
		kept += 1
	}
	resize(&d.lines, kept)
	delete_key(&d.keys, k)
	return removed
}
