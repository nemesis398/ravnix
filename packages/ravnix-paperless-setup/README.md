# ravnix-paperless-setup

Puts a Paperless-ngx instance into the shape of the household design over its
REST API: the group of the family, the household user, a fallback owner for
every consumed file, and one ownership workflow per inbox folder. The
script's header says exactly what it makes.

```sh
ravnix-paperless-setup --url URL --token-file FILE \
  --owners NAME,NAME,... --household haushalt --family-group family \
  --fallback-owner paperless_admin [--consume-root DIR]
```

- `--token-file` holds the API token of a superuser (the local admin login),
  on one line. The token goes to curl through a configuration file in a
  private temporary directory, never on a command line or in an environment.
- `--owners` is the deployment's owner list, joined with commas. The
  household's name may be in it; it stands for the household there.
- `--fallback-owner` names an existing, active superuser. On the NAS that is
  `paperless_admin`, which has no `Archiv` mount, so the archive copy copies
  its files nowhere.
- `--consume-root` is the consume folder as Paperless sees it, by default
  the container's `/usr/src/paperless/consume`, which is what the NAS needs.
  The VM test passes its own.
- Exit status: 0 done; 1 an API call failed (printed with its endpoint), an
  owner has no account yet, or the fallback owner is no active superuser
  (checked before any change); 2 bad arguments (nothing is called).

A second run changes nothing and prints `nothing to change`. What differs from
the design is put back: the group's permissions, the household user's flags,
a workflow's order, trigger and action.

`tests/services/paperless.nix` (the check `services-paperless`) runs it
against Paperless in a NixOS VM, with four inboxes, and drops PDFs into them.

## What it makes

| Object | Shape |
| --- | --- |
| group `--family-group` | view, add and change on documents, tags, correspondents, document types, storage paths, saved views and UI settings; no other permission |
| user `--household` | inactive, not staff, not superuser, no group, no permission of its own, made without a password |
| workflow `ravnix: fallback owner` | order 0; trigger *Consumption Started*, source the consume folder, path `ROOT/*`; action: owner `--fallback-owner`, no grant |
| workflow `ravnix: owner NAME` | order 1; the same trigger with path `ROOT/NAME/*`; action: owner NAME, nobody else |
| workflow `ravnix: household NAME` | order 1; the same for the household's folder; action: owner the household, view and change for the group |

Paperless runs the workflows of a trigger in their order, and a later
assignment of an owner replaces an earlier one. So every file from the consume
folder first becomes the fallback owner's, and the workflow of its folder then
makes it its person's or the household's. A file that no later workflow names
(an inbox of someone without an account yet, the folder's top, a stray
subfolder) stays the fallback owner's, which no family member can see. A
document without an owner would be visible to the whole group.

`ROOT` is `--consume-root`. Every filter starts with it, because Paperless
matches a filter against the file's whole path with `fnmatch`, whose `*` also
matches `/`. A filter of `*/consume/bob/*` would also take
`ROOT/alice/consume/bob/x.pdf`, and the workflows of both alice and bob, of
the same order, would match it. So whoever may write into an inbox, and
every member may write into the household's, could hand a file of their own
to someone else. Anchored, that file is alice's, the owner of the inbox it
was dropped into (the VM test's `nested-path`). A run with another root, or after the earlier unanchored
filters, rewrites every filter. The workflows take only
files from the consume folder: an upload in the browser, a phone app or the
API keeps its uploader as the owner, which is Paperless's own default.

### Why these permissions

The design names the six models a family member works with: documents, tags,
correspondents, document types, storage paths and saved views. Model
permissions do not open other people's documents, since object ownership
decides that. On top of the design the group has view, add and change on *UI
settings*: Paperless's documentation says that a user of the web UI needs at
least view on them, and without it the UI's settings call answers 403. A user
reads and writes only their own settings (the VM test checks that).

The group does **not** have view on *tasks* (`view_paperlesstask`, the list of
consumptions and their failures). In Paperless 3.3.4 a user who is not staff
sees every task without an owner, and a task from the consume folder has none,
because the owner is set by a workflow inside the task. So the permission would
show every member every other member's file names and document ids. The VM
test pins this: if a later Paperless gives consumption tasks an owner, that
subtest fails and the grant can be weighed again. The family therefore does
not see a failed consumption in the UI; the admin does, and the file stays in
the inbox.

Also not granted: notes, custom fields, share links, users and groups (the
dialog that shares one document by hand needs to list users and groups).

## Limits

What it does not cover:

- **Owners must have an account first.** Paperless makes a person's account
  at the first sign-in through OIDC, and an account made beforehand under the
  same name would make that sign-in pick another name. So the tool makes no
  owner's account: an owner without one gets no workflow, the rest is made,
  and the run names the owner and exits 1. Run it again once they have signed
  in. Until then a file in that person's inbox is the fallback owner's and not
  theirs; it moves to them only by hand.
- **The household user's password hash is empty, not Django's unusable
  marker** (accepted). The REST API can make a user without a password but
  cannot call `set_unusable_password()`. An empty hash matches no password,
  and the user is inactive, so it cannot sign in either way; Django's
  `has_usable_password()` still answers true for it, since it only knows the
  marker.
- **The download of another person's document answers 403, not 404**
  (accepted, Paperless's behavior). The document itself answers 404 and no
  content leaks, but the 403 tells a member that a document of that id
  exists.
- **It never deletes.** A workflow of its own for an owner no longer listed is
  named and left; delete it in Paperless. A workflow of another name is not
  touched, even one that also sets owners, and one with an order above 1 runs
  after the tool's and can override them.
- **The tool owns its workflows' order, trigger and action.** It compares the
  fields that decide which files match (type, sources, path, file name, mail
  rule), who gets them (owner, view and change users and groups) and the
  order, and writes a workflow anew when one differs, which also drops
  anything else added to it by hand. A change by hand to another field (a tag
  added to the action) stays until then.
- **Path filters compare case.** Python's `fnmatch` on Linux is
  case-sensitive, so the folder must be named exactly as the owner.
- It reads every group, user and workflow in one page of up to 100000; a
  longer list stops it with 1.
