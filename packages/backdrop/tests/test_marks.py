"""The marks: the ravnix mark the package ships, and the wordmark when it is
missing or cannot be drawn."""

import math
import shutil

from conftest import (
    H,
    LOGO_MONO,
    MARK_REACH,
    PHYLLON,
    RING_INNER,
    S,
    SHIPPED,
    W,
    bbox,
    not_base,
    reach,
    rgb,
    where,
    window,
)

CENTER = dict(cx=W / 2, cy=H / 2, half=130 * S)

# A solid disc across the whole of its box: nothing like the wordmark.
DISC = (
    b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
    b'<circle cx="50" cy="50" r="46" fill="black"/></svg>'
)


def assets(lab, ravnix_mark=None, phyllon=True):
    lab.assets.mkdir()
    if phyllon:
        shutil.copy(PHYLLON, lab.assets / "phyllon-mark.svg")
    if ravnix_mark is not None:
        (lab.assets / "ravnix-mark.svg").write_bytes(ravnix_mark)


def wordmark(lab, kind="lock"):
    """The image as it is without a ravnix mark: the wordmark."""
    plain = lab.root / "plain-assets"
    if not plain.exists():
        plain.mkdir()
        (plain / "phyllon-mark.svg").write_bytes(PHYLLON.read_bytes())
    return lab.render(kind, name="wordmark-%s.png" % kind, BACKDROP_ASSETS=str(plain))[0]


# The mark of docs/brand/logo-mono.svg in its own units (viewBox 14 14 132
# 132, center 80 80): the beak tip of the upper raven at (18, 52) is its
# farthest point, and the eyes are holes of radius 5 at (44, 52) and (116, 108).
TIP = math.hypot(18 - 80, 52 - 80)
EYES = ((44 - 80, 52 - 80), (116 - 80, 108 - 80))


def test_the_package_ships_the_mark_of_the_brand_guide():
    # A copy, not a link and not a redrawing: the one-color form with the
    # eyes cut out, so that the eyes stay holes when it is drawn in the accent.
    shipped = SHIPPED / "ravnix-mark.svg"
    assert shipped.is_file() and not shipped.is_symlink(), shipped
    assert shipped.read_bytes() == LOGO_MONO.read_bytes()


def test_the_shipped_mark_is_drawn_and_not_the_wordmark(lab):
    for kind in ("lock", "wall"):
        img, proc = lab.render(kind, name=kind + ".png")
        assert lab.journal(proc) == []
        assert (img != wordmark(lab, kind)).any(), kind


def test_the_shipped_mark_reaches_as_far_as_the_phyllon_mark_inside_the_ring(lock):
    r = reach(not_base(lock), W / 2, H / 2)
    assert 0.97 * MARK_REACH * S <= r <= 1.02 * MARK_REACH * S
    assert r <= RING_INNER * S


def test_the_shipped_mark_has_its_eyes_cut_out(lock):
    # Each eye is Base in the middle and the accent a little outside it, in
    # all four directions, so the eyes show as holes and the ravens are the
    # right way round (the upper one looks left).
    k = reach(not_base(lock), W / 2, H / 2) / TIP  # px per unit of the SVG
    for ex, ey in EYES:
        cx, cy = W / 2 + ex * k, H / 2 + ey * k
        assert tuple(lock[round(cy), round(cx)]) == rgb("base"), (ex, ey)
        for dx, dy in ((8, 0), (-8, 0), (0, 8), (0, -8)):
            px = lock[round(cy + dy * k), round(cx + dx * k)]
            assert tuple(px) == rgb("mauve"), (ex, ey, dx, dy)


def test_the_shipped_mark_replaces_the_wordmark_in_the_accent(lab):
    assets(lab, DISC)
    for kind in ("wall", "lock"):
        img, proc = lab.render(kind, name=kind + ".png")
        assert lab.journal(proc) == []
        # A disc of 46 of the box's 100 units: solid at the center and at
        # three quarters of the way out, where the wordmark has gaps.
        r = int(0.40 * 102.5 * S)
        for dx, dy in [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r)]:
            assert tuple(img[H // 2 + dy, W // 2 + dx]) == rgb("mauve"), (kind, dx, dy)
        edge = reach(not_base(img) & window(img, **CENTER), W / 2, H / 2)
        assert 0.9 * 0.92 * 102.5 * S <= edge <= RING_INNER * S


def test_the_shipped_mark_is_drawn_in_one_color_whatever_it_says(lab):
    colored = (
        b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
        b'<rect width="100" height="50" fill="red"/><rect y="50" width="100" height="50" fill="lime"/></svg>'
    )
    assets(lab, colored)
    img, _ = lab.render("lock")
    assert where(img, rgb("mauve")).sum() > 10000
    assert not where(img, (255, 0, 0)).any() and not where(img, (0, 255, 0)).any()


def test_a_broken_mark_falls_back_to_the_wordmark_with_one_line(lab):
    default = wordmark(lab)
    assets(lab, b"<svg this is not xml")
    img, proc = lab.render("lock")
    assert (img == default).all()
    lines = lab.journal(proc)
    assert len(lines) == 1 and "ravnix-mark.svg" in lines[0], lines


def test_an_empty_mark_falls_back_to_the_wordmark_with_one_line(lab):
    default = wordmark(lab)
    assets(lab, b"")
    img, proc = lab.render("lock")
    assert (img == default).all()
    assert len(lab.journal(proc)) == 1


def test_a_missing_phyllon_mark_leaves_the_rest_of_the_wallpaper(lab):
    assets(lab, phyllon=False)
    img, proc = lab.render("wall")
    assert proc.returncode == 0
    assert not not_base(img[: int(0.40 * H), : int(0.45 * W)]).any()
    assert where(img, rgb("mauve"))[window(img, **CENTER)].sum() > 3000
    assert where(img[: int(0.40 * H), W // 2 :], rgb("blue")).sum() > 500
    lines = lab.journal(proc)
    assert len(lines) == 1 and "phyllon" in lines[0], lines


def test_a_mark_that_draws_nothing_falls_back_to_the_wordmark_with_one_line(lab):
    default = wordmark(lab)
    assets(lab, b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"/>')
    img, proc = lab.render("lock")
    assert (img == default).all()
    lines = lab.journal(proc)
    assert len(lines) == 1 and "ravnix-mark.svg" in lines[0], lines


def test_the_lock_image_is_made_again_when_the_mark_ships(lab):
    assets(lab)
    first = lab.run("lock-args").stdout
    (lab.assets / "ravnix-mark.svg").write_bytes(DISC)
    second = lab.run("lock-args").stdout
    assert first != second


def test_the_wordmark_is_in_the_font_of_the_theme(lab):
    # Another family changes the shape of the mark; the corners stay on the circle.
    assets(lab)
    a, _ = lab.render("lock", name="a.png")
    lab.write_config(font="DejaVu Sans")
    b, _ = lab.render("lock", name="b.png")
    assert (a != b).any()
    r = reach(not_base(b), W / 2, H / 2)
    assert 0.93 * MARK_REACH * S <= r <= RING_INNER * S
    x0, y0, x1, y1 = bbox(not_base(b))
    assert abs((x0 + x1) / 2 - W / 2) < 0.03 * MARK_REACH * S
