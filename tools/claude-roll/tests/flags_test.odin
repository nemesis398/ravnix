// The launch flags: what a pane's Claude Code was started with, which a
// resume must pass again because Claude Code does not keep them (--add-dir,
// --settings, --mcp-config and the rest), and what it must not pass again (the
// old --resume, a first prompt, --worktree). And the ids that go into a file
// name or onto a command line.
package claude_roll_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import roll ".."

Flags_Case :: struct {
	argv: []string,
	want: []string,
	// A word of the error; "" when the flags are usable.
	err:  string,
}

@(test)
keeps_the_flags_a_resume_needs :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)

	cases := []Flags_Case {
		{{}, {}, ""},
		{{"--add-dir", "/home/user/notes"}, {"--add-dir", "/home/user/notes"}, ""},
		// Variadic: every value up to the next flag.
		{{"--add-dir", "/a", "/b", "--model", "opus"}, {"--add-dir", "/a", "/b", "--model", "opus"}, ""},
		{{"--mcp-config", "a.json", "b.json"}, {"--mcp-config", "a.json", "b.json"}, ""},
		{{"--settings", "{\"x\": 1}", "--strict-mcp-config"}, {"--settings", "{\"x\": 1}", "--strict-mcp-config"}, ""},
		{{"--model=opus", "--effort=high"}, {"--model=opus", "--effort=high"}, ""},
		{{"--dangerously-skip-permissions", "--permission-mode", "plan"}, {"--dangerously-skip-permissions", "--permission-mode", "plan"}, ""},
		{{"-n", "work", "--append-system-prompt", "be brief"}, {"-n", "work", "--append-system-prompt", "be brief"}, ""},
		{{"--allowedTools", "Bash(git *)", "Edit", "--verbose"}, {"--allowedTools", "Bash(git *)", "Edit", "--verbose"}, ""},
		// The old session: --resume with and without its id, -r, --continue,
		// --session-id, --fork-session.
		{{"--resume", "0a1b2c3d-1111-4222-8333-444455556666", "--add-dir", "/a"}, {"--add-dir", "/a"}, ""},
		{{"-r", "old-name", "--model", "opus"}, {"--model", "opus"}, ""},
		{{"--resume", "--model", "opus"}, {"--model", "opus"}, ""},
		{{"--resume=abc", "-c", "--continue", "--fork-session"}, {}, ""},
		{{"--session-id", "0a1b2c3d-1111-4222-8333-444455556666"}, {}, ""},
		// A first prompt is not sent twice.
		{{"fix the build"}, {}, ""},
		{{"--model", "opus", "fix the build"}, {"--model", "opus"}, ""},
		{{"--", "--model", "x"}, {}, ""},
		// --debug takes an optional filter.
		{{"--debug", "hooks", "--verbose"}, {"--debug", "hooks", "--verbose"}, ""},
		{{"-d", "--verbose"}, {"-d", "--verbose"}, ""},
		// What a resume cannot carry: a new worktree each time, print mode,
		// background sessions, and anything claude-roll does not know.
		{{"--worktree", "x"}, nil, "--worktree"},
		{{"-w"}, nil, "-w"},
		{{"-p", "hi"}, nil, "-p"},
		{{"--bg"}, nil, "--bg"},
		{{"--teleport"}, nil, "--teleport"},
		{{"--no-such-flag", "x"}, nil, "--no-such-flag"},
		{{"-dc"}, nil, "-dc"},
		// A value that a flag needs and does not get.
		{{"--model"}, nil, "--model"},
		{{"--model", "--verbose"}, nil, "--model"},
		{{"--add-dir"}, nil, "--add-dir"},
		{{"--model="}, nil, "--model"},
		// Control characters cannot be typed into a shell line (herdr refuses
		// them too).
		{{"--append-system-prompt", "a\nb"}, nil, "control"},
		{{"--add-dir", "/a\x1b[2J"}, nil, "control"},
		// A boolean with a value.
		{{"--verbose=yes"}, nil, "--verbose"},
	}
	for c in cases {
		got, err := roll.resume_args(c.argv, a)
		if c.err != "" {
			testing.expectf(t, strings.contains(err, c.err), "%v: error %q does not name %q", c.argv, err, c.err)
			continue
		}
		testing.expectf(t, err == "", "%v: unexpected error %q", c.argv, err)
		testing.expectf(t, equal_strings(got, c.want), "%v: got %v, want %v", c.argv, got, c.want)
	}
}

@(test)
accepts_only_a_uuid_as_session_id :: proc(t: ^testing.T) {
	testing.expect(t, roll.valid_session_id("0a1b2c3d-1111-4222-8333-444455556666"))
	testing.expect(t, roll.valid_session_id("0A1B2C3D-1111-4222-8333-444455556666"))
	for bad in ([]string {
			"",
			"--dangerously-skip-permissions",
			"0a1b2c3d-1111-4222-8333-44445555666",
			"0a1b2c3d-1111-4222-8333-4444555566667",
			"0a1b2c3d_1111-4222-8333-444455556666",
			"0a1b2c3d-1111-4222-8333-44445555666g",
			"0a1b2c3d-1111-4222-8333-444455556666\n",
			"0a1b2c3d-1111-4222-8333-444455556666; rm -r ~",
			"../../0a1b2c3d-1111-4222-8333-444455556666",
			"my session",
		}) {
		testing.expectf(t, !roll.valid_session_id(bad), "%q passed", bad)
	}
}

@(test)
accepts_only_a_plain_pane_id :: proc(t: ^testing.T) {
	for good in ([]string{"w1:p1", "wK:p1N", "wG:p1N", "w_2:p-3"}) {
		testing.expectf(t, roll.valid_pane_id(good), "%q refused", good)
	}
	for bad in ([]string{"", ".", "..", "../x", "a/b", "-w1", "w1:p1\n", "w1 p1", "w1:p1\x00", strings.repeat("w", 65, context.temp_allocator)}) {
		testing.expectf(t, !roll.valid_pane_id(bad), "%q passed", bad)
	}
}

@(test)
names_the_restarted_agent :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	// The name it had, when herdr would take it again.
	testing.expect_value(t, roll.agent_name("reviewer", "wK:p1", a), "reviewer")
	// Otherwise one made of the pane: [a-z][a-z0-9_-]{0,31}.
	testing.expect_value(t, roll.agent_name("", "wK:p1N", a), "claude-wk-p1n")
	testing.expect_value(t, roll.agent_name("Bad Name", "w1:p2", a), "claude-w1-p2")
	long := roll.agent_name("", "wABCDEFGHIJKLMNOPQRSTUVWXYZ:p1234567890", a)
	testing.expect(t, len(long) <= 32)
	testing.expect(t, strings.has_prefix(long, "claude-"))
}

@(test)
reads_a_pane_record :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)

	rec, err := roll.parse_pane_record(transmute([]byte)string(`{"pane":"wK:p1","session_id":"0a1b2c3d-2222-4222-8333-444455556666","cwd":"/home/user/project","source":"startup","argv":["--add-dir","/home/user/notes"]}`), a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, rec.pane, "wK:p1")
	testing.expect_value(t, rec.session_id, "0a1b2c3d-2222-4222-8333-444455556666")
	testing.expect(t, equal_strings(rec.argv, {"--add-dir", "/home/user/notes"}))

	// An empty argv is a pane started with no flags at all.
	rec, err = roll.parse_pane_record(transmute([]byte)string(`{"pane":"wK:p1","session_id":"0a1b2c3d-2222-4222-8333-444455556666","argv":[]}`), a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(rec.argv), 0)

	for bad in ([]string {
			``,
			`{`,
			`{"pane":"wK:p1","session_id":"0a1b2c3d-2222-4222-8333-444455556666","argv":["--add-dir"`,
			`null`,
			`[]`,
			`{"pane":"wK:p1","session_id":"x","argv":"--add-dir"}`,
			`{"pane":"wK:p1","session_id":"x","argv":[1,2]}`,
			// No argv: not recorded, not "no flags".
			`{"pane":"wK:p1","session_id":"0a1b2c3d-2222-4222-8333-444455556666"}`,
			"\x00\x00",
		}) {
		_, e := roll.parse_pane_record(transmute([]byte)bad, a)
		testing.expectf(t, e != "", "%q parsed", bad)
	}
}

equal_strings :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}
