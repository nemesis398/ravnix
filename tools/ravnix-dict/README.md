# ravnix-dict

One dictionary of custom words for every tool that keeps a word list:
names, tools, hostnames, German and English terms. The dictionary is a
plain text file in the user's private flake (`ravnix.dictionary.file`),
which the user edits by hand and git keeps the history of. `ravnix-dict`
adds to it, removes from it, and syncs it with the tools: a word added in
any tool comes into the dictionary and goes to every other tool, and a
word is removed only in the dictionary, so no tool that resets its list
can wipe it.

```
usage: ravnix-dict [--file PATH] [--state DIR] COMMAND [ARG...]

  add WORD [--lang de,en] [--heard "A;B"]
                       add a word, or the mishearings and languages it lacks
                       (a word without lang= is in every language already)
  remove WORD          remove a word, in any case, from the dictionary here,
                       and from every tool at the next sync
  sync [--adapter NAME] [--allow-empty]
                       take the tools' new words into the dictionary, and
                       give every tool (or NAME) the words it lacks
  list                 print the words, one per line
```

The dictionary is `--file`, or `$RAVNIX_DICT_FILE`; the module
(`modules/common/dictionary.nix`) puts a `ravnix-dict` on the PATH whose
default for it is `ravnix.dictionary.file`. The state is `--state`, or
`$XDG_STATE_HOME/ravnix-dict`, or `~/.local/state/ravnix-dict`. `list`
needs no state.

| Exit | Means |
| --- | --- |
| 0 | done, or nothing to do (`add` of a word that is there with all its fields); an unavailable adapter, skipped, is no failure |
| 1 | failed: the dictionary is missing, too big, not writable or not one (not UTF-8, a NUL, a git merge conflict); `remove` of a word that is not there; the lock was held for a minute; the state cannot be read or written; an adapter failed (the others are synced all the same); `RAVNIX_DICT_ADAPTERS` names an adapter that does not exist |
| 64 | bad usage: an unknown command or option, a missing or extra argument, a word or value the file cannot hold |

## The file

One entry per line, UTF-8:

```
# A comment: a line whose first character that is not a space is #.
Huginn | lang=de,en | heard=Hugin;who gin
Open WebUI
CLAUDE.md
```

The word comes first, then optional fields after ` | `: `lang=` the
two-letter languages it belongs to, separated by `,`, and `heard=` what
speech recognition wrote instead, separated by `;`. A word is one entry
whatever its case: `GitHub`, `github` and `GITHUB` are one word, spelled
as its first line spells it, with the languages and mishearings of all its
lines.

**Languages.** A word without `lang=` is in every language, as the
editor's LanguageTool code (`modules/common/nvim/lua/ravnix_languagetool.lua`)
reads the file; so is a word of which any one line has no `lang=`, or an
empty one. Only a word whose every line names languages is limited to
them, the union of those lines. `langs_of` returns `all` for the first
kind and the codes for the second. `add WORD --lang xx` adds `xx` to a
limited word, and never narrows a word that is in every language: it
leaves the word as it is and says so in its one line of output. To limit
such a word, edit its line in the file. `add` of a word that is there in
another spelling says how it is spelled; a new spelling is an edit of the
file too. The case is folded rune by rune to lower case, so `Ärger` and
`ärger` are one word, but `Straße` and `STRASSE` are two.

**Byte for byte.** Every line is kept as it was written, with its own line
break (`\n` or `\r\n`), a byte order mark at the start, a last line without
a line break, blank lines, comments, spacing around the bars, and fields
ravnix-dict does not know. `add` appends a line in the line break of the
file's first line (closing a last line that has none), or rewrites the one
line of a word that gains a language or a mishearing; `remove` drops the
lines of the word. No other byte changes.

**What it warns about, and keeps.** A line with no word before its first
bar (`|`, `| lang=de`), a word the file cannot hold, an empty field, a
field without `=`, a field it does not know, and `lang=` or `heard=` given
twice on one line (both count). Each is printed on standard error by
every command that reads the file, at most 20 and a count of the rest; the
line stays as it is, and is no entry when it has no word.

**What it refuses.** A file that is not UTF-8 (an editor saving an umlaut in
Latin-1), that holds a NUL, or that holds a git merge conflict marker, is
no list of words to trust: every command fails with the line, and nothing
is written. So does a file bigger than 16 MiB, a missing file (the path
comes from the configuration; a dictionary that is not where it should be
is not an empty one, and is never created), and a directory.

**Words it cannot hold.** A word cannot be empty, longer than 256 bytes,
start or end with white space, start with `#` (a comment), hold `|` (a
field), hold a line break, a tab or another control character, or look
like a merge conflict marker. There is no escape: no tool that keeps a word
list needs such a word, and an escape would make the file harder to read
and to edit by hand. `#` inside a word is fine (`C#`), and so are `=`,
dots, spaces and umlauts. `add` refuses such a word with exit 64; a tool's
such word stays in the tool, out of the dictionary, with a warning at each
sync.

**Writing.** The file is replaced, never written in place: a new file next
to it (`.NAME.ravnix-dict-new`), synced to the disk, then renamed over it,
so a reader sees the old file or the new one. A link is followed, so the
link stays a link; the file keeps its mode; a file the user made read-only
is not replaced, even where the directory would allow the rename. Before
the rename, the file is read again: when it no longer holds what the
command read (an editor saved it in the meantime), the command starts
again on the new file, up to five times.

## Sync

Two-way and add only. For the adapters given (every one, or `--adapter
NAME`):

1. Every adapter's list is read. Each word is trimmed; empty words and a
   second word of the same key are dropped.
2. A word in a tool that the dictionary lacks, and that is not a removed
   word, is appended to the dictionary, in the order of the adapters, with
   the tool's spelling.
3. Every tool gets its own words, less the removed ones and in the
   dictionary's spelling, followed by the dictionary's words it lacks, in
   the dictionary's order. A tool whose list is already that is not
   written, so a tool that must be stopped to be written is not stopped
   for nothing. The adapters that must stop are written after all the
   others.
4. A word is never taken out of the dictionary because a tool lacks it. A
   tool that resets its list to nothing gets every word back.

An adapter that fails to read or to write is named on standard error with
its reason; the others are synced, and sync exits 1.

One run at a time: `add`, `remove` and `sync` hold `STATE/lock` (flock),
and wait up to a minute for another run to let go.

## Removal

Sync is add only, yet `remove` must take a word from every tool. Without a
record of the removal, the next sync would find the word in a tool, find it
missing in the dictionary, and add it back. The record is in the state
directory, on the host:

- `STATE/known` is the words of the dictionary at the end of the last
  sync, in lower case.
- `STATE/removed` is the words removed from the dictionary, in lower case,
  each until it is in the dictionary again.

Both are plain text, sorted, one word per line under a comment. The
dictionary itself carries no tombstones: it stays the list of words, and
a removed word leaves no trace in it.

At the start of each sync, before any tool is read, the words that `known`
holds and the dictionary no longer does are added to `removed`, and the
words that are in the dictionary again are taken out of it; `removed` is
written to the disk. Then a tool's copy of a removed word is dropped from
what the tool is given, and is never taken into the dictionary. At the
end, `known` becomes the dictionary's words.

**A line deleted by hand** is a removal like `remove`: the next sync sees
that `known` has the word and the file does not. Changing the case of a
word by hand (`Github` to `GitHub`) is no removal; the tools get the new
spelling.

**`remove`** writes the word into `removed` itself, before it replaces the
file. A crash between the two leaves a record of a word that is still in
the file, which the next sync drops; the other order could lose the
removal. So `remove` works on a host that never synced, where a line
deleted by hand does not (below).

**A crash, a failed adapter.** `removed` is on the disk before any tool is
touched, and a word stays in it until it is in the dictionary again, not
until every tool has lost it. A sync that crashes, or whose adapter fails,
leaves the record as it was; any later sync takes the word from the tools
that missed it, though the file shows no fresh removal by then. The same
holds for `sync --adapter NAME`: a removal seen in the sync of one adapter
reaches the others in theirs.

**A tool that resets its list**, or is restored from a backup that still
has the word, cannot bring it back: the word is in `removed`, so the tool's
copy is dropped, not taken.

**Bringing a word back** goes through the dictionary only: `ravnix-dict
add`, or the line written again by hand. A removed word that turns up in a
tool again, typed in or written back by Handy from its memory, is taken out
of the tool at the next sync: strip it, add it back on purpose (the
maintainer's rule, 2026-11-14).

**An emptied dictionary.** A file with no word left, when the last sync
knew some, is more often an editor that truncated the file before writing
it, or a checkout gone wrong, than a wish to empty every tool. sync refuses
it and touches nothing; `sync --allow-empty` says it is meant, and then the
words of the last sync go from every tool. A word added in a tool since
the last sync is not among them: it comes into the file, as always. A file that
was only half written when sync read it records the missing words as
removed and takes them from the tools; once the file is whole they are in
it again, out of `removed`, and every tool gets them back at the next sync.

The record is per host on purpose: each host has its own tools and its own
checkout of the dictionary. A removal made on one host and pulled with git
on another is a line gone from the file there, which that host's next sync
sees through its own `known`, on one condition: that host has synced at
least once while the word was in its file, and kept its state since. A
host that never did sees the word in its tools as a new one and adds it
back, the same gap as a line deleted by hand before a host's first sync
(below).

## Adapters

```odin
Error :: Maybe(string)

Adapter :: struct {
	name:        string,
	read:        proc() -> ([]string, Error),
	write:       proc(words: []string) -> Error,
	must_stop:   bool,
	unavailable: proc() -> string,
}
```

`read` gives the tool's list as the tool has it, `write` gives it a whole
new list, and `must_stop` says that writing stops the tool for a moment;
the adapter stops and starts the tool itself. `unavailable`, when an
adapter has one, says why the tool cannot be reached right now (`""`
when it can): sync then prints `NAME: skipped: REASON`, neither reads nor
writes it, and that is no failure. What `read` returns is allocated in the
context's allocator, which the core frees: an adapter frees nothing it
returns. `Error` is a message for the user, or nil; as `Maybe(string)` it
is the same type in every package, so the adapters live in a package of
their own, `adapters/`, which needs nothing from this one.

Which adapters `sync` reads is `RAVNIX_DICT_ADAPTERS`, their names
separated by commas, read in the order `handy`, `languagetool`, `prose`
whatever the order named; without it, none (the bench, a test, a shell
without the module). A name that is no adapter is an error before any
command runs. `adapters()` in `adapter.odin` builds the list from the
environment (`Setup`):

| Variable | Is | Default |
| --- | --- | --- |
| `RAVNIX_DICT_ADAPTERS` | the adapters to sync | none |
| `RAVNIX_DICT_HANDY_SETTINGS` | Handy's settings store | `$XDG_DATA_HOME/com.pais.handy/settings_store.json`, `~/.local/share/...` |
| `RAVNIX_DICT_PROSE_FILE` | the prose skill's dictionary | `$XDG_CONFIG_HOME/prose/dictionary.txt`, `~/.config/...` |
| `RAVNIX_DICT_LANGUAGETOOL_SERVER` | the words API, without `/v2` | `https://api.languagetoolplus.com` |
| `LANGUAGETOOL_USERNAME`, `LANGUAGETOOL_API_KEY`, `LANGUAGETOOL_RBW_ITEM` | LanguageTool's credentials, as the editor reads them | none; see below |

The module (`modules/common/dictionary.nix`) sets the first three in the
wrapper on the PATH, and the vault item and the account of LanguageTool from
their options, from `ravnix.dictionary.adapters`: the prose skill's
everywhere, LanguageTool's on the laptop shape (`ravnix.shape`), Handy's
where the desktop installs Handy (`modules/desktop/apps.nix`). The
environment still wins over the wrapper.

### Handy

Handy's custom words are `settings.custom_words` in its settings store, a
JSON file that also holds every other setting of Handy, API keys among them.
Handy keeps the store in memory and writes all of it back when a setting
changes and when it quits (tauri-plugin-store), so a list written into the
file while Handy runs is undone at its next save. A write therefore:

1. finds Handy's processes of this user in `/proc`, by name
   (`.handy-wrapped`, nixpkgs' wrapped binary, or `handy`; not
   `Handy-worker`, which ends with its parent), and notes in the state
   directory, `STATE/handy-stopped`, that it is stopping Handy;
2. stops them: a Handy in its session unit, `app-handy@autostart.service`
   (its `/proc/PID/cgroup` says so), with `systemctl --user stop`, so the
   unit is inactive and not merely missing its process when it is started
   again; any other with SIGTERM through a pidfd, killing what is left
   after ten seconds;
3. reads the store again, since what Handy saved as it quit is the newest;
   a word it has there that the last read did not, typed into its window in
   the meantime, is kept after the words given, and the next sync takes it
   into the dictionary;
4. replaces the value of `custom_words`, and nothing else: every other
   byte of the store stays as it was, in Handy's own layout (serde_json's,
   two spaces per level), and the store is replaced through a rename, with
   its mode, a link followed;
5. starts Handy again, if it ran, by starting that unit, so it gets the
   session's environment, and removes the note. Handy reads the new list
   as it starts.

A sync that ends between the stop and the start (its timeout, a stop of
the service, a crash), or a start that fails, leaves the note, and the next
sync's read starts Handy before anything else; a note while Handy runs is
only removed. Without the note, a Handy the user quit stays quit.

A store without `custom_words`, or without `settings`, gets them; a missing
store is no words, and a write makes one that holds only them, which Handy
completes with its defaults (its settings have a container-level
`serde(default)`). A store that is not JSON, or whose `custom_words` is not
an array of strings, is an error and stays as it is; since Handy writes it
in place, a read that meets half a file tries again, three times. No message
quotes the store.

### LanguageTool

The word list of a LanguageTool Premium account, in the cloud. The API lists
the words 500 at a time (`GET /v2/words`, until a page comes back empty, so
a server that caps the page lower still gives every word) and adds and deletes one word per
request (`POST /v2/words/add`, `/v2/words/delete`); a write sends only the
difference to the list the read got, deletes first, so a word whose spelling
changed is deleted in its old spelling before the new one is added. A word
with white space is left out: the API takes no phrase. A 429 is waited out
(its `Retry-After`, at most a minute, or 2 s doubling), and so are a 5xx and
a connection that broke off, six tries in all; a 401 or 403 says that the
account or the key was refused.

The requests run through curl (the store path the package is built with),
and curl's configuration, the key in it, goes to curl on its standard input
(`curl -q --config -`): the key is on no command line, in no environment
of another process and in no file, and no message holds it. main takes
`LANGUAGETOOL_API_KEY` out of its own environment before it starts
anything.

The credentials are found in the order of the editor's LanguageTool code
(`modules/common/nvim/lua/ravnix_languagetool.lua`): the environment, then
the vault through rbw, only while `rbw unlocked` says it is (the item that
`LANGUAGETOOL_RBW_ITEM` names: the key is its password, the account its
`username` field), then `~/.config/languagetool/credentials`, `KEY=VALUE`
lines. The wrapper sets `LANGUAGETOOL_RBW_ITEM` and `LANGUAGETOOL_USERNAME`
from `ravnix.dictionary.languagetool.rbwItem` and `.username`, which have no
default.

Only a locked vault skips the adapter: it is the usual state, not a
failure, and the watcher's timer syncs LanguageTool once the vault is open.
Everything else fails the sync with one line that says what to set: no item
named and no key elsewhere, an item the vault does not have, no account
name, rbw not installed, or a key the server refuses. A misconfigured host
shows as a failed `ravnix-dict-sync.service`, not as a list that silently
never syncs. Each timer run that reads the vault also renews rbw's idle
lock, which `modules/common/rbw.nix` caps at 12 hours.

### prose

The prose skill's own dictionary of the user, `~/.config/prose/dictionary.txt`:
a word per line, `#` comments, read as the skill's checker reads it (a line,
trimmed, that is not empty and does not start with `#`). The list that
ships with the skill is not written. A write keeps the comments, the blank
lines and the line breaks where they are, keeps each word's line in its place
with the spelling given, drops the lines of the words it is not given, and
appends the new words; a missing file is made with a comment that says
where its words come from.

## The watcher

`modules/common/dictionary-watch.nix` runs `ravnix-dict sync` as the user
service `ravnix-dict-sync`: started by a path unit whenever the dictionary
or a list in a file changes (Handy's store, the prose dictionary), and by a
timer two minutes after login and 15 minutes after each run, for what no
file shows (LanguageTool's list) and for a change that came while a sync
ran. It is the wrapper of the shell, with home-manager's `XDG_STATE_HOME`,
so the shell and the service share one state and one lock. Without a
dictionary at the configured path the service does not run.
`ravnix.dictionary.watch = false` leaves the three units out.

A sync that writes a list changes a file the path unit watches, which starts
one more sync; that one finds every list in step and writes nothing.

## Tests and bench

`ravnix-dict-tests` runs `tests/`: the format (`dict_test.odin`: round
trips of every kind of line, case, fields, the lines it refuses, a 200 000
line file), the command line against files on the disk (`cli_test.odin`: a
missing, too big, not writable, linked and directory dictionary, the lock
held and four runs at once, usage), and sync (`sync_test.odin`) against
three fixture adapters whose lists live in the test, one of which must be
stopped and any of which can be made to fail: two-way and add only, a
reset tool, `remove` and a line deleted by hand, a crash and a failed
adapter between a removal and the sync that carries it, a tool restored
from an old list, the emptied file, a merge conflict, a corrupt and a lost
state, duplicates and empty words from a tool, a 50 000 word sync each way,
a file changed while sync reads the tools, a removed word that turns up in a
tool again and is added back, and an adapter that is unavailable.

The adapters are tested against real processes (`fakes.odin`): the test
program itself, started through a link whose name says which part to play,
stands in for Handy and for rbw. `handy_test.odin` runs a Handy that reads
its store as it starts and writes its memory back as it quits: a write
stops it, writes, and starts it again, and the word survives its next quit,
while a write made with it running is undone (Review Focus 2 of the plan);
also every other byte of the store kept, a store with and without the
member, missing, malformed or nested too deep, a Handy that ignores
SIGTERM, one that cannot be started again, a word Handy got between read
and write, the mode and a link, and 10 000 words. `languagetool_test.odin`
runs a stand-in of the words API on 127.0.0.1 in a thread, through the real
curl: paging, only the difference written (deletes first, phrases left
out, odd characters encoded), a 429 waited out with and without
`Retry-After`, a limit that stays, a 5xx, a refusal and an answer that
repeats the key (neither message holds it), answers that are no word list,
a server that does not answer and one that is not there, and the
credentials from the vault, the file, a locked vault and no rbw; while curl
waits for each answer, the stand-in looks through `/proc` for the key in a
command line or an environment. `prose_test.odin` reads as the checker
does, keeps the layout, makes a missing file, refuses one that is not
UTF-8, and keeps a link, the mode and a read-only file. `setup_test.odin`
checks `RAVNIX_DICT_ADAPTERS` and the paths. The editor's side of the
file's format is `tests/common/nvim-dictionary.nix`, on the same lines as
`the_editor_and_the_core_read_lang_alike` here.

The leak check of `ravnix-dict-tests` (`ODIN_TEST_FAIL_ON_BAD_MEMORY`)
covers almost nothing here: `run` puts a whole command into one arena,
which it frees at the end, and the tests use arenas and the temporary
allocator for what they parse. The design is the arena (a command runs
to its end, and nothing outlives it); a leak inside a command is not
caught, and does not outlive it either.

`ravnix-dict-bench` syncs `bench/dictionary.txt` (2000 made-up words) with
no adapter against `bench/state`, whose `known` holds two words that the
file no longer has.

## Known gaps

- A line deleted by hand before the first sync on a host comes back from a
  tool that has the word: nothing on that host knew the word was in the
  file (`a_line_deleted_before_the_first_sync_on_a_host_comes_back`).
  `remove` has no such gap.
- A state directory that is lost forgets the removals that have not reached
  every tool yet; a tool that still has such a word brings it back. Nothing
  else is lost: the next sync is a first one.
- Pointing `ravnix.dictionary.file` at another file makes the words of the
  old one that the new one lacks removals, on the next sync. The state
  does not record which file it belongs to.
- The compare before the rename narrows the window in which an editor's
  save is overwritten, but cannot close it: a save that lands between the
  compare and the rename is lost from the file (the editor still has it).
  The same holds for a writer that does not take the lock, such as the
  editor's LanguageTool code that appends to the dictionary
  (`modules/common/nvim/lua/ravnix_languagetool.lua`).
- Folding case rune by rune keeps `Straße` and `STRASSE` apart: a word
  that differs only so is two entries. This is on purpose, since full
  folding would make `Masse` and `Maße` one word.
- No Unicode normalization: `Ärger` in NFC and in NFD (`A` and U+0308)
  are two keys, so a tool that returns NFD puts a second spelling of the
  word into the file. Odin's core has no normalization to apply.
- A removed word typed into a tool again is taken out of the tool at the
  next sync, unattended once the watcher runs it; sync counts such words on
  standard output but does not name them. This is the maintainer's rule
  (strip it, add it back on purpose), so that a tool restored from an old
  backup, or Handy saving its memory, brings no word back.
- Handy is found by its process name only (`.handy-wrapped`, `handy`). A
  Handy started under another name is not stopped, and a write while it
  runs is undone at its next save. A Handy stopped for a write ends a
  dictation in progress; a sync stops it only when its list changes.
- Handy is started again through `app-handy@autostart.service`, the unit
  the session's XDG autostart makes of handy-launch's entry, hidden in the
  tray, also when it was started by hand with its window open. In a session
  without that unit, the words are written and the start fails, with a
  message that says so, and every sync tries again.
- LanguageTool's list cannot hold a word with white space (`Open WebUI`).
  The adapter leaves such words out, so the list never has them, and every
  sync counts them as written to it again, without a request.
- Two hosts that sync one LanguageTool account each take its new words into
  their own checkout of the dictionary, and a removal on one host goes back
  into the cloud from the other until it has pulled the removal; that is
  why the adapter is on the laptop only by default.
- A change that comes while a sync runs starts no second sync (systemd
  merges the start into the one that runs); the timer catches it within 15
  minutes.
- The first sync with LanguageTool adds every word of the dictionary with
  a request each, and its rate limit (80 a minute on Premium) makes it take
  minutes, with the lock held: an `add` by hand waits a minute for it, then
  gives up.
- The state's place comes from `XDG_STATE_HOME`. The watcher's service
  gets home-manager's `xdg.stateHome`, which is the shell's when
  home-manager exports it (`xdg.enable`) or when neither sets it; a shell
  with another value has a second state and a second lock.
- A crash between writing the new file and renaming it leaves
  `.NAME.ravnix-dict-new` next to the dictionary, in the private flake's
  checkout, where `git add -A` would commit it. The next command that
  writes replaces it; until then it can be deleted by hand.
- A field ravnix-dict does not know is kept, and warned about on every
  run that reads the file, so a deliberate one keeps warning.
