# sway-game-mode

Holds Sway in mode `game` while a game window has focus. It runs as the user
service `sway-game-mode` (`modules/desktop/sway.nix`), started with
`sway-session.target`.

Sway binds the MX Master's Back and Forward (button8/9, copy and paste) and
the gesture keys F14-F18 (sway-mouse) for every window, so a game never sees
them. Mode `game` in the Sway config (`modules/desktop/sway/config`) leaves
exactly those unbound. The watcher switches into it when a window of its list
gains focus, and back to `default` when focus goes anywhere else, an empty
workspace included (2026-11-06, for Minecraft 26.3).

```sh
sway-game-mode [--leave] [--socket PATH]
```

- no argument: watch, until SIGTERM or SIGINT (exit 0, after leaving `game`)
  or until Sway goes away or breaks the protocol (exit 1; the unit restarts
  it after 2 s).
- `--leave`: leave `game` if Sway is in it, and exit. Exit 0 also when there
  is no Sway to ask. The unit's `ExecStopPost` runs it, so a crash (where the
  SIGTERM handling never ran) cannot leave Sway in `game` with the mouse
  buttons unbound and no watcher.
- `--socket PATH`: Sway's IPC socket. The default is `$SWAYSOCK`, then
  `$I3SOCK`, as `swaymsg` finds it. The unit has no Sway on its `PATH` and
  needs none: the tool speaks the IPC protocol itself (`ipc.odin`), so it
  runs no other program.
- exit 2: bad usage.

## What it does

1. It subscribes to the `window` and `workspace` events, and only then looks
   at the tree once (the Python watcher looked first, so a change in between
   was lost).
2. For each event whose `change` is `focus`, `close`, `new`, `move`, `init`,
   `empty` or `reload`, it asks for the tree and the binding state and
   decides:
   - the focused node's `app_id` (or, for an XWayland window, its
     `window_properties.class`) is in `GAMES` (`watcher.odin`; today
     `com.mojang.minecraft`) and the mode is `default`: **enter**;
   - it is not, and the mode is `game`: **leave**;
   - anything else: nothing. In particular a focus change while you are in
     `resize` or `passthrough` leaves that mode alone, in both directions.
     An empty workspace holds the focus itself and has no app.
3. **Enter** sends `mode game`, `seat * hide_cursor when-typing disable` and
   `seat * hide_cursor 0`. **Leave** sends `mode default`,
   `seat * hide_cursor when-typing enable` and `seat * hide_cursor 8000`,
   the values of `seat * hide_cursor` in the Sway config. Keep `HIDE_*` in
   step with it.

`reload` arrives on the workspace channel: `swaymsg reload` resets Sway to
mode `default` while the game keeps focus, and no focus event follows.

Why the cursor: `seat * hide_cursor when-typing` hides the cursor on every
key press by sending the window a `wl_pointer.leave`, and `hide_cursor 8000`
does the same after 8 s without motion. SDL takes a leave as "all buttons
released", so Minecraft stopped mining whenever W was pressed during a held
click (measured with `WAYLAND_DEBUG` on `wev`, 2026-11-06).

To add a game, put its app_id (or XWayland class) into `GAMES`; read it with

```sh
swaymsg -t get_tree | jq -r '.. | select(.focused?) | .app_id // .window_properties.class'
```

## Differences from the Python watcher

- It enters `game` only from `default`. The Python watcher entered it from
  any mode but `game`, so a game gaining focus during `resize` or
  `passthrough` (a VNC session into another compositor) switched that mode
  away, against its own documentation ("a focus change while you are in
  `resize` or `passthrough` leaves that mode alone"). The check
  `desktop-sway-game-mode` shows the old behavior failing on the same cases.
- It subscribes before the first look, not after.
- A Sway that answers with garbage ends the watcher with status 1 and one
  line in the journal; the Python watcher died with a traceback or ignored
  the line. A command that Sway refuses (`"success": false`) is logged as
  `sway refused "...": reason`, and the rest still run.
- It logs each entering and leaving, one line each.
- An unknown argument is a usage error (2), not a silent watch.

## The protocol, and what it refuses

Frames are `i3-ipc`, the payload length and the message type as two 32-bit
integers in the host's byte order, and the JSON payload. The tool sends
`subscribe`, `get_tree`, `get_binding_state` and `run_command`, and reads a
reply of the type of its request. It uses two connections: one for the event
stream, one for requests, so an event can never be taken for a reply.

- A frame that does not start with the magic, or announces a payload over
  16 MiB, ends the watcher with status 1, before anything is read for it.
- A tree nested deeper than 512 brackets is refused before the JSON parser
  (which recurses) sees it.
- Each request waits 10 s at most, the connect included (it is non-blocking
  and polls the stop descriptor, so a Sway whose listen backlog is full
  holds neither the watcher nor `--leave`); a Sway that does not answer ends
  the watcher with status 1. The event stream has no timeout between
  frames, but a frame that has begun, also one that came in with the
  previous frame, must finish within 10 s.
- SIGTERM and SIGINT write to an eventfd that every wait polls next to the
  sockets, so a signal ends a wait at once, in the main flow and not in the
  handler. Writes poll it too. The watcher then leaves `game` on a new
  connection that no signal interrupts, so the leave itself finishes. A stop
  in the middle of entering or leaving runs the whole leave whatever the
  mode is, so the cursor hiding is never left off with the mode already
  `default` (the Python watcher had that hole).
- Window titles are not trusted: the tests read trees with non-ASCII text, a
  lone surrogate escape, raw invalid UTF-8 and a NUL, which
  `core:encoding/json` takes.
- An event whose payload is not a JSON object, has no `change` or is of
  another type is skipped, like Python skipped an unreadable line.

## Tests

`tests/` runs the watcher and `--leave` against a stand-in for Sway (a Unix
socket in a thread of the test, with its own frame code): the commands in
order, each mode, SIGTERM, a Sway that hangs up, hangs, answers in bytes or
in the wrong type, a refused subscription, a truncated, oversized or
mismatched frame, a 12 000-window tree, replies one byte at a time, bursts of
events, and a tree 100 000 levels deep. `tests/desktop/sway-game-mode.nix`
(`desktop-sway-game-mode`) runs the built tool against a real headless Sway
with real windows (foot): the same cases, plus a killed watcher and
`--leave`, and Sway going away.

## Findings not fixed

- The seat's `hide_cursor` values cannot be read back from Sway. The unit
  tests check the commands the tool sends, and the check against a real Sway
  that Sway accepts every one of them (it logs `sway refused` otherwise),
  but nothing observes the cursor itself.
- After a hand-leave (Super+Shift+Escape in `game`) with the game still in
  focus, the next event that makes the watcher look (a new window anywhere,
  a window moved) enters `game` again. The Python watcher did the same. The
  hand-leave is for the case where the watcher left `game` stuck, not a way
  to use the other bindings while the game is focused.
- The watcher subscribes to no `mode` event on purpose: looking again at
  every mode change would undo that hand-leave.
- The bench measures the run that finds no Sway (`--leave --socket` on a
  path that is not there), about 8 000 instructions that are nearly all
  Odin's start. A run with a Sway needs a compositor, which the bench has
  not, so a slowdown of the event loop is not caught by it.
- `GAMES` is in the source. A second game is a rebuild, as it was before.
