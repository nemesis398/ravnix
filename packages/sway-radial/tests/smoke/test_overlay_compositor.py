"""Needs a live Wayland session, so it is marked and deselected by default.

Everything about the ring's appearance is covered by the pixel tests in
tests/test_overlay.py, which need no display at all. What is left here is what
an ImageSurface cannot answer: that the window really maps as a layer surface,
and that it really is configured to take no input while it is unlatched.
"""

import pytest


@pytest.mark.compositor
def test_overlay_maps_and_takes_no_input():
    from sway_radial.overlay import Overlay

    ov = Overlay(on_click=lambda d: None, on_escape=lambda: None, on_back=lambda: None)
    ov.show((960.0, 540.0))
    ov.hide()


@pytest.mark.compositor
def test_the_layer_surface_is_configured_the_way_the_design_needs_it():
    """The load-bearing configuration, read back rather than assumed.

    There is no getter for the input region, but there is one for the keyboard
    mode, and the two are set together. If ON_DEMAND ever showed up while
    unlatched, the menu would be taking focus during a gesture and the whole
    click-through premise would be gone.
    """
    from gi.repository import Gtk4LayerShell as layer_shell

    from sway_radial.overlay import Overlay

    ov = Overlay(on_click=lambda d: None, on_escape=lambda: None, on_back=lambda: None)
    window = ov._window

    assert layer_shell.is_layer_window(window)
    assert layer_shell.get_layer(window) == layer_shell.Layer.OVERLAY
    assert layer_shell.get_exclusive_zone(window) == 0
    for edge in (
        layer_shell.Edge.LEFT,
        layer_shell.Edge.RIGHT,
        layer_shell.Edge.TOP,
        layer_shell.Edge.BOTTOM,
    ):
        assert layer_shell.get_anchor(window, edge), edge

    assert layer_shell.get_keyboard_mode(window) == layer_shell.KeyboardMode.NONE
    ov.set_latched(True)
    assert layer_shell.get_keyboard_mode(window) == layer_shell.KeyboardMode.ON_DEMAND
    ov.set_latched(False)
    assert layer_shell.get_keyboard_mode(window) == layer_shell.KeyboardMode.NONE
