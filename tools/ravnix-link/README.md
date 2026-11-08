# ravnix-link

The link between the two hosts. The terminal applications run on the
server, muninn, which has no screen; what they open, the notifications they
show and the notes they move in Obsidian belong on the laptop, huginn.
`ravnix-link` on the server turns each of these into a request and sends it
to `ravnix-link daemon` on the laptop, over a Unix socket that the main
connection forwards from the laptop to the server. While the laptop is
away, the requests wait in a queue on the server's disk, and when it is
back they are delivered once each and in order. `vault-commit` commits in
the server's copy of the vault, after the Obsidian operations queued before
it, once that copy shows what they did.

```
usage: ravnix-link [OPTION...] COMMAND [ARG...]

On the server (muninn), forwarded to the laptop (huginn), queued while it is away:
  open URL|PATH                       open a link or a file on the laptop (xdg-open)
  notify [--topic T] [--urgency U] [--app NAME] SUMMARY [BODY]
  notify-send [OPTION...] SUMMARY [BODY]
  obsidian move path=P to=P           move a note in Obsidian on the laptop
  obsidian rename path=P name=N       rename a note
  obsidian delete path=P              move a note to the trash
  vault-commit MESSAGE [PATH...]      commit PATHs (or what is staged) in the vault
  flush                               deliver what waits, now
  deliver                             deliver whenever the laptop is back (a service)
  status                              list what waits, and the commits that failed
  dismiss                             clear the list of commits that failed

On the laptop:
  daemon                              carry out what the server sends

Options:
  --socket PATH   --state DIR   --vault DIR   --git PATH   --ravnix-notify PATH
  --xdg-open PATH   --notify-send PATH   --obsidian PATH   --systemd-run PATH
```

`ravnix-link --help` prints the whole text. The socket defaults to
`$XDG_RUNTIME_DIR/ravnix-link.sock`, the state to
`$XDG_STATE_HOME/ravnix-link` (`~/.local/state/ravnix-link` without it).

| Exit | Means |
| --- | --- |
| 0 | done on the laptop, or queued for it (another run may be delivering it, or a commit waits for its next attempt); a notification dropped as too old |
| 1 | failed on the laptop or the server, refused (a full queue, a request too long), or `notify --topic` could not post to the room |
| 64 | bad usage: an unknown command or option, a missing or extra argument, a value the protocol does not take |

What waits, what failed and why go to standard error, one line each. Every
command on the server but `status` and `dismiss` also warns there of the
commits that failed for good, until `dismiss` clears them.

## On the server

Each command makes a request with a fresh UUID and the time, appends it to
the queue and delivers what waits, at once. When the laptop is there, the
command waits for the daemon's reply and exits with it; when it is away, it
says the request is queued and exits 0.

- **`open URL|PATH`.** A URL of `http`, `https` or `mailto`, the scheme in
  lower case, or a path, which is made absolute against the working
  directory. Every other scheme is refused, `obsidian:` and `file:` among
  them: an `obsidian:` URL reaches the plugins and the URI handlers of the
  vault (`obsidian://new?...&overwrite` writes a note), and a file opens by
  its path. A note, too, opens by its absolute path, with the laptop's
  default application for its type. The file must be at the same path on
  the laptop, as the synced folders are; the server does not check.
- **`notify`.** A summary, an optional body, `--urgency low|normal|critical`
  and `--app NAME`. With `--topic T` (lower case letters, digits and `-`),
  it also runs `ravnix-notify --topic T MESSAGE`, which posts to that topic's
  Matrix room; the notification is queued either way, and the exit is 1 if
  the room did not get it. A notification that reaches the laptop more than
  10 minutes after it was made is dropped, not shown.
- **`notify-send`.** The server's `notify-send`: it reads libnotify's
  options as libnotify does, runs the real `notify-send` with the same
  arguments (on a server without a notification service that fails, and its
  output and status are dropped), and forwards the summary, the body, the
  urgency and the application's name. `--help` and `--version` are the real
  one's.
- **`obsidian move|rename|delete`.** As Obsidian's CLI takes them:
  `path=` a note relative to the vault's root, `to=` a folder or path in it,
  `name=` the new name. Refused: a bare word, `file=`, `vault=`,
  `permanent`, a key twice, any other key, an absolute path, a `..`, `.`
  or empty component. `delete` moves the note to Obsidian's trash.
- **`vault-commit MESSAGE [PATH...]`.** Needs `--vault`, which the module
  gives. It runs on the server, not the laptop, in the vault configured
  when it runs (a commit queued before a change of the vault goes to the
  new one): `git --literal-pathspecs -C VAULT add -A -- PATH...` of the
  paths in the work tree, for the new files, and
  `git --literal-pathspecs -C VAULT commit -m MESSAGE -- PATH...` of all,
  which takes the removal of a path that is gone; or
  `git -C VAULT commit -m MESSAGE` of what is staged when it names no path.
  The paths are names, not patterns: `Scan [1].png` is that file alone. At
  most 256 paths, each relative to the vault's root. Git runs with
  `LC_ALL=C`, so its messages can be read. "Nothing to commit" counts as
  done. A commit that fails, a path git does not know yet included, runs
  again after 15 s, then twice as long each time up to an hour; 24 hours
  after its first attempt it fails for good, goes into the list that
  `status` shows and every command warns of, and the commits after it go
  ahead. The user's git configuration and the vault's hooks apply.
- **`flush`** delivers what waits and says how many still wait; a commit
  that waits for its next attempt runs now. **`deliver`** is the service: it
  delivers when the socket appears, when the queue changes, and on a retry
  after 1 s, then twice as long each time up to a minute. **`status`** lists
  what waits, oldest first, with what a commit waits for, and the commits
  that failed for good:

  ```
  3 requests wait for the laptop:
    2026-11-08T12:00:00Z  open https://example.org/
    2026-11-08T12:00:03Z  obsidian rename path=Notizen/Alt.md name=Neu
    2026-11-08T12:00:04Z  vault-commit "vault: Neu"
        attempt 2 failed, again at 2026-11-08T12:01:00Z: error: Couldn't get agent socket
  1 vault commit failed for good (ravnix-link dismiss clears this list):
    2026-11-07T09:00:00Z  vault-commit "vault: Plan": it failed for 24 hours, 30 times; the last time: ...
  ```

  **`dismiss`** empties that list.

## On the laptop

`ravnix-link daemon` listens on the socket, mode 600, in a directory that
is the user's alone. It refuses to start while another daemon holds its
state directory (`daemon.lock`) or answers on the socket; a socket that
nobody answers on is a dead daemon's and is replaced, and a file at the
socket's path that is not a socket is left alone. It serves one connection
at a time, a line at a time, and runs:

| Request | Runs | Done when |
| --- | --- | --- |
| open | `xdg-open TARGET` | it exits 0, or still runs after 5 s (it has handed the link to an application) |
| notify | `notify-send [-u U] [-a APP] -- SUMMARY [BODY]` | it exits 0 within 10 s |
| obsidian | `obsidian OP path=P [to=P\|name=N]`, stdin from `/dev/null` | it exits 0 within 60 s and prints no line that starts with `Error:` (Obsidian's CLI exits 0 on its own errors) |
| vault-commit | nothing | refused: the commit is the server's |

With `--systemd-run`, which the module gives, each program starts in a
transient scope of its own (`systemd-run --user --scope --collect`), so a
restart of the daemon's unit does not end the browser or the Obsidian it
started. The output of xdg-open and notify-send goes to the daemon's
standard error, the journal (`journalctl --user -u ravnix-link-daemon`),
and a failure says so. obsidian's goes to a pipe that the daemon reads
while the CLI runs and closes when it ends, so an Obsidian that the CLI
started does not write into the daemon for its whole life.

A program that is not installed (the scope's `systemd-run` included)
answers `retry`, and the request stays in the queue; 6 hours after it was
made it fails. A program that hangs is killed at its limit, with what it
started (its process group), and the request failed. Everything it runs
gets `RAVNIX_LINK_DAEMON=1` in its environment,
and `ravnix-link` refuses every command but `daemon` and `status` under it:
a laptop whose `xdg-open` were the link's would otherwise send its requests
around in a circle.

## The protocol

One JSON object per line, UTF-8, over the socket. A request:

```json
{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","kind":"open","args":{"target":"https://example.org/"},"created":"2026-11-08T12:00:00Z"}
```

`kind` is `open`, `notify`, `obsidian` or `vault-commit`, and `args` holds
the fields of the kind. The daemon answers every line, by the request's ID:

```json
{"id":"0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d","status":"done","error":""}
```

`status` is `done`, `failed` (with the reason in `error`) or `retry`. A line
that is no request is answered `failed`, with its ID when it has a valid
one and `""` otherwise, and the connection goes on.

Limits, the same on both ends:

- A line is at most 64 KiB, its newline included. A longer request is
  refused before it is queued (a 10 MB body is refused, not cut), and a
  longer line on the socket is answered `failed` and the connection closed.
- Every string is valid UTF-8 without a NUL. The summary, the application's
  name, a URL and a path hold no control character either; a body and a
  commit message may hold newlines and tabs. On the wire every control
  character is escaped, and so are U+2028 and U+2029, so a line stays one
  line. An escaped lone surrogate, an unknown key, a key twice, nesting
  deeper than 4 and anything after the object are refused.
- A path is at most 4096 bytes, and the queue at most 16 MiB: a queue that
  full takes no more requests, as the laptop has been away for very long or
  something sends without end.

## Once, and in order

The server keeps its state in `$XDG_STATE_HOME/ravnix-link/`, mode 700, its
files 600:

| File | Holds |
| --- | --- |
| `queue` | the requests, one line each, appended under an exclusive lock as one write and synced to the disk before the command goes on |
| `acked` | an outcome per request: `started`, `retry`, `done`, `failed`, `expired` or `skipped`; a commit's `started` and `retry` hold the vault's HEAD before git ran, the attempts, the first attempt's time and the next one's |
| `expect` | what each Obsidian operation the laptop did leaves in the vault (a path there, one gone), until the server's copy shows it |
| `failed` | the commits that failed for good, until `dismiss` |
| `deliver.lock` | the lock that lets one delivery run at a time |

The laptop keeps `seen` (the IDs it has started and their outcomes) and
`daemon.lock` in its own `$XDG_STATE_HOME/ravnix-link/`.

1. **Order.** The requests go in the order of the queue, in two streams.
   The vault's, the Obsidian operations and the commits, waits behind the
   first of them that is not resolved. The laptop's, every request for the
   laptop, waits behind the first that cannot be delivered, and behind one
   the laptop answers `retry` for a missing xdg-open or notify-send. A
   missing `obsidian` holds only the vault's stream, so opens and
   notifications pass it. One the laptop answered `failed` holds nothing.
2. **The commit after the notes.** A `vault-commit` waits for every Obsidian
   operation and commit queued before it, and for nothing else: an open or
   a notification before it does not hold it up. The daemon answers once
   Obsidian on the laptop has done the operation; the sync brings it to the
   server's copy later. So the commit waits, with the request still in the
   queue, until that copy shows the result of each operation before it: a
   renamed or moved note at its new path and not at the old one, a deleted
   note gone. After 15 minutes without it, the commit goes ahead and says
   so, and a path git does not know yet makes it run again later.
3. **Once.** The daemon writes a request's ID to `seen` before it runs it,
   and its outcome after. A request delivered again (the server crashed
   between the reply and writing it down, or the connection broke) gets the
   outcome it had and runs nothing, even after a restart of the daemon. One
   that was running when the daemon stopped is answered `failed`, not run
   again, since it may have happened. A commit is written down as `started`,
   with the vault's HEAD, before git runs. One found `started` runs again
   unless HEAD has moved to a commit with its message since, which shows it
   ran; a second run of one that did commit finds nothing to commit, which
   is done.
4. **Torn lines.** A queue whose last line a crash cut short gets a newline
   before the next request, so that request is a line of its own. A line
   that is no request is reported once, by its line number, written down as
   `skipped` under a hash of its bytes, and passed over.
5. **Compaction.** When nothing waits, the queue is emptied and `acked` keeps
   the last 64 outcomes, for a command whose request another run delivered.
   A request that came in meanwhile keeps the queue as it is.

Concurrent commands append whole lines and never tear each other's; one
delivery runs at a time. A command waits up to 5 s for another's lock,
then leaves its request queued and says that another run delivers it. One
whose outcome was compacted away by the time it looks says that another run
resolved it.

## The module

`modules/glue/link.nix` installs both ends, by the host's shape
(`ravnix.shape`), and nothing on a host without one. On the server, the
system's and the user's profile get `ravnix-link` with the vault and the
store's git, an `xdg-open` that is `ravnix-link open`, and a `notify-send`
that is `ravnix-link notify-send` with libnotify's as the real one, all
three ahead of xdg-utils and libnotify; the user unit `ravnix-link-deliver`
runs `deliver` from boot. The server's sshd gets `StreamLocalBindUnlink`,
so a connection can forward the socket again after one that dropped left it
behind. On the laptop, the user unit `ravnix-link-daemon` runs `daemon` in
the graphical session, with xdg-utils' `xdg-open`, libnotify's
`notify-send`, the `obsidian` on the user's PATH and systemd's
`systemd-run`. `ravnix.link.socket` is the socket's name in
`$XDG_RUNTIME_DIR` on both hosts, and the main connection forwards it with

```
RemoteForward /run/user/<uid on muninn>/ravnix-link.sock /run/user/<uid on huginn>/ravnix-link.sock
```

### The agent for signed commits

`ravnix-link-deliver` runs the queued commits. Its unit sets PATH and
nothing else, so it has the rest of the user manager's environment. A
vault that signs its commits (`commit.gpgsign` with an ssh key) needs the
agent there:

- **The interface:** the module that runs the agent on the server (Task
  4.3) puts `SSH_AUTH_SOCK` into the user manager's environment, by
  `systemd.user.sessionVariables` of home-manager (`environment.d`) or
  `systemctl --user set-environment`, before the commits run.
  `systemctl --user show-environment` shows it.
- **Without it,** or with the agent locked, the commit fails, is not made
  unsigned, and runs again with the backoff above; `status` shows the
  attempt and git's error.

## Tests and bench

`ravnix-link-tests` runs 75 tests. The protocol: every kind round-trips with
spaces, umlauts and an en dash in its paths; a 10 MB body, a line of 64 KiB
and one byte, NUL, control characters, invalid UTF-8, lone surrogates,
unknown keys and kinds, a key twice, deep nesting, trailing bytes, bad IDs
and timestamps, paths that leave the vault, and the schemes `open` refuses
(`obsidian://new?...&overwrite`, `file:///`, `javascript:`, a scheme in
mixed case). The queue: requests queue while the laptop is away and are
delivered once and in order when it is back; eight writers at once tear no
line; the service and four clients delivering at once run each request,
commits included, once and in order; a torn last line, a corrupt line, a
full queue, a crash between delivery and ack with and without a daemon
restart, the same line twice, a rename then an edit then a commit, a commit
behind a failed or a waiting Obsidian request, a commit that waits for the
sync and one that gives up waiting, a path git does not know yet, a commit
cut off before and after git ran, nothing to commit, a commit that fails
and is given up after a day, one that failed after git add had staged a
removal, the configured vault, a long commit between
two opens, a laptop that cannot run a request yet and one that cannot for
six hours, a busy lock, an outcome compacted away, a record that cannot be
written, a notification too old, compaction, a missing or unwritable state
directory, and the files' modes. The daemon: its socket's mode, a second
daemon, a live one with another state directory, a stale socket, one a
forked child still holds for a moment, a file in its place, a socket path
too long, a program that is missing, fails, hangs, prints `Error:`, or
still runs (xdg-open), an xdg-open that ends later and is collected, the
scopes, an obsidian that leaves a process on its output, a timeout that
stops what the program started, notify-send's arguments, nonsense on the
socket, a line too long, a request of the server's. The command line: every
command and its usage errors, notify-send's options as GOption reads them,
`--topic` with a room that fails, the environment's defaults, the loop
guard, the exit codes. And the delivery service delivers when the socket
appears and sleeps while the laptop is away.

`tests/glue/link-shapes.nix` (`glue-link-shapes`) evaluates both shapes:
on the server shape `xdg-open` and `notify-send` are the link's and come
first, the delivery unit starts at boot with the user manager's environment
and sshd unlinks a stale socket; on the laptop shape `xdg-open` is
xdg-utils' and the daemon is part of the graphical session and starts its
programs in scopes; and the module's socket name is the tool's.

`tests/glue/link.nix` (`glue-link`) runs both ends in two VMs, with the
forward made by `ssh -R` and stand-ins for xdg-open, notify-send and
obsidian: four requests queue while the forward is down and survive a
reboot of the server, the delivery service sleeps meanwhile, the daemon's
socket is mode 600 on both hosts, and when the forward comes up the
requests are delivered once and in order; the vault signs its commits with
an ssh key, and while the agent is away the commit fails and is not made;
the service has `SSH_AUTH_SOCK` from the user manager's environment, and
once the agent is there it makes the commit, signed, with the renamed note
and the edit made after the rename was queued; nothing runs twice after the
service and the daemon restart; a request with the laptop there runs at
once; a program the daemon started outlives a restart of the daemon; and a
stale socket from a dropped connection does not block the next forward.

`ravnix-link-bench` runs `status` on `bench/queue`, 400 requests of every
kind with umlauts and escapes and two lines that are not requests, with an
outcome in `bench/acked` for every third: the reading, the parsing and the
checks of a queue, without a socket or a program to run.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- The wait for the sync sees paths, not contents. A note that is at its
  new path and gone from the old one counts as synced, even when an edit
  made on the laptop after the operation has not come yet; and when the
  sync takes longer than 15 minutes, the commit runs on what is there.
  The VM test's stand-in renames on the server directly.
- What an operation leaves in the vault is written to `expect` after its
  `done` record. A run cut off between the two leaves a commit after it
  that does not wait for the sync, as before this wait existed.
- A commit found `started` counts as done when a commit with its message
  has come since its HEAD, among the newest thousand. Another commit with
  the same message in that span would count, too.
- A request that the laptop answers `retry` fails 6 hours after it was
  made, not after the first `retry`: one that waited longer than that for
  the laptop fails at once.
- The concurrency tests run threads, each with its own descriptors on the
  lock and the files, as processes have them; they do not fork.
- Only the server takes a `vault-commit`. The daemon refuses one, so a
  commit asked for on the laptop has no way to the server yet.
- Of notify-send's options only the urgency and the application's name
  reach the laptop. `--print-id`, `--wait`, actions, a replaced ID, hints,
  an icon, an expiry and a category are read and dropped.
- `to=` takes no empty path, so `obsidian move` cannot move a note to the
  vault's root, and `vault=` is refused: the daemon's Obsidian works in the
  vault it has open.
- The laptop's `seen` keeps the newest 10,000 IDs, rewritten at start when
  it holds more than twice as many. A request delivered again after 10,000
  newer ones would run again.
- Without `--systemd-run`, a program the daemon started ends with a
  restart of the daemon's unit.
- A path given to `open` is not checked on the server. One that is not at
  the same path on the laptop fails there, with xdg-open's message.
