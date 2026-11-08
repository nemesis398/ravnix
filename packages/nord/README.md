# nord

NordVPN as a plain NetworkManager WireGuard (NordLynx) profile, with no Nord
app and no daemon: `nord [status|up|down|toggle|refresh|setup]`. It is the
script of the Fedora laptop, `nord.bash`, packaged with
`writeShellApplication`, so shellcheck ran over it at build time. Its header
holds the reasoning for every setting of the profile (why not the official
app, how it coexists with NetBird, the routing rule, the DNS routing domain,
the firewall mark).

## What differs from the Fedora script

- **The personal values are baked in.** `COUNTRY_ID`, `TOKEN_ITEM` and
  `KEY_ITEM` come from `ravnix.vpn.nord` (`countryId`, `tokenItem`, `keyItem`)
  through the package arguments of the same names, and `NORD_COUNTRY_ID`,
  `NORD_TOKEN_ITEM` and `NORD_KEY_ITEM` in the environment win. Built with
  none of them, the command works from the environment alone, and says which
  option to set when a value it needs is missing.
- **The access token is no longer on a command line.** `setup` passed it to
  curl as `-u token:...`, where any user of the machine could read it from
  `/proc` for the second the call took. It now reaches curl as a config line on
  standard input (`-K -`), as `vpn-home` does.
- A key item that is not named skips the copy to Bitwarden with a message
  instead of calling `rbw add` with an empty name.
- **`setup` files the key whatever editor the session names.** rbw asks
  `$VISUAL` before `$EDITOR` (1.15.0, `src/edit.rs`), and ravnix exports
  `VISUAL=nvim`; the script set only `EDITOR`, so on huginn `rbw add` would
  have opened nvim on a terminal that `>/dev/null 2>&1` hides, and `setup`
  would have hung there. It now sets both to a copy command, and quotes the
  path for the `/bin/sh -c` that rbw runs an editor with a space in it
  through, so a cache directory with a space in its name works too. The
  stand-in rbw picks `$VISUAL` before `$EDITOR` the same way, and the VM
  runs `setup` with `VISUAL` set, so a regression fails both.
- **`up` and `down` no longer fail for want of a notification daemon.** The
  Fedora script ended `down` with a bare `notify-send`, so over SSH, with no
  daemon, `down` took the tunnel down, printed nothing and exited 1.
  `notify` now ignores a failing `notify-send`, and `down` prints.
- `tr -d '\\'` is `tr -d '\134'`: the same backslash, and shellcheck
  (SC1003) reads it right.
- The comments that named people, hosts and domains of the author's setup are
  worded in general terms.
- The script keeps its own `set -uo pipefail`, without errexit, as it had
  (`bashOptions = [ ]`): its functions test commands and carry on.

## Tests

`tests/desktop/printing.nix` (the check `desktop-printing`) runs
`tests/desktop/helpers/wrappers.test.bash` against stand-ins for nmcli, curl,
rbw and notify-send that record what they are called with: every subcommand,
the API answering nothing, an empty list, garbage, a server without WireGuard
and a dead API; a locked vault; a refused import; a profile that cannot be
finished; the key and the token on no command line and in no file left
behind; the imported profile taken down before it is changed. The same check's
VM runs `nord setup`, `status`, `up` and `down` against the real
NetworkManager with a stand-in for Nord's API, and reads back every property
of the profile, the key file's mode, the `wg-nord` interface, its firewall
mark and NetBird's mark rule (priority 120, `fwmark 0x1bd00`, table `main`).

## Findings that are not fixed

- With NetworkManager not running, `nmcli` fails, `status` says "no profile
  yet (run: nord setup)", and `setup` would go on to fail at the import with
  "NM refused the import". Both are true to the script's tests and wrong in
  their words; the cause is in `nmcli`'s own message above them.
- `setup` writes the WireGuard key to a 0600 file in a fresh directory under
  `$XDG_CACHE_HOME` (disk, not RAM, on purpose) and removes it at once. A kill
  with SIGKILL, or a power cut, between the two leaves it there: the EXIT trap
  cannot run. Remove `~/.cache/tmp.*` by hand after such an interruption.
- `setup` is for a terminal. When standard input is not one, rbw 1.15.0 reads
  the new item from standard input and starts no editor, so the copy of the
  key to Bitwarden would not be what `setup` meant to file (or would fail,
  with the message that the profile has the key). Run `setup` in a terminal.
- `rbw add` has no update: a second `setup` (after the profile was deleted)
  files a second item under the same name.
- `refresh`, `up` and `down` do not lock. Two at once race on `nmcli
  connection modify`; the last one wins. It is one user on one machine.
- Nord's `users/services/credentials` endpoint is, in the script's own words,
  tolerated and not documented for manual use. If Nord removes it, `setup`
  stops working; a profile that exists keeps working, because the key is in
  NetworkManager.
- The Nord API itself is never called by the tests; a real `nord setup` and a
  real `nord up` on huginn are for the maintainer to run (Task 3.6, Step 5 of the plan).
