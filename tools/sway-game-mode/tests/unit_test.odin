// The pieces on their own: the decision, the reading of Sway's JSON, the
// frames, and the command line.
package sway_game_mode_tests

import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import sg ".."

// ── the decision ─────────────────────────────────────────────────────────────

@(test)
enters_game_from_default_only :: proc(t: ^testing.T) {
	testing.expect_value(t, sg.decide("com.mojang.minecraft", "default"), sg.Action.Enter)
	testing.expect_value(t, sg.decide("com.mojang.minecraft", "game"), sg.Action.Nothing)
	// Resize and passthrough (a VNC session into another compositor) keep
	// the mode when a game gains focus, and so does a mode nobody knows.
	for mode in ([?]string{"resize", "passthrough", "", "Default", "mode game"}) {
		testing.expect_value(t, sg.decide("com.mojang.minecraft", mode), sg.Action.Nothing)
	}
}

@(test)
leaves_game_when_focus_goes_elsewhere :: proc(t: ^testing.T) {
	for app in ([?]string{"", "foot", "com.mojang.minecraft.launcher", "COM.MOJANG.MINECRAFT"}) {
		testing.expect_value(t, sg.decide(app, "game"), sg.Action.Leave)
		for mode in ([?]string{"default", "resize", "passthrough"}) {
			testing.expect_value(t, sg.decide(app, mode), sg.Action.Nothing)
		}
	}
}

@(test)
knows_the_events_that_matter :: proc(t: ^testing.T) {
	for c in ([?]string{"focus", "close", "new", "move", "init", "empty", "reload"}) {
		testing.expect(t, sg.is_event_change(c), c)
	}
	for c in ([?]string{"", "title", "fullscreen_mode", "floating", "urgent", "mark", "Focus", "focus "}) {
		testing.expect(t, !sg.is_event_change(c), c)
	}
}

// ── the tree ─────────────────────────────────────────────────────────────────

app_of :: proc(t: ^testing.T, tree: string) -> string {
	v, ok := sg.parse_json(transmute([]u8)tree, context.temp_allocator)
	testing.expect(t, ok, tree)
	return sg.focused_app(v, context.temp_allocator)
}

@(test)
finds_the_focused_window :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		app_of(t, `{"focused":false,"nodes":[{"focused":false,"nodes":[{"focused":true,"app_id":"foot"}]},{"focused":false,"app_id":"other"}],"floating_nodes":[]}`),
		"foot",
	)
	// A floating window.
	testing.expect_value(
		t,
		app_of(t, `{"focused":false,"nodes":[{"focused":false,"app_id":"a"}],"floating_nodes":[{"focused":true,"app_id":"com.mojang.minecraft"}]}`),
		"com.mojang.minecraft",
	)
}

@(test)
reads_the_class_of_an_xwayland_window :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		app_of(t, `{"focused":true,"app_id":null,"window_properties":{"class":"Steam","title":"x"}}`),
		"Steam",
	)
	// An empty app_id counts as none, as `app_id or class` did.
	testing.expect_value(t, app_of(t, `{"focused":true,"app_id":"","window_properties":{"class":"Steam"}}`), "Steam")
	testing.expect_value(t, app_of(t, `{"focused":true,"app_id":"foot","window_properties":{"class":"Steam"}}`), "foot")
}

@(test)
an_empty_workspace_has_no_app :: proc(t: ^testing.T) {
	testing.expect_value(t, app_of(t, `{"focused":false,"nodes":[{"type":"workspace","focused":true,"nodes":[]}]}`), "")
	testing.expect_value(t, app_of(t, `{"focused":false,"nodes":[]}`), "")
	testing.expect_value(t, app_of(t, `{"focused":true}`), "")
}

@(test)
survives_a_tree_of_the_wrong_shape :: proc(t: ^testing.T) {
	cases := [?]string {
		`[]`,
		`"x"`,
		`null`,
		`17`,
		`{"focused":"true","app_id":"foot"}`,
		`{"focused":1,"app_id":"foot"}`,
		`{"nodes":null,"floating_nodes":"x"}`,
		`{"nodes":[1,"a",null,[],{"focused":true,"app_id":7}]}`,
		`{"focused":true,"app_id":["foot"],"window_properties":"x"}`,
		`{"focused":true,"window_properties":{"class":5}}`,
	}
	for c in cases {
		testing.expect_value(t, app_of(t, c), "")
	}
}

@(test)
refuses_json_nested_too_deep :: proc(t: ^testing.T) {
	ok_depth := strings.concatenate({strings.repeat("[", sg.MAX_JSON_DEPTH, context.temp_allocator), strings.repeat("]", sg.MAX_JSON_DEPTH, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, sg.json_depth_ok(transmute([]u8)ok_depth))
	deep := strings.repeat("[", sg.MAX_JSON_DEPTH + 1, context.temp_allocator)
	testing.expect(t, !sg.json_depth_ok(transmute([]u8)deep))
	// A million brackets: refused at the 513th, without recursion.
	million := strings.repeat("{\"a\":", 1_000_000, context.temp_allocator)
	_, ok := sg.parse_json(transmute([]u8)million, context.temp_allocator)
	testing.expect(t, !ok)
	// Brackets inside strings, escaped quotes included, are no nesting.
	text := strings.concatenate({`{"title":"[[[[[[[[ \"[[[[", "x":"`, strings.repeat("[", 2000, context.temp_allocator), `"}`}, context.temp_allocator)
	testing.expect(t, sg.json_depth_ok(transmute([]u8)text))
}

@(test)
reads_the_mode_name :: proc(t: ^testing.T) {
	m, ok := sg.binding_mode(transmute([]u8)string(`{"name":"game"}`), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, m, "game")
	for bad in ([?]string{``, `{}`, `{"name":null}`, `{"name":3}`, `[]`, `"game"`, `{"name":"x"`, `not json`}) {
		_, bok := sg.binding_mode(transmute([]u8)bad, context.temp_allocator)
		testing.expectf(t, !bok, "%q", bad)
	}
}

@(test)
reads_an_events_change :: proc(t: ^testing.T) {
	testing.expect_value(t, sg.event_change(transmute([]u8)string(`{"change":"focus","container":{}}`), context.temp_allocator), "focus")
	for bad in ([?]string{``, `{}`, `[]`, `{"change":5}`, `{"change":`, `\xff\xfe`, `{"change":"fo`}) {
		testing.expectf(t, sg.event_change(transmute([]u8)bad, context.temp_allocator) == "", "%q", bad)
	}
}

@(test)
reads_what_sway_refused :: proc(t: ^testing.T) {
	r :: proc(s: string) -> string {
		return sg.failed_commands(transmute([]u8)s, context.temp_allocator)
	}
	testing.expect_value(t, r(`[{"success":true}]`), "")
	testing.expect_value(t, r(`[{"success":true},{"success":false,"error":"Unknown command"}]`), "Unknown command")
	testing.expect_value(t, r(`[{"success":false}]`), "the command failed")
	for odd in ([?]string{``, `{}`, `[]`, `[1,"x",null]`, `[{"success":"no"}]`, `garbage`}) {
		testing.expect_value(t, r(odd), "")
	}
}

@(test)
reads_the_subscription_reply :: proc(t: ^testing.T) {
	r :: proc(s: string) -> bool {
		return sg.subscribed(transmute([]u8)s, context.temp_allocator)
	}
	testing.expect(t, r(`{"success":true}`))
	for bad in ([?]string{``, `{}`, `{"success":false}`, `{"success":"true"}`, `[true]`, `x`}) {
		testing.expect(t, !r(bad), bad)
	}
}

// ── the frames ───────────────────────────────────────────────────────────────

@(test)
encodes_a_request :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	sg.encode_frame(&out, sg.MSG_RUN_COMMAND, "mode game")
	want := []u8{'i', '3', '-', 'i', 'p', 'c', 9, 0, 0, 0, 0, 0, 0, 0, 'm', 'o', 'd', 'e', ' ', 'g', 'a', 'm', 'e'}
	testing.expect_value(t, string(out[:]), string(want))
	clear(&out)
	sg.encode_frame(&out, sg.MSG_GET_BINDING_STATE, "")
	testing.expect_value(t, string(out[:]), "i3-ipc\x00\x00\x00\x00\x0c\x00\x00\x00")
	clear(&out)
	sg.encode_frame(&out, sg.EVENT_WINDOW, "{}")
	testing.expect_value(t, string(out[:]), "i3-ipc\x02\x00\x00\x00\x03\x00\x00\x80{}")
}

socket_pair :: proc(t: ^testing.T) -> (a, b: linux.Fd) {
	fds: [2]linux.Fd
	if linux.socketpair(.UNIX, .STREAM, .HOPOPT, &fds) != .NONE {
		testing.fail_now(t, "no socketpair")
	}
	return fds[0], fds[1]
}

send_bytes :: proc(fd: linux.Fd, data: []u8) {
	linux.send(fd, data, {.NOSIGNAL})
}

frame :: proc(type: u32, payload: string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	sg.encode_frame(&out, type, payload)
	return out[:]
}

@(test)
reads_frames_as_they_come :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	c := sg.Conn {
		fd      = a,
		stop    = -1,
		timeout = time.Second,
	}
	defer sg.conn_close(&c)
	defer linux.close(b)

	// Two frames in one write, and an empty one.
	both := make([dynamic]u8, context.temp_allocator)
	append(&both, ..frame(sg.EVENT_WINDOW, `{"change":"focus"}`))
	append(&both, ..frame(sg.EVENT_WORKSPACE, ``))
	append(&both, ..frame(7, `x`))
	send_bytes(b, both[:])
	ty, p, err := sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, ty, sg.EVENT_WINDOW)
	testing.expect_value(t, string(p), `{"change":"focus"}`)
	ty, p, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, ty, sg.EVENT_WORKSPACE)
	testing.expect_value(t, len(p), 0)
	ty, p, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, ty, u32(7))
	testing.expect_value(t, string(p), "x")

	// One frame, a byte at a time.
	one := frame(sg.EVENT_WINDOW, `{"change":"close"}`)
	for i in 0 ..< len(one) {
		send_bytes(b, one[i:i + 1])
		if i == 3 || i == 20 {
			time.sleep(time.Millisecond)
		}
	}
	ty, p, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, string(p), `{"change":"close"}`)
}

@(test)
reads_a_large_frame :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	c := sg.Conn {
		fd      = a,
		stop    = -1,
		timeout = 5 * time.Second,
	}
	defer sg.conn_close(&c)
	size := 3 << 20
	payload := strings.repeat("x", size)
	defer delete(payload)
	data := frame(sg.MSG_GET_TREE, payload)
	writer := thread.create_and_start_with_poly_data2(b, data, proc(fd: linux.Fd, d: []u8) {
			rest := d
			for len(rest) > 0 {
				n, e := linux.send(fd, rest, {.NOSIGNAL})
				if e != .NONE {
					break
				}
				rest = rest[n:]
			}
		})
	_, p, err := sg.read_frame(&c)
	thread.join(writer)
	thread.destroy(writer)
	linux.close(b)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, len(p), size)
}

@(test)
refuses_what_is_no_frame :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		data: []u8,
		want: sg.Net_Error,
	}
	huge := frame(0, "")
	huge[6], huge[7], huge[8], huge[9] = 0xff, 0xff, 0xff, 0xff
	just_over := frame(0, "")
	over := u32(sg.MAX_PAYLOAD + 1)
	just_over[6], just_over[7], just_over[8], just_over[9] = u8(over), u8(over >> 8), u8(over >> 16), u8(over >> 24)
	whole := frame(sg.EVENT_WINDOW, `{"change":"focus"}`)
	cases := [?]Case {
		{"bad magic", transmute([]u8)string("I3-IPC\x00\x00\x00\x00\x00\x00\x00\x00"), .Bad_Magic},
		{"plain text", transmute([]u8)string("HTTP/1.1 200 OK\r\n\r\n"), .Bad_Magic},
		{"four gigabytes", huge, .Too_Big},
		{"one byte over the limit", just_over, .Too_Big},
		{"header cut short", whole[:9], .Closed},
		{"payload cut short", whole[:len(whole) - 1], .Closed},
		{"nothing at all", {}, .Closed},
	}
	for c in cases {
		a, b := socket_pair(t)
		conn := sg.Conn {
			fd      = a,
			stop    = -1,
			timeout = time.Second,
		}
		send_bytes(b, c.data)
		linux.close(b)
		_, _, err := sg.read_frame(&conn)
		testing.expectf(t, err == c.want, "%s: %v, want %v", c.name, err, c.want)
		sg.conn_close(&conn)
	}
}

@(test)
a_silent_peer_times_out :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	defer linux.close(b)
	c := sg.Conn {
		fd      = a,
		stop    = -1,
		timeout = 50 * time.Millisecond,
	}
	defer sg.conn_close(&c)
	start := time.tick_now()
	_, _, err := sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Timeout)
	took := time.tick_diff(start, time.tick_now())
	testing.expectf(t, took >= 40 * time.Millisecond && took < 3 * time.Second, "took %v", took)
	// Half a frame and then silence is the same.
	send_bytes(b, frame(sg.EVENT_WINDOW, "{}")[:10])
	_, _, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Timeout)
}

@(test)
a_frame_that_stalls_in_the_stream_times_out :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	defer linux.close(b)
	c := sg.Conn {
		fd    = a,
		stop  = -1,
		stall = 50 * time.Millisecond,
	}
	defer sg.conn_close(&c)
	// Silence between frames is not a stall: the stream has no timeout.
	// Half a frame and then silence is.
	whole := frame(sg.EVENT_WINDOW, `{"change":"focus"}`)
	send_bytes(b, whole[:5])
	start := time.tick_now()
	_, _, err := sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Timeout)
	testing.expect(t, time.tick_diff(start, time.tick_now()) < 3 * time.Second)
	// A whole frame after a pause is read.
	d, e := socket_pair(t)
	defer linux.close(e)
	c2 := sg.Conn {
		fd    = d,
		stop  = -1,
		stall = 50 * time.Millisecond,
	}
	defer sg.conn_close(&c2)
	pause := thread.create_and_start_with_poly_data2(e, whole, proc(fd: linux.Fd, data: []u8) {
			time.sleep(150 * time.Millisecond)
			send_bytes(fd, data)
		})
	_, p, err2 := sg.read_frame(&c2)
	thread.join(pause)
	thread.destroy(pause)
	testing.expect_value(t, err2, sg.Net_Error.None)
	testing.expect_value(t, string(p), `{"change":"focus"}`)
}

@(test)
a_frame_begun_with_the_previous_one_stalls_too :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	defer linux.close(b)
	c := sg.Conn {
		fd    = a,
		stop  = -1,
		stall = 50 * time.Millisecond,
	}
	defer sg.conn_close(&c)
	// One whole frame and the first five bytes of the next, in one write.
	both := make([dynamic]u8, context.temp_allocator)
	append(&both, ..frame(sg.EVENT_WINDOW, `{"change":"focus"}`))
	append(&both, ..frame(sg.EVENT_WINDOW, `{"change":"close"}`)[:5])
	send_bytes(b, both[:])
	_, p, err := sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.None)
	testing.expect_value(t, string(p), `{"change":"focus"}`)
	start := time.tick_now()
	_, _, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Timeout)
	testing.expect(t, time.tick_diff(start, time.tick_now()) < 3 * time.Second)
}

@(test)
a_stop_ends_a_wait_at_once :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	defer linux.close(b)
	stop, _ := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	defer linux.close(stop)
	c := sg.Conn {
		fd      = a,
		stop    = stop,
		timeout = 0,
	}
	defer sg.conn_close(&c)
	one := u64(1)
	linux.write(stop, (cast(^[8]u8)&one)[:])
	_, _, err := sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Stopped)
	// A stop wins over data that is there.
	send_bytes(b, frame(sg.EVENT_WINDOW, "{}"))
	_, _, err = sg.read_frame(&c)
	testing.expect_value(t, err, sg.Net_Error.Stopped)
}

@(test)
a_request_gets_the_reply_of_its_own_type :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	c := sg.Conn {
		fd      = a,
		stop    = -1,
		timeout = 200 * time.Millisecond,
	}
	defer sg.conn_close(&c)
	defer linux.close(b)
	send_bytes(b, frame(sg.MSG_GET_TREE, `{}`))
	_, err := sg.request(&c, sg.MSG_GET_BINDING_STATE, "")
	testing.expect_value(t, err, sg.Net_Error.Unexpected)
	free_all(context.temp_allocator)
}

@(test)
a_dead_peer_breaks_a_request :: proc(t: ^testing.T) {
	a, b := socket_pair(t)
	c := sg.Conn {
		fd      = a,
		stop    = -1,
		timeout = 200 * time.Millisecond,
	}
	defer sg.conn_close(&c)
	linux.close(b)
	_, err := sg.request(&c, sg.MSG_GET_TREE, "")
	testing.expect(t, err == .Closed || err == .Failed)
	free_all(context.temp_allocator)
}

@(test)
cannot_dial_what_is_not_there :: proc(t: ^testing.T) {
	_, why := sg.dial("/nonexistent/sway-ipc.sock")
	testing.expect(t, strings.contains(why, "no such file"), why)
	_, why = sg.dial(strings.repeat("x", 108, context.temp_allocator))
	testing.expect(t, strings.contains(why, "longer"), why)
	d := scratch(t)
	defer os.remove_all(d)
	// A file that is no socket, and a directory.
	path := strings.concatenate({d, "/plain"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file_from_string(path, "x") == nil)
	_, why = sg.dial(path)
	testing.expect(t, why != "")
	_, why = sg.dial(d)
	testing.expect(t, why != "")
	free_all(context.temp_allocator)
}

// ── the command line ─────────────────────────────────────────────────────────

cli :: proc(t: ^testing.T, args: []string, env: sg.Env) -> (code: int, out: string) {
	d := scratch(t)
	defer os.remove_all(d)
	path := strings.concatenate({d, "/stderr"}, context.temp_allocator)
	f, err := os.create(path)
	if err != nil {
		testing.fail_now(t, "cannot create the stderr file")
	}
	code = sg.cli(args, env, -1, 300 * time.Millisecond, f)
	os.close(f)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return code, string(data)
}

@(test)
refuses_bad_usage :: proc(t: ^testing.T) {
	cases := [][]string{{"--socket"}, {"--frobnicate"}, {"extra"}, {"--socket", "a", "--socket", "b"}, {"leave"}, {"-leave"}, {"--leave=1"}}
	for args in cases {
		code, out := cli(t, args, {})
		testing.expectf(t, code == 2, "%v: exit %d", args, code)
		testing.expectf(t, strings.contains(out, "usage"), "%v: %q", args, out)
	}
	code, out := cli(t, {"--help"}, {})
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "usage"))
}

@(test)
finds_the_socket_as_swaymsg_does :: proc(t: ^testing.T) {
	testing.expect_value(t, sg.socket_path({socket = "/a"}, {swaysock = "/b", i3sock = "/c"}), "/a")
	testing.expect_value(t, sg.socket_path({}, {swaysock = "/b", i3sock = "/c"}), "/b")
	testing.expect_value(t, sg.socket_path({}, {i3sock = "/c"}), "/c")
	testing.expect_value(t, sg.socket_path({}, {}), "")
}

@(test)
says_so_without_a_socket :: proc(t: ^testing.T) {
	// A watcher has nothing to watch (1, and systemd retries); a --leave
	// has nothing to leave (0).
	code, out := cli(t, {}, {})
	testing.expect_value(t, code, 1)
	testing.expectf(t, strings.contains(out, "SWAYSOCK"), "%q", out)
	code, out = cli(t, {"--leave"}, {})
	testing.expect_value(t, code, 0)
	testing.expectf(t, strings.contains(out, "SWAYSOCK"), "%q", out)
}

@(test)
leave_without_a_sway_is_done :: proc(t: ^testing.T) {
	code, out := cli(t, {"--leave", "--socket", "/nonexistent/sway-ipc.sock"}, {})
	testing.expect_value(t, code, 0)
	testing.expectf(t, strings.contains(out, "nothing to leave"), "%q", out)
	code, out = cli(t, {}, {swaysock = "/nonexistent/sway-ipc.sock"})
	testing.expect_value(t, code, 1)
	testing.expectf(t, strings.contains(out, "no such file"), "%q", out)
}
