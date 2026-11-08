# The workbench

What the server runs for you: herdr's server, aerc, iamb, khal and vdirsyncer,
Podman and the toolchains, a copy of your Nextcloud, and Claude Code's Remote
Control. `hosts/server` is the server shape that brings it along with the common
module. Everything personal is a typed option (`ravnix.nextcloud`,
`ravnix.mail`, `ravnix.calendar`, `ravnix.matrix.userId`,
`ravnix.server.remoteControlDir`), and no option holds a password: where one is
needed, the option names the Bitwarden item and rbw reads it when the unit runs.

The tests are in `tests/workbench/server.nix` (the check `workbench-server`) and
`tests/workbench/rbw.nix` (the check `workbench-rbw`: the vault, the SSH agent,
signing and the token helper, against the real rbw and a stand-in vault).

## The vault and the keys

The server's rbw logs in to the same Bitwarden account as the laptop's and sees
the whole vault. **Once you have run `ai-unlock` on the server, every process of
your account there, every agent and every session among them, can read every
item of the vault, and sign with every SSH key in it**, which logs in wherever
those keys open. That is the price of a server that works with the lid shut; a
second account with only the items the server needs would be the narrower
choice. rbw's agent runs on both hosts the same way (`modules/common/rbw.nix`):

- `rbw-agent.service`, a user unit from boot, holds the vault's key once it is
  unlocked and is your SSH agent: `SSH_AUTH_SOCK` is
  `$XDG_RUNTIME_DIR/rbw/ssh-agent-socket` in the shell and in the user manager,
  so a commit signs from a terminal, from Claude Code and from a user unit.
- **It locks 12 hours after each unlock**, by the clock, whatever used it in
  between: unlocking arms `rbw-relock.timer` for that moment (a calendar
  timer, so a suspend does not stretch it), and `rbw-relock.service` then runs
  `rbw lock` and says so in its journal (`journalctl --user -u rbw-relock`). If
  arming or locking fails, the journal says that too, and the unit fails. The
  cap guards against forgetting, not against an agent: any process of yours
  can stop the timer. rbw's own `lock_timeout` (an hour) would never run out here,
  because every read and every signature starts it again and the Nextcloud sync
  reads every five minutes. After the 12 hours the syncs stop with status 75
  and say the vault is locked, and nothing signs, until the next `ai-unlock`.
  `ravnix.rbw.lockAfter` (home-manager) changes the 12 hours.
- A locked agent asks nobody. It refuses an SSH signature, a token or a read at
  once, unless an `rbw` command waits on a terminal for the master password (as
  `ai-unlock` does). A commit or a unit fails instead of waiting for a prompt in
  a pane nobody looks at.
- `ravnix.secrets.gitTokens` gives git an HTTPS token for exactly one remote
  each (set it in the server's host module: the update timer pushes the private
  flake with the write token). Another repository, host, scheme or user gets
  nothing. A credential helper set for every URL in your git config is reset
  for that remote; one in a repository's `.git/config`, in `~/.gitconfig` or
  given with `-c` is not, and `store` there would write the token to
  `~/.git-credentials`. Configure none on a host with tokens.
- `ravnix.server.proxmoxUpdate` names the key the server's tools use for a
  Proxmox node, at `ssh <alias>`. The node takes it with a forced command only,
  in that user's `~/.ssh/authorized_keys` there:
  `command="/path/to/update-script",restrict ssh-ed25519 AAAA...`. ravnix does
  not configure the node; that line is yours to write.
- **Known gap, accepted (2026-11-08): the agent serves every SSH key in the
  vault, the Proxmox nodes' root keys among them.** While the vault is
  unlocked, any agent on the server can log in to a node as root,
  unrestricted, wherever the network lets the server reach it, and root on the
  hypervisor is root on the server's disk. The forced-command key restricts
  only itself. The same holds for every host a vault key opens, and for the
  vault's touch-free git keys, which Task 5.4's blocks keep away from the git
  host names but not from an alias, a trailing dot or an address. What would
  close it: a vault account for the server with fewer items, or a
  `from="!<server's addresses>,*"` on each node's root keys.
- ssh offers every key of the agent to every host it connects to, unless a
  block with `IdentitiesOnly` and the host's own public key says otherwise: a
  host whose key comes late refuses with "Too many authentication failures",
  and every server sees all your public keys. Pin a key for each host you use
  from here.
- The deploy keys are root's, on a security key (which rbw's agent cannot
  serve), and `ravnix.server.deployFrom` may name none of the server's own
  addresses (its NetBird address, a loopback address in any spelling; an
  assertion says so). Its LAN address is in no option: keep it out by hand.

## Units

All of them are user units of your account, which systemd keeps running without a
login (`users.users.<user>.linger`).

| Unit | What it does | Needs the vault |
| --- | --- | --- |
| `herdr-server.service` | herdr's server, from boot; a switch never restarts it | no |
| `nextcloud-sync.timer` | `nextcloudcmd` for each folder, hidden files included, every five minutes | yes |
| `vdirsyncer.timer` | the feeds, then discover, metasync and sync of calendars and contacts, every quarter hour | yes, except for the feeds |
| `claude-remote-control.service` | Remote Control, as the development VM before it had it | no |
| `rbw-agent.service` | rbw's agent and the SSH agent, locked from boot until `ai-unlock` | it is the vault |
| `rbw-relock.timer` | locks the vault 12 hours after each unlock, by the clock; made by the unlock, not at boot | it locks it |

## Steps by hand

These cannot be declared, because each one is a login or a secret.

1. **Unlock the vault** after every boot of the server (`ai-unlock`, in a
   terminal: over ssh or in a herdr pane). Until then nothing signs, and a unit
   that needs the vault stops, says that it is locked, and fails with status 75;
   it runs again at its next tick. The vault locks again 12 hours after each
   unlock (see above), so unlock it again then.
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
   a setup token does not work with Remote Control). The login makes
   `~/.claude/.credentials.json` and records in `~/.claude.json` that Claude Code
   had its first run (`hasCompletedOnboarding`); Remote Control needs both.
   Copying only `~/.claude/` from another machine is not enough, because
   `~/.claude.json` lives beside it in the home directory. And a `~/.claude.json`
   that merely exists is not enough either: ravnix itself makes one when it
   merges the MCP servers into it, and that file says nothing of a first run.
   Clone the repository named by `ravnix.server.remoteControlDir`, `cd` into it and
   run `claude` once to accept the folder: `claude remote-control` refuses a folder
   it does not trust, and the unit checks that `~/.claude.json` records the trust
   for exactly that repository (trust on a folder above it is not honored). A
   `~/.claude.json` copied from another machine has the trust for that machine's
   paths, so do this step again after such a copy. Then `systemctl --user start
   claude-remote-control`; it starts by itself at every boot after that. Until the
   login, the first run, the trusted folder and the repository exist, the unit is
   skipped, not restarted every half minute: `systemctl --user status
   claude-remote-control` and `journalctl --user -u claude-remote-control` say
   which is missing.

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
  terminal, and a unit has no such shell. The unit starts at boot, while the
  vault is still locked, so reading them at its start would find nothing
  either; token-backed MCP servers fail in those sessions. Left so (Task 4.3).
- After a reboot of the server, or 12 hours after the last unlock, nothing
  tells you that the vault waits for `ai-unlock` but the journal
  (`rbw-relock`, and the syncs' own lines): the syncs fail with status 75 and
  stall until you unlock, and a vault copy that does not sync is one the agents
  commit stale. A message to Matrix (Task 5.6) would reach the phone.
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

### The container form (Task 4.4)

`hosts/server/oci.nix` makes muninn an image for Docker; `tests/workbench/oci.md`
is the record.

- **Root in the container is root on the Docker host.** systemd needs
  `SYS_ADMIN` and Docker's AppArmor profile off, in the host's own user
  namespace. That is not fixed here. The narrower ways (rootless Podman with
  `--systemd=always`, Docker with `userns-remap`, an AppArmor profile that
  allows only the mounts stage 2 needs) are named in the compose files and
  none of them was tried.
- **Steps 2 and 3 of the task are open.** Round 1 ran a first image on a Docker
  host with stand-ins for what the image now does itself. Round 2 (the committed
  image, both compose files, a container made again, the cleanup proof) waits
  for the maintainer's go.
- The system came up `degraded` in round 1 because `systemd-machine-id-commit`
  timed out on a starved disk pool. It is plausibly not the image's fault, and
  in a container that unit only writes a layer the next swap discards, but it
  was not shown on a quiet pool.
- `tmpfs` on `/run` and its `exec` option, the health check turning `healthy`,
  and `/dev/net/tun` for the Podman file are reasoned, not observed.
- The Kubernetes manifests are validated against the schema with
  `kubeconform -strict` and never applied. A node on cgroup v1, or a runtime
  that ignores the image's `StopSignal`, does not stop the pod cleanly.
- `no_pivot_root` for Podman inside lets a container that Podman runs leave its
  chroot with the account's rights. In the container form run only images you
  trust.
- The list of the laptop's programs that the closure must not hold is written
  in four places (`workbench-oci`, `docker-checks.sh`, `workbench-server`,
  `workbench-optional`). One shared list means a change to the other two tests.
- `docker-checks.sh` is Bash, a record script piped over ssh into a container;
  it adds a key to the volume's `authorized_keys` and removes it again, and it
  refuses to run unless the container belongs to the project
  `ravnix-muninn-test`. It is not part of `nix flake check`.
- The image is 6.9 GB with one editor language, and grows by several GB with
  the template's other languages (Odin alone is 2.3 GB). A first `docker load`
  on a loaded NAS took half an hour.
