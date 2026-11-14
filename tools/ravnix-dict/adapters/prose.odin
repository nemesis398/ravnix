// The prose skill's dictionary: a plain list of words, one per line, `#`
// comments, which the skill's checker reads beside its own bundled list
// and hands to LanguageTool as words to accept (../README.md, "prose").
// The file is the user's, ~/.config/prose/dictionary.txt: the skill's own
// list ships with the skill and is not written.
//
// A write keeps the file's comments, blank lines and line breaks where
// they are, keeps each word's line in its place (with the spelling it is
// given), drops the lines of the words it is not given, and appends the
// new words at the end.
package adapters

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

Prose :: struct {
	file: string,
}

PROSE_MAX_SIZE :: 16 * 1024 * 1024

PROSE_HEADER :: `# Words the prose skill's LanguageTool check accepts, one per line.
# ravnix-dict writes this file from the dictionary (ravnix.dictionary.file);
# a word added here comes into the dictionary at the next sync, and a word
# is removed in the dictionary, not here.
`

@(thread_local)
prose: Prose

@(private)
Prose_Line :: struct {
	text: string, // without its line break
	end:  string,
	word: string, // "" for a comment or a blank line
}

@(private)
prose_lines :: proc(text: string) -> (lines: []Prose_Line, why: string) {
	if !utf8.valid_string(text) {
		return nil, fmt.tprintf("%s is not UTF-8", prose.file)
	}
	out := make([dynamic]Prose_Line)
	rest := text
	for rest != "" {
		l: Prose_Line
		i := strings.index_byte(rest, '\n')
		if i < 0 {
			l.text, rest = rest, ""
		} else {
			l.text, l.end, rest = rest[:i], "\n", rest[i + 1:]
			if strings.has_suffix(l.text, "\r") {
				l.text, l.end = l.text[:len(l.text) - 1], "\r\n"
			}
		}
		// As the checker reads it: a line, trimmed, that is not empty and
		// does not start with #.
		w := strings.trim_space(l.text)
		if w != "" && w[0] != '#' {
			l.word = w
		}
		append(&out, l)
	}
	return out[:], ""
}

prose_read :: proc() -> ([]string, Error) {
	text, missing, why := read_text(prose.file, PROSE_MAX_SIZE, context.allocator)
	if why != "" {
		return nil, why
	}
	if missing {
		return nil, nil
	}
	lines, lwhy := prose_lines(text)
	if lwhy != "" {
		return nil, lwhy
	}
	words := make([dynamic]string)
	for l in lines {
		if l.word != "" {
			append(&words, l.word)
		}
	}
	return words[:], nil
}

prose_write :: proc(words: []string) -> Error {
	text, missing, why := read_text(prose.file, PROSE_MAX_SIZE, context.allocator)
	if why != "" {
		return why
	}
	if missing {
		text = PROSE_HEADER
	}
	lines, lwhy := prose_lines(text)
	if lwhy != "" {
		return lwhy
	}
	// Each word given, by its key, with its place in words; a line of a
	// word takes the spelling given, and the second line of a word goes.
	given := make(map[string]int, len(words), context.temp_allocator)
	for w, i in words {
		k := lower(w)
		if k not_in given {
			given[k] = i
		}
	}
	placed := make([]bool, len(words), context.temp_allocator)
	nl := "\n"
	for l in lines {
		if l.end != "" {
			nl = l.end
			break
		}
	}
	b := strings.builder_make(0, len(text) + 16 * len(words))
	last_end := "\n"
	for l in lines {
		if l.word == "" {
			strings.write_string(&b, l.text)
			strings.write_string(&b, l.end)
			last_end = l.end
			continue
		}
		i, ok := given[lower(l.word)]
		if !ok || placed[i] {
			continue
		}
		placed[i] = true
		if l.word == words[i] {
			strings.write_string(&b, l.text)
		} else {
			// The spelling given, in the line's own indentation.
			lead := l.text[:strings.index(l.text, l.word)]
			strings.write_string(&b, lead)
			strings.write_string(&b, words[i])
		}
		strings.write_string(&b, l.end)
		last_end = l.end
	}
	if last_end == "" && strings.builder_len(b) > 0 {
		strings.write_string(&b, nl)
	}
	for w, i in words {
		if !placed[i] && given[lower(w)] == i {
			strings.write_string(&b, w)
			strings.write_string(&b, nl)
		}
	}
	if rwhy := replace(prose.file, strings.to_string(b), 0o644); rwhy != "" {
		return rwhy
	}
	return nil
}
