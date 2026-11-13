// The lock file: which nodes an input owns, what a new revision may change,
// and the copy with another lock's nodes put in.
package claude_roll_tests

import "core:strings"
import "core:testing"
import roll ".."

parse :: proc(f: ^Fixture, text: string) -> roll.Lock {
	l, err := roll.parse_lock(transmute([]byte)text, f.a)
	testing.expect_value(f.t, err, "")
	return l
}

@(test)
an_input_owns_its_node_and_what_only_it_reaches :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	l := parse(f, lock_text(f, OLD_LOCK))
	names, err := roll.input_nodes(l, "claude-code", f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, strings.join(names, ",", f.a), "claude-code,systems")
	// ravnix reaches nixpkgs; its claude-code input follows a path.
	names, err = roll.input_nodes(l, "ravnix", f.a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, strings.join(names, ",", f.a), "nixpkgs,ravnix")
	// An input that follows another has no node; one that is not there.
	_, err = roll.input_nodes(l, "nixpkgs", f.a)
	testing.expect(t, strings.contains(err, "follows"), err)
	_, err = roll.input_nodes(l, "home-manager", f.a)
	testing.expect(t, strings.contains(err, "no input"), err)
}

@(test)
refuses_a_node_another_input_reaches_too :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	text := lock_text(f, OLD_LOCK)
	// ravnix now uses claude-code's systems node as well.
	shared, _ := strings.replace(text, `"ravnix":{"inputs":{"claude-code":["claude-code"],`, `"ravnix":{"inputs":{"claude-code":["claude-code"],"systems":"systems",`, 1, f.a)
	l := parse(f, shared)
	_, err := roll.input_nodes(l, "claude-code", f.a)
	testing.expect(t, strings.contains(err, "also used"), err)
	// A node that names a node that is not there.
	dangling, _ := strings.replace(text, `"systems":"systems"`, `"systems":"systems_9"`, 1, f.a)
	_, err = roll.input_nodes(parse(f, dangling), "claude-code", f.a)
	testing.expect(t, strings.contains(err, "not there"), err)
}

@(test)
a_new_revision_moves_and_nothing_else_may :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	old := parse(f, lock_text(f, OLD_LOCK))
	moved, names, err := roll.compare_input(old, parse(f, lock_text(f, NEW_LOCK)), "claude-code", f.a)
	testing.expect_value(t, err, "")
	testing.expect(t, moved)
	testing.expect_value(t, len(names), 2)

	moved, _, err = roll.compare_input(old, old, "claude-code", f.a)
	testing.expect_value(t, err, "")
	testing.expect(t, !moved)

	// Another node moving is not the input's business.
	other := OLD_LOCK
	other.nixpkgs_rev = "mmmm"
	moved, _, err = roll.compare_input(old, parse(f, lock_text(f, other)), "claude-code", f.a)
	testing.expect_value(t, err, "")
	testing.expect(t, !moved)

	text := lock_text(f, NEW_LOCK)
	bad := []string {
		// another owner, original, repository type
		lock_text(f, {cc_rev = "bbbb", cc_owner = "mallory", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}),
		lock_text(f, {cc_rev = "bbbb", cc_original = "mallory", systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}),
		replace(f, text, `"repo":"claude-code-nix","rev":"bbbb","type":"github"`, `"repo":"claude-code-nix","rev":"bbbb","type":"tarball"`),
		// a field more in locked, a node more, an input less
		replace(f, text, `"rev":"bbbb",`, `"rev":"bbbb","ref":"evil",`),
		lock_text(f, {cc_rev = "bbbb", cc_extra = true, systems_rev = "ssss", nixpkgs_rev = "nnnn", ravnix_rev = "rrrr"}),
		replace(f, text, `"inputs":{"nixpkgs":["nixpkgs"],"systems":"systems"}`, `"inputs":{"nixpkgs":["nixpkgs"]}`),
		// claude-code no longer follows nixpkgs
		replace(f, text, `"nixpkgs":["nixpkgs"],"systems"`, `"nixpkgs":"nixpkgs","systems"`),
		// the root points claude-code at another node
		replace(f, text, `"root":{"inputs":{"claude-code":"claude-code"`, `"root":{"inputs":{"claude-code":"systems"`),
		// a flake = false
		replace(f, text, `"original":{"owner":"sadjow"`, `"flake":false,"original":{"owner":"sadjow"`),
	}
	for b, i in bad {
		_, _, e := roll.compare_input(old, parse(f, b), "claude-code", f.a)
		testing.expectf(t, e != "", "case %d was taken", i)
	}
}

replace :: proc(f: ^Fixture, s, old, new: string) -> string {
	out, n := strings.replace(s, old, new, 1, f.a)
	testing.expectf(f.t, n, "the fixture has no %q", old)
	return out
}

@(test)
refuses_what_is_no_lock :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	for text in ([]string{"", "[]", "{}", `{"nodes":{},"root":"root"}`, `{"nodes":[],"root":"root"}`, `{"nodes":{"root":{}},"root":7}`, "{\"nodes\":", "// not json"}) {
		_, err := roll.parse_lock(transmute([]byte)text, f.a)
		testing.expectf(t, err != "", "%q was taken", text)
	}
	_, err := roll.parse_lock(transmute([]byte)strings.repeat("{", 5 << 20, f.a), f.a)
	testing.expect(t, strings.contains(err, "4 MiB"), err)
	// Deep enough to take the parser's stack, small enough to pass the size.
	deep := strings.concatenate({`{"nodes":{"root":{}},"root":"root","x":`, strings.repeat("[", 200_000, f.a), strings.repeat("]", 200_000, f.a), "}"}, f.a)
	_, err = roll.parse_lock(transmute([]byte)deep, f.a)
	testing.expect(t, strings.contains(err, "nests deeper"), err)
	// Brackets inside strings do not count.
	quoted := strings.concatenate({`{"nodes":{"root":{}},"root":"root","x":"`, strings.repeat("[", 1000, f.a), `\"{"}`}, f.a)
	_, err = roll.parse_lock(transmute([]byte)quoted, f.a)
	testing.expect_value(t, err, "")
}

@(test)
others_equal_sees_any_other_change :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	old := parse(f, lock_text(f, OLD_LOCK))
	names := []string{"claude-code", "systems"}
	_, same := roll.others_equal(old, parse(f, lock_text(f, NEW_LOCK)), names)
	testing.expect(t, same)
	other := NEW_LOCK
	other.ravnix_rev = "zzzz"
	what, same2 := roll.others_equal(old, parse(f, lock_text(f, other)), names)
	testing.expect(t, !same2)
	testing.expect_value(t, what, "ravnix")
	text := lock_text(f, NEW_LOCK)
	what, same2 = roll.others_equal(old, parse(f, replace(f, text, `"version":7`, `"version":8`)), names)
	testing.expect(t, !same2)
	what, same2 = roll.others_equal(old, parse(f, replace(f, text, `"root":"root","version"`, `"extra":1,"root":"root","version"`)), names)
	testing.expect(t, !same2)
	what, same2 = roll.others_equal(old, parse(f, replace(f, text, `"systems":{"locked"`, `"stray":{},"systems":{"locked"`)), names)
	testing.expect(t, !same2)
	testing.expect_value(t, what, "stray")
}

@(test)
splice_puts_the_input_nodes_into_the_deployed_lock :: proc(t: ^testing.T) {
	f := fixture(t)
	defer fixture_destroy(f)
	old := parse(f, lock_text(f, OLD_LOCK))
	cand := NEW_LOCK
	cand.nixpkgs_rev = "mmmm"
	from := parse(f, lock_text(f, cand))
	out := roll.splice(old, from, {"claude-code", "systems"}, f.a)
	got := parse(f, out)
	want := parse(f, lock_text(f, NEW_LOCK))
	testing.expect(t, roll.json_equal(roll.json_value(got), roll.json_value(want)), out)
	// Strings that need escaping come out as they went in.
	odd := replace(f, lock_text(f, OLD_LOCK), `"ref":"nixos-unstable"`, `"ref":"a\"b\\c\nd\u0001é"`)
	l := parse(f, odd)
	again := parse(f, roll.splice(l, l, {}, f.a))
	testing.expect(t, roll.json_equal(roll.json_value(again), roll.json_value(l)))
}
