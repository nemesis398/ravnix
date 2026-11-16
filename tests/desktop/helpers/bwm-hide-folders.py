# Run inside the interpreter of bwm, after the path set-up of its entry script
# (tests/desktop/bitwarden-menu-hide-folders.nix prepends it). Prints what it
# found and exits 1 on a problem. argv[1] is a scratch directory.
#
# It calls bwm's own dmenu_run on a vault made of fake items, with the menu
# replaced by a function that records the entries bwm would show and then
# chooses nothing, as Escape does.
import os
import sys
import traceback

scratch = sys.argv[1]
problems = []


def check(ok, what):
    if not ok:
        problems.append(what)


import bwm  # noqa: E402
import bwm.bwm as main  # noqa: E402
from bwm.bwcli import Item  # noqa: E402

# What `bw list folders` gives: the folders by id, and "No Folder" under the
# id null, which is where bwm's get_folders puts it.
FOLDERS = {
    "f-hidden": {"object": "folder", "id": "f-hidden", "name": "Hidden"},
    "f-shown": {"object": "folder", "id": "f-shown", "name": "Shown"},
    "f-also": {"object": "folder", "id": "f-also", "name": "Also hidden"},
    None: {"object": "folder", "id": None, "name": "No Folder"},
}


def item(name, folder_id, **extra):
    # What `bw list items` gives carries `folderId`, never `folder`.
    fields = {"type": 2, "name": name, "folderId": folder_id, "notes": ""}
    fields.update(extra)
    return Item(fields)


ENTRIES = [
    item("in hidden", "f-hidden"),
    item("in shown", "f-shown"),
    item("in no folder", None),
    item("in also hidden", "f-also"),
    item("in a folder that is gone", "f-gone"),
]


def shown(config):
    """The names dmenu_run lists, for a config.ini whose [vault] is `config`."""
    path = os.path.join(scratch, "config.ini")
    with open(path, "w", encoding="utf-8") as f:
        f.write("[dmenu]\ndmenu_command = fuzzel --dmenu\n[vault]\n" + config)
    bwm.reload_config(path)
    seen = {}

    def menu(options, entries, folders):
        seen["main"] = [i["name"] for i in entries]
        # The "View/Type Individual entries" menu gets the same list.
        view = options["View/Type Individual entries"]
        seen["view"] = [i["name"] for i in view.args[0]]
        return None

    vault = main.Vault(
        url="https://vault.invalid",
        email="",
        passw="",
        twofactor="",
        entries=list(ENTRIES),
        folders=dict(FOLDERS),
    )
    real = main.view_all_entries
    main.view_all_entries = menu
    try:
        run = main.dmenu_run(vault)
    except Exception:
        problems.append("dmenu_run raised with %r:\n%s" % (config, traceback.format_exc()))
        return None
    finally:
        main.view_all_entries = real
    check(run == main.Run.STOP, "%r: no choice did not stop: %r" % (config, run))
    check(seen.get("main") == seen.get("view"), "%r: the view menu lists others: %r" % (config, seen))
    print("  %-40r -> %r" % (config, seen.get("main")))
    return seen.get("main")


ALL = [i["name"] for i in ENTRIES]

# No hide_folders: every item.
got = shown("")
check(got == ALL, "without hide_folders: %r, want %r" % (got, ALL))

# One folder: its items go, the others stay, an item outside any folder and an
# item whose folder is gone included.
got = shown("hide_folders = Hidden\n")
want = [n for n in ALL if n != "in hidden"]
check(got == want, "hide_folders = Hidden: %r, want %r" % (got, want))

# Several folders, one per line, as configparser continues a value; a name
# that is no folder (Bitwarden's trash is none) is dropped and hides nothing.
got = shown("hide_folders = Hidden\n  Trash\n  Also hidden\n")
want = [n for n in ALL if n not in ("in hidden", "in also hidden")]
check(got == want, "hide_folders = Hidden, Trash, Also hidden: %r, want %r" % (got, want))

# Only names that are no folder: nothing is hidden.
got = shown("hide_folders = Trash\n")
check(got == ALL, "hide_folders = Trash: %r, want %r" % (got, ALL))

# "No Folder" is the name bw gives the items without a folder.
got = shown("hide_folders = No Folder\n")
want = [n for n in ALL if n != "in no folder"]
check(got == want, "hide_folders = No Folder: %r, want %r" % (got, want))

for p in problems:
    print("  " + p)
print("bwm hide_folders: %d problems" % len(problems))
sys.exit(1 if problems else 0)
