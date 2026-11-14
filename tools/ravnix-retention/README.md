# ravnix-retention

Reads the retention file, `backups.toml` (`ravnix.backup.retentionFile`),
and prints the flags of `restic forget` that keep what the file says one
host keeps at one target. The prune jobs on the NAS run it once per host
and target:

```sh
restic forget --prune $(ravnix-retention flags --target nas --host huginn)
```

```sh
ravnix-retention flags --target TARGET --host HOST [--file FILE]
```

`--file` names the file; without it the tool reads the file that
`RAVNIX_RETENTION_FILE` names, which is how the prune job's image passes
it. With neither, it refuses.

## The flags

For the template's file, `--target nas --host huginn` prints

```
--host huginn --group-by host --keep-daily 7 --keep-weekly 4 --keep-monthly 6
```

- **`--host HOST`, always.** The Internxt repository is shared by the whole
  estate, so a forget without `--host` would apply one host's numbers to
  every other machine's snapshots there.
- **`--group-by host`, always.** restic groups by host and paths unless it
  is told otherwise. A host whose backup paths change, say by a new
  `ravnix.backup.nas.paths`, would then have two groups, and the policy keeps
  the newest snapshots of each group: the old group's last week of dailies
  would stay forever.
- **A count of 0 is left out.** 0 means none of that kind is kept for its
  own sake, which is what restic does with a kind it is not given. restic
  0.19 reads `--keep-yearly 0` the same way; leaving it out does not depend
  on that.
- **A host's own table wins** for the keys it gives; the other keys come
  from the target. `[targets.nas.hosts.muninn]` with `daily = 14` changes
  only muninn's dailies at the NAS.

## What it refuses

A file with any mistake anywhere gives no flags at all, so the prune does
not run. Each refusal names the key, and the line where there is one:

- a count that is negative, a fraction, a string, a boolean, an array, an
  inline table, or larger than a 64-bit integer;
- a target or host table without a count, or with a key that is not a count
  (`dayly`, `hourly`), or with `hosts` inside a host;
- a target other than `nas` and `internxt`, a missing target, a key outside
  `targets`, and a value where a table belongs;
- a target, or a host's numbers after its override, that keeps nothing at
  all, which would delete every snapshot. restic 0.19 refuses an all-zero
  policy itself ("no policy was specified"); the tool does not rely on that;
- TOML that is not part of a retention file: an array of tables, an escape
  in a quoted key, a key or table given twice, a header that does not end,
  a control character; and a file larger than 64 KiB, or one that does not
  end (`/dev/zero`), which is cut at the limit and refused.

The arguments are checked too. `--target` must be `nas` or `internxt`, and
`--host` must be a host name: letters, digits, `-` and `_`, starting with a
letter or a digit, at most 63 characters. The flags pass through a shell's
word splitting, and a name like `-v` would be read as an option.

The messages are the ones `modules/options/backup.nix` gives at build time,
and `tests/options/retention-tool.nix` checks that the two agree on every
fixture of `tests/options/fixtures/retention/`.

| Exit | Means |
| --- | --- |
| 0 | the flags are printed, on one line |
| 1 | the file cannot be read, is too large, or is wrong |
| 2 | bad usage: a missing, repeated or unknown option, an unknown target, a host that is no host name, or no file named |

Only exit 0 prints anything on standard output.

## The TOML it reads

TOML has no reader in Odin's core library, so the tool reads the part of
TOML a retention file needs: comments, `[table]` headers, `key = value`,
bare keys, quoted keys without escapes, dotted keys, and decimal integers
with an optional sign and underscores between digits. A byte order mark
and CRLF line ends are taken.

## Findings not fixed

- **TOML that Nix reads and this tool does not.** A count written in hex,
  octal or binary (`0x7`), an escape in a quoted key, a multi-line value and
  an inline table are valid TOML, and `builtins.fromTOML` reads them, so the
  build accepts such a file; the tool refuses it, and the prune does not
  run. That is the safe way to be wrong, and the template's comments show
  only what the tool reads. A file in that shape fails the prune job loudly
  instead of deleting anything.
- **A host name the file has but no host carries.** An override for
  `hugin` instead of `huginn` is not an error: the tool cannot know the
  hosts. The prune job asks for the names it knows, so such an override is
  simply never used.
