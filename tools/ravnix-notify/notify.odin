// ravnix-notify posts a message to the Matrix room of a topic, as the
// topic's bot. README.md has the contract; the exit codes are sysexits(3).
package ravnix_notify

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

EX_USAGE :: 64
EX_DATAERR :: 65
EX_IOERR :: 74
EX_UNAVAILABLE :: 69
EX_TEMPFAIL :: 75
EX_PROTOCOL :: 76
EX_NOPERM :: 77
EX_CONFIG :: 78

// A message that does not get through is tried again this often, after
// waiting longer each time (the config's retryBaseMs, doubling), or as long
// as the homeserver says. An answer to wait for longer than MAX_RETRY_AFTER_MS
// is not waited for: the caller, a timer or a person, is a better place to
// retry from.
MAX_RETRIES :: 3
MAX_RETRY_AFTER_MS :: 30000

// The most of an answer that is read. Matrix answers a send with a few dozen
// bytes.
MAX_ANSWER_BYTES :: 1 << 20

// Env is everything run reads from and writes to outside itself, so the
// tests give their own.
Env :: struct {
	stdin:          ^os.File,
	out:            io.Writer,
	err:            io.Writer,
	// Standard error is the journal's stream: its device and inode are the
	// ones in JOURNAL_STREAM (see stderr_is_journal).
	journal_stream: bool,
	// The journal's socket; "" is the system's.
	journal_socket: string,
}

// run is the whole command, for the arguments after the program's name, and
// returns the exit status.
run :: proc(args: []string, env: Env) -> int {
	// Everything the run allocates goes into one arena, freed at its end.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		fmt.wprintln(env.err, "ravnix-notify: there is no memory to run")
		return 1
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	a, perr := parse_args(args)
	if perr != "" {
		return usage_error(env, perr)
	}
	if a.help {
		fmt.wprintln(env.out, HELP)
		return 0
	}

	data, rerr := os.read_entire_file(a.config_path, context.allocator)
	if rerr != nil {
		return fail(env, EX_CONFIG, fmt.aprintf("cannot read the config %s: %s", a.config_path, os.error_string(rerr)))
	}
	cfg, cerr := parse_config(data)
	if cerr != "" {
		return fail(env, EX_CONFIG, fmt.aprintf("the config %s is wrong: %s", a.config_path, cerr))
	}

	room, known := cfg.rooms[a.topic]
	if !known {
		topics := make([dynamic]string)
		for topic in cfg.rooms {
			append(&topics, topic)
		}
		slice.sort(topics[:])
		return usage_error(
			env,
			fmt.aprintf(
				"unknown topic \"%s\"; known topics: %s",
				one_line(a.topic),
				strings.join(topics[:], ", ") if len(topics) > 0 else "none",
			),
		)
	}
	if room.room_id == "" {
		return fail(
			env,
			EX_CONFIG,
			fmt.aprintf("%s: the topic has no room yet (roomId is null in the config); create the room, invite the bot, and set ravnix.matrix.rooms.%s.roomId", a.topic, a.topic),
		)
	}

	message := a.message
	if a.from_stdin {
		text, status := read_message(env.stdin)
		switch status {
		case .Ok:
		case .Too_Big:
			return fail(env, EX_DATAERR, fmt.aprintf("%s: the message on standard input is too large for a Matrix event", a.topic))
		case .Failed:
			return fail(env, EX_IOERR, fmt.aprintf("%s: the message on standard input could not be read to its end, so nothing is sent", a.topic))
		}
		message = strings.trim_space(text)
		if message == "" {
			return usage_error(env, "there is no message on standard input")
		}
	}
	event, eerr := build_event(message)
	switch eerr {
	case .None:
	case .Too_Large:
		return fail(env, EX_DATAERR, fmt.aprintf("%s: the message is too large for a Matrix event (the limit is %d bytes once encoded)", a.topic, MAX_EVENT_BYTES))
	case .Encode:
		return fail(env, EX_DATAERR, fmt.aprintf("%s: the message cannot be encoded", a.topic))
	}

	base := strings.concatenate({cfg.homeserver, "/_matrix/client/v3/rooms/", percent_encode(room.room_id), "/send/m.room.message/"})
	if a.dry_run {
		fmt.wprintf(env.out, "PUT %s<transaction id>\n%s\n", base, event)
		return 0
	}

	token, code := fetch_token(env, cfg, a.topic, room.token_item)
	if code != 0 {
		return code
	}
	// One transaction id for all tries: a retry after an answer that was lost
	// does not post the message again, the homeserver answers it from the
	// first.
	raw: [16]byte
	crypto.rand_bytes(raw[:])
	url := strings.concatenate({base, string(hex.encode(raw[:]))})
	return send(env, cfg, a.topic, url, token, event)
}

usage_error :: proc(env: Env, text: string) -> int {
	fmt.wprintf(env.err, "ravnix-notify: %s\n%s\n", one_line(text), USAGE)
	return EX_USAGE
}

// fail says what went wrong, to stderr and the journal, and returns code.
fail :: proc(env: Env, code: int, text: string) -> int {
	log_line(env, .Error, text)
	return code
}

Read_Status :: enum {
	Ok,
	// More than an event can hold.
	Too_Big,
	// The read failed before the end of the input, so what was read is a
	// cut message.
	Failed,
}

// read_message reads the message from standard input, up to what an event
// can hold. Only the end of the input ends it: a read that fails (EAGAIN on
// an inherited non-blocking pipe, EIO) is not the end, and a message cut
// there is not sent as if it were whole.
read_message :: proc(f: ^os.File) -> (text: string, status: Read_Status) {
	data := make([dynamic]byte)
	buf: [4096]byte
	for {
		n, err := os.read(f, buf[:])
		if n > 0 {
			append(&data, ..buf[:n])
			if len(data) > MAX_EVENT_BYTES {
				return "", .Too_Big
			}
		}
		if err == io.Error.EOF || (err == nil && n == 0) {
			break
		}
		if err != nil {
			return "", .Failed
		}
	}
	return string(data[:]), .Ok
}

// ---------------------------------------------------------------------------
// The token

// fetch_token asks rbw for the bot's access token. It asks whether the vault
// is unlocked first: a locked vault makes rbw ask for the master password
// with a pinentry, on a terminal that a timer or a hook does not have. The
// token is printable ASCII without blanks, and anything else is refused
// instead of passed on to curl. What rbw printed is never said.
fetch_token :: proc(env: Env, cfg: Config, topic, item: string) -> (token: string, code: int) {
	timeout := time.Duration(cfg.rbw_timeout_ms) * time.Millisecond
	unlocked := run_child({cfg.rbw, "unlocked"}, nil, timeout, 64 * 1024)
	if code = rbw_trouble(env, cfg, topic, unlocked); code != 0 {
		return
	}
	if unlocked.exit_code != 0 {
		return "", fail(env, EX_TEMPFAIL, fmt.aprintf("%s: the vault is locked, so the access token cannot be read; unlock it (ai-unlock) and the next message goes out", topic))
	}

	got := run_child({cfg.rbw, "get", "--", item}, nil, timeout, 64 * 1024)
	if code = rbw_trouble(env, cfg, topic, got); code != 0 {
		return
	}
	if got.exit_code != 0 {
		return "", fail(
			env,
			EX_UNAVAILABLE,
			fmt.aprintf("%s: rbw could not read the access token in the item \"%s\": %s", topic, item, first_line(string(got.stderr))),
		)
	}
	value := string(got.stdout)
	value = strings.trim_suffix(value, "\n")
	value = strings.trim_suffix(value, "\r")
	if !is_token(value) {
		return "", fail(
			env,
			EX_UNAVAILABLE,
			fmt.aprintf("%s: the item \"%s\" holds no usable access token (a token is printable ASCII without blanks)", topic, item),
		)
	}
	return value, 0
}

// rbw_trouble reports that rbw could not be run or did not answer, with the
// status to exit with, or 0 when it ran.
rbw_trouble :: proc(env: Env, cfg: Config, topic: string, r: Child_Result) -> int {
	switch {
	case r.start_error != "":
		return fail(env, EX_UNAVAILABLE, fmt.aprintf("%s: cannot run rbw (%s) to read the access token: %s", topic, cfg.rbw, r.start_error))
	case r.timed_out:
		return fail(env, EX_UNAVAILABLE, fmt.aprintf("%s: rbw did not answer within %d ms, so the access token cannot be read", topic, cfg.rbw_timeout_ms))
	case r.too_much:
		return fail(env, EX_UNAVAILABLE, fmt.aprintf("%s: rbw printed far more than an access token", topic))
	}
	return 0
}

is_token :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]byte)s {
		if c <= ' ' || c >= 0x7f {
			return false
		}
	}
	return true
}

first_line :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if i := strings.index_byte(t, '\n'); i >= 0 {
		t = strings.trim_space(t[:i])
	}
	return t if t != "" else "it said nothing"
}

// ---------------------------------------------------------------------------
// The request

Outcome :: enum {
	Sent,
	// Worth another try: the homeserver cannot be reached, or is busy.
	Transient,
	// 401 and 403: the token or the bot's place in the room is refused.
	Refused,
	// An answer that no retry changes.
	Rejected,
	// Neither curl nor the request can be made to run.
	Cannot_Run,
	// curl refuses the homeserver's address.
	Bad_Address,
}

Attempt :: struct {
	outcome:        Outcome,
	// What happened, as a sentence for the log.
	why:            string,
	// How long the homeserver asked to wait; 0 when it did not say.
	retry_after_ms: int,
}

// send posts the event, trying again as MAX_RETRIES and the config say, and
// returns the exit status.
send :: proc(env: Env, cfg: Config, topic, url, token, event: string) -> int {
	for tries := 1; ; tries += 1 {
		attempt := send_once(cfg, url, token, event)
		// An answer that quotes the token back does not get it into a log.
		attempt.why, _ = strings.replace_all(attempt.why, token, "[token]")
		switch attempt.outcome {
		case .Sent:
			return 0
		case .Refused:
			return fail(env, EX_NOPERM, fmt.aprintf("%s: the homeserver refused the bot: %s", topic, attempt.why))
		case .Rejected:
			return fail(env, EX_PROTOCOL, fmt.aprintf("%s: the homeserver did not take the message: %s", topic, attempt.why))
		case .Cannot_Run:
			return fail(env, EX_UNAVAILABLE, fmt.aprintf("%s: %s", topic, attempt.why))
		case .Bad_Address:
			return fail(env, EX_CONFIG, fmt.aprintf("%s: curl refuses the homeserver address: %s", topic, attempt.why))
		case .Transient:
			if tries > MAX_RETRIES {
				return fail(env, EX_TEMPFAIL, fmt.aprintf("%s: giving up after %d tries: %s", topic, tries, attempt.why))
			}
			wait := cfg.retry_base_ms << uint(tries - 1)
			if attempt.retry_after_ms > 0 {
				if attempt.retry_after_ms > MAX_RETRY_AFTER_MS {
					return fail(
						env,
						EX_TEMPFAIL,
						fmt.aprintf("%s: giving up: the homeserver asks to wait %d ms, and this tool waits no longer than %d ms: %s", topic, attempt.retry_after_ms, MAX_RETRY_AFTER_MS, attempt.why),
					)
				}
				wait = attempt.retry_after_ms
			}
			log_line(env, .Warning, fmt.aprintf("%s: retry %d of %d in %d ms: %s", topic, tries, MAX_RETRIES, wait, attempt.why))
			time.sleep(time.Duration(wait) * time.Millisecond)
		}
	}
}

// send_once makes the request with curl. The request, token and all, goes to
// curl on standard input as its config file (curl -K -), so the token is on
// no command line, where any user of the machine could read it, and in no
// file. A value that would end its line in that config, a line break in the
// token say, is refused rather than quoted.
send_once :: proc(cfg: Config, url, token, event: string) -> (a: Attempt) {
	url_q, ok_url := curl_quote(url)
	token_q, ok_token := curl_quote(token)
	event_q, ok_event := curl_quote(event)
	if !(ok_url && ok_token && ok_event) {
		return {.Cannot_Run, "the request holds a control character that curl's config cannot carry", 0}
	}
	secs := cfg.timeout_secs
	request := fmt.aprintf(
		"url = \"%s\"\nrequest = \"PUT\"\nheader = \"Authorization: Bearer %s\"\nheader = \"Content-Type: application/json\"\nheader = \"Accept: application/json\"\ndata-binary = \"%s\"\nuser-agent = \"ravnix-notify\"\nsilent\nshow-error\ngloboff\nmax-time = %g\nconnect-timeout = %g\nproto = \"=http,https\"\nwrite-out = \"\\n%%{{http_code}}\"\n",
		url_q,
		token_q,
		event_q,
		secs,
		min(secs, 10.0),
	)
	// curl's own time limit comes first; this one is for a curl that hangs.
	limit := time.Duration(secs * f64(time.Second)) + 5 * time.Second
	r := run_child({cfg.curl, "-q", "-K", "-"}, transmute([]byte)request, limit, MAX_ANSWER_BYTES + 4096)
	switch {
	case r.start_error != "":
		return {.Cannot_Run, fmt.aprintf("cannot run curl (%s): %s", cfg.curl, r.start_error), 0}
	case r.too_much:
		return {.Rejected, fmt.aprintf("the answer is larger than %d bytes", MAX_ANSWER_BYTES), 0}
	case r.timed_out:
		return {.Transient, fmt.aprintf("curl did not finish within %d s", int(limit / time.Second)), 0}
	case r.exit_code == 1 || r.exit_code == 3:
		return {.Bad_Address, fmt.aprintf("curl exit %d: %s", r.exit_code, first_line(string(r.stderr))), 0}
	case r.exit_code != 0:
		return {.Transient, fmt.aprintf("curl exit %d: %s", r.exit_code, first_line(string(r.stderr))), 0}
	}

	answer := string(r.stdout)
	cut := strings.last_index_byte(answer, '\n')
	status, ok_status := 0, false
	if cut >= 0 {
		status, ok_status = strconv.parse_int(answer[cut + 1:])
	}
	if !ok_status {
		return {.Transient, "curl printed no status", 0}
	}
	errcode, message, retry_after := matrix_error(answer[:cut])
	what := fmt.aprintf("HTTP %d", status)
	if errcode != "" {
		what = fmt.aprintf("%s %s", what, errcode)
	}
	if message != "" {
		what = fmt.aprintf("%s: %s", what, message)
	}
	switch {
	case status >= 200 && status < 300:
		if has_event_id(answer[:cut]) {
			return {.Sent, "", 0}
		}
		// A captive portal or a proxy answers 200 to anything.
		return {.Rejected, fmt.aprintf("%s, and no event_id in the answer", what), 0}
	case status == 401 || status == 403:
		return {.Refused, what, 0}
	case status == 429:
		return {.Transient, what, retry_after}
	case status == 408 || (status >= 500 && status < 600):
		return {.Transient, what, 0}
	}
	return {.Rejected, what, 0}
}

// matrix_error reads the errcode, the error text and the retry_after_ms of
// a Matrix error answer. A body that is not one gives "" and 0 for what is
// missing; a retry_after_ms that is no positive whole number is none.
matrix_error :: proc(body: string) -> (errcode, message: string, retry_after_ms: int) {
	value, err := json.parse(transmute([]byte)body, parse_integers = true)
	if err != .None {
		return
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return
	}
	if s, ok := obj["errcode"].(json.String); ok {
		errcode = string(s)
	}
	if s, ok := obj["error"].(json.String); ok {
		message = string(s)
	}
	#partial switch n in obj["retry_after_ms"] {
	case json.Integer:
		if n > 0 && n < 1 << 40 {
			retry_after_ms = int(n)
		}
	case json.Float:
		if n > 0 && n < 1 << 40 {
			retry_after_ms = int(n)
		}
	}
	return
}

// has_event_id is whether body is a JSON object with a non-empty string
// event_id, the proof that a homeserver took the event.
has_event_id :: proc(body: string) -> bool {
	value, err := json.parse(transmute([]byte)body)
	if err != .None {
		return false
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		return false
	}
	id, is_str := obj["event_id"].(json.String)
	return is_str && len(id) > 0
}
