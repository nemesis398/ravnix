"""The menu that ships has to satisfy every rule the loader enforces.

This is not a duplicate of test_config.py. That file proves the loader rejects a
bad tree; this one proves the tree we actually ship is not one, which is the half
that breaks when someone edits the menu and does not restart the daemon.

The menu is the packaged default, ravnix's, which is the public one and holds
nothing personal. SWAY_RADIAL_TEST_MENU points the same tests at another file
(conftest.py), so that whoever sets ravnix.desktop.radial.menu can judge theirs
by the same rules; the tests that are about the default alone say so.

Three tests ask what the machine has, and the sandbox has no machine. Nix hands
them lists (a file of names, one per line) in the variables named below; without
one the test is skipped, and says so.

    SWAY_RADIAL_TEST_PROGRAMS    the commands the menu may run
    SWAY_RADIAL_TEST_DESKTOP_IDS the .desktop ids the menu may launch
"""

import os
import re
from pathlib import Path

import pytest

from sway_radial.config import load_menu, submenu
from sway_radial.model import BACK_DIRECTION, DIRECTIONS
from sway_radial.daemon import _packaged_menu


def test_the_shipped_menu_loads(menu_path):
    load_menu(menu_path)


def test_the_top_ring_uses_all_eight_slots(menu_path):
    # The top ring has no parent and therefore reserves nothing.
    assert set(load_menu(menu_path).items) == set(DIRECTIONS)


def test_no_submenu_ever_fills_its_back_slot(menu_path):
    """Back is south in every ring, and nothing in the menu may claim south.

    Before 2026-09-05 Back sat opposite the entry direction, so this walk had to
    pass the direction in to know where to look. The rule is now fixed, and the
    test is what would catch a menu edit that quietly puts an item back there.
    """

    def walk(menu, path):
        for item in menu.items.values():
            if item.is_submenu:
                sub = submenu(item)
                assert sub.back == BACK_DIRECTION, (path, item.label)
                assert sub.back not in sub.items, (path, item.label)
                walk(sub, (*path, item.label))

    walk(load_menu(menu_path), ())


def test_every_leaf_has_exactly_one_action(menu_path):
    def walk(items):
        for item in items:
            if item.is_submenu:
                walk(item.children)
            else:
                assert bool(item.desktop) ^ bool(item.command), item.label

    walk(tuple(load_menu(menu_path).items.values()))


def test_all_ten_workspaces_are_reachable(menu_path):
    root = load_menu(menu_path)
    found = set()

    def walk(items):
        for item in items:
            if item.is_submenu:
                walk(item.children)
            elif item.command and "workspace number" in item.command:
                found.add(item.command.rsplit(None, 1)[-1])

    walk(tuple(root.items.values()))
    assert found == {str(n) for n in range(1, 11)}


def _leaves(menu):
    def walk(items):
        for item in items:
            if item.is_submenu:
                yield from walk(item.children)
            else:
                yield item

    yield from walk(menu.items.values())


@pytest.mark.machine
def test_every_desktop_id_resolves_on_this_machine(menu_path):
    """A .desktop id that does not resolve is drawn disabled rather than hidden,
    so this never breaks the menu. It does mean a dead item nobody notices, which
    is what this test is for. It needs the applications installed, so it is
    deselected by default (pytest -m machine)."""
    from sway_radial.actions import desktop_exists

    missing = [
        (item.label, item.desktop)
        for item in _leaves(load_menu(menu_path))
        if item.desktop and not desktop_exists(item.desktop)
    ]
    assert not missing


def _names(variable):
    path = os.environ.get(variable)
    if not path:
        pytest.skip(f"{variable} is not set; the Nix check hands it over")
    return {line.strip() for line in Path(path).read_text().splitlines() if line.strip()}


def test_every_desktop_id_is_one_the_desktop_installs(menu_path):
    known = _names("SWAY_RADIAL_TEST_DESKTOP_IDS")
    unknown = [
        (item.label, item.desktop)
        for item in _leaves(load_menu(menu_path))
        if item.desktop and item.desktop.removesuffix(".desktop") not in known
    ]
    assert not unknown, unknown


def test_every_command_runs_a_program_the_desktop_installs(menu_path):
    known = _names("SWAY_RADIAL_TEST_PROGRAMS")
    unknown = []
    for item in _leaves(load_menu(menu_path)):
        if item.command:
            program = item.command.split()[0]
            if program not in known:
                unknown.append((item.label, program))
    assert not unknown, unknown


def test_the_packaged_default_names_no_absolute_path_and_no_home():
    """The default is for every user: a program is a name on the PATH, and a
    path into a home directory or into /usr names a machine."""
    path = _packaged_menu()
    assert path is not None
    text = path.read_text()
    assert "/home/" not in text and "~/" not in text and "$HOME" not in text
    for item in _leaves(load_menu(path)):
        if item.command:
            assert not item.command.startswith("/"), (item.label, item.command)
            assert "/usr/" not in item.command, (item.label, item.command)


def test_the_packaged_default_names_no_sink_and_no_address():
    """A sink name, a Bluetooth address or a PCI address belongs to one machine
    (the menu of a user may hold them; the default may not)."""
    text = _packaged_menu().read_text()
    assert not re.search(r"bluez_|alsa_output|[0-9A-Fa-f]{2}(?:[:_][0-9A-Fa-f]{2}){5}", text)
    assert not re.search(r"\b[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]\b", text)


def test_the_packaged_default_holds_no_mail_address_or_url():
    text = _packaged_menu().read_text()
    assert not re.search(r"[\w.+-]+@[\w-]+\.[\w.-]+", text), "a mail address"
    assert "://" not in text, "a URL"


def _every_item(menu):
    """Every item in the tree, walking children directly.

    Not via submenu(), which needs the direction the ring was entered through in
    order to reserve Back. Nothing here cares about Back.
    """
    def walk(items):
        for item in items:
            yield item
            yield from walk(item.children)

    yield from walk(menu.items.values())


def test_every_icon_is_a_single_character(menu_path):
    """Icons are drawn, not resolved.

    The overlay paints ``item.icon`` as text in JetBrainsMono Nerd Font through
    Cairo's toy API, which does no per-glyph fallback and looks nothing up in an
    icon theme. The menu shipped freedesktop icon *names* until 2026-09-05, so
    every sector drew a truncated word: "applications-other" came out as
    "appl…" sitting on top of its own label. Nothing errored, and the pixel
    tests passed, because drawing a string is exactly what the renderer does.
    """
    offenders = [
        (item.label, item.icon)
        for item in _every_item(load_menu(menu_path))
        if item.icon is not None and len(item.icon) != 1
    ]
    assert offenders == [], offenders
