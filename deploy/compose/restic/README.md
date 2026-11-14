# restic: the NAS's side of the backups

Every ravnix host backs its home up to the rest-server of
`docker-compose.yaml`, on the NAS, and to nothing else
(`modules/common/backup.nix`, `ravnix.backup.nas`). The NAS keeps one
repository per host in the shared folder `restic`, prunes each by the
retention file, and copies every host's snapshots into the one restic
repository on Internxt that the whole estate shares. No host has the
Internxt credential, and no host can delete anything on the NAS.

```
huginn ──┐  restic backup, append-only        NAS                       Internxt
         ├──────────────────────────────▶  /volume1/restic/HOST  ──copy──▶  estate repo
muninn ──┘  (LAN, or NetBird's route)        prune by nas policy          prune by internxt
                                                                         policy, --host HOST
```

What exists: the server (`docker-compose.yaml`), the host side, and
`ravnix-retention` (`tools/ravnix-retention`), which turns the retention
file into the flags of `restic forget`. What follows is the design of what
does not exist yet: the deploy (Step 5) and the two jobs on the NAS (Step 6).

## Deploy (Step 5)

1. **The share.** Make the UGOS shared folder `restic` and note its owner's
   uid and gid. Make `/volume1/docker/restic/` for the compose file, its
   `.env` (the variables in the compose file's header) and `htpasswd`,
   readable by that owner only.
2. **The logins.** One line per host, `HOST:BCRYPT`, with the password of the
   host's `loginItem` from Bitwarden: `htpasswd -B -i htpasswd HOST`, the
   password on standard input from `rbw get` on a machine that has the vault,
   never on a command line. With `--private-repos` the user name must be the
   first path segment of the host's `repository`.
3. **The repositories, on the NAS.** A host never runs `restic init`. Each
   host's repository is made beside the server, with the chunker parameters
   of the Internxt repository, so that `restic copy` deduplicates into it
   (below):

   ```sh
   restic init --repo /data/HOST --from-repo INTERNXT --copy-chunker-params
   ```

   with the host's repository password (its `passwordItem`) and the Internxt
   repository's password, both from the maintenance container's secrets.
4. **The server.** `docker compose up -d`. The NAS's firewall allows the port
   from the LAN and the NetBird range only; the router forwards nothing.
5. **Verify**, from each host, and record the output in the private flake:
   - `systemctl --user start ravnix-backup`, then `restic snapshots` on the
     NAS shows the host's snapshot with its `host` name;
   - a forget is refused: with the host's login,
     `restic -r REPOSITORY forget SNAPSHOT` fails (the server answers 403),
     and the snapshot is still listed;
   - another host's repository is refused: `restic -r
     rest:http://NAS:PORT/OTHER/ snapshots` with this host's login fails.

   `tests/common/backup.nix` shows all three against a rest-server with the
   compose file's flags, in the sandbox; the deploy shows them on the NAS.

## Pruning and the copy to Internxt (Step 6)

Both jobs run on the NAS, in one maintenance container, and open the
repositories in `/volume1/restic` directly, not through the rest-server,
which stays append-only: no endpoint on the network can delete.

**The image.** The NAS has no Nix, so the container is an image that Nix
builds with its whole closure (`dockerTools.buildLayeredImage`): restic and
rclone from ravnix's nixpkgs, `ravnix-retention`, and the private flake's
`backups.toml`, which a wrapper names in `RAVNIX_RETENTION_FILE`. The
private flake builds it, since the retention file is its own, from a
function ravnix exports, and the deploy loads it with `docker load` as the
muninn image is loaded. A change of the retention file is a new image. The
job's run logic, the per-host loop, the order below, the dry run and the
exit codes, is more than thin glue, so it is an Odin tool (AGENTS.md, rule
4), a subcommand beside `flags` or a tool of its own, with its tests.

**The secrets** stay on the NAS, in files the container reads, written by
the deploy from Bitwarden: each host's repository password, and the
Internxt repository's password and rclone remote (Internxt is reached
through rclone, as the estate's existing restic jobs reach it). No host
gets any of them.

**One run**, daily after the hosts' backup window (they back up at
`onCalendar` with up to 10 minutes of random delay), for each host the job
is configured with:

1. **Copy first.** `restic -r INTERNXT copy --from-repo /data/HOST --host
   HOST`. restic copies only the snapshots the destination lacks. Copying
   before the NAS prunes means a snapshot that Internxt keeps longer (12
   monthlies against the NAS's 6) has reached Internxt before the NAS lets
   it go, even after days in which the copy failed.
2. **Prune the NAS.** `restic -r /data/HOST forget --prune --retry-lock 30m
   $(ravnix-retention flags --target nas --host HOST)`. The flags carry
   `--host HOST --group-by host`; a wrong retention file gives no flags and
   a non-zero exit, and the job stops for that host before restic runs.
3. **Prune Internxt.** `restic -r INTERNXT forget --prune --retry-lock 30m
   $(ravnix-retention flags --target internxt --host HOST)`. `--host` keeps
   the forget to this host's snapshots in the shared repository. The prune
   that follows is repository-wide, which is safe: it removes only data no
   snapshot of any host refers to, and it takes restic's exclusive lock, so
   it waits for another machine's backup or copy that holds its lock.

Before the first real prune of each host and target, the job runs the same
command with `--dry-run` instead of `--prune`, and the output goes into the
private flake's deploy notes; only then is the real prune turned on.

**How a run reports.** Not decided: the NAS cannot run `ravnix-notify`
(it reads the Matrix token from rbw). Either the job writes a status file
that muninn reads over `ssh nas-admin` and posts to the `backups` room, or
it pings an Uptime Kuma push monitor. A host whose newest snapshot is older
than two days is the alarm either way.

### How a host's forget is refused

By the server, not by the host: `--append-only` refuses every DELETE and
every overwrite but a lock file's, so `restic forget` and `restic prune`
fail with 403 whatever the host runs, and its own unit runs neither.
Only the NAS's maintenance container, which opens `/volume1/restic`
directly, can delete. What the host can still do: add rubbish (disk space),
remove lock files, which can make a running prune notice its lock is gone
and stop, and read its own repository.

### Checking the chunker parameters

`restic copy` deduplicates only between repositories with the same chunker
polynomial; with different ones it still copies, but every snapshot is
stored again in full. Each NAS repository is made with
`--copy-chunker-params` from the Internxt repository (Deploy, 3). Before the
first copy, and in the job before each, compare:

```sh
restic -r INTERNXT cat config --json | jq -r .chunker_polynomial
restic -r /data/HOST cat config --json | jq -r .chunker_polynomial
```

They must be equal; the job refuses to copy a host whose polynomial
differs, and says so. A repository made with other parameters cannot be
changed: make a new one with the right ones and `restic copy` the old one
into it, or start fresh.

## Open points

- **The estate's other jobs on the Internxt repository** must prune with
  `--host` too. A forget without it, from the estate's existing restic job,
  would apply that job's policy to huginn's and muninn's snapshots. Check
  the existing jobs' commands before the first copy.
- **A locked vault means no backup.** The host's run reads both secrets
  through rbw, so it fails with status 75 while the vault is locked and
  tries again every 30 minutes. On muninn the vault locks 12 hours after
  each unlock (`ravnix.rbw.lockAfter`), so muninn backs up only on days
  someone runs `ai-unlock` there. The alarm above shows it.
- **Plain HTTP on the LAN.** The data is encrypted by restic, and the logins
  open only append-only repositories, but a login can be read on the LAN.
  rest-server takes `--tls` with a certificate if that matters.
- **The image digest.** The compose file pins the tag; pin the digest at
  deploy time.
