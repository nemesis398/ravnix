# scripts

The local gate and the hooks around it. There is no CI, so these are the
only checks ravnix has; the reasons for each design choice are in the header
of each script.

| Script | Does |
| --- | --- |
| `check.sh` | the gate: `--fast` (boundary check, style check, shellcheck) on every commit and stop, the full gate (adds `nix flake check`, then `claude-code-verify` on the Claude Code download against Anthropic's live release manifest, remembering what it verified) before every push |
| `check-public.sh` | the public-boundary check: no deny-list value in any file, file name or link target |
| `check-style.sh` | the style check: no hex color outside `modules/theme/`, no radius other than 0, nothing translucent (the keyword `transparent` too) but the inside of the lock ring, no transition or animation, no Mermaid init block but the shared one (`docs/mermaid-theme.json`); prints `file:line:rule`. A child that shows its parent uses the role color or `inherit`, never `transparent` |
| `lib/git-snapshot.sh` | lays out the index or a commit as plain files, for the checks to read what git will commit or push |
| `hooks/stop-gate.sh` | the Claude Code Stop hook: the fast gate before the agent may stop |
| `hooks/no-verify-guard.sh` | the Claude Code PreToolUse hook: refuses commands that skip or redirect the git hooks |
| `../.githooks/` | `pre-commit` (fast gate), `commit-msg` (boundary check on the message), `pre-push` (each pushed commit, message and ref name, then the full gate) |

Tests: `tests/*.test.sh` and `hooks/test.sh`, run by the flake check
`scripts-tests`. `tests/lib.sh` points `XDG_STATE_HOME` into each test
file's scratch directory, so no test's gate records into your state.

## Verified downloads

The full gate records each pair of Claude Code version and download store
path that `claude-code-verify` verified, one line `<version> <download>`
per pair, in `${XDG_STATE_HOME:-$HOME/.local/state}/ravnix/claude-code-verified`.
The file holds nothing secret. A store path names the download's bytes: the
download is a fixed-output derivation, so the same path is the same file.

| The verifier says | The gate |
| --- | --- |
| verified (exit 0) | passes, and records the pair |
| mismatch (exit 1) | fails, and removes the pair if it was recorded; the whole record when the pair cannot go alone, and when neither can, it names the file to delete |
| manifest unreachable (exit 3) | passes for a recorded pair and fails for any other, and says which case applied |
| anything else | fails, and leaves the record alone |

A record with any line of another shape (a NUL byte, a CR, a line of one
word, an empty line) counts as empty, and the next verified run replaces it.
A record the gate cannot write (a directory in its place, a read-only
state directory) does not fail a verified run; the gate says so, and a later
run with the manifest unreachable fails for that pair. Neither does a pair
the record could not hold as one line of its shape, such as a version with
a space in it: the gate does not record it. Delete the file to
make the gate check every download live again.

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
- Two full gates at once may each rewrite the record of verified downloads,
  and the last one wins, so a pair one of them recorded can be lost. That
  only makes a later run with the manifest unreachable fail for it.
- The record is per machine and per user: a pair verified on one host does
  not let the gate pass on another while the manifest is unreachable.
- Any program running as the user, an agent session included, can write
  the record. The match is exact, so malformed content cannot pass, but a
  forged line can: `<new version> <new download>` lets the gate pass for a
  binary nobody verified, while `downloads.claude.ai` is unreachable. That is
  all a forged line can do, since a reachable manifest is still checked
  live, and it is no larger than the user account itself, the gate's trust
  boundary: a program that can write the record can edit `check.sh` as well.
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

What it judges, and where:

- It judges styling sources by type and place: `*.nix`, CSS, `*.ini`,
  `*.conf`, `*.toml`, `*.jsonc`, `*.kdl`, `*.colors`, anything below a
  `modules/` or `hosts/` directory, and Markdown and Mermaid files (hex colors
  and init blocks only). A styling source of another kind outside those places
  (a Python script that draws, an SVG, Odin code) is not read, so "never write
  a hex color outside `modules/theme/`" (AGENTS.md) is wider than what the
  check enforces there.
- An exemption is a place at the root of the judged tree, never a directory
  name. Skipped whole: `.worktrees/`, `.superpowers/`, `tests/`,
  `scripts/tests/` and `tools/NAME/tests/` (fixtures that fail on purpose),
  and a directory named `.git` or `node_modules` at any depth. Hex colors are
  allowed in `modules/theme/` and `docs/style.md`, and in `vendor/`, the one
  root for vendored files, which every other rule still judges. A `themes/`,
  `tests/` or `vendor/` further down is judged like any other directory.
- The root is the current directory. A relative path, or an absolute one below
  the current directory, is placed by its path from there. A directory outside
  it is the root of its own tree. A file outside it is placed by its path as
  given, so it gets no exemption: run the check from the root of the checkout.

What it sees, and what it does not (the false negatives):

- Hex colors are `#` plus 6 or 8 digits, and a bare `rrggbb` or `rrggbbaa`
  value on a color key (`fuzzel` and `swaylock` write them), which is a
  hex-color hit outside `modules/theme/` and, with an alpha below `ff`, an
  opacity hit. A color key is one that holds `color` or `colour`, or has a
  dash or underscore separated part `background`, `foreground`, `bg`, `fg`,
  `border`, `selection`, `match`, `placeholder`, `prompt`, `counter`,
  `separator`, `frame`, `text` or `input`. Not seen: a bare color on another
  key, one that shares its line with other values, a six-digit color with
  no letter in it (`333333`), except Mocha's own Mantle and Surface0, and a
  value of the letters a to f only (`abcdef`, `facade`, `deadbeef`), which
  counts as a color only when every byte is one digit twice (`ffeedd`, as
  `#fed` expands).
- `#rgb` and `#rgba` are searched only in CSS files, in quotes and after a
  color property, because `#123` and `#add` are issue numbers and anchors
  everywhere else. Colors written as `rgb(...)`, a name, `0xRRGGBB` or a
  decimal triple (KDE) are not hex colors to it.
- An eight-digit hex color is read as `#rrggbbaa`. One written `#aarrggbb`
  (Qt, Android) is a hex-color hit anyway, and inside `modules/theme/` it is
  a false opacity hit unless it is fully opaque in both readings.
- An all-digit `#123456` is taken for an issue number in Markdown, on a comment
  line and in a trailing `#`, `//` or (Lua) `--` comment. The all-digit Mocha colors
  Mantle and Surface0 are still found, but another all-digit color in prose
  (`#333333`) is not. A link target, `](#facade)` or `href="#facade"`, is no
  color, which also hides a real color written as a link target.
- The lock ring's exemption is a key name: `inside-color` and
  `inside-*-color`, bare or with a `#`, when the key and the value are on one
  line. A translucent value on any other key is a hit.
- Opacity keys are every key that ends in `opacity` and the key `alpha` bare
  or led by a surface (`background`, `bg`, `window`, `inactive`, `border`,
  `text`, ... `_alpha`), so a `smoothing_alpha` is no hit. Another alpha key
  (`layer_alpha`) is not seen, nor an alpha spelled `fade(`, `color-mix(` or
  as a percentage word. Neovim's `winblend` and `pumblend` are hits above 0
  (`vim.o.pumblend = 10`, `set winblend=10`); not seen: the same option set
  from another option (`winblend = vim.o.pumblend`), a `blend` attribute of a
  highlight group, and a program's own default that the configuration never
  writes. LazyVim sets `pumblend = 10` itself, so a Neovim module has to write
  `vim.opt.pumblend = 0`; the check cannot tell that it did not. Sway's `opacity` command is a hit also inside a
  quoted string; prose in a string that starts `opacity 0.5` is a false hit.
- `transparent` is a hit as the value of a key set with `=`, as the last word of
  a CSS declaration on a color property (a name with `color`, `background`,
  `border`, `outline`, `fill`, `stroke`, `shadow` or `caret` in it), and in
  `@define-color name transparent`. After a colon on any other key it is prose
  (`Default: transparent`), so `"ui.menu": "transparent"` in JSON or YAML is not
  seen. It is not seen inside a function (`linear-gradient(to right,
  transparent, red)`). `rgba(0, 0, 0, 0)` is judged by its alpha.
- Radius: `border-radius` and its per-corner forms, every key that ends in
  `radius` or `-radius` (except the lock ring's `indicator-radius`,
  `ring-radius` and `lock-ring-radius`, which are gauge geometry; any other
  ring, such as `focus_ring_radius`, has a corner, and any other radius that is
  no corner is a false hit: widening the exemption needs the maintainer), a key with
  `border` in its name set to `rounded`, and `round_corners` or
  `rounded_corners` with any value but 0, false, off, no or none. Not seen:
  other spellings of the same thing (Hyprland's `rounding`, a `style` set to
  `rounded`, rounded box-drawing glyphs `╭╮╰╯` in a prompt or a border
  string), and a radius built by interpolation (`"border-${side}-radius"`),
  taken from a variable (`var(--r)` is a hit, `cfg.radius` is not) or set by a
  sibling rule.
- Motion is the keys `transition*`, `animation*` and `@keyframes`, and
  `enable-animations` and `gtk-enable-animations` set to anything but an
  off-value (`none`, `false`, `off`, `no`, `0`, `0s`, `0ms`). Other ways to
  move are not judged: a blinking cursor, smooth scrolling, a key such as
  `animations-enabled`. The key is judged also as the last part of a Nix
  attribute path (`gtk.gtk3.extraConfig.gtk-enable-animations = true`); a CSS
  class selector with a pseudo-class (`.animation-x:hover`) is no key, in a CSS
  file and in a stylesheet inside a Nix string, as long as its line ends in `,`
  or `{` or the rule opens right after it (a selector alone on its line, with
  the `{` on the next, is a false hit in a string).
  An attribute that is named like a key (`animation-nvim = ...` in a plugin
  set) is a false hit, as is prose that starts `transition:` or `animation:`
  (in a multi-line string, say).
- Comment lines (`#` and a space, `;`, `//`, `--` in Lua, `/*`, a leading `*`)
  are not searched for radius, opacity and motion. A `/* ... */` that ends
  before more code is cut out of the line. The body lines of a block comment
  that do not start with `*` are searched, so prose there can be a false
  positive; a comment that trails code on its line (`x = 1; # radius: 4`) is
  searched too. A hex color in a comment is a hit on purpose.
- The line of a hit is the line of the match; a declaration that spans lines
  (`border-radius:` on one, its value on the next) is judged by the first.
- Mermaid blocks (`%%{init: ...}%%` and `%%{initialize: ...}%%`, also with
  white space after the brace) are compared with the shared one without white
  space, so the key order counts. Theme settings given other than by an init
  block (front matter `config:`), directives other than init, and Mermaid
  shapes are not judged.
