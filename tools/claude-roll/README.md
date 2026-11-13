# claude-roll

Rolls the Claude Code sessions that run in herdr's panes on the server onto
the Claude Code that is installed now, so a new version reaches every
session without ending its work. Task 6.1's update timer runs it after a
switch that changed the Claude Code version; herdr itself is never updated
in the same run, because a restart of the herdr server resumes every pane at
once, whatever its state.

```sh
claude-roll [--dry-run] [--deadline 3h] [--state DIR] [--herdr PATH] [--ravnix-notify PATH]
claude-roll record              # Claude Code's SessionStart hook
claude-roll classify FILE...    # what claude-roll makes of a recorded screen
```

`claude-roll --help` has the options and the exit status: 0 done (sessions
left on their version included), 1 herdr could not be read or a session did
not come back, 64 bad usage, 75 another claude-roll runs.

## What it does with each pane

`herdr agent list` gives every agent with its state and session. Only the
Claude Code panes of the first list are handled; a pane that appears later
already runs the new version.

| herdr says | claude-roll |
| --- | --- |
| `idle`, `done` | reads the screen; if it is ready (below), types `/exit`, waits for the pane's shell, and runs `herdr agent start NAME --kind claude --pane PANE --timeout 120000 -- --resume SESSION FLAGS` |
| `working`, `unknown` | tries again every 30 s until the deadline (3 h), then leaves it on its version until the next run |
| `blocked` | never touches it, and tells the user |

The session is herdr's `agent_session` when its kind is `id`, else the one
the pane's record holds; either must be a UUID, or nothing is sent. The
flags are what the pane's Claude Code was started with, from its record
(below). `NAME` is the agent's herdr name when it had one, else
`claude-<pane>`.

Before it types anything it reads the screen twice, 0.5 s apart
(`herdr agent read PANE --source visible --format ansi`), and types only
when both reads show the same empty input box (`screen.odin`):

- The input box of Claude Code is at the bottom: two rules, `❯` and a blank
  as the input line, and at most a status line and a mode line under it.
- Nothing is typed in it. A prompt suggestion, which Claude Code draws dim,
  is no input; text in a color is. Without the ANSI codes, any text is.
- No turn runs: no spinner line with `…` above the box, no
  `esc to interrupt`, no background agents waited for.
- Not vim's NORMAL mode, where letters are commands.
- No dialog anywhere on the screen: `Resume this conversation?`, a
  permission prompt, a question form, a menu (`DIALOG_WORDS`). herdr takes
  some of them for idle; claude-roll never types into one
  and tells the user.

The busy file that `claude/hooks/busy-state.sh` writes per session is a
second signal: while it says `busy`, the pane waits like a working one.

`/exit` goes through `herdr agent prompt`, which refuses, before it types
anything, an agent that is blocked, gone or not ready. Once it is sent, the
deadline no longer counts: the session has stopped, so claude-roll waits up
to 60 s for the shell (`herdr pane process-info` shows the shell in the
foreground and `herdr pane get` no agent) and starts it again. If the shell
does not come, or the start fails, the user gets the session id to resume
by hand (`claude --resume SESSION`), and the run exits 1. A start that
herdr reports as `agent_not_ready` (the resumed session waits at a dialog)
is reported too.

`--dry-run` reads the list and the screens, and logs what it would type,
start and notify. It sends, types and notifies nothing, takes no lock, and
makes one pass without waiting. The tests check it against a fake herdr that
records every call, in the process and through real processes.

Two runs at once: the second finds the lock (`DIR/claude-roll.lock`, an
`flock`) and exits 75 without a call to herdr.

The messages go to `ravnix-notify --topic sessions`, once per pane and run;
a failing ravnix-notify is logged and the run goes on. The log goes to
standard error, which the timer's journal keeps.

## The record of a pane

Claude Code keeps a session's conversation, not the flags it was started
with: `--add-dir`, `--settings`, `--mcp-config` and the rest are gone after a
plain `claude --resume`. `claude-roll record`, Claude Code's SessionStart
hook (`claude-pane` in `modules/common/claude-skills.nix`), writes
`$XDG_STATE_HOME/ravnix/claude-panes/<pane>.json`:

```json
{"pane":"w1:p1","session_id":"…","cwd":"/home/user/project","source":"startup","argv":["--add-dir","/home/user/notes"]}
```

It reads the session from the hook's input and `argv` from the command line
of the Claude Code process above the hook (`/proc`, up to eight parents; a
process named `claude` or `.claude-wrapped`). It runs again at `/clear`,
`/compact` and a resume, so the record follows the session the pane runs
now. Outside a herdr pane (no `HERDR_PANE_ID`), for an id it cannot vouch
for, or without a Claude Code above it, it writes nothing. It always exits 0
and prints nothing on standard output.

On a roll, `flags.odin` keeps from `argv` only flags it knows (those of
Claude Code 2.1.323), with the number of values each takes, and drops the
old session's (`--resume`, `--continue`, `--session-id`, `--fork-session`)
and a first prompt. A flag it does not know, one a resume must not repeat
(`--worktree`, `--print`, `--bg`, …), a value with a control character, or a
missing or broken record leaves the pane on its version, and the user is
told why.

## Tests

`claude-roll-tests` runs `tests/`:

- `screen_test.odin`: every screen in `testdata/screens` against its verdict,
  the dim tell, the true-color `2` that is no dim, prompts that are not
  Claude Code's, malformed and huge input.
- `flags_test.odin`: the flags kept and dropped, the ids accepted.
- `record_test.odin`: the hook against a fake `/proc`: wrappers, `/clear`,
  loops in the tree, odd ids, no Claude Code above it.
- `roll_test.odin`: the roll against a herdr in the test
  (`fake_herdr.odin`) that records every call and keeps a clock that only
  sleeps move: idle, working until idle, working past the deadline, the
  deadline in a wait and during a roll, blocked, a dialog that herdr calls
  idle (every dialog screen), a new session after `/clear`, a failed resume,
  a shell that never comes, a start that waits at a dialog, `--dry-run`,
  herdr not running, missing or dying, a list that is no list, a pane gone
  between list and read, a screen that changes between the reads, odd
  session ids, missing and broken records, the busy file, a refused and an
  unanswered `/exit`, a failing ravnix-notify, the lock.
- `cli_test.odin`: the command line, durations, and the runner through real
  processes (`testdata/fake-herdr`): `--dry-run`, a herdr that is not there,
  one whose server is gone, one that hangs, one that prints without end.

`claude/hooks/tests/busy-state.test.sh` tests the busy hook, and
`tests/claude/home.nix` both hooks as a home wires them.

The bench classifies six screens (`bench/`), a full viewport among them.

### Where the test data comes from

- `testdata/herdr/*.json`: what herdr 0.9.5 printed on a live server
  (`agent list`, `pane process-info`, `pane get`, the errors
  `server_not_running`, `agent_not_found`, `pane_not_found`), with paths,
  titles and ids replaced; the replies that need a real roll (`agent start`,
  `agent prompt`, `agent_blocked`, the start errors) are built from herdr's
  source (`src/api/schema`, `src/app/agents.rs`, `src/cli/agent.rs`).
- `testdata/screens/idle-suggestion.txt` and `working-spinner.txt`: recorded
  from live Claude Code 2.1.323 panes, with the transcript text replaced; the
  box, its rules, the dim suggestion and the spinner line are as recorded.
- The other screens are rebuilt from Claude Code 2.1.323's own strings (the
  `Resume this conversation?` dialog, its options and its `Enter to
  confirm`), herdr's Claude detection rules (the permission prompts, the
  forms, the transcript viewer), and the shape of a question form seen on a
  live pane, with made-up text.

## Unverified, for the end-to-end run on the server (Task 6.2, step 5)

- That `/exit` sent through `herdr agent prompt` (a bracketed paste, then
  Enter) runs the command and returns the pane to its shell.
- The whole `herdr agent start … -- --resume` round trip, and whether a
  resumed session stops at `Resume this conversation?` on startup (then it
  is reported as waiting at a dialog).
- Where Claude Code draws `Resume this conversation?` in its idle variant,
  and how often an idle session shows it. Record a real screen of it and of
  a permission prompt into `testdata/screens` and check them with
  `claude-roll classify`.
- Whether an older Claude Code reads a transcript a newer one wrote, which
  the rollback (pin the previous version and switch) relies on.

## Known gaps

Findings the tests turned up or the design leaves, not fixed:

- A session that shows `Resume this conversation?` while idle is never
  rolled, and the user is told on every run. Escape would dismiss the idle
  variant, but in the variant shown after a submitted prompt Escape resumes
  the conversation, so claude-roll presses nothing.
- A pane in vim's NORMAL mode is never rolled; it waits until the deadline.
- A turn interrupted with Esc ends without Stop, so the busy file says busy
  until the next prompt's Stop, and the pane waits until the deadline.
- A dialog word that only appears in the transcript (a session that talks
  about permission prompts) makes claude-roll leave the pane and report a
  dialog. That costs a roll, never a keystroke.
- Sessions started before the hook was installed have no record; they are
  left and reported on every run until they are started again. So is a pane
  moved to another workspace, whose id changes while its Claude Code keeps
  the old one in `HERDR_PANE_ID`.
- The flags table is that of Claude Code 2.1.323; a flag added later leaves
  its panes on their version until it is added to `flag_of`.
- Between the second read of a screen and the `/exit` there are a few
  milliseconds in which a dialog could come up; herdr's own refusal of a
  blocked agent narrows it, nothing closes it.
- The resumed session starts in the shell's working directory. A session
  whose Claude Code ran elsewhere than the shell (`--worktree` is refused for
  this reason) fails to resume, and the user gets its id.
- A pane without a herdr name gets `claude-<pane>` as its name after the
  roll, which herdr shows.
