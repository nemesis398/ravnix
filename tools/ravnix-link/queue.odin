// The queue on muninn, and its delivery to the daemon on huginn.
//
// The queue is the state directory's file queue: one request per line,
// appended and never rewritten while a request in it waits. Beside it,
// acked holds one record per outcome (done, failed, expired), and started
// before a commit runs. A request is pending while acked has no final
// record of its id. Every write is one line under a lock, synced to the
// disk before the writer goes on, so the queue survives a reboot and two
// writers never tear or interleave a line.
//
// Delivery takes the lock deliver.lock, so one process delivers at a time,
// and walks the pending requests in order. Requests for the laptop (open,
// notify, obsidian) are sent one by one, each after the daemon has answered
// the one before; the first that does not get through stops the rest, so
// the order holds. A vault-commit runs here, on muninn, once every Obsidian
// request queued before it has been answered: it waits for those and for
// nothing else.
package ravnix_link

import "base:runtime"
import "core:fmt"
import "core:encoding/json"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// How long things may take, in milliseconds, when the configuration says 0.
DEFAULT_REPLY_TIMEOUT :: 90_000 // the daemon answers within its own limits
// A delivery that holds the lock longer is running: the request is queued,
// and that run or the service sends it.
DEFAULT_LOCK_WAIT :: 5_000
DEFAULT_COMMIT_TIMEOUT :: 120_000 // git and the vault's hooks
DEFAULT_NOTIFY_TIMEOUT :: 60_000 // ravnix-notify, with its retries
// How many outcomes stay in acked when a drained queue is emptied, so a
// client whose request another process delivered still finds its outcome.
KEEP_RECORDS :: 64
// How long a commit waits for the sync to bring the results of the Obsidian
// operations before it: the server's copy syncs every five minutes.
SYNC_WAIT :: 15 * time.Minute
// A failed commit runs again after 15 s, then twice as long each time, at
// most an hour apart, and is given up a day after its first attempt.
COMMIT_RETRY_FIRST :: 15 * time.Second
COMMIT_RETRY_MAX :: time.Hour
COMMIT_GIVE_UP :: 24 * time.Hour
// A request the laptop answers retry (its program is missing) fails after
// this long in the queue.
LAPTOP_RETRY_GIVE_UP :: 6 * time.Hour

// Where things are and what to run. A field left empty or 0 has its
// default; the command fills it from the environment and its options.
Config :: struct {
	socket:             string, // the daemon's socket
	state:              string, // the state directory
	vault:              string, // the vault's git repository (the server)
	git:                string,
	ravnix_notify:      string,
	xdg_open:           string, // the daemon's programs
	notify_send:        string, // the daemon's, and the real one under the wrapper
	obsidian:           string,
	systemd_run:        string, // the daemon starts each program in a scope of its own with it; "" starts them directly
	now:                time.Time, // the clock, for tests; zero is the real one
	stderr:             ^os.File, // where reports go; nil is the process's own
	open_wait_ms:       int,
	idle_ms:            int,
	reply_timeout_ms:   int,
	lock_wait_ms:       int,
	program_timeout_ms: int,
	commit_timeout_ms:  int,
	retry_now:          bool, // run a commit that waits for its next attempt now (flush)
}

// A line of the queue: its request, or why it is none.
Entry :: struct {
	line:    string,
	number:  int, // 1 for the first line
	request: Request,
	why:     string,
	hash:    string, // the id of its skipped record, for a line that is no request
}

Snapshot :: struct {
	entries:    []Entry,
	records:    map[string]Record,
	queue_size: i64,
}

// How a submitted request came out.
Outcome :: enum u8 {
	Done,
	Failed,
	Queued,
	Expired,
	Refused, // it could not even be queued
	Busy, // another run held the delivery's lock; it is queued
	Retrying, // a commit that failed and runs again
	Delivered, // another run resolved it, and its outcome is no longer recorded
}

// What a delivery did.
Flushed :: struct {
	sent, done, failed, expired, pending: int,
	laptop:                               bool, // the daemon answered
	busy:                                 bool, // another delivery held the lock
	outcomes:                             map[string]Record,
}

clock :: proc(cfg: Config) -> time.Time {
	if cfg.now != {} {
		return cfg.now
	}
	return time.now()
}

or_default :: proc(v, d: int) -> int {
	return v if v > 0 else d
}

report :: proc(cfg: Config, format: string, args: ..any) {
	errf := cfg.stderr if cfg.stderr != nil else os.stderr
	msg := fmt.tprintf(format, ..args)
	fmt.fprintf(errf, "ravnix-link: %s\n", msg)
}

state_path :: proc(cfg: Config, name: string) -> string {
	return fmt.tprintf("%s/%s", cfg.state, name)
}

// enqueue appends r to the queue, or says why it cannot.
enqueue :: proc(cfg: Config, r: Request) -> string {
	line, why := encode_request(r, context.temp_allocator)
	if why != "" {
		return why
	}
	if why = ensure_dir(cfg.state); why != "" {
		return why
	}
	return append_line(state_path(cfg, "queue"), line, MAX_QUEUE_BYTES)
}

is_final :: proc(s: Record_Status) -> bool {
	return s != .Started && s != .Retry
}

// read_snapshot reads the queue and the records, into allocator.
read_snapshot :: proc(cfg: Config, allocator := context.allocator) -> (s: Snapshot, why: string) {
	queue: string
	if queue, why = read_state(state_path(cfg, "queue"), allocator); why != "" {
		return
	}
	acked: string
	if acked, why = read_state(state_path(cfg, "acked"), allocator); why != "" {
		return
	}
	s.queue_size = i64(len(queue))
	s.records = make(map[string]Record, allocator)
	rest := acked
	for line in strings.split_lines_iterator(&rest) {
		rec, rwhy := decode_record(line, allocator)
		if rwhy != "" {
			// A record cut short by a crash; the request it was about is
			// still pending, and delivered again, once.
			continue
		}
		old, seen := s.records[rec.id]
		if !seen || !is_final(old.status) {
			s.records[rec.id] = rec
		}
	}
	entries := make([dynamic]Entry, allocator)
	number := 0
	rest = queue
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		if line == "" {
			continue
		}
		e := Entry{line = line, number = number}
		e.request, e.why = decode_request(line, allocator)
		if e.why != "" {
			e.hash = fmt.aprintf("corrupt-%016x", hash.fnv64a(transmute([]u8)line), allocator = allocator)
		}
		append(&entries, e)
	}
	s.entries = entries[:]
	return
}

// pending is the requests of s that wait, in their order, each id once.
pending :: proc(s: Snapshot, allocator := context.allocator) -> []Entry {
	out := make([dynamic]Entry, allocator)
	seen := make(map[string]struct{}, context.temp_allocator)
	for e in s.entries {
		if e.why != "" || e.request.id in seen {
			continue
		}
		seen[e.request.id] = {}
		if rec, ok := s.records[e.request.id]; ok && is_final(rec.status) {
			continue
		}
		append(&out, e)
	}
	return out[:]
}

describe :: proc(r: Request) -> string {
	switch r.kind {
	case .Open:
		return fmt.tprintf("open %s", r.target)
	case .Notify:
		return fmt.tprintf("notify \"%s\"", first_lines(r.summary, 1))
	case .Obsidian:
		switch r.op {
		case .Move:
			return fmt.tprintf("obsidian move path=%s to=%s", r.path, r.to)
		case .Rename:
			return fmt.tprintf("obsidian rename path=%s name=%s", r.path, r.name)
		case .Delete, .None:
			return fmt.tprintf("obsidian %s path=%s", OP_NAMES[r.op], r.path)
		}
	case .Vault_Commit:
		return fmt.tprintf("vault-commit \"%s\"", first_lines(r.message, 1))
	}
	return ""
}

// record writes rec to acked, and keeps it in the delivery's outcomes.
record :: proc(cfg: Config, out: ^Flushed, rec: Record, allocator: runtime.Allocator) -> string {
	why := append_line(state_path(cfg, "acked"), encode_record(rec, context.temp_allocator))
	if is_final(rec.status) {
		out.outcomes[strings.clone(rec.id, allocator)] = Record {
			id     = strings.clone(rec.id, allocator),
			status = rec.status,
			error  = strings.clone(rec.error, allocator),
		}
	}
	return why
}

// note_outcome records rec, and reports when it cannot: the request is then
// delivered again, and the daemon's record keeps it from running twice.
note_outcome :: proc(cfg: Config, out: ^Flushed, rec: Record) {
	if why := record(cfg, out, rec, context.temp_allocator); why != "" {
		report(cfg, "cannot record that %s is %s: %s", rec.id, RECORD_NAMES[rec.status], why)
	}
}

// The environment git runs in: the process's own, in the C locale, so its
// messages are the ones read here.
git_env :: proc() -> []string {
	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 1, context.temp_allocator)
	for kv in environ {
		if !strings.has_prefix(kv, "LC_ALL=") && !strings.has_prefix(kv, "LANGUAGE=") {
			append(&env, kv)
		}
	}
	append(&env, "LC_ALL=C")
	return env[:]
}

// git_head is the vault's HEAD, "" in a repository without a commit yet.
git_head :: proc(cfg: Config, vault: string) -> (head: string, why: string) {
	git := cfg.git if cfg.git != "" else "git"
	ran := run_program({git, "-C", vault, "rev-parse", "--verify", "-q", "HEAD"}, or_default(cfg.commit_timeout_ms, DEFAULT_COMMIT_TIMEOUT), git_env(), allocator = context.temp_allocator)
	if ran.success {
		return strings.trim_space(ran.output), ""
	}
	if ran.exited && ran.code == 1 && strings.trim_space(ran.output) == "" {
		return "", ""
	}
	return "", program_failure("git rev-parse", ran)
}

// normal_message is a commit message as git stores one given with -m:
// without trailing white space on a line, empty lines at its ends, and runs
// of empty lines.
normal_message :: proc(m: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	rest := m
	blank := 0
	any := false
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right_space(line)
		if l == "" {
			blank += 1
			continue
		}
		if any {
			strings.write_string(&b, "\n\n" if blank > 0 else "\n")
		}
		strings.write_string(&b, l)
		any = true
		blank = 0
	}
	return strings.to_string(b)
}

// committed_since says whether a commit after old, up to head, has the
// message: the commit of a run that stopped after git and before its
// record.
committed_since :: proc(cfg: Config, vault, old, head, message: string) -> bool {
	git := cfg.git if cfg.git != "" else "git"
	span := head if old == "" else fmt.tprintf("%s..%s", old, head)
	ran := run_program({git, "-C", vault, "log", "--max-count=1000", "--format=%B%x00", span}, or_default(cfg.commit_timeout_ms, DEFAULT_COMMIT_TIMEOUT), git_env(), allocator = context.temp_allocator)
	if !ran.success {
		return false
	}
	want := normal_message(message)
	rest := ran.output
	for body in strings.split_iterator(&rest, "\x00") {
		if normal_message(body) == want {
			return true
		}
	}
	return false
}

Commit_Result :: enum u8 {
	Committed,
	Nothing, // nothing to commit: the paths are as committed already
	Failed,
}

// run_git_commit commits the request's paths (or what is staged) in vault.
// The paths are literal, so a name with *, ? or [ is that name and no
// pattern.
//
// git add gets only the paths in the work tree, for the new files among
// them. One that is gone (a note renamed, moved or deleted) is left to
// git commit -- PATH, which takes its removal: git add refuses a path that
// is in neither the work tree nor the index, as the old path of a rename
// is once an attempt before has staged its removal. A path git does not
// know at all fails the commit, and it runs again later.
run_git_commit :: proc(cfg: Config, vault: string, r: Request) -> (Commit_Result, string) {
	git := cfg.git if cfg.git != "" else "git"
	timeout := or_default(cfg.commit_timeout_ms, DEFAULT_COMMIT_TIMEOUT)
	env := git_env()
	missing :: proc(output: string) -> bool {
		return strings.contains(output, "pathspec") && strings.contains(output, "did not match any")
	}
	present := make([dynamic]string, context.temp_allocator)
	for p in r.paths {
		st: linux.Stat
		e := linux.lstat(cstr(fmt.tprintf("%s/%s", vault, p)), &st)
		if e != .ENOENT && e != .ENOTDIR {
			append(&present, p)
		}
	}
	if len(present) > 0 {
		argv := make([dynamic]string, context.temp_allocator)
		append(&argv, git, "--literal-pathspecs", "-C", vault, "add", "-A", "--")
		append(&argv, ..present[:])
		ran := run_program(argv[:], timeout, env, allocator = context.temp_allocator)
		if !ran.success {
			if ran.exited && missing(ran.output) {
				return .Failed, fmt.tprintf("a path is not in the vault here (yet): %s", first_lines(ran.output, 1))
			}
			return .Failed, program_failure("git add", ran)
		}
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, git, "--literal-pathspecs", "-C", vault, "commit", "-m", r.message)
	if len(r.paths) > 0 {
		append(&argv, "--")
		append(&argv, ..r.paths)
	}
	ran := run_program(argv[:], timeout, env, allocator = context.temp_allocator)
	if ran.success {
		return .Committed, ""
	}
	if ran.exited && ran.code == 1 {
		o := ran.output
		if strings.contains(o, "nothing to commit") || strings.contains(o, "nothing added to commit") || strings.contains(o, "no changes added to commit") {
			return .Nothing, ""
		}
		if missing(o) {
			return .Failed, fmt.tprintf("a path is not in the vault here (yet): %s", first_lines(o, 1))
		}
	}
	return .Failed, program_failure("git commit", ran)
}

// commit_backoff is the wait before attempt n+1 of a commit after n failed:
// 15 s, twice as long each time, at most an hour.
commit_backoff :: proc(n: int) -> time.Duration {
	d := COMMIT_RETRY_FIRST
	for _ in 1 ..< n {
		d *= 2
		if d >= COMMIT_RETRY_MAX {
			return COMMIT_RETRY_MAX
		}
	}
	return d
}

// give_up records the commit r as failed for good, and lists it in the
// failed file, which status shows and every command warns of.
give_up :: proc(cfg: Config, out: ^Flushed, r: Request, msg: string) {
	out.failed += 1
	report(cfg, "%s failed for good: %s", describe(r), msg)
	note_outcome(cfg, out, Record{id = r.id, status = .Failed, error = msg})
	line := encode_failed(Failed_Commit{id = r.id, message = r.message, at = timestamp(clock(cfg), context.temp_allocator), error = msg}, context.temp_allocator)
	if why := append_line(state_path(cfg, "failed"), line); why != "" {
		report(cfg, "cannot list the failed commit: %s", why)
	}
}

// commit_step runs the commit r, or finds out how an interrupted run of it
// ended, and says whether it is resolved: done, or failed for good. While it
// is not, it and what comes after it in the vault wait.
//
// A run writes started, with the vault's HEAD, before git. A run found
// started is looked into: if HEAD moved to a commit with r's message, it
// happened and is done; otherwise it runs again, which commits nothing a
// second time ("nothing to commit" is done). A failed run is tried again
// after commit_backoff, until COMMIT_GIVE_UP after the first attempt.
commit_step :: proc(cfg: Config, r: Request, rec: Record, has: bool, expects: ^[dynamic]Expectation, out: ^Flushed) -> bool {
	now := clock(cfg)
	vault := cfg.vault
	if vault == "" {
		give_up(cfg, out, r, "no vault is configured here (--vault, ravnix.link.vault)")
		return true
	}
	if has && rec.status == .Retry && !cfg.retry_now {
		if next, ok := parse_timestamp(rec.next); ok && time.diff(now, next) > 0 {
			return false
		}
	}
	// The results of the Obsidian operations queued before it, in this copy
	// of the vault, which the sync brings later than the laptop has them.
	for &x in expects {
		if x.dropped || x.created > r.created || synced(vault, x) {
			continue
		}
		if done, ok := parse_timestamp(x.done); ok && time.diff(done, now) < SYNC_WAIT {
			return false
		}
		x.dropped = true
		report(cfg, "the vault here does not show %s after %d minutes; the commits after it go ahead", x.what, int(SYNC_WAIT / time.Minute))
	}
	head, hwhy := git_head(cfg, vault)
	attempts := rec.attempts if has else 0
	since := rec.since if has && rec.since != "" else timestamp(now, context.temp_allocator)
	if hwhy == "" && has && rec.status == .Started && head != rec.head && committed_since(cfg, vault, rec.head, head, r.message) {
		report(cfg, "%s was committed by a run that stopped before it wrote that down", describe(r))
		out.done += 1
		note_outcome(cfg, out, Record{id = r.id, status = .Done})
		return true
	}
	result: Commit_Result
	failure: string
	if hwhy != "" {
		result, failure = .Failed, hwhy
	} else {
		started := Record{id = r.id, status = .Started, head = head, attempts = attempts + 1, since = since}
		if why := record(cfg, out, started, context.temp_allocator); why != "" {
			// Without it, a run cut short could not be told from one that
			// never started; the commit waits until it can be written.
			report(cfg, "%s waits: cannot record its start: %s", describe(r), why)
			return false
		}
		result, failure = run_git_commit(cfg, vault, r)
	}
	switch result {
	case .Committed, .Nothing:
		out.done += 1
		note_outcome(cfg, out, Record{id = r.id, status = .Done})
		return true
	case .Failed:
	}
	first, _ := parse_timestamp(since)
	if time.diff(first, now) >= COMMIT_GIVE_UP {
		give_up(cfg, out, r, fmt.tprintf("it failed for %d hours, %d times; the last time: %s", int(COMMIT_GIVE_UP / time.Hour), attempts + 1, failure))
		return true
	}
	next := timestamp(time.time_add(now, commit_backoff(attempts + 1)), context.temp_allocator)
	report(cfg, "%s did not commit (attempt %d), and runs again at %s: %s", describe(r), attempts + 1, next, failure)
	note_outcome(cfg, out, Record{id = r.id, status = .Retry, error = failure, head = head, attempts = attempts + 1, since = since, next = next})
	return false
}

// program_failure says how a program that did not succeed ended.
program_failure :: proc(name: string, ran: Program_Run) -> string {
	if ran.why != "" {
		return ran.why
	}
	output := first_lines(ran.output, 20)
	how := fmt.tprintf("%s was killed by signal %d", name, ran.code) if ran.signaled else fmt.tprintf("%s exited with status %d", name, ran.code)
	if output == "" {
		return how
	}
	return fmt.tprintf("%s: %s", how, output)
}

expired :: proc(cfg: Config, r: Request) -> bool {
	created, ok := parse_timestamp(r.created)
	return ok && time.diff(created, clock(cfg)) > NOTIFY_TTL
}

// What an Obsidian operation that the laptop has done must look like in
// the server's copy of the vault before a commit after it runs: gone is
// gone, and present (or alt) is there; a delete has no present. The file
// expect keeps them, one per line, until they show or SYNC_WAIT has passed.
Expectation :: struct {
	id:      string,
	created: string, // the operation's: a commit created at or after it waits
	done:    string, // when the laptop had done it
	what:    string, // the operation, for reports
	gone:    string,
	present: string,
	alt:     string, // the other name it may have (a rename's extension)
	dropped: bool,
}

// expectation_of is what the Obsidian operation r leaves in the vault.
expectation_of :: proc(r: Request, done: string, allocator: runtime.Allocator) -> Expectation {
	x := Expectation {
		id      = r.id,
		created = r.created,
		done    = done,
		what    = strings.clone(describe(r), allocator),
		gone    = r.path,
	}
	slash := strings.last_index_byte(r.path, '/')
	dir := r.path[:slash + 1] if slash >= 0 else ""
	base := r.path[slash + 1:]
	dot := strings.last_index_byte(base, '.')
	ext := base[dot:] if dot > 0 else ""
	#partial switch r.op {
	case .Rename:
		x.present = strings.concatenate({dir, r.name}, allocator)
		if ext != "" && !strings.has_suffix(r.name, ext) {
			x.alt = strings.concatenate({dir, r.name, ext}, allocator)
		}
	case .Move:
		// Into the folder to, or to the path to.
		x.present = strings.concatenate({r.to, "/", base}, allocator)
		x.alt = r.to
	}
	if x.gone == x.present || x.gone == x.alt {
		x.gone = ""
	}
	return x
}

// synced says whether the vault shows x.
synced :: proc(vault: string, x: Expectation) -> bool {
	there :: proc(vault, p: string) -> bool {
		st: linux.Stat
		return linux.lstat(cstr(fmt.tprintf("%s/%s", vault, p)), &st) == .NONE
	}
	if x.gone != "" && there(vault, x.gone) {
		return false
	}
	if x.present == "" {
		return true
	}
	return there(vault, x.present) || x.alt != "" && there(vault, x.alt)
}

encode_expectation :: proc(x: Expectation, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	fields := [?][2]string {
		{"id", x.id},
		{"created", x.created},
		{"done", x.done},
		{"what", x.what},
		{"gone", x.gone},
		{"present", x.present},
		{"alt", x.alt},
	}
	strings.write_byte(&b, '{')
	for f, i in fields {
		if f[1] == "" && i >= 3 {
			continue
		}
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		write_json_string(&b, f[0])
		strings.write_byte(&b, ':')
		write_json_string(&b, f[1], true)
	}
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

decode_expectation :: proc(line: string, allocator: runtime.Allocator) -> (x: Expectation, why: string) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	obj: json.Object
	if obj, why = parse_object(line, &arena); why != "" {
		return
	}
	if extra := only_keys(obj, "id", "created", "done", "what", "gone", "present", "alt"); extra != "" {
		return {}, fmt.tprintf("no field %q", extra)
	}
	targets := [?]^string{&x.id, &x.created, &x.done, &x.what, &x.gone, &x.present, &x.alt}
	names := [?]string{"id", "created", "done", "what", "gone", "present", "alt"}
	for name, i in names {
		if targets[i]^, why = string_field(obj, name, i < 3, allocator); why != "" {
			return {}, why
		}
	}
	return
}

// read_expectations reads the file expect; a line cut short is passed over.
read_expectations :: proc(cfg: Config, allocator: runtime.Allocator) -> (xs: [dynamic]Expectation, why: string) {
	xs = make([dynamic]Expectation, allocator)
	text: string
	if text, why = read_state(state_path(cfg, "expect"), allocator); why != "" {
		return
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if x, xwhy := decode_expectation(line, allocator); xwhy == "" {
			append(&xs, x)
		}
	}
	return
}

// A commit that failed for good, as the file failed lists it until the
// user dismisses it.
Failed_Commit :: struct {
	id, message, at, error: string,
}

encode_failed :: proc(f: Failed_Commit, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"id":`)
	write_json_string(&b, f.id, true)
	strings.write_string(&b, `,"message":`)
	write_json_string(&b, f.message[:min(len(f.message), MAX_LINE / 4)], true)
	strings.write_string(&b, `,"at":`)
	write_json_string(&b, f.at, true)
	strings.write_string(&b, `,"error":`)
	write_json_string(&b, f.error[:min(len(f.error), MAX_LINE / 4)], true)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// read_failed is the failed commits that the file failed lists.
read_failed :: proc(cfg: Config, allocator: runtime.Allocator) -> (list: [dynamic]Failed_Commit, why: string) {
	list = make([dynamic]Failed_Commit, allocator)
	text: string
	if text, why = read_state(state_path(cfg, "failed"), allocator); why != "" {
		return
	}
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		arena: virtual.Arena
		obj, pwhy := parse_object(line, &arena)
		if pwhy == "" {
			f: Failed_Commit
			f.id, _ = string_field(obj, "id", false, allocator)
			f.message, _ = string_field(obj, "message", false, allocator)
			f.at, _ = string_field(obj, "at", false, allocator)
			f.error, _ = string_field(obj, "error", false, allocator)
			append(&list, f)
		}
		virtual.arena_destroy(&arena)
	}
	return
}

// dismiss empties the list of failed commits, under the delivery's lock,
// and says how many it held.
dismiss :: proc(cfg: Config) -> (n: int, why: string) {
	if why = ensure_dir(cfg.state); why != "" {
		return
	}
	lock_fd, lwhy := open_state(state_path(cfg, "deliver.lock"), true)
	if lwhy != "" {
		return 0, lwhy
	}
	defer linux.close(lock_fd)
	if !lock_within(lock_fd, or_default(cfg.lock_wait_ms, DEFAULT_LOCK_WAIT) * 6) {
		return 0, "another ravnix-link run is delivering; try again in a moment"
	}
	defer lock(lock_fd, {.UN})
	list, rwhy := read_failed(cfg, context.temp_allocator)
	if rwhy != "" {
		return 0, rwhy
	}
	if len(list) == 0 {
		return 0, ""
	}
	return len(list), replace_file(state_path(cfg, "failed"), "")
}

// flush delivers what waits, as the header says. It reports on stderr what
// failed and what was skipped; that the laptop is away is no report.
//
// Two orders hold. The requests for the laptop go in the queue's order,
// and the first that does not get through stops those after it. And in the
// vault, Obsidian operations and commits go in the queue's order: one that
// is not resolved (an operation the laptop cannot run yet, a commit that
// waits for the sync or for its next attempt) holds the vault's requests
// after it, but not the opens and notifications.
flush :: proc(cfg: Config) -> (out: Flushed, why: string) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return {}, "there is no memory to deliver"
	}
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	// The outcomes outlive the arena: they are the caller's, in its
	// allocator, as temporary memory.
	out.outcomes = make(map[string]Record, context.temp_allocator)

	if why = ensure_dir(cfg.state); why != "" {
		return
	}
	lock_fd, lwhy := open_state(state_path(cfg, "deliver.lock"), true)
	if lwhy != "" {
		return out, lwhy
	}
	defer linux.close(lock_fd)
	if !lock_within(lock_fd, or_default(cfg.lock_wait_ms, DEFAULT_LOCK_WAIT)) {
		out.busy = true
		return
	}
	defer lock(lock_fd, {.UN})

	snap: Snapshot
	if snap, why = read_snapshot(cfg, a); why != "" {
		return
	}
	expects, rwhy := read_expectations(cfg, a)
	if rwhy != "" {
		report(cfg, "%s; the commits do not wait for the sync", rwhy)
	}
	known := len(expects)
	conn: linux.Fd = -1
	defer hang_up(conn)
	reader := Line_Reader {
		buf = make([]u8, MAX_LINE, a),
	}
	laptop_blocked, vault_blocked := false, false
	seen := make(map[string]struct{}, a)
	reply_timeout := or_default(cfg.reply_timeout_ms, DEFAULT_REPLY_TIMEOUT)
	for e in snap.entries {
		if e.why != "" {
			if _, recorded := snap.records[e.hash]; !recorded {
				report(cfg, "line %d of %s is not a request (%s); it is skipped", e.number, state_path(cfg, "queue"), e.why)
				note_outcome(cfg, &out, Record{id = e.hash, status = .Skipped})
				snap.records[e.hash] = Record{id = e.hash, status = .Skipped}
			}
			continue
		}
		r := e.request
		if r.id in seen {
			continue
		}
		seen[r.id] = {}
		rec, has := snap.records[r.id]
		if has && is_final(rec.status) {
			continue
		}
		if r.kind == .Vault_Commit {
			if vault_blocked {
				out.pending += 1
				continue
			}
			// A commit may take longer than the daemon keeps a quiet
			// connection open; the next request for the laptop dials again.
			hang_up(conn)
			conn = -1
			if !commit_step(cfg, r, rec, has, &expects, &out) {
				vault_blocked = true
				out.pending += 1
			}
			continue
		}
		if r.kind == .Notify && expired(cfg, r) {
			out.expired += 1
			report(cfg, "a notification from %s was not shown: the laptop was away for longer than %d minutes (%s)", r.created, int(NOTIFY_TTL / time.Minute), describe(r))
			note_outcome(cfg, &out, Record{id = r.id, status = .Expired})
			continue
		}
		in_vault := r.kind == .Obsidian
		if in_vault && vault_blocked {
			out.pending += 1
			continue
		}
		if !laptop_blocked && conn < 0 {
			dwhy: string
			conn, dwhy = dial(cfg.socket)
			if dwhy != "" {
				laptop_blocked = true
			}
			reader.fd = conn
			reader.start, reader.end = 0, 0
		}
		if laptop_blocked {
			out.pending += 1
			vault_blocked ||= in_vault
			continue
		}
		line, ewhy := encode_request(r, a)
		if ewhy != "" {
			// It decoded, so it encodes; this is a bug, and the request is
			// let go rather than sent forever.
			out.failed += 1
			note_outcome(cfg, &out, Record{id = r.id, status = .Failed, error = ewhy})
			continue
		}
		reply, xwhy := exchange_with(&reader, line, reply_timeout, a)
		if xwhy == "" && reply.id != r.id {
			xwhy = fmt.tprintf("the laptop answered for %q, not for %s", reply.id, r.id)
		}
		if xwhy != "" {
			// The laptop went away, or answered nonsense: what it did with
			// the request is unknown, so it is sent again later, and the
			// daemon's record of its id keeps it from running twice.
			hang_up(conn)
			conn = -1
			laptop_blocked = true
			out.pending += 1
			vault_blocked ||= in_vault
			continue
		}
		out.laptop = true
		out.sent += 1
		switch reply.status {
		case .Done:
			out.done += 1
			note_outcome(cfg, &out, Record{id = r.id, status = .Done})
			if in_vault {
				x := expectation_of(r, timestamp(clock(cfg), a), a)
				if w := append_line(state_path(cfg, "expect"), encode_expectation(x, context.temp_allocator)); w != "" {
					report(cfg, "cannot write down what %s leaves in the vault, so no later run waits for its sync: %s", describe(r), w)
				}
				append(&expects, x)
			}
		case .Failed:
			out.failed += 1
			report(cfg, "%s failed on the laptop: %s", describe(r), reply.error)
			note_outcome(cfg, &out, Record{id = r.id, status = .Failed, error = reply.error})
		case .Retry:
			created, _ := parse_timestamp(r.created)
			if time.diff(created, clock(cfg)) > LAPTOP_RETRY_GIVE_UP {
				out.failed += 1
				msg := fmt.tprintf("the laptop could not run it for %d hours: %s", int(LAPTOP_RETRY_GIVE_UP / time.Hour), reply.error)
				report(cfg, "%s failed: %s", describe(r), msg)
				note_outcome(cfg, &out, Record{id = r.id, status = .Failed, error = msg})
				continue
			}
			report(cfg, "the laptop cannot run %s yet, and it waits: %s", describe(r), reply.error)
			out.pending += 1
			// A missing obsidian holds the vault's requests, not the opens
			// and notifications; a missing xdg-open or notify-send holds
			// every request for the laptop.
			if in_vault {
				vault_blocked = true
			} else {
				laptop_blocked = true
			}
		}
	}
	// What the vault shows now, or was waited for too long, is no longer
	// waited for.
	keep := make([dynamic]Expectation, a)
	now := clock(cfg)
	for x in expects {
		done, ok := parse_timestamp(x.done)
		if !x.dropped && ok && time.diff(done, now) < SYNC_WAIT && cfg.vault != "" && !synced(cfg.vault, x) {
			append(&keep, x)
		}
	}
	if len(keep) != known || len(expects) != known {
		b := strings.builder_make(a)
		for x in keep {
			strings.write_string(&b, encode_expectation(x, a))
		}
		if w := replace_file(state_path(cfg, "expect"), strings.to_string(b)); w != "" {
			report(cfg, "%s", w)
		}
	}
	if out.pending == 0 {
		compact(cfg, snap.queue_size)
	}
	return
}

// compact empties a queue whose every request is resolved, unless a
// request came in since it was read. The queue goes first: a crash
// between the two leaves records of ids that will not come again. acked
// keeps its last records, for a client that waits to read its own.
compact :: proc(cfg: Config, size_read: i64) {
	queue_path := state_path(cfg, "queue")
	fd, why := open_state(queue_path, true)
	if why != "" {
		report(cfg, "cannot empty the queue: %s", why)
		return
	}
	defer linux.close(fd)
	if lock(fd, {.EX}) != .NONE {
		return
	}
	defer lock(fd, {.UN})
	size, e := file_size(fd)
	if e != .NONE || size != size_read || size == 0 {
		return
	}
	if te := linux.ftruncate(fd, 0); te != .NONE {
		report(cfg, "cannot empty the queue: %s", errno_text(te))
		return
	}
	linux.fsync(fd)

	acked_path := state_path(cfg, "acked")
	afd, awhy := open_state(acked_path, true)
	if awhy != "" {
		report(cfg, "cannot shorten %s: %s", acked_path, awhy)
		return
	}
	defer linux.close(afd)
	if lock(afd, {.EX}) != .NONE {
		return
	}
	defer lock(afd, {.UN})
	data, rwhy := read_fd(afd, context.temp_allocator)
	if rwhy != "" {
		report(cfg, "cannot shorten %s: %s", acked_path, rwhy)
		return
	}
	lines := strings.split_lines(strings.trim_suffix(string(data), "\n"), context.temp_allocator)
	keep := lines[max(0, len(lines) - KEEP_RECORDS):]
	b := strings.builder_make(context.temp_allocator)
	for l in keep {
		if l != "" && !strings.contains(l, `"status":"skipped"`) && !strings.contains(l, `"status":"started"`) && !strings.contains(l, `"status":"retry"`) {
			strings.write_string(&b, l)
			strings.write_byte(&b, '\n')
		}
	}
	if w := replace_file(acked_path, strings.to_string(b)); w != "" {
		report(cfg, "cannot shorten %s: %s", acked_path, w)
	}
}

// submit queues r, delivers what waits, and says how r came out; the
// string is the error of a failed request, why r was refused, or for a
// commit that runs again, when and why.
submit :: proc(cfg: Config, r: Request) -> (Outcome, string) {
	if why := enqueue(cfg, r); why != "" {
		return .Refused, why
	}
	out, why := flush(cfg)
	if why != "" {
		report(cfg, "%s", why)
	}
	return outcome_of(cfg, r.id, out)
}

// outcome_of is how the request id came out, after the delivery out.
outcome_of :: proc(cfg: Config, id: string, out: Flushed) -> (Outcome, string) {
	if out.busy {
		return .Busy, ""
	}
	rec, found := out.outcomes[id]
	queued := true
	if !found {
		snap, swhy := read_snapshot(cfg, context.temp_allocator)
		if swhy == "" {
			rec, found = snap.records[id]
			queued = false
			for e in snap.entries {
				if e.why == "" && e.request.id == id {
					queued = true
					break
				}
			}
		}
	}
	if !found && !queued {
		// Resolved by another run, whose record compaction has dropped.
		return .Delivered, ""
	}
	if found && rec.status == .Retry {
		return .Retrying, fmt.tprintf("%s; it runs again at %s", rec.error, rec.next)
	}
	if !found || !is_final(rec.status) {
		return .Queued, ""
	}
	#partial switch rec.status {
	case .Done:
		return .Done, ""
	case .Expired:
		return .Expired, ""
	}
	return .Failed, rec.error
}

// count_pending is how many requests wait, 0 when the queue cannot be read.
count_pending :: proc(cfg: Config) -> int {
	snap, why := read_snapshot(cfg, context.temp_allocator)
	if why != "" {
		return 0
	}
	n := 0
	for e in snap.entries {
		if e.why == "" {
			if rec, ok := snap.records[e.request.id]; !ok || !is_final(rec.status) {
				n += 1
			}
		}
	}
	return n
}

// Watch is what the delivery service watches: the directory of the socket,
// for the socket alone, and the state directory, for the queue alone. A
// change to anything else there (the acked file, the state directory's
// mode) wakes nothing, or the service's own writes would wake it.
Watch :: struct {
	socket:      linux.Wd,
	socket_name: string,
	state:       linux.Wd,
}

// wakes reads what the inotify descriptor holds and says whether the socket
// or the queue changed, or the kernel dropped events and it may have.
wakes :: proc(ino: linux.Fd, watch: Watch) -> bool {
	HEADER :: size_of(linux.Inotify_Event)
	buf: [4096]u8 = ---
	woken := false
	for {
		got, e := linux.read(ino, buf[:])
		if e != .NONE || got <= 0 {
			return woken
		}
		at := 0
		for at + HEADER <= got {
			ev := (^linux.Inotify_Event)(&buf[at])
			end := at + HEADER + int(ev.len)
			if end > got {
				break
			}
			name := strings.truncate_to_byte(string(buf[at + HEADER:end]), 0)
			switch {
			case .Q_OVERFLOW in ev.mask:
				woken = true
			case ev.wd == watch.socket && name == watch.socket_name:
				woken = true
			case ev.wd == watch.state && name == "queue":
				woken = true
			}
			at = end
		}
	}
}

// deliver is the service on muninn: it delivers what waits whenever the
// socket appears, the queue changes, or a retry is due (after 1 s, then
// twice as long each time, up to a minute), until stop is set. It looks at
// stop at least every max_wait_ms.
deliver :: proc(cfg: Config, stop: ^bool, max_wait_ms: int) {
	if why := ensure_dir(cfg.state); why != "" {
		report(cfg, "%s", why)
	}
	// The descriptor is closed when deliver returns, not at the end of a
	// block: a closed one polls as ready at once, and its number, once
	// another file has it, would have the service read that file's data.
	ino, ie := linux.inotify_init1({.CLOEXEC, .NONBLOCK})
	if ie != .NONE {
		ino = -1
	}
	defer if ino >= 0 {
		linux.close(ino)
	}
	watch := Watch {
		socket = -1,
		state  = -1,
	}
	if ino >= 0 {
		if cfg.socket != "" {
			cut := strings.last_index_byte(cfg.socket, '/')
			dir := cfg.socket[:max(cut, 1)] if cut >= 0 else "."
			watch.socket_name = cfg.socket[cut + 1:]
			watch.socket, _ = linux.inotify_add_watch(ino, cstr(dir), {.CREATE, .MOVED_TO, .ATTRIB})
		}
		watch.state, _ = linux.inotify_add_watch(ino, cstr(cfg.state), {.MODIFY, .CREATE, .MOVED_TO})
	}
	backoff := 1000
	next_try := time.tick_now()
	never := true
	due := true
	for !sync.atomic_load(stop) {
		if due {
			due = false
			if count_pending(cfg) > 0 {
				out, why := flush(cfg)
				if why != "" {
					report(cfg, "%s", why)
				}
				if out.pending > 0 || out.busy {
					next_try = time.tick_add(time.tick_now(), time.Duration(backoff) * time.Millisecond)
					never = false
					backoff = min(backoff * 2, 60_000)
				} else {
					never = true
					backoff = 1000
				}
			} else {
				never = true
			}
			free_all(context.temp_allocator)
		}
		wait := max_wait_ms
		if !never {
			left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), next_try)))
			if left <= 0 {
				due = true
				continue
			}
			wait = min(wait, left)
		}
		if ino >= 0 {
			fds := []linux.Poll_Fd{{fd = ino, events = {.IN}}}
			n, _ := linux.poll(fds, i32(wait))
			if n > 0 && fds[0].revents & {.ERR, .NVAL} != {} {
				// The watch is gone; a retry still comes when it is due.
				linux.close(ino)
				ino = -1
			} else if n > 0 && wakes(ino, watch) {
				due = true
				backoff = 1000
			}
		} else {
			time.sleep(time.Duration(wait) * time.Millisecond)
		}
	}
}
