"""backdrop render wall, with no image: the shipped default on Base."""

from conftest import (
    BAR,
    H,
    KERNEL,
    MARK_REACH,
    RING_INNER,
    S,
    W,
    bbox,
    facts_text,
    not_base,
    palette_row_offset,
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


def test_the_palette_row_starts_in_the_value_column(wall):
    # The Palette row is one line that jumps to the column of the values, like
    # the rows above it.
    assert abs(palette_row_offset(facts_area(wall))) < 1.5


def test_the_left_half_below_the_phyllon_mark_is_empty(wall):
    below = wall[H // 2 + int(130 * S) :, : W // 2 - int(130 * S)]
    assert not not_base(below).any()


def test_no_state_hue_in_the_marks(wall):
    # The facts do carry state hues, as fastfetch prints them: the usage
    # percentages turn Yellow and Red, and the Palette row shows the terminal's
    # eight colors. The marks are the part of the wall that owns no state.
    for part in (wall[window(wall, **CENTER)], corner(wall)):
        for warm in ("red", "peach", "maroon", "yellow", "green"):
            assert not where(part, rgb(warm)).any()


def test_the_facts_show_the_usage_states_and_the_palette_row(wall):
    right = facts_area(wall)
    # Yellow and Red are the 62% and 91% of Swap and Disk and the second and
    # fourth of the eight swatches; Green and Teal are swatches only.
    for name in ("yellow", "red", "green", "teal"):
        assert where(right, rgb(name)).sum() > 100, name
    # The eight swatches are one line, in the order of the terminal's colors.
    green, teal = bbox(where(right, rgb("green"))), bbox(where(right, rgb("teal")))
    assert green[1] == teal[1] and green[3] == teal[3], "the swatches are not on one line"
    assert green[2] < teal[0]


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
    ink = not_base(img) & window(img, 1280, 800, 130 * 2)
    # On a screen of 1280x800 logical px the 22 rows of the facts end close
    # above the mark, and their logo's lowest rows fall into the mark's square.
    # The mark has no ink right of 56 % of the width and above 40 % of the
    # height: at its top it is only 190 px from the center.
    ink[: int(0.40 * 1600), int(0.56 * 2560) :] = False
    r = reach(ink, 1280, 800)
    assert 0.93 * MARK_REACH * 2 <= r <= RING_INNER * 2


def test_a_small_screen_still_holds_the_composition(lab):
    img, _ = lab.render("wall", size=(1280, 720), scale=1)
    assert img.shape == (720, 1280, 3)
    assert where(img, rgb("mauve")).sum() > 3000
    assert where(img, rgb("blue")).sum() > 200


def test_the_facts_fixture_is_what_the_tests_assume():
    # Guards the fixture: a change of facts_text would silently weaken the
    # tests of the logo and the facts above.
    text = facts_text()
    assert text.count("\n") == 23
    assert "Palette" in text and "\x1b[30m" in text and "\x1b[37m" in text
    assert "{" not in text and "\\e" not in text, "a placeholder is left"
    assert text.count(KERNEL) == 1
