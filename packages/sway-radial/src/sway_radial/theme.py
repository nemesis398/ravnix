"""The colors, the font and the line widths of the ring, read from a theme file.

The program draws no color of its own. ravnix writes a JSON file from the roles
of its theme module (modules/desktop/sway-radial.nix) and the unit names it in
``SWAY_RADIAL_THEME``; without the variable the file is
``$XDG_CONFIG_HOME/sway-radial/theme.json``. The shape:

    {"roles": {"canvas": "#rrggbb", ...}, "font": "...",
     "lineWidth": {"frame": 1, "marker": 2}}

``roles`` may hold more than the ring uses (the module writes all of them); the
eight it draws with are in ``ROLES``. A color is ``#rrggbb`` and nothing else:
the ring is opaque, so a color with an alpha part is refused.

The file is read once, when this module is first imported, and the constants
below are what the painter reads. A file that is missing or wrong must not take
the menu away, so the import never raises: it logs one error naming the file
and what is wrong, and the constants are the grayscale fallback, which draws a
ring that works and looks like nothing in particular. Cairo takes floats in
0..1, and converting at every call site is how a palette drifts, so the colors
are converted once, here.
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "ACCENT",
    "CANVAS",
    "DEEPEST",
    "FONT",
    "FRAME",
    "MARKER",
    "MUTED",
    "ROLES",
    "SECONDARY",
    "SELECTED",
    "TEXT",
    "THEME_ENV",
    "Theme",
    "ThemeError",
    "WASH",
    "default_path",
    "fallback",
    "load",
]

log = logging.getLogger(__name__)

THEME_ENV = "SWAY_RADIAL_THEME"

#: The roles the ring draws with, by the names of the style spec (docs/style.md
#: of ravnix): the accent marks the lit sector, canvas fills an empty one, wash
#: an occupied one, selected is the line between sectors, deepest the hub and
#: the text on the accent, text and secondary are labels, muted a dim one.
ROLES = ("accent", "canvas", "deepest", "muted", "secondary", "selected", "text", "wash")

#: A theme file is a few hundred bytes. A big one is the wrong file, and it is
#: refused before it is parsed.
_MAX_BYTES = 64 * 1024

_COLOR = re.compile(r"#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})")

RGB = tuple[float, float, float]


class ThemeError(Exception):
    """Raised with a message naming the file and what is wrong in it."""


@dataclass(frozen=True, slots=True)
class Theme:
    colors: dict[str, RGB]
    font: str
    frame: float
    marker: float


def default_path() -> Path:
    """The theme file: the variable's, else the config directory's."""
    given = os.environ.get(THEME_ENV)
    if given:
        return Path(given)
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "sway-radial" / "theme.json"


def fallback() -> Theme:
    """A grayscale theme, for when there is no usable file.

    The accent is a light gray apart from every neighbour it is drawn on, so
    the lit sector still stands out and the label on it (deepest) is readable.
    """
    levels = {
        "deepest": 0.0,
        "canvas": 0.1,
        "wash": 0.2,
        "selected": 0.3,
        "muted": 0.5,
        "secondary": 0.7,
        "text": 0.9,
        "accent": 0.8,
    }
    return Theme(
        colors={role: (level, level, level) for role, level in levels.items()},
        font="monospace",
        frame=1.0,
        marker=2.0,
    )


def _color(source: str, role: str, value: object) -> RGB:
    match = _COLOR.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise ThemeError(
            f'{source}: role "{role}" is {value!r}, not a color of the form #rrggbb'
        )
    red, green, blue = (int(part, 16) / 255 for part in match.groups())
    return (red, green, blue)


def _width(source: str, name: str, value: object) -> float:
    # bool is an int in Python, and `true` is not a width.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ThemeError(f'{source}: lineWidth "{name}" is {value!r}, not a number')
    if not math.isfinite(value) or value <= 0:
        raise ThemeError(f'{source}: lineWidth "{name}" is {value!r}, not a positive width')
    return float(value)


def parse(data: object, *, source: str) -> Theme:
    """Build a Theme from already-parsed JSON, or raise ThemeError."""
    if not isinstance(data, dict):
        raise ThemeError(f"{source}: is not a JSON object")

    roles = data.get("roles")
    if not isinstance(roles, dict):
        raise ThemeError(f'{source}: "roles" is missing or is not an object')
    colors: dict[str, RGB] = {}
    for role in ROLES:
        if role not in roles:
            raise ThemeError(f'{source}: role "{role}" is missing from "roles"')
        colors[role] = _color(source, role, roles[role])

    font = data.get("font")
    if not isinstance(font, str) or not font:
        raise ThemeError(f'{source}: "font" is missing or is not a family name')

    widths = data.get("lineWidth")
    if not isinstance(widths, dict):
        raise ThemeError(f'{source}: "lineWidth" is missing or is not an object')
    for name in ("frame", "marker"):
        if name not in widths:
            raise ThemeError(f'{source}: lineWidth "{name}" is missing')

    return Theme(
        colors=colors,
        font=font,
        frame=_width(source, "frame", widths["frame"]),
        marker=_width(source, "marker", widths["marker"]),
    )


def load(path: Path) -> Theme:
    """Read and parse a theme file. Raises ThemeError on any problem."""
    source = str(path)
    try:
        with open(path, "rb") as handle:
            raw = handle.read(_MAX_BYTES + 1)
    except OSError as exc:
        raise ThemeError(f"{source}: cannot be read: {exc}") from exc
    if len(raw) > _MAX_BYTES:
        raise ThemeError(f"{source}: is too large for a theme file (over {_MAX_BYTES} bytes)")
    try:
        data = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise ThemeError(f"{source}: is not UTF-8 text: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ThemeError(f"{source}: is not valid JSON: {exc}") from exc
    except RecursionError as exc:
        raise ThemeError(f"{source}: is nested too deeply to read") from exc
    return parse(data, source=source)


def _initial() -> Theme:
    path = default_path()
    try:
        return load(path)
    except ThemeError as exc:
        log.error("%s; drawing in grayscale", exc)
        return fallback()


_THEME = _initial()

ACCENT = _THEME.colors["accent"]
CANVAS = _THEME.colors["canvas"]
DEEPEST = _THEME.colors["deepest"]
MUTED = _THEME.colors["muted"]
SECONDARY = _THEME.colors["secondary"]
SELECTED = _THEME.colors["selected"]
TEXT = _THEME.colors["text"]
WASH = _THEME.colors["wash"]

FONT = _THEME.font

#: Line widths in px (docs/style.md: 1 px frames, 2 px markers). The line
#: between two sectors is a frame; the countdown arc is a marker.
FRAME = _THEME.frame
MARKER = _THEME.marker
