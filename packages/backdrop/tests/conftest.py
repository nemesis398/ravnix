"""Shared pieces of the backdrop tests.

The tests run the command line of backdrop and lock-screen as a user does and
look at the pixels of the PNG it writes. They need no network, no sway and no
fastfetch: sway's swaymsg and swaylock are stand-ins in tests/stubs, and the
facts fastfetch would print come from a file (BACKDROP_FACTS), except in the
one test that runs the real fastfetch (BACKDROP_REAL_FASTFETCH=1).

Environment:
  BACKDROP                 the backdrop program; default: the script in the
                           source tree, run with this interpreter
  LOCK_SCREEN              the lock-screen program; default: the source tree's
  BACKDROP_TEST_PALETTE    a JSON file with the palette (name -> #rrggbb),
                           which Nix writes from modules/theme/palette.nix, so
                           that no test holds a color of its own
  BACKDROP_TEST_PHYLLON    the phyllon mark (assets/phyllon-mark.svg), for the
                           tests that build an assets directory of their own
  BACKDROP_REAL_FASTFETCH  set to 1 to run the tests of the real fastfetch
"""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import cairo
import numpy as np
import pytest

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
STUBS = HERE / "stubs"

# The layout the style spec fixes, in logical px (docs/style.md, Identity).
RING_INNER = 105  # swaylock's ring: radius 110, thickness 10
MARK_REACH = 95  # how far both marks reach from their center
BAR = 32

W, H, S = 2560, 1600, 1.25  # huginn's panel: physical size and the output scale


def command(var, default):
    given = os.environ.get(var)
    return [given] if given else default


# The interpreter of the stand-ins. They name it by its path: the build sandbox
# has no /usr/bin/env.
BASH = shutil.which("bash")

BACKDROP = command("BACKDROP", [sys.executable, str(PKG / "backdrop")])
LOCK_SCREEN = command("LOCK_SCREEN", [str(PKG / "lock-screen")])


PHYLLON = Path(os.environ.get("BACKDROP_TEST_PHYLLON") or PKG.parents[1] / "assets" / "phyllon-mark.svg")


def load_palette():
    path = os.environ.get("BACKDROP_TEST_PALETTE")
    if not path:
        pytest.exit("BACKDROP_TEST_PALETTE names no palette file (see conftest.py)", 2)
    return json.loads(Path(path).read_text())


PALETTE = load_palette()


def rgb(name):
    value = PALETTE[name]
    return tuple(int(value[i : i + 2], 16) for i in (1, 3, 5))


def load_png(path):
    """The image as an array of rows of RGB."""
    surf = cairo.ImageSurface.create_from_png(str(path))
    w, h, stride = surf.get_width(), surf.get_height(), surf.get_stride()
    raw = np.frombuffer(surf.get_data(), dtype=np.uint8).reshape(h, stride // 4, 4)
    return raw[:, :w, [2, 1, 0]].copy()


def where(img, color):
    """The mask of the pixels that are exactly this color."""
    return np.all(img == np.array(color, dtype=np.uint8), axis=-1)


def not_base(img):
    return ~where(img, rgb("base"))


def reach(mask, cx, cy):
    """The farthest distance of a masked pixel from (cx, cy)."""
    ys, xs = np.nonzero(mask)
    return float(np.hypot(xs - cx, ys - cy).max()) if len(xs) else 0.0


def bbox(mask):
    """(x0, y0, x1, y1) of the masked pixels, x1 and y1 exclusive."""
    ys, xs = np.nonzero(mask)
    if not len(xs):
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def blobs(mask, block=4):
    """Bounding boxes of the connected shapes in a mask, in pixels.

    The mask is thinned to the blocks that are solid, so that the hundred
    thousand pixels of a shape are one flood fill of a few hundred cells, and
    the odd antialiased pixel of some text that happens to have the color of a
    gray is no shape."""
    h, w = mask.shape
    h4, w4 = h // block * block, w // block * block
    cells = mask[:h4, :w4].reshape(h4 // block, block, w4 // block, block).all(axis=(1, 3))
    seen = np.zeros_like(cells)
    found = []
    for y0, x0 in zip(*np.nonzero(cells), strict=True):
        if seen[y0, x0]:
            continue
        stack, box = [(y0, x0)], [x0, y0, x0, y0]
        seen[y0, x0] = True
        while stack:
            y, x = stack.pop()
            box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < cells.shape[0] and 0 <= nx < cells.shape[1]:
                        if cells[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
        found.append(((box[0]) * block, (box[1]) * block, (box[2] + 1) * block, (box[3] + 1) * block))
    return found


def window(img, cx, cy, half):
    """A mask of the square of 2*half pixels about (cx, cy)."""
    mask = np.zeros(img.shape[:2], dtype=bool)
    mask[int(cy - half) : int(cy + half), int(cx - half) : int(cx + half)] = True
    return mask


def distance_to_box(px, py, box):
    x0, y0, x1, y1 = box
    return float(np.hypot(max(x0 - px, 0, px - x1), max(y0 - py, 0, py - y1)))


# What the real fastfetch prints with ravnix's own config (modules/common/cli.nix):
# a capture of fastfetch 2.70 on a laptop, the personal values replaced by
# invented ones and the colors by names, so that no test holds a color of its
# own. \e is the escape character, and {blue}, {sapphire}, {accent}, {muted},
# {yellow} and {red} are the "R;G;B" of palette entries. Memory is in the
# accent, Swap in Yellow and Disk in Red, as fastfetch colors a percentage
# that is low, high and over the limit; the Palette row is the eight colors of
# the terminal, of which the wallpaper draws the four that are no state hue, and
# the logo is the NixOS one, in block glyphs, bold.
FASTFETCH = HERE / "fastfetch.ansi"
KERNEL = "6.18.2"  # a value that occurs once, for the tests that change a fact
FASTFETCH_ROLES = {
    "blue": "blue",
    "sapphire": "sapphire",
    "accent": "mauve",
    "muted": "overlay0",
    "yellow": "yellow",
    "red": "red",
}


def facts_text():
    text = FASTFETCH.read_text(encoding="utf-8").replace("\\e", "\x1b")
    for name, entry in FASTFETCH_ROLES.items():
        text = text.replace("{%s}" % name, ";".join(str(c) for c in rgb(entry)))
    return text


def tinted(img, color, base, least=0.45, slack=14):
    """The mask of the pixels that are `color` at least `least` strong over
    `base`, antialiased edges included: on the line from `base` to `color`,
    to within `slack` of the 0 to 255 scale in each channel's sum of squares."""
    base, color = np.array(base, dtype=float), np.array(color, dtype=float)
    d = color - base
    p = img.astype(float) - base
    t = (p @ d) / (d @ d)
    residual = np.linalg.norm(p - t[..., None] * d, axis=-1)
    return (t >= least) & (residual <= slack)


# The hues that carry a state and nothing else (docs/style.md, State; the
# accent rule lists the same six).
STATE_HUES = ("red", "peach", "maroon", "yellow", "green", "blue")

# The swatches of the Palette row on the wallpaper, from the value column: the
# terminal's black, magenta, cyan and white. Red, Green, Yellow and Blue are
# state hues, so they are left out and the rest close up.
SWATCHES = ("surface1", "pink", "teal", "subtext1")


def palette_box(right):
    """(first, last, top, bottom, advance) of the Palette row in the facts area
    `right`: the columns from the first swatch to the end of the last, and the
    rows of the line. Teal is the one swatch that no other part of the facts
    has the color of, so the first swatch starts as many glyphs before it as the
    swatches that come first. Fails when the swatches are on more than one
    line, as the block symbol prints the bright eight on a second line that
    starts under the frame."""
    teal = bbox(where(right, rgb("teal")))
    assert teal, "no Palette row"
    advance = (teal[2] - teal[0]) / 3
    assert teal[3] - teal[1] <= 2.5 * advance, "the Palette swatches are on more than one line"
    first = int(teal[0] - 3 * SWATCHES.index("teal") * advance)
    return first, int(first + 3 * len(SWATCHES) * advance), teal[1], teal[3], advance


def palette_row_offset(right):
    """How far the Palette row starts from the value column, in glyph advances.

    The value column starts at the leftmost pixel of Text, antialiased or not,
    which is where the values of the rows above begin: a line of its own that a
    failing command prints would be to the left of it."""
    first, _, _, _, advance = palette_box(right)
    values = bbox(tinted(right, rgb("text"), rgb("base")))
    return (first - values[0]) / advance


def svg(body):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">%s</svg>' % body
    ).encode()


# Three logos that look nothing alike, drawn in black: backdrop paints each in
# one Surface gray whatever the file says.
LOGOS = {
    "bar": svg('<rect x="0" y="40" width="100" height="20" fill="black"/>'),
    "disc": svg('<circle cx="50" cy="50" r="50" fill="black"/>'),
    "tri": svg('<polygon points="50,0 100,100 0,100" fill="black"/>'),
}


class Lab:
    """One test's home, cache, config and stand-ins."""

    def __init__(self, root):
        self.root = Path(root)
        self.home = self.root / "home"
        self.cache = self.root / "cache"
        self.stubs = self.root / "stubs"
        self.assets = self.root / "assets"
        self.work = self.root / "work"
        self.log = self.root / "swaymsg.log"
        for d in (self.home, self.work, self.stubs):
            d.mkdir(parents=True, exist_ok=True)
        for stub in STUBS.iterdir():
            self.install_stub(stub.name, stub.read_text())
        self.config_path = self.root / "config.json"
        self.facts_path = self.root / "facts.txt"
        self.outputs_path = self.root / "outputs.json"
        self.write_config()
        self.facts_path.write_text(facts_text())
        self.set_outputs([("eDP-1", W, H, S)])
        self.extra_env = {}

    def install_stub(self, name, script):
        """An executable on the stand-in PATH, run by bash."""
        path = self.stubs / name
        path.write_text(script.replace("#!/usr/bin/env bash", "#!" + BASH, 1))
        path.chmod(0o755)
        return path

    def write_config(self, **over):
        config = {
            "palette": PALETTE,
            "accent": "mauve",
            "font": "JetBrainsMono Nerd Font",
            "image": None,
            "tools": [],
        }
        config.update(over)
        config = {k: v for k, v in config.items() if v is not ...}
        self.config_path.write_text(json.dumps(config))
        return config

    def set_outputs(self, outputs):
        """What swaymsg -t get_outputs reports: (name, physical w, h, scale)."""
        data = [
            {
                "name": name,
                "active": True,
                "scale": scale,
                "rect": {"x": 0, "y": 0, "width": round(w / scale), "height": round(h / scale)},
            }
            for name, w, h, scale in outputs
        ]
        self.outputs_path.write_text(json.dumps(data))

    def write(self, name, data, mode="wb"):
        path = self.work / name
        with open(path, mode) as f:
            f.write(data)
        return path

    def logos(self, *names):
        return [str(self.write(n + ".svg", LOGOS[n])) for n in names]

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("SWAY", "WAYLAND"))}
        env.pop("DISPLAY", None)
        env.update(
            PATH=f"{self.stubs}:{os.environ['PATH']}",
            HOME=str(self.home),
            XDG_CACHE_HOME=str(self.cache),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            BACKDROP_CONFIG=str(self.config_path),
            BACKDROP_FACTS=str(self.facts_path),
            STUB_OUTPUTS=str(self.outputs_path),
            STUB_LOG=str(self.log),
            LC_ALL="C.UTF-8",
            PYTHONDONTWRITEBYTECODE="1",
        )
        if self.assets.exists():
            env["BACKDROP_ASSETS"] = str(self.assets)
        env.update(self.extra_env)
        env.update(extra)
        return env

    def run(self, *args, program=None, check=True, timeout=120, **env):
        proc = subprocess.run(
            list(program or BACKDROP) + [str(a) for a in args],
            env=self.env(**env),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if check and proc.returncode != 0:
            raise AssertionError(
                "backdrop %s exited %d\n%s" % (" ".join(map(str, args)), proc.returncode, proc.stderr)
            )
        return proc

    def render(self, kind="wall", size=(W, H), scale=S, name=None, **env):
        out = self.work / (name or "%s.png" % kind)
        proc = self.run("render", kind, out, "%dx%d" % size, scale, **env)
        return load_png(out), proc

    def journal(self, proc):
        """The lines backdrop wrote for the journal."""
        return [l for l in proc.stderr.splitlines() if l.strip()]


@pytest.fixture
def lab(tmp_path):
    return Lab(tmp_path)


@pytest.fixture(scope="session")
def shared(tmp_path_factory):
    """A lab for the tests that only read the default renders."""
    return Lab(tmp_path_factory.mktemp("shared"))


@pytest.fixture(scope="session")
def wall(shared):
    return shared.render("wall")[0]


@pytest.fixture(scope="session")
def lock(shared):
    return shared.render("lock")[0]
