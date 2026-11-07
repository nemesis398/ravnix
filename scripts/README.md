# scripts

The local gate and the hooks around it. There is no CI, so these are the
only checks ravnix has; the reasons for each design choice are in the header
of each script.

| Script | Does |
| --- | --- |
| `check.sh` | the gate: `--fast` (boundary check, shellcheck) on every commit and stop, the full gate (adds `nix flake check`) before every push |
| `check-public.sh` | the public-boundary check: no deny-list value in any file, file name or link target |
| `lib/git-snapshot.sh` | lays out the index or a commit as plain files, for the checks to read what git will commit or push |
| `hooks/stop-gate.sh` | the Claude Code Stop hook: the fast gate before the agent may stop |
| `hooks/no-verify-guard.sh` | the Claude Code PreToolUse hook: refuses commands that skip or redirect the git hooks |
| `../.githooks/` | `pre-commit` (fast gate), `commit-msg` (boundary check on the message), `pre-push` (each pushed commit and message, then the full gate) |

Tests: `tests/*.test.sh` and `hooks/test.sh`, run by the flake check
`scripts-tests`.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- `check-public.sh` matches literals. It does not find a value that is
  compressed (a `.gz` file), encoded (base64, URL encoding), split across two
  lines, or written in another Unicode normal form (a decomposed `ö` against
  a composed entry).
- `check.sh` does not read untracked files: they are not part of any commit
  until staged, and pre-commit checks them then. A Stop hook therefore does
  not catch a value in a new file that was never staged.
- `check.sh` lays out the index with one `git cat-file` per file, which is
  fine for hundreds of files and slow for many thousands.
- The full gate runs `nix flake check` on the work tree (the tracked files
  with their work-tree contents), not on exactly the commits being pushed.
- `pre-push` checks only commits the remote's tracking refs do not have. When
  the deny list grows, older history is not checked again by itself; to check
  all of it, run `.githooks/pre-push` by hand with a URL as the remote name,
  which no tracking ref matches.
- `no-verify-guard.sh` reads the command text. It misses a command built at
  run time (an option held in a variable, base64, printf or `$'\x..'`
  escapes), a `$(...)` inside `${...}` or in the body of an unquoted heredoc,
  plumbing that makes commits without hooks (`git commit-tree`, `git
  update-ref`), `.git/config` edited by hand, and hooks deleted or made
  non-executable. It resolves git aliases from the configuration of the
  directory Claude Code runs it in. `pre-push` catches what such a commit
  would publish.
