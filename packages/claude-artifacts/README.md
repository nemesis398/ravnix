# claude-artifacts

Starts Claude Code with the Artifact tool switched on for one session. Bash,
carried over from Fedora's `bin-claude-artifacts` (AGENTS.md, rule 4): it
removes `CLAUDE_CODE_DISABLE_ARTIFACT` from the environment and passes
`--settings` that turn the three artifact skills on.

Installed on both hosts by `modules/common/scripts.nix`. `claude` is looked up
on the `PATH`.

The variable it undoes is set by the Claude Code module
(`modules/common/claude-code.nix`) for the login shell and the user manager,
as Fedora's `environment.d/80-claude-code.conf` did. It is deliberately not in
the settings' `env`: Claude Code applies that block to itself, and a launcher
cannot undo what it sets on itself from user settings.

## Personal values

None.

## Changes from the original

One: the secrets. On Fedora every shell held the MCP tokens, so this launcher
inherited them. Here only the `claude` function of the interactive shell adds
them (`modules/common/bash/secrets.bash`), and a command is not that function,
so the launcher runs `claude` through `with-secret-env`
(`packages/with-secret-env`), which reads the same table and exports the
tokens after the last read. Without a table, an unlocked vault or an `rbw`,
`claude` starts without them and a note says why.

shellcheck passes; `bashOptions = [ ]` (the script is one `exec`).

## Left out

Nothing.

## Tests

`tests/claude-artifacts.test.sh`, the check `bin-claude-artifacts`: `claude`
is a stand-in that prints its arguments, whether the variable is set and the
secrets it got; `rbw` is a stand-in with two items. Covers that the variable is
gone, that the settings JSON is valid and names the three skills, that every
argument passes through unchanged, and that the secrets of the table reach
`claude` and are no argument (one unreadable item sets none, a locked vault and
a missing table start `claude` with a note).

## Findings not fixed

- `claude` here is the first `claude` on the `PATH`. The interactive `claude`
  function pins the profile's binary by path (`modules/common/bash.nix`) so that
  a `~/.local/bin/claude` never gets the secrets; this launcher does not, and
  the tokens go to whatever `claude` comes first.
