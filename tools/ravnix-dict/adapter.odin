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
// this one to be one. unavailable, when an adapter has it, says why the
// tool cannot be reached right now (LanguageTool without credentials, the
// vault locked): sync then skips the adapter and says so, and that is no
// failure.
package ravnix_dict

import "core:fmt"
import "core:os"
import "core:strings"
import tools "adapters"

Error :: Maybe(string)

Adapter :: struct {
	name:        string,
	read:        proc() -> ([]string, Error),
	write:       proc(words: []string) -> Error,
	must_stop:   bool,
	unavailable: proc() -> string,
}

// ADAPTER_NAMES is every adapter there is, in the order sync reads them.
ADAPTER_NAMES :: []string{"handy", "languagetool", "prose"}

// Setup is where the adapters find their tools: what main reads from the
// environment.
Setup :: struct {
	// RAVNIX_DICT_ADAPTERS: the names of the adapters to sync, separated
	// by commas; none when it is empty.
	names:                string,
	home:                 string, // HOME
	config_home:          string, // XDG_CONFIG_HOME
	data_home:            string, // XDG_DATA_HOME
	handy_settings:       string, // RAVNIX_DICT_HANDY_SETTINGS
	prose_file:           string, // RAVNIX_DICT_PROSE_FILE
	languagetool_server:  string, // RAVNIX_DICT_LANGUAGETOOL_SERVER
	languagetool_user:    string, // LANGUAGETOOL_USERNAME
	languagetool_key:     string, // LANGUAGETOOL_API_KEY
	languagetool_item:    string, // LANGUAGETOOL_RBW_ITEM
}

// xdg is an XDG base directory: the variable when it is an absolute path,
// else fallback under HOME.
@(private)
xdg :: proc(value, home, fallback: string) -> string {
	if strings.has_prefix(value, "/") {
		return value
	}
	if home == "" {
		return ""
	}
	return strings.concatenate({home, "/", fallback})
}

// adapters is the adapters setup names, each set up from setup; why names
// an adapter that does not exist, or a path that cannot be found.
adapters :: proc(setup: Setup) -> (list: []Adapter, why: string) {
	out := make([dynamic]Adapter)
	wanted := make(map[string]struct{})
	for part in strings.split(setup.names, ",") {
		name := strings.trim_space(part)
		if name == "" {
			continue
		}
		if !contains(ADAPTER_NAMES, name) {
			return nil, fmt.tprintf("RAVNIX_DICT_ADAPTERS names %s; the adapters are %s", name, strings.join(ADAPTER_NAMES, ", "))
		}
		wanted[name] = {}
	}
	data := xdg(setup.data_home, setup.home, ".local/share")
	config := xdg(setup.config_home, setup.home, ".config")
	for name in ADAPTER_NAMES {
		if name not_in wanted {
			continue
		}
		switch name {
		case "handy":
			settings := setup.handy_settings
			if settings == "" && data != "" {
				settings = strings.concatenate({data, "/com.pais.handy/settings_store.json"})
			}
			if settings == "" {
				return nil, "the handy adapter finds no settings: set RAVNIX_DICT_HANDY_SETTINGS, XDG_DATA_HOME or HOME"
			}
			tools.handy = {settings = settings}
			append(&out, Adapter{name = name, read = tools.handy_read, write = tools.handy_write, must_stop = true})
		case "languagetool":
			tools.languagetool_reset()
			tools.languagetool = {
				server   = setup.languagetool_server,
				user     = setup.languagetool_user,
				key      = setup.languagetool_key,
				rbw_item = setup.languagetool_item,
			}
			if config != "" {
				tools.languagetool.credentials = strings.concatenate({config, "/languagetool/credentials"})
			}
			append(&out, Adapter{name = name, read = tools.languagetool_read, write = tools.languagetool_write, unavailable = tools.languagetool_unavailable})
		case "prose":
			file := setup.prose_file
			if file == "" && config != "" {
				file = strings.concatenate({config, "/prose/dictionary.txt"})
			}
			if file == "" {
				return nil, "the prose adapter finds no dictionary: set RAVNIX_DICT_PROSE_FILE, XDG_CONFIG_HOME or HOME"
			}
			tools.prose = {file = file}
			append(&out, Adapter{name = name, read = tools.prose_read, write = tools.prose_write})
		}
	}
	return out[:], ""
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
	failed:  bool, // or skipped: neither read nor written
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
// partial says that list is some of the host's adapters (--adapter), which
// a first sync on the host refuses.
sync :: proc(cfg: Config, list: []Adapter, allow_empty: bool, partial := false) -> int {
	// An adapter may keep what must outlive a sync there (Handy's marker
	// of a stop it has not undone yet).
	tools.state_dir = cfg.state
	fd, why := lock(cfg.state, cfg.lock_wait_ms)
	if why != "" {
		warn(cfg, "%s", why)
		return 1
	}
	defer unlock(fd)
	for _ in 0 ..< MAX_ATTEMPTS {
		switch sync_once(cfg, list, allow_empty, partial) {
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
sync_once :: proc(cfg: Config, list: []Adapter, allow_empty, partial: bool) -> Outcome {
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

	// The first sync on this host is the first merge: every tool's words
	// into the dictionary, and all of them to every tool. It writes the
	// known list, which the watcher waits for, so a tool it left out (one
	// adapter given, or LanguageTool behind a locked vault) would be merged
	// later by the watcher, unattended. It reaches every tool, or syncs
	// nothing.
	if !known_found {
		if partial {
			warn(cfg, "the first sync on this host must reach every tool: run ravnix-dict sync without --adapter")
			return .Failed
		}
		for a in list {
			if a.unavailable == nil {
				continue
			}
			if reason := a.unavailable(); reason != "" {
				warn(cfg, "%s: %s; the first sync on this host must reach every tool, so it syncs nothing", a.name, reason)
				return .Failed
			}
		}
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
		if a.unavailable != nil {
			if reason := a.unavailable(); reason != "" {
				fmt.fprintf(cfg.out, "%s: skipped: %s\n", a.name, reason)
				t.failed = true
				continue
			}
		}
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
