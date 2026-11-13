// The tests of a commit asked for on the laptop: the laptop's vault-commit
// sends it to the server's receive, through the program of --forward (ssh,
// in the module), with the bytes of each path as the laptop has them; the
// server queues it, and the commit waits until its copy of the vault, which
// the sync brings later, has those bytes.
package ravnix_link_tests

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import link ".."

// The SHA-256 of "text\n", the default of note, and of "neu\n".
SUM_TEXT :: "b9e68e1bea3e5b19ca6b2f98b73a54b73daafaa250484902e09982e07a12e733"
SUM_NEU :: "7148855a83bde71c263a00c43f3deb63b08d4eb2ad96bf1d033b9a5ba750ffd5"

laptop_commit :: proc(f: ^Fixture, message: string, paths: []string, sums: []string) -> link.Request {
	r := commit_request(f, message, ..paths)
	r.vault = "/home/alice/laptop-vault"
	s := make([]string, len(sums), f.a)
	copy(s, sums)
	r.sums = s
	return r
}

encoded :: proc(f: ^Fixture, r: link.Request) -> string {
	line, why := link.encode_request(r, f.a)
	testing.expect_value(f.t, why, "")
	return line
}

// receive runs the server's receive with input on its standard input.
receive :: proc(f: ^Fixture, input: string, vault := true) -> Ran {
	in_path := join(f, "receive-stdin")
	write_file(f, in_path, input)
	stdin, err := os.open(in_path)
	testing.expect_value(f.t, err, nil)
	defer os.close(stdin)
	env := environment(f)
	env.stdin = stdin
	all := make([dynamic]string, f.a)
	append(&all, "--socket", f.socket, "--state", f.client.state, "--git", f.client.git)
	if vault {
		append(&all, "--vault", f.vault)
	}
	append(&all, "receive")
	return run_cli(f, env, all[:])
}

reply_in :: proc(f: ^Fixture, out: string) -> link.Reply {
	rep, why := link.decode_reply(strings.trim_space(out), f.a)
	testing.expectf(f.t, why == "", "%q is no reply: %s", out, why)
	return rep
}

// laptop runs vault-commit as the laptop's ravnix-link: its own copy of
// the vault, and --forward, the stand-in forward.
laptop :: proc(f: ^Fixture, args: ..string) -> Ran {
	os.make_directory(join(f, "laptop-vault"))
	all := make([dynamic]string, f.a)
	append(&all, "--state", join(f, "laptop-state"), "--vault", join(f, "laptop-vault"))
	append(&all, "--forward", join(f, "bin", "forward"))
	append(&all, ..args)
	return run_cli(f, environment(f), all[:])
}

laptop_note :: proc(f: ^Fixture, path: string, text := "text\n") {
	full := join(f, "laptop-vault", path)
	if slash := strings.last_index_byte(full, '/'); slash > 0 {
		os.make_directory_all(full[:slash])
	}
	write_file(f, full, text)
}

// FORWARD_ANSWERS is the stand-in forward: it keeps what it read in
// forward-in and answers for the request's id with the status and error
// that the files status and error in bin say (done without them).
FORWARD_ANSWERS :: `[ "$n" = forward ] && {
  cat >"$d/forward-in"
  id=$(sed -n 's/^{"id":"\([^"]*\)".*/\1/p' "$d/forward-in")
  st=done; [ -f "$d/status" ] && st=$(cat "$d/status")
  er=; [ -f "$d/error" ] && er=$(cat "$d/error")
  echo "some words of ssh on stderr" >&2
  printf '{"id":"%s","status":"%s","error":"%s"}\n' "$id" "$st" "$er"
  [ -f "$d/code" ] && exit "$(cat "$d/code")"
  exit 0
}
`

@(test)
a_commit_carries_the_laptops_sums_and_refuses_bad_ones :: proc(t: ^testing.T) {
	r := base_request(.Vault_Commit)
	sums := [?]string{SUM_TEXT, link.NO_FILE}
	r.sums = sums[:]
	back := round_trip(t, r)
	testing.expect_value(t, len(back.sums), 2)
	if len(back.sums) == 2 {
		testing.expect_value(t, back.sums[0], SUM_TEXT)
		testing.expect_value(t, back.sums[1], link.NO_FILE)
	}
	// Without sums, a commit's line is as it was.
	plain, _ := link.encode_request(base_request(.Vault_Commit), context.temp_allocator)
	testing.expect(t, !contains(plain, "sums"), plain)

	one := [?]string{SUM_TEXT}
	upper := [?]string{strings.to_upper(SUM_TEXT, context.temp_allocator), link.NO_FILE}
	short := [?]string{SUM_TEXT[1:], link.NO_FILE}
	empty := [?]string{"", link.NO_FILE}
	for bad in ([][]string{one[:], upper[:], short[:], empty[:]}) {
		b := base_request(.Vault_Commit)
		b.sums = bad
		testing.expectf(t, link.check_request(b) != "", "%v was taken", bad)
	}
	// Sums without paths, and on another kind.
	no_paths := base_request(.Vault_Commit)
	no_paths.paths = nil
	no_paths.sums = one[:]
	testing.expect(t, link.check_request(no_paths) != "")
	open := base_request(.Open)
	open.sums = one[:]
	testing.expect(t, link.check_request(open) != "")

	for line in ([]string {
			`{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","kind":"vault-commit","args":{"vault":"/v","message":"m","paths":["a.md"],"sums":"-"},"created":"2026-11-08T12:00:00Z"}`,
			`{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","kind":"vault-commit","args":{"vault":"/v","message":"m","paths":["a.md"],"sums":[1]},"created":"2026-11-08T12:00:00Z"}`,
			`{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","kind":"vault-commit","args":{"vault":"/v","message":"m","paths":["a.md"],"sums":["-","-"]},"created":"2026-11-08T12:00:00Z"}`,
		}) {
		_, why := link.decode_request(line, context.temp_allocator)
		testing.expectf(t, why != "", "%s was taken", line)
	}
	free_all(context.temp_allocator)
}

// The sync has not brought the laptop's edit of a.md nor its removal of
// b.md: the commit waits, and status says for what; once the vault here
// has both, it runs.
@(test)
a_commit_from_the_laptop_waits_until_the_vault_here_has_its_files :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/a b.md")
	note(f, "Notizen/weg.md")
	commit := laptop_commit(f, "vault: vom Laptop", {"Notizen/a b.md", "Notizen/weg.md"}, {SUM_NEU, link.NO_FILE})
	outcome, _ := link.submit(f.client, commit)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	r := cli(f, "status")
	testing.expect(t, contains(r.out, "waits until the vault here has 2 files as the laptop wrote them"), r.out)

	note(f, "Notizen/a b.md", "neu\n")
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	r = cli(f, "status")
	testing.expect(t, contains(r.out, "waits until the vault here has 1 file as the laptop wrote it"), r.out)

	testing.expect_value(t, os.remove(join(f, "vault", "Notizen", "weg.md")), nil)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, run_order(f), "add commit")
	got := git_runs(f, "commit")
	if len(got) == 1 {
		// The server's vault, not the one the laptop named.
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: vom Laptop|--|Notizen/a b.md|Notizen/weg.md"}, f.a))
	}
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Done)
}

// The sync never brings it: after SYNC_WAIT the commit runs on what is
// there, and says so once.
@(test)
a_commit_from_the_laptop_goes_ahead_after_the_sync_wait :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "a.md")
	base := link.clock(f.client)
	f.client.now = base
	commit := laptop_commit(f, "vault: a", {"a.md"}, {SUM_NEU})
	outcome, _ := link.submit(f.client, commit)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	f.client.now = time.time_add(base, link.SYNC_WAIT - time.Minute)
	link.flush(f.client)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)
	testing.expect(t, contains(stderr_text(f), "goes ahead with what is there"), stderr_text(f))
}

// A file the laptop has, which the sync has not brought here when the wait
// is over: git does not know it, and the commit runs again, as the sync may
// still bring it; once it does, the commit is made.
@(test)
a_file_the_laptop_has_that_git_does_not_know_is_tried_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, strings.concatenate({"v='", f.vault, "'\n", `[ "$n" = git ] && [ "$4" = commit ] && [ ! -e "$v/neu.md" ] && { echo "error: pathspec 'neu.md' did not match any file(s) known to git" >&2; exit 1; }
`}, f.a))
	base := link.clock(f.client)
	f.client.now = base
	commit := laptop_commit(f, "vault: neu", {"neu.md"}, {SUM_NEU})
	expect_enqueued(f, commit)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	note(f, "neu.md", "neu\n")
	f.client.now = time.time_add(base, time.Hour)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.done, 1)
	rec, _ = record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Done)
}

// receive queues the commit and runs no git itself (an ssh session may
// have no agent): the delivery service commits it, in the server's vault.
// Before that, the answer is that it is queued; a request sent again, as a
// laptop that did not get the answer sends it, gets the outcome it had and
// runs nothing twice.
@(test)
receive_queues_a_commit_from_the_laptop_and_answers_it :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/Über – x.md")
	f.client.receive_wait_ms = 300
	commit := laptop_commit(f, "vault: Über\n\nZeile „zwei“", {"Notizen/Über – x.md"}, {SUM_TEXT})
	rep, code := link.receive(f.client, encoded(f, commit))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, rep.id, commit.id)
	testing.expect_value(t, rep.status, link.Status.Retry)
	testing.expect(t, contains(rep.error, "ravnix-link-deliver"), rep.error)
	testing.expect_value(t, len(runs_of(f, "git")), 0)
	testing.expect_value(t, len(queue_lines(f)), 1)

	// The delivery service's run.
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.done, 1)
	got := git_runs(f, "commit")
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: Über\n\nZeile „zwei“|--|Notizen/Über – x.md"}, f.a))
	}
	rep, code = link.receive(f.client, encoded(f, commit))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, rep.status, link.Status.Done)
	link.flush(f.client)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)
}

// The service resolves it while receive waits: receive answers with the
// outcome, done or failed.
@(test)
receive_answers_what_the_service_did :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "a.md")
	stop := false
	worker := thread.create_and_start_with_poly_data2(f, &stop, proc(f: ^Fixture, stop: ^bool) {
			defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
			link.deliver(f.client, stop, 50)
		}, context)
	defer {
		sync.atomic_store(&stop, true)
		thread.join(worker)
		thread.destroy(worker)
	}
	f.client.receive_wait_ms = 20_000
	rep, code := link.receive(f.client, encoded(f, laptop_commit(f, "vault: a", {"a.md"}, {SUM_TEXT})))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, rep.status, link.Status.Done)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)

	note(f, "b.md")
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { echo "hook: kein Commit heute" >&2; exit 1; }` + "\n")
	rep, code = link.receive(f.client, encoded(f, laptop_commit(f, "vault: b", {"b.md"}, {SUM_TEXT})))
	testing.expect_value(t, code, 1)
	testing.expect_value(t, rep.status, link.Status.Failed)
	testing.expect(t, contains(rep.error, "kein Commit heute"), rep.error)
}

@(test)
receive_answers_retry_while_the_sync_has_not_brought_the_files :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	commit := laptop_commit(f, "vault: neu", {"neu.md"}, {SUM_NEU})
	r := receive(f, encoded(f, commit))
	testing.expect_value(t, r.code, 0)
	rep := reply_in(f, r.out)
	testing.expect_value(t, rep.status, link.Status.Retry)
	testing.expect(t, contains(rep.error, "sync"), rep.error)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	testing.expect_value(t, len(queue_lines(f)), 1)
}

@(test)
receive_refuses_what_is_not_a_commit_from_the_laptop :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "a.md")
	open := open_request(f, "https://example.org/")
	plain := commit_request(f, "vault: ohne Summen", "a.md")
	staged := laptop_commit(f, "vault: was gestaged ist", {}, {})
	good := laptop_commit(f, "vault: a", {"a.md"}, {SUM_TEXT})
	cases := []struct {
		input: string,
		vault: bool,
		code:  int,
	} {
		{encoded(f, open), true, 64},
		{encoded(f, plain), true, 64},
		{encoded(f, staged), true, 64},
		{"nonsense\n", true, 64},
		{"", true, 64},
		{strings.repeat("x", link.MAX_LINE + 10, f.a), true, 64},
		{encoded(f, good), false, 64},
	}
	for c in cases {
		r := receive(f, c.input, c.vault)
		testing.expectf(t, r.code == c.code, "%.60q: exit %d, %s", c.input, r.code, r.err)
		rep := reply_in(f, r.out)
		testing.expect_value(t, rep.status, link.Status.Failed)
		testing.expect(t, rep.error != "")
	}
	testing.expect_value(t, len(queue_lines(f)), 0)
	testing.expect_value(t, len(runs_of(f, "git")), 0)
}

@(test)
on_the_laptop_vault_commit_goes_to_the_server_with_the_sums :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, FORWARD_ANSWERS)
	laptop_note(f, "AI/sessions/2026-11-13 Über – Grüße.md")
	r := laptop(f, "vault-commit", "vault: Sitzung\nmit \"Zitat\"", "AI/sessions/2026-11-13 Über – Grüße.md", "AI/weg.md")
	testing.expectf(t, r.code == 0, "exit %d: %s", r.code, r.err)
	testing.expect_value(t, len(runs_of(f, "forward")), 1)
	testing.expect_value(t, len(runs_of(f, "git")), 0)
	line := read_file(f, join(f, "bin", "forward-in"))
	testing.expect_value(t, strings.count(line, "\n"), 1)
	sent, why := link.decode_request(line, f.a)
	testing.expect_value(t, why, "")
	testing.expect_value(t, sent.kind, link.Kind.Vault_Commit)
	testing.expect_value(t, sent.message, "vault: Sitzung\nmit \"Zitat\"")
	testing.expect_value(t, len(sent.paths), 2)
	testing.expect_value(t, len(sent.sums), 2)
	if len(sent.sums) == 2 {
		testing.expect_value(t, sent.paths[0], "AI/sessions/2026-11-13 Über – Grüße.md")
		testing.expect_value(t, sent.sums[0], SUM_TEXT)
		testing.expect_value(t, sent.sums[1], link.NO_FILE)
	}
	// Nothing waits on the laptop: the queue is the server's.
	testing.expect(t, !os.exists(join(f, "laptop-state", "queue")))
}

@(test)
the_laptop_tells_what_the_server_answered :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, FORWARD_ANSWERS)
	laptop_note(f, "a.md")
	write_file(f, join(f, "bin", "status"), "retry")
	write_file(f, join(f, "bin", "error"), "it waits for the sync")
	r := laptop(f, "vault-commit", "m", "a.md")
	testing.expect_value(t, r.code, 0)
	testing.expect(t, contains(r.err, "it waits for the sync"), r.err)
	testing.expect(t, contains(r.err, "queued"), r.err)

	write_file(f, join(f, "bin", "status"), "failed")
	write_file(f, join(f, "bin", "error"), "git refused it")
	r = laptop(f, "vault-commit", "m", "a.md")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "git refused it"), r.err)

	// ssh could not connect: no answer, and its words.
	set_case(f, `[ "$n" = forward ] && { echo "ssh: connect to host ravnix-server port 22: No route to host" >&2; exit 255; }` + "\n")
	r = laptop(f, "vault-commit", "m", "a.md")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "No route to host"), r.err)
	testing.expect(t, contains(r.err, "did not answer"), r.err)

	// An answer for another request is none.
	set_case(f, `[ "$n" = forward ] && { cat >/dev/null; echo '{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","status":"done","error":""}'; exit 0; }` + "\n")
	r = laptop(f, "vault-commit", "m", "a.md")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "did not answer"), r.err)

	os.remove(join(f, "bin", "forward"))
	r = laptop(f, "vault-commit", "m", "a.md")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "forward"), r.err)
}

@(test)
the_laptop_refuses_a_commit_it_cannot_describe :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, FORWARD_ANSWERS)
	laptop_note(f, "Ordner/a.md")
	for bad in ([][]string {
			{"vault-commit", "m"}, // what is staged is the server's
			{"vault-commit", "m", "Ordner"}, // a folder: the files are what the server waits for
			{"vault-commit", "m", "/abs.md"},
			{"vault-commit", "m", "../x.md"},
			{"vault-commit", "", "Ordner/a.md"},
		}) {
		r := laptop(f, ..bad)
		testing.expectf(t, r.code == 64, "%v: exit %d, %s", bad, r.code, r.err)
	}
	testing.expect_value(t, len(runs_of(f, "forward")), 0)
	// Without a vault the laptop cannot say what it has.
	no_vault := []string{"--state", join(f, "laptop-state"), "--forward", join(f, "bin", "forward"), "vault-commit", "m", "Ordner/a.md"}
	r := run_cli(f, environment(f), no_vault)
	testing.expect_value(t, r.code, 64)
	testing.expect(t, contains(r.err, "--vault"), r.err)
	testing.expect_value(t, len(runs_of(f, "forward")), 0)
}

// A file the laptop had that never reaches the vault here under its name
// (renamed or deleted on the laptop before the upload, a name the sync does
// not carry, a conflict copy): after LAPTOP_FILE_WAIT the commit fails for
// good, says which file, tells the laptop, and what waits behind it goes
// ahead, instead of holding the vault's stream for a day.
@(test)
a_laptop_file_that_never_arrives_fails_and_releases_the_stream :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, strings.concatenate({"v='", f.vault, "'\n", `[ "$n" = git ] && [ "$4" = commit ] && [ "$6" = "vault: neu" ] && [ ! -e "$v/neu.md" ] && { echo "error: pathspec 'neu.md' did not match any file(s) known to git" >&2; exit 1; }
`}, f.a))
	note(f, "da.md")
	base := link.clock(f.client)
	f.client.now = base
	commit := laptop_commit(f, "vault: neu", {"neu.md"}, {SUM_NEU})
	expect_enqueued(f, commit)
	after := commit_request(f, "vault: danach", "da.md")
	expect_enqueued(f, after)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 2)
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)

	f.client.now = time.time_add(base, link.LAPTOP_FILE_WAIT + time.Minute)
	f.client.retry_now = true
	result, _ = link.flush(f.client)
	rec, _ = record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, "neu.md"), rec.error)
	testing.expect(t, contains(rec.error, "never arrived"), rec.error)
	next, _ := record_of(f, after.id)
	testing.expect_value(t, next.status, link.Record_Status.Done)
	failed, _ := link.read_failed(f.client, f.a)
	testing.expect_value(t, len(failed), 1)
	// The laptop hears of it: a notification waits for it.
	told := false
	for line in queue_lines(f) {
		if r, why := link.decode_request(line, f.a); why == "" && r.kind == .Notify {
			told = contains(r.body, "neu.md")
		}
	}
	testing.expect(t, told, "no notification for the laptop")
}

// The wait counts from when the server got the request, by the server's
// clock: a laptop whose clock is a day behind does not skip it.
@(test)
receive_counts_the_wait_from_the_servers_clock :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "a.md")
	commit := laptop_commit(f, "vault: a", {"a.md"}, {SUM_NEU})
	commit.created = link.timestamp(time.time_add(link.clock(f.client), -24 * time.Hour), f.a)
	rep, _ := link.receive(f.client, encoded(f, commit))
	testing.expect_value(t, rep.status, link.Status.Retry)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
}

// After the wait, git finds nothing to commit because the laptop's version
// never came: that is no commit made, and it is not recorded done.
@(test)
a_laptop_version_that_never_arrived_is_not_recorded_done :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { echo "nothing to commit, working tree clean"; exit 1; }` + "\n")
	note(f, "a.md")
	base := link.clock(f.client)
	f.client.now = base
	commit := laptop_commit(f, "vault: a", {"a.md"}, {SUM_NEU})
	expect_enqueued(f, commit)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, "never arrived"), rec.error)
}

// A commit from the laptop waits for the Obsidian operations queued before
// it, as the server's own do, even when its files are here.
@(test)
a_commit_from_the_laptop_waits_for_the_obsidian_operations_before_it :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/alt.md")
	note(f, "a.md")
	set_case_in_vault(f)
	f.client.receive_wait_ms = 200
	expect_enqueued(f, obsidian_request(f, .Rename, "Notizen/alt.md", name = "neu"))
	rep, _ := link.receive(f.client, encoded(f, laptop_commit(f, "vault: a", {"a.md"}, {SUM_TEXT})))
	testing.expect_value(t, rep.status, link.Status.Retry)
	link.flush(f.client)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, run_order(f), "obsidian add commit")
}

@(test)
an_empty_file_has_the_sum_of_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "leer.md", "")
	sum, why, not_a_file := link.file_sum(join(f, "vault", "leer.md"), f.a)
	testing.expect_value(t, why, "")
	testing.expect(t, !not_a_file)
	testing.expect_value(t, sum, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	// A path the sync cannot carry is refused on the laptop.
	set_case(f, FORWARD_ANSWERS)
	r := laptop(f, "vault-commit", "m", "zwei\nZeilen.md")
	testing.expect_value(t, r.code, 64)
	testing.expect_value(t, len(runs_of(f, "forward")), 0)
}
