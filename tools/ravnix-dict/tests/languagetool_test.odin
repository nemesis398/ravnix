// The LanguageTool adapter against a stand-in of LanguageTool's Premium
// words API (GET /v2/words, POST /v2/words/add and /v2/words/delete) on
// 127.0.0.1, through the real curl: the list a page at a time, only the
// difference written, a rate limit (429) waited out, and the API key on
// no command line and in no environment while curl runs.
package ravnix_dict_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import tools "../adapters"

LT_USER :: "alice@lt.test"
// Made up, long enough to be found in a process list.
LT_KEY :: "k3y-0f-th3-t3st-NOT-REAL-7f3a9c"

Fake_LT :: struct {
	mutex:       sync.Mutex,
	arena:       virtual.Arena,
	a:           runtime.Allocator,
	socket:      net.TCP_Socket,
	port:        int,
	thread:      ^thread.Thread,
	done:        bool,
	words:       [dynamic]string,
	// What it was asked, one line per request: "GET offset=0 limit=3",
	// "add Word", "delete Word".
	log:         [dynamic]string,
	// The next this many requests get 429, with retry_after if it is set.
	limited:     int,
	retry_after: string,
	// Every request gets this status, when it is not 0.
	status:      int,
	body:        string,
	// The request is never answered.
	hang:        bool,
	// The most words a page holds, whatever limit asks; 0 is no cap.
	cap:         int,
	// Every page is the first one, whatever offset asks.
	same_page:   bool,
	// The key was found in a process's command line or environment.
	leaked:      string,
	requests:    int,
}

fake_lt_start :: proc(f: ^Fixture) -> ^Fake_LT {
	s := new(Fake_LT, f.a)
	if virtual.arena_init_growing(&s.arena) != nil {
		testing.fail_now(f.t, "no memory for the stand-in")
	}
	s.a = virtual.arena_allocator(&s.arena)
	s.words = make([dynamic]string, s.a)
	s.log = make([dynamic]string, s.a)
	sock, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil {
		testing.fail_now(f.t, "the stand-in cannot listen on 127.0.0.1")
	}
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, serve)
	tools.languagetool_reset()
	tools.languagetool = {
		server  = fmt.aprintf("http://127.0.0.1:%d", s.port, allocator = f.a),
		user    = LT_USER,
		key     = LT_KEY,
		timeout = 3 * time.Second,
		backoff = 10 * time.Millisecond,
		tries   = 4,
		page    = 3,
	}
	return s
}

fake_lt_stop :: proc(s: ^Fake_LT) {
	sync.mutex_lock(&s.mutex)
	s.done = true
	sync.mutex_unlock(&s.mutex)
	// A connection of its own wakes the accept.
	if c, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = s.port}); err == nil {
		net.close(c)
	}
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.socket)
	virtual.arena_destroy(&s.arena)
}

fake_lt_set :: proc(s: ^Fake_LT, words: ..string) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	clear(&s.words)
	for w in words {
		append(&s.words, strings.clone(w, s.a))
	}
}

// fake_lt_answer sets how the stand-in answers: limited requests get 429
// (with retry_after), then every request gets status and body (0: as the
// API would), or none at all (hang).
fake_lt_answer :: proc(s: ^Fake_LT, limited := 0, retry_after := "", status := 0, body := "", hang := false) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	s.limited, s.retry_after, s.status, s.body, s.hang = limited, retry_after, status, body, hang
}

fake_lt_seen :: proc(s: ^Fake_LT) -> (requests: int, leaked: string) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return s.requests, s.leaked
}

fake_lt_words :: proc(f: ^Fixture, s: ^Fake_LT) -> string {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return strings.join(s.words[:], "|", f.a)
}

fake_lt_log :: proc(f: ^Fixture, s: ^Fake_LT) -> string {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	return strings.join(s.log[:], "\n", f.a)
}

serve :: proc(s: ^Fake_LT) {
	context.allocator = s.a
	context.temp_allocator = s.a
	for {
		client, _, err := net.accept_tcp(s.socket)
		sync.mutex_lock(&s.mutex)
		done := s.done
		sync.mutex_unlock(&s.mutex)
		if done {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			continue
		}
		handle(s, client)
		net.close(client)
	}
}

// form decodes name=value pairs, as a query or an urlencoded body.
form :: proc(text: string) -> map[string]string {
	out := make(map[string]string)
	for pair in strings.split(text, "&") {
		eq := strings.index_byte(pair, '=')
		if eq < 0 {
			continue
		}
		decode :: proc(s: string) -> string {
			plus, _ := strings.replace_all(s, "+", " ")
			v, _ := net.percent_decode(plus)
			return v
		}
		out[decode(pair[:eq])] = decode(pair[eq + 1:])
	}
	return out
}

handle :: proc(s: ^Fake_LT, client: net.TCP_Socket) {
	buf := make([dynamic]u8)
	chunk: [4096]u8
	head_end := -1
	length := 0
	for {
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n == 0 {
			return
		}
		append(&buf, ..chunk[:n])
		text := string(buf[:])
		if head_end < 0 {
			head_end = strings.index(text, "\r\n\r\n")
			if head_end >= 0 {
				for line in strings.split(text[:head_end], "\r\n") {
					if strings.has_prefix(strings.to_lower(line), "content-length:") {
						length, _ = strconv.parse_int(strings.trim_space(line[len("content-length:"):]))
					}
				}
			}
		}
		if head_end >= 0 && len(buf) >= head_end + 4 + length {
			break
		}
	}
	text := string(buf[:])
	request_line := text[:strings.index(text, "\r\n")]
	parts := strings.split(request_line, " ")
	method, target := parts[0], parts[1]
	path, query := target, ""
	if q := strings.index_byte(target, '?'); q >= 0 {
		path, query = target[:q], target[q + 1:]
	}
	params := form(query if method == "GET" else text[head_end + 4:])

	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	s.requests += 1
	// While curl waits for the answer: is the key in what anyone can list?
	if s.leaked == "" {
		s.leaked = find_key_in_processes()
	}
	status := 200
	body := ""
	retry := ""
	switch {
	case s.hang:
		sync.mutex_unlock(&s.mutex)
		for {
			time.sleep(20 * time.Millisecond)
			sync.mutex_lock(&s.mutex)
			if s.done {
				return
			}
			sync.mutex_unlock(&s.mutex)
		}
	case s.limited > 0:
		s.limited -= 1
		status, body, retry = 429, `{"message":"Too many requests"}`, s.retry_after
	case s.status != 0:
		status, body = s.status, s.body
	case params["username"] != LT_USER || params["apiKey"] != LT_KEY:
		status, body = 403, `{"message":"Invalid credentials"}`
	case method == "GET" && path == "/v2/words":
		offset, _ := strconv.parse_int(params["offset"])
		limit, _ := strconv.parse_int(params["limit"])
		append(&s.log, fmt.aprintf("GET offset=%d limit=%d", offset, limit))
		if s.cap > 0 {
			limit = min(limit, s.cap)
		}
		if s.same_page {
			offset = 0
		}
		b := strings.builder_make()
		strings.write_string(&b, `{"words": [`)
		for i in offset ..< min(offset + limit, len(s.words)) {
			if i > offset {
				strings.write_string(&b, ", ")
			}
			tools.encode_string(&b, s.words[i])
		}
		strings.write_string(&b, "]}")
		body = strings.to_string(b)
	case method == "POST" && path == "/v2/words/add":
		w := params["word"]
		append(&s.log, fmt.aprintf("add %s", w))
		added := !contains_word(s.words[:], w)
		if added {
			append(&s.words, w)
		}
		body = fmt.aprintf(`{{"added": %v}}`, added)
	case method == "POST" && path == "/v2/words/delete":
		w := params["word"]
		append(&s.log, fmt.aprintf("delete %s", w))
		deleted := false
		for x, i in s.words {
			if x == w {
				ordered_remove(&s.words, i)
				deleted = true
				break
			}
		}
		body = fmt.aprintf(`{{"deleted": %v}}`, deleted)
	case:
		status, body = 404, `{"message":"no such path"}`
	}
	head := fmt.aprintf("HTTP/1.1 %d X\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n", status, len(body))
	if retry != "" {
		head = fmt.aprintf("%sRetry-After: %s\r\n", head, retry)
	}
	answer := fmt.aprintf("%s\r\n%s", head, body)
	_, _ = net.send_tcp(client, transmute([]u8)answer)
}

contains_word :: proc(list: []string, w: string) -> bool {
	for x in list {
		if x == w {
			return true
		}
	}
	return false
}

// find_key_in_processes names a process whose command line or environment
// holds the key.
find_key_in_processes :: proc() -> string {
	for pid in tools.process_ids() {
		for what in ([]string{"cmdline", "environ"}) {
			data, rerr := os.read_entire_file(fmt.aprintf("/proc/%d/%s", pid, what), context.allocator)
			if rerr == nil && strings.contains(string(data), LT_KEY) {
				return fmt.aprintf("process %d's %s", pid, what)
			}
		}
	}
	return ""
}

@(test)
languagetool_lists_every_page :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_set(s, "a", "b", "c", "d", "e", "f", "g")
	words, err := tools.languagetool_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.join(words, "|"), "a|b|c|d|e|f|g")
	// It asks until a page comes back empty.
	testing.expect_value(t, fake_lt_log(f, s), "GET offset=0 limit=3\nGET offset=3 limit=3\nGET offset=6 limit=3\nGET offset=7 limit=3")
	// A server that gives fewer words than asked for, a page at a time:
	// every word is read all the same, the next page where the last ended.
	sync.mutex_lock(&s.mutex)
	s.cap = 2
	clear(&s.log)
	sync.mutex_unlock(&s.mutex)
	words, err = tools.languagetool_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, strings.join(words, "|"), "a|b|c|d|e|f|g")
	testing.expect_value(t, fake_lt_log(f, s), "GET offset=0 limit=3\nGET offset=2 limit=3\nGET offset=4 limit=3\nGET offset=6 limit=3\nGET offset=7 limit=3")
	_, leaked := fake_lt_seen(s)
	testing.expect_value(t, leaked, "")
}

@(test)
languagetool_gives_up_on_a_list_that_does_not_end :: proc(t: ^testing.T) {
	// A server that ignores the offset gives the first page again and
	// again: the paging stops after its most pages, with one line.
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_set(s, "a", "b", "c", "d")
	sync.mutex_lock(&s.mutex)
	s.same_page = true
	sync.mutex_unlock(&s.mutex)
	tools.languagetool.max_pages = 5
	_, err := tools.languagetool_read()
	message, failed := err.?
	testing.expectf(t, failed && strings.contains(message, "did not end after 5 pages") && !strings.contains(message, "\n"), "%v", err)
	requests, _ := fake_lt_seen(s)
	testing.expect_value(t, requests, 5)
	// The default is far above any real list.
	testing.expect(t, tools.LT_MAX_PAGES * tools.LT_PAGE >= 100_000)
}

@(test)
languagetool_writes_only_the_difference :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_set(s, "keep", "gone", "github")
	_, err := tools.languagetool_read()
	testing.expect_value(t, err, nil)
	words := []string{"keep", "GitHub", "Open WebUI", "neu&mehr=+%", `back\slash"quote`, "Ärger"}
	testing.expect_value(t, tools.languagetool_write(words), nil)
	// Deleted first, then added; a phrase stays out, which the API refuses.
	testing.expect_value(t, fake_lt_log(f, s), "GET offset=0 limit=3\nGET offset=3 limit=3\ndelete gone\ndelete github\nadd GitHub\nadd neu&mehr=+%\nadd back\\slash\"quote\nadd Ärger")
	testing.expect_value(t, fake_lt_words(f, s), "keep|GitHub|neu&mehr=+%|back\\slash\"quote|Ärger")
	_, leaked := fake_lt_seen(s)
	testing.expect_value(t, leaked, "")
	// In step: no request but the list.
	_, _ = tools.languagetool_read()
	before, _ := fake_lt_seen(s)
	testing.expect_value(t, tools.languagetool_write(words), nil)
	after, _ := fake_lt_seen(s)
	testing.expect_value(t, after, before)
}

@(test)
languagetool_waits_out_a_rate_limit :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_set(s, "a")
	_, _ = tools.languagetool_read()
	// Twice 429, the first with Retry-After: 1, then the add goes through.
	fake_lt_answer(s, limited = 2, retry_after = "1")
	start := time.tick_now()
	testing.expect_value(t, tools.languagetool_write({"a", "b"}), nil)
	waited := time.tick_since(start)
	testing.expect_value(t, fake_lt_words(f, s), "a|b")
	testing.expectf(t, waited >= 2 * time.Second, "Retry-After is waited for: %v", waited)
	// Without Retry-After the wait grows from the backoff.
	fake_lt_answer(s, limited = 3)
	_, err := tools.languagetool_read()
	testing.expect_value(t, err, nil)
}

@(test)
languagetool_gives_up_on_a_limit_that_stays :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_answer(s, limited = 100)
	_, err := tools.languagetool_read()
	message, failed := err.?
	testing.expectf(t, failed && strings.contains(message, "4 tries") && strings.contains(message, "429"), "%v", err)
	requests, _ := fake_lt_seen(s)
	testing.expect_value(t, requests, 4)
	// A server error is tried again too, and also given up on.
	fake_lt_answer(s, status = 503, body = "down")
	_, err = tools.languagetool_read()
	message, failed = err.?
	testing.expectf(t, failed && strings.contains(message, "503"), "%v", err)
}

@(test)
languagetool_names_a_refusal_without_the_key :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	tools.languagetool.key = "a-wrong-key-of-some-length"
	_, err := tools.languagetool_read()
	message, failed := err.?
	testing.expectf(t, failed && strings.contains(message, "403") && !strings.contains(message, "a-wrong-key"), "%v", err)
	// A server that repeats the key in its answer: the message drops it.
	tools.languagetool_reset()
	tools.languagetool.key = LT_KEY
	fake_lt_answer(s, status = 400, body = fmt.aprintf(`{{"message":"bad request for key %s"}}`, LT_KEY))
	_, err = tools.languagetool_read()
	message, failed = err.?
	testing.expectf(t, failed && strings.contains(message, "400") && !strings.contains(message, LT_KEY), "%v", err)
}

@(test)
languagetool_refuses_an_answer_that_is_no_word_list :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	for body in ([]string{"<html>maintenance</html>", `{"words": "a"}`, `{"other": []}`, `{"words": [1]}`}) {
		fake_lt_answer(s, status = 200, body = body)
		_, err := tools.languagetool_read()
		testing.expectf(t, err != nil, "%q is read as a list", body)
	}
}

@(test)
languagetool_stops_waiting_for_a_server_that_does_not_answer :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	tools.languagetool.timeout = time.Second
	tools.languagetool.tries = 2
	fake_lt_answer(s, hang = true)
	start := time.tick_now()
	_, err := tools.languagetool_read()
	testing.expect(t, err != nil)
	testing.expectf(t, time.tick_since(start) < 10 * time.Second, "it gave up in %v", time.tick_since(start))
	// Nothing listens: an error at once, not a wait.
	tools.languagetool.server = "http://127.0.0.1:1"
	_, err = tools.languagetool_read()
	testing.expect(t, err != nil)
}

// lt_vault makes a stand-in rbw in its own directory and points the
// adapter at it, with no credentials of its own.
lt_vault :: proc(f: ^Fixture, unlocked: bool, key, user: string) -> string {
	dir := join(f, "vault")
	testing.expect_value(f.t, os.make_directory(dir), nil)
	tools.languagetool_reset()
	tools.languagetool.user, tools.languagetool.key = "", ""
	tools.languagetool.rbw = link(f, dir, "rbw")
	tools.languagetool.rbw_item = "LanguageTool - test"
	tools.languagetool.credentials = join(f, "credentials")
	write_file(f, strings.concatenate({dir, "/rbw-item"}, f.a), "LanguageTool - test")
	if unlocked {
		write_file(f, strings.concatenate({dir, "/rbw-unlocked"}, f.a), "")
	}
	if key != "" {
		write_file(f, strings.concatenate({dir, "/rbw-key"}, f.a), key)
	}
	if user != "" {
		write_file(f, strings.concatenate({dir, "/rbw-user"}, f.a), user)
	}
	return dir
}

@(test)
languagetool_finds_its_credentials_in_the_vault_and_the_file :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)
	fake_lt_set(s, "a")

	// Unlocked: the key and the account from the vault's item.
	dir := lt_vault(f, true, LT_KEY, LT_USER)
	testing.expect_value(t, tools.languagetool_unavailable(), "")
	words, err := tools.languagetool_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(words), 1)
	_, leaked := fake_lt_seen(s)
	testing.expect_value(t, leaked, "")
	log := read_file(f, strings.concatenate({dir, "/rbw-log"}, f.a))
	testing.expect_value(t, log, "unlocked\nget LanguageTool - test\nget --field username LanguageTool - test\n")

	// The item has no username: the account from the option, or the file.
	dir = lt_vault_again(f, true, LT_KEY, "")
	tools.languagetool.user = LT_USER
	_, err = tools.languagetool_read()
	testing.expect_value(t, err, nil)
	dir = lt_vault_again(f, true, LT_KEY, "")
	write_file(f, tools.languagetool.credentials, "# not a secret\nLANGUAGETOOL_USERNAME = \"alice@lt.test\"\n")
	_, err = tools.languagetool_read()
	testing.expect_value(t, err, nil)
	os.remove(tools.languagetool.credentials)

	// Locked, with the item named: the credentials file is the fallback,
	// in the order env, vault, file. The vault is asked only whether it is
	// unlocked.
	dir = lt_vault_again(f, false, LT_KEY, LT_USER)
	write_file(f, tools.languagetool.credentials, fmt.aprintf("LANGUAGETOOL_API_KEY=%s\nLANGUAGETOOL_USERNAME=%s\n", LT_KEY, LT_USER))
	testing.expect_value(t, tools.languagetool_unavailable(), "")
	words, err = tools.languagetool_read()
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(words), 1)
	testing.expect_value(t, read_file(f, strings.concatenate({dir, "/rbw-log"}, f.a)), "unlocked\n")
	// A file with no key leaves the vault locked: skipped, as before.
	dir = lt_vault_again(f, false, LT_KEY, LT_USER)
	write_file(f, tools.languagetool.credentials, "LANGUAGETOOL_USERNAME=alice@lt.test\n")
	testing.expect(t, strings.contains(tools.languagetool_unavailable(), "locked"))
	os.remove(tools.languagetool.credentials)
}

// lt_fails says that the credentials make the adapter fail, not skip, with
// one line that holds each of says and not the key.
lt_fails :: proc(t: ^testing.T, says: ..string, loc := #caller_location) {
	testing.expect_value(t, tools.languagetool_unavailable(), "", loc = loc)
	_, err := tools.languagetool_read()
	message, failed := err.?
	testing.expectf(t, failed, "the read fails", loc = loc)
	for s in says {
		testing.expectf(t, strings.contains(message, s), "%q says %q", message, s, loc = loc)
	}
	testing.expectf(t, !strings.contains(message, "\n") && !strings.contains(message, LT_KEY), "%q is one line without the key", message, loc = loc)
}

@(test)
only_a_locked_vault_skips_languagetool_quietly :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	context.allocator = f.a
	s := fake_lt_start(f)
	defer fake_lt_stop(s)

	// Locked: skipped, and the vault is asked nothing but whether it is.
	dir := lt_vault(f, false, LT_KEY, LT_USER)
	why := tools.languagetool_unavailable()
	testing.expectf(t, strings.contains(why, "locked") && strings.contains(why, "unlock the vault first"), "%q", why)
	testing.expect_value(t, read_file(f, strings.concatenate({dir, "/rbw-log"}, f.a)), "unlocked\n")

	// Everything else is a misconfiguration, and fails loudly.
	// The item the option names is not in the vault.
	dir = lt_vault_again(f, true, LT_KEY, LT_USER)
	tools.languagetool.rbw_item = "LanguageTool - elsewhere"
	lt_fails(t, "LanguageTool - elsewhere", "ravnix.dictionary.languagetool.rbwItem")
	// The item holds no account, and neither the option nor the file does.
	dir = lt_vault_again(f, true, LT_KEY, "")
	lt_fails(t, "account", "ravnix.dictionary.languagetool.username")
	// No item named at all, and no key anywhere: rbw is not even asked.
	dir = lt_vault_again(f, true, LT_KEY, LT_USER)
	tools.languagetool.rbw_item = ""
	lt_fails(t, "API key", "ravnix.dictionary.languagetool.rbwItem")
	testing.expect_value(t, read_file(f, strings.concatenate({dir, "/rbw-log"}, f.a)), "")
	// No rbw installed.
	dir = lt_vault_again(f, true, LT_KEY, LT_USER)
	tools.languagetool.rbw = join(f, "no-such-rbw")
	lt_fails(t, "not installed")
	// A key the server refuses.
	dir = lt_vault_again(f, true, "a-refused-key-of-some-length", LT_USER)
	lt_fails(t, "403")
}

lt_vault_again :: proc(f: ^Fixture, unlocked: bool, key, user: string) -> string {
	os.remove_all(join(f, "vault"))
	return lt_vault(f, unlocked, key, user)
}
