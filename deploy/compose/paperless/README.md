# paperless: the household's documents, on the NAS

Paperless-ngx for the whole household, from `docker-compose.yaml`, on the
NAS beside restic. Each person signs in through Authelia and sees their own
documents and the household's. A file dropped into a person's `Eingang`
folder becomes a document that person owns, OCRed in German and English.
Each night the export goes into the export folder, which restic-offsite
carries off-site, and each person's filed documents are copied into their
`Archiv` folder.

```
NAS personal folder                    Paperless (this project)                  NAS personal folder
<home>/Paperless/Eingang ──mount──▶  webserver: consume/<owner>  ─▶ media ──archive-copy 03:30──▶ <home>/Paperless/Archiv
                                     (a workflow sets the owner)       │
                                                                       └──exporter 02:30──▶ export/ ──restic-offsite──▶ off-site
```

This file holds no person. The private repository holds the people: the
override `paperless.override.yaml` mounts one `Eingang` and one `Archiv`
per owner, the household's `haushalt` among them. `ravnix-paperless-setup`
(`packages/ravnix-paperless-setup`) makes the group, the household user
and the workflows that set each document's owner from its folder.

## The services

| Service | Image | Does |
| --- | --- | --- |
| `webserver` | `ghcr.io/paperless-ngx/paperless-ngx`, nixpkgs' version | the web UI and the API, the consumer and the task workers; the only published port |
| `db` | `docker.io/library/postgres:18.x` | the database, in `PAPERLESS_DATA_DIR/db` |
| `broker` | `docker.io/library/redis:8.x` | the task queue, in `PAPERLESS_DATA_DIR/redis` |
| `exporter` | the Paperless image | `document_exporter` into `export/`, daily at 02:30 Europe/Berlin |
| `archive-copy` | `ravnix-paperless-copy-image`, tag from `.env` | the `Archiv` copy, daily at 03:30 (`packages/ravnix-paperless-copy`) |

The check `deploy-paperless-compose` (`tests/deploy/paperless-compose.nix`)
holds the file to this: the tags, the one port, the settings, the OIDC
provider, the hardening below, and that every required variable stops
`docker compose` with a message. It also runs the exporter's loop against
stubs.

### Running as the Paperless account, with no capabilities

Every service runs as `PAPERLESS_UID:PAPERLESS_GID`, the NAS account that
owns `PAPERLESS_DATA_DIR`, with `cap_drop: ALL` and `no-new-privileges`.
None keeps a capability:

- **webserver and exporter**: the image's rootless mode (`user:` set,
  Paperless-ngx docs, *Setup*, "Rootless"). It starts as that user and
  never changes user, so it needs neither `SETUID` nor `CHOWN`. This
  replaces `USERMAP_UID`/`USERMAP_GID`, which only work when the container
  starts as root, and it is why `PAPERLESS_OCR_LANGUAGES` stays unset: that
  setting installs packages at start, which a rootless container cannot do
  (`deu` and `eng` ship in the image).
- **db**: the Debian Postgres image runs as any user that owns its data
  directory, faking the passwd entry initdb needs.
- **broker**: the Redis image runs as any user that owns `/data`.

The port inside is 8000, so no `NET_BIND_SERVICE` either. A smoke run on
2026-11-20 (Podman 5.8, rootless, the pinned images) showed all four
Paperless-side services up with empty capability sets and `NoNewPrivs: 1`,
the migrations done, a German test page consumed with its umlauts in the
OCR text, an export written, the login page offering Authelia, and no
route out of the `backend` network from `db`.

Only `archive-copy` has a read-only root. The other images write below
their root at start (s6-overlay's `/run`, Postgres's socket directory), and
a read-only root for them is not tried yet (see *Open findings*).

### Networks

`db` and `broker` are only on `backend`, an internal network without a
route out. `webserver` and `exporter` are on it and on `default`: the
webserver talks to Authelia, the exporter pushes to Kuma. `archive-copy`
is only on `default`, for its push.

## Sign-in

OIDC through Authelia with django-allauth's `openid_connect` provider, as
the Paperless-ngx docs set it up (*Configuration*,
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` and `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS`;
*Advanced usage*, "OpenID Connect and social authentication"). The JSON in
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` has this shape, with the secret and the
server URL from `.env`:

```json
{"openid_connect": {
  "SCOPE": ["openid", "profile", "email", "groups"],
  "OAUTH_PKCE_ENABLED": true,
  "APPS": [{"provider_id": "authelia", "name": "Authelia", "client_id": "paperless",
            "secret": "<PAPERLESS_OIDC_CLIENT_SECRET>",
            "settings": {"server_url": "<PAPERLESS_OIDC_SERVER_URL>",
                         "oauth_pkce_enabled": true,
                         "token_auth_method": "client_secret_basic"}}]}}
```

`SCOPE` asks for `groups` as well, which nothing here reads (see the group
sync below) and which costs nothing. PKCE (set for
the provider and for the app, both of which allauth 65.16, the version
3.3.4 ships, reads) and `token_auth_method` are allauth's `openid_connect`
keys (its `docs/socialaccount/providers/openid_connect.rst`), set because
Authelia's clients require PKCE S256 and `client_secret_basic`; the v3
migration notes name `token_auth_method` as the fix for an
`invalid_client` at the callback. `server_url` is Authelia's issuer; allauth
reads its discovery document below it. Authelia's redirect URI is
`PAPERLESS_URL/accounts/oidc/authelia/login/callback/`.

- `PAPERLESS_SOCIAL_AUTO_SIGNUP=true`: whoever Authelia lets through gets
  an account. Paperless cannot limit sign-up to a group, so the gate is the
  Authelia client's policy.
- `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS=family`: the model permissions
  every new account needs to see anything, given once, at sign-up. The
  group must exist before the first sign-in; an account made before it has
  no permissions until `paperless_admin` adds it.
- No `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`. The sync does not add groups:
  it sets an account's groups to the claim's, `groups.set(..., clear=True)`
  in Paperless 3.3.4's `signals.py`, right after sign-up and again at every
  login. With it, `family` would survive only while Authelia has a group of
  that name holding everyone, and every group given in Paperless by hand
  would be gone at the next login. Who may sign in is the Authelia client's
  policy, and what an account may do is Paperless's groups, set in
  Paperless.
- No `PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP` or `_STAFF_GROUP`: no
  OIDC account becomes staff or superuser.
- `PAPERLESS_DISABLE_REGULAR_LOGIN=false`: the local login stays, for
  `paperless_admin` and for while Authelia is down.
- `PAPERLESS_ACCOUNT_ALLOW_SIGNUPS=false`: nobody makes a local account
  (the default, written out). Paperless ignores it on a fresh install, one
  with no user and no document: then sign-up is open, and the first account
  made, local or through OIDC, becomes superuser and staff (`adapter.py`).
  So `paperless_admin` is made before the port is published (*Deploy*,
  step 5).

## Folders on the NAS

```
PAPERLESS_DATA_DIR/        the shared folder, PAPERLESS_UID's, such as /volume1/paperless
  data/                    Paperless's data: search index, logs, exporter.last
  media/                   the documents: originals/ and archive/, by owner
  export/                  document_exporter's output, restic-offsite's source
  consume/                 the consume root; the override mounts each Eingang below it
  db/                      Postgres (its data is in db/18/docker)
  redis/                   the task queue's snapshot
```

Make all six before the first `docker compose up`, owned by
`PAPERLESS_UID:PAPERLESS_GID`. Docker makes a missing bind source as root,
and the services, which are not root, could not write it.

## Deploy

1. **The account and the share.** A NAS account for Paperless, which owns
   `PAPERLESS_DATA_DIR` and its six folders and may write into every
   `Eingang` and `Archiv` folder the override names. Note its uid and gid.
   Only that account and the NAS's admins may reach the shared folder
   `paperless`: `media/` and `export/` hold every owner's documents, so a
   family account with access to it would see everyone's. In UGOS, the
   shared folder's permissions name no family account or group, and the
   folder is not offered over SMB to them. Verify on the NAS:

   ```sh
   stat -c '%U:%G %A' /volume1/paperless /volume1/paperless/*   # the Paperless account, no rights for others
   getfacl -p /volume1/paperless 2>/dev/null                   # no family account or group in an ACL entry
   ```

   and, as one family account over SMB, that the share `paperless` is not
   listed or refuses to open.
2. **The files.** `/volume1/docker/paperless/` gets this compose file, the
   private override and a `.env` from `.env.example`, filled in and mode
   0600. The secrets get a copy in the password manager. Never add an
   `env_file:` of `.env`: compose reads it only for the values in the file,
   and `PAPERLESS_DATA_DIR` and `PAPERLESS_PORT` mean other things to
   Paperless inside the container.
3. **The archive-copy image.** `docker load` of `ravnix-paperless-copy-image`;
   the tag it prints goes into `PAPERLESS_ARCHIVE_COPY_IMAGE`.
4. **Pull.** In that folder, with both files (`dc` below stands for
   `docker compose -f docker-compose.yaml -f paperless.override.yaml`):

   ```sh
   dc pull
   ```

   It skips `archive-copy`, whose `pull_policy` is `never`: its image is the
   one step 3 loaded, which no registry has. A line
   `COMPOSE_FILE=docker-compose.yaml:paperless.override.yaml` in `.env`,
   which the private values carry, makes a bare `docker compose` in that
   folder read both files as well. An explicit `-f` wins over it, which steps
   5 and 6 rely on.
5. **The admin, before the port opens.** A fresh install is open for
   sign-up and makes its first account superuser (*Sign-in*), so
   `paperless_admin` comes first, from a one-off container that publishes
   no port (`run` publishes none without `--service-ports`) and, run from
   this file alone, mounts no `Eingang`. Its start migrates the empty
   database, as the Paperless-ngx docs' `docker compose run --rm webserver
   document_index reindex` does:

   ```sh
   dc up -d db broker
   docker compose -f docker-compose.yaml run --rm webserver createsuperuser --username paperless_admin
   ```

   The password goes into the password manager.
6. **Start, without the inboxes.** The webserver alone, from this file
   alone. The admin exists, so sign-up is closed. No `Eingang` is mounted
   yet, so nothing is consumed before step 7 has made the workflows: a file
   consumed before them would get no owner (*Ownerless documents*).

   ```sh
   docker compose -f docker-compose.yaml up -d webserver
   ```

   `exporter` and `archive-copy` wait for step 8: without the override the
   copy has no `/targets` and would restart until then. Wait until
   `docker compose -f docker-compose.yaml ps webserver` shows it `healthy`;
   `PAPERLESS_URL` then serves the login page.
7. **Setup.** Run `ravnix-paperless-setup` against the instance, with a
   token of `paperless_admin`'s (its profile page, *API Auth Token*) and
   `--fallback-owner paperless_admin`, for the group `family`, the household
   user and the workflows. With nobody signed in yet it makes all but the
   people's workflows, names each person as missing and exits 1. A second
   run that prints no `made` or `put back` line shows the rest complete.
   Invite the family only after it: an account that signs in before
   `family` exists gets no permissions.
8. **The inboxes.** Both files now:

   ```sh
   dc up -d
   ```

   This makes the webserver anew with every `Eingang` mounted and starts the
   exporter, once the webserver is healthy, and the archive copy. Then check
   that no document is without an owner (*Ownerless documents*). Pin the
   four registry images' digests after their tags in the NAS's copy of this
   file, as `docker image inspect -f '{{index .RepoDigests 0}}' IMAGE`
   prints them; the loaded archive-copy image has none (see *Open
   findings*).

After each person's first sign-in, the first one included, run step 7
again before that person's `Eingang` is used. Their workflow exists only
from that run on; until then a file in their `Eingang` is
`paperless_admin`'s.

The project is named `paperless`, so its containers are
`paperless-webserver-1`, `paperless-db-1`, `paperless-broker-1` and so on,
the names Kuma's container push on the NAS watches.

## Ownerless documents

A document without an owner is visible to every account with the view
permission, so to the whole group `family`: Paperless adds `owner__isnull`
to what a user may see. Two ways lead there:

- a file consumed before its folder had a workflow, which *Deploy* steps 6
  to 8 rule out;
- deleting a Paperless user. Paperless hands their documents to nobody: it
  sets their owner to none (`on_delete=SET_NULL`), so all their papers open
  to everyone.

**The gate.** As `paperless_admin`, `/api/documents/?owner__isnull=true`
must report `"count": 0`: after *Deploy* step 8, before the family is
invited, and after a user is deleted. From the laptop, with step 7's token
file and `PAPERLESS_URL` set to the address (the token reaches curl on its
standard input, not its command line):

```sh
printf 'header = "Authorization: Token %s"\n' "$(cat TOKEN_FILE)" |
  curl -fsS -K - "$PAPERLESS_URL/api/documents/?owner__isnull=true&page_size=1" | jq .count
```

A count above 0 is a leak: give each such document its owner (*Documents*,
select, *Permissions*) before anyone else signs in.

**Before deleting a user**, reassign or delete their documents: as
`paperless_admin`, filter the documents by that owner, select them all and
set another owner, or delete them and empty them from the trash. Then
delete the user and check the gate again.

## The two nightly jobs

**The export**, 02:30 Europe/Berlin: `document_exporter
/usr/src/paperless/export --no-progress-bar --skip-checks`, in the
Paperless image, by a loop in the shape of restic-offsite's. Exporting
into the existing folder is incremental. No `--delete`: a document deleted
or renamed in Paperless stays in the export, so the off-site copy never
loses one. No `--passphrase`: restic encrypts the off-site repository, and
a second secret would only be one more to lose. `--skip-checks` skips
Paperless's start-up checks, which want a writable consume folder the
exporter has no use for. The media stay writable for it, because
`document_exporter` takes its lock in `media/media.lock` (the smoke run
failed with a read-only media folder).

The loop wakes every minute and runs once a day, the first time the clock
reads 02:30 or later. The night without a 02:30 (spring forward) it runs at
03:00, the night with two it runs once, and a day missed while the
container was stopped is caught up when it starts. The day goes into
`data/exporter.last` before the run, so a failing export waits for the next
day instead of retrying every minute. A good run pushes
`KUMA_PUSH_URL_PAPERLESS_EXPORT` when it is set; the URL reaches curl on
its standard input, never on a command line that `ps` shows.

**The archive copy**, 03:30: `ravnix-paperless-copy --media /media
--targets /targets`, media read-only, one target per owner from the
override, and a push of `KUMA_PUSH_URL_PAPERLESS_COPY` (read by the tool
from `KUMA_PUSH_URL`) on success. Its README has the rest.

Both finish well before restic-offsite runs, which wants an hour of quiet
on its sources.

## Update

Paperless follows nixpkgs: when the lock moves `paperless-ngx` to a new
version, the check fails until the two tags in the compose file follow it,
so the VM test of Task 9.5.2 and the NAS run the same version. Postgres and
Redis move by hand within their major versions. On the NAS:

1. Take a database dump beside the export, so the off-site copy holds one
   from before the update:

   ```sh
   docker compose -f docker-compose.yaml -f paperless.override.yaml exec -T db \
     pg_dump -U paperless paperless > "$PAPERLESS_DATA_DIR/export/pre-update-OLD_TAG.sql"
   ```

2. Change the tag (and the digest), `pull`, `up -d`. The webserver migrates
   the database at start.

## Rollback

Paperless's migrations only go forward, so the previous tag does not start
against a database the new one has migrated. Roll back with the dump:

1. `docker compose ... down`.
2. Move `db/` aside and make it again, empty and `PAPERLESS_UID`'s.
3. Put the previous tag (and digest) back.
4. `docker compose ... up -d db`, then load the dump:
   `docker compose ... exec -T db psql -U paperless paperless < export/pre-update-OLD_TAG.sql`.
5. `docker compose ... up -d`.

The media are not touched by a migration and stay as they are. Without a
dump, the export restores everything into an empty instance of the same
version as the export: `document_importer /usr/src/paperless/export` in the
webserver.

## Open findings

- **Where the digests live.** *Deploy* step 8 pins them in the NAS's copy;
  the repository's file keeps the bare tags, which its check holds exactly.
  Whether pins move into the repository, with a check that allows them, is
  open, as for restic's compose file.
- **Read-only roots.** Only `archive-copy` has one. The webserver
  (s6-overlay with `S6_READ_ONLY_ROOT`, tmpfs on `/run` and `/tmp`), db and
  broker might take one too; not tried yet.
- **The proxy's address.** Behind the reverse proxy every request comes
  from the proxy, so allauth's rate limits count the whole household as one
  client. `PAPERLESS_TRUSTED_PROXIES` would fix it, but it is an address
  and lives in no public file; it can join `.env` when it matters.
- **Slow writers.** The consumer waits until a file has kept its size and
  time for `PAPERLESS_CONSUMER_STABILITY_DELAY`, 5 s by default. That
  covers the 20 s chunked write of Task 9.5.2's test; a writer that stalls
  longer over SMB would need a larger value here and in that test.
