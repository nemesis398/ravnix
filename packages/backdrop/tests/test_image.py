"""A user's image: the wallpaper and the lock image are made from it."""

import os
import struct
import zlib

import cairo
import gi
import numpy as np
import pytest

from conftest import H, MARK_REACH, S, W, reach, rgb, where, window

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

CENTER = dict(cx=W / 2, cy=H / 2, half=130 * S)


def banded_png(path, w=400, h=400):
    """The top tenth Red, the bottom tenth Green, Sky between."""
    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, w, h)
    cr = cairo.Context(surf)
    for color, (top, bottom) in (("red", (0, 0.1)), ("sky", (0.1, 0.9)), ("green", (0.9, 1))):
        cr.set_source_rgb(*(c / 255 for c in rgb(color)))
        cr.rectangle(0, top * h, w, (bottom - top) * h)
        cr.fill()
    surf.write_to_png(str(path))
    return path


def beyond_the_facts(img):
    """The pixels outside the band of the facts, which carry Red, Yellow and
    Green of their own: the usage percentages and the Palette row."""
    outside = np.ones(img.shape[:2], dtype=bool)
    outside[: int(0.40 * img.shape[0]), img.shape[1] // 2 :] = False
    return outside


def test_the_image_covers_the_output(lab):
    # A square image on a wide output: scaled until it covers, then cropped
    # at the middle, so Sky shows everywhere and Red and Green not at all.
    lab.write_config(image=str(banded_png(lab.work / "square.png")))
    img, proc = lab.render("wall")
    assert lab.journal(proc) == []
    sky = where(img, rgb("sky"))
    assert sky[:200].any() and sky[-200:].any()
    assert sky[:, :200].any() and sky[:, -200:].any()
    outside = beyond_the_facts(img)
    assert not where(img, rgb("red"))[outside].any()
    assert not where(img, rgb("green"))[outside].any()
    assert not where(img, rgb("base")).any(), "Base shows: the image does not cover"
    corners = [img[:8, :8], img[:8, -8:], img[-8:, :8], img[-8:, -8:]]
    for c in corners:
        assert (c == rgb("sky")).all()


def test_a_tall_image_is_cropped_to_the_output(lab):
    # 4:3 wide image on a tall output: the sides are cut.
    surf = cairo.ImageSurface(cairo.FORMAT_RGB24, 400, 300)
    cr = cairo.Context(surf)
    cr.set_source_rgb(*(c / 255 for c in rgb("red")))
    cr.paint()
    cr.set_source_rgb(*(c / 255 for c in rgb("sky")))
    cr.rectangle(100, 0, 200, 300)
    cr.fill()
    surf.write_to_png(str(lab.work / "wide.png"))
    lab.write_config(image=str(lab.work / "wide.png"))
    img, _ = lab.render("wall", size=(600, 900), scale=1)
    assert not where(img, rgb("red"))[beyond_the_facts(img)].any()
    assert where(img, rgb("sky"))[:50].any()


def test_the_marks_and_the_facts_sit_on_the_image(lab):
    lab.write_config(image=str(banded_png(lab.work / "square.png")))
    img, _ = lab.render("wall")
    assert where(img, rgb("mauve"))[window(img, **CENTER)].sum() > 3000
    corner = img[: H // 2, : int(0.45 * W)]
    assert where(corner, rgb("mauve")).sum() > 1500
    right = img[: int(0.40 * H), W // 2 :]
    assert where(right, rgb("blue")).sum() > 500
    assert where(right, rgb("sapphire")).sum() > 500
    r = reach(where(img, rgb("mauve")) & window(img, **CENTER), W / 2, H / 2)
    assert r >= 0.93 * MARK_REACH * S


def test_the_lock_is_the_image_with_the_mark_alone(lab):
    lab.write_config(image=str(banded_png(lab.work / "square.png")))
    img, _ = lab.render("lock")
    outside = ~window(img, **CENTER)
    assert (img[outside] == rgb("sky")).all(), "something but the image outside the mark"
    assert where(img, rgb("mauve")).sum() > 3000
    assert not where(img, rgb("blue")).any() and not where(img, rgb("text")).any()


def test_a_jpeg(lab):
    pb = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, 640, 480)
    r, g, b = rgb("lavender")
    pb.fill((r << 24) | (g << 16) | (b << 8) | 0xFF)
    pb.savev(str(lab.work / "photo.jpg"), "jpeg", ["quality"], ["95"])
    lab.write_config(image=str(lab.work / "photo.jpg"))
    img, proc = lab.render("lock")
    assert lab.journal(proc) == []
    sample = img[20:60, 20:60].reshape(-1, 3).mean(axis=0)
    assert np.abs(sample - np.array(rgb("lavender"))).max() < 6


def test_a_translucent_png_lands_on_base(lab):
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 64, 64)
    surf.write_to_png(str(lab.work / "clear.png"))  # fully transparent
    lab.write_config(image=str(lab.work / "clear.png"))
    img, proc = lab.render("lock")
    assert lab.journal(proc) == []
    assert (img[0] == rgb("base")).all()


@pytest.fixture
def default_wall(lab):
    return lab.render("wall", name="default.png")[0]


def test_a_missing_image_falls_back_to_the_default(lab, default_wall):
    lab.write_config(image=str(lab.work / "gone.png"))
    img, proc = lab.render("wall")
    assert proc.returncode == 0
    assert (img == default_wall).all()
    lines = lab.journal(proc)
    assert len(lines) == 1, lines
    assert "gone.png" in lines[0]


def garbage(lab):
    return lab.write("garbage.png", os.urandom(4096))


def truncated(lab):
    full = banded_png(lab.work / "full.png").read_bytes()
    return lab.write("cut.png", full[: len(full) // 2])


def empty(lab):
    return lab.write("empty.png", b"")


def a_directory(lab):
    path = lab.work / "dir.png"
    path.mkdir()
    return path


def huge(lab):
    # A valid 9000 by 9000 PNG of one bit per pixel: ten megabytes of zeros
    # deflate to a few kilobytes, and decoding it would take 250 MB.
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    side = 9000
    rows = (b"\x00" + b"\x00" * ((side + 7) // 8)) * side
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 1, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    return lab.write("huge.png", png)


def unreadable(lab):
    if os.geteuid() == 0:
        pytest.skip("root reads every file")
    path = banded_png(lab.work / "locked.png")
    path.chmod(0)
    return path


@pytest.mark.parametrize("make", [garbage, truncated, empty, a_directory, huge, unreadable])
@pytest.mark.parametrize("kind", ["wall", "lock"])
def test_an_unusable_image_falls_back_with_one_line(lab, kind, make):
    default = lab.render(kind, name="default.png")[0]
    bad = make(lab)
    lab.write_config(image=str(bad))
    img, proc = lab.render(kind)
    assert proc.returncode == 0
    assert (img == default).all()
    lines = lab.journal(proc)
    assert len(lines) == 1, lines
    assert bad.name in lines[0]


def test_an_image_path_with_odd_characters(lab):
    odd = lab.work / "my wall 'paper' äö.png"
    banded_png(odd)
    lab.write_config(image=str(odd))
    img, proc = lab.render("lock")
    assert lab.journal(proc) == []
    assert (img[0, 0] == rgb("sky")).all()


def test_a_relative_image_path_is_refused(lab, default_wall):
    banded_png(lab.work / "rel.png")
    lab.write_config(image="rel.png")
    img, proc = lab.render("wall")
    assert (img == default_wall).all()
    assert len(lab.journal(proc)) == 1
