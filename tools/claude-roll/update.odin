// The Claude Code update: the twice-daily timer's work, split by who may do
// what (README.md, "The update").
//
//   claude-roll update            root, the timer's unit. On the server
//                                 (--mode bump) it asks downloads.claude.ai
//                                 for the latest version and stops when
//                                 the host runs it. Then it has the user's
//                                 side prepare a lock (the unit
//                                 --prepare-unit). On the server it takes
//                                 only the input's nodes from it into a
//                                 copy of the flake the host was deployed
//                                 from; on the laptop (--mode follow) the
//                                 lock only says that the server moved,
//                                 and root runs `nix flake update INPUT`
//                                 on that copy itself. Then it builds,
//                                 checks the download with
//                                 claude-code-verify, switches, and has the
//                                 user's side finish (--finish-unit).
//   claude-roll update-prepare    the user: fetches the private flake over
//                                 HTTPS (git asks the user's token helper),
//                                 and on the server runs `nix flake update
//                                 INPUT` on it; the lock it leaves is the
//                                 candidate. On the laptop a locked vault
//                                 ends it with 75, quietly.
//   claude-roll update-finish     the user: on the server commits the
//                                 candidate, signed, onto what it fetched,
//                                 pushes it, and starts the roll; on both,
//                                 tells the user what happened.
//
// Root never runs anything the user wrote: the flake it builds is the one
// the host was deployed from, a store path, and of a new lock it takes only
// the input's nodes, and only a new revision of the same repository
// (lockfile.odin). Which revision, a lock cannot vouch for: GitHub serves a
// fork's commit under the upstream's URL, and claude-code-verify checks the
// download the revision's own package names. So the laptop takes no
// revision from the lock the server's account pushed and asks the input's
// repository itself; the server takes its own account's, whose package runs
// as that account anyway. The user's side holds the token and the signing
// key, which live in the user's vault, so the account never gets root and
// root never reads the vault.
package claude_roll

import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

Update_Mode :: enum {
	// The server: bump the input, build, switch, commit and push.
	Bump,
	// The laptop: when the lock the server pushed moved the input, move it
	// to the head of its branch itself, build and switch.
	Follow,
}

DEFAULT_RELEASES :: "https://downloads.claude.ai/claude-code-releases"
DEFAULT_ROOT_STATE :: "/var/lib/ravnix-claude-update"
DEFAULT_PROFILE :: "/nix/var/nix/profiles/system"
DEFAULT_INPUT :: "claude-code"
DEFAULT_BRANCH :: "main"
PREPARE_UNIT :: "ravnix-claude-update-prepare.service"
FINISH_UNIT :: "ravnix-claude-update-finish.service"
UPDATE_TOPIC :: "updates"

UPDATE_LOCK :: "update.lock"
RESULT_NAME :: "result.json"
CANDIDATE_NAME :: "candidate.lock"
BASE_NAME :: "base"
FINISHED_NAME :: "finished"
PENDING_NAME :: "pending"

// The most a command of the update may print: a nix build's log.
MAX_UPDATE_OUTPUT :: 16 << 20

// How long each step may take.
LATEST_TIMEOUT :: 60 * time.Second
PREPARE_TIMEOUT :: 30 * time.Minute
EVAL_TIMEOUT :: 30 * time.Minute
BUILD_TIMEOUT :: 3 * time.Hour
VERIFY_TIMEOUT :: 2 * time.Minute
SWITCH_TIMEOUT :: 30 * time.Minute
UNIT_TIMEOUT :: 60 * time.Second
GIT_TIMEOUT :: 5 * time.Minute
FLAKE_UPDATE_TIMEOUT :: 15 * time.Minute

// claude-code-verify's exit status for a manifest it could not reach.
VERIFY_UNREACHABLE :: 3

// One command of the update: its words, where it runs, what it adds to
// the environment (NAME=VALUE), and what it reads on standard input.
Cmd :: struct {
	argv:    []string,
	dir:     string,
	env:     []string,
	input:   []byte,
	timeout: time.Duration,
}

// The seams of the tests; nil is the real thing.
Update_Hooks :: struct {
	data:  rawptr,
	run:   proc(data: rawptr, cmd: Cmd) -> Run_Result,
	now:   proc(data: rawptr) -> time.Time,
	sleep: proc(data: rawptr, d: time.Duration),
}

Override :: struct {
	name, path: string,
}

Update_Config :: struct {
	mode:         Update_Mode,
	// The flake the host was deployed from: a store path, never a checkout.
	flake:        string,
	// Its nixosConfigurations.<host>.
	host:         string,
	// The account whose units prepare and finish, and its group.
	user:         string,
	group:        string,
	input:        string,
	// The Claude Code package, below the host's config.
	package_attr: string,
	releases:     string,
	// The Claude Code version the host runs.
	running:      string,
	state_dir:    string,
	// Where the user's side leaves its lock; read as the user.
	candidate:    string,
	prepare_unit: string,
	finish_unit:  string,
	profile:      string,
	// Inputs to build with as the running system was built, such as the
	// ravnix it came from: NAME and a path.
	overrides:    []Override,
	hooks:        Update_Hooks,
	log:          ^strings.Builder,
}

Update_Outcome :: enum {
	Failed,
	// Another update holds the lock.
	Locked,
	// The latest version could not be read.
	Unreachable,
	// The host runs the latest version.
	Current,
	// The user's side could not fetch or bump.
	Prepare_Failed,
	// The lock has not moved: nothing new to follow or to bump to.
	Not_Moved,
	// The new lock holds a version that is not newer than the running one.
	Not_Newer,
	// The candidate changes more than a revision of the input.
	Refused,
	Build_Failed,
	Verify_Failed,
	// claude-code-verify could not reach the manifest: try again later.
	Verify_Unreachable,
	Switch_Failed,
	Switched,
	// The laptop's user side cannot run: the vault is locked, or no user
	// manager runs. The retry timer tries again.
	Waiting,
}

default_update_config :: proc() -> Update_Config {
	return {
		input = DEFAULT_INPUT,
		releases = DEFAULT_RELEASES,
		state_dir = DEFAULT_ROOT_STATE,
		prepare_unit = PREPARE_UNIT,
		finish_unit = FINISH_UNIT,
		profile = DEFAULT_PROFILE,
	}
}

// What a run of the update shares: the seams, the log and an arena.
Updater :: struct {
	hooks:  Update_Hooks,
	log:    ^strings.Builder,
	notify: string,
	name:   string,
}

update :: proc(cfg: Update_Config) -> (outcome: Update_Outcome, status: int) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return .Failed, EXIT_FAILED
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	u := Updater{hooks = cfg.hooks, log = cfg.log, name = "claude-roll update"}
	outcome, status = run_update(&u, cfg)
	if cfg.mode == .Follow && outcome != .Locked {
		// The laptop's retry timer runs the update while this marker is
		// there (modules/workbench/claude-update.nix).
		pending, _ := filepath.join({cfg.state_dir, PENDING_NAME})
		#partial switch outcome {
		case .Waiting, .Unreachable, .Verify_Unreachable:
			if !write_atomic(pending, transmute([]byte)fmt.tprintf("%v\n", outcome)) {
				ulog(&u, "cannot write %s, so no retry runs before the next timer", pending)
			}
		case:
			if e := os.remove(pending); e != nil && os.exists(pending) {
				ulog(&u, "cannot remove %s", pending)
			}
		}
	}
	return outcome, status
}

@(private = "file")
run_update :: proc(u: ^Updater, cfg: Update_Config) -> (Update_Outcome, int) {
	if e := os.make_directory_all(cfg.state_dir); e != nil && e != os.General_Error.Exist {
		ulog(u, "cannot make the state directory %s", cfg.state_dir)
		return .Failed, EXIT_FAILED
	}
	lock_path, _ := filepath.join({cfg.state_dir, UPDATE_LOCK})
	lock, held := take_lock(lock_path)
	defer if lock != nil {
		os.close(lock)
	}
	if !held {
		if lock == nil {
			ulog(u, "cannot open the lock %s", lock_path)
			return .Failed, EXIT_FAILED
		}
		ulog(u, "another update is running (it holds %s); nothing done", lock_path)
		return .Locked, EXIT_LOCKED
	}
	if !valid_version(cfg.running) {
		ulog(u, "the running version %q is no version", cfg.running)
		return .Failed, EXIT_FAILED
	}

	if cfg.mode == .Bump {
		latest, ok := fetch_latest(u, cfg.releases)
		if !ok {
			return .Unreachable, EXIT_LOCKED
		}
		if compare_versions(latest, cfg.running) <= 0 {
			ulog(u, "this host runs Claude Code %s, and the latest is %s: nothing to do", cfg.running, latest)
			return .Current, EXIT_OK
		}
		ulog(u, "Claude Code %s is out, and this host runs %s", latest, cfg.running)
	}

	// The user's side: fetch, and on the server bump.
	res := urun(u, {argv = {"systemctl", fmt.tprintf("--machine=%s@.host", cfg.user), "--user", "start", "--", cfg.prepare_unit}, timeout = PREPARE_TIMEOUT})
	if !succeeded_update(res) {
		if cfg.mode == .Follow {
			// The laptop at 06:00, or at boot before anyone logged in: the
			// vault is locked (prepare exits 75), or no user manager runs to
			// ask. Nobody is told; the retry timer tries again.
			show := urun(u, {argv = {"systemctl", fmt.tprintf("--machine=%s@.host", cfg.user), "--user", "show", "--property=ExecMainStatus", "--value", "--", cfg.prepare_unit}, timeout = UNIT_TIMEOUT})
			if !succeeded_update(show) || strings.trim_space(string(show.stdout)) == "75" {
				ulog(u, "the user's side cannot run now (%s): %s's vault is locked, or no manager of theirs runs. Nothing was done; the update tries again every hour until it can", tail(describe(res)), cfg.user)
				return .Waiting, EXIT_LOCKED
			}
		}
		ulog(u, "the user's side (%s of %s) failed, so nothing was built: %s; its journal says why (journalctl --user -u %s)", cfg.prepare_unit, cfg.user, describe(res), cfg.prepare_unit)
		return .Prepare_Failed, EXIT_LOCKED
	}
	res = urun(u, {argv = {"setpriv", fmt.tprintf("--reuid=%s", cfg.user), fmt.tprintf("--regid=%s", cfg.group), "--clear-groups", "--", "cat", "--", cfg.candidate}, timeout = UNIT_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "cannot read the lock the user's side left in %s: %s", cfg.candidate, describe(res))
		return .Prepare_Failed, EXIT_FAILED
	}
	candidate_bytes := res.stdout
	candidate_hash := sha256_hex(candidate_bytes)

	deployed_path, _ := filepath.join({cfg.flake, "flake.lock"})
	deployed_bytes, rerr := os.read_entire_file(deployed_path, context.allocator)
	if rerr != nil {
		ulog(u, "cannot read the deployed flake's lock %s", deployed_path)
		return .Failed, EXIT_FAILED
	}
	deployed, perr := parse_lock(deployed_bytes, context.allocator)
	if perr != "" {
		ulog(u, "the deployed flake's lock: %s", perr)
		return .Failed, EXIT_FAILED
	}
	r := Result {
		status    = "refused",
		mode      = "bump" if cfg.mode == .Bump else "follow",
		host      = cfg.host,
		from      = cfg.running,
		candidate = candidate_hash,
	}
	candidate, cerr := parse_lock(candidate_bytes, context.allocator)
	if cerr != "" {
		r.message = fmt.tprintf("The update on %s took nothing from the private flake's lock, which it cannot read: %s. %s stays on Claude Code %s.", cfg.host, cerr, cfg.host, cfg.running)
		return finish_with(u, cfg, r, .Refused)
	}
	nix := [?]string{"nix", "--extra-experimental-features", "nix-command flakes"}
	work, _ := filepath.join({cfg.state_dir, "work"})
	lock_file, _ := filepath.join({work, "flake.lock"})

	// What is built. On the server, the candidate's nodes of the input: the
	// lock the user's side bumped. On the laptop the candidate, which the
	// server's account wrote, is only the sign that there is something to
	// follow: root moves the input itself, to the head of its own branch,
	// so a revision only a fork has (GitHub serves those under the
	// upstream's URL too) is never taken from the lock.
	source := candidate
	pushed := ""
	if cfg.mode == .Follow {
		pushed = input_rev(candidate, cfg.input)
		if pushed == "" || pushed == input_rev(deployed, cfg.input) {
			ulog(u, "the private flake's lock has not moved the %s input; nothing to follow", cfg.input)
			return .Not_Moved, EXIT_OK
		}
		if !copy_flake(u, cfg.flake, work) {
			return .Failed, EXIT_FAILED
		}
		argv := make([dynamic]string)
		append(&argv, ..nix[:])
		append(&argv, "flake", "update", "--refresh", cfg.input, "--flake", fmt.tprintf("path:%s", work))
		res = urun(u, {argv = argv[:], dir = work, timeout = FLAKE_UPDATE_TIMEOUT})
		if !succeeded_update(res) {
			ulog(u, "the private flake's lock names revision %s of the %s input, but the input's own repository could not be asked for its head, so nothing was done; the update tries again within the hour: %s", short_rev(pushed), cfg.input, tail(describe(res)))
			return .Unreachable, EXIT_LOCKED
		}
		own_bytes, oerr := os.read_entire_file(lock_file, context.allocator)
		if oerr != nil {
			ulog(u, "nix left no flake.lock in %s", work)
			return .Failed, EXIT_FAILED
		}
		own, perr2 := parse_lock(own_bytes, context.allocator)
		if perr2 != "" {
			ulog(u, "the lock nix wrote: %s", perr2)
			return .Failed, EXIT_FAILED
		}
		source = own
	}

	moved, names, merr := compare_input(deployed, source, cfg.input, context.allocator)
	if merr == "" && cfg.mode == .Follow {
		if what, same := others_equal(deployed, source, names); !same {
			merr = fmt.tprintf("it also changed %s", what)
		}
	}
	if merr != "" {
		if cfg.mode == .Follow {
			r.message = fmt.tprintf("The update on %s refused what its own `nix flake update %s` did to the lock: %s. %s stays on Claude Code %s.", cfg.host, cfg.input, merr, cfg.host, cfg.running)
		} else {
			r.message = fmt.tprintf("The update on %s refused the private flake's lock: %s. Only a new revision of the %s input is taken; %s stays on Claude Code %s.", cfg.host, merr, cfg.input, cfg.host, cfg.running)
		}
		return finish_with(u, cfg, r, .Refused)
	}
	if !moved {
		if cfg.mode == .Bump {
			ulog(u, "the %s input has no newer revision yet; the next run tries again", cfg.input)
		} else {
			ulog(u, "the private flake's lock names revision %s of the %s input, but the head of the input's branch is still the revision %s runs, so nothing was taken", short_rev(pushed), cfg.input, cfg.host)
		}
		return .Not_Moved, EXIT_OK
	}

	// The deployed flake with the input's nodes put in.
	if cfg.mode == .Bump && !copy_flake(u, cfg.flake, work) {
		return .Failed, EXIT_FAILED
	}
	if e := os.write_entire_file(lock_file, splice(deployed, source, names, context.allocator)); e != nil {
		ulog(u, "cannot write %s", lock_file)
		return .Failed, EXIT_FAILED
	}

	root_inputs, _ := node_inputs(deployed, deployed.root)
	over := make([dynamic]string)
	for o in cfg.overrides {
		if _, has := root_inputs[o.name]; has {
			append(&over, "--override-input", o.name, o.path)
		}
	}
	config := fmt.tprintf("path:%s#nixosConfigurations.%s.config", work, cfg.host)
	pkg := fmt.tprintf("%s.%s", config, cfg.package_attr)

	argv := make([dynamic]string)
	append(&argv, ..nix[:])
	append(&argv, "eval", "--raw", "--no-write-lock-file")
	append(&argv, ..over[:])
	append(&argv, fmt.tprintf("%s.version", pkg))
	res = urun(u, {argv = argv[:], timeout = EVAL_TIMEOUT})
	version := strings.trim_space(string(res.stdout))
	if !succeeded_update(res) || !valid_version(version) {
		r.status = "build-failed"
		r.message = fmt.tprintf("Claude Code from the new lock did not evaluate on %s, which stays on %s: %s", cfg.host, cfg.running, nix_error(res))
		return finish_with(u, cfg, r, .Build_Failed)
	}
	r.to = version
	if compare_versions(version, cfg.running) <= 0 {
		if cfg.mode == .Bump {
			ulog(u, "the %s input's newest revision has Claude Code %s, not newer than %s; the next run tries again", cfg.input, version, cfg.running)
			return .Not_Newer, EXIT_OK
		}
		r.message = fmt.tprintf("The private flake's lock holds Claude Code %s, which is not newer than the %s that %s runs, so %s stays on it. Going back to an older version is a deploy by hand.", version, cfg.running, cfg.host, cfg.host)
		return finish_with(u, cfg, r, .Not_Newer)
	}

	clear(&argv)
	append(&argv, ..nix[:])
	append(&argv, "build", "--no-link", "--print-out-paths", "--no-write-lock-file")
	append(&argv, ..over[:])
	append(&argv, fmt.tprintf("%s.system.build.toplevel", config))
	res = urun(u, {argv = argv[:], timeout = BUILD_TIMEOUT})
	toplevel := strings.trim_space(string(res.stdout))
	if !succeeded_update(res) || !strings.has_prefix(toplevel, "/") || strings.contains_any(toplevel, "\n ") {
		r.status = "build-failed"
		r.message = fmt.tprintf("Claude Code %s did not build on %s, which stays on %s; nothing was switched or pushed. %s", version, cfg.host, cfg.running, nix_error(res))
		return finish_with(u, cfg, r, .Build_Failed)
	}
	clear(&argv)
	append(&argv, ..nix[:])
	append(&argv, "build", "--no-link", "--print-out-paths", "--no-write-lock-file")
	append(&argv, ..over[:])
	append(&argv, fmt.tprintf("%s.download", pkg))
	res = urun(u, {argv = argv[:], timeout = BUILD_TIMEOUT})
	download := strings.trim_space(string(res.stdout))
	if !succeeded_update(res) || !strings.has_prefix(download, "/") || strings.contains_any(download, "\n ") {
		r.status = "build-failed"
		r.message = fmt.tprintf("The download of Claude Code %s, which claude-code-verify checks, did not build on %s, which stays on %s. %s", version, cfg.host, cfg.running, nix_error(res))
		return finish_with(u, cfg, r, .Build_Failed)
	}

	res = urun(u, {argv = {"claude-code-verify", "--releases", cfg.releases, download, version}, timeout = VERIFY_TIMEOUT})
	if res.start_error == "" && !res.timed_out && res.exit_code == VERIFY_UNREACHABLE {
		ulog(u, "Anthropic's manifest for %s could not be reached, so nothing was switched; the next run tries again: %s", version, describe(res))
		return .Verify_Unreachable, EXIT_LOCKED
	}
	if !succeeded_update(res) {
		r.status = "verify-failed"
		r.message = fmt.tprintf("The Claude Code %s that %s built is not the one Anthropic released (claude-code-verify: %s), so %s stays on %s; nothing was switched or pushed.", version, cfg.host, tail(describe(res)), cfg.host, cfg.running)
		return finish_with(u, cfg, r, .Verify_Failed)
	}

	res = urun(u, {argv = {"nix-env", "--profile", cfg.profile, "--set", toplevel}, timeout = SWITCH_TIMEOUT})
	if !succeeded_update(res) {
		r.status = "switch-failed"
		r.message = fmt.tprintf("Claude Code %s built on %s, but the system profile could not be set (%s), so %s stays on %s.", version, cfg.host, tail(describe(res)), cfg.host, cfg.running)
		return finish_with(u, cfg, r, .Switch_Failed)
	}
	switch_to, _ := filepath.join({toplevel, "bin", "switch-to-configuration"})
	res = urun(u, {argv = {switch_to, "switch"}, timeout = SWITCH_TIMEOUT})
	if !succeeded_update(res) {
		r.status = "switch-failed"
		r.message = fmt.tprintf("The switch of %s to Claude Code %s failed: %s. The new generation is the default one now; look at it before the next boot.", cfg.host, version, tail(describe(res)))
		return finish_with(u, cfg, r, .Switch_Failed)
	}
	r.status = "switched"
	ulog(u, "switched to Claude Code %s (%s)", version, toplevel)
	if cfg.mode == .Follow {
		took := input_rev(source, cfg.input)
		if took == pushed {
			r.message = fmt.tprintf("%s runs Claude Code %s now (was %s), from the head of the %s input's branch, which the private flake's lock names too; Anthropic's manifest vouches for the binary.", cfg.host, version, cfg.running, cfg.input)
		} else {
			r.message = fmt.tprintf("%s runs Claude Code %s now (was %s), from the head of the %s input's branch (%s). The private flake's lock names %s instead, which %s did not take; Anthropic's manifest vouches for the binary.", cfg.host, version, cfg.running, cfg.input, short_rev(took), short_rev(pushed), cfg.host)
		}
	}
	return finish_with(u, cfg, r, .Switched)
}

// What root hands the user's side: written to the state directory, which
// the user can read.
Result :: struct {
	id:        string,
	status:    string,
	mode:      string,
	host:      string,
	from:      string,
	to:        string,
	// The sha256 of the candidate lock root took the input's nodes from.
	candidate: string,
	message:   string,
}

@(private = "file")
finish_with :: proc(u: ^Updater, cfg: Update_Config, r: Result, outcome: Update_Outcome) -> (Update_Outcome, int) {
	r := r
	if r.message != "" {
		ulog(u, "%s", r.message)
	}
	r.id = fmt.tprintf("%d", time.to_unix_nanoseconds(unow(u)))
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	fields := [?][2]string {
		{"id", r.id},
		{"status", r.status},
		{"mode", r.mode},
		{"host", r.host},
		{"from", r.from},
		{"to", r.to},
		{"candidate", r.candidate},
		{"message", r.message},
	}
	for f, i in fields {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		write_json_string(&b, f[0])
		strings.write_byte(&b, ':')
		write_json_string(&b, f[1])
	}
	strings.write_string(&b, "}\n")
	path, _ := filepath.join({cfg.state_dir, RESULT_NAME})
	status := EXIT_OK if outcome == .Switched else EXIT_FAILED
	if !write_atomic(path, transmute([]byte)strings.to_string(b)) {
		ulog(u, "cannot write %s, so the user's side is not told", path)
		return outcome, EXIT_FAILED
	}
	res := urun(u, {argv = {"systemctl", fmt.tprintf("--machine=%s@.host", cfg.user), "--user", "start", "--no-block", "--", cfg.finish_unit}, timeout = UNIT_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "cannot start %s of %s: %s", cfg.finish_unit, cfg.user, describe(res))
		status = EXIT_FAILED
	}
	return outcome, status
}

@(private = "file")
fetch_latest :: proc(u: ^Updater, releases: string) -> (version: string, ok: bool) {
	url := fmt.tprintf("%s/latest", strings.trim_right(releases, "/"))
	res := urun(u, {argv = {"curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "30", "--max-filesize", "1024", "--", url}, timeout = LATEST_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "cannot read the latest version from %s, so nothing was done; the next run tries again: %s", url, describe(res))
		return "", false
	}
	version = strings.trim_space(string(res.stdout))
	if !valid_version(version) {
		ulog(u, "%s answered with no version (%d bytes), so nothing was done; the next run tries again", url, len(res.stdout))
		return "", false
	}
	return version, true
}

// copy_flake copies the deployed flake, a store path, to a directory root
// may write.
@(private = "file")
copy_flake :: proc(u: ^Updater, flake, work: string) -> bool {
	if e := os.remove_all(work); e != nil && os.exists(work) {
		ulog(u, "cannot clear %s", work)
		return false
	}
	res := urun(u, {argv = {"cp", "-r", "--no-preserve=mode,ownership,timestamps", "-T", "--", flake, work}, timeout = UNIT_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "cannot copy the deployed flake %s: %s", flake, describe(res))
		return false
	}
	return true
}

// short_rev is a revision as people read it. The server's lock names it,
// so what is no hex digit is not passed on into a message.
short_rev :: proc(rev: string) -> string {
	short := rev[:min(len(rev), 12)]
	for c in transmute([]byte)short {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return "(no revision)"
		}
	}
	return short
}

// ---- The user's side: prepare ----

Prepare_Config :: struct {
	mode:      Update_Mode,
	// The private flake's HTTPS remote: the URL git's token helper answers.
	remote:    string,
	branch:    string,
	input:     string,
	// $XDG_STATE_HOME/ravnix/claude-update: the candidate, the base, the lock.
	state_dir: string,
	// A bare repository of the update's own; never a checkout of the user's.
	repo:      string,
	host:      string,
	notify:    string,
	hooks:     Update_Hooks,
	log:       ^strings.Builder,
}

// The environment of every git command: no prompt, no askpass, plain
// messages.
@(rodata)
GIT_ENV := [?]string{"GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=", "SSH_ASKPASS=", "LC_ALL=C"}

prepare :: proc(cfg: Prepare_Config) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return EXIT_FAILED
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	u := Updater{hooks = cfg.hooks, log = cfg.log, notify = cfg.notify, name = "claude-roll update-prepare"}
	return run_prepare(&u, cfg)
}

@(private = "file")
run_prepare :: proc(u: ^Updater, cfg: Prepare_Config) -> int {
	lock, status := user_lock(u, cfg.state_dir)
	if lock == nil {
		return status
	}
	defer os.close(lock)

	if cfg.mode == .Follow {
		// On the laptop the vault locks after an hour idle, and is locked at
		// boot, when the timer catches up. That is no failure to tell: exit
		// 75, and root's retry tries again once it is unlocked.
		res := urun(u, {argv = {"rbw", "unlocked"}, timeout = UNIT_TIMEOUT})
		if res.start_error != "" {
			tell_update(u, fmt.tprintf("The update on %s cannot ask rbw whether the vault is unlocked (%s); Claude Code stays on its version.", cfg.host, res.start_error))
			return EXIT_FAILED
		}
		if !succeeded_update(res) {
			ulog(u, "the vault is locked, so the private flake is not fetched now; the update tries again every hour until it is unlocked")
			return EXIT_LOCKED
		}
	}

	base, ok := fetch_flake(u, cfg.repo, cfg.remote, cfg.branch, cfg.host)
	if !ok {
		return EXIT_FAILED
	}
	git_dir := fmt.tprintf("--git-dir=%s", cfg.repo)
	res := urun(u, {argv = {"git", git_dir, "show", fmt.tprintf("%s:flake.lock", base)}, env = GIT_ENV[:], timeout = GIT_TIMEOUT})
	if !succeeded_update(res) {
		tell_update(u, fmt.tprintf("The update on %s found no flake.lock on %s of %s (%s); Claude Code stays on its version.", cfg.host, cfg.branch, cfg.remote, tail(describe(res))))
		return EXIT_FAILED
	}
	old_bytes := res.stdout
	old, perr := parse_lock(old_bytes, context.allocator)
	if perr != "" {
		tell_update(u, fmt.tprintf("The update on %s cannot read the flake.lock on %s of %s: %s. Claude Code stays on its version.", cfg.host, cfg.branch, cfg.remote, perr))
		return EXIT_FAILED
	}
	candidate := old_bytes

	if cfg.mode == .Bump {
		tree, _ := filepath.join({cfg.state_dir, "tree"})
		index, _ := filepath.join({cfg.state_dir, "tree.index"})
		defer {
			_ = os.remove_all(tree)
			_ = os.remove(index)
		}
		_ = os.remove_all(tree)
		_ = os.remove(index)
		if e := os.make_directory_all(tree); e != nil {
			ulog(u, "cannot make %s", tree)
			return EXIT_FAILED
		}
		env := make([dynamic]string)
		append(&env, ..GIT_ENV[:])
		append(&env, fmt.tprintf("GIT_INDEX_FILE=%s", index))
		work_tree := fmt.tprintf("--work-tree=%s", tree)
		res = urun(u, {argv = {"git", git_dir, work_tree, "read-tree", base}, dir = tree, env = env[:], timeout = GIT_TIMEOUT})
		if succeeded_update(res) {
			res = urun(u, {argv = {"git", git_dir, work_tree, "checkout-index", "--all", "--force"}, dir = tree, env = env[:], timeout = GIT_TIMEOUT})
		}
		if !succeeded_update(res) {
			ulog(u, "cannot check out %s into %s: %s", base, tree, describe(res))
			return EXIT_FAILED
		}
		res = urun(u, {argv = {"nix", "--extra-experimental-features", "nix-command flakes", "flake", "update", cfg.input, "--flake", fmt.tprintf("path:%s", tree)}, dir = tree, timeout = FLAKE_UPDATE_TIMEOUT})
		if !succeeded_update(res) {
			tell_update(u, fmt.tprintf("The update on %s could not update the %s input (%s); Claude Code stays on its version, and the next run tries again.", cfg.host, cfg.input, tail(describe(res))))
			return EXIT_FAILED
		}
		new_path, _ := filepath.join({tree, "flake.lock"})
		new_bytes, rerr := os.read_entire_file(new_path, context.allocator)
		if rerr != nil {
			ulog(u, "nix left no flake.lock in %s", tree)
			return EXIT_FAILED
		}
		new, nerr := parse_lock(new_bytes, context.allocator)
		if nerr != "" {
			ulog(u, "the lock nix wrote: %s", nerr)
			return EXIT_FAILED
		}
		_, names, merr := compare_input(old, new, cfg.input, context.allocator)
		if merr == "" {
			if what, same := others_equal(old, new, names); !same {
				merr = fmt.tprintf("it also changed %s", what)
			}
		}
		if merr != "" {
			tell_update(u, fmt.tprintf("The update on %s refused what `nix flake update %s` did to the lock: %s. Claude Code stays on its version.", cfg.host, cfg.input, merr))
			return EXIT_FAILED
		}
		candidate = new_bytes
	}

	candidate_path, _ := filepath.join({cfg.state_dir, CANDIDATE_NAME})
	base_path, _ := filepath.join({cfg.state_dir, BASE_NAME})
	if !write_atomic(candidate_path, candidate) || !write_atomic(base_path, transmute([]byte)fmt.tprintf("%s\n", base)) {
		ulog(u, "cannot write the candidate to %s", cfg.state_dir)
		return EXIT_FAILED
	}
	ulog(u, "the candidate lock is in %s, on %s", candidate_path, base)
	return EXIT_OK
}

// fetch_flake fetches the branch of the remote into the update's own bare
// repository, making it the first time, and returns the commit.
@(private = "file")
fetch_flake :: proc(u: ^Updater, repo, remote, branch, host: string) -> (commit: string, ok: bool) {
	head, _ := filepath.join({repo, "HEAD"})
	if !os.exists(head) {
		res := urun(u, {argv = {"git", "init", "--bare", "--quiet", "--", repo}, env = GIT_ENV[:], timeout = GIT_TIMEOUT})
		if !succeeded_update(res) {
			ulog(u, "cannot make the repository %s: %s", repo, describe(res))
			return "", false
		}
	}
	git_dir := fmt.tprintf("--git-dir=%s", repo)
	ref := fmt.tprintf("refs/remotes/origin/%s", branch)
	res := urun(u, {argv = {"git", git_dir, "fetch", "--quiet", "--no-tags", "--", remote, fmt.tprintf("+refs/heads/%s:%s", branch, ref)}, env = GIT_ENV[:], timeout = GIT_TIMEOUT})
	if !succeeded_update(res) {
		tell_update(u, fmt.tprintf("The update on %s could not fetch %s of %s (%s); Claude Code stays on its version until a run can.", host, branch, remote, tail(describe(res))))
		return "", false
	}
	res = urun(u, {argv = {"git", git_dir, "rev-parse", "--verify", "--quiet", fmt.tprintf("%s^{{commit}}", ref)}, env = GIT_ENV[:], timeout = GIT_TIMEOUT})
	commit = strings.trim_space(string(res.stdout))
	if !succeeded_update(res) || !valid_commit(commit) {
		ulog(u, "the fetched %s is no commit: %s", ref, describe(res))
		return "", false
	}
	return commit, true
}

// ---- The user's side: finish ----

Finish_Config :: struct {
	mode:       Update_Mode,
	remote:     string,
	branch:     string,
	state_dir:  string,
	repo:       string,
	// Root's result.json.
	result:     string,
	notify:     string,
	// The units that roll the sessions, started after a switch.
	roll_units: []string,
	hooks:      Update_Hooks,
	log:        ^strings.Builder,
}

finish :: proc(cfg: Finish_Config) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return EXIT_FAILED
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	u := Updater{hooks = cfg.hooks, log = cfg.log, notify = cfg.notify, name = "claude-roll update-finish"}
	return run_finish(&u, cfg)
}

@(private = "file")
run_finish :: proc(u: ^Updater, cfg: Finish_Config) -> int {
	lock, status := user_lock(u, cfg.state_dir)
	if lock == nil {
		return status
	}
	defer os.close(lock)

	data, rerr := os.read_entire_file(cfg.result, context.allocator)
	if rerr != nil {
		ulog(u, "cannot read root's result %s", cfg.result)
		return EXIT_FAILED
	}
	r, perr := parse_result(data)
	if perr != "" {
		ulog(u, "root's result %s: %s", cfg.result, perr)
		return EXIT_FAILED
	}
	finished_path, _ := filepath.join({cfg.state_dir, FINISHED_NAME})
	if last, err := os.read_entire_file(finished_path, context.allocator); err == nil && strings.trim_space(string(last)) == r.id {
		ulog(u, "the result %s is handled already", r.id)
		return EXIT_OK
	}
	defer write_atomic(finished_path, transmute([]byte)fmt.tprintf("%s\n", r.id))

	if r.status != "switched" {
		tell_update(u, r.message)
		return EXIT_OK
	}
	if cfg.mode == .Follow {
		if r.message != "" {
			tell_update(u, r.message)
		} else {
			tell_update(u, fmt.tprintf("%s runs Claude Code %s now (was %s).", r.host, r.to, r.from))
		}
		return EXIT_OK
	}

	status = EXIT_OK
	published := publish(u, cfg, r)
	if !published {
		status = EXIT_FAILED
	}
	if len(cfg.roll_units) > 0 {
		argv := make([dynamic]string)
		append(&argv, "systemctl", "--user", "start", "--no-block", "--")
		append(&argv, ..cfg.roll_units)
		res := urun(u, {argv = argv[:], timeout = UNIT_TIMEOUT})
		if !succeeded_update(res) {
			tell_update(u, fmt.tprintf("%s runs Claude Code %s now, but the roll of the sessions did not start (%s); run `systemctl --user start %s`.", r.host, r.to, tail(describe(res)), strings.join(cfg.roll_units, " ")))
			status = EXIT_FAILED
		}
	}
	return status
}

// publish commits the candidate onto the commit it was made from, signed,
// and pushes it. The commit is made without a checkout, in the update's own
// repository, so no working tree can be dirty and none of the user's is
// touched.
@(private = "file")
publish :: proc(u: ^Updater, cfg: Finish_Config, r: Result) -> bool {
	candidate_path, _ := filepath.join({cfg.state_dir, CANDIDATE_NAME})
	base_path, _ := filepath.join({cfg.state_dir, BASE_NAME})
	candidate, cerr := os.read_entire_file(candidate_path, context.allocator)
	base_bytes, berr := os.read_entire_file(base_path, context.allocator)
	base := strings.trim_space(string(base_bytes))
	if cerr != nil || berr != nil || !valid_commit(base) || sha256_hex(candidate) != r.candidate {
		tell_update(u, fmt.tprintf("%s runs Claude Code %s now (was %s), but the lock it was built from is not the one this side prepared, so nothing was committed or pushed.", r.host, r.to, r.from))
		return false
	}
	git_dir := fmt.tprintf("--git-dir=%s", cfg.repo)
	index, _ := filepath.join({cfg.state_dir, "commit.index"})
	_ = os.remove(index)
	defer {
		_ = os.remove(index)
	}
	env := make([dynamic]string)
	append(&env, ..GIT_ENV[:])
	append(&env, fmt.tprintf("GIT_INDEX_FILE=%s", index))

	why := ""
	res := urun(u, {argv = {"git", git_dir, "hash-object", "-w", "--stdin"}, env = GIT_ENV[:], input = candidate, timeout = GIT_TIMEOUT})
	blob := strings.trim_space(string(res.stdout))
	tree := ""
	commit := ""
	switch {
	case !succeeded_update(res) || !valid_commit(blob):
		why = describe(res)
	case:
		res = urun(u, {argv = {"git", git_dir, "read-tree", base}, env = env[:], timeout = GIT_TIMEOUT})
		if succeeded_update(res) {
			res = urun(u, {argv = {"git", git_dir, "update-index", "--cacheinfo", fmt.tprintf("100644,%s,flake.lock", blob)}, env = env[:], timeout = GIT_TIMEOUT})
		}
		if succeeded_update(res) {
			res = urun(u, {argv = {"git", git_dir, "write-tree"}, env = env[:], timeout = GIT_TIMEOUT})
			tree = strings.trim_space(string(res.stdout))
		}
		if !succeeded_update(res) || !valid_commit(tree) {
			why = describe(res)
			break
		}
		message := fmt.tprintf("chore: update Claude Code to %s\n\nThe update timer on %s moved only the %s input of flake.lock,\nbuilt and switched to it, and claude-code-verify checked the download\nagainst Anthropic's release manifest. It ran %s before.\n", r.to, r.host, DEFAULT_INPUT, r.from)
		res = urun(u, {argv = {"git", git_dir, "commit-tree", "-S", tree, "-p", base, "-F", "-"}, env = env[:], input = transmute([]byte)message, timeout = GIT_TIMEOUT})
		commit = strings.trim_space(string(res.stdout))
		if !succeeded_update(res) || !valid_commit(commit) {
			why = describe(res)
		}
	}
	if why != "" {
		tell_update(u, fmt.tprintf("%s runs Claude Code %s now (was %s), but the lock could not be committed (%s), so nothing was pushed; the other host follows when a later update pushes.", r.host, r.to, r.from, tail(why)))
		return false
	}
	res = urun(u, {argv = {"git", git_dir, "push", "--quiet", "--", cfg.remote, fmt.tprintf("%s:refs/heads/%s", commit, cfg.branch)}, env = GIT_ENV[:], timeout = GIT_TIMEOUT})
	if !succeeded_update(res) {
		tell_update(u, fmt.tprintf("%s runs Claude Code %s now (was %s), but the push of the lock to %s was refused (%s); the other host follows when a later update pushes.", r.host, r.to, r.from, cfg.remote, tail(describe(res))))
		return false
	}
	tell_update(u, fmt.tprintf("%s runs Claude Code %s now (was %s): built, checked against Anthropic's manifest, switched, and the lock is pushed (%s). The sessions roll now.", r.host, r.to, r.from, commit[:12]))
	return true
}

parse_result :: proc(data: []byte, allocator := context.allocator) -> (r: Result, err: string) {
	if len(data) > 1 << 20 {
		return r, "it is larger than 1 MiB"
	}
	v, e := json.parse(data, .JSON, true, allocator)
	if e != .None {
		return r, "it is not JSON"
	}
	obj, ok := v.(json.Object)
	if !ok {
		return r, "it is not an object"
	}
	field :: proc(obj: json.Object, key: string) -> string {
		s, _ := obj[key].(json.String)
		return s
	}
	r = {
		id        = field(obj, "id"),
		status    = field(obj, "status"),
		mode      = field(obj, "mode"),
		host      = field(obj, "host"),
		from      = field(obj, "from"),
		to        = field(obj, "to"),
		candidate = field(obj, "candidate"),
		message   = field(obj, "message"),
	}
	if r.id == "" || r.status == "" {
		return r, "it has no id or no status"
	}
	if r.status == "switched" && (!valid_version(r.to) || !valid_version(r.from)) {
		return r, "it says switched, without the two versions"
	}
	if r.status != "switched" && r.message == "" {
		return r, "it says what failed without a message"
	}
	return r, ""
}

// ---- Shared ----

valid_version :: proc(s: string) -> bool {
	parts := 0
	digits := 0
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			digits += 1
			if digits > 6 {
				return false
			}
		case c == '.':
			if digits == 0 {
				return false
			}
			parts += 1
			digits = 0
		case:
			return false
		}
	}
	return digits > 0 && parts < 4
}

// compare_versions compares two valid versions part by part: -1, 0 or 1.
compare_versions :: proc(a, b: string) -> int {
	ra, rb := a, b
	for ra != "" || rb != "" {
		x, y: int
		x, ra = next_part(ra)
		y, rb = next_part(rb)
		if x != y {
			return -1 if x < y else 1
		}
	}
	return 0
}

@(private = "file")
next_part :: proc(s: string) -> (n: int, rest: string) {
	if s == "" {
		return 0, ""
	}
	dot := strings.index_byte(s, '.')
	part := s if dot < 0 else s[:dot]
	n, _ = strconv.parse_int(part, 10)
	return n, "" if dot < 0 else s[dot + 1:]
}

valid_commit :: proc(s: string) -> bool {
	if len(s) != 40 && len(s) != 64 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

sha256_hex :: proc(data: []byte) -> string {
	digest := hash.hash_bytes(.SHA256, data, context.temp_allocator)
	return string(hex.encode(digest, context.temp_allocator))
}

// user_lock takes the user's side's lock, making the state directory.
@(private = "file")
user_lock :: proc(u: ^Updater, state: string) -> (lock: ^os.File, status: int) {
	if e := os.make_directory_all(state); e != nil && e != os.General_Error.Exist {
		ulog(u, "cannot make the state directory %s", state)
		return nil, EXIT_FAILED
	}
	path, _ := filepath.join({state, UPDATE_LOCK})
	f, held := take_lock(path)
	if !held {
		if f == nil {
			ulog(u, "cannot open the lock %s", path)
			return nil, EXIT_FAILED
		}
		os.close(f)
		ulog(u, "another update is running (it holds %s); nothing done", path)
		return nil, EXIT_LOCKED
	}
	return f, EXIT_OK
}

// write_atomic writes data beside path and moves it over path.
write_atomic :: proc(path: string, data: []byte) -> bool {
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, data) != nil {
		_ = os.remove(tmp)
		return false
	}
	if os.rename(tmp, path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

tell_update :: proc(u: ^Updater, message: string) {
	ulog(u, "%s", message)
	if u.notify == "" {
		return
	}
	res := urun(u, {argv = {u.notify, "--topic", UPDATE_TOPIC, "--", message}, timeout = NOTIFY_TIMEOUT})
	if !succeeded_update(res) {
		ulog(u, "ravnix-notify failed (%s)", describe(res))
	}
}

succeeded_update :: proc(res: Run_Result) -> bool {
	return res.start_error == "" && !res.timed_out && !res.too_much && res.exit_code == 0
}

describe :: proc(res: Run_Result) -> string {
	switch {
	case res.start_error != "":
		return fmt.tprintf("could not start it: %s", res.start_error)
	case res.timed_out:
		return "it did not finish in time"
	case res.too_much:
		return "it printed more than allowed"
	case res.exit_code != 0:
		return fmt.tprintf("exit %d: %s", res.exit_code, strings.trim_space(string(res.stderr)))
	}
	return strings.trim_space(string(res.stderr))
}

// nix_error is what a failed nix command says went wrong: its output from
// the last line that starts with "error:" up to the next warning, which
// Nix prints after the error (the lock file it did not write), cut to what
// a notification holds. Without such a line, the end of what it printed.
nix_error :: proc(res: Run_Result) -> string {
	text := string(res.stderr)
	if res.start_error != "" || res.timed_out || res.too_much {
		return tail(describe(res))
	}
	at := -1
	if strings.has_prefix(text, "error:") {
		at = 0
	}
	if i := strings.last_index(text, "\nerror:"); i >= 0 {
		at = i + 1
	}
	if at < 0 {
		return tail(describe(res))
	}
	text = text[at:]
	if i := strings.index(text, "\nwarning:"); i >= 0 {
		text = text[:i]
	}
	text = strings.trim_space(text)
	MAX :: 1200
	if len(text) > MAX {
		cut := MAX
		for cut > 0 && (text[cut] & 0xC0) == 0x80 {
			cut -= 1
		}
		text = fmt.tprintf("%s…", text[:cut])
	}
	return text
}

// tail is the end of a long message: the last lines a notification needs.
tail :: proc(text: string) -> string {
	MAX :: 1200
	s := strings.trim_space(text)
	if len(s) <= MAX {
		return s
	}
	cut := len(s) - MAX
	for cut < len(s) && (s[cut] & 0xC0) == 0x80 {
		cut += 1
	}
	return fmt.tprintf("…%s", s[cut:])
}

urun :: proc(u: ^Updater, cmd: Cmd) -> Run_Result {
	if u.hooks.run != nil {
		return u.hooks.run(u.hooks.data, cmd)
	}
	env: []string
	if len(cmd.env) > 0 {
		base, _ := os.environ(context.allocator)
		merged := make([dynamic]string)
		outer: for kv in base {
			name := kv[:max(strings.index_byte(kv, '='), 0)]
			for add in cmd.env {
				if strings.has_prefix(add, name) && len(add) > len(name) && add[len(name)] == '=' {
					continue outer
				}
			}
			append(&merged, kv)
		}
		append(&merged, ..cmd.env)
		env = merged[:]
	}
	res := run_child(cmd.argv, cmd.input, cmd.timeout, MAX_UPDATE_OUTPUT, context.allocator, cmd.dir, env)
	if res.start_error != "" {
		res.start_error = fmt.tprintf("%s: %s", cmd.argv[0], res.start_error)
	}
	return res
}

unow :: proc(u: ^Updater) -> time.Time {
	if u.hooks.now != nil {
		return u.hooks.now(u.hooks.data)
	}
	return time.now()
}

usleep :: proc(u: ^Updater, d: time.Duration) {
	if u.hooks.sleep != nil {
		u.hooks.sleep(u.hooks.data, d)
		return
	}
	time.sleep(d)
}

ulog :: proc(u: ^Updater, format: string, args: ..any) {
	if u.log != nil {
		fmt.sbprintf(u.log, "%s: ", u.name)
		fmt.sbprintf(u.log, format, ..args)
		strings.write_byte(u.log, '\n')
		return
	}
	fmt.eprintf("%s: ", u.name)
	fmt.eprintf(format, ..args)
	fmt.eprintln()
}
