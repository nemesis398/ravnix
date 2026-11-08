// The tests of the queue on muninn and its delivery: what queues while the
// laptop is away, what is delivered once and in order when it is back, and
// what a crash, a corrupt line or two writers at once do to it (Review
// Focus 5 of the plan).
package ravnix_link_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import link ".."

@(test)
with_the_socket_down_three_requests_queue_on_disk_in_order :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	reqs := []link.Request {
		open_request(f, "https://example.org/eins"),
		obsidian_request(f, .Move, ODD_PATH, to = "Archiv"),
		obsidian_request(f, .Delete, "Notizen/alt.md"),
	}
	for r in reqs {
		outcome, _ := link.submit(f.client, r)
		testing.expect_value(t, outcome, link.Outcome.Queued)
	}
	lines := queue_lines(f)
	testing.expect_value(t, len(lines), 3)
	for r, i in reqs {
		if i >= len(lines) {
			break
		}
		back, why := link.decode_request(lines[i], f.a)
		testing.expect_value(t, why, "")
		testing.expect_value(t, back.id, r.id)
	}
	snap, why := link.read_snapshot(f.client, f.a)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(link.pending(snap, f.a)), 3)
	testing.expect_value(t, len(runs(f)), 0)
}

@(test)
on_reconnect_they_deliver_once_in_order :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	a := open_request(f, "https://example.org/eins")
	b := obsidian_request(f, .Rename, ODD_PATH, name = "Neu – Grüße")
	c := open_request(f, "/home/alice/Nextcloud/Über – x.pdf")
	for r in ([]link.Request{a, b, c}) {
		expect_enqueued(f, r)
	}
	start_daemon(f)
	result, why := link.flush(f.client)
	testing.expect_value(t, why, "")
	testing.expect_value(t, result.done, 3)
	testing.expect_value(t, result.pending, 0)
	got := runs(f)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0][0], "xdg-open")
		testing.expect_value(t, got[0][1], "https://example.org/eins")
		testing.expect_value(t, got[1][0], "obsidian")
		testing.expect_value(t, strings.join(got[1][1:], " ", f.a), "rename path=" + ODD_PATH + " name=Neu – Grüße")
		testing.expect_value(t, got[2][1], "/home/alice/Nextcloud/Über – x.pdf")
	}
	// A second flush, and a restarted daemon, deliver nothing again.
	result, why = link.flush(f.client)
	testing.expect_value(t, result.sent, 0)
	stop_daemon(f)
	start_daemon(f)
	result, why = link.flush(f.client)
	testing.expect_value(t, result.sent, 0)
	testing.expect_value(t, len(runs(f)), 3)
	for r in ([]link.Request{a, b, c}) {
		rec, ok := record_of(f, r.id)
		testing.expect(t, ok || len(queue_lines(f)) == 0, "a delivered request has no record and is still queued")
		if ok {
			testing.expect_value(t, rec.status, link.Record_Status.Done)
		}
	}
}

// A request the daemon has run, whose ack the client never wrote (the
// client crashed between the two), runs once when it is delivered again,
// whether the daemon kept running or was restarted in between.
@(test)
a_crash_between_deliver_and_ack_runs_nothing_twice :: proc(t: ^testing.T) {
	for restart in ([]bool{false, true}) {
		f := fixture(t)
		defer fixture_destroy(f)
		r := obsidian_request(f, .Rename, ODD_PATH, name = "Neu")
		expect_enqueued(f, r)
		start_daemon(f)
		line, _ := link.encode_request(r, f.a)
		fd, dwhy := link.dial(f.socket)
		testing.expect_value(t, dwhy, "")
		reply, ewhy := link.exchange(fd, line, 5000, f.a)
		link.hang_up(fd)
		testing.expect_value(t, ewhy, "")
		testing.expect_value(t, reply.status, link.Status.Done)
		if restart {
			stop_daemon(f)
			start_daemon(f)
		}
		result, why := link.flush(f.client)
		testing.expect_value(t, why, "")
		testing.expect_value(t, result.done, 1)
		testing.expect_value(t, len(runs_of(f, "obsidian")), 1)
	}
}

@(test)
a_request_delivered_twice_runs_once :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	r := open_request(f, "https://example.org/zweimal")
	line, _ := link.encode_request(r, f.a)
	for _ in 0 ..< 3 {
		fd, dwhy := link.dial(f.socket)
		testing.expect_value(t, dwhy, "")
		reply, why := link.exchange(fd, line, 5000, f.a)
		link.hang_up(fd)
		testing.expect_value(t, why, "")
		testing.expect_value(t, reply.status, link.Status.Done)
		testing.expect_value(t, reply.id, r.id)
	}
	testing.expect_value(t, len(runs(f)), 1)
	// The same line twice in the queue (a writer that wrote it twice) is one
	// request as well.
	again := obsidian_request(f, .Delete, "Notizen/doppelt.md")
	expect_enqueued(f, again)
	expect_enqueued(f, again)
	result, why := link.flush(f.client)
	testing.expect_value(t, why, "")
	testing.expect_value(t, result.sent, 1)
	testing.expect_value(t, len(runs_of(f, "obsidian")), 1)
}

// The daemon recorded that it started a request and never recorded how it
// ended: it stopped while the request ran. Running it again could rename a
// note twice, so it is not run again, and the client is told why.
@(test)
a_request_the_daemon_stopped_in_is_not_run_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	r := obsidian_request(f, .Rename, ODD_PATH, name = "Neu")
	testing.expect_value(t, os.make_directory_all(f.server.state, os.perm_number(0o700)), nil)
	write_file(f, strings.concatenate({f.server.state, "/seen"}, f.a), link.encode_record(link.Record{id = r.id, status = .Started}, f.a))
	expect_enqueued(f, r)
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.failed, 1)
	testing.expect_value(t, len(runs(f)), 0)
	rec, _ := record_of(f, r.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, "not run again"), rec.error)
}

// A rename, then an edit to the old path, then a commit: the rename is
// delivered first, the commit runs last, and it sees the renamed note with
// the edit. Obsidian on the laptop is a stand-in that renames the file in
// the vault, as Obsidian and the sync between the hosts would.
@(test)
a_rename_then_an_edit_delivers_the_rename_first_and_the_commit_last :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, ODD_PATH, "alt\n")
	old_path := strings.concatenate({f.vault, "/", ODD_PATH}, f.a)
	set_case_in_vault(f, `[ "$n" = git ] && [ "$4" = commit ] && {
  [ -e "$v/Notizen/Neu – Grüße.md" ] && echo new >>"$d/seen-at-commit"
  [ -e "$v/` + ODD_PATH + `" ] && echo old >>"$d/seen-at-commit"
  while IFS= read -r l; do echo "$l" >>"$d/seen-at-commit"; done <"$v/Notizen/Neu – Grüße.md"
}
`)
	rename := obsidian_request(f, .Rename, ODD_PATH, name = "Neu – Grüße")
	outcome, _ := link.submit(f.client, rename)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	// The edit, made on muninn while the rename waits for the laptop.
	write_file(f, old_path, "alt\nbearbeitet\n")
	commit := commit_request(f, "vault: rename and edit", ODD_PATH, "Notizen/Neu – Grüße.md")
	outcome, _ = link.submit(f.client, commit)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	testing.expect_value(t, len(runs(f)), 0)

	start_daemon(f)
	result, why := link.flush(f.client)
	testing.expect_value(t, why, "")
	testing.expect_value(t, result.pending, 0)
	testing.expectf(t, run_order(f) == "obsidian add commit", "the runs were %s; the reports: %s", run_order(f), stderr_text(f))
	adds, commits := git_runs(f, "add"), git_runs(f, "commit")
	if len(adds) == 1 && len(commits) == 1 {
		// The old path is gone; the commit takes its removal.
		testing.expect_value(t, strings.join(adds[0][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|add|-A|--|Notizen/Neu – Grüße.md"}, f.a))
		testing.expect_value(t, strings.join(commits[0][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: rename and edit|--|", ODD_PATH, "|Notizen/Neu – Grüße.md"}, f.a))
	}
	testing.expect_value(t, read_file(f, join(f, "bin", "seen-at-commit")), "new\nalt\nbearbeitet\n")
}

// The commit of a rename whose first attempt failed after git add had
// staged the old path's removal (a signing agent that was not there): git
// knows the old path in neither the work tree nor the index any more, and
// git add refuses it. The next attempt adds only what is in the work tree,
// and the commit takes the removal of the rest, as git commit -- PATH does.
@(test)
a_commit_that_failed_after_staging_a_removal_runs_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/Neu.md")
	set_case_in_vault(f, `[ "$n" = git ] && case $4 in
add)
  shift 6
  for p in "$@"; do
    [ -e "$v/$p" ] || [ ! -e "$d/staged" ] || { echo "fatal: pathspec '$p' did not match any files" >&2; exit 128; }
  done
  : >"$d/staged" ;;
commit)
  [ -e "$d/failed-once" ] || { : >"$d/failed-once"; printf '%s\n' "error: Couldn't get agent socket?" 'fatal: failed to write commit object' >&2; exit 128; } ;;
esac
`)
	c := commit_request(f, "vault: rename", "Notizen/Alt.md", "Notizen/Neu.md")
	outcome, message := link.submit(f.client, c)
	testing.expect_value(t, outcome, link.Outcome.Retrying)
	testing.expect(t, contains(message, "agent socket"), message)
	f.client.retry_now = true
	result, _ := link.flush(f.client)
	testing.expectf(t, result.done == 1, "the reports: %s", stderr_text(f))
	adds, commits := git_runs(f, "add"), git_runs(f, "commit")
	testing.expect_value(t, len(commits), 2)
	for a in adds {
		testing.expect_value(t, strings.join(a[1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|add|-A|--|Notizen/Neu.md"}, f.a))
	}
	if len(commits) == 2 {
		testing.expect_value(t, strings.join(commits[1][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: rename|--|Notizen/Alt.md|Notizen/Neu.md"}, f.a))
	}
}

// The laptop has done the rename, but the server's copy of the vault does
// not show it yet: the commit after it waits, pending and with no git run,
// until the sync brings the rename, and status says what it waits for.
// The rename was delivered, and the queue emptied, before the commit was
// even made: the commit waits all the same.
@(test)
a_commit_waits_until_the_vault_here_shows_the_operations_before_it :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/alt.md")
	start_daemon(f)
	rename := obsidian_request(f, .Rename, "Notizen/alt.md", name = "neu")
	outcome, _ := link.submit(f.client, rename)
	testing.expect_value(t, outcome, link.Outcome.Done)
	testing.expect_value(t, len(queue_lines(f)), 0)
	commit := commit_request(f, "vault: rename", "Notizen/alt.md", "Notizen/neu.md")
	outcome, _ = link.submit(f.client, commit)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
	r := cli(f, "status")
	testing.expect(t, contains(r.out, "waits until the vault here shows obsidian rename path=Notizen/alt.md name=neu"), r.out)
	// The sync brings it.
	testing.expect_value(t, os.rename(strings.concatenate({f.vault, "/Notizen/alt.md"}, f.a), strings.concatenate({f.vault, "/Notizen/neu.md"}, f.a)), nil)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Done)
}

// The sync does not bring it: after SYNC_WAIT the commit goes ahead and
// says so; the path git does not find is the rename's, which a late sync
// may still bring, so the commit is tried again.
@(test)
a_commit_gives_up_waiting_for_the_sync_and_goes_ahead :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/alt.md")
	set_case(f, `[ "$n" = git ] && [ "$4" = add ] && { echo "fatal: pathspec 'Notizen/neu.md' did not match any files" >&2; exit 128; }` + "\n")
	start_daemon(f)
	base := link.clock(f.client)
	f.client.now = base
	expect_enqueued(f, obsidian_request(f, .Rename, "Notizen/alt.md", name = "neu"))
	commit := commit_request(f, "vault: rename", "Notizen/alt.md", "Notizen/neu.md")
	expect_enqueued(f, commit)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	testing.expect_value(t, len(git_runs(f, "add")), 0)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	testing.expect_value(t, len(git_runs(f, "add")), 1)
	testing.expect(t, contains(stderr_text(f), "does not show obsidian rename"), stderr_text(f))
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	testing.expect(t, contains(rec.error, "not in the vault"), rec.error)
}

// Obsidian operations run before a commit queued after them; a commit with
// no Obsidian operation waiting before it runs at once, laptop or not, and
// does not wait for a link to open.
@(test)
a_commit_waits_for_the_obsidian_operations_before_it_and_nothing_else :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/a.md")
	set_case_in_vault(f)
	open_first := open_request(f, "https://example.org/spaeter")
	expect_enqueued(f, open_first)
	early := commit_request(f, "vault: early")
	outcome, _ := link.submit(f.client, early)
	testing.expect_value(t, outcome, link.Outcome.Done)
	testing.expect_value(t, run_order(f), "commit")

	move := obsidian_request(f, .Move, "Notizen/a.md", to = "Archiv")
	expect_enqueued(f, move)
	late := commit_request(f, "vault: late", "Notizen/a.md", "Archiv/a.md")
	outcome, _ = link.submit(f.client, late)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	testing.expect_value(t, run_order(f), "commit")

	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, run_order(f), "commit xdg-open obsidian add commit")
}

@(test)
a_corrupt_queue_line_is_skipped_and_reported_and_the_rest_delivered :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	a := open_request(f, "https://example.org/vorher")
	b := open_request(f, "https://example.org/nachher")
	expect_enqueued(f, a)
	queue := join(f, "state", "queue")
	text := read_file(f, queue)
	write_file(f, queue, strings.concatenate({text, "{\"id\": kaputt\n", "\xff\xfe nonsense\n"}, f.a))
	expect_enqueued(f, b)
	start_daemon(f)
	result, why := link.flush(f.client)
	testing.expect_value(t, why, "")
	testing.expect_value(t, result.done, 2)
	opened := runs_of(f, "xdg-open")
	testing.expect_value(t, len(opened), 2)
	report := stderr_text(f)
	testing.expectf(t, strings.count(report, "skipped") == 2, "the two lines are reported: %q", report)
	testing.expect(t, contains(report, "line 2"), report)
	testing.expect(t, contains(report, "line 3"), report)
	// Reported once, not on every flush.
	c := open_request(f, "https://example.org/danach")
	expect_enqueued(f, c)
	link.flush(f.client)
	testing.expect_value(t, strings.count(stderr_text(f), "skipped"), 2)
}

// A writer that died in the middle of a line leaves it without a newline.
// The next request still gets a line of its own.
@(test)
a_torn_last_line_does_not_swallow_the_next_request :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	expect_enqueued(f, open_request(f, "https://example.org/a"))
	queue := join(f, "state", "queue")
	write_file(f, queue, strings.concatenate({read_file(f, queue), `{"id":"0b9a1c2e-4f5d-4a6b-8c7d`}, f.a))
	b := open_request(f, "https://example.org/b")
	expect_enqueued(f, b)
	lines := queue_lines(f)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 {
		back, why := link.decode_request(lines[2], f.a)
		testing.expect_value(t, why, "")
		testing.expect_value(t, back.id, b.id)
	}
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.done, 2)
	testing.expect(t, contains(stderr_text(f), "skipped"))
}

// muninn reboots: nothing of the client survives but its files. A fresh
// configuration, read from the same directory, finds the same requests
// waiting, and delivers them.
@(test)
the_queue_survives_a_reboot :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	ids := make([dynamic]string, f.a)
	for target in ([]string{"https://example.org/1", "https://example.org/2"}) {
		r := open_request(f, target)
		append(&ids, r.id)
		expect_enqueued(f, r)
	}
	link.flush(f.client)
	after := link.Config {
		socket           = f.socket,
		state            = strings.clone(f.client.state, f.a),
		stderr           = f.stderr,
		reply_timeout_ms = 10_000,
	}
	snap, why := link.read_snapshot(after, f.a)
	testing.expect_value(t, why, "")
	waiting := link.pending(snap, f.a)
	testing.expect_value(t, len(waiting), 2)
	for e, i in waiting {
		testing.expect_value(t, e.request.id, ids[i])
	}
	start_daemon(f)
	result, _ := link.flush(after)
	testing.expect_value(t, result.done, 2)
}

@(test)
a_ten_megabyte_body_is_refused_and_nothing_is_queued :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	r := notify_request(f, "groß", strings.repeat("x", 10 * 1024 * 1024, f.a))
	why := link.enqueue(f.client, r)
	testing.expect(t, contains(why, "65536"), why)
	outcome, message := link.submit(f.client, r)
	testing.expect_value(t, outcome, link.Outcome.Refused)
	testing.expect(t, contains(message, "65536"), message)
	testing.expect_value(t, len(queue_lines(f)), 0)
}

Writer :: struct {
	f:      ^Fixture,
	thread: int,
	ids:    [dynamic]string,
	errors: int,
}

writer_worker :: proc(w: ^Writer) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	for i in 0 ..< 60 {
		// Lines from a few bytes to most of the limit, so a torn or
		// interleaved write would show in the line it broke.
		size := (i * 7919 + w.thread * 104_729) % 60_000
		r := notify_request(w.f, fmt.aprintf("w%d-%d", w.thread, i, allocator = w.f.a), strings.repeat("z", size, w.f.a))
		if link.enqueue(w.f.client, r) != "" {
			w.errors += 1
		}
		append(&w.ids, r.id)
	}
}

@(test)
two_clients_at_once_never_interleave_or_tear_a_line :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	// The fixture's arena is not safe from threads; each writer gets its
	// own.
	writers: [8]Writer
	fixtures: [8]^Fixture
	for i in 0 ..< len(writers) {
		fixtures[i] = fixture(t)
		fixtures[i].client = f.client
		writers[i] = Writer{f = fixtures[i], thread = i, ids = make([dynamic]string, fixtures[i].a)}
	}
	defer for x in fixtures {
		fixture_destroy(x)
	}
	threads: [8]^thread.Thread
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data(&writers[i], writer_worker, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	lines := queue_lines(f)
	testing.expect_value(t, len(lines), 8 * 60)
	position := make(map[string]int, f.a)
	for line, i in lines {
		r, why := link.decode_request(line, f.a)
		testing.expectf(t, why == "", "line %d is torn: %s", i + 1, why)
		position[r.id] = i
	}
	for w in writers {
		testing.expect_value(t, w.errors, 0)
		last := -1
		for id in w.ids {
			p, ok := position[id]
			testing.expect(t, ok, "a request is missing")
			testing.expect(t, p > last, "a writer's requests are out of order")
			last = p
		}
	}
}

@(test)
a_drained_queue_is_emptied :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	for target in ([]string{"https://example.org/1", "https://example.org/2"}) {
		outcome, _ := link.submit(f.client, open_request(f, target))
		testing.expectf(t, outcome == .Done, "%v, the client said: %s", outcome, stderr_text(f))
	}
	testing.expect_value(t, read_file(f, join(f, "state", "queue")), "")
	// acked keeps the last outcomes, for a client whose request another run
	// delivered, and no more than that, however many came before.
	for i in 0 ..< link.KEEP_RECORDS + 10 {
		outcome, _ := link.submit(f.client, open_request(f, fmt.aprintf("https://example.org/%d", i, allocator = f.a)))
		testing.expectf(t, outcome == .Done, "%d: %v, the client said: %s", i, outcome, stderr_text(f))
	}
	testing.expect_value(t, read_file(f, join(f, "state", "queue")), "")
	acked := strings.split_lines(strings.trim_suffix(read_file(f, join(f, "state", "acked")), "\n"), f.a)
	testing.expectf(t, len(acked) <= link.KEEP_RECORDS + 1, "acked holds %d records", len(acked))
}

@(test)
a_stale_notification_is_dropped_and_a_fresh_one_shown :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	old := notify_request(f, "alt", "von vorhin")
	old.created = link.timestamp(time.time_add(link.clock(f.client), -11 * time.Minute), f.a)
	fresh := notify_request(f, "neu", "eben")
	expect_enqueued(f, old)
	expect_enqueued(f, fresh)
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.expired, 1)
	testing.expect_value(t, result.done, 1)
	shown := runs_of(f, "notify-send")
	testing.expect_value(t, len(shown), 1)
	if len(shown) == 1 {
		testing.expect_value(t, strings.join(shown[0][1:], "|", f.a), "--|neu|eben")
	}
	rec, _ := record_of(f, old.id)
	testing.expect_value(t, rec.status, link.Record_Status.Expired)
}

// Obsidian answers with an Error: line (and exits 0, as it does). The
// request failed: it is reported and not tried again, and the requests
// after it are still delivered.
@(test)
a_failing_obsidian_operation_is_reported_once_and_not_retried :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = obsidian ] && echo 'Error: File "Notizen/weg.md" not found.'` + "\n")
	bad := obsidian_request(f, .Delete, "Notizen/weg.md")
	after := open_request(f, "https://example.org/danach")
	expect_enqueued(f, bad)
	expect_enqueued(f, after)
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.failed, 1)
	testing.expect_value(t, result.done, 1)
	rec, _ := record_of(f, bad.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, `Error: File "Notizen/weg.md" not found.`), rec.error)
	testing.expect(t, contains(stderr_text(f), "not found"))
	link.flush(f.client)
	testing.expect_value(t, len(runs_of(f, "obsidian")), 1)
}

// The daemon cannot run an Obsidian operation now (Obsidian is not
// installed): it is not acknowledged and stays queued. The vault's requests
// after it (another operation, a commit) wait behind it, so their order
// holds; an open after it goes ahead. Six hours on, it fails.
@(test)
a_request_the_laptop_cannot_run_yet_holds_the_vault_and_lets_an_open_pass :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/a.md")
	note(f, "Notizen/b.md")
	set_case_in_vault(f)
	f.server.obsidian = join(f, "bin", "no-obsidian")
	first := obsidian_request(f, .Delete, "Notizen/a.md")
	second := open_request(f, "https://example.org/danach")
	third := obsidian_request(f, .Delete, "Notizen/b.md")
	commit := commit_request(f, "vault: weg")
	for r in ([]link.Request{first, second, third, commit}) {
		expect_enqueued(f, r)
	}
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 3)
	testing.expect_value(t, run_order(f), "xdg-open")
	testing.expect(t, contains(stderr_text(f), "no-obsidian"), stderr_text(f))
	// Obsidian is there now.
	stop_daemon(f)
	f.server.obsidian = join(f, "bin", "obsidian")
	start_daemon(f)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, run_order(f), "xdg-open obsidian obsidian commit")
}

@(test)
a_request_the_laptop_cannot_run_for_six_hours_fails :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	f.server.obsidian = join(f, "bin", "no-obsidian")
	base := link.clock(f.client)
	f.client.now = base
	r := obsidian_request(f, .Delete, "Notizen/a.md")
	expect_enqueued(f, r)
	start_daemon(f)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	f.client.now = time.time_add(base, link.LAPTOP_RETRY_GIVE_UP + time.Minute)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, result.failed, 1)
	rec, _ := record_of(f, r.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, "6 hours"), rec.error)
}

// A run stopped between its started record and git: HEAD has not moved, so
// the commit runs again.
@(test)
a_commit_cut_off_before_git_runs_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && [ "$3" = rev-parse ] && { echo 1111111111111111111111111111111111111111; exit 0; }` + "\n")
	c := commit_request(f, "vault: cut off")
	expect_enqueued(f, c)
	write_file(f, join(f, "state", "acked"), link.encode_record(link.Record{id = c.id, status = .Started, head = "1111111111111111111111111111111111111111", attempts = 1, since = now(f)}, f.a))
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.done, 1)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)
	testing.expect_value(t, len(git_runs(f, "log")), 0)
}

// A run stopped between git and its done record: HEAD moved to a commit
// with the message, so it is done, and git does not commit again. One whose
// HEAD moved to other commits runs again.
@(test)
a_commit_cut_off_after_git_is_found_and_not_run_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && case $3 in
rev-parse) echo 2222222222222222222222222222222222222222; exit 0 ;;
log) [ "$6" = 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 ] || exit 1
  printf 'vault: someone else\n\n\000vault: cut off  \n\n\000' ; exit 0 ;;
esac
`)
	done := commit_request(f, "vault: cut off")
	other := commit_request(f, "vault: not there")
	expect_enqueued(f, done)
	expect_enqueued(f, other)
	acked := strings.concatenate({
		link.encode_record(link.Record{id = done.id, status = .Started, head = "1111111111111111111111111111111111111111", attempts = 1, since = now(f)}, f.a),
		link.encode_record(link.Record{id = other.id, status = .Started, head = "1111111111111111111111111111111111111111", attempts = 1, since = now(f)}, f.a),
	}, f.a)
	write_file(f, join(f, "state", "acked"), acked)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.done, 2)
	commits := git_runs(f, "commit")
	testing.expect_value(t, len(commits), 1)
	if len(commits) == 1 {
		testing.expect(t, contains(strings.join(commits[0], " ", f.a), "vault: not there"))
	}
	testing.expect(t, contains(stderr_text(f), "was committed by a run that stopped"), stderr_text(f))
}

// A commit git refuses for a reason another attempt cannot change (a path
// it does not know, a hook that rejects the commit) fails at once, with
// HEAD where it was: it is listed as failed for good, and the commit queued
// after it runs.
@(test)
a_commit_git_refuses_for_good_fails_at_once_and_the_next_runs :: proc(t: ^testing.T) {
	Case :: struct {
		why, stderr: string,
		code:        int,
	}
	cases := []Case {
		{"a path git does not know", "error: pathspec 'Notizen/gibts-nicht.md' did not match any file(s) known to git", 1},
		{"a hook that rejects it", "commit-msg: the subject is longer than 72 characters", 1},
		{"an ignored path", "The following paths are ignored by one of your .gitignore files:\nNotizen/tmp.md", 1},
		// A hook's own words may name an agent, a signature or gpg; they are
		// still the hook's no.
		{"a hook that names an agent", "commit-msg: an agent commit must name its model in a Co-Authored-By trailer", 1},
		{"a hook that names a signature", "pre-commit: signing policy: sign your work with gpg, see the signature guide", 1},
		{"a hook that names a merge", "pre-commit: no commits during a merge freeze", 1},
	}
	for c in cases {
		f := fixture(t)
		defer fixture_destroy(f)
		write_file(f, join(f, "bin", "stderr-text"), c.stderr)
		write_file(f, join(f, "bin", "exit-code"), fmt.aprint(c.code, allocator = f.a))
		set_case(f, `[ "$n" = git ] && [ "$3" = rev-parse ] && { echo 1111111111111111111111111111111111111111; exit 0; }
[ "$n" = git ] && [ "$4" = commit ] && [ "$6" = "vault: falsch" ] && { cat "$d/stderr-text" >&2; exit "$(cat "$d/exit-code")"; }
`)
		bad := commit_request(f, "vault: falsch")
		outcome, message := link.submit(f.client, bad)
		testing.expectf(t, outcome == .Failed, "%s: %v %s", c.why, outcome, message)
		good := commit_request(f, "vault: richtig")
		outcome, message = link.submit(f.client, good)
		testing.expectf(t, outcome == .Done, "%s: the next commit %v %s", c.why, outcome, message)
		testing.expect_value(t, len(git_runs(f, "commit")), 2)
		r := cli(f, "status")
		testing.expectf(t, contains(r.out, `1 vault commit failed for good`) && contains(r.out, `vault-commit "vault: falsch"`), "%s: %s", c.why, r.out)
	}
}

// What another attempt can change is tried again: a lock another git
// holds, an agent that is not there or locked, a signature that failed.
@(test)
a_commit_that_fails_for_a_lock_or_the_agent_is_tried_again :: proc(t: ^testing.T) {
	for stderr in ([]string {
			"fatal: Unable to create '/v/.git/index.lock': File exists.",
			"error: Couldn't get agent socket?\nfatal: failed to write commit object",
			"error: agent refused operation\nfatal: failed to write commit object",
			"error: gpg failed to sign the data\nfatal: failed to write commit object",
			"fatal: cannot lock ref 'HEAD': is at 1111 but expected 2222",
			"fatal: unable to write new index file",
			"error: unable to write file .git/objects/ab/cdef: No space left on device",
			"fatal: write error: No space left on device",
			"fatal: cannot do a partial commit during a rebase.",
			"fatal: cannot do a partial commit during a merge.",
			"error: open(\"Notizen/a.md\"): No such file or directory\nerror: unable to index file 'Notizen/a.md'\nfatal: adding files failed",
		}) {
		f := fixture(t)
		defer fixture_destroy(f)
		write_file(f, join(f, "bin", "stderr-text"), stderr)
		set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { cat "$d/stderr-text" >&2; exit 128; }` + "\n")
		outcome, message := link.submit(f.client, commit_request(f, "vault: spaeter"))
		testing.expectf(t, outcome == .Retrying, "%s: %v %s", stderr, outcome, message)
	}
}

// git add refuses an ignored path itself, as real git does: that is for
// good too.
@(test)
an_ignored_path_git_add_refuses_fails_at_once :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/tmp.md")
	write_file(f, join(f, "bin", "stderr-text"), "The following paths are ignored by one of your .gitignore files:\nNotizen/tmp.md\nhint: Use -f if you really want to add them.")
	set_case(f, `[ "$n" = git ] && [ "$4" = add ] && { cat "$d/stderr-text" >&2; exit 1; }` + "\n")
	outcome, message := link.submit(f.client, commit_request(f, "vault: ignoriert", "Notizen/tmp.md"))
	testing.expectf(t, outcome == .Failed, "%v %s", outcome, message)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
}

// git add fails to index a file for what lasts: one it may not read (mode
// 000, as a sync client may write one) or a folder that holds a repository
// of its own. That is for good, at once; only a file the sync replaced
// while git read it is tried again.
@(test)
a_file_git_add_cannot_index_for_good_fails_at_once :: proc(t: ^testing.T) {
	Case :: struct {
		why, stderr: string,
	}
	cases := []Case {
		{"a nested repository", "error: 'Notizen/a.md' does not have a commit checked out\nerror: unable to index file 'Notizen/a.md'\nfatal: adding files failed"},
		{"a file it may not read", ""},
	}
	for c in cases {
		f := fixture(t)
		defer fixture_destroy(f)
		note(f, "Notizen/a.md")
		if c.stderr == "" {
			testing.expect_value(t, os.chmod(join(f, "vault", "Notizen", "a.md"), os.perm_number(0)), nil)
		}
		write_file(f, join(f, "bin", "stderr-text"), c.stderr)
		set_case(f, strings.concatenate({"v='", f.vault, "'\n", `[ "$n" = git ] && [ "$4" = add ] && {
  if [ ! -r "$v/Notizen/a.md" ]; then
    printf '%s\n' 'error: open("Notizen/a.md"): Permission denied' "error: unable to index file 'Notizen/a.md'" 'fatal: adding files failed' >&2
  else
    cat "$d/stderr-text" >&2
  fi
  exit 128
}
`}, f.a))
		outcome, message := link.submit(f.client, commit_request(f, "vault: kaputt", "Notizen/a.md"))
		testing.expectf(t, outcome == .Failed, "%s: %v %s", c.why, outcome, message)
		os.chmod(join(f, "vault", "Notizen", "a.md"), os.perm_number(0o644))
	}
}

// drop of a commit that waits for a path an Obsidian operation was to
// bring retires that operation too: the next commit that names the path
// does not wait a day for it again.
@(test)
drop_retires_the_operation_a_commit_waits_for :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/alt.md")
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { echo "error: pathspec 'Notizen/neu.md' did not match any file(s) known to git" >&2; exit 1; }` + "\n")
	start_daemon(f)
	base := link.clock(f.client)
	f.client.now = base
	expect_enqueued(f, obsidian_request(f, .Rename, "Notizen/alt.md", name = "neu"))
	first := commit_request(f, "vault: rename", "Notizen/alt.md", "Notizen/neu.md")
	expect_enqueued(f, first)
	link.flush(f.client)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	link.flush(f.client)
	rec, _ := record_of(f, first.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	r := cli(f, "drop", first.id)
	testing.expectf(t, r.code == 0, "%d %s", r.code, r.err)
	expects, _ := link.read_expectations(f.client, f.a)
	testing.expect_value(t, len(expects), 0)
	again := commit_request(f, "vault: rename again", "Notizen/neu.md")
	outcome, message := link.submit(f.client, again)
	testing.expectf(t, outcome == .Failed, "%v %s", outcome, message)
}

// A refusal with HEAD moved since the attempt began (the commit may have
// landed after all): not given up, but tried again, which finds out.
@(test)
a_refusal_with_head_moved_is_tried_again :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	write_file(f, join(f, "bin", "heads"), "")
	set_case(f, `[ "$n" = git ] && [ "$3" = rev-parse ] && {
  echo x >>"$d/heads"
  if [ "$(wc -l <"$d/heads")" -le 1 ]; then echo 1111111111111111111111111111111111111111; else echo 2222222222222222222222222222222222222222; fi
  exit 0
}
[ "$n" = git ] && [ "$4" = commit ] && { echo 'commit-msg: no' >&2; exit 1; }
`)
	outcome, message := link.submit(f.client, commit_request(f, "vault: verschoben"))
	testing.expectf(t, outcome == .Retrying, "%v %s", outcome, message)
}

// A path the vault does not show, which an Obsidian operation before the
// commit was to bring (the laptop suspended before its sync uploaded the
// rename): tried again, with the bound of a day, after the sync wait has
// given up. A path no operation names fails at once.
@(test)
a_missing_path_an_operation_names_is_tried_again_after_the_sync_wait :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	note(f, "Notizen/alt.md")
	set_case(f, strings.concatenate({"v='", f.vault, "'\n", `[ "$n" = git ] && [ "$4" = commit ] && [ "$6" = "vault: vertippt" ] && { echo "error: pathspec 'Notizen/nue.md' did not match any file(s) known to git" >&2; exit 1; }
[ "$n" = git ] && [ "$4" = commit ] && [ ! -e "$v/Notizen/neu.md" ] && { echo "error: pathspec 'Notizen/neu.md' did not match any file(s) known to git" >&2; exit 1; }
`}, f.a))
	start_daemon(f)
	base := link.clock(f.client)
	f.client.now = base
	expect_enqueued(f, obsidian_request(f, .Rename, "Notizen/alt.md", name = "neu"))
	commit := commit_request(f, "vault: rename", "Notizen/alt.md", "Notizen/neu.md")
	expect_enqueued(f, commit)
	link.flush(f.client)
	f.client.now = time.time_add(base, link.SYNC_WAIT + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 1)
	rec, _ := record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	// Another attempt, a quarter of an hour on, still before the sync: the
	// operation the wait gave up on is kept, and it is tried again.
	f.client.now = time.time_add(base, 30 * time.Minute)
	f.client.retry_now = true
	result, _ = link.flush(f.client)
	f.client.retry_now = false
	testing.expect_value(t, result.pending, 1)
	rec, _ = record_of(f, commit.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	testing.expect_value(t, rec.attempts, 2)
	// status does not show the wait it gave up as one.
	r := cli(f, "status")
	testing.expect(t, !contains(r.out, "waits until"), r.out)
	testing.expect(t, contains(r.out, "attempt 2 failed"), r.out)
	// The kept operation names neu.md, not a path that nothing brings.
	expects, xwhy := link.read_expectations(f.client, f.a)
	testing.expect_value(t, xwhy, "")
	testing.expect_value(t, len(expects), 1)
	typo := commit_request(f, "vault: vertippt", "Notizen/nue.md")
	testing.expect(t, !link.brought_by_sync(f.vault, typo, expects))
	testing.expect(t, link.brought_by_sync(f.vault, commit, expects))
	// The sync comes, an hour on: the commit goes through.
	os.rename(join(f, "vault", "Notizen", "alt.md"), join(f, "vault", "Notizen", "neu.md"))
	f.client.now = time.time_add(base, time.Hour)
	result, _ = link.flush(f.client)
	testing.expect_value(t, result.done, 1)
	// A path nothing brings: for good, at once.
	outcome, _ := link.submit(f.client, commit_request(f, "vault: vertippt", "Notizen/nue.md"))
	testing.expect_value(t, outcome, link.Outcome.Failed)
}

// A commit that failed, recorded retry, whose HEAD has since moved to a
// commit with its message (a hook that outlived the time limit after the
// ref moved): it is done, and git does not commit again.
@(test)
a_commit_recorded_retry_that_landed_is_done :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && case $3 in
rev-parse) echo 2222222222222222222222222222222222222222; exit 0 ;;
log) printf 'vault: gelandet\n\n\000'; exit 0 ;;
esac
`)
	c := commit_request(f, "vault: gelandet")
	expect_enqueued(f, c)
	write_file(f, join(f, "state", "acked"), link.encode_record(link.Record{id = c.id, status = .Retry, head = "1111111111111111111111111111111111111111", attempts = 1, since = now(f), next = now(f), error = "git commit did not finish"}, f.a))
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.done, 1)
	testing.expect_value(t, len(git_runs(f, "commit")), 0)
}

// drop ID resolves a waiting request by hand: a commit that waits for its
// next attempt, with one behind it, which then runs. status names the ids.
@(test)
drop_lets_go_of_a_waiting_request :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && [ "$6" = "vault: haengt" ] && { printf '%s\n' "error: Couldn't get agent socket?" 'fatal: failed to write commit object' >&2; exit 128; }` + "\n")
	stuck := commit_request(f, "vault: haengt")
	outcome, _ := link.submit(f.client, stuck)
	testing.expect_value(t, outcome, link.Outcome.Retrying)
	behind := commit_request(f, "vault: dahinter")
	outcome, _ = link.submit(f.client, behind)
	testing.expect_value(t, outcome, link.Outcome.Queued)
	r := cli(f, "status")
	testing.expect(t, contains(r.out, stuck.id), r.out)
	testing.expect(t, contains(r.out, behind.id), r.out)
	r = cli(f, "drop", stuck.id)
	testing.expectf(t, r.code == 0, "%d %s", r.code, r.err)
	testing.expect(t, contains(r.out, `dropped vault-commit "vault: haengt"`), r.out)
	rec, _ := record_of(f, stuck.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	testing.expect(t, contains(rec.error, "dropped"), rec.error)
	link.flush(f.client)
	rec, _ = record_of(f, behind.id)
	testing.expect_value(t, rec.status, link.Record_Status.Done)
	// Once more, or an id that waits for nothing: refused.
	r = cli(f, "drop", stuck.id)
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "waits for nothing"), r.err)
	r = cli(f, "drop", "0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d")
	testing.expect_value(t, r.code, 1)
	for bad in ([][]string{{"drop"}, {"drop", "a", "b"}, {"drop", "nonsense"}}) {
		r = cli(f, ..bad)
		testing.expectf(t, r.code == 64, "%v: %d %s", bad, r.code, r.err)
	}
}

// "nothing to commit": the paths are as committed already, which a commit
// run a second time finds. That is done.
@(test)
nothing_to_commit_is_done :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { echo 'nothing to commit, working tree clean'; exit 1; }` + "\n")
	outcome, message := link.submit(f.client, commit_request(f, "vault: nothing"))
	testing.expect_value(t, outcome, link.Outcome.Done)
	testing.expect_value(t, message, "")
}

// A commit that fails (a signature without an agent) runs again after 15 s,
// then 30 s, and status shows when and why; a day after the first attempt it
// fails for good, is listed in status, every command warns of it, and
// dismiss clears the list.
@(test)
a_failed_commit_runs_again_and_is_given_up_after_a_day :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && { echo 'error: Load key "/no/agent": Could not open a connection to your authentication agent.' >&2; echo 'fatal: failed to write commit object' >&2; exit 128; }` + "\n")
	base := link.clock(f.client)
	f.client.now = base
	c := commit_request(f, "vault: signed")
	outcome, message := link.submit(f.client, c)
	testing.expect_value(t, outcome, link.Outcome.Retrying)
	testing.expect(t, contains(message, "authentication agent"), message)
	rec, _ := record_of(f, c.id)
	testing.expect_value(t, rec.status, link.Record_Status.Retry)
	testing.expect_value(t, rec.attempts, 1)
	testing.expect_value(t, rec.next, link.timestamp(time.time_add(base, 15 * time.Second), f.a))
	// Not before its time; then again, 30 s later.
	link.flush(f.client)
	testing.expect_value(t, len(git_runs(f, "commit")), 1)
	f.client.now = time.time_add(base, 16 * time.Second)
	link.flush(f.client)
	testing.expect_value(t, len(git_runs(f, "commit")), 2)
	rec, _ = record_of(f, c.id)
	testing.expect_value(t, rec.attempts, 2)
	testing.expect_value(t, rec.next, link.timestamp(time.time_add(f.client.now, 30 * time.Second), f.a))
	r := cli(f, "status")
	testing.expect(t, contains(r.out, "attempt 2 failed, again at"), r.out)
	testing.expect(t, contains(r.out, "authentication agent"), r.out)
	// A flush by hand does not wait for the next attempt.
	testing.expect_value(t, cli(f, "flush").code, 0)
	testing.expect_value(t, len(git_runs(f, "commit")), 3)
	// A day on, it is given up.
	f.client.now = time.time_add(base, link.COMMIT_GIVE_UP + time.Minute)
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.failed, 1)
	testing.expect_value(t, result.pending, 0)
	rec, _ = record_of(f, c.id)
	testing.expect_value(t, rec.status, link.Record_Status.Failed)
	r = cli(f, "status")
	testing.expect(t, contains(r.out, "1 vault commit failed for good"), r.out)
	testing.expect(t, contains(r.out, `vault-commit "vault: signed"`), r.out)
	r = cli(f, "open", "https://example.org/")
	testing.expect(t, contains(r.err, "1 vault commit failed for good"), r.err)
	r = cli(f, "dismiss")
	testing.expect_value(t, r.code, 0)
	testing.expect(t, contains(r.out, "1 vault commit cleared"), r.out)
	r = cli(f, "status")
	testing.expect(t, !contains(r.out, "failed for good"), r.out)
	r = cli(f, "open", "https://example.org/")
	testing.expect(t, !contains(r.err, "failed for good"), r.err)
}

// A queued commit runs in the vault configured here, not in the one its
// line names (a vault that moved since).
@(test)
a_commit_runs_in_the_configured_vault :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	c := commit_request(f, "vault: here")
	c.vault = "/somewhere/else"
	outcome, _ := link.submit(f.client, c)
	testing.expect_value(t, outcome, link.Outcome.Done)
	commits := git_runs(f, "commit")
	testing.expect_value(t, len(commits), 1)
	if len(commits) == 1 {
		testing.expect_value(t, commits[0][3], f.vault)
	}
	no_vault := f.client
	no_vault.vault = ""
	c2 := commit_request(f, "vault: nowhere")
	outcome, _ = link.submit(no_vault, c2)
	testing.expect_value(t, outcome, link.Outcome.Failed)
}

// A commit that takes longer than the daemon keeps a quiet connection open
// does not cost the requests for the laptop after it their delivery.
@(test)
a_long_commit_between_two_opens_does_not_drop_the_second :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	f.server.idle_ms = 200
	set_case(f, `[ "$n" = git ] && [ "$4" = commit ] && sleep 0.6` + "\n")
	start_daemon(f)
	for r in ([]link.Request{open_request(f, "https://example.org/1"), commit_request(f, "vault: slow"), open_request(f, "https://example.org/2")}) {
		expect_enqueued(f, r)
	}
	result, _ := link.flush(f.client)
	testing.expect_value(t, result.pending, 0)
	testing.expect_value(t, run_order(f), "xdg-open commit xdg-open")
}

// A run that found the lock held says so, and does not take the lock's
// whole wait; a request whose outcome another run recorded and compaction
// then dropped is reported delivered, not queued.
@(test)
a_busy_lock_and_a_dropped_outcome_are_told_as_they_are :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	testing.expect_value(t, link.ensure_dir(f.client.state), "")
	fd, why := link.open_state(join(f, "state", "deliver.lock"), true)
	testing.expect_value(t, why, "")
	testing.expect_value(t, link.lock(fd, {.EX}), linux.Errno.NONE)
	busy := f.client
	busy.lock_wait_ms = 100
	outcome, _ := link.submit(busy, open_request(f, "https://example.org/"))
	testing.expect_value(t, outcome, link.Outcome.Busy)
	link.lock(fd, {.UN})
	linux.close(fd)

	start_daemon(f)
	first := open_request(f, "https://example.org/erst")
	expect_enqueued(f, first)
	link.flush(f.client)
	for i in 0 ..< link.KEEP_RECORDS + 5 {
		link.submit(f.client, open_request(f, fmt.aprintf("https://example.org/%d", i, allocator = f.a)))
	}
	o, _ := link.outcome_of(f.client, first.id, {})
	testing.expect_value(t, o, link.Outcome.Delivered)
}

// A record that cannot be written is reported, not swallowed.
@(test)
a_record_that_cannot_be_written_is_reported :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	expect_enqueued(f, open_request(f, "https://example.org/"))
	acked := join(f, "state", "acked")
	write_file(f, acked, "")
	// A file that reads and takes no line, as on a full or read-only disk.
	testing.expect_value(t, os.chmod(acked, os.perm_number(0o400)), nil)
	_, why := link.flush(f.client)
	testing.expect_value(t, why, "")
	testing.expect(t, contains(stderr_text(f), "cannot record"), stderr_text(f))
	testing.expect_value(t, len(runs(f)), 1)
}

@(test)
the_state_is_the_users_alone :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	expect_enqueued(f, open_request(f, "https://example.org/"))
	link.flush(f.client)
	start_daemon(f)
	link.flush(f.client)
	Want :: struct {
		path: string,
		mode: u32,
	}
	for w in ([]Want{{f.client.state, 0o700}, {join(f, "state", "queue"), 0o600}, {join(f, "state", "acked"), 0o600}}) {
		info, err := os.stat(w.path, f.a)
		testing.expectf(t, err == nil, "%s: %v", w.path, err)
		mode := transmute(u32)info.mode & 0o777
		testing.expectf(t, mode == w.mode, "%s has mode %o", w.path, mode)
	}
}

@(test)
a_queue_above_its_limit_takes_no_more :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	expect_enqueued(f, open_request(f, "https://example.org/"))
	queue := join(f, "state", "queue")
	fd, err := os.open(queue, {.Write, .Append})
	testing.expect_value(t, err, nil)
	filler := strings.repeat("#", 1024 * 1024 - 1, f.a)
	for _ in 0 ..< link.MAX_QUEUE_BYTES / (1024 * 1024) {
		os.write_string(fd, filler)
		os.write_string(fd, "\n")
	}
	os.close(fd)
	why := link.enqueue(f.client, open_request(f, "https://example.org/zu-viel"))
	testing.expect(t, contains(why, "MiB"), why)
}

Loop :: struct {
	cfg:  link.Config,
	stop: bool,
	// The processor time the service took, in its thread.
	cpu:  time.Duration,
}

loop_worker :: proc(l: ^Loop) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	link.deliver(l.cfg, &l.stop, 50)
	ts, _ := linux.clock_gettime(.THREAD_CPUTIME_ID)
	l.cpu = time.Duration(ts.time_sec) * time.Second + time.Duration(ts.time_nsec)
}

// While the laptop is away, the service sleeps until the socket appears,
// the queue changes or a retry is due; it does not spin, and it reads no
// descriptor but its own.
@(test)
the_delivery_service_waits_without_spinning :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	expect_enqueued(f, open_request(f, "https://example.org/spaeter"))
	l := Loop{cfg = f.client}
	worker := thread.create_and_start_with_poly_data(&l, loop_worker, context)
	time.sleep(600 * time.Millisecond)
	sync.atomic_store(&l.stop, true)
	thread.join(worker)
	thread.destroy(worker)
	testing.expectf(t, l.cpu < 50 * time.Millisecond, "the service took %v of processor time in 600 ms", l.cpu)
	testing.expect_value(t, len(queue_lines(f)), 1)
}

// The service on muninn: it waits for the socket and delivers what is
// queued when the laptop comes back, with no client run to start it.
@(test)
the_delivery_service_delivers_when_the_laptop_comes_back :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	l := Loop{cfg = f.client}
	worker := thread.create_and_start_with_poly_data(&l, loop_worker, context)
	expect_enqueued(f, open_request(f, "https://example.org/zurueck"))
	time.sleep(200 * time.Millisecond)
	testing.expect_value(t, len(runs(f)), 0)
	start_daemon(f)
	deadline := time.tick_now()
	for len(runs(f)) == 0 && time.tick_since(deadline) < 5 * time.Second {
		time.sleep(20 * time.Millisecond)
	}
	sync.atomic_store(&l.stop, true)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect_value(t, len(runs(f)), 1)
}

Flusher :: struct {
	f:        ^Fixture,
	thread:   int,
	targets:  [dynamic]string,
	outcomes: [dynamic]link.Outcome,
}

// flusher_worker sends an open and a commit in turn, five of each; a
// commit's key is its message.
flusher_worker :: proc(w: ^Flusher) {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
	for i in 0 ..< 10 {
		r: link.Request
		key: string
		if i % 2 == 0 {
			key = fmt.aprintf("https://example.org/w%d/%d", w.thread, i, allocator = w.f.a)
			r = open_request(w.f, key)
		} else {
			key = fmt.aprintf("vault: w%d-%d", w.thread, i, allocator = w.f.a)
			r = link.Request{id = link.new_id(w.f.a), kind = .Vault_Commit, created = now(w.f), vault = w.f.client.vault, message = key}
		}
		outcome, _ := link.submit(w.f.client, r)
		append(&w.targets, key)
		append(&w.outcomes, outcome)
	}
}

// The service and four clients deliver from one queue at once, each with
// its own descriptor on deliver.lock, as processes have: every request
// runs once, and each client's requests run in the order it sent them.
// The daemon would run an open delivered twice only once; a commit runs
// here, and a slow git leaves time for a second delivery to run it again.
@(test)
the_service_and_clients_delivering_at_once_run_each_request_once_in_order :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	set_case(f, `[ "$n" = git ] && case " $* " in *" commit "*) sleep 0.05 ;; esac` + "\n")
	start_daemon(f)
	l := Loop{cfg = f.client}
	service := thread.create_and_start_with_poly_data(&l, loop_worker, context)
	// The fixture's arena is not safe from threads; each client gets its
	// own, and shares the first fixture's state.
	flushers: [4]Flusher
	fixtures: [4]^Fixture
	for i in 0 ..< len(flushers) {
		fixtures[i] = fixture(t)
		fixtures[i].client = f.client
		flushers[i] = Flusher {
			f        = fixtures[i],
			thread   = i,
			targets  = make([dynamic]string, fixtures[i].a),
			outcomes = make([dynamic]link.Outcome, fixtures[i].a),
		}
	}
	defer for x in fixtures {
		fixture_destroy(x)
	}
	threads: [4]^thread.Thread
	for &th, i in threads {
		th = thread.create_and_start_with_poly_data(&flushers[i], flusher_worker, context)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	sync.atomic_store(&l.stop, true)
	thread.join(service)
	thread.destroy(service)

	position := make(map[string]int, f.a)
	ran := 0
	for r, i in runs(f) {
		key: string
		switch {
		case r[0] == "xdg-open":
			key = r[1]
		case r[0] == "git" && git_sub(r) == "commit":
			key = r[len(r) - 1]
		case:
			continue
		}
		_, twice := position[key]
		testing.expectf(t, !twice, "%s ran twice", key)
		position[key] = i
		ran += 1
	}
	testing.expect_value(t, ran, 4 * 10)
	for w in flushers {
		last := -1
		for target, i in w.targets {
			testing.expectf(t, w.outcomes[i] == .Done || w.outcomes[i] == .Delivered, "%s: %v", target, w.outcomes[i])
			p, ok := position[target]
			testing.expectf(t, ok, "%s never ran", target)
			testing.expectf(t, p > last, "%s ran before a request its client sent first", target)
			last = p
		}
	}
	testing.expect_value(t, read_file(f, join(f, "state", "queue")), "")
}
