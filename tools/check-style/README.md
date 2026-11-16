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

Each file is read in blocks and judged line by line, and what a line allocates
is freed after the line, so the memory is that of the longest line and of the
hits, not of the size of the files: a file of 8.5 MB and one of 34 MB, both of
85-byte lines, take 2.3 MB at most. `tests/edge_test.odin` reads the peak of
the per-line arena through a seam in `Config` and fails when it follows the file
size: with the free after each line removed the arena holds 24 MB for a 10 MB
file, with it 200 bytes. Files are found by `getdents`, never by a shell out, and no other program runs: the Bash version needed `rg`, `awk`, `find`,
`sed` and `sort`. Hits are sorted by file name (bytes), line and rule, as
`sort` in the C locale did, and a repeat of a hit is printed once.

The rules are hand-written scanners over the bytes of a line, not regular
expressions: each regular expression of the Bash version is a procedure that
says in its comment what it finds. A line is searched whole. A scan is linear
in the length of the line: lines of 8 MB made of one construct repeated take
under 0.3 s each (`edge_test.odin` holds the shapes that would make a careless
scanner quadratic).

## In the gate

`scripts/check.sh` (the fast part, which pre-commit and the Claude Code Stop
hook run) judges the index and the unstaged changes with this program, as
the index builds it: nix builds the package from the index's snapshot and the
gate keeps the build in the work tree's git directory, keyed on what the
build reads, as the index's snapshot holds it (this directory, `lib/odin.nix`,
`lib/discover-tools.nix`, `flake.nix`, `flake.lock`, `docs/mermaid-theme.json`
and `docs/style.md`), so a commit that changes the program is judged by the
program it holds and an unchanged key costs no nix call (`scripts/README.md`,
"The style step"). The Nix checks that judge generated files
(`desktop-sway`, `desktop-helium-devtools-stylesheet`, `theme-apps`) use the
same package. The Bash script is deleted; its shell test is
`tests/bin/check-style/check-style.test.sh`, which `bin-check-style` runs on
the program.

## What differs from the Bash version

Where the 160-character window cut a keyword's context, the port reads the
whole line: it finds more (below), and in a few cases less, where the window
made a hit that the line does not hold (a value that began at the window's
edge read cut: `opacity` and 157 spaces and `0.9x` was `0.9`). That is not a
regression: the whole line is what the rule means. Each, with a test:

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

## White space and the start of a file

ripgrep's `\s` is Unicode white space, and ripgrep drops a byte order mark and
reads UTF-16, and the script read every file through it. The program finds
what the script finds: at the three places that used `\s` (the character
before a motion key, the white space between it and its `=` or `:`, and the
white space between a color property and its colon) it takes the Unicode
White_Space characters (U+0085, U+00A0, U+1680, U+2000 to U+200A, U+2028,
U+2029, U+202F, U+205F, U+3000, and the ASCII ones), read from UTF-8; a
broken sequence is no white space. A UTF-8 byte order mark at the start of a
file is dropped; a file that starts with a UTF-16 mark (either order) is read
as UTF-16, whole, and a unit that belongs to no pair counts as U+FFFD.

One deliberate difference follows from it. The script found the Mermaid init
blocks with `awk` on the raw bytes, not through ripgrep, so a byte order mark
in front of the first line kept the block's opening line from matching: a `.md`
or `.mmd` file with a mark before the shared init block gave the script four
`hex-color` hits (the block's colors), and a different block after a mark gave
it no `mermaid-init` hit. The program drops the mark first, so the shared block
is exempt and a different one is a `mermaid-init` hit. That is the reading the
rule means.

## Findings that are not fixed

- `@keyframes` glued to a non-ASCII letter (`@keyframesé`) is a hit; the
  script's `\b` is Unicode and saw a longer word. The program finds more here,
  never less.
- Invalid UTF-8: ripgrep's patterns stop at a byte that is no UTF-8. The
  radius, opacity and transparent rules judge each run of valid UTF-8 on its
  own, and a line that holds such a byte is no `/*` or `*` comment line, as in
  the script. The other rules (hex, bare color, motion) read across the byte,
  where the script stopped: they can find more there (a short color after a
  color property and a broken byte), never less.
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

`tests/` holds 159 `core:testing` tests: the 93 cases of the shell test that
fit a process (the 94th, which runs the program with an empty `PATH`, is a
shell case), a test per corner a
mutation of the program survived until it was named (found by mutating the program and running the tests), and the edge cases: malformed bytes, a
CR in the middle of a line, a symbolic link to a directory, a fifo, an
unreadable file or directory, a missing or odd theme, 200 000 lines, lines of
8 MB. `bin-check-style` runs the 98 shell cases on the built program. The
bench judges `bench/tree`, a small tree of one file of each kind, with no hit
(a hit would be an exit status 1 and fail the bench).
