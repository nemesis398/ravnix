# ravnix-paperless-setup

Puts a Paperless-ngx instance into the shape of the household design over its
REST API: the group of the family, the household user, and one ownership
workflow per inbox folder. The script's header says exactly what it makes.

```sh
ravnix-paperless-setup --url URL --token-file FILE \
  --owners NAME,NAME,... --household haushalt --family-group family
```

- `--token-file` holds the API token of a superuser (the local admin login),
  on one line. The token goes to curl through a configuration file in a
  private temporary directory, never on a command line or in an environment.
- `--owners` is the deployment's owner list, joined with commas. The
  household's name may be in it; it stands for the household there.
- Exit status: 0 done, 1 an API call failed (printed with its endpoint) or an
  owner has no account yet, 2 bad arguments (nothing is called).

A second run changes nothing and prints `nothing to change`. What differs from
the design is put back: the group's permissions, the household user's flags,
a workflow's trigger and action.

`tests/services/paperless.nix` (the check `services-paperless`) runs it
against Paperless in a NixOS VM, with three inboxes, and drops PDFs into them.

## What it makes

| Object | Shape |
| --- | --- |
| group `--family-group` | view, add and change on documents, tags, correspondents, document types, storage paths and saved views; no other permission |
| user `--household` | inactive, not staff, not superuser, no group, no permission of its own, made without a password |
| workflow `ravnix: owner NAME` | trigger *Consumption Started*, source the consume folder, path `*/consume/NAME/*`; action: owner NAME, nobody else |
| workflow `ravnix: household NAME` | the same for the household's folder; action: owner the household, view and change for the group |

The path filters assume that the consume folder's last segment is `consume`,
as `/usr/src/paperless/consume` is in the container. The workflows take only
files from the consume folder: an upload in the browser, a phone app or the
API keeps its uploader as the owner, which is Paperless's own default.

## Limits

What it does not cover:

- **Owners must have an account first.** Paperless makes a person's account
  at the first sign-in through OIDC, and an account made beforehand under the
  same name would make that sign-in pick another name. So the tool makes no
  owner's account: an owner without one gets no workflow, the rest is made,
  and the run names the owner and exits 1. Run it again once they have signed
  in. Until then a file in that person's inbox gets **no owner, and a
  document without an owner is visible to everyone with view permission**,
  that is the whole family. The same holds for a file at the consume
  folder's top or in a subfolder no workflow names.
- **The household user's password hash is empty, not Django's unusable
  marker.** The REST API can make a user without a password but cannot call
  `set_unusable_password()`. An empty hash matches no password, and the user
  is inactive, so it cannot sign in either way; Django's
  `has_usable_password()` still answers true for it, since it only knows the
  marker.
- **The group's permissions are the design's six models and nothing else.**
  Paperless's documentation says that a user of the web UI needs at least
  view on *UI settings*, which this group does not grant; nor does it grant
  view on tasks (the failed-consumption list), notes, custom fields, share
  links, users or groups (the dialog that shares one document by hand). The
  group is as the design specifies. The VM test prints what that means: a
  member of the group gets HTTP 403 on `/api/ui_settings/` and on
  `/api/tasks/`. Whether the group grants more is the deployment's decision,
  and a one-line change of `permissions` in the script.
- **It never deletes.** A workflow of its own for an owner no longer listed is
  named and left; delete it in Paperless. A workflow of another name is not
  touched, even one that also sets owners.
- **The tool owns its workflows' trigger and action.** It compares the fields
  that decide which files match (type, sources, path, file name, mail rule)
  and who gets them (owner, view and change users and groups), and writes a
  workflow anew when one differs, which also drops anything else added to
  it by hand. A change by hand to another field (a tag added to the action)
  stays until then.
- **Path filters compare case.** Python's `fnmatch` on Linux is
  case-sensitive, so the folder must be named exactly as the owner.
- It reads every group, user and workflow in one page of up to 100000; a
  longer list stops it with 1.
