# The workbench

What the server runs for you: herdr's server, aerc, iamb, khal and vdirsyncer,
Podman and the toolchains, a copy of your Nextcloud, and Claude Code's Remote
Control. `hosts/server` is the server shape that brings it along with the common
module. Everything personal is a typed option (`ravnix.nextcloud`,
`ravnix.mail`, `ravnix.calendar`, `ravnix.matrix.userId`,
`ravnix.server.remoteControlDir`), and no option holds a password: where one is
needed, the option names the Bitwarden item and rbw reads it when the unit runs.

The tests are in `tests/workbench/server.nix` (the check `workbench-server`).

## Units

All of them are user units of your account, which systemd keeps running without a
login (`users.users.<user>.linger`).

| Unit | What it does | Needs the vault |
| --- | --- | --- |
| `herdr-server.service` | herdr's server, from boot; a switch never restarts it | no |
| `nextcloud-sync.timer` | `nextcloudcmd` for each folder, hidden files included, every five minutes | yes |
| `vdirsyncer.timer` | the feeds, then discover, metasync and sync of calendars and contacts, every quarter hour | yes, except for the feeds |
| `claude-remote-control.service` | Remote Control, as the development VM before it had it | no |

## Steps by hand

These cannot be declared, because each one is a login or a secret.

1. **Unlock the vault** after every boot of the server and every time rbw locks
   (`ai-unlock`). A unit that needs it and finds it locked stops, says that the
   vault is locked, and fails with status 75; it runs again at its next tick.
   How long the vault stays unlocked is rbw's `lock_timeout`, one hour unless
   something sets it. Until Task 4.3 decides that, sync stops an hour after the
   last unlock.
2. **Nextcloud and the calendar.** Make an app password in Nextcloud (Settings,
   Security, Create new app password) and put it into the vault as the item that
   `passwordItem` names. The first run of `nextcloud-sync` copies the whole of
   each folder, hidden files included (`.git` directories are left out); start
   it once by hand to watch it
   (`systemctl --user start nextcloud-sync`, `journalctl --user -u nextcloud-sync`).
   khal works after the first calendar sync that found the vault unlocked
   (`systemctl --user start vdirsyncer`): until then its default calendar does
   not exist and it says so. The feeds are copied before the vault is asked,
   so they arrive even while it is locked.
3. **iamb.** Run `iamb` once. It asks for the password of `ravnix.matrix.userId`
   in the terminal, logs in, and keeps the session in `~/.local/share/iamb`. It
   cannot read a password from a command.
4. **Remote Control.** Run `claude auth login` and choose claude.ai (an API key or
   a setup token does not work with Remote Control). The login makes both
   `~/.claude/.credentials.json` and `~/.claude.json`, and Remote Control needs
   both: copying only `~/.claude/` from another machine is not enough, because
   `~/.claude.json` lives beside it in the home directory. Clone the repository
   named by `ravnix.server.remoteControlDir`, `cd` into it and run `claude` once
   to accept the folder. Then `systemctl --user start claude-remote-control`; it
   starts by itself at every boot after that. Until the login, the state file and
   the repository exist, the unit is skipped with a failed condition
   (`systemctl --user status claude-remote-control` says which), not restarted
   every half minute.

## Updating

- **herdr** is updated by a flake bump on its own. A switch leaves the running
  server alone, because restarting it restarts every pane. `herdr status server`
  says `server_binary_stale` when the installed herdr is newer; restart on
  purpose with `systemctl --user restart herdr-server` (the agents are resumed).
- **Claude Code** reaches Remote Control when it restarts
  (`systemctl --user restart claude-remote-control`), because the unit runs
  `claude` through your profile and its text does not change.

## Findings that are not fixed

- Remote Control sessions started from the phone do not get the tokens of
  `ravnix.shell.secretEnv`: those are read by the `claude` shell function in a
  terminal, and a unit has no such shell. Task 4.3 (secrets on the server) has to
  decide how a unit gets them.
- The Remote Control unit is not rolled by `claude-roll` (it is not a herdr pane),
  so Task 6.1 must restart it after a Claude Code update.
- herdr's notifications are set to `terminal` (ask the terminal that is attached);
  with nobody attached nothing is shown. What must reach the phone goes to Matrix
  (Task 5.6).
- The sync excludes `.git` directories with the client's exclude list, and since
  hidden files are synced (`-h`) that list is the only thing that keeps a `.git`
  out of the copy. That the anchored pattern `.git` matches at every depth (a
  repository below the synced folder, not only at its top) was read from the
  client's source and is still unverified against a real server; the test VM
  has none. The test runs the real client with the unit's command line, but
  only as far as the connection it cannot make.
