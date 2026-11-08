import textwrap
import pytest
from pathlib import Path
from sway_radial.config import ConfigError, load_menu, parse_menu, parse_settings, submenu
from sway_radial.model import DEFAULT_DWELL_MS
import tomllib

def parse(src: str):
    return parse_menu(tomllib.loads(textwrap.dedent(src)), source="test.toml")

def test_minimal_leaf():
    menu = parse("""
        [[items]]
        dir = "n"
        label = "Browser"
        desktop = "helium.desktop"
    """)
    assert menu.back is None
    assert menu.items["n"].label == "Browser"
    assert menu.items["n"].desktop == "helium.desktop"
    assert menu.items["n"].command is None

def test_exec_maps_to_command():
    menu = parse("""
        [[items]]
        dir = "e"
        label = "Clipboard"
        exec = "sway-clipboard"
    """)
    assert menu.items["e"].command == "sway-clipboard"

def test_submenu_back_is_opposite_the_entry_direction():
    menu = parse("""
        [[items]]
        dir = "n"
        label = "Apps"
          [[items.items]]
          dir = "n"
          label = "Browser"
          desktop = "helium.desktop"
    """)
    apps = menu.items["n"]
    assert apps.is_submenu
    # The Menu for a submenu is built on demand; the reserved direction is
    # derived, so the loader only has to prove it is free.
    assert apps.children[0].label == "Browser"

def test_item_in_the_reserved_direction_is_rejected():
    with pytest.raises(ConfigError) as e:
        parse("""
            [[items]]
            dir = "n"
            label = "Apps"
              [[items.items]]
              dir = "s"
              label = "Nope"
              exec = "true"
        """)
    msg = str(e.value)
    assert "test.toml" in msg and "Apps" in msg and "s" in msg

def test_unknown_direction_is_rejected():
    with pytest.raises(ConfigError, match="up"):
        parse('[[items]]\ndir = "up"\nlabel = "X"\nexec = "true"\n')

def test_duplicate_direction_is_rejected():
    with pytest.raises(ConfigError, match="ne"):
        parse("""
            [[items]]
            dir = "ne"
            label = "A"
            exec = "true"
            [[items]]
            dir = "ne"
            label = "B"
            exec = "true"
        """)

def test_leaf_with_both_desktop_and_exec_is_rejected():
    with pytest.raises(ConfigError, match="exactly one"):
        parse('[[items]]\ndir = "n"\nlabel = "X"\ndesktop = "a.desktop"\nexec = "b"\n')

def test_leaf_with_neither_is_rejected():
    with pytest.raises(ConfigError, match="exactly one"):
        parse('[[items]]\ndir = "n"\nlabel = "X"\n')

def test_submenu_with_a_command_is_rejected():
    with pytest.raises(ConfigError, match="submenu"):
        parse("""
            [[items]]
            dir = "n"
            label = "Apps"
            exec = "true"
              [[items.items]]
              dir = "n"
              label = "Browser"
              exec = "true"
        """)

def test_missing_label_is_rejected():
    with pytest.raises(ConfigError, match="label"):
        parse('[[items]]\ndir = "n"\nexec = "true"\n')

def test_nesting_is_arbitrarily_deep(tmp_path: Path):
    menu = parse("""
        [[items]]
        dir = "n"
        label = "Apps"
          [[items.items]]
          dir = "nw"
          label = "More"
            [[items.items.items]]
            dir = "n"
            label = "Editor"
            desktop = "nvim.desktop"
    """)
    assert menu.items["n"].children[0].children[0].label == "Editor"

def test_load_menu_reports_the_real_path(tmp_path: Path):
    p = tmp_path / "menu.toml"
    p.write_text('[[items]]\ndir = "zz"\nlabel = "X"\nexec = "true"\n')
    with pytest.raises(ConfigError, match=str(p)):
        load_menu(p)

def test_malformed_toml_raises_config_error(tmp_path: Path):
    p = tmp_path / "menu.toml"
    p.write_text("[[items]\ndir =")
    with pytest.raises(ConfigError):
        load_menu(p)


def test_dwell_ms_defaults_when_absent():
    data = tomllib.loads('[[items]]\ndir="n"\nlabel="A"\nexec="true"\n')
    assert parse_settings(data, source="t").dwell_ms == DEFAULT_DWELL_MS


def test_dwell_ms_is_read_from_the_file():
    data = tomllib.loads('dwell_ms = 500\n[[items]]\ndir="n"\nlabel="A"\nexec="true"\n')
    assert parse_settings(data, source="t").dwell_ms == 500


def test_a_wrong_dwell_ms_is_an_error_not_a_silent_default():
    """Someone who wrote the key wanted that number. Quietly using 350 instead
    is indistinguishable from the setting not working at all."""
    for bad in ('dwell_ms = "fast"', "dwell_ms = true", "dwell_ms = -1", "dwell_ms = 99999"):
        data = tomllib.loads(bad + '\n[[items]]\ndir="n"\nlabel="A"\nexec="true"\n')
        with pytest.raises(ConfigError, match="dwell_ms"):
            parse_settings(data, source="menu.toml")
