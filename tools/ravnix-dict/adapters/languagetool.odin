// LanguageTool: the word list of a Premium account, in LanguageTool's cloud
// (../README.md, "LanguageTool"). Its API lists the words a page at a time
// (GET /v2/words, until a page is empty) and adds and deletes one word per request
// (POST /v2/words/add, /v2/words/delete); a write sends only the
// difference to what the last read listed.
//
// The requests go through curl, whose configuration, the API key in it,
// goes to curl on its standard input (curl -q --config -): the key is on
// no command line, in no environment of another process and in no file.
// A message never holds the key.
//
// The credentials are found in the editor's order
// (modules/common/nvim/lua/ravnix_languagetool.lua): LANGUAGETOOL_API_KEY
// and LANGUAGETOOL_USERNAME, then the vault through rbw while it is
// unlocked (the item LANGUAGETOOL_RBW_ITEM names, which the wrapper sets
// from ravnix.dictionary.languagetool.rbwItem: the key is its password,
// the account its username field), then ~/.config/languagetool/credentials.
// A locked vault skips the adapter, since it is a normal state; anything
// else missing or refused is a failure, so a misconfiguration is loud.
package adapters

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode"

// The curl that runs the requests: the store path the package is built
// with (default.nix), or curl on PATH.
CURL :: #config(RAVNIX_DICT_CURL, "curl")

Language_Tool :: struct {
	// The API's address, without /v2.
	server:      string,
	// From the environment, when it gives them.
	user, key:   string,
	rbw:         string,
	rbw_item:    string,
	// The file of the non-secret settings, and the last place a key is
	// looked for.
	credentials: string,
	curl:        string,
	// How long one request may take.
	timeout:     time.Duration,
	// The first wait after a 429 or a 5xx without Retry-After; each next
	// wait is twice the last.
	backoff:     time.Duration,
	// How often a request is tried before it fails.
	tries:       int,
	// How many words a page of the list holds.
	page:        int,
}

LT_SERVER :: "https://api.languagetoolplus.com"
LT_TIMEOUT :: 30 * time.Second
LT_BACKOFF :: 2 * time.Second
LT_TRIES :: 6
LT_PAGE :: 500
// The longest a Retry-After is waited for.
LT_MAX_WAIT :: 60 * time.Second

@(thread_local)
languagetool: Language_Tool

@(private)
Credentials :: struct {
	user, key: string,
	looked:    bool,
	// The vault, the only place left to look, is locked: skipped.
	locked:    bool,
	// What is missing or wrong, for a read to fail with; "" when nothing.
	why:       string,
}

@(thread_local)
lt_credentials: Credentials
@(thread_local)
lt_seen: []string

// languagetool_reset forgets the credentials found and the list read, for
// a new setup (the tests make one each).
languagetool_reset :: proc() {
	lt_credentials = {}
	lt_seen = nil
}

// languagetool_unavailable is "the vault is locked" when the key can only
// come from the vault and it is locked, and "" otherwise. That is the one
// state that skips quietly: a missing item, a missing account, rbw not
// installed or a refused key make the read fail, so that a misconfiguration
// is a failed sync and not a silent one.
languagetool_unavailable :: proc() -> string {
	c := lt_find_credentials()
	return "the vault is locked (unlock the vault first: rbw unlock)" if c.locked else ""
}

@(private)
lt_find_credentials :: proc() -> Credentials {
	if lt_credentials.looked {
		return lt_credentials
	}
	c := Credentials {
		user   = languagetool.user,
		key    = languagetool.key,
		looked = true,
	}
	item := languagetool.rbw_item
	vault := ""
	if c.key == "" && item != "" {
		rbw := languagetool.rbw if languagetool.rbw != "" else "rbw"
		// Only while the vault is unlocked: a locked one would ask for its
		// password, and nobody may be there to give it.
		ran, why := run_program({rbw, "unlocked"}, "", 5 * time.Second, context.allocator)
		switch {
		case why != "":
			vault = why
		case ran.status != 0:
			c.locked = true
		case:
			got, gwhy := run_program({rbw, "get", item}, "", 10 * time.Second, context.allocator)
			if gwhy == "" && got.status == 0 {
				c.key = strings.trim_space(got.output)
			} else {
				vault = fmt.tprintf("the vault has no item %q (ravnix.dictionary.languagetool.rbwItem)", item)
			}
			if c.user == "" && c.key != "" {
				named, nwhy := run_program({rbw, "get", "--field", "username", item}, "", 10 * time.Second, context.allocator)
				if nwhy == "" && named.status == 0 {
					c.user = strings.trim_space(named.output)
				}
			}
		}
	}
	if (c.key == "" || c.user == "") && languagetool.credentials != "" {
		text, _, _ := read_text(languagetool.credentials, 64 * 1024, context.allocator)
		for line in strings.split_lines(text, context.temp_allocator) {
			eq := strings.index_byte(line, '=')
			if eq < 0 || strings.has_prefix(strings.trim_space(line), "#") {
				continue
			}
			k := strings.trim_space(line[:eq])
			v := strings.trim(strings.trim_space(line[eq + 1:]), "\"'")
			if v == "" {
				continue
			}
			if k == "LANGUAGETOOL_API_KEY" && c.key == "" {
				c.key = v
			} else if k == "LANGUAGETOOL_USERNAME" && c.user == "" {
				c.user = v
			}
		}
	}
	switch {
	case c.key == "" && c.locked:
		// Skipped; whether an account is missing shows once it is open.
	case c.key == "" && vault != "":
		c.why = fmt.tprintf("no LanguageTool API key: %s", vault)
	case c.key == "":
		c.why = "no LanguageTool API key: name the vault item whose password it is in ravnix.dictionary.languagetool.rbwItem"
	case c.user == "":
		c.why = "no LanguageTool account name: the vault item has no username; set ravnix.dictionary.languagetool.username"
	}
	if c.why != "" || c.locked {
		c.key, c.user = "", ""
	}
	lt_credentials = c
	return c
}

// scrub is message without the API key.
@(private)
scrub :: proc(message: string) -> string {
	key := lt_credentials.key
	if len(key) < 4 {
		return message
	}
	out, _ := strings.replace_all(message, key, "(the API key)", context.temp_allocator)
	return out
}

// quote is s as a string of curl's configuration file.
@(private)
quote :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
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
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

@(private)
Param :: struct {
	name, value: string,
}

// lt_request sends one request and returns the body of its answer. A 429,
// a 5xx and a connection that broke off are tried again, after the wait
// Retry-After asks for, or a growing one.
@(private)
lt_request :: proc(get: bool, path: string, params: []Param) -> (body: string, why: string) {
	c := lt_find_credentials()
	if c.why != "" {
		return "", c.why
	}
	if c.locked {
		return "", "the vault is locked"
	}
	server := strings.trim_right(languagetool.server if languagetool.server != "" else LT_SERVER, "/")
	timeout := languagetool.timeout if languagetool.timeout > 0 else LT_TIMEOUT
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "silent\nshow-error\nmax-time = %d\n", max(int(timeout / time.Second), 1))
	strings.write_string(&b, "url = ")
	quote(&b, strings.concatenate({server, "/v2/", path}, context.temp_allocator))
	strings.write_byte(&b, '\n')
	if get {
		strings.write_string(&b, "get\n")
	}
	all := make([dynamic]Param, 0, len(params) + 2, context.temp_allocator)
	append(&all, Param{"username", c.user}, Param{"apiKey", c.key})
	append(&all, ..params)
	for p in all {
		strings.write_string(&b, "data-urlencode = ")
		quote(&b, strings.concatenate({p.name, "=", p.value}, context.temp_allocator))
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "write-out = \"\\n%header{retry-after}\\n%{http_code}\"\n")
	config := strings.to_string(b)

	curl := languagetool.curl if languagetool.curl != "" else CURL
	tries := languagetool.tries if languagetool.tries > 0 else LT_TRIES
	wait := languagetool.backoff if languagetool.backoff > 0 else LT_BACKOFF
	for attempt in 1 ..= tries {
		ran, rwhy := run_program({curl, "-q", "--config", "-"}, config, timeout + 5 * time.Second, context.allocator)
		if rwhy != "" {
			return "", rwhy
		}
		again := false
		retry_after := time.Duration(-1)
		if ran.status != 0 {
			// 28 a timeout, 52 no answer, 55 and 56 a connection that broke.
			switch ran.status {
			case 28, 52, 55, 56:
				again = true
				why = fmt.tprintf("curl: %s", strings.trim_space(ran.output))
			case:
				return "", scrub(fmt.tprintf("curl (exit %d): %s", ran.status, strings.trim_space(ran.output)))
			}
		} else {
			out := ran.output
			nl := strings.last_index_byte(out, '\n')
			code_text := out[nl + 1:]
			out = out[:max(nl, 0)]
			nl = strings.last_index_byte(out, '\n')
			retry_text := strings.trim_space(out[nl + 1:])
			body = out[:max(nl, 0)]
			code, _ := strconv.parse_int(code_text, 10)
			if seconds, ok := strconv.parse_int(retry_text, 10); ok && seconds >= 0 {
				retry_after = min(time.Duration(seconds) * time.Second, LT_MAX_WAIT)
			}
			switch {
			case code >= 200 && code < 300:
				return body, ""
			case code == 401 || code == 403:
				return "", fmt.tprintf("LanguageTool refused the account or its API key (HTTP %d)", code)
			case code == 429 || code >= 500:
				again = true
				why = fmt.tprintf("HTTP %d", code)
			case:
				excerpt := strings.trim_space(body)
				if len(excerpt) > 200 {
					excerpt = excerpt[:200]
				}
				return "", scrub(fmt.tprintf("HTTP %d from LanguageTool: %s", code, excerpt))
			}
		}
		if !again || attempt == tries {
			break
		}
		time.sleep(retry_after if retry_after >= 0 else wait)
		wait *= 2
	}
	return "", scrub(fmt.tprintf("LanguageTool did not answer after %d tries, the last with %s", tries, why))
}

languagetool_read :: proc() -> ([]string, Error) {
	lt_seen = nil
	page := languagetool.page if languagetool.page > 0 else LT_PAGE
	words := make([dynamic]string)
	// Until a page comes back empty: a server that gives fewer words than
	// asked for (a cap below the limit) must not end the list early, or
	// every word past the first page would be added again at each sync.
	offset := 0
	for {
		body, why := lt_request(true, "words", {{"offset", fmt.tprint(offset)}, {"limit", fmt.tprint(page)}})
		if why != "" {
			return nil, why
		}
		doc, dwhy := check_document(body)
		if dwhy != "" {
			return nil, fmt.tprintf("LanguageTool's word list %s", dwhy)
		}
		list, found := member(body, doc, "words")
		if !found {
			return nil, "LanguageTool's answer holds no word list"
		}
		got, gwhy := string_array(body, list.value)
		if gwhy != "" {
			return nil, fmt.tprintf("LanguageTool's word list %s", gwhy)
		}
		if len(got) == 0 {
			break
		}
		append(&words, ..got)
		offset += len(got)
	}
	lt_seen = words[:]
	out := make([]string, len(words))
	copy(out, words[:])
	return out, nil
}

// is_phrase reports a word that LanguageTool's list cannot hold: its API
// takes no white space in a word.
is_phrase :: proc(word: string) -> bool {
	for r in word {
		if unicode.is_white_space(r) {
			return true
		}
	}
	return false
}

languagetool_write :: proc(words: []string) -> Error {
	want := make(map[string]struct{}, len(words), context.temp_allocator)
	for w in words {
		want[w] = {}
	}
	have := make(map[string]struct{}, len(lt_seen), context.temp_allocator)
	for w in lt_seen {
		have[w] = {}
	}
	// Deletes first: a word whose spelling changed is deleted in the old
	// one before the new one is added, whether LanguageTool tells the two
	// apart or not.
	for w in lt_seen {
		if w not_in want {
			if _, why := lt_request(false, "words/delete", {{"word", w}}); why != "" {
				return fmt.tprintf("cannot delete %q: %s", w, why)
			}
		}
	}
	for w in words {
		if w in have || is_phrase(w) {
			continue
		}
		have[w] = {}
		if _, why := lt_request(false, "words/add", {{"word", w}}); why != "" {
			return fmt.tprintf("cannot add %q: %s", w, why)
		}
	}
	return nil
}
