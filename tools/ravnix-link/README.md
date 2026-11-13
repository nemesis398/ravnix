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
it, once that copy shows what they did. On the laptop, whose copy of the
vault has no `.git`, `vault-commit` sends the commit to the server instead
(`receive`), with the SHA-256 of each file, and the server commits once the
file sync has brought its copy those bytes.

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
  drop ID                             let go of a request that waits
  receive                             queue the commit on standard input, one
                                      line, which the laptop's vault-commit
                                      sends; answer with how it came out

On the laptop:
  daemon                              carry out what the server sends
  vault-commit MESSAGE PATH...        with --forward: ask the server to commit
                                      PATHs, once its copy of the vault has
                                      them as they are here

Options:
  --socket PATH   --state DIR   --vault DIR   --git PATH   --ravnix-notify PATH
  --xdg-open PATH   --notify-send PATH   --obsidian PATH   --systemd-run PATH
  --forward PATH
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
  default application for its type (xdg-open's MIME default), which may be
  Obsidian: a note the server wrote opens there without a click, as it
  would when the user opened it. The file must be at the same path on the
  laptop, as the synced folders are; the server does not check.
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
  done. The commit takes its paths as the work tree has them when it runs,
  which may be hours after it was asked for: edits made to them since, by
  anyone, go in under its message.

  A commit that fails for what another attempt may not have runs again
  after 15 s, then twice as long each time up to an hour, and 24 hours
  after its first attempt it fails for good. These are read from git's own
  words: a lock another git holds (`….lock': File exists`, `cannot lock
  ref`), a signature that failed (git ends every one, whatever the agent
  said, with `failed to write commit object`), an index or object it could
  not write, a full or read-only disk, a rebase or merge under way (`cannot
  do a partial commit during a`), a file the sync replaced while git read
  it (`unable to index file` with `No such file or directory`), and a time
  limit. A file git may not read, or a folder with a repository of its
  own, fails at once. So is a path git does not know that an Obsidian operation before
  the commit leaves, since a late sync may still bring it (a laptop that
  suspended before it uploaded the rename). One that git refuses for what
  every attempt would have (any other path git does not know, an ignored
  path, a hook that rejects it, whatever words the hook uses), with HEAD
  where it was, fails for good at once. Either way it goes into the list
  that `status` shows and every command warns of, and what waits behind it
  goes ahead. The user's git configuration and the vault's hooks apply.
  git itself gets SIGTERM when the `ravnix-link` run that started it ends
  (Ctrl-C, a caller's time limit), and removes its locks; the hooks and the
  ssh-keygen it started do not get it.
- **`flush`** delivers what waits and says how many still wait; a commit
  that waits for its next attempt runs now. **`deliver`** is the service: it
  delivers when the socket appears, when the queue changes, and on a retry
  after 1 s, then twice as long each time up to a minute. **`status`** lists
  what waits, oldest first, with what a commit waits for, and the commits
  that failed for good, each request by its ID:

  ```
  3 requests wait for the laptop:
    2026-11-08T12:00:00Z  0b9a1c2e-4f5d-4a6b-8c7d-9e0f1a2b3c4d  open https://example.org/
    2026-11-08T12:00:03Z  5d1c7a3e-2b4f-4c6d-8e9f-0a1b2c3d4e5f  obsidian rename path=Notizen/Alt.md name=Neu
    2026-11-08T12:00:04Z  9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a  vault-commit "vault: Neu"
        attempt 2 failed, again at 2026-11-08T12:01:00Z: error: Couldn't get agent socket
  1 vault commit failed for good (ravnix-link dismiss clears this list):
    2026-11-07T09:00:00Z  vault-commit "vault: Plan": it failed for 24 hours, 30 times; the last time: ...
  ```

  A commit from the laptop (below) that waits for the sync says so:

  ```
      waits until the vault here has 2 files as the laptop wrote them (the sync brings them), at most until 2026-11-08T12:15:04Z
  ```

  **`dismiss`** empties that list. **`drop ID`** lets go of a request that
  waits, by its ID: it is recorded failed, by hand, and what waits behind
  it goes ahead. A dropped commit also retires the Obsidian operations it
  was retried for, so the next commit of those paths fails at once when
  git does not know them. An ID that waits for nothing is refused.
- **`receive`.** The server's end of a commit asked for on the laptop: it
  reads one request line on standard input, a `vault-commit` that names
  its files and carries a sum for each, and writes one reply line on
  standard output. Anything else (another kind, no paths, no sums, a line
  that is no request or longer than 64 KiB, a server without `--vault`) is
  answered `failed` and exits 64, with nothing queued. The commit is queued
  as the server's own, in the vault configured here (the laptop's path for
  it is ignored), with the time the server got it, by the server's clock
  (the laptop's is ignored too: the waits and the order after the Obsidian
  operations are the server's), and `receive` runs no git: the delivery service commits
  it, in the user manager's environment, which has the agent a signed
  commit needs and an ssh session may not. The queue's change wakes the
  service. `receive` answers `done` or `failed` (exit 1) when the service
  has resolved the commit within 10 s, and `retry`, which the laptop reads
  as queued, when it has not, or at once when the server's copy does not
  have the files yet. Until the copy has each file with the laptop's
  bytes, and each path the laptop does not have is gone here, the commit
  waits, and what is queued in the vault after it waits too; 15 minutes
  after the server got it, it goes ahead with what is there, and says so.
  A file the laptop had that git then does not know is tried again, as a
  late sync may still bring it, until an hour after the server got the
  request; then the file is not coming under that name (renamed or deleted
  on the laptop before the upload, a name the sync does not carry, a
  conflict copy), and the commit fails for good, naming the file, and what
  waits behind it goes ahead. When git finds nothing to commit because the
  laptop's version never came, the commit fails for good too, rather than
  counting as done. Either way the failure is in the list `status` shows,
  and a notification for the laptop is queued. The same request sent
  again, as a laptop that did not get the answer sends it, gets the
  outcome it had and runs nothing twice.

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

`ravnix-link vault-commit MESSAGE PATH...` with `--forward`, as the
module gives it, does not queue on the laptop. It needs `--vault`, the
laptop's copy of the vault, and at least one path: what is staged is the
server's. It checks the paths as the server does, reads each in the
laptop's copy, takes the SHA-256 of a file, or `-` for a path that is not
there (the commit takes its removal), and refuses a folder or a symlink
(exit 64): the server waits for each file the sync brings, so the files
are named. It runs the program of `--forward` with the request on its
standard input (the module's is `ssh -T -o BatchMode=yes -- ravnix-server
/run/current-system/sw/bin/ravnix-link receive`, a fixed command, so no
value passes through a shell), and reads the server's reply among what
the program prints. `done` exits 0; `retry` says that the server queued
the commit, and why, and exits 0; `failed` says the server's reason and
exits 1. No reply for the request (ssh could not connect, the program is
missing or timed out after the server's commit time and a minute) exits
1 and says so: the server may or may not have queued it, and asking again
is safe, as a second commit of the same files commits nothing.

With `--systemd-run`, which the module gives, each program starts in a
transient scope of its own (`systemd-run --user --scope --collect`), so a
restart of the daemon's unit does not end the browser or the Obsidian it
started. The output of xdg-open and notify-send goes to the daemon's
standard error, the journal (`journalctl --user -u ravnix-link-daemon`),
and a failure says so. obsidian's goes to a pipe that the daemon reads
while the CLI runs; the daemon answers when the CLI has ended, and copies
what an Obsidian the CLI started writes later on to the journal, until it
closes the pipe. Only the daemon's end of the pipe is non-blocking.
systemd-run --user connects to the user manager's own socket,
`$XDG_RUNTIME_DIR/systemd/private`; while that is not there, a request
answers `retry`.

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
the fields of the kind. A `vault-commit` from the laptop has `sums`, one
per path in `paths`, each 64 lowercase hex digits or `-`; one without it
is as it was. The daemon answers every line, by the request's ID:

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
| `expect` | what each Obsidian operation the laptop did leaves in the vault (a path there, one gone), until the server's copy shows it; one it does not show within 15 minutes is kept for a day, flagged dropped, so a commit that misses its path is tried again |
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
   so. A path git then does not know, which one of those operations
   leaves, makes it run again, for a day; another fails it for good.
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
`$XDG_RUNTIME_DIR` on both hosts. The laptop's `ravnix-link` has its copy
of the vault (`ravnix.link.vault`) and the forward over ssh to
`ravnix-server`, the block of `modules/glue/terminal.nix`, whose key needs
no agent and no touch. `ravnix.link.command` is the host's `ravnix-link`,
which `vault-commit` of `modules/glue/vault.nix` runs. The main connection
forwards the socket with

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

`ravnix-link-tests` runs 104 tests. The protocol: every kind round-trips with
spaces, umlauts and an en dash in its paths; a 10 MB body, a line of 64 KiB
and one byte, NUL, control characters, invalid UTF-8, lone surrogates,
unknown keys and kinds, a key twice, deep nesting, trailing bytes, bad IDs
and timestamps, paths that leave the vault, and the schemes `open` refuses
(`obsidian://new?...&overwrite`, `file:///`, `javascript:`, a scheme in
mixed case, behind a space or with its colon percent-encoded). The queue: requests queue while the laptop is away and are
delivered once and in order when it is back; eight writers at once tear no
line; the service and four clients delivering at once run each request,
commits included, once and in order; a torn last line, a corrupt line, a
full queue, a crash between delivery and ack with and without a daemon
restart, the same line twice, a rename then an edit then a commit, a commit
behind a failed or a waiting Obsidian request, a commit that waits for the
sync and one that gives up waiting, a path git does not know and one that a
late sync brings, a hook (one naming an agent or a signature among them)
or an ignored path that refuses it at once, from git add or git commit, a
file git may not index (mode 000, a nested repository), a retry across a
flush before the late sync, a drop that retires the operation, a
refusal with HEAD moved, a lock, an agent, a signature, a full disk, a
rebase or a file the sync replaced that it is tried again for, one recorded retry that had landed, `drop`, a commit
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
scopes, a missing user manager, a kept output closed at its end, an obsidian that leaves a process writing on
its output, a timeout that stops what the program started, a program that
ends with the run that started it, notify-send's arguments, nonsense on the
socket, a line too long, a request of the server's. The command line: every
command and its usage errors, notify-send's options as GOption reads them,
`--topic` with a room that fails, the environment's defaults, the loop
guard, the exit codes. And the delivery service delivers when the socket
appears and sleeps while the laptop is away. The commits from the laptop:
the sums round-trip and a wrong count, case, length or type is refused;
a commit waits until the vault here has each file as the laptop wrote it
and each removed path gone, says so in `status`, goes ahead after the
wait, is tried again for a file git does not know yet and fails after an
hour, naming the file, telling the laptop and letting the stream go on,
fails rather than counting as done when the laptop's version never came,
counts its wait by the server's clock, and waits for an Obsidian
operation queued before it; an empty file has the sum of nothing; `receive`
queues it and runs no git, answers what the service did within its wait,
gets the outcome it had for the same request again, and refuses another
kind, no paths, no sums, nonsense, an empty or overlong line and a server
without a vault; the laptop's `vault-commit` sends the sums of its files
(`-` for one it does not have) with an odd message, tells `done`, `retry`
and `failed` apart, says when the server did not answer (ssh's words, an
answer for another request, no forward), and refuses no paths, a folder,
a path that leaves the vault or holds a newline, an empty message and a
missing `--vault`.

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
Then the vault on both hosts: the skill values say `ravnix-link` on both,
with the repository on the server; the commit queued behind the rename is
asked for with `vault-commit` on the server, so it waits for the rename; a
note written on the laptop, committed there with `vault-commit`, goes to
the server over ssh and waits there until the test copies it over, as the
sync would, and the service commits it, signed; a commit from the laptop
of a file the server has already is answered as made; `vault-commit` on
the server commits at once when nothing waits; and three commits asked
for on each host at once all land, none failing on git's `index.lock`.

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
  `done` record. When that line is lost (a run cut off between the two, a
  failed append, which is reported, or an `expect` that cannot be read),
  the commit after it does not wait for the sync, and a path of the
  operation's that git does not know yet fails it for good, at once.
- A commit found `started` or `retry` counts as done when a commit with
  its message has come since the HEAD it recorded, among the newest
  thousand. A `retry` record lives up to a day, so another commit with the
  same message in that span, made by hand or by another tool, would count,
  too.
- A commit retried for a path an Obsidian operation was to bring says
  only git's pathspec error in `status`, not which operation it waits
  for. When that operation will never show (the note was renamed again on
  the laptop before the sync), `drop` releases the commit and the
  operation.
- Whether git's refusal is for good is read from git's own words, listed
  above. A hook that prints one of those phrases is tried again, for a
  day; any other refusal with HEAD unchanged fails at once.
- git gets SIGTERM when its run ends; the hooks and the ssh-keygen it
  started do not, and one that ignores git's end can outlive it.
- A restart of the daemon closes the pipes it kept for obsidian's output.
  An Obsidian that an earlier CLI started, in its own scope, then gets
  EPIPE on its next write, which Electron may report as an uncaught error.
  While the daemon serves one long connection it does not drain the
  pipes, and an Obsidian that writes more than a pipe holds (64 KiB) in
  that time waits.
- An obsidian CLI that hangs is stopped with its process group, so an
  Obsidian it started in that group goes too.
- The check before a scope looks for the user manager's socket only: a
  manager that is there but does not answer fails the request, with
  systemd-run's message in the journal.
- A request that the laptop answers `retry` fails 6 hours after it was
  made, not after the first `retry`: one that waited longer than that for
  the laptop fails at once.
- The concurrency tests run threads, each with its own descriptors on the
  lock and the files, as processes have them; they do not fork.
- A commit asked for on the laptop is not queued there: a laptop that
  cannot reach the server says so and exits 1, and the caller asks again.
  A laptop that writes notes offline commits them once it is back.
- After the 15 minutes the sums decide nothing more but the failure when
  git finds nothing to commit: the commit takes what the server's copy
  has then, edits made since included, or for some of its files a version
  older than the laptop's when the sync is slower.
- While a commit from the laptop waits for the sync, the server's own
  commits and Obsidian operations queued after it wait too: 15 minutes,
  and up to an hour for a file of the laptop's that git does not know.
- A note the laptop changes again between two commits it asks for: the
  first waits for bytes the laptop no longer has, the full 15 minutes,
  then commits the newer version under its message, and the second finds
  nothing to commit, which fails as above.
- git runs in the configured vault with `-C`, so a repository around the
  vault (before the vault's own `.git` is there) takes its commits.
  `vault-commit`'s git route checks for that; ravnix-link does not.
- `receive` answers `retry` when the delivery service has not resolved
  the commit within 10 s (no service running, a commit before it that
  waits); the laptop then does not learn how it ended. `status` and the
  list of failed commits on the server show it.
- A path the laptop does not have, and that git never knew (a file made
  and deleted again on the laptop before the sync), fails the whole
  commit for good, at once, as git's pathspec error.
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
