"""Needs JetBrainsMono Nerd Font installed, so it is marked and deselected.

Glyph index 0 is .notdef. That is the only honest answer to "does this font have
that character": rendering it and looking proves nothing, because .notdef in
many fonts is a box that reads as a deliberate icon, and in others is blank,
which reads as spacing.
"""

import pytest

from sway_radial.config import load_menu


def _every_item(menu):
    """Every item in the tree, walking children directly.

    Not via submenu(), which needs the direction the ring was entered through in
    order to reserve Back. Nothing here cares about Back.
    """
    def walk(items):
        for item in items:
            yield item
            yield from walk(item.children)

    yield from walk(menu.items.values())


@pytest.mark.font
def test_every_shipped_icon_has_a_glyph_in_the_theme_font(menu_path):
    import cairo

    from sway_radial import theme

    cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 10, 10))
    cr.select_font_face(theme.FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(32)
    scaled = cr.get_scaled_font()

    # The control first. Without it a font that failed to load at all would
    # report every glyph missing, and a font that resolved to a fallback with
    # broad coverage would report every glyph present, including this one.
    control, _, _ = scaled.text_to_glyphs(0, 0, "\U000f0000", True)
    assert [g.index for g in control] == [0], "control codepoint resolved, the check is blind"

    missing = []
    for item in _every_item(load_menu(menu_path)):
        if item.icon is None:
            continue
        glyphs, _, _ = scaled.text_to_glyphs(0, 0, item.icon, True)
        if any(g.index == 0 for g in glyphs):
            missing.append((item.label, hex(ord(item.icon))))
    assert missing == [], missing
