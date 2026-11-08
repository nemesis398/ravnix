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
    tinted,
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
    # Yellow and Red are the 62% and 91% of Swap and Disk: text, so only the
    # cores of its strokes are exactly the color. The swatches of the Palette
    # row are the terminal's colors without its state hues.
    for name in ("yellow", "red"):
        assert where(right, rgb(name)).sum() > 0, name
    for name in ("pink", "teal", "subtext1"):
        assert where(right, rgb(name)).sum() > 100, name
    # One line, in the order of the terminal's colors.
    pink, teal = bbox(where(right, rgb("pink"))), bbox(where(right, rgb("teal")))
    assert pink[1] == teal[1] and pink[3] == teal[3], "the swatches are not on one line"
    assert pink[2] <= teal[0]


STATE_HUES = ("red", "peach", "maroon", "yellow", "green")


def swatch_row(right):
    """The box of the Teal swatch of the Palette row, the one swatch of the
    facts that nothing else has the color of."""
    teal = bbox(where(right, rgb("teal")))
    assert teal, "no Palette row"
    return teal


def test_the_glyph_blocks_meet_without_a_seam(wall):
    # The logo and the swatches are block glyphs, drawn as the terminal draws
    # them: whole cells with edges on whole pixels. A seam between two blocks,
    # or a ragged edge, is a pixel that is neither a color nor Base but a blend.
    right = facts_area(wall)
    # The logo is everything left of the frame, whose strokes are the leftmost
    # accent of the facts.
    logo = right[:, : bbox(tinted(right, rgb("mauve"), rgb("base"), least=0.3))[0]]
    assert logo.shape[1] > 200
    for name in ("blue", "sapphire"):
        blend = tinted(logo, rgb(name), rgb("base"), least=0.05, slack=6) & ~where(logo, rgb(name))
        assert not blend.any(), "%s: %d blended pixels" % (name, blend.sum())
    # The swatches: one solid rectangle each, one line tall, with Base above
    # and below, and on both sides of the row.
    x0, y0, x1, y1 = swatch_row(right)
    advance = (x1 - x0) / 3
    first, last = int(x0 - 9 * advance), int(x0 + 6 * advance)
    row = right[y0:y1, first - 1 : last + 1]
    assert (row == row[len(row) // 2]).all(), "a seam row inside the swatches"
    assert {tuple(p) for p in row[0]} == {rgb(n) for n in ("base", "surface1", "blue", "pink", "teal", "subtext1")}
    for edge in (right[y0 - 1], right[y1]):
        assert (edge[first - 1 : last + 1] == rgb("base")).all(), "a ragged edge"


def test_the_swatch_row_has_no_state_hue(wall):
    # Style rule 4: warm hues are for warnings and errors. The Palette row is
    # decoration, so the swatches that are Red, Yellow or Green are left out;
    # the percentages of the rows above keep their state colors.
    right = facts_area(wall)
    _, y0, _, y1 = swatch_row(right)
    for hue in STATE_HUES:
        assert not where(right[y0:y1], rgb(hue)).any(), hue


def test_the_swatches_that_stay_keep_their_order_and_close_up(wall):
    # Black, Blue, Pink, Teal and White of the terminal's eight, side by side
    # from the value column; Teal is the fourth.
    right = facts_area(wall)
    x0, y0, x1, y1 = swatch_row(right)
    advance = (x1 - x0) / 3
    first = x0 - 9 * advance
    middle = (y0 + y1) // 2
    row = [tuple(right[middle, int(first + (3 * i + 1.5) * advance)]) for i in range(6)]
    assert row == [rgb(n) for n in ("surface1", "blue", "pink", "teal", "subtext1", "base")], row


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
