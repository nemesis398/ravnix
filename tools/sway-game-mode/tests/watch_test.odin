// The watcher and `--leave` against the stand-in for Sway: the cases of the
// plan's behavior inventory, and what the Python watcher never met.
package sway_game_mode_tests

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import sg ".."

GAME :: "com.mojang.minecraft"

ENTER := []string{"mode game", "seat * hide_cursor when-typing disable", "seat * hide_cursor 0"}
LEAVE := []string{"mode default", "seat * hide_cursor when-typing enable", "seat * hide_cursor 8000"}

// begin starts a watcher on the fake, and returns once it has subscribed
// and made its first look.
begin :: proc(t: ^testing.T, f: ^Fake, timeout := WAIT) -> ^Run {
	r := run_start(t, f, timeout)
	testing.expect(t, eventually(f, has_subscriber, 1), "the watcher did not subscribe")
	testing.expect(t, eventually(f, has_state_requests, 1), "the watcher did not look")
	return r
}

// barrier makes the watcher look once more and waits until it has, so that
// everything it did for the events before is on record.
barrier :: proc(t: ^testing.T, f: ^Fake) {
	n := fake_count(f, sg.MSG_GET_BINDING_STATE)
	fake_event(f, sg.EVENT_WINDOW, `{"change":"focus"}`)
	testing.expect(t, eventually(f, has_state_requests, n + 1), "the watcher did not look again")
}

expect_commands :: proc(t: ^testing.T, f: ^Fake, want: []string) {
	testing.expectf(t, eventually(f, has_commands, len(want)), "wanted %d commands, got %v", len(want), fake_commands(f))
	barrier(t, f)
	got := fake_commands(f)
	testing.expectf(t, same_strings(got, want), "got %v, want %v", got, want)
}

finish :: proc(t: ^testing.T, f: ^Fake, r: ^Run, want_code: int) {
	code := run_end(r)
	testing.expect_value(t, code, want_code)
	fake_stop(f)
	fake_free(f)
	free_all(context.temp_allocator)
}

// ── mode game and the cursor ─────────────────────────────────────────────────

@(test)
a_game_already_in_focus_enters_game :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	testing.expect_value(t, fake_mode(f), "game")
	testing.expect_value(t, f.subscriptions[0], `["window", "workspace"]`)
	finish(t, f, r, 0)
}

@(test)
a_game_gaining_focus_enters_game_and_leaving_it_restores :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	expect_commands(t, f, {})
	fake_focus(f, GAME)
	expect_commands(t, f, ENTER)
	testing.expect_value(t, fake_mode(f), "game")
	fake_focus(f, "foot")
	both := make([dynamic]string, context.temp_allocator)
	append(&both, ..ENTER)
	append(&both, ..LEAVE)
	expect_commands(t, f, both[:])
	testing.expect_value(t, fake_mode(f), "default")
	finish(t, f, r, 0)
}

@(test)
an_empty_workspace_leaves_game :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	fake_focus(f, "")
	both := make([dynamic]string, context.temp_allocator)
	append(&both, ..ENTER)
	append(&both, ..LEAVE)
	expect_commands(t, f, both[:])
	testing.expect_value(t, fake_mode(f), "default")
	finish(t, f, r, 0)
}

@(test)
an_xwayland_class_and_a_floating_window_count :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME, xwayland = true, floating = true})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	finish(t, f, r, 0)
}

@(test)
only_the_games_list_counts :: proc(t: ^testing.T) {
	for app in ([?]string{"com.mojang.minecraft.launcher", "COM.MOJANG.MINECRAFT", "minecraft", " com.mojang.minecraft"}) {
		f := fake_start(t, {focused = app})
		r := begin(t, f)
		expect_commands(t, f, {})
		finish(t, f, r, 0)
	}
}

@(test)
a_reload_that_resets_the_mode_enters_game_again :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	// `swaymsg reload` sets the mode to "default"; the game keeps focus and
	// the only event is the workspace channel's "reload".
	fake_set_mode(f, "default")
	fake_event(f, sg.EVENT_WORKSPACE, `{"change":"reload"}`)
	both := make([dynamic]string, context.temp_allocator)
	append(&both, ..ENTER)
	append(&both, ..ENTER)
	expect_commands(t, f, both[:])
	testing.expect_value(t, fake_mode(f), "game")
	finish(t, f, r, 0)
}

@(test)
every_listed_change_makes_it_look :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	for c in sg.EVENT_CHANGES {
		for type in ([?]u32{sg.EVENT_WINDOW, sg.EVENT_WORKSPACE}) {
			n := fake_count(f, sg.MSG_GET_TREE)
			fake_event(f, type, fmt.tprintf(`{{"change":%q}}`, c))
			testing.expectf(t, eventually(f, has_tree_requests, n + 1), "%s on %x: no look", c, type)
		}
	}
	finish(t, f, r, 0)
}

// ── what leaves the mode alone ───────────────────────────────────────────────

@(test)
resize_and_passthrough_are_left_alone :: proc(t: ^testing.T) {
	for mode in ([?]string{"resize", "passthrough", "something else"}) {
		// A game gains focus while in the mode ...
		f := fake_start(t, {mode = mode, focused = "foot"})
		r := begin(t, f)
		fake_focus(f, GAME)
		expect_commands(t, f, {})
		testing.expect_value(t, fake_mode(f), mode)
		// ... and the focus leaves it again.
		fake_focus(f, "foot")
		expect_commands(t, f, {})
		testing.expect_value(t, fake_mode(f), mode)
		finish(t, f, r, 0)
	}
	// Started in the mode with a game focused.
	f := fake_start(t, {mode = "passthrough", focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, {})
	testing.expect_value(t, fake_mode(f), "passthrough")
	// SIGTERM leaves it alone as well.
	run_signal(r)
	testing.expect(t, run_done(r))
	testing.expect_value(t, len(fake_commands(f)), 0)
	finish(t, f, r, 0)
}

@(test)
a_hand_leave_of_game_stays_left_while_the_game_has_focus :: proc(t: ^testing.T) {
	// Super+Shift+Escape in "game" goes to "default" with the game still in
	// focus. No focus event follows, and the watcher does not fight it.
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	before := fake_requests(f)
	fake_set_mode(f, "default")
	fake_event(f, 0x80000002, `{"change":"default","pango_markup":true}`)
	time.sleep(50 * time.Millisecond)
	testing.expect_value(t, fake_requests(f), before)
	testing.expect(t, same_strings(fake_commands(f), ENTER))
	testing.expect_value(t, fake_mode(f), "default")
	finish(t, f, r, 0)
}

@(test)
events_that_change_nothing_make_no_request :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	before := fake_requests(f)
	for payload in ([?]string {
			`{"change":"title"}`,
			`{"change":"fullscreen_mode"}`,
			`{"change":"floating"}`,
			`{"change":"urgent"}`,
			`{"change":"mark"}`,
			`{"change":"rename"}`,
			`{"change":"FOCUS"}`,
			`{"change":""}`,
			`{}`,
			`{"change":5}`,
			`[]`,
			`null`,
			`not json at all`,
			``,
			`{"change":"focus"`,
			"\xff\xfe\x00",
		}) {
		fake_event(f, sg.EVENT_WINDOW, payload)
	}
	// Events of other types are skipped too, even with a change that matters.
	for type in ([?]u32{0x80000001, 0x80000002, 0x80000004, 0x80000015, 0x7fffffff, 0}) {
		fake_event(f, type, `{"change":"focus"}`)
	}
	// A frame that does follow is still read.
	time.sleep(20 * time.Millisecond)
	testing.expect_value(t, fake_requests(f), before)
	barrier(t, f)
	testing.expect_value(t, fake_requests(f), before + 2)
	finish(t, f, r, 0)
}

@(test)
two_events_in_one_write_and_a_burst_are_all_read :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	two := make([dynamic]u8, context.temp_allocator)
	append(&two, ..frame(sg.EVENT_WINDOW, `{"change":"focus"}`))
	append(&two, ..frame(sg.EVENT_WORKSPACE, `{"change":"empty"}`))
	n := fake_count(f, sg.MSG_GET_BINDING_STATE)
	fake_raw(f, two[:])
	testing.expect(t, eventually(f, has_state_requests, n + 2))
	for i in 0 ..< 200 {
		fake_focus(f, GAME if i % 2 == 0 else "foot")
	}
	fake_focus(f, GAME)
	testing.expect(t, eventually(f, has_commands, len(ENTER)))
	barrier(t, f)
	testing.expect_value(t, fake_mode(f), "game")
	finish(t, f, r, 0)
}

@(test)
a_large_tree_is_read :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME, filler = 12_000})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	finish(t, f, r, 0)
}

@(test)
slow_replies_are_read :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME, dribble = true})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	finish(t, f, r, 0)
}

@(test)
a_refused_command_does_not_stop_the_rest :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME, refuse_commands = true})
	r := begin(t, f)
	testing.expect(t, eventually(f, has_commands, len(ENTER)))
	// All three were sent, and the watcher still runs.
	testing.expect_value(t, len(fake_commands(f)), 3)
	finish(t, f, r, 0)
}

// ── SIGTERM ──────────────────────────────────────────────────────────────────

@(test)
sigterm_in_game_returns_to_default :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	run_signal(r)
	testing.expect(t, run_done(r), "the watcher did not stop")
	both := make([dynamic]string, context.temp_allocator)
	append(&both, ..ENTER)
	append(&both, ..LEAVE)
	got := fake_commands(f)
	testing.expectf(t, same_strings(got, both[:]), "got %v", got)
	testing.expect_value(t, fake_mode(f), "default")
	finish(t, f, r, 0)
}

@(test)
sigterm_in_default_sends_no_command :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	run_signal(r)
	testing.expect(t, run_done(r))
	testing.expect_value(t, len(fake_commands(f)), 0)
	finish(t, f, r, 0)
}

@(test)
sigterm_ends_a_wait_for_a_hung_sway :: proc(t: ^testing.T) {
	// The tree request is never answered; the signal still ends the watcher
	// at once, and it leaves "game" on a fresh connection, which Sway does
	// answer.
	f := fake_start(t, {focused = GAME, mode = "game", hang_on = sg.MSG_GET_TREE})
	r := run_start(t, f, 60 * time.Second)
	testing.expect(t, eventually(f, has_subscriber, 1))
	testing.expect(t, eventually(f, has_state_requests, 0))
	time.sleep(50 * time.Millisecond)
	start := time.tick_now()
	run_signal(r)
	testing.expect(t, run_done(r))
	testing.expect(t, time.tick_diff(start, time.tick_now()) < 3 * time.Second)
	testing.expect(t, same_strings(fake_commands(f), LEAVE))
	finish(t, f, r, 0)
}

@(test)
sigterm_in_the_middle_of_leaving_finishes_leaving :: proc(t: ^testing.T) {
	// "mode default" is done and the cursor command hangs; the signal comes.
	// The mode is "default" by then, but the cursor hiding is still off.
	f := fake_start(t, {mode = "game", focused = "foot", hang_on = sg.MSG_RUN_COMMAND, hang_skip = 1, hang_once = true})
	r := run_start(t, f, 60 * time.Second)
	testing.expect(t, eventually(f, has_commands, 2))
	run_signal(r)
	testing.expect(t, run_done(r), "the watcher did not stop")
	got := fake_commands(f)
	testing.expectf(t, len(got) == 5 && same_strings(got[2:], LEAVE), "got %v", got)
	finish(t, f, r, 0)
}

@(test)
sigterm_in_the_middle_of_entering_leaves_game :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME, hang_on = sg.MSG_RUN_COMMAND, hang_skip = 1, hang_once = true})
	r := run_start(t, f, 60 * time.Second)
	testing.expect(t, eventually(f, has_commands, 2))
	run_signal(r)
	testing.expect(t, run_done(r), "the watcher did not stop")
	got := fake_commands(f)
	testing.expectf(t, len(got) == 5 && same_strings(got[2:], LEAVE), "got %v", got)
	testing.expect_value(t, fake_mode(f), "default")
	finish(t, f, r, 0)
}

@(test)
sigterm_before_the_first_reply_ends_it :: proc(t: ^testing.T) {
	f := fake_start(t, {hang_on = sg.MSG_SUBSCRIBE})
	r := run_start(t, f, 60 * time.Second)
	time.sleep(50 * time.Millisecond)
	run_signal(r)
	testing.expect(t, run_done(r))
	finish(t, f, r, 0)
}

@(test)
sigterm_when_sway_is_gone_is_a_clean_stop :: proc(t: ^testing.T) {
	f := fake_start(t, {focused = GAME})
	r := begin(t, f)
	expect_commands(t, f, ENTER)
	// Sway quits first at logout: its socket is gone when the signal comes.
	fake_stop(f)
	run_signal(r)
	testing.expect(t, run_done(r))
	code := run_end(r)
	// The hang-up may be seen before the signal (1), or the signal first
	// (0): both end the watcher, and neither leaves anything undone.
	testing.expect(t, code == 0 || code == 1, "unexpected exit")
	fake_free(f)
}

// ── --leave ──────────────────────────────────────────────────────────────────

leave_config :: proc(f: ^Fake, timeout := WAIT) -> sg.Config {
	return sg.Config{socket = f.socket, stop = -1, timeout = timeout, log = os.stderr}
}

@(test)
leave_returns_to_default_from_game :: proc(t: ^testing.T) {
	f := fake_start(t, {mode = "game", focused = GAME})
	code := sg.leave_if_game(leave_config(f))
	testing.expect_value(t, code, 0)
	testing.expect(t, same_strings(fake_commands(f), LEAVE))
	testing.expect_value(t, fake_mode(f), "default")
	fake_stop(f)
	fake_free(f)
	free_all(context.temp_allocator)
}

@(test)
leave_touches_no_other_mode :: proc(t: ^testing.T) {
	for mode in ([?]string{"default", "resize", "passthrough"}) {
		f := fake_start(t, {mode = mode})
		testing.expect_value(t, sg.leave_if_game(leave_config(f)), 0)
		testing.expect_value(t, len(fake_commands(f)), 0)
		testing.expect_value(t, fake_mode(f), mode)
		fake_stop(f)
		fake_free(f)
	}
	free_all(context.temp_allocator)
}

@(test)
leave_fails_on_garbage_and_on_a_dead_sway :: proc(t: ^testing.T) {
	cases := []Behavior {
		{binding_state = "not json"},
		{binding_state = `{"nomode":1}`},
		{hang_on = sg.MSG_GET_BINDING_STATE},
		{close_on = sg.MSG_GET_BINDING_STATE},
		{garbage_on = sg.MSG_GET_BINDING_STATE, garbage = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}},
		{mode = "game", close_on = sg.MSG_RUN_COMMAND, close_skip = 1},
	}
	for b in cases {
		f := fake_start(t, b)
		code := sg.leave_if_game(leave_config(f, 200 * time.Millisecond))
		testing.expectf(t, code == 1, "%v: exit %d", b, code)
		fake_stop(f)
		fake_free(f)
	}
	free_all(context.temp_allocator)
}

// ── a Sway that dies, hangs or lies ──────────────────────────────────────────

// dies runs the watcher against a fake with this behavior and returns its
// exit status, which must come without a signal.
dies :: proc(t: ^testing.T, b: Behavior, timeout := WAIT, after: proc(f: ^Fake) = nil) -> int {
	f := fake_start(t, b)
	r := run_start(t, f, timeout)
	if after != nil {
		eventually(f, has_state_requests, 1)
		after(f)
	}
	ended := run_done(r)
	testing.expect(t, ended, "the watcher did not end by itself")
	code := run_end(r)
	fake_stop(f)
	fake_free(f)
	free_all(context.temp_allocator)
	return code
}

@(test)
a_socket_that_dies_mid_stream_ends_with_status_1 :: proc(t: ^testing.T) {
	// The event stream hangs up.
	testing.expect_value(t, dies(t, {focused = "foot"}, after = fake_hang_up), 1)
	// The command connection hangs up at each of its requests.
	for ty in ([?]u32{sg.MSG_GET_TREE, sg.MSG_GET_BINDING_STATE}) {
		testing.expect_value(t, dies(t, {focused = "foot", close_on = ty}), 1)
	}
	// Even in the middle of entering game.
	testing.expect_value(t, dies(t, {focused = GAME, close_on = sg.MSG_RUN_COMMAND, close_skip = 1}), 1)
	// The subscription itself is not answered, or the peer hangs up.
	testing.expect_value(t, dies(t, {close_on = sg.MSG_SUBSCRIBE}), 1)
}

@(test)
a_hung_sway_ends_with_status_1 :: proc(t: ^testing.T) {
	for ty in ([?]u32{sg.MSG_SUBSCRIBE, sg.MSG_GET_TREE, sg.MSG_GET_BINDING_STATE}) {
		testing.expect_value(t, dies(t, {focused = "foot", hang_on = ty}, 150 * time.Millisecond), 1)
	}
	testing.expect_value(t, dies(t, {focused = GAME, hang_on = sg.MSG_RUN_COMMAND}, 150 * time.Millisecond), 1)
}

@(test)
a_refused_subscription_ends_with_status_1 :: proc(t: ^testing.T) {
	for reply in ([?]string{`{"success":false}`, `{}`, `[]`, `nonsense`}) {
		testing.expect_value(t, dies(t, {subscribe_reply = reply}), 1)
	}
}

@(test)
malformed_frames_end_with_status_1 :: proc(t: ^testing.T) {
	bad_magic := []u8{'x', '3', '-', 'i', 'p', 'c', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	huge_length := []u8{'i', '3', '-', 'i', 'p', 'c', 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0x80}
	half := []u8{'i', '3', '-', 'i', 'p', 'c', 100, 0, 0, 0, 3, 0, 0, 0x80, '{', '"'}
	for ty in ([?]u32{sg.MSG_SUBSCRIBE, sg.MSG_GET_TREE, sg.MSG_GET_BINDING_STATE}) {
		for garbage in ([?][]u8{bad_magic, huge_length, half, {'a', 'b'}}) {
			code := dies(t, {focused = "foot", garbage_on = ty, garbage = garbage}, 300 * time.Millisecond)
			testing.expectf(t, code == 1, "type %d, %v: exit %d", ty, garbage, code)
		}
	}
	// A reply of the wrong type.
	for ty in ([?]u32{sg.MSG_SUBSCRIBE, sg.MSG_GET_TREE, sg.MSG_GET_BINDING_STATE}) {
		testing.expect_value(t, dies(t, {focused = "foot", wrong_type_on = ty}), 1)
	}
}

@(test)
bad_json_in_a_reply_ends_with_status_1 :: proc(t: ^testing.T) {
	testing.expect_value(t, dies(t, {tree = "this is not a tree"}), 1)
	testing.expect_value(t, dies(t, {tree = `{"nodes":[`}), 1)
	testing.expect_value(t, dies(t, {binding_state = "{}"}), 1)
	testing.expect_value(t, dies(t, {binding_state = `{"name":7}`}), 1)
	deep := make([dynamic]u8, context.temp_allocator)
	for _ in 0 ..< 100_000 {
		append(&deep, '[')
	}
	testing.expect_value(t, dies(t, {tree = string(deep[:])}), 1)
}

@(test)
a_malformed_event_frame_ends_with_status_1 :: proc(t: ^testing.T) {
	bad_magic := []u8{'x', '3', '-', 'i', 'p', 'c', 0, 0, 0, 0, 3, 0, 0, 0x80}
	huge := []u8{'i', '3', '-', 'i', 'p', 'c', 0xff, 0xff, 0xff, 0xff, 3, 0, 0, 0x80}
	too_big := []u8{'i', '3', '-', 'i', 'p', 'c', 1, 0, 0, 1, 3, 0, 0, 0x80}
	for garbage in ([?][]u8{bad_magic, huge, too_big}) {
		f := fake_start(t, {focused = "foot"})
		r := begin(t, f)
		fake_raw(f, garbage)
		testing.expect(t, run_done(r), "the watcher did not end")
		testing.expect_value(t, run_end(r), 1)
		fake_stop(f)
		fake_free(f)
	}
	// A frame cut off by the hang-up.
	f := fake_start(t, {focused = "foot"})
	r := begin(t, f)
	fake_raw(f, []u8{'i', '3', '-', 'i', 'p', 'c', 50, 0, 0, 0, 3, 0, 0, 0x80, '{'})
	fake_hang_up(f)
	testing.expect(t, run_done(r))
	testing.expect_value(t, run_end(r), 1)
	fake_stop(f)
	fake_free(f)
	free_all(context.temp_allocator)
}

@(test)
without_a_sway_the_watcher_ends_with_status_1 :: proc(t: ^testing.T) {
	d := scratch(t)
	defer os.remove_all(d)
	r := new(Run)
	r.cfg = sg.Config{socket = "/nonexistent/sway-ipc.sock", stop = -1, timeout = time.Second, log = os.stderr}
	testing.expect_value(t, sg.watch(r.cfg), 1)
	free(r)
}
