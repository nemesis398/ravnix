# scripts

The local gate and the hooks around it. There is no CI, so these are the
only checks ravnix has; the reasons for each design choice are in the header
of each script.

| Script | Does |
| --- | --- |
| `check.sh` | the gate: `--fast` (boundary check, style check, shellcheck) on every commit and stop, the full gate (adds `nix flake check`) before every push |
| `check-public.sh` | the public-boundary check: no deny-list value in any file, file name or link target |
| `check-style.sh` | the style check: no hex color outside `modules/theme/`, no radius other than 0, nothing translucent but the inside of the lock ring, no transition or animation, no Mermaid init block but the shared one (`docs/mermaid-theme.json`); prints `file:line:rule` |
| `lib/git-snapshot.sh` | lays out the index or a commit as plain files, for the checks to read what git will commit or push |
| `hooks/stop-gate.sh` | the Claude Code Stop hook: the fast gate before the agent may stop |
| `hooks/no-verify-guard.sh` | the Claude Code PreToolUse hook: refuses commands that skip or redirect the git hooks |
| `../.githooks/` | `pre-commit` (fast gate), `commit-msg` (boundary check on the message), `pre-push` (each pushed commit, message and ref name, then the full gate) |

Tests: `tests/*.test.sh` and `hooks/test.sh`, run by the flake check
`scripts-tests`.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- `check-public.sh` matches literals. It does not find a value that is
  compressed (a `.gz` file), encoded (base64, URL encoding), split across two
  lines, or written in another Unicode normal form (a decomposed `ö` against
  a composed entry).
- `check-public.sh` skips everything named `.git` at any depth, not only the
  top one. Git cannot track such a path, so through the gate this changes
  nothing; a directory checked outside git skips a nested repository's
  `.git` too.
- `check.sh` does not read untracked files: they are not part of any commit
  until staged, and pre-commit checks them then. A Stop hook therefore does
  not catch a value in a new file that was never staged.
- `check.sh` lays out the index with one `git cat-file` per file, which is
  fine for hundreds of files and slow for many thousands.
- The full gate runs `nix flake check` on the work tree (the tracked files
  with their work-tree contents), not on exactly the commits being pushed.
- `commit-msg` stops reading at git's exact cut line, because under
  `--verbose` what follows is a diff that git drops. A message given with
  `-m` or `-F` that holds that line keeps the text below it, unchecked by
  `commit-msg`; `pre-push` reads every message in full and stops the push.
- `pre-push` checks only commits the remote's tracking refs do not have. When
  the deny list grows, older history is not checked again by itself; to check
  all of it, run `.githooks/pre-push` by hand with a URL as the remote name,
  which no tracking ref matches.
- `stop-gate.sh` blocks the first stop of every user turn while the gate is
  red for a reason the session cannot fix (a deny list that moved, a missing
  tool), since a new turn's first stop does not count as repeated. It is let
  through on the repeated stop; the behavior is phyllon's.
- Check discovery (`lib/discover-checks.nix`) refuses a `.nix` file directly
  in `tests/`, but a `.nix` file in a subdirectory of an area is silently no
  check, because helpers and fixtures go there. A discovered name that clashes
  with a check `flake.nix` defines itself (`scripts-tests`) throws, untested.
- `no-verify-guard.sh` reads the command text. It misses:
  - a command built at run time: an option held in a variable, base64,
    printf or `$'\x..'` escapes;
  - a script piped into a shell (`echo '...' | bash`, `cat <<EOF | sh`); a
    heredoc or here-string that the shell itself reads is judged;
  - a command run elsewhere (`ssh host '...'`), and runners other than
    `sh -c`, `eval`, `nix-shell --run`, `script`, `su` and `flock -c`, such
    as `watch` or `tmux send-keys`;
  - `$(...)` inside `${...}`, or in a heredoc no shell reads;
  - plumbing that makes commits without hooks (`git commit-tree`,
    `git update-ref`), `.git/config` edited by hand, and hooks deleted or
    made non-executable.

  It resolves git aliases from the configuration of the directory Claude
  Code runs it in. `pre-push` catches what such a commit would publish.

### `check-style.sh`

- It judges styling sources by type and place: `*.nix`, CSS, `*.ini`,
  `*.conf`, `*.toml`, `*.jsonc`, `*.kdl`, `*.colors`, anything below
  `modules/` or `hosts/`, and Markdown and Mermaid files (hex colors and init
  blocks only). A styling source of another kind outside those places (a
  Python script that draws, an SVG, Odin code) is not read, so "never write a
  hex color outside `modules/theme/`" (AGENTS.md) is wider than what the
  check enforces there.
- Directories named `vendor`, `vendored`, `third_party`, `third-party`,
  `themes`, `tests`, `fixtures`, `fixture` and `testdata` are skipped whole,
  at any depth, because they hold vendored files and fixtures that fail on
  purpose. Anything put there is not judged.
- Hex colors are `#` plus 6 or 8 digits. `#rgb` and `#rgba` are searched only
  in CSS files, in quotes and after a color property, because `#123` and
  `#add` are issue numbers and anchors everywhere else. Colors written as
  `rgb(...)`, a name, `0xRRGGBB`, a decimal triple (KDE) or a bare `rrggbb`
  are not hex colors to it; a bare `rrggbbaa` is judged for its alpha, on
  color keys only (`color`, `background`, `border`, `selection`, ...), so a
  version or a revision is never mistaken for one.
- The lock ring's exemption is a key name: `inside-color` and
  `inside-*-color`. A translucent value on any other key is a hit.
- Comment lines (`#` and a space, `;`, `//`, `/*`, a leading `*`) are not
  searched for radius, opacity and motion. The body lines of a block comment
  that do not start with `*` are, so prose there can be a false positive; a
  hex color in a comment is a hit on purpose.
- A radius or opacity built by interpolation (`"border-${side}-radius"`), taken
  from a variable (`var(--r)` is a hit, `cfg.radius` is not) or set by a
  sibling rule is not followed. Motion is the keys `transition*`,
  `animation*` and `@keyframes`, except a key whose value turns motion off
  (`none`, `false`, `off`, `0`, `0s`, `0ms`); other ways to move (a blinking
  cursor, smooth scrolling) are not judged.
- An eight-digit hex color is read as `#rrggbbaa`. One written `#aarrggbb`
  (Qt, Android) is a hex-color hit anyway, and inside `modules/theme/` it is
  a false opacity hit unless it is fully opaque in both readings.
- In Markdown and on comment lines an all-digit `#123456` is taken for an
  issue number. The all-digit Mocha colors Mantle and Surface0 are still
  found, but another all-digit color in prose (`#333333`) is not.
- Mermaid blocks are compared with the shared one without white space, so the
  key order counts. Theme settings given other than by `%%{init: ...}%%`
  (front matter `config:`) and Mermaid shapes are not judged.
- The line of a hit is the line of the match; a declaration that spans lines
  (`border-radius:` on one, its value on the next) is judged by the first.
