"""The marks: the wordmark until the ravnix mark ships, then the mark."""

import shutil

from conftest import (
    H,
    MARK_REACH,
    PHYLLON,
    RING_INNER,
    S,
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
    default, _ = lab.render("lock", name="default.png")
    assets(lab, b"<svg this is not xml")
    img, proc = lab.render("lock")
    assert (img == default).all()
    lines = lab.journal(proc)
    assert len(lines) == 1 and "ravnix-mark.svg" in lines[0], lines


def test_an_empty_mark_falls_back_to_the_wordmark_with_one_line(lab):
    default, _ = lab.render("lock", name="default.png")
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


def test_the_lock_image_is_made_again_when_the_mark_ships(lab):
    first = lab.run("lock-args").stdout
    assets(lab, DISC)
    second = lab.run("lock-args").stdout
    assert first != second


def test_the_wordmark_is_in_the_font_of_the_theme(lab):
    # Another family changes the shape of the mark; the corners stay on the circle.
    a, _ = lab.render("lock", name="a.png")
    lab.write_config(font="DejaVu Sans")
    b, _ = lab.render("lock", name="b.png")
    assert (a != b).any()
    r = reach(not_base(b), W / 2, H / 2)
    assert 0.93 * MARK_REACH * S <= r <= RING_INNER * S
    x0, y0, x1, y1 = bbox(not_base(b))
    assert abs((x0 + x1) / 2 - W / 2) < 0.03 * MARK_REACH * S
