# ravnix-notify

Posts a message to the Matrix room of a topic, as the bot of that topic. A
unit, a timer or a hook that wants to be heard with the lid closed calls it;
the message arrives on the phone.

```sh
ravnix-notify --topic TOPIC [--config FILE] [--dry-run] MESSAGE...
ravnix-notify --topic TOPIC [--config FILE] [--dry-run] -
```

The topics are `sessions`, `updates`, `backups`, `builds` and `services`.
They come from the config, which `modules/glue/notify.nix` writes from
`ravnix.matrix.rooms`; the option has exactly these five names, so a sixth
is an error when the host is built, and the tool says "unknown topic" for any
other (exit 64). A host that sets no room has all five without one: the tool
is installed on every host, and each topic exits 78 until it has a room. The words of `MESSAGE` are joined with blanks, a lone `-`
reads the message from standard input, and `--` ends the options.

`--dry-run` prints the request it would send (the line `PUT URL`, then the
event as JSON) and does nothing else: it asks rbw for nothing and contacts no
homeserver. It still refuses what a real run refuses before it asks anyone
(the topic, the room, the size). The bench uses it.

## The message

The message is Markdown, and goes out as an `m.text` event with the text
itself as `body` and the rendered HTML as `formatted_body` (format
`org.matrix.custom.html`). It is `m.text` and not `m.notice` on purpose:
Matrix's default push rules keep `m.notice` from notifying a phone.

The renderer (`markdown.odin`) knows this subset of CommonMark:

- paragraphs; a line break in a paragraph is a line break (`<br>`), as in a
  notification typed by hand;
- `**bold**`, `__bold__`, `*italic*`, `_italic_`, `***both***`, `~~strike~~`
  and `` `code` ``, with backslash escapes;
- links `[text](address)`, for `http`, `https` and `mailto` addresses only;
- ATX headings (`# ` to `###### `), `---` rules, `> ` quotes;
- bullet lists (`- `, `* `, `+ `) and numbered lists (`1. `, `2) `), flat;
- fenced code blocks, with a language name when it is a plain word.

Whatever else the text says is text. No HTML of the sender's own comes out:
`<`, `>`, `&` and `"` are escaped everywhere, a link address lands in an
attribute only after the same escaping, and a link of any other scheme
(`javascript:`, `data:`, `file:`, a relative one) is shown as the text it is.
Bytes that are not UTF-8 become U+FFFD, since JSON has no such bytes and a log
excerpt can end in the middle of a character.

Nothing the renderer does may take long. A scan for a closing delimiter
remembers where it found none, a link is looked for within 2000 bytes, and
quotes and emphasis nest sixteen deep, beyond which the rest is text. A link
is looked for by scanning from its `[`; once the scans of a text have looked
at more than four times its size, one pass finds where every bracket and
parenthesis closes and answers the rest at once, so sixty thousand `[` are
not sixty thousand scans. The tests feed it 60 000 bytes of each pattern that
would otherwise be quadratic, and give each a budget of 100 ms.

A message whose event is over 60 000 bytes is refused (exit 65), not cut: a
notification that loses its end says something else than its sender wrote.
Matrix allows 65 536 bytes for an event with what the homeserver adds. The
HTML can be several times the text (`<` becomes `&lt;`), so the limit is on
the encoded event, which is the thing the homeserver counts.

## The config

`/etc/ravnix/notify.json`, written by `modules/glue/notify.nix` and the same on
both hosts. `--config` names another.

```json
{
  "homeserver": "https://matrix.example.org",
  "rbw": "/nix/store/...-rbw/bin/rbw",
  "rooms": {
    "builds": { "roomId": "!AbCdEf:example.org", "tokenItem": "Matrix - access token (ravnix-builds)" },
    "sessions": { "roomId": null, "tokenItem": "Matrix - access token (ravnix-sessions)" }
  }
}
```

`roomId` is null while a room does not exist yet (and it is, for every topic,
on a host that sets nothing). A run for such a topic exits 78 and says so
before it asks rbw for anything or starts curl, and the build warns once for
each such topic (`modules/glue/notify.nix`), so the gap shows when the host is
built and not when a message is needed. `tokenItem` defaults to `Matrix -
access token (ravnix-TOPIC)`. Optional keys: `curl` (the program; the
build's store path by default), `retryBaseMs` (1000), `timeoutSecs` (20,
curl's limit for one request) and `rbwTimeoutMs` (30000). The tests lower
the last three so that a hang takes a moment. A key that is wrong stops the
run, and the message names the key.

## The token

The bot's access token is in Bitwarden, in the item `tokenItem` names. The
tool asks rbw for it each time:

1. `rbw unlocked`. A locked vault would make rbw ask for the master password
   with a pinentry, on a terminal that a timer or a hook does not have, so a
   locked vault stops the run at once (exit 75, "unlock it (ai-unlock)"), the
   way `modules/workbench/unlocked.nix` does.
2. `rbw get -- ITEM`. Its standard output is the token. It must be printable
   ASCII without a blank, or the run stops (exit 69) without saying what rbw
   printed.

Both calls are cut off after `rbwTimeoutMs`. The tool waits for rbw to exit,
not for its pipes to close, because rbw starts its agent on the first call and
the agent may keep the pipes it inherited.

The token is on no command line, in no environment variable and in no file.
It goes to curl on standard input, as part of curl's config file (`curl -q -K
-`), together with the URL and the body. The tests run a curl that records its
arguments and check that the token is not among them, nor in anything the tool
said, nor in a file of the run's scratch directory. The tool opens no file for
writing at all, which `tests/source_test.odin` checks by reading the sources
for the calls that would; no listing of `$TMPDIR` is compared, because tests
that run side by side share it. If the homeserver quotes the token back in an
error, the log line has `[token]` in its place.

## Retries

A try fails in a way worth another try when curl cannot reach the homeserver
(it is down, the name does not resolve, the connection drops or times out)
and when the homeserver answers 408, 429 or 5xx. There are three retries, so
four tries, with the wait doubling from `retryBaseMs`: 1, 2 and 4 seconds by
default. A 429 with `retry_after_ms` waits that long instead. An answer that
asks for more than 30 seconds is not waited for; the run ends at once with
exit 75, since a timer is a better place to try again from.

All tries of one run send the same transaction id (`PUT .../send/m.room.message/TXN`),
so a try after an answer that was lost does not post the message again: the
homeserver answers it from the first. A new run is a new message.

Each retry and the end are lines on standard error and in the journal.

### How long a run can take

A run is bounded, and the bound is long enough to matter to a caller with a
timeout of its own. Both rbw calls (`unlocked`, then `get`) are cut off after
`rbwTimeoutMs`, and each of the four tries after `timeoutSecs` (curl's own
limit; the tool kills a curl that outlives it by five seconds). With the
defaults:

- a homeserver that answers at once, down or up: a few seconds, with 7
  seconds of backoff when it is down;
- a homeserver that accepts the connection and never answers: 4 x 20 s of
  tries and 7 s of backoff, about 87 s, and with a hanging rbw as well up to
  60 s more;
- the worst case, a homeserver that answers 429 with a wait of 30 s three
  times, after a hanging rbw: 2 x 30 s + 4 x 20 s + 3 x 30 s = 230 s, and
  250 s if every curl has to be killed five seconds after its limit. 250 s is
  the bound with the defaults.

A larger `retryBaseMs` raises the backoff (it is 7 times that); the config
accepts up to 60 s. A hook or a unit with a shorter timeout is killed in the
middle of a retry, and writes no journal line. So a caller that cannot wait
runs the tool in the background (`ravnix-notify ... &`, or a transient unit)
or lowers `timeoutSecs` and `rbwTimeoutMs` in its config.

## The journal

"Exit 75 and a line in the journal" is done by one of two ways, whichever is
true of the run, so the line is in the journal exactly once:

- **Run by a unit**, standard error is the journal's stream. A line starts
  with `<4>` (a retry) or `<3>` (a failure), the syslog priority that journald
  reads off a stream.
- **Run by hand, by a hook, by cron, or by a child of a unit**, standard
  error is not the journal.
  The line goes to standard error in plain words and, as an entry of its own
  (`MESSAGE=`, `PRIORITY=`, `SYSLOG_IDENTIFIER=ravnix-notify`), to the
  journal's socket `/run/systemd/journal/socket`, which is what
  `systemd-cat` does without a program to start. A journal that is not there
  loses the entry and nothing else.

Which of the two is decided as systemd.exec(5) says: `JOURNAL_STREAM` holds
the device and inode of the stream (`DEV:INO`, in decimal), and standard
error is that stream when `fstat(2)` of descriptor 2 gives the same two
numbers. That the variable is set proves nothing. A unit passes it on to every
child, and the sessions of herdr and Claude Code, which run under units, start
programs whose standard error is a terminal or a pipe of their own; for those
a `<3>` in front of the line would reach no journal, and the line would be
lost. A value that is not `DEV:INO` in plain decimal digits, an unset
variable and a descriptor that is not open all mean "not the journal".

Text from outside (what the homeserver or a program said) is cut to 400 bytes
and its control characters become blanks, so a hostile answer cannot paint the
terminal or fill the journal.

## Exit status

| Exit | Means |
| --- | --- |
| 0 | the homeserver took the message (a 2xx answer with an `event_id`) |
| 64 | bad usage, or a topic the config does not have |
| 65 | the message is too large for an event |
| 69 | no usable token (rbw cannot run, does not answer, has no such item, or the item holds no token), or curl cannot run |
| 74 | the message on standard input could not be read to its end (a read error before the end of the input); nothing is sent |
| 75 | the vault is locked, or the homeserver stayed out of reach after the retries, or asks for a longer wait than the tool gives |
| 76 | the homeserver's answer is no success and no retry changes it: a 4xx other than 401, 403, 408 and 429, a redirect (curl does not follow one, so the token cannot leave for another host), a 2xx without an `event_id` (a captive portal answers 200 to anything), an answer over 1 MiB |
| 77 | the homeserver refused the token or the bot's place in the room (401, 403) |
| 78 | the config is missing or wrong, the topic has no room yet, or curl refuses the homeserver's address |

## Why curl

Odin's core library has no TLS, and the homeserver is reached over https. The
tool therefore runs curl, whose store path the build puts into the binary
(`-define:CURL=...` in `default.nix`), so it needs nothing on `PATH`, as
`ravnix-disk-guard` does with lsblk. The request is made by curl's config
file on standard input, in which a value that would end its line (a line
break in a token, say) is refused, and a backslash and a quote are escaped.
curl does not follow redirects, reads no `.curlrc` (`-q`) and speaks only
http and https.

## Tests

`ravnix-notify-tests` runs the whole command in the test process against a
homeserver that is a thread on a loopback port, which records each request
(method, path, headers, body, the moment) and answers from a script. The vault
client and curl are scripts in a scratch directory (`tests/testdata`), and curl
is the real one, so the request that arrives is the request that would. What
is checked, besides the happy path for each topic:

- the room, token, headers and JSON of the request; Markdown as `formatted_body`;
- an unknown topic, a bad command line, a topic without a room, a missing or
  broken config, a message too large (from arguments and from standard input);
- every way the token can be wrong or absent, and that none shows up on
  curl's command line, in the log, in the journal or in a file;
- a locked vault, a missing, hanging or endless rbw, an rbw that leaves a
  daemon holding its pipe;
- a homeserver that is down, hangs, closes the connection, answers 5xx, 408,
  429 with and without a usable `retry_after_ms` (the wait is measured), one
  that asks for an hour, 401, 403, other 4xx, redirects, a 200 without an
  `event_id`, and an answer of 6 MiB;
- a message that cannot be read from standard input to its end is not sent
  cut (74);
- the same transaction id on every try, and a new one for a new run;
- that a `.curlrc` in curl's home is not read (with a control that the same
  file is read by a curl without `-q`);
- where standard error is the journal: `DEV:INO` against `fstat(2)` of a real
  descriptor, for a match, another inode, another device, malformed values,
  numbers that wrap around and a closed descriptor;
- that `SIGPIPE` is ignored after a run (`sigaction`, with a no-op handler
  standing in meanwhile, so a parallel test that writes to a closed pipe
  cannot kill the binary);
- that the link index gives the answers of the scan it takes over from, on
  60 000 random texts, at the length limit, and on hostile patterns;
- that the sources call nothing that creates or writes a file;
- a request over the 64 KiB a pipe holds, and a curl that exits without
  reading it;
- eight runs at the same time;
- the renderer on every construct, on text that is not Markdown, on HTML in
  the message, and on 60 000 bytes (the most an event holds) of each pattern
  that could make it slow, each with a time budget of its own.

`tests/glue/notify.nix` checks the other side: the Nix that writes the config
and the built tool that reads it, with `--dry-run`, on the server and the
laptop shape and on a host that sets no room; the warning for each topic
without a room (and none for a topic with one); and, with the built binary,
that `JOURNAL_STREAM` puts a priority in front of a line only when it names
the very file standard error is.

`ravnix-notify-bench` renders `bench/message.md` (every construct, 7 KB) with
`--dry-run`. The bench starts the program with no `PATH`, so a run that
starts rbw and curl cannot be benched (`tools/README.md`, "Known gaps"), and
the network path is not measured.

## Known gaps

Findings that are not fixed.

- **At most once per run, at least once per message.** The transaction id
  keeps a retry inside a run from posting twice. A caller that runs the tool
  again after exit 75 (a timer, a hook) sends a new message, and if the first
  try had in fact arrived (the reply to the last try was lost), the room has
  it twice. A later version could take a stable key from the caller, such as
  `$INVOCATION_ID` with the topic, and derive the transaction id from it;
  Synapse deduplicates per access token.
- **A `Retry-After` header is ignored.** Only `retry_after_ms` in a Matrix
  error body is read. A proxy that rate-limits with the header gets the
  doubling backoff instead.
- **A TLS failure is retried like an outage.** A certificate that curl
  rejects (exit 60) is tried four times and then ends in exit 75, after about
  seven seconds, not in a status of its own.
- **Emphasis pairs by equal length.** `**bold *italic***` ends in `***`, which
  is not the `**` it opened with, so the stars show. CommonMark would nest
  them. A link title is accepted and dropped. There are no nested lists, tables,
  images or raw HTML; a nested list item reads as a line of its parent's.
- **curl, rbw and rbw's agent inherit `SIGPIPE` ignored.** Odin's
  `process_start` does not reset signal dispositions, and `run_child` ignores
  the signal in this process. curl and rbw ignore it themselves, so it is
  harmless here; a program started this way that relied on the default would
  not get it.
- **The token stays in memory until the process ends.** It is not wiped, and
  curl holds it while it runs. A process of the same user can read both.
- **rbw is the user's.** The tool asks the rbw of whoever runs it. A unit that
  runs as another user (root, say) needs that user's vault unlocked, or it
  exits 75.
