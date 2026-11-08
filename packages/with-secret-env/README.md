# with-secret-env

Runs a command with the secrets of `ravnix.shell.secretEnv` in its environment
and in nobody else's. Bash, written for ravnix. It is the one loader of the
launchers: `claude-artifacts` and `claude-bg` carry it. It is not installed for
the user.

```
with-secret-env [--table FILE] [--report] [--] COMMAND [ARGS...]
```

## What it does

The table is `~/.config/ravnix/secret-env` (`--table`, else
`$RAVNIX_SECRET_ENV`, else `$XDG_CONFIG_HOME/ravnix/secret-env`), which the
module writes from `ravnix.shell.secretEnv`: one `NAME=item` line per secret,
the item being the name or id of a Bitwarden item, never a value. Each item is
read with `rbw get`, one child process each. The values are kept in shell
variables until the last read is done, then exported at once, and the command
is started with `exec`.

## What it keeps out of reach

- **A command line.** A value is passed by `export`, a builtin; `ps` does not
  show it. Nothing is ever put in an argument.
- **Any process but the command.** Nothing is exported before the last read, so
  no `rbw` child carries the values read before it. That is the rule of the
  interactive `claude` function (`modules/common/bash/secrets.bash`) too.
- **A log or a trace.** The script turns tracing off first, whatever `bash -x`,
  `SHELLOPTS` or `PS4` say, and never prints a value. What `rbw` writes to
  stderr is thrown away, so a failing `rbw` cannot spill one.
- **A password prompt.** It never asks for one, so a launcher in a script does
  not stop at a prompt. `ai-unlock` unlocks the vault first.

## All or nothing

If one item cannot be read, none of the secrets is exported: the command starts
without them and the note names the item. An item with an empty value is not a
secret; it is named and left unset, and the others are set. A vault that is
locked, an `rbw` that is not installed and a table that is not there are not
errors either: the command starts without the secrets and the note says why.
An empty table is silent: that is a choice (no `secretEnv`).

This differs from the interactive `claude` function in one respect. The
function sets the secrets it could read and names the others; this helper sets
none when one fails. A launcher that starts without a token fails visibly (the
MCP server reports an authentication error), one that starts with some does
too, and "all or nothing" is the rule that is easiest to state and to test.
If the two should agree, the function is the one to change.

## `--report`

Puts two variables into the command's environment, names only:
`WITH_SECRET_ENV_LOADED`, the names that were set, or `WITH_SECRET_ENV_WHY`,
why none was. `claude-bg` uses them to compare the tokens with a running
service.

## Tests

`tests/with-secret-env.test.sh`, the check `bin-with-secret-env`: `rbw` and the
command are stand-ins. Covers that every secret reaches the command byte for
byte (spaces, `=`, `$`, a backtick, a quote, newlines inside, at the start and
as a blank line; values that start with a dash: `-n`, `-e`, `--`, a lone `-`
and one that looks like the helper's own option), that no `rbw` child
sees one, that no value is on a command line, in the output, in the log or in a
trace (`bash -x`, `SHELLOPTS=xtrace`), that one failed read sets none, that
`rbw`'s stderr is not passed on, the empty item, the locked vault (never
prompted for), a missing `rbw`, a missing, empty or messy table, three hundred
secrets, where the table is looked for, `--report`, argument pass-through and
exit status, and the usage errors.

## Findings not fixed

- A name in the table is not checked against the names the shell, the loader
  and ravnix's own tools read (`PATH`, `LD_*`, `BASH*`, and the families of the
  tools such as `CLAUDE_BG_*` and `WITH_SECRET_ENV_*`).
  `ravnix.shell.secretEnv` refuses them, and the table is the user's own file;
  the helper trusts it.
- The newlines at the end of a value are dropped: `rbw get` ends its output
  with one, and the shell's command substitution cannot tell it from the
  secret's own. A secret that ends in a newline reaches the command without it.
