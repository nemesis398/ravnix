"""The NixOS logomark on the wallpaper: the vendored vector logo, in Mauve and
Blue (the two ravens' colors), where fastfetch's block-glyph logo was, beside
the facts, with the clear space the branding guide asks for."""

import cairo
import gi
import numpy as np
import pytest
import re
import shutil

from conftest import BAR, H, LOGO_DARK, LOGO_LIGHT, PHYLLON, S, SHIPPED, W, bbox, blobs, rgb, tinted, where

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

LOGO = SHIPPED / "nixos-logomark.svg"

# Where the block-glyph logo was at 2560x1600 and scale 1.25 with the facts
# fixture (measured on the render before the vector logo, as the bounding box
# of its pixels): x0, y0, x1, y1.
OLD_BOX = (1444, 143, 1874, 542)
# The facts and their frame start to the right of the logo.
FIELD = slice(0, int(0.38 * H)), slice(W // 2, int(0.74 * W))


def arms(wall):
    """(dark, light, both): the masks of the dark arms (Mauve) and the light
    arms (Blue) of the logo, and of every pixel that is any blend of the two
    with Base, in the field left of the facts' frame."""
    area = wall[FIELD]
    dark, light = where(area, rgb(LOGO_DARK)), where(area, rgb(LOGO_LIGHT))
    both = tinted(area, rgb(LOGO_DARK), rgb("base"), least=0.05, slack=40) | tinted(
        area, rgb(LOGO_LIGHT), rgb("base"), least=0.05, slack=40
    )
    return dark, light, both


def native_ink():
    """The ink box (x0, y0, x1, y1) of the shipped SVG filling a 500 px square."""
    handle = Rsvg.Handle.new_from_data(LOGO.read_bytes())
    probe = cairo.ImageSurface(cairo.FORMAT_ARGB32, 500, 500)
    rect = Rsvg.Rectangle()
    rect.x, rect.y, rect.width, rect.height = 0, 0, 500, 500
    handle.render_document(cairo.Context(probe), rect)
    probe.flush()
    alpha = np.frombuffer(probe.get_data(), dtype=np.uint8).reshape(500, probe.get_stride() // 4, 4)[:, :500, 3]
    return bbox(alpha > 0)


def reference(width, height, box, dark, light, mirror=False, turn=False):
    """The shipped SVG drawn straight through librsvg, its ink fitted into
    `box` (x0, y0, x1, y1) with each axis scaled on its own, in a plane of
    width by height: the picture that a faithful logo has to match."""
    handle = Rsvg.Handle.new_from_data(LOGO.read_bytes())
    css = ".dark{fill:#%02x%02x%02x}.light{fill:#%02x%02x%02x}" % (*dark, *light)
    handle.set_stylesheet(css.encode())
    unit = 500
    rect = Rsvg.Rectangle()
    rect.x, rect.y, rect.width, rect.height = 0, 0, unit, unit
    ix0, iy0, ix1, iy1 = native_ink()
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    cr = cairo.Context(surf)
    x0, y0, x1, y1 = box
    kx, ky = (x1 - x0) / (ix1 - ix0), (y1 - y0) / (iy1 - iy0)
    cr.translate(x0, y0)
    if mirror:
        cr.translate(x1 - x0, 0)
        cr.scale(-1, 1)
    cr.scale(kx, ky)
    cr.translate(-ix0, -iy0)
    if turn:
        cx, cy = (ix0 + ix1) / 2, (iy0 + iy1) / 2
        cr.translate(cx, cy)
        cr.rotate(3.14159265 / 6)
        cr.translate(-cx, -cy)
    rect.width = rect.height = unit
    handle.render_document(cr, rect)
    surf.flush()
    raw = np.frombuffer(surf.get_data(), dtype=np.uint8).reshape(height, surf.get_stride() // 4, 4)
    return raw[:, :width, :]


def mismatch(wall, **kw):
    """The share of the logo's pixels that differ from the reference's."""
    dark, light, both = arms(wall)
    x0, y0, x1, y1 = bbox(both)
    area = wall[FIELD]
    box = (x0, y0, x1, y1)
    ref = reference(area.shape[1], area.shape[0], box, rgb(LOGO_DARK), rgb(LOGO_LIGHT), **kw)
    solid = ref[..., 3] > 200
    mine = dark | light
    ref_dark = solid & (np.abs(ref[..., [2, 1, 0]].astype(int) - np.array(rgb(LOGO_DARK))).sum(-1) < 30)
    ref_light = solid & (np.abs(ref[..., [2, 1, 0]].astype(int) - np.array(rgb(LOGO_LIGHT))).sum(-1) < 30)
    wrong = (dark ^ ref_dark) | (light ^ ref_light)
    return wrong.sum() / max(mine.sum(), 1)


def test_the_package_ships_the_logomark_as_a_vector_with_its_credit():
    assert LOGO.is_file() and not LOGO.is_symlink(), LOGO
    text = LOGO.read_text()
    head, _, body = text.partition("-->")
    assert "nixos-artwork" in head and "Creative Commons Attribution 4.0" in head
    assert "Simon Frankau" in head and "Tim Cuthbertson" in head and "colors changed" in head
    assert "logo/nix-snowflake-colours.svg" in head and "9d2cdedd73d64a068214482902adea3d02783ba8" in head
    assert "<path" in body and "<use" in body
    # No color in the file: backdrop sets the fills of its two classes.
    assert not re.search(r"#[0-9a-fA-F]{3,8}\b", body), "a color in the vector"
    assert "gradient" not in body.lower()


def test_the_logo_is_drawn_in_mauve_and_blue(wall):
    dark, light, _ = arms(wall)
    assert dark.sum() > 15000 and light.sum() > 15000
    # Three arms of each color, apart: a blob each.
    assert len(blobs(dark, block=8)) == 3
    assert len(blobs(light, block=8)) == 3


def test_the_logo_colors_do_not_follow_the_accent(lab):
    lab.write_config(accent="teal")
    img, _ = lab.render("wall")
    dark, light, _ = arms(img)
    assert dark.sum() > 15000 and light.sum() > 15000
    assert len(blobs(dark, block=8)) == 3


def logo_frame(img):
    """(logo, frame_x, facts_top, facts_bottom): the logo's ink box (x0, y0,
    x1, y1) in image pixels, the leftmost pixel of the facts' frame stroke, and
    the top and bottom of that stroke."""
    h, w = img.shape[:2]
    field = img[: int(0.40 * h), w // 2 :]
    # The frame is the accent's long vertical stroke: the column with the
    # longest unbroken run of strong accent (the arms of the logo are
    # slanted, so their runs are short), and a few pixels wide at larger scales.
    stroke = tinted(field, rgb("mauve"), rgb("base"), least=0.5)

    def run(column):
        best = length = 0
        for on in stroke[:, column]:
            length = length + 1 if on else 0
            best = max(best, length)
        return best

    runs = [run(x) for x in range(stroke.shape[1])]
    col = int(np.argmax(runs))
    ys = np.nonzero(stroke[:, col])[0]
    left = col
    while left > 0 and runs[left - 1] > 0.5 * runs[col]:
        left -= 1
    # The stroke's antialiased skirt is left of it by a pixel or two: the logo
    # is what is more than three pixels left of the stroke.
    left -= 3
    ink = tinted(field[:, :left], rgb(LOGO_DARK), rgb("base"), least=0.05, slack=40) | tinted(
        field[:, :left], rgb(LOGO_LIGHT), rgb("base"), least=0.05, slack=40
    )
    x0, y0, x1, y1 = bbox(ink)
    return (x0 + w // 2, y0, x1 + w // 2, y1), left + 3 + w // 2, int(ys.min()), int(ys.max()) + 1


SIZES = [((1366, 768), 1), ((1920, 1080), 1), ((1920, 1200), 1.25), ((2560, 1600), 1.25), ((3840, 2160), 1.5), ((2880, 1800), 2)]


@pytest.mark.parametrize("size, scale", SIZES)
def test_the_logo_keeps_a_quarter_of_its_height_clear_of_the_facts(lab, size, scale):
    # The NixOS branding guide's minimum clear space is a quarter of the
    # logomark's height. Measured from the logo's ink to the ink of the
    # frame, which stands inside its cell, so it is more than backdrop keeps;
    # a pixel of slack for rounding.
    img, _ = lab.render("wall", size=size, scale=scale)
    (x0, y0, x1, y1), frame, _, _ = logo_frame(img)
    height = y1 - y0
    assert frame - x1 >= height / 4 - 1, "gap %d px for a logo %d px high" % (frame - x1, height)
    # And no more than a cell more: the logo is as large as the rule lets it be.
    assert frame - x1 <= height / 4 + 0.08 * (x1 - x0) + 4, "the logo is smaller than it has to be"


@pytest.mark.parametrize("size, scale", SIZES)
def test_the_logo_is_vertically_centered_beside_the_facts(lab, size, scale):
    img, _ = lab.render("wall", size=size, scale=scale)
    (x0, y0, x1, y1), _, top, bottom = logo_frame(img)
    # The frame's stroke runs from the first row's middle to the last row's;
    # the rows themselves are one line taller than that.
    line = (bottom - top) / 24
    assert abs((y0 + y1) / 2 - (top + bottom) / 2) <= max(3, line), ((y0 + y1) / 2, (top + bottom) / 2)


@pytest.mark.parametrize("size, scale", [((2560, 1600), 1.25), ((1920, 1080), 1)])
def test_short_facts_do_not_push_the_logo_out_of_its_box(lab, size, scale):
    # Facts of five rows beside a logo that is twenty rows high would put the
    # middle of the facts so high that the logo, centered on it, stood partly
    # off the screen or under the bar. It stays inside the box the glyphs
    # covered, as the glyphs would have, and keeps its size.
    full, _ = lab.render("wall", size=size, scale=scale, name="full.png")
    lines = lab.facts_path.read_text().split("\n")
    short = []
    for n, line in enumerate(lines):
        cut = min((line.index(c) for c in "┌├└│" if c in line), default=None)
        short.append(line if n < 5 or cut is None else line[:cut])
    lab.facts_path.write_text("\n".join(short))
    img, _ = lab.render("wall", size=size, scale=scale, name="short.png")
    # The glyph box, from the stand-in: the same facts with no vector.
    plain = lab.root / "glyph-assets"
    plain.mkdir()
    shutil.copy(PHYLLON, plain / "phyllon-mark.svg")
    glyphs, _ = lab.render("wall", size=size, scale=scale, name="glyphs.png", BACKDROP_ASSETS=str(plain))
    h = size[1]
    # Left of the facts' frame, which is where the logo and the glyphs are.
    _, frame, _, _ = logo_frame(full)
    field = lambda a: a[: int(0.40 * h), size[0] // 2 : frame - 4]
    gx0, gy0, gx1, gy1 = bbox(where(field(glyphs), rgb(LOGO_DARK)) | where(field(glyphs), rgb(LOGO_LIGHT)))
    box = bbox(
        tinted(field(img), rgb(LOGO_DARK), rgb("base"), least=0.05, slack=40)
        | tinted(field(img), rgb(LOGO_LIGHT), rgb("base"), least=0.05, slack=40)
    )
    x0, y0, x1, y1 = box
    # A pixel or two of slack: the vector's first and last pixel rows are
    # antialiased, the glyphs' are not.
    assert y0 >= gy0 - 3 and y1 <= gy1 + 3, "the logo left the box of the glyphs: %s vs %s" % ((y0, y1), (gy0, gy1))
    assert y0 > BAR * scale
    fx0, fy0, fx1, fy1 = bbox(
        tinted(field(full), rgb(LOGO_DARK), rgb("base"), least=0.05, slack=40)
        | tinted(field(full), rgb(LOGO_LIGHT), rgb("base"), least=0.05, slack=40)
    )
    assert abs((y1 - y0) - (fy1 - fy0)) <= 1 and abs((x1 - x0) - (fx1 - fx0)) <= 1, "the logo changed its size"


def test_the_logo_starts_where_the_block_logo_did_and_is_smaller(wall):
    _, _, both = arms(wall)
    x0, y0, x1, y1 = bbox(both)
    x0, x1 = x0 + W // 2, x1 + W // 2
    ox0, oy0, ox1, oy1 = OLD_BOX
    assert abs(x0 - ox0) <= 3, "not at the left edge the glyph logo had"
    assert y0 >= oy0 - 3 and y1 <= oy1 + 3 and x1 <= ox1 + 3
    # Smaller than the glyph logo, for the clear space: that one stood 45 px
    # from the facts, and 93 are needed.
    assert (x1 - x0) < (ox1 - ox0) - 40
    assert y0 > BAR * S


def test_the_logo_is_the_vector_drawing_unchanged(wall):
    # Compared with librsvg's own drawing of the shipped file, fitted to the
    # box the logo takes: a drawing with vector edges, which is neither
    # stepped like the glyphs were nor redrawn. At most one pixel in a hundred
    # of the logo may differ: the logo's left edge, top edge and width are
    # whole pixels, so its edges do not fall between two pixels of the
    # reference's fit (measured 0.0088; with edges on fractions it was 0.0169).
    assert mismatch(wall) < 0.01


def test_the_logo_is_not_stretched_rotated_mirrored_or_cropped(wall):
    # The proportions are the file's: the ink box of the render and of the
    # file agree to one percent.
    dark, light, both = arms(wall)
    x0, y0, x1, y1 = bbox(both)
    rx0, ry0, rx1, ry1 = native_ink()
    assert abs((x1 - x0) / (y1 - y0) / ((rx1 - rx0) / (ry1 - ry0)) - 1) < 0.01
    # And the checks above can tell: a mirrored or a turned logo does not match.
    assert mismatch(wall, mirror=True) > 0.1
    assert mismatch(wall, turn=True) > 0.1


def test_the_logo_has_no_stair_steps_on_its_diagonals(wall):
    # The glyph logo had edges with whole-pixel steps and no blended pixel;
    # the vector has antialiased edges: pixels between Base and each color.
    area = wall[FIELD][:, : OLD_BOX[2] - W // 2]
    _, _, both = arms(wall)
    solid = where(area, rgb(LOGO_DARK)) | where(area, rgb(LOGO_LIGHT)) | where(area, rgb("base"))
    inner = both[: area.shape[0], : area.shape[1]] & ~solid
    assert inner.sum() > 800


def test_without_the_vector_the_block_logo_stands_in(lab):
    plain = lab.root / "plain-assets"
    plain.mkdir()
    shutil.copy(PHYLLON, plain / "phyllon-mark.svg")
    img, proc = lab.render("wall", name="plain.png", BACKDROP_ASSETS=str(plain))
    lines = lab.journal(proc)
    assert len(lines) >= 1 and any("nixos logo" in l for l in lines), lines
    dark, light, both = arms(img)
    assert dark.sum() > 15000 and light.sum() > 15000
    x0, y0, x1, y1 = bbox(dark | light)
    # The glyphs themselves: their box is the old one, and the blocks meet
    # without a seam or a ragged edge: no pixel is a blend of Base and a color.
    assert (x0 + W // 2, y0, x1 + W // 2, y1) == OLD_BOX
    logo = img[FIELD][:, : OLD_BOX[2] - W // 2 + 4]
    for name in (LOGO_DARK, LOGO_LIGHT):
        blend = tinted(logo, rgb(name), rgb("base"), least=0.05, slack=6) & ~where(logo, rgb(name))
        assert not blend.any(), "%s: %d blended pixels" % (name, blend.sum())


def test_a_broken_logo_file_falls_back_with_one_line(lab):
    plain = lab.root / "broken-assets"
    plain.mkdir()
    shutil.copy(PHYLLON, plain / "phyllon-mark.svg")
    (plain / "nixos-logomark.svg").write_bytes(b"not an svg")
    img, proc = lab.render("wall", name="broken.png", BACKDROP_ASSETS=str(plain))
    lines = [l for l in lab.journal(proc) if "nixos logo" in l]
    assert len(lines) == 1, lab.journal(proc)
    assert where(img[FIELD], rgb("blue")).sum() > 20000


def test_a_logo_that_draws_nothing_falls_back(lab):
    plain = lab.root / "empty-assets"
    plain.mkdir()
    shutil.copy(PHYLLON, plain / "phyllon-mark.svg")
    (plain / "nixos-logomark.svg").write_bytes(b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>')
    img, proc = lab.render("wall", name="empty.png", BACKDROP_ASSETS=str(plain))
    assert any("nixos logo" in l and "draws nothing" in l for l in lab.journal(proc)), lab.journal(proc)
    assert where(img[FIELD], rgb("blue")).sum() > 20000


def test_facts_with_no_logo_get_none(lab):
    # The facts alone, as fastfetch prints them with no logo: no block glyph
    # left of the frame, so no logo is drawn.
    lines = lab.facts_path.read_text().split("\n")
    # Blocks right of the key "Palette" are the swatches, which stay.
    blank = lambda s: re.sub("[\u2580-\u259f]", " ", s)
    lab.facts_path.write_text(
        "\n".join(blank(l[: l.index("Palette")]) + l[l.index("Palette") :] if "Palette" in l else blank(l) for l in lines)
    )
    img, proc = lab.render("wall", name="nologo.png")
    area = img[FIELD][:, : OLD_BOX[2] - W // 2]
    assert not where(area, rgb(LOGO_LIGHT)).any() and not where(area, rgb(LOGO_DARK)).any()


def test_the_lock_has_no_logo(lock):
    # The lock holds the ravnix mark in the accent, which is Mauve here; the
    # logo's other color is not on it, and nothing is outside the mark.
    assert not where(lock, rgb(LOGO_LIGHT)).any()
    assert not (lock[FIELD] != rgb("base")).any()


def test_the_logo_does_not_move_when_a_fact_changes(lab):
    a, _ = lab.render("wall", name="a.png")
    lab.facts_path.write_text(lab.facts_path.read_text().replace("6.18.2", "6.18.22"))
    b, _ = lab.render("wall", name="b.png")
    assert (a[FIELD][:, : OLD_BOX[2] - W // 2] == b[FIELD][:, : OLD_BOX[2] - W // 2]).all()


def test_a_few_blocks_before_a_word_are_text_and_no_logo(lab):
    # The logo is what a logo is big: three blocks in front of a word stay as
    # the glyphs they are.
    lab.facts_path.write_text("\x1b[38;2;%d;%d;%dm███ text\n" % rgb("blue"))
    img, proc = lab.render("wall", name="few.png")
    assert lab.journal(proc) == []
    assert where(img[FIELD], rgb("blue")).sum() > 100
    assert where(img[FIELD], rgb("blue")).sum() < 3000
