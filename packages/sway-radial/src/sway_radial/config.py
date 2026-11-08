"""Reading a menu tree out of TOML, and refusing one that cannot work.

The TOML shape is a single top level ``[[items]]`` array. Every entry carries
``dir`` and ``label``, optionally ``icon``, and then either exactly one of
``desktop`` or ``exec`` when it is a leaf, or a nested ``[[items.items]]``
array when it is a submenu.

Nothing here is dropped quietly. A misplaced item is an item that simply never
appears on screen, and the person who wrote the file has no way to tell that
from a sector they forgot to fill in, so every rejection names the file, the
enclosing menu and the direction it was aimed at.
"""

from __future__ import annotations

import tomllib
from pathlib import Path
from typing import Any

from .model import BACK_DIRECTION, DEFAULT_DWELL_MS, DIRECTIONS, Direction, Menu, MenuItem, Settings

__all__ = ["ConfigError", "load_config", "load_menu", "parse_menu", "parse_settings", "submenu"]


class ConfigError(Exception):
    """Raised with a message naming the file, the menu and the direction."""


def _reject(source: str, menu_label: str, direction: object, problem: str) -> ConfigError:
    """Build the one error shape this module raises.

    The three coordinates are the whole point: with them a mistake is a ten
    second fix, without them it is an item that never appears and that nobody
    thinks to go looking for.
    """
    where = f'menu "{menu_label}"' if menu_label else "the top ring"
    return ConfigError(f'{source}: {where}, direction "{direction}": {problem}')


def _parse_items(
    raw: object,
    *,
    source: str,
    menu_label: str,
    nested: bool,
) -> tuple[MenuItem, ...]:
    """Turn one ring's worth of TOML tables into items, recursing into submenus.

    Every ring below the top reserves ``BACK_DIRECTION`` and therefore has seven
    slots. The top ring has no parent, reserves nothing, and has eight.
    """
    if not isinstance(raw, list):
        raise _reject(source, menu_label, "?", "items must be an array of tables")

    reserved = BACK_DIRECTION if nested else None
    items: list[MenuItem] = []
    seen: set[Direction] = set()

    for entry in raw:
        if not isinstance(entry, dict):
            raise _reject(source, menu_label, "?", f"{entry!r} is not a table")

        raw_dir = entry.get("dir")
        if raw_dir not in DIRECTIONS:
            listed = ", ".join(DIRECTIONS)
            raise _reject(source, menu_label, raw_dir, f"not a direction, expected one of {listed}")
        direction: Direction = raw_dir  # type: ignore[assignment]

        if direction == reserved:
            raise _reject(
                source,
                menu_label,
                direction,
                f'reserved for Back, which is always "{BACK_DIRECTION}" in a submenu',
            )
        if direction in seen:
            raise _reject(source, menu_label, direction, "already taken by an earlier item")
        seen.add(direction)

        label = entry.get("label")
        if not isinstance(label, str) or not label:
            raise _reject(source, menu_label, direction, "needs a non-empty label")

        icon = entry.get("icon")
        if icon is not None and not isinstance(icon, str):
            raise _reject(source, menu_label, direction, "icon must be a string")

        desktop = entry.get("desktop")
        command = entry.get("exec")
        for key, value in (("desktop", desktop), ("exec", command)):
            if value is not None and not isinstance(value, str):
                raise _reject(source, menu_label, direction, f"{key} must be a string")

        children_raw = entry.get("items")
        if children_raw is not None:
            if desktop is not None or command is not None:
                raise _reject(
                    source,
                    menu_label,
                    direction,
                    f'"{label}" is a submenu, so it carries neither desktop nor exec',
                )
            children = _parse_items(
                children_raw,
                source=source,
                menu_label=label,
                nested=True,
            )
            if not children:
                raise _reject(source, menu_label, direction, f'submenu "{label}" is empty')
        else:
            if (desktop is None) == (command is None):
                raise _reject(
                    source,
                    menu_label,
                    direction,
                    f'"{label}" is a leaf, so it needs exactly one of desktop or exec',
                )
            children = ()

        items.append(
            MenuItem(
                direction=direction,
                label=label,
                icon=icon,
                desktop=desktop,
                command=command,
                children=children,
            )
        )

    return tuple(items)


def parse_menu(data: dict[str, Any], *, source: str) -> Menu:
    """Build the top ring from an already-parsed TOML mapping."""
    raw = data.get("items")
    if raw is None:
        # No direction to name here, because there is not a single item to misplace.
        raise ConfigError(f"{source}: the top ring has no [[items]] array")
    try:
        items = _parse_items(raw, source=source, menu_label="", nested=False)
    except RecursionError as exc:
        raise ConfigError(f"{source}: is nested too deeply to read") from exc
    if not items:
        # A ring with nothing in it opens, shows eight empty sectors, and does
        # nothing. That is a menu that cannot work, and it is better to say so
        # and fall back than to start with it: a submenu with no items is
        # refused for the same reason.
        raise ConfigError(f"{source}: the top ring has no items")
    return Menu(label="", items={item.direction: item for item in items}, back=None)


def parse_settings(data: dict[str, Any], *, source: str) -> Settings:
    """The non-item keys of an already-parsed TOML mapping.

    Absent keys take their defaults, so a menu.toml that only lists items keeps
    working untouched. A key that is present and wrong is an error rather than a
    silent fallback: someone who wrote dwell_ms wanted a particular number, and
    quietly using 350 instead would look exactly like the setting not working.
    """
    raw = data.get("dwell_ms", DEFAULT_DWELL_MS)
    # bool is an int in Python and `dwell_ms = true` is not a duration.
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        raise ConfigError(f"{source}: dwell_ms must be a number, not {type(raw).__name__}")
    if not 0 <= raw <= 5000:
        raise ConfigError(f"{source}: dwell_ms must be between 0 and 5000 ms, not {raw}")
    return Settings(dwell_ms=int(raw))


def load_config(path: Path) -> tuple[Menu, Settings]:
    """Read a TOML file once and return both halves of what it configures."""
    data = _read(path)
    source = str(path)
    return parse_menu(data, source=source), parse_settings(data, source=source)


def load_menu(path: Path) -> Menu:
    """Read and parse a TOML file. Raises ConfigError on any problem."""
    return parse_menu(_read(path), source=str(path))


def _read(path: Path) -> dict[str, Any]:
    # The source name is the path the user typed, because that is what they
    # have to open to fix whatever comes back.
    source = str(path)
    try:
        with open(path, "rb") as handle:
            return tomllib.load(handle)
    except OSError as exc:
        raise ConfigError(f"{source}: cannot be read: {exc}") from exc
    except UnicodeDecodeError as exc:
        # TOML is UTF-8 text; a binary file is not a menu, and is no crash.
        raise ConfigError(f"{source}: is not UTF-8 text: {exc}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{source}: is not valid TOML: {exc}") from exc
    except RecursionError as exc:
        # Tables nested a few hundred deep exhaust the parser's stack.
        raise ConfigError(f"{source}: is nested too deeply to read") from exc


def submenu(item: MenuItem) -> Menu:
    """The Menu for a submenu item, with Back reserved opposite the direction
    it was entered through.

    Built on demand rather than stored on the item, because the same submenu
    can be reached from more than one direction once a tree is edited, and a
    Back slot baked in at load time would then point the wrong way. The loader
    has already proved the reserved direction is free, so this only has to name
    it.
    """
    return Menu(
        label=item.label,
        items={child.direction: child for child in item.children},
        back=BACK_DIRECTION,
    )
