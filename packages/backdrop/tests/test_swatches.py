"""The swatches of the terminal's palette on the wallpaper: the ones that are
state hues are left out, whatever symbol the colors module prints them in."""

import pytest

from conftest import H, W, rgb, where


def sgr(color):
    return "\x1b[38;2;%d;%d;%dm" % color


def render_facts(lab, text, **kw):
    # The band right of the middle and above the ravnix mark.
    lab.facts_path.write_text(text)
    img, proc = lab.render("wall", **kw)
    return img[: int(0.40 * H), W // 2 :], proc


# The terminal's Red, Green, Yellow and Blue, normal and bright, as SGR codes
# and as 256-color indexes, and some of them mixed with other attributes.
STATE_CODES = [
    "31", "32", "33", "34", "91", "92", "93", "94",
    "38;5;1", "38;5;2", "38;5;3", "38;5;4", "38;5;9", "38;5;10", "38;5;11", "38;5;12",
    "1;91", "0;33;1", "1;38;5;12",
]


@pytest.mark.parametrize("code", STATE_CODES)
def test_a_state_hue_swatch_of_the_terminal_is_left_out(lab, code):
    right, proc = render_facts(lab, "\x1b[%sm███\x1b[m\n" % code)
    assert lab.journal(proc) == []
    assert not (right != rgb("base")).any(), "the swatch is drawn"


@pytest.mark.parametrize("run", ["███ ", " ███", " ███ ", "██"])
def test_padding_does_not_bring_a_swatch_back(lab, run):
    right, _ = render_facts(lab, "\x1b[31m%s\x1b[m\n" % run)
    assert not (right != rgb("base")).any(), "the swatch is drawn"


@pytest.mark.parametrize("symbol", ["●", "■", "▲", "◆"])
@pytest.mark.parametrize("code", ["31", "33", "34", "38;5;2", "38;5;12"])
def test_the_symbols_of_the_other_colors_shapes_are_left_out_too(lab, code, symbol):
    # fastfetch's colors module can print circles, squares, triangles or
    # diamonds, each followed by a space, instead of blocks.
    right, _ = render_facts(lab, "\x1b[%sm%s \x1b[m\n" % (code, symbol))
    assert not (right != rgb("base")).any(), "the symbol is drawn"


def test_a_symbol_in_a_color_that_is_no_state_hue_is_drawn(lab):
    right, _ = render_facts(lab, "\x1b[35m● \x1b[m\n")
    assert (right != rgb("base")).any()


def test_the_swatches_after_a_dropped_one_close_up(lab):
    # Red is dropped and Pink and Teal take its place: the same image as when
    # the row never had the red swatch.
    with_red, _ = render_facts(lab, "\x1b[31m███\x1b[35m███\x1b[36m███\x1b[m\n")
    without, _ = render_facts(lab, "\x1b[35m███\x1b[36m███\x1b[m\n")
    assert (without != rgb("base")).any(), "nothing was drawn"
    assert (with_red == without).all()


def test_text_in_the_terminals_red_keeps_its_state_hue(lab):
    # A message in the terminal's red is state, not a swatch, with a symbol
    # before it or not.
    for text in ("error", "● error", "█ error"):
        right, _ = render_facts(lab, "\x1b[31m%s\x1b[m\n" % text)
        assert where(right, rgb("red")).sum() > 0, text


def test_blocks_in_an_rgb_red_keep_their_state_hue(lab):
    # A bar that fastfetch colored by its own rules (RGB, not the terminal's
    # palette) is state too: three cells of it are drawn.
    right, _ = render_facts(lab, sgr(rgb("red")) + "███\x1b[m\n")
    assert where(right, rgb("red")).sum() > 500
