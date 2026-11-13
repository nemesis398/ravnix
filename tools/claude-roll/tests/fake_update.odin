// The world of the update, in the test: every program the update runs
// (curl, systemctl, setpriv, cp, nix, claude-code-verify, nix-env, the
// switch, git, ravnix-notify) is answered here and recorded, so a test says
// what the update did and, as much, what it did not.
package claude_roll_tests

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import roll ".."

TOPLEVEL :: "/nix/store/0000000000000000000000000000000a-nixos-system-host"
DOWNLOAD :: "/nix/store/0000000000000000000000000000000b-claude"
BASE :: "1111111111111111111111111111111111111111"
BLOB :: "2222222222222222222222222222222222222222"
TREE :: "3333333333333333333333333333333333333333"
COMMIT :: "4444444444444444444444444444444444444444"
REMOTE :: "https://git.example.org/alice/private.git"

Fake_Update :: struct {
	a:                 runtime.Allocator,
	calls:             [dynamic]string,
	inputs:            [dynamic]string,
	notified:          [dynamic]string,
	// curl
	latest:            string,
	latest_fails:      bool,
	// root's systemctl: the prepare unit fails, and the exit status
	// `systemctl show` then reports for it ("" fails the show, as with no
	// user manager).
	prepare_fails:     bool,
	prepare_status:    string,
	finish_fails:      bool,
	// setpriv cat: the candidate; "" fails the read.
	candidate:         string,
	// root's own fetch of upstream, and whether the pushed revision is on
	// its head.
	upstream_fetch_fails: bool,
	not_ancestor:      bool,
	// nix
	version:           string,
	eval_fails:        bool,
	build_fails:       bool,
	download_fails:    bool,
	verify_exit:       int,
	nix_env_fails:     bool,
	switch_fails:      bool,
	// the user's side
	vault_locked:      bool,
	fetch_fails:       bool,
	fetch_error:       string,
	remote_lock:       string,
	// what `nix flake update` writes; "" fails it.
	updated_lock:      string,
	commit_fails:      bool,
	push_fails:        bool,
	roll_start_fails:  bool,
	// remote-control: the `systemctl --user show` answers in turn (the last
	// repeats), and a restart's failure.
	unit_states:       []string,
	shows:             int,
	restart_fails:     bool,
	// the clock
	clock:             time.Time,
}

fake_update :: proc(f: ^Fixture) -> ^Fake_Update {
	fu := new(Fake_Update, f.a)
	fu.a = f.a
	fu.calls = make([dynamic]string, f.a)
	fu.inputs = make([dynamic]string, f.a)
	fu.notified = make([dynamic]string, f.a)
	fu.clock = time.unix(1_800_000_000, 0)
	return fu
}

hooks_of :: proc(fu: ^Fake_Update) -> roll.Update_Hooks {
	return {data = fu, run = fake_update_run, now = fake_update_now, sleep = fake_update_sleep}
}

fake_update_now :: proc(data: rawptr) -> time.Time {
	return (^Fake_Update)(data).clock
}

fake_update_sleep :: proc(data: rawptr, d: time.Duration) {
	fu := (^Fake_Update)(data)
	fu.clock = time.time_add(fu.clock, d)
}

// called says whether a call whose words start with the words given was
// made; count says how many.
called :: proc(fu: ^Fake_Update, prefix: string) -> bool {
	return count(fu, prefix) > 0
}

count :: proc(fu: ^Fake_Update, prefix: string) -> int {
	n := 0
	for c in fu.calls {
		if strings.has_prefix(c, prefix) {
			n += 1
		}
	}
	return n
}

ok_res :: proc(fu: ^Fake_Update, out: string) -> roll.Run_Result {
	return {stdout = transmute([]byte)strings.clone(out, fu.a)}
}

fail_res :: proc(fu: ^Fake_Update, code: int, err: string) -> roll.Run_Result {
	return {exit_code = code, stderr = transmute([]byte)strings.clone(err, fu.a)}
}

fake_update_run :: proc(data: rawptr, cmd: roll.Cmd) -> roll.Run_Result {
	fu := (^Fake_Update)(data)
	context.allocator = fu.a
	line := strings.join(cmd.argv, " ")
	append(&fu.calls, line)
	append(&fu.inputs, strings.clone(string(cmd.input), fu.a))
	argv := cmd.argv
	switch {
	case argv[0] == "curl":
		if fu.latest_fails {
			return fail_res(fu, 6, "curl: (6) Could not resolve host: downloads.claude.ai")
		}
		return ok_res(fu, fu.latest)
	case argv[0] == "systemctl":
		return fake_systemctl(fu, argv)
	case argv[0] == "setpriv":
		if fu.candidate == "" {
			return fail_res(fu, 1, "cat: /home/alice/candidate.lock: No such file or directory")
		}
		return ok_res(fu, fu.candidate)
	case argv[0] == "cp":
		if os.make_directory_all(argv[len(argv) - 1]) != nil {
			return fail_res(fu, 1, "cp: cannot create directory")
		}
		return ok_res(fu, "")
	case argv[0] == "nix":
		return fake_nix(fu, cmd)
	case argv[0] == "claude-code-verify":
		if fu.verify_exit != 0 {
			return fail_res(fu, fu.verify_exit, "claude-code-verify: the sha256 differs")
		}
		return ok_res(fu, "verified")
	case argv[0] == "nix-env":
		if fu.nix_env_fails {
			return fail_res(fu, 1, "error: opening lock file")
		}
		return ok_res(fu, "")
	case strings.has_suffix(argv[0], "/bin/switch-to-configuration"):
		if fu.switch_fails {
			return fail_res(fu, 4, "warning: the following units failed: nginx.service")
		}
		return ok_res(fu, "")
	case argv[0] == "git":
		return fake_git(fu, cmd)
	case argv[0] == "rbw":
		if fu.vault_locked {
			return fail_res(fu, 1, "")
		}
		return ok_res(fu, "")
	case argv[0] == "ravnix-notify":
		append(&fu.notified, strings.clone(argv[len(argv) - 1], fu.a))
		return ok_res(fu, "")
	}
	return {start_error = fmt.aprintf("%s: not found", argv[0], allocator = fu.a)}
}

@(private = "file")
fake_systemctl :: proc(fu: ^Fake_Update, argv: []string) -> roll.Run_Result {
	has :: proc(argv: []string, word: string) -> bool {
		for w in argv {
			if w == word {
				return true
			}
		}
		return false
	}
	switch {
	case has(argv, "show") && has(argv, roll.PREPARE_UNIT):
		if fu.prepare_status == "" {
			return fail_res(fu, 1, "Failed to connect to bus: No medium found")
		}
		return ok_res(fu, strings.concatenate({fu.prepare_status, "\n"}, fu.a))
	case has(argv, "show"):
		if len(fu.unit_states) == 0 {
			return fail_res(fu, 1, "Failed to connect to bus")
		}
		s := fu.unit_states[min(fu.shows, len(fu.unit_states) - 1)]
		fu.shows += 1
		return ok_res(fu, s)
	case has(argv, "restart"):
		if fu.restart_fails {
			return fail_res(fu, 1, "Job for claude-remote-control.service failed.")
		}
		return ok_res(fu, "")
	case has(argv, roll.PREPARE_UNIT):
		if fu.prepare_fails {
			return fail_res(fu, 1, "Job for ravnix-claude-update-prepare.service failed because the control process exited with error code.")
		}
		return ok_res(fu, "")
	case has(argv, roll.FINISH_UNIT):
		if fu.finish_fails {
			return fail_res(fu, 1, "Failed to connect to bus: No medium found")
		}
		return ok_res(fu, "")
	case has(argv, "start"):
		if fu.roll_start_fails {
			return fail_res(fu, 1, "Failed to start claude-roll.service: Unit not found.")
		}
		return ok_res(fu, "")
	}
	return fail_res(fu, 1, "unknown systemctl call")
}

@(private = "file")
fake_nix :: proc(fu: ^Fake_Update, cmd: roll.Cmd) -> roll.Run_Result {
	argv := cmd.argv
	verb := argv[3]
	target := argv[len(argv) - 1]
	switch verb {
	case "eval":
		if fu.eval_fails {
			return fail_res(fu, 1, "error: attribute 'claude-code' missing")
		}
		return ok_res(fu, fu.version)
	case "build":
		if strings.has_suffix(target, ".toplevel") {
			if fu.build_fails {
				// Nix says what failed, then what it did not write.
				return fail_res(fu, 1, strings.concatenate({"error: builder for '/nix/store/x-claude-code-2.2.0.drv' failed with exit code 1\nwarning: not writing modified lock file of flake 'path:/var/lib/ravnix-claude-update/work':\n", strings.repeat("• Updated input 'ravnix':\n    'github:alice/ravnix/0000' (2026-11-13)\n  → 'path:/nix/store/x-source' (2026-11-13)\n", 20, fu.a)}, fu.a))
			}
			return ok_res(fu, TOPLEVEL + "\n")
		}
		if fu.download_fails {
			return fail_res(fu, 1, "error: hash mismatch in fixed-output derivation")
		}
		return ok_res(fu, DOWNLOAD + "\n")
	case "flake":
		if fu.updated_lock == "" {
			return fail_res(fu, 1, "error: unable to download 'https://api.github.com/repos/sadjow/claude-code-nix/commits/HEAD'")
		}
		path, _ := filepath.join({cmd.dir, "flake.lock"}, fu.a)
		if os.write_entire_file(path, transmute([]byte)fu.updated_lock) != nil {
			return fail_res(fu, 1, "cannot write")
		}
		return ok_res(fu, "")
	}
	return fail_res(fu, 1, "unknown nix call")
}

@(private = "file")
fake_git :: proc(fu: ^Fake_Update, cmd: roll.Cmd) -> roll.Run_Result {
	argv := cmd.argv
	verb := ""
	for w in argv[1:] {
		if !strings.has_prefix(w, "--git-dir=") && !strings.has_prefix(w, "--work-tree=") {
			verb = w
			break
		}
	}
	switch verb {
	case "init":
		repo := argv[len(argv) - 1]
		_ = os.make_directory_all(repo)
		head, _ := filepath.join({repo, "HEAD"}, fu.a)
		_ = os.write_entire_file(head, transmute([]byte)string("ref: refs/heads/main\n"))
		return ok_res(fu, "")
	case "fetch":
		if strings.has_suffix(argv[1], "upstream.git") {
			if fu.upstream_fetch_fails {
				return fail_res(fu, 128, "fatal: unable to access 'https://github.com/sadjow/claude-code-nix.git/': Could not resolve host: github.com")
			}
			return ok_res(fu, "")
		}
		if fu.fetch_fails {
			return fail_res(fu, 128, fu.fetch_error)
		}
		return ok_res(fu, "")
	case "rev-parse":
		return ok_res(fu, BASE + "\n")
	case "merge-base":
		if fu.not_ancestor {
			return fail_res(fu, 1, "")
		}
		return ok_res(fu, "")
	case "show":
		if fu.remote_lock == "" {
			return fail_res(fu, 128, "fatal: path 'flake.lock' does not exist in '1111111'")
		}
		return ok_res(fu, fu.remote_lock)
	case "read-tree", "update-index":
		return ok_res(fu, "")
	case "checkout-index":
		path, _ := filepath.join({cmd.dir, "flake.lock"}, fu.a)
		_ = os.write_entire_file(path, transmute([]byte)fu.remote_lock)
		return ok_res(fu, "")
	case "hash-object":
		return ok_res(fu, BLOB + "\n")
	case "write-tree":
		return ok_res(fu, TREE + "\n")
	case "commit-tree":
		if fu.commit_fails {
			return fail_res(fu, 128, "error: Couldn't find key in agent?\nfatal: failed to write commit object")
		}
		return ok_res(fu, COMMIT + "\n")
	case "push":
		if fu.push_fails {
			return fail_res(fu, 1, "To https://git.example.org/alice/private.git\n ! [remote rejected] main (pre-receive hook declined)")
		}
		return ok_res(fu, "")
	}
	return fail_res(fu, 1, "unknown git call")
}

// A lock like a private flake's: claude-code with its own systems node and
// nixpkgs following the root's, ravnix with nixpkgs.
Lock_Spec :: struct {
	cc_rev:      string,
	cc_owner:    string,
	cc_original: string,
	systems_rev: string,
	nixpkgs_rev: string,
	ravnix_rev:  string,
	// Another input of claude-code's own, beside systems.
	cc_extra:    bool,
}

lock_text :: proc(f: ^Fixture, s: Lock_Spec) -> string {
	cc_owner := s.cc_owner if s.cc_owner != "" else "sadjow"
	original := s.cc_original if s.cc_original != "" else "sadjow"
	extra := `,"extra":"systems"` if s.cc_extra else ""
	// A revision as a lock holds it: 40 characters.
	cc_rev := strings.repeat(s.cc_rev, 10, f.a) if len(s.cc_rev) == 4 else s.cc_rev
	return fmt.aprintf(
		`{{"nodes":{{` +
		`"claude-code":{{"inputs":{{"nixpkgs":["nixpkgs"],"systems":"systems"%s}},"locked":{{"lastModified":1793988107,"narHash":"sha256-%s","owner":"%s","repo":"claude-code-nix","rev":"%s","type":"github"}},"original":{{"owner":"%s","repo":"claude-code-nix","type":"github"}}}},` +
		`"nixpkgs":{{"locked":{{"lastModified":5,"narHash":"sha256-%s","owner":"NixOS","repo":"nixpkgs","rev":"%s","type":"github"}},"original":{{"owner":"NixOS","ref":"nixos-unstable","repo":"nixpkgs","type":"github"}}}},` +
		`"ravnix":{{"inputs":{{"claude-code":["claude-code"],"nixpkgs":"nixpkgs"}},"locked":{{"lastModified":6,"narHash":"sha256-%s","owner":"alice","repo":"ravnix","rev":"%s","type":"github"}},"original":{{"owner":"alice","repo":"ravnix","type":"github"}}}},` +
		`"root":{{"inputs":{{"claude-code":"claude-code","nixpkgs":["ravnix","nixpkgs"],"ravnix":"ravnix"}}}},` +
		`"systems":{{"locked":{{"lastModified":2,"narHash":"sha256-%s","owner":"nix-systems","repo":"default","rev":"%s","type":"github"}},"original":{{"owner":"nix-systems","repo":"default","type":"github"}}}}` +
		`}},"root":"root","version":7}}` + "\n",
		extra,
		cc_rev,
		cc_owner,
		cc_rev,
		original,
		s.nixpkgs_rev,
		s.nixpkgs_rev,
		s.ravnix_rev,
		s.ravnix_rev,
		s.systems_rev,
		s.systems_rev,
		allocator = f.a,
	)
}

OLD_LOCK :: Lock_Spec{cc_rev = "aaaa", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}
NEW_LOCK :: Lock_Spec{cc_rev = "bbbb", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}
// A revision of the same repository that only a fork has: GitHub serves it
// under the upstream's own URL all the same.
FORK_LOCK :: Lock_Spec{cc_rev = "ffff", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}

// A deployed flake: a directory with the lock in it.
deployed_flake :: proc(f: ^Fixture, s: Lock_Spec) -> string {
	dir := pj(f.a, f.dir, "deployed")
	_ = os.make_directory_all(dir)
	write_file(f, pj(f.a, dir, "flake.lock"), lock_text(f, s))
	return dir
}

root_config :: proc(f: ^Fixture, fu: ^Fake_Update, mode: roll.Update_Mode, log: ^strings.Builder) -> roll.Update_Config {
	c := roll.default_update_config()
	c.mode = mode
	c.flake = deployed_flake(f, OLD_LOCK)
	c.host = "muninn"
	c.user = "alice"
	c.group = "users"
	c.package_attr = "home-manager.users.alice.programs.claude-code.package"
	c.running = "2.1.0"
	c.state_dir = pj(f.a, f.dir, "root")
	c.candidate = "/home/alice/.local/state/ravnix/claude-update/candidate.lock"
	overrides := make([]roll.Override, 2, f.a)
	overrides[0] = {"ravnix", "/nix/store/0000000000000000000000000000000c-source"}
	overrides[1] = {"absent", "/nix/store/x"}
	c.overrides = overrides
	c.hooks = hooks_of(fu)
	c.log = log
	return c
}

// note is the first message the update sent, "" for none.
note :: proc(fu: ^Fake_Update) -> string {
	return fu.notified[0] if len(fu.notified) > 0 else ""
}
