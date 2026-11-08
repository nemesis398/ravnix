"""The tool logos: optional, on the wallpaper only, spread around the rest."""

import numpy as np
import pytest

from conftest import (
    H,
    KERNEL,
    S,
    W,
    bbox,
    blobs,
    distance_to_box,
    facts_text,
    not_base,
    rgb,
    where,
)

MARK_RADIUS = 102.5 * S  # the square the marks are drawn in, about its center


@pytest.fixture(autouse=True)
def facts_with_no_surface1(lab):
    # The Palette row of the facts paints the terminal's black swatch in
    # Surface1, which is also the gray of every other tool logo, and these
    # tests count the gray shapes. The swatch gets the terminal's magenta
    # (Pink) instead: it keeps its place and size, so the clearance from the
    # facts is still measured against the whole panel.
    lab.facts_path.write_text(facts_text().replace("\x1b[30m", "\x1b[35m"))


def grays(img):
    return where(img, rgb("surface1")), where(img, rgb("surface2"))


def test_no_tools_by_default(lab):
    img, _ = lab.render("wall")
    one, two = grays(img)
    assert blobs(one | two) == []


def test_each_logo_appears_once_alternately_in_surface1_and_surface2(lab):
    names = ("bar", "disc", "tri", "bar", "disc", "tri")
    lab.write_config(tools=lab.logos(*names))
    img, proc = lab.render("wall")
    assert lab.journal(proc) == []
    one, two = grays(img)
    # Logos 0, 2, 4 are Surface2 and 1, 3, 5 Surface1, as on Fedora.
    assert len(blobs(two)) == 3, blobs(two)
    assert len(blobs(one)) == 3, blobs(one)


def test_a_logo_is_drawn_in_one_gray_whatever_its_file_says(lab):
    colored = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">' \
        b'<rect width="10" height="10" fill="red"/><circle cx="5" cy="5" r="3" fill="lime"/></svg>'
    lab.write_config(tools=[str(lab.write("colored.svg", colored))])
    img, _ = lab.render("wall")
    assert len(blobs(grays(img)[0] | grays(img)[1])) == 1
    assert not where(img, (255, 0, 0)).any() and not where(img, (0, 255, 0)).any()


def test_logos_keep_clear_of_the_marks_and_the_facts(lab):
    bare, _ = lab.render("wall", name="bare.png")
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 6))
    img, _ = lab.render("wall", name="tools.png")
    one, two = grays(img)
    boxes = blobs(one | two)
    assert len(boxes) == 18
    facts = bbox(not_base(bare[: int(0.40 * H), W // 2 :]))
    facts = (facts[0] + W // 2, facts[1], facts[2] + W // 2, facts[3])
    for x0, y0, x1, y1 in boxes:
        # Nothing touches the screen's edge.
        assert x0 > 0 and y0 > 0 and x1 < W and y1 < H
        # Clear of the ravnix mark and the phyllon mark: both are discs
        # of the square the marks are drawn in.
        assert distance_to_box(W / 2, H / 2, (x0, y0, x1, y1)) > MARK_RADIUS
        margin = bbox(not_base(bare[: H // 2, : int(0.45 * W)]))
        pc = ((margin[0] + margin[2]) / 2, (margin[1] + margin[3]) / 2)
        assert distance_to_box(pc[0], pc[1], (x0, y0, x1, y1)) > MARK_RADIUS * 0.9
        # Clear of the facts' box: no overlap, and not under it.
        assert x1 <= facts[0] or x0 >= facts[2] or y1 <= facts[1] or y0 >= facts[3]


def test_logos_do_not_overlap_each_other(lab):
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 6))
    img, _ = lab.render("wall")
    one, two = grays(img)
    boxes = blobs(one | two)
    for i, a in enumerate(boxes):
        for b in boxes[i + 1 :]:
            assert a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1], (a, b)


def test_the_marks_and_the_facts_are_the_same_with_tools(lab):
    bare, _ = lab.render("wall", name="bare.png")
    lab.write_config(tools=lab.logos("bar", "disc", "tri"))
    img, _ = lab.render("wall", name="tools.png")
    one, two = grays(img)
    boxes = blobs(one | two)
    assert len(boxes) == 3
    inside = np.zeros(bare.shape[:2], dtype=bool)
    for x0, y0, x1, y1 in boxes:
        inside[max(y0 - 16, 0) : y1 + 16, max(x0 - 16, 0) : x1 + 16] = True
    differs = np.any(bare != img, axis=-1)
    assert not (differs & ~inside).any(), "tools changed more than their own pixels"


def test_the_spread_is_the_same_on_every_render(lab):
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 4))
    a, _ = lab.render("wall", name="a.png")
    b, _ = lab.render("wall", name="b.png")
    assert (a == b).all()


def test_the_logos_do_not_move_when_a_fact_changes(lab):
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 4))
    a, _ = lab.render("wall", name="a.png")
    text = lab.facts_path.read_text().replace(KERNEL, "a much longer value than before")
    lab.facts_path.write_text(text)
    b, _ = lab.render("wall", name="b.png")
    assert blobs(grays(a)[0] | grays(a)[1]) == blobs(grays(b)[0] | grays(b)[1])


def test_a_missing_or_broken_logo_is_skipped_with_one_line(lab):
    broken = lab.write("broken.svg", b"<svg this is not xml")
    empty = lab.write("empty.svg", b"")
    lab.write_config(tools=[str(lab.work / "gone.svg"), str(broken), str(empty), *lab.logos("disc")])
    img, proc = lab.render("wall")
    assert proc.returncode == 0
    assert len(blobs(grays(img)[0] | grays(img)[1])) == 1
    lines = lab.journal(proc)
    assert len(lines) == 3, lines
    assert any("gone.svg" in l for l in lines)
    assert any("broken.svg" in l for l in lines)


def test_an_empty_list_is_no_tools(lab):
    lab.write_config(tools=[])
    a, _ = lab.render("wall", name="a.png")
    lab.write_config(tools=...)  # the key left out altogether
    b, proc = lab.render("wall", name="b.png")
    assert (a == b).all()
    assert lab.journal(proc) == []


def test_logos_with_no_room_do_not_fail_the_wallpaper(lab):
    # No spot of a 120 by 100 px screen is 72 px from every edge.
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 2))
    img, proc = lab.render("wall", size=(120, 100), scale=1)
    assert proc.returncode == 0
    assert not blobs(grays(img)[0] | grays(img)[1])
    lines = lab.journal(proc)
    assert len(lines) == 1 and "no room for 6 of the 6" in lines[0], lines


def test_a_crowded_screen_gets_the_logos_that_fit(lab):
    lab.write_config(tools=lab.logos(*("bar", "disc", "tri") * 40))
    img, proc = lab.render("wall", size=(800, 500), scale=1)
    assert proc.returncode == 0
    assert where(img, rgb("mauve")).sum() > 1000
    assert len(blobs(grays(img)[0] | grays(img)[1])) > 10


def test_a_logo_with_no_ink_is_skipped(lab):
    nothing = b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"></svg>'
    lab.write_config(tools=[str(lab.write("nothing.svg", nothing)), *lab.logos("disc")])
    img, proc = lab.render("wall")
    assert len(blobs(grays(img)[0] | grays(img)[1])) == 1
    assert len(lab.journal(proc)) == 1


def test_the_tools_follow_the_scale(lab):
    lab.write_config(tools=lab.logos("disc"))
    one, _ = lab.render("wall", size=(1280, 800), scale=1, name="one.png")
    two, _ = lab.render("wall", size=(2560, 1600), scale=2, name="two.png")
    area_one = (grays(one)[0] | grays(one)[1]).sum()
    area_two = (grays(two)[0] | grays(two)[1]).sum()
    assert area_one > 1000
    assert abs(area_two / area_one - 4) < 0.4
