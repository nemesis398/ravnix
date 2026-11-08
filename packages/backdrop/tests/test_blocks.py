"""The block elements of the facts are rectangles on whole pixels."""

import re
import unicodedata

import numpy as np

from conftest import H, W, bbox, rgb, tinted, where

# Every block element that is drawn as rectangles: U+2580 to U+259F, except the
# three shades.
CHARS = [chr(c) for c in range(0x2580, 0x25A0) if c not in (0x2591, 0x2592, 0x2593)]

EIGHTHS = {
    "ONE EIGHTH": 1, "ONE QUARTER": 2, "THREE EIGHTHS": 3, "HALF": 4,
    "FIVE EIGHTHS": 5, "THREE QUARTERS": 6, "SEVEN EIGHTHS": 7,
}


def covered(char):
    """The 8 by 8 grid (rows, then columns) of the eighths of a cell that the
    character covers, read off its Unicode name, so that the expectation comes
    from the standard and not from the table the code draws from."""
    name = unicodedata.name(char)
    grid = np.zeros((8, 8), dtype=bool)
    side = re.fullmatch(r"(UPPER|LOWER|LEFT|RIGHT) (.+) BLOCK", name)
    if name == "FULL BLOCK":
        grid[:] = True
    elif side:
        n = EIGHTHS[side[2]]
        if side[1] == "UPPER":
            grid[:n] = True
        elif side[1] == "LOWER":
            grid[8 - n :] = True
        elif side[1] == "LEFT":
            grid[:, :n] = True
        else:
            grid[:, 8 - n :] = True
    else:
        assert name.startswith("QUADRANT "), name
        for part in name[len("QUADRANT ") :].split(" AND "):
            vertical, horizontal = part.split()
            rows = slice(0, 4) if vertical == "UPPER" else slice(4, 8)
            columns = slice(0, 4) if horizontal == "LEFT" else slice(4, 8)
            grid[rows, columns] = True
    return grid


def sgr(color):
    return "\x1b[38;2;%d;%d;%dm" % color


def render_facts(lab, text, **kw):
    # The band right of the middle and above the ravnix mark: 15 rows fit in it.
    lab.facts_path.write_text(text)
    img, proc = lab.render("wall", **kw)
    return img[: int(0.40 * H), W // 2 :], proc


def cell_size(lab):
    """(width, height) of one cell, as the full block fills it."""
    right, _ = render_facts(lab, sgr(rgb("blue")) + "\u2588\n")
    x0, y0, x1, y1 = bbox(where(right, rgb("blue")))
    return x1 - x0, y1 - y0


def longest_run(line):
    best = run = 0
    for v in line:
        run = run + 1 if v else 0
        best = max(best, run)
    return best


def test_a_block_element_covers_the_eighths_its_name_says_and_nothing_else(lab):
    blue, base = rgb("blue"), rgb("base")
    width, height = cell_size(lab)
    for start in range(0, len(CHARS), 13):
        group = CHARS[start : start + 13]
        # A full block first, which sets the corner the rows are counted from.
        right, proc = render_facts(lab, "".join(sgr(blue) + c + "\x1b[m\n" for c in ("\u2588", *group)))
        assert lab.journal(proc) == []
        ink = where(right, blue)
        x0, y0 = bbox(ink)[:2]
        assert not (tinted(right, blue, base, least=0.05, slack=6) & ~ink).any(), "a blended pixel"
        for row, char in enumerate(group, start=1):
            want = covered(char)
            for r in range(8):
                for c in range(8):
                    # The center of each eighth of the cell in each direction.
                    x = x0 + int((c + 0.5) * width / 8)
                    y = y0 + row * height + int((r + 0.5) * height / 8)
                    got = tuple(right[y, x])
                    assert got == (blue if want[r, c] else base), (char, unicodedata.name(char), r, c, got)
            # Whole pixels also in the sum: the part covered is its eighths, to a pixel on each edge.
            cell = ink[y0 + row * height : y0 + (row + 1) * height, x0 : x0 + width]
            assert abs(cell.sum() - want.mean() * width * height) <= (width + height) / 2, (char, int(cell.sum()))


def test_blocks_above_one_another_and_side_by_side_leave_no_seam(lab):
    blue = rgb("blue")
    width, height = cell_size(lab)
    # A right half and a left half beside each other fill one cell's width, and
    # a lower half over an upper half fill one cell's height.
    right, _ = render_facts(lab, "".join(sgr(blue) + line + "\n" for line in ("\u2590\u258c", "\u2584", "\u2580")))
    ink = where(right, blue)
    y0 = bbox(ink)[1]
    assert longest_run(ink[y0 + height // 2]) == width, "a seam between the halves side by side"
    below = ink[y0 + height :]
    column = bbox(below)[0] + 1
    assert longest_run(below[:, column]) == height, "a seam between the halves above one another"
    assert not (tinted(right, blue, rgb("base"), least=0.05, slack=6) & ~ink).any()


def test_text_and_blocks_in_one_run_keep_their_columns(lab):
    blue, text = rgb("blue"), rgb("text")
    # A wide character takes two columns: the block after it is three cells on.
    right, proc = render_facts(lab, sgr(blue) + "█中█\n" + sgr(blue) + "███\n")
    assert lab.journal(proc) == []
    x0, y0, x1, y1 = bbox(where(right, blue))
    cell = (x1 - x0) // 4
    assert (x1 - x0) % 4 == 0, "the columns are not whole cells"
    height = (y1 - y0) // 2
    top = where(right, blue)[y0 : y0 + height]
    assert top[:, x0 : x0 + cell].all() and top[:, x1 - cell : x1].all()
    assert not top[:, x0 + cell : x0 + 3 * cell].all()
    assert where(right, text).sum() == 0


def test_a_shade_character_still_draws(lab):
    right, proc = render_facts(lab, sgr(rgb("blue")) + "░▒▓ shades\n")
    assert proc.returncode == 0
    assert (right != rgb("base")).any()
