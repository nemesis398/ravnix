"""Running a selected menu item.

Two indirections here look like overhead and are not.

A ``.desktop`` item is launched with ``gtk-launch``, never by reading ``Exec=``
and running it ourselves. The point of the indirection is that the Wayland and
Electron flags stay defined in one place, the desktop file. A bare command is
not equivalent: that is how ``exec helium`` quietly ran XWayland Helium for
months.

A raw command goes through ``swaymsg exec``, not a direct ``Popen``, so sway
reparents the child. The daemon then inherits neither a zombie nor a
controlling terminal.
"""

from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path

from .model import MenuItem

logger = logging.getLogger(__name__)

#: The XDG default when ``XDG_DATA_DIRS`` is unset, per the basedir spec.
_DEFAULT_DATA_DIRS = "/usr/local/share:/usr/share"


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


def run_item(item: MenuItem) -> None:
    """Launch a desktop item with gtk-launch, or run a command item through
    'swaymsg exec'. Never raises; failures are logged."""
    if item.is_submenu:
        return

    if item.desktop:
        argv = ["gtk-launch", item.desktop]
    elif item.command:
        # The '--' keeps a command starting with a dash from being read as a
        # swaymsg option.
        argv = ["swaymsg", "exec", "--", item.command]
    else:
        logger.warning("menu item %r has neither a desktop id nor a command", item.label)
        return

    try:
        _spawn(argv)
    except Exception as exc:  # noqa: BLE001
        # Deliberately everything. The alternative is a daemon that dies
        # because someone renamed a .desktop file.
        logger.error("failed to launch %r via %s: %s", item.label, argv[0], exc)
