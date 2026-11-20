# ravnix-paperless-copy

The nightly, one-way copy of each person's filed Paperless documents into
their read-only `Archiv` folder on the NAS. It runs as the `archive-copy`
service of the Paperless compose, in the image `ravnix-paperless-copy-image`
(`packages/ravnix-paperless-copy-image`). The design is the section *The
archive copy* of the Paperless spec; the script's header is the full contract.

```
ravnix-paperless-copy --media DIR --targets DIR [--once] [--at HH:MM]
```

- `--media` is Paperless' media folder (`documents/archive/OWNER/...`,
  `documents/originals/OWNER/...`; the filename format puts the owner first).
- `--targets` holds one folder per owner, each that person's `Archiv` folder.
  The folders in it are the owner list: only an owner whose folder is mounted
  there is copied, and the tool never creates one. A symlink there is refused.
- Without `--once` it loops and copies every day at `--at` (default `03:30`) on
  the clock of `$TZ` (default `Europe/Berlin`). The first run is the first
  `--at` after the start. A run that fails is logged and the loop goes on.
- The Uptime Kuma push URL is read from the environment variable
  `KUMA_PUSH_URL` (empty or unset: no push). It is a token, so there is no
  option for it; curl reads it from its standard input and the variable is
  unset before anything else runs. The push happens when every owner folder
  was copied, and not on a failure, a refusal, or when there was nothing to do.
- Exit status: 0 done (or nothing to do), 1 a copy failed, 2 usage, 3 refused.

## What an owner's folder becomes

The files of `documents/archive/OWNER` (the searchable PDF/A), plus each file
of `documents/originals/OWNER` that has **no archive twin**, plus
`LIESMICH.txt`. A twin is the same relative path with `.pdf` in place of the
original's extension. Everything else in the folder is deleted, so:

- a file deleted in the `Archiv` folder is back after the next run, and a
  changed or added one is overwritten or removed (`LIESMICH.txt` says so, in
  German);
- a document renamed in Paperless (title, correspondent, year) has its new path
  after the next run, with no stale old file and no empty old folder;
- a fallback original is replaced by the PDF/A when Paperless makes one later,
  and goes when the document goes.

### How the fallback survives `--delete`

Not with a second pass and a protect rule: there is one `rsync --delete` per
owner, from a **staging tree** that holds exactly what the folder is to become.
The staging tree is made of symlinks (`cp -rs` of the archive tree, then a
symlink for each original without a twin, then the notice) in `$TMPDIR`, and
rsync follows them (`-L`). The delete pass thus compares against the merged set
and a fallback original is as safe from it as any archive file, folders that
only a fallback sits in stay, and a rename is one pass. The staging tree costs
a few bytes per document and is removed when the run ends. Symlinks, fifos and
devices in the media folder are removed from it first, so a link there cannot
show the owner a file elsewhere.

Copied files are mode 644 and folders 755 whatever the source had
(`--no-perms --chmod`), owned by the UID the container runs as. The folder
itself (the mount point) is never chmod'ed or touched in time (`-O`), which
the NAS account may not own. A source folder that is read-only does not stop a
run: rsync adds the write bit it needs to the folders it writes in.

## What it refuses

Exit 3, nothing changed, when `documents/archive` is missing or empty while any
owner folder holds a file other than the notice: an unmounted media folder
never empties a copy. The same with empty folders is "nothing to do" (exit 0, no
push). It also refuses an owner whose entry in `--targets` is a symlink, and one
whose folder in the media folder is a symlink, and goes on with the others
(exit 3 at the end). It never reads outside its two roots: symlinks inside a
target are deleted or replaced, never followed.

## Tests

`tests/copy.test.sh`, run by the check `bin-ravnix-paperless-copy`
(`tests/bin/ravnix-paperless-copy.nix`) against throwaway trees, with a stub
curl and sleep: per owner, original fallback and its survival of later nights,
restore of a deleted file, rename, refusal of a missing or empty source,
symlinks in a target and in the source, umlauts / decomposed umlauts /
division slash / newline / glob characters in names, readable modes, the
notice, no leftover staging tree, a failed copy, the push (token on no command
line), the loop and its clock, and usage.

## Why Bash

AGENTS.md's rule 4 has new tools written in Odin. The plan for this task names
a Bash tool with shell tests, and it is glue around `rsync`, `cp` and `find`
with the logic in the file layout, so Bash is kept; the maintainer decides
whether a port belongs on the Odin list.

## Findings that are not fixed

- The loop's clock is `date -d`; the daylight-saving changes are by
  construction (tomorrow's `HH:MM`, not 24 hours on) but no test crosses one.
- Two runs at the same time (the loop and a `docker exec ... --once`) are not
  locked out. Both mirror the same set, so the result is the same, but the
  second one can see a half-built folder and say a file vanished (rsync 24,
  which counts as success).
- A file that changes while it is copied, or a document consumed during the
  run, may fail the run (an unreadable or dangling staging link is rsync 23,
  exit 1, no push). The next night repairs it; Kuma's missing push is the alarm.
- Quick check only: a copy edited to the same size with its modification time
  put back is not noticed (no `--checksum`: it would read every document each
  night).
- The refusal covers `documents/archive` as a whole. An owner whose documents
  were all deleted in Paperless has their folder emptied when others still have
  documents; there is no per-owner "never empty a folder" rule.
- Not verified on UGOS: the ACL / SMB visibility of the copied files for the
  person (only modes 644/755 and the run's UID are set), and whether the NAS
  drops metadata folders (`@eaDir`, `#recycle`) into an `Archiv` folder, which
  the run would delete each night.
- Names that SMB clients dislike (a colon, a quote, a trailing space) are
  copied as Paperless wrote them. The test pins that they arrive byte for byte;
  how Windows shows them is not tested.
