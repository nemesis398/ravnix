"""The swatches of the terminal's palette on the wallpaper: the ones that are
state hues are left out."""

import pytest

from conftest import H, W, rgb, where


def sgr(color):
    return "\x1b[38;2;%d;%d;%dm" % color


def render_facts(lab, text, **kw):
    # The band right of the middle and above the ravnix mark.
    lab.facts_path.write_text(text)
    img, proc = lab.render("wall", **kw)
    return img[: int(0.40 * H), W // 2 :], proc


@pytest.mark.parametrize("code", ["31", "32", "33", "91", "92", "93", "38;5;1", "38;5;2", "38;5;3", "38;5;9"])
def test_a_state_hue_swatch_of_the_terminal_is_left_out(lab, code):
    right, proc = render_facts(lab, "\x1b[%sm███\x1b[m\n" % code)
    assert lab.journal(proc) == []
    assert not (right != rgb("base")).any(), "the swatch is drawn"


def test_the_swatches_after_a_dropped_one_close_up(lab):
    # Red is dropped and Blue and Pink take its place: the same image as when
    # the row never had the red swatch.
    with_red, _ = render_facts(lab, "\x1b[31m███\x1b[34m███\x1b[35m███\x1b[m\n")
    without, _ = render_facts(lab, "\x1b[34m███\x1b[35m███\x1b[m\n")
    assert (without != rgb("base")).any(), "nothing was drawn"
    assert (with_red == without).all()


def test_text_in_the_terminals_red_keeps_its_state_hue(lab):
    # A message in the terminal's red is state, not a swatch.
    right, _ = render_facts(lab, "\x1b[31merror\x1b[m\n")
    assert where(right, rgb("red")).sum() > 0


def test_blocks_in_an_rgb_red_keep_their_state_hue(lab):
    # A bar that fastfetch colored by its own rules (RGB, not the terminal's
    # palette) is state too: three cells of it are drawn.
    right, _ = render_facts(lab, sgr(rgb("red")) + "███\x1b[m\n")
    assert where(right, rgb("red")).sum() > 500
