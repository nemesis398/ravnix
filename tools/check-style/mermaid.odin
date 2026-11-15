package check_style

import "core:fmt"
import "core:strings"

// Mermaid init blocks: %%{init: ...}%% or %%{initialize: ...}%% at the start
// of a line must hold exactly what docs/mermaid-theme.json holds, compared
// without white space, and must close. Prose that mentions the syntax in
// the middle of a line is no block.

// The shared theme, read when the first block is met: a run on files with
// no block needs no theme.
Theme :: struct {
	path:      string,
	loaded:    bool,
	// The file without its white space.
	reference: string,
}

// theme_load reads the shared theme once. The error text is empty on success.
theme_load :: proc(t: ^Theme) -> string {
	if t.loaded {
		return ""
	}
	if t.path == "" {
		return "cannot read the shared Mermaid theme: RAVNIX_MERMAID_THEME is not set, and this build names no default"
	}
	data, ok := read_whole_file(t.path)
	if !ok {
		return fmt.aprintf("cannot read the shared Mermaid theme %s", t.path)
	}
	b: strings.Builder
	for c in data {
		if !is_space(c) {
			strings.write_byte(&b, c)
		}
	}
	t.reference = strings.to_string(b)
	t.loaded = true
	return ""
}

// The block being read, from its first line to the line with }%%.
Mermaid :: struct {
	inside: bool,
	// The line the block started on, which a hit names.
	start:  int,
	// How many bytes of the reference the block has matched so far, and
	// whether it differs.
	pos:    int,
	bad:    bool,
}

// init_start: the rest of the line after `%%{init:`, if the line starts a
// block (blanks, %%{, blanks, init or initialize, blanks, a colon).
init_start :: proc(line: string) -> (rest: string, ok: bool) {
	i := 0
	for i < len(line) && is_blank(line[i]) {
		i += 1
	}
	if !has_at(line, i, "%%{") {
		return "", false
	}
	i += 3
	for i < len(line) && is_blank(line[i]) {
		i += 1
	}
	if has_at(line, i, "initialize") {
		i += len("initialize")
	} else if has_at(line, i, "init") {
		i += len("init")
	} else {
		return "", false
	}
	for i < len(line) && is_blank(line[i]) {
		i += 1
	}
	if i >= len(line) || line[i] != ':' {
		return "", false
	}
	return line[i + 1:], true
}

// mermaid_step reads one line into the block state, and says in j.in_init
// whether the line is part of a block (hex colors there are the shared
// theme's business). A fatal error is the text to print, with exit status 2.
mermaid_step :: proc(j: ^Judge) -> (fatal: string) {
	m := &j.mermaid
	text := j.line
	if !m.inside {
		rest, ok := init_start(text)
		if !ok {
			return ""
		}
		fatal = theme_load(j.theme)
		if fatal != "" {
			return
		}
		m^ = Mermaid {
			inside = true,
			start  = j.line_no,
		}
		text = rest
	}
	j.in_init = true
	closed := strings.index(text, "}%%")
	part := text if closed < 0 else text[:closed]
	if !m.bad {
		ref := j.theme.reference
		for c in transmute([]u8)part {
			// The block is compared without space, tab and line ends.
			if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
				continue
			}
			if m.pos >= len(ref) || ref[m.pos] != c {
				m.bad = true
				break
			}
			m.pos += 1
		}
	}
	if closed >= 0 {
		if m.bad || m.pos != len(j.theme.reference) {
			add_hit_at(j, m.start, .Mermaid_Init)
		}
		m.inside = false
	}
	return ""
}

// finish_file: a block that never closes is a hit at its first line.
finish_file :: proc(j: ^Judge) {
	if j.mermaid.inside {
		add_hit_at(j, j.mermaid.start, .Mermaid_Init)
		j.mermaid.inside = false
	}
}
