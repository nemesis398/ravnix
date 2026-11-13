// The update's three steps against the fake world of fake_update.odin:
// root's (check, bump or follow, build, verify, switch) and the user's
// (prepare: fetch and bump; finish: commit, push, roll, tell).
package claude_roll_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import roll ".."

// ---- root ----

@(test)
does_nothing_when_the_latest_version_runs :: proc(t: ^testing.T) {
	for latest in ([]string{"2.1.0", "2.1.0\n", "2.0.9", "1.99.99"}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest = latest
		log := strings.builder_make(f.a)
		outcome, status := roll.update(root_config(f, fu, .Bump, &log))
		testing.expect_value(t, outcome, roll.Update_Outcome.Current)
		testing.expect_value(t, status, 0)
		testing.expect_value(t, len(fu.calls), 1)
		testing.expect(t, strings.has_suffix(fu.calls[0], "https://downloads.claude.ai/claude-code-releases/latest"), fu.calls[0])
		testing.expect(t, !os.exists(pj(f.a, f.dir, "root", "result.json")))
	}
}

@(test)
does_nothing_when_the_latest_version_cannot_be_read :: proc(t: ^testing.T) {
	// The network is down, a portal answers, the answer is empty or no
	// version at all.
	for latest in ([]string{"", "<html>login</html>", "v2.2.0", "2.2.0-beta", "2.2.0.1.1", "9999999.0.0"}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest = latest
		fu.latest_fails = latest == ""
		log := strings.builder_make(f.a)
		outcome, status := roll.update(root_config(f, fu, .Bump, &log))
		testing.expectf(t, outcome == .Unreachable, "%q: %v", latest, outcome)
		testing.expect_value(t, status, roll.EXIT_LOCKED)
		testing.expect_value(t, len(fu.calls), 1)
		testing.expect(t, strings.contains(strings.to_string(log), "nothing was done"), strings.to_string(log))
	}
}

@(test)
bumps_builds_verifies_and_switches_a_newer_version :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.latest = "2.2.0"
	fu.version = "2.2.0"
	// The private flake's lock moved nixpkgs too since the deploy: root
	// takes only claude-code's nodes from it.
	cand := NEW_LOCK
	cand.nixpkgs_rev = "mmmm"
	cand.systems_rev = "tttt"
	fu.candidate = lock_text(f, cand)
	log := strings.builder_make(f.a)
	cfg := root_config(f, fu, .Bump, &log)
	outcome, status := roll.update(cfg)
	testing.expect_value(t, outcome, roll.Update_Outcome.Switched)
	testing.expect_value(t, status, 0)

	order := []string {
		"curl ",
		"systemctl --machine=alice@.host --user start -- ravnix-claude-update-prepare.service",
		"setpriv --reuid=alice --regid=users --clear-groups -- cat -- /home/alice/.local/state/ravnix/claude-update/candidate.lock",
		"cp ",
		"nix --extra-experimental-features nix-command flakes eval --raw --no-write-lock-file --override-input ravnix /nix/store/0000000000000000000000000000000c-source path:",
		"nix --extra-experimental-features nix-command flakes build --no-link --print-out-paths --no-write-lock-file --override-input ravnix",
		"nix --extra-experimental-features nix-command flakes build --no-link --print-out-paths --no-write-lock-file --override-input ravnix",
		"claude-code-verify --releases https://downloads.claude.ai/claude-code-releases " + DOWNLOAD + " 2.2.0",
		"nix-env --profile /nix/var/nix/profiles/system --set " + TOPLEVEL,
		TOPLEVEL + "/bin/switch-to-configuration switch",
		"systemctl --machine=alice@.host --user start --no-block -- ravnix-claude-update-finish.service",
	}
	testing.expect_value(t, len(fu.calls), len(order))
	for want, i in order {
		if i < len(fu.calls) {
			testing.expectf(t, strings.has_prefix(fu.calls[i], want), "call %d: %q, want %q", i, fu.calls[i], want)
		}
	}
	// An override for an input the flake does not have is dropped.
	testing.expect(t, !called(fu, "nix --extra-experimental-features nix-command flakes eval --raw --no-write-lock-file --override-input absent"))
	testing.expect(t, strings.has_suffix(fu.calls[4], "#nixosConfigurations.muninn.config.home-manager.users.alice.programs.claude-code.package.version"), fu.calls[4])
	testing.expect(t, strings.has_suffix(fu.calls[5], "#nixosConfigurations.muninn.config.system.build.toplevel"), fu.calls[5])

	// The copy's lock: the deployed one, with claude-code's nodes of the
	// candidate, its nixpkgs the deployed one.
	data, _ := os.read_entire_file(pj(f.a, f.dir, "root", "work", "flake.lock"), f.a)
	built, err := roll.parse_lock(data, f.a)
	testing.expect_value(t, err, "")
	rev :: proc(l: roll.Lock, node: string) -> string {
		n, _ := l.nodes[node].(json.Object)
		locked, _ := n["locked"].(json.Object)
		s, _ := locked["rev"].(json.String)
		return s
	}
	testing.expect_value(t, rev(built, "claude-code"), "bbbb")
	testing.expect_value(t, rev(built, "systems"), "tttt")
	testing.expect_value(t, rev(built, "nixpkgs"), "nnnn")
	testing.expect_value(t, rev(built, "ravnix"), "rrrr")

	r, perr := roll.parse_result(read_result(f), f.a)
	testing.expect_value(t, perr, "")
	testing.expect_value(t, r.status, "switched")
	testing.expect_value(t, r.from, "2.1.0")
	testing.expect_value(t, r.to, "2.2.0")
	testing.expect_value(t, r.host, "muninn")
	testing.expect_value(t, r.candidate, roll.sha256_hex(transmute([]byte)fu.candidate))
}

read_result :: proc(f: ^Fixture) -> []byte {
	data, _ := os.read_entire_file(pj(f.a, f.dir, "root", "result.json"), f.a)
	return data
}

expect_untouched :: proc(t: ^testing.T, fu: ^Fake_Update, loc := #caller_location) {
	testing.expect(t, !called(fu, "nix-env"), "the profile was set", loc = loc)
	testing.expect(t, !called(fu, TOPLEVEL), "switch-to-configuration ran", loc = loc)
}

@(test)
a_failed_build_switches_nothing :: proc(t: ^testing.T) {
	for what in ([]string{"eval", "build", "download"}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest, fu.version = "2.2.0", "2.2.0"
		fu.candidate = lock_text(f, NEW_LOCK)
		fu.eval_fails = what == "eval"
		fu.build_fails = what == "build"
		fu.download_fails = what == "download"
		log := strings.builder_make(f.a)
		outcome, status := roll.update(root_config(f, fu, .Bump, &log))
		testing.expectf(t, outcome == .Build_Failed, "%s: %v", what, outcome)
		testing.expect_value(t, status, 1)
		expect_untouched(t, fu)
		testing.expect(t, !called(fu, "claude-code-verify"))
		r, _ := roll.parse_result(read_result(f), f.a)
		testing.expect_value(t, r.status, "build-failed")
		testing.expect(t, strings.contains(r.message, "stays on 2.1.0"), r.message)
		testing.expect(t, strings.contains(r.message, "error: "), r.message)
		testing.expect(t, !strings.contains(r.message, "Updated input"), r.message)
		// The user's side is told, to tell the user.
		testing.expect(t, called(fu, "systemctl --machine=alice@.host --user start --no-block -- ravnix-claude-update-finish.service"))
	}
}

@(test)
a_download_anthropic_did_not_release_is_never_switched_to :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.latest, fu.version = "2.2.0", "2.2.0"
	fu.candidate = lock_text(f, NEW_LOCK)
	fu.verify_exit = 1
	log := strings.builder_make(f.a)
	outcome, status := roll.update(root_config(f, fu, .Bump, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Verify_Failed)
	testing.expect_value(t, status, 1)
	expect_untouched(t, fu)
	r, _ := roll.parse_result(read_result(f), f.a)
	testing.expect_value(t, r.status, "verify-failed")
}

@(test)
an_unreachable_manifest_waits_for_the_next_run :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.latest, fu.version = "2.2.0", "2.2.0"
	fu.candidate = lock_text(f, NEW_LOCK)
	fu.verify_exit = 3
	log := strings.builder_make(f.a)
	outcome, status := roll.update(root_config(f, fu, .Bump, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Verify_Unreachable)
	testing.expect_value(t, status, roll.EXIT_LOCKED)
	expect_untouched(t, fu)
	testing.expect(t, !called(fu, "systemctl --machine=alice@.host --user start --no-block"))
}

@(test)
a_failed_switch_is_told :: proc(t: ^testing.T) {
	for which in ([]string{"profile", "switch"}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest, fu.version = "2.2.0", "2.2.0"
		fu.candidate = lock_text(f, NEW_LOCK)
		fu.nix_env_fails = which == "profile"
		fu.switch_fails = which == "switch"
		log := strings.builder_make(f.a)
		outcome, status := roll.update(root_config(f, fu, .Bump, &log))
		testing.expect_value(t, outcome, roll.Update_Outcome.Switch_Failed)
		testing.expect_value(t, status, 1)
		testing.expect_value(t, called(fu, TOPLEVEL), which == "switch")
		r, _ := roll.parse_result(read_result(f), f.a)
		testing.expect_value(t, r.status, "switch-failed")
	}
}

@(test)
waits_when_claude_code_nix_has_not_caught_up :: proc(t: ^testing.T) {
	// No new revision at all, and a new revision with an old version.
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.latest = "2.2.0"
	fu.candidate = lock_text(f, OLD_LOCK)
	log := strings.builder_make(f.a)
	outcome, status := roll.update(root_config(f, fu, .Bump, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Not_Moved)
	testing.expect_value(t, status, 0)
	testing.expect(t, !called(fu, "nix "))

	g := fixture(t)
	defer fixture_destroy(g)
	gu := fake_update(g)
	gu.latest, gu.version = "2.2.0", "2.1.0"
	gu.candidate = lock_text(g, NEW_LOCK)
	outcome, status = roll.update(root_config(g, gu, .Bump, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Not_Newer)
	testing.expect_value(t, status, 0)
	testing.expect(t, !called(gu, "nix --extra-experimental-features nix-command flakes build"))
	testing.expect(t, !called(gu, "systemctl --machine=alice@.host --user start --no-block"))
}

@(test)
refuses_a_lock_that_points_claude_code_elsewhere :: proc(t: ^testing.T) {
	bad := []Lock_Spec {
		{cc_rev = "bbbb", cc_owner = "mallory", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"},
		{cc_rev = "bbbb", cc_original = "mallory", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"},
		{cc_rev = "bbbb", cc_extra = true, systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"},
	}
	for spec in bad {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest, fu.version = "2.2.0", "2.2.0"
		fu.candidate = lock_text(f, spec)
		log := strings.builder_make(f.a)
		outcome, status := roll.update(root_config(f, fu, .Bump, &log))
		testing.expect_value(t, outcome, roll.Update_Outcome.Refused)
		testing.expect_value(t, status, 1)
		testing.expect(t, !called(fu, "nix "))
		r, _ := roll.parse_result(read_result(f), f.a)
		testing.expect_value(t, r.status, "refused")
	}
	// Not a lock at all, and one too large to be one.
	for text in ([]string{"{}", "not json", strings.repeat(" ", 5 << 20, context.temp_allocator)}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest = "2.2.0"
		fu.candidate = text
		log := strings.builder_make(f.a)
		outcome, _ := roll.update(root_config(f, fu, .Bump, &log))
		testing.expect_value(t, outcome, roll.Update_Outcome.Refused)
		testing.expect(t, !called(fu, "nix "))
	}
	free_all(context.temp_allocator)
}

@(test)
nothing_is_built_when_the_users_side_fails :: proc(t: ^testing.T) {
	// A locked vault, a refused token: the prepare unit fails. Or it leaves
	// no candidate.
	for which in ([]string{"prepare", "candidate"}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.latest = "2.2.0"
		fu.prepare_fails = which == "prepare"
		if which != "candidate" {
			fu.candidate = lock_text(f, NEW_LOCK)
		}
		log := strings.builder_make(f.a)
		outcome, _ := roll.update(root_config(f, fu, .Bump, &log))
		testing.expect_value(t, outcome, roll.Update_Outcome.Prepare_Failed)
		testing.expect(t, !called(fu, "nix "))
		testing.expect(t, !called(fu, "cp "))
	}
}

@(test)
a_second_update_at_once_does_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.latest = "2.2.0"
	log := strings.builder_make(f.a)
	cfg := root_config(f, fu, .Bump, &log)
	_ = os.make_directory_all(cfg.state_dir)
	held, ok := roll.take_lock(pj(f.a, cfg.state_dir, roll.UPDATE_LOCK))
	testing.expect(t, ok)
	outcome, status := roll.update(cfg)
	os.close(held)
	testing.expect_value(t, outcome, roll.Update_Outcome.Locked)
	testing.expect_value(t, status, roll.EXIT_LOCKED)
	testing.expect_value(t, len(fu.calls), 0)
	// Released, it runs. Another test's child may hold a copy of the lock's
	// file between its fork and its exec (the file is close-on-exec), so
	// the run is tried for a while.
	fu.latest = "2.1.0"
	for _ in 0 ..< 100 {
		if outcome, _ = roll.update(cfg); outcome != .Locked {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, outcome, roll.Update_Outcome.Current)
}

@(test)
follows_the_lock_without_asking_for_the_latest_version :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.version = "2.2.0"
	fu.candidate = lock_text(f, NEW_LOCK)
	log := strings.builder_make(f.a)
	cfg := root_config(f, fu, .Follow, &log)
	cfg.host = "huginn"
	outcome, status := roll.update(cfg)
	testing.expect_value(t, outcome, roll.Update_Outcome.Switched)
	testing.expect_value(t, status, 0)
	testing.expect(t, !called(fu, "curl"))
	testing.expect(t, called(fu, TOPLEVEL + "/bin/switch-to-configuration switch"))
	r, _ := roll.parse_result(read_result(f), f.a)
	testing.expect_value(t, r.mode, "follow")

	// A lock that has not moved: nothing.
	g := fixture(t)
	defer fixture_destroy(g)
	gu := fake_update(g)
	gu.candidate = lock_text(g, OLD_LOCK)
	outcome, status = roll.update(root_config(g, gu, .Follow, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Not_Moved)
	testing.expect_value(t, len(gu.calls), 2)
}

@(test)
never_follows_a_lock_back_to_an_older_version :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.version = "2.0.0"
	fu.candidate = lock_text(f, NEW_LOCK)
	log := strings.builder_make(f.a)
	outcome, status := roll.update(root_config(f, fu, .Follow, &log))
	testing.expect_value(t, outcome, roll.Update_Outcome.Not_Newer)
	testing.expect_value(t, status, 1)
	testing.expect(t, !called(fu, "nix --extra-experimental-features nix-command flakes build"))
	expect_untouched(t, fu)
	r, _ := roll.parse_result(read_result(f), f.a)
	testing.expect(t, strings.contains(r.message, "not newer"), r.message)
}

// ---- the user's side: prepare ----

prepare_config :: proc(f: ^Fixture, fu: ^Fake_Update, mode: roll.Update_Mode, log: ^strings.Builder) -> roll.Prepare_Config {
	state := pj(f.a, f.dir, "user")
	return {
		mode = mode,
		remote = REMOTE,
		branch = "main",
		input = "claude-code",
		state_dir = state,
		repo = pj(f.a, state, "flake.git"),
		host = "muninn",
		notify = "ravnix-notify",
		hooks = hooks_of(fu),
		log = log,
	}
}

read_text :: proc(f: ^Fixture, parts: ..string) -> string {
	data, err := os.read_entire_file(pj(f.a, ..parts), f.a)
	if err != nil {
		return ""
	}
	return string(data)
}

@(test)
prepare_bumps_the_input_in_a_tree_of_its_own :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.remote_lock = lock_text(f, OLD_LOCK)
	fu.updated_lock = lock_text(f, NEW_LOCK)
	log := strings.builder_make(f.a)
	status := roll.prepare(prepare_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 0)
	testing.expect_value(t, read_text(f, f.dir, "user", "candidate.lock"), fu.updated_lock)
	testing.expect_value(t, read_text(f, f.dir, "user", "base"), BASE + "\n")
	testing.expect(t, called(fu, cat(f, "git init --bare --quiet -- ", pj(f.a, f.dir, "user", "flake.git"))))
	testing.expect(t, called(fu, cat(f, "git --git-dir=", pj(f.a, f.dir, "user", "flake.git"), " fetch --quiet --no-tags -- " + REMOTE + " +refs/heads/main:refs/remotes/origin/main")))
	testing.expect(t, called(fu, "nix --extra-experimental-features nix-command flakes flake update claude-code --flake path:"))
	testing.expect(t, called(fu, cat(f, "git --git-dir=", pj(f.a, f.dir, "user", "flake.git"), " rev-parse --verify --quiet refs/remotes/origin/main^{commit}")))
	// The tree is gone, and so is its index.
	testing.expect(t, !os.exists(pj(f.a, f.dir, "user", "tree")))
	testing.expect(t, !os.exists(pj(f.a, f.dir, "user", "tree.index")))
	testing.expect_value(t, len(fu.notified), 0)

	// A second run finds the repository and does not make it again.
	before := count(fu, "git init")
	status = roll.prepare(prepare_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 0)
	testing.expect_value(t, count(fu, "git init"), before)
}

@(test)
prepare_refuses_an_update_that_moves_more_than_the_input :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.remote_lock = lock_text(f, OLD_LOCK)
	more := NEW_LOCK
	more.nixpkgs_rev = "mmmm"
	fu.updated_lock = lock_text(f, more)
	log := strings.builder_make(f.a)
	status := roll.prepare(prepare_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 1)
	testing.expect(t, !os.exists(pj(f.a, f.dir, "user", "candidate.lock")))
	testing.expect_value(t, len(fu.notified), 1)
	if len(fu.notified) == 1 {
		testing.expect(t, strings.contains(note(fu), "nixpkgs"), note(fu))
	}
}

@(test)
prepare_tells_why_it_cannot_fetch :: proc(t: ^testing.T) {
	// The token helper's words when the vault is locked, and a refused
	// token.
	for why in ([]string {
			"ravnix-git-token: the vault is locked, so the token for https://git.example.org/alice/private.git cannot be read; unlock it with ai-unlock\nfatal: could not read Username for 'https://git.example.org': terminal prompts disabled",
			"remote: Unauthorized\nfatal: Authentication failed for 'https://git.example.org/alice/private.git/'",
		}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		fu.fetch_fails = true
		fu.fetch_error = why
		log := strings.builder_make(f.a)
		status := roll.prepare(prepare_config(f, fu, .Bump, &log))
		testing.expect_value(t, status, 1)
		testing.expect(t, !called(fu, "nix "))
		testing.expect(t, !os.exists(pj(f.a, f.dir, "user", "candidate.lock")))
		testing.expect_value(t, len(fu.notified), 1)
		if len(fu.notified) == 1 {
			last := why[strings.last_index_byte(why, '\n') + 1:]
			testing.expect(t, strings.contains(note(fu), last), note(fu))
		}
	}
}

@(test)
prepare_tells_a_failed_flake_update :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.remote_lock = lock_text(f, OLD_LOCK)
	log := strings.builder_make(f.a)
	status := roll.prepare(prepare_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 1)
	testing.expect(t, !os.exists(pj(f.a, f.dir, "user", "candidate.lock")))
	testing.expect_value(t, len(fu.notified), 1)
}

@(test)
prepare_follows_by_reading_the_fetched_lock :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.remote_lock = lock_text(f, NEW_LOCK)
	log := strings.builder_make(f.a)
	cfg := prepare_config(f, fu, .Follow, &log)
	status := roll.prepare(cfg)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, read_text(f, f.dir, "user", "candidate.lock"), fu.remote_lock)
	testing.expect(t, !called(fu, "nix "))
	testing.expect(t, !called(fu, cat(f, "git --git-dir=", cfg.repo, " push")))

	// A branch without a flake.lock.
	fu.remote_lock = ""
	status = roll.prepare(cfg)
	testing.expect_value(t, status, 1)
}

@(test)
prepare_runs_once_at_a_time :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	log := strings.builder_make(f.a)
	cfg := prepare_config(f, fu, .Bump, &log)
	_ = os.make_directory_all(cfg.state_dir)
	held, ok := roll.take_lock(pj(f.a, cfg.state_dir, roll.UPDATE_LOCK))
	testing.expect(t, ok)
	status := roll.prepare(cfg)
	os.close(held)
	testing.expect_value(t, status, roll.EXIT_LOCKED)
	testing.expect_value(t, len(fu.calls), 0)
}

// ---- the user's side: finish ----

finish_config :: proc(f: ^Fixture, fu: ^Fake_Update, mode: roll.Update_Mode, log: ^strings.Builder) -> roll.Finish_Config {
	state := pj(f.a, f.dir, "user")
	units := make([]string, 2, f.a)
	units[0], units[1] = "claude-roll.service", "claude-remote-control-roll.service"
	return {
		mode = mode,
		remote = REMOTE,
		branch = "main",
		state_dir = state,
		repo = pj(f.a, state, "flake.git"),
		result = pj(f.a, f.dir, "root", "result.json"),
		notify = "ravnix-notify",
		roll_units = units,
		hooks = hooks_of(fu),
		log = log,
	}
}

// prepared writes what prepare leaves, and root's result for it.
prepared :: proc(f: ^Fixture, status: string, candidate_hash := "") -> string {
	candidate := lock_text(f, NEW_LOCK)
	_ = os.make_directory_all(pj(f.a, f.dir, "user"))
	_ = os.make_directory_all(pj(f.a, f.dir, "root"))
	write_file(f, pj(f.a, f.dir, "user", "candidate.lock"), candidate)
	write_file(f, pj(f.a, f.dir, "user", "base"), BASE + "\n")
	hash := candidate_hash if candidate_hash != "" else roll.sha256_hex(transmute([]byte)candidate)
	message := "" if status == "switched" else "Claude Code 2.2.0 did not build on muninn, which stays on 2.1.0."
	b := strings.builder_make(f.a)
	strings.write_string(&b, `{"id":"17","status":`)
	roll.write_json_string(&b, status)
	strings.write_string(&b, `,"mode":"bump","host":"muninn","from":"2.1.0","to":"2.2.0","candidate":`)
	roll.write_json_string(&b, hash)
	strings.write_string(&b, `,"message":`)
	roll.write_json_string(&b, message)
	strings.write_string(&b, "}\n")
	write_file(f, pj(f.a, f.dir, "root", "result.json"), strings.to_string(b))
	return candidate
}

@(test)
finish_commits_signed_onto_the_base_pushes_and_rolls :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	candidate := prepared(f, "switched")
	log := strings.builder_make(f.a)
	cfg := finish_config(f, fu, .Bump, &log)
	status := roll.finish(cfg)
	testing.expect_value(t, status, 0)
	git := cat(f, "git --git-dir=", cfg.repo)
	order := []string {
		cat(f, git, " hash-object -w --stdin"),
		cat(f, git, " read-tree " + BASE),
		cat(f, git, " update-index --cacheinfo 100644," + BLOB + ",flake.lock"),
		cat(f, git, " write-tree"),
		cat(f, git, " commit-tree -S " + TREE + " -p " + BASE + " -F -"),
		cat(f, git, " push --quiet -- " + REMOTE + " " + COMMIT + ":refs/heads/main"),
		"ravnix-notify --topic updates --",
		"systemctl --user start --no-block -- claude-roll.service claude-remote-control-roll.service",
	}
	testing.expect_value(t, len(fu.calls), len(order))
	for want, i in order {
		if i < len(fu.calls) {
			testing.expectf(t, strings.has_prefix(fu.calls[i], want), "call %d: %q, want %q", i, fu.calls[i], want)
		}
	}
	testing.expect_value(t, fu.inputs[0], candidate)
	testing.expect(t, strings.has_prefix(fu.inputs[4], "chore: update Claude Code to 2.2.0\n\n"), fu.inputs[4])
	testing.expect(t, strings.contains(note(fu), "muninn runs Claude Code 2.2.0 now (was 2.1.0)"), note(fu))

	// The same result again: handled already, nothing done twice.
	n := len(fu.calls)
	status = roll.finish(cfg)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, len(fu.calls), n)
}

@(test)
finish_tells_a_refused_push_and_still_rolls :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.push_fails = true
	prepared(f, "switched")
	log := strings.builder_make(f.a)
	status := roll.finish(finish_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 1)
	testing.expect_value(t, len(fu.notified), 1)
	testing.expect(t, strings.contains(note(fu), "pre-receive hook declined"), note(fu))
	testing.expect(t, called(fu, "systemctl --user start --no-block -- claude-roll.service"))
}

@(test)
finish_pushes_nothing_it_could_not_sign :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	fu.commit_fails = true
	prepared(f, "switched")
	log := strings.builder_make(f.a)
	cfg := finish_config(f, fu, .Bump, &log)
	status := roll.finish(cfg)
	testing.expect_value(t, status, 1)
	testing.expect(t, !called(fu, cat(f, "git --git-dir=", cfg.repo, " push")))
	testing.expect(t, strings.contains(note(fu), "could not be committed"), note(fu))
	testing.expect(t, called(fu, "systemctl --user start --no-block"))
}

@(test)
finish_publishes_only_the_lock_root_built :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	prepared(f, "switched", strings.repeat("0", 64, f.a))
	log := strings.builder_make(f.a)
	cfg := finish_config(f, fu, .Bump, &log)
	status := roll.finish(cfg)
	testing.expect_value(t, status, 1)
	testing.expect(t, !called(fu, "git "))
	testing.expect_value(t, len(fu.notified), 1)
}

@(test)
finish_only_tells_a_failure :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	prepared(f, "build-failed")
	log := strings.builder_make(f.a)
	status := roll.finish(finish_config(f, fu, .Bump, &log))
	testing.expect_value(t, status, 0)
	testing.expect_value(t, len(fu.calls), 1)
	testing.expect_value(t, note(fu), "Claude Code 2.2.0 did not build on muninn, which stays on 2.1.0.")
}

@(test)
finish_on_the_laptop_tells_and_pushes_nothing :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	fu := fake_update(f)
	prepared(f, "switched")
	log := strings.builder_make(f.a)
	cfg := finish_config(f, fu, .Follow, &log)
	status := roll.finish(cfg)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, len(fu.calls), 1)
	testing.expect(t, strings.has_prefix(fu.calls[0], "ravnix-notify --topic updates"))
}

@(test)
finish_refuses_a_result_it_cannot_read :: proc(t: ^testing.T) {
	for text in ([]string{"", "nope", `{"id":"1"}`, `{"id":"1","status":"switched","to":"x"}`, `{"id":"1","status":"build-failed"}`, `[]`}) {
		f := fixture(t)
		defer fixture_destroy(f)
		fu := fake_update(f)
		_ = os.make_directory_all(pj(f.a, f.dir, "root"))
		if text != "" {
			write_file(f, pj(f.a, f.dir, "root", "result.json"), text)
		}
		log := strings.builder_make(f.a)
		status := roll.finish(finish_config(f, fu, .Bump, &log))
		testing.expectf(t, status == 1, "%q: %d", text, status)
		testing.expect_value(t, len(fu.calls), 0)
	}
}

// ---- versions and the command line ----

@(test)
reads_versions :: proc(t: ^testing.T) {
	for v in ([]string{"2.1.323", "1", "0.0.1", "10.20.30.40", "999999.0.0"}) {
		testing.expectf(t, roll.valid_version(v), "%q", v)
	}
	for v in ([]string{"", ".", "2.", ".2", "2..1", "v2", "2.1.0-rc1", "2 .1", "1.2.3.4.5", "1234567.0", "2.1.0\n"}) {
		testing.expectf(t, !roll.valid_version(v), "%q", v)
	}
	testing.expect_value(t, roll.compare_versions("2.1.323", "2.1.99"), 1)
	testing.expect_value(t, roll.compare_versions("2.1.99", "2.1.323"), -1)
	testing.expect_value(t, roll.compare_versions("2.1", "2.1.0"), 0)
	testing.expect_value(t, roll.compare_versions("3", "2.99.99"), 1)
	testing.expect_value(t, roll.compare_versions("2.1.0", "2.1.0"), 0)
}

@(test)
parses_the_update_command_lines :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	env := roll.Environment{state_home = "/s", home = "/h"}
	a, err := roll.parse_args({"update", "--mode", "bump", "--flake", "/nix/store/x-source", "--host", "muninn", "--user", "alice", "--group", "users", "--running", "2.1.0", "--candidate", "/home/alice/c.lock", "--override", "ravnix=/nix/store/y-source", "--override=other=/z"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.command, roll.Command.Update)
	testing.expect_value(t, a.update.package_attr, "home-manager.users.alice.programs.claude-code.package")
	testing.expect_value(t, a.update.releases, roll.DEFAULT_RELEASES)
	testing.expect_value(t, len(a.update.overrides), 2)
	testing.expect_value(t, a.update.state_dir, "/var/lib/ravnix-claude-update")

	a, err = roll.parse_args({"update-prepare", "--mode=follow", "--remote", REMOTE, "--host", "huginn"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.prepare.mode, roll.Update_Mode.Follow)
	testing.expect_value(t, a.prepare.state_dir, "/s/ravnix/claude-update")
	testing.expect_value(t, a.prepare.repo, "/s/ravnix/claude-update/flake.git")
	testing.expect_value(t, a.prepare.branch, "main")

	a, err = roll.parse_args({"update-finish", "--mode", "bump", "--remote", REMOTE, "--roll-unit", "a.service", "--roll-unit", "b.service"}, roll.Environment{home = "/h"}, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(a.finish.roll_units), 2)
	testing.expect_value(t, a.finish.state_dir, "/h/.local/state/ravnix/claude-update")
	testing.expect_value(t, a.finish.result, "/var/lib/ravnix-claude-update/result.json")

	a, err = roll.parse_args({"remote-control", "--deadline", "5m"}, env, f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, a.rc.deadline, 5 * time.Minute)
	testing.expect_value(t, a.rc.unit, "claude-remote-control.service")

	for bad in ([][]string {
			{"update"},
			{"update", "--mode", "sideways", "--flake", "/f", "--host", "h", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c"},
			{"update", "--mode", "bump", "--flake", "/f", "--host", "h x", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c"},
			{"update", "--mode", "bump", "--flake", "/f", "--host", "h", "--user", "u", "--group", "g", "--running", "latest", "--candidate", "/c"},
			{"update", "--mode", "bump", "--flake", "f", "--host", "h", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c"},
			{"update", "--mode", "bump", "--flake", "/f", "--host", "h", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c", "--releases", "http://x"},
			{"update", "--mode", "bump", "--flake", "/f", "--host", "h", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c", "--package", "a..b"},
			{"update", "--mode", "bump", "--flake", "/f", "--host", "h", "--user", "u", "--group", "g", "--running", "1", "--candidate", "/c", "--override", "ravnix"},
			{"update", "--mode", "bump", "--flake", "/f", "--flake", "/g"},
			{"update-prepare", "--mode", "bump", "--host", "h"},
			{"update-prepare", "--mode", "bump", "--remote", "http://x/y.git", "--host", "h"},
			{"update-prepare", "--mode", "bump", "--remote", REMOTE},
			{"update-prepare", "--mode", "bump", "--remote", REMOTE, "--host", "h", "--branch", "../x"},
			{"update-prepare", "--mode", "bump", "--remote", REMOTE, "--host", "h", "--branch", "-f"},
			{"update-finish", "--mode", "bump", "--remote", REMOTE, "--roll-unit", "-x"},
			{"update-finish", "--mode", "bump", "--remote", REMOTE, "--unknown", "1"},
			{"remote-control", "--deadline", "forever"},
			{"remote-control", "--unit", "no unit"},
			{"remote-control", "--unit"},
			{"remote-control", "--unit", "a.service\nb"},
		}) {
		_, e := roll.parse_args(bad, env, f.a)
		testing.expectf(t, e != "", "accepted %v", bad)
	}
	_, err = roll.parse_args({"update-prepare", "--mode", "bump", "--remote", REMOTE, "--host", "h"}, roll.Environment{}, f.a)
	testing.expect(t, err != "", "no state directory to be found")
}

cat :: proc(f: ^Fixture, parts: ..string) -> string {
	return strings.concatenate(parts, f.a)
}
