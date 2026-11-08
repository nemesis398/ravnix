// The tests of the command: each subcommand's arguments as a user or a
// program gives them, what it refuses, the exit codes, and the notify-send
// that muninn gets.
package ravnix_link_tests

import "core:os"
import "core:strings"
import "core:testing"
import link ".."

Ran :: struct {
	code: int,
	out:  string,
	err:  string,
}

// run_cli runs the command in this process with env, its output in files.
run_cli :: proc(f: ^Fixture, env: link.Environment, args: []string) -> (r: Ran) {
	out_path := join(f, "cli-stdout")
	err_path := join(f, "cli-stderr")
	out, _ := os.create(out_path)
	errf, _ := os.create(err_path)
	r.code = link.run(args, env, out, errf)
	os.close(out)
	os.close(errf)
	r.out = read_file(f, out_path)
	r.err = read_file(f, err_path)
	return
}

environment :: proc(f: ^Fixture) -> link.Environment {
	return link.Environment{runtime_dir = f.dir, state_home = join(f, "xdg-state"), home = f.dir, cwd = f.vault}
}

// cli runs the command as the fixture's client: its socket, state, vault
// and stand-ins.
cli :: proc(f: ^Fixture, args: ..string) -> Ran {
	all := make([dynamic]string, f.a)
	append(&all, "--socket", f.socket, "--state", f.client.state, "--vault", f.vault)
	append(&all, "--git", f.client.git, "--ravnix-notify", f.client.ravnix_notify)
	append(&all, ..args)
	return run_cli(f, environment(f), all[:])
}

queued_request :: proc(f: ^Fixture, index: int) -> link.Request {
	lines := queue_lines(f)
	if index >= len(lines) {
		testing.fail_now(f.t, "the request is not in the queue")
	}
	r, why := link.decode_request(lines[index], f.a)
	testing.expect_value(f.t, why, "")
	return r
}

@(test)
open_takes_one_target_and_makes_a_path_absolute :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	r := cli(f, "open", "Notizen/Über – x.pdf")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "")
	testing.expect(t, contains(r.err, "queued"), r.err)
	testing.expect_value(t, queued_request(f, 0).target, strings.concatenate({f.vault, "/Notizen/Über – x.pdf"}, f.a))
	r = cli(f, "open", "./a/../b.pdf")
	testing.expect_value(t, queued_request(f, 1).target, strings.concatenate({f.vault, "/b.pdf"}, f.a))
	r = cli(f, "open", "https://example.org/x")
	testing.expect_value(t, queued_request(f, 2).target, "https://example.org/x")
	for bad in ([][]string{{"open"}, {"open", "a", "b"}, {"open", "javascript:alert(1)"}, {"open", ""}}) {
		r = cli(f, ..bad)
		testing.expectf(t, r.code == 64, "%v gave %d: %s", bad, r.code, r.err)
	}
	testing.expect_value(t, len(queue_lines(f)), 3)
}

@(test)
done_is_silent_and_failed_says_why :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	r := cli(f, "open", "https://example.org/")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, r.out, "")
	testing.expect_value(t, r.err, "")
	set_case(f, `[ "$n" = xdg-open ] && { echo 'no handler' >&2; exit 4; }` + "\n")
	r = cli(f, "open", "https://example.org/")
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "exited with status 4"), r.err)
	testing.expect(t, contains(r.err, "journal"), r.err)
	// xdg-open's own words go to the daemon's standard error, the journal.
	testing.expect(t, contains(stderr_text(f), "no handler"), stderr_text(f))
}

@(test)
obsidian_takes_path_and_never_a_bare_name_or_permanent :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	ok := [][]string {
		{"obsidian", "move", "path=" + ODD_PATH, "to=Archiv"},
		{"obsidian", "rename", "name=Neu – Grüße", "path=" + ODD_PATH},
		{"obsidian", "delete", "path=Notizen/a b.md"},
	}
	for args in ok {
		r := cli(f, ..args)
		testing.expectf(t, r.code == 0, "%v: %d %s", args, r.code, r.err)
	}
	testing.expect_value(t, queued_request(f, 1).name, "Neu – Grüße")
	testing.expect_value(t, queued_request(f, 2).path, "Notizen/a b.md")
	refused := []struct {
		args: []string,
		says: string,
	} {
		{{"obsidian", "delete", "Notizen/a.md"}, "path="},
		{{"obsidian", "delete", "file=a"}, "path="},
		{{"obsidian", "delete", "path=a.md", "permanent"}, "permanent"},
		{{"obsidian", "delete", "path=a.md", "permanent=true"}, "permanent"},
		{{"obsidian", "delete", "path=a.md", "path=b.md"}, "twice"},
		{{"obsidian", "move", "path=a.md"}, "to="},
		{{"obsidian", "rename", "path=a.md", "to=b.md"}, "name="},
		{{"obsidian", "shred", "path=a.md"}, "move"},
		{{"obsidian"}, "move"},
		{{"obsidian", "delete", "vault=Other", "path=a.md"}, "vault="},
		{{"obsidian", "delete", "--help"}, "path="},
	}
	for c in refused {
		r := cli(f, ..c.args)
		testing.expectf(t, r.code == 64 && contains(r.err, c.says), "%v: %d %s", c.args, r.code, r.err)
	}
	testing.expect_value(t, len(queue_lines(f)), 3)
}

@(test)
vault_commit_needs_the_vault_and_commits_there :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	plain := []string{"--socket", f.socket, "--state", f.client.state, "--git", f.client.git, "vault-commit", "m"}
	r := run_cli(f, environment(f), plain)
	testing.expect_value(t, r.code, 64)
	testing.expect(t, contains(r.err, "server"), r.err)
	note(f, "Notizen/a b.md")
	r = cli(f, "vault-commit", "vault: ein Eintrag", "Notizen/a b.md")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, run_order(f), "add commit")
	got := git_runs(f, "commit")
	if len(got) == 1 {
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: ein Eintrag|--|Notizen/a b.md"}, f.a))
	}
	for bad in ([][]string{{"vault-commit"}, {"vault-commit", ""}, {"vault-commit", "m", "/abs.md"}, {"vault-commit", "m", "../x.md"}}) {
		r = cli(f, ..bad)
		testing.expectf(t, r.code == 64, "%v: %d %s", bad, r.code, r.err)
	}
	// Without paths it commits what is staged, as git commit does.
	r = cli(f, "vault-commit", "vault: staged")
	got = git_runs(f, "commit")
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, strings.join(got[1][1:], "|", f.a), strings.concatenate({"--literal-pathspecs|-C|", f.vault, "|commit|-m|vault: staged"}, f.a))
	}
}

@(test)
notify_with_a_topic_also_goes_to_its_matrix_room :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	r := cli(f, "notify", "Sitzung blockiert", "wartet auf dich", "--topic", "sessions")
	testing.expect_value(t, r.code, 0)
	room := runs_of(f, "ravnix-notify")
	testing.expect_value(t, len(room), 1)
	if len(room) == 1 {
		testing.expect_value(t, strings.join(room[0][1:], "|", f.a), "--topic|sessions|Sitzung blockiert\n\nwartet auf dich")
	}
	testing.expect_value(t, len(runs_of(f, "notify-send")), 1)
	// Without a topic, no Matrix.
	r = cli(f, "notify", "--urgency", "low", "nur", "hier")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, len(runs_of(f, "ravnix-notify")), 1)
	// The laptop away: the room still gets it; the popup waits.
	stop_daemon(f)
	r = cli(f, "notify", "--topic", "builds", "Build kaputt")
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, len(runs_of(f, "ravnix-notify")), 2)
	testing.expect(t, contains(r.err, "queued"), r.err)
	// No ravnix-notify: the topic's message reached no room, and it says so.
	all := []string{"--socket", f.socket, "--state", f.client.state, "--ravnix-notify", join(f, "bin", "missing"), "notify", "--topic", "builds", "x"}
	r = run_cli(f, environment(f), all)
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "Matrix"), r.err)
	for bad in ([][]string{{"notify"}, {"notify", ""}, {"notify", "a", "b", "c"}, {"notify", "--topic"}, {"notify", "--topic", "Bad Topic", "x"}, {"notify", "--urgency", "max", "x"}, {"notify", "--nope", "x"}}) {
		r = cli(f, ..bad)
		testing.expectf(t, r.code == 64, "%v: %d %s", bad, r.code, r.err)
	}
}

@(test)
notify_send_options_are_read_as_libnotify_reads_them :: proc(t: ^testing.T) {
	Case :: struct {
		args:                        []string,
		summary, body, urgency, app: string,
	}
	cases := []Case {
		{{"Hallo"}, "Hallo", "", "", ""},
		{{"Hallo", "Welt"}, "Hallo", "Welt", "", ""},
		{{"-u", "critical", "Hallo", "Welt"}, "Hallo", "Welt", "critical", ""},
		{{"-ucritical", "Hallo"}, "Hallo", "", "critical", ""},
		{{"--urgency=low", "Hallo"}, "Hallo", "", "low", ""},
		{{"--urgency", "normal", "Hallo"}, "Hallo", "", "normal", ""},
		{{"-a", "Claude Code", "-i", "dialog-question", "-t", "5000", "Frage", "Darf ich?"}, "Frage", "Darf ich?", "", "Claude Code"},
		{{"--app-name=herdr", "--icon=x", "--expire-time=1", "--category=im", "--hint=int:x:1", "--transient", "-e", "-r", "7", "-A", "ok=OK", "Frage"}, "Frage", "", "", "herdr"},
		{{"-h", "string:x-canonical-private-synchronous:a", "Hallo"}, "Hallo", "", "", ""},
		{{"--", "-u", "--body"}, "-u", "--body", "", ""},
		{{"Hallo", "-u", "low"}, "Hallo", "", "low", ""},
	}
	for c in cases {
		n, why := link.parse_notify_send(c.args)
		testing.expectf(t, why == "", "%v: %s", c.args, why)
		testing.expectf(t, n.summary == c.summary && n.body == c.body && n.urgency == c.urgency && n.app == c.app, "%v: %#v", c.args, n)
		testing.expect(t, !n.passthrough)
	}
	for args in ([][]string{{"--help"}, {"-?"}, {"--version"}, {"-v"}}) {
		n, why := link.parse_notify_send(args)
		testing.expect_value(t, why, "")
		testing.expect(t, n.passthrough, "help and version are notify-send's own")
	}
	for args in ([][]string{{}, {"a", "b", "c"}, {"-u"}, {"--urgency"}, {"-u", "max", "x"}, {"--nope", "x"}, {"-Z", "x"}, {""}}) {
		_, why := link.parse_notify_send(args)
		testing.expectf(t, why != "", "%v was taken", args)
	}
}

@(test)
notify_send_on_the_server_runs_the_real_one_and_forwards :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	start_daemon(f)
	real := join(f, "bin", "notify-send")
	set_case(f, `[ "$n" = notify-send ] && [ "$1" = -a ] && { echo "GDBus.Error: no notification server" >&2; exit 1; }` + "\n")
	all := []string{"--socket", f.socket, "--state", f.client.state, "--notify-send", real, "notify-send", "-a", "herdr", "-u", "critical", "Pane wartet", "Agent 2"}
	r := run_cli(f, environment(f), all)
	testing.expect_value(t, r.code, 0)
	testing.expectf(t, !contains(r.err, "GDBus"), "the real notify-send's complaint reached the caller: %s", r.err)
	got := runs_of(f, "notify-send")
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		// The real one with the caller's arguments, then the laptop's.
		testing.expect_value(t, strings.join(got[0][1:], "|", f.a), "-a|herdr|-u|critical|Pane wartet|Agent 2")
		testing.expect_value(t, strings.join(got[1][1:], "|", f.a), "-u|critical|-a|herdr|--|Pane wartet|Agent 2")
	}
	r = run_cli(f, environment(f), {"--socket", f.socket, "--state", f.client.state, "notify-send", "--bad"})
	testing.expect_value(t, r.code, 64)
	// --version is the real one's to answer, and nothing is forwarded.
	before := len(runs(f))
	r = run_cli(f, environment(f), {"--socket", f.socket, "--state", f.client.state, "--notify-send", real, "notify-send", "--version"})
	testing.expect_value(t, r.code, 0)
	testing.expect_value(t, len(runs(f)), before + 1)
}

@(test)
status_lists_what_waits :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	cli(f, "open", "https://example.org/eins")
	cli(f, "obsidian", "delete", "path=" + ODD_PATH)
	r := cli(f, "status")
	testing.expect_value(t, r.code, 0)
	testing.expect(t, contains(r.out, "2 requests wait"), r.out)
	testing.expect(t, contains(r.out, "open https://example.org/eins"), r.out)
	testing.expect(t, contains(r.out, "obsidian delete path=" + ODD_PATH), r.out)
	start_daemon(f)
	cli(f, "flush")
	r = cli(f, "status")
	testing.expect(t, contains(r.out, "nothing waits"), r.out)
}

@(test)
usage_errors_exit_64 :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	for bad in ([][]string{{}, {"frobnicate"}, {"--socket"}, {"--nope", "status"}, {"--state", "", "status"}, {"--socket", "a", "--socket", "b", "status"}, {"status", "extra"}, {"flush", "extra"}}) {
		r := run_cli(f, environment(f), bad)
		testing.expectf(t, r.code == 64, "%v: %d %s", bad, r.code, r.err)
	}
	r := run_cli(f, environment(f), {"--help"})
	testing.expect_value(t, r.code, 0)
	testing.expect(t, contains(r.out, "usage: ravnix-link"), r.out)
}

@(test)
the_environment_gives_the_socket_and_the_state :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	env := environment(f)
	cfg, why := link.config_from(env, f.a)
	testing.expect_value(t, why, "")
	testing.expect_value(t, cfg.socket, strings.concatenate({f.dir, "/ravnix-link.sock"}, f.a))
	testing.expect_value(t, cfg.state, strings.concatenate({env.state_home, "/ravnix-link"}, f.a))
	env.state_home = ""
	cfg, why = link.config_from(env, f.a)
	testing.expect_value(t, cfg.state, strings.concatenate({f.dir, "/.local/state/ravnix-link"}, f.a))
	// No runtime directory: the request still queues, the socket is unknown.
	env.runtime_dir = ""
	r := run_cli(f, env, {"--state", f.client.state, "open", "https://example.org/"})
	testing.expect_value(t, r.code, 0)
	testing.expect(t, contains(r.err, "queued"), r.err)
	// No home and no state directory: nowhere to queue.
	env.home = ""
	r = run_cli(f, env, {"open", "https://example.org/"})
	testing.expect_value(t, r.code, 1)
	testing.expect(t, contains(r.err, "HOME"), r.err)
}

// The daemon checks for the user manager's own socket before a scope, as
// systemd-run --user connects there, not to the D-Bus bus.
@(test)
the_user_manager_is_looked_for_in_the_runtime_directory :: proc(t: ^testing.T) {
	cfg, _ := link.config_from(link.Environment{runtime_dir = "/run/user/1000", home = "/home/alice"}, context.temp_allocator)
	testing.expect_value(t, cfg.user_manager, "/run/user/1000/systemd/private")
	cfg, _ = link.config_from(link.Environment{home = "/home/alice"}, context.temp_allocator)
	testing.expect_value(t, cfg.user_manager, "")
	free_all(context.temp_allocator)
}
