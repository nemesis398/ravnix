"""Running a selected menu item.

Two indirections here look like overhead and are not.

A ``.desktop`` item is launched with ``gtk-launch``, never by reading ``Exec=``
and running it ourselves. The point of the indirection is that the Wayland and
Electron flags stay defined in one place, the desktop file. A bare command is
not equivalent: that is how ``exec helium`` quietly ran XWayland Helium for
months.

Every item, desktop or command, is started by Sway: the program asks for it
with ``swaymsg exec`` and never runs an app itself. Sway becomes the parent, so
the daemon inherits neither a zombie nor a controlling terminal, and, since the
daemon is a user service, the app does not live in the service's cgroup, where
a restart of the unit (a rebuild that changes it, a crash) would end it along
with the menu. It also starts with the session's environment (its PATH, with
``/run/wrappers/bin``), and none of the variables the wrapper of this program
sets for itself.
"""

from __future__ import annotations

import logging
import os
import re
import shlex
import subprocess
from pathlib import Path

from .model import MenuItem

logger = logging.getLogger(__name__)

#: The XDG default when ``XDG_DATA_DIRS`` is unset, per the basedir spec.
_DEFAULT_DATA_DIRS = "/usr/local/share:/usr/share"

#: The wrapper of the package names the gtk-launch it was built with here, so
#: that the launch does not depend on the session's PATH holding GTK's tools.
GTK_LAUNCH_ENV = "SWAY_RADIAL_GTK_LAUNCH"

#: What a desktop id is made of. The id reaches a shell through Sway's ``exec``,
#: which also splits a command line at ``;`` and ``,``, and ``gtk-launch`` reads
#: a leading dash as an option. A real id (``helium``, ``md.obsidian.Obsidian``,
#: ``webapp-claude``) has none of those.
_DESKTOP_ID = re.compile(r"[A-Za-z0-9_+][A-Za-z0-9._+-]*")


def _spawn(argv: list[str]) -> None:
    """Start a process. The seam the tests monkeypatch, so keep it one line."""
    subprocess.Popen(argv)


def _data_dirs() -> list[Path]:
    """The XDG data path, read fresh on every call.

    Reading the environment at call time rather than at import time is what
    lets a test point the search at a temporary directory, and it is also what
    makes the daemon see a session whose environment was completed after the
    service started.
    """
    dirs: list[Path] = []
    home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    dirs.append(Path(home))
    raw = os.environ.get("XDG_DATA_DIRS") or _DEFAULT_DATA_DIRS
    dirs.extend(Path(part) for part in raw.split(":") if part)
    return dirs


def desktop_exists(desktop_id: str) -> bool:
    """True when a .desktop entry with this id is on the XDG search path.

    Accepts both ``helium`` and ``helium.desktop``, because a config written by
    hand will use whichever form the author remembers.
    """
    name = desktop_id if desktop_id.endswith(".desktop") else f"{desktop_id}.desktop"
    return any((base / "applications" / name).is_file() for base in _data_dirs())


def _sway_exec(command: str) -> list[str]:
    # The '--' keeps a command starting with a dash from being read as a
    # swaymsg option.
    return ["swaymsg", "exec", "--", command]


def run_item(item: MenuItem) -> None:
    """Launch a desktop item with gtk-launch, or run a command item, both
    through 'swaymsg exec' so that Sway starts them. Never raises; failures are
    logged."""
    if item.is_submenu:
        return

    if item.desktop:
        if not _DESKTOP_ID.fullmatch(item.desktop):
            logger.error(
                "menu item %r: %r is not a desktop id, so nothing is run",
                item.label,
                item.desktop,
            )
            return
        launcher = os.environ.get(GTK_LAUNCH_ENV) or "gtk-launch"
        argv = _sway_exec(shlex.join([launcher, item.desktop]))
    elif item.command:
        argv = _sway_exec(item.command)
    else:
        logger.warning("menu item %r has neither a desktop id nor a command", item.label)
        return

    try:
        _spawn(argv)
    except Exception as exc:  # noqa: BLE001
        # Deliberately everything. The alternative is a daemon that dies
        # because someone renamed a .desktop file.
        logger.error("failed to launch %r via %s: %s", item.label, argv[0], exc)
