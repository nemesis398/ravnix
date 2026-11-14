"""The NixOS logomark on the wallpaper: the vendored vector logo, in Blue and
Sapphire, where fastfetch's block-glyph logo was and as large as it was."""

import cairo
import gi
import numpy as np
import re
import shutil

from conftest import BAR, H, PHYLLON, S, SHIPPED, W, bbox, rgb, tinted, where

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

LOGO = SHIPPED / "nixos-logomark.svg"

# Where the block-glyph logo was at 2560x1600 and scale 1.25 with the facts
# fixture (measured on the render before the vector logo, as the bounding box
# of its Blue and Sapphire pixels): x0, y0, x1, y1.
OLD_BOX = (1444, 143, 1874, 542)
# The facts and their frame start to the right of the logo.
FIELD = slice(0, int(0.38 * H)), slice(W // 2, int(0.74 * W))


def logo_masks(wall):
    area = wall[FIELD]
    return where(area, rgb("blue")), where(area, rgb("sapphire"))


def arms(wall):
    blue, sapphire = logo_masks(wall)
    both = tinted(wall[FIELD], rgb("blue"), rgb("base"), least=0.05, slack=40) | tinted(
        wall[FIELD], rgb("sapphire"), rgb("base"), least=0.05, slack=40
    )
    return blue, sapphire, both


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
    blue, sapphire, both = arms(wall)
    x0, y0, x1, y1 = bbox(both)
    area = wall[FIELD]
    box = (x0, y0, x1, y1)
    ref = reference(area.shape[1], area.shape[0], box, rgb("blue"), rgb("sapphire"), **kw)
    solid = ref[..., 3] > 200
    mine = blue | sapphire
    ref_blue = solid & (np.abs(ref[..., [2, 1, 0]].astype(int) - np.array(rgb("blue"))).sum(-1) < 30)
    ref_sapphire = solid & (np.abs(ref[..., [2, 1, 0]].astype(int) - np.array(rgb("sapphire"))).sum(-1) < 30)
    wrong = (blue ^ ref_blue) | (sapphire ^ ref_sapphire)
    return wrong.sum() / max(mine.sum(), 1)


def test_the_package_ships_the_logomark_as_a_vector_with_its_credit():
    assert LOGO.is_file() and not LOGO.is_symlink(), LOGO
    text = LOGO.read_text()
    head, _, body = text.partition("-->")
    assert "nixos-artwork" in head and "Creative Commons Attribution 4.0" in head
    assert "<path" in body and "<use" in body
    # No color in the file: backdrop sets the fills of its two classes.
    assert not re.search(r"#[0-9a-fA-F]{3,8}\b", body), "a color in the vector"
    assert "gradient" not in body.lower()


def test_the_logo_is_drawn_in_blue_and_sapphire(wall):
    blue, sapphire, _ = arms(wall)
    assert blue.sum() > 20000 and sapphire.sum() > 20000
    # Three arms of each color, apart: a blob each.
    from conftest import blobs

    assert len(blobs(blue, block=8)) == 3
    assert len(blobs(sapphire, block=8)) == 3
    # The accent is not in it, nor any brand blue.
    area = wall[FIELD][:, : OLD_BOX[2] - W // 2]
    assert not where(area, rgb("mauve")).any()


def test_the_logo_is_where_the_block_logo_was_and_as_large(wall):
    _, _, both = arms(wall)
    x0, y0, x1, y1 = bbox(both)
    x0, x1 = x0 + W // 2, x1 + W // 2
    ox0, oy0, ox1, oy1 = OLD_BOX
    assert oy0 - 3 <= y0 and y1 <= oy1 + 3
    assert ox0 - 3 <= x0 and x1 <= ox1 + 3
    # As large as the old one on the axis that limits it, centered on the other.
    assert (y1 - y0) >= (oy1 - oy0) - 4 or (x1 - x0) >= (ox1 - ox0) - 4
    assert abs((x0 + x1) / 2 - (ox0 + ox1) / 2) <= 3
    assert abs((y0 + y1) / 2 - (oy0 + oy1) / 2) <= 3
    assert y0 > BAR * S


def test_the_logo_is_the_vector_drawing_unchanged(wall):
    # Compared with librsvg's own drawing of the shipped file, fitted to the
    # box the logo takes: a drawing with vector edges, which is neither
    # stepped like the glyphs were nor redrawn.
    assert mismatch(wall) < 0.01


def test_the_logo_is_not_stretched_rotated_mirrored_or_cropped(wall):
    # The proportions are the file's: the ink box of the render and of the
    # file agree to one percent.
    blue, sapphire, both = arms(wall)
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
    solid = where(area, rgb("blue")) | where(area, rgb("sapphire")) | where(area, rgb("base"))
    inner = both[: area.shape[0], : area.shape[1]] & ~solid
    assert inner.sum() > 800


def test_without_the_vector_the_block_logo_stands_in(lab):
    plain = lab.root / "plain-assets"
    plain.mkdir()
    shutil.copy(PHYLLON, plain / "phyllon-mark.svg")
    img, proc = lab.render("wall", name="plain.png", BACKDROP_ASSETS=str(plain))
    lines = lab.journal(proc)
    assert len(lines) >= 1 and any("nixos logo" in l for l in lines), lines
    assert where(img[FIELD], rgb("blue")).sum() > 20000 and where(img[FIELD], rgb("sapphire")).sum() > 20000
    x0, y0, x1, y1 = bbox(where(img[FIELD], rgb("blue")) | where(img[FIELD], rgb("sapphire")))
    # The glyphs themselves: their box is the old one, and the blocks meet
    # without a seam or a ragged edge: no pixel is a blend of Base and a color.
    assert (x0 + W // 2, y0, x1 + W // 2, y1) == OLD_BOX
    logo = img[FIELD][:, : OLD_BOX[2] - W // 2 + 4]
    for name in ("blue", "sapphire"):
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
    assert not where(area, rgb("blue")).any() and not where(area, rgb("sapphire")).any()


def test_the_lock_has_no_logo(lock):
    assert not where(lock, rgb("sapphire")).any()
    assert not where(lock, rgb("blue")).any()


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
