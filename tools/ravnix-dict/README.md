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
                       add a word, or the languages and mishearings it lacks
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
| 0 | done, or nothing to do (`add` of a word that is there with all its fields) |
| 1 | failed: the dictionary is missing, too big, not writable or not one (not UTF-8, a NUL, a git merge conflict); `remove` of a word that is not there; the lock was held for a minute; the state cannot be read or written; an adapter failed (the others are synced all the same) |
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
lines. The case is folded rune by rune to lower case, so `Ärger` and
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
add`, or the line written again by hand. A removed word that is typed into
a tool again is taken out of the tool at the next sync.

**An emptied dictionary.** A file with no word left, when the last sync
knew some, is more often an editor that truncated the file before writing
it, or a checkout gone wrong, than a wish to empty every tool. sync refuses
it and touches nothing; `sync --allow-empty` says it is meant. A file that
was only half written when sync read it records the missing words as
removed and takes them from the tools; once the file is whole they are in
it again, out of `removed`, and every tool gets them back at the next sync.

The record is per host on purpose: each host has its own tools and its own
checkout of the dictionary. A removal made on one host and pulled with git
on another is a line gone from the file there, which that host's next sync
sees through its own `known`.

## Adapters

```odin
Error :: Maybe(string)

Adapter :: struct {
	name:      string,
	read:      proc() -> ([]string, Error),
	write:     proc(words: []string) -> Error,
	must_stop: bool,
}
```

`read` gives the tool's list as the tool has it, `write` gives it a whole
new list, and `must_stop` says that writing stops the tool for a moment;
the adapter stops and starts the tool itself. What `read` returns is
allocated in the context's allocator, which the core frees: an adapter
frees nothing it returns. `Error` is a message for the user, or nil; as
`Maybe(string)` it is the same type in every package, so an adapter in a
package of its own needs nothing from this one. The list `main` syncs is
`adapters()` in `adapter.odin`, empty until Task 7.2 adds Handy,
LanguageTool and the prose skill's dictionary.

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
and a file changed while sync reads the tools.

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
  that differs only so is two entries.
- A field ravnix-dict does not know is kept, and warned about on every
  run that reads the file, so a deliberate one keeps warning.
