"""backdrop render lock: the mark alone, inside swaylock's ring."""

import numpy as np

from conftest import (
    H,
    bbox,
    MARK_REACH,
    RING_INNER,
    S,
    W,
    not_base,
    reach,
    rgb,
    where,
)


def test_the_mark_sits_inside_the_ring(lock):
    r = reach(not_base(lock), W / 2, H / 2)
    assert r <= RING_INNER * S, "the mark would run under the ring"
    assert r >= 0.93 * MARK_REACH * S, "the mark is smaller than it should be"


def test_everything_outside_the_mark_is_base(lock):
    ys, xs = np.nonzero(not_base(lock))
    assert len(xs) > 3000
    assert np.hypot(xs - W / 2, ys - H / 2).max() <= RING_INNER * S
    # Base in every corner and along every edge: no fact, logo or clock.
    edge = np.concatenate([lock[0], lock[-1], lock[:, 0], lock[:, -1]])
    assert (edge == rgb("base")).all()


def test_the_mark_is_centered_in_the_accent(lock):
    accent = where(lock, rgb("mauve"))
    assert accent.sum() > 3000
    x0, y0, x1, y1 = bbox(not_base(lock))
    assert abs((x0 + x1) / 2 - W / 2) < 0.03 * MARK_REACH * S
    assert abs((y0 + y1) / 2 - H / 2) < 0.03 * MARK_REACH * S


def test_nothing_but_the_accent_and_its_edges(lock):
    # The only colors are Base, the accent and the blends between them.
    base, accent = np.array(rgb("base")), np.array(rgb("mauve"))
    ys, xs = np.nonzero(not_base(lock))
    px = lock[ys, xs].astype(float)
    # A blend of two colors lies on the segment between them.
    t = (px - base) @ (accent - base) / ((accent - base) @ (accent - base))
    off = np.abs(px - (base + np.outer(t, accent - base))).max()
    assert off < 2.5, "a color other than the accent shows on the lock image"


def test_no_phyllon_mark_no_logo_no_facts_on_the_lock(lock):
    top_left = lock[: int(0.40 * H), : int(0.45 * W)]
    top_right = lock[: int(0.40 * H), W // 2 :]
    assert not not_base(top_left).any()
    assert not not_base(top_right).any()


def test_facts_cannot_reach_the_lock(lab):
    # The lock image never asks for the facts: with none to read, it still
    # renders, and it is the same image.
    plain, _ = lab.render("lock", name="a.png")
    lab.extra_env["BACKDROP_FACTS"] = str(lab.work / "does-not-exist")
    again, proc = lab.render("lock", name="b.png")
    assert (plain == again).all()
    assert lab.journal(proc) == []


def test_tools_do_not_reach_the_lock(lab):
    plain, _ = lab.render("lock", name="a.png")
    lab.write_config(tools=lab.logos("bar", "disc", "tri"))
    with_tools, _ = lab.render("lock", name="b.png")
    assert (plain == with_tools).all()


def test_accent_follows_the_option(lab):
    lab.write_config(accent="teal")
    img, _ = lab.render("lock")
    assert where(img, rgb("teal")).sum() > 3000
    assert not where(img, rgb("mauve")).any()


def test_the_mark_scales_with_the_output(lab):
    img, _ = lab.render("lock", size=(2560, 1600), scale=2)
    assert img.shape == (1600, 2560, 3)
    r = reach(not_base(img), 1280, 800)
    assert 0.93 * MARK_REACH * 2 <= r <= RING_INNER * 2


def test_the_mark_stays_inside_the_ring_at_every_scale(lab):
    for scale in (1, 1.25, 1.5, 1.75, 3):
        size = (int(1000 * scale), int(700 * scale))
        img, _ = lab.render("lock", size=size, scale=scale, name="s%s.png" % scale)
        r = reach(not_base(img), size[0] / 2, size[1] / 2)
        assert r <= RING_INNER * scale, scale
        assert r >= 0.9 * MARK_REACH * scale, scale
