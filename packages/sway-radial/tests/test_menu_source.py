"""Which menu the daemon starts with, and what a bad menu file does to it.

ravnix hands the daemon a menu file (ravnix.desktop.radial.menu, or the packaged
default when the option is null). The file is the user's, so everything a file
can be goes through here: missing, empty, binary, not TOML, TOML of the wrong
shape, nested until the parser gives up, a directory, a link to nothing, and
one the user may not read. None of them may stop the daemon, and none may leave
it without a menu: at start the packaged default takes over, and on a reload
the menu that is already loaded stays.
"""

import logging
import os
import sys
import time
import tomllib

import pytest

from sway_radial.config import ConfigError, load_menu, parse_menu
from sway_radial.daemon import Daemon, _packaged_menu

ONE_ITEM = '[[items]]\ndir = "n"\nlabel = "{label}"\nexec = "true"\n'


def deeply_nested(levels: int) -> str:
    """A menu in inline tables, one inside the other `levels` times."""
    inner = '[{dir = "n", label = "leaf", exec = "true"}]'
    for number in range(levels):
        inner = '[{dir = "n", label = "level %d", items = %s}]' % (number, inner)
    return "items = " + inner + "\n"


def header_nested(levels: int) -> str:
    """A menu nested through [[items.items...]] headers, `levels` deep.

    tomllib reads these without recursing (up to the length of a key it allows),
    so the data arrives whole at parse_menu, unlike the inline tables above,
    which the parser itself gives up on. Each level is a submenu holding the
    next; the last is a leaf.
    """
    lines = []
    for number in range(levels):
        lines += ["[[" + ".".join(["items"] * (number + 1)) + "]]", 'dir = "n"', 'label = "level %d"' % number]
    lines.append('exec = "true"')
    return "\n".join(lines) + "\n"


# Every kind of bad file, as the bytes it holds. "directory" and the links are
# made by hand in `make_bad`, because they are no content.
BAD_CONTENT = {
    "empty": b"",
    "blank": b"\n\n   \n",
    "binary": b"\xff\xfe\x00\x01\x02garbage\x00",
    "not toml": b"[[items]\nbroken",
    "no items": b"dwell_ms = 500\n",
    "items is a number": b"items = 3\n",
    "items is empty": b"items = []\n",
    "direction missing": b'[[items]]\nlabel = "A"\nexec = "true"\n',
    "direction unknown": b'[[items]]\ndir = "up"\nlabel = "A"\nexec = "true"\n',
    "direction taken twice": (ONE_ITEM.format(label="A") * 2).encode(),
    "back slot used": (
        b'[[items]]\ndir = "n"\nlabel = "A"\n'
        b'  [[items.items]]\n  dir = "s"\n  label = "B"\n  exec = "true"\n'
    ),
    "leaf without an action": b'[[items]]\ndir = "n"\nlabel = "A"\n',
    "leaf with two actions": b'[[items]]\ndir = "n"\nlabel = "A"\nexec = "x"\ndesktop = "y"\n',
    "empty label": b'[[items]]\ndir = "n"\nlabel = ""\nexec = "true"\n',
    "dwell is a string": b'dwell_ms = "slow"\n' + ONE_ITEM.format(label="A").encode(),
    "dwell is huge": b"dwell_ms = 99999999\n" + ONE_ITEM.format(label="A").encode(),
    "nested too deeply": deeply_nested(3000).encode(),
    # As deep as tomllib's own limit on the parts of a key allows (1000), which
    # is deeper than the interpreter's stack allows parse_menu to walk. Which of
    # the two guards stops it depends on the Python; the test below pins the
    # second.
    "nested too deeply by headers": header_nested(1000).encode(),
}


def make_bad(path, kind):
    """Make `path`, which does not exist yet, a bad menu file of this kind."""
    if kind == "directory":
        path.mkdir()
    elif kind == "link to nothing":
        path.symlink_to(path.parent / "nowhere.toml")
    elif kind == "missing":
        pass
    elif kind == "unreadable":
        path.write_text(ONE_ITEM.format(label="A"))
        path.chmod(0)
    else:
        path.write_bytes(BAD_CONTENT[kind])


KINDS = [*BAD_CONTENT, "directory", "link to nothing", "missing", "unreadable"]


def skip_if_unreadable_is_readable(kind):
    if kind == "unreadable" and os.geteuid() == 0:
        pytest.skip("root reads every file")


def test_a_menu_file_is_the_menu(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text(ONE_ITEM.format(label="Mine"))
    daemon = Daemon(config_path=path)
    assert set(daemon.menu.items) == {"n"}
    assert daemon.menu.items["n"].label == "Mine"


def test_a_menu_file_behind_a_link_is_the_menu(tmp_path):
    """home-manager links ~/.config/sway-radial/menu.toml into the Nix store."""
    real = tmp_path / "store-menu.toml"
    real.write_text(ONE_ITEM.format(label="Linked"))
    link = tmp_path / "menu.toml"
    link.symlink_to(real)
    assert Daemon(config_path=link).menu.items["n"].label == "Linked"


def test_the_settings_of_the_file_are_used(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text("dwell_ms = 321\n" + ONE_ITEM.format(label="A"))
    assert Daemon(config_path=path).settings.dwell_ms == 321


@pytest.mark.parametrize("kind", KINDS)
def test_a_bad_menu_file_at_start_falls_back_to_the_packaged_default(tmp_path, caplog, kind):
    skip_if_unreadable_is_readable(kind)
    path = tmp_path / "menu.toml"
    make_bad(path, kind)
    packaged = load_menu(_packaged_menu())
    daemon = Daemon(config_path=path)
    assert daemon.menu == packaged, "the daemon has a different menu than the packaged default"
    assert any(r.levelname == "ERROR" and str(path) in r.getMessage() for r in caplog.records), (
        "the log does not name the file"
    )


@pytest.mark.parametrize("kind", KINDS)
def test_a_bad_menu_file_on_reload_keeps_the_loaded_menu(tmp_path, caplog, kind):
    skip_if_unreadable_is_readable(kind)
    path = tmp_path / "menu.toml"
    path.write_text(ONE_ITEM.format(label="Before"))
    daemon = Daemon(config_path=path)
    before, machine = daemon.menu, daemon._machine

    # Replace the file by the bad one, the way a deploy would.
    path.unlink()
    make_bad(path, kind)
    daemon._on_config_changed()

    assert daemon.menu is before
    assert daemon._machine is machine
    assert any(r.levelname == "ERROR" and "reload failed" in r.getMessage() for r in caplog.records)


def test_the_menu_is_read_again_when_a_bad_file_is_mended(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text(ONE_ITEM.format(label="Before"))
    daemon = Daemon(config_path=path)
    path.write_text("[[items]\nbroken")
    daemon._on_config_changed()
    path.write_text(ONE_ITEM.format(label="After"))
    daemon._on_config_changed()
    assert daemon.menu.items["n"].label == "After"


def test_a_huge_menu_file_of_comments_still_loads(tmp_path):
    """A megabyte of comment lines before the one item: slow parsers fail this."""
    path = tmp_path / "menu.toml"
    path.write_text("# " + "x" * 60 + "\n" * 1 + ("# comment line\n" * 100_000) + ONE_ITEM.format(label="Far"))
    started = time.monotonic()
    daemon = Daemon(config_path=path)
    assert daemon.menu.items["n"].label == "Far"
    assert time.monotonic() - started < 10, "a large file took too long to read"


def test_a_huge_label_is_refused_or_kept_but_never_a_crash(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text(ONE_ITEM.format(label="L" * 1_000_000))
    daemon = Daemon(config_path=path)
    assert daemon.menu is not None


def test_a_nested_menu_is_a_config_error_and_no_crash(tmp_path):
    path = tmp_path / "menu.toml"
    path.write_text(deeply_nested(3000))
    with pytest.raises(ConfigError, match="nested"):
        load_menu(path)


def test_the_packaged_default_is_found_beside_the_package():
    """The fallback needs a file, and the installed layout puts it one level
    above the package (lib/sway-radial/menu.toml)."""
    path = _packaged_menu()
    assert path is not None and path.is_file()
    assert path.name == "menu.toml"


def test_the_daemon_stays_up_when_the_default_is_missing_too(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr("sway_radial.daemon._packaged_menu", lambda: None)
    caplog.set_level(logging.ERROR)
    daemon = Daemon(config_path=tmp_path / "nowhere.toml")
    assert daemon.menu is None
    assert "no packaged default menu" in caplog.text


def test_the_guard_in_parse_menu_stops_a_menu_nested_by_headers():
    """The second RecursionError guard, the one tomllib never reaches.

    The data is read at the normal limit, and the walk is run on a stack that
    has room for fewer levels than the menu has, so the test does not depend on
    how large the interpreter's limit is. At the normal limit the same data
    loads: it is the depth of the walk that is refused, not the shape.
    """
    data = tomllib.loads(header_nested(300))
    assert parse_menu(data, source="t").items["n"].children  # loads when there is room

    frames, frame = 0, sys._getframe()
    while frame is not None:
        frames, frame = frames + 1, frame.f_back
    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(frames + 100)
    try:
        with pytest.raises(ConfigError, match="nested too deeply"):
            parse_menu(data, source="t")
    finally:
        sys.setrecursionlimit(limit)
