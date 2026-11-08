"""Needs the theme font, because text extents are what this measures.

Every label the shipped menu can draw has to stay inside the ring and has to do
it without being ellipsized. The first is correctness: text drawn past R_DRAW
sits outside the wedge it belongs to, on top of the desktop. The second is a
content rule, and it belongs in the test suite because the fix is always to
shorten the label, never to shrink the type or grow the ring.
"""

import math

import pytest

from sway_radial.config import load_menu, submenu
from sway_radial.geometry import R_DRAW, angle_of


def _every_ring(menu, prefix="the top ring"):
    yield prefix, menu
    for item in menu.items.values():
        if item.is_submenu:
            child = submenu(item)
            yield from _every_ring(child, f"{prefix} > {item.label}")


def _measure(menu_path):
    import cairo

    from sway_radial import overlay as ov
    from sway_radial import theme

    cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 8, 8))
    cr.select_font_face(theme.FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(ov._LABEL_SIZE)

    for ring, menu in _every_ring(load_menu(menu_path)):
        for direction, item in menu.items.items():
            cx, cy = ov._polar(angle_of(direction), ov._R_LABEL)
            room = ov._bounded_width(
                cr, cx, cy, R_DRAW - ov._EDGE_PAD, ov._CHORD * ov._R_LABEL - 12.0
            )
            drawn = ov._fit(cr, item.label, room)
            ext = cr.text_extents(drawn)
            x0, y0 = cx - ext.width / 2, cy - ext.height / 2
            corners = (
                (x0, y0),
                (x0 + ext.width, y0),
                (x0, y0 + ext.height),
                (x0 + ext.width, y0 + ext.height),
            )
            yield ring, item.label, drawn, max(math.hypot(px, py) for px, py in corners)


@pytest.mark.font
def test_no_label_is_drawn_outside_the_ring(menu_path):
    outside = [
        (ring, label, round(far, 1))
        for ring, label, _drawn, far in _measure(menu_path)
        if far > R_DRAW
    ]
    assert outside == [], outside


@pytest.mark.font
def test_no_label_has_to_be_ellipsized_to_fit(menu_path):
    cut = [
        (ring, label, drawn) for ring, label, drawn, _far in _measure(menu_path) if drawn != label
    ]
    assert cut == [], cut


@pytest.mark.font
def test_the_icon_and_the_label_never_touch(menu_path):
    """Due east and due west both run horizontally, so the icon and the label
    are laid out along the same line and compete for it. Pulling the labels in
    to keep them inside the ring closed this gap to 2 px before the icons were
    pulled in to match, which is the sort of thing that reads as a rendering
    fault rather than a layout choice."""
    import cairo

    from sway_radial import overlay as ov
    from sway_radial import theme

    cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 8, 8))
    cr.select_font_face(theme.FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)

    def box(text, size, cx, cy):
        cr.set_font_size(size)
        ext = cr.text_extents(text)
        return (cx - ext.width / 2, cy - ext.height / 2, cx + ext.width / 2, cy + ext.height / 2)

    tight = []
    for ring, menu in _every_ring(load_menu(menu_path)):
        for direction, item in menu.items.items():
            if not item.icon:
                continue
            angle = angle_of(direction)
            ix, iy = ov._polar(angle, ov._R_ICON)
            lx, ly = ov._polar(angle, ov._R_LABEL)
            icon = box(item.icon, ov._ICON_SIZE, ix, iy)
            label = box(item.label, ov._LABEL_SIZE, lx, ly)
            gap = max(
                max(icon[0], label[0]) - min(icon[2], label[2]),
                max(icon[1], label[1]) - min(icon[3], label[3]),
            )
            if gap < 6.0:
                tight.append((ring, item.label, round(gap, 1)))
    assert tight == [], tight
