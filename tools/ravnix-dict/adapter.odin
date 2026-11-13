// The adapters, and sync: two-way and add only (README.md).
//
// An adapter is one tool that keeps a word list. read gives the list as
// the tool has it, write gives the tool a whole new list, and must_stop
// says that writing stops the tool for a moment (Handy, which writes its
// settings from memory on exit, must be stopped first; the adapter does
// that itself). The core calls write only when the list changes, and the
// adapters that must stop after all the others.
//
// What read returns, and the strings in it, are allocated in the context's
// allocator; the core frees them, so an adapter does not. Error is a
// message for the user, or nil; as Maybe(string) it is the same type in
// every package, so an adapter in a package of its own needs nothing from
// this one to be one.
package ravnix_dict

import "core:fmt"
import "core:os"
import "core:strings"

Error :: Maybe(string)

Adapter :: struct {
	name:      string,
	read:      proc() -> ([]string, Error),
	write:     proc(words: []string) -> Error,
	must_stop: bool,
}

// adapters is the adapters main syncs. Task 7.2 fills it: Handy,
// LanguageTool and the prose skill's dictionary.
adapters :: proc() -> []Adapter {
	return nil
}

Config :: struct {
	file:         string,
	state:        string,
	lock_wait_ms: int,
	out:          ^os.File,
	errf:         ^os.File,
}

warn :: proc(cfg: Config, format: string, args: ..any) {
	fmt.fprintf(cfg.errf, "ravnix-dict: %s\n", fmt.tprintf(format, ..args))
}

// MAX_WARNINGS is how many warnings about the file a run prints; a file
// with many lines it cannot read gets a count of the rest.
MAX_WARNINGS :: 20

// load reads and parses the dictionary and prints its warnings.
load :: proc(cfg: Config) -> (d: Dictionary, data: string, ok: bool) {
	why: string
	data, why = read_dictionary(cfg.file, context.allocator)
	if why != "" {
		warn(cfg, "%s", why)
		return
	}
	d, why = parse(data, context.allocator)
	if why != "" {
		warn(cfg, "%s: %s", cfg.file, why)
		return
	}
	for w, i in d.warnings {
		if i == MAX_WARNINGS {
			warn(cfg, "%s: %d more lines like these", cfg.file, len(d.warnings) - MAX_WARNINGS)
			break
		}
		warn(cfg, "%s: %s", cfg.file, w)
	}
	return d, data, true
}

// A tool's list as sync reads it.
@(private)
Tool :: struct {
	adapter: Adapter,
	raw:     []string, // as read
	words:   []string, // trimmed, without empty words, each key once
	keys:    map[string]struct{},
	failed:  bool,
	taken:   int,
}

Outcome :: enum {
	Done,
	Failed,
	// The dictionary changed while sync ran; it starts again.
	Changed,
}

// MAX_ATTEMPTS is how often sync starts again when the dictionary changes
// under it.
MAX_ATTEMPTS :: 5

// sync exchanges words between the dictionary and the adapters, and
// returns the exit status: 1 when an adapter, the dictionary or the state
// failed, with the adapters that did not fail synced all the same.
sync :: proc(cfg: Config, list: []Adapter, allow_empty: bool) -> int {
	fd, why := lock(cfg.state, cfg.lock_wait_ms)
	if why != "" {
		warn(cfg, "%s", why)
		return 1
	}
	defer unlock(fd)
	for _ in 0 ..< MAX_ATTEMPTS {
		switch sync_once(cfg, list, allow_empty) {
		case .Done:
			return 0
		case .Failed:
			return 1
		case .Changed:
		}
	}
	warn(cfg, "%s changed %d times while sync ran; run it again", cfg.file, MAX_ATTEMPTS)
	return 1
}

@(private)
sync_once :: proc(cfg: Config, list: []Adapter, allow_empty: bool) -> Outcome {
	d, data, ok := load(cfg)
	if !ok {
		return .Failed
	}
	known, known_found, kwhy := read_keys(cfg.state, KNOWN, context.allocator)
	if kwhy != "" {
		warn(cfg, "%s", kwhy)
		return .Failed
	}
	removed, _, rwhy := read_keys(cfg.state, REMOVED, context.allocator)
	if rwhy != "" {
		warn(cfg, "%s", rwhy)
		return .Failed
	}

	// A dictionary with no word left, after a sync that knew some, is more
	// often an editor that truncated the file before writing it, or a
	// checkout gone wrong, than a wish to empty every tool.
	if len(d.keys) == 0 && known_found && len(known) > 0 && !allow_empty {
		warn(
			cfg,
			"%s holds no word: the %d %s of the last sync would go from every tool (a tool's word added since would still come in); if that is meant, run ravnix-dict sync --allow-empty",
			cfg.file,
			len(known),
			"word" if len(known) == 1 else "words",
		)
		return .Failed
	}

	// The removals: what the last sync knew and the file no longer holds,
	// added to those recorded before, less what is in the file again.
	// Recorded before any tool is touched, so a crash after this point
	// loses none, and kept until the word comes back, so a tool that
	// missed this sync, or resets to an old list, cannot bring it back.
	now_removed := make(Keys)
	for k in removed {
		if d.keys[k] == 0 {
			now_removed[k] = {}
		}
	}
	for k in known {
		if d.keys[k] == 0 {
			now_removed[k] = {}
		}
	}
	if !same_keys(now_removed, removed) {
		if why := write_keys(cfg.state, REMOVED, now_removed, REMOVED_COMMENT); why != "" {
			warn(cfg, "%s", why)
			return .Failed
		}
	}

	failed := false
	tools := make([]Tool, len(list))
	for a, i in list {
		t := &tools[i]
		t.adapter = a
		raw, err := a.read()
		if message, bad := err.?; bad {
			warn(cfg, "%s: cannot read its words: %s", a.name, message)
			t.failed, failed = true, true
			continue
		}
		t.raw = raw
		read_tool(cfg, t)
	}

	// New in a tool: into the dictionary, in the order of the adapters.
	for &t in tools {
		if t.failed {
			continue
		}
		for w in t.words {
			k := key(w, context.temp_allocator)
			if d.keys[k] > 0 || k in now_removed || word_problem(w) != "" {
				continue
			}
			add_word(&d, w, nil, nil, context.allocator)
			t.taken += 1
		}
	}
	total_taken := 0
	for t in tools {
		total_taken += t.taken
	}
	if total_taken > 0 {
		result, why := replace_file(cfg.file, serialize(d, context.allocator), data)
		switch result {
		case .Done:
		case .Changed:
			return .Changed
		case .Failed:
			warn(cfg, "cannot add the tools' new words to the dictionary: %s", why)
			return .Failed
		}
	}

	// Missing from a tool: written to it. The spelling is the dictionary's.
	spelling := make(map[string]string, len(d.keys))
	file_words := make([dynamic]string, 0, len(d.keys))
	for l in d.lines {
		if l.kind == .Entry && l.key not_in spelling {
			spelling[l.key] = l.word
			append(&file_words, l.word)
		}
	}
	for pass in 0 ..< 2 {
		for &t in tools {
			if t.failed || t.adapter.must_stop != (pass == 1) {
				continue
			}
			if !write_tool(cfg, &t, file_words[:], spelling, now_removed) {
				failed = true
			}
		}
	}

	file_keys := make(Keys, len(d.keys))
	for k, n in d.keys {
		if n > 0 {
			file_keys[k] = {}
		}
	}
	if !known_found || !same_keys(file_keys, known) {
		if why := write_keys(cfg.state, KNOWN, file_keys, KNOWN_COMMENT); why != "" {
			warn(cfg, "%s", why)
			return .Failed
		}
	}
	return .Failed if failed else .Done
}

// read_tool cleans what a tool returned: each word trimmed, an empty one
// dropped, a word that is there in another case once. A word the file
// cannot hold stays in the tool, and is not taken.
@(private)
read_tool :: proc(cfg: Config, t: ^Tool) {
	words := make([dynamic]string, 0, len(t.raw))
	t.keys = make(map[string]struct{}, len(t.raw))
	for raw in t.raw {
		w := strings.trim_space(raw)
		if w == "" {
			continue
		}
		k := key(w, context.allocator)
		if k in t.keys {
			continue
		}
		t.keys[k] = {}
		append(&words, w)
		if problem := word_problem(w); problem != "" {
			warn(cfg, "%s: %q stays in the tool and out of the dictionary: %s", t.adapter.name, w, problem)
		}
	}
	t.words = words[:]
}

// write_tool gives the tool its words, less the removed ones, in the
// dictionary's spelling, then the dictionary's words it lacks; and only
// when that is not what it has.
@(private)
write_tool :: proc(cfg: Config, t: ^Tool, file_words: []string, spelling: map[string]string, removed: Keys) -> bool {
	target := make([dynamic]string, 0, len(t.words) + len(file_words))
	dropped := 0
	for w in t.words {
		k := key(w, context.temp_allocator)
		if k in removed {
			dropped += 1
			continue
		}
		append(&target, spelling[k] or_else w)
	}
	given := 0
	for w in file_words {
		if key(w, context.temp_allocator) not_in t.keys {
			append(&target, w)
			given += 1
		}
	}
	in_step := len(target) == len(t.raw)
	for w, i in target {
		if !in_step {
			break
		}
		in_step = w == t.raw[i]
	}
	if in_step {
		if t.taken > 0 {
			fmt.fprintf(cfg.out, "%s: %d new in the dictionary\n", t.adapter.name, t.taken)
		}
		return true
	}
	if err := t.adapter.write(target[:]); err != nil {
		warn(cfg, "%s: cannot write its words: %s", t.adapter.name, err.?)
		return false
	}
	fmt.fprintf(
		cfg.out,
		"%s: %d new in the dictionary, %d written to it, %d removed from it\n",
		t.adapter.name,
		t.taken,
		given,
		dropped,
	)
	return true
}
