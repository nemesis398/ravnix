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


# The Palette row is a line of swatches in different colors: that is what the
# colors module prints, and what a state-hue swatch is dropped from. A pink one
# keeps each of these lines a Palette row, and what is left of it is the pink.
def palette_row(first, last="35", run="███"):
    return "\x1b[%sm%s\x1b[%sm%s\x1b[m\n" % (first, run, last, run)


@pytest.mark.parametrize("code", STATE_CODES)
def test_a_state_hue_swatch_of_the_terminal_is_left_out(lab, code):
    right, proc = render_facts(lab, palette_row(code))
    assert lab.journal(proc) == []
    only_pink, _ = render_facts(lab, "\x1b[35m███\x1b[m\n")
    assert (only_pink != rgb("base")).any(), "nothing was drawn"
    assert (right == only_pink).all(), "the swatch is drawn"


@pytest.mark.parametrize("run", ["███ ", " ███", " ███ ", "██"])
def test_padding_does_not_bring_a_swatch_back(lab, run):
    right, _ = render_facts(lab, palette_row("31", run=run))
    only_pink, _ = render_facts(lab, "\x1b[35m%s\x1b[m\n" % run)
    assert (right == only_pink).all(), "the swatch is drawn"


@pytest.mark.parametrize("symbol", ["●", "■", "▲", "◆"])
@pytest.mark.parametrize("code", ["31", "33", "34", "38;5;2", "38;5;12"])
def test_the_symbols_of_the_other_colors_shapes_are_left_out_too(lab, code, symbol):
    # fastfetch's colors module can print circles, squares, triangles or
    # diamonds, each followed by a space, instead of blocks.
    right, _ = render_facts(lab, palette_row(code, run=symbol + " "))
    only_pink, _ = render_facts(lab, "\x1b[35m%s \x1b[m\n" % symbol)
    assert (only_pink != rgb("base")).any(), "nothing was drawn"
    assert (right == only_pink).all(), "the symbol is drawn"


def test_a_symbol_in_a_color_that_is_no_state_hue_is_drawn(lab):
    right, _ = render_facts(lab, palette_row("35", "36", run="● "))
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


# What fastfetch prints in the terminal's own colors besides the Palette row: a
# percent bar (type 3) is squares in the color of its state, then dashes, and a
# status can be a dot. They are state, and they are not on a Palette row.
BARS = {"31": "red", "32": "green", "33": "yellow", "91": "red", "92": "green", "93": "yellow",
        "38;5;1": "red", "38;5;2": "green", "38;5;3": "yellow"}


@pytest.mark.parametrize("code", BARS)
def test_a_bar_of_squares_in_the_terminals_state_colors_keeps_its_hue(lab, code):
    right, _ = render_facts(lab, "Disk  \x1b[%sm\u25a0\u25a0\u25a0\u25a0\u25a0\u25a0\u25a0\u25a0\x1b[m\x1b[37m--\x1b[m 80%%\n" % code)
    assert where(right, rgb(BARS[code])).sum() > 100


def test_a_bar_of_blocks_keeps_its_hue(lab):
    right, _ = render_facts(lab, "Memory  \x1b[32m█████\x1b[37m-----\x1b[m 50%\n")
    assert where(right, rgb("green")).sum() > 500


def test_a_status_dot_keeps_its_hue(lab):
    right, _ = render_facts(lab, "Failed  \x1b[31m\u25cf\x1b[m 2 units\n")
    assert where(right, rgb("red")).sum() > 20


def test_a_line_of_one_swatch_is_not_a_palette_row(lab):
    right, _ = render_facts(lab, "\x1b[31m\u25a0\u25a0\u25a0\u25a0\u25a0\x1b[m\n")
    assert where(right, rgb("red")).sum() > 100



def test_a_line_of_state_dots_with_no_words_is_taken_for_a_palette_row(lab):
    # The trade-off, pinned: a line of nothing but dots in two colors looks like
    # the Palette row, so its state-hue dots are left out (README, findings).
    right, _ = render_facts(lab, "\x1b[31m● \x1b[32m● \x1b[m\n")
    assert not (right != rgb("base")).any()
