"""The swatches of the terminal's palette on the wallpaper: all of them are
drawn, the ones in a state hue too, whatever symbol the colors module prints
them in. The Palette row is a picture of the terminal's colors, not a state."""

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
# and as 256-color indexes, and some of them mixed with other attributes, with
# the hue each is drawn in.
STATE_CODES = {
    "31": "red", "32": "green", "33": "yellow", "34": "blue",
    "91": "red", "92": "green", "93": "yellow", "94": "blue",
    "38;5;1": "red", "38;5;2": "green", "38;5;3": "yellow", "38;5;4": "blue",
    "38;5;9": "red", "38;5;10": "green", "38;5;11": "yellow", "38;5;12": "blue",
    "1;91": "red", "0;33;1": "yellow", "1;38;5;12": "blue",
}


def palette_row(first, last="35", run="███"):
    return "\x1b[%sm%s\x1b[%sm%s\x1b[m\n" % (first, run, last, run)


@pytest.mark.parametrize("code", STATE_CODES)
def test_a_state_hue_swatch_of_the_terminal_is_drawn(lab, code):
    right, proc = render_facts(lab, palette_row(code))
    assert lab.journal(proc) == []
    only_pink, _ = render_facts(lab, "\x1b[35m███\x1b[m\n")
    assert (right != only_pink).any(), "the swatch is left out"
    assert where(right, rgb(STATE_CODES[code])).sum() > 500, "three cells of it"


@pytest.mark.parametrize("run", ["███ ", " ███", " ███ ", "██"])
def test_padding_does_not_hide_a_swatch(lab, run):
    right, _ = render_facts(lab, palette_row("31", run=run))
    assert where(right, rgb("red")).sum() > 100, "the swatch is left out"


@pytest.mark.parametrize("symbol", ["●", "■", "▲", "◆"])
@pytest.mark.parametrize("code", ["31", "33", "34", "38;5;2", "38;5;12"])
def test_the_symbols_of_the_other_colors_shapes_are_drawn_too(lab, code, symbol):
    # fastfetch's colors module can print circles, squares, triangles or
    # diamonds, each followed by a space, instead of blocks.
    right, _ = render_facts(lab, palette_row(code, run=symbol + " "))
    assert where(right, rgb(STATE_CODES[code])).sum() > 20, "the symbol is left out"


def test_all_eight_colors_in_one_row_are_all_drawn(lab):
    row = "".join("\x1b[%dm███" % c for c in range(30, 38)) + "\x1b[m\n"
    right, _ = render_facts(lab, row)
    for name in ("surface1", "red", "green", "yellow", "blue", "pink", "teal", "subtext1"):
        assert where(right, rgb(name)).sum() > 500, name


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
    right, _ = render_facts(lab, "Disk  \x1b[%sm■■■■■■■■\x1b[m\x1b[37m--\x1b[m 80%%\n" % code)
    assert where(right, rgb(BARS[code])).sum() > 100


def test_a_bar_of_blocks_keeps_its_hue(lab):
    right, _ = render_facts(lab, "Memory  \x1b[32m█████\x1b[37m-----\x1b[m 50%\n")
    assert where(right, rgb("green")).sum() > 500


def test_a_status_dot_keeps_its_hue(lab):
    right, _ = render_facts(lab, "Failed  \x1b[31m●\x1b[m 2 units\n")
    assert where(right, rgb("red")).sum() > 20
