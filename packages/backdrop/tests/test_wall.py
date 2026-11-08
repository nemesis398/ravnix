"""backdrop render wall, with no image: the shipped default on Base."""

from conftest import (
    BAR,
    H,
    MARK_REACH,
    RING_INNER,
    S,
    W,
    bbox,
    facts_text,
    not_base,
    reach,
    rgb,
    where,
    window,
)

# Where the marks are, in the 2560x1600 image at scale 1.25: a square about
# the center that holds the ravnix mark and the corner quarter that holds the
# phyllon mark.
CENTER = dict(cx=W / 2, cy=H / 2, half=130 * S)


def corner(img):
    return img[: H // 2, : int(0.45 * W)]


def facts_area(img):
    # Right of the middle and above the ravnix mark.
    return img[: int(0.40 * H), W // 2 :]


def test_corners_are_base(wall):
    base = rgb("base")
    for ys in (slice(0, 24), slice(H - 24, H)):
        for xs in (slice(0, 24), slice(W - 24, W)):
            assert (wall[ys, xs] == base).all()


def test_the_image_has_the_physical_size(wall):
    assert wall.shape == (H, W, 3)


def test_mark_is_centered_in_the_accent(wall):
    mask = window(wall, **CENTER)
    accent = where(wall, rgb("mauve")) & mask
    assert accent.sum() > 3000, "the mark has too few accent pixels to read"
    x0, y0, x1, y1 = bbox(not_base(wall) & mask)
    assert abs((x0 + x1) / 2 - W / 2) < 0.03 * MARK_REACH * S
    assert abs((y0 + y1) / 2 - H / 2) < 0.03 * MARK_REACH * S
    # Drawn in one color and nothing else: every other pixel is Base or a
    # blend of the two along an edge, so no state hue and no Text.
    for other in ("blue", "sapphire", "red", "peach", "yellow", "green", "text"):
        assert not (where(wall, rgb(other)) & mask).any()


def test_mark_sits_inside_the_ring(wall):
    r = reach(not_base(wall) & window(wall, **CENTER), W / 2, H / 2)
    assert r <= RING_INNER * S
    assert r >= 0.93 * MARK_REACH * S, "the mark is smaller than it should be"


def test_phyllon_mark_is_top_left_at_the_size_of_the_mark(wall):
    region = not_base(corner(wall))
    box = bbox(region)
    assert box is not None, "nothing is drawn top left"
    x0, y0, x1, y1 = box
    assert x0 < 0.12 * W and y0 < 0.12 * H, "the phyllon mark is not in the corner"
    assert y0 > BAR * S, "the bar would cover the mark"
    assert where(corner(wall), rgb("mauve")).sum() > 1500
    for other in ("blue", "sapphire", "text"):
        assert not where(corner(wall), rgb(other)).any()
    phyllon = reach(region, (x0 + x1) / 2, (y0 + y1) / 2)
    ravnix = reach(not_base(wall) & window(wall, **CENTER), W / 2, H / 2)
    assert abs(phyllon - ravnix) <= 0.05 * ravnix, "the two marks differ in size"


def test_nixos_logo_and_facts_are_top_right(wall):
    right = facts_area(wall)
    blue, sapphire = where(right, rgb("blue")), where(right, rgb("sapphire"))
    assert blue.sum() > 500 and sapphire.sum() > 500
    assert where(right, rgb("text")).sum() > 100, "no fact in Text"
    assert where(right, rgb("mauve")).sum() > 100, "no key in the accent"
    x0, y0, x1, y1 = bbox(not_base(right))
    assert y0 > BAR * S
    assert (x0 + x1) / 2 + W // 2 > 0.6 * W
    assert (y0 + y1) / 2 < 0.4 * H
    assert x1 < right.shape[1] - 8, "the facts run into the screen's edge"
    # The logo comes first, then the facts.
    assert bbox(blue)[0] < bbox(where(right, rgb("mauve")))[0]


def test_the_left_half_below_the_phyllon_mark_is_empty(wall):
    below = wall[H // 2 + int(130 * S) :, : W // 2 - int(130 * S)]
    assert not not_base(below).any()


def test_no_state_hue_on_the_wall(wall):
    for warm in ("red", "peach", "maroon", "yellow", "green"):
        assert not where(wall, rgb(warm)).any()


def test_the_default_wall_is_deterministic(shared, wall):
    again, _ = shared.render("wall", name="again.png")
    assert (again == wall).all()


def test_accent_follows_the_option(lab):
    lab.write_config(accent="teal")
    img, _ = lab.render("wall")
    for part in (img[window(img, **CENTER)], corner(img)):
        assert where(part, rgb("teal")).sum() > 1500
        assert not where(part, rgb("mauve")).any()


def test_scale_two_renders_at_the_physical_resolution(lab):
    img, _ = lab.render("wall", size=(2560, 1600), scale=2)
    assert img.shape == (1600, 2560, 3)
    r = reach(not_base(img) & window(img, 1280, 800, 130 * 2), 1280, 800)
    assert 0.93 * MARK_REACH * 2 <= r <= RING_INNER * 2


def test_a_small_screen_still_holds_the_composition(lab):
    img, _ = lab.render("wall", size=(1280, 720), scale=1)
    assert img.shape == (720, 1280, 3)
    assert where(img, rgb("mauve")).sum() > 3000
    assert where(img, rgb("blue")).sum() > 200


def test_the_facts_fixture_is_what_the_tests_assume():
    # Guards the fixture: a change of facts_text would silently weaken the
    # tests of the logo and the facts above.
    assert facts_text().count("\n") == 19
