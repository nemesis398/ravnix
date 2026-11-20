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
`PAPERLESS_SOCIALACCOUNT_PROVIDERS` and `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`;
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

`SCOPE` with `groups` is what the docs ask for group sync. PKCE (set for
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
- `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS=true`: the claim's groups map onto
  Paperless groups of the same name, which must exist first.
- `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS=family`: the model permissions
  every new account needs to see anything. The group must exist before the
  first sign-in.
- No `PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP` or `_STAFF_GROUP`: no
  OIDC account becomes staff or superuser.
- `PAPERLESS_DISABLE_REGULAR_LOGIN=false`: the local login stays, for
  `paperless_admin` and for while Authelia is down.

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

1. **The account.** A NAS account for Paperless, which owns
   `PAPERLESS_DATA_DIR` and its six folders and may write into every
   `Eingang` and `Archiv` folder the override names. Note its uid and gid.
2. **The files.** `/volume1/docker/paperless/` gets this compose file, the
   private override and a `.env` from `.env.example`, filled in and mode
   0600. The secrets get a copy in the password manager. Never add an
   `env_file:` of `.env`: compose reads it only for the values in the file,
   and `PAPERLESS_DATA_DIR` and `PAPERLESS_PORT` mean other things to
   Paperless inside the container.
3. **The archive-copy image.** `docker load` of `ravnix-paperless-copy-image`;
   the tag it prints goes into `PAPERLESS_ARCHIVE_COPY_IMAGE`.
4. **Start.** In that folder, with both files:

   ```sh
   docker compose -f docker-compose.yaml -f paperless.override.yaml pull
   docker compose -f docker-compose.yaml -f paperless.override.yaml up -d
   ```

   The first start migrates the empty database; the exporter starts once
   the webserver is healthy. Then pin each image's digest after its tag, as
   `docker compose images` prints it.
5. **Administration and setup.** Make the local `paperless_admin`
   superuser (`docker compose exec webserver createsuperuser`), then run
   `ravnix-paperless-setup` against the instance for the group `family`,
   the household user and the workflows.

The project is named `paperless`, so its containers are
`paperless-webserver-1`, `paperless-db-1`, `paperless-broker-1` and so on,
the names Kuma's container push on the NAS watches.

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
