// The stand-ins of the flow tests: a homeserver on a loopback port that
// records what it is asked and answers from a script, a vault client and a
// curl that are scripts in a scratch directory, and a socket that plays the
// journal. None of it is a test; the tests are in notify_test.odin.
//
// Everything the server thread owns is allocated with the heap allocator,
// not the test's, so the tracking allocator of a test never sees a pointer
// that crossed a thread.
package ravnix_notify_tests

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import notify ".."

FAKE_RBW :: #directory + "/testdata/fake-rbw"
FAKE_CURL :: #directory + "/testdata/fake-curl"

TOPICS := [?]string{"sessions", "updates", "backups", "builds", "services"}

// ---------------------------------------------------------------------------
// The homeserver

// One answer of the script. The request that is nth takes the nth reply,
// and the last reply stays for every request after that.
Reply :: struct {
	status:      int,
	body:        string,
	delay_ms:    int,
	// Read the request and say nothing, until the server is stopped.
	hang:        bool,
	// Read the request and close the connection.
	close_early: bool,
}

Request :: struct {
	method, target, authorization, content_type, body: string,
	// X-Curlrc, a header only a .curlrc adds.
	x_curlrc:                                          string,
	at:                                                time.Tick,
}

Fake_Server :: struct {
	listener: net.TCP_Socket,
	port:     int,
	worker:   ^thread.Thread,
	stop:     bool,
	script:   []Reply,
	mutex:    sync.Mutex,
	requests: [dynamic]Request,
	// Connections of a reply that hangs: open until the server stops, so
	// the server goes on answering the next ones.
	held:     [dynamic]net.TCP_Socket,
}

OK_REPLY :: Reply {
	status = 200,
	body   = `{"event_id":"$fake:example.org"}`,
}

fake_start :: proc(t: ^testing.T, script: []Reply) -> ^Fake_Server {
	a := runtime.heap_allocator()
	s := new(Fake_Server, a)
	s.script = script
	s.requests = make([dynamic]Request, a)
	s.held = make([dynamic]net.TCP_Socket, a)
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expectf(t, err == nil, "cannot listen on loopback: %v", err) {
		return s
	}
	s.listener = listener
	ep, _ := net.bound_endpoint(listener)
	s.port = ep.port
	testing.expect_value(t, net.set_blocking(listener, false), nil)
	s.worker = thread.create_and_start_with_data(s, serve)
	return s
}

fake_stop :: proc(s: ^Fake_Server) {
	a := runtime.heap_allocator()
	sync.atomic_store(&s.stop, true)
	if s.worker != nil {
		thread.join(s.worker)
		thread.destroy(s.worker)
	}
	net.close(s.listener)
	for c in s.held {
		net.close(c)
	}
	delete(s.held)
	for r in s.requests {
		delete(r.method, a)
		delete(r.target, a)
		delete(r.authorization, a)
		delete(r.content_type, a)
		delete(r.x_curlrc, a)
		delete(r.body, a)
	}
	delete(s.requests)
	free(s, a)
}

// fake_requests is what the server has been asked so far. The strings live
// until fake_stop.
fake_requests :: proc(s: ^Fake_Server) -> []Request {
	sync.guard(&s.mutex)
	return s.requests[:]
}

// free_port is a port nothing listens on: the homeserver that is down.
free_port :: proc(t: ^testing.T) -> int {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, err, nil)
	ep, _ := net.bound_endpoint(listener)
	net.close(listener)
	return ep.port
}

@(private = "file")
serve :: proc(data: rawptr) {
	s := cast(^Fake_Server)data
	context.allocator = runtime.heap_allocator()
	for !sync.atomic_load(&s.stop) {
		client, _, err := net.accept_tcp(s.listener)
		if err != nil {
			time.sleep(time.Millisecond)
			continue
		}
		if !answer(s, client) {
			net.close(client)
		}
	}
}

@(private = "file")
answer :: proc(s: ^Fake_Server, client: net.TCP_Socket) -> (keep: bool) {
	a := context.allocator
	net.set_option(client, .Receive_Timeout, 5 * time.Second)
	buf := make([dynamic]byte, a)
	defer delete(buf)
	chunk: [4096]byte
	head_end := -1
	for head_end < 0 {
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n == 0 {
			return
		}
		append(&buf, ..chunk[:n])
		head_end = strings.index(string(buf[:]), "\r\n\r\n")
	}
	head := string(buf[:head_end])
	lines := strings.split(head, "\r\n", a)
	defer delete(lines, a)
	req: Request
	req.at = time.tick_now()
	line := strings.split(lines[0], " ", a)
	defer delete(line, a)
	if len(line) >= 2 {
		req.method = strings.clone(line[0], a)
		req.target = strings.clone(line[1], a)
	}
	length := 0
	for h in lines[1:] {
		colon := strings.index_byte(h, ':')
		if colon < 0 {
			continue
		}
		name := strings.to_lower(h[:colon], a)
		defer delete(name, a)
		value := strings.trim_space(h[colon + 1:])
		switch name {
		case "authorization":
			req.authorization = strings.clone(value, a)
		case "content-type":
			req.content_type = strings.clone(value, a)
		case "x-curlrc":
			req.x_curlrc = strings.clone(value, a)
		case "content-length":
			length, _ = strconv.parse_int(value)
		}
	}
	body_start := head_end + 4
	for len(buf) - body_start < length {
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n == 0 {
			break
		}
		append(&buf, ..chunk[:n])
	}
	req.body = strings.clone(string(buf[body_start:]), a)

	sync.lock(&s.mutex)
	index := len(s.requests)
	append(&s.requests, req)
	sync.unlock(&s.mutex)

	reply := s.script[min(index, len(s.script) - 1)]
	if reply.close_early {
		return
	}
	if reply.hang {
		append(&s.held, client)
		return true
	}
	if reply.delay_ms > 0 {
		time.sleep(time.Duration(reply.delay_ms) * time.Millisecond)
	}
	response := fmt.aprintf(
		"HTTP/1.1 %d Fake\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		reply.status,
		len(reply.body),
		reply.body,
		allocator = a,
	)
	defer delete(response, a)
	net.send_tcp(client, transmute([]byte)response)
	return false
}

// ---------------------------------------------------------------------------
// The journal

// A datagram socket in the scratch directory, where the tool finds the
// journal. Datagrams are read back with journal_lines.
journal_listen :: proc(t: ^testing.T, path: string) -> linux.Fd {
	fd, errno := linux.socket(.UNIX, .DGRAM, {.CLOEXEC}, {})
	if !testing.expectf(t, errno == .NONE, "cannot make a unix socket: %v", errno) {
		return -1
	}
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if !testing.expectf(t, len(path) < len(addr.sun_path), "the socket path %s is too long", path) {
		return -1
	}
	copy(addr.sun_path[:], path)
	testing.expect_value(t, linux.bind(fd, &addr), linux.Errno.NONE)
	return fd
}

// journal_lines is every datagram that has arrived, one string each.
journal_lines :: proc(fd: linux.Fd) -> []string {
	lines := make([dynamic]string)
	buf: [8192]byte
	for {
		n, errno := linux.recv(fd, buf[:], {.DONTWAIT})
		if errno != .NONE {
			break
		}
		append(&lines, strings.clone(string(buf[:n])))
	}
	return lines[:]
}

journal_lines_destroy :: proc(lines: []string) {
	for l in lines {
		delete(l)
	}
	delete(lines)
}

// ---------------------------------------------------------------------------
// The fixture

// Everything one test needs: a scratch directory with the vault client and
// curl as scripts, the config that points at them and at a homeserver port,
// and a journal socket. Change a field and call fixture_write to apply it.
Fixture :: struct {
	dir:            string,
	config_path:    string,
	journal_path:   string,
	journal:        linux.Fd,
	port:           int,
	rooms:          []string,
	retry_base_ms:  int,
	timeout_secs:   f64,
	rbw_timeout_ms: int,
	// The shell that the vault client's `get` runs, with $1 the item.
	// Standard: every topic has the token tok-<topic>.
	rbw_get:        string,
	locked:         bool,
	homeserver:     string,
	rbw_path:       string,
	curl_path:      string,
}

fixture_make :: proc(t: ^testing.T, port: int) -> (f: Fixture) {
	dir, err := os.make_directory_temp("", "notify-test-*", context.allocator)
	testing.expect_value(t, err, nil)
	f.dir = dir
	f.port = port
	f.homeserver = fmt.aprintf("http://127.0.0.1:%d", port)
	f.rooms = TOPICS[:]
	f.retry_base_ms = 5
	f.timeout_secs = 5
	f.rbw_timeout_ms = 5000
	f.config_path = strings.concatenate({dir, "/config.json"})
	f.journal_path = strings.concatenate({dir, "/journal"})
	f.rbw_path = strings.concatenate({dir, "/rbw"})
	f.curl_path = strings.concatenate({dir, "/curl"})
	testing.expect_value(t, os.symlink(FAKE_RBW, f.rbw_path), nil)
	testing.expect_value(t, os.symlink(FAKE_CURL, f.curl_path), nil)
	f.journal = journal_listen(t, f.journal_path)
	fixture_write(t, &f)
	return
}

fixture_destroy :: proc(f: ^Fixture) {
	linux.close(f.journal)
	os.remove_all(f.dir)
	delete(f.dir)
	delete(f.config_path)
	delete(f.journal_path)
	delete(f.homeserver)
	delete(f.rbw_path)
	delete(f.curl_path)
}

token_of :: proc(topic: string) -> string {
	return strings.concatenate({"tok-", topic})
}

item_of :: proc(topic: string) -> string {
	return strings.concatenate({"Matrix - access token (ravnix-", topic, ")"})
}

room_of :: proc(topic: string) -> string {
	return strings.concatenate({"!room-", topic, ":example.org"})
}

// fixture_write writes the config and the two scripts' case files from the
// fields.
fixture_write :: proc(t: ^testing.T, f: ^Fixture) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(
		&b,
		`{{"homeserver":%q,"rbw":%q,"curl":%q,"retryBaseMs":%d,"timeoutSecs":%g,"rbwTimeoutMs":%d,"rooms":{{`,
		f.homeserver,
		f.rbw_path,
		f.curl_path,
		f.retry_base_ms,
		f.timeout_secs,
		f.rbw_timeout_ms,
	)
	for topic, i in TOPICS {
		room_id := "null"
		has_room := false
		for r in f.rooms {
			has_room ||= r == topic
		}
		item := item_of(topic)
		defer delete(item)
		room := room_of(topic)
		defer delete(room)
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		if has_room {
			fmt.sbprintf(&b, `%q:{{"roomId":%q,"tokenItem":%q}}`, topic, room, item)
		} else {
			fmt.sbprintf(&b, `%q:{{"roomId":%s,"tokenItem":%q}}`, topic, room_id, item)
		}
	}
	strings.write_string(&b, "}}")
	testing.expect_value(t, os.write_entire_file(f.config_path, strings.to_string(b)), nil)

	// The vault client: records its calls, then answers.
	rb := strings.builder_make()
	defer strings.builder_destroy(&rb)
	strings.write_string(&rb, "echo \"$*\" >> \"${0%/*}/rbw-calls\"\n")
	strings.write_string(&rb, "case \"$1\" in\n")
	if f.locked {
		strings.write_string(&rb, "unlocked) echo 'rbw: the vault is locked' >&2; exit 1 ;;\n")
	} else {
		strings.write_string(&rb, "unlocked) exit 0 ;;\n")
	}
	strings.write_string(&rb, "get) shift; [ \"$1\" = -- ] && shift\n")
	if f.rbw_get != "" {
		strings.write_string(&rb, f.rbw_get)
		strings.write_string(&rb, "\n ;;\n")
	} else {
		strings.write_string(&rb, " case \"$1\" in\n")
		for topic in TOPICS {
			item := item_of(topic)
			defer delete(item)
			fmt.sbprintf(&rb, " '%s') printf '%%s\\n' 'tok-%s' ;;\n", item, topic)
		}
		strings.write_string(&rb, " *) echo \"rbw: no entry found: $1\" >&2; exit 1 ;;\n esac ;;\n")
	}
	strings.write_string(&rb, "*) exit 2 ;;\nesac\n")
	rbw_case := strings.concatenate({f.dir, "/rbw-case.sh"})
	defer delete(rbw_case)
	testing.expect_value(t, os.write_entire_file(rbw_case, strings.to_string(rb)), nil)

	// curl: passes everything on to the real one.
	curl_case := strings.concatenate({f.dir, "/curl-case.sh"})
	defer delete(curl_case)
	body := fmt.aprintf("exec '%s' \"$@\"\n", notify.CURL)
	defer delete(body)
	testing.expect_value(t, os.write_entire_file(curl_case, body), nil)
}

// file_in is the text of a file of the scratch directory, "" when there is
// none.
file_in :: proc(f: ^Fixture, name: string) -> string {
	path := strings.concatenate({f.dir, "/", name})
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

// ---------------------------------------------------------------------------
// Running the tool

Ran :: struct {
	code:    int,
	out:     string,
	err:     string,
	elapsed: time.Duration,
}

ran_destroy :: proc(r: Ran) {
	delete(r.out)
	delete(r.err)
}

Run_Options :: struct {
	stdin:          string,
	// Standard input is a directory, which opens and cannot be read.
	stdin_unreadable: bool,
	journal_stream: bool,
	no_journal:     bool,
}

// run_notify runs the whole command in this process, as ravnix-notify
// --config <the fixture's> ARGS, and returns what it printed.
run_notify :: proc(t: ^testing.T, f: ^Fixture, args: []string, opt := Run_Options{}) -> (r: Ran) {
	stdin_path := strings.concatenate({f.dir, "/stdin"})
	defer delete(stdin_path)
	testing.expect_value(t, os.write_entire_file(stdin_path, opt.stdin), nil)
	if opt.stdin_unreadable {
		delete(stdin_path)
		stdin_path = strings.clone(f.dir)
	}
	stdin, oerr := os.open(stdin_path)
	testing.expect_value(t, oerr, nil)
	defer os.close(stdin)

	all := make([dynamic]string)
	defer delete(all)
	append(&all, "--config", f.config_path)
	append(&all, ..args)

	out_b := strings.builder_make()
	err_b := strings.builder_make()
	defer strings.builder_destroy(&out_b)
	defer strings.builder_destroy(&err_b)
	env := notify.Env {
		stdin          = stdin,
		out            = strings.to_writer(&out_b),
		err            = strings.to_writer(&err_b),
		journal_stream = opt.journal_stream,
		journal_socket = f.journal_path if !opt.no_journal else "/nonexistent/journal",
	}
	started := time.tick_now()
	r.code = notify.run(all[:], env)
	r.elapsed = time.tick_diff(started, time.tick_now())
	r.out = strings.clone(strings.to_string(out_b))
	r.err = strings.clone(strings.to_string(err_b))
	return
}
