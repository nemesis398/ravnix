# claude-bg

Starts a background Claude Code session (`claude --bg`) that has its MCP
tokens. Bash, carried over from Fedora's `bin-claude-bg` (AGENTS.md, rule 4).

Installed on both hosts by `modules/common/scripts.nix`. `claude` and `rbw`
are looked up on the `PATH`: the `claude` that runs is the first one on it. That
is the profile's, which the gate verified against Anthropic's release manifest,
unless something precedes it on the `PATH` (see "Findings not fixed").

## Personal values

None are built in. The tokens come from a table of `NAME=item` lines,
`~/.config/ravnix/secret-env` (or `CLAUDE_BG_SECRETS`), which the module
writes from `ravnix.shell.secretEnv`. The item is the name or id of the
Bitwarden item. `with-secret-env` (`packages/with-secret-env`) reads each with
`rbw get` when the session starts and exports the values after the last read,
by a builtin, so they are on no command line and in no file. A line that is not
`NAME=item` is not part of the table. If one item cannot be read, none of the
tokens is set (all or nothing); an empty item is named and skipped.

`claude-bg` runs in two stages in one file: the first makes sure `rbw` is
unlocked (it may ask for the master password, which `with-secret-env` never
does), the second is the same script started by `with-secret-env`, so that the
tokens are in its environment when it compares them with the running service
and starts the session.

## Changes from the original

- the secrets: Fedora sourced `~/.config/ai-secrets.env`, a file of values.
  Sourcing a file a human wrote runs its tail as commands, and a value would
  sit in a file. The table of items replaces it, and a helper reads it: Fedora
  exported each token as it was read, so later `rbw` children carried the
  earlier ones; the helper exports after the last read;
- the comments about the earlier routing shim are neutral.

shellcheck passes without a change; `bashOptions = [ ]`.

## Left out

Nothing.

## Tests

`tests/claude-bg.test.sh`, the check `bin-claude-bg`: `claude` and `rbw` are
stand-ins, `/proc` is a fake tree (`CLAUDE_BG_PROC`). Covers that no `rbw` child
sees a token and that one unreadable item sets none, the supervisor
(none, one with every token, one lacking or holding an older token, which is
restarted with its workers kept; look-alike processes are left alone; a failed
stop is reported), a locked vault and a refused unlock, the secret table (a
missing one, items read by name, an unreadable item, comments and malformed
lines, an item name with an equals sign, an empty table, an empty value), a
token that starts with a dash or holds a newline (compared with the
supervisor's environment byte for byte), and a missing `claude`.

## Findings not fixed

- `claude` here is the first `claude` on the `PATH`, not the profile's binary
  by path as the interactive `claude` function has it
  (`modules/common/bash.nix`). A `~/.local/bin/claude` ahead of the profile on
  the `PATH` would be started, with the tokens.
