"""The ring on screen: a pure Cairo painter, plus the layer-shell window it lives in.

Two halves that deliberately do not know about each other.

``draw_ring`` is a function of a ``cairo.Context`` and nothing else. No GTK type
crosses into it, so the whole appearance is testable against an in-memory
``ImageSurface`` with no display, no compositor and no trackpad. Every pixel
assertion in the test suite goes through it.

``Overlay`` is the surface. It is a **pure renderer with an empty input region**,
and that is the single decision the project rests on. The daemon reads libinput
itself, so while the fingers are down the menu needs neither pointer nor keyboard
focus: ``KeyboardMode.NONE`` and an empty ``set_input_region`` mean the window
underneath keeps every event, and sway's gesture ownership has nothing to take
away from us because we never asked for the gesture in the first place. Only
``set_latched(True)`` trades that away, once the fingers are off and a click, Esc
or mouse button 8 is the only way left to drive the menu.
"""

from __future__ import annotations

# This must run before ``import gi``, and it is not tidiable. The library shims
# libwayland symbols, so it has to be resolved into the process before GTK pulls
# in the real ones. Moving it below the imports leaves the shim inert and the
# window maps as an ordinary toplevel instead of a layer surface.
import ctypes

ctypes.CDLL("libgtk4-layer-shell.so.0")

import logging  # noqa: E402
import math  # noqa: E402
from collections.abc import Callable, Sequence  # noqa: E402

import cairo  # noqa: E402
import gi  # noqa: E402

from . import theme  # noqa: E402
from .actions import desktop_exists  # noqa: E402
from .geometry import R_DEAD, R_DRAW, angle_of, direction_at, sector_bounds  # noqa: E402
from .model import DIRECTIONS, Direction, Menu  # noqa: E402

gi.require_version("Gdk", "4.0")
gi.require_version("Gtk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")

from gi.repository import Gdk, Gtk, Gtk4LayerShell  # noqa: E402

__all__ = ["Overlay", "draw_ring"]

logger = logging.getLogger(__name__)

#: Cairo puts 0 at east and grows toward +y, which is down on screen. This module
#: puts 0 at north and grows clockwise, which is also down-first, so the two
#: agree on direction and differ only by a quarter turn.
_CAIRO_TURN = -math.pi / 2

_R_ICON = 88.0
_R_LABEL = 145.0
_ICON_SIZE = 22.0
_LABEL_SIZE = 15.0
#: Breathing room between any drawn text and the edge of the circle bounding it.
_EDGE_PAD = 6.0
#: The dwell arc, drawn just inside the ring's edge.
_DWELL_INSET = 4.0
_PATH_SIZE = 9.0
_HUB_SIZE = 12.0
#: The X that replaces the breadcrumb while the exit counts down. Drawn in TEXT
#: like every other dwell: a warm color would be a second accent, and the style
#: has one. Position and glyph already separate leaving from choosing.
_CLOSE_ICON = "\uf00d"  # nf-fa-times, verified present in JetBrainsMono NF
_HUB_ICON_SIZE = 30.0

#: A 45 degree sector is this fraction of its radius wide at the chord.
_CHORD = 2 * math.sin(math.pi / 8)

_BACK_LABEL = "Back"

#: The layer surface covers the whole output and the ring is drawn on a part of
#: it, so everything else has to be clear or the ring would hide the screen. The
#: ring itself is opaque, and it appears and disappears at once: there is no
#: fade (docs/style.md of ravnix, the sway-radial row).
_CSS = """
#sway-radial-window { background-color: transparent; }
"""


def _polar(angle: float, r: float) -> tuple[float, float]:
    """A point at ``angle`` and radius ``r``, relative to the ring's origin.

    +y is down on screen, so north costs a negation rather than a sign flip in
    the angle. Every caller in the project uses this same pair, tests included.
    """
    return math.sin(angle) * r, -math.cos(angle) * r


def _fit(cr: cairo.Context, text: str, max_width: float) -> str:
    """``text``, shortened with an ellipsis until it fits ``max_width``.

    A label that overflows its sector lands in the neighboring one, where it
    reads as that neighbor's label. Truncating is ugly; the alternative is
    wrong.
    """
    if not text or cr.text_extents(text).width <= max_width:
        return text
    while text and cr.text_extents(text + "…").width > max_width:
        text = text[:-1]
    return text + "…" if text else ""


def _bounded_width(
    cr: cairo.Context, cx: float, cy: float, bound: float | None, max_width: float
) -> float:
    """``max_width``, further reduced so the ink box cannot leave a circle.

    The sector chord is the only limit the ring had, and it is the wrong one on
    its own. A chord says how much room a label has *sideways*, between its two
    neighbors, and says nothing about the outer edge. Text is drawn horizontally
    whatever direction its sector points in, so due east the circle runs out
    long before the neighbors do: at r=155 the chord allows 107 px and the ring
    only has room for 78. Two labels in the shipped menu were drawn past the
    edge because of it, and several more touched it.

    The box height comes from the font rather than the string, so a label with a
    descender and one without are bounded identically and sit on one radius.
    """
    if bound is None:
        return max_width
    half_height = cr.font_extents()[2] / 2
    room = bound * bound - (abs(cy) + half_height) ** 2
    if room <= 0.0:
        return 0.0
    return max(0.0, min(max_width, 2.0 * (math.sqrt(room) - abs(cx))))


def _centered_text(
    cr: cairo.Context,
    text: str,
    cx: float,
    cy: float,
    *,
    size: float,
    color: tuple[float, float, float],
    max_width: float,
    bound: float | None = None,
) -> None:
    """Draw ``text`` with its ink box centered on ``(cx, cy)``.

    Centering on the ink box rather than the baseline keeps a label optically on
    its radius whether or not it happens to contain a descender. ``bound``, when
    given, is the radius of a circle centered on the ring's origin that the text
    may not leave.
    """
    cr.select_font_face(theme.FONT, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(size)
    text = _fit(cr, text, _bounded_width(cr, cx, cy, bound, max_width))
    if not text:
        return
    ext = cr.text_extents(text)
    cr.set_source_rgb(*color)
    cr.move_to(cx - ext.width / 2 - ext.x_bearing, cy - ext.height / 2 - ext.y_bearing)
    cr.show_text(text)


def _wedge_path(cr: cairo.Context, direction: Direction, r_inner: float, r_outer: float) -> None:
    """Lay down the annular wedge for one sector, ready to fill."""
    # sector_bounds is unnormalized on purpose: north comes back as
    # (-pi/8, +pi/8) rather than wrapping through 2pi, and Cairo's arc takes a
    # negative start, so no sector needs a special case here.
    start, end = sector_bounds(direction)
    cr.new_path()
    cr.arc(0.0, 0.0, r_outer, start + _CAIRO_TURN, end + _CAIRO_TURN)
    cr.arc_negative(0.0, 0.0, r_inner, end + _CAIRO_TURN, start + _CAIRO_TURN)
    cr.close_path()


def _label_color(
    menu: Menu, direction: Direction, highlighted: Direction | None
) -> tuple[float, float, float]:
    """The text color for one sector, which is also how a broken item is told.

    An item whose ``.desktop`` id does not resolve is drawn in the muted role rather
    than hidden. Hiding it would shift every other item in the ring, and the
    whole point of a directional menu is that a direction means the same thing
    every time.
    """
    if direction == highlighted:
        return theme.DEEPEST
    if direction == menu.back:
        return theme.SECONDARY
    item = menu.items.get(direction)
    if item is not None and item.desktop and not desktop_exists(item.desktop):
        return theme.MUTED
    return theme.TEXT


def _draw_hub(
    cr: cairo.Context,
    menu: Menu,
    breadcrumb: Sequence[str],
    closing: bool = False,
) -> None:
    """The dead zone, and the breadcrumb written into it.

    The path of ancestors is the secondary role and the ring you are actually in is TEXT,
    so a glance at the middle answers "how deep am I" without reading a word.

    While the close countdown runs, the breadcrumb gives way to an X. The arc
    outside says that something is counting down; only this says what it will
    do, and the two together are the whole of how the exit is discovered.
    """
    cr.new_path()
    cr.arc(0.0, 0.0, R_DEAD, 0.0, math.tau)
    cr.set_source_rgb(*theme.DEEPEST)
    cr.fill()

    if closing:
        _centered_text(
            cr,
            _CLOSE_ICON,
            0.0,
            0.0,
            size=_HUB_ICON_SIZE,
            color=theme.TEXT,
            max_width=R_DEAD,
            bound=R_DEAD - _EDGE_PAD,
        )
        return

    if not breadcrumb:
        return

    current = menu.label or breadcrumb[-1]
    ancestors = " › ".join(breadcrumb[:-1])
    if ancestors:
        _centered_text(
            cr,
            ancestors,
            0.0,
            -8.0,
            size=_PATH_SIZE,
            color=theme.SECONDARY,
            max_width=70.0,
            bound=R_DEAD - _EDGE_PAD,
        )
        _centered_text(
            cr,
            current,
            0.0,
            8.0,
            size=_HUB_SIZE,
            color=theme.TEXT,
            max_width=64.0,
            bound=R_DEAD - _EDGE_PAD,
        )
    else:
        _centered_text(
            cr,
            current,
            0.0,
            0.0,
            size=_HUB_SIZE,
            color=theme.TEXT,
            max_width=70.0,
            bound=R_DEAD - _EDGE_PAD,
        )


def draw_ring(
    cr: cairo.Context,
    *,
    menu: Menu,
    highlighted: Direction | None,
    breadcrumb: Sequence[str],
    origin: tuple[float, float],
    scale: float,
    dwell: bool = False,
) -> None:
    """Paint one ring centered on ``origin``, in logical pixels times ``scale``.

    Takes a ``cairo.Context`` and nothing from GTK, so it can be tested against
    an ImageSurface with no compositor.

    Nothing is painted outside R_DRAW. The behavior has no outer bound, the
    graphic does, and a ring that leaked ink across the whole output would make
    a click-through overlay look like a modal one.
    """
    cr.save()
    cr.translate(origin[0], origin[1])
    cr.scale(scale, scale)

    for direction in DIRECTIONS:
        item = menu.items.get(direction)
        occupied = item is not None or direction == menu.back

        # Draw order per sector: wedge fill, separator, icon, label.
        _wedge_path(cr, direction, R_DEAD, R_DRAW)
        if direction == highlighted:
            cr.set_source_rgb(*theme.ACCENT)
        elif occupied:
            cr.set_source_rgb(*theme.WASH)
        else:
            cr.set_source_rgb(*theme.CANVAS)
        cr.fill()

        start, _ = sector_bounds(direction)
        cr.new_path()
        cr.move_to(*_polar(start, R_DEAD))
        cr.line_to(*_polar(start, R_DRAW))
        cr.set_line_width(theme.FRAME)
        cr.set_source_rgb(*theme.SELECTED)
        cr.stroke()

        if not occupied:
            continue

        center = angle_of(direction)
        color = _label_color(menu, direction, highlighted)

        if item is not None and item.icon:
            ix, iy = _polar(center, _R_ICON)
            _centered_text(
                cr,
                item.icon,
                ix,
                iy,
                size=_ICON_SIZE,
                color=color,
                max_width=_CHORD * _R_ICON,
                bound=R_DRAW - _EDGE_PAD,
            )

        label = item.label if item is not None else _BACK_LABEL
        lx, ly = _polar(center, _R_LABEL)
        _centered_text(
            cr,
            label,
            lx,
            ly,
            size=_LABEL_SIZE,
            color=color,
            max_width=_CHORD * _R_LABEL - 12.0,
            bound=R_DRAW - _EDGE_PAD,
        )

    if dwell:
        _draw_dwell(cr, highlighted)
    _draw_hub(cr, menu, breadcrumb, closing=highlighted is None and dwell)
    cr.restore()


def _draw_dwell(cr: cairo.Context, highlighted: Direction | None) -> None:
    """The countdown, drawn as an arc along the highlighted sector's edge.

    Without it a dwell is indistinguishable from a menu that has stopped
    responding: the hand is holding still on purpose and nothing on screen says
    that something is about to happen. It appears whole when the dwell starts
    and goes when the dwell fires or is cancelled; it does not sweep, because
    the style has no motion (docs/style.md of ravnix). It is drawn in DEEPEST,
    the role for marks on an accent fill, because the wedge underneath is the
    accent and the accent on the accent is invisible.

    With nothing highlighted the countdown belongs to the exit, so it is drawn
    as a full turn around the dead zone instead, just outside the hub fill,
    which paints over anything inside R_DEAD. That one lies on the canvas and
    the wash, not on the accent, so it stays TEXT.
    """
    if highlighted is None:
        cr.new_path()
        cr.arc(0.0, 0.0, R_DEAD + _DWELL_INSET, 0.0, math.tau)
        cr.set_source_rgb(*theme.TEXT)
        cr.set_line_width(theme.MARKER)
        cr.stroke()
        return
    start, end = sector_bounds(highlighted)
    cr.new_path()
    cr.arc(0.0, 0.0, R_DRAW - _DWELL_INSET, start + _CAIRO_TURN, end + _CAIRO_TURN)
    cr.set_source_rgb(*theme.DEEPEST)
    cr.set_line_width(theme.MARKER)
    cr.stroke()


# There was a _draw_cursor here until 2026-09-05: a dot showing where the
# fingers had travelled to, which existed because nothing highlighted until the
# pinch armed and reached past the ring, so the first centimetre of every gesture
# gave no feedback at all. The machine now keeps one sector lit at all times, so
# the highlight is the cursor and a second indicator of the same thing was one
# too many, so it was taken out.


class Overlay:
    """The layer-shell window that shows the ring, and takes no input doing it."""

    def __init__(
        self,
        on_click: Callable[[Direction], None],
        on_escape: Callable[[], None],
        on_back: Callable[[], None],
        on_hover: Callable[[Direction | None], None] | None = None,
    ) -> None:
        """Build the window and keep it hidden. Never shown from __init__."""
        self._on_click = on_click
        self._on_escape = on_escape
        self._on_back = on_back
        self._on_hover = on_hover

        self._menu: Menu | None = None
        self._highlighted: Direction | None = None
        self._breadcrumb: tuple[str, ...] = ()
        self._origin: tuple[float, float] = (0.0, 0.0)
        self._output: str | None = None
        self._dwell_armed = False
        self._latched = False

        self._window = Gtk.Window()
        self._window.set_name("sway-radial-window")
        self._window.set_decorated(False)

        self._area = Gtk.DrawingArea()
        self._area.set_name("sway-radial-ring")
        self._area.set_draw_func(self._draw)
        self._window.set_child(self._area)

        self._install_css()

        Gtk4LayerShell.init_for_window(self._window)
        Gtk4LayerShell.set_namespace(self._window, "sway-radial")
        Gtk4LayerShell.set_layer(self._window, Gtk4LayerShell.Layer.OVERLAY)
        for edge in (
            Gtk4LayerShell.Edge.LEFT,
            Gtk4LayerShell.Edge.RIGHT,
            Gtk4LayerShell.Edge.TOP,
            Gtk4LayerShell.Edge.BOTTOM,
        ):
            Gtk4LayerShell.set_anchor(self._window, edge, True)
        # Anchored on all four edges the surface fills the output, and an
        # exclusive zone of 0 keeps it from pushing the bar or the tiling area
        # around while it does.
        Gtk4LayerShell.set_exclusive_zone(self._window, 0)
        Gtk4LayerShell.set_keyboard_mode(self._window, Gtk4LayerShell.KeyboardMode.NONE)

        clicks = Gtk.GestureClick()
        clicks.set_button(0)  # every button, so button 8 arrives here too
        clicks.connect("pressed", self._on_pressed)
        self._window.add_controller(clicks)

        # Pointer motion lights the sector under it, latched only. While
        # unlatched the input region is empty and no motion arrives anyway.
        motion = Gtk.EventControllerMotion()
        motion.connect("motion", self._on_motion)
        self._window.add_controller(motion)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self._window.add_controller(keys)

        # The GdkSurface only exists once the window is realized, so the input
        # region cannot be set here. It is applied from the map handler and
        # again on every show and latch change.
        self._window.connect("map", lambda *_: self._apply_input_region())

    def _install_css(self) -> None:
        provider = Gtk.CssProvider()
        provider.load_from_string(_CSS)
        display = Gdk.Display.get_default()
        if display is None:
            logger.warning("no display, the overlay will use the theme background")
            return
        Gtk.StyleContext.add_provider_for_display(
            display, provider, Gtk.STYLE_PROVIDER_PRIORITY_USER
        )

    def _apply_input_region(self) -> None:
        """Empty region while unlatched, the whole surface once latched.

        This is the mechanism behind the click-through claim, so it is applied
        from three places rather than once: the window can be latched before it
        maps, and a region set on a surface that does not exist yet is lost.
        """
        surface = self._window.get_surface()
        if surface is None:
            return
        if self._latched:
            region = cairo.Region(
                cairo.RectangleInt(0, 0, surface.get_width(), surface.get_height())
            )
        else:
            region = cairo.Region()
        surface.set_input_region(region)

    def _draw(self, area: Gtk.DrawingArea, cr: cairo.Context, width: int, height: int) -> None:
        if self._menu is None:
            return
        # GTK has already scaled the context to the output, so the ring is drawn
        # in logical pixels and carries no scale of its own. The window covers
        # the whole output, so widget coordinates are the output's logical
        # coordinates and the origin goes in unchanged.
        draw_ring(
            cr,
            menu=self._menu,
            highlighted=self._highlighted,
            breadcrumb=self._breadcrumb,
            origin=self._origin,
            scale=1.0,
            dwell=self._dwell_armed,
        )

    def _on_pressed(self, gesture: Gtk.GestureClick, n_press: int, x: float, y: float) -> None:
        button = gesture.get_current_button()
        if button == 8:
            self._on_back()
            return
        if button != 1:
            return
        direction = direction_at(x - self._origin[0], y - self._origin[1])
        if direction is None:
            self._on_escape()
        else:
            self._on_click(direction)

    def _on_motion(self, controller: Gtk.EventControllerMotion, x: float, y: float) -> None:
        if not self._latched or self._on_hover is None:
            return
        self._on_hover(direction_at(x - self._origin[0], y - self._origin[1]))

    def _on_key(self, controller: Gtk.EventControllerKey, keyval: int, keycode: int, state) -> bool:
        if keyval == Gdk.KEY_Escape:
            self._on_escape()
            return True
        return False

    def start_dwell(self, duration_ms: int) -> None:
        """Show the countdown arc, whole, until the dwell fires or is cancelled.

        Cosmetic only. The daemon keeps the timer that fires the action; this
        one draws once and holds still, so it has no timer of its own and a
        dropped frame cannot change what the dwell does.
        """
        self._dwell_armed = duration_ms > 0
        self._area.queue_draw()

    def cancel_dwell(self) -> None:
        self._dwell_armed = False
        self._area.queue_draw()

    def _monitor_named(self, name: str | None):
        """The Gdk.Monitor whose connector is ``name``, or None.

        sway's output name and GDK's connector are the same string, which is
        what makes this a lookup rather than a guess.
        """
        if not name:
            return None
        display = Gdk.Display.get_default()
        if display is None:
            return None
        monitors = display.get_monitors()
        for index in range(monitors.get_n_items()):
            monitor = monitors.get_item(index)
            if monitor is not None and monitor.get_connector() == name:
                return monitor
        return None

    def show(self, origin: tuple[float, float], output: str | None = None) -> None:
        self._origin = origin
        # Pin the surface to the output the origin was measured on. Without this
        # the compositor picks, and the ring can be drawn with one output's
        # numbers onto another output's surface. Set while hidden, and only on a
        # change, because it remaps a visible window.
        if output != self._output:
            self._output = output
            monitor = self._monitor_named(output)
            if monitor is not None:
                Gtk4LayerShell.set_monitor(self._window, monitor)
        self._window.present()
        self._apply_input_region()
        self._area.queue_draw()

    def hide(self) -> None:
        """Gone at once: the ring does not fade (docs/style.md of ravnix)."""
        self._dwell_armed = False
        self._window.set_visible(False)
        self.set_latched(False)

    def update(
        self,
        menu: Menu,
        highlighted: Direction | None,
        breadcrumb: tuple[str, ...],
    ) -> None:
        self._menu = menu
        self._highlighted = highlighted
        self._breadcrumb = breadcrumb
        self._area.queue_draw()

    def set_latched(self, latched: bool) -> None:
        """False: empty input region, KeyboardMode.NONE, click-through.
        True: full input region, keyboard on demand, Esc and button 8 live."""
        self._latched = latched
        mode = (
            Gtk4LayerShell.KeyboardMode.ON_DEMAND if latched else Gtk4LayerShell.KeyboardMode.NONE
        )
        Gtk4LayerShell.set_keyboard_mode(self._window, mode)
        self._apply_input_region()
