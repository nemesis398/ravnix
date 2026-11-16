# atuin-root-login

Logs root in to the atuin account the user is logged in to, so root's shell
history goes into the same shared timeline. Bash, thin glue around `rbw`,
`sudo` and `atuin`.

```
atuin-root-login ITEM
```

`ITEM` is the name or id of the Bitwarden item that holds the account: the
username, the password, and the recovery key (the words of `atuin key`) alone
in the notes. Run it as the user, in a terminal, with the vault unlocked. The
laptop installs it (`hosts/laptop/atuin-root.nix`); the install guide has the
step (`docs/install-from-another-distro.md`).

## Why it is a helper

Root has no rbw vault, and the login is state with secrets, so the flake cannot
do it. The user reads the three fields, and the root half of the script, which
`sudo` starts by its store path with `--as-root`, takes them from a pipe.

## What it keeps out of reach

- **A command line.** The password reaches atuin on its standard input (`-p -`)
  and the recovery key in `ATUIN_ENCRYPTION_KEY`, set for that one command.
  `rbw`, `sudo` and `atuin` get no secret as an argument. The account's name is
  on atuin's command line: it is a name, not a secret.
- **A file.** Nothing is written but atuin's own key file under `/root`.
- **Any other process's environment.** The values are shell variables and a
  pipe; `sudo`'s environment holds none.
- **A trace or an error.** The script turns tracing off first, whatever
  `bash -x`, `SHELLOPTS` or `PS4` say. `rbw`'s stderr is thrown away, and a
  refusal names the field, never its content.

A field that is empty, or has more than one line, is refused before `sudo`
runs.

## Tests

`tests/atuin-root-login.test.sh`, the check `bin-atuin-root-login`. `rbw`,
`sudo` and `id` are stand-ins, and `atuin` is a stand-in built into the
package's `PATH`, so no vault, no root and no server are involved. The tests
look for the password and the key on every command line, in the environment of
`sudo` and of atuin, in files, in output and under `bash -x`; they feed values
that look like options or shell syntax; they break each step (a locked vault, a
missing `rbw`, a field `rbw` cannot read, an empty field, two lines, a failing
`sudo`, a failing login, a failing sync, a root half started by a normal user,
a short input); and one test runs the real atuin, against a closed port, to show
that it reads the password from `-p -` and the key from the environment.

## Findings that are not fixed

- `-p -` (the password from the standard input) and `ATUIN_ENCRYPTION_KEY` are
  atuin 18.x. An older atuin would take `-` as the password. The test with the
  real atuin fails then, at the flake bump that brings the older one.
- `rbw get` has no timeout of its own. If the vault wants a master password and
  no pinentry can show, the helper waits for it; the unlocked check before it
  makes that rare.
- If the login succeeds and the first `atuin sync` fails (the server is not
  reachable), the helper exits with sync's status although root is logged in.
  Running it again says so and syncs.
- A notes field with the key and anything else is refused (more than one line);
  the helper does not guess which line is the key.
