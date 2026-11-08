"""The theme file: where the ring gets its colors, its font and its line widths.

ravnix writes the file (modules/desktop/sway-radial.nix) from the roles of its
theme module, and the program reads it once, when the theme module is imported.
The tests below build their own files from a ramp of grays, so that no test
holds a color of its own, and they run the import in a fresh interpreter, which
is the only way to see what a first import does.
"""

import json
import os
import subprocess
import sys

import pytest

from sway_radial import theme

ROLES = ("accent", "canvas", "deepest", "muted", "secondary", "selected", "text", "wash")


def gray(level):
    return f"#{level:02x}{level:02x}{level:02x}"


def good(**changes):
    data = {
        "roles": {role: gray(16 * (number + 1)) for number, role in enumerate(ROLES)},
        "font": "Some Mono",
        "lineWidth": {"frame": 1, "marker": 2},
    }
    data.update(changes)
    return data


def write(tmp_path, data, name="theme.json"):
    path = tmp_path / name
    path.write_text(data if isinstance(data, str) else json.dumps(data))
    return path


def with_role(role, value):
    data = good()
    data["roles"][role] = value
    return data


def without_role(role):
    data = good()
    del data["roles"][role]
    return data


# -- what a good file gives ---------------------------------------------------


def test_the_roles_are_read_as_cairo_floats(tmp_path):
    loaded = theme.load(write(tmp_path, good()))
    for number, role in enumerate(ROLES):
        level = 16 * (number + 1) / 255
        assert loaded.colors[role] == pytest.approx((level, level, level)), role


def test_the_font_and_the_line_widths_are_read(tmp_path):
    loaded = theme.load(write(tmp_path, good()))
    assert loaded.font == "Some Mono"
    assert loaded.frame == 1.0
    assert loaded.marker == 2.0


def test_roles_the_ring_does_not_use_and_other_keys_are_ignored(tmp_path):
    data = good(extra={"anything": [1, 2, 3]})
    data["roles"]["placeholder"] = gray(7)
    data["roles"]["dock"] = "not read"
    assert theme.load(write(tmp_path, data)).font == "Some Mono"


def test_upper_case_digits_are_colors_too(tmp_path):
    loaded = theme.load(write(tmp_path, with_role("accent", "#ABCDEF")))
    assert loaded.colors["accent"] == pytest.approx((0xAB / 255, 0xCD / 255, 0xEF / 255))


# -- what a bad file gives ----------------------------------------------------

BAD = {
    "not an object": ("[]", "object"),
    "no roles": ({"font": "F", "lineWidth": {"frame": 1, "marker": 2}}, "roles"),
    "roles is a list": (good(roles=[]), "roles"),
    "a role is missing": (without_role("accent"), "accent"),
    "a role is a number": (with_role("canvas", 5), "canvas"),
    "a role is null": (with_role("wash", None), "wash"),
    "a role is a word": (with_role("text", "red"), "text"),
    "a role is too short": (with_role("muted", "#12"), "muted"),
    "a role has no hash": (with_role("selected", "ffffff"), "selected"),
    "a role is not hex": (with_role("secondary", "#12345g"), "secondary"),
    "a role is translucent": (with_role("deepest", "#ffffff80"), "deepest"),
    "a role is empty": (with_role("accent", ""), "accent"),
    "no font": (good(font=None), "font"),
    "empty font": (good(font=""), "font"),
    "font is a number": (good(font=3), "font"),
    "no line widths": ({k: v for k, v in good().items() if k != "lineWidth"}, "lineWidth"),
    "frame is zero": (good(lineWidth={"frame": 0, "marker": 2}), "frame"),
    "frame is negative": (good(lineWidth={"frame": -1, "marker": 2}), "frame"),
    "marker is a string": (good(lineWidth={"frame": 1, "marker": "2"}), "marker"),
    "marker is a bool": (good(lineWidth={"frame": 1, "marker": True}), "marker"),
    "marker is missing": (good(lineWidth={"frame": 1}), "marker"),
    "marker is not a number": (
        '{"roles": %s, "font": "F", "lineWidth": {"frame": 1, "marker": NaN}}'
        % json.dumps(good()["roles"]),
        "marker",
    ),
    "frame is infinite": (
        '{"roles": %s, "font": "F", "lineWidth": {"frame": Infinity, "marker": 2}}'
        % json.dumps(good()["roles"]),
        "frame",
    ),
}


@pytest.mark.parametrize("name", BAD)
def test_a_bad_file_is_refused_and_says_what_is_wrong(tmp_path, name):
    content, culprit = BAD[name]
    path = write(tmp_path, content)
    with pytest.raises(theme.ThemeError) as raised:
        theme.load(path)
    assert str(path) in str(raised.value), "the message does not name the file"
    assert culprit in str(raised.value), "the message does not name what is wrong"


def test_a_missing_file_is_refused(tmp_path):
    with pytest.raises(theme.ThemeError, match="nowhere.json"):
        theme.load(tmp_path / "nowhere.json")


def test_a_directory_is_refused(tmp_path):
    with pytest.raises(theme.ThemeError, match="cannot be read"):
        theme.load(tmp_path)


def test_a_link_to_nothing_is_refused(tmp_path):
    (tmp_path / "theme.json").symlink_to(tmp_path / "nowhere.json")
    with pytest.raises(theme.ThemeError):
        theme.load(tmp_path / "theme.json")


@pytest.mark.parametrize(
    "content",
    [b"", b"\n", b"{", b"\xff\xfe\x00{}", b"{} trailing", b"null", b"[1, 2]", b'"theme"'],
    ids=["empty", "blank", "unclosed", "binary", "trailing text", "null", "list", "string"],
)
def test_a_file_that_is_no_json_object_is_refused(tmp_path, content):
    path = tmp_path / "theme.json"
    path.write_bytes(content)
    with pytest.raises(theme.ThemeError, match="theme.json"):
        theme.load(path)


def test_a_huge_file_is_refused_without_being_read_whole(tmp_path):
    """A theme file is a few hundred bytes; a big one is the wrong file."""
    path = tmp_path / "theme.json"
    path.write_text(json.dumps(good(font="F" * 5_000_000)))
    with pytest.raises(theme.ThemeError, match="too large"):
        theme.load(path)


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads every file")
def test_an_unreadable_file_is_refused(tmp_path):
    path = write(tmp_path, good())
    path.chmod(0)
    with pytest.raises(theme.ThemeError, match="cannot be read"):
        theme.load(path)


def test_deep_nesting_is_refused_and_no_crash(tmp_path):
    path = write(tmp_path, "[" * 10_000)
    with pytest.raises(theme.ThemeError):
        theme.load(path)


# -- where the file is --------------------------------------------------------


def test_the_environment_names_the_file(monkeypatch, tmp_path):
    monkeypatch.setenv(theme.THEME_ENV, str(tmp_path / "mine.json"))
    assert theme.default_path() == tmp_path / "mine.json"


def test_the_config_directory_holds_the_file_by_default(monkeypatch, tmp_path):
    monkeypatch.delenv(theme.THEME_ENV, raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert theme.default_path() == tmp_path / "sway-radial" / "theme.json"


def test_the_home_directory_is_the_last_resort(monkeypatch, tmp_path):
    monkeypatch.delenv(theme.THEME_ENV, raising=False)
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert theme.default_path() == tmp_path / ".config" / "sway-radial" / "theme.json"


def test_an_empty_variable_is_no_variable(monkeypatch, tmp_path):
    monkeypatch.setenv(theme.THEME_ENV, "")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert theme.default_path() == tmp_path / "sway-radial" / "theme.json"


# -- what the ring falls back to ----------------------------------------------


def test_the_fallback_has_every_role_and_a_visible_highlight():
    fallback = theme.fallback()
    assert set(ROLES) <= set(fallback.colors)
    for role, color in fallback.colors.items():
        assert len(color) == 3 and all(0.0 <= c <= 1.0 for c in color), role
    assert fallback.font
    assert fallback.frame > 0 and fallback.marker > 0
    # The lit sector has to stand out from the ones around it, and its label
    # (deepest, drawn on the accent) has to be readable on it.
    assert fallback.colors["accent"] != fallback.colors["wash"]
    assert fallback.colors["accent"] != fallback.colors["canvas"]
    assert fallback.colors["accent"] != fallback.colors["deepest"]


# -- the first import ---------------------------------------------------------


def run_import(env_extra, code):
    env = dict(os.environ)
    env.pop(theme.THEME_ENV, None)
    env.update(env_extra)
    # The interpreter of the tests finds the package through its sys.path, and
    # the child must find it the same way.
    env["PYTHONPATH"] = os.pathsep.join(p for p in sys.path if p)
    return subprocess.run(
        [sys.executable, "-c", code], env=env, capture_output=True, text=True, timeout=60
    )


def test_the_constants_come_from_the_file_on_import(tmp_path):
    path = write(tmp_path, good())
    done = run_import(
        {theme.THEME_ENV: str(path)},
        "from sway_radial import theme\n"
        "print(theme.ACCENT, theme.CANVAS, theme.DEEPEST, theme.WASH, theme.SELECTED,"
        " theme.MUTED, theme.SECONDARY, theme.TEXT, theme.FONT, theme.FRAME, theme.MARKER)",
    )
    assert done.returncode == 0, done.stderr
    expected = theme.load(path)
    parts = [expected.colors[r] for r in ROLES]
    for color in parts:
        assert str(color) in done.stdout
    assert "Some Mono" in done.stdout
    assert done.stderr == ""


def test_a_missing_file_leaves_the_fallback_and_one_error_line(tmp_path):
    missing = tmp_path / "nowhere.json"
    done = run_import(
        {theme.THEME_ENV: str(missing)},
        "from sway_radial import theme\nprint(theme.ACCENT, theme.FONT)",
    )
    assert done.returncode == 0, "a missing theme file stopped the import"
    assert done.stderr.count("\n") == 1 and str(missing) in done.stderr
    fallback = theme.fallback()
    assert str(fallback.colors["accent"]) in done.stdout and fallback.font in done.stdout


def test_a_broken_file_leaves_the_fallback_and_names_the_role(tmp_path):
    path = write(tmp_path, with_role("accent", "teal"))
    done = run_import(
        {theme.THEME_ENV: str(path)},
        "from sway_radial import theme\nprint(theme.ACCENT)",
    )
    assert done.returncode == 0
    assert "accent" in done.stderr and str(path) in done.stderr
    assert str(theme.fallback().colors["accent"]) in done.stdout
