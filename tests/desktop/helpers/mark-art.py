#!/usr/bin/env python3
"""The raven mark as text, for the login screen: assets/ravnix-mark.txt.

    mark-art.py SVG ROWS

prints the mark of SVG (assets/ravnix-mark.svg) in ROWS lines of half blocks,
the way fastfetch prints the NixOS and Fedora logos. A console cell is twice
as high as it is wide, so the upper and lower half of a cell are two square
pixels: each pixel is on when the mark covers at least half of it, and a cell
is a space, ▀, ▄ or █. These four are in the console's own font (the kernel's,
whose table is code page 437), which quadrant blocks are not.

The art is cropped to the mark's ink, and no line ends in a space: the
greeter's module (modules/desktop/greetd.nix) pads every line to the widest,
because tuigreet centers each line of the greeting on its own.

The check desktop-mark runs this on the shipped mark and fails when the
result differs from assets/ravnix-mark.txt; to make the file again, take the
art the failing check prints.
"""
import sys

import cairo
import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg  # noqa: E402

SAMPLES = 8  # samples per pixel side
MEASURE = 1024  # the square the ink is measured in
CELLS = {(False, False): " ", (True, False): "▀", (False, True): "▄", (True, True): "█"}


def render(handle, x, y, side, width, height):
    """The alpha of the SVG fitted into a square of `side` at (x, y), on a
    surface of width by height, as rows of bytes."""
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    rect = Rsvg.Rectangle()
    rect.x, rect.y, rect.width, rect.height = x, y, side, side
    handle.render_document(cairo.Context(surf), rect)
    surf.flush()
    data = bytes(surf.get_data())[3 if sys.byteorder == "little" else 0 :: 4]
    stride = surf.get_stride() // 4
    return [data[r * stride : r * stride + width] for r in range(height)]


def ink(rows):
    """(x0, y0, x1, y1) of the pixels that are not clear, x1 and y1 exclusive."""
    ys = [y for y, row in enumerate(rows) if row.strip(b"\0")]
    if not ys:
        raise SystemExit("mark-art.py: the mark draws nothing")
    x0 = min(len(rows[y]) - len(rows[y].lstrip(b"\0")) for y in ys)
    x1 = max(len(rows[y].rstrip(b"\0")) for y in ys)
    return x0, ys[0], x1, ys[-1] + 1


def art(svg, rows):
    handle = Rsvg.Handle.new_from_data(svg)
    x0, y0, x1, y1 = ink(render(handle, 0, 0, MEASURE, MEASURE, MEASURE))
    height = 2 * rows
    k = height / (y1 - y0)  # art pixels per measured pixel
    width = round((x1 - x0) * k)
    s = k * SAMPLES
    # Centered across the columns: the rounding of the width splits evenly.
    dx = (width * SAMPLES - (x1 - x0) * s) / 2
    alpha = render(handle, -x0 * s + dx, -y0 * s, MEASURE * s, width * SAMPLES, height * SAMPLES)
    full = 255 * SAMPLES * SAMPLES

    def on(px, py):
        total = sum(
            sum(alpha[py * SAMPLES + j][px * SAMPLES : (px + 1) * SAMPLES])
            for j in range(SAMPLES)
        )
        return 2 * total >= full

    return [
        "".join(CELLS[on(x, 2 * r), on(x, 2 * r + 1)] for x in range(width)).rstrip(" ")
        for r in range(rows)
    ]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.split("\n\n")[1])
    with open(sys.argv[1], "rb") as f:
        svg = f.read()
    for line in art(svg, int(sys.argv[2])):
        print(line)


if __name__ == "__main__":
    main()
