// ravnix-dict: one dictionary of custom words for every tool that keeps a
// word list (README.md). add and remove edit the dictionary file, list
// prints it, and sync exchanges its words with the tools' lists.
package ravnix_dict

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"

EX_USAGE :: 64

// LOCK_WAIT_MS is how long a run waits for another to finish: a sync that
// stops and starts a tool takes a few seconds.
LOCK_WAIT_MS :: 60_000

USAGE :: `usage: ravnix-dict [--file PATH] [--state DIR] COMMAND [ARG...]

  add WORD [--lang de,en] [--heard "A;B"]
                       add a word, or the mishearings and languages it lacks
                       (a word without lang= is in every language already)
  remove WORD          remove a word, in any case, from the dictionary here,
                       and from every tool at the next sync
  sync [--adapter NAME] [--allow-empty]
                       take the tools' new words into the dictionary, and
                       give every tool (or NAME) the words it lacks
  list                 print the words, one per line

  --file PATH   the dictionary (default: $RAVNIX_DICT_FILE)
  --state DIR   what sync remembers on this host
                (default: $XDG_STATE_HOME/ravnix-dict, ~/.local/state/ravnix-dict)

A word is removed only in the dictionary: by remove, or by deleting its
line. sync never takes a word out of the dictionary because a tool lacks it.

Exit: 0 done, 1 failed (an adapter, the file, the lock), 64 bad usage.`


// Environment is what run reads from the process's environment.
Environment :: struct {
	file:         string, // RAVNIX_DICT_FILE
	state_home:   string, // XDG_STATE_HOME
	home:         string, // HOME
	lock_wait_ms: int, // 0: LOCK_WAIT_MS
}

usage_error :: proc(errf: ^os.File, format: string, args: ..any) -> int {
	fmt.fprintf(errf, "ravnix-dict: %s\n", fmt.tprintf(format, ..args))
	fmt.fprintln(errf, "run ravnix-dict --help for the usage")
	return EX_USAGE
}

run :: proc(args: []string, env: Environment, list: []Adapter, stdout, stderr: ^os.File) -> int {
	out := stdout if stdout != nil else os.stdout
	errf := stderr if stderr != nil else os.stderr
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.fprintln(errf, "ravnix-dict: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	defer free_all(context.temp_allocator)

	cfg := Config {
		file         = env.file,
		lock_wait_ms = env.lock_wait_ms if env.lock_wait_ms > 0 else LOCK_WAIT_MS,
		out          = out,
		errf         = errf,
	}
	switch {
	case strings.has_prefix(env.state_home, "/"):
		cfg.state = strings.concatenate({env.state_home, "/ravnix-dict"})
	case env.home != "":
		cfg.state = strings.concatenate({env.home, "/.local/state/ravnix-dict"})
	}

	file_given, state_given := false, false
	i := 0
	for ; i < len(args); i += 1 {
		arg := args[i]
		if arg == "-h" || arg == "--help" {
			fmt.fprintln(out, USAGE)
			return 0
		}
		if arg != "--file" && arg != "--state" {
			break
		}
		given := &file_given if arg == "--file" else &state_given
		if given^ {
			return usage_error(errf, "%s given twice", arg)
		}
		if i + 1 >= len(args) || args[i + 1] == "" {
			return usage_error(errf, "%s needs a value", arg)
		}
		i += 1
		given^ = true
		if arg == "--file" {
			cfg.file = args[i]
		} else {
			cfg.state = args[i]
		}
	}
	if i >= len(args) {
		return usage_error(errf, "no command")
	}
	command, rest := args[i], args[i + 1:]

	switch command {
	case "add":
		word, langs, heard, code := add_args(errf, rest)
		if code != 0 {
			return code
		}
		if status, stop := need(cfg, true).?; stop {
			return status
		}
		return run_add(cfg, word, langs, heard)
	case "remove":
		if len(rest) != 1 {
			return usage_error(errf, "remove takes one word")
		}
		if status, stop := need(cfg, true).?; stop {
			return status
		}
		return run_remove(cfg, rest[0])
	case "list":
		if len(rest) != 0 {
			return usage_error(errf, "list takes nothing")
		}
		if status, stop := need(cfg, false).?; stop {
			return status
		}
		return run_list(cfg)
	case "sync":
		only := ""
		allow_empty := false
		for j := 0; j < len(rest); j += 1 {
			switch rest[j] {
			case "--allow-empty":
				allow_empty = true
			case "--adapter":
				if only != "" {
					return usage_error(errf, "--adapter given twice")
				}
				if j + 1 >= len(rest) || rest[j + 1] == "" {
					return usage_error(errf, "--adapter needs a name")
				}
				j += 1
				only = rest[j]
			case:
				return usage_error(errf, "sync takes --adapter NAME and --allow-empty, not %s", rest[j])
			}
		}
		selected := list
		if only != "" {
			selected = nil
			for a, j in list {
				if a.name == only {
					selected = list[j:j + 1]
				}
			}
			if selected == nil {
				names := make([dynamic]string)
				for a in list {
					append(&names, a.name)
				}
				known := strings.join(names[:], ", ") if len(names) > 0 else "none"
				return usage_error(errf, "there is no adapter %s; there are: %s", only, known)
			}
		}
		if status, stop := need(cfg, true).?; stop {
			return status
		}
		return sync(cfg, selected, allow_empty)
	}
	return usage_error(errf, "unknown command %s", command)
}

// need checks that the dictionary is named, and the state when it is
// needed; it returns an exit status when not.
need :: proc(cfg: Config, state: bool) -> Maybe(int) {
	if cfg.file == "" {
		warn(cfg, "no dictionary: set RAVNIX_DICT_FILE or give --file")
		return 1
	}
	if state && cfg.state == "" {
		warn(cfg, "neither XDG_STATE_HOME nor HOME is set, so there is no place for the state (give --state)")
		return 1
	}
	return nil
}

add_args :: proc(errf: ^os.File, args: []string) -> (word: string, langs, heard: []string, code: int) {
	lang_given, heard_given, word_given := false, false, false
	for j := 0; j < len(args); j += 1 {
		arg := args[j]
		switch arg {
		case "--lang", "--heard":
			given := &lang_given if arg == "--lang" else &heard_given
			if given^ {
				code = usage_error(errf, "%s given twice", arg)
				return
			}
			if j + 1 >= len(args) {
				code = usage_error(errf, "%s needs a value", arg)
				return
			}
			given^ = true
			j += 1
			if arg == "--lang" {
				langs, code = split_values(errf, args[j], ",", true)
			} else {
				heard, code = split_values(errf, args[j], ";", false)
			}
			if code != 0 {
				return
			}
		case:
			if strings.has_prefix(arg, "--") {
				code = usage_error(errf, "add takes --lang and --heard, not %s", arg)
				return
			}
			if word_given {
				code = usage_error(errf, "add takes one word; a word with a space is one argument: \"Open WebUI\"")
				return
			}
			word, word_given = arg, true
		}
	}
	if !word_given {
		code = usage_error(errf, "add needs a word")
		return
	}
	if problem := word_problem(word); problem != "" {
		code = usage_error(errf, "%q cannot be added: %s", word, problem)
	}
	return
}

// split_values reads the values of --lang (two letters each) or --heard.
split_values :: proc(errf: ^os.File, text: string, separator: string, lang: bool) -> (values: []string, code: int) {
	out := make([dynamic]string)
	for part in strings.split(text, separator) {
		v := strings.trim_space(part)
		if v == "" {
			continue
		}
		if lang {
			v = strings.to_lower(v)
			if len(v) != 2 || v[0] < 'a' || v[0] > 'z' || v[1] < 'a' || v[1] > 'z' {
				return nil, usage_error(errf, "--lang takes two-letter codes separated by commas (de,en), not %q", part)
			}
		} else if problem := value_problem(v, ';'); problem != "" {
			return nil, usage_error(errf, "--heard %q: %s", part, problem)
		}
		if !contains(out[:], v) {
			append(&out, v)
		}
	}
	if len(out) == 0 {
		return nil, usage_error(errf, "%s is empty", "--lang" if lang else "--heard")
	}
	return out[:], 0
}

// edit runs change on the dictionary under the lock and replaces the file
// with the result, reading it again when it changed in the meantime.
edit :: proc(cfg: Config, change: proc(cfg: Config, d: ^Dictionary, data: rawptr) -> (changed: bool, code: int), data: rawptr) -> int {
	fd, why := lock(cfg.state, cfg.lock_wait_ms)
	if why != "" {
		warn(cfg, "%s", why)
		return 1
	}
	defer unlock(fd)
	for _ in 0 ..< MAX_ATTEMPTS {
		d, text, ok := load(cfg)
		if !ok {
			return 1
		}
		changed, code := change(cfg, &d, data)
		if !changed || code != 0 {
			return code
		}
		result, rwhy := replace_file(cfg.file, serialize(d, context.allocator), text)
		switch result {
		case .Done:
			return 0
		case .Failed:
			warn(cfg, "%s", rwhy)
			return 1
		case .Changed:
		}
	}
	warn(cfg, "%s changed %d times while it was edited; try again", cfg.file, MAX_ATTEMPTS)
	return 1
}

Add :: struct {
	word:  string,
	langs: []string,
	heard: []string,
}

run_add :: proc(cfg: Config, word: string, langs, heard: []string) -> int {
	a := Add{word, langs, heard}
	return edit(cfg, proc(cfg: Config, d: ^Dictionary, data: rawptr) -> (bool, int) {
			a := (^Add)(data)
			spelled := spelling_of(d^, a.word)
			// --lang adds to a word's languages, and never narrows one that
			// is in every language: that is an edit of the file.
			everywhere := spelled != "" && len(a.langs) > 0 && langs_of(d^, a.word, context.temp_allocator).all
			note := "; it is in every language, which --lang does not narrow (restrict it in the file)" if everywhere else ""
			if !add_word(d, a.word, a.langs, a.heard, context.allocator) {
				if spelled != a.word {
					note = fmt.tprintf("%s; it is spelled %s, which an edit of the file changes", note, spelled)
				}
				fmt.fprintf(cfg.out, "%s is already in the dictionary%s\n", a.word, note)
				return false, 0
			}
			fmt.fprintf(cfg.out, "%s %s%s\n", "updated" if spelled != "" else "added", a.word, note)
			return true, 0
		}, &a)
}

run_remove :: proc(cfg: Config, word: string) -> int {
	w := word
	return edit(cfg, proc(cfg: Config, d: ^Dictionary, data: rawptr) -> (bool, int) {
			word := (^string)(data)^
			if !has_word(d^, word) {
				warn(cfg, "%s is not in the dictionary", word)
				return false, 1
			}
			// The record first: a crash before the file is replaced leaves a
			// removal of a word that is still there, which the next sync
			// drops; the other order could lose the removal.
			removed, _, why := read_keys(cfg.state, REMOVED, context.allocator)
			if why != "" {
				warn(cfg, "%s", why)
				return false, 1
			}
			removed[key(word, context.allocator)] = {}
			if why = write_keys(cfg.state, REMOVED, removed, REMOVED_COMMENT); why != "" {
				warn(cfg, "%s", why)
				return false, 1
			}
			n := remove_word(d, word)
			fmt.fprintf(cfg.out, "removed %s (%d %s); the next sync takes it from every tool\n", word, n, "line" if n == 1 else "lines")
			return true, 0
		}, &w)
}

run_list :: proc(cfg: Config) -> int {
	d, _, ok := load(cfg)
	if !ok {
		return 1
	}
	b := strings.builder_make()
	for w in words(d, context.allocator) {
		strings.write_string(&b, w)
		strings.write_byte(&b, '\n')
	}
	fmt.fprint(cfg.out, strings.to_string(b))
	return 0
}

main :: proc() {
	get :: proc(name: string) -> string {
		return os.get_env(name, context.allocator)
	}
	env := Environment {
		file       = get("RAVNIX_DICT_FILE"),
		state_home = get("XDG_STATE_HOME"),
		home       = get("HOME"),
	}
	list, why := adapters(
		Setup {
			names = get("RAVNIX_DICT_ADAPTERS"),
			home = env.home,
			config_home = get("XDG_CONFIG_HOME"),
			data_home = get("XDG_DATA_HOME"),
			handy_settings = get("RAVNIX_DICT_HANDY_SETTINGS"),
			prose_file = get("RAVNIX_DICT_PROSE_FILE"),
			languagetool_server = get("RAVNIX_DICT_LANGUAGETOOL_SERVER"),
			languagetool_user = get("LANGUAGETOOL_USERNAME"),
			languagetool_key = get("LANGUAGETOOL_API_KEY"),
			languagetool_item = get("LANGUAGETOOL_RBW_ITEM"),
		},
	)
	// The key is in the adapter now; nothing ravnix-dict starts (curl, rbw,
	// systemctl) inherits it, as the editor does with it too.
	os.unset_env("LANGUAGETOOL_API_KEY")
	if why != "" {
		fmt.eprintfln("ravnix-dict: %s", why)
		os.exit(1)
	}
	os.exit(run(os.args[1:], env, list, os.stdout, os.stderr))
}
