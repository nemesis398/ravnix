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
claude-roll update ...          # the update timer, root's step
claude-roll update-prepare ...  # the update, the user's first step
claude-roll update-finish ...   # the update, the user's last step
claude-roll remote-control      # restart Remote Control once no session is open
```

The update's three steps and the Remote Control restart are described in
"The update" below; `modules/workbench/claude-update.nix` runs them.

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
(below). The record must be of that session and of the Claude Code process
that runs in the pane now: its pid is in the pane's foreground
(`herdr pane process-info`), and `/proc` gives the same start time for it.
A record of another session or process (a Claude Code started inside this
one, a pane moved here, a hook that failed and left an older record) is not
used: the pane is left, and the user is told. `NAME` is the agent's herdr
name when it had one, else `claude-<pane>`.

A session whose turn has ended can still run work: a command its Bash tool
started in the background (a dev server, a long build). Claude Code runs
each such command in a shell of its own
(`bash -c source ~/.claude/shell-snapshots/snapshot-… && eval …`), in a
process group of its own, while its MCP servers stay in its group
(`proc.odin`, seen on Claude Code 2.1.323). A pane whose Claude Code has a
child that is such a shell, or that leads another group, waits like a
working one, and so does a pane whose processes cannot be read: /exit would
end that work.

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
{"pane":"w1:p1","session_id":"…","cwd":"/home/user/project","source":"startup","argv":["--add-dir","/home/user/notes"],"pid":4242,"start_time":28511566}
```

It reads the session from the hook's input and `argv` from the command line
of the Claude Code process above the hook (`/proc`, up to eight parents; a
process named `claude` or `.claude-wrapped`), with that process's pid and
start time (field 22 of `/proc/PID/stat`). It runs again at `/clear`,
`/compact` and a resume, so the record follows the session the pane runs
now. Outside a herdr pane (no `HERDR_PANE_ID`), for an id it cannot vouch
for, or without a Claude Code above it, it writes nothing. Nor does a Claude
Code started inside another one, which inherits the pane's `HERDR_PANE_ID`:
one with `CLAUDECODE` in its own environment (Claude Code sets it for what
it runs), or with another Claude Code above it. It always exits 0
and prints nothing on standard output.

On a roll, `flags.odin` keeps from `argv` only flags it knows (those of
Claude Code 2.1.323), with the number of values each takes, and drops the
old session's (`--resume`, `--continue`, `--session-id`, `--fork-session`)
and a first prompt. A flag it does not know, one a resume must not repeat
(`--worktree`, `--print`, `--bg`, …), a value with a control character, or a
missing or broken record leaves the pane on its version, and the user is
told why.

## The update

The twice-daily Claude Code update (`modules/workbench/claude-update.nix`,
06:00 and 18:00, Persistent) is three steps, because two parties hold what
it needs: root may switch the system, and only the user's vault holds the
git tokens and the signing key. Root never reads the vault, and never builds
what the account wrote.

1. `claude-roll update` (root, `ravnix-claude-update.service`):
   - `--mode bump` (the server) reads `RELEASES/latest` with curl (https
     only, 30 s, 1 KiB) and stops when the host runs that version or a newer
     one. An answer that is no version, or none, ends the run with 75.
   - It starts the user's prepare unit (`systemctl --machine=USER@.host
     --user start`) and reads the lock it leaves as the user (`setpriv ...
     cat`). On the laptop (`--mode follow`) a prepare that exits 75 (the
     vault is locked) or a user manager that is not there ends the run with
     75 and outcome `Waiting`, and tells nobody.
   - `--mode follow` takes no revision from that lock. The lock was written
     by the server's account, and GitHub serves a commit of any fork under
     the upstream's own URL, so a revision in it may be one only a fork has,
     whose package can name Anthropic's genuine download for
     claude-code-verify and install something else. The lock is only the
     sign: when its input revision is the deployed one, the run ends
     (nothing to follow). Otherwise root copies the deployed flake to
     `STATE/work` and runs `nix flake update --refresh INPUT` there itself,
     which asks the input's own repository for the head of its branch; it
     fails with 75 when that cannot be reached. The result must pass the
     same rules as the server's candidate, and leave every other node as
     it was.
   - It compares the new lock's input nodes with the deployed flake's
     (`lockfile.odin`): the input's node and the nodes only it reaches, with
     the same names, inputs and `original`, and in `locked` nothing but
     `rev`, `narHash`, `lastModified` and `revCount` changed. Anything else
     is refused. A lock that moved nothing ends the run (claude-code-nix has
     not caught up; on the laptop, the head of the branch is the deployed
     revision whatever the server's lock names).
   - It copies the deployed flake (`--flake`, a store path) to
     `STATE/work` (the server; the laptop has already), puts the new input
     nodes into its lock (the other nodes stay the deployed ones), and
     evaluates the package's version with the
     `--override` inputs (the ravnix the host runs). A version that is not
     newer than `--running` is waited for on the server and refused on the
     laptop.
   - It builds the host's toplevel and the package's download, runs
     `claude-code-verify --releases RELEASES DOWNLOAD VERSION` (exit 3, an
     unreachable manifest, ends the run with 75 and switches nothing), sets
     the system profile and runs `switch-to-configuration switch`.
   - It writes `STATE/result.json` (status `switched`, `build-failed`,
     `verify-failed`, `switch-failed` or `refused`, the versions, the
     candidate's sha256 and a message) and starts the user's finish unit.
     On the laptop the message of a switch names the revision it took, and
     the one the server's lock named when the two differ; that is a notice,
     not a failure.
   - On the laptop it leaves `STATE/pending` after a run that ended with 75
     for want of the vault, the user's manager, the input's repository or
     the manifest, and removes it after any other run but a locked one.
     `ravnix-claude-update-retry.timer` starts the update every hour while
     the file is there.
2. `claude-roll update-prepare` (the user): fetches `--branch` of
   `--remote` into a bare repository of its own (`STATE/flake.git`) over
   HTTPS, where git asks the token helper of `ravnix.secrets.gitTokens`. On
   the server it checks the fetched tree out into `STATE/tree` and runs `nix
   flake update INPUT` there, and refuses a result that changed any other
   node. It leaves the lock in `STATE/candidate.lock` and the commit in
   `STATE/base`. A failed fetch or update is told to the user. On the
   laptop it first asks `rbw unlocked`, and with the vault locked exits 75
   without a word: the token for the private remote is in the vault.
3. `claude-roll update-finish` (the user): reads root's result once (by its
   id). A failure is told to the user, and on the laptop a switch with
   root's message. On the server a switch is committed
   without a working tree: the candidate becomes `flake.lock` of a tree made
   from `base`, `git commit-tree -S` signs it through rbw's agent, and `git
   push REMOTE COMMIT:refs/heads/BRANCH` sends it (never forced, so a branch
   that moved meanwhile refuses it). Then it starts the roll units
   (`--roll-unit`, `claude-roll.service` and
   `claude-remote-control-roll.service`) and tells the user. It publishes
   only the candidate whose sha256 root built.

The messages go to the `updates` topic of ravnix-notify; the roll's and
Remote Control's to `sessions`.

`claude-roll remote-control` restarts Claude Code's Remote Control unit
(`--unit`, by default `claude-remote-control.service`) once its control
group holds its main process alone; each phone session is a process beside
it, and a restart ends them all. It looks every minute until the deadline,
then leaves the unit on its version and tells the user how to restart it. A
group it cannot read counts as busy; a unit that stopped or restarted by
itself meanwhile is left alone.

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
  sleeps move: idle, working until idle, working past the deadline, a record
  of another session or process, a background task, unreadable processes, the
  deadline in a wait and during a roll, blocked, a dialog that herdr calls
  idle (every dialog screen), a new session after `/clear`, a failed resume,
  a shell that never comes, a start that waits at a dialog, `--dry-run`,
  herdr not running, missing or dying, a list that is no list, a pane gone
  between list and read, a screen that changes between the reads, odd
  session ids, missing and broken records, the busy file, a refused and an
  unanswered `/exit`, a failing ravnix-notify, the lock.
- `lockfile_test.odin`: which nodes an input owns (follows paths, a node
  another input shares, a dangling node), what a new revision may change
  (another owner, `original`, type, field, node, input or `flake` is
  refused), locks that are none, too large or nested 200 000 deep (root
  parses what the user wrote, so the nesting is bounded before the
  parser recurses), and the splice, escapes included.
- `update_test.odin`: the update against a world in the test
  (`fake_update.odin`) that answers and records every program: an equal or
  older version, an unreachable or garbled `latest`, the whole bump in
  order (the overrides, the input nodes taken, the others kept), a failed
  evaluation, build and download, a manifest mismatch and an unreachable
  manifest, a failed profile and switch, claude-code-nix not caught up, a
  lock that points elsewhere or is none or is huge, a failed prepare and a
  missing candidate, two runs at once, following by root's own update of
  the input, a lock that names a fork's revision (with upstream moved and
  not), root's own update moving more or elsewhere or out of reach,
  following back to an older version, a locked vault or no user manager on
  the laptop (a quiet 75, the pending marker, and the run after the unlock);
  prepare's bump, a bump that moved more, a locked vault (told on the
  server, a quiet 75 on the laptop) and a refused token, a failed `nix
  flake update`, a branch without a lock, the lock; finish's signed commit
  and push, the same result twice, a refused push, a failed signature, a
  candidate root did not build, a failure, the laptop and root's message
  there, results that are none; versions, and the command lines.
- `remote_control_test.odin`: Remote Control against a fake
  `/sys/fs/cgroup`: idle, a session until the deadline, a session that ends,
  a session in a group below, an unreadable or foreign group, a stopped unit,
  a unit that restarted by itself, a failed restart.
- `cli_test.odin`: the command line, durations, and the runner through real
  processes (`testdata/fake-herdr`): `--dry-run`, a herdr that is not there,
  one whose server is gone, one that hangs, one that prints without end.

`claude/hooks/tests/busy-state.test.sh` tests the busy hook, and
`tests/claude/home.nix` both hooks as a home wires them.
`tests/workbench/claude-update.nix` runs the update in three VMs: the server,
the laptop, and a forge that stands in for Forgejo and for
downloads.claude.ai.

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
- The background-work check on the server's Claude Code: that its Bash tool
  shells still carry `shell-snapshots/snapshot-` and their own process
  group, and that its MCP servers stay in its group. Record the footer a
  session shows while a background task runs; a screen check on it would be
  a second signal beside the process check.

## Unverified, for the first unattended update on the hosts (Task 6.1)

- That `claude remote-control --spawn worktree` runs each phone session as a
  process of its own in the unit's control group, and nothing else beside
  its main process while idle. If it ran sessions inside the main process,
  the restart would end them; if it kept a helper process, it would never
  restart and the user is told after the deadline.
- That `switch-to-configuration switch`, run from root's update unit, leaves
  that unit running (restartIfChanged is off, as for system.autoUpgrade),
  and the real build and switch time of a Claude Code bump on the server.
- That `systemctl --machine=USER@.host --user start` reaches the user's
  manager on the real hosts as it does in the VMs.
- That root on the laptop gets the head of `github:sadjow/claude-code-nix`
  with `nix flake update --refresh claude-code` and no token (GitHub's
  limit for anonymous API calls is 60 an hour; the VM's upstream is a git
  URL on the forge).

## Known gaps

Findings the tests turned up or the design leaves, not fixed:

- The update: a refused push (the branch moved, the forge is down) leaves
  the server switched and the laptop behind until a later update pushes;
  nothing retries the push before then.
- The update: the laptop runs at the same 06:00 and 18:00 as the server, so
  a laptop awake at 18:00 sees the server's push only at the next run
  (`ravnix.claudeUpdate.times` sets other times per host).
- The update: going back to an older Claude Code is a deploy by hand; the
  timer refuses a lock with an older version on the laptop, and waits on the
  server.
- The update: on the server root still builds the revision the account's
  `nix flake update` chose, so a compromised account there can have root
  install a fork's revision. ravnix takes only the input's package, which
  runs as that same account, so it gains nothing it lacked; the laptop,
  whose user is another, takes no revision from the server's lock.
- The update: on the laptop a fetch that fails for want of the network is
  told, as on the server, and not retried before the next timer; only a
  locked vault, a missing user manager, an unreachable input repository or
  manifest wait for the hourly retry.
- The update: the laptop's follow can take a newer head of the input's
  branch than the server built, before the server has run it.
- The update: a run that stops between prepare and finish (a reboot) leaves
  a candidate behind, which the next prepare replaces; nothing is lost, and
  nothing is committed for it.
- The update: the manifest's signature is not checked
  (`tools/claude-code-verify/README.md`).

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
- The background-work check reads how Claude Code 2.1.323 starts its
  processes. A version that starts an MCP server in a process group of its
  own holds every pane with that server back until the deadline (safe, and
  visible in the log); one that starts Bash tool shells in its own group
  without the snapshot line would let a background task through.
- A pane whose shell has `CLAUDECODE` in its environment (herdr started
  from inside a Claude Code session) writes no record, so its sessions are
  left and reported on every run.
