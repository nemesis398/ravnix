# check-style

The style check: what `docs/style.md` forbids and a program can see. It
searches the paths it is given and prints one line per hit,

```
file:line:rule
```

and the rules are `hex-color`, `radius`, `opacity`, `motion` and
`mermaid-init`. `main.odin` has the full list, with the reasons; `docs/style.md`
names each rule. Ported from `scripts/check-style.sh` (AGENTS.md, rule 4).

```sh
check-style PATH...
```

At least one path. A directory is searched whole, a file by itself, a
symbolic link never followed. The root of the judged tree is the current
directory, and the exemptions (`modules/theme/`, `docs/style.md`, `vendor/`;
the fixture roots `tests/`, `scripts/tests/`, `tools/NAME/tests/`) are places
at that root, never directory names. The shared Mermaid theme is the file that
`RAVNIX_MERMAID_THEME` names, else `docs/mermaid-theme.json` of the flake the
program was built from (`default.nix` names it).

Exit status: 0 when nothing was found, 1 on a hit, 2 on bad usage, a path that
does not exist, a missing shared theme (only when a Mermaid block needs it),
a file or directory that cannot be read, or a line over 256 MiB.

## Personal values

None.

## How it works

Each file is read in blocks and judged line by line; the memory it needs is
that of its longest line. Files are found by `getdents`, never by a shell
out, and no other program runs: the Bash version needed `rg`, `awk`, `find`,
`sed` and `sort`. Hits are sorted by file name (bytes), line and rule, as
`sort` in the C locale did, and a repeat of a hit is printed once.

The rules are hand-written scanners over the bytes of a line, not regular
expressions: each regular expression of the Bash version is a procedure that
says in its comment what it finds. A line is searched whole. A scan is linear
in the length of the line: lines of 8 MB made of one construct repeated take
under 0.3 s each (`edge_test.odin` holds the shapes that would make a careless
scanner quadratic).

## Why the script is still here

`scripts/check.sh --fast` (pre-commit and the Claude Code Stop hook) runs
`scripts/check-style.sh` straight from the checkout. The fast gate needs git,
`rg` and `shellcheck` and no Nix, and builds no Odin tool; only the full gate
needs Nix (it builds `claude-code-verify`). So the script stays, and the Nix
checks that judge generated files (`desktop-sway`, `desktop-helium-devtools-
stylesheet`, `theme-apps`) use the port. The two cannot drift unseen while both
exist: `scripts-tests` runs `scripts/tests/check-style.test.sh` on the script,
and `bin-check-style` runs the same file on the program (`CHECK_STYLE`). When
the fast gate can run the program (the options are in the port's report:
a gcroot built once per run, or a binary on the PATH), `check.sh` switches
and the script goes.

## What differs from the Bash version

Fixed, and each with a test:

- **A line is searched whole.** ripgrep found each keyword with 160
  characters around it, and the rules judged those windows. Past 160
  characters the context of a keyword was cut; a value or a key that ran
  across a window edge was read cut. (A very long line was also slow: the
  Bash version needed minutes for a minified stylesheet that the port reads
  in milliseconds.)
- **A color glued to another is found.** Two colors with one byte between
  them gave one hit: the match of the first took that byte, and the second
  had no byte before it. A translucent color after another one could hide,
  and so could a color after a Markdown link target, which was read as a
  color of its own.
- **An upper-case `.MD`** was judged as a document for the list of files, but
  as code for the alpha check. It is a document for both.
- **A number is compared as text.** The Bash version converted it to a double,
  so `0.99999999999999999999` was 1. Now it is below 1.
- **An empty argument** is a path that does not exist.
- **A line longer than 256 MiB** is refused (exit 2, with its file), not read.
- **No `rg`.** The test of a missing `rg` became a test that the program runs
  with an empty `PATH`.
- Messages begin with `check-style:`, not `check-style.sh:`, and a file that
  cannot be read says why, not what `rg` said.

Not changed, on purpose: the odd rules are the rules (a hex color in a comment
counts, `#123456` in a document is an issue number, a link target is no color,
and so on); `edge_test.odin` and the shell cases pin them.

## Findings that are not fixed

- Case folding is ASCII. ripgrep's `(?i)` folded Unicode, so `K` (the Kelvin
  sign) matched `k` in a key; no key of a real style source has one.
- A character is a byte, except where the rules count characters (the 60 of
  a motion key's value count UTF-8 sequences).
- A line the program cannot read as a whole because of its length
  (over 256 MiB) stops the run; the lines before it are not reported.
- The directory walk reads every entry of a directory before it descends, so a
  directory of millions of entries takes memory in proportion to its names.
- `current_directory` follows `$PWD` as the shell does, so `check-style` run
  through a link keeps the link's path; run from the root of the checkout, as
  `scripts/check.sh` does, nothing depends on it.
- The callgrind bench judges a small tree (`bench/tree`), not a large file;
  the large files and the long lines are tests.

## Tests and bench

`tests/` holds 145 `core:testing` tests: the 93 cases of the shell test that
fit a process (the 94th, a missing `rg`, is a shell case), a test per corner a
mutation of the program survived until it was named (the list of mutations
that was run is in the port's report), and the edge cases: malformed bytes, a
CR in the middle of a line, a symbolic link to a directory, a fifo, an
unreadable file or directory, a missing or odd theme, 200 000 lines, lines of
8 MB. `bin-check-style` runs the 94 shell cases on the built program. The
bench judges `bench/tree`, a small tree of one file of each kind, with no hit
(a hit would be an exit status 1 and fail the bench).
