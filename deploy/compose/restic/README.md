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

The hosts find the server through the service registry, as they find the
Nix cache and builder: `ravnix.services.restic-server = { enable = true;
host = "<the NAS in ravnix.hosts>"; port = <RESTIC_PORT>; }`. A host's
repository is derived from it, `rest:<url>/<host>/`, so a new address of
the NAS is a change of one line.

**One name per host.** `ravnix.backup.nas.host` is the name the snapshots
carry, the repository's path (`/volume1/restic/HOST`), the login's user in
`htpasswd`, the retention file's `[targets.<target>.hosts.<host>]`, and the
`--host` of every job below. The module derives the path and the user from
it, so they cannot differ; it refuses a name that `ravnix.hosts` gives to
a machine that is not a ravnix host, such as the NAS, which may back
itself up under its own name into the same Internxt repository.

What exists: the server (`docker-compose.yaml`), the host side, and
`ravnix-retention` (`tools/ravnix-retention`), which turns the retention
file into the flags of `restic forget`. What follows is the design of what
does not exist yet: the deploy (Step 5) and the two jobs on the NAS (Step 6).

## Deploy (Step 5)

1. **The share.** Make the UGOS shared folder `restic` and note its owner's
   uid and gid. Make `/volume1/docker/restic/` for the compose file, its
   `.env` (the variables in the compose file's header) and `htpasswd`,
   readable by that owner only.
2. **The logins.** One line per host, `HOST:BCRYPT`, where `HOST` is the
   host's `ravnix.backup.nas.host` and the password is its `loginItem`'s
   from Bitwarden: `htpasswd -B -i htpasswd HOST`, the password on standard
   input from `rbw get` on a machine that has the vault, never on a command
   line. With `--private-repos` the user reaches only `/HOST/`, the path the
   module derives.
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
5. **The root-only file, on each host with `secrets = "file"`** (muninn).
   The two secrets are in a file only root can read, written once from the
   password manager, without a secret in a command line, the environment
   or the shell's history. The command writes the file only when both
   items gave a password, each on its own line; a locked vault, an item
   rbw cannot get or one without a password leave the old file as it was:

   ```sh
   rbw unlock && sudo -v && (
     set -euo pipefail
     f=/var/lib/ravnix/backup-secrets
     sudo install -d -m 700 -- "$(dirname -- "$f")"
     trap 'sudo rm -f -- "$f.new"' EXIT
     { printf 'repository='; rbw get -- "<passwordItem>"
       printf 'login='; rbw get -- "<loginItem>"; } |
       sudo install -m 600 /dev/stdin "$f.new"
     sudo awk 'NR == 1 && /^repository=./ { r = 1 }
       NR == 2 && /^login=./ { l = 1 }
       END { exit !(NR == 2 && r && l) }' "$f.new"
     sudo mv -f -- "$f.new" "$f"
   )
   ```

   This is a deliberate exception to secrets from rbw at runtime, the same
   as the Nix builder's key (`ravnix.nixBuilder.sshKey`): the backup runs
   unattended while rbw is locked, so the secrets have to be on disk. The
   system unit `ravnix-backup` refuses the file unless it is root's and
   mode 600, loads it as a systemd credential, and runs the backup under a
   UID of its own (`DynamicUser=`) that reads the home through
   `CAP_DAC_READ_SEARCH` alone, so the login user's processes, agents
   among them, cannot read the file or the credential.

   On muninn's container shape only `/home` outlives an image swap, and
   the default `/var/lib/ravnix/backup-secrets` is gone with every new
   image: set `secretsFile` in a directory of root's beside the home, as
   sshd's host key is (`/home/.muninn-ssh`), for example
   `/home/.ravnix/backup-secrets`, and run the command with that path in
   `f`. `ravnix.backup.nas.secretsFile` has the rest.
6. **Verify**, from each host, and record the output in the private flake:
   - `systemctl --user start ravnix-backup` (with rbw) or `sudo systemctl
     start ravnix-backup` (with the file), then `restic snapshots` on the
     NAS shows the host's snapshot with its `host` name;
   - a forget is refused: with the host's login,
     `restic -r REPOSITORY forget SNAPSHOT` fails (the server answers 403),
     and the snapshot is still listed;
   - another host's repository is refused: `restic -r
     rest:http://NAS:PORT/OTHER/ snapshots` with this host's login fails.

   `tests/common/backup.nix` shows all three against a rest-server with the
   compose file's flags, in the sandbox; the deploy shows them on the NAS.
7. **Before the job's first run for a host**, look in the Internxt
   repository for snapshots under its name: `restic -r INTERNXT snapshots
   --host HOST`. None: the ledger starts empty. Some, as an older setup
   that backed machines up to Internxt directly, which ravnix replaces,
   may have left: the job refuses to start for the host until one of these
   is done, by hand and decided by the owner:
   - **adopt them**, when they are this machine's own older backups: put
     their ids into the ledger (`restic -r INTERNXT snapshots --host HOST
     --json | jq -r '.[].id'`). From then on the Internxt prune thins them
     with the new ones as one group (`--group-by host`); run it with
     `--dry-run` first and record what it would delete;
   - **forget them**, by id, after a `--dry-run`, when they are not worth
     keeping;
   - **give the host another name**, when they belong to someone else:
     `ravnix.backup.nas.host` with `ignoreHostName = true`, and that name
     in the retention file, `htpasswd` and the job's list.

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

**The hosts it knows.** The job is configured with the list of host
names, and refuses to start, naming the problem, when:

- a name is in the list twice: two machines under one name would be
  pruned as one group, `--group-by host`, and one machine's dailies would
  push out the other's;
- a name is one of the estate's own: a name that another job backs up
  under into the Internxt repository, the NAS's own host name among them
  (the estate's offsite job forgets with `--host <the NAS's name>
  --group-by host`). The private flake lists those names beside the hosts,
  and the job checks the list against them before every run;
- a name has snapshots in the Internxt repository that this job did not
  copy: another machine is using it. "Did not copy" is read from a ledger,
  not from the NAS repository: one file per host,
  `/volume1/docker/restic/state/copied/HOST`, beside the job's secrets and
  outside what the rest-server serves, with the Internxt id of every
  snapshot the job has copied there. Every Internxt snapshot of
  `restic snapshots --host HOST` must be in it, or have as its `original`
  the id of a snapshot that is still in `/data/HOST`. The second is a copy
  of the host's own that a run made and did not get to record, because it
  stopped between the copy and the ledger write; without it, one such stop
  would refuse the host for good. The next run's ledger write records it.

  Why a ledger. Internxt keeps snapshots the NAS has already let go (12
  monthlies and 2 yearlies against the NAS's 6 and 0), so after about half
  a year a comparison with the NAS repository's ids would take the host's
  own old monthlies for another machine's and stop its copy and prune for
  good. A comparison only with snapshots newer than the host's oldest on
  the NAS would not, but it would miss exactly the snapshots that matter:
  another machine's, or an older setup's, from before that date, and it
  hangs on snapshot times that each host's clock sets. The ledger is exact.
  Its cost is state. The job writes it right after each copy, before
  anything is pruned, as exactly this set: the old ledger, plus this run's
  copies (the ids of the Internxt snapshots whose `original` is a snapshot
  of `/data/HOST`), minus the ids that `restic snapshots --host HOST` on
  Internxt no longer lists, because the Internxt prune has forgotten them.
  Nothing else enters it, and nothing else leaves it: an id that Internxt
  still lists stays, after the NAS has let its original go. It goes to a
  new file that is renamed over the old one, so a stop leaves the old
  ledger or the new one and never half of one. A lost ledger makes every snapshot look foreign, so the job
  refuses, loudly, until it is rebuilt the way the first run below makes
  it.

**One run**, daily after the hosts' backup window (they back up at
`onCalendar` with up to 10 minutes of random delay), for each host the job
is configured with:

1. **Copy first.** `restic -r INTERNXT copy --from-repo /data/HOST --host
   HOST`. restic copies only the snapshots the destination lacks. Copying
   before the NAS prunes means a snapshot that Internxt keeps longer (12
   monthlies against the NAS's 6) has reached Internxt before the NAS lets
   it go, even after days in which the copy failed. Then the ledger write
   (above), and only after it a prune.
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
that muninn reads over ssh, at the NAS's `sshTarget` in `ravnix.hosts`, and
posts to the `backups` room, or
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

- **The ledger is state.** It must survive like the job's secrets; the
  NAS's own backup should hold `/volume1/docker/restic/state`. Losing it
  stops the job, never deletes anything.
- **A host name in two places.** Each host's evaluation sees only its own
  `ravnix.backup.nas.host`, so the module cannot see that two hosts chose
  one name; the job's checks above can, and the template says to set the
  value per host, never in me.nix.
- **The estate's other jobs on the Internxt repository** must prune with
  `--host` too. A forget without it, from the estate's existing restic job,
  would apply that job's policy to huginn's and muninn's snapshots. Check
  the existing jobs' commands before the first copy.
- **A locked vault means no backup, where the secrets come from rbw.** A
  host with `ravnix.backup.nas.secrets = "rbw"` (the laptop) fails with
  status 75 while its vault is locked and tries again every 30 minutes.
  The server cannot wait for that: its vault locks 12 hours after each
  unlock (`ravnix.rbw.lockAfter`). So muninn uses `secrets = "file"`, the
  root-only file below, and backs up every day.
- **Plain HTTP on the LAN.** The data is encrypted by restic, and the logins
  open only append-only repositories, but a login can be read on the LAN.
  rest-server takes `--tls` with a certificate if that matters.
- **The image digest.** The compose file pins the tag; pin the digest at
  deploy time.
