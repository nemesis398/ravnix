"""The block elements of the facts are rectangles on whole pixels."""

from conftest import H, W, bbox, rgb, tinted, where

# Each block element and the part of its cell it covers.
FRACTIONS = {
    "▀": 1 / 2, "▄": 1 / 2, "▌": 1 / 2, "▐": 1 / 2,
    "▁": 1 / 8, "▂": 2 / 8, "▃": 3 / 8, "▅": 5 / 8, "▆": 6 / 8, "▇": 7 / 8,
    "▉": 7 / 8, "▊": 6 / 8, "▋": 5 / 8, "▍": 3 / 8, "▎": 2 / 8, "▏": 1 / 8,
    "▔": 1 / 8, "▕": 1 / 8,
    "▖": 1 / 4, "▗": 1 / 4, "▘": 1 / 4, "▝": 1 / 4,
    "▙": 3 / 4, "▛": 3 / 4, "▜": 3 / 4, "▟": 3 / 4,
    "▚": 1 / 2, "▞": 1 / 2,
}


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


def test_a_block_element_covers_its_part_of_the_cell_with_no_blend(lab):
    blue = rgb("blue")
    width, height = cell_size(lab)
    chars = list(FRACTIONS)
    for start in range(0, len(chars), 14):
        group = chars[start : start + 14]
        right, proc = render_facts(lab, "".join(sgr(blue) + c + "\x1b[m\n" for c in group))
        assert lab.journal(proc) == []
        ink = where(right, blue)
        x0, y0, x1, y1 = bbox(ink)
        assert not (tinted(right, blue, rgb("base"), least=0.05, slack=6) & ~ink).any()
        for row, char in enumerate(group):
            cell = ink[y0 + row * height : y0 + (row + 1) * height, x0 : x0 + width]
            # The edges are rounded to whole pixels, so a part is right to a pixel on each side.
            assert abs(cell.sum() - FRACTIONS[char] * width * height) <= width + height, (char, int(cell.sum()))


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
